//------------------------------------------------------------------------------
// @file ddr_axi_backend.sv
// @module-contract
// Converts one internal DDRAM request into one AXI4 burst or write. DDRAM_BUSY
// stays asserted until every AXI channel belonging to the request has retired.
// AXI VALID and payloads are never withdrawn before READY. A watchdog reports a
// recoverable fault and suppresses DDRAM read data, then drains the live AXI
// transaction. A second no-progress timeout marks the backend fatal while the
// interface remains quiesced and continues honoring the outstanding handshake.
//------------------------------------------------------------------------------
module ddr_axi_backend_sv #(
  parameter logic [31:0] G_DDR_BASE = 32'h1000_0000,
  parameter logic [19:0] G_WATCHDOG_LIMIT = 20'd100000,
  parameter logic [19:0] G_DRAIN_TIMEOUT  = 20'd100000
) (
  input  logic         clk,
  input  logic         rst_n,

  output logic         DDRAM_BUSY,
  input  logic [7:0]   DDRAM_BURSTCNT,
  input  logic [28:0]  DDRAM_ADDR,
  output logic [63:0]  DDRAM_DOUT,
  output logic         DDRAM_DOUT_READY,
  output logic         DDRAM_DONE,
  input  logic         DDRAM_RD,
  input  logic [63:0]  DDRAM_DIN,
  input  logic [7:0]   DDRAM_BE,
  input  logic         DDRAM_WE,

  output logic [31:0]  M_AXI_AWADDR,
  output logic [7:0]   M_AXI_AWLEN,
  output logic [2:0]   M_AXI_AWSIZE,
  output logic [1:0]   M_AXI_AWBURST,
  output logic         M_AXI_AWVALID,
  input  logic         M_AXI_AWREADY,

  output logic [63:0]  M_AXI_WDATA,
  output logic [7:0]   M_AXI_WSTRB,
  output logic         M_AXI_WLAST,
  output logic         M_AXI_WVALID,
  input  logic         M_AXI_WREADY,

  input  logic [1:0]   M_AXI_BRESP,
  input  logic         M_AXI_BVALID,
  output logic         M_AXI_BREADY,

  output logic [31:0]  M_AXI_ARADDR,
  output logic [7:0]   M_AXI_ARLEN,
  output logic [2:0]   M_AXI_ARSIZE,
  output logic [1:0]   M_AXI_ARBURST,
  output logic         M_AXI_ARVALID,
  input  logic         M_AXI_ARREADY,

  input  logic [63:0]  M_AXI_RDATA,
  input  logic [1:0]   M_AXI_RRESP,
  input  logic         M_AXI_RLAST,
  input  logic         M_AXI_RVALID,
  output logic         M_AXI_RREADY,

  output logic [31:0]  ERR_VEC,
  output logic         ERR_PULSE,
  output logic         FATAL_FAULT
);
  localparam logic [31:0] C_MISTER_BASE = 32'h3000_0000;
  localparam logic [3:0]  ERR_READ_TIMEOUT  = 4'hD;
  localparam logic [3:0]  ERR_WRITE_TIMEOUT = 4'hD;
  localparam logic [3:0]  ERR_RLAST         = 4'hC;
  localparam logic [3:0]  ERR_FATAL_DRAIN   = 4'hE;

  typedef enum logic [2:0] {
    S_IDLE,
    S_RD_ADDR,
    S_RD_DATA,
    S_WR_ADDR_DATA,
    S_WR_RESP
  } state_t;

  state_t state;
  logic [31:0] awaddr_reg;
  logic [7:0]  awlen_reg;
  logic        awvalid_reg;
  logic [63:0] wdata_reg;
  logic [7:0]  wstrb_reg;
  logic        wvalid_reg;
  logic        bready_reg;
  logic [31:0] araddr_reg;
  logic [7:0]  arlen_reg;
  logic        arvalid_reg;
  logic        rready_reg;
  logic [63:0] dout_reg;
  logic        dout_ready_reg;
  logic        done_reg;
  logic [7:0]  rd_remaining;
  logic        aw_done;
  logic        w_done;
  logic        txn_faulted;
  logic [19:0] watchdog_ctr;
  logic [19:0] drain_watchdog_ctr;

  wire ar_fire = arvalid_reg && M_AXI_ARREADY;
  wire r_fire  = rready_reg && M_AXI_RVALID;
  wire aw_fire = awvalid_reg && M_AXI_AWREADY;
  wire w_fire  = wvalid_reg && M_AXI_WREADY;
  wire b_fire  = bready_reg && M_AXI_BVALID;
  wire progress = ar_fire || r_fire || aw_fire || w_fire || b_fire;
  wire timeout_now = (state != S_IDLE) && !txn_faulted &&
                     (watchdog_ctr >= G_WATCHDOG_LIMIT);
  wire drain_timeout_now = (state != S_IDLE) && txn_faulted &&
                           !FATAL_FAULT &&
                           (drain_watchdog_ctr >= G_DRAIN_TIMEOUT);

  function automatic logic [31:0] map_addr(input logic [28:0] in_addr);
    logic [31:0] full_addr;
    begin
      full_addr = {in_addr, 3'b000};
      if (full_addr >= C_MISTER_BASE)
        map_addr = G_DDR_BASE + (full_addr - C_MISTER_BASE);
      else
        map_addr = G_DDR_BASE + full_addr;
    end
  endfunction

  task automatic latch_error(input logic [3:0] err_code,
                             input logic [27:0] err_addr);
    begin
      ERR_VEC   <= {err_code, err_addr};
      ERR_PULSE <= 1'b1;
    end
  endtask

  assign DDRAM_BUSY       = (state != S_IDLE);
  assign DDRAM_DOUT        = dout_reg;
  assign DDRAM_DOUT_READY  = dout_ready_reg;
  assign DDRAM_DONE        = done_reg;

  assign M_AXI_AWADDR      = awaddr_reg;
  assign M_AXI_AWLEN       = awlen_reg;
  assign M_AXI_AWSIZE      = 3'b011;
  assign M_AXI_AWBURST     = 2'b01;
  assign M_AXI_AWVALID     = awvalid_reg;
  assign M_AXI_WDATA       = wdata_reg;
  assign M_AXI_WSTRB       = wstrb_reg;
  assign M_AXI_WLAST       = wvalid_reg && (awlen_reg == 8'd0);
  assign M_AXI_WVALID      = wvalid_reg;
  assign M_AXI_BREADY      = bready_reg;
  assign M_AXI_ARADDR      = araddr_reg;
  assign M_AXI_ARLEN       = arlen_reg;
  assign M_AXI_ARSIZE      = 3'b011;
  assign M_AXI_ARBURST     = 2'b01;
  assign M_AXI_ARVALID     = arvalid_reg;
  assign M_AXI_RREADY      = rready_reg;

  always_ff @(posedge clk) begin
    logic expected_last;
    logic good_read_beat;

    if (!rst_n) begin
      state             <= S_IDLE;
      awvalid_reg       <= 1'b0;
      wvalid_reg        <= 1'b0;
      bready_reg        <= 1'b0;
      arvalid_reg       <= 1'b0;
      rready_reg        <= 1'b0;
      dout_ready_reg    <= 1'b0;
      done_reg          <= 1'b0;
      aw_done           <= 1'b0;
      w_done            <= 1'b0;
      rd_remaining      <= 8'd0;
      watchdog_ctr      <= 20'd0;
      drain_watchdog_ctr<= 20'd0;
      txn_faulted       <= 1'b0;
      FATAL_FAULT       <= 1'b0;
      dout_reg          <= 64'd0;
      awaddr_reg        <= 32'd0;
      awlen_reg         <= 8'd0;
      wdata_reg         <= 64'd0;
      wstrb_reg         <= 8'd0;
      araddr_reg        <= 32'd0;
      arlen_reg         <= 8'd0;
      ERR_VEC           <= 32'd0;
      ERR_PULSE         <= 1'b0;
    end else begin
      dout_ready_reg <= 1'b0;
      done_reg <= 1'b0;
      ERR_PULSE <= 1'b0;

      if (state == S_IDLE) begin
        watchdog_ctr       <= 20'd0;
        drain_watchdog_ctr <= 20'd0;
        txn_faulted        <= 1'b0;
      end else if (progress) begin
        watchdog_ctr <= 20'd0;
        if (txn_faulted) drain_watchdog_ctr <= 20'd0;
      end else if (!txn_faulted) begin
        watchdog_ctr <= watchdog_ctr + 20'd1;
      end else if (!FATAL_FAULT) begin
        drain_watchdog_ctr <= drain_watchdog_ctr + 20'd1;
      end

      if (timeout_now) begin
        txn_faulted <= 1'b1;
        drain_watchdog_ctr <= 20'd0;
        if (state == S_RD_ADDR || state == S_RD_DATA)
          latch_error(ERR_READ_TIMEOUT, araddr_reg[27:0]);
        else
          latch_error(ERR_WRITE_TIMEOUT, awaddr_reg[27:0]);
      end

      if (drain_timeout_now) begin
        FATAL_FAULT <= 1'b1;
        latch_error(ERR_FATAL_DRAIN,
                    (state == S_RD_ADDR || state == S_RD_DATA)
                      ? araddr_reg[27:0] : awaddr_reg[27:0]);
      end

      case (state)
        S_IDLE: begin
          if (DDRAM_RD) begin
            araddr_reg   <= map_addr(DDRAM_ADDR);
            arlen_reg    <= (DDRAM_BURSTCNT == 8'd0)
                              ? 8'd0 : DDRAM_BURSTCNT - 8'd1;
            rd_remaining <= (DDRAM_BURSTCNT == 8'd0)
                              ? 8'd0 : DDRAM_BURSTCNT - 8'd1;
            arvalid_reg  <= 1'b1;
            rready_reg   <= 1'b0;
            state        <= S_RD_ADDR;
          end else if (DDRAM_WE) begin
            awaddr_reg   <= map_addr(DDRAM_ADDR);
            awlen_reg    <= 8'd0;
            awvalid_reg  <= 1'b1;
            wdata_reg    <= DDRAM_DIN;
            wstrb_reg    <= DDRAM_BE;
            wvalid_reg   <= 1'b1;
            bready_reg   <= 1'b0;
            aw_done      <= 1'b0;
            w_done       <= 1'b0;
            state        <= S_WR_ADDR_DATA;
          end
        end

        S_RD_ADDR: begin
          if (ar_fire) begin
            arvalid_reg <= 1'b0;
            rready_reg  <= 1'b1;
            state       <= S_RD_DATA;
          end
        end

        S_RD_DATA: begin
          if (r_fire) begin
            expected_last = (rd_remaining == 8'd0);
            good_read_beat = !txn_faulted && !timeout_now &&
                             (M_AXI_RRESP == 2'b00) &&
                             (M_AXI_RLAST == expected_last);

            if (good_read_beat) begin
              dout_reg       <= M_AXI_RDATA;
              dout_ready_reg <= 1'b1;
            end

            if (!txn_faulted && !timeout_now) begin
              if (M_AXI_RRESP != 2'b00) begin
                txn_faulted <= 1'b1;
                drain_watchdog_ctr <= 20'd0;
                latch_error({2'b01, M_AXI_RRESP}, araddr_reg[27:0]);
              end else if (M_AXI_RLAST != expected_last) begin
                txn_faulted <= 1'b1;
                drain_watchdog_ctr <= 20'd0;
                latch_error(ERR_RLAST, araddr_reg[27:0]);
              end
            end

            if (M_AXI_RLAST) begin
              done_reg <= 1'b1;
              rready_reg <= 1'b0;
              rd_remaining <= 8'd0;
              state <= S_IDLE;
              txn_faulted <= 1'b0;
              drain_watchdog_ctr <= 20'd0;
            end else if (!txn_faulted && !timeout_now && !expected_last) begin
              rd_remaining <= rd_remaining - 8'd1;
            end
          end
        end

        S_WR_ADDR_DATA: begin
          if (aw_fire) begin
            awvalid_reg <= 1'b0;
            aw_done <= 1'b1;
          end
          if (w_fire) begin
            wvalid_reg <= 1'b0;
            w_done <= 1'b1;
          end
          if ((aw_done || aw_fire) && (w_done || w_fire)) begin
            bready_reg <= 1'b1;
            state <= S_WR_RESP;
          end
        end

        S_WR_RESP: begin
          if (b_fire) begin
            done_reg <= 1'b1;
            if (!txn_faulted && !timeout_now && M_AXI_BRESP != 2'b00)
              latch_error({2'b10, M_AXI_BRESP}, awaddr_reg[27:0]);
            bready_reg <= 1'b0;
            state <= S_IDLE;
            txn_faulted <= 1'b0;
            drain_watchdog_ctr <= 20'd0;
          end
        end

        default: begin
          // No outstanding AXI VALID is withdrawn by the recovery path.
          // An illegal encoding is quarantined and reported as fatal.
          FATAL_FAULT <= 1'b1;
          latch_error(ERR_FATAL_DRAIN, 28'd0);
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_arvalid_stable_until_handshake;
    @(posedge clk) disable iff (!rst_n)
      M_AXI_ARVALID && !M_AXI_ARREADY |=> M_AXI_ARVALID &&
        $stable({M_AXI_ARADDR, M_AXI_ARLEN, M_AXI_ARSIZE, M_AXI_ARBURST});
  endproperty
  assert property (p_arvalid_stable_until_handshake);

  property p_awvalid_stable_until_handshake;
    @(posedge clk) disable iff (!rst_n)
      M_AXI_AWVALID && !M_AXI_AWREADY |=> M_AXI_AWVALID &&
        $stable({M_AXI_AWADDR, M_AXI_AWLEN, M_AXI_AWSIZE, M_AXI_AWBURST});
  endproperty
  assert property (p_awvalid_stable_until_handshake);

  property p_wvalid_stable_until_handshake;
    @(posedge clk) disable iff (!rst_n)
      M_AXI_WVALID && !M_AXI_WREADY |=> M_AXI_WVALID &&
        $stable({M_AXI_WDATA, M_AXI_WSTRB, M_AXI_WLAST});
  endproperty
  assert property (p_wvalid_stable_until_handshake);

  property p_bad_read_response_never_reaches_ddram;
    @(posedge clk) disable iff (!rst_n)
      r_fire && (M_AXI_RRESP != 2'b00) |=> !DDRAM_DOUT_READY;
  endproperty
  assert property (p_bad_read_response_never_reaches_ddram);

  property p_done_only_after_response_retirement;
    @(posedge clk) disable iff (!rst_n)
      DDRAM_DONE |-> $past((state == S_WR_RESP && b_fire) ||
                           (state == S_RD_DATA && r_fire && M_AXI_RLAST));
  endproperty
  assert property (p_done_only_after_response_retirement);

  property p_b_response_retires_write_once;
    @(posedge clk) disable iff (!rst_n)
      b_fire |=> DDRAM_DONE && !DDRAM_BUSY;
  endproperty
  assert property (p_b_response_retires_write_once);

  property p_done_is_single_cycle;
    @(posedge clk) disable iff (!rst_n)
      DDRAM_DONE |=> !DDRAM_DONE;
  endproperty
  assert property (p_done_is_single_cycle);
`endif
endmodule

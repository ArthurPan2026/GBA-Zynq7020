`timescale 1ns/1ps
module tb_ddr_axi_backend_fault_drain;
  logic test_done = 1'b0;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [7:0] DDRAM_BURSTCNT = 8'd1;
  logic [28:0] DDRAM_ADDR = 29'd0;
  logic [63:0] DDRAM_DIN = 64'd0;
  logic [7:0] DDRAM_BE = 8'hFF;
  logic DDRAM_RD = 1'b0;
  logic DDRAM_WE = 1'b0;
  wire DDRAM_BUSY;
  wire [63:0] DDRAM_DOUT;
  wire DDRAM_DOUT_READY;
  wire DDRAM_DONE;

  wire [31:0] M_AXI_AWADDR;
  wire [7:0] M_AXI_AWLEN;
  wire [2:0] M_AXI_AWSIZE;
  wire [1:0] M_AXI_AWBURST;
  wire M_AXI_AWVALID;
  logic M_AXI_AWREADY = 1'b0;
  wire [63:0] M_AXI_WDATA;
  wire [7:0] M_AXI_WSTRB;
  wire M_AXI_WLAST;
  wire M_AXI_WVALID;
  logic M_AXI_WREADY = 1'b0;
  logic [1:0] M_AXI_BRESP = 2'b00;
  logic M_AXI_BVALID = 1'b0;
  wire M_AXI_BREADY;

  wire [31:0] M_AXI_ARADDR;
  wire [7:0] M_AXI_ARLEN;
  wire [2:0] M_AXI_ARSIZE;
  wire [1:0] M_AXI_ARBURST;
  wire M_AXI_ARVALID;
  logic M_AXI_ARREADY = 1'b0;
  logic [63:0] M_AXI_RDATA = 64'd0;
  logic [1:0] M_AXI_RRESP = 2'b00;
  logic M_AXI_RLAST = 1'b0;
  logic M_AXI_RVALID = 1'b0;
  wire M_AXI_RREADY;
  wire [31:0] ERR_VEC;
  wire ERR_PULSE;
  wire FATAL_FAULT;

  ddr_axi_backend_sv #(
    .G_DDR_BASE(32'd0),
    .G_WATCHDOG_LIMIT(20'd8),
    .G_DRAIN_TIMEOUT(20'd12)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_DONE(DDRAM_DONE),
    .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_AWLEN(M_AXI_AWLEN),
    .M_AXI_AWSIZE(M_AXI_AWSIZE), .M_AXI_AWBURST(M_AXI_AWBURST),
    .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_AWREADY(M_AXI_AWREADY),
    .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB),
    .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_WVALID(M_AXI_WVALID),
    .M_AXI_WREADY(M_AXI_WREADY), .M_AXI_BRESP(M_AXI_BRESP),
    .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_BREADY(M_AXI_BREADY),
    .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_ARLEN(M_AXI_ARLEN),
    .M_AXI_ARSIZE(M_AXI_ARSIZE), .M_AXI_ARBURST(M_AXI_ARBURST),
    .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_ARREADY(M_AXI_ARREADY),
    .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP),
    .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_RVALID(M_AXI_RVALID),
    .M_AXI_RREADY(M_AXI_RREADY), .ERR_VEC(ERR_VEC), .ERR_PULSE(ERR_PULSE),
    .FATAL_FAULT(FATAL_FAULT)
  );

  task automatic launch_read(input logic [7:0] beats, input logic [28:0] addr);
  begin
    @(negedge clk);
    DDRAM_ADDR = addr;
    DDRAM_BURSTCNT = beats;
    DDRAM_RD = 1'b1;
    @(negedge clk);
    DDRAM_RD = 1'b0;
  end
  endtask

  task automatic send_rbeat(input logic [1:0] resp,
                            input logic last,
                            input logic [63:0] data);
  begin
    @(negedge clk);
    M_AXI_RRESP = resp;
    M_AXI_RLAST = last;
    M_AXI_RDATA = data;
    M_AXI_RVALID = 1'b1;
    @(posedge clk); #1;
    M_AXI_RVALID = 1'b0;
    M_AXI_RLAST = 1'b0;
  end
  endtask

  initial begin
    #100us;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_ddr_axi_backend_fault_drain.sv");
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Timeout while ARREADY is low must report a fault without retracting
    // ARVALID or changing its payload. A late, otherwise-good response is
    // drained but never delivered to DDRAM/cache.
    launch_read(8'd1, 29'h0000_0123);
    wait (M_AXI_ARVALID);
    begin : ar_stall_check
      logic [39:0] held;
      held = {M_AXI_ARADDR, M_AXI_ARLEN};
      repeat (10) begin
        @(negedge clk);
        if (!M_AXI_ARVALID || {M_AXI_ARADDR, M_AXI_ARLEN} !== held)
          $fatal(1, "TEST_FAIL: ARVALID/payload changed before ARREADY");
        if (!DDRAM_BUSY) $fatal(1, "TEST_FAIL: backend left busy while AR was outstanding");
      end
    end
    if (ERR_VEC[31:28] != 4'hD) $fatal(1, "TEST_FAIL: read timeout code missing: %h", ERR_VEC);
    M_AXI_ARREADY = 1'b1;
    @(posedge clk); #1;
    M_AXI_ARREADY = 1'b0;
    if (!M_AXI_RREADY) $fatal(1, "TEST_FAIL: backend did not enter read drain");
    send_rbeat(2'b00, 1'b1, 64'hA5A5_5A5A_DEAD_BEEF);
    if (DDRAM_DOUT_READY) $fatal(1, "TEST_FAIL: late read data leaked to DDRAM");
    if (!DDRAM_DONE || DDRAM_BUSY) $fatal(1, "TEST_FAIL: backend did not retire late RLAST exactly once");

    // A response error on an early beat suppresses that data and drains the
    // rest of the burst before returning idle.
    DDRAM_BURSTCNT = 8'd2;
    launch_read(8'd2, 29'h0000_0200);
    wait (M_AXI_ARVALID);
    M_AXI_ARREADY = 1'b1;
    @(posedge clk); #1;
    M_AXI_ARREADY = 1'b0;
    send_rbeat(2'b10, 1'b0, 64'hFFFF_FFFF_FFFF_FFFF);
    if (DDRAM_DOUT_READY) $fatal(1, "TEST_FAIL: SLVERR beat leaked to DDRAM");
    if (!DDRAM_BUSY || !M_AXI_RREADY) $fatal(1, "TEST_FAIL: response error was not drained");
    send_rbeat(2'b00, 1'b1, 64'h1234_5678_9ABC_DEF0);
    if (DDRAM_DOUT_READY || DDRAM_BUSY) $fatal(1, "TEST_FAIL: drain beat leaked or transaction stayed busy");

    // AW and W remain independently valid and stable across timeout; B is
    // still consumed before the backend releases the request.
    @(negedge clk);
    DDRAM_ADDR = 29'h0000_0040;
    DDRAM_DIN = 64'h0123_4567_89AB_CDEF;
    DDRAM_BE = 8'h5A;
    DDRAM_WE = 1'b1;
    @(negedge clk);
    DDRAM_WE = 1'b0;
    wait (M_AXI_AWVALID && M_AXI_WVALID);
    begin : wr_stall_check
      logic [31:0] held_addr;
      logic [63:0] held_data;
      logic [7:0] held_strb;
      held_addr = M_AXI_AWADDR;
      held_data = M_AXI_WDATA;
      held_strb = M_AXI_WSTRB;
      repeat (10) begin
        @(negedge clk);
        if (!M_AXI_AWVALID || !M_AXI_WVALID || M_AXI_AWADDR !== held_addr ||
            M_AXI_WDATA !== held_data || M_AXI_WSTRB !== held_strb)
          $fatal(1, "TEST_FAIL: AW/WVALID or payload changed before READY");
      end
    end
    M_AXI_AWREADY = 1'b1;
    @(posedge clk); #1;
    M_AXI_AWREADY = 1'b0;
    if (!M_AXI_WVALID) $fatal(1, "TEST_FAIL: WVALID dropped before WREADY");
    M_AXI_WREADY = 1'b1;
    @(posedge clk); #1;
    M_AXI_WREADY = 1'b0;
    if (!M_AXI_BREADY || !DDRAM_BUSY || DDRAM_DONE)
      $fatal(1, "TEST_FAIL: write did not wait for B response");
    repeat (2) @(negedge clk);
    M_AXI_BVALID = 1'b1;
    @(posedge clk); #1;
    M_AXI_BVALID = 1'b0;
    if (DDRAM_BUSY || !DDRAM_DONE) $fatal(1, "TEST_FAIL: write response did not retire exactly once");

    // A transaction that never drains becomes fatal but continues to hold the
    // AXI request and DDRAM_BUSY, preventing unsafe reuse of the port.
    launch_read(8'd1, 29'h0000_0300);
    wait (M_AXI_ARVALID);
    repeat (32) @(negedge clk);
    if (!FATAL_FAULT) $fatal(1, "TEST_FAIL: undrained transaction did not become fatal");
    if (!M_AXI_ARVALID || !DDRAM_BUSY)
      $fatal(1, "TEST_FAIL: fatal drain withdrew ARVALID or released DDRAM_BUSY");

    test_done = 1'b1;
    $display("TEST_PASS: tb_ddr_axi_backend_fault_drain");
    $finish;
  end
endmodule

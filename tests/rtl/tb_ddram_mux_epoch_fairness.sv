`timescale 1ns/1ps
`include "../../src/rtl/common/ps_pl_contract_generated.vh"
module tb_ddram_mux_epoch_fairness;
  logic test_done = 1'b0;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic backend_busy = 1'b0;
  logic [63:0] backend_data = 64'h1111_2222_3333_4444;
  logic backend_stall = 1'b0;
  logic [7:0] backend_beats_left = 8'd0;
  logic [63:0] backend_txn_data = 64'd0;
  logic backend_is_write = 1'b0;
  integer backend_reads = 0;
  logic [7:0] DDRAM_BURSTCNT;
  logic DDRAM_DONE = 1'b0;
  wire ch4_write_done;
  wire MEM_ACCEPT_NEW;
  logic [28:0] DDRAM_ADDR;
  wire [63:0] DDRAM_DOUT;
  logic DDRAM_DOUT_READY;
  wire DDRAM_RD;
  wire [63:0] DDRAM_DIN;
  wire [7:0] DDRAM_BE;
  wire DDRAM_WE;

  logic CFG_ROM_DDR_SAFE = 1'b0;
  logic MEM_CMD_VALID = 1'b0;
  logic [63:0] MEM_CMD_PAYLOAD = 64'd0;
  wire MEM_CMD_READY;
  logic DDRAM_ERR_PULSE = 1'b0;
  logic [31:0] DDRAM_ERR_VEC = 32'd0;
  logic DDRAM_FATAL_FAULT = 1'b0;
  wire [4:0] MEM_STATUS;
  wire [3:0] MEM_ERROR;
  wire [27:0] MEM_ERROR_ADDR;
  wire [31:0] ROM_EPOCH;

  logic [27:1] ch1_addr = '0;
  wire [63:0] ch1_dout;
  logic [15:0] ch1_din = 16'd0;
  logic ch1_req = 1'b0;
  logic ch1_rnw = 1'b1;
  wire ch1_ready;

  logic [27:1] ch2_addr = '0;
  wire [31:0] ch2_dout;
  logic [31:0] ch2_din = 32'd0;
  logic ch2_req = 1'b0;
  logic ch2_rnw = 1'b1;
  wire ch2_ready;

  logic [25:1] ch3_addr = '0;
  wire [15:0] ch3_dout;
  logic [15:0] ch3_din = 16'd0;
  logic ch3_req = 1'b0;
  logic ch3_rnw = 1'b1;
  wire ch3_ready;

  logic [27:1] ch4_addr = '0;
  wire [63:0] ch4_dout;
  logic [63:0] ch4_din = 64'd0;
  logic ch4_req = 1'b0;
  logic ch4_rnw = 1'b1;
  logic [7:0] ch4_be = 8'hFF;
  wire ch4_ready;

  logic [27:1] ch5_addr = '0;
  wire [63:0] ch5_dout;
  logic [63:0] ch5_din = 64'd0;
  logic ch5_req = 1'b0;
  logic ch5_rnw = 1'b1;
  wire ch5_ready;

  integer ready1_count = 0;
  integer ready2_count = 0;
  integer ready3_count = 0;
  integer ready4_count = 0;
  integer ready5_count = 0;

  assign DDRAM_DOUT = backend_txn_data;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      backend_busy <= 1'b0;
      DDRAM_DOUT_READY <= 1'b0;
      backend_beats_left <= 8'd0;
      backend_txn_data <= 64'd0;
      backend_is_write <= 1'b0;
      backend_reads <= 0;
    end else begin
      DDRAM_DOUT_READY <= 1'b0;
      DDRAM_DONE <= 1'b0;
      if (!backend_busy && (DDRAM_RD || DDRAM_WE)) begin
        backend_busy <= 1'b1;
        backend_is_write <= DDRAM_WE;
        if (DDRAM_RD) begin
          backend_beats_left <= (DDRAM_BURSTCNT == 0) ? 8'd1 : DDRAM_BURSTCNT;
          backend_txn_data <= backend_data;
          backend_reads <= backend_reads + 1;
        end else begin
          backend_beats_left <= 8'd1;
        end
      end else if (backend_busy && !backend_stall) begin
        if (backend_is_write) begin
          backend_beats_left <= 8'd0;
          backend_busy <= 1'b0;
          DDRAM_DONE <= 1'b1;
        end else if (backend_beats_left != 0) begin
          DDRAM_DOUT_READY <= 1'b1;
          if (backend_beats_left == 8'd1) begin
            backend_beats_left <= 8'd0;
            backend_busy <= 1'b0;
            DDRAM_DONE <= 1'b1;
          end else begin
            backend_beats_left <= backend_beats_left - 8'd1;
          end
        end
      end

      if (ch1_ready) ready1_count <= ready1_count + 1;
      if (ch2_ready) ready2_count <= ready2_count + 1;
      if (ch3_ready) ready3_count <= ready3_count + 1;
      if (ch4_ready) ready4_count <= ready4_count + 1;
      if (ch5_ready) ready5_count <= ready5_count + 1;
    end
  end

  ddram_mux dut (
    .DDRAM_CLK(clk), .rst_n(rst_n), .DDRAM_BUSY(backend_busy),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_DONE(DDRAM_DONE), .ch4_write_done(ch4_write_done),
    .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE), .CFG_ROM_DDR_SAFE(CFG_ROM_DDR_SAFE),
    .MEM_CMD_VALID(MEM_CMD_VALID), .MEM_CMD_PAYLOAD(MEM_CMD_PAYLOAD),
    .MEM_CMD_ACK_ENABLE(1'b1), .MEM_CMD_READY(MEM_CMD_READY),
    .MEM_ACCEPT_NEW(MEM_ACCEPT_NEW), .DDRAM_ERR_PULSE(DDRAM_ERR_PULSE),
    .DDRAM_ERR_VEC(DDRAM_ERR_VEC), .DDRAM_FATAL_FAULT(DDRAM_FATAL_FAULT),
    .MEM_STATUS(MEM_STATUS), .MEM_ERROR(MEM_ERROR),
    .MEM_ERROR_ADDR(MEM_ERROR_ADDR), .ROM_EPOCH(ROM_EPOCH),
    .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_din(ch1_din),
    .ch1_req(ch1_req), .ch1_rnw(ch1_rnw), .ch1_ready(ch1_ready),
    .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_din(ch2_din),
    .ch2_req(ch2_req), .ch2_rnw(ch2_rnw), .ch2_ready(ch2_ready),
    .ch3_addr(ch3_addr), .ch3_dout(ch3_dout), .ch3_din(ch3_din),
    .ch3_req(ch3_req), .ch3_rnw(ch3_rnw), .ch3_ready(ch3_ready),
    .ch4_addr(ch4_addr), .ch4_dout(ch4_dout), .ch4_din(ch4_din),
    .ch4_req(ch4_req), .ch4_rnw(ch4_rnw), .ch4_be(ch4_be), .ch4_ready(ch4_ready),
    .ch5_addr(ch5_addr), .ch5_dout(ch5_dout), .ch5_din(ch5_din),
    .ch5_req(ch5_req), .ch5_rnw(ch5_rnw), .ch5_ready(ch5_ready)
  );

  task automatic pulse_ch1(input logic [27:1] addr);
  begin
    @(negedge clk); ch1_addr = addr; ch1_req = 1'b1;
    @(negedge clk); ch1_req = 1'b0;
  end
  endtask

  task automatic send_mem_cmd(input logic [31:0] command,
                              input logic [31:0] command_sequence);
  begin
    @(negedge clk);
    MEM_CMD_PAYLOAD = {command_sequence, command};
    MEM_CMD_VALID = 1'b1;
    do @(negedge clk); while (!MEM_CMD_READY);
    @(negedge clk);
    MEM_CMD_VALID = 1'b0;
  end
  endtask

  initial begin
    #2ms;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_ddram_mux_epoch_fairness.sv");
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(negedge clk);

    // Change cache epoch while a read is still returning. The old response must
    // be drained without READY/cache fill, forcing a fresh DDR transaction.
    backend_stall = 1'b1;
    pulse_ch1(27'h0000_100);
    wait (backend_busy);
    begin : stale_epoch_read
      integer old_ready_count;
      integer old_read_count;
      old_ready_count = ready1_count;
      old_read_count = backend_reads;
      @(negedge clk); CFG_ROM_DDR_SAFE = 1'b1;
      backend_data = 64'hAAAA_0000_1111_0000;
      backend_stall = 1'b0;
      wait (!backend_busy);
      repeat (3) @(negedge clk);
      if (ready1_count != old_ready_count)
        $fatal(1, "TEST_FAIL: stale epoch data became visible to channel 1");
      pulse_ch1(27'h0000_100);
      wait (ch1_ready);
      if (backend_reads != old_read_count + 1)
        $fatal(1, "TEST_FAIL: stale line was cached across ROM epoch change");
      if (ch1_dout !== backend_data)
        $fatal(1, "TEST_FAIL: post-epoch read returned wrong data");
    end

    // Every continuously active request must be served; rr_last_grant advances
    // only when a real pending channel is granted, so unused ports consume no turn.
    begin : active_channel_fairness
      integer c1, c2, c3, c4, c5;
      c1 = dut.grant_count_ch1;
      c2 = dut.grant_count_ch2;
      c3 = dut.grant_count_ch3;
      c4 = dut.grant_count_ch4;
      c5 = dut.grant_count_ch5;
      @(negedge clk);
      ch1_addr = 27'h0000_400; ch1_req = 1'b1;
      ch2_addr = 27'h0000_800; ch2_req = 1'b1;
      ch3_addr = 25'h0000_200; ch3_req = 1'b1;
      ch4_addr = 27'h0000_C00; ch4_req = 1'b1;
      ch5_addr = 27'h0001_000; ch5_req = 1'b1;
      @(negedge clk);
      ch1_req = 1'b0; ch2_req = 1'b0; ch3_req = 1'b0;
      ch4_req = 1'b0; ch5_req = 1'b0;
      wait ((ready1_count > 1) && (ready2_count > 0) && (ready3_count > 0) &&
            (ready4_count > 0) && (ready5_count > 0));
      if (dut.grant_count_ch1 <= c1 || dut.grant_count_ch2 <= c2 ||
          dut.grant_count_ch3 <= c3 || dut.grant_count_ch4 <= c4 ||
          dut.grant_count_ch5 <= c5)
        $fatal(1, "TEST_FAIL: active channel starved under round-robin arbitration");
    end

    // Channel 4 write ACK is an acceptance pulse; the save-busy lifetime must
    // extend through the backend response, represented by DDRAM_DONE here.
    backend_stall = 1'b1;
    @(negedge clk);
    ch4_addr = 27'h0000_180;
    ch4_din = 64'h0123_4567_89AB_CDEF;
    ch4_req = 1'b1;
    ch4_rnw = 1'b0;
    @(negedge clk);
    ch4_req = 1'b0;
    wait (ch4_ready);
    if (ch4_write_done) $fatal(1, "TEST_FAIL: channel-4 write retired before backend response");
    wait (backend_busy);
    repeat (3) @(negedge clk);
    if (ch4_write_done) $fatal(1, "TEST_FAIL: write-busy cleared during response stall");
    backend_stall = 1'b0;
    wait (ch4_write_done);
    wait (!backend_busy);

    // Quiesce, flush, and epoch advance are serialized through the same command
    // handshake; flush cannot acknowledge before the cache-clear pulse.
    send_mem_cmd(`PS_PL_MEM_CMD_QUIESCE, 32'd1);
    if (((MEM_STATUS & `PS_PL_MEM_STATUS_QUIESCED) == 0) || ((MEM_STATUS & `PS_PL_MEM_STATUS_DRAINED) == 0)) $fatal(1, "TEST_FAIL: quiesce failed to drain");
    send_mem_cmd(`PS_PL_MEM_CMD_FLUSH_ROM, 32'd2);
    if (ROM_EPOCH != 32'd1) $fatal(1, "TEST_FAIL: flush did not advance ROM epoch");
    send_mem_cmd(`PS_PL_MEM_CMD_RESUME, 32'd3);
    if (!dut.accept_new_requests) $fatal(1, "TEST_FAIL: resume failed to reopen request acceptance");

    test_done = 1'b1;
    $display("TEST_PASS: tb_ddram_mux_epoch_fairness");
    $finish;
  end
endmodule

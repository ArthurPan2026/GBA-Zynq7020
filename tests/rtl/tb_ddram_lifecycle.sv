`timescale 1ns/1ps
`include "../../src/rtl/common/ps_pl_contract_generated.vh"
module tb_ddram_lifecycle;
  logic test_done = 1'b0;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic cmd_valid = 1'b0;
  logic [63:0] cmd_payload = 64'd0;
  logic ack_enable = 1'b1;
  wire cmd_ready;
  logic drained = 1'b1;
  logic backend_error_pulse = 1'b0;
  logic [31:0] backend_error_vec = 32'd0;
  logic backend_fatal = 1'b0;
  wire accept_new_requests;
  wire cache_flush;
  wire [4:0] mem_status;
  wire [3:0] mem_error;
  wire [27:0] mem_error_addr;
  wire [31:0] rom_epoch;
  integer flush_count = 0;

  ddram_lifecycle_ctrl dut (.*);

  always @(posedge clk) begin
    if (cache_flush) flush_count <= flush_count + 1;
  end

  task automatic send_command(input logic [31:0] command,
                              input logic [31:0] command_sequence);
  begin
    @(negedge clk);
    cmd_payload = {command_sequence, command};
    cmd_valid = 1'b1;
    do @(negedge clk); while (!cmd_ready);
    @(negedge clk); // command handshakes at the preceding rising edge
    cmd_valid = 1'b0;
  end
  endtask

  initial begin
    #100us;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_ddram_lifecycle.sv");
  end

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    // QUIESCE must wait for a real drain before its response is acknowledged.
    drained = 1'b0;
    @(negedge clk);
    cmd_payload = {32'd1, `PS_PL_MEM_CMD_QUIESCE};
    cmd_valid = 1'b1;
    repeat (4) begin
      @(negedge clk);
      if (cmd_ready) $fatal(1, "TEST_FAIL: QUIESCE acknowledged before drain");
      if (accept_new_requests) $fatal(1, "TEST_FAIL: new requests accepted while quiescing");
    end
    ack_enable = 1'b0; // status snapshot return has not crossed back yet
    drained = 1'b1;
    repeat (3) begin
      @(negedge clk);
      if (cmd_ready) $fatal(1, "TEST_FAIL: command ACK escaped before status snapshot ACK");
    end
    ack_enable = 1'b1;
    do @(negedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 1'b0;
    if (((mem_status & `PS_PL_MEM_STATUS_QUIESCED) == 0) || ((mem_status & `PS_PL_MEM_STATUS_DRAINED) == 0)) $fatal(1, "TEST_FAIL: QUIESCE status missing");

    send_command(`PS_PL_MEM_CMD_FLUSH_ROM, 32'd2);
    if (rom_epoch != 32'd1 || flush_count != 1)
      $fatal(1, "TEST_FAIL: successful flush did not advance epoch exactly once");

    send_command(`PS_PL_MEM_CMD_RESUME, 32'd3);
    if (!accept_new_requests) $fatal(1, "TEST_FAIL: RESUME did not reopen request acceptance");

    // A recoverable AXI error automatically quiesces. FLUSH preserves the
    // error until CLEAR_ERROR; RESUME stays blocked until both are complete.
    @(negedge clk);
    backend_error_vec = {4'h6, 28'h0123_4567};
    backend_error_pulse = 1'b1;
    @(negedge clk);
    backend_error_pulse = 1'b0;
    wait (mem_status[0]);
    if (((mem_status & `PS_PL_MEM_STATUS_FAULTED) == 0) || mem_error != 4'h6 || mem_error_addr != 28'h0123_4567)
      $fatal(1, "TEST_FAIL: recoverable error was not retained");

    send_command(`PS_PL_MEM_CMD_QUIESCE, 32'd4);
    send_command(`PS_PL_MEM_CMD_FLUSH_ROM, 32'd5);
    if (mem_error != 4'h6 || accept_new_requests)
      $fatal(1, "TEST_FAIL: FLUSH incorrectly cleared the recoverable fault");
    send_command(`PS_PL_MEM_CMD_CLEAR_ERROR, 32'd6);
    if (mem_error != 4'd0 || mem_status[3])
      $fatal(1, "TEST_FAIL: CLEAR_ERROR did not clear recoverable fault");
    send_command(`PS_PL_MEM_CMD_RESUME, 32'd7);
    if (!accept_new_requests) $fatal(1, "TEST_FAIL: recovered memory did not resume");

    @(negedge clk);
    backend_fatal = 1'b1;
    @(negedge clk);
    backend_fatal = 1'b0;
    repeat (2) @(negedge clk);
    send_command(`PS_PL_MEM_CMD_CLEAR_ERROR, 32'd8);
    send_command(`PS_PL_MEM_CMD_RESUME, 32'd9);
    if (((mem_status & `PS_PL_MEM_STATUS_FATAL_FAULT) == 0) || accept_new_requests || mem_error == 4'd0)
      $fatal(1, "TEST_FAIL: fatal fault was cleared or resumed");

    test_done = 1'b1;
    $display("TEST_PASS: tb_ddram_lifecycle");
    $finish;
  end
endmodule

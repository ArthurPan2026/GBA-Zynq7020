`timescale 1ns/1ps
module tb_cdc_mailbox_atomic;
  logic test_done = 1'b0;
  localparam int WIDTH = 374;
  logic src_clk = 1'b0;
  logic dst_clk = 1'b0;
  logic src_rst_n = 1'b0;
  logic dst_rst_n = 1'b0;
  always #5 src_clk = ~src_clk;
  always #7 dst_clk = ~dst_clk;

  logic src_valid = 1'b0;
  logic [WIDTH-1:0] src_payload = '0;
  wire src_ready, src_busy, src_req_toggle, src_ack_toggle;
  wire [WIDTH-1:0] src_ack_payload;
  wire dst_valid;
  wire [WIDTH-1:0] dst_payload;
  logic dst_ready = 1'b0;

  cdc_toggle_mailbox #(.WIDTH(WIDTH)) dut (.*);

  task automatic accept_destination;
  begin
    dst_ready = 1'b1;
    @(posedge dst_clk);
    #1;
    dst_ready = 1'b0;
  end
  endtask

  localparam logic [WIDTH-1:0] CFG_A = {32'h1357_9BDF, 342'h123456789ABCDEF00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF};
  localparam logic [WIDTH-1:0] CFG_B = {32'h2468_ACE0, 342'hFEDCBA9876543210FFEEDDCCBBAA99887766554433221100FFEEDDCCBBAA99887766554433221100};

  initial begin
    #100us;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_cdc_mailbox_atomic.sv src_valid=%b src_ready=%b src_busy=%b src_req=%b src_ack=%b dst_valid=%b dst_ready=%b dst_ack=%b", src_valid, src_ready, src_busy, src_req_toggle, src_ack_toggle, dst_valid, dst_ready, dut.dst_ack_toggle);
  end

  initial begin
    repeat (3) @(negedge src_clk);
    src_rst_n = 1'b1;
    dst_rst_n = 1'b1;

    @(negedge src_clk);
    if (!src_ready) $fatal(1, "TEST_FAIL: mailbox not ready after reset");
    src_payload = CFG_A;
    src_valid = 1'b1;
    @(negedge src_clk);
    src_valid = 1'b0;
    src_payload = CFG_B; // must not alter the accepted in-flight image

    wait (dst_valid);
    if (dst_payload !== CFG_A) $fatal(1, "TEST_FAIL: torn or changed config payload");
    repeat (5) begin
      @(negedge dst_clk);
      if (!dst_valid || dst_payload !== CFG_A)
        $fatal(1, "TEST_FAIL: destination payload changed under backpressure");
    end
    accept_destination();
    wait (src_ready);
    if (src_ack_payload !== CFG_A) $fatal(1, "TEST_FAIL: ack did not identify captured payload");

    @(negedge src_clk);
    src_payload = CFG_B;
    src_valid = 1'b1;
    @(negedge src_clk);
    src_valid = 1'b0;
    wait (dst_valid);
    if (dst_payload !== CFG_B) $fatal(1, "TEST_FAIL: second mailbox image mismatch");
    accept_destination();
    wait (src_ready);

    test_done = 1'b1;
    $display("TEST_PASS: tb_cdc_mailbox_atomic");
    $finish;
  end
endmodule

`timescale 1ns/1ps
module tb_debug_snapshot_hold;
  logic test_done = 1'b0;
  localparam int WIDTH = 128;
  logic src_clk = 1'b0;
  logic dst_clk = 1'b0;
  logic src_rst_n = 1'b0;
  logic dst_rst_n = 1'b0;
  always #5 src_clk = ~src_clk;
  always #8 dst_clk = ~dst_clk;

  logic frame_event = 1'b0;
  logic error_event = 1'b0;
  logic [WIDTH-1:0] live_debug_status = '0;
  logic pending = 1'b0;
  wire src_ready, src_busy, src_req_toggle, src_ack_toggle;
  wire [WIDTH-1:0] src_ack_payload;
  wire src_valid = pending && src_ready;
  wire dst_valid;
  wire [WIDTH-1:0] dst_payload;
  logic slow_axi_read = 1'b1;
  wire dst_ready = dst_valid && !slow_axi_read;

  cdc_toggle_mailbox #(.WIDTH(WIDTH)) snapshot_mailbox (
    .src_clk(src_clk), .src_rst_n(src_rst_n),
    .src_valid(src_valid), .src_payload(live_debug_status),
    .src_ready(src_ready), .src_busy(src_busy),
    .src_req_toggle(src_req_toggle), .src_ack_toggle(src_ack_toggle),
    .src_ack_payload(src_ack_payload),
    .dst_clk(dst_clk), .dst_rst_n(dst_rst_n),
    .dst_valid(dst_valid), .dst_payload(dst_payload), .dst_ready(dst_ready)
  );

  // Mirrors the top-level event snapshot: repeated events while the current
  // image is unacknowledged coalesce to the newest complete source image.
  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin
      pending <= 1'b0;
    end else if (frame_event || error_event) begin
      pending <= 1'b1;
    end else if (src_valid) begin
      pending <= 1'b0;
    end
  end

  task automatic pulse_frame(input logic [WIDTH-1:0] image);
  begin
    @(negedge src_clk);
    live_debug_status = image;
    frame_event = 1'b1;
    @(negedge src_clk);
    frame_event = 1'b0;
  end
  endtask

  task automatic pulse_error(input logic [WIDTH-1:0] image);
  begin
    @(negedge src_clk);
    live_debug_status = image;
    error_event = 1'b1;
    @(negedge src_clk);
    error_event = 1'b0;
  end
  endtask

  initial begin
    #100us;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_debug_snapshot_hold.sv");
  end

  initial begin
    repeat (3) @(negedge src_clk);
    src_rst_n = 1'b1;
    dst_rst_n = 1'b1;

    pulse_frame(128'h0000_0001_0000_0000_1111_2222_3333_4444);
    wait (dst_valid);
    if (dst_payload !== 128'h0000_0001_0000_0000_1111_2222_3333_4444)
      $fatal(1, "TEST_FAIL: first frame snapshot tore");

    // Simulate an AXI read holding the destination payload while newer frame
    // and error events arrive. The accepted image stays stable; the pending
    // image coalesces to the latest error snapshot and follows after ACK.
    repeat (4) begin
      @(negedge dst_clk);
      if (!dst_valid || dst_payload !== 128'h0000_0001_0000_0000_1111_2222_3333_4444)
        $fatal(1, "TEST_FAIL: AXI read stall changed held snapshot");
    end
    pulse_frame(128'h0000_0002_0000_0000_AAAA_BBBB_CCCC_DDDD);
    pulse_error(128'h0000_0003_0000_0006_DEAD_BEEF_0123_4567);
    repeat (4) begin
      @(negedge dst_clk);
      if (!dst_valid || dst_payload !== 128'h0000_0001_0000_0000_1111_2222_3333_4444)
        $fatal(1, "TEST_FAIL: in-flight AXI snapshot was overwritten by an event");
    end

    slow_axi_read = 1'b0;
    @(negedge dst_clk);
    slow_axi_read = 1'b1;
    wait (src_ready);
    wait (dst_valid);
    if (dst_payload !== 128'h0000_0003_0000_0006_DEAD_BEEF_0123_4567)
      $fatal(1, "TEST_FAIL: latest repeated event was not coalesced atomically");
    slow_axi_read = 1'b0;
    @(negedge dst_clk);
    if (dst_valid) begin
      @(negedge dst_clk);
    end

    test_done = 1'b1;
    $display("TEST_PASS: tb_debug_snapshot_hold");
    $finish;
  end
endmodule

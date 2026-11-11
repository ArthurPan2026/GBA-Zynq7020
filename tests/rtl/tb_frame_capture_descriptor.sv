`timescale 1ns/1ps
`include "../../src/rtl/common/ps_pl_contract_generated.vh"
module tb_frame_capture_descriptor;
  logic test_done = 1'b0;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [15:0] pixel_addr = 16'd0;
  logic [17:0] pixel_data = 18'd0;
  logic pixel_we = 1'b0;
  wire [31:0] frame_seq;
  wire frame_buf_idx;
  wire [31:0] frame_status;
  wire [31:0] bank0_gen;
  wire [31:0] bank1_gen;
  wire [31:0] bram_dout_b;
  logic bram_en_b = 1'b0;
  logic [3:0] bram_we_b = 4'd0;
  logic [17:0] bram_addr_b = 18'd0;
  logic [31:0] bram_din_b = 32'd0;

  gba_frame_capture_bram dut (
    .wr_clk(clk), .wr_rst_n(rst_n), .pixel_addr(pixel_addr),
    .pixel_data(pixel_data), .pixel_we(pixel_we),
    .frame_seq(frame_seq), .frame_buf_idx(frame_buf_idx),
    .frame_status(frame_status), .bank0_gen(bank0_gen), .bank1_gen(bank1_gen),
    .bram_clk_b(clk), .bram_rst_b(1'b0), .bram_en_b(bram_en_b),
    .bram_we_b(bram_we_b), .bram_addr_b(bram_addr_b),
    .bram_din_b(bram_din_b), .bram_dout_b(bram_dout_b)
  );

  task automatic push_pixel(input logic [15:0] address);
  begin
    @(negedge clk);
    pixel_addr = address;
    pixel_data = {6'h2A, 6'h15, 6'h31};
    pixel_we = 1'b1;
    @(posedge clk);
    #1;
  end
  endtask

  task automatic stop_pixels;
  begin
    @(negedge clk);
    pixel_we = 1'b0;
  end
  endtask

  initial begin
    #5ms;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_frame_capture_descriptor.sv");
  end

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    if (frame_status & `PS_PL_FRAME_STATUS_VALID)
      $fatal(1, "TEST_FAIL: frame descriptor valid before a published frame");

    // Publish one complete frame in bank 0.
    for (int p = 0; p < 38400; p++) push_pixel(16'(p));
    stop_pixels();
    if (frame_seq != 32'd1 || frame_buf_idx != 1'b0 ||
        bank0_gen != 32'd1 || bank1_gen != 32'd0)
      $fatal(1, "TEST_FAIL: first complete frame descriptor/generation mismatch");
    if (!(frame_status & `PS_PL_FRAME_STATUS_VALID) ||
        (frame_status & `PS_PL_FRAME_STATUS_PUBLISHED_BANK1) ||
        (frame_status & `PS_PL_FRAME_STATUS_PARTIAL))
      $fatal(1, "TEST_FAIL: first frame status bits mismatch");

    // Bank 1 becomes writer at the next frame start. An interrupted partial
    // update stays unpublished and does not require strict full-frame capture.
    push_pixel(16'd0);
    if (!(frame_status & `PS_PL_FRAME_STATUS_BANK1_WRITING) || bank1_gen != 32'd1)
      $fatal(1, "TEST_FAIL: bank 1 writer descriptor did not advance on entry");
    for (int p = 1; p <= 200; p++) push_pixel(16'(p));
    push_pixel(16'd0);
    if (frame_seq != 32'd1 || frame_buf_idx != 1'b0 ||
        bank1_gen != 32'd2 || !(frame_status & `PS_PL_FRAME_STATUS_PARTIAL))
      $fatal(1, "TEST_FAIL: partial update changed publication or lost its diagnostic");

    // Accumulate the near-full threshold, then start another frame. Existing
    // near-full publication remains active and the next writer generation moves
    // to bank 0 at the same boundary.
    for (int p = 1; p <= 38271; p++) push_pixel(16'(p));
    push_pixel(16'd0);
    stop_pixels();
    if (frame_seq != 32'd2 || frame_buf_idx != 1'b1 || bank0_gen != 32'd2 ||
        !(frame_status & `PS_PL_FRAME_STATUS_PUBLISHED_BANK1) ||
        !(frame_status & `PS_PL_FRAME_STATUS_PARTIAL) ||
        !(frame_status & `PS_PL_FRAME_STATUS_BANK0_WRITING))
      $fatal(1, "TEST_FAIL: near-full publication or writer generation semantics changed");

    // Out-of-range writes are diagnosed without suppressing existing partial
    // capture behavior or clearing the published descriptor.
    push_pixel(16'd40000);
    stop_pixels();
    if (!(frame_status & `PS_PL_FRAME_STATUS_ERROR))
      $fatal(1, "TEST_FAIL: out-of-range pixel write was not diagnosed");

    test_done = 1'b1;
    $display("TEST_PASS: tb_frame_capture_descriptor");
    $finish;
  end
endmodule

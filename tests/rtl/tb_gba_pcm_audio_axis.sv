`timescale 1ns/1ps

module tb_gba_pcm_audio_axis;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg sample_ce = 1'b0;
  reg [15:0] sample_left = 16'd0;
  reg [15:0] sample_right = 16'd0;
  reg tready = 1'b0;
  wire [47:0] tdata;
  wire tvalid;
  wire overflow_sticky;

  gba_pcm_audio_axis #(
    .FIFO_DEPTH(4),
    .FIFO_ADDR_WIDTH(2)
  ) dut (
    .clk_100(clk),
    .rst_n(rst_n),
    .sample_ce(sample_ce),
    .sample_left(sample_left),
    .sample_right(sample_right),
    .m_axis_tdata(tdata),
    .m_axis_tvalid(tvalid),
    .m_axis_tready(tready),
    .overflow_sticky(overflow_sticky)
  );

  always #5 clk = ~clk;

  function automatic [23:0] left_align_16(input [15:0] sample);
    left_align_16 = {sample, 8'h00};
  endfunction

  task automatic send_sample(input [15:0] left, input [15:0] right);
    begin
      @(negedge clk);
      sample_left = left;
      sample_right = right;
      sample_ce = 1'b1;
      @(posedge clk);
      #1;
      sample_ce = 1'b0;
    end
  endtask

  reg [47:0] held_data;
  initial begin
    repeat (2) @(posedge clk);
    #1 rst_n = 1'b1;

    // Signed 16-bit full-scale maps to 24-bit HDMI full-scale after left alignment.
    send_sample(16'h7FFF, 16'h8000);
    send_sample(16'h0000, 16'h0000);
    if (!tvalid || tdata !== {left_align_16(16'h8000),left_align_16(16'h7FFF)})
      $fatal(1, "positive/negative full-scale 24-bit alignment or L/R packing is wrong: %h", tdata);
    held_data = tdata;
    repeat (5) begin
      @(posedge clk);
      #1;
      if (!tvalid || tdata !== held_data)
        $fatal(1, "AXIS TVALID/TDATA changed while TREADY was low");
    end

    // Fill the remaining slots. Empty-to-data and FIFO-full behavior must be exact.
    send_sample(16'h1234, 16'hABCD);
    send_sample(16'h5678, 16'hDEF0);
    if (!tvalid || overflow_sticky)
      $fatal(1, "FIFO did not fill cleanly");
    if (tdata !== {left_align_16(16'h8000),left_align_16(16'h7FFF)})
      $fatal(1, "FIFO head changed before a transfer");

    // At full, simultaneous pop+push replaces the freed slot without overflow.
    @(negedge clk);
    sample_left = 16'h5555;
    sample_right = 16'h6666;
    sample_ce = 1'b1;
    tready = 1'b1;
    @(posedge clk);
    #1;
    sample_ce = 1'b0;
    tready = 1'b0;
    if (!tvalid || tdata !== {left_align_16(16'h0000),left_align_16(16'h0000)} || overflow_sticky)
      $fatal(1, "simultaneous full FIFO pop/push failed: valid=%b data=%h ovf=%b",
             tvalid, tdata, overflow_sticky);

    // FIFO remains full. Drop the new sample, latch overflow, and preserve its head.
    held_data = tdata;
    send_sample(16'h7777, 16'h8888);
    if (!overflow_sticky || !tvalid || tdata !== held_data)
      $fatal(1, "FIFO full overflow/status or held output is wrong");
    repeat (3) begin
      @(posedge clk);
      #1;
      if (!tvalid || tdata !== held_data)
        $fatal(1, "overflow changed the held AXIS output");
    end

    // Reset clears queued samples and sticky overflow; drain one new word to empty.
    @(negedge clk);
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (tvalid || overflow_sticky)
      $fatal(1, "reset did not clear FIFO/overflow");
    rst_n = 1'b1;
    send_sample(16'h0001, 16'h0002);
    if (!tvalid || tdata !== {left_align_16(16'h0002),left_align_16(16'h0001)} || overflow_sticky)
      $fatal(1, "FIFO did not recover after reset");
    @(negedge clk);
    tready = 1'b1;
    @(posedge clk);
    #1;
    tready = 1'b0;
    if (tvalid || overflow_sticky)
      $fatal(1, "FIFO did not become empty after the final transfer");

    $display("TEST_PASS: tb_gba_pcm_audio_axis 16-to-24 left alignment, full/empty, backpressure, overflow, reset");
    $finish;
  end
endmodule

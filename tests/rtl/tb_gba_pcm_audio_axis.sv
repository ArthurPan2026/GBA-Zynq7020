`timescale 1ns/1ps

module tb_gba_pcm_audio_axis;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg sample_ce = 1'b0;
  reg [15:0] sample_left = 16'd0;
  reg [15:0] sample_right = 16'd0;
  reg tready = 1'b0;
  wire [31:0] tdata;
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

  reg [31:0] held_data;
  initial begin
    repeat (2) @(posedge clk);
    #1 rst_n = 1'b1;

    // 入队两帧；背压期间 TVALID 和头部 TDATA 必须保持稳定。
    send_sample(16'h1234, 16'hABCD);
    send_sample(16'h5678, 16'hDEF0);
    if (!tvalid || tdata !== {16'hABCD, 16'h1234})
      $fatal(1, "first PCM pair packing/order is wrong: valid=%b data=%h", tvalid, tdata);
    held_data = tdata;
    repeat (5) begin
      @(posedge clk);
      #1;
      if (!tvalid || tdata !== held_data)
        $fatal(1, "AXIS head changed while TREADY was low");
    end

    // 满 FIFO 时同拍 pop+push 应正常替换样本，不应产生 overflow。
    send_sample(16'h1111, 16'h2222);
    send_sample(16'h3333, 16'h4444);
    if (!tvalid || overflow_sticky)
      $fatal(1, "FIFO did not fill cleanly");
    @(negedge clk);
    sample_left = 16'h5555;
    sample_right = 16'h6666;
    sample_ce = 1'b1;
    tready = 1'b1;
    @(posedge clk);
    #1;
    sample_ce = 1'b0;
    tready = 1'b0;
    if (!tvalid || tdata !== {16'hDEF0, 16'h5678} || overflow_sticky)
      $fatal(1, "simultaneous full FIFO pop/push failed: valid=%b data=%h ovf=%b",
             tvalid, tdata, overflow_sticky);

    // FIFO 仍满，下一采样节拍必须记录粘滞溢出并保持当前输出不变。
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

    // 复位清空 FIFO 并清除 sticky overflow。
    @(negedge clk);
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (tvalid || overflow_sticky)
      $fatal(1, "reset did not clear FIFO/overflow");
    rst_n = 1'b1;
    send_sample(16'h0001, 16'h0002);
    if (!tvalid || tdata !== {16'h0002, 16'h0001} || overflow_sticky)
      $fatal(1, "FIFO did not recover after reset");

    $display("GBA_PCM_AXIS_PASS");
    $finish;
  end
endmodule

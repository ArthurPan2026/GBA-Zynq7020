`timescale 1ns/1ps
module audio_event_pulse_sync (
  input  logic src_clk,
  input  logic src_resetn,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_resetn,
  output logic dst_pulse
);
  logic src_toggle;
  (* ASYNC_REG = "TRUE" *) logic dst_sync_meta;
  (* ASYNC_REG = "TRUE" *) logic dst_sync;
  logic dst_sync_delayed;

  // 用翻转状态跨域传递单拍事件；音频欠载/溢出事件远慢于同步器延迟。
  always_ff @(posedge src_clk or negedge src_resetn) begin
    if (!src_resetn)
      src_toggle <= 1'b0;
    else if (src_pulse)
      src_toggle <= ~src_toggle;
  end

  // 两级同步后与上一拍比较，在目标时钟域产生一个周期脉冲。
  always_ff @(posedge dst_clk or negedge dst_resetn) begin
    if (!dst_resetn) begin
      dst_sync_meta <= 1'b0;
      dst_sync <= 1'b0;
      dst_sync_delayed <= 1'b0;
      dst_pulse <= 1'b0;
    end else begin
      dst_sync_meta <= src_toggle;
      dst_sync <= dst_sync_meta;
      dst_sync_delayed <= dst_sync;
      dst_pulse <= dst_sync ^ dst_sync_delayed;
    end
  end
endmodule

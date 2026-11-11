//------------------------------------------------------------------------------
// @file frame_tick_480p.sv
// @module-contract
// 职责: 视频帧节拍检测；480p 视频节拍检测器，从像素坐标/同步信号生成帧边界脉冲。
// 上游: 480p 坐标、de/hs/vs 信号。
// 下游: 顶层帧计数、IRQ 或状态采样逻辑。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
// 关键协议: 像素/行/帧节拍、VRAM/OAM/调色板访问和缓冲区切换必须保持确定延迟关系。
// 设计注意点: 用视频时序边界压缩出一帧一次的同步事件，作为跨模块的帧级时间基准；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
module frame_tick_480p (
  input  logic      clk,
  input  logic      rst_n,

  output logic      frame_pulse,
  output logic [1:0] frame_idx
);

  localparam int H_TOTAL  = 800;
  localparam int H_ACTIVE = 640;
  localparam int V_TOTAL  = 525;
  localparam int V_ACTIVE = 480;

  logic [1:0] pix_div;
  logic       pix_ce;

  logic [9:0] h_cnt;
  logic [9:0] v_cnt;

  // @process-purpose: 在 clk 时钟域处理视频帧节拍检测的请求、事件或计数条件，并把结果锁存为下游可采样的控制/状态信号。
  // @process-mechanism: !rst_n 时先回到初始/安全状态；pix_ce、h_cnt == H_TOTAL - 1 作为有效时选择对应处理分支；默认分支清除单拍脉冲并保持寄存器，触发条件满足时在时钟沿锁存 pix_div、pix_ce、h_cnt、v_cnt、frame_pulse、frame_idx，形成下游可采样的同步状态、单拍脉冲或握手响应。
  // @process-result: 结果是 pix_div、pix_ce、h_cnt、v_cnt、frame_pulse、frame_idx 等信号只在明确时钟沿变化，下游可以把它们视为同步有效的控制或数据边界。
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pix_div     <= 2'd0;
      pix_ce      <= 1'b0;
      h_cnt       <= 10'd0;
      v_cnt       <= 10'd0;
      frame_pulse <= 1'b0;
      frame_idx   <= 2'd0;
    end else begin
      frame_pulse <= 1'b0;

      // Generate a 25 MHz timing tick from the 100 MHz fabric clock.
      pix_div <= pix_div + 2'd1;
      pix_ce  <= (pix_div == 2'd3);

      if (pix_ce) begin
        if (h_cnt == H_TOTAL - 1) begin
          h_cnt <= 10'd0;
          if (v_cnt == V_TOTAL - 1) begin
            v_cnt       <= 10'd0;
            frame_pulse <= 1'b1;
            frame_idx   <= frame_idx + 2'd1;
          end else begin
            v_cnt <= v_cnt + 10'd1;
          end
        end else begin
          h_cnt <= h_cnt + 10'd1;
        end
      end
    end
  end

endmodule

`timescale 1ns/1ps
// 把HDMI前导、保护带和数据岛符号插入TMDS 视频编码输出。
module hdmi_tmds_mode_mux #(
  parameter integer ENCODER_LATENCY = 3
) (
  input  logic        pixel_clk,
  input  logic        aresetn,
  input  logic [2:0]  symbol_mode,
  input  logic        hsync,
  input  logic        vsync,
  input  logic [8:0]  packet_data,
  input  logic [9:0]  video_lane0,
  input  logic [9:0]  video_lane1,
  input  logic [9:0]  video_lane2,
  output logic [9:0]  tmds_lane0,
  output logic [9:0]  tmds_lane1,
  output logic [9:0]  tmds_lane2
);
  localparam logic [2:0] MODE_CONTROL         = 3'd0;
  localparam logic [2:0] MODE_VIDEO           = 3'd1;
  localparam logic [2:0] MODE_VIDEO_PREAMBLE  = 3'd2;
  localparam logic [2:0] MODE_DATA_PREAMBLE   = 3'd3;
  localparam logic [2:0] MODE_VIDEO_GUARD     = 3'd4;
  localparam logic [2:0] MODE_DATA_GUARD      = 3'd5;
  localparam logic [2:0] MODE_DATA_PAYLOAD    = 3'd6;
  localparam logic [9:0] CONTROL_00 = 10'b1101010100;
  localparam logic [9:0] CONTROL_01 = 10'b0010101011;
  localparam logic [9:0] VIDEO_GUARD_BLUE_RED = 10'b1011001100;
  localparam logic [9:0] VIDEO_GUARD_GREEN = 10'b0100110011;
  localparam logic [9:0] DATA_GUARD_GREEN_RED = 10'b0100110011;

  logic [2:0] mode_pipe [0:ENCODER_LATENCY-1];
  logic [8:0] packet_pipe [0:ENCODER_LATENCY-1];
  logic [ENCODER_LATENCY-1:0] hsync_pipe;
  logic [ENCODER_LATENCY-1:0] vsync_pipe;
  logic [9:0] channel0_terc_symbol;
  logic [9:0] channel1_terc_symbol;
  logic [9:0] channel2_terc_symbol;
  logic [3:0] channel0_terc_nibble;
  integer stage;

  always_ff @(posedge pixel_clk or negedge aresetn) begin
    if (!aresetn) begin
      for (stage = 0; stage < ENCODER_LATENCY; stage = stage + 1) begin
        mode_pipe[stage] <= MODE_CONTROL;
        packet_pipe[stage] <= '0;
      end
      hsync_pipe <= '0;
      vsync_pipe <= '0;
    end else begin
      mode_pipe[0] <= symbol_mode;
      packet_pipe[0] <= packet_data;
      hsync_pipe[0] <= hsync;
      vsync_pipe[0] <= vsync;
      for (stage = 1; stage < ENCODER_LATENCY; stage = stage + 1) begin
        mode_pipe[stage] <= mode_pipe[stage-1];
        packet_pipe[stage] <= packet_pipe[stage-1];
        hsync_pipe[stage] <= hsync_pipe[stage-1];
        vsync_pipe[stage] <= vsync_pipe[stage-1];
      end
    end
  end

  // HDMI §5.2.3.1/§5.2.3.3：蓝通道D0=HS、D1=VS、D2=header位、D3保留。
  // 数据岛保护带将D3:D2置为11；负载时D2传header位，D3保留。
  always_comb begin
    if (mode_pipe[ENCODER_LATENCY-1] == MODE_DATA_GUARD)
      channel0_terc_nibble = {2'b11, vsync_pipe[ENCODER_LATENCY-1],
                              hsync_pipe[ENCODER_LATENCY-1]};
    else
      channel0_terc_nibble = {1'b0, packet_pipe[ENCODER_LATENCY-1][8],
                              vsync_pipe[ENCODER_LATENCY-1],
                              hsync_pipe[ENCODER_LATENCY-1]};
  end
  hdmi_terc4_encoder u_channel0_terc (
    .nibble(channel0_terc_nibble), .symbol(channel0_terc_symbol)
  );
  hdmi_terc4_encoder u_channel1_terc (
    .nibble(packet_pipe[ENCODER_LATENCY-1][3:0]), .symbol(channel1_terc_symbol)
  );
  hdmi_terc4_encoder u_channel2_terc (
    .nibble(packet_pipe[ENCODER_LATENCY-1][7:4]), .symbol(channel2_terc_symbol)
  );

  always_comb begin
    tmds_lane0 = video_lane0;
    tmds_lane1 = video_lane1;
    tmds_lane2 = video_lane2;
    case (mode_pipe[ENCODER_LATENCY-1])
      MODE_VIDEO: begin
        tmds_lane0 = video_lane0;
        tmds_lane1 = video_lane1;
        tmds_lane2 = video_lane2;
      end
      MODE_CONTROL: begin
        tmds_lane0 = video_lane0;
        tmds_lane1 = video_lane1;
        tmds_lane2 = video_lane2;
      end
      MODE_VIDEO_PREAMBLE: begin
        tmds_lane0 = video_lane0;
        tmds_lane1 = CONTROL_01;
        tmds_lane2 = CONTROL_00;
      end
      MODE_DATA_PREAMBLE: begin
        tmds_lane0 = video_lane0;
        tmds_lane1 = CONTROL_01;
        tmds_lane2 = CONTROL_01;
      end
      MODE_VIDEO_GUARD: begin
        tmds_lane0 = VIDEO_GUARD_BLUE_RED;
        tmds_lane1 = VIDEO_GUARD_GREEN;
        tmds_lane2 = VIDEO_GUARD_BLUE_RED;
      end
      MODE_DATA_GUARD: begin
        tmds_lane0 = channel0_terc_symbol;
        tmds_lane1 = DATA_GUARD_GREEN_RED;
        tmds_lane2 = DATA_GUARD_GREEN_RED;
      end
      MODE_DATA_PAYLOAD: begin
        tmds_lane0 = channel0_terc_symbol;
        tmds_lane1 = channel1_terc_symbol;
        tmds_lane2 = channel2_terc_symbol;
      end
      default: begin
        tmds_lane0 = video_lane0;
        tmds_lane1 = video_lane1;
        tmds_lane2 = video_lane2;
      end
    endcase
  end

  initial begin
    if (ENCODER_LATENCY < 1)
      $error("TMDS流水延迟必须至少为一拍");
  end
endmodule

`timescale 1ns/1ps
// 7系列HDMI发射低层：SystemVerilog TMDS 编码/串行化，并由本模块生成音频包。
module embedded_video_ip_7series_tx #(
  parameter bit ENABLE_HDMI_AUDIO = 1'b1,
  parameter integer PIXEL_CLOCK_HZ = 25_178_571,
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48_000,
  parameter integer USE_RUNTIME_VIDEO_PROFILE = 0,
  parameter integer VGA_PROFILE_CLOCK_HZ = 25_178_571,
  parameter integer HD_PROFILE_CLOCK_HZ = 74_218_750,
  parameter integer H_ACTIVE_SIZE = 640,
  parameter integer HBLANK_PIXELS = 160,
  parameter integer H_TOTAL = H_ACTIVE_SIZE + HBLANK_PIXELS,
  parameter integer H_SYNC_START = 656,
  parameter bit HSYNC_ACTIVE_LEVEL = 1'b1,
  parameter integer ACR_N =
      (AUDIO_SAMPLE_RATE_HZ == 96_000) ? 12_288 :
      (AUDIO_SAMPLE_RATE_HZ == 192_000) ? 24_576 : 6_144,
  parameter integer OUTPUT_COLOR_MODE = 0, // 0=RGB, 1=YCbCr 4:4:4
  parameter integer COLORIMETRY = 0,       // YCbCr: 0=BT.601, 1=BT.709
  parameter integer YCC_RANGE = 0,         // YCbCr: 0=limited, 1=full
  parameter integer OUTPUT_COLOR_DEPTH = 8 // Current TMDS clock profile supports 8 bpc only
) (
  input  logic        pixel_clk,
  input  logic        serial_clk,
  input  logic        audio_pcm_clk,
  input  logic        aresetn,
  input  logic        hdmi_mode_request,
  input  logic [23:0] video_rgb,
  input  logic        video_de,
  input  logic        hsync,
  input  logic        vsync,
  input  logic [1:0]  mode_timing_profile,
  input  logic [47:0] audio_pcm_tdata,
  input  logic        audio_pcm_tvalid,
  output logic        audio_pcm_tready,
  input  logic        hdmi_audio_enable,
  input  logic        audio_mute,
  input  logic [16:0] audio_gain_q15,
  output logic        tmds_tx_clk_p,
  output logic        tmds_tx_clk_n,
  output logic [2:0]  tmds_tx_data_p,
  output logic [2:0]  tmds_tx_data_n,
  output logic        audio_underflow_event,
  output logic        audio_overflow_event
);
  localparam integer VIDEO_LOOKAHEAD_CYCLES = 10;
  localparam integer VIDEO_PIPE_STAGES = VIDEO_LOOKAHEAD_CYCLES + 1;
  localparam logic [9:0] TMDS_CLOCK_SYMBOL = 10'b1111100000;

  logic pixel_aresetn, audio_pcm_aresetn;
  logic [2:0] tmds_release_pipe;
  logic tmds_serializer_aresetn;
  logic [23:0] rgb_pipe [0:VIDEO_LOOKAHEAD_CYCLES];
  logic de_pipe [0:VIDEO_LOOKAHEAD_CYCLES];
  logic hsync_pipe [0:VIDEO_LOOKAHEAD_CYCLES];
  logic vsync_pipe [0:VIDEO_LOOKAHEAD_CYCLES];
  logic [2:0] symbol_mode;
  logic hdmi_mode_active;
  logic packet_start;
  logic line_prepare, packet_cancel;
  logic packet_valid, packet_ready, packet_loaded, packet_active, packet_done;
  logic packet_loaded_avi;
  logic packet_cancel_link;
  logic packet_cancel_sched;
  logic [23:0] packet_header;
  logic [55:0] packet_sub0, packet_sub1, packet_sub2, packet_sub3;
  logic [23:0] assembler_packet_header;
  logic [55:0] assembler_packet_sub0, assembler_packet_sub1;
  logic [55:0] assembler_packet_sub2, assembler_packet_sub3;
  logic [23:0] color_avi_header;
  logic [55:0] color_avi_subpacket [0:3];
  logic [31:0] active_pixel_clock_hz;
  (* ASYNC_REG = "TRUE" *) logic [1:0] mode_profile_meta, mode_profile_sync;
  logic [31:0] active_h_total, active_h_active_size, active_h_sync_start;
  logic active_hsync_active_level;
  logic [7:0] active_video_vic;
  logic active_profile_valid;
  logic [8:0] packet_data;
  logic [9:0] video_lane0, video_lane1, video_lane2;
  logic [9:0] tmds_lane0, tmds_lane1, tmds_lane2;
  logic [23:0] ycbcr_pixel_rbg;
  logic [23:0] encoder_pixel_rbg;
  logic underflow_pixel, overflow_audio;
  integer pipe_index;

  embedded_video_ip_reset_sync u_pixel_reset_sync (
    .clk(pixel_clk), .async_aresetn(aresetn), .sync_aresetn(pixel_aresetn)
  );
  embedded_video_ip_reset_sync u_audio_reset_sync (
    .clk(audio_pcm_clk), .async_aresetn(aresetn), .sync_aresetn(audio_pcm_aresetn)
  );

  // TMDS 编码器保留两拍像素延迟；再延迟释放串行器复位以屏蔽流水填充期间的未知值。
  always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
    if (!pixel_aresetn)
      tmds_release_pipe <= 3'b000;
    else
      tmds_release_pipe <= {tmds_release_pipe[1:0],1'b1};
  end
  assign tmds_serializer_aresetn = pixel_aresetn && tmds_release_pipe[2];

  always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
    if (!pixel_aresetn) begin
      mode_profile_meta <= 2'd0;
      mode_profile_sync <= 2'd0;
    end else begin
      mode_profile_meta <= mode_timing_profile;
      mode_profile_sync <= mode_profile_meta;
    end
  end

  // Runtime profile selection is driven from the mode controller's active
  // profile. A single profile ID updates VIC, sample/ACR clocks and line geometry.
  always_comb begin
    active_pixel_clock_hz = 32'(PIXEL_CLOCK_HZ);
    active_h_total = 32'(H_TOTAL);
    active_h_active_size = 32'(H_ACTIVE_SIZE);
    active_h_sync_start = 32'(H_SYNC_START);
    active_hsync_active_level = HSYNC_ACTIVE_LEVEL;
    active_video_vic = 8'd1;
    active_profile_valid = 1'b1;
    if (USE_RUNTIME_VIDEO_PROFILE != 0) begin
      case (mode_profile_sync)
        2'd0: begin
          active_pixel_clock_hz = 32'(VGA_PROFILE_CLOCK_HZ);
          active_h_total = 32'd800;
          active_h_active_size = 32'd640;
          active_h_sync_start = 32'd656;
          active_hsync_active_level = 1'b0;
          active_video_vic = 8'd1;
        end
        2'd1: begin
          active_pixel_clock_hz = 32'(HD_PROFILE_CLOCK_HZ);
          active_h_total = 32'd1650;
          active_h_active_size = 32'd1280;
          active_h_sync_start = 32'd1390;
          active_hsync_active_level = 1'b1;
          active_video_vic = 8'd4;
        end
        2'd2: begin
          active_pixel_clock_hz = 32'(HD_PROFILE_CLOCK_HZ);
          active_h_total = 32'd2200;
          active_h_active_size = 32'd1920;
          active_h_sync_start = 32'd2008;
          active_hsync_active_level = 1'b1;
          active_video_vic = 8'd34;
        end
        default: begin
          active_pixel_clock_hz = 32'd0;
          active_h_total = 32'd0;
          active_h_active_size = 32'd0;
          active_h_sync_start = 32'd0;
          active_hsync_active_level = 1'b0;
          active_video_vic = 8'd0;
          active_profile_valid = 1'b0;
        end
      endcase
    end
  end

  hdmi_rgb_to_ycbcr444 #(
    .COLORIMETRY(COLORIMETRY), .YCC_RANGE(YCC_RANGE)
  ) u_rgb_to_ycbcr444 (
    .rgb_rbg(rgb_pipe[VIDEO_LOOKAHEAD_CYCLES]), .ycbcr_rbg(ycbcr_pixel_rbg)
  );

  generate
    if ((OUTPUT_COLOR_DEPTH == 8) && (OUTPUT_COLOR_MODE == 0)) begin : g_rgb_8bit
      assign encoder_pixel_rbg = rgb_pipe[VIDEO_LOOKAHEAD_CYCLES];
    end else if ((OUTPUT_COLOR_DEPTH == 8) && (OUTPUT_COLOR_MODE == 1)) begin : g_ycbcr444_8bit
      assign encoder_pixel_rbg = ycbcr_pixel_rbg;
    end else begin : g_unsupported_color_profile
      // Fail closed in hardware and stop simulation: 10-bit Deep Color needs
      // HDMI pixel-group packing and a 1.25x TMDS clock profile that this TX
      // does not implement. Never silently zero-extend 8-bit samples.
      assign encoder_pixel_rbg = 24'h000000;
      initial $fatal(1, "Only 8-bit RGB or YCbCr 4:4:4 profiles are implemented");
    end
  endgenerate

  hdmi_avi_infoframe #(
    .COLOR_MODE(OUTPUT_COLOR_MODE), .COLORIMETRY(COLORIMETRY), .YCC_RANGE(YCC_RANGE)
  ) u_color_avi_infoframe (
    .video_vic(active_video_vic), .header(color_avi_header), .subpacket(color_avi_subpacket)
  );

  // Replace only the AVI payload from the packet source. Audio packets and
  // their scheduling remain unchanged; the InfoFrame now matches the selected
  // pixel encoding and quantization range.
  always_comb begin
    assembler_packet_header = packet_header;
    assembler_packet_sub0 = packet_sub0;
    assembler_packet_sub1 = packet_sub1;
    assembler_packet_sub2 = packet_sub2;
    assembler_packet_sub3 = packet_sub3;
    if (packet_header[7:0] == 8'h82) begin
      assembler_packet_header = color_avi_header;
      assembler_packet_sub0 = color_avi_subpacket[0];
      assembler_packet_sub1 = color_avi_subpacket[1];
      assembler_packet_sub2 = color_avi_subpacket[2];
      assembler_packet_sub3 = color_avi_subpacket[3];
    end
  end

  // 延迟视频输入10个像素时钟，为首个有效像素前插入8拍前导和2拍保护带。
  always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
    if (!pixel_aresetn) begin
      for (pipe_index = 0; pipe_index < VIDEO_PIPE_STAGES; pipe_index = pipe_index + 1) begin
        rgb_pipe[pipe_index] <= 24'd0;
        de_pipe[pipe_index] <= 1'b0;
        hsync_pipe[pipe_index] <= 1'b0;
        vsync_pipe[pipe_index] <= 1'b0;
      end
    end else begin
      rgb_pipe[0] <= video_rgb;
      de_pipe[0] <= video_de;
      hsync_pipe[0] <= hsync;
      vsync_pipe[0] <= vsync;
      for (pipe_index = 1; pipe_index < VIDEO_PIPE_STAGES; pipe_index = pipe_index + 1) begin
        rgb_pipe[pipe_index] <= rgb_pipe[pipe_index-1];
        de_pipe[pipe_index] <= de_pipe[pipe_index-1];
        hsync_pipe[pipe_index] <= hsync_pipe[pipe_index-1];
        vsync_pipe[pipe_index] <= vsync_pipe[pipe_index-1];
      end
    end
  end

  hdmi_pcm_packet_source #(
    .ENABLE_HDMI_AUDIO(ENABLE_HDMI_AUDIO),
    .AUDIO_SAMPLE_RATE_HZ(AUDIO_SAMPLE_RATE_HZ),
    .ACR_N(ACR_N),
    .USE_VIDEO_PROFILE_CLOCKS(USE_RUNTIME_VIDEO_PROFILE != 0),
    .VGA_PROFILE_CLOCK_HZ(VGA_PROFILE_CLOCK_HZ),
    .HD_PROFILE_CLOCK_HZ(HD_PROFILE_CLOCK_HZ)
  ) u_audio_packet_source (
    .pixel_clk(pixel_clk), .audio_pcm_clk(audio_pcm_clk),
    .pixel_clock_hz(active_pixel_clock_hz), .h_total(active_h_total), .video_vic(active_video_vic),
    .pixel_aresetn(pixel_aresetn), .audio_pcm_aresetn(audio_pcm_aresetn),
    .hdmi_mode_active(hdmi_mode_active), .vsync(vsync_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .line_prepare(line_prepare), .packet_active(packet_active),
    .audio_pcm_tdata(audio_pcm_tdata), .audio_pcm_tvalid(audio_pcm_tvalid),
    .audio_pcm_tready(audio_pcm_tready),
    .hdmi_audio_enable(hdmi_audio_enable),
    .audio_mute(audio_mute), .audio_gain_q15(audio_gain_q15),
    .packet_ready(packet_ready), .packet_valid(packet_valid), .packet_cancel(packet_cancel),
    .packet_cancel_link(packet_cancel_link), .packet_header(packet_header), .packet_sub0(packet_sub0), .packet_sub1(packet_sub1),
    .packet_sub2(packet_sub2), .packet_sub3(packet_sub3),
    .audio_underflow_event(underflow_pixel), .audio_overflow_event(overflow_audio)
  );

  hdmi_packet_assembler #(.STATIC_AVI_ONLY(!ENABLE_HDMI_AUDIO)) u_packet_assembler (
    .pixel_clk(pixel_clk), .resetn(pixel_aresetn),
    .packet_valid(packet_valid), .packet_ready(packet_ready), .packet_cancel(packet_cancel),
    .packet_cancel_link(packet_cancel_link), .packet_start(packet_start), .packet_loaded(packet_loaded),
    .packet_loaded_avi(packet_loaded_avi),
    .packet_header(assembler_packet_header), .packet_sub0(assembler_packet_sub0),
    .packet_sub1(assembler_packet_sub1), .packet_sub2(assembler_packet_sub2),
    .packet_sub3(assembler_packet_sub3),
    .packet_active(packet_active), .packet_data(packet_data), .packet_done(packet_done)
  );

  hdmi_line_slot_scheduler #(
    .VIDEO_LOOKAHEAD_CYCLES(VIDEO_LOOKAHEAD_CYCLES)
  ) u_line_slot_scheduler (
    .pixel_clk(pixel_clk), .aresetn(pixel_aresetn),
    .h_total(active_h_total), .h_active_size(active_h_active_size),
    .h_sync_start(active_h_sync_start), .hsync_active_level(active_hsync_active_level),
    .hdmi_mode_request(hdmi_mode_request), .video_profile_valid(active_profile_valid),
    .hdmi_mode_active(hdmi_mode_active),
    .packet_active(packet_active),
    .video_de_lookahead(video_de), .video_de_delayed(de_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .hsync_delayed(hsync_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .packet_loaded(packet_loaded), .packet_offer(packet_valid), .packet_cancel(packet_cancel_sched),
    .line_prepare(line_prepare), .symbol_mode(symbol_mode), .packet_start(packet_start)
  );

  // Audio disable may cancel a not-yet-started audio packet. Preserve an AVI
  // InfoFrame so its data island retains legal HDMI framing.
  assign packet_cancel_sched = packet_cancel_link |
                               (packet_cancel &&
                                !(packet_loaded_avi ||
                                  (packet_valid && packet_header[7:0] == 8'h82)));

  // RBG 顺序映射到 TMDS 通道0/1/2；YCbCr 模式下对应 Cb/Y/Cr。
  hdmi_tmds_video_encoder u_systemverilog_video_encoder (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .aresetn(pixel_aresetn),
    .video_rgb_rbg(encoder_pixel_rbg),
    .video_de(de_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .hsync(hsync_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .vsync(vsync_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .lane0_blue_symbol(video_lane0), .lane1_green_symbol(video_lane1),
    .lane2_red_symbol(video_lane2)
  );

  hdmi_tmds_mode_mux #(.ENCODER_LATENCY(3)) u_hdmi_mode_mux (
    .pixel_clk(pixel_clk), .aresetn(pixel_aresetn), .symbol_mode(symbol_mode),
    .hsync(hsync_pipe[VIDEO_LOOKAHEAD_CYCLES]),
    .vsync(vsync_pipe[VIDEO_LOOKAHEAD_CYCLES]), .packet_data(packet_data),
    .video_lane0(video_lane0), .video_lane1(video_lane1), .video_lane2(video_lane2),
    .tmds_lane0(tmds_lane0), .tmds_lane1(tmds_lane1), .tmds_lane2(tmds_lane2)
  );

  // 时钟通道发送固定TMDS时钟图样，三个数据通道使用7-series OSERDESE2/OBUFDS。
  hdmi_7series_output_serdes #(.PARALLEL_WIDTH(10)) u_clock_serdes (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .serial_p(tmds_tx_clk_p),
    .serial_n(tmds_tx_clk_n), .parallel_data(TMDS_CLOCK_SYMBOL), .areset(~tmds_serializer_aresetn)
  );
  hdmi_7series_output_serdes #(.PARALLEL_WIDTH(10)) u_data0_serdes (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .serial_p(tmds_tx_data_p[0]),
    .serial_n(tmds_tx_data_n[0]), .parallel_data(tmds_lane0), .areset(~tmds_serializer_aresetn)
  );
  hdmi_7series_output_serdes #(.PARALLEL_WIDTH(10)) u_data1_serdes (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .serial_p(tmds_tx_data_p[1]),
    .serial_n(tmds_tx_data_n[1]), .parallel_data(tmds_lane1), .areset(~tmds_serializer_aresetn)
  );
  hdmi_7series_output_serdes #(.PARALLEL_WIDTH(10)) u_data2_serdes (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .serial_p(tmds_tx_data_p[2]),
    .serial_n(tmds_tx_data_n[2]), .parallel_data(tmds_lane2), .areset(~tmds_serializer_aresetn)
  );

  assign audio_underflow_event = underflow_pixel;
  assign audio_overflow_event = overflow_audio;
endmodule

`timescale 1ns/1ps
// EmbeddedVideoIP 单一 PL+PS composite 顶层。
module embedded_video_ip_top #(
  parameter integer MAX_INPUT_WIDTH = 1280,
  parameter integer MAX_INPUT_HEIGHT = 720,
  parameter integer BRAM_ADDR_WIDTH = 18,
  parameter integer AXI_ADDR_WIDTH = 6,
  parameter integer ENABLE_BRAM_SOURCE = 1,
  parameter integer ENABLE_HLS_SOURCE = 1,
  parameter integer ENABLE_VDMA_SOURCE = 1,
  parameter integer SOURCE_SELECT_MODE = 0,
  parameter integer FIXED_SOURCE = 2,
  parameter integer FORMAT_SELECT_MODE = 0,
  parameter integer FIXED_FORMAT = 2,
  parameter integer MAX_SCALER_INPUT_WIDTH = MAX_INPUT_WIDTH,
  parameter integer MAX_SCALER_INPUT_HEIGHT = MAX_INPUT_HEIGHT,
  parameter integer ENABLE_SCALER = 1,
  parameter integer LINE_BUFFER_IMPLEMENTATION = 1,
  parameter integer ENABLE_HDMI_AUDIO = 0,
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48000,
  parameter integer OUTPUT_COLOR_MODE = 0,
  parameter integer COLORIMETRY = 0,
  parameter integer YCC_RANGE = 0,
  parameter integer OUTPUT_COLOR_DEPTH = 8
) (
  input wire aclk,
  input wire aresetn,
  input wire hdmi_ref_clk,

  input wire [31:0] s_axis_hls_tdata,
  input wire s_axis_hls_tvalid,
  output wire s_axis_hls_tready,
  input wire s_axis_hls_tuser,
  input wire s_axis_hls_tlast,

  input wire [31:0] s_axis_vdma_tdata,
  input wire s_axis_vdma_tvalid,
  output wire s_axis_vdma_tready,
  input wire s_axis_vdma_tuser,
  input wire s_axis_vdma_tlast,

  output wire bram_en,
  output wire [BRAM_ADDR_WIDTH-1:0] bram_addr,
  input wire [31:0] bram_dout,
  output wire bram_busy,
  output wire bram_frame_done,

  input wire audio_pcm_clk,
  input wire [47:0] s_axis_audio_pcm_tdata,
  input wire s_axis_audio_pcm_tvalid,
  output wire s_axis_audio_pcm_tready,

  input wire [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input wire s_axi_awvalid,
  output wire s_axi_awready,
  input wire [31:0] s_axi_wdata,
  input wire [3:0] s_axi_wstrb,
  input wire s_axi_wvalid,
  output wire s_axi_wready,
  output wire [1:0] s_axi_bresp,
  output wire s_axi_bvalid,
  input wire s_axi_bready,
  input wire [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input wire s_axi_arvalid,
  output wire s_axi_arready,
  output wire [31:0] s_axi_rdata,
  output wire [1:0] s_axi_rresp,
  output wire s_axi_rvalid,
  input wire s_axi_rready,

  output wire tmds_tx_clk_p,
  output wire tmds_tx_clk_n,
  output wire [2:0] tmds_tx_data_p,
  output wire [2:0] tmds_tx_data_n
);
  localparam integer EVIP_PIXEL_CLOCK_HZ = 25_178_571;

  wire [23:0] m_axis_video_tdata;
  wire m_axis_video_tvalid;
  wire m_axis_video_tready;
  wire m_axis_video_tuser;
  wire m_axis_video_tlast;
  wire hdmi_audio_enable;
  wire hdmi_link_mode;
  wire audio_mute;
  wire [16:0] audio_gain_q15;
  wire [16:0] audio_gain_pixel;
  wire audio_underflow_event_pixel;
  wire audio_overflow_event_audio;
  wire audio_pcm_resetn_sync;
  wire audio_underflow_aclk;
  wire audio_overflow_aclk;
  wire tx_audio_pcm_tready;
  wire [23:0] video_rgb;
  wire video_de;
  wire video_hsync;
  wire video_vsync;
  wire video_vsync_raw;
  wire pixel_clk;
  (* CLOCK_BUFFER_TYPE="NONE", KEEP="TRUE" *) wire serial_clk;
  (* CLOCK_BUFFER_TYPE="NONE", KEEP="TRUE" *) wire serdes_pixel_clk;
  wire serial_monitor_clk;
  wire [1:0] phy_errors_async;
  (* ASYNC_REG="TRUE" *) reg [1:0] phy_errors_meta, phy_errors_sync;
  always @(posedge aclk) begin
    if (!aresetn) begin phy_errors_meta<=0; phy_errors_sync<=0; end
    else begin phy_errors_meta<=phy_errors_async; phy_errors_sync<=phy_errors_meta; end
  end
  wire [1:0] mode_clock_mode;
  wire pixel_aresetn;
  wire hdmi_mmcm_locked;
  wire pixel_reset_ext_asserted;
  wire [5:0] hdmi_diag_status;
  wire [1:0] video_mode_request;
  wire video_mode_commit;
  wire video_mode_error_clear;
  wire [1:0] video_mode_active;
  wire video_mode_busy;
  wire video_mode_error;
  wire video_mode_pixel_reset_hold;
  wire video_mode_config_ready;
  wire [2:0] video_mode_debug_state;
  wire [2:0] video_mode_failure_stage;
  wire video_mode_vsync_level;
  wire [1:0] mode_timing_profile;
  (* ASYNC_REG = "TRUE" *) reg [1:0] mode_profile_meta_pixel;
  (* ASYNC_REG = "TRUE" *) reg [1:0] mode_profile_sync_pixel;
  wire mode_clock_profile_sel;
  wire [1:0] mode_locked_profiles;
  wire force_dvi_safe;
  wire audio_allow;
  reg tx_hdmi_mode_request;
  reg tx_hdmi_audio_enable;
  reg tx_audio_mute;

  hdmi_runtime_status u_hdmi_runtime_status (
    .aclk(aclk), .aresetn(aresetn),
    .pixel_clk(pixel_clk), .mmcm_locked_async(hdmi_mmcm_locked),
    .pixel_resetn_async(pixel_aresetn),
    .pixel_reset_ext_asserted_async(pixel_reset_ext_asserted),
    .serial_clk(serial_monitor_clk),
    .video_vsync_async(video_vsync_raw), .status(hdmi_diag_status)
  );

  video_pipeline_v1_0 #(
    .OUTPUT_WIDTH(1920), .OUTPUT_HEIGHT(1080),
    .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
    .MAX_INPUT_HEIGHT(MAX_INPUT_HEIGHT),
    .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .ENABLE_BRAM_SOURCE(ENABLE_BRAM_SOURCE),
    .ENABLE_HLS_SOURCE(ENABLE_HLS_SOURCE),
    .ENABLE_VDMA_SOURCE(ENABLE_VDMA_SOURCE),
    .SOURCE_SELECT_MODE(SOURCE_SELECT_MODE),
    .FIXED_SOURCE(FIXED_SOURCE),
    .FORMAT_SELECT_MODE(FORMAT_SELECT_MODE),
    .FIXED_FORMAT(FIXED_FORMAT),
    .MAX_SCALER_INPUT_WIDTH(MAX_SCALER_INPUT_WIDTH),
    .MAX_SCALER_INPUT_HEIGHT(MAX_SCALER_INPUT_HEIGHT),
    .ENABLE_SCALER(ENABLE_SCALER),
    .LINE_BUFFER_IMPLEMENTATION(LINE_BUFFER_IMPLEMENTATION),
    .ENABLE_HDMI_AUDIO(ENABLE_HDMI_AUDIO), .ENABLE_OUTPUT_MODE(1), .ENABLE_1080P60(1)
  ) video_core (
    .aclk(aclk), .aresetn(aresetn),
    .bram_en(bram_en), .bram_addr(bram_addr), .bram_dout(bram_dout),
    .bram_busy(bram_busy), .bram_frame_done(bram_frame_done),
    .s_axis_hls_tdata(s_axis_hls_tdata), .s_axis_hls_tvalid(s_axis_hls_tvalid),
    .s_axis_hls_tready(s_axis_hls_tready), .s_axis_hls_tuser(s_axis_hls_tuser),
    .s_axis_hls_tlast(s_axis_hls_tlast),
    .s_axis_vdma_tdata(s_axis_vdma_tdata), .s_axis_vdma_tvalid(s_axis_vdma_tvalid),
    .s_axis_vdma_tready(s_axis_vdma_tready), .s_axis_vdma_tuser(s_axis_vdma_tuser),
    .s_axis_vdma_tlast(s_axis_vdma_tlast),
    .m_axis_video_tdata(m_axis_video_tdata), .m_axis_video_tvalid(m_axis_video_tvalid),
    .m_axis_video_tready(m_axis_video_tready), .m_axis_video_tuser(m_axis_video_tuser),
    .m_axis_video_tlast(m_axis_video_tlast),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .hdmi_audio_enable(hdmi_audio_enable), .hdmi_link_mode(hdmi_link_mode),
    .audio_mute(audio_mute), .audio_gain_q15(audio_gain_q15),
    .audio_underflow(audio_underflow_aclk),
    .audio_overflow(audio_overflow_aclk), .hdmi_diag_status(hdmi_diag_status),
    .phy_errors(phy_errors_sync),
    .video_mode_request(video_mode_request), .video_mode_commit(video_mode_commit),
    .video_mode_error_clear(video_mode_error_clear), .video_mode_active(video_mode_active),
    .video_mode_busy(video_mode_busy), .video_mode_pixel_reset_hold(video_mode_pixel_reset_hold),
    .video_mode_error(video_mode_error), .video_mode_config_ready(video_mode_config_ready),
    .video_mode_debug_state(video_mode_debug_state),
    .video_mode_failure_stage(video_mode_failure_stage),
    .video_mode_vsync_level(video_mode_vsync_level)
  );

  hdmi_mode_transition_ctrl #(.ENABLE_1080P60(1'b1)) u_hdmi_mode_transition_ctrl (
    .clk(aclk), .aresetn(aresetn),
    .mode_commit(video_mode_commit), .mode_req(video_mode_request),
    .mode_error_clear(video_mode_error_clear), .mode_config_ready(video_mode_config_ready),
    .pixel_vsync_async(video_vsync_raw), .clock_locked(mode_locked_profiles),
    .clock_mode(mode_clock_mode), .clock_profile_sel(mode_clock_profile_sel), .timing_profile(mode_timing_profile),
    .mode_busy(video_mode_busy), .mode_active(video_mode_active), .mode_error(video_mode_error),
    .pixel_reset_hold(video_mode_pixel_reset_hold), .force_dvi_safe(force_dvi_safe),
    .audio_allow(audio_allow), .debug_state(video_mode_debug_state),
    .failure_stage(video_mode_failure_stage),
    .debug_vsync_level(video_mode_vsync_level)
  );

  // Register complete aclk-domain requests before their destination synchronizers.
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      tx_hdmi_mode_request <= 1'b0;
      tx_hdmi_audio_enable <= 1'b0;
      tx_audio_mute <= 1'b1;
    end else begin
      tx_hdmi_mode_request <= hdmi_link_mode && !force_dvi_safe;
      tx_hdmi_audio_enable <= hdmi_audio_enable && audio_allow && !force_dvi_safe;
      tx_audio_mute <= audio_mute || !audio_allow || force_dvi_safe;
    end
  end

  // Synchronize the stable mode bundle once, then distribute it in pixel_clk.
  always @(posedge pixel_clk or negedge pixel_aresetn) begin
    if (!pixel_aresetn) begin
      mode_profile_meta_pixel <= 2'd0;
      mode_profile_sync_pixel <= 2'd0;
    end else begin
      mode_profile_meta_pixel <= mode_timing_profile;
      mode_profile_sync_pixel <= mode_profile_meta_pixel;
    end
  end

  embedded_video_ip_video_out_wrapper video_output (
    .clock_mode(mode_clock_mode), .pixel_reset_hold(video_mode_pixel_reset_hold),
    .timing_profile(mode_profile_sync_pixel), .locked_profiles(mode_locked_profiles),
    .aclk(aclk), .aresetn(aresetn), .hdmi_ref_clk(hdmi_ref_clk),
    .s_axis_video_tdata(m_axis_video_tdata), .s_axis_video_tvalid(m_axis_video_tvalid),
    .s_axis_video_tready(m_axis_video_tready), .s_axis_video_tuser(m_axis_video_tuser),
    .s_axis_video_tlast(m_axis_video_tlast),
    .video_rgb(video_rgb), .video_de(video_de), .video_hsync(video_hsync),
    .video_vsync(video_vsync), .video_vsync_raw(video_vsync_raw),
    .pixel_clk(pixel_clk), .serial_clk(serial_clk),
    .serdes_pixel_clk(serdes_pixel_clk), .serial_monitor_clk(serial_monitor_clk),
    .pixel_aresetn(pixel_aresetn), .hdmi_mmcm_locked(hdmi_mmcm_locked),
    .pixel_reset_ext_asserted(pixel_reset_ext_asserted)
  );

  // The gain control bus is held stable until the pixel domain acknowledges
  // each update, so the active gain changes atomically across the clock boundary.
  hdmi_gain_bus_cdc u_audio_gain_cdc (
    .src_clk(aclk), .src_resetn(aresetn), .src_gain_q15(audio_gain_q15),
    .dst_clk(pixel_clk), .dst_resetn(pixel_aresetn), .dst_gain_q15(audio_gain_pixel)
  );

  embedded_video_ip_7series_tx #(
    .ENABLE_HDMI_AUDIO(ENABLE_HDMI_AUDIO),
    .AUDIO_SAMPLE_RATE_HZ(AUDIO_SAMPLE_RATE_HZ),
    .PIXEL_CLOCK_HZ(EVIP_PIXEL_CLOCK_HZ),
    .USE_RUNTIME_VIDEO_PROFILE(1),
    .OUTPUT_COLOR_MODE(OUTPUT_COLOR_MODE),
    .COLORIMETRY(COLORIMETRY),
    .YCC_RANGE(YCC_RANGE),
    .OUTPUT_COLOR_DEPTH(OUTPUT_COLOR_DEPTH)
  ) hdmi_tx (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .serdes_pixel_clk(serdes_pixel_clk), .aresetn(pixel_aresetn),
    .phy_errors(phy_errors_async),
    .hdmi_mode_request(tx_hdmi_mode_request),
    .video_rgb(video_rgb), .video_de(video_de), .hsync(video_hsync),
    .vsync(video_vsync), .mode_timing_profile(mode_profile_sync_pixel),
    .audio_pcm_clk(audio_pcm_clk), .audio_pcm_tdata(s_axis_audio_pcm_tdata),
    .audio_pcm_tvalid(s_axis_audio_pcm_tvalid), .audio_pcm_tready(tx_audio_pcm_tready),
    .hdmi_audio_enable(tx_hdmi_audio_enable), .audio_mute(tx_audio_mute),
    .audio_gain_q15(audio_gain_pixel),
    .tmds_tx_clk_p(tmds_tx_clk_p), .tmds_tx_clk_n(tmds_tx_clk_n),
    .tmds_tx_data_p(tmds_tx_data_p), .tmds_tx_data_n(tmds_tx_data_n),
    .audio_underflow_event(audio_underflow_event_pixel),
    .audio_overflow_event(audio_overflow_event_audio)
  );

  generate
    if (ENABLE_HDMI_AUDIO != 0) begin : gen_hdmi_audio_events
      assign s_axis_audio_pcm_tready = tx_audio_pcm_tready;
      embedded_video_ip_reset_sync audio_event_reset_sync (
        .clk(audio_pcm_clk), .async_aresetn(aresetn),
        .sync_aresetn(audio_pcm_resetn_sync)
      );
      audio_event_pulse_sync underflow_event_sync (
        .src_clk(pixel_clk), .src_resetn(pixel_aresetn),
        .src_pulse(audio_underflow_event_pixel), .dst_clk(aclk),
        .dst_resetn(aresetn), .dst_pulse(audio_underflow_aclk)
      );
      audio_event_pulse_sync overflow_event_sync (
        .src_clk(audio_pcm_clk), .src_resetn(audio_pcm_resetn_sync),
        .src_pulse(audio_overflow_event_audio), .dst_clk(aclk),
        .dst_resetn(aresetn), .dst_pulse(audio_overflow_aclk)
      );
    end else begin : gen_hdmi_audio_disabled
      // Audio 关闭时仍接收并丢弃样本，避免阻塞外部 PCM 源。
      assign s_axis_audio_pcm_tready = 1'b1;
      assign audio_underflow_aclk = 1'b0;
      assign audio_overflow_aclk = 1'b0;
    end
  endgenerate


endmodule

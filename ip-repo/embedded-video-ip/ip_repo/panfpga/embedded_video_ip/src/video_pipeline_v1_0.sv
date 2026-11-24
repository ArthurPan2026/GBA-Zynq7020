`timescale 1ns/1ps
module video_pipeline_v1_0 #(
  parameter int unsigned MAX_INPUT_WIDTH = 640,
  parameter int unsigned MAX_INPUT_HEIGHT = 480,
  parameter int unsigned OUTPUT_WIDTH = 640,
  parameter int unsigned OUTPUT_HEIGHT = 480,
  parameter int unsigned BRAM_ADDR_WIDTH = 18,
  parameter int unsigned AXI_ADDR_WIDTH = 6,
  // Source enables preserve the full generic interface by default.
  parameter int unsigned ENABLE_BRAM_SOURCE = 1,
  parameter int unsigned ENABLE_HLS_SOURCE = 1,
  parameter int unsigned ENABLE_VDMA_SOURCE = 1,
  // 0 selects the AXI-Lite source/format fields; 1 fixes them at elaboration.
  parameter int unsigned SOURCE_SELECT_MODE = 0,
  parameter int unsigned FIXED_SOURCE = 2,
  parameter int unsigned FORMAT_SELECT_MODE = 0,
  parameter int unsigned FIXED_FORMAT = 2,
  // The external input contract may be wider than the scaler line store.
  parameter int unsigned MAX_SCALER_INPUT_WIDTH = MAX_INPUT_WIDTH,
  parameter int unsigned MAX_SCALER_INPUT_HEIGHT = MAX_INPUT_HEIGHT,
  // 0 creates a frame-aware AXI-Stream straight-through path with no scaler.
  parameter int unsigned ENABLE_SCALER = 1,
  // 0 uses LUTRAM for the scaler line store; 1 uses synchronous BRAM.
  parameter int unsigned LINE_BUFFER_IMPLEMENTATION = 0,
  parameter int unsigned ENABLE_HDMI_AUDIO = 0,
  parameter bit ENABLE_1080P60 = 1'b0,
  parameter int unsigned ENABLE_OUTPUT_MODE = 0
) (
  input logic aclk, input logic aresetn,

  // BRAM source: 32-bit words with two RGB565 pixels, low pixel first.
  output logic bram_en,
  output logic [BRAM_ADDR_WIDTH-1:0] bram_addr,
  input logic [31:0] bram_dout,
  output logic bram_busy,
  output logic bram_frame_done,

  // HLS and VDMA sources use one 32-bit beat per pixel, TUSER=SOF, TLAST=EOL.
  input logic [31:0] s_axis_hls_tdata,
  input logic s_axis_hls_tvalid,
  output logic s_axis_hls_tready,
  input logic s_axis_hls_tuser,
  input logic s_axis_hls_tlast,

  input logic [31:0] s_axis_vdma_tdata,
  input logic s_axis_vdma_tvalid,
  output logic s_axis_vdma_tready,
  input logic s_axis_vdma_tuser,
  input logic s_axis_vdma_tlast,

  // Processed AXI4-Stream Video output uses RBG component packing (R[23:16], B[15:8], G[7:0]).
  output logic [23:0] m_axis_video_tdata,
  output logic m_axis_video_tvalid,
  input logic m_axis_video_tready,
  output logic m_axis_video_tuser,
  output logic m_axis_video_tlast,

  // AXI4-Lite control and status.
  input logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input logic s_axi_awvalid,
  output logic s_axi_awready,
  input logic [31:0] s_axi_wdata,
  input logic [3:0] s_axi_wstrb,
  input logic s_axi_wvalid,
  output logic s_axi_wready,
  output logic [1:0] s_axi_bresp,
  output logic s_axi_bvalid,
  input logic s_axi_bready,
  input logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input logic s_axi_arvalid,
  output logic s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0] s_axi_rresp,
  output logic s_axi_rvalid,
  input logic s_axi_rready,

  // HDMI audio control/status is routed to the composite transmitter.
  output logic hdmi_audio_enable,
  output logic hdmi_link_mode,
  output logic audio_mute,
  output logic [16:0] audio_gain_q15,
  input logic audio_underflow,
  input logic audio_overflow,
  input logic [5:0] hdmi_diag_status,
  input logic [1:0] phy_errors,
  output logic [1:0] video_mode_request,
  output logic video_mode_commit,
  output logic video_mode_error_clear,
  input logic [1:0] video_mode_active,
  input logic video_mode_busy,
  input logic video_mode_pixel_reset_hold,
  input logic video_mode_error,
  output logic video_mode_config_ready,
  input logic [2:0] video_mode_debug_state,
  input logic [2:0] video_mode_failure_stage,
  input logic video_mode_vsync_level
);
  logic cfg_enable, cfg_scale, cfg_stretch;
  logic [1:0] cfg_source, cfg_format;
  logic [15:0] cfg_width, cfg_height;
  logic [31:0] cfg_stride, cfg_bram_base;
  logic cfg_commit, bram_start, clear_errors;
  logic abort_stream, resume_stream, stream_hold, stream_resetn, stream_accept;
  logic stream_config_settle;
  logic scaler_sready;
  logic [31:0] cfg_frame_count, cfg_error_flags;
  logic [10:0] req_active_width, req_active_height;
  logic [10:0] req_x_offset, req_y_offset;
  logic [10:0] req_x_origin, req_y_origin;
  logic [10:0] req_x_step, req_x_rem, req_y_step, req_y_rem;
  logic [10:0] measured_active_width, measured_active_height;
  logic [10:0] req_output_width, req_output_height;
  logic [10:0] active_output_width, active_output_height;
  logic cfg_busy;

  logic active_enable, active_scale, active_stretch;
  logic [1:0] active_source, active_format;
  logic [15:0] active_width, active_height;
  logic [10:0] active_active_width, active_active_height;
  logic [10:0] active_x_offset, active_y_offset;
  logic [10:0] active_x_origin, active_y_origin;
  logic [10:0] active_x_step, active_x_rem, active_y_step, active_y_rem;
  logic [31:0] active_stride, active_bram_base;
  logic cfg_pending, mode_cfg_pending;

  logic [31:0] bram_axis_tdata;
  logic bram_axis_tvalid, bram_axis_tready, bram_axis_tuser, bram_axis_tlast;
  logic [31:0] mux_tdata;
  logic mux_tvalid, mux_tready, mux_tuser, mux_tlast;
  logic [23:0] rgb_tdata;
  logic [23:0] scaler_tdata_rgb;
  logic rgb_tvalid, rgb_source_ready, rgb_scaler_ready, rgb_tuser, rgb_tlast;
  logic [31:0] bram_error_flags;
  logic [31:0] scaler_error_flags;
  logic bram_start_pending, bram_start_reader;
  logic source_request_enabled;
  logic invalid_profile_request, invalid_profile_error;
  logic [1:0] selected_source, selected_format;
  logic pass_busy;
  logic [31:0] pass_frame_count, pass_error_flags;
  logic [10:0] pass_active_width, pass_active_height;
  logic [15:0] pass_line_index, pass_pixel_count;
  localparam logic [1:0] DEFAULT_ENABLED_SOURCE =
      (ENABLE_BRAM_SOURCE != 0) ? 2'd0 :
      (ENABLE_HLS_SOURCE != 0) ? 2'd1 : 2'd2;

  localparam logic [3:0] NATIVE_MODE_MASK = {
    (ENABLE_1080P60 && ENABLE_OUTPUT_MODE != 0 && MAX_INPUT_WIDTH >= 1920 && MAX_INPUT_HEIGHT >= 1080),
    (ENABLE_OUTPUT_MODE != 0 && MAX_INPUT_WIDTH >= output_width_for_mode(2'd2) && MAX_INPUT_HEIGHT >= output_height_for_mode(2'd2)),
    (ENABLE_OUTPUT_MODE != 0 && MAX_INPUT_WIDTH >= output_width_for_mode(2'd1) && MAX_INPUT_HEIGHT >= output_height_for_mode(2'd1)),
    (MAX_INPUT_WIDTH >= output_width_for_mode(2'd0) && MAX_INPUT_HEIGHT >= output_height_for_mode(2'd0))};
  axi_lite_video_regs #(.ADDR_WIDTH(AXI_ADDR_WIDTH),
                         .ENABLE_HDMI_AUDIO(ENABLE_HDMI_AUDIO),
                         .NATIVE_MODE_MASK(NATIVE_MODE_MASK),
                         .ENABLE_OUTPUT_MODE(ENABLE_OUTPUT_MODE)) u_regs (
    .aclk(aclk), .aresetn(aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .cfg_enable(cfg_enable), .cfg_source(cfg_source), .cfg_scale_enable(cfg_scale),
    .cfg_stretch(cfg_stretch), .cfg_format(cfg_format), .cfg_width(cfg_width),
    .cfg_height(cfg_height), .cfg_stride_bytes(cfg_stride), .cfg_bram_base_word(cfg_bram_base),
    .cfg_active_width(req_active_width), .cfg_active_height(req_active_height),
    .cfg_x_offset(req_x_offset), .cfg_y_offset(req_y_offset),
    .cfg_source_x_origin(req_x_origin), .cfg_source_y_origin(req_y_origin),
    .cfg_x_step(req_x_step), .cfg_x_rem(req_x_rem), .cfg_y_step(req_y_step), .cfg_y_rem(req_y_rem),
    .cfg_commit(cfg_commit), .bram_start(bram_start), .clear_errors(clear_errors),
    .abort_stream(abort_stream), .resume_stream(resume_stream),
    .cfg_pending(cfg_pending), .stream_hold(stream_hold), .active_enable(active_enable),
    .busy(cfg_busy), .bram_busy(bram_busy), .active_source(active_source),
    .active_width(measured_active_width), .active_height(measured_active_height),
    .frame_count(cfg_frame_count), .error_flags(cfg_error_flags),
    .hdmi_audio_enable(hdmi_audio_enable), .hdmi_link_mode(hdmi_link_mode),
    .audio_mute(audio_mute), .audio_gain_q15(audio_gain_q15),
    .audio_underflow(audio_underflow),
    .audio_overflow(audio_overflow), .hdmi_diag_status(hdmi_diag_status),
    .phy_errors(phy_errors),
    .video_mode_request(video_mode_request), .video_mode_commit(video_mode_commit),
    .video_mode_error_clear(video_mode_error_clear),
    .video_mode_active(video_mode_active), .video_mode_busy(video_mode_busy),
    .video_mode_error(video_mode_error),
    .video_mode_debug_state(video_mode_debug_state),
    .video_mode_failure_stage(video_mode_failure_stage),
    .video_mode_config_ready(video_mode_config_ready),
    .video_mode_vsync_level(video_mode_vsync_level)
  );

  function automatic logic [10:0] output_width_for_mode(input logic [1:0] mode_value);
    case (mode_value)
      2'd0: output_width_for_mode = 11'd640;
      2'd1: output_width_for_mode = 11'd1280;
      2'd2, 2'd3: output_width_for_mode = 11'd1920;
      default: output_width_for_mode = 11'd0;
    endcase
  endfunction

  function automatic logic [10:0] output_height_for_mode(input logic [1:0] mode_value);
    case (mode_value)
      2'd0: output_height_for_mode = 11'd480;
      2'd1: output_height_for_mode = 11'd720;
      2'd2, 2'd3: output_height_for_mode = 11'd1080;
      default: output_height_for_mode = 11'd0;
    endcase
  endfunction

  always_comb begin
    req_output_width = (ENABLE_OUTPUT_MODE != 0) ? output_width_for_mode(video_mode_request) : 11'(OUTPUT_WIDTH);
    req_output_height = (ENABLE_OUTPUT_MODE != 0) ? output_height_for_mode(video_mode_request) : 11'(OUTPUT_HEIGHT);
    case (cfg_source)
      2'd0: source_request_enabled = (ENABLE_BRAM_SOURCE != 0);
      2'd1: source_request_enabled = (ENABLE_HLS_SOURCE != 0);
      2'd2: source_request_enabled = (ENABLE_VDMA_SOURCE != 0);
      default: source_request_enabled = 1'b0;
    endcase

    invalid_profile_request = !source_request_enabled ||
        (cfg_width == 0) || (cfg_height == 0) ||
        (cfg_width > MAX_INPUT_WIDTH) || (cfg_height > MAX_INPUT_HEIGHT) ||
        (req_output_width == 0) || (req_output_height == 0) ||
        (req_output_width > OUTPUT_WIDTH) || (req_output_height > OUTPUT_HEIGHT) ||
        (req_active_width == 0) || (req_active_height == 0) ||
        (req_active_width > req_output_width) || (req_active_height > req_output_height) ||
        ((req_x_offset + req_active_width) > req_output_width) ||
        ((req_y_offset + req_active_height) > req_output_height) ||
        (req_x_origin >= cfg_width) || (req_y_origin >= cfg_height) ||
        (req_x_rem >= req_active_width) || (req_y_rem >= req_active_height) ||
        (req_x_step > MAX_INPUT_WIDTH) || (req_y_step > MAX_INPUT_HEIGHT) ||
        ((ENABLE_OUTPUT_MODE != 0) && (req_output_width == 0 || req_output_height == 0)) ||
        ((ENABLE_OUTPUT_MODE != 0) && (video_mode_request == 2'd3) && !ENABLE_1080P60) ||
        ((SOURCE_SELECT_MODE != 0) && (cfg_source != FIXED_SOURCE)) ||
        ((FORMAT_SELECT_MODE != 0) && (cfg_source != 2'd0) &&
         (cfg_format != FIXED_FORMAT));
    if (ENABLE_SCALER == 0) begin
      // A scaler-free profile only accepts an exact output-sized 1:1 frame.
      invalid_profile_request = invalid_profile_request ||
          (cfg_width != req_output_width) || (cfg_height != req_output_height) ||
          (req_active_width != req_output_width) || (req_active_height != req_output_height) ||
          (req_x_offset != 0) || (req_y_offset != 0) ||
          (req_x_origin != 0) || (req_y_origin != 0) ||
          (req_x_step != 1) || (req_x_rem != 0) ||
          (req_y_step != 1) || (req_y_rem != 0);
    end
  end

  // A mode transition may pause AXI video mid-frame while the pixel clock is
  // switched. Reset the scaler state during that held interval so config_ready
  // is not blocked waiting for an input frame that stream_accept has stopped.
  assign stream_resetn = aresetn && !abort_stream &&
                         !((ENABLE_OUTPUT_MODE != 0) && video_mode_pixel_reset_hold);
  assign stream_accept = !stream_hold && !abort_stream && !stream_config_settle &&
                         !((ENABLE_OUTPUT_MODE != 0) && video_mode_pixel_reset_hold);
  // The mode FSM consumes this stable acknowledgement on a following cycle.
  always_ff @(posedge aclk) begin
    if (!aresetn) video_mode_config_ready <= (ENABLE_OUTPUT_MODE == 0);
    else video_mode_config_ready <= (ENABLE_OUTPUT_MODE == 0) ||
        (!cfg_commit && !cfg_pending && !mode_cfg_pending && !video_mode_commit &&
         !cfg_busy && !invalid_profile_request &&
         (active_output_width == req_output_width) && (active_output_height == req_output_height));
  end
  assign selected_source = (SOURCE_SELECT_MODE != 0) ? FIXED_SOURCE : active_source;
  // BRAM RGB565 is expanded by its reader; other sources use the configured format.
  assign selected_format = (selected_source == 2'd0) ? 2'd2 :
                           ((FORMAT_SELECT_MODE != 0) ? FIXED_FORMAT : active_format);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      active_enable <= 1'b0;
      active_source <= (SOURCE_SELECT_MODE != 0) ? FIXED_SOURCE : DEFAULT_ENABLED_SOURCE;
      active_scale <= 1'b0;
      active_stretch <= 1'b0;
      active_format <= (FORMAT_SELECT_MODE != 0) ? FIXED_FORMAT : 2'd1;
      active_width <= 16'd320;
      active_height <= 16'd240;
      active_stride <= 32'd640;
      active_bram_base <= 32'd0;
      active_active_width <= 11'd320; active_active_height <= 11'd240;
      active_x_offset <= 11'd160; active_y_offset <= 11'd120;
      active_output_width <= 11'd640; active_output_height <= 11'd480;
      active_x_origin <= '0; active_y_origin <= '0;
      active_x_step <= 10'd1; active_x_rem <= '0;
      active_y_step <= 10'd1; active_y_rem <= '0;
      cfg_pending <= 1'b0;
      mode_cfg_pending <= 1'b0;
      stream_hold <= 1'b0;
      stream_config_settle <= 1'b0;
      invalid_profile_error <= 1'b0;
    end else begin
      stream_config_settle <= cfg_commit || cfg_pending || mode_cfg_pending || video_mode_commit;
      if (abort_stream)
        stream_hold <= 1'b1;
      else if (resume_stream)
        stream_hold <= 1'b0;
      if (clear_errors)
        invalid_profile_error <= 1'b0;
      if (cfg_commit) begin
        cfg_pending <= 1'b1;
        if ((ENABLE_OUTPUT_MODE != 0) && video_mode_commit)
          mode_cfg_pending <= 1'b1;
      end
      if ((cfg_commit || cfg_pending) && !cfg_busy &&
          (((ENABLE_OUTPUT_MODE == 0) || (!mode_cfg_pending && !video_mode_commit)) ||
           video_mode_pixel_reset_hold || invalid_profile_request)) begin
        if (invalid_profile_request) begin
          // Reject unsupported mode/geometry changes and stop output until
          // software submits a valid configuration. ERROR_FLAGS[4] is sticky.
          active_enable <= 1'b0;
          invalid_profile_error <= 1'b1;
          cfg_pending <= 1'b0;
          mode_cfg_pending <= 1'b0;
        end else begin
          active_enable <= cfg_enable;
          active_source <= (SOURCE_SELECT_MODE != 0) ? FIXED_SOURCE : cfg_source;
          active_scale <= cfg_scale;
          active_stretch <= cfg_stretch;
          active_format <= (FORMAT_SELECT_MODE != 0) ? FIXED_FORMAT : cfg_format;
          active_width <= cfg_width;
          active_height <= cfg_height;
          active_stride <= cfg_stride;
          active_bram_base <= cfg_bram_base;
          active_active_width <= req_active_width; active_active_height <= req_active_height;
          active_x_offset <= req_x_offset; active_y_offset <= req_y_offset;
          active_output_width <= req_output_width; active_output_height <= req_output_height;
          active_x_origin <= req_x_origin; active_y_origin <= req_y_origin;
          active_x_step <= req_x_step; active_x_rem <= req_x_rem;
          active_y_step <= req_y_step; active_y_rem <= req_y_rem;
          cfg_pending <= 1'b0;
          mode_cfg_pending <= 1'b0;
          stream_hold <= 1'b0;
        end
      end
    end
  end

  generate
    if (ENABLE_BRAM_SOURCE != 0) begin : gen_bram_source
      video_bram_rgb565_reader #(
        .MAX_WIDTH(MAX_INPUT_WIDTH),
        .MAX_HEIGHT(MAX_INPUT_HEIGHT),
        .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH)
      ) u_bram_reader (
        .aclk(aclk), .aresetn(stream_resetn), .frame_start(bram_start_reader),
        .frame_base_word(active_bram_base), .frame_width(active_width),
        .frame_height(active_height), .frame_stride_bytes(active_stride),
        .bram_en(bram_en), .bram_addr(bram_addr), .bram_dout(bram_dout),
        .m_axis_tdata(bram_axis_tdata), .m_axis_tvalid(bram_axis_tvalid),
        .m_axis_tready(bram_axis_tready), .m_axis_tuser(bram_axis_tuser),
        .m_axis_tlast(bram_axis_tlast), .busy(bram_busy), .frame_done(bram_frame_done),
        .clear_errors(clear_errors), .error_flags(bram_error_flags)
      );

      always_ff @(posedge aclk) begin
        if (!stream_resetn) begin
          bram_start_pending <= 1'b0;
          bram_start_reader <= 1'b0;
        end else begin
          bram_start_reader <= 1'b0;
          if (bram_start)
            bram_start_pending <= 1'b1;
          if (bram_start_pending && !cfg_pending && !cfg_commit && !cfg_busy) begin
            bram_start_reader <= 1'b1;
            bram_start_pending <= 1'b0;
          end
        end
      end
    end else begin : gen_no_bram_source
      assign bram_en = 1'b0;
      assign bram_addr = '0;
      assign bram_busy = 1'b0;
      assign bram_frame_done = 1'b0;
      assign bram_axis_tdata = 32'd0;
      assign bram_axis_tvalid = 1'b0;
      assign bram_axis_tuser = 1'b0;
      assign bram_axis_tlast = 1'b0;
      assign bram_error_flags = 32'd0;
      assign bram_start_reader = 1'b0;
    end
  endgenerate

  generate
    if ((SOURCE_SELECT_MODE == 0) && (ENABLE_BRAM_SOURCE != 0) &&
        (ENABLE_HLS_SOURCE != 0) && (ENABLE_VDMA_SOURCE != 0)) begin : gen_full_runtime_mux
      axis_video_mux3 u_source_mux (
        .select(active_source),
        .s0_tdata(bram_axis_tdata), .s0_tvalid(bram_axis_tvalid), .s0_tready(bram_axis_tready),
        .s0_tuser(bram_axis_tuser), .s0_tlast(bram_axis_tlast),
        .s1_tdata(s_axis_hls_tdata), .s1_tvalid(s_axis_hls_tvalid), .s1_tready(s_axis_hls_tready),
        .s1_tuser(s_axis_hls_tuser), .s1_tlast(s_axis_hls_tlast),
        .s2_tdata(s_axis_vdma_tdata), .s2_tvalid(s_axis_vdma_tvalid), .s2_tready(s_axis_vdma_tready),
        .s2_tuser(s_axis_vdma_tuser), .s2_tlast(s_axis_vdma_tlast),
        .m_tdata(mux_tdata), .m_tvalid(mux_tvalid), .m_tready(mux_tready),
        .m_tuser(mux_tuser), .m_tlast(mux_tlast)
      );
    end else if ((SOURCE_SELECT_MODE != 0) && (FIXED_SOURCE == 0) &&
                 (ENABLE_BRAM_SOURCE != 0)) begin : gen_fixed_bram_source
      assign mux_tdata = bram_axis_tdata;
      assign mux_tvalid = bram_axis_tvalid;
      assign mux_tuser = bram_axis_tuser;
      assign mux_tlast = bram_axis_tlast;
      assign bram_axis_tready = mux_tready;
      assign s_axis_hls_tready = 1'b0;
      assign s_axis_vdma_tready = 1'b0;
    end else if ((SOURCE_SELECT_MODE != 0) && (FIXED_SOURCE == 1) &&
                 (ENABLE_HLS_SOURCE != 0)) begin : gen_fixed_hls_source
      assign mux_tdata = s_axis_hls_tdata;
      assign mux_tvalid = s_axis_hls_tvalid;
      assign mux_tuser = s_axis_hls_tuser;
      assign mux_tlast = s_axis_hls_tlast;
      assign bram_axis_tready = 1'b0;
      assign s_axis_hls_tready = mux_tready;
      assign s_axis_vdma_tready = 1'b0;
    end else if ((SOURCE_SELECT_MODE != 0) && (FIXED_SOURCE == 2) &&
                 (ENABLE_VDMA_SOURCE != 0)) begin : gen_fixed_vdma_source
      assign mux_tdata = s_axis_vdma_tdata;
      assign mux_tvalid = s_axis_vdma_tvalid;
      assign mux_tuser = s_axis_vdma_tuser;
      assign mux_tlast = s_axis_vdma_tlast;
      assign bram_axis_tready = 1'b0;
      assign s_axis_hls_tready = 1'b0;
      assign s_axis_vdma_tready = mux_tready;
    end else begin : gen_pruned_runtime_mux
      always_comb begin
        mux_tdata = 32'd0;
        mux_tvalid = 1'b0;
        mux_tuser = 1'b0;
        mux_tlast = 1'b0;
        bram_axis_tready = 1'b0;
        s_axis_hls_tready = 1'b0;
        s_axis_vdma_tready = 1'b0;
        case (active_source)
          2'd0: if (ENABLE_BRAM_SOURCE != 0) begin
            mux_tdata = bram_axis_tdata;
            mux_tvalid = bram_axis_tvalid;
            mux_tuser = bram_axis_tuser;
            mux_tlast = bram_axis_tlast;
            bram_axis_tready = mux_tready;
          end
          2'd1: if (ENABLE_HLS_SOURCE != 0) begin
            mux_tdata = s_axis_hls_tdata;
            mux_tvalid = s_axis_hls_tvalid;
            mux_tuser = s_axis_hls_tuser;
            mux_tlast = s_axis_hls_tlast;
            s_axis_hls_tready = mux_tready;
          end
          2'd2: if (ENABLE_VDMA_SOURCE != 0) begin
            mux_tdata = s_axis_vdma_tdata;
            mux_tvalid = s_axis_vdma_tvalid;
            mux_tuser = s_axis_vdma_tuser;
            mux_tlast = s_axis_vdma_tlast;
            s_axis_vdma_tready = mux_tready;
          end
          default: begin end
        endcase
      end
    end
  endgenerate

  axis_rgb888 u_format (
    .s_axis_tdata(mux_tdata), .s_axis_tvalid(mux_tvalid && active_enable && stream_accept),
    .s_axis_tready(rgb_source_ready), .s_axis_tuser(mux_tuser), .s_axis_tlast(mux_tlast),
    // The BRAM reader already yields internal RGB; HLS/VDMA use the
    // configured source format (RGB AXI video input is RBG packed).
    .format(selected_format),
    .m_axis_tdata(rgb_tdata), .m_axis_tvalid(rgb_tvalid), .m_axis_tready(rgb_scaler_ready),
    .m_axis_tuser(rgb_tuser), .m_axis_tlast(rgb_tlast)
  );
  assign mux_tready = active_enable && rgb_source_ready && stream_accept;

  // Keep RGB internally, then emit the AMD AXI4-Stream Video RGB packing:
  // R in [23:16], B in [15:8], G in [7:0]. The TMDS serializer consumes RBG.
  assign m_axis_video_tdata = {scaler_tdata_rgb[23:16],
                               scaler_tdata_rgb[7:0],
                               scaler_tdata_rgb[15:8]};

  generate
    if (ENABLE_SCALER != 0) begin : gen_scaler
      axis_video_nn_scaler #(
        .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
        .MAX_INPUT_HEIGHT(MAX_INPUT_HEIGHT),
        .MAX_BUFFER_WIDTH(MAX_SCALER_INPUT_WIDTH),
        .MAX_BUFFER_HEIGHT(MAX_SCALER_INPUT_HEIGHT),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .OUTPUT_HEIGHT(OUTPUT_HEIGHT),
        .LINE_BUFFER_IMPLEMENTATION(LINE_BUFFER_IMPLEMENTATION)
      ) u_scaler (
        .aclk(aclk), .aresetn(stream_resetn),
        .cfg_width(active_width), .cfg_height(active_height),
        .cfg_output_width(active_output_width), .cfg_output_height(active_output_height),
        .cfg_active_width(active_active_width), .cfg_active_height(active_active_height),
        .cfg_x_offset(active_x_offset), .cfg_y_offset(active_y_offset),
        .cfg_source_x_origin(active_x_origin), .cfg_source_y_origin(active_y_origin),
        .cfg_x_step(active_x_step), .cfg_x_rem(active_x_rem),
        .cfg_y_step(active_y_step), .cfg_y_rem(active_y_rem), .clear_errors(clear_errors),
        .s_axis_tdata(rgb_tdata), .s_axis_tvalid(rgb_tvalid && stream_accept),
        .s_axis_tready(scaler_sready), .s_axis_tuser(rgb_tuser), .s_axis_tlast(rgb_tlast),
        .m_axis_tdata(scaler_tdata_rgb), .m_axis_tvalid(m_axis_video_tvalid),
        .m_axis_tready(m_axis_video_tready), .m_axis_tuser(m_axis_video_tuser),
        .m_axis_tlast(m_axis_video_tlast), .busy(cfg_busy), .frame_count(cfg_frame_count),
        .error_flags(scaler_error_flags), .active_width(measured_active_width),
        .active_height(measured_active_height)
      );
      assign rgb_scaler_ready = scaler_sready && stream_accept;
    end else begin : gen_stream_passthrough
      logic pass_waiting_for_sof;
      assign scaler_tdata_rgb = rgb_tdata;
      // A restarted stream can resume in the middle of a frame. Drain and
      // discard those beats until SOF, then expose only complete frames.
      assign rgb_scaler_ready = active_enable && stream_accept &&
          ((pass_waiting_for_sof && !rgb_tuser) ? 1'b1 : m_axis_video_tready);
      assign m_axis_video_tvalid = rgb_tvalid && active_enable && stream_accept &&
          (!pass_waiting_for_sof || rgb_tuser);
      assign m_axis_video_tuser = rgb_tuser;
      assign m_axis_video_tlast = rgb_tlast;
      assign cfg_busy = pass_busy;
      assign cfg_frame_count = pass_frame_count;
      assign scaler_error_flags = pass_error_flags;
      assign measured_active_width = pass_active_width;
      assign measured_active_height = pass_active_height;

      // Lightweight frame monitor preserves the status/commit contract while
      // the pixel path is a direct AXI-Stream pass-through.
      always_ff @(posedge aclk) begin
        if (!stream_resetn) begin
          pass_busy <= 1'b0;
          pass_waiting_for_sof <= 1'b1;
          pass_frame_count <= 32'd0;
          pass_error_flags <= 32'd0;
          pass_active_width <= 11'd0;
          pass_active_height <= 11'd0;
          pass_line_index <= 16'd0;
          pass_pixel_count <= 16'd0;
        end else begin
          if (clear_errors)
            pass_error_flags <= 32'd0;
          if (rgb_tvalid && rgb_scaler_ready) begin
            if (pass_waiting_for_sof && !rgb_tuser) begin
              pass_pixel_count <= 16'd0;
              pass_line_index <= 16'd0;
            end else if (rgb_tuser) begin
              pass_waiting_for_sof <= 1'b0;
              if (pass_busy)
                pass_error_flags[2] <= 1'b1;
              pass_busy <= 1'b1;
              pass_active_width <= active_active_width;
              pass_active_height <= active_active_height;
              pass_line_index <= 16'd0;
              if (rgb_tlast) begin
                if (active_width != 1)
                  pass_error_flags[1] <= 1'b1;
                pass_pixel_count <= 16'd0;
                if (active_height == 1) begin
                  pass_busy <= 1'b0;
                  pass_frame_count <= pass_frame_count + 1'b1;
                end else begin
                  pass_line_index <= 16'd1;
                end
              end else begin
                pass_pixel_count <= 16'd1;
                if (active_width == 1)
                  pass_error_flags[1] <= 1'b1;
              end
            end else if (!pass_busy) begin
              pass_error_flags[3] <= 1'b1;
            end else if (rgb_tlast) begin
              if ((pass_pixel_count + 1'b1) != active_width)
                pass_error_flags[1] <= 1'b1;
              pass_pixel_count <= 16'd0;
              if (pass_line_index == (active_height - 1'b1)) begin
                pass_busy <= 1'b0;
                pass_line_index <= 16'd0;
                pass_frame_count <= pass_frame_count + 1'b1;
              end else begin
                pass_line_index <= pass_line_index + 1'b1;
              end
            end else begin
              if ((pass_pixel_count + 1'b1) >= active_width)
                pass_error_flags[1] <= 1'b1;
              pass_pixel_count <= pass_pixel_count + 1'b1;
            end
          end
        end
      end
    end
  endgenerate

  // ERROR_FLAGS[4] reports rejected source, format, or scaler-free geometry.
  // The BRAM reader currently uses only its low error bit; retain the full
  // BRAM error half and place the profile error in the unused scaler bit 4.
  assign cfg_error_flags = {bram_error_flags[15:0], scaler_error_flags[15:5],
                            invalid_profile_error, scaler_error_flags[3:0]};
endmodule

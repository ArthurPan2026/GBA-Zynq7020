`timescale 1ns/1ps
// 将48-bit双声道24-bit PCM整理为HDMI 1.4b音频包，采样率采用静态profile。
module hdmi_pcm_packet_source #(
  parameter bit ENABLE_HDMI_AUDIO = 1'b1,
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48_000,
  parameter integer FIFO_ADDR_WIDTH = 4,
  parameter integer ACR_N =
      (AUDIO_SAMPLE_RATE_HZ == 96_000) ? 12_288 :
      (AUDIO_SAMPLE_RATE_HZ == 192_000) ? 24_576 : 6_144,
  parameter bit USE_VIDEO_PROFILE_CLOCKS = 1'b0,
  parameter integer VGA_PROFILE_CLOCK_HZ = 25_178_571,
  parameter integer HD_PROFILE_CLOCK_HZ = 74_250_000
) (
  input  logic        pixel_clk,
  input  logic        audio_pcm_clk,
  input  logic [31:0] pixel_clock_hz,
  input  logic [31:0] h_total,
  input  logic [7:0]  video_vic,
  input  logic        pixel_aresetn,
  input  logic        audio_pcm_aresetn,
  input  logic        hdmi_mode_active,
  input  logic        vsync,
  input  logic        line_prepare,
  input  logic        packet_active,
  input  logic [47:0] audio_pcm_tdata,
  input  logic        audio_pcm_tvalid,
  output logic        audio_pcm_tready,
  input  logic        hdmi_audio_enable,
  input  logic        audio_mute,
  input  logic [16:0] audio_gain_q15,
  input  logic        packet_ready,
  output logic        packet_valid,
  output logic        packet_cancel,
  output logic        packet_cancel_link,
  output logic [23:0] packet_header,
  output logic [55:0] packet_sub0,
  output logic [55:0] packet_sub1,
  output logic [55:0] packet_sub2,
  output logic [55:0] packet_sub3,
  output logic        audio_underflow_event,
  output logic        audio_overflow_event
);
  function automatic logic [31:0] profile_clock_from_vic(input logic [7:0] vic);
    case (vic)
      8'd1: profile_clock_from_vic = 32'(VGA_PROFILE_CLOCK_HZ);
      8'd4, 8'd34: profile_clock_from_vic = 32'(HD_PROFILE_CLOCK_HZ);
      8'd16: profile_clock_from_vic = 32'd148500000;
      default: profile_clock_from_vic = 32'd0;
    endcase
  endfunction

  function automatic logic [31:0] profile_h_total_from_vic(input logic [7:0] vic);
    case (vic)
      8'd1: profile_h_total_from_vic = 32'd800;
      8'd4: profile_h_total_from_vic = 32'd1650;
      8'd34, 8'd16: profile_h_total_from_vic = 32'd2200;
      default: profile_h_total_from_vic = 32'd0;
    endcase
  endfunction

  function automatic logic profile_vic_supported(input logic [7:0] vic);
    profile_vic_supported = (vic == 8'd1) || (vic == 8'd4) ||
                            (vic == 8'd34) || (vic == 8'd16);
  endfunction

  generate if (ENABLE_HDMI_AUDIO) begin : g_hdmi_audio_enabled
    localparam logic [2:0] PACKET_NONE = 3'd0;
    localparam logic [2:0] PACKET_SAMPLE = 3'd1;
    localparam logic [2:0] PACKET_ACR = 3'd2;
    localparam logic [2:0] PACKET_INFOFRAME = 3'd3;
    localparam logic [2:0] PACKET_AVI = 3'd5;
    localparam integer SAMPLE_PHASE_WIDTH = USE_VIDEO_PROFILE_CLOCKS ? 28 : 32;
    localparam integer ACR_PHASE_WIDTH = 32;
    localparam integer ACR_PACKET_RATE_HZ = (128 * AUDIO_SAMPLE_RATE_HZ) / ACR_N;

    (* ASYNC_REG = "TRUE" *) logic audio_enable_meta, audio_enable_sync;
    (* ASYNC_REG = "TRUE" *) logic audio_link_meta, audio_link_sync;
    logic audio_enable_prev;
    (* ASYNC_REG = "TRUE" *) logic pixel_enable_meta, pixel_enable_sync;
    logic pixel_enable_prev;
    (* ASYNC_REG = "TRUE" *) logic mute_meta, mute_sync;
    logic pixel_audio_enable, audio_run_enable;
    logic wr_clear, rd_clear;
    logic rd_flush_pending;
    logic [47:0] fifo_rd_data;
    logic fifo_wr_ready, fifo_rd_valid, fifo_rd_ready;
    logic fifo_wr_full, fifo_rd_empty;
    logic [FIFO_ADDR_WIDTH:0] fifo_wr_level, fifo_rd_level;
    logic [SAMPLE_PHASE_WIDTH-1:0] sample_phase;
    logic [SAMPLE_PHASE_WIDTH-1:0] sample_phase_threshold;
    logic [SAMPLE_PHASE_WIDTH-1:0] sample_phase_threshold_comb;
    logic [SAMPLE_PHASE_WIDTH-1:0] sample_phase_next;
    logic sample_due;
    logic [ACR_PHASE_WIDTH-1:0] acr_line_phase;
    logic [63:0] acr_line_phase_increment;
    logic [63:0] acr_line_phase_increment_comb;
    logic [63:0] acr_line_phase_sum;
    logic acr_line_tick, acr_line_tick_next;
    logic [31:0] pixel_clock_hz_prev, h_total_prev;
    logic [7:0] video_vic_prev;
    logic [31:0] scheduler_pixel_clock_hz, scheduler_h_total;
    logic sample_clock_valid;
    logic profile_params_changed;
    logic rd_fire;
    logic audio_started;
    logic [2:0] startup_sample_count;
    logic [4:0] sample_debt;
    logic [2:0] buffered_sample_count;
    logic [47:0] sample_buffer [0:3];
    logic [7:0] next_frame_index;
    logic [7:0] first_buffer_frame_index;
    wire signed [23:0] gained_left, gained_right;
    logic signed [23:0] gain_sample_left, gain_sample_right;
    logic signed [17:0] gain_coefficient;
    (* use_dsp = "yes" *) logic signed [41:0] gain_product_left, gain_product_right;
    logic gain_input_valid, gain_output_valid;
    logic [2:0] selected_packet;
    logic packet_sample_fire;
    logic acr_due;
    logic infoframe_due;
    logic avi_due;
    logic vsync_q;
    logic vsync_rise;
    logic [23:0] sample_header, acr_header, info_header, avi_header;
    logic [55:0] sample_sub [0:3];
    logic [55:0] acr_sub [0:3];
    logic [55:0] info_sub [0:3];
    logic [55:0] avi_sub [0:3];
    integer sample_index;

    // HDMI 请求分别同步到 PCM 与像素时钟域，再与像素域的实际链路状态组合。
    assign pixel_audio_enable = pixel_enable_sync && hdmi_mode_active;
    assign audio_run_enable = audio_enable_sync && audio_link_sync;
    assign profile_params_changed = USE_VIDEO_PROFILE_CLOCKS ?
                                    (video_vic != video_vic_prev) :
                                    ((pixel_clock_hz != pixel_clock_hz_prev) ||
                                     (h_total != h_total_prev));

    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        pixel_clock_hz_prev <= 32'd0;
        h_total_prev <= 32'd0;
        video_vic_prev <= 8'd0;
        sample_phase_threshold <= '0;
      end else begin
        pixel_clock_hz_prev <= pixel_clock_hz;
        h_total_prev <= h_total;
        video_vic_prev <= video_vic;
        sample_phase_threshold <= sample_phase_threshold_comb;
      end
    end

    always_ff @(posedge audio_pcm_clk or negedge audio_pcm_aresetn) begin
      if (!audio_pcm_aresetn) begin
        audio_enable_meta <= 1'b0;
        audio_enable_sync <= 1'b0;
        audio_link_meta <= 1'b0;
        audio_link_sync <= 1'b0;
        audio_enable_prev <= 1'b0;
      end else begin
        audio_enable_meta <= hdmi_audio_enable;
        audio_enable_sync <= audio_enable_meta;
        audio_link_meta <= hdmi_mode_active;
        audio_link_sync <= audio_link_meta;
        audio_enable_prev <= audio_run_enable;
      end
    end

    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        pixel_enable_meta <= 1'b0;
        pixel_enable_sync <= 1'b0;
        pixel_enable_prev <= 1'b0;
        mute_meta <= 1'b0;
        mute_sync <= 1'b0;
        rd_flush_pending <= 1'b1;
      end else begin
        pixel_enable_meta <= hdmi_audio_enable;
        pixel_enable_sync <= pixel_enable_meta;
        pixel_enable_prev <= pixel_audio_enable;
        mute_meta <= audio_mute;
        mute_sync <= mute_meta;

        if (pixel_audio_enable != pixel_enable_prev)
          rd_flush_pending <= 1'b1;
        else if (rd_flush_pending && !packet_active)
          rd_flush_pending <= 1'b0;
      end
    end

    assign wr_clear = (audio_run_enable != audio_enable_prev);
    assign rd_clear = rd_flush_pending && !packet_active;
    assign audio_pcm_tready = !audio_run_enable || (fifo_wr_ready && !wr_clear);
    assign audio_overflow_event = 1'b0;
    // A pending packet may be discarded only after the link has safely selected DVI.
    // Audio disable stops future audio packets; a loaded packet completes at its boundary.
    assign packet_cancel = !pixel_audio_enable && !packet_active;
    assign packet_cancel_link = !hdmi_mode_active && !packet_active;

    audio_pcm_async_fifo #(
      .DATA_WIDTH(48), .ADDR_WIDTH(FIFO_ADDR_WIDTH)
    ) u_audio_fifo (
      .wr_clk(audio_pcm_clk), .wr_resetn(audio_pcm_aresetn), .wr_clear(wr_clear),
      .wr_data(audio_pcm_tdata), .wr_valid(audio_pcm_tvalid && audio_run_enable && !wr_clear),
      .wr_ready(fifo_wr_ready), .wr_full(fifo_wr_full), .wr_level(fifo_wr_level),
      .rd_clk(pixel_clk), .rd_resetn(pixel_aresetn), .rd_clear(rd_clear),
      .rd_data(fifo_rd_data), .rd_valid(fifo_rd_valid),
      .rd_ready(fifo_rd_ready), .rd_empty(fifo_rd_empty), .rd_level(fifo_rd_level)
    );

    // Fractional accumulators use the active pixel clock and horizontal total.
    always_comb begin
      scheduler_pixel_clock_hz = USE_VIDEO_PROFILE_CLOCKS ?
          profile_clock_from_vic(video_vic) : pixel_clock_hz;
      scheduler_h_total = USE_VIDEO_PROFILE_CLOCKS ?
          profile_h_total_from_vic(video_vic) : h_total;
      sample_clock_valid = USE_VIDEO_PROFILE_CLOCKS ?
          profile_vic_supported(video_vic) : (pixel_clock_hz > AUDIO_SAMPLE_RATE_HZ);
      sample_phase_threshold_comb = '0;
      if (USE_VIDEO_PROFILE_CLOCKS) begin
        case (video_vic)
          8'd1: sample_phase_threshold_comb =
              SAMPLE_PHASE_WIDTH'(VGA_PROFILE_CLOCK_HZ - AUDIO_SAMPLE_RATE_HZ);
          8'd4, 8'd34: sample_phase_threshold_comb =
              SAMPLE_PHASE_WIDTH'(HD_PROFILE_CLOCK_HZ - AUDIO_SAMPLE_RATE_HZ);
          8'd16: sample_phase_threshold_comb =
              SAMPLE_PHASE_WIDTH'(148_500_000 - AUDIO_SAMPLE_RATE_HZ);
          default: sample_phase_threshold_comb = '0;
        endcase
      end else if (pixel_clock_hz > AUDIO_SAMPLE_RATE_HZ) begin
        sample_phase_threshold_comb =
            SAMPLE_PHASE_WIDTH'(pixel_clock_hz - AUDIO_SAMPLE_RATE_HZ);
      end
      sample_due = sample_clock_valid &&
                   (sample_phase >= sample_phase_threshold);
      if (sample_due)
        sample_phase_next = sample_phase - sample_phase_threshold;
      else
        sample_phase_next = sample_phase + SAMPLE_PHASE_WIDTH'(AUDIO_SAMPLE_RATE_HZ);
      if (USE_VIDEO_PROFILE_CLOCKS) begin
        case (video_vic)
          8'd1: acr_line_phase_increment_comb = 64'(ACR_PACKET_RATE_HZ) * 64'd800;
          8'd4: acr_line_phase_increment_comb = 64'(ACR_PACKET_RATE_HZ) * 64'd1650;
          8'd34, 8'd16: acr_line_phase_increment_comb = 64'(ACR_PACKET_RATE_HZ) * 64'd2200;
          default: acr_line_phase_increment_comb = 64'd0;
        endcase
      end else begin
        acr_line_phase_increment_comb = 64'(ACR_PACKET_RATE_HZ) * 64'(h_total);
      end
      acr_line_phase_sum = 64'(acr_line_phase) + acr_line_phase_increment;
      acr_line_tick_next = (scheduler_pixel_clock_hz != 32'd0) &&
                      (scheduler_h_total != 32'd0) &&
                      (acr_line_phase_sum >= 64'(scheduler_pixel_clock_hz));
    end

    // Register the mode-constant multiply before phase arithmetic.
    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        acr_line_phase_increment <= 0;
        acr_line_tick <= 1'b0;
      end else begin
        acr_line_phase_increment <= acr_line_phase_increment_comb;
        // Phase changes only at line_prepare; settle this decision before the next line.
        acr_line_tick <= acr_line_tick_next;
      end
    end

    assign fifo_rd_ready = pixel_audio_enable && !rd_flush_pending &&
                           (buffered_sample_count < 3'd4) && !gain_input_valid && !gain_output_valid;
    assign rd_fire = fifo_rd_valid && fifo_rd_ready;
    assign vsync_rise = vsync && !vsync_q;
    // Reserve one FIFO sample while the two-stage Q1.15 multiply completes.
    // Gain is clamped to unity, so a signed 24-bit input cannot overflow.
    assign gained_left = gain_product_left[38:15];
    assign gained_right = gain_product_right[38:15];
    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        gain_input_valid <= 1'b0;
        gain_output_valid <= 1'b0;
        gain_sample_left <= '0;
        gain_sample_right <= '0;
        gain_coefficient <= '0;
        gain_product_left <= '0;
        gain_product_right <= '0;
      end else if (rd_clear || !pixel_audio_enable) begin
        gain_input_valid <= 1'b0;
        gain_output_valid <= 1'b0;
      end else begin
        gain_input_valid <= rd_fire;
        gain_output_valid <= gain_input_valid;
        if (rd_fire) begin
          gain_sample_left <= $signed(fifo_rd_data[23:0]);
          gain_sample_right <= $signed(fifo_rd_data[47:24]);
          gain_coefficient <= mute_sync ? 18'sd0 :
              ((audio_gain_q15 > 17'd32768) ? 18'sd32768 : $signed({1'b0,audio_gain_q15}));
        end
        if (gain_input_valid) begin
          gain_product_left <= gain_sample_left * gain_coefficient;
          gain_product_right <= gain_sample_right * gain_coefficient;
        end
      end
    end

    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        sample_phase <= '0;
        audio_started <= 1'b0;
        startup_sample_count <= 3'd0;
        sample_debt <= 5'd0;
        audio_underflow_event <= 1'b0;
      end else begin
        audio_underflow_event <= 1'b0;
        if (!pixel_audio_enable || rd_flush_pending || profile_params_changed ||
            !sample_clock_valid) begin
          sample_phase <= '0;
          audio_started <= 1'b0;
          startup_sample_count <= 3'd0;
          sample_debt <= 5'd0;
        end else begin
          sample_phase <= sample_phase_next;

          if (rd_fire) begin
            if (startup_sample_count < 3'd4)
              startup_sample_count <= startup_sample_count + 1'b1;
            if (startup_sample_count >= 3'd3)
              audio_started <= 1'b1;
            sample_debt <= 5'd0;
          end else if (sample_due && buffered_sample_count == 3'd0 &&
                       !fifo_rd_valid && audio_started && !mute_sync) begin
            if (sample_debt < 5'd2)
              sample_debt <= sample_debt + 1'b1;
            if (sample_debt >= 5'd2)
              audio_underflow_event <= 1'b1;
          end else if (sample_due && (buffered_sample_count != 3'd0 || fifo_rd_valid)) begin
            sample_debt <= 5'd0;
          end
        end
      end
    end

    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        buffered_sample_count <= 3'd0;
        next_frame_index <= 8'd0;
        first_buffer_frame_index <= 8'd0;
        for (sample_index = 0; sample_index < 4; sample_index = sample_index + 1)
          sample_buffer[sample_index] <= '0;
      end else begin
        if (rd_clear) begin
          buffered_sample_count <= 3'd0;
        end else begin
          case ({gain_output_valid, packet_sample_fire})
            2'b00: begin end
            2'b01: buffered_sample_count <= 3'd0;
            2'b10: begin
              if (buffered_sample_count == 3'd0)
                first_buffer_frame_index <= next_frame_index;
              if (buffered_sample_count < 3'd4) begin
                sample_buffer[buffered_sample_count] <= {gained_right, gained_left};
                buffered_sample_count <= buffered_sample_count + 1'b1;
              end
            end
            2'b11: begin
              // 包装入旧四帧时，恰好同时到达的新帧成为下一包的首帧。
              sample_buffer[0] <= {gained_right, gained_left};
              buffered_sample_count <= 3'd1;
              first_buffer_frame_index <= next_frame_index;
            end
          endcase
        end

        if (gain_output_valid) begin
          if (next_frame_index == 8'd191)
            next_frame_index <= 8'd0;
          else
            next_frame_index <= next_frame_index + 1'b1;
        end
      end
    end

    hdmi_audio_sample_packet #(.AUDIO_SAMPLE_RATE_HZ(AUDIO_SAMPLE_RATE_HZ)) u_sample_packet (
      .stereo_sample(sample_buffer), .sample_count(buffered_sample_count), .sample_flat(4'b0000),
      .first_frame_index(first_buffer_frame_index), .header(sample_header),
      .subpacket(sample_sub)
    );
    hdmi_acr_packet #(
      .AUDIO_SAMPLE_RATE_HZ(AUDIO_SAMPLE_RATE_HZ), .ACR_N(ACR_N),
      .USE_VIDEO_PROFILE_CLOCKS(USE_VIDEO_PROFILE_CLOCKS),
      .VGA_PROFILE_CLOCK_HZ(VGA_PROFILE_CLOCK_HZ),
      .HD_PROFILE_CLOCK_HZ(HD_PROFILE_CLOCK_HZ)
    ) u_acr_packet (.pixel_clock_hz(pixel_clock_hz), .video_vic(video_vic),
                    .header(acr_header), .subpacket(acr_sub));
    hdmi_audio_infoframe #(.AUDIO_SAMPLE_RATE_HZ(AUDIO_SAMPLE_RATE_HZ), .AUDIO_SAMPLE_SIZE_BITS(24))
      u_audio_infoframe (.header(info_header), .subpacket(info_sub));
    hdmi_avi_infoframe u_avi_infoframe (
      .video_vic(video_vic), .header(avi_header), .subpacket(avi_sub)
    );

    always_comb begin
      selected_packet = PACKET_NONE;
      if (pixel_audio_enable && !rd_flush_pending &&
          (acr_due || acr_line_tick)) begin
        selected_packet = PACKET_ACR;
      end else if (hdmi_mode_active && avi_due) begin
        selected_packet = PACKET_AVI;
      end else if (pixel_audio_enable && !rd_flush_pending) begin
        if (infoframe_due)
          selected_packet = PACKET_INFOFRAME;
        else if (buffered_sample_count != 3'd0)
          selected_packet = PACKET_SAMPLE;
      end
      packet_valid = line_prepare && hdmi_mode_active && packet_ready &&
                     (selected_packet != PACKET_NONE);
      packet_header = 24'd0;
      packet_sub0 = 56'd0;
      packet_sub1 = 56'd0;
      packet_sub2 = 56'd0;
      packet_sub3 = 56'd0;
      case (selected_packet)
        PACKET_SAMPLE: begin
          packet_header = sample_header;
          packet_sub0 = sample_sub[0];
          packet_sub1 = sample_sub[1];
          packet_sub2 = sample_sub[2];
          packet_sub3 = sample_sub[3];
        end
        PACKET_ACR: begin
          packet_header = acr_header;
          packet_sub0 = acr_sub[0];
          packet_sub1 = acr_sub[1];
          packet_sub2 = acr_sub[2];
          packet_sub3 = acr_sub[3];
        end
        PACKET_INFOFRAME: begin
          packet_header = info_header;
          packet_sub0 = info_sub[0];
          packet_sub1 = info_sub[1];
          packet_sub2 = info_sub[2];
          packet_sub3 = info_sub[3];
        end
        PACKET_AVI: begin
          packet_header = avi_header;
          packet_sub0 = avi_sub[0];
          packet_sub1 = avi_sub[1];
          packet_sub2 = avi_sub[2];
          packet_sub3 = avi_sub[3];
        end
        default: begin end
      endcase
    end

    assign packet_sample_fire = packet_valid && (selected_packet == PACKET_SAMPLE);

    // CTS 7-29 checks the long-term ACR update interval. Use a fractional
    // line accumulator rather than a fixed 31-line interval.
    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        acr_due <= 1'b1;
        acr_line_phase <= '0;
        infoframe_due <= 1'b1;
        avi_due <= 1'b1;
        vsync_q <= 1'b0;
      end else if (rd_clear) begin
        acr_due <= 1'b1;
        acr_line_phase <= '0;
        infoframe_due <= 1'b1;
        avi_due <= 1'b1;
        vsync_q <= vsync;
      end else if (profile_params_changed) begin
        // The timing profile changed at the pixel-domain boundary; restart the
        // fractional ACR schedule and re-advertise both InfoFrames.
        acr_due <= 1'b1;
        acr_line_phase <= '0;
        infoframe_due <= 1'b1;
        avi_due <= 1'b1;
        vsync_q <= vsync;
      end else begin
        vsync_q <= vsync;

        if (!hdmi_mode_active) begin
          infoframe_due <= 1'b1;
          avi_due <= 1'b1;
        end

        if (!pixel_audio_enable || rd_flush_pending) begin
          acr_due <= 1'b1;
          acr_line_phase <= '0;
          if (!pixel_audio_enable || rd_flush_pending)
            infoframe_due <= 1'b1;
        end else if (line_prepare) begin
          if (packet_valid && packet_ready && selected_packet == PACKET_ACR) begin
            // Start the next interval at the actual ACR packet line. Preserve
            // fractional overshoot only when this packet lands on the phase tick.
            acr_due <= 1'b0;
            if (acr_line_tick)
              acr_line_phase <= 32'(acr_line_phase_sum - 64'(scheduler_pixel_clock_hz));
            else
              acr_line_phase <= '0;
          end else if (acr_due) begin
            // A due packet is waiting for a free island slot; hold its phase.
          end else if (acr_line_tick) begin
            acr_line_phase <= 32'(acr_line_phase_sum - 64'(scheduler_pixel_clock_hz));
            acr_due <= 1'b1;
          end else begin
            acr_line_phase <= acr_line_phase_sum[ACR_PHASE_WIDTH-1:0];
          end
        end

        if (line_prepare) begin
          if (packet_valid && packet_ready && selected_packet == PACKET_INFOFRAME)
            infoframe_due <= 1'b0;
          if (packet_valid && packet_ready && selected_packet == PACKET_AVI)
            avi_due <= 1'b0;
        end

        // Use the actual frame marker instead of a duplicate line counter.
        if (vsync_rise) begin
          infoframe_due <= 1'b1;
          avi_due <= 1'b1;
        end
      end
    end

    initial begin
      if (ACR_N <= 0 || ACR_PACKET_RATE_HZ <= 0)
        $error("ACR_N must produce a positive HDMI 1.4b CTS update rate");
    end
  end else begin : g_hdmi_audio_disabled
    logic vsync_q;
    logic vsync_rise;
    logic avi_due;
    logic [23:0] avi_header;
    logic [55:0] avi_sub [0:3];
    hdmi_avi_infoframe u_avi_infoframe (
      .video_vic(video_vic), .header(avi_header), .subpacket(avi_sub)
    );
    assign vsync_rise = vsync && !vsync_q;
    assign audio_pcm_tready = 1'b1;
    assign packet_valid = hdmi_mode_active && line_prepare && packet_ready && avi_due;
    assign packet_cancel = 1'b0;
    assign packet_cancel_link = !hdmi_mode_active && !packet_active;
    always_comb begin
      // The STATIC_AVI_ONLY assembler consumes this constant payload directly.
      packet_header = avi_header;
      packet_sub0 = avi_sub[0];
      packet_sub1 = avi_sub[1];
      packet_sub2 = avi_sub[2];
      packet_sub3 = avi_sub[3];
    end
    assign audio_underflow_event = 1'b0;
    assign audio_overflow_event = 1'b0;

    always_ff @(posedge pixel_clk or negedge pixel_aresetn) begin
      if (!pixel_aresetn) begin
        vsync_q <= 1'b0;
        avi_due <= 1'b1;
      end else begin
        vsync_q <= vsync;
        if (!hdmi_mode_active) begin
          avi_due <= 1'b1;
        end else if (line_prepare) begin
          if (packet_valid && packet_ready && avi_due)
            avi_due <= 1'b0;
        end
        if (vsync_rise) begin
          avi_due <= 1'b1;
        end
      end
    end
  end endgenerate
endmodule

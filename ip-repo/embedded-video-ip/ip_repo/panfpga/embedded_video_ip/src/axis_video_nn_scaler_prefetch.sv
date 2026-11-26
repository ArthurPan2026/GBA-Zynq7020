// Dual-line-prefetch nearest-neighbor scaler for BRAM-backed video paths.
// The input side captures the next source row into the free bank while the
// output side emits repeated rows from the current bank.
module axis_video_nn_scaler_prefetch #(
  parameter integer MAX_INPUT_WIDTH = 1920,
  parameter integer MAX_INPUT_HEIGHT = 1080,
  parameter integer OUTPUT_WIDTH = 1920,
  parameter integer OUTPUT_HEIGHT = 1080,
  parameter integer MAX_BUFFER_WIDTH = 240,
  parameter integer MAX_BUFFER_HEIGHT = 160
) (
  input logic aclk, input logic aresetn,
  input logic [15:0] cfg_width, input logic [15:0] cfg_height,
  input logic [10:0] cfg_output_width, input logic [10:0] cfg_output_height,
  input logic [10:0] cfg_active_width, input logic [10:0] cfg_active_height,
  input logic [10:0] cfg_x_offset, input logic [10:0] cfg_y_offset,
  input logic [10:0] cfg_source_x_origin, input logic [10:0] cfg_source_y_origin,
  input logic [10:0] cfg_x_step, input logic [10:0] cfg_x_rem,
  input logic [10:0] cfg_y_step, input logic [10:0] cfg_y_rem,
  input logic clear_errors,
  input logic [23:0] s_axis_tdata, input logic s_axis_tvalid,
  output logic s_axis_tready, input logic s_axis_tuser, input logic s_axis_tlast,
  output logic [23:0] m_axis_tdata, output logic m_axis_tvalid,
  input logic m_axis_tready, output logic m_axis_tuser, output logic m_axis_tlast,
  output logic busy, output logic [31:0] frame_count,
  output logic [31:0] error_flags,
  output logic [10:0] active_width, output logic [10:0] active_height
);
  typedef enum logic [2:0] {
    ST_WAIT_SOF, ST_DROP, ST_WAIT_LINE, ST_PAD_TOP,
    ST_EMIT_ROW, ST_PAD_BOTTOM, ST_BYPASS
  } state_t;
  state_t state;

  logic cfg_invalid_geometry, cfg_bypass_1to1;
  logic cfg_invalid_geometry_comb, cfg_bypass_1to1_comb;
  logic [10:0] in_width, in_height, bypass_x_left, bypass_y_left;
  logic [10:0] input_x, input_y, input_pixels_left, input_reuse_source_y;
  logic input_frame_active, input_frame_done, capture_active;
  logic capture_bank, next_write_bank, output_read_bank;
  logic [1:0] line_valid;
  logic [10:0] line_y0, line_y1;
  logic output_frame_completed, stream_synchronized;

  logic [10:0] x_offset, y_offset, emit_x, out_y_total, active_y_count;
  logic [10:0] active_x_start_last, active_x_remaining;
  logic active_x_window;
  logic [10:0] pad_top_left, pad_bottom_left;
  logic top_emitted;
  localparam integer SOURCE_X_WIDTH =
      (MAX_BUFFER_WIDTH > 1) ? $clog2(2 * MAX_BUFFER_WIDTH + 1) : 2;
  logic [SOURCE_X_WIDTH-1:0] line_read_source_x, line_read_next_x;
  logic [SOURCE_X_WIDTH-1:0] line_buf_read_current_x, line_buf_read_addr;
  logic [10:0] line_read_x_error, line_read_next_error;
  logic [11:0] line_read_x_error_sum;
  logic [10:0] source_y, source_x_origin, source_y_origin;
  logic [10:0] x_step, x_rem, y_step, y_rem, y_error;
  logic [11:0] y_error_sum;
  logic [10:0] y_error_next_calc, y_increment_calc;
  logic [10:0] y_step_plus_one, y_error_next_pending, y_increment_pending;
  logic y_carry;

  logic bank0_free, bank1_free, any_bank_free, selected_write_bank;
  logic [1:0] line_bank_reusable;
  logic line_bank_release_pending;
  logic selected_line_valid, selected_line_bank;
  logic input_sof_allowed, input_sof_abort, input_line_error;
  logic input_first_pixel, input_new_line_pixel, input_capture_pixel;
  logic input_pixel_accept, input_line_complete;
  logic [10:0] input_pixel_y, input_pixel_x;
  logic line_buf_wr_en, line_buf_wr_bank;
  logic [10:0] line_buf_wr_addr;
  logic line_buf_read_issue, line_buf_read_valid, line_buf_read_pop;
  logic [23:0] line_buf_read_data;
  logic line_buf_pixel_needed;
  logic bypass_start, bypass_active_beat, bypass_beat;
  logic in_handshake;
  logic output_row_end, output_frame_finish;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      cfg_invalid_geometry <= 1'b1;
      cfg_bypass_1to1 <= 1'b0;
    end else begin
      cfg_invalid_geometry <= cfg_invalid_geometry_comb;
      cfg_bypass_1to1 <= cfg_bypass_1to1_comb;
    end
  end

  always_comb begin
    cfg_bypass_1to1_comb = (cfg_width == cfg_output_width) &&
                           (cfg_height == cfg_output_height) &&
                           (cfg_active_width == cfg_width) &&
                           (cfg_active_height == cfg_height) &&
                           (cfg_x_offset == 0) && (cfg_y_offset == 0) &&
                           (cfg_source_x_origin == 0) && (cfg_source_y_origin == 0) &&
                           (cfg_x_step == 11'd1) && (cfg_x_rem == 0) &&
                           (cfg_y_step == 11'd1) && (cfg_y_rem == 0);
    cfg_invalid_geometry_comb = (cfg_width == 0) || (cfg_height == 0) ||
                          (cfg_output_width == 0) || (cfg_output_height == 0) ||
                          (cfg_output_width > OUTPUT_WIDTH) ||
                          (cfg_output_height > OUTPUT_HEIGHT) ||
                          (cfg_width > MAX_INPUT_WIDTH) ||
                          (cfg_height > MAX_INPUT_HEIGHT) ||
                          (!cfg_bypass_1to1_comb &&
                           ((cfg_width > MAX_BUFFER_WIDTH) ||
                            (cfg_height > MAX_BUFFER_HEIGHT))) ||
                          (cfg_active_width == 0) || (cfg_active_height == 0) ||
                          (cfg_active_width > cfg_output_width) ||
                          (cfg_active_height > cfg_output_height) ||
                          ((cfg_x_offset + cfg_active_width) > cfg_output_width) ||
                          ((cfg_y_offset + cfg_active_height) > cfg_output_height) ||
                          (cfg_source_x_origin >= cfg_width) ||
                          (cfg_source_y_origin >= cfg_height) ||
                          (cfg_x_rem >= cfg_active_width) ||
                          (cfg_y_rem >= cfg_active_height) ||
                          (cfg_x_step > MAX_INPUT_WIDTH) ||
                          (cfg_y_step > MAX_INPUT_HEIGHT);

    bank0_free = (line_bank_reusable[0] || output_frame_completed) &&
                 !(capture_active && !capture_bank);
    bank1_free = (line_bank_reusable[1] || output_frame_completed) &&
                 !(capture_active && capture_bank);
    any_bank_free = bank0_free || bank1_free;
    if (!next_write_bank)
      selected_write_bank = bank0_free ? 1'b0 : 1'b1;
    else
      selected_write_bank = bank1_free ? 1'b1 : 1'b0;

    selected_line_valid = 1'b0;
    selected_line_bank = 1'b0;
    if (line_valid[0] && (line_y0 == source_y)) begin
      selected_line_valid = 1'b1;
      selected_line_bank = 1'b0;
    end else if (line_valid[1] && (line_y1 == source_y)) begin
      selected_line_valid = 1'b1;
      selected_line_bank = 1'b1;
    end

    input_sof_allowed = ((state == ST_WAIT_SOF) || (state == ST_DROP)) &&
                        input_frame_done && !input_frame_active &&
                        !capture_active && any_bank_free;
    input_sof_abort = !cfg_bypass_1to1 && s_axis_tvalid && s_axis_tuser &&
                      input_frame_active;
    if (cfg_invalid_geometry) begin
      s_axis_tready = ((state == ST_WAIT_SOF) || (state == ST_DROP));
    end else if (cfg_bypass_1to1) begin
      if ((state == ST_WAIT_SOF) || (state == ST_DROP))
        s_axis_tready = m_axis_tready;
      else if (state == ST_BYPASS)
        s_axis_tready = !s_axis_tuser && m_axis_tready;
      else
        s_axis_tready = 1'b0;
    end else if (input_sof_abort) begin
      s_axis_tready = 1'b0;
    end else if (s_axis_tuser) begin
      s_axis_tready = input_sof_allowed;
    end else if ((state == ST_WAIT_SOF) || (state == ST_DROP)) begin
      s_axis_tready = 1'b1;
    end else if (capture_active) begin
      s_axis_tready = 1'b1;
    end else begin
      s_axis_tready = input_frame_active && any_bank_free;
    end
    in_handshake = s_axis_tvalid && s_axis_tready;

    input_first_pixel = in_handshake && s_axis_tuser &&
                        !cfg_invalid_geometry && !cfg_bypass_1to1;
    input_new_line_pixel = in_handshake && !s_axis_tuser &&
                           input_frame_active && !capture_active &&
                           (state != ST_DROP);
    input_capture_pixel = in_handshake && !s_axis_tuser &&
                          capture_active && (state != ST_DROP);
    input_pixel_accept = input_first_pixel || input_new_line_pixel ||
                         input_capture_pixel;
    input_pixel_y = input_first_pixel ? 11'd0 : input_y;
    input_pixel_x = (input_first_pixel || input_new_line_pixel) ? 11'd0 : input_x;
    input_reuse_source_y = input_first_pixel ? cfg_source_y_origin : source_y;
    input_line_error = 1'b0;
    if (input_first_pixel)
      input_line_error = (s_axis_tlast != (cfg_width == 1));
    else if (input_new_line_pixel)
      input_line_error = (s_axis_tlast != (in_width == 1));
    else if (input_capture_pixel)
      input_line_error = (s_axis_tlast != (input_pixels_left == 11'd1));
    input_line_complete = input_pixel_accept && s_axis_tlast && !input_line_error;

    // A malformed line may write into its reserved free bank; line_valid is
    // asserted only after a complete, correctly framed line, so partial data
    // is never exposed to the output side.
    line_buf_wr_en = input_pixel_accept;
    line_buf_wr_bank = (input_first_pixel || input_new_line_pixel) ?
                       selected_write_bank : capture_bank;
    line_buf_wr_addr = input_pixel_x;

    bypass_start = ((state == ST_WAIT_SOF) || (state == ST_DROP)) &&
                   cfg_bypass_1to1 && !cfg_invalid_geometry &&
                   s_axis_tvalid && s_axis_tuser;
    bypass_active_beat = (state == ST_BYPASS) && !s_axis_tuser;
    bypass_beat = bypass_start || bypass_active_beat;

    line_read_x_error_sum = line_read_x_error + x_rem;
    if (line_read_x_error_sum >= active_width) begin
      line_read_next_x = line_read_source_x + x_step + 1'b1;
      line_read_next_error = line_read_x_error_sum - active_width;
    end else begin
      line_read_next_x = line_read_source_x + x_step;
      line_read_next_error = line_read_x_error_sum;
    end
    y_error_sum = {1'b0, y_error} + {1'b0, y_rem};
    y_carry = (y_error_sum >= {1'b0, active_height});
    if (y_carry) begin
      y_error_next_calc = y_error_sum - {1'b0, active_height};
      y_increment_calc = y_step_plus_one;
    end else begin
      y_error_next_calc = y_error_sum[10:0];
      y_increment_calc = y_step;
    end

    line_buf_pixel_needed = (state == ST_EMIT_ROW) &&
                            active_x_window &&
                            ((line_buf_read_valid &&
                              (line_buf_read_current_x < in_width)) ||
                             (!line_buf_read_valid &&
                              (line_read_source_x < in_width)));

    m_axis_tvalid = (state == ST_PAD_TOP) ||
                    (state == ST_EMIT_ROW) ||
                    (state == ST_PAD_BOTTOM) ||
                    (bypass_beat && s_axis_tvalid);
    if (line_buf_pixel_needed)
      m_axis_tvalid = line_buf_read_valid;
    m_axis_tuser = m_axis_tvalid && (out_y_total == 0) && (emit_x == 0);
    m_axis_tlast = m_axis_tvalid && (emit_x == cfg_output_width-1'b1);
    m_axis_tdata = 24'd0;
    if (bypass_beat) begin
      m_axis_tdata = s_axis_tdata;
      m_axis_tuser = s_axis_tuser;
      m_axis_tlast = s_axis_tlast;
    end else if ((state == ST_EMIT_ROW) &&
                 active_x_window &&
                 line_buf_read_valid &&
                 (line_buf_read_current_x < in_width)) begin
      m_axis_tdata = line_buf_read_data;
    end

    line_buf_read_pop = line_buf_read_valid && m_axis_tvalid && m_axis_tready;
    line_buf_read_issue = 1'b0;
    line_buf_read_addr = line_read_source_x;
    if ((state == ST_EMIT_ROW) && active_x_window) begin
      if (!line_buf_read_valid && (line_read_source_x < in_width))
        line_buf_read_issue = 1'b1;
      else if (line_buf_read_pop && (line_read_source_x < in_width))
        line_buf_read_issue = 1'b1;
    end

    output_row_end = m_axis_tvalid && m_axis_tready &&
                     (emit_x == cfg_output_width-1'b1) &&
                     ((state == ST_EMIT_ROW) || (state == ST_PAD_TOP) ||
                      (state == ST_PAD_BOTTOM));
    output_frame_finish =
      (output_row_end && (state == ST_EMIT_ROW) &&
       (active_y_count + 1 >= active_height) && (pad_bottom_left == 0)) ||
      (output_row_end && (state == ST_PAD_BOTTOM) && (pad_bottom_left <= 1));

    busy = ((state != ST_WAIT_SOF) && (state != ST_DROP)) ||
           !input_frame_done;
  end

  (* ram_style = "block" *) logic [23:0] line_buf0 [0:MAX_BUFFER_WIDTH-1];
  (* ram_style = "block" *) logic [23:0] line_buf1 [0:MAX_BUFFER_WIDTH-1];
  logic [23:0] line_buf_read_data0, line_buf_read_data1;
  logic line_buf_read_valid0, line_buf_read_valid1;
  assign line_buf_read_data = output_read_bank ? line_buf_read_data1 :
                                                line_buf_read_data0;
  assign line_buf_read_valid = output_read_bank ? line_buf_read_valid1 :
                                                 line_buf_read_valid0;

  always_ff @(posedge aclk) begin
    if (line_buf_wr_en && !line_buf_wr_bank)
      line_buf0[line_buf_wr_addr] <= s_axis_tdata;
    if (!aresetn) begin
      line_buf_read_valid0 <= 1'b0;
    end else if (line_buf_read_issue && !output_read_bank) begin
      line_buf_read_data0 <= line_buf0[line_buf_read_addr];
      line_buf_read_valid0 <= 1'b1;
    end else if (line_buf_read_pop || (state != ST_EMIT_ROW) ||
                 output_read_bank) begin
      line_buf_read_valid0 <= 1'b0;
    end
  end

  always_ff @(posedge aclk) begin
    if (line_buf_wr_en && line_buf_wr_bank)
      line_buf1[line_buf_wr_addr] <= s_axis_tdata;
    if (!aresetn) begin
      line_buf_read_valid1 <= 1'b0;
    end else if (line_buf_read_issue && output_read_bank) begin
      line_buf_read_data1 <= line_buf1[line_buf_read_addr];
      line_buf_read_valid1 <= 1'b1;
    end else if (line_buf_read_pop || (state != ST_EMIT_ROW) ||
                 !output_read_bank) begin
      line_buf_read_valid1 <= 1'b0;
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      input_frame_active <= 1'b0;
      input_frame_done <= 1'b1;
      capture_active <= 1'b0;
      capture_bank <= 1'b0;
      next_write_bank <= 1'b0;
      input_x <= '0;
      input_y <= '0;
      input_pixels_left <= '0;
      line_valid <= 2'b00;
    end else if (cfg_bypass_1to1) begin
      input_frame_active <= 1'b0;
      input_frame_done <= 1'b1;
      capture_active <= 1'b0;
      input_x <= '0;
      input_y <= '0;
      input_pixels_left <= '0;
      line_valid <= 2'b00;
    end else if (input_sof_abort || input_line_error ||
                 (in_handshake && s_axis_tuser && cfg_invalid_geometry)) begin
      input_frame_active <= 1'b0;
      input_frame_done <= 1'b1;
      capture_active <= 1'b0;
      input_x <= '0;
      input_y <= '0;
      input_pixels_left <= '0;
      line_valid <= 2'b00;
    end else begin
      // Start each input frame with empty row ownership. Line tags remain
      // valid until reused; the reusable flags are updated separately.
      if (input_first_pixel) begin
        if (input_line_complete &&
            (input_pixel_y >= source_y_origin)) begin
          if (line_buf_wr_bank) line_valid <= 2'b10;
          else line_valid <= 2'b01;
        end else begin
          line_valid <= 2'b00;
        end
      end else if (input_line_complete) begin
        if (input_pixel_y >= source_y_origin) begin
          if (line_buf_wr_bank) line_valid[1] <= 1'b1;
          else line_valid[0] <= 1'b1;
        end else begin
          if (line_buf_wr_bank) line_valid[1] <= 1'b0;
          else line_valid[0] <= 1'b0;
        end
      end

      if (input_first_pixel) begin
        input_frame_active <= 1'b1;
        input_frame_done <= 1'b0;
        input_y <= 11'd0;
        capture_bank <= selected_write_bank;
        next_write_bank <= ~selected_write_bank;
        if (cfg_width == 1) begin
          capture_active <= 1'b0;
          input_x <= '0;
          input_pixels_left <= '0;
          if (cfg_height == 1) begin
            input_frame_active <= 1'b0;
            input_frame_done <= 1'b1;
          end else begin
            input_y <= 11'd1;
          end
        end else begin
          capture_active <= 1'b1;
          input_x <= 11'd1;
          input_pixels_left <= cfg_width[10:0] - 11'd1;
        end
      end else if (input_new_line_pixel) begin
        capture_bank <= selected_write_bank;
        next_write_bank <= ~selected_write_bank;
        if (in_width == 1) begin
          capture_active <= 1'b0;
          input_x <= '0;
          input_pixels_left <= '0;
          if (input_y == in_height-1'b1) begin
            input_frame_active <= 1'b0;
            input_frame_done <= 1'b1;
          end else begin
            input_y <= input_y + 1'b1;
          end
        end else begin
          capture_active <= 1'b1;
          input_x <= 11'd1;
          input_pixels_left <= in_width - 11'd1;
        end
      end else if (input_capture_pixel) begin
        if (s_axis_tlast) begin
          capture_active <= 1'b0;
          input_x <= '0;
          input_pixels_left <= '0;
          if (input_y == in_height-1'b1) begin
            input_frame_active <= 1'b0;
            input_frame_done <= 1'b1;
          end else begin
            input_y <= input_y + 1'b1;
          end
        end else begin
          input_x <= input_x + 1'b1;
          input_pixels_left <= input_pixels_left - 11'd1;
        end
      end

      if (input_line_complete && (input_pixel_y == in_height-1'b1)) begin
        input_frame_active <= 1'b0;
        input_frame_done <= 1'b1;
      end
    end
  end

  // Row tags are written on completed, in-crop input lines. A tag on a bank
  // marked reusable remains harmless until that bank is selected and rewritten.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      line_y0 <= '0;
      line_y1 <= '0;
    end else if (input_line_complete &&
                 (input_pixel_y >= source_y_origin)) begin
      if (line_buf_wr_bank)
        line_y1 <= input_pixel_y;
      else
        line_y0 <= input_pixel_y;
    end
  end

  // Track reusable banks one cycle after source_y advances. The ready path
  // then consumes a registered flag instead of a wide source_y comparison.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      line_bank_reusable <= 2'b11;
      line_bank_release_pending <= 1'b0;
    end else begin
      line_bank_release_pending <= output_row_end && (state == ST_EMIT_ROW);
      if (cfg_bypass_1to1 || input_sof_abort || input_line_error ||
          (in_handshake && s_axis_tuser && cfg_invalid_geometry) ||
          input_first_pixel)
        line_bank_reusable <= 2'b11;
      if (line_bank_release_pending) begin
        if (line_valid[0] && (line_y0 < source_y))
          line_bank_reusable[0] <= 1'b1;
        if (line_valid[1] && (line_y1 < source_y))
          line_bank_reusable[1] <= 1'b1;
      end
      if (input_line_complete) begin
        if (line_buf_wr_bank)
          line_bank_reusable[1] <= (input_pixel_y < source_y_origin) ||
                                   (input_pixel_y < input_reuse_source_y);
        else
          line_bank_reusable[0] <= (input_pixel_y < source_y_origin) ||
                                   (input_pixel_y < input_reuse_source_y);
      end
    end
  end

  // Track the active horizontal window per row. The counter advances only
  // when an output beat is accepted, so backpressure freezes the window.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      active_x_window <= 1'b0;
      active_x_remaining <= '0;
    end else if ((state == ST_WAIT_LINE) && selected_line_valid) begin
      active_x_window <= (x_offset == 0);
      active_x_remaining <= active_width;
    end else if ((state == ST_EMIT_ROW) && m_axis_tvalid && m_axis_tready) begin
      if (active_x_window) begin
        if (active_x_remaining == 11'd1) begin
          active_x_window <= 1'b0;
          active_x_remaining <= '0;
        end else begin
          active_x_remaining <= active_x_remaining - 11'd1;
        end
      end else if ((x_offset != 0) && (emit_x == active_x_start_last)) begin
        active_x_window <= 1'b1;
        active_x_remaining <= active_width;
      end
    end
  end

  // Keep horizontal read state, vertical DDA state, and the input/state
  // machine in separate register groups. Input framing errors are local to
  // the capture path and do not gate output-coordinate registers.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      line_read_source_x <= '0;
      line_read_x_error <= '0;
      line_buf_read_current_x <= '0;
    end else if ((state == ST_WAIT_LINE) && selected_line_valid) begin
      line_read_source_x <= source_x_origin;
      line_read_x_error <= '0;
    end else if (line_buf_read_issue) begin
      line_read_source_x <= line_read_next_x;
      line_read_x_error <= line_read_next_error;
      line_buf_read_current_x <= line_buf_read_addr;
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      y_error_next_pending <= '0;
      y_increment_pending <= '0;
    end else if (state == ST_WAIT_LINE) begin
      y_error_next_pending <= y_error_next_calc;
      y_increment_pending <= y_increment_calc;
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      source_y <= '0;
      y_error <= '0;
    end else if (in_handshake && s_axis_tuser && !cfg_invalid_geometry) begin
      source_y <= cfg_source_y_origin;
      y_error <= '0;
    end else if (output_row_end && (state == ST_EMIT_ROW)) begin
      source_y <= source_y + y_increment_pending;
      y_error <= y_error_next_pending;
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state <= ST_WAIT_SOF;
      in_width <= '0; in_height <= '0;
      active_width <= '0; active_height <= '0;
      x_offset <= '0; y_offset <= '0; emit_x <= '0;
      active_x_start_last <= '0;
      out_y_total <= '0; active_y_count <= '0;
      pad_top_left <= '0; pad_bottom_left <= '0; top_emitted <= 1'b0;
      source_x_origin <= '0; source_y_origin <= '0;
      bypass_x_left <= '0; bypass_y_left <= '0;
      x_step <= '0; x_rem <= '0; y_step <= '0; y_rem <= '0;
      y_step_plus_one <= '0;
      output_read_bank <= 1'b0;
      output_frame_completed <= 1'b0;
      stream_synchronized <= 1'b0;
      frame_count <= '0; error_flags <= '0;
    end else begin
      if (clear_errors) error_flags <= '0;

      if (input_sof_abort) begin
        error_flags[2] <= 1'b1;
        state <= ST_WAIT_SOF;
        output_frame_completed <= 1'b0;
        emit_x <= '0; out_y_total <= '0; active_y_count <= '0;
      end else if (input_line_error) begin
        error_flags[1] <= 1'b1;
        state <= ST_DROP;
        output_frame_completed <= 1'b0;
        emit_x <= '0; out_y_total <= '0; active_y_count <= '0;
      end else begin
        case (state)
          ST_WAIT_SOF, ST_DROP: begin
            if ((state == ST_WAIT_SOF) && stream_synchronized &&
                in_handshake && !s_axis_tuser) begin
              error_flags[3] <= 1'b1;
            end
            if (in_handshake && s_axis_tuser) begin
              if (cfg_invalid_geometry) begin
                error_flags[0] <= 1'b1;
                state <= ST_DROP;
              end else begin
                stream_synchronized <= 1'b1;
                in_width <= cfg_width[10:0];
                in_height <= cfg_height[10:0];
                active_width <= cfg_active_width;
                active_height <= cfg_active_height;
                x_offset <= cfg_x_offset;
                active_x_start_last <= (cfg_x_offset == 0) ?
                                        11'd0 : cfg_x_offset - 11'd1;
                y_offset <= cfg_y_offset;
                pad_top_left <= cfg_y_offset;
                pad_bottom_left <= cfg_output_height - cfg_y_offset - cfg_active_height;
                top_emitted <= 1'b0;
                emit_x <= '0; out_y_total <= '0; active_y_count <= '0;
                source_x_origin <= cfg_source_x_origin;
                source_y_origin <= cfg_source_y_origin;
                x_step <= cfg_x_step; x_rem <= cfg_x_rem;
                y_step <= cfg_y_step; y_rem <= cfg_y_rem;
                y_step_plus_one <= cfg_y_step + 11'd1;
                output_frame_completed <= 1'b0;
                if (cfg_bypass_1to1) begin
                  if ((cfg_width == 1) && s_axis_tlast) begin
                    if (cfg_height == 1) begin
                      state <= ST_WAIT_SOF;
                      output_frame_completed <= 1'b1;
                      frame_count <= frame_count + 1'b1;
                    end else begin
                      bypass_x_left <= 11'd1;
                      bypass_y_left <= cfg_height - 1'b1;
                      state <= ST_BYPASS;
                    end
                  end else if (s_axis_tlast || (cfg_width == 1)) begin
                    error_flags[1] <= 1'b1;
                    state <= ST_DROP;
                  end else begin
                    bypass_x_left <= cfg_width - 1'b1;
                    bypass_y_left <= cfg_height;
                    state <= ST_BYPASS;
                  end
                end else begin
                  state <= ST_WAIT_LINE;
                end
              end
            end
          end

          ST_BYPASS: begin
            if (s_axis_tvalid && s_axis_tuser) begin
              error_flags[2] <= 1'b1;
              state <= ST_WAIT_SOF;
              output_frame_completed <= 1'b0;
              bypass_x_left <= '0;
              bypass_y_left <= '0;
            end else if (in_handshake) begin
              if (s_axis_tlast != (bypass_x_left == 11'd1)) begin
                error_flags[1] <= 1'b1;
                state <= ST_DROP;
              end else if (s_axis_tlast) begin
                if (bypass_y_left == 11'd1) begin
                  state <= ST_WAIT_SOF;
                  output_frame_completed <= 1'b1;
                  frame_count <= frame_count + 1'b1;
                  bypass_x_left <= '0;
                  bypass_y_left <= '0;
                end else begin
                  bypass_y_left <= bypass_y_left - 1'b1;
                  bypass_x_left <= in_width;
                end
              end else begin
                bypass_x_left <= bypass_x_left - 1'b1;
              end
            end
          end

          ST_WAIT_LINE: begin
            if (!top_emitted && (pad_top_left != 0)) begin
              emit_x <= '0;
              state <= ST_PAD_TOP;
              top_emitted <= 1'b1;
            end else if (selected_line_valid) begin
              output_read_bank <= selected_line_bank;
              emit_x <= '0;
              state <= ST_EMIT_ROW;
            end else if (input_frame_done && !input_frame_active) begin
              error_flags[3] <= 1'b1;
              if (pad_bottom_left == 0) begin
                state <= ST_WAIT_SOF;
                output_frame_completed <= 1'b1;
                frame_count <= frame_count + 1'b1;
              end else begin
                emit_x <= '0;
                state <= ST_PAD_BOTTOM;
              end
            end
          end

          ST_PAD_TOP: begin
            if (output_row_end) begin
              emit_x <= '0;
              out_y_total <= out_y_total + 1'b1;
              if (pad_top_left <= 1) begin
                pad_top_left <= '0;
                state <= ST_WAIT_LINE;
              end else begin
                pad_top_left <= pad_top_left - 1'b1;
              end
            end else if (m_axis_tvalid && m_axis_tready) begin
              emit_x <= emit_x + 1'b1;
            end
          end

          ST_EMIT_ROW: begin
            if (m_axis_tvalid && m_axis_tready) begin
              if (emit_x == cfg_output_width-1'b1) begin
                emit_x <= '0;
                out_y_total <= out_y_total + 1'b1;
                active_y_count <= active_y_count + 1'b1;
                if (active_y_count + 1 >= active_height) begin
                  if (pad_bottom_left == 0) begin
                    state <= ST_WAIT_SOF;
                    output_frame_completed <= 1'b1;
                    frame_count <= frame_count + 1'b1;
                  end else begin
                    state <= ST_PAD_BOTTOM;
                  end
                end else begin
                  state <= ST_WAIT_LINE;
                end
              end else begin
                emit_x <= emit_x + 1'b1;
              end
            end
          end

          ST_PAD_BOTTOM: begin
            if (output_row_end) begin
              emit_x <= '0;
              out_y_total <= out_y_total + 1'b1;
              if (pad_bottom_left <= 1) begin
                pad_bottom_left <= '0;
                state <= ST_WAIT_SOF;
                output_frame_completed <= 1'b1;
                frame_count <= frame_count + 1'b1;
              end else begin
                pad_bottom_left <= pad_bottom_left - 1'b1;
              end
            end else if (m_axis_tvalid && m_axis_tready) begin
              emit_x <= emit_x + 1'b1;
            end
          end

          default: state <= ST_WAIT_SOF;
        endcase
      end
    end
  end
endmodule


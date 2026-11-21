`timescale 1ns/1ps
// Internal RGB888 one-pixel-per-beat nearest-neighbor scaler.
// The top-level adapter repacks its RGB output into AMD AXI4-Stream Video RBG order.
// Geometry and DDA ratios are supplied by the host driver so this datapath
// has no variable divider in its pixel-clock critical path.
module axis_video_nn_scaler #(
  parameter int unsigned MAX_INPUT_WIDTH = 640,
  parameter int unsigned MAX_INPUT_HEIGHT = 480,
  parameter int unsigned OUTPUT_WIDTH = 640,
  parameter int unsigned OUTPUT_HEIGHT = 480,
  parameter int unsigned MAX_BUFFER_WIDTH = MAX_INPUT_WIDTH,
  parameter int unsigned MAX_BUFFER_HEIGHT = MAX_INPUT_HEIGHT,
  // 0 uses asynchronous distributed RAM; 1 uses synchronous block RAM.
  parameter int unsigned LINE_BUFFER_IMPLEMENTATION = 0
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
  typedef enum logic [3:0] {
    ST_WAIT_SOF, ST_CAPTURE, ST_LINE_READY, ST_PAD_TOP,
    ST_EMIT_ROW, ST_DRAIN, ST_PAD_BOTTOM, ST_DROP, ST_BYPASS
  } state_t;
  state_t state;
  logic line_buf_wr_en, cfg_invalid_geometry, cfg_bypass_1to1;
  logic cfg_invalid_geometry_comb, cfg_bypass_1to1_comb;
  logic [10:0] line_buf_wr_addr;
  logic line_buf_read_issue, line_buf_read_valid, line_buf_read_pop;
  logic [10:0] line_buf_read_addr;
  logic [23:0] line_buf_read_data;
  logic line_buf_pixel_needed;
  logic bypass_start, bypass_active_beat, bypass_beat;
  logic [10:0] in_width, in_height, cap_x, cap_y;
  logic [10:0] x_offset, y_offset, emit_x, out_y_total, active_y_count;
  logic [10:0] pad_top_left, pad_bottom_left;
  logic top_emitted;
  logic [10:0] source_x, source_y, source_x_origin;
  logic [10:0] x_step, x_rem, y_step, y_rem;
  logic [10:0] x_error, y_error;
  logic [11:0] x_error_sum, y_error_sum;
  logic [10:0] next_source_x, next_source_y;
  logic [10:0] next_y_error;
  logic in_handshake;

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

    bypass_start = ((state == ST_WAIT_SOF) || (state == ST_DROP)) &&
                   cfg_bypass_1to1 && !cfg_invalid_geometry &&
                   s_axis_tvalid && s_axis_tuser;
    bypass_active_beat = (state == ST_BYPASS) && !s_axis_tuser;
    bypass_beat = bypass_start || bypass_active_beat;

    s_axis_tready = 1'b0;
    case (state)
      ST_WAIT_SOF, ST_DROP:
        s_axis_tready = (cfg_bypass_1to1 && !cfg_invalid_geometry) ?
                        m_axis_tready : 1'b1;
      ST_CAPTURE, ST_DRAIN: s_axis_tready = !s_axis_tuser;
      ST_BYPASS: s_axis_tready = !s_axis_tuser && m_axis_tready;
      default: s_axis_tready = 1'b0;
    endcase
    in_handshake = s_axis_tvalid && s_axis_tready;

    x_error_sum = x_error + x_rem;
    if (x_error_sum >= active_width)
      next_source_x = source_x + x_step + 1'b1;
    else
      next_source_x = source_x + x_step;
    line_buf_pixel_needed = (state == ST_EMIT_ROW) &&
                            (emit_x >= x_offset) &&
                            (emit_x < (x_offset + active_width)) &&
                            (source_x < in_width);

    // The scaler only writes its one-line store in scaled mode.
    line_buf_wr_en = 1'b0;
    line_buf_wr_addr = '0;
    if (aresetn && in_handshake) begin
      if (((state == ST_WAIT_SOF) || (state == ST_DROP)) &&
          s_axis_tuser && !cfg_invalid_geometry && !cfg_bypass_1to1) begin
        line_buf_wr_en = 1'b1;
        line_buf_wr_addr = '0;
      end else if (state == ST_CAPTURE) begin
        line_buf_wr_en = 1'b1;
        line_buf_wr_addr = cap_x;
      end
    end

    m_axis_tvalid = (state == ST_PAD_TOP) ||
                    (state == ST_EMIT_ROW) ||
                    (state == ST_PAD_BOTTOM) ||
                    (bypass_beat && s_axis_tvalid);
    if ((LINE_BUFFER_IMPLEMENTATION == 1) && line_buf_pixel_needed)
      m_axis_tvalid = line_buf_read_valid;
    m_axis_tuser = m_axis_tvalid && (out_y_total == 0) && (emit_x == 0);
    m_axis_tlast = m_axis_tvalid && (emit_x == cfg_output_width-1'b1);
    m_axis_tdata = 24'd0;
    if (bypass_beat) begin
      m_axis_tdata = s_axis_tdata;
      m_axis_tuser = s_axis_tuser;
      m_axis_tlast = s_axis_tlast;
    end else if ((state == ST_EMIT_ROW) &&
                 (emit_x >= x_offset) &&
                 (emit_x < (x_offset + active_width)) &&
                 (source_x < in_width)) begin
      m_axis_tdata = line_buf_read_data;
    end

    line_buf_read_pop = line_buf_read_valid && m_axis_tvalid && m_axis_tready;
    line_buf_read_issue = 1'b0;
    line_buf_read_addr = source_x;
    if ((LINE_BUFFER_IMPLEMENTATION == 1) && (state == ST_EMIT_ROW)) begin
      if (line_buf_pixel_needed) begin
        if (!line_buf_read_valid) begin
          line_buf_read_issue = 1'b1;
          line_buf_read_addr = source_x;
        end else if (line_buf_read_pop) begin
          // Refill the read stage on the accepted beat to sustain one pixel
          // per cycle after its first active pixel.
          line_buf_read_issue = 1'b1;
          line_buf_read_addr = next_source_x;
        end
      end
    end

    y_error_sum = y_error + y_rem;
    if (y_error_sum >= active_height) begin
      next_source_y = source_y + y_step + 1'b1;
      next_y_error = y_error_sum - active_height;
    end else begin
      next_source_y = source_y + y_step;
      next_y_error = y_error_sum;
    end
    busy = (state != ST_WAIT_SOF) && (state != ST_DROP);
  end

  generate
    if (LINE_BUFFER_IMPLEMENTATION == 0) begin : gen_lutram_line_buffer
      (* ram_style = "distributed" *) logic [23:0] line_buf [0:MAX_BUFFER_WIDTH-1];
      assign line_buf_read_data = line_buf[source_x];
      assign line_buf_read_valid = 1'b1;
      always_ff @(posedge aclk) begin
        if (line_buf_wr_en)
          line_buf[line_buf_wr_addr] <= s_axis_tdata;
      end
    end else begin : gen_bram_line_buffer
      (* ram_style = "block" *) logic [23:0] line_buf [0:MAX_BUFFER_WIDTH-1];
      logic [23:0] line_buf_read_data_reg;
      logic line_buf_read_valid_reg;
      assign line_buf_read_data = line_buf_read_data_reg;
      assign line_buf_read_valid = line_buf_read_valid_reg;
      always_ff @(posedge aclk) begin
        if (line_buf_wr_en)
          line_buf[line_buf_wr_addr] <= s_axis_tdata;
        if (!aresetn) begin
          line_buf_read_valid_reg <= 1'b0;
        end else if (line_buf_read_issue) begin
          line_buf_read_data_reg <= line_buf[line_buf_read_addr];
          line_buf_read_valid_reg <= 1'b1;
        end else if (line_buf_read_pop || (state != ST_EMIT_ROW)) begin
          line_buf_read_valid_reg <= 1'b0;
        end
      end
    end
  endgenerate

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state <= ST_WAIT_SOF;
      in_width <= '0; in_height <= '0; cap_x <= '0; cap_y <= '0;
      active_width <= '0; active_height <= '0;
      x_offset <= '0; y_offset <= '0; emit_x <= '0;
      out_y_total <= '0; active_y_count <= '0;
      pad_top_left <= '0; pad_bottom_left <= '0; top_emitted <= 1'b0;
      source_x <= '0; source_y <= '0; source_x_origin <= '0;
      x_step <= '0; x_rem <= '0; y_step <= '0; y_rem <= '0;
      x_error <= '0; y_error <= '0;
      frame_count <= '0; error_flags <= '0;
    end else begin
      if (clear_errors)
        error_flags <= '0;

      // Hold a newly observed SOF until the current malformed frame is aborted.
      if (((state == ST_CAPTURE) || (state == ST_DRAIN) || (state == ST_BYPASS)) &&
          s_axis_tvalid && s_axis_tuser) begin
        error_flags[2] <= 1'b1;
        state <= ST_WAIT_SOF;
        cap_x <= '0;
        cap_y <= '0;
      end else begin
        case (state)
          ST_WAIT_SOF, ST_DROP: begin
            if (in_handshake && s_axis_tuser) begin
              if (cfg_invalid_geometry) begin
                error_flags[0] <= 1'b1;
                state <= ST_DROP;
              end else begin
                in_width <= cfg_width[10:0];
                in_height <= cfg_height[10:0];
                active_width <= cfg_active_width;
                active_height <= cfg_active_height;
                x_offset <= cfg_x_offset;
                y_offset <= cfg_y_offset;
                pad_top_left <= cfg_y_offset;
                pad_bottom_left <= cfg_output_height - cfg_y_offset - cfg_active_height;
                top_emitted <= 1'b0;
                cap_x <= '0; cap_y <= '0;
                emit_x <= '0; out_y_total <= '0; active_y_count <= '0;
                source_x_origin <= cfg_source_x_origin;
                source_x <= cfg_source_x_origin;
                source_y <= cfg_source_y_origin;
                x_step <= cfg_x_step; x_rem <= cfg_x_rem;
                y_step <= cfg_y_step; y_rem <= cfg_y_rem;
                x_error <= '0; y_error <= '0;
                if (cfg_bypass_1to1) begin
                  if ((cfg_width == 1) && s_axis_tlast) begin
                    cap_x <= '0;
                    if (cfg_height == 1) begin
                      state <= ST_WAIT_SOF;
                      frame_count <= frame_count + 1'b1;
                    end else begin
                      cap_y <= 1;
                      state <= ST_BYPASS;
                    end
                  end else if (s_axis_tlast || (cfg_width == 1)) begin
                    error_flags[1] <= 1'b1;
                    state <= ST_DROP;
                  end else begin
                    cap_x <= 1;
                    state <= ST_BYPASS;
                  end
                end else if ((cfg_width == 1) && s_axis_tlast) begin
                  state <= ST_LINE_READY;
                end else if (s_axis_tlast || (cfg_width == 1)) begin
                  error_flags[1] <= 1'b1;
                  state <= ST_DROP;
                end else begin
                  cap_x <= 1;
                  state <= ST_CAPTURE;
                end
              end
            end
          end

          ST_BYPASS: begin
            if (in_handshake) begin
              if (s_axis_tlast) begin
                if (cap_x != in_width-1) begin
                  error_flags[1] <= 1'b1;
                  state <= ST_DROP;
                end else begin
                  cap_x <= '0;
                  if (cap_y == in_height-1) begin
                    state <= ST_WAIT_SOF;
                    frame_count <= frame_count + 1'b1;
                  end else begin
                    cap_y <= cap_y + 1'b1;
                  end
                end
              end else if (cap_x == in_width-1) begin
                error_flags[1] <= 1'b1;
                state <= ST_DROP;
              end else begin
                cap_x <= cap_x + 1'b1;
              end
            end
          end

          ST_CAPTURE: begin
            if (in_handshake) begin
              if (s_axis_tlast) begin
                if (cap_x != in_width-1) begin
                  error_flags[1] <= 1'b1;
                  state <= ST_DROP;
                end else begin
                  cap_x <= '0;
                  state <= ST_LINE_READY;
                end
              end else if (cap_x == in_width-1) begin
                error_flags[1] <= 1'b1;
                state <= ST_DROP;
              end else begin
                cap_x <= cap_x + 1'b1;
              end
            end
          end

          ST_LINE_READY: begin
            if (!top_emitted && (pad_top_left != 0)) begin
              emit_x <= '0;
              state <= ST_PAD_TOP;
              top_emitted <= 1'b1;
            end else if ((active_y_count < active_height) &&
                         (source_y == cap_y)) begin
              emit_x <= '0;
              source_x <= source_x_origin;
              x_error <= '0;
              state <= ST_EMIT_ROW;
            end else if (cap_y + 1 < in_height) begin
              cap_y <= cap_y + 1'b1;
              cap_x <= '0;
              state <= ST_CAPTURE;
            end else begin
              if (active_y_count < active_height)
                error_flags[3] <= 1'b1;
              if (pad_bottom_left == 0) begin
                state <= ST_WAIT_SOF;
                frame_count <= frame_count + 1'b1;
              end else begin
                emit_x <= '0;
                state <= ST_PAD_BOTTOM;
              end
            end
          end

          ST_PAD_TOP: begin
            if (m_axis_tvalid && m_axis_tready) begin
              if (emit_x == cfg_output_width-1'b1) begin
                emit_x <= '0;
                out_y_total <= out_y_total + 1'b1;
                if (pad_top_left <= 1) begin
                  pad_top_left <= '0;
                  state <= ST_LINE_READY;
                end else begin
                  pad_top_left <= pad_top_left - 1'b1;
                end
              end else begin
                emit_x <= emit_x + 1'b1;
              end
            end
          end

          ST_EMIT_ROW: begin
            if (m_axis_tvalid && m_axis_tready) begin
              if ((emit_x >= x_offset) && (emit_x < (x_offset + active_width))) begin
                if (x_error_sum >= active_width) begin
                  source_x <= source_x + x_step + 1'b1;
                  x_error <= x_error_sum - active_width;
                end else begin
                  source_x <= source_x + x_step;
                  x_error <= x_error_sum;
                end
              end

              if (emit_x == cfg_output_width-1'b1) begin
                emit_x <= '0;
                out_y_total <= out_y_total + 1'b1;
                active_y_count <= active_y_count + 1'b1;
                source_y <= next_source_y;
                y_error <= next_y_error;

                if (active_y_count + 1 >= active_height) begin
                  if (cap_y + 1 < in_height) begin
                    cap_y <= cap_y + 1'b1;
                    cap_x <= '0;
                    state <= ST_DRAIN;
                  end else if (pad_bottom_left == 0) begin
                    state <= ST_WAIT_SOF;
                    frame_count <= frame_count + 1'b1;
                  end else begin
                    state <= ST_PAD_BOTTOM;
                  end
                end else begin
                  // Decide whether to repeat this source row or capture the next
                  // one in ST_LINE_READY, outside the pixel-coordinate update path.
                  state <= ST_LINE_READY;
                end
              end else begin
                emit_x <= emit_x + 1'b1;
              end
            end
          end

          ST_DRAIN: begin
            if (in_handshake) begin
              if (s_axis_tlast) begin
                if (cap_x != in_width-1) begin
                  error_flags[1] <= 1'b1;
                  state <= ST_DROP;
                end else if (cap_y + 1 >= in_height) begin
                  cap_x <= '0;
                  if (pad_bottom_left == 0) begin
                    state <= ST_WAIT_SOF;
                    frame_count <= frame_count + 1'b1;
                  end else begin
                    emit_x <= '0;
                    state <= ST_PAD_BOTTOM;
                  end
                end else begin
                  cap_y <= cap_y + 1'b1;
                  cap_x <= '0;
                end
              end else if (cap_x == in_width-1) begin
                error_flags[1] <= 1'b1;
                state <= ST_DROP;
              end else begin
                cap_x <= cap_x + 1'b1;
              end
            end
          end

          ST_PAD_BOTTOM: begin
            if (m_axis_tvalid && m_axis_tready) begin
              if (emit_x == cfg_output_width-1'b1) begin
                emit_x <= '0;
                out_y_total <= out_y_total + 1'b1;
                if (pad_bottom_left <= 1) begin
                  pad_bottom_left <= '0;
                  state <= ST_WAIT_SOF;
                  frame_count <= frame_count + 1'b1;
                end else begin
                  pad_bottom_left <= pad_bottom_left - 1'b1;
                end
              end else begin
                emit_x <= emit_x + 1'b1;
              end
            end
          end

          default: state <= ST_WAIT_SOF;
        endcase
      end
    end
  end
endmodule

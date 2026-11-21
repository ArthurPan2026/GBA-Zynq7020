`timescale 1ns/1ps
module video_bram_rgb565_reader #(
  parameter int unsigned MAX_WIDTH = 640,
  parameter int unsigned MAX_HEIGHT = 480,
  parameter int unsigned BRAM_ADDR_WIDTH = 18
) (
  input logic aclk, input logic aresetn,
  input logic frame_start,
  input logic [31:0] frame_base_word,
  input logic [15:0] frame_width,
  input logic [15:0] frame_height,
  input logic [31:0] frame_stride_bytes,
  output logic bram_en,
  output logic [BRAM_ADDR_WIDTH-1:0] bram_addr,
  input logic [31:0] bram_dout,
  output logic [31:0] m_axis_tdata,
  output logic m_axis_tvalid,
  input logic m_axis_tready,
  output logic m_axis_tuser,
  output logic m_axis_tlast,
  output logic busy,
  output logic frame_done,
  input logic clear_errors,
  output logic [31:0] error_flags
);
  typedef enum logic [2:0] {ST_IDLE, ST_REQ, ST_WAIT, ST_LOW, ST_HIGH} state_t;
  state_t state;
  logic [BRAM_ADDR_WIDTH-1:0] row_base_word;
  logic [31:0] stride_words;
  logic [15:0] width;
  logic [15:0] height;
  logic [15:0] pixel_x;
  logic [15:0] pixel_y;
  logic [31:0] word_hold;

  function automatic logic [23:0] expand565(input logic [15:0] p);
    expand565 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
  endfunction

  always_comb begin
    bram_en = (state == ST_REQ);
    bram_addr = row_base_word + (pixel_x >> 1);
    m_axis_tvalid = (state == ST_LOW) || (state == ST_HIGH);
    m_axis_tdata = 32'd0;
    if (state == ST_LOW)
      m_axis_tdata = {8'd0, expand565(word_hold[15:0])};
    else if (state == ST_HIGH)
      m_axis_tdata = {8'd0, expand565(word_hold[31:16])};
    m_axis_tuser = m_axis_tvalid && (pixel_x == 0) && (pixel_y == 0);
    m_axis_tlast = m_axis_tvalid && (pixel_x == width-1);
    busy = (state != ST_IDLE);
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state <= ST_IDLE;
      row_base_word <= '0;
      stride_words <= '0;
      width <= '0;
      height <= '0;
      pixel_x <= '0;
      pixel_y <= '0;
      word_hold <= '0;
      frame_done <= 1'b0;
      error_flags <= '0;
    end else begin
      frame_done <= 1'b0;
      if (clear_errors)
        error_flags <= '0;

      case (state)
        ST_IDLE: begin
          if (frame_start) begin
            if ((frame_width == 0) || (frame_height == 0) ||
                (frame_width > MAX_WIDTH) || (frame_height > MAX_HEIGHT) ||
                (frame_stride_bytes < (frame_width * 2)) ||
                (frame_stride_bytes[1:0] != 2'b00)) begin
              error_flags[0] <= 1'b1;
            end else begin
              row_base_word <= frame_base_word[BRAM_ADDR_WIDTH-1:0];
              stride_words <= frame_stride_bytes >> 2;
              width <= frame_width;
              height <= frame_height;
              pixel_x <= '0;
              pixel_y <= '0;
              state <= ST_REQ;
            end
          end
        end
        ST_REQ: state <= ST_WAIT;
        ST_WAIT: begin
          word_hold <= bram_dout;
          state <= ST_LOW;
        end
        ST_LOW: begin
          if (m_axis_tvalid && m_axis_tready) begin
            if (pixel_x == width-1) begin
              if (pixel_y == height-1) begin
                frame_done <= 1'b1;
                state <= ST_IDLE;
              end else begin
                pixel_y <= pixel_y + 1'b1;
                row_base_word <= row_base_word + stride_words[BRAM_ADDR_WIDTH-1:0];
                pixel_x <= '0;
                state <= ST_REQ;
              end
            end else if (!pixel_x[0]) begin
              pixel_x <= pixel_x + 1'b1;
              state <= ST_HIGH;
            end else begin
              pixel_x <= pixel_x + 1'b1;
              state <= ST_REQ;
            end
          end
        end
        ST_HIGH: begin
          if (m_axis_tvalid && m_axis_tready) begin
            if (pixel_x == width-1) begin
              if (pixel_y == height-1) begin
                frame_done <= 1'b1;
                state <= ST_IDLE;
              end else begin
                pixel_y <= pixel_y + 1'b1;
                row_base_word <= row_base_word + stride_words[BRAM_ADDR_WIDTH-1:0];
                pixel_x <= '0;
                state <= ST_REQ;
              end
            end else begin
              pixel_x <= pixel_x + 1'b1;
              state <= ST_REQ;
            end
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule

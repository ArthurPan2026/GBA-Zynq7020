`timescale 1ns/1ps

// GBA PCM adapter: left-align signed 16-bit I2S samples in 24-bit HDMI LPCM words.
// FIFO 满时丢弃新样本并锁存溢出状态；输出端始终满足 TVALID/TDATA 背压稳定规则。
module gba_pcm_audio_axis #(
  parameter integer FIFO_DEPTH = 16,
  parameter integer FIFO_ADDR_WIDTH = 4
) (
  input  wire        clk_100,
  input  wire        rst_n,
  input  wire        sample_ce,
  input  wire [15:0] sample_left,
  input  wire [15:0] sample_right,
  output wire [47:0] m_axis_tdata,
  output wire        m_axis_tvalid,
  input  wire        m_axis_tready,
  output reg         overflow_sticky
);
  reg [47:0] fifo_mem [0:FIFO_DEPTH-1];
  reg [FIFO_ADDR_WIDTH-1:0] wr_ptr;
  reg [FIFO_ADDR_WIDTH-1:0] rd_ptr;
  reg [FIFO_ADDR_WIDTH:0] count;
  wire pop_sample = m_axis_tvalid && m_axis_tready;
  wire fifo_has_space = (count < FIFO_DEPTH) || pop_sample;
  wire push_sample = sample_ce && fifo_has_space;

  assign m_axis_tvalid = (count != 0);
  assign m_axis_tdata = fifo_mem[rd_ptr];

  always @(posedge clk_100) begin
    if (!rst_n) begin
      wr_ptr <= {FIFO_ADDR_WIDTH{1'b0}};
      rd_ptr <= {FIFO_ADDR_WIDTH{1'b0}};
      count <= {(FIFO_ADDR_WIDTH + 1){1'b0}};
      overflow_sticky <= 1'b0;
    end else begin
      if (sample_ce && !fifo_has_space)
        overflow_sticky <= 1'b1;

      if (push_sample) begin
        // HDMI announces 24-bit LPCM, so preserve 16-bit full-scale in the upper bits.
        fifo_mem[wr_ptr] <= {sample_right, 8'h00,
                             sample_left, 8'h00};
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (pop_sample)
        rd_ptr <= rd_ptr + 1'b1;

      case ({push_sample, pop_sample})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule

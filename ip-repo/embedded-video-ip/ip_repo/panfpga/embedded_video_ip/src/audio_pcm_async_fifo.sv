`timescale 1ns/1ps
// 双时钟 AXI-Stream PCM FIFO；Gray 指针跨域，clear 在各自本地时钟域同步执行。
module audio_pcm_async_fifo #(
  parameter int DATA_WIDTH = 32,
  parameter int ADDR_WIDTH = 4
) (
  input  logic                  wr_clk,
  input  logic                  wr_resetn,
  input  logic                  wr_clear,
  input  logic [DATA_WIDTH-1:0] wr_data,
  input  logic                  wr_valid,
  output logic                  wr_ready,
  output logic                  wr_full,
  output logic [ADDR_WIDTH:0]    wr_level,

  input  logic                  rd_clk,
  input  logic                  rd_resetn,
  input  logic                  rd_clear,
  output logic [DATA_WIDTH-1:0] rd_data,
  output logic                  rd_valid,
  input  logic                  rd_ready,
  output logic                  rd_empty,
  output logic [ADDR_WIDTH:0]    rd_level
);
  localparam int PTR_WIDTH = ADDR_WIDTH + 1;
  localparam int DEPTH = 1 << ADDR_WIDTH;

  (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_WIDTH-1:0] wr_bin, rd_bin;
  // Keep registered Gray pointers as the CDC source; recomputing Gray from the
  // binary counter after synthesis can reintroduce multi-bit combinational skew.
  (* DONT_TOUCH = "TRUE" *) logic [PTR_WIDTH-1:0] wr_gray, rd_gray;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [PTR_WIDTH-1:0] rd_gray_wsync1, rd_gray_wsync2;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [PTR_WIDTH-1:0] wr_gray_rsync1, wr_gray_rsync2;
  logic [PTR_WIDTH-1:0] wr_bin_next, wr_gray_next;
  logic [PTR_WIDTH-1:0] rd_bin_next, rd_gray_next;
  logic wr_full_next, rd_empty_next;
  logic [PTR_WIDTH-1:0] rd_bin_sync, wr_bin_sync;
  logic wr_fire, rd_fire;

  function automatic logic [PTR_WIDTH-1:0] bin_to_gray(input logic [PTR_WIDTH-1:0] value);
    bin_to_gray = (value >> 1) ^ value;
  endfunction

  function automatic logic [PTR_WIDTH-1:0] gray_to_bin(input logic [PTR_WIDTH-1:0] value);
    logic [PTR_WIDTH-1:0] result;
    integer bit_index;
    begin
      result[PTR_WIDTH-1] = value[PTR_WIDTH-1];
      for (bit_index=PTR_WIDTH-2; bit_index>=0; bit_index=bit_index-1)
        result[bit_index] = result[bit_index+1] ^ value[bit_index];
      gray_to_bin = result;
    end
  endfunction

  assign wr_ready = !wr_full;
  assign rd_valid = !rd_empty;
  assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];
  assign wr_fire = wr_valid && wr_ready;
  assign rd_fire = rd_ready && rd_valid;

  always_comb begin
    wr_bin_next = wr_bin + PTR_WIDTH'(wr_fire);
    wr_gray_next = bin_to_gray(wr_bin_next);
    rd_bin_next = rd_bin + PTR_WIDTH'(rd_fire);
    rd_gray_next = bin_to_gray(rd_bin_next);
    // 写指针领先读指针一圈时为满，因此比较值需翻转Gray码的最高两位。
    wr_full_next = (wr_gray_next ==
      {~rd_gray_wsync2[PTR_WIDTH-1:PTR_WIDTH-2], rd_gray_wsync2[PTR_WIDTH-3:0]});
    rd_empty_next = (rd_gray_next == wr_gray_rsync2);
    rd_bin_sync = gray_to_bin(rd_gray_wsync2);
    wr_bin_sync = gray_to_bin(wr_gray_rsync2);
    wr_level = wr_bin - rd_bin_sync;
    rd_level = wr_bin_sync - rd_bin;
  end

  // Keep the RAM write port free of asynchronous-reset logic so Vivado can
  // infer distributed memory. Pointer reset/clear makes old entries unreachable.
  always_ff @(posedge wr_clk) begin
    if (wr_resetn && !wr_clear && wr_fire)
      mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
  end

  always_ff @(posedge wr_clk or negedge wr_resetn) begin
    if (!wr_resetn) begin
      wr_bin <= '0;
      wr_gray <= '0;
      wr_full <= 1'b0;
    end else if (wr_clear) begin
      wr_bin <= '0;
      wr_gray <= '0;
      wr_full <= 1'b0;
    end else begin
      wr_bin <= wr_bin_next;
      wr_gray <= wr_gray_next;
      wr_full <= wr_full_next;
    end
  end

  always_ff @(posedge rd_clk or negedge rd_resetn) begin
    if (!rd_resetn) begin
      rd_bin <= '0;
      rd_gray <= '0;
      rd_empty <= 1'b1;
    end else if (rd_clear) begin
      rd_bin <= '0;
      rd_gray <= '0;
      rd_empty <= 1'b1;
    end else begin
      rd_bin <= rd_bin_next;
      rd_gray <= rd_gray_next;
      rd_empty <= rd_empty_next;
    end
  end

  always_ff @(posedge wr_clk or negedge wr_resetn) begin
    if (!wr_resetn) begin
      rd_gray_wsync1 <= '0;
      rd_gray_wsync2 <= '0;
    end else if (wr_clear) begin
      rd_gray_wsync1 <= '0;
      rd_gray_wsync2 <= '0;
    end else begin
      rd_gray_wsync1 <= rd_gray;
      rd_gray_wsync2 <= rd_gray_wsync1;
    end
  end

  always_ff @(posedge rd_clk or negedge rd_resetn) begin
    if (!rd_resetn) begin
      wr_gray_rsync1 <= '0;
      wr_gray_rsync2 <= '0;
    end else if (rd_clear) begin
      wr_gray_rsync1 <= '0;
      wr_gray_rsync2 <= '0;
    end else begin
      wr_gray_rsync1 <= wr_gray;
      wr_gray_rsync2 <= wr_gray_rsync1;
    end
  end
endmodule

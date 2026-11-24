`timescale 1ns/1ps
// 固定640x480时序的水平消隐调度器，活动区和垂直消隐区逐行执行。
module hdmi_line_slot_scheduler #(
  parameter integer VIDEO_LOOKAHEAD_CYCLES = 10,
  parameter integer H_COUNT_WIDTH = 32
) (
  input  logic        pixel_clk,
  input  logic        aresetn,
  input  logic [H_COUNT_WIDTH-1:0] h_total,
  input  logic [H_COUNT_WIDTH-1:0] h_active_size,
  input  logic [H_COUNT_WIDTH-1:0] h_sync_start,
  input  logic        hsync_active_level,
  input  logic       hdmi_mode_request,
  input  logic       video_profile_valid,
  output logic       hdmi_mode_active,
  input  logic       packet_active,
  input  logic       video_de_lookahead,
  input  logic       video_de_delayed,
  input  logic       hsync_delayed,
  input  logic       packet_loaded,
  input  logic       packet_offer,
  input  logic       packet_cancel,
  output logic       line_prepare,
  output logic [2:0] symbol_mode,
  output logic       packet_start
);
  localparam logic [2:0] MODE_CONTROL         = 3'd0;
  localparam logic [2:0] MODE_VIDEO           = 3'd1;
  localparam logic [2:0] MODE_VIDEO_PREAMBLE  = 3'd2;
  localparam logic [2:0] MODE_DATA_PREAMBLE   = 3'd3;
  localparam logic [2:0] MODE_VIDEO_GUARD     = 3'd4;
  localparam logic [2:0] MODE_DATA_GUARD      = 3'd5;
  localparam logic [2:0] MODE_DATA_PAYLOAD    = 3'd6;
  localparam integer PREAMBLE_CYCLES = 8;
  localparam integer GUARD_CYCLES = 2;
  localparam integer PACKET_CYCLES = 32;
  localparam integer DATA_ISLAND_CYCLES = PREAMBLE_CYCLES + GUARD_CYCLES +
                                           PACKET_CYCLES + GUARD_CYCLES;
  // This VIC 1 profile leaves control symbols between islands and video periods;
  // the line-slot bench checks the HDMI 1.4b 32-character extended-control minimum.
  localparam integer CONTROL_BEFORE_ISLAND = 12;
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_ONE = H_COUNT_WIDTH'(1);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_TWENTY = H_COUNT_WIDTH'(20);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_CONTROL_BEFORE_ISLAND =
      H_COUNT_WIDTH'(CONTROL_BEFORE_ISLAND);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_PREAMBLE_CYCLES =
      H_COUNT_WIDTH'(PREAMBLE_CYCLES);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_GUARD_CYCLES =
      H_COUNT_WIDTH'(GUARD_CYCLES);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_PACKET_CYCLES =
      H_COUNT_WIDTH'(PACKET_CYCLES);
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_DATA_ISLAND_CYCLES =
      H_COUNT_PREAMBLE_CYCLES + H_COUNT_GUARD_CYCLES +
      H_COUNT_PACKET_CYCLES + H_COUNT_GUARD_CYCLES;
  localparam logic [H_COUNT_WIDTH-1:0] H_COUNT_PACKET_START_OFFSET =
      H_COUNT_PREAMBLE_CYCLES + H_COUNT_GUARD_CYCLES - H_COUNT_ONE;
  logic [H_COUNT_WIDTH-1:0] island_start;
  logic [H_COUNT_WIDTH-1:0] island_end;
  logic [H_COUNT_WIDTH-1:0] prepare_x;
  logic timing_locked;
  logic [H_COUNT_WIDTH-1:0] x_count;
  logic lookahead_de_q;
  logic [3:0] video_preamble_count;
  logic island_available;
  logic hsync_active;
  logic hsync_active_q;
  logic hsync_active_rise;
  logic lookahead_de_rise;
  (* ASYNC_REG = "TRUE" *) logic hdmi_mode_meta, hdmi_mode_sync;

  always_comb begin
    island_start = h_sync_start + H_COUNT_CONTROL_BEFORE_ISLAND;
    island_end = island_start + H_COUNT_DATA_ISLAND_CYCLES;
  end

  // The profile width is stable while video reset is held. Register its
  // horizontal prepare coordinate so the live line-slot path avoids a
  // profile-width subtract before the packet scheduler.
  always_ff @(posedge pixel_clk or negedge aresetn) begin
    if (!aresetn)
      prepare_x <= '0;
    else if (h_active_size >= H_COUNT_TWENTY)
      prepare_x <= h_active_size - H_COUNT_TWENTY;
    else
      prepare_x <= '0;
  end

  assign hsync_active = (hsync_delayed == hsync_active_level);
  assign hsync_active_rise = hsync_active && !hsync_active_q;
  assign lookahead_de_rise = video_de_lookahead && !lookahead_de_q;
  assign island_available = hdmi_mode_active && !packet_cancel &&
                            (packet_loaded || packet_offer);
  assign line_prepare = timing_locked && (h_total != '0) && (x_count == prepare_x);

  // HSync每行同步一次计数器；同一行既能处理活动区，也能处理VBlank。
  always_ff @(posedge pixel_clk or negedge aresetn) begin
    if (!aresetn) begin
      hsync_active_q <= 1'b0;
      hdmi_mode_meta <= 1'b0;
      hdmi_mode_sync <= 1'b0;
      hdmi_mode_active <= 1'b0; // DVI-safe until the consumer confirms an HDMI VSDB.
      timing_locked <= 1'b0;
      x_count <= '0;
      lookahead_de_q <= 1'b0;
      video_preamble_count <= 4'd0;
    end else begin
      hsync_active_q <= hsync_active;
      hdmi_mode_meta <= hdmi_mode_request;
      hdmi_mode_sync <= hdmi_mode_meta;
      lookahead_de_q <= video_de_lookahead;

      // DVI-safe reset mode persists through the first active line. The delayed
      // HSync edge is inside horizontal blanking; switch there only with no packet
      // in flight so the next active line uses one complete framing mode.
      if (hsync_active_rise && !packet_active && !packet_loaded)
        hdmi_mode_active <= hdmi_mode_sync && video_profile_valid;

      if (hsync_active_rise) begin
        x_count <= h_sync_start;
        timing_locked <= 1'b1;
      end else if ((h_total == '0) || (x_count >= h_total - H_COUNT_ONE)) begin
        x_count <= '0;
      end else begin
        x_count <= x_count + 1'b1;
      end

      if (lookahead_de_rise)
        video_preamble_count <= 4'd1;
      else if (video_preamble_count != 4'd0 &&
               video_preamble_count < VIDEO_LOOKAHEAD_CYCLES)
        video_preamble_count <= video_preamble_count + 1'b1;
      else
        video_preamble_count <= 4'd0;
    end
  end

  always_comb begin
    symbol_mode = MODE_CONTROL;
    packet_start = 1'b0;

    if (!hdmi_mode_active) begin
      // DVI 1.0 compatibility: active video and control periods only.
      if (video_de_delayed)
        symbol_mode = MODE_VIDEO;
    end else begin
      // 让模式管线和延迟后的DE/编码器首符号按同一边沿对齐。
      // 上升沿当拍计数器只置1；下一拍开始输出8拍前导，再输出2拍保护带。
      if (video_preamble_count >= 4'd1 &&
          video_preamble_count <= PREAMBLE_CYCLES) begin
        symbol_mode = MODE_VIDEO_PREAMBLE;
      end else if (video_preamble_count > PREAMBLE_CYCLES &&
                   video_preamble_count <= VIDEO_LOOKAHEAD_CYCLES) begin
        symbol_mode = MODE_VIDEO_GUARD;
      end else if (video_de_delayed) begin
        symbol_mode = MODE_VIDEO;
      end else if (timing_locked && island_available &&
                   x_count >= island_start && x_count < island_end) begin
        if (x_count < island_start + H_COUNT_PREAMBLE_CYCLES)
          symbol_mode = MODE_DATA_PREAMBLE;
        else if (x_count < island_start + H_COUNT_PREAMBLE_CYCLES + H_COUNT_GUARD_CYCLES ||
                 x_count >= island_start + H_COUNT_PREAMBLE_CYCLES +
                            H_COUNT_GUARD_CYCLES + H_COUNT_PACKET_CYCLES)
          symbol_mode = MODE_DATA_GUARD;
        else
          symbol_mode = MODE_DATA_PAYLOAD;

        if (x_count == island_start + H_COUNT_PACKET_START_OFFSET &&
            packet_loaded && !packet_cancel)
          packet_start = 1'b1;
      end
    end
  end

  initial begin
    if (VIDEO_LOOKAHEAD_CYCLES != PREAMBLE_CYCLES + GUARD_CYCLES)
      $error("VIDEO_LOOKAHEAD_CYCLES must equal the 8-cycle preamble plus 2-cycle guard");
  end
endmodule

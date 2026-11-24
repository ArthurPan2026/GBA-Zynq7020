`timescale 1ns/1ps
// One-pixel-per-clock progressive timing source for CTA/VESA modes 0..3.
// timing_profile is synchronized into pixel_clk; each accepted change restarts
// the raster at coordinate (0,0) while resetn is expected to be held by the caller.
module hdmi_video_timing_gen #(
  parameter int unsigned VGA_H_TOTAL = 800,
  parameter int unsigned VGA_H_ACTIVE = 640,
  parameter int unsigned VGA_H_FRONT = 16,
  parameter int unsigned VGA_H_SYNC = 96,
  parameter int unsigned VGA_V_TOTAL = 525,
  parameter int unsigned VGA_V_ACTIVE = 480,
  parameter int unsigned VGA_V_FRONT = 10,
  parameter int unsigned VGA_V_SYNC = 2,
  parameter bit VGA_HSYNC_ACTIVE_HIGH = 1'b0,
  parameter bit VGA_VSYNC_ACTIVE_HIGH = 1'b0,

  parameter int unsigned HD720_H_TOTAL = 1650,
  parameter int unsigned HD720_H_ACTIVE = 1280,
  parameter int unsigned HD720_H_FRONT = 110,
  parameter int unsigned HD720_H_SYNC = 40,
  parameter int unsigned HD720_V_TOTAL = 750,
  parameter int unsigned HD720_V_ACTIVE = 720,
  parameter int unsigned HD720_V_FRONT = 5,
  parameter int unsigned HD720_V_SYNC = 5,
  parameter bit HD720_HSYNC_ACTIVE_HIGH = 1'b1,
  parameter bit HD720_VSYNC_ACTIVE_HIGH = 1'b1,

  parameter int unsigned HD1080_H_TOTAL = 2200,
  parameter int unsigned HD1080_H_ACTIVE = 1920,
  parameter int unsigned HD1080_H_FRONT = 88,
  parameter int unsigned HD1080_H_SYNC = 44,
  parameter int unsigned HD1080_V_TOTAL = 1125,
  parameter int unsigned HD1080_V_ACTIVE = 1080,
  parameter int unsigned HD1080_V_FRONT = 4,
  parameter int unsigned HD1080_V_SYNC = 5,
  parameter bit HD1080_HSYNC_ACTIVE_HIGH = 1'b1,
  parameter bit HD1080_VSYNC_ACTIVE_HIGH = 1'b1
) (
  input  logic       pixel_clk,
  input  logic       resetn,
  input  logic       enable,
  input  logic [1:0] timing_profile,

  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing ACTIVE_VIDEO" *)
  (* X_INTERFACE_MODE = "Master" *)
  output logic ACTIVE_VIDEO,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HBLANK" *)
  output logic HBLANK,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VBLANK" *)
  output logic VBLANK,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HSYNC" *)
  output logic HSYNC,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VSYNC" *)
  output logic VSYNC,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing FIELD" *)
  output logic FIELD
);
  localparam int unsigned VGA_H_BACK =
      VGA_H_TOTAL - VGA_H_ACTIVE - VGA_H_FRONT - VGA_H_SYNC;
  localparam int unsigned VGA_V_BACK =
      VGA_V_TOTAL - VGA_V_ACTIVE - VGA_V_FRONT - VGA_V_SYNC;
  localparam int unsigned HD720_H_BACK =
      HD720_H_TOTAL - HD720_H_ACTIVE - HD720_H_FRONT - HD720_H_SYNC;
  localparam int unsigned HD720_V_BACK =
      HD720_V_TOTAL - HD720_V_ACTIVE - HD720_V_FRONT - HD720_V_SYNC;
  localparam int unsigned HD1080_H_BACK =
      HD1080_H_TOTAL - HD1080_H_ACTIVE - HD1080_H_FRONT - HD1080_H_SYNC;
  localparam int unsigned HD1080_V_BACK =
      HD1080_V_TOTAL - HD1080_V_ACTIVE - HD1080_V_FRONT - HD1080_V_SYNC;

  (* ASYNC_REG = "TRUE" *) logic [1:0] profile_meta;
  (* ASYNC_REG = "TRUE" *) logic [1:0] profile_sync;
  logic [1:0] profile_active;
  logic [11:0] h_count;
  logic [11:0] v_count;

  logic profile_valid;
  logic [11:0] h_total_cfg;
  logic [11:0] h_active_cfg;
  logic [11:0] v_total_cfg;
  logic [11:0] v_active_cfg;
  logic hsync_active_high_cfg;
  logic vsync_active_high_cfg;
  logic hsync_pulse;
  logic vsync_pulse;

  always_comb begin
    profile_valid = 1'b1;
    h_total_cfg = 12'd1;
    h_active_cfg = 12'd0;
    v_total_cfg = 12'd1;
    v_active_cfg = 12'd0;
    hsync_active_high_cfg = 1'b0;
    vsync_active_high_cfg = 1'b0;

    case (profile_active)
      2'd0: begin
        h_total_cfg = 12'(VGA_H_TOTAL);
        h_active_cfg = 12'(VGA_H_ACTIVE);
        v_total_cfg = 12'(VGA_V_TOTAL);
        v_active_cfg = 12'(VGA_V_ACTIVE);
        hsync_active_high_cfg = VGA_HSYNC_ACTIVE_HIGH;
        vsync_active_high_cfg = VGA_VSYNC_ACTIVE_HIGH;
      end
      2'd1: begin
        h_total_cfg = 12'(HD720_H_TOTAL);
        h_active_cfg = 12'(HD720_H_ACTIVE);
        v_total_cfg = 12'(HD720_V_TOTAL);
        v_active_cfg = 12'(HD720_V_ACTIVE);
        hsync_active_high_cfg = HD720_HSYNC_ACTIVE_HIGH;
        vsync_active_high_cfg = HD720_VSYNC_ACTIVE_HIGH;
      end
      2'd2, 2'd3: begin
        h_total_cfg = 12'(HD1080_H_TOTAL);
        h_active_cfg = 12'(HD1080_H_ACTIVE);
        v_total_cfg = 12'(HD1080_V_TOTAL);
        v_active_cfg = 12'(HD1080_V_ACTIVE);
        hsync_active_high_cfg = HD1080_HSYNC_ACTIVE_HIGH;
        vsync_active_high_cfg = HD1080_VSYNC_ACTIVE_HIGH;
      end
      default: begin
        // Unknown profile holds a fully blank, static safe raster.
        profile_valid = 1'b0;
      end
    endcase
  end

  always_comb begin
    hsync_pulse = 1'b0;
    vsync_pulse = 1'b0;
    case (profile_active)
      2'd0: begin
        hsync_pulse = (h_count >= 12'(VGA_H_ACTIVE + VGA_H_FRONT)) &&
                      (h_count < 12'(VGA_H_ACTIVE + VGA_H_FRONT + VGA_H_SYNC));
        vsync_pulse = (v_count >= 12'(VGA_V_ACTIVE + VGA_V_FRONT)) &&
                      (v_count < 12'(VGA_V_ACTIVE + VGA_V_FRONT + VGA_V_SYNC));
      end
      2'd1: begin
        hsync_pulse = (h_count >= 12'(HD720_H_ACTIVE + HD720_H_FRONT)) &&
                      (h_count < 12'(HD720_H_ACTIVE + HD720_H_FRONT + HD720_H_SYNC));
        vsync_pulse = (v_count >= 12'(HD720_V_ACTIVE + HD720_V_FRONT)) &&
                      (v_count < 12'(HD720_V_ACTIVE + HD720_V_FRONT + HD720_V_SYNC));
      end
      2'd2, 2'd3: begin
        hsync_pulse = (h_count >= 12'(HD1080_H_ACTIVE + HD1080_H_FRONT)) &&
                      (h_count < 12'(HD1080_H_ACTIVE + HD1080_H_FRONT + HD1080_H_SYNC));
        vsync_pulse = (v_count >= 12'(HD1080_V_ACTIVE + HD1080_V_FRONT)) &&
                      (v_count < 12'(HD1080_V_ACTIVE + HD1080_V_FRONT + HD1080_V_SYNC));
      end
      default: begin end
    endcase

    ACTIVE_VIDEO = 1'b0;
    HBLANK = 1'b1;
    VBLANK = 1'b1;
    HSYNC = 1'b1;
    VSYNC = 1'b1;
    FIELD = 1'b0;

    if (resetn && profile_valid) begin
      ACTIVE_VIDEO = (h_count < h_active_cfg) && (v_count < v_active_cfg);
      HBLANK = (h_count >= h_active_cfg);
      VBLANK = (v_count >= v_active_cfg);
      HSYNC = hsync_pulse ? hsync_active_high_cfg : !hsync_active_high_cfg;
      VSYNC = vsync_pulse ? vsync_active_high_cfg : !vsync_active_high_cfg;
    end
  end

  always_ff @(posedge pixel_clk or negedge resetn) begin
    if (!resetn) begin
      profile_meta <= 2'd0;
      profile_sync <= 2'd0;
      profile_active <= 2'd0;
      h_count <= 12'd0;
      v_count <= 12'd0;
    end else begin
      profile_meta <= timing_profile;
      profile_sync <= profile_meta;

      if (profile_sync != profile_active) begin
        profile_active <= profile_sync;
        h_count <= 12'd0;
        v_count <= 12'd0;
      end else if (!profile_valid) begin
        h_count <= 12'd0;
        v_count <= 12'd0;
      end else if (enable) begin
        if (h_count == (h_total_cfg - 1'b1)) begin
          h_count <= 12'd0;
          if (v_count == (v_total_cfg - 1'b1))
            v_count <= 12'd0;
          else
            v_count <= v_count + 1'b1;
        end else begin
          h_count <= h_count + 1'b1;
        end
      end
    end
  end
endmodule

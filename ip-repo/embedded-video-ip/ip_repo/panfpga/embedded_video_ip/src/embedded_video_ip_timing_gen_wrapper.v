`timescale 1ns/1ps
module embedded_video_ip_timing_gen_wrapper (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.PIXEL_CLK CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PIXEL_CLK, FREQ_HZ 25178571, FREQ_TOLERANCE_HZ 0, PHASE 0.0" *)
  input wire pixel_clk,
  input wire resetn,
  input wire enable,
  input wire [1:0] timing_profile,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing ACTIVE_VIDEO" *)
  (* X_INTERFACE_MODE = "Master" *)
  output wire ACTIVE_VIDEO,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HBLANK" *)
  output wire HBLANK,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VBLANK" *)
  output wire VBLANK,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HSYNC" *)
  output wire HSYNC,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VSYNC" *)
  output wire VSYNC,
  (* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing FIELD" *)
  output wire FIELD,
  // Separate observation pin: connecting the bundled VSYNC member directly
  // to an external BD port can detach that member from the timing interface.
  output wire vsync_raw
);
  assign vsync_raw = VSYNC;
  hdmi_video_timing_gen u_video_timing_gen (
    .pixel_clk(pixel_clk), .resetn(resetn), .enable(enable), .timing_profile(timing_profile),
    .ACTIVE_VIDEO(ACTIVE_VIDEO), .HBLANK(HBLANK), .VBLANK(VBLANK),
    .HSYNC(HSYNC), .VSYNC(VSYNC), .FIELD(FIELD)
  );
endmodule

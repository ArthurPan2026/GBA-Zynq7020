`timescale 1ns/1ps
module embedded_video_ip_clock_profile_mux_wrapper (
  input wire clock_profile_sel,
  input wire vga_pixel_clk,
  input wire vga_serial_clk,
  input wire vga_locked,
  input wire hd_pixel_clk,
  input wire hd_serial_clk,
  input wire hd_locked,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.PIXEL_CLK CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PIXEL_CLK, FREQ_HZ 25178571, FREQ_TOLERANCE_HZ 0, PHASE 0.0" *)
  output wire pixel_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.SERIAL_CLK CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.SERIAL_CLK, FREQ_HZ 125892857, FREQ_TOLERANCE_HZ 0, PHASE 0.0" *)
  output wire serial_clk,
  output wire [1:0] locked_profiles,
  output wire selected_locked
);
  hdmi_clock_profile_mux u_clock_profile_mux (
    .clock_profile_sel(clock_profile_sel),
    .vga_pixel_clk(vga_pixel_clk), .vga_serial_clk(vga_serial_clk), .vga_locked(vga_locked),
    .hd_pixel_clk(hd_pixel_clk), .hd_serial_clk(hd_serial_clk), .hd_locked(hd_locked),
    .pixel_clk(pixel_clk), .serial_clk(serial_clk),
    .locked_profiles(locked_profiles), .selected_locked(selected_locked)
  );
endmodule

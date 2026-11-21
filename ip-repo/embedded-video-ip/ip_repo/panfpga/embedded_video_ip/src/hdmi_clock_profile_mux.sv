`timescale 1ns/1ps

// Glitch-free VGA/HD global-clock selector for a 7-series HDMI transmitter.
// The transition controller owns reset sequencing and waits for selected_locked
// before releasing pixel logic. Clock outputs are not gated by LOCKED.
module hdmi_clock_profile_mux (
  input  logic clock_profile_sel, // 0=VGA, 1=shared HD profile
  input  logic vga_pixel_clk,
  input  logic vga_serial_clk,
  input  logic vga_locked,
  input  logic hd_pixel_clk,
  input  logic hd_serial_clk,
  input  logic hd_locked,
  output wire  pixel_clk,
  output wire  serial_clk,
  output logic [1:0] locked_profiles, // [0]=VGA, [1]=HD
  output logic selected_locked
);
  logic [1:0] clock_select_onehot;

  // Decode to a fail-safe one-hot S0/S1 pair. BUFGCTRL's S pins provide the
  // asynchronous, glitch-free select path; CE pins remain asserted and IGNORE
  // remains deasserted. Unknown select values fall back to VGA.
  always_comb begin
    case (clock_profile_sel)
      1'b0: clock_select_onehot = 2'b01;
      1'b1: clock_select_onehot = 2'b10;
      default: clock_select_onehot = 2'b01;
    endcase
  end

  assign locked_profiles = {hd_locked, vga_locked};

  always_comb begin
    case (clock_profile_sel)
      1'b0: selected_locked = vga_locked;
      1'b1: selected_locked = hd_locked;
      default: selected_locked = vga_locked;
    endcase
  end

  BUFGCTRL #(.INIT_OUT(1'b0)) u_pixel_clock_profile_mux (
    .I0(vga_pixel_clk), .I1(hd_pixel_clk), .O(pixel_clk),
    .CE0(1'b1), .CE1(1'b1), .S0(clock_select_onehot[0]), .S1(clock_select_onehot[1]),
    .IGNORE0(1'b0), .IGNORE1(1'b0)
  );

  BUFGCTRL #(.INIT_OUT(1'b0)) u_serial_clock_profile_mux (
    .I0(vga_serial_clk), .I1(hd_serial_clk), .O(serial_clk),
    .CE0(1'b1), .CE1(1'b1), .S0(clock_select_onehot[0]), .S1(clock_select_onehot[1]),
    .IGNORE0(1'b0), .IGNORE1(1'b0)
  );
endmodule

`timescale 1ns/1ps
// HDMI 1.4b AVI InfoFrame with active VIC and static 8-bit RGB/YCbCr 4:4:4 color profile.
module hdmi_avi_infoframe #(
  parameter integer COLOR_MODE = 0,      // 0=RGB, 1=YCbCr 4:4:4
  parameter integer COLORIMETRY = 0,     // YCbCr: 0=BT.601, 1=BT.709
  parameter integer YCC_RANGE = 0        // YCbCr: 0=limited, 1=full
) (
  input  logic [7:0]  video_vic,
  output logic [23:0] header,
  output logic [55:0] subpacket [0:3]
);
  logic [7:0] payload [0:27];
  logic [7:0] checksum_sum;
  logic [1:0] picture_aspect_code;
  logic [1:0] colorimetry_code;
  integer i;

  always_comb begin
    // Header bytes are transmitted low byte first: HB0, HB1, HB2.
    header = {8'h0D, 8'h02, 8'h82};
    for (i = 0; i < 28; i = i + 1)
      payload[i] = 8'h00;
    case (video_vic)
      8'd1: picture_aspect_code = 2'b01; // 4:3
      8'd4, 8'd16, 8'd34: picture_aspect_code = 2'b10; // 16:9
      default: picture_aspect_code = 2'b00;
    endcase
    if (COLOR_MODE == 0) begin
      colorimetry_code = 2'b00;
      payload[1] = 8'h10; // RGB, A0=1, no bar/scan flags.
      payload[3] = 8'h08; // Full-range RGB.
    end else begin
      colorimetry_code = (COLORIMETRY == 0) ? 2'b01 : 2'b10;
      payload[1] = 8'h50; // YCbCr 4:4:4, A0=1, no bar/scan flags.
      payload[5] = (YCC_RANGE == 0) ? 8'h00 : 8'h40;
    end
    // PB2 picture aspect follows the active VIC; active-format aspect matches it.
    payload[2] = {colorimetry_code, picture_aspect_code, 4'b1000};
    // PB4: run-time VIC; pixel repetition is zero.
    payload[4] = video_vic;
    checksum_sum = header[7:0] + header[15:8] + header[23:16];
    for (i = 1; i < 13; i = i + 1)
      checksum_sum = checksum_sum + payload[i];
    payload[0] = -checksum_sum;
    for (i = 0; i < 4; i = i + 1)
      subpacket[i] = {payload[6 + i*7], payload[5 + i*7], payload[4 + i*7],
                      payload[3 + i*7], payload[2 + i*7], payload[1 + i*7],
                      payload[0 + i*7]};
  end

  initial begin
    if ((COLOR_MODE != 0) && (COLOR_MODE != 1))
      $fatal(1, "COLOR_MODE must be 0 (RGB) or 1 (YCbCr 4:4:4)");
    if ((COLORIMETRY != 0) && (COLORIMETRY != 1))
      $fatal(1, "COLORIMETRY must be 0 (BT.601) or 1 (BT.709)");
    if ((YCC_RANGE != 0) && (YCC_RANGE != 1))
      $fatal(1, "YCC_RANGE must be 0 (limited) or 1 (full)");
  end
endmodule

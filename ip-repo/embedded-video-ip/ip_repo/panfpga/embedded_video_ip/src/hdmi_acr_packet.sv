`timescale 1ns/1ps
// HDMI 1.4b Audio Clock Regeneration packet. Generic mode supports arbitrary
// pixel clocks; runtime video profiles select precomputed CTS constants.
module hdmi_acr_packet #(
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48_000,
  parameter integer ACR_N =
      (AUDIO_SAMPLE_RATE_HZ == 96_000) ? 12_288 :
      (AUDIO_SAMPLE_RATE_HZ == 192_000) ? 24_576 : 6_144,
  parameter bit USE_VIDEO_PROFILE_CLOCKS = 1'b0,
  parameter integer VGA_PROFILE_CLOCK_HZ = 25_178_571,
  parameter integer HD_PROFILE_CLOCK_HZ = 74_250_000
) (
  input  logic [31:0] pixel_clock_hz,
  input  logic [7:0]  video_vic,
  output logic [23:0] header,
  output logic [55:0] subpacket [0:3]
);
  localparam longint unsigned CTS_DENOM = 64'd128 * 64'(AUDIO_SAMPLE_RATE_HZ);
  localparam logic [19:0] N_VALUE = 20'(ACR_N);
  logic [19:0] cts_value;
  integer i;

  function automatic logic [19:0] calculate_cts(input logic [31:0] clock_hz);
    logic [63:0] numerator;
    begin
      numerator = (64'(clock_hz) * 64'(ACR_N)) + (CTS_DENOM / 2);
      if (CTS_DENOM == 0)
        calculate_cts = 20'd0;
      else
        calculate_cts = 20'(numerator / CTS_DENOM);
    end
  endfunction

  generate
    if (USE_VIDEO_PROFILE_CLOCKS) begin : g_static_profile_cts
      localparam logic [19:0] VGA_CTS = calculate_cts(32'(VGA_PROFILE_CLOCK_HZ));
      localparam logic [19:0] HD_CTS = calculate_cts(32'(HD_PROFILE_CLOCK_HZ));
      localparam logic [19:0] HD60_CTS = calculate_cts(32'd148500000);

      always_comb begin
        cts_value = 20'd0;
        case (video_vic)
          8'd1: cts_value = VGA_CTS;
          8'd4, 8'd34: cts_value = HD_CTS;
          8'd16: cts_value = HD60_CTS;
          default: cts_value = 20'd0;
        endcase
      end
    end else begin : g_generic_cts
      logic [63:0] numerator;
      always_comb begin
        numerator = (64'(pixel_clock_hz) * 64'(ACR_N)) + (CTS_DENOM / 2);
        if (CTS_DENOM == 0)
          cts_value = 20'd0;
        else
          cts_value = 20'(numerator / CTS_DENOM);
      end
    end
  endgenerate

  always_comb begin
    header = 24'h000001;
    for (i = 0; i < 4; i = i + 1)
      subpacket[i] = {N_VALUE[7:0], N_VALUE[15:8], {4'b0000, N_VALUE[19:16]},
                      cts_value[7:0], cts_value[15:8], {4'b0000, cts_value[19:16]},
                      8'h00};
  end

  initial begin
    if (AUDIO_SAMPLE_RATE_HZ != 48_000 &&
        AUDIO_SAMPLE_RATE_HZ != 96_000 &&
        AUDIO_SAMPLE_RATE_HZ != 192_000)
      $error("HDMI 1.4b 24-bit LPCM profile supports 48, 96, or 192 kHz");
    if (ACR_N <= 0 || ACR_N > 20'hFFFFF)
      $error("HDMI ACR requires a positive 20-bit N value");
  end
endmodule

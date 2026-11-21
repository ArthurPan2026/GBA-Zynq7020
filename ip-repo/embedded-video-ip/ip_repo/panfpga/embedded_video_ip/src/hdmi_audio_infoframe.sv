`timescale 1ns/1ps
// HDMI 1.4b two-channel LPCM Audio InfoFrame for a static 24-bit Fs profile.
module hdmi_audio_infoframe #(
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48_000,
  parameter integer AUDIO_SAMPLE_SIZE_BITS = 24
) (
  output logic [23:0] header,
  output logic [55:0] subpacket [0:3]
);
  logic [7:0] bytes [0:27];
  logic [2:0] sample_frequency_code;
  logic [1:0] sample_size_code;
  integer i;
  logic [7:0] checksum_sum;

  always_comb begin
    header = {8'h0A, 8'h01, 8'h84};
    case (AUDIO_SAMPLE_RATE_HZ)
      48_000:  sample_frequency_code = 3'd3;
      96_000:  sample_frequency_code = 3'd5;
      192_000: sample_frequency_code = 3'd7;
      default: sample_frequency_code = 3'd0;
    endcase
    case (AUDIO_SAMPLE_SIZE_BITS)
      16: sample_size_code = 2'd1;
      20: sample_size_code = 2'd2;
      24: sample_size_code = 2'd3;
      default: sample_size_code = 2'd0;
    endcase

    for (i = 0; i < 28; i = i + 1)
      bytes[i] = 8'h00;
    bytes[1] = 8'h01; // CC=1: two channels; CT=0: LPCM.
    bytes[2] = {4'b0000, sample_frequency_code, sample_size_code};
    bytes[3] = 8'h00;
    bytes[4] = 8'h00; // CA=0: front left/front right.
    bytes[5] = 8'h00;
    checksum_sum = header[7:0] + header[15:8] + header[23:16];
    for (i = 1; i <= 10; i = i + 1)
      checksum_sum = checksum_sum + bytes[i];
    bytes[0] = -checksum_sum;
    for (i = 0; i < 4; i = i + 1)
      subpacket[i] = {bytes[6 + i*7], bytes[5 + i*7], bytes[4 + i*7],
                      bytes[3 + i*7], bytes[2 + i*7], bytes[1 + i*7], bytes[0 + i*7]};
  end

  initial begin
    if (AUDIO_SAMPLE_RATE_HZ != 48_000 &&
        AUDIO_SAMPLE_RATE_HZ != 96_000 &&
        AUDIO_SAMPLE_RATE_HZ != 192_000)
      $error("HDMI 1.4b 24-bit LPCM profile supports 48, 96, or 192 kHz");
    if (AUDIO_SAMPLE_SIZE_BITS != 24)
      $error("This module is configured for 24-bit LPCM");
  end
endmodule

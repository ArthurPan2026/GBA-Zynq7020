`timescale 1ns/1ps
// HDMI 1.4b Layout 0 dual-channel 24-bit LPCM audio sample packet.
module hdmi_audio_sample_packet #(
  parameter integer AUDIO_SAMPLE_RATE_HZ = 48_000
) (
  input  logic [47:0] stereo_sample [0:3], // [23:0] left, [47:24] right, signed two's complement.
  input  logic [2:0]  sample_count,        // Range 0..4; only leading subpackets are present.
  input  logic [3:0]  sample_flat,         // 1 marks a sample period as flat.
  input  logic [7:0]  first_frame_index,   // IEC 60958 block frame index 0..191.
  output logic [23:0] header,
  output logic [55:0] subpacket [0:3]
);
  logic [7:0] hb0, hb1, hb2;
  logic [23:0] left_word [0:3];
  logic [23:0] right_word [0:3];
  logic [7:0] sb6 [0:3];
  logic [7:0] sample_index [0:3];
  logic block_start [0:3];
  logic c_left [0:3];
  logic c_right [0:3];
  logic p_left [0:3];
  logic p_right [0:3];
  integer i;

  function automatic logic channel_status_bit(input logic right_channel, input logic [7:0] index);
    logic [3:0] channel_number;
    begin
      channel_number = right_channel ? 4'd2 : 4'd1;
      case (index)
        8'd20: channel_status_bit = channel_number[0];
        8'd21: channel_status_bit = channel_number[1];
        8'd22: channel_status_bit = channel_number[2];
        8'd23: channel_status_bit = channel_number[3];
        // IEC 60958 consumer Fs: 48 kHz=0100, 96 kHz=0101, 192 kHz=0111.
        8'd25: channel_status_bit = 1'b1;
        8'd26: channel_status_bit = (AUDIO_SAMPLE_RATE_HZ == 192_000);
        8'd27: channel_status_bit = (AUDIO_SAMPLE_RATE_HZ >= 96_000);
        // 24-bit maximum word length and actual word length: channel-status bits 35:32=1011.
        8'd32: channel_status_bit = 1'b1;
        8'd33: channel_status_bit = 1'b1;
        8'd35: channel_status_bit = 1'b1;
        // Original Fs code, transmitted LSB first (48=1101, 96=0101, 192=0001).
        8'd36: channel_status_bit = 1'b1;
        8'd37: channel_status_bit = 1'b0;
        8'd38: channel_status_bit = (AUDIO_SAMPLE_RATE_HZ != 192_000);
        8'd39: channel_status_bit = (AUDIO_SAMPLE_RATE_HZ == 48_000);
        default: channel_status_bit = 1'b0;
      endcase
    end
  endfunction

  always_comb begin
    hb0 = 8'h02;
    hb1 = {3'b000, 1'b0, (sample_count >= 3'd4), (sample_count >= 3'd3),
           (sample_count >= 3'd2), (sample_count >= 3'd1)};
    hb2 = 8'h00;
    for (i = 0; i < 4; i = i + 1) begin
      sample_index[i] = first_frame_index + i[7:0];
      if (sample_index[i] >= 8'd192)
        sample_index[i] = sample_index[i] - 8'd192;
      block_start[i] = (sample_index[i] == 8'd0) && (sample_count > i);
      hb2[i] = (sample_count > i) && sample_flat[i];
      hb2[4+i] = block_start[i];
      left_word[i] = stereo_sample[i][23:0];
      right_word[i] = stereo_sample[i][47:24];
      c_left[i] = channel_status_bit(1'b0, sample_index[i]);
      c_right[i] = channel_status_bit(1'b1, sample_index[i]);
      // IEC 60958 sample bits plus V/U/C use even parity.
      p_left[i] = ^{left_word[i], c_left[i], 2'b00};
      p_right[i] = ^{right_word[i], c_right[i], 2'b00};
      sb6[i] = {p_right[i], c_right[i], 2'b00, p_left[i], c_left[i], 2'b00};
      subpacket[i] = {sb6[i], right_word[i], left_word[i]};
    end
    header = {hb2, hb1, hb0};
  end

  initial begin
    if (AUDIO_SAMPLE_RATE_HZ != 48_000 &&
        AUDIO_SAMPLE_RATE_HZ != 96_000 &&
        AUDIO_SAMPLE_RATE_HZ != 192_000)
      $error("HDMI 1.4b 24-bit LPCM profile supports 48, 96, or 192 kHz");
  end
endmodule

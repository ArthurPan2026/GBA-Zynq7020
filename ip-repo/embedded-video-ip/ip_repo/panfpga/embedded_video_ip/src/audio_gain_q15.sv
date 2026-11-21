`timescale 1ns/1ps
// Signed 24-bit PCM Q1.15 gain; legal gain is 0..32768, where 32768 is unity.
module audio_gain_q15 (
  input  logic signed [23:0] sample_in,
  input  logic        [16:0] gain_q15,
  input  logic               mute,
  output logic signed [23:0] sample_out
);
  logic signed [40:0] sample_ext;
  logic signed [40:0] gain_ext;
  logic signed [40:0] product;
  logic signed [40:0] scaled;
  logic [16:0] gain_limited;

  always_comb begin
    gain_limited = (gain_q15 > 17'd32768) ? 17'd32768 : gain_q15;
    sample_ext = {{17{sample_in[23]}}, sample_in};
    gain_ext = $signed({24'd0, gain_limited});
    product = sample_ext * gain_ext;
    // Arithmetic shift rounds negative products toward negative infinity.
    scaled = product >>> 15;
    if (mute || gain_limited == 17'd0)
      sample_out = 24'sd0;
    else if (scaled > 41'sd8388607)
      sample_out = 24'sh7fffff;
    else if (scaled < -41'sd8388608)
      sample_out = 24'sh800000;
    else
      sample_out = scaled[23:0];
  end
endmodule

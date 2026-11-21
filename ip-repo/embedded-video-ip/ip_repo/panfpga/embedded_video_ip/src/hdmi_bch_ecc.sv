`timescale 1ns/1ps
// HDMI 1.3 BCH校验，生成多项式G(x)=1+x^6+x^7+x^8，串行位序低位优先。
module hdmi_bch_ecc #(
  parameter int DATA_WIDTH = 24
) (
  input  logic [DATA_WIDTH-1:0] data_in,
  output logic [7:0] ecc_out
);
  function automatic logic [7:0] next_ecc(input logic [7:0] ecc, input logic data_bit);
    logic feedback;
    begin
      feedback = ecc[0] ^ data_bit;
      next_ecc = ecc >> 1;
      if (feedback)
        next_ecc = next_ecc ^ 8'h83;
    end
  endfunction
  integer i;
  logic [7:0] work;
  always_comb begin
    work = 8'h00;
    for (i = 0; i < DATA_WIDTH; i = i + 1)
      work = next_ecc(work, data_in[i]);
    ecc_out = work;
  end
endmodule

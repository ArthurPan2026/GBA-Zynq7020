`timescale 1ns/1ps
// HDMI 1.3 TERC4从4-bit数据到10-bit符号的映射表。
module hdmi_terc4_encoder (
  input  logic [3:0] nibble,
  output logic [9:0] symbol
);
  always_comb begin
    unique case (nibble)
      4'h0: symbol = 10'b1010011100;
      4'h1: symbol = 10'b1001100011;
      4'h2: symbol = 10'b1011100100;
      4'h3: symbol = 10'b1011100010;
      4'h4: symbol = 10'b0101110001;
      4'h5: symbol = 10'b0100011110;
      4'h6: symbol = 10'b0110001110;
      4'h7: symbol = 10'b0100111100;
      4'h8: symbol = 10'b1011001100;
      4'h9: symbol = 10'b0100111001;
      4'hA: symbol = 10'b0110011100;
      4'hB: symbol = 10'b1011000110;
      4'hC: symbol = 10'b1010001110;
      4'hD: symbol = 10'b1001110001;
      4'hE: symbol = 10'b0101100011;
      4'hF: symbol = 10'b1011000011;
      default: symbol = 10'b0000000000;
    endcase
  end
endmodule

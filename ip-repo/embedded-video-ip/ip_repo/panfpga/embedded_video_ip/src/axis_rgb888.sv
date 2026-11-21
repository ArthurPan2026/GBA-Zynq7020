`timescale 1ns/1ps
module axis_rgb888 (
  input logic [31:0] s_axis_tdata, input logic s_axis_tvalid,
  output logic s_axis_tready, input logic s_axis_tuser, input logic s_axis_tlast,
  input logic [1:0] format,
  output logic [23:0] m_axis_tdata, output logic m_axis_tvalid,
  input logic m_axis_tready, output logic m_axis_tuser, output logic m_axis_tlast
);
  always_comb begin
    case (format)
      2'd0: m_axis_tdata = {s_axis_tdata[15:11], s_axis_tdata[15:13],
                            s_axis_tdata[10:5], s_axis_tdata[10:9],
                            s_axis_tdata[4:0], s_axis_tdata[4:2]};
      2'd1: m_axis_tdata = {s_axis_tdata[23:16], s_axis_tdata[7:0], s_axis_tdata[15:8]}; // AXI4-Stream Video RGB uses RBG component packing
      2'd2: m_axis_tdata = s_axis_tdata[23:0]; // XRGB8888: low 24 bits are RGB
      2'd3: m_axis_tdata = {s_axis_tdata[15:8], s_axis_tdata[23:16],
                            s_axis_tdata[31:24]}; // BGRX8888
      default: m_axis_tdata = 24'd0;
    endcase
    s_axis_tready = m_axis_tready;
    m_axis_tvalid = s_axis_tvalid;
    m_axis_tuser = s_axis_tuser;
    m_axis_tlast = s_axis_tlast;
  end
endmodule

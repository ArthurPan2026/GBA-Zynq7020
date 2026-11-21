`timescale 1ns/1ps
module axis_video_mux3 (
  input logic [1:0] select,
  input logic [31:0] s0_tdata, input logic s0_tvalid, output logic s0_tready,
  input logic s0_tuser, input logic s0_tlast,
  input logic [31:0] s1_tdata, input logic s1_tvalid, output logic s1_tready,
  input logic s1_tuser, input logic s1_tlast,
  input logic [31:0] s2_tdata, input logic s2_tvalid, output logic s2_tready,
  input logic s2_tuser, input logic s2_tlast,
  output logic [31:0] m_tdata, output logic m_tvalid, input logic m_tready,
  output logic m_tuser, output logic m_tlast
);
  always_comb begin
    m_tdata = 32'd0; m_tvalid = 1'b0; m_tuser = 1'b0; m_tlast = 1'b0;
    s0_tready = 1'b0; s1_tready = 1'b0; s2_tready = 1'b0;
    case (select)
      2'd0: begin
        m_tdata=s0_tdata; m_tvalid=s0_tvalid; m_tuser=s0_tuser; m_tlast=s0_tlast; s0_tready=m_tready;
      end
      2'd1: begin
        m_tdata=s1_tdata; m_tvalid=s1_tvalid; m_tuser=s1_tuser; m_tlast=s1_tlast; s1_tready=m_tready;
      end
      2'd2: begin
        m_tdata=s2_tdata; m_tvalid=s2_tvalid; m_tuser=s2_tuser; m_tlast=s2_tlast; s2_tready=m_tready;
      end
      default: begin end
    endcase
  end
endmodule

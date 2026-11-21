`timescale 1ns/1ps
// HDMI Data Island packet serializer. Static audio-off profiles bypass the
// packet payload registers because their only packet is a constant AVI InfoFrame.
module hdmi_packet_assembler #(
  parameter bit STATIC_AVI_ONLY = 1'b0
) (
  input  logic        pixel_clk,
  input  logic        resetn,
  input  logic        packet_valid,
  output logic        packet_ready,
  input  logic        packet_cancel,
  input  logic        packet_cancel_link,
  input  logic        packet_start,
  output logic        packet_loaded,
  output logic        packet_loaded_avi,
  input  logic [23:0] packet_header,
  input  logic [55:0] packet_sub0,
  input  logic [55:0] packet_sub1,
  input  logic [55:0] packet_sub2,
  input  logic [55:0] packet_sub3,
  output logic        packet_active,
  output logic [8:0]  packet_data,
  output logic        packet_done
);
  logic [23:0] active_header;
  logic [55:0] active_sub [0:3];
  logic [7:0] header_ecc;
  logic [7:0] sub_ecc [0:3];
  logic [31:0] header_block;
  logic [63:0] bch_block [0:3];
  logic [4:0] pixel_index;
  logic [5:0] bit_even, bit_odd;
  integer i;

  assign packet_ready = !packet_loaded;
  // AVI InfoFrames remain legal while HDMI audio is disabled; callers may
  // defer an audio-only cancellation while one is already loaded.
  assign packet_loaded_avi = packet_loaded && (active_header[7:0] == 8'h82);

  hdmi_bch_ecc #(.DATA_WIDTH(24)) u_header_bch (.data_in(active_header), .ecc_out(header_ecc));
  hdmi_bch_ecc #(.DATA_WIDTH(56)) u_sub0_bch (.data_in(active_sub[0]), .ecc_out(sub_ecc[0]));
  hdmi_bch_ecc #(.DATA_WIDTH(56)) u_sub1_bch (.data_in(active_sub[1]), .ecc_out(sub_ecc[1]));
  hdmi_bch_ecc #(.DATA_WIDTH(56)) u_sub2_bch (.data_in(active_sub[2]), .ecc_out(sub_ecc[2]));
  hdmi_bch_ecc #(.DATA_WIDTH(56)) u_sub3_bch (.data_in(active_sub[3]), .ecc_out(sub_ecc[3]));

  always_comb begin
    header_block = {header_ecc, active_header};
    for (i=0; i<4; i=i+1)
      bch_block[i] = {sub_ecc[i], active_sub[i]};
    bit_even = {1'b0, pixel_index, 1'b0};
    bit_odd = bit_even + 1'b1;
    packet_data[8] = header_block[pixel_index];
    packet_data[3:0] = {bch_block[3][bit_even], bch_block[2][bit_even],
                        bch_block[1][bit_even], bch_block[0][bit_even]};
    packet_data[7:4] = {bch_block[3][bit_odd], bch_block[2][bit_odd],
                        bch_block[1][bit_odd], bch_block[0][bit_odd]};
  end

  generate if (STATIC_AVI_ONLY) begin : g_static_avi
    assign active_header = packet_header;
    assign active_sub[0] = packet_sub0;
    assign active_sub[1] = packet_sub1;
    assign active_sub[2] = packet_sub2;
    assign active_sub[3] = packet_sub3;

    always_ff @(posedge pixel_clk or negedge resetn) begin
      if (!resetn) begin
        pixel_index <= '0;
        packet_active <= 1'b0;
        packet_loaded <= 1'b0;
        packet_done <= 1'b0;
      end else begin
        packet_done <= 1'b0;
        if (packet_cancel_link && !packet_active) begin
          packet_loaded <= 1'b0;
          pixel_index <= 5'd0;
        end else if (packet_valid && packet_ready) begin
          pixel_index <= 5'd0;
          packet_loaded <= 1'b1;
        end else if (packet_start && packet_loaded && !packet_active) begin
          pixel_index <= 5'd0;
          packet_active <= 1'b1;
        end else if (packet_active) begin
          if (pixel_index == 5'd31) begin
            packet_active <= 1'b0;
            packet_loaded <= 1'b0;
            packet_done <= 1'b1;
            pixel_index <= 5'd0;
          end else begin
            pixel_index <= pixel_index + 1'b1;
          end
        end
      end
    end
  end else begin : g_dynamic_packets
    logic [23:0] header_q;
    logic [55:0] sub_q [0:3];
    assign active_header = header_q;
    assign active_sub[0] = sub_q[0];
    assign active_sub[1] = sub_q[1];
    assign active_sub[2] = sub_q[2];
    assign active_sub[3] = sub_q[3];

    always_ff @(posedge pixel_clk or negedge resetn) begin
      if (!resetn) begin
        header_q <= '0;
        sub_q[0] <= '0;
        sub_q[1] <= '0;
        sub_q[2] <= '0;
        sub_q[3] <= '0;
        pixel_index <= '0;
        packet_active <= 1'b0;
        packet_loaded <= 1'b0;
        packet_done <= 1'b0;
      end else begin
        packet_done <= 1'b0;
        if (packet_cancel_link && !packet_active) begin
          packet_loaded <= 1'b0;
          pixel_index <= 5'd0;
        end else if (packet_cancel && !packet_active && header_q[7:0] != 8'h82 &&
                     !(packet_valid && packet_header[7:0] == 8'h82)) begin
          packet_loaded <= 1'b0;
          pixel_index <= 5'd0;
        end else if (packet_valid && packet_ready) begin
          header_q <= packet_header;
          sub_q[0] <= packet_sub0;
          sub_q[1] <= packet_sub1;
          sub_q[2] <= packet_sub2;
          sub_q[3] <= packet_sub3;
          pixel_index <= 5'd0;
          packet_loaded <= 1'b1;
        end else if (packet_start && packet_loaded && !packet_active) begin
          pixel_index <= 5'd0;
          packet_active <= 1'b1;
        end else if (packet_active) begin
          if (pixel_index == 5'd31) begin
            packet_active <= 1'b0;
            packet_loaded <= 1'b0;
            packet_done <= 1'b1;
            pixel_index <= 5'd0;
          end else begin
            pixel_index <= pixel_index + 1'b1;
          end
        end
      end
    end
  end endgenerate
endmodule

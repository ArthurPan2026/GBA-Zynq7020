`timescale 1ns/1ps

// HDMI/DVI TMDS video encoder and 7-series output serializer in SystemVerilog.
// Packed pixels use the existing RBG byte layout: R[23:16], B/Cb[15:8], G/Y[7:0].
module hdmi_tmds_video_encoder (
  input  logic        pixel_clk,
  input  logic        serial_clk, // Kept for interface compatibility; TMDS encoding is pixel-clocked.
  input  logic        aresetn,
  input  logic [23:0] video_rgb_rbg,
  input  logic        video_de,
  input  logic        hsync,
  input  logic        vsync,
  output logic [9:0]  lane0_blue_symbol,
  output logic [9:0]  lane1_green_symbol,
  output logic [9:0]  lane2_red_symbol
);
  hdmi_tmds_8b10b_encoder u_blue_encoder (
    .pixel_clk(pixel_clk), .resetn(aresetn), .data_in(video_rgb_rbg[15:8]),
    .data_enable(video_de), .control({vsync, hsync}), .symbol(lane0_blue_symbol)
  );

  hdmi_tmds_8b10b_encoder u_green_encoder (
    .pixel_clk(pixel_clk), .resetn(aresetn), .data_in(video_rgb_rbg[7:0]),
    .data_enable(video_de), .control(2'b00), .symbol(lane1_green_symbol)
  );

  hdmi_tmds_8b10b_encoder u_red_encoder (
    .pixel_clk(pixel_clk), .resetn(aresetn), .data_in(video_rgb_rbg[23:16]),
    .data_enable(video_de), .control(2'b00), .symbol(lane2_red_symbol)
  );

  // Suppress an unused-clock warning without putting serial-clock logic in the
  // pixel-domain encoder. The serializer below owns all serial-clock edges.
  logic unused_serial_clk;
  always_comb unused_serial_clk = serial_clk;
endmodule

// DVI 1.0 Figure 3-5 transition-minimized, DC-balanced 8-to-10-bit encoder.
// The two-stage input pipeline plus registered output preserves the prior
// Keep a fixed two-cycle input-to-symbol latency across all color profiles.
module hdmi_tmds_8b10b_encoder (
  input  logic       pixel_clk,
  input  logic       resetn,
  input  logic [7:0] data_in,
  input  logic       data_enable,
  input  logic [1:0] control, // {C1,C0}
  output logic [9:0] symbol
);
  logic [7:0] data_stage1;
  logic       de_stage1;
  logic [1:0] control_stage1;
  logic [8:0] q_m_comb;
  logic [8:0] q_m_stage2;
  logic       de_stage2;
  logic [1:0] control_stage2;
  logic signed [4:0] running_disparity;
  logic signed [4:0] disparity_next;
  logic [9:0] symbol_next;
  integer n1_input;
  integer n1_q_m;
  integer dc_bias;
  integer disparity_work;
  integer bit_index;
  logic use_xnor;

  function automatic logic [9:0] control_symbol(input logic [1:0] ctl);
    case (ctl)
      2'b00: control_symbol = 10'b1101010100;
      2'b01: control_symbol = 10'b0010101011;
      2'b10: control_symbol = 10'b0101010100;
      default: control_symbol = 10'b1010101011;
    endcase
  endfunction

  always_comb begin
    n1_input = 0;
    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
      n1_input = n1_input + data_stage1[bit_index];

    use_xnor = (n1_input > 4) || ((n1_input == 4) && !data_stage1[0]);
    q_m_comb = '0;
    q_m_comb[0] = data_stage1[0];
    for (bit_index = 1; bit_index < 8; bit_index = bit_index + 1)
      q_m_comb[bit_index] = use_xnor ? ~(q_m_comb[bit_index-1] ^ data_stage1[bit_index]) :
                                      (q_m_comb[bit_index-1] ^ data_stage1[bit_index]);
    q_m_comb[8] = !use_xnor;

    n1_q_m = 0;
    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
      n1_q_m = n1_q_m + q_m_stage2[bit_index];
    dc_bias = 8 - 2*n1_q_m;
    disparity_work = $signed(running_disparity);
    symbol_next = control_symbol(control_stage2);
    disparity_next = '0;

    if (de_stage2) begin
      if ((running_disparity == 0) || (n1_q_m == 4)) begin
        if (!q_m_stage2[8]) begin
          symbol_next = {1'b1, 1'b0, ~q_m_stage2[7:0]};
          disparity_work = $signed(running_disparity) + dc_bias;
        end else begin
          symbol_next = {1'b0, 1'b1, q_m_stage2[7:0]};
          disparity_work = $signed(running_disparity) - dc_bias;
        end
      end else if (((running_disparity > 0) && (n1_q_m > 4)) ||
                   ((running_disparity < 0) && (n1_q_m < 4))) begin
        symbol_next = {1'b1, q_m_stage2[8], ~q_m_stage2[7:0]};
        disparity_work = $signed(running_disparity) + (q_m_stage2[8] ? 2 : 0) + dc_bias;
      end else begin
        symbol_next = {1'b0, q_m_stage2[8], q_m_stage2[7:0]};
        disparity_work = $signed(running_disparity) - (q_m_stage2[8] ? 0 : 2) - dc_bias;
      end
      disparity_next = disparity_work[4:0];
    end
  end

  always_ff @(posedge pixel_clk or negedge resetn) begin
    if (!resetn) begin
      data_stage1 <= 8'd0;
      de_stage1 <= 1'b0;
      control_stage1 <= 2'b00;
      q_m_stage2 <= 9'd0;
      de_stage2 <= 1'b0;
      control_stage2 <= 2'b00;
      running_disparity <= 5'sd0;
      symbol <= 10'b1101010100;
    end else begin
      data_stage1 <= data_in;
      de_stage1 <= data_enable;
      control_stage1 <= control;
      q_m_stage2 <= q_m_comb;
      de_stage2 <= de_stage1;
      control_stage2 <= control_stage1;
      running_disparity <= disparity_next;
      symbol <= symbol_next;
    end
  end
endmodule

// BT.601 or BT.709 RGB-to-YCbCr conversion, with either limited or full range.
// Input and output use the existing RBG packing to preserve TX lane mapping.
// Coefficients are Q0.8 approximations with +128 rounding before arithmetic
// shift. Limited output is clamped to legal 16..235 luma and 16..240 chroma.
module hdmi_rgb_to_ycbcr444 #(
  parameter integer COLORIMETRY = 0,    // 0=BT.601, 1=BT.709
  parameter integer YCC_RANGE = 0       // 0=limited, 1=full
) (
  input  logic [23:0] rgb_rbg,
  output logic [23:0] ycbcr_rbg // Cr[23:16], Cb[15:8], Y[7:0]
);
  localparam integer Y_R = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? 66  : 77)  : ((YCC_RANGE == 0) ? 47  : 54);
  localparam integer Y_G = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? 129 : 150) : ((YCC_RANGE == 0) ? 157 : 183);
  localparam integer Y_B = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? 25  : 29)  : ((YCC_RANGE == 0) ? 16  : 19);
  localparam integer CB_R = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? -38 : -43) : ((YCC_RANGE == 0) ? -26 : -29);
  localparam integer CB_G = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? -74 : -85) : ((YCC_RANGE == 0) ? -86 : -99);
  localparam integer CB_B = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? 112 : 128) : ((YCC_RANGE == 0) ? 112 : 128);
  localparam integer CR_R = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? 112 : 128) : ((YCC_RANGE == 0) ? 112 : 128);
  localparam integer CR_G = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? -94 : -107) : ((YCC_RANGE == 0) ? -102 : -116);
  localparam integer CR_B = (COLORIMETRY == 0) ? ((YCC_RANGE == 0) ? -18 : -21) : ((YCC_RANGE == 0) ? -10 : -12);

  logic signed [17:0] r_s, g_s, b_s;
  logic signed [17:0] y_sum, cb_sum, cr_sum;
  logic signed [17:0] y_shift, cb_shift, cr_shift;
  integer y_value, cb_value, cr_value;

  always_comb begin
    r_s = $signed({10'd0, rgb_rbg[23:16]});
    b_s = $signed({10'd0, rgb_rbg[15:8]});
    g_s = $signed({10'd0, rgb_rbg[7:0]});

    y_sum  = r_s * Y_R  + g_s * Y_G  + b_s * Y_B;
    cb_sum = r_s * CB_R + g_s * CB_G + b_s * CB_B;
    cr_sum = r_s * CR_R + g_s * CR_G + b_s * CR_B;
    y_shift  = (y_sum  + 18'sd128) >>> 8;
    cb_shift = (cb_sum + 18'sd128) >>> 8;
    cr_shift = (cr_sum + 18'sd128) >>> 8;
    y_value  = $signed(y_shift) + ((YCC_RANGE == 0) ? 16 : 0);
    cb_value = $signed(cb_shift) + 128;
    cr_value = $signed(cr_shift) + 128;

    if (YCC_RANGE == 0) begin
      if (y_value < 16) y_value = 16;
      if (y_value > 235) y_value = 235;
      if (cb_value < 16) cb_value = 16;
      if (cb_value > 240) cb_value = 240;
      if (cr_value < 16) cr_value = 16;
      if (cr_value > 240) cr_value = 240;
    end else begin
      if (y_value < 0) y_value = 0;
      if (y_value > 255) y_value = 255;
      if (cb_value < 0) cb_value = 0;
      if (cb_value > 255) cb_value = 255;
      if (cr_value < 0) cr_value = 0;
      if (cr_value > 255) cr_value = 255;
    end

    ycbcr_rbg = {cr_value[7:0], cb_value[7:0], y_value[7:0]};
  end

  initial begin
    if ((COLORIMETRY != 0) && (COLORIMETRY != 1))
      $fatal(1, "COLORIMETRY must be 0 (BT.601) or 1 (BT.709)");
    if ((YCC_RANGE != 0) && (YCC_RANGE != 1))
      $fatal(1, "YCC_RANGE must be 0 (limited) or 1 (full)");
  end
endmodule

// 7-series OSERDESE2/OBUFDS wrapper for the 10-bit TMDS symbol. The simulation
// branch models D1-first, LSB-first output over both SerialClk edges; it does
// not claim to model placement, clock skew, or electrical timing.
module hdmi_7series_output_serdes #(
  parameter integer PARALLEL_WIDTH = 10
) (
  input  logic                       pixel_clk,
  input  logic                       serial_clk,
  input  logic                       areset,
  input  logic [PARALLEL_WIDTH-1:0] parallel_data,
  output logic                       serial_p,
  output logic                       serial_n
);
`ifdef SYNTHESIS
  logic serial_data;
  logic slave_shift1, slave_shift2;

  OSERDESE2 #(
    .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(PARALLEL_WIDTH),
    .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1), .TBYTE_CTL("FALSE"), .TBYTE_SRC("FALSE")
  ) serializer_master (
    .OFB(), .OQ(serial_data), .SHIFTOUT1(), .SHIFTOUT2(), .TBYTEOUT(), .TFB(), .TQ(),
    .CLK(serial_clk), .CLKDIV(pixel_clk),
    .D1(parallel_data[0]), .D2(parallel_data[1]), .D3(parallel_data[2]), .D4(parallel_data[3]),
    .D5(parallel_data[4]), .D6(parallel_data[5]), .D7(parallel_data[6]), .D8(parallel_data[7]),
    .OCE(1'b1), .RST(areset), .SHIFTIN1(slave_shift1), .SHIFTIN2(slave_shift2),
    .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
  );

  OSERDESE2 #(
    .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(PARALLEL_WIDTH),
    .SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1), .TBYTE_CTL("FALSE"), .TBYTE_SRC("FALSE")
  ) serializer_slave (
    .OFB(), .OQ(), .SHIFTOUT1(slave_shift1), .SHIFTOUT2(slave_shift2),
    .TBYTEOUT(), .TFB(), .TQ(), .CLK(serial_clk), .CLKDIV(pixel_clk),
    .D1(1'b0), .D2(1'b0), .D3(parallel_data[8]), .D4(parallel_data[9]),
    .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .OCE(1'b1), .RST(areset),
    .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN(1'b0), .TCE(1'b0)
  );

  OBUFDS #(.IOSTANDARD("TMDS_33")) output_buffer (
    .I(serial_data), .O(serial_p), .OB(serial_n)
  );
`else
  logic [PARALLEL_WIDTH-1:0] sim_parallel_data;
  integer sim_bit_index;
  logic sim_prev_pixel_clk;

  // The event controls model the two DDR output edges. Test benches offset
  // clocks to avoid simultaneous events, just as a real MMCM phase
  // relationship must be set.
  always @(posedge pixel_clk or posedge serial_clk or negedge serial_clk or posedge areset) begin
    if (areset) begin
      sim_parallel_data <= '0;
      sim_bit_index <= 0;
      sim_prev_pixel_clk <= 1'b0;
    end else if (pixel_clk && !sim_prev_pixel_clk) begin
      sim_parallel_data <= parallel_data;
      sim_bit_index <= 0;
      sim_prev_pixel_clk <= 1'b1;
    end else begin
      sim_prev_pixel_clk <= pixel_clk;
      if (sim_bit_index < PARALLEL_WIDTH-1)
        sim_bit_index <= sim_bit_index + 1;
    end
  end

  always_comb begin
    serial_p = areset ? 1'b0 : sim_parallel_data[sim_bit_index];
    serial_n = ~serial_p;
  end
`endif

  initial begin
    if (PARALLEL_WIDTH != 10)
      $fatal(1, "This HDMI TMDS serializer supports exactly 10-bit symbols");
  end
endmodule

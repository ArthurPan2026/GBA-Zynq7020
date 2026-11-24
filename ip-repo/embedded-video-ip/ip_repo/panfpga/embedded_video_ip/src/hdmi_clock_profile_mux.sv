`timescale 1ns/1ps

package hdmi_clock_profile_drp_pkg;
  function automatic integer divider_for_output(
    input logic [1:0] output_id,
    input logic [1:0] profile
  );
    begin
      case (profile)
        2'd0: divider_for_output = (output_id == 2'd0) ? 5 :
                                   (output_id == 2'd3) ? 5 : 25;
        2'd1, 2'd2: divider_for_output = (output_id == 2'd0) ? 2 :
                                         (output_id == 2'd3) ? 5 : 10;
        2'd3: divider_for_output = (output_id == 2'd0) ? 1 : 5;
        default: divider_for_output = 0;
      endcase
    end
  endfunction

  function automatic logic [15:0] encode_divider_reg1(input integer divider);
    logic [5:0] high_count;
    logic [5:0] low_count;
    begin
      if (divider == 1) begin
        high_count = 6'd1;
        low_count = 6'd1;
      end else if (divider > 1) begin
        high_count = 6'(divider / 2);
        low_count = 6'(divider - (divider / 2));
      end else begin
        high_count = 6'd0;
        low_count = 6'd0;
      end
      encode_divider_reg1 = {4'b0000, high_count, low_count};
    end
  endfunction

  function automatic logic [15:0] encode_divider_reg2(
    input logic [15:0] old_value,
    input integer divider
  );
    logic [15:0] value;
    begin
      value = old_value & 16'hfc00;
      value[7] = (divider > 1) && ((divider % 2) != 0);
      value[6] = (divider == 1);
      encode_divider_reg2 = value;
    end
  endfunction
endpackage

// Glitch-free VGA/HD global-clock selector for a 7-series HDMI transmitter.
// The transition controller owns reset sequencing and waits for selected_locked
// before releasing pixel logic. Clock outputs are not gated by LOCKED.
module hdmi_clock_profile_mux (
  input  logic clock_profile_sel, // 0=VGA, 1=shared HD profile
  input  logic vga_pixel_clk,
  input  logic vga_serial_clk,
  input  logic vga_locked,
  input  logic hd_pixel_clk,
  input  logic hd_serial_clk,
  input  logic hd_locked,
  output wire  pixel_clk,
  output wire  serial_clk,
  output logic [1:0] locked_profiles, // [0]=VGA, [1]=HD
  output logic selected_locked
);
  logic [1:0] clock_select_onehot;

  // Decode to a fail-safe one-hot S0/S1 pair. BUFGCTRL's S pins provide the
  // asynchronous, glitch-free select path; CE pins remain asserted and IGNORE
  // remains deasserted. Unknown select values fall back to VGA.
  always_comb begin
    case (clock_profile_sel)
      1'b0: clock_select_onehot = 2'b01;
      1'b1: clock_select_onehot = 2'b10;
      default: clock_select_onehot = 2'b01;
    endcase
  end

  assign locked_profiles = {hd_locked, vga_locked};

  always_comb begin
    case (clock_profile_sel)
      1'b0: selected_locked = vga_locked;
      1'b1: selected_locked = hd_locked;
      default: selected_locked = vga_locked;
    endcase
  end

  BUFGCTRL #(.INIT_OUT(1'b0)) u_pixel_clock_profile_mux (
    .I0(vga_pixel_clk), .I1(hd_pixel_clk), .O(pixel_clk),
    .CE0(1'b1), .CE1(1'b1), .S0(clock_select_onehot[0]), .S1(clock_select_onehot[1]),
    .IGNORE0(1'b0), .IGNORE1(1'b0)
  );

  BUFGCTRL #(.INIT_OUT(1'b0)) u_serial_clock_profile_mux (
    .I0(vga_serial_clk), .I1(hd_serial_clk), .O(serial_clk),
    .CE0(1'b1), .CE1(1'b1), .S0(clock_select_onehot[0]), .S1(clock_select_onehot[1]),
    .IGNORE0(1'b0), .IGNORE1(1'b0)
  );
endmodule

// Canonical 50 MHz to VGA-reference clock generator. Keep the hierarchy used by
// embedded_video_ip_clocks.xdc: clocks/vga_reference/inst/mmcm_adv_inst.
module embedded_video_ip_video_out_clk_wiz_vga_0 (
 output wire clk_out1, output wire clk_out2, output wire locked,
 input wire resetn, input wire clk_in1
);
 embedded_video_ip_video_out_clk_wiz_vga_0_clk_wiz inst (
  .clk_out1(clk_out1), .clk_out2(clk_out2), .locked(locked),
  .resetn(resetn), .clk_in1(clk_in1));
endmodule

(* KEEP_HIERARCHY = "yes" *)
module embedded_video_ip_video_out_clk_wiz_vga_0_clk_wiz (
 output wire clk_out1, output wire clk_out2, output wire locked,
 input wire resetn, input wire clk_in1
);
 wire clkfb_raw, clkfb_buf, clkout1_raw, clkout2_raw, locked_int;
 wire clkfboutb_unused, clkout0b_unused, clkout1b_unused;
 wire clkout2_unused, clkout2b_unused, clkout3_unused, clkout3b_unused;
 wire clkout4_unused, clkout5_unused, clkout6_unused;
 wire [15:0] do_unused;
 wire clkfbstopped_unused, clkinstopped_unused, drdy_unused, psdone_unused;
 wire reset_high = ~resetn;
 (* KEEP_HIERARCHY = "yes" *) MMCME2_ADV #(
  .BANDWIDTH("OPTIMIZED"), .CLKOUT4_CASCADE(1'b0),
  .COMPENSATION("ZHOLD"), .STARTUP_WAIT(1'b0),
  .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(17.625), .CLKFBOUT_PHASE(0.0),
  .CLKFBOUT_USE_FINE_PS(1'b0), .CLKOUT0_DIVIDE_F(35.0),
  .CLKOUT0_PHASE(0.0), .CLKOUT0_DUTY_CYCLE(0.5), .CLKOUT0_USE_FINE_PS(1'b0),
  .CLKOUT1_DIVIDE(7), .CLKOUT1_PHASE(0.0), .CLKOUT1_DUTY_CYCLE(0.5),
  .CLKOUT1_USE_FINE_PS(1'b0), .CLKIN1_PERIOD(20.0)
 ) mmcm_adv_inst (
  .CLKFBOUT(clkfb_raw), .CLKFBOUTB(clkfboutb_unused),
  .CLKOUT0(clkout1_raw), .CLKOUT0B(clkout0b_unused),
  .CLKOUT1(clkout2_raw), .CLKOUT1B(clkout1b_unused),
  .CLKOUT2(clkout2_unused), .CLKOUT2B(clkout2b_unused),
  .CLKOUT3(clkout3_unused), .CLKOUT3B(clkout3b_unused),
  .CLKOUT4(clkout4_unused), .CLKOUT5(clkout5_unused), .CLKOUT6(clkout6_unused),
  .CLKFBIN(clkfb_buf), .CLKIN1(clk_in1), .CLKIN2(1'b0), .CLKINSEL(1'b1),
  .DADDR(7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0), .DO(do_unused),
  .DRDY(drdy_unused), .DWE(1'b0), .PSCLK(1'b0), .PSEN(1'b0),
  .PSINCDEC(1'b0), .PSDONE(psdone_unused), .LOCKED(locked_int),
  .CLKINSTOPPED(clkinstopped_unused), .CLKFBSTOPPED(clkfbstopped_unused),
  .PWRDWN(1'b0), .RST(reset_high));
 BUFG clkf_buf (.O(clkfb_buf), .I(clkfb_raw));
 BUFG clkout1_buf (.O(clk_out1), .I(clkout1_raw));
 BUFG clkout2_buf (.O(clk_out2), .I(clkout2_raw));
 assign locked = locked_int;
endmodule

// Four-mode PHY clock tree. The MMCM drives BUFIO/BUFR through its dedicated
// high-performance clock outputs. A fixed feedback multiplier keeps the DRP
// update limited to output dividers and their edge/no-count bits.
module hdmi_four_mode_clocks (
 input wire ctrl_clk, input wire resetn, input wire ref_clk,
 input wire [1:0] mode,
 output wire pixel_clk, (* CLOCK_BUFFER_TYPE="NONE" *) output wire serial_clk,
 (* CLOCK_BUFFER_TYPE="NONE" *) output wire serdes_pixel_clk,
 output wire serial_monitor_clk, output wire locked
);
 wire vga_pixel_unused, vga_ref, vga_locked;
 wire hd_ref_raw, hd_ref, hd_locked, mmfb_raw, mmfb;
 embedded_video_ip_video_out_clk_wiz_vga_0 vga_reference (
  .clk_in1(ref_clk), .resetn(resetn), .clk_out1(vga_pixel_unused),
  .clk_out2(vga_ref), .locked(vga_locked));
 MMCME2_BASE #(.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(37.125),
  .DIVCLK_DIVIDE(2), .CLKOUT0_DIVIDE_F(6.25), .BANDWIDTH("OPTIMIZED")) hd_reference (
  .CLKIN1(ref_clk), .RST(!resetn), .PWRDWN(1'b0),
  .CLKFBIN(mmfb), .CLKFBOUT(mmfb_raw), .CLKFBOUTB(),
  .CLKOUT0(hd_ref_raw), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
  .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
  .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(hd_locked));
 BUFG hd_feedback_buf (.I(mmfb_raw),.O(mmfb));
 BUFG hd_reference_buf (.I(hd_ref_raw),.O(hd_ref));
 reg [1:0] applied_mode;
 wire reference_locked = (applied_mode==0) ? vga_locked : hd_locked;
 (* ASYNC_REG="TRUE" *) reg [1:0] lock_sync, ref_lock_sync;
 wire mmcm_locked, mmcm_feedback, logic_pixel_raw, monitor_raw;
 wire [15:0] drp_do; wire drp_ready;
 reg [6:0] drp_addr; reg [15:0] drp_di; reg drp_en, drp_we;
 reg mmcm_reset; reg [3:0] state; reg [2:0] index; reg [4:0] settle;
 reg [15:0] drp_old;
 (* CLOCK_BUFFER_TYPE="NONE" *) wire raw_serial, raw_pixel;
 MMCME2_ADV #(.CLKIN1_PERIOD(7.943), .CLKIN2_PERIOD(6.7340067),
  .CLKFBOUT_MULT_F(5.0),
  .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(5.0), .CLKOUT1_DIVIDE(25),
  .CLKOUT2_DIVIDE(25), .CLKOUT3_DIVIDE(5),
  .COMPENSATION("ZHOLD"), .BANDWIDTH("OPTIMIZED")) serializer_mmcm (
  .CLKIN1(vga_ref),.CLKIN2(hd_ref),.CLKINSEL(applied_mode==0),
  .CLKFBIN(mmcm_feedback),.CLKFBOUT(mmcm_feedback),.CLKFBOUTB(),
  .CLKOUT0(raw_serial),.CLKOUT1(raw_pixel),.CLKOUT2(logic_pixel_raw),
  .CLKOUT0B(),.CLKOUT1B(),.CLKOUT2B(),.CLKOUT3(monitor_raw),.CLKOUT3B(),
  .CLKOUT4(),.CLKOUT5(),.CLKOUT6(),
  .RST(mmcm_reset || !resetn || !reference_locked),
  .PWRDWN(1'b0),.LOCKED(mmcm_locked),
  .DCLK(ctrl_clk),.DADDR(drp_addr),.DI(drp_di),.DO(drp_do),
  .DEN(drp_en),.DWE(drp_we),.DRDY(drp_ready),
  .CLKINSTOPPED(),.CLKFBSTOPPED(),.PSDONE(),
  .PSCLK(1'b0),.PSEN(1'b0),.PSINCDEC(1'b0));
 BUFIO u_tmds_bufio (.I(raw_serial), .O(serial_clk));
 BUFR #(.BUFR_DIVIDE("1"), .SIM_DEVICE("7SERIES")) u_serdes_bufr (
  .I(raw_pixel), .CE(1'b1), .CLR(mmcm_reset || !mmcm_locked || !resetn), .O(serdes_pixel_clk));
 BUFG logic_pixel_buffer (.I(logic_pixel_raw),.O(pixel_clk));
 BUFG serial_monitor_buffer (.I(monitor_raw),.O(serial_monitor_clk));
 assign locked=(state==0) && mode==applied_mode && lock_sync[1] && ref_lock_sync[1];
 function automatic [6:0] reg_addr(input [2:0] i);
  case(i)
   0:reg_addr=7'h08; 1:reg_addr=7'h09;
   2:reg_addr=7'h0a; 3:reg_addr=7'h0b;
   4:reg_addr=7'h0c; default:reg_addr=7'h0d;
  endcase
 endfunction
 always @(posedge ctrl_clk or negedge resetn) begin
  if(!resetn) begin lock_sync<=0;ref_lock_sync<=0;end
  else begin lock_sync<={lock_sync[0],mmcm_locked};ref_lock_sync<={ref_lock_sync[0],reference_locked};end
 end
 // Only output dividers change. Feedback multiplier and loop filter stay M=5.
 always @(posedge ctrl_clk or negedge resetn) begin
  if(!resetn) begin
   applied_mode<=0;state<=1;settle<=0;index<=0;mmcm_reset<=1;
   drp_en<=0;drp_we<=0;drp_addr<=0;drp_di<=0;drp_old<=0;
  end else begin
   drp_en<=0;drp_we<=0;
   case(state)
    0:if(mode!=applied_mode)begin mmcm_reset<=1;settle<=0;state<=7;end
    1:if(settle==31 && ref_lock_sync[1])begin index<=0;state<=2;end else if(settle!=31)settle<=settle+1'b1;
    2:begin drp_addr<=reg_addr(index);drp_en<=1;state<=3;end
    3:if(drp_ready)begin drp_old<=drp_do;state<=4;end
    4:begin
      if(index[0])
        drp_di<=hdmi_clock_profile_drp_pkg::encode_divider_reg2(
          drp_old,hdmi_clock_profile_drp_pkg::divider_for_output(index[2:1],applied_mode));
      else
        drp_di<=(drp_old & 16'h1000) |
          hdmi_clock_profile_drp_pkg::encode_divider_reg1(
            hdmi_clock_profile_drp_pkg::divider_for_output(index[2:1],applied_mode));
      drp_en<=1;drp_we<=1;state<=5;
    end
    5:if(drp_ready)begin
      if(index==5)begin mmcm_reset<=0;state<=6;settle<=0;end
      else begin index<=index+1'b1;state<=2;end
    end
    6:if(lock_sync[1])begin
      if(settle==31)state<=0;else settle<=settle+1'b1;
    end else settle<=0;
    7:begin applied_mode<=mode;settle<=0;state<=1;end
    default:begin mmcm_reset<=1;state<=1;settle<=0;end
   endcase
  end
 end
endmodule

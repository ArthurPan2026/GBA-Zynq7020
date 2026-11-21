//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2.1 (lin64) Build 6403652 Thu Mar 19 13:47:00 MDT 2026
//Date        : Sat Nov 21 09:52:27 2026
//Host        : pzy-fpga running 64-bit Ubuntu 22.04.5 LTS
//Command     : generate_target embedded_video_ip_video_out.bd
//Design      : embedded_video_ip_video_out
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

(* CORE_GENERATION_INFO = "embedded_video_ip_video_out,IP_Integrator,{x_ipVendor=xilinx.com,x_ipLibrary=BlockDiagram,x_ipName=embedded_video_ip_video_out,x_ipVersion=1.00.a,x_ipLanguage=VERILOG,numBlks=11,numReposBlks=11,numNonXlnxBlks=0,numHierBlks=0,maxHierDepth=0,numSysgenBlks=0,numHlsBlks=0,numHdlrefBlks=2,numPkgbdBlks=0,bdsource=USER,synth_mode=Hierarchical}" *) (* HW_HANDOFF = "embedded_video_ip_video_out.hwdef" *) 
module embedded_video_ip_video_out
   (aclk,
    aresetn,
    clock_profile_sel,
    hdmi_mmcm_locked,
    hdmi_ref_clk,
    locked_profiles,
    pixel_aresetn,
    pixel_clk,
    pixel_reset_ext_asserted,
    pixel_reset_hold,
    s_axis_video_tdata,
    s_axis_video_tlast,
    s_axis_video_tready,
    s_axis_video_tuser,
    s_axis_video_tvalid,
    serial_clk,
    timing_profile,
    video_de,
    video_hsync,
    video_rgb,
    video_vsync,
    video_vsync_raw);
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.ACLK CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ACLK, ASSOCIATED_BUSIF s_axis_video, CLK_DOMAIN embedded_video_ip_video_out_aclk, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *) input aclk;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.ARESETN RST" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.ARESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *) input aresetn;
  input clock_profile_sel;
  output hdmi_mmcm_locked;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.HDMI_REF_CLK CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.HDMI_REF_CLK, CLK_DOMAIN embedded_video_ip_video_out_hdmi_ref_clk, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *) input hdmi_ref_clk;
  output [1:0]locked_profiles;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.PIXEL_ARESETN RST" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.PIXEL_ARESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *) output [0:0]pixel_aresetn;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.PIXEL_CLK CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PIXEL_CLK, CLK_DOMAIN embedded_video_ip_video_out_clock_profile_mux_0_pixel_clk, FREQ_HZ 25178571, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *) output pixel_clk;
  output [0:0]pixel_reset_ext_asserted;
  input pixel_reset_hold;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_video TDATA" *) (* X_INTERFACE_MODE = "Slave" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_video, CLK_DOMAIN embedded_video_ip_video_out_aclk, FREQ_HZ 100000000, HAS_TKEEP 0, HAS_TLAST 1, HAS_TREADY 1, HAS_TSTRB 0, INSERT_VIP 0, LAYERED_METADATA undef, PHASE 0.0, TDATA_NUM_BYTES 3, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1" *) input [23:0]s_axis_video_tdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_video TLAST" *) input s_axis_video_tlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_video TREADY" *) output s_axis_video_tready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_video TUSER" *) input s_axis_video_tuser;
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_video TVALID" *) input s_axis_video_tvalid;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.SERIAL_CLK CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.SERIAL_CLK, CLK_DOMAIN embedded_video_ip_video_out_clock_profile_mux_0_serial_clk, FREQ_HZ 125892857, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *) output serial_clk;
  input [1:0]timing_profile;
  output video_de;
  output video_hsync;
  output [23:0]video_rgb;
  output video_vsync;
  output video_vsync_raw;

  wire aclk;
  wire aresetn;
  wire clk_wiz_hd_clk_out1;
  wire clk_wiz_hd_clk_out2;
  wire clk_wiz_hd_locked;
  wire clk_wiz_vga_clk_out1;
  wire clk_wiz_vga_clk_out2;
  wire clk_wiz_vga_locked;
  wire clock_profile_sel;
  wire hdmi_mmcm_locked;
  wire hdmi_ref_clk;
  wire [1:0]locked_profiles;
  wire [0:0]pixel_aresetn;
  wire pixel_clk;
  wire [0:0]pixel_reset_ext_asserted;
  wire pixel_reset_hold;
  wire [0:0]pixel_reset_peripheral_reset;
  wire [0:0]reset_invert_Res;
  wire [0:0]reset_zero_dout;
  wire [23:0]s_axis_video_tdata;
  wire s_axis_video_tlast;
  wire s_axis_video_tready;
  wire s_axis_video_tuser;
  wire s_axis_video_tvalid;
  wire serial_clk;
  wire timing_gen_video_timing_ACTIVE_VIDEO;
  wire timing_gen_video_timing_FIELD;
  wire timing_gen_video_timing_HBLANK;
  wire timing_gen_video_timing_HSYNC;
  wire timing_gen_video_timing_VBLANK;
  wire timing_gen_video_timing_VSYNC;
  wire [1:0]timing_profile;
  wire video_de;
  wire video_hsync;
  wire [0:0]video_out_aclken_invert_Res;
  wire [0:0]video_out_pixel_ce_one_dout;
  wire [23:0]video_rgb;
  wire video_vsync;
  wire video_vsync_raw;

  embedded_video_ip_video_out_clk_wiz_hd_0 clk_wiz_hd
       (.clk_in1(hdmi_ref_clk),
        .clk_out1(clk_wiz_hd_clk_out1),
        .clk_out2(clk_wiz_hd_clk_out2),
        .locked(clk_wiz_hd_locked),
        .resetn(aresetn));
  embedded_video_ip_video_out_clk_wiz_vga_0 clk_wiz_vga
       (.clk_in1(hdmi_ref_clk),
        .clk_out1(clk_wiz_vga_clk_out1),
        .clk_out2(clk_wiz_vga_clk_out2),
        .locked(clk_wiz_vga_locked),
        .resetn(aresetn));
  embedded_video_ip_video_out_clock_profile_mux_0 clock_profile_mux
       (.clock_profile_sel(clock_profile_sel),
        .hd_locked(clk_wiz_hd_locked),
        .hd_pixel_clk(clk_wiz_hd_clk_out1),
        .hd_serial_clk(clk_wiz_hd_clk_out2),
        .locked_profiles(locked_profiles),
        .pixel_clk(pixel_clk),
        .selected_locked(hdmi_mmcm_locked),
        .serial_clk(serial_clk),
        .vga_locked(clk_wiz_vga_locked),
        .vga_pixel_clk(clk_wiz_vga_clk_out1),
        .vga_serial_clk(clk_wiz_vga_clk_out2));
  embedded_video_ip_video_out_pixel_reset_0 pixel_reset
       (.aux_reset_in(reset_zero_dout),
        .dcm_locked(hdmi_mmcm_locked),
        .ext_reset_in(pixel_reset_ext_asserted),
        .mb_debug_sys_rst(reset_zero_dout),
        .peripheral_aresetn(pixel_aresetn),
        .peripheral_reset(pixel_reset_peripheral_reset),
        .slowest_sync_clk(pixel_clk));
  embedded_video_ip_video_out_reset_invert_0 reset_invert
       (.Op1(aresetn),
        .Res(reset_invert_Res));
  embedded_video_ip_video_out_reset_or_mode_hold_0 reset_or_mode_hold
       (.Op1(reset_invert_Res),
        .Op2(pixel_reset_hold),
        .Res(pixel_reset_ext_asserted));
  embedded_video_ip_video_out_reset_zero_0 reset_zero
       (.dout(reset_zero_dout));
  embedded_video_ip_video_out_timing_gen_0 timing_gen
       (.ACTIVE_VIDEO(timing_gen_video_timing_ACTIVE_VIDEO),
        .FIELD(timing_gen_video_timing_FIELD),
        .HBLANK(timing_gen_video_timing_HBLANK),
        .HSYNC(timing_gen_video_timing_HSYNC),
        .VBLANK(timing_gen_video_timing_VBLANK),
        .VSYNC(timing_gen_video_timing_VSYNC),
        .enable(video_out_pixel_ce_one_dout),
        .pixel_clk(pixel_clk),
        .resetn(pixel_aresetn),
        .timing_profile(timing_profile),
        .vsync_raw(video_vsync_raw));
  embedded_video_ip_video_out_video_out_0 video_out
       (.aclk(aclk),
        .aclken(video_out_aclken_invert_Res),
        .aresetn(aresetn),
        .fid(reset_zero_dout),
        .s_axis_video_tdata(s_axis_video_tdata),
        .s_axis_video_tlast(s_axis_video_tlast),
        .s_axis_video_tready(s_axis_video_tready),
        .s_axis_video_tuser(s_axis_video_tuser),
        .s_axis_video_tvalid(s_axis_video_tvalid),
        .vid_active_video(video_de),
        .vid_data(video_rgb),
        .vid_hsync(video_hsync),
        .vid_io_out_ce(video_out_pixel_ce_one_dout),
        .vid_io_out_clk(pixel_clk),
        .vid_io_out_reset(pixel_reset_peripheral_reset),
        .vid_vsync(video_vsync),
        .vtg_active_video(timing_gen_video_timing_ACTIVE_VIDEO),
        .vtg_field_id(timing_gen_video_timing_FIELD),
        .vtg_hblank(timing_gen_video_timing_HBLANK),
        .vtg_hsync(timing_gen_video_timing_HSYNC),
        .vtg_vblank(timing_gen_video_timing_VBLANK),
        .vtg_vsync(timing_gen_video_timing_VSYNC));
  embedded_video_ip_video_out_video_out_aclken_invert_0 video_out_aclken_invert
       (.Op1(pixel_reset_hold),
        .Res(video_out_aclken_invert_Res));
  embedded_video_ip_video_out_video_out_pixel_ce_one_0 video_out_pixel_ce_one
       (.dout(video_out_pixel_ce_one_dout));
endmodule

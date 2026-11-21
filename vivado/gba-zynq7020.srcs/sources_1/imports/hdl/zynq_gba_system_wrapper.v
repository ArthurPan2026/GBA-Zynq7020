//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2.1 (lin64) Build 6403652 Thu Mar 19 13:47:00 MDT 2026
//Date        : Sat Nov 21 10:10:21 2026
//Host        : pzy-fpga running 64-bit Ubuntu 22.04.5 LTS
//Command     : generate_target zynq_gba_system_wrapper.bd
//Design      : zynq_gba_system_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module zynq_gba_system_wrapper
   (AUDIO_IIC_scl_io,
    AUDIO_IIC_sda_io,
    DDR_addr,
    DDR_ba,
    DDR_cas_n,
    DDR_ck_n,
    DDR_ck_p,
    DDR_cke,
    DDR_cs_n,
    DDR_dm,
    DDR_dq,
    DDR_dqs_n,
    DDR_dqs_p,
    DDR_odt,
    DDR_ras_n,
    DDR_reset_n,
    DDR_we_n,
    FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp,
    FIXED_IO_mio,
    FIXED_IO_ps_clk,
    FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb,
    HDMI_DDC_IIC_scl_io,
    HDMI_DDC_IIC_sda_io,
    ac_mclk,
    ac_muten,
    btns,
    hdmi_tx_hpd,
    i2s_tx_lrclk_tx,
    i2s_tx_sclk_tx,
    i2s_tx_sdata_0,
    leds,
    sws,
    tmds_tx_clk_n,
    tmds_tx_clk_p,
    tmds_tx_data_n,
    tmds_tx_data_p);
  inout AUDIO_IIC_scl_io;
  inout AUDIO_IIC_sda_io;
  inout [14:0]DDR_addr;
  inout [2:0]DDR_ba;
  inout DDR_cas_n;
  inout DDR_ck_n;
  inout DDR_ck_p;
  inout DDR_cke;
  inout DDR_cs_n;
  inout [3:0]DDR_dm;
  inout [31:0]DDR_dq;
  inout [3:0]DDR_dqs_n;
  inout [3:0]DDR_dqs_p;
  inout DDR_odt;
  inout DDR_ras_n;
  inout DDR_reset_n;
  inout DDR_we_n;
  inout FIXED_IO_ddr_vrn;
  inout FIXED_IO_ddr_vrp;
  inout [53:0]FIXED_IO_mio;
  inout FIXED_IO_ps_clk;
  inout FIXED_IO_ps_porb;
  inout FIXED_IO_ps_srstb;
  inout HDMI_DDC_IIC_scl_io;
  inout HDMI_DDC_IIC_sda_io;
  output ac_mclk;
  output ac_muten;
  input [3:0]btns;
  input hdmi_tx_hpd;
  output i2s_tx_lrclk_tx;
  output i2s_tx_sclk_tx;
  output i2s_tx_sdata_0;
  output [3:0]leds;
  input [3:0]sws;
  output tmds_tx_clk_n;
  output tmds_tx_clk_p;
  output [2:0]tmds_tx_data_n;
  output [2:0]tmds_tx_data_p;

  wire AUDIO_IIC_scl_i;
  wire AUDIO_IIC_scl_io;
  wire AUDIO_IIC_scl_o;
  wire AUDIO_IIC_scl_t;
  wire AUDIO_IIC_sda_i;
  wire AUDIO_IIC_sda_io;
  wire AUDIO_IIC_sda_o;
  wire AUDIO_IIC_sda_t;
  wire [14:0]DDR_addr;
  wire [2:0]DDR_ba;
  wire DDR_cas_n;
  wire DDR_ck_n;
  wire DDR_ck_p;
  wire DDR_cke;
  wire DDR_cs_n;
  wire [3:0]DDR_dm;
  wire [31:0]DDR_dq;
  wire [3:0]DDR_dqs_n;
  wire [3:0]DDR_dqs_p;
  wire DDR_odt;
  wire DDR_ras_n;
  wire DDR_reset_n;
  wire DDR_we_n;
  wire FIXED_IO_ddr_vrn;
  wire FIXED_IO_ddr_vrp;
  wire [53:0]FIXED_IO_mio;
  wire FIXED_IO_ps_clk;
  wire FIXED_IO_ps_porb;
  wire FIXED_IO_ps_srstb;
  wire HDMI_DDC_IIC_scl_i;
  wire HDMI_DDC_IIC_scl_io;
  wire HDMI_DDC_IIC_scl_o;
  wire HDMI_DDC_IIC_scl_t;
  wire HDMI_DDC_IIC_sda_i;
  wire HDMI_DDC_IIC_sda_io;
  wire HDMI_DDC_IIC_sda_o;
  wire HDMI_DDC_IIC_sda_t;
  wire ac_mclk;
  wire ac_muten;
  wire [3:0]btns;
  wire hdmi_tx_hpd;
  wire i2s_tx_lrclk_tx;
  wire i2s_tx_sclk_tx;
  wire i2s_tx_sdata_0;
  wire [3:0]leds;
  wire [3:0]sws;
  wire tmds_tx_clk_n;
  wire tmds_tx_clk_p;
  wire [2:0]tmds_tx_data_n;
  wire [2:0]tmds_tx_data_p;

  IOBUF AUDIO_IIC_scl_iobuf
       (.I(AUDIO_IIC_scl_o),
        .IO(AUDIO_IIC_scl_io),
        .O(AUDIO_IIC_scl_i),
        .T(AUDIO_IIC_scl_t));
  IOBUF AUDIO_IIC_sda_iobuf
       (.I(AUDIO_IIC_sda_o),
        .IO(AUDIO_IIC_sda_io),
        .O(AUDIO_IIC_sda_i),
        .T(AUDIO_IIC_sda_t));
  IOBUF HDMI_DDC_IIC_scl_iobuf
       (.I(HDMI_DDC_IIC_scl_o),
        .IO(HDMI_DDC_IIC_scl_io),
        .O(HDMI_DDC_IIC_scl_i),
        .T(HDMI_DDC_IIC_scl_t));
  IOBUF HDMI_DDC_IIC_sda_iobuf
       (.I(HDMI_DDC_IIC_sda_o),
        .IO(HDMI_DDC_IIC_sda_io),
        .O(HDMI_DDC_IIC_sda_i),
        .T(HDMI_DDC_IIC_sda_t));
  zynq_gba_system zynq_gba_system_i
       (.AUDIO_IIC_scl_i(AUDIO_IIC_scl_i),
        .AUDIO_IIC_scl_o(AUDIO_IIC_scl_o),
        .AUDIO_IIC_scl_t(AUDIO_IIC_scl_t),
        .AUDIO_IIC_sda_i(AUDIO_IIC_sda_i),
        .AUDIO_IIC_sda_o(AUDIO_IIC_sda_o),
        .AUDIO_IIC_sda_t(AUDIO_IIC_sda_t),
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .HDMI_DDC_IIC_scl_i(HDMI_DDC_IIC_scl_i),
        .HDMI_DDC_IIC_scl_o(HDMI_DDC_IIC_scl_o),
        .HDMI_DDC_IIC_scl_t(HDMI_DDC_IIC_scl_t),
        .HDMI_DDC_IIC_sda_i(HDMI_DDC_IIC_sda_i),
        .HDMI_DDC_IIC_sda_o(HDMI_DDC_IIC_sda_o),
        .HDMI_DDC_IIC_sda_t(HDMI_DDC_IIC_sda_t),
        .ac_mclk(ac_mclk),
        .ac_muten(ac_muten),
        .btns(btns),
        .hdmi_tx_hpd(hdmi_tx_hpd),
        .i2s_tx_lrclk_tx(i2s_tx_lrclk_tx),
        .i2s_tx_sclk_tx(i2s_tx_sclk_tx),
        .i2s_tx_sdata_0(i2s_tx_sdata_0),
        .leds(leds),
        .sws(sws),
        .tmds_tx_clk_n(tmds_tx_clk_n),
        .tmds_tx_clk_p(tmds_tx_clk_p),
        .tmds_tx_data_n(tmds_tx_data_n),
        .tmds_tx_data_p(tmds_tx_data_p));
endmodule

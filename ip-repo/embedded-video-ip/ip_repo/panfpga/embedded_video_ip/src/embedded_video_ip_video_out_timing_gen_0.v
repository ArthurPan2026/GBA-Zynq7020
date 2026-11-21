// (c) Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// (c) Copyright 2022-2026 Advanced Micro Devices, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of AMD and is protected under U.S. and international copyright
// and other intellectual property laws.
// 
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// AMD, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) AMD shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or AMD had been advised of the
// possibility of the same.
// 
// CRITICAL APPLICATIONS
// AMD products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of AMD products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
// 
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
// 
// DO NOT MODIFY THIS FILE.


// IP VLNV: xilinx.com:module_ref:embedded_video_ip_timing_gen_wrapper:1.0
// IP Revision: 1

(* X_CORE_INFO = "embedded_video_ip_timing_gen_wrapper,Vivado 2025.2.1" *)
(* CHECK_LICENSE_TYPE = "embedded_video_ip_video_out_timing_gen_0,embedded_video_ip_timing_gen_wrapper,{}" *)
(* CORE_GENERATION_INFO = "embedded_video_ip_video_out_timing_gen_0,embedded_video_ip_timing_gen_wrapper,{x_ipProduct=Vivado 2025.2.1,x_ipVendor=xilinx.com,x_ipLibrary=module_ref,x_ipName=embedded_video_ip_timing_gen_wrapper,x_ipVersion=1.0,x_ipCoreRevision=1,x_ipLanguage=VERILOG,x_ipSimLanguage=VERILOG}" *)
(* IP_DEFINITION_SOURCE = "module_ref" *)
(* DowngradeIPIdentifiedWarnings = "yes" *)
module embedded_video_ip_video_out_timing_gen_0 (
  pixel_clk,
  resetn,
  enable,
  timing_profile,
  ACTIVE_VIDEO,
  HBLANK,
  VBLANK,
  HSYNC,
  VSYNC,
  FIELD,
  vsync_raw
);

(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.PIXEL_CLK CLK" *)
(* X_INTERFACE_MODE = "slave" *)
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PIXEL_CLK, ASSOCIATED_RESET resetn, FREQ_HZ 25178571, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN embedded_video_ip_video_out_clock_profile_mux_0_pixel_clk, INSERT_VIP 0" *)
input wire pixel_clk;
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
(* X_INTERFACE_MODE = "slave" *)
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
input wire resetn;
input wire enable;
input wire [1 : 0] timing_profile;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing ACTIVE_VIDEO" *)
(* X_INTERFACE_MODE = "master" *)
output wire ACTIVE_VIDEO;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HBLANK" *)
output wire HBLANK;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VBLANK" *)
output wire VBLANK;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing HSYNC" *)
output wire HSYNC;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing VSYNC" *)
output wire VSYNC;
(* X_INTERFACE_INFO = "xilinx.com:interface:video_timing:2.0 video_timing FIELD" *)
output wire FIELD;
output wire vsync_raw;

  embedded_video_ip_timing_gen_wrapper inst (
    .pixel_clk(pixel_clk),
    .resetn(resetn),
    .enable(enable),
    .timing_profile(timing_profile),
    .ACTIVE_VIDEO(ACTIVE_VIDEO),
    .HBLANK(HBLANK),
    .VBLANK(VBLANK),
    .HSYNC(HSYNC),
    .VSYNC(VSYNC),
    .FIELD(FIELD),
    .vsync_raw(vsync_raw)
  );
endmodule

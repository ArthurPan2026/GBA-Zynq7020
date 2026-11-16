#------------------------------------------------------------------------------
# @file zybo_z7_20.xdc
# @module-contract
# 职责: 板级实现约束；Zybo Z7-20 PL 管脚、IO 标准、时钟域关系和异步路径约束。
# 上游: Vivado 顶层端口。
# 下游: Zybo Z7-20 物理引脚和 STA。
# 时钟域: 声明和约束 PS FCLK、视频/音频相关 PL 时钟及跨域路径。
# 复位: 约束文件不产生复位，只描述端口、时钟和异步路径关系。
# 关键协议: 音频采样、FIFO/声道节拍和串行位时钟共同决定输出节奏。
# 设计注意点: 约束 HDMI、音频、按键、拨码、LED 的物理连接，并明确 PS FCLK/板级 GPIO 的异步时序边界；本注释只解释设计意图，不改变 RTL/XDC 功能。
#------------------------------------------------------------------------------
## Zynq-GBA_MiSTer Vivado constraints
## Target board: Digilent Zybo Z7-20
## Canonical top: zynq_gba_system_wrapper

## Bitstream
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# @section 管脚约束: HDMI TMDS 与 DDC/HPD，IOSTANDARD 必须匹配 Zybo Z7-20 原理图。
## HDMI TX
set_property -dict {PACKAGE_PIN H16 IOSTANDARD TMDS_33} [get_ports tmds_tx_clk_p]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD TMDS_33} [get_ports tmds_tx_clk_n]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_p[0]}]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_n[0]}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_p[1]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_n[1]}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_p[2]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD TMDS_33} [get_ports {tmds_tx_data_n[2]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports hdmi_tx_hpd]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports HDMI_DDC_IIC_scl_io]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports HDMI_DDC_IIC_sda_io]

# @section 管脚约束: SSM2603 PCM/I2S 输出，时序由 PL 音频发送器产生。
## Audio codec SSM2603 PCM data
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports ac_mclk]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports ac_bclk]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports ac_pblrc]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports ac_pbdat]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports ac_muten]

## Audio codec I2C
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports AUDIO_IIC_scl_io]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports AUDIO_IIC_sda_io]

## Buttons
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports {btns[0]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {btns[1]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports {btns[2]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {btns[3]}]

## Switches
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports {sws[0]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {sws[1]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sws[2]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {sws[3]}]

## LEDs
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {leds[0]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {leds[1]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {leds[2]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {leds[3]}]

# @section 时钟约束: PS FCLK0/FCLK1 在 RTL 中按异步域处理，CDC 由同步器承担。
## Clock relationship cleanup
## PS FCLK0/FCLK1 are asynchronous domains; include clocks generated from either root.
set_clock_groups -name ps_fclk_domains_async -asynchronous \
    -group [get_clocks -include_generated_clocks clk_fpga_1] \
    -group [get_clocks -include_generated_clocks {clk_fpga_0 *clk_wiz/inst/clk_in1}]

# @section 异步路径: 机械按键、拨码、调试/板级输出不参与内部同步时序收敛。
## Async GPIO / board-level debug/status pins: no external timing budget is enforced.
set_false_path -from [get_ports {btns[*] sws[*] hdmi_tx_hpd HDMI_DDC_IIC_scl_io HDMI_DDC_IIC_sda_io}]
set_false_path -to [get_ports {leds[*] ac_mclk ac_bclk ac_pblrc ac_pbdat ac_muten}]
set_false_path -to [get_ports {tmds_tx_clk_p tmds_tx_clk_n tmds_tx_data_p[*] tmds_tx_data_n[*]}]
set_false_path -to [get_ports {HDMI_DDC_IIC_scl_io HDMI_DDC_IIC_sda_io}]


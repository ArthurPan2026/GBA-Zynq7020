# 架构

GBA-Zynq7020 将 GBA 核心与视频、音频和显示接口逻辑部署在 Zybo Z7-20 的 PL 中，由 Zynq-7000 PS 运行 FreeRTOS 应用。

## 硬件层次

Vivado 入口为 `vivado/gba-zynq7020.xpr`。Block Design 位于 `vivado/gba-zynq7020.srcs/sources_1/bd/zynq_gba_system/`，包含 Zynq PS、AXI 互连、DDR 帧缓冲、时钟与复位、HDMI 视频输出和音频接口。器件约束位于 `src/constraints/`。

PL RTL 位于 `src/rtl/`。GBA 核心、项目封装和顶层通过 Block Design wrapper 接入系统。PS/PL 寄存器与数据契约定义在 `config/ps-pl-contract.json`，生成的 C 与 HDL 声明位于 `src/generated/`。

## PS 应用

Vitis 应用源码位于 `src/ps/app/src/`，运行于 FreeRTOS。应用负责 ROM 与存档访问、输入、菜单、音频、显示和运行状态管理。应用通过 AXI 控制寄存器与 PL 交互。

EmbeddedVideoIP 的 Vivado IP 文件位于 `ip-repo/embedded-video-ip/ip_repo/`，Zynq-7000 PS 库位于 `src/ps/app/src/Video/Lib/`。版本与发布资产来源在 `fpga-project.toml` 中声明。FPGAFlow 计算实际输入哈希，并在仓库外保存运行索引与输入锁。

## 工程与输出

Git 管理 Vivado 的 XPR、Block Design、wrapper、IP 包和设计源码。Vivado 的运行与缓存目录和 Vitis 生成 platform 保存在本地。其他构建、仿真和部署输出集中在 `build/`。

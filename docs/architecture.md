# 工程架构

## 目录层次

src/rtl/ 保存项目 RTL。src/bd/gba-system/ 保存 Block Design 源快照和离线 IP 源。src/ps/app/ 保存 Vitis 应用。src/generated/ 保存由 PS/PL contract 生成的接口头文件。

Vivado 工程由脚本生成。工程文件不进入 Git。

## PL 数据路径

    GBA core
      ├── video pixels ──> frame buffer / DDR ──> HDMI video pipeline
      ├── PCM audio ─────> HDMI audio packetizer
      ├── cartridge / save / DDR requests
      └── AXI status and control registers

公共模块位于 src/rtl/common/：

- DDR AXI backend。
- DDR mux 和仲裁器。
- AXI-Lite control registers。
- CDC toggle mailbox。
- 音频 AXI stream。
- 帧同步和视频辅助逻辑。

顶层模块位于 src/rtl/top/。GBA 原始核心位于 src/rtl/gba-core/rtl/，硬件实体名保持 gba_* 和 zynq_gba_* 形式。

## PS 软件

PS 应用位于 src/ps/app/src/，按功能目录组织：

- App/：启动、控制台、运行时和 ROM 加载。
- Common/：公共状态和逻辑。
- Diagnostics/：诊断和证据输出。
- Gba/：GBA 寄存器、mailbox 和 contract 接口。
- Hdmi/：HDMI、EDID 和视频模式。
- Input/：实体按键和 USB 输入。
- Rom/：ROM 元数据和加载。
- Save/：存档和存储事务。
- Storage/：FatFs 和 SD 存储。
- Ui/：LVGL 菜单。
- third-party/：LVGL、CherryUSB 和字体。

## PS/PL contract

源配置：

    config/ps-pl-contract.json

生成文件：

    src/generated/ps/ps_pl_contract_generated.h
    src/generated/rtl/ps_pl_contract_generated.vh

应用代码和 RTL 都从生成文件读取寄存器偏移、ABI 版本、能力位、命令和状态位。修改接口时先修改 JSON，再运行 contract generator。

## 视频依赖

HDMI 视频 IP 位于独立的 EmbeddedVideoIP 仓库。GBA 工程通过 fpga-flow.toml 锁定提交和输入文件。

GBA 仓库保留消费端配置：

    scripts/vivado/embedded_video_ip_consumer.tcl

视频 IP 的实现、接口文件和 PS library 由 EmbeddedVideoIP 仓库维护。

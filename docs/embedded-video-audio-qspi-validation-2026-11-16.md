# 2026-11-16 HDMI 音频集成与 QSPI 稳定点记录

日期：2026-11-16。目标板为 Zybo Z7-20，器件为 XC7Z020。硬件工具为 Vivado/Vitis 2025.2.1。游戏测试只使用 MechPlatoon。

## 迭代记录

### FPGAFlow 消费工程与构建流程

此前 Vivado、Vitis 和增量缓存脚本各自决定产物路径和缓存规则。Vivado 产物与 Flow 预期目录不一致。平台复用只比较 XSA 路径；同一路径下 XSA 内容变化时，可能复用旧平台。部署前也缺少对 bit、XSA、PS 平台和 ELF 的统一关联检查。

2026-11-15 的两个本地提交完善了 GBA 消费工程配置。提交 f5559de 统一了 Flow stage、输出目录、阶段输入摘要、工具版本、产物哈希和板级验证入口。提交 54a9a24 增加 fpga-flow.toml 消费项目配置。主要文件包括 tools/flow.py、tools/vitis_stages.py、scripts/build/build_bitstream.tcl、scripts/build/rebuild_project.tcl、scripts/build/embedded_video_ip_consumer.tcl、tests/test_flow.py 和 tests/test_vitis_stages.py。

这轮还修复了 XSA 原位更新后的旧平台误复用。平台输入记录现在保存 XSA SHA-256；内容摘要不一致时，Flow 会创建新平台并完整构建 BSP。测试覆盖了 XSA 内容变化、阶段缓存和产物关联。PS 本轮确实使用新 XSA 做全量 platform/BSP 构建，再全量构建 app。当前 manifest 中的硬件、平台、app、boot 阶段都成功，Flow report 的所有输出哈希均有效。

### 可选 HDMI 音频接入

需求是让 GBA 菜单能在启动游戏前选择 HDMI 或板载 I²S codec 输出。I²S 属于 GBA 消费工程，不属于通用 EmbeddedVideoIP。EmbeddedVideoIP 只接收通用 PCM AXI4-Stream，并处理可选 HDMI 音频。

PL 端在 src/rtl/top/zynq_gba_top.v 中复用现有 I²S 48 kHz sample_ce。新增 src/rtl/common/gba_pcm_audio_axis.sv，把 GBA 左右声道样本送入 HDMI PCM AXI4-Stream。I²S 发送器仍由 GBA 工程保留。src/rtl/common/axi_lite_ctrl_regs.sv 和 PS VDMA API 增加 HDMI 音频控制与状态访问。

PS 端新增 src/ps/app/src/Common/Inc/ps_app_audio_route_logic.h 和 src/ps/app/src/Common/Src/ps_app_audio_route_logic.c，负责路由切换、音量曲线、静音和回滚。src/ps/app/src/Ui/Src/ps_app_ui.c 在主菜单提供输出路径选择，按 B 切换 I²S 与 HDMI；选定路径后再启动游戏。src/ps/app/src/App/Src/ps_app_runtime_boot.c 应用目标路由的音量、静音和 HDMI 使能。UART 增加 audio status、audio path 和 HDMI 状态诊断。

新增 tests/rtl/tb_gba_pcm_audio_axis.sv 和 tests/ps/test_audio_route_logic.c。EVIP 在 0.2.0-dev.4 中实现 HDMI LPCM packetizer、ACR、Audio InfoFrame、采样 FIFO、增益/静音和 TMDS 数据岛调度。GBA 锁定 EmbeddedVideoIP 提交 2008d713bf3ee37495bbc940634ad7b917a0ba78。EVIP 内没有 I²S 逻辑。

### HDMI 无信号根因和修复

部署带音频的候选后，显示器曾报告无信号。UART 诊断显示 TMDS 串行时钟、MMCM 和像素时钟运行，但像素复位未释放，VSYNC 没有变化。复位单元的 aux_reset_in 接常量 0，同时 C_AUX_RESET_HIGH=0 将低电平解释为有效复位，因此像素域一直处于复位状态。

EmbeddedVideoIP 的 tools/package_composite_ip.tcl 将 C_AUX_RESET_HIGH 和 C_EXT_RESET_HIGH 设为 1。aux_reset_in 的低电平因此代表未请求复位；ext_reset_in 则接收反相后的系统低有效复位。复位输入极性参数见 AMD PG164《Processor System Reset Module》。

修复前诊断为 pixel_reset_released=0、vsync_seen=0，MMCM 和像素时钟已运行。修复后为 pixel_reset_released=1、serial_seen=1、vsync_seen=1、mmcm_locked=1、pixel_clk_seen=1、pixel_ext_reset=0。C1-1 USB3 Video 随后锁定 640×480、60 fps 信号。3 秒连续采集得到 180 帧，MechPlatoon 画面正常。采集截图和音频 WAV 保存在工作站 E:/Ubuntu-FPGA/out/capture/，未纳入公开仓库。

### HDMI 发送边界修复

TX 仿真发现，视频 guard band 与第一颗视频像素之间会多出一个 CONTROL 符号。该符号会打断接收器对视频数据岛/视频区边界的识别。EmbeddedVideoIP 提交 2008d713 调整了 line-slot scheduler，并在 tb_embedded_video_ip_7series_tx.sv 中增加边界检查。192 项边界检查通过。

## 构建、时序和功能验收

本次 PL 综合与实现耗时 28 分 43 秒，输入摘要为 93f5a2371c1589c7b1d9d6780725503ddb3b435c11e094b509fd10e4e227197d，ABI build ID 为 0x39EB86A3。最终时序为：

| 指标 | 结果 |
| --- | ---: |
| WNS | +0.152 ns |
| TNS | 0 |
| WHS | +0.012 ns |
| THS | 0 |
| DRC 错误 | 0 |
| Critical Warnings | 0 |

WHS 余量只有 0.012 ns，虽通过门槛，后续 RTL 改动仍须复查。其余非致命 DRC warning 仍在报告中。

EVIP video_flow.py sim 的 Python、PS C API 和 XSim 回归通过；GBA host/Flow 回归和 XSA 内容变化测试通过。Flow validate --target qspi 报告上述时序结果，Flow report 验证所有硬件和 PS 阶段产物哈希。

板上用 JTAG 部署 PL、PS 初始化文件和 app ELF。UART 直接执行 rom load 0:/games/MechPlatoon.gba 成功，ROM 为 8,388,608 bytes，标题为 MECH PLATOON，代码为 AKGE。状态为 VDMA SR 0x00011000、VDMA/DMA 错误为 0、CyclesMissing 为 0。hdmi diag 读到 HDMI_AUDIO_CTRL=1、AUDIO_STATUS=1；状态含义为音频已使能，FIFO 欠载 sticky 位为 0。

C1-1 USB3 Audio 采到 48 kHz PCM。音量为 45 时，6 秒采样的平均电平为 -62.3 dBFS、峰值 -50.9 dBFS。临时调到 70 后，平均电平为 -46.1 dBFS、峰值 -35.5 dBFS，随后恢复 45。幅度随音量设置改变，证明 HDMI 音频数据到达采集卡。尚未通过显示器扬声器主观确认听感，也未完成完整 HDMI 音频认证；默认音量 45 的采集电平偏低。

## QSPI 写入和验证

使用 manifest 绑定的 BOOT.BIN 与 FSBL 写入 QSPI 偏移 0。映像大小为 4,549,304 bytes，SHA-256 为 86560f6771094b57fe0df4decf676da599ba0e9b2d0ad36a8253bf7e8fd2751e。Flash 检测为 W25Q128JV，容量 16 MiB。实际擦除范围为 0x000000～0x45FFFF，覆盖映像并按 64 KiB sector 对齐，没有擦除整片 Flash。

Program Flash 日志报告 Blank Check Operation successful、Program Operation successful 和 Verify Operation successful。Flow manifest 的 readback_verified=true，erase_all=false。日志位于 out/board/deploy/20261116T081650Z/qspi.log，SHA-256 为 bef3ca90cd2468ffd15250b4395b4642498b96ba12e9f6bfb53d84fad40873a0。

Program Flash 报告通用 qspi-x4-single 类型与检测到的 W25Q128JV 名称不一致，但后续空白检查、编程和全范围读回比较均成功。该警告保留在原始日志中。板卡 BOOT_MODE REG 为 0x00000000，仍处于 JTAG 启动模式；本轮只确认写入与读回，没有切换启动模式，也没有做 QSPI 冷启动验证。

## 交付摘要

| 产物 | SHA-256 |
| --- | --- |
| PL bit | 028136f3905845dad141c2d6c896808bf3644ea66202635a36a04fd210f0fd55 |
| XSA | e6f28242bbf1abe4e9dd6497d5dd18d28d348f1cd7bef559de1f6374fde84719 |
| app ELF | 12e404a9e891051d9392c5839148eb12085afedac74f35395a3b0d89d4953e9a |
| BOOT.BIN | 86560f6771094b57fe0df4decf676da599ba0e9b2d0ad36a8253bf7e8fd2751e |

生成日志和采集文件保存在 out/ 或本地采集目录中。本文记录测试条件、观测结果、产物哈希和未覆盖范围。

## EmbeddedVideoIP 连续迭代索引

GBA 固定依赖 EmbeddedVideoIP 0.2.0-dev.4。以下提交均属于当前版本的依赖历史，提交号用于定位每次迭代的完整文件差异。

| 提交 | 遇到的问题和改动 | 结果 |
| --- | --- | --- |
| 6d922a7 | 增加可选 HDMI 音频。新增 PCM 异步 FIFO、Q15 增益、ACR、Audio InfoFrame、音频数据包和 7-series TMDS 数据岛逻辑；保留 Vivado 参数裁剪能力。 | 补齐库级音频接口和仿真；不包含 I²S codec。 |
| 6db6ff2 | Vivado 处理 XDC 时，时钟尚未建立，CDC 时钟组约束找不到目标。将 CDC 约束移到时钟对象生成后应用。 | 修复约束加载阶段问题。 |
| e840c38 | CDC 约束引用了不稳定的层级时钟名称。将异步时钟组绑定到 IP 作用域中的时钟端口。 | 打包后仍能稳定找到相关时钟。 |
| 2008d71 | TX 仿真发现 guard band 与首个视频像素之间出现多余 CONTROL 符号；板测又发现像素域复位没有释放。修正行槽调度器、增加运行时复位/时钟/VSYNC 状态，并修正 proc_sys_reset 的输入极性。 | 192 项 TX 边界检查、状态寄存器测试和 EVIP 仿真通过；GBA 板测恢复 640×480、60 fps 视频。 |

上述提交的 HDL、PS API、IP-XACT、打包脚本和测试差异保存在 EmbeddedVideoIP Git 仓库。GBA 的消费适配、板级结果和剩余验证限制由本记录归档。

## 2026-11-16 文档修订与依赖锁定

EmbeddedVideoIP 主分支新增文档提交 a7c480c，记录 C1-1 HDMI PCM 信号路径预验证。GBA 仍锁定经过板测的代码提交 2008d713。Flow 检查确认 a7c480c 相对锁定提交只修改 README.md 和 docs/*.md；新的回归验证文档后续提交不改变硬件/app 输入摘要，非文档源码修改仍会被拒绝。

Flow report、QSPI artifact 验证和构建计划通过。硬件阶段只做安全元数据重键，没有运行 Vivado 综合或实现。PL bit、XSA、app ELF 和 BOOT.BIN 均未变化；没有重新烧录 QSPI。

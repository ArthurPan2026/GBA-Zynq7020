# V1 验证记录

日期：2026-11-13。

注：前文记录的是 2026-11-13 的状态。最新实现和板测结果见文末的 2026-11-14 记录。

## 交付范围

V1 是配套的 PL IP 与 PS C 库，PL-only 不属于支持配置。当前唯一完成实板验证的组合是 Zybo Z7-20、XC7Z020、Zynq-7000、Vivado/Vitis 2025.2.1。PS 适配器为 Xilinx standalone/FreeRTOS VDMA 与 MMIO 实现。

本轮板测走 VDMA MM2S 输入。HLS AXI4-Stream 和 BRAM RGB565 路径通过 RTL 仿真，尚未在板上做源切换验收。其他 Vivado 器件尚未有配套 PS 适配器和板级输出配置，不标记为开箱即用。

## 库级验证

- `tb_axis_video_nn_scaler`、`tb_video_bram_rgb565_reader`、`tb_video_pipeline_v1_0` 通过。顶层仿真覆盖 VDMA、HLS、BRAM 三种源。
- `test_video_out` 通过。测试确认驱动先等待当前帧结束，之后才改视频寄存器和 VDMA 几何。
- PS 安装器的 4 个单元测试通过，覆盖重复安装、文件冲突、完整手工配置和部分配置冲突。
- Vivado 2025.2.1 将 IP 打包为 `panfpga.org:video:video_pipeline:1.0`。IP Catalog 验证通过。临时验证 BD 没有 PS AXI master，因此将无主机的 AXI-Lite 地址段排除；Zybo 消费工程接入 PS master 并分配真实地址。
- 独立 Vivado 工程注册脚本通过临时工程测试，Vivado 能在 IP Catalog 中找到该 VLNV。
- dev.2 的 Zynq-7020 OOC 综合通过：LUT 6,551（12.31%）、FF 16,377（15.39%）、BRAM 0、DSP 0；WNS +1.654 ns、TNS 0。dev.3 增加了 RGB 通道重排 RTL，本轮按要求没有为 dev.3 重新综合。

## GBA 消费工程实现

dev.2 使用 `out/video-ip-candidate` 单独输出目录完成实现，保留原有 `out/vivado`。该 bitstream/XSA 的 post-route WNS 为 +0.026 ns、TNS 为 0，DRC 0 error。dev.3 的颜色 RTL 改动尚未进入 bitstream。资源为 LUT 36,148（67.95%）、FF 48,627（45.70%）、BRAM 131.5 / 140（93.93%）、DSP 12 / 220（5.45%）。

实现报告有 ULMTCS-2 控制集警告，placed report 为 2,888 个控制集。DRC 有 9 条 REQP-1839，涉及 HDMI VDMA XPM FIFO RAMB36 异步控制；其余 DPIP/DPOP 等警告仍在 routed report 中。HDMI TMDS 输出在现有 XDC 中有 false-path 约束，因此该结果不等于外部 HDMI IO 时序已完整签核。

改动时发现一次 UART 加载的黑屏竞态。UI 过早进入 GAME 后停止 LVGL 刷新，视频层仍保留菜单模式。随后修正为加载画面保持到首个完整游戏帧停放后再切换。2026-11-13 时曾把返回菜单失败归因于 PS 驱动提前关闭活动 AXI-Stream 源；2026-11-14 的实板复现推翻了这个假设。实际失败发生在 VideoOut_Configure 的 busy 轮询超时，VDMA 没有切回菜单尺寸。最终修复见文末。MM2S 重启后仍显式停放首个游戏帧，确认 PARKPTR 为 frame 2。

此前一次硬件阶段构建命令误触发 Vivado 工程重新生成。我在 Vivado 启动 synth_1 前终止了流程。工程重生成清理了 out/video-ip-candidate 中的原始时序和 DRC 报告。dev.2 的 .bit 仍保存在 Vivado impl_1、Vitis app 和平台副本中，三处 SHA-256 都是 0c8411bec97f2e7aeeb5eff5f33a4a40018c8183f083ef7d17e599c423152544。XSA 的 SHA-256 为 6b0003e535c508207cb9b8f5a25f1c65b22d86e95179b6ded33080c0fd8eab5b。候选输出根目录没有顶层 .bit 文件。上文时序、DRC 和资源数据来自当时记录，原始报告目前无法重新打开核验。

## 实板运行

通过 XSCT 对开发板执行系统复位、bitstream 编程、PS 初始化和 ELF 下载。`APP_RUNNING` 后 PC 持续有效。ROM 通过 UART 直接路径加载。

- MechPlatoon：`0:/games/MechPlatoon.gba`，8,388,608 bytes，title `MECH PLATOON`，code `AKGE`。模式切换日志显示输入 240×160、stride 960，初始 park frame 2，VDMA 错误 0。
- Skyland：`0:/games/Skyland.gba`，24,693,968 bytes，title `SKYLAND.....`，code `SKLD`。ROM 切换后能进入 Skyland 场景。UART 状态显示 VDMA 错误 0。
- `fps 5 100`：capture 59.40 FPS、blit 59.20 FPS、blit/capture 99.7%、CyclesMissing 增量 0。
- 画面只从 OBS Virtual Camera 观察。Skyland 稳定片段连续采样 12 秒，能看到游戏场景和帧变化，没有持续全黑。

实板验证只覆盖了 VDMA 输入。HLS/BRAM 板测、其他器件适配和长时间运行仍待后续验证。

## 颜色状态

已确认颜色偏差来自 AXI4-Stream Video 分量顺序。AMD UG934 对 RGB 格式定义为 R、B、G 分量顺序；Digilent `rgb2dvi` 源码也将输入 `[23:16]` 送红、`[7:0]` 送绿、`[15:8]` 送蓝。原视频核却输出 RGB，因此绿色和蓝色互换。0.1.0-dev.3 的 RTL 已统一输入和输出顺序，仿真回归覆盖红、绿、蓝主色。按当前指示，本轮没有重新综合、实现或下载修正后的 PL。截至 2026-11-13，板上仍运行 dev.2 bitstream，修正后的颜色尚未显示。该状态已在 2026-11-14 的全量硬件构建和板测中更新，详见文末。

## 2026-11-14 重配置恢复与 GBA 复测

### 根因和修复

从游戏返回菜单时，PS app 需要把 VDMA 从 240×160 改为 640×480，并让视频 IP 从最近邻缩放切换到 1:1 旁路。旧驱动先轮询 STATUS.busy，最多读 1,000,000 次。连续 AXI4-Stream 帧可能让软件错过 busy 拉低的间隙，配置因此超时。

板上复现日志为：

    [VIDEO] configure 640x480 scale=0 result=-1 core_status=00000090->00000090 core_ctrl=0000004D vdma=240x160 stride=960 ready=1
    [UI] LT hold exit: ROM unloaded but VGA mode restore failed

ROM 卸载流程已清空 VDMA 帧缓冲。模式重配置失败后，VDMA 仍读取 240×160 的黑色帧，所以 OBS Virtual Camera 显示全黑菜单。

PS 库现在在 busy 轮询超时后发送 CTRL[11] 中止请求。视频 IP 清除当前帧状态，并暂挂 AXI 输入。PS 随后重配 VDMA 和几何参数，再提交新配置。有效配置生效后，IP 清除输入暂挂。CTRL[12] 可在 VDMA 回调失败时解除暂挂。STATUS 新增 enabled、stream_hold 和 config_pending 位，PS 库等待新配置生效后才返回成功。

这仍是唯一的 video_pipeline:1.0 IP。改动没有增加 IP 变体，也没有改写器件无关的 AXI4-Stream 像素处理接口。

### 库级验证和资源

tools/run_video_tests.sh 全部通过：

- 4 个 RTL bench：缩放器、BRAM 读取器、通用视频管线、静态直通配置。
- test_video_out：模拟 busy 一直有效，验证软件触发中止、保持输入、重配 VDMA、提交后释放输入。
- PS 库安装器的 4 个测试。

静态直通 bench 配置 640×480。测试先发一个不完整帧，再中止流。提交有效配置后，bench 确认输入恢复，并完成一帧 640×480 数据。颜色、SOF、EOL、帧计数均符合预期。

Vivado 2025.2.1 IP 打包和 IP Catalog/BD 校验通过。GBA 参数的 OOC 综合结果为 958 LUT、754 FF、128 LUTRAM、0 BRAM、0 DSP；100 MHz 下 WNS +1.478 ns、TNS 0。恢复控制比修复前同一 OOC profile 多 11 LUT、1 FF。

### GBA 全量构建

全量构建输出保存在 out/video-ip-reconfig-recovery-20261114，旧候选目录未覆盖。综合结果为 35,078 LUT（65.94%）、34,616 FF（32.53%）、131.5/140 BRAM tile（93.93%）和 12 DSP（5.45%）。

Post-route 时序为 WNS +0.251 ns、TNS 0、WHS +0.013 ns、THS 0；所有用户时序约束满足。路由状态为 63,049/63,049 条可路由网络已完成，未布线和部分布线网络均为 0。

Post-route DRC 为 0 error、0 critical warning。警告与此前候选一致：DPIP-1 20 条、DPOP-1 8 条、DPOP-2 12 条、PDCN-1569 4 条、REQP-1839 9 条、RTSTAT-10 1 条；另有 REQP-181 advisory 1 条。REQP-1839 仍涉及 HDMI VDMA XPM FIFO RAMB36 的异步控制。Vivado 向量无关功耗报告另有 Power 33-332 提示，指出默认高扇出复位活动模型可能使功耗估算不准确；这不是板级功耗测量。

产物 SHA-256：

| 产物 | SHA-256 |
|---|---|
| zynq_gba_system_wrapper.bit | 2f79bf5afdc65fa4e4e6caa5e98c99c2ef7372e7e54aca18f72573ea3f1082c9 |
| zynq_gba_system_wrapper.xsa | 36c92a81e7b7dabc4181a95d6ce75ec25b7af57f2a5c1c8d1da8861a0fa25aa1 |
| app.elf | 7022044a962ad57c522d7dc1dc268eaceaddaa0d3e553ded50b9a26d7bd03664 |

### 板上验证

XSCT 联合部署输出 PL_CONFIGURED、PS_INITIALIZED、APP_ELF_DOWNLOADED 和 APP_RUNNING。应用运行 10 s 后，PC 为 0x001B7B54，CPSR 为 0x6000001F。整个过程没有使用 computer-use；画面只从 OBS Virtual Camera 采集。

OBS Virtual Camera 初始显示完整 LVGL 菜单，颜色通道正常。UART 直接加载 0:/games/MechPlatoon.gba，ROM 为 8,388,608 bytes，title 为 MECH PLATOON，code 为 AKGE。PS 日志确认 240×160、stride 960、游戏首帧停放成功，VDMA 错误为 0。

游戏运行 5 s 的结果为：capture 59.40 fps、blit 59.20 fps、blit/capture 99.7%、CyclesMissing 增量 0、VDMA 和 DDR 错误均为 0。画面显示 MechPlatoon 开场文本。

再次长按 LT 返回菜单时，UART 日志为：

    [VIDEO] configure 640x480 scale=0 result=0 core_status=00000091->00000091 core_ctrl=00000045 vdma=640x480 stride=2560 ready=1
    [UI] LT hold exit: back to menu
    [CMD] rom loaded=0 busy=0 bytes=0 aligned=0
    [VDMA] diag cr=0x00014001 sr=0x00011000 err=0x000 v=480 h=2560 strd=0x00000A00 park=0x00000000

OBS Virtual Camera 随后采到完整菜单画面，没有停留在黑屏。该板测覆盖了从菜单到 MechPlatoon、再从游戏返回 640×480 菜单的两次模式切换。HLS/BRAM 实板源切换和其他器件适配仍未验证。

### 手柄无响应定位

在重编程后的初始状态，USB Host 枚举到 2DC8:6013 HID 接口，但“input status”显示 valid=0、reports=0，USB 诊断也没有首包。用户按方向键后，Hub 记录一次 detach/attach，设备转为 2DC8:310B XInput。随后 in_ok 和输入报告计数持续增加，菜单选中项发生变化。

项目文档中的 G30S TE 手册（TRG_Manual_G30S.TE.pdf）说明，2.4 GHz 接收器需要与已上电的手柄连接；手册也列出 View+Menu 协议切换。现有日志无法确认 6013 HID 无首包是接收器重连、手柄待机还是协议切换状态。输入恢复时，USB 状态从 6013 HID 变为 310B XInput。

调查时，6013 的 profile 使用 host-init NONE，因此没有首包超时恢复。现在 profile 会在 3 s 内没有首包时，发送一次已有的 8BitDo sideband 启动序列。input-driver-registry 单测确认了该策略。Vitis app-only 构建成功后，联合部署输出新的 ELF。板上以 310B XInput 枚举；运行 5 s 后，USB input report 已收到 100 包。此次没有触发 6013 fallback。

在干净部署状态下，用户实际长按 LT 退出 MechPlatoon，再按方向键，菜单正常响应。当前没有复现“游戏退出后 UI 输入失效”。USB 日志表明设备在 6013 HID 无首包状态和 310B XInput 有报告状态之间切换；未见 UI 菜单状态机断开 USB 的证据。

第一次排查时，我用 UART input inject 模拟 LT 长按；之后又执行了 usb portreset 和 VBUS 断电重连。这些诊断操作改变了输入状态，并让 USB Host 一度停在已连接但未绑定的状态。该状态不能作为原始用户现象的证据。完整联合部署重新初始化 USB Host 后，输入恢复。项目手册建议 2.4 GHz 接收器断连时先按 Home 重连；View+Menu 用于切换 XInput、Dinput 和 Switch Pro。后续复测应先记录 usb status 和 input status，再用实体手柄复现。

## 2026-11-14 主仓库最终复测

本节记录主仓库 `/home/pzy/Projects/Zynq-GBA_MisTer-Vivado` 的最终状态。GBA 项目调用独立 Git 仓库中的 `EmbeddedVideoIP`，固定版本 `0.1.0-dev.3`，提交为 `fc2faa222afc54d096236aaabd242e8788086209`。

### 构建问题和修复

新 XSA 创建的 FreeRTOS BSP 使用 64 KiB heap；原项目配置是 256 KiB。应用创建任务时耗尽 heap，CPU 进入 `vApplicationMallocFailedHook`，OBS 画面全黑。平台脚本现将 `freertos_total_heap_size` 固定为 262144。主仓库的首次 PS 构建因此从新目录完整编译。

同一个 BSP 默认把 XilFFS 的 `XILFFS_use_lfn` 设为 0。应用头文件后来才改为 LFN=2，库和应用的 FatFs 配置不一致。SD 菜单曾显示 0 个游戏，UART 的 `rom load` 返回 `invalid_name`。平台脚本现在在 BSP 构建前启用 `XILFFS_use_lfn=2`；UTF-8 配置应用到 BSP 和导出头文件后，再重建 `libxilffs.a`。复制库文件时会先比较内容；内容相同就保留时间戳，避免触发 app 全量重编译。修复后，ROM 直接加载成功，OBS 菜单重新枚举到 14 个游戏。

PS 工具还检查 XSA SHA-256、Vitis 工具链、FreeRTOS heap、XilFFS 配置和库哈希。新 XSA 会使用新的构建目录，并从全量 PS 构建开始。同一配置再次构建时，CMake 配置缓存命中，Ninja 输出 `no work to do`。

### PL 构建结果

当前 XSA 和 bitstream 来自现有的全量 Vivado 构建；本次没有再次综合或实现。文件放在主仓库现有的 `build` 目录。

| 产物或指标 | 结果 |
|---|---|
| Vivado | 2025.2.1 |
| 器件 | XC7Z020 |
| Post-route WNS / TNS | +0.172 ns / 0 |
| Post-route WHS / THS | +0.024 ns / 0 |
| DRC errors / critical warnings | 0 / 0 |
| XSA SHA-256 | `90a017aaac2f51fb03ba2ac397bb8328545d565d1e030e97d11b4e30376b49df` |
| Bitstream SHA-256 | `b7c682f9f7907fba5071d839da2332aac69363f4bfa2bd66f588f5d54058f303` |

### PS 构建和板测

新 XSA 的 PS 首次构建完成了 507 个 app 编译单元。修正 XilFFS 设置后又完成一次全量 app 编译。后续同 XSA 构建命中平台和 CMake 缓存，Ninja 没有重编对象文件。最终 ELF SHA-256 为 `fe574adfee4833ffa52de1e6fa6299d91551502165c28cc40e563029f5ea3899`。

通过 XSCT 只用 JTAG 编程 PL、初始化 PS 和下载 ELF，没有写 QSPI。UART 直接执行 `rom load 0:/games/MechPlatoon.gba` 成功，ROM 为 8,388,608 bytes，title 为 `MECH PLATOON`，code 为 `AKGE`。UTF-8/LFN BSP 修复前同一调用返回 `invalid_name`；修复后返回 `rom load ok`。

游戏模式配置为 240×160 输入、960 bytes 行宽、2560 bytes stride。VDMA 状态为 `cr=0x00014001`、`sr=0x00011000`，错误为 0。运行 10 秒后 UART 仍读到 `rom loaded=1`、`miss=0`、`vdma_err=0` 和 `dma_err=0`。

`fps 1 100` 返回 capture 236.82、blit 230.85、present 97.5%、blit 平均 1764 µs、CyclesMissing 增量 0。`hdmi_fps=6.97` 统计的是每 100 ms 采样时 VDMA 当前帧存储编号的变化，不是 HDMI 扫描频率，不能用它判断 HDMI 输出刷新率。

### OBS 画面

画面只从 OBS Virtual Camera 采集。10.033 秒片段为 1280×720、30 fps，共 301 帧。画面先显示 MechPlatoon 剧情文字，随后切入星球和游戏场景。黑帧检测在 4.533–5.533 秒标出一段 1 秒黑画面；前后采样画面分别显示剧情文字和后续场景。UART 显示 ROM 仍加载，VDMA 错误为 0。现有记录不能区分这段黑场来自游戏内容还是显示瞬态。

OBS Virtual Camera 视频和采样图、UART 输出、timing/DRC 报告及 bit/XSA/ELF 哈希记录都放在主仓库的 `build` 目录。HLS 和 BRAM 输入仍只完成 RTL 仿真，本轮没有在板上切换这两种源。

# 构建、验证与板级部署

## 工程环境

目标板为 Zybo Z7-20，PL 器件为 XC7Z020。工程使用 Vivado 和 Vitis 2025.2.1。

Flow 要求 Python 3.15。仓库用 `.python-version` 固定为 3.15.2。Ubuntu 22.04 的 `/usr/bin/python3` 继续由系统管理，版本仍为 3.10。用户登录 shell 的 `python` 和 `python3` 指向 uv 安装的 3.15.2。

GBA 主仓库和私有 EmbeddedVideoIP 仓库分开管理。GBA 从 `scripts/build/embedded_video_ip_consumer.tcl` 读取 EVIP 版本与提交锁。Flow 会检查 EVIP 工作区干净，并把相关源文件纳入阶段 SHA-256 指纹。

所有命令从 GBA 仓库根目录运行。Linux 示例使用 Bash：

```sh
python3 tools/flow.py --vivado /tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado \
  --vitis /tools/AMDDesignTools/2025.2.1/Vitis/bin/vitis doctor
fpga-flow plan --config fpga-flow.toml --target zybo_z7_20
```

Flow 只接受仓库内的 `out/` 作为输出根目录。

## 打开当前 Vivado 工程

仓库根目录的 Zynq-GBA_MisTer-Vivado.xpr 是历史工程快照，最后一次 Git 修改在 2026-05-06。它仍引用旧 F:、D: 盘路径，缺少当前的 `ps_pl_contract_generated.vh` 文件记录。当前 HDMI 接口的 VLNV 是 `panfpga.org:interface:tmds:1.0`。Vivado 从 `$evip_ip_repo/if/tmds_v1_0/tmds.xml` 和 `tmds_rtl.xml` 加载总线定义及 RTL 抽象定义。

当前硬件工程由 Flow 在 `out/vivado/Zynq-GBA_MisTer-Vivado.xpr` 生成。该工程记录当前 RTL、硬件契约头文件、EmbeddedVideoIP IP package 和其 `ip_repo/if` 总线定义。它与仓库根目录的旧 XPR 同名，打开时请核对完整路径。

out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr 是 Flow 的仿真工程，供 smoke、memory、CPU 和 system 仿真使用，不是硬件综合/实现工程。它由以下命令生成：

    fpga-flow validate --config fpga-flow.toml --suite rtl-smoke

打开硬件工程前，可先检查硬件阶段状态：

    fpga-flow plan --config fpga-flow.toml --target zybo_z7_20

硬件工程不存在或硬件输入已变化时，先运行 hardware stage，再打开 out/vivado/Zynq-GBA_MisTer-Vivado.xpr：

    fpga-flow build --config fpga-flow.toml --stage hardware

## PL 与 PS 阶段

PL 和 PS 分开构建。Flow 统一调度，但两边使用独立输入、缓存和输出目录。

| 阶段 | 输入 | 主要输出 | 缓存行为 |
| --- | --- | --- | --- |
| `hardware` | RTL、BD/IP、约束、硬件契约、Vivado 脚本和锁定依赖 | Vivado 工程、bitstream、XSA、路由 DCP、时序和 DRC 报告 | 指纹相同且输出哈希有效时跳过 Vivado。只有 RTL 改变而其他实现身份不变时，才尝试复用已验证 DCP。 |
| `platform` | 当前硬件阶段的 XSA | XPFM、BSP、FSBL、PS 初始化脚本 | 新 XSA 的首建全量生成一次平台。FreeRTOS heap 和 FatFs LFN 在首建前配置。 |
| `app` | 当前 XPFM 和 PS app 源码 | app ELF 和构建日志 | 源码放在稳定暂存目录。Ninja 构建目录按 XPFM 摘要固定，app 改动只重编受影响文件。 |
| `boot` | 匹配的 FSBL、bitstream 和 app ELF | BOOT.BIN 和 BIF | 任一上游摘要变化都会使该阶段失效。 |

PS 阶段只读取硬件阶段已验证的 XSA。修改 LVGL、UI 或 PS app 不会启动 Vivado。修改 PL 输入后，Flow 会阻止旧 XSA 继续进入 PS 阶段。

## 常用命令

先查看缓存决策，再运行所需阶段：

```sh
fpga-flow doctor --config fpga-flow.toml --target zybo_z7_20
fpga-flow plan --config fpga-flow.toml --target zybo_z7_20
fpga-flow validate --config fpga-flow.toml --suite host
fpga-flow validate --config fpga-flow.toml --suite rtl-smoke
fpga-flow build --config fpga-flow.toml --stage hardware
fpga-flow build --config fpga-flow.toml --stage platform
fpga-flow build --config fpga-flow.toml --stage app
fpga-flow build --config fpga-flow.toml --stage boot
python3 tools/flow.py validate --target qspi
fpga-flow status --config fpga-flow.toml --json
```

`plan` 不启动 Vivado、Vitis、XSCT 或板卡写入。它显示每个阶段会命中缓存、重建或等待上游阶段。仅影响仿真工程的 Tcl 改动会与 PL 指纹隔离；已有 bit/XSA 和报告哈希有效时，Flow 只做安全元数据重键，不启动 PL 综合或实现。

`project` 在 `out/vivado/project/` 下生成独立的仿真 Vivado 工程。它注册锁定的 EmbeddedVideoIP repository，由 IP catalog 加载其中的 `if/tmds_v1_0` 定义，再生成 BD/IP 仿真目标。该命令不会运行综合或实现。`test --suite smoke|memory|cpu|system --seed N` 需要先有与当前源文件一致的仿真工程。每轮仿真结束后 Flow 恢复项目文件快照，避免 Vivado 写入 `sim_1` 设置后破坏工程缓存。

`build` 每次只运行一个 PL 或 PS 阶段。新 XSA 会触发一次完整 platform 和 BSP 首建。相同 XSA 下的 app 改动会复用稳定的 Ninja 目录。

`deploy` 只使用同一份 manifest 绑定且哈希通过的产物。它不会自动构建：

```sh
python3 tools/flow.py deploy --target jtag --hw-server tcp:127.0.0.1:3121
python3 tools/flow.py deploy --target qspi --hw-server tcp:127.0.0.1:3121
```

`release` 是明确的完整流水线入口。它依次检查缓存、构建缺失阶段、验证产物并执行所选部署：

```sh
python3 tools/flow.py release --target jtag --jobs 4
python3 tools/flow.py release --target qspi --jobs 4
```

## 板级验证

`doctor` 会列出 FTDI 串口候选和 Zybo JTAG 目标。UART 默认优先选择稳定路径中带 `if01-port0` 的接口；首次使用前先确认它确实输出 PS 控制台。

部署 JTAG 后，可先查询 UART 状态：

```sh
python3 tools/flow.py validate --target jtag --board \
  --serial /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_210351BFB011-if01-port0
```

板级验证会发送 `help`、`status` 和 `rom status`。它记录 ROM 大小和路径、帧索引、采集序号、CyclesMissing、VDMA 状态、VDMA 错误数和 DMA 错误掩码。默认还会运行 `fps 10 100`。

需要验证 ROM 时，可以显式传入 SD 卡路径：

```sh
python3 tools/flow.py validate --target jtag --board \
  --serial /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_210351BFB011-if01-port0 \
  --rom 0:/games/MechPlatoon.gba
```

不传 `--rom` 时，Flow 不会改变当前游戏。验证脚本不发送存档命令。画面仍由你通过 OBS 虚拟摄像头检查，Flow 不会操作 OBS。

## QSPI 部署

QSPI 只在显式运行 `deploy --target qspi` 或 `release --target qspi` 时写入。Flow 使用 manifest 中匹配的 BOOT.BIN 和 FSBL，偏移为 0，擦写对应镜像，再运行 blank check 和 readback verify。

Flow 不传 `-erase_all`。通过条件是 program_flash 返回成功并完成读回校验。此结果不表示开发板已冷启动；切换启动模式和重新上电仍需单独检查。

## 输出与缓存记录

所有生成文件都位于 `out/`：

| 路径 | 内容 |
| --- | --- |
| `out/fpga-flow/manifest.json` | 唯一阶段清单、输入和工具版本、依赖摘要、输出 SHA-256、部署与板测结果 |
| `out/vivado/` | PL 工程、bitstream、XSA、DCP 和时序/DRC/QoR 报告 |
| `out/vitis/` | 平台、BSP、FSBL、稳定 app 源码暂存区、Ninja build 和 BOOT.BIN |
| `out/sim/` | RTL 仿真日志、波形和中间文件 |
| `out/board/` | JTAG、QSPI、UART 验收日志 |

Manifest 使用 schema 2 和 SHA-256 内容指纹。旧 schema 记录保存在 `legacy_manifest`，不会直接作为新缓存命中。失败阶段会记录失败状态，并保留上次成功的硬件缓存条目。

增量 DCP 的兼容摘要也写在 `out/fpga-flow/manifest.json`。DCP 文件放在 `out/vivado/`。QoR 门限为 WNS/WHS 不小于 0、TNS/THS 为 0、DRC Errors 和 Critical Warnings 为 0。若增量实现未过门限，Vivado 会清理实现运行并尝试一次干净实现。

## HDMI 与 codec 的 BD 接口

HDMI 的 VLNV 是 `panfpga.org:interface:tmds:1.0`。Vivado 从 `$evip_ip_repo/if/tmds_v1_0/tmds.xml` 和 `tmds_rtl.xml` 加载总线定义及 RTL 抽象定义。BD 将 `tmds_tx` bus 连接到顶层，物理成员使用 `tmds_tx_clk_p/n` 和 `tmds_tx_data_p/n[2:0]`，由 Zybo XDC 约束。Vivado project 使用 board part `digilentinc.com:zybo-z7-20:part0:1.2`。

GBA codec 的 BCLK、LRCLK 和串行数据组成 Vivado 标准 `i2s_tx` 接口。Vivado 将其展开为 `i2s_tx_sclk_tx`、`i2s_tx_lrclk_tx` 和 `i2s_tx_sdata_0`，并映射到 R19、T19、R18 管脚及 LVCMOS33 标准。`ac_mclk` 与 `ac_muten` 是独立信号。HDMI DDC 使用 IIC 总线，HPD 由 PS GPIO 采样。


## 四层板级验收

板级验收分为四层：部署、runtime_health、gameplay_audio_signal、speaker_cold_boot。部署阶段只确认产物哈希、PL 配置和 PS 初始化；runtime_health 通过 UART 检查时钟、VSYNC、DMA/VDMA 和音频错误；gameplay_audio_signal 加载 ROM 后使用 FFmpeg 采集 HDMI 音频并记录音量指标；speaker_cold_boot 读取独立的冷启动证据 JSON。没有采集输入或冷启动证据时，阶段必须失败，不生成通过记录。

对应套件为 board-runtime 和 board-cold-boot。开发 QSPI 使用 deploy_qspi，默认关闭读回校验；发布使用 deploy_qspi_release，固定启用读回校验。统一 bundle 输出位于 out/current/bundle.json。

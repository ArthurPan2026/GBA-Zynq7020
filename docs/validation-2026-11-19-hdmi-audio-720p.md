# 2026-11-19 HDMI 720p 音频修复与验收记录

本记录归档 GBA 项目在 1280 × 720 输出下的 HDMI 音频修复和板级证据。

## 根因

GBA 核心输出的是 signed 16-bit PCM，HDMI 音频包声明的是 24-bit LPCM。旧适配器把 16-bit 样本放在 24-bit 字的低 16 位，并做符号扩展：

```systemverilog
{{8{sample[15]}}, sample}
```

HDMI 接收端按 24-bit 样本解释后，信号幅度缩小 256 倍，理论衰减约 48.16 dB。板测与这个结果一致：修复前游戏态采样约为 `-80 dBFS`，峰值约 `-68 dBFS`。

## 修复

适配器改为左对齐 16-bit 样本：

```systemverilog
{sample_right, 8'h00, sample_left, 8'h00}
```

同步更新 `tb_gba_pcm_audio_axis.sv`，测试满幅、声道顺序、FIFO 满空、背压、溢出和复位行为。

GBA 消费端同时锁定 EmbeddedVideoIP `50c069e`，并将 FPGAFlow 的实现策略改为默认 clean。只有设置环境变量 `ZYNQ_GBA_INCREMENTAL_IMPLEMENTATION=1` 时，Flow 才会尝试复用 routed DCP。

## 构建与部署

2026-11-19 的 clean implementation 通过门槛：

| 指标 | 结果 |
| --- | ---: |
| WNS | `+0.111 ns` |
| TNS | `0 ns` |
| WHS | `+0.015 ns` |
| THS | `0 ns` |
| DRC errors | `0` |
| Critical warnings | `0` |

增量实现本轮最终 WNS 为 `-0.461 ns`，未通过门槛，流程随后自动执行 clean implementation。该结果保留在构建日志中，说明默认 clean 是必要的工程策略。

JTAG 部署完成，XSCT 记录了 `PL_CONFIGURED`、`PS_INITIALIZED`、`APP_ELF_DOWNLOADED` 和 `APP_RUNNING`。UART 验证报告：

- MechPlatoon ROM 加载成功，大小为 `8,388,608` bytes。
- 1280 × 720 VDMA 参数为 `v=720`、`h=5120`。
- `VDMA_ERR=0`，`DMA_ERR=0x000`。
- 首帧已呈现，`frame=1`，`miss=0`。

菜单本身不播放声音。启动菜单处于静音状态，不能用菜单采样判断游戏音频是否正常。

## HDMI 音频采样

使用 C1-1 USB3 Audio 采集卡，在 MechPlatoon ROM 加载后采集 12 s、48 kHz、立体声 PCM。FFmpeg 测得：

- mean volume：`-29.6 dBFS`
- max volume：`-18.7 dBFS`
- 左声道 RMS：`-29.60 dBFS`
- 右声道 RMS：`-29.57 dBFS`
- 采样中仅出现约 `0.815 s` 的静音段，未出现全程静音

原始 WAV 和 FFmpeg 指标保存在本目录。WAV 的 SHA-256 为：

```text
77ef5ca0e4c7d1876a70a5f873e5bddaf9ccb5c63000cd18f6b8e32afa4052ab
```

## 完整 RTL 回归

使用 Vivado Simulator 2025.2.1、seed `1`，并以干净的 EmbeddedVideoIP `50c069e` 工作树作为 GBA 依赖，四套 GBA RTL suite 全部通过：

| Suite | Bench 数量 | 结果 |
| --- | ---: | --- |
| `smoke` | 6 | `FLOW-SIM-SUCCESS` |
| `memory` | 6 | `FLOW-SIM-SUCCESS` |
| `cpu` | 2 | `FLOW-SIM-SUCCESS` |
| `system` | 2 | `FLOW-SIM-SUCCESS` |

`smoke` 中的 `tb_gba_pcm_audio_axis` 已报告 `16-to-24 left alignment`，并覆盖满幅、声道顺序、FIFO 满空、背压、溢出和复位。

## 证据文件

- `validation-evidence/2026-11-19/qor_gate.tsv`：Vivado QoR/DRC 门槛结果。
- `validation-evidence/2026-11-19/vivado-timing-summary.txt`：clean implementation 时序摘要。
- `validation-evidence/2026-11-19/vivado-drc.txt`：clean implementation DRC 报告。
- `validation-evidence/2026-11-19/jtag.log`：XSCT JTAG 部署记录。
- `validation-evidence/2026-11-19/uart.log`：ROM 加载和板级状态记录。
- `validation-evidence/2026-11-19/hdmi-audio-mechplatoon-20261119.wav`：C1-1 USB3 Audio 原始采样。
- `validation-evidence/2026-11-19/hdmi-audio-mechplatoon-20261119.metrics.txt`：FFmpeg 采样参数和电平结果。

用户将自行完成最终听感验收。本记录不把采集卡电平或软件状态替代为扬声器主观听感结论。

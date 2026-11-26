# 2026-11-25 dev.15 硬件构建与实板验证

## 版本和产物

| 项目 | 身份 |
|---|---|
| FPGAFlow | 0.3.0 |
| Vivado / Vitis | 2025.2.1 |
| EmbeddedVideoIP | `0.3.0-dev.15 / coreRevision 16` |
| canonical 源码树 SHA-256 | `063e4de78d03da8b587cb2c4a6f5d4ea13d3bdcc88ec8226918acbe574488e00` |
| GBA 导入 IP 目录树哈希 | `c26c588067125483094c3185de61e5baa3b6e42b910bce21cc21fae9eae20a03` |
| GBA 导入 PS 库目录树哈希 | `21bfde9676a7eabf59eee284128511a135a16c676ba6832269756d98318b144d` |
| IP ZIP SHA-256 | `b5e8dc1e0a81493be76fe8faae5ae72c2f16b2b7afc6715348dd8a1b3fd59117` |
| PS ZIP SHA-256 | `73b27f13543c164eedbcf37ba1e30233d4d5dbe553024ec249f82a42943f33ba` |
| SHA256SUMS SHA-256 | `4d7359930a4ee1e72234403bfa53c88469c35b4f61e0bdbf11636db00711905e` |
| canonical 打包时 source_commit | `3e6885f46c289955763d38caba4270e79cf7f2f8` |
| canonical 源码交付 commit | `92c1302992498f76d73abfc3942d12879cfb8c90` |
| GBA 功能交付 commit | `3e6ce0e8c31a357a7896fca9b19051da96930004` |

硬件 ZIP 文件名为 `EmbeddedVideoIP-0.3.0-dev.15-vivado-2025.2.1.zip`，PS ZIP 文件名为 `EmbeddedVideoIP-PS-Zynq7000-0.3.0-dev.15.zip`。目录锁与包哈希来自 [EmbeddedVideoIP dev.15 验证记录](https://github.com/ArthurPan2026/EmbeddedVideoIP/blob/main/docs/validation-2026-11-25.md)。

FPGAFlow workspace run `20261125T015305Z-61a7712e37` 完成 canonical 发布、IP 导入、GBA hardware/platform/app/boot、JTAG 部署、board-smoke 和 1080p60 模式确认。host/RTL 回归节点按可选配置跳过。hardware 使用 run `20261125T015310Z-f82a24c8df`。BOOT 构建为 `20261125T023701Z-4e7d3d58f4`，JTAG 部署为 `20261125T023716Z-d64bad73e2`，board-smoke 为 `20261125T023831Z-bff7f8ed33`，模式检查为 `20261125T023926Z-ff439d0762`。

## 时序和资源

最终 post-route gate 与放置后利用率来自 hardware run `20261125T015310Z-f82a24c8df`。

| 指标 | 结果 |
|---|---:|
| Setup WNS | +0.017 ns |
| Setup TNS | 0 ns |
| Hold WHS | +0.008 ns |
| Hold THS | 0 ns |
| bus-skew | 通过 |
| 实际 DRC Error | 0 |
| Critical Warning | 0 |
| OSERDESE2 时钟路径 | MMCM → BUFIO / BUFR → 8 个 OSERDESE2 |
| REQP-1975 | 0 |
| 1080p60 OSERDESE2 pulse-width | −0.320 ns |

| 放置后资源 | 使用量 | XC7Z020 容量 | 占用率 |
|---|---:|---:|---:|
| Slice LUT | 35,261 | 53,200 | 66.28% |
| Slice Registers | 33,780 | 106,400 | 31.75% |
| Block RAM Tile | 131 | 140 | 93.57% |
| DSP | 14 | 220 | 6.36% |

bitstream SHA-256 为 `fb00cbb48a168951741af4cefc888ea36259b28b2407b6eedd2ec10e8871eb92`，XSA SHA-256 为 `1a3bc999952666f02ee31b682688b1486faeaa4c1e96764e2bfe3f873d35468f`。

## 四模式板端与采集卡交叉验证

每种模式载入 MechPlatoon，等待动态场景后，同时采集 10 秒 UART 板端计数与 C1-1 USB3 Video。FFmpeg 以 MJPEG 直存。核心帧捕获率、PS 源帧提交率、PL 扫描率和采集卡解码帧数分列记录。采集卡“不同解码帧”按图像内容统计。

| 模式 | 板端核心捕获 | PS 帧提交 | PL 扫描 | FFmpeg 尺寸 / 帧率 | 采集帧 / 不同解码帧 | UART 测量 run ID |
|---|---:|---:|---:|---|---:|---|
| 480p60 | 59.4 fps | 59.3 fps | 59.9 Hz | 640×480 / 60 fps | 600 / 168 | `20261125T034934Z-4193220a48` |
| 720p60 | 59.3 fps | 59.3 fps | 59.9 Hz | 1280×720 / 60 fps | 601 / 98 | `20261125T034741Z-69e10d4f12` |
| 1080p30 | 59.4 fps | 59.3 fps | 30.0 Hz | 1920×1080 / 30 fps | 301 / 129 | `20261125T035131Z-dd1154e126` |
| 1080p60 | 59.3 fps | 59.2 fps | 59.9 Hz | 1920×1080 / 60 fps | 601 / 86 | `20261125T034523Z-d151707087` |

四档模式均报告 `sink=HDMI`、EDID 有效、HPD=1、MMCM locked、串行时钟与 VSYNC 已检测；HDMI errors、VDMA errors、DMA errors 和 `cycles_missing` 均为 0。采集文件位于 `build/fpga-flow/board/hdmi-validation-20261125/`。

| 模式 | 模式切换 run ID |
|---|---|
| 480p60 | `20261125T034857Z-5bdb9ded71` |
| 720p60 | `20261125T034659Z-ae1d2f18f3` |
| 1080p30 | `20261125T035052Z-150ce8fe48` |
| 1080p60 | `20261125T034344Z-382153ac7d` |

| 采集文件 | SHA-256 |
|---|---|
| `480p60-MechPlatoon-sync10s.mkv` | `75225fae2da93abc8fd038488f8ccd75edc855970ce152f8b0952234f45da8f1` |
| `720p60-MechPlatoon-sync10s.mkv` | `ddaa489e108554f86ecc3e5ab47f46fa2fda018df995bc76de3744e68c801f3c` |
| `1080p30-MechPlatoon-sync10s.mkv` | `b0b64fc35b7ef334514f5300689a95955e9915a1fbce96816603c7e9833ee8c7` |
| `1080p60-MechPlatoon-sync10s.mkv` | `402c48db2db61a281f08c978bf4aceeccffe10db990c5dd9d8f6ea181ab88c01` |



1080p30 菜单采集 run `20261125T035633Z-1e54649705` 得到 1920×1080、30 fps、91 帧。串口 `video ui` 显示 `mode=0 games=14 rom=0`。菜单采集 `menu-1080p30-sync.mkv` 的 SHA-256 为 `b661457fdc3be129c54698ac8a6bb76290089637e2b9f2aac956e98195261dbe`。

## 音频与菜单验收

板端音频诊断报告 `path=HDMI`、`requested=HDMI`、`err=0`、`pcm_overflow=0`。Windows C1-1 USB3 Audio 使用 FFmpeg DirectShow 采集 48 kHz 双声道 PCM，volumedetect 测得平均音量 −28.3 dBFS、峰值 −18.7 dBFS。WAV 文件 SHA-256 为 `43f5accea4f868d539e9bf618232a1f9ca940f5803d0cc7d69b3000368fa09d6`。

2026-11-24 用户目视确认游戏交接后的绿色残影、首帧等待、游戏列表滚动和路径滚动方向四项正常。

## QSPI 固化

BOOT.BIN SHA-256 为 `ad74d3f4dd0c4b138673e019c85502e727ad77e3ce2fed956d59329cfa12d8f6`，大小为 9,429,112 字节。FPGAFlow QSPI run `20261125T040042Z-7fd049a2f9` 使用 `w25q128jv-qspi-x4-single`，offset `0x0`，blank-check 开启，读回 Verify 关闭。program_flash 返回 `Flash Operation Successful`。

## 套件结果

GBA host C 测试 `build/fpga-flow/tests/host/unittest.log` 输出 `HOST_TESTS_PASS count=11`。完整 GBA host/RTL workspace 节点按可选配置跳过。

2026-11-25 workspace run `20261125T015305Z-61a7712e37` 中，UART `runtime_health` run `20261125T023939Z-8e543bfbc5` 通过。紧接的 ALSA 采集 run `20261125T023945Z-f75454d64c` 因 `FPGA_CAPTURE_INPUT` 未配置而失败。验证配置已将 `board-runtime` 限定为 UART 运行状态检查，并新增显式套件 `gameplay-audio-signal` 执行 Linux ALSA 采集；Windows DirectShow 采集作为独立板测记录。

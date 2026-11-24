# 2026-11-24 源码与实板交付记录

## 版本身份

| 项目 | 当前身份 |
|---|---|
| 工具 | Vivado/Vitis 2025.2.1，FPGAFlow 0.3.0 |
| IP | EmbeddedVideoIP 0.3.0-dev.6，coreRevision 7 |
| canonical 源码树 SHA-256 | `5256d1268ff90b1a77b089404b683987cd558c7a8b8a4a201481bc06d216153d` |
| 硬件 IP ZIP SHA-256 | `dcf43eb433a6daf7ae95c4099575474f7626a7c152b17d755ccc620fdeb70d40` |
| PS ZIP SHA-256 | `a62c647e30c4cf40f8ed52892788459b3ec410a282a602d226c6da783e180b38` |
| bitstream SHA-256 | `c20d200d06ff93cebf19d445626bca730048bbd23c1f780f123092594a9defeb` |
| BOOT.BIN SHA-256 | `ce7474251b5e37e10ad12b580a30e14979a33b038679f738889b2dbe486f2ef9` |
| 分辨率选项与音频路由修复提交 | `84fc782cb48f361a0822298053235e0e7820438f` |

IP 包在开发工作树中生成，历史来源 HEAD 为 `cda0758be7c01c13e00a6519bf505d2fe84fa512`。canonical 文件清单及哈希固定实际源码身份。EmbeddedVideoIP 源码提交 `b738f17`、快照提交 `bbefd16` 与 GBA 导入提交 `1b6e517` 关联这份源码树、消费快照和依赖锁。GBA PS 修复提交为 `522afc2`。分辨率选项与音频路由标签修复提交为 `84fc782`。

## 实现结果

hardware run `20261123T215815Z-8d4e4fd8d5` 的 `reports/qor_gate.tsv` 记录如下。

| 指标 | 结果 |
|---|---:|
| Setup WNS | +0.003 ns |
| Setup TNS | 0 ns |
| Hold WHS | +0.050 ns |
| Hold THS | 0 ns |
| 实际 DRC Error | 0 |
| Critical Warning | 0 |

bus-skew 通过。最终门禁在 route 与优化完成后检查 setup/hold 严格为正、TNS/THS 为 0、实际 DRC Error 为 0。时钟路径为 MMCM→BUFIO/BUFR→8 个 OSERDESE2，REQP-1975 为 0。1080p60 的 OSERDESE2 pulse-width `−0.320 ns` 作为已采用的超频配置单列。

## 视频与音频采集

2026-11-24 使用 FFmpeg DirectShow 同时采集 C1-1 USB3 Video 与 C1-1 USB3 Audio。视频采用 MJPEG 直通，音频采用 48 kHz 双声道 PCM。板端 video mode status、HDMI 状态寄存器与采集卡媒体流逐档核对。

| 板端模式 | HDMI 活动尺寸 | FFmpeg 视频流 | 解码帧数 | HDMI/VDMA/DMA |
|---|---:|---:|---:|---|
| 480p60 | 640×480 | 640×480，60/1 fps | 178 | errors=0，vdma_err=0，dma_err=0 |
| 720p60 | 1280×720 | 1280×720，60/1 fps | 238 | errors=0，vdma_err=0，dma_err=0 |
| 1080p30 | 1920×1080 | 1920×1080，30/1 fps | 118 | errors=0，vdma_err=0，dma_err=0 |
| 1080p60 | 1920×1080 | 1920×1080，60/1 fps | 241 | errors=0，vdma_err=0，dma_err=0 |

ffprobe 帧时间戳检查显示，60 fps 样本帧间隔中位数为 17 ms、最大 18 ms，30 fps 样本帧间隔中位数为 33 ms、最大 34 ms。blackdetect 未报告持续黑场。两帧采样的 YAVG 为 142–153，YMAX 为 255。四档 MJPEG 直通采集均无 DirectShow 实时缓冲区溢出或丢帧告警。
480p60 路径栏连续采样 8.016 s、478 帧。0.5、2、4、6 秒的 FFmpeg 裁剪帧显示路径前缀与后缀沿水平方向循环滚动。当前 C1-1 EDID 下四个固定模式均可用，显示设置页五项全部可见，当前项标记 1080p60。

1080p60 的 MechPlatoon.gba 游戏音频采集持续 6.017 s，获得 358 帧视频和 48 kHz 双声道 PCM。FFmpeg volumedetect 测得 mean 为 −26.9 dBFS、peak 为 −19.2 dBFS。板端 audio status 显示 path=HDMI、route=idle、err=0、pcm_overflow=0。

采集文件与页面截图保存在本机 E:\Ubuntu-FPGA\out\ffmpeg-qspi-validation-20261124\。

| 文件 | SHA-256 |
|---|---|
| 480p60.mkv | 4ceaa4b5a467a9b37fc78b85f9876a36d2086c59417cde35c90015eaf76eb815 |
| 720p60.mkv | 3d1338598163f789054d14b05e795e674fe8d4c242794cf84fc36f1e75572b83 |
| 1080p30.mkv | eaa087f682eca2b312518df7100d6a872694fe4b809e2c4e743f809265532fe6 |
| 1080p60.mkv | 2348cbc92fa36599fc8e557c8cc3a6c983dd817948d883d04fa459093587c00a |
| gameplay-audio-1080p60.mkv | 822defb9ca7a72898b0230d57f8813fe2482791bae36028c4273fa08fd78ab6e |
| display-options-1080p60.png | c05968378ac49e3ff6f2a7d00445a1d4a4b8287bc0437783d4a0239eb8e60376 |
| audio-options-1080p60.png | 1b64307756e874ac10484ce1488824293ed1e5d04fccfe1b83832c6eab7d8b0e |
| path-scroll-480p60.mkv | c3d1690395ed4240e5990eb2c874cb9c478c2fc6a837cb18aa0954c76a548a3c |

## 菜单与游戏交接修复

游戏首帧提交后，LVGL 控件更新曾重新唤醒自动刷新定时器，使菜单缓冲继续参与 VDMA park 切换。应用保留 LVGL 刷新定时器对象并清除自动回调，菜单从持有 VDMA 锁的入口绘制。视频任务在首帧被 VDMA 扫描后按 ROM generation 保存确认结果，再继续轮换游戏帧。

游戏列表复用行对象，选择变更只更新样式与详情，超出可见区时平滑滚动。路径显示副本保持单行，按实际宽度选择水平滚动。

JTAG run `20261124T013830Z-b30557490c` 部署后，串口出现 `first game frame presented`，随后约 10 秒提交 199 帧。`video-mode-1080p60` run `20261124T013942Z-127fbf17b2` 通过。`board-smoke` run `20261124T014020Z-f16e4b993e` 在卸载完成前检查 `rom loaded=0`，该次结果为失败。后续串口查询确认 `rom loaded=0` 和主菜单状态。

2026-11-24 用户人工复验确认绿色残影、首帧等待、列表滚动和路径方向四项正常。此项按人工验收记录。

## QSPI 编程

历史 run 20261124T014336Z-d05b0aa33c 使用通用 qspi-x4-single，Program Flash 日志显示 detected w25q128jv，并发出 Flash Mismatched 警告。该次编程成功，诊断读回与当时 BOOT.BIN SHA-256 46af4496433f3f94e017aadbfbbca81d1decf718acfc77739076c49f5173c6e5 完全一致。

本次 run 20261124T120730Z-bac6f1f2a5 使用 w25q128jv-qspi-x4-single 编程当前 BOOT.BIN，SHA-256 为 ce7474251b5e37e10ad12b580a30e14979a33b038679f738889b2dbe486f2ef9。Program Flash 检测到板载 16 MiB w25q128jv，offset=0，blank-check 成功，返回 Flash Operation Successful，日志没有 Flash Mismatched。adapter 参数为 verify=false、blank_check=true、erase_all=false。写入完成后未执行读回 Verify。

写入后 JTAG run 20261124T121442Z-3756eb8dd1 重新加载同一 BOOT 并复查运行态。ROM 未加载，1080p60 已确认，HDMI errors=0x00000000，VDMA/DMA 错误为 0，活动音频路径为 HDMI，PCM overflow 为 0。本轮没有断电冷启动。

本次 hardware 与 platform 使用已有缓存，路由 bitstream SHA-256 为 c20d200d06ff93cebf19d445626bca730048bbd23c1f780f123092594a9defeb。缓存对应 XPR SHA-256 438db216f540c7a6b4de7c1d460434861846d85936fb9c97a3d4083a5730a99b。为复用该硬件产物，构建和部署期间临时恢复对应的旧 XPR，结束后恢复当前 XPR SHA-256 df549dd0be6abc94d2307afd7efd9bd40e62417ad67c079806c1d3efc70bc0f7。当前 XPR 的 hardware 输入仍需单独构建后才能成为最新 Flow 硬件缓存。

## 本轮主机检查

2026-11-24 执行 FPGAFlow 集成、QoR 门禁与 CMake 解析定向测试，22 项通过。完整 Python 套件 47 项通过，清单测试已改为检查 bench 唯一性、必需视频测试和分组覆盖关系。host C 套件 11 项通过，包含 EDID、模式逻辑、ROM 加载进度、音频路由和 LVGL 运行时。GitHub CI run `45315752068` 的 Python、host C 与便携 RTL 均通过。

本机安装 Ubuntu 软件源的 Icarus 11.0 至用户目录后，`tb_gba_pcm_audio_axis`、`tb_gba_physical_key_mapper` 两项便携 RTL 回归通过。日志为 `build/delivery-portable-rtl.log`。工程 inventory 检查通过，并清除了 XPR 对本机自动生成 DCP 的引用。

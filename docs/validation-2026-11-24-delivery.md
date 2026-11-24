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
| BOOT.BIN SHA-256 | `46af4496433f3f94e017aadbfbbca81d1decf718acfc77739076c49f5173c6e5` |

IP 包在开发工作树中生成，历史来源 HEAD 为 `cda0758be7c01c13e00a6519bf505d2fe84fa512`。canonical 文件清单及哈希固定实际源码身份。本轮 Git 提交保存该源码树、消费快照和依赖锁。

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

2026-11-24 已有板端和 C1-1/FFmpeg 交叉核验记录。

| 板端模式 | 采集格式 | 结果 |
|---|---|---|
| 480p60 | 640×480@60 | 模式与采集对应 |
| 720p60 | 1280×720@60 | 模式与采集对应 |
| 1080p60 | 1920×1080@60 | 模式与采集对应 |

模式预览超时恢复、1080p60 保留与菜单返回已记录。1080p60 游戏音频为 48 kHz 双声道 PCM，mean 为 −29.0 dBFS，peak 为 −19.2 dBFS。板端记录 HDMI 音频路由和 PCM overflow=0。原始采集位于本机 `build/fpga-flow/board/hdmi-validation-20261124/`。

## 菜单与游戏交接修复

游戏首帧提交后，LVGL 控件更新曾重新唤醒自动刷新定时器，使菜单缓冲继续参与 VDMA park 切换。应用保留 LVGL 刷新定时器对象并清除自动回调，菜单从持有 VDMA 锁的入口绘制。视频任务在首帧被 VDMA 扫描后按 ROM generation 保存确认结果，再继续轮换游戏帧。

游戏列表复用行对象，选择变更只更新样式与详情，超出可见区时平滑滚动。路径显示副本保持单行，按实际宽度选择水平滚动。

JTAG run `20261124T013830Z-b30557490c` 部署后，串口出现 `first game frame presented`，随后约 10 秒提交 199 帧。`video-mode-1080p60` run `20261124T013942Z-127fbf17b2` 通过。`board-smoke` run `20261124T014020Z-f16e4b993e` 在卸载完成前检查 `rom loaded=0`，该次结果为失败。后续串口查询确认 `rom loaded=0` 和主菜单状态。

2026-11-24 用户人工复验确认绿色残影、首帧等待、列表滚动和路径方向四项正常。此项按人工验收记录。

## QSPI 编程

run `20261124T014336Z-d05b0aa33c` 的编程结果为成功，offset 为 0，器件为 16 MiB Winbond w25q128jv。诊断期间完整读回与 BOOT 镜像一致。后续使用 `w25q128jv-qspi-x4-single` 探测，未再出现 `Flash Mismatched`，两个部署 adapter 已指定该型号。

普通编程配置为 blank-check 开启、Verify 关闭、`erase_all=false`。冷启动状态为待用户验证。

## 本轮主机检查

2026-11-24 执行 FPGAFlow 集成、QoR 门禁与 CMake 解析定向测试，22 项通过。完整 Python 套件 47 项通过，清单测试已改为检查 bench 唯一性、必需视频测试和分组覆盖关系。host C 套件 11 项通过，包含 EDID、模式逻辑、ROM 加载进度、音频路由和 LVGL 运行时。GitHub CI 结果按最终远端提交核验。

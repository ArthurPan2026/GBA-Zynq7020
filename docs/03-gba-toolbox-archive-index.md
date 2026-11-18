# 03-GBA 与我的工具箱：全对话归档索引

本索引覆盖 Codex 对话「03-GBA 与我的工具箱」（thread ID：01a1e39e-1b6b-7e73-b738-bd83eb10c63b），时间范围为 2026 年 11 月 16 日至 18 日。它按问题和结论组织对话，不是逐字稿；各项结论链接到工程记录、证据和 Git 提交。

## 最终状态

- 工程分支为 ps-runtime-hw-sync。相关改动和记录已推送到 GitHub，远端 HEAD 为 d57d5399a3cb3ccf572c142408c84e655a9cb0f3。
- Sony 电视的 HDMI 音频切换已修复。根因是对 EDID segment 0 多发了 segment pointer 地址 0x30 的写入，NACK 后固件错误终止 EDID 基础块读取。
- 有效 HDMI EDID 到达后，固件自动优先 HDMI。无可用 HDMI sink 时保留 I²S。开机共享音量恢复为 45%，I²S codec 曲线和 HDMI Q15 曲线保持各自映射。
- 最终 BOOT 镜像已写入 QSPI 并通过空白检查与读回校验。开发板仍处于 JTAG 启动模式；没有完成 QSPI 断电冷启动。
- 左侧紫条的来源在不同采集样本中不稳定。TX 行首 RTL 仿真通过，C1-1 采集卡曾出现行首色度收敛；目前不能将其描述为所有接收设备上已完全排除。

## 对话时间线与主题

| 日期 | 对话主题 | 结果与归档入口 |
| --- | --- | --- |
| 11 月 16 日 | 阅读 02-GBA，并从 Agent 实践中查找 FPGAFlow 痛点 | 明确要求 FPGAFlow 与消费项目解耦、提高流程效率。修复产物选择不唯一、CLI 输出过大、headless 工具探测噪声、测试状态误读等问题。GBA 仅作为消费项目验证入口。见提交 9702235 和 73b3a2a。 |
| 11 月 16 日 | EmbeddedVideoIP 下一代方案调查 | 初始阶段只调查、不改代码；随后锁定 HDMI 1.4b，要求不加新功能、保留现有能力、优化结构/CDC/PPA 和消费端集成，并制作架构图。详细前序记录见工程变更日志及 11 月 16 日 HDMI/QSPI 验证记录。 |
| 11 月 16 日 | EmbeddedVideoIP 新一代架构图 | 保存可编辑 draw.io 原稿和 PNG 预览，见 docs/diagrams/embedded-video-ip-hdmi14b-nextgen-architecture.drawio 与同名 PNG。 |
| 11 月 16 日 | 实施 EmbeddedVideoIP 1.4b 方案并用 GBA 消费测试 | 按既有授权完成协议、RTL、CDC 和 GBA 消费端验证。路由后时序、DRC、RTL/Host 回归和板级验收结果分列在既有工程记录；未把 HDMI 认证或扬声器听感写成已通过。 |
| 11 月 16 日 | FPGAFlow 与 GBA 的集成测试 | 发现并修复 GBA 消费 profile 选择历史 Vitis 产物不唯一、UART 预检误警告、host/RTL smoke 成功标记不一致及 headless 版本探测问题。板测经 FPGAFlow 完成，未触碰 QSPI，直至用户之后明确授权烧录。 |
| 11 月 17 日 | HDMI 整屏偏色、音频切换闪动、左侧紫条、字符问题 | AVI InfoFrame 的 RGB 声明错误导致整体偏色，PB1 修正后颜色恢复。字符问题由 UI 刷新帧选择状态造成，之后已按用户说明不再重复排查。音频切换改用安全帧事务，减少菜单闪动。左侧紫条与整屏偏色分开处理。 |
| 11 月 17 日 | 紫条 RTL 仿真与 BMP | TX 行首标记像素仿真检查 191 行、764 个像素，并生成 BMP；TX 侧未复现紫条。C1-1 的原始 YUYV/MJPEG 行首曾观察到色度收敛，结论偏向采集卡行首处理，但没有另一台物理 HDMI 接收端或 ILA 证据。后续录像有时复现、有时不复现，不能宣称彻底解决。 |
| 11 月 17 日 | BTN0/BTN3、SW 与去抖 | BTN0 固定为 Right、BTN3 固定为 Left；SW0–SW3 对应 A/B/Select/Start。PL 加两级同步和 10 ms 稳定判定。仿真覆盖短脉冲和映射。用户确认 BTN0/BTN3 按键测试通过。真实手柄操作按用户明确要求豁免，不能标成实测通过。 |
| 11 月 17 日 | HDMI/I²S 默认音量 | 旧 HDMI 50% 沿用 codec 曲线，Q15 仅 519，约 −36 dB。之后改用独立 HDMI 线性幅度映射，50%=16384、100%=32768。I²S codec 映射没有改动。 |
| 11 月 18 日 | 退出游戏返回菜单后黑屏 | 串口显示 ROM=0，但 VDMA 请求帧与扫描帧不一致，菜单内容写在未扫描帧。PS 端加强 Park 请求读回、失败回滚，并清理退出游戏时残留的安全刷新事务。旧版回归含 48 次路由切换和 4 次游戏退出返回菜单。 |
| 11 月 18 日 | Sony 电视切 HDMI 音频失败 | 串口捕获 route error 4、EDID block 0 send error 3、sink=DVI。修复对 segment=0 跳过 0x30 写入后，同一电视读到有效 EDID、识别 HDMI，音频路由成功。 |
| 11 月 18 日 | 默认输出和 I²S 音量回退 | 电视有效 EDID 就绪后自动切 HDMI；未识别 HDMI 时继续 I²S。用户指出 I²S 听感变怪后，将开机共享音量从 50 恢复到此前的 45%，保留 codec 映射和 HDMI Q15 映射。软件路由可自动 HDMI，也通过手动 HDMI→I²S→HDMI 回归；I²S 主观听感仍待用户确认。 |
| 11 月 18 日 | Sony 电视 EDID 能力识别 | 基础块显示 SNY、产品码 0x5201、名称“SONY TV XV”、EDID 1.3；基础块 DTD 含 1080p60 和 720p60。CTA revision 3 和 HDMI VSDB 已确认。完整 CTA 视频数据块没有导出，因此不能把 1080p60 写成已验证的完整最高模式；EDID 也没有直接给出 HDMI 1.4/2.0/2.1 版本号。 |
| 11 月 18 日 | QSPI 烧录、归档与推送 | 最终 BOOT SHA 为 04130d9438ca0dd051f4a3c58604f695e191db98d12bcda8cf47b365bd3504dc。擦除范围为镜像覆盖区域，未用 erase_all；blank check、program、verify 成功。工具的 Flash Mismatched 警告保留在记录中。 |

## 决策和验证边界

- EmbeddedVideoIP 本轮目标限定为 HDMI 1.4b，保持既有功能，不增加新功能；先调查和方案，再经用户授权实施。
- GBA 作为 FPGAFlow 消费项目验证，不把 GBA 专属路径和规则硬编码进 FPGAFlow。
- 并行协作时，用户指定子智能体统一使用 gpt-6-luna Max。
- PS 侧问题优先处理；只有确认需要 PL 修改后才集中运行硬件构建。
- BTN0 固定 Right、BTN3 固定 Left；SW0–SW3 固定 A/B/Select/Start。
- 字符显示问题按用户说明视为之前已修复，本轮不重复追查。
- AXI Video 的 RGB 字节排列按接口契约保留；RGB→RBG 是通道连线重排，不是运算级，删除它不会带来可观 PPA 收益。
- 真实手柄按用户要求豁免人工复测；这不等于真实手柄输入已通过。
- HDMI/DVI 自动判定以成功读取的 EDID 与 HDMI VSDB 为依据。HPD 出现时先用 DVI-safe 模式，确认 HDMI sink 后再切 HDMI；不要把“写入 HDMI mode 成功”当成接收端能力证明。
- HDMI Q15 线性映射与 I²S codec 曲线是两条独立映射。最终默认共享百分比为 45；具体扬声器听感受电视和音箱设置影响。
- 640×480p60 是当前 GBA transmitter 固定输出时序，不代表电视最高分辨率。
- QSPI 读回验证与 QSPI 冷启动分开记录。冷启动需 JP5 设为 QSPI 后断电重上电；本轮没有执行。
- 左侧紫条曾有互相矛盾的采集结果；TX 仿真未复现，C1-1 行首色度有收敛现象。记录为未在所有物理接收端排除。

## 归档导航

- [本轮 Sony 电视、音频路由与 QSPI 验证](validation-2026-11-18-menu-audio-qspi.md)
- [较早的 HDMI 音频、复位修复和 QSPI 稳定点](embedded-video-audio-qspi-validation-2026-11-16.md)
- [EmbeddedVideoIP 消费端验证](embedded-video-ip-consumer-validation-2026-11-14.md)
- [工程变更记录与提交索引](engineering-change-log.md)
- [工程验收状态](engineering-status.md)
- [EmbeddedVideoIP HDMI 1.4b 新一代架构图（draw.io）](diagrams/embedded-video-ip-hdmi14b-nextgen-architecture.drawio)
- [架构图 PNG 预览](diagrams/embedded-video-ip-hdmi14b-nextgen-architecture.png)
- [HDMI 行首仿真 BMP](validation-evidence/2026-11-17/hdmi_tx_line_start_sim.bmp)
- [本轮归档证据](validation-evidence/2026-11-18/)

## 本轮 Git 提交

| 提交 | 内容 |
| --- | --- |
| f5559de | 建立 GBA 通用构建和板测流程 |
| 54a9a24 | 增加 FPGAFlow 消费项目配置 |
| 882845e | 建立 HDMI 音频与 QSPI 稳定点 |
| 7293dbd | 更新 HDMI 音频验收状态和文档依赖 |
| a0ff362 | 集成 EmbeddedVideoIP 0.3.0-dev.1 与 HDMI EDID 链路检测 |
| 73b3a2a | 绑定唯一 GBA 构建产物并加入 HDMI smoke 检查 |
| 9702235d8739a5d0e15993d4266b3694d7083db3 | FPGAFlow GBA 消费 profile、产物绑定和验证改进 |
| d57d5399a3cb3ccf572c142408c84e655a9cb0f3 | HDMI/DDC 修复、自动 HDMI 路由、菜单和按键修复、音量恢复及证据归档 |

两项提交已推送到 ps-runtime-hw-sync，远端 HEAD 为 d57d5399a3cb3ccf572c142408c84e655a9cb0f3。

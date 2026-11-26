# 验证矩阵

| 层级 | 内容 | 结果归档 |
|---|---|---|
| 主机 | EDID、模式选择、ROM 进度、CMake、流程与 QoR 解析 | host 测试日志 |
| RTL | GBA 子模块、系统接口、四模式视频和 PCM 采样节奏 | testbench 与 bench 记录 |
| 实现 | route 后 setup/hold、bus-skew、DRC、时钟拓扑 | hardware run 报告 |
| 软件 | platform、FSBL、应用 ELF 与 BOOT 身份 | stage run 与 bundle |
| 运行 | UART、帧计数、HDMI、VDMA 和音频状态 | `board-runtime` UART run |
| 采集 | 四模式尺寸、扫描率、图像和 PCM | Windows DirectShow 或显式 Linux ALSA suite |
| 人工 | 菜单交互、残影、滚动及显示观察 | 日期与确认项目 |
| QSPI | 指定器件写入与 blank-check | 普通写入默认关闭读回 Verify |

每份记录关联源码或输入树哈希、工具、目标板、run ID 和产物 SHA-256。完整输出保存在 `build/fpga-flow/`，精简结果进入文档。

最终实现门禁要求 setup WNS、hold WHS 严格为正，TNS/THS 为 0，bus-skew 通过，实际 DRC Error 为 0。1080p60 OSERDESE2 pulse-width 以超频实验项记录。

当前记录见[2026-11-25 dev.15 交付验证](validation-2026-11-25-delivery.md)，历史模式恢复见[1080p30 切换记录](validation-2026-11-22-1080p30.md)。

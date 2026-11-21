# 验证矩阵

| 层级 | 验证内容 | 记录位置 |
|---|---|---|
| 主机 | PS 核心逻辑与 CMake 回归 | `tests/host/` |
| RTL | GBA 子模块、系统接口和仿真场景 | `tests/rtl/`、`fpga-project.toml` 中的 `[[tests.bench]]` |
| Vivado | 综合、实现、时序与 DRC 报告 | 本地 `build/vivado/` |
| Vitis | platform、FSBL 与应用 ELF | 本地 Vitis workspace |
| 启动镜像 | FSBL、bitstream、应用 ELF 的 BOOT.BIN | 本地 `build/` |
| 板卡 | QSPI 编程、读回校验与冷启动 | 项目验证记录 |

每项验证记录应对应明确的源码提交、工具版本、目标板、输入产物和执行日期。硬件结果与板卡结果分别记录，以便从 XSA、ELF 和 BOOT.BIN 回溯来源。

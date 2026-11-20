# 验证矩阵

## 主机验证

| 类别 | 入口 | 结果文件 |
| --- | --- | --- |
| PS C 回归 | scripts/flow/run_host_regression.py | build/test-host/unittest.log |
| CMake source resolver | tests/host/test_app_source_resolver.py | 测试输出 |
| Vitis stage | tests/host/test_vitis_stages.py | 测试输出 |
| FatFs 配置 | tests/host/test_fatfs_configure.py | 测试输出 |
| LVGL 迁移 | tests/host/test_lvgl_migration.py | 测试输出 |

## RTL 验证

| Suite | 内容 | 日志位置 |
| --- | --- | --- |
| rtl-smoke | CDC、AXI、音频、按键和基础生命周期 | build/sim/smoke/ |
| rtl-memory | cache、DDR mux、DDR fault、RAM collision | build/sim/memory/ |
| rtl-cpu | CPU 和 memory mux 启动路径 | build/sim/cpu/ |
| rtl-system | frame capture 和完整 GBA startup | build/sim/system/ |

每个 bench 保存独立的 bench.json、仿真日志、输入指纹和日志哈希。

## 硬件验证

硬件验证由 FPGAFlow 阶段产生：

| 检查 | 结果 |
| --- | --- |
| Vivado synthesis | build/vivado/hardware/reports/ |
| Implementation timing | timing_summary.rpt |
| DRC | drc.rpt |
| QoR gate | qor_gate.tsv |
| XSA | build/fpga-flow/artifacts/hardware.xsa |
| Bitstream | build/fpga-flow/artifacts/bitstream.bit |
| PS app | build/fpga-flow/artifacts/app.elf |
| Boot image | build/fpga-flow/artifacts/BOOT.BIN |

## 板级证据

精简证据位于 docs/evidence/。每个文件使用日期和验证类别组织：

    docs/evidence/
    ├── 2026-11-18/
    │   ├── qspi-verify-summary.txt
    │   ├── sony-tv-edid-summary.json
    │   └── ...
    └── 2026-11-19/
        ├── qor_gate.tsv
        ├── vivado-drc.txt
        ├── vivado-timing-summary.txt
        └── ...

板级证据文件记录命令、输入 commit、工具版本、运行 ID 和结果。

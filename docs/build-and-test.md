# 构建和测试

## FPGAFlow 入口

所有正式流程通过 FPGAFlow 运行。项目路径、工具链、输入、输出、依赖和阶段顺序由 fpga-flow.toml 管理。

查看阶段计划：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli plan
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20

查看 JSON 计划：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli plan
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20
      --json

## Host 回归

    python3 scripts/flow/run_host_regression.py

测试输出：

    build/test-host/

## RTL 回归

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl-smoke
      --target zybo_z7_20

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl-memory
      --target zybo_z7_20

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl-cpu
      --target zybo_z7_20

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl-system
      --target zybo_z7_20

完整 suite：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20

## 硬件构建

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite hardware
      --target zybo_z7_20

硬件构建输出：

    build/vivado/hardware/
    build/fpga-flow/artifacts/
    build/fpga-flow/backend/

## Vitis 应用

Vitis 阶段由 FPGAFlow 的 platform、app 和 boot 阶段管理。

发布产物包括：

    build/fpga-flow/artifacts/platform.xpfm
    build/fpga-flow/artifacts/fsbl.elf
    build/fpga-flow/artifacts/app.elf
    build/fpga-flow/artifacts/BOOT.BIN

## 结果记录

每个阶段记录：

- 输入指纹。
- 工具版本。
- 命令行。
- stdout 和 stderr。
- 输出文件哈希。
- 阶段运行 ID。

记录位于：

    build/fpga-flow/runs/
    build/fpga-flow/manifest.json

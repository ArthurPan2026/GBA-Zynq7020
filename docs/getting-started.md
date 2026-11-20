# 开始开发

## 准备仓库

目录建议如下：

    workspace/
    ├── GBA-Zynq7020/
    └── EmbeddedVideoIP/

进入项目目录：

    cd GBA-Zynq7020

检查外部依赖：

    git -C ../EmbeddedVideoIP status --short --branch
    cat ../EmbeddedVideoIP/VERSION

项目配置中的锁定提交必须与外部仓库一致。

## 配置工具

确认工具路径：

    command -v python3
    command -v cmake
    command -v iverilog
    /tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado -version
    /tools/AMDDesignTools/2025.2.1/Vitis/bin/vitis --version

FPGAFlow 使用 fpga-flow.toml 中的工具链配置。临时改变路径时使用环境变量：

    export VIVADO_BIN=/tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado
    export VITIS_BIN=/tools/AMDDesignTools/2025.2.1/Vitis/bin/vitis
    export EMBEDDED_VIDEO_IP_REPO=$PWD/../EmbeddedVideoIP

## 检查接口文件

    python3 scripts/flow/generate_hw_contract.py --check

需要重新生成时：

    python3 scripts/flow/generate_hw_contract.py --write

生成文件位于：

    src/generated/ps/ps_pl_contract_generated.h
    src/generated/rtl/ps_pl_contract_generated.vh

## 第一次主机回归

    python3 scripts/flow/run_host_regression.py

输出位于：

    build/test-host/

## 第一次 RTL 回归

先生成 RTL 仿真工程：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl-smoke
      --target zybo_z7_20

随后运行完整 RTL suite：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20

生成工程位于：

    build/vivado/rtl/

## 首次硬件构建

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite hardware
      --target zybo_z7_20

硬件生成工程位于：

    build/vivado/hardware/

bitstream、XSA、FSBL、app ELF 和 BOOT.BIN 位于：

    build/fpga-flow/artifacts/

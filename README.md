# GBA-Zynq7020

GBA-Zynq7020 是运行在 Digilent Zybo Z7-20 上的 GBA FPGA 项目。工程包含 Zynq-7000 PS 软件、GBA RTL 核心、DDR 和 CDC 逻辑、HDMI 视频音频通路，以及板级验证工具。

## 项目组成

- PL：GBA 核心、视频输出、音频输出、DDR 访问和 AXI 控制寄存器。
- PS：启动服务、ROM 加载、存档、输入、菜单、HDMI 诊断和运行状态管理。
- FPGAFlow：统一管理工程生成、硬件构建、Vitis 构建、RTL 回归和证据记录。
- EmbeddedVideoIP：独立的视频 IP 仓库，由 fpga-flow.toml 锁定提交。

## 目录结构

    src/
    ├── rtl/
    │   ├── common/          公共 RTL
    │   ├── gba-core/        GBA 核心
    │   └── top/             顶层模块
    ├── bd/gba-system/       Block Design 源快照和离线 IP 源
    ├── constraints/         Zybo Z7-20 约束
    ├── generated/           由 PS/PL contract 生成的接口头文件
    └── ps/app/              Vitis PS 应用

    scripts/
    ├── flow/                FPGAFlow 后端和 RTL manifest
    ├── vivado/              Vivado 工程与硬件构建脚本
    ├── vitis/               Vitis 和 FatFs 脚本
    ├── board/               板级编程与验证脚本
    └── maintenance/         可重复使用的维护工具

    tests/
    ├── host/                CMake、PS C 和 Python 回归
    ├── rtl/                 VHDL/SystemVerilog testbench
    ├── board/               板级证据检查
    └── manifests/           RTL bench 清单

    docs/
    ├── getting-started.md   环境准备和首次构建
    ├── architecture.md      设计层次和数据路径
    ├── build-and-test.md    构建和测试命令
    ├── verification.md      验证矩阵
    └── evidence/            精简文本和 JSON 证据

    build/                   本地生成目录，不纳入 Git

## 环境准备

主机需要安装：

- Python 3.15。
- AMD Vivado 2025.2.1。
- AMD Vitis 2025.2.1。
- XSCT 和 program_flash。
- GCC、CMake、Icarus Verilog。
- 一个干净的相邻 EmbeddedVideoIP 仓库。

默认外部仓库位置：

    ../EmbeddedVideoIP

也可以设置：

    export EMBEDDED_VIDEO_IP_REPO=/path/to/EmbeddedVideoIP

依赖仓库的提交、工作树状态和输入文件由 FPGAFlow 检查。

## 快速开始

检查 PS/PL contract：

    python3 scripts/flow/generate_hw_contract.py --check

运行主机回归：

    python3 scripts/flow/run_host_regression.py

查看 RTL 计划：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli plan
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20

运行 RTL 回归：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite rtl
      --target zybo_z7_20

构建硬件：

    PYTHONPATH=/path/to/FPGAFlow/src
    python3 -m fpga_flow.cli validate
      --config fpga-flow.toml
      --suite hardware
      --target zybo_z7_20

板级下载和 QSPI 写入属于独立的部署流程，使用明确的 deploy suite。

## 生成物

所有生成物进入 build/：

    build/
    ├── fpga-flow/          FPGAFlow 运行记录和发布产物
    ├── vivado/
    │   ├── hardware/       硬件 Vivado 工程
    │   └── rtl/            RTL 仿真 Vivado 工程
    ├── vitis/              Vitis workspace 和平台
    ├── sim/                XSim 输出
    ├── test-host/          主机 C 回归输出
    └── board/              板级验证输出

两个 Vivado 工程的职责不同，工程名不同：

    build/vivado/hardware/gba-zynq7020-hardware.xpr
    build/vivado/rtl/gba-zynq7020-rtl.xpr

工程源快照位于 src/bd/gba-system/。根目录不放 .xpr。

## 开发规则

- 修改 PS/PL 接口时，先修改 config/ps-pl-contract.json，再生成接口头文件。
- 修改 RTL、Block Design 或约束后，运行对应 RTL 回归和硬件 plan。
- 修改 PS 应用后，运行主机回归。
- 新增验证结果时，只提交文本、JSON、报告和必要的来源说明。
- 生成的 bitstream、XSA、ELF、BOOT.BIN、XSim 数据和缓存进入 build/。
- Python 文件使用下划线命名。
- HDL 文件使用下划线命名，并保持实体名、模块名和文件名一致。
- 文档和目录使用小写短横线命名。

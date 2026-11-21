# GBA-Zynq7020

GBA-Zynq7020 是面向 Digilent Zybo Z7-20 的 FPGA 游戏机项目。硬件工程使用 Vivado 管理，处理系统软件使用 Vitis 管理。

## 目录

- `vivado/gba-zynq7020.xpr`：唯一的 Vivado 硬件工程入口。
- `vivado/gba-zynq7020.srcs/`：Block Design、wrapper 和工程源文件引用。
- `ip-repo/embedded-video-ip/`：项目使用的 EmbeddedVideoIP Vivado IP 包。
- `src/rtl/`：GBA 核心及项目 RTL。
- `src/ps/app/src/`：Vitis 应用源码，含 EmbeddedVideoIP PS 库。
- `src/constraints/`：Zybo Z7-20 引脚和时序约束。
- `config/`：PS/PL 接口契约。
- `fpga-project.toml`：维护者使用的项目与测试声明。
- `scripts/`：工程维护与构建辅助脚本。
- `tests/`：主机、RTL 与板级测试源。
- `build/`：本机生成物。

Vivado 的 `.runs`、`.cache`、`.gen` 等工作目录位于 `vivado/`，并由 Git 忽略。Vitis platform、应用输出、启动镜像和其他构建文件放入本机输出目录。

## GUI 构建与部署

完整流程见 [开始开发](docs/getting-started.md) 与 [构建和部署](docs/build-and-test.md)。

1. 克隆仓库，用 Vivado 2025.2.1 打开 `vivado/gba-zynq7020.xpr`。
2. 生成 Block Design 输出产品，运行综合、实现和 Generate Bitstream。
3. 导出包含 bitstream 的 XSA。
4. 在 Vitis 2025.2.1 基于 XSA 创建 FreeRTOS platform，创建应用并构建 ELF。
5. 在 Vitis 中生成包含 FSBL、bitstream 和应用 ELF 的 `BOOT.BIN`。
6. 通过 Vitis Program Flash 写入 Zybo Z7-20 QSPI，并启用校验。

## 依赖

EmbeddedVideoIP 的版本、VLNV、Vivado 版本、来源提交和发布包 SHA-256 记录在 [fpga-project.toml](fpga-project.toml)。FPGAFlow 根据这些声明生成输入锁。硬件 IP 与 PS C 库以各自许可和目录结构随本项目提供。

## 许可

项目许可按内容范围管理，详见 [LICENSES/README.md](LICENSES/README.md)。GBA 核心保留其 GPL-2.0 许可；AMD/Xilinx 与其他第三方组件保留各自的版权和许可声明。

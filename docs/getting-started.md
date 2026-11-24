# 开始开发

## 准备环境

安装 Vivado/Vitis 2025.2.1、Zynq-7000 支持和 Zybo Z7-20 板卡文件。安装 Python 3.15 与 FPGAFlow 0.3.0。

```sh
git clone https://github.com/ArthurPan2026/FPGAFlow.git
python3.15 -m pip install './FPGAFlow[uart]'
git clone https://github.com/ArthurPan2026/GBA-Zynq7020.git
cd GBA-Zynq7020
```

本地主机配置保存 Vivado/Vitis 路径、hw_server 地址和 UART 设备。具体格式见 FPGAFlow README。项目清单保存工具版本和目标板身份。仓库内已有锁定的 EmbeddedVideoIP 快照。

## 首次构建

```sh
fpga-flow --project fpga-project.toml inventory
fpga-flow --project fpga-project.toml plan --target zybo_z7_20
fpga-flow --project fpga-project.toml build --stage boot --with-deps
fpga-flow --project fpga-project.toml deploy --target zybo_z7_20 --stage deploy_jtag --allow-destructive
```

运行结果位于 `build/fpga-flow/runs/`，当前交付视图位于 `build/fpga-flow/current/`。开发中修改应用后，继续构建 boot，Flow 会核对并复用硬件与 platform。

## 更新 IP

```sh
git clone https://github.com/ArthurPan2026/EmbeddedVideoIP.git ../EmbeddedVideoIP
fpga-flow --workspace fpga-workspace.toml plan --json
fpga-flow --workspace fpga-workspace.toml run --allow-side-effects --allow-destructive
```

workspace 先验证并生成 canonical 发布包，再校验导入 GBA。GBA host/RTL 回归可用 `--include-optional` 选择。

## GUI 与固化

Vivado GUI 打开 `vivado/gba-zynq7020.xpr`。Vitis 使用 `src/ps/app/src/app.yaml` 和本次 XSA。GUI 的详细步骤、QSPI 参数与最终时序门禁见[构建和部署](build-and-test.md)。

## 文档入口

[系统架构](architecture.md) · [维护说明](fpga-flow-maintainer.md) · [验证矩阵](verification.md) · [当前交付记录](validation-2026-11-24-delivery.md)

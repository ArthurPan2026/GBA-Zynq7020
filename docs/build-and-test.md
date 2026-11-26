# 构建和部署

## FPGAFlow 构建

安装 FPGAFlow 0.3.0 和 Vivado/Vitis 2025.2.1，在仓库外的本地配置中设置工具路径、硬件服务器与串口。

```sh
fpga-flow --project fpga-project.toml doctor --stage hardware
fpga-flow --project fpga-project.toml build --stage boot --with-deps
fpga-flow --project fpga-project.toml deploy --target zybo_z7_20 --stage deploy_jtag --allow-destructive
```

hardware 生成 bitstream 与 XSA，platform 生成 FreeRTOS BSP 与 FSBL，app 编译应用，boot 生成启动镜像。每个阶段按实际输入和依赖产物判断缓存。运行目录位于项目内 `build/fpga-flow/runs/<run-id>/`。

## 更新 EmbeddedVideoIP

将 canonical `EmbeddedVideoIP` 克隆到 GBA 的相邻目录。workspace 依次完成 canonical 验证与发布、校验导入、GBA 构建、JTAG 和板级验证。

```sh
fpga-flow --workspace fpga-workspace.toml plan --json
fpga-flow --workspace fpga-workspace.toml run --allow-side-effects --allow-destructive
```

GBA host/RTL 节点设为可选，`--include-optional` 将其加入运行。导入器同步硬件 IP、PS 库及依赖锁，保存 ZIP 和目录树哈希。具体阶段见[维护说明](fpga-flow-maintainer.md)。

## Vivado/Vitis GUI

在 Vivado 2025.2.1 打开 `vivado/gba-zynq7020.xpr`，生成 BD 输出产品，依次运行综合、实现与 bitstream，并导出包含 bitstream 的 XSA。

在 Vitis 使用该 XSA 建立 `platform`，输出至 `src/ps/platform/`，配置 `ps7_cortexa9_0` FreeRTOS domain、262144 字节 heap 和 `xilffs`。FatFs 使用 `FILE_SYSTEM_USE_LFN=2`、`FF_LFN_UNICODE=2`、`FF_CODE_PAGE=437`、`FF_MAX_LFN=255`、`FF_LFN_BUF=765`、`FF_SFN_BUF=34`。

基于该 domain 导入 `src/ps/app/src/app.yaml` 所在源码目录并构建。Boot Image 按 FSBL、bitstream、应用 ELF 的顺序生成 `BOOT.BIN`。XSA、FSBL 和 ELF 对应同一硬件版本。

## 最终实现门禁

place 阶段报告用于诊断，route 与后续优化完成后执行最终门禁。setup WNS 和 hold WHS 严格大于 0，TNS/THS 为 0，bus-skew 通过，实际 DRC Error 为 0。1080p60 的 OSERDESE2 pulse-width 超频项在报告中单列。

## QSPI

```sh
fpga-flow --project fpga-project.toml deploy --target zybo_z7_20 --stage deploy_qspi --allow-destructive --allow-side-effects
```

Flash 型号为 `w25q128jv-qspi-x4-single`，容量 16 MiB，offset 为 0，blank-check 开启，读回 Verify 默认关闭，按镜像范围擦除。`deploy_qspi_release` 提供开启读回 Verify 的阶段。

## 验证

```sh
fpga-flow --project fpga-project.toml validate --suite host-regression
fpga-flow --project fpga-project.toml validate --suite rtl --target zybo_z7_20
fpga-flow --project fpga-project.toml validate --suite board-smoke --target zybo_z7_20 --allow-side-effects
fpga-flow --project fpga-project.toml validate --suite board-runtime --target zybo_z7_20 --allow-side-effects
```

`board-runtime` 检查 UART 返回的时钟、HDMI、VDMA 和音频路由状态。`gameplay-audio-signal` 是独立的 Linux ALSA 采集套件，设置 `FPGA_CAPTURE_FORMAT=alsa` 与 `FPGA_CAPTURE_INPUT` 后运行。Windows DirectShow 采集归档在板级验证记录中。

主机逻辑、RTL、最终时序、板端诊断、图像采集和人工验收的记录方式见[验证矩阵](verification.md)。

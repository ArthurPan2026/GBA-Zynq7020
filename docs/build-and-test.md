# 构建和部署

## Vivado 硬件流程

在 Vivado 2025.2.1 打开 `vivado/gba-zynq7020.xpr`。

1. 对 `zynq_gba_system.bd` 执行 **Generate Output Products**。
2. 执行 **Run Synthesis**。
3. 执行 **Run Implementation**。
4. 执行 **Generate Bitstream**。
5. 通过 **File → Export → Export Hardware** 导出包含 bitstream 的 XSA。

Vivado 项目保存在 `vivado/`。项目源文件与工程文件一起提交；运行、缓存和临时生成目录由 Git 忽略。Vivado 报告与硬件输出可保存在 `build/vivado/`。

## Vitis platform 与应用

在 Vitis 2025.2.1 中基于本次导出的 XSA 创建名为 `platform` 的 platform component，并将输出位置设为 `src/ps/platform/`。为 `ps7_cortexa9_0` 配置 FreeRTOS domain、262144 字节 heap 和 `xilffs`。FatFs 配置使用 `FILE_SYSTEM_USE_LFN=2`、`FF_LFN_UNICODE=2`、`FF_CODE_PAGE=437`、`FF_MAX_LFN=255`、`FF_LFN_BUF=765`、`FF_SFN_BUF=34`。

创建应用 component，指定 `src/ps/app/src/app.yaml` 对应的应用源码。应用组件会使用仓库中的 `Video/Lib` 源码。platform 导出到 `src/ps/platform/export/platform/`，与 `app.yaml` 中的 domain 路径一致。完成 platform 与应用构建后，记录本次使用的 XSA、platform 和 ELF，确保三者来自同一次硬件版本。

## BOOT.BIN 与 QSPI

Boot image 中按启动顺序加入 FSBL、bitstream 和应用 ELF，生成 `BOOT.BIN`。通过 Vitis **Program Flash** 选择 `qspi-x4-single`、QSPI offset `0x0`、容量 16 MiB，启用 Blank Check 和 Verify。使用与 XSA 相匹配的 FSBL。

写入前确认目标为 Zybo Z7-20；写入后执行冷启动并确认应用启动。

## RTL 与主机回归

仓库保留 host C、Python 与 RTL 测试源，供维护者在修改对应模块后运行。RTL testbench 与文件清单位于：

- `tests/rtl/`
- `fpga-project.toml` 中的 `[[tests.bench]]`

Host C 回归源位于 `tests/host/ps/`。各测试脚本及 Vivado 仿真工程位于 `scripts/flow/` 与 `build/`。测试输出写入 `build/`，不纳入源码提交。

## 版本一致性

EmbeddedVideoIP 硬件 IP 和 Zynq-7000 PS 库的版本与来源在 `fpga-project.toml` 中声明。更新依赖包时，同时更新 `ip-repo/embedded-video-ip/`、`src/ps/app/src/Video/Lib/` 和项目依赖声明。FPGAFlow 重新计算输入哈希并生成运行记录。

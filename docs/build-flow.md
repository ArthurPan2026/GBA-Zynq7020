# 构建、验证与部署

## 环境

工程使用 Zybo Z7-20、Vivado 2025.2.1、Vitis 2025.2.1 和 Python 3.15。安装 FPGAFlow 及其 UART 可选依赖后，在仓库根目录运行以下命令。

```sh
fpga-flow doctor --config fpga-flow.toml --target zybo_z7_20
fpga-flow plan --config fpga-flow.toml --target zybo_z7_20
```

`plan` 只读取配置、Git 状态、输入和已有产物。它不会运行 Vivado、Vitis 或写入开发板。

`fpga-flow.toml` 与 `scripts/build/embedded_video_ip_consumer.tcl` 锁定 EmbeddedVideoIP 提交。默认从相邻的 `../EmbeddedVideoIP` 读取依赖。需要其他位置时，设置 `EMBEDDED_VIDEO_IP_REPO`。依赖工作树必须干净。仅修改 `README.md` 或 `docs/*.md` 的后续提交可以复用锁定代码。

## 构建和仿真

```sh
fpga-flow validate --config fpga-flow.toml --suite host
fpga-flow validate --config fpga-flow.toml --suite rtl-smoke
fpga-flow validate --config fpga-flow.toml --suite rtl
fpga-flow build --config fpga-flow.toml --stage boot --with-deps
```

`host` 运行本地主机 C 回归。`rtl-smoke` 运行 smoke 集合，`rtl` 依次覆盖 smoke、memory、CPU 和 system 集合。仿真工程位于 `out/vivado/project/`，测试入口位于 `tests/rtl_manifest.toml`。每个 bench 记录独立输入指纹和日志哈希；通过且输入未变的 bench 可以复用。测试使用固定 seed 1。

`boot --with-deps` 依次检查 hardware、platform、app 和 boot。hardware 使用完整实现，检查 WNS、WHS、TNS、THS 和 DRC，再生成 bitstream 与 XSA。首次构建或硬件输入变化会启动 Vivado，耗时较长。相同 XSA 下，app 阶段复用对应的 Ninja 构建目录。

## 产物和部署

所有构建阶段都有效后，FPGAFlow 把匹配的 bitstream、XSA、FSBL、PS 初始化脚本、app ELF 和 BOOT.BIN 发布到 `out/current/`。`bundle.json` 记录输入、依赖和产物哈希。部署前，Flow 会重新检查阶段状态和 bundle；部署命令不会自动构建。

```sh
fpga-flow deploy --config fpga-flow.toml --target zybo_z7_20 --stage deploy_jtag --allow-destructive
fpga-flow deploy --config fpga-flow.toml --target zybo_z7_20 --stage deploy_qspi --allow-destructive
```

`deploy_qspi` 用于开发，默认不做读回校验。发布时使用 `deploy_qspi_release`，它要求读回校验。`release` 先完成构建和测试，只有显式指定 `--deploy` 才写入 QSPI。

```sh
fpga-flow release --config fpga-flow.toml --target zybo_z7_20 --deploy --deploy-stage deploy_qspi_release --allow-destructive --allow-side-effects
```

两种 QSPI 命令均不使用 `-erase_all`。编程、读回和冷启动分别记录。

## 板级验收

板级记录分为部署、运行状态、游戏音频信号和冷启动四层。

1. `deploy_jtag` 或 `deploy_qspi_release` 记录所选 bundle 和工具输出。
2. `runtime_health` 通过 UART 检查 HDMI 时钟、VSYNC、DMA/VDMA 和音频状态。
3. `gameplay_audio_signal` 确认 ROM 已加载、帧序号前进、音频路由正确，再使用 FFmpeg 采集音频并记录哈希和电平。该检查证明采集到非静音信号，听感由人工验收。
4. `speaker_cold_boot` 把操作人确认的断电重启和扬声器结果，与同一 bundle 的 QSPI 读回和新的运行状态记录关联。

音频采集脚本在 Linux 主机上运行。请将采集卡连接到该主机，安装 FFmpeg，并设置 `FPGA_CAPTURE_INPUT`。ALSA 输入可同时设置 `FPGA_CAPTURE_FORMAT=alsa`。菜单静音不作为游戏音频失败的依据。

```sh
fpga-flow validate --config fpga-flow.toml --suite board-runtime --target zybo_z7_20 --allow-side-effects
```

冷启动前，先完成 `deploy_qspi_release`。重新上电后，在 `out/board/cold_boot_evidence.json` 填写当前 `bundle_id`、`operator`、`cold_boot_observed`、`speaker_signal` 和带时区的 `power_cycle_at_utc`。两项观察均须由操作人确认，时间须晚于 QSPI 编程。然后运行：

```sh
fpga-flow validate --config fpga-flow.toml --suite board-cold-boot --target zybo_z7_20
```

该套件先重新检查运行状态，再验证人工记录。缺少证据、bundle 不匹配或时间顺序错误时，检查会失败。

## 记录和 CI

`out/fpga-flow/manifest.json` 索引当前阶段，`out/fpga-flow/runs/` 保存每次运行的证据。`out/current/bundle.json` 保存交付产物与部署状态。历史 Flow 源码及旧测试保存在 `docs/archive/legacy-flow-2026-11-20/`，不再作为命令入口。

GitHub Actions 在托管的 Ubuntu 环境运行 Python、Host C 和可移植 RTL 检查。完整 XSim 工作流使用自建 Runner。手动运行需要 `vivado` 标签；定时运行还需要将仓库变量 `VIVADO_RUNNER_ENABLED` 设为 `true`。自建 Runner 必须预先安装 FPGAFlow、Python、Vivado 和锁定的私有依赖。工作流不执行综合、实现或板卡写入。

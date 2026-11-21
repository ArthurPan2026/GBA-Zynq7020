# 开始开发

## 准备

克隆 GBA-Zynq7020，并安装 Vivado 与 Vitis 2025.2.1。Vivado 需要识别 Zybo Z7-20 器件与板卡文件。Vitis 需要包含 Zynq-7000、FreeRTOS、Bootgen 和 QSPI 编程支持。

Vivado IP Catalog 使用仓库内的 `ip-repo/embedded-video-ip/ip_repo`。该目录与 XPR 一起版本管理，克隆后可直接打开工程。

## Vivado：构建硬件并导出 XSA

1. 启动 Vivado，选择 **Open Project**，打开 `vivado/gba-zynq7020.xpr`。
2. 在 Sources 中展开 `zynq_gba_system`。首次打开时右键 Block Design，选择 **Generate Output Products**。
3. 运行 **Run Synthesis**，再运行 **Run Implementation**。
4. 运行 **Generate Bitstream**。
5. 选择 **File → Export → Export Hardware**，勾选 **Include bitstream**，导出 `gba-zynq7020.xsa`。将 XSA 保存到工作区的 `build/hardware/`。

## Vitis：创建 platform 与应用

1. 在 Vitis 2025.2.1 打开工作区，选择 **Create Platform Component**，以刚导出的 XSA 创建 platform。
2. 将 platform component 命名为 `platform`，输出到 `src/ps/platform/`。在 platform 中为 `ps7_cortexa9_0` 创建 FreeRTOS domain，并启用 `xilffs`。
3. 将 FreeRTOS 总 heap 配置为 262144 字节。
4. 配置 FatFs 长文件名：`FILE_SYSTEM_USE_LFN=2`、`FF_LFN_UNICODE=2`、`FF_CODE_PAGE=437`、`FF_MAX_LFN=255`、`FF_LFN_BUF=765`、`FF_SFN_BUF=34`。
5. 构建并导出 platform。
6. 选择 **Create Application Component**，使用该 platform 的 `freertos_ps7_cortexa9_0` domain，导入 `src/ps/app/src/app.yaml` 所在的应用源码目录。
7. 构建应用。应用所需的视频 PS C 源码已位于 `src/ps/app/src/Video/Lib/`，随应用一同编译。

Vitis platform 的导出目录为 `src/ps/platform/export/platform/`，应用的 domain 路径由 `src/ps/app/src/app.yaml` 指向该位置。platform、BSP 和应用构建文件均由 Git 忽略。

## 生成 BOOT.BIN 并写入 QSPI

1. 在 Vitis 的 Boot Image 工具中建立 Zynq-7000 boot image，依次添加 FSBL（设置为 bootloader）、Vivado bitstream 和应用 ELF。
2. 生成 `BOOT.BIN`。
3. 在 Vitis 中打开 **Program Flash**，连接目标板，选择 QSPI single、x4 配置 `qspi-x4-single`，设置地址 `0x0`。
4. 选择 `BOOT.BIN` 和匹配的 FSBL，执行 Blank Check、Program 与 Verify。
5. 断电重启目标板，确认应用从 QSPI 启动。

## 工程位置

- Vivado 工程：`vivado/gba-zynq7020.xpr`
- Block Design：`vivado/gba-zynq7020.srcs/sources_1/bd/zynq_gba_system/zynq_gba_system.bd`
- EmbeddedVideoIP：`ip-repo/embedded-video-ip/ip_repo/`
- Vitis 应用源：`src/ps/app/src/`
- 本地构建输出：`build/`

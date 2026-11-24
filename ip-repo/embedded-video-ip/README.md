# EmbeddedVideoIP Vivado IP 包

本指南适用于只需要 Vivado 硬件 IP 的工程。发布 ZIP 已包含 Catalog 所需的 IP 文件、接口定义、版本元数据和 CERN-OHL-W-2.0 许可。

## 加入 Vivado IP Catalog

1. 下载与本机 Vivado 版本匹配的 `EmbeddedVideoIP-<version>-vivado-<version>.zip`。
2. 解压至本机依赖目录。
3. 在 Vivado 工程打开 **Settings → IP → Repository**。
4. 添加解压目录下的 `ip_repo/`，刷新 Catalog。
5. 在 Block Design 中加入 `panfpga.org:video:embedded_video_ip:1.0`。

完整接口说明见 [组合式 IP 接口](composite-ip-api.md) 和 [寄存器映射](register-map.md)。发布包的来源提交、工具版本与文件哈希记录在 `RELEASE-METADATA.json`。

## 通过 Vitis 使用 PS 库

Vitis 软件组件单独发布为 `EmbeddedVideoIP-PS-Zynq7000-<version>.zip`。该包包含 `Video/Lib` 目录、集成说明、版本和 Apache-2.0 许可。应用集成步骤见 [构建和使用](build-and-use.md#vitis-ps-library)。

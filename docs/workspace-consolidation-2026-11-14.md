# GBA 工程目录与版本归档

归档日期：2026-11-14。

## 保留的工程目录

GBA 消费工程统一放在 `/home/pzy/Projects/Zynq-GBA_MisTer-Vivado`。可复用视频库仍是独立项目，位于 `/home/pzy/Projects/EmbeddedVideoIP`，不会复制进 GBA 仓库。EmbeddedVideoIP 当前提交为 `fc2faa222afc54d096236aaabd242e8788086209`，版本为 `0.1.0-dev.3`。

## 原副本的 Git 归档

清理目录前，先将副本的历史引用和工作区状态保存在 GBA 主仓库的 `refs/archive/` 下。

| 原目录 | 归档记录 |
|---|---|
| `Zynq-GBA_MisTer-Vivado` 初始工作区 | `refs/archive/pre-consolidation-2026-11-14`，提交 `e4fcafc8657e4cc919690b3aa96fe124ff21653d`。 |
| `Zynq-GBA_MisTer-Vivado.baseline-2026-11-08` | 分支和远端引用位于 `refs/archive/baseline/`。修改后的工作区快照为 `refs/archive/baseline/pre-delete-2026-11-14`，提交 `fd33b2efed196c1a2dc736725a1b0b11c0a4cd9b`。 |
| `Zynq-GBA_MisTer-Vivado-improve` | 本地分支、远端跟踪分支和原归档引用位于 `refs/archive/improve/`。工作区快照为 `refs/archive/improve/pre-delete-2026-11-14`，提交 `658930e492641eab43b878f798a78e79eafb0e92`。 |
| `Zynq-GBA_MisTer-Vivado-evip-candidate` | 此目录没有独立 Git 历史。非忽略文件快照为 `refs/archive/evip-candidate/pre-delete-2026-11-14`，提交 `1b25b9bf8caeed0fae40b351ee5b4132b9938e45`。 |

baseline 和 improve 的分支历史均已导入主仓库。improve 的远端跟踪分支还包含功耗测量提交 `5592e8f5972b8271bd2edf0b7e54ceb8b326e415`。候选目录以快照提交保存其源文件和非忽略工作区文件。

归档快照引用保留在开发机的本地 Git 中，本次不把这些自定义引用推到公开 GBA 仓库。EmbeddedVideoIP 完整源代码已推入独立私有仓库。

Windows 临时编辑包也已分别存入对应仓库的本地归档引用。GBA 快照为 `refs/archive/local-edit-gba-2026-11-14`，提交 `76dfb597ce0eb72173010cabe448d87d5d66bde6`。EmbeddedVideoIP 快照为 `refs/archive/local-edit-2026-11-14`，提交 `5b565caa3c393bdc06f7437602d76518452e16db`。

## 构建产物与测试记录

从主仓库、baseline、improve 和候选副本共发现 238 份 `.bit`、`.xsa`、`.elf` 文件。按 SHA-256 去重后，共保存 79 个版本，原始内容总计 1,227,689,906 bytes。清单 `artifacts/archive/deployable-artifacts-inventory.json` 记录每个版本的哈希、归档路径和原始路径。文件放在 `artifacts/archive/deployables/sha256/`，当前稳定版本和 baseline 另放在具名目录。

当前通过板测的 bitstream、XSA、ELF、Vivado 时序和 DRC 报告、PS 构建日志、UART 输出、OBS 视频与菜单截图，集中保存在 `artifacts/validated/2026-11-14/`。XSA 内嵌 bitstream 与独立 bitstream 的 SHA-256 相同。验证细节见 `docs/embedded-video-ip-consumer-validation-2026-11-14.md`。

两个只有诊断日志的临时目录也已纳入版本管理：`docs/archive/rom-progress/from-MisTer-Vivado/` 和 `docs/archive/rom-progress/from-Vivado/`。日志内容保持原样。

归档保存所有发现的部署产物版本。Vivado/Vitis 可再生成的中间缓存和历史 DCP 不作为发布产物归档；当前成功路由 DCP 仍保留在主仓库的 `.build_cache/` 中。

## 清理结果

归档并核对哈希后，已删除 GBA 的 baseline、improve、候选副本和两处日志临时目录。`/home/pzy/Projects` 下的其他无关项目不在本次清理范围内。
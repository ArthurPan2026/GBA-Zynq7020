# 工程变更记录

更新时间：2026-11-12。

本文件索引本项目在此前对话和本轮工作中完成的改动。Git 提交保存已提交改动的逐文件差异；当前未提交改动在本文件中逐路径记录。已有技术调查与实板结果继续保存在 [工程状态记录](engineering-status.md)。

## 记录规则

以后每次修改代码、配置、构建脚本或硬件工程，都在本文件追加一条记录。条目应写明日期、文件路径、改动原因、验证结果和生成或复用的交付物。计划但未实施的工作要单独标为“未实施”。

查看某个历史提交的逐文件路径和差异：

```sh
git show --name-status <提交号>
```

## 历史对话提交索引

以下 25 个提交构成当前分支从初始可综合版本到工程稳定点的历史索引。每个提交都包含完整逐文件差异；表中摘要用于定位功能阶段。

| 提交 | 日期 | 改动主题 |
| --- | --- | --- |
| `ca9247f` | 2026-04-07 | 初始化并提交当前可综合实现版本 |
| `2502795` | 2026-04-11 | 实现 PS 侧 BRAM 取帧显示链路并补充像素调试 |
| `9d9d0c2` | 2026-04-12 | reorganize ps runtime and sync hardware updates |
| `75d358e` | 2026-04-12 | WIP: sync current workspace snapshot |
| `c99368a` | 2026-04-14 | 修复大容量 GBA ROM 兼容性并补充 PS 侧探针 |
| `8cd23ce` | 2026-04-14 | 完善 PS 运行时 USB 主机与 8BitDo 手柄支持 |
| `3f04a48` | 2026-04-15 | 改进手柄输入按帧锁存，缓解单击多步问题 |
| `5333b05` | 2026-04-15 | 提交当前项目版本：优化显示链路与 FPS 诊断 |
| `06e7ad3` | 2026-04-16 | 同步当前版本项目代码 |
| `cdaae7c` | 2026-04-16 | Improve USB hotplug handling and sync current workspace changes |
| `2e61fd7` | 2026-04-16 | 音量控制按 dB 标准重构并调整默认音量 |
| `37ae7bd` | 2026-04-18 | 完成 PS/PL 功能补齐与启动稳定性修复（含 savestate/RTC/视频增强框架） |
| `2404ced` | 2026-04-21 | feat(ps/pl): 补齐 GBA 核心能力并重构运行时链路 |
| `8450f1d` | 2026-04-22 | feat: 完成 GBA 核心功能补齐与 USB 主机稳定性修复（PS/PL） |
| `d570e09` | 2026-04-22 | fix: 修复 8BitDo 重连后无输入的首包误判问题 |
| `5218ae0` | 2026-04-23 | feat: 集成 LVGL 像素风启动菜单并完善游戏启动/退出流程 |
| `0a20960` | 2026-04-23 | feat(ui): 融合板载输入并完善板载退出与像素菜单文案显示 |
| `3d4ffeb` | 2026-04-23 | feat(rtc): 修复 RTC 双时间戳链路并落地软 RTC 自校准体系 |
| `cf615c3` | 2026-04-24 | 完善 PIXEL GBA 菜单与中文 ROM 支持 |
| `443e9a4` | 2026-04-24 | 增强 G30S TE 手柄兼容链路并收敛 RTC 校准工具 |
| `6e46264` | 2026-04-28 | 增强启动诊断并收敛核心资源映射 |
| `7dc4721` | 2026-04-30 | 重构 GBA GamePak Cache 为 2 路组相联并集成 cache 诊断工具 |
| `70084e6` | 2026-05-04 | 解决精灵宝可梦·白金光场景转换偶发 10～20 s 黑屏问题 |
| `399cfd0` | 2026-05-06 | 修复自定义 BIOS CpuFastSet 自旋锁导致部分游戏黑屏的问题 |
| `055a68b` | 2026-11-11 | 建立 Zynq GBA 工程稳定点 |

## 当前工作树中的未提交改动

截至 2026-11-11，Git 中有 11 个已跟踪文件处于修改状态。下表记录这 11 个文件的来源和作用。

| 文件 | 改动来源 | 记录 |
| --- | --- | --- |
| `docs/README.md` | 既有改动 | 增加工程变更记录入口。 |
| `docs/engineering-status.md` | 既有改动和本轮 PPA 记录 | 记录 LVGL 迁移、IWRAM 修复、板测结果和本轮 PPA 验收。 |
| `scripts/build/rebuild_project.tcl` | 本轮 PPA 改动 | 启用 `power_opt_design` 与 `post_place_power_opt_design`。 |
| `src/ps/app/src/App/Src/ps_app_runtime_rom.c` | 本轮前已有的未提交改动 | ROM 加载时先清 HDMI 帧，再保存旧存档和读取新 ROM。 |
| `src/rtl/common/ddram_mux.sv` | 本轮 PPA 改动 | 简化 burst 1、2、4 的 4 KiB 页尾限制。 |
| `src/rtl/core/gba_mister/rtl/gba_memorymux.vhd` | IWRAM 修复及本轮 PPA 候选 | 保留 IWRAM 清理；GamePak cache 改为 64 KiB。 |
| `tests/rtl/tb_cache_dword_timing.vhd` | 本轮 RTL 回归改动 | 增加单周期和连续命中测试。 |
| `tests/rtl/tb_comprehensive_ddr.vhd` | 本轮 RTL 回归改动 | 补齐显存清理端口连接，并等待清理结束。 |
| `tests/rtl/tb_memorymux_anwj_fetch.vhd` | 本轮 RTL 回归改动 | 补齐显存清理端口连接。 |
| `tests/rtl/tb_sync_ram_dual_collision.vhd` | 本轮验证改动 | 对照 block RAM 与 distributed RAM 的同址碰撞行为。 |
| `tools/flow.py` | 本轮工程改动 | 将页尾穷举测试加入 memory suite。 |

本轮新增未跟踪测试为 `tests/rtl/tb_ddram_mux_burst_boundary.sv`。本文件和 `docs/worktree-inventory-2026-11-11.md` 也是未跟踪文件。其他未跟踪路径见工作树清单。

cache 数据和 tag RAM 读门控只做过实验，已从生产 RTL 回退。该候选的整机测试未通过，因此没有进入 bitstream。GPU RAM 映射没有改动，因为同址碰撞行为不等价。ddram mux 的 next-line 状态预计算没有保留。

本轮 Vivado 工程、报告、bit/XSA、仿真日志和板测日志都保存在 `out/`，不属于源文件改动。

## 2026-11-11 Skyland 白屏修复记录

触发序列是先从菜单启动 `0:/games/电梯大战.gba`，再切换到 `0:/games/Skyland.gba`。软 ROM 切换会关闭核心，但此前没有清理无复位端口的 IWRAM。前一款游戏的代码、数据和 BIOS 锁状态可能留给下一款游戏使用。

修复位于 `src/rtl/core/gba_mister/rtl/gba_memorymux.vhd`。它复用已有 core-off 清理阶段，并在清理后把 IWRAM 字 `0x1FFE` 初始化为未锁定状态。没有修改 PS/PL ABI、存档格式或 CherryUSB。

Vivado 2025.2.1 完成一轮综合和实现。最终 DRC 错误数为 0，WNS 为 `+0.100 ns`，TNS 为 0，WHS 为 `+0.014 ns`，THS 为 0。生成并下载了新 PL bit 和 XSA。Vitis app ELF 与 `ps7_init.tcl` 复用，没有重建 PS 软件。

板上按相同顺序复测两轮。两轮均从电梯大战标题切换到 Skyland 标题和游戏画面。直接采集 OBS Virtual Camera，第一轮记录 70 帧，第二轮记录 80 帧，采样频率均为 2 fps。按中心区域近白像素占比 90% 判定，全白帧计数均为 0，最大近白比例为 14.06%。第一轮 UART 快照显示 CPU 在 BIOS、IWRAM、ROM 区间间推进，非法取指计数为 0；帧捕获序号持续增加，FBSCAN 的白行数为 0，VDMA 错误为 0。

复测摘要、采集截图和接触表保存在 `out/board-test/20261111/`：

- `elevator_to_skyland_iwram_clear.log`：下载顺序、ROM 头、CPU/帧捕获诊断和采样方法。
- `skyland-current.png`：Skyland 正常游戏画面。
- `elevator-title.png`、`elevator-repeat2.png`：两轮电梯大战标题画面。
- `skyland-exit-menu.png`：从游戏返回菜单后的选中状态。
- `skyland-contact.png`、`skyland-contact2.png`：两轮 HDMI 序列接触表。

故障发生瞬间的锁字值没有通过现有诊断接口直接读回。因此记录确认的是 IWRAM 未随软 ROM 切换清理，以及加入清理后同一触发序列连续两轮通过；不将旧故障的具体锁值写成已实测事实。

## 构建和板卡交付物

本轮硬件产物：

- `out/vivado/Zynq-GBA_MisTer-Vivado.runs/impl_1/zynq_gba_system_wrapper.bit`：新建并联合下载的 PL bit。
- `out/vivado/zynq_gba_system_wrapper.xsa`：随新实现更新的 XSA。
- `out/vitis/platform-39eb86a3-10f-09cc12e1/workspace/gba_app_fpslabels-20_2d6c1f15/build/app.elf`：复用的 PS app ELF。
- 对应 workspace 下 `_ide/psinit/ps7_init.tcl`：复用的 PS 初始化脚本。

未生成新的 BOOT.BIN。当前修改没有提交；后续提交应包含源码和本记录，不要把计划中未执行的项目写成已验证。

## 2026-11-11 FPGA 资源、时序和功耗比较

本轮比较 FPGA 资源、时序性能和功耗。只运行了一次完整综合与实现。开始前保存同日基线 bit、XSA、routed DCP 和实现报告，目录为 `out/board-test/20261111/optimization-baseline-20261111/`。

### 候选改动

- `ddram_mux.sv` 简化 burst 1、2、4 的 4 KiB 页尾限制。没有更改仲裁顺序或 outstanding 事务数。
- GamePak cache 从 128 KiB 改为 64 KiB。IWRAM 清理修复保留。
- Vivado 构建启用 `power_opt_design` 和 `post_place_power_opt_design`。两个阶段均完成。
- GPU RAM 映射没有更改。cache 读门控实验未通过整机测试，已从生产 RTL 回退。

### 最终 PPA

| 指标 | 同日基线 | 本轮候选 |
| --- | ---: | ---: |
| BRAM Tile | 127/140 | 107/140 |
| Slice LUT | 28,367/53,200 | 29,162/53,200 |
| Slice Registers | 30,844/106,400 | 30,742/106,400 |
| Unique Control Sets | 1,154/13,300 | 2,008/13,300 |
| DSP | 12/220 | 12/220 |
| 100 MHz 域 WNS | +0.100 ns | +0.186 ns |
| 100 MHz 域 TNS | 0 | 0 |
| 100 MHz 域 WHS | +0.014 ns | +0.016 ns |
| 100 MHz 域 THS | 0 | 0 |

BRAM 使用量减少 20 tiles，达到不超过 119 tiles 的目标。Slice LUT 增加 795 个，约 2.8%；寄存器减少 102 个。WNS 提升 0.086 ns，低于 +0.300 ns 的优化目标。setup/hold 均为非负，TNS/THS 为 0。

最差路径从 GamePak cache 地址逻辑到 DDR burst 控制，转移到 CPU 的 PC 到 execute-add-cycles 路径。新路径延迟为 9.774 ns，其中逻辑延迟 3.047 ns、布线延迟 6.727 ns，共 10 级逻辑。

57,646 条可布线网络全部完成路由，routing error 为 0。DRC 有 0 errors。bitstream 和 XSA 均成功生成：

- `out/vivado/Zynq-GBA_MisTer-Vivado.runs/impl_1/zynq_gba_system_wrapper.bit`
- `out/vivado/zynq_gba_system_wrapper.xsa`

两个 power-opt 阶段都有成功日志和 `.end.rst` 完成标记。工具日志记录 power optimizer 将写使能移到 BRAM enable 端口。

Vivado 功耗报告的芯片总功耗估算从 2.338 W 降到 2.219 W。两个报告的置信度都是 Low，且都没有 SAIF 活动数据。本轮没有板级电流测量，不把估算写成实测节电结果。AMD 指出，准确的功耗分析需要有代表性的开关活动，并应达到 High confidence。[UG1388 功耗分析指南](https://docs.amd.com/r/en-US/ug1388-acap-system-integration-validation-methodology/Best-Practices-for-Accurate-Power-Analysis)；SAIF 的作用见 [UG900](https://docs.amd.com/r/2025.2-English/ug900-vivado-logic-simulation/Dumping-SAIF-for-Power-Analysis)。

### CDC 和方法学观察

候选 CDC 报告有 2,237 条 CDC-15 warning、45 条 CDC-3 info 和 1 条 CDC-9 info。基线分别为 2,257、45 和 1。没有新增 CDC 类型。CDC-15 按数据位记录 clock-enable controlled bundled-data 路径；计数不等于独立故障数。

相关 mailbox 使用 request/ack toggle 与稳定 payload。部分 mailbox 还有保持和背压断言。异步时钟组把这些 payload 路径排除在普通 STA 之外，XDC 没有为 payload 总线设置 `set_max_delay -datapath_only` 或 bus-skew 约束。RTL 握手说明了设计意图，报告没有证明 payload 在目的域采样前已到达。这是本轮之前已有的 CDC 签核风险。本轮没有改变时钟约束。

methodology report 将控制集规则从基线的 ULMTCS-1 升为 ULMTCS-2。placed utilization 报告的控制集从 1,154 增至 2,008（15.10%）。DRC 比基线多 1 条 REQP-1839 ENBWREN 异步控制 warning。它位于同一个 HDMI VDMA XPM FIFO RAMB36；基线已有该 RAM 的 WEBWE 异步控制 warning。power-opt 执行了 WE 到 EN 的改写。该 warning 提醒异步复位可能影响 FIFO 写使能，板测重点检查了复位后的首帧和游戏切换。

本轮没有 Critical Warning 或 DRC error。板上冷启动、MechPlatoon、Skyland 和 stripes 均有正常画面。新增 ENBWREN warning 与控制集增长仍应在后续评估。CDC 和 methodology 报告位于 `out/board-test/20261111/optimization-final-reports/`。

### RTL 和整机回归

memory、CPU、DDR fault drain、仲裁、公平性和 RAM 碰撞测试均 PASS。comprehensive DDR 有 23 pass、0 fail；burst 页尾测试有 1,536 个组合检查。

保留的 64 KiB `tb_gba_top_full` 测试运行到 PC `0x0808075C` 并 PASS。随后对新生成工程发起的重复运行，在 8.5 ms 仿真时间处取消，以节省数十分钟；该次没有 TEST_PASS，不计入验收。memory 和 CPU 日志位于 `out/sim/optimization/final-memory-cpu/`；整机测试日志位于 `out/sim/optimization/system-cache64-functional/`。

### 实板结果

使用 `tools/board/joint_program.tcl` 完成联合 PL/PS 复位和下载。PS app ELF 与 `ps7_init.tcl` 复用。HDMI 经 OBS Virtual Camera 采集。

| 场景 | 捕获 FPS | blit FPS | present 比例 | CyclesMissing 增量 |
| --- | ---: | ---: | ---: | ---: |
| MechPlatoon 标题 | 59.33 | 58.53 | 98.7% | 0 |
| Skyland 标题 | 59.40 | 59.30 | 99.8% | 0 |
| stripes | 59.40 | 59.30 | 99.8% | 0 |
| stripes 切回 Skyland | 59.30 | 59.30 | 100.0% | 0 |

MechPlatoon 的旧基线为捕获 59.30 FPS、blit 58.50 FPS、present 98.7%、CyclesMissing 增量 0。本轮采样结果基本持平。各游戏启动日志中的 VDMA 错误掩码都是 0，帧捕获序号持续增加。

Skyland 切回后以 2 fps 采集 20 帧。分析区域内近白像素比例最大值为 3.60%，没有帧达到 90%。接触表和采样摘要位于 `out/board-test/20261111/ppa_candidate_skyland_2fps_contact.png` 和 `ppa_skyland_visual_sampling.log`。

本轮串口无法输入中文文件名。尝试输入“电梯大战”时，日志路径变为 `0:/games/.gba` 并返回 `no_file`，没有加载该 ROM。本轮用 stripes 切回 Skyland 验证切换；前文 IWRAM 修复记录中的两轮 Elevator→Skyland 结果不是本轮 bit 的新实板复测。

Skyland 加载日志显示程序先预载 `0:/saves/Skyland.sav`，随后 save flush 成功。测试时没有操作游戏。PS app 未启用写后 checksum，因此没有做存档字节对比。

本轮按整体收益保留该 PPA 候选作为当前开发版本：BRAM 少 20 tiles，100 MHz WNS 改善 0.086 ns；MechPlatoon 与旧基线帧率持平，Skyland 和 stripes 样本约 59 FPS，CyclesMissing 增量均为 0。新增控制集与 ENBWREN warning 已记录。功耗估算置信度低，payload CDC 的物理时序也未闭合，因此不把它标为最终发布版。

本轮没有测实体手柄、音频、掉电保存、长时间运行、完整 ROM 矩阵、板级功耗或 Windows 原生构建。实板通过的是代表性游戏和切换场景，不能代表全部游戏组合。

## 2026-11-12 UART UTF-8 路径和 power-opt 候选复测

### 源码与回归

- src/ps/app/src/App/Src/ps_app_console.c：UART 行接收改为调用独立 line-input helper，保留 UTF-8 字节；超长行提示并丢弃。
- src/ps/app/src/App/Inc/ps_app_console_line.h 与 src/ps/app/src/App/Src/ps_app_console_line.c：新增 192 字节行缓冲、UTF-8 字符退格和整行超长检测。
- tests/ps/test_console_line_utf8.c：新增 ASCII、中文 ROM 路径、退格和超长输入回归。
- tools/flow.py 与 tests/test_flow.py：登记 Host C 回归，并把新增 helper 头文件加入输入指纹。

FatFs 已配置 UTF-8 LFN；本次未修改 FatFs、存档格式或 PS/PL ABI。Python 单测 55/55 通过，Host C 回归 7/7 通过。

### 构建与实板

Vitis 2025.2.1 使用现有 XPFM/BSP 构建 PS app。新 app 与候选 XSA 的 ps7_init.tcl 内容一致。joint_program.tcl 完成系统复位、PL 配置、PS 初始化和 ELF 下载。没有运行 Vivado 综合或实现。

UART 直接加载电梯大战和 Skyland 均成功。两轮时间同步的 OBS Virtual Camera 采样没有发现近白比例达到 90% 的帧。加载后 1 秒内，电梯大战旧画面清为黑色加载画面；之后出现 Skyland 场景。详细记录、UART 日志和关键帧见 out/board-test/20261112/utf8-poweropt/board-retest-summary.md。

两款游戏测试及 hdmi park 1/0 park/resume 均报告 VDMA err=0、CyclesMissing 增量 0。候选 placed utilization 的 control sets 为 2,008，methodology 报告另记 2,012 并触发 ULMTCS-2；REQP-1839 由基线 8 项增至候选 9 项，新增项为 HDMI VDMA FIFO 的 ENBWREN。两项静态 warning 均保留，没有据实板通过记录为已消除。

按用户指示，本次未备份或哈希比对 SD 存档；Skyland 加载触发的自动 save flush 未逐字节核验。Flow report 仍报告硬件清单 stale，因为候选 bit 哈希不匹配最后一次成功记录。本次没有为了更新清单重跑综合实现。

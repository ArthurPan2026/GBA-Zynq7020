# 工程变更记录

更新时间：2026-11-18。

本文件索引本项目在此前对话和本轮工作中完成的改动。Git 提交保存已提交改动的逐文件差异；当前未提交改动在本文件中逐路径记录。已有技术调查与实板结果继续保存在 [工程状态记录](engineering-status.md)。

## 记录规则

以后每次修改代码、配置、构建脚本或硬件工程，都在本文件追加一条记录。条目应写明日期、文件路径、改动原因、验证结果和生成或复用的交付物。计划但未实施的工作要单独标为“未实施”。

查看某个历史提交的逐文件路径和差异：

```sh
git show --name-status <提交号>
```

## 历史对话提交索引

以下 27 个较早提交构成初始可综合版本到工程稳定点的历史索引。2026-11-16 至 18 的对话提交另列于表后和全对话索引。每个提交都包含完整逐文件差异；表中摘要用于定位功能阶段。

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
| `a1ad1ba` | 2026-11-12 | 建立 Zynq GBA UTF-8 与 power-opt 开发稳定点 |
| `0070b92` | 2026-11-13 | 建立 Zynq-GBA ROM 加载进度与 PPU 显示稳定点 |
| `882845e` | 2026-11-16 | 建立 HDMI 音频与 QSPI 验证稳定点 |
| `7293dbd` | 2026-11-16 | 更新 HDMI 音频验收状态并复用文档变更产物 |
| `a0ff362` | 2026-11-17 | 集成 EmbeddedVideoIP 0.3.0-dev.1 与 HDMI EDID 链路检测 |
| `73b3a2a` | 2026-11-17 | 绑定唯一 GBA 构建产物并加入 HDMI smoke 检查 |
| `9702235` | 2026-11-18 | 绑定 GBA 消费 profile 产物并改进验证 |
| `d57d539` | 2026-11-18 | 修复 GBA HDMI/DDC、菜单帧、默认路由和按键并归档证据 |

## 2026-11-11 工作树中的未提交改动

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

## 2026-11-13 Boktai 异常调查与 PPU 修改

### 起因和调查

用户报告《Boktai》进入游戏后明显加速，并出现横向条纹或横杆。用户确认其他游戏正常，同一 ROM 在 mGBA 中正常；因此调查重点放在这款游戏触发的 GBA 核心路径，以及 ROM 与核心的交互。本次所测文件为 boktsolr.gba（CRC32：AC52552F）。用户当时没有其他 Boktai 版本可供对照，并说明现象与 OBS、HDMI 无关。

调查中查看了上游 GBA_MiSTer 的相关实现，并在板上试过两项运行时设置。U3IJ 配置读回 `ctrl=0x29413`，其中 Turbo 关闭、Underclock 开启、interframe blend 开启；用户仍观察到加速和横杆。随后启用 `romsafe=1`，让 ROM 读取改单拍并关闭预取，现象仍未消失。现有证据没有区分出 ROM 本身与核心兼容路径中的唯一根因。

### 实际保留的 PPU 修改

- `src/rtl/core/gba_mister/rtl/gba_gpu_timing.vhd`：原逻辑会在收到 `new_cycles_valid` 的同一拍，把 `new_cycles` 加入临时计数，再用新值推进 PPU 状态机。修改后先把周期写入 `cycles`，该拍不推进 PPU 状态机；下一拍再按已登记的周期处理可见区、HBlank 和 VBlank。
- `src/rtl/top/zynq_gba_top.v`：Underclock 和 interframe blend 从固定常量改为读取配置位，使对应配置能到达 GPU timing 模块。

用户参与了 PPU A/B 观察：部分 Boktai 场景速度略接近正常，其他场景仍偏快；横杆没有改善，多个场景仍有加速。用户随后决定暂时停止 Boktai 修复，并纠正 MechPlatoon 表现正常、Turbo 没有问题。最终保留上述 PPU 修改；没有改 Turbo 默认值，也没有把 Boktai 标记为已修复。其他游戏未见问题的结论仅限于用户反馈和本轮代表性板测，不等于完整兼容性证明。

## 2026-11-13 LVGL ROM 加载进度与切换画面

### 起因和代码改动

菜单加载 ROM 时，UI 任务同步等待文件读取，期间不再运行 LVGL 定时器。旧进度条只是动画，没有反映 SD 卡实际读取量。加载入口还会清空 VDMA 帧缓冲，而视频呈现任务在 `is_loading` 期间暂停，所以读取期间出现黑屏；启动前的全帧清空也会让菜单到加载界面发生闪屏。

- `src/ps/app/src/Common/Inc/ps_app_rom_load_progress.h`、`src/ps/app/src/Common/Src/ps_app_rom_load_progress.c` 和 `ps_app_state.h`：增加带临界区保护的阶段、字节数、总量、结果和尝试编号快照。
- `src/ps/app/src/Storage/Inc/ps_fatfs_storage.h`、`src/ps/app/src/Storage/Src/ps_fatfs_storage.c`、`src/ps/app/src/Rom/Inc/ps_rom_loader.h`、`src/ps/app/src/Rom/Src/ps_rom_loader.c`：把文件总字节数传到分块读取回调，每读完一个 128 KiB 分块就报告实际进度。
- `src/ps/app/src/Ui/Src/ps_app_ui.c`、`src/ps/app/src/Common/Inc/ps_app_ui_launch_logic.h`、`src/ps/app/src/Common/Src/ps_app_ui_launch_logic.c`：用单个低优先级 worker 调用原有同步加载 API，UI 任务继续每 10 ms 处理 LVGL。读取显示真实百分比；准备、初始化和等待首帧显示对应阶段。失败、队列发送失败或 worker 创建失败时回到菜单。UART `rom load` 与菜单入口共用加载状态。
- `src/ps/app/src/App/Src/ps_app_runtime_rom.c` 和 `src/ps/app/src/Video/Src/ps_app_video.c`：加载成功后等待首个有效捕获帧，再切换游戏画面；移除加载开始和结束时清空整帧缓冲的操作。为避免旋转帧缓冲的上下黑边残留菜单像素，每个 ROM 代次首次绘制到每个 VDMA 目标缓冲时单独清屏。UART 启动新加载时先完整重绘不透明菜单，再显示进度。
- src/ps/app/src/Common/Inc/ps_project_config.h：为 ROM 加载 worker 设置独立的任务栈大小和优先级。
- `tests/ps/test_rom_load_progress.c`、`tests/ps/stubs/task.h` 和 `tools/flow.py`：加入分块进度、失败结果、零总量、进度上限及 worker/队列失败恢复测试，并登记到 Host C 测试套件。

### 验证结果

Host C 测试共 8 个套件通过，ROM 进度回归通过。覆盖 128 KiB 分块和尾块、百分比单调、总量为零、失败不显示 100%，以及 worker 或队列失败后恢复菜单。

使用 Vitis 2025.2.1 基于已有 XPFM/BSP 只构建 PS app，没有重跑 Vivado。ELF 大小为 32,480,548 字节，SHA-256 为 `78d948bb0f51ebe5a8006912ca02978425d7dc3a5a36a30ca1ac6d406c7025bd`。标准 flow 因硬件输出清单中的 XSA/bit 哈希过期而拒绝 app 阶段；改用已有 XPFM 直接构建。候选 XSA 与 XPFM 的整体哈希不同，但 `ps7_init.tcl`、C 文件、头文件和 BDA 内容一致，HWH 只差报告时间戳。Vitis 有一条既有的 `PsAppUsbHost_PortResetImplForGeneration` 隐式声明警告，链接成功。此轮没有重新生成时序或 DRC 报告。

用 `tools/board/joint_program.tcl` 复位系统、配置保留的 PPU 候选 bit、初始化 PS 并下载新 ELF。画面证据只从 OBS Virtual Camera 采集，没有使用 Computer Use。

- 菜单启动 MechPlatoon 时，LVGL 进度按实际读取量变化，首个游戏帧出现后再切换画面。切换附近约 2 秒的 OBS 样本没有捕获到全黑帧。
- UART 加载 `0:/games/MechPlatoon.gba`（8 MiB）时，完整 LVGL 页面在上一款游戏画面之上显示到 89% 和 100%，随后交给首个游戏帧。
- 不存在的 ROM 路径返回 `no_file`，菜单显示失败状态，`rom loaded=0`。该错误路径在最后一次仅改重绘逻辑前验证；错误处理逻辑没有随重绘改动。
- MechPlatoon 采样期间 VDMA 错误掩码为 `0x000`，捕获和 blit 约为 59 fps，`CyclesMissing` 增量为 0。验收时板上保留 MechPlatoon。
- 按本轮边界，没有备份或哈希核对 SD 存档。
本次只覆盖菜单和 UI 运行期间的 UART rom load；默认关闭的开机自动加载路径没有纳入。

详细 UART 日志、OBS 截图和构建信息留在 `out/board-test/20261113/rom-progress/`；该目录属于本地构建产物，没有提交到 Git。源码和测试已经由 `0070b92` 提交；它继承 `a1ad1ba` 中的 UART UTF-8 与 power-opt 候选改动。UTF-8 路径和 power-opt 风险的原因、改动与复测结果见本文件前面的“2026-11-12 UART UTF-8 路径和 power-opt 候选复测”。

## 2026-11-13 宝可梦改版 ROM 启动标志调查

用户报告部分游戏加载后没有任天堂标志，并提供 `bjg.gba` 与 SD 卡副本逐字节一致这一信息。对本地 `bjg.gba` 的检查显示文件为 32 MiB，头部标题为 `POKEMON RUBY`，游戏代码为 `AXVE`，ROM 头部校验值与计算值均为 `0x41`。卡带标志字节与 Boktai、MechPlatoon ROM 的标志字节哈希一致，因此文件路径截断或本地副本差异不能解释这个启动画面。

运行日志没有发现 `0:/boot.rom`，核心会回退到内置 Normmatt BIOS。截图中的 Normmatt 标志与该回退路径一致。该文件属于改版 ROM，可能跳过或替换标准 BIOS 启动过程；仅凭当前文件头和截图，尚不能断言是哪段 ROM 启动代码跳过任天堂标志。没有修改 BIOS、ROM 头或游戏启动逻辑。进一步区分需要用你已有的原版 BIOS 及对应 ROM 启动对照。本节记录的是调查结论，不是已修复的缺陷。

## 2026-11-13 Zybo Z7 板载 IMON 功耗测量

### 原因和实现

此前 Vivado 功耗报告估算从 2.338 W 降到 2.219 W，但置信度为 Low，且没有 SAIF 活动数据。用户要求用实板方法测量，并指定只使用 MechPlatoon。

新增 `src/ps/app/src/Diagnostics/Inc/ps_app_power_monitor.h` 和 `src/ps/app/src/Diagnostics/Src/ps_app_power_monitor.c`。功耗监测模块通过 XADC 的 VP/VN 通道读取 Zybo Z7 板载 TPS25940 IMON 信号。XADC 使用 256 点平均，16 位寄存器值右移 4 位得到 12 位原始读数，再按 Zybo Z7 参考手册 Figure 1.4.1 换算成输入电流。FreeRTOS BSP 已有 XAdcPs 驱动，本次没有加入新的 XADC IP，也没有修改硬件工程。

在 `src/ps/app/src/App/Src/ps_app_console_diag.c` 增加 UART 命令 `power [seconds] [input_mV]`。默认采样 10 秒，默认输入电压为 5,000 mV；每 200 ms 采一次，输出原始读数、平均电流、最小/最大电流和输入功率估值。电压参数表示用户给定的电源电压，命令本身不会测量输入电压。

### 构建和实板测量

Vitis 2025.2.1 基于已有 XPFM/BSP 只构建 PS app，没有重跑 Vivado。602 个构建步骤成功，ELF 大小为 32,565,624 字节，SHA-256 为 `fc48d6099f570535fa235105ed440990a16438b7cfc4f1457a1b7ca8170a981b`。构建仍有一条既有的 USB-host 隐式声明警告，链接成功。

用户确认开发板由 J17 圆孔口外接 5 V 电源。测量按 5,000 mV 计算输入功率，未另用电压表测量电源端电压。每段采样 60 秒，共 300 个有效样本；同一 PS app 依次加载基线 bit 和候选 bit，重复执行候选、基线、候选、基线、候选。每次只加载并运行 MechPlatoon，ROM 代码为 AKGE，大小 8 MiB；测量期间没有操作游戏。

| 次序 | PL bit | 平均输入电流 | 5.000 V 下功率估值 | 60 秒采样最小～最大电流 |
| --- | --- | ---: | ---: | ---: |
| A1 | 候选 | 552 mA | 2.760 W | 538～561 mA |
| B1 | 基线 | 562 mA | 2.810 W | 545～574 mA |
| A2 | 候选 | 553 mA | 2.765 W | 539～565 mA |
| B2 | 基线 | 563 mA | 2.815 W | 549～575 mA |
| A3 | 候选 | 553 mA | 2.765 W | 540～563 mA |

候选三段均值为 552.7 mA，基线两段均值为 562.5 mA，差值约 9.8 mA。按 5.000 V 计算，候选整板输入功率均值约低 49 mW（1.75%）。重复的 60 秒平均值稳定，但单段瞬时范围有重叠。电压按 5 V 名义值计算，结果没有外部功率计校准。

本次比较的是 11 月 11 日保存的 PPA 基线 bit 与当前候选 bit；两者包含多项 RTL 差异，不能把约 49 mW 的差值单独归因于 power-opt 阶段。IMON 测到整板输入电流，功率包含 PS、DDR、PL、风扇和外接设备。之前 Vivado 估算的 2.338 W 与 2.219 W 是芯片内部低置信度估算，本次测量的是整板输入，不能直接逐项对比。

UART 采样日志、ROM 加载日志和最终 BOOT.BIN 保存在 `out/board-test/20261113/power/`。

### QSPI 更新

为了让此前固化的 QSPI 镜像也包含 power 命令，用当前 app、候选 bit 和 FSBL 重新生成 BOOT.BIN。镜像大小为 4,594,040 字节，SHA-256 为 `1a9842711b2770a37e1b5bfc47dc555d24613edef61bd5df71d1b22cd305e1de`。Vitis Program Flash 对 QSPI 偏移 0 执行镜像范围擦除、空白检查、写入和全镜像读回验证，均成功。工具提示通用 qspi-x4-single 类型与检测到的 W25Q128JV 名称不一致，实际读回校验通过；没有擦除整片 Flash。

工具读到 BOOT_MODE REG 为 0x00000000，板卡当前仍设置为 JTAG 启动，因此本次没有做 QSPI 冷启动验收。烧录后已重新通过 JTAG 启动候选 PL 和新 app，并加载 MechPlatoon。恢复后再测 5 秒，25 个样本全部有效，平均电流 552 mA。


## 2026-11-15 FPGAFlow 消费工程构建与部署流程

提交 f5559de 统一 GBA 项目的 PL/PS stage、清单、工具版本、缓存输入摘要和产物哈希；提交 54a9a24 增加 fpga-flow.toml。改动原因是 Vivado 与 PS 脚本各自维护产物路径和缓存规则，部署时难以证明 bit、XSA、平台、ELF 与 BOOT.BIN 属于同一构建。

本轮又发现平台缓存只比对 XSA 路径，没有比对文件内容。同一位置覆盖新 XSA 后会复用旧 XPFM。tools/vitis_stages.py 现在在平台输入记录中保存 XSA SHA-256，并拒绝复用缺少摘要或摘要不同的平台；tests/test_vitis_stages.py 增加 XSA 内容变化回归。首次使用新 XSA 完整构建 platform/BSP/app，后续 app-only 变更可复用平台。

当前全链路构建、产物验证和板级状态见[2026-11-16 验证记录](embedded-video-audio-qspi-validation-2026-11-16.md)。

## 2026-11-16 HDMI 音频、HDMI 复位修复与 QSPI 稳定点

本轮集成 GBA 到 EmbeddedVideoIP 的可选 HDMI 音频。GBA 用现有 48 kHz sample_ce 产生 PCM AXI4-Stream。LVGL 在主菜单选择 HDMI 或 I²S codec 后再启动游戏。I²S 逻辑留在 GBA，没有放进 EmbeddedVideoIP。

板测出现 HDMI 无信号。UART 证据显示像素时钟和 MMCM 正常，像素复位未释放且 VSYNC 不变。EmbeddedVideoIP 的像素域 proc_sys_reset 将低有效 aux_reset_in 固定接 0；C_AUX_RESET_HIGH 原设置把低电平判为有效复位。现改为高有效配置。修复后像素复位释放，C1-1 连续接收 640×480、60 fps 视频。EVIP TX scheduler 的 guard band/首像素边界也已修复并增加仿真覆盖。

主要修改位于 src/rtl/common/gba_pcm_audio_axis.sv、src/rtl/top/zynq_gba_top.v、src/ps/app/src/App/Src/ps_app_runtime_boot.c、src/ps/app/src/Ui/Src/ps_app_ui.c、src/ps/app/src/Common/Src/ps_app_audio_route_logic.c、scripts/build/embedded_video_ip_bd.tcl、tools/flow.py、tools/vitis_stages.py。逐路径差异由本次 Git 稳定提交保存。EmbeddedVideoIP 源码与库级回归分别记录在锁定提交 2008d713 和该文件。

硬件实现通过时序门槛：WNS +0.152 ns、TNS 0、WHS +0.012 ns、THS 0，DRC 错误和 Critical Warnings 为 0。MechPlatoon 的 HDMI 视频及可变幅度音频经 C1 采集通过。QSPI 偏移 0 写入当前 BOOT.BIN，空白检查、编程、读回 verify 成功；未擦除整片 Flash，未做冷启动验收。详细数据、SHA-256 和警告见[2026-11-16 验证记录](embedded-video-audio-qspi-validation-2026-11-16.md)。


## 2026-11-16 EVIP 文档状态修订与 GBA 依赖锁

GBA 的 C1-1 预验证确认 HDMI PCM 到达采集卡，采集电平会随音量变化。EVIP 旧文档只写“正式板级音频验收尚未完成”，没有写明这项预验证。EVIP 主分支新增提交 a7c480c，更新 README、架构/API、快速上手、兼容性和验证说明，并增加板级预验证记录。正式扬声器听音、板级验收和 HDMI 认证仍未完成。

GBA 继续锁定通过综合、实现和板测的 EVIP 代码提交 2008d713。Flow 现在只接受该提交的干净后续版本，且改动仅限根 README.md 和 docs/*.md。RTL、PS 库、约束、参数或依赖清单变化仍会触发锁定错误。tests/test_flow.py 增加回归，验证 Markdown-only 后续提交保持 PL/PS 输入摘要不变，代码修改会被拒绝。

EVIP 文档提交推送后，GBA Flow report 仍通过。硬件阶段只做了安全元数据重键，命令 python3 tools/flow.py build --stage hardware 输出 FLOW-CACHE-REKEY，没有启动综合或实现。QSPI 没有重写。


## 2026-11-18 03-GBA 全对话归档与最终 Sony 电视修复

本节对应 [03-GBA 与我的工具箱全对话归档索引](03-gba-toolbox-archive-index.md)。索引按时间整理全对话中的 FPGAFlow、EmbeddedVideoIP、显示色彩/紫条、音频路由、菜单帧、按键和 Sony 电视 DDC 事项。

本次对话结束时的新增提交为：

| 提交 | 改动范围 | 验证 |
| --- | --- | --- |
| 9702235 | fpga-flow.toml、消费端构建脚本、tools/flow.py、Flow 单测 | GBA profile 产物来源与 HDMI smoke 条件 |
| d57d539 | PS 音频/EDID/菜单/输入，PL 按键映射与测试，验证文档和证据 | App/BOOT 构建、Sony TV 串口实测、QSPI verify |

Sony 电视失败的串口状态是 HPD=1、EDID block 0 send error=3、sink=DVI；随后 HDMI 音频选择失败 error=4。PS 代码在读取 EDID block 0 时不必要地向 segment pointer 地址 0x30 写入 segment 0。跳过 segment 0 指针写后，原电视 EDID 与 HDMI 音频路由均恢复。最终 App SHA-256 为 7d9df0a402b84a5c51e54331850fab07f95f5fa08d7132319713214920f12012，BOOT SHA-256 为 04130d9438ca0dd051f4a3c58604f695e191db98d12bcda8cf47b365bd3504dc。QSPI manifest 记录 readback_verified=true；cold_boot_verified=false。

完整测试条件、未覆盖范围、EDID 摘要和 GitHub 归档证据见 [2026-11-18 Sony 电视及最终 QSPI 验证](validation-2026-11-18-menu-audio-qspi.md)。

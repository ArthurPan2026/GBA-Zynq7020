# 改进实现与验收状态

更新时间：2026-11-18。原工作副本和基线快照仍保留。

## 实现范围

- 增加统一 Flow 入口、按 stage 记录路径/大小/mtime 输入指纹、检查源码变更，并为 bit/XSA/ELF/BOOT.BIN 保留 SHA-256 来源校验。
- Vivado project/sim 工程改写到 out/vivado/project/。硬件 build 继续使用 out/vivado/。新增回归测试检查两个输出树不重叠。
- HDMI `tmds_tx` 使用 VLNV `panfpga.org:interface:tmds:1.0`。总线定义和 RTL 抽象定义位于 EVIP 的 `ip_repo/if/tmds_v1_0/`；硬件阶段将两份 XML 和 `embedded_video_ip` package 纳入输入摘要。
- 用 config/ps_pl_contract.json 维护 PS/PL ABI、扩展寄存器和能力位。ABI 为 0x00020000，build ID 为 0x39EB86A3。
- 修复 AXI 后端故障隔离、ROM 生命周期/flush、frame 和 save snapshot mailboxes。
- 将手柄 VID/PID、接口匹配和 transport capability 放入静态 profile 表。generation 0 被新 API 拒绝；旧 API 在入队时绑定设备 generation。
- mailbox timeout 使用单调毫秒时基。应用构建采用严格 C11，第三方编译选项单独配置。
- Vitis collector 的扁平源码名按唯一真实路径解析。当前关闭 VGLite 下，CMake 只滤除已确认的 vg_lite_matrix.c 冲突。
- 将应用 LVGL 从 9.5 替换为官方 9.6.0；锁定上游 release commit、导入文件数和树摘要，保留 MIT 许可证与项目字体。
- UI 以每个 ROM 一个 LVGL label 行构建 flex column 列表，选中态由行左边框表示；手柄选择、末项滚动与启动路径不变，长名称在列表中省略、在详情标题中完整滚动显示。
- 迁移应用颜色格式和参数检查配置，启用 object style cache；PS/PL 构建缓存改为按 hardware/project/sim/platform/app/boot 分别选取输入。

## 验收结果

| 验证 | 结果 |
| --- | --- |
| Python 单测 | 55/55 通过 |
| Host C 回归 | 7 个 suite 通过；GCC 11.4；包含 UTF-8 console 行输入回归和 LVGL 9.6 主机渲染测试 |
| RTL smoke，seed 0 | 3 个 bench 通过 |
| RTL memory，seed 0 | 5 个 bench 通过 |
| RTL CPU，seed 0 | 2 个 bench 通过 |
| RTL system，seed 0 | 2 个 bench 通过；DMA3 完成 65,536 次写入 |
| Vivado hardware | 2025.2.1 综合与实现成功；bit/XSA 已更新；后布线 WNS +0.026 ns、WHS +0.050 ns，TNS/THS 为 0，DRC 0 errors |
| Vitis platform/app | UTF-8 修复仅改 PS console；复用现有 XPFM/BSP，Vitis app-only 构建成功；新 ps7_init.tcl 与候选 XSA 一致 |
| BOOT.BIN | 本次未重新生成；板上测试使用 XSCT 同时下载 PL bit 和 PS app |
| Bootgen BIF | Zynq-7000 格式通过 Bootgen 生成和读取检查 |
| project/sim 隔离 | project stage 和 smoke seed 0 通过；bit/XSA 哈希保持不变 |
| Flow report | 当前仍因候选 bit 哈希与成功清单不匹配而报告 hardware stale；实际候选 bit/XSA 存在，本轮未重跑硬件构建 |

## Zybo Z7-20 实板 HDMI 验收

本次用同一份 XSCT 脚本下载 PL 和 PS。脚本先加载 bitstream，再运行 ps7_init 与 ps7_post_config，随后下载 app ELF。冷启动后，应用运行 20 秒，UART 控制台可执行诊断命令。本次未向 QSPI 或 SD 写入启动镜像。

| 检查 | 观测结果 | 判定 |
| --- | --- | --- |
| HDMI 采集 | Windows 设备 C1-1 USB3 Video；YUYV422，640×480，60 fps | 通过 |
| EDID | 读取成功；接收端报告 HJW、产品 ID 0x2130，首选时序 1920×1080 | 通过 |
| VDMA | CR=0x00014001，SR=0x00011000，驱动错误掩码为 0；480 行、每行 2,560 B；三个 1,228,800 B 帧缓冲 | 通过 |
| 帧缓冲扫描 | fbscan 检查 17 条采样线，白线和全黑线都为 0，anomaly=0 | 通过 |
| RGB 纯色 | hdmi fill all 依次输出红、绿、蓝、白；采集帧颜色通道顺序正确 | 通过 |
| 启动菜单 | 冷启动后完整显示外框、标题、游戏列表、详情、状态栏和按键提示；SD 目录计数为 14 | 通过 |
| 连续帧 | 5 秒内采集 10 帧，采样率 2 fps；相邻帧只有少量 UI 区域变化，整帧未闪黑或停顿 | 通过 |
| RTC 显示 | 控制台报告 2026-05-06，uncertainty=INF，last_cal=0；未执行 rtc sync，也未改写 RTC 文件 | 需处理 |

应用按固定 640×480 输出。EDID 首选模式为 1920×1080，采集卡仍稳定锁定实际输出。VDMA SR 的 Halted 位为 0，帧计数状态为 1，帧计数中断位为 1；错误状态为 0。位定义见 [AMD AXI VDMA PG020](https://docs.amd.com/r/en-US/pg020_axi_vdma/MM2S_VDMASR-MM2S-VDMA-Status-Register-Offset-04h)。

实板截图和颜色测试帧保存在 out/board-test/20261110/。菜单截图为 [hdmi_cold_menu.png](../out/board-test/20261110/hdmi_cold_menu.png)，纯色样例包括 [hdmi_red.png](../out/board-test/20261110/hdmi_red.png)、[hdmi_green.png](../out/board-test/20261110/hdmi_green.png)、[hdmi_blue.png](../out/board-test/20261110/hdmi_blue.png) 和 [hdmi_white.png](../out/board-test/20261110/hdmi_white.png)。XSCT 联合下载记录为 xsct_joint_coldboot.log，UART 诊断记录为 hdmi_diag_cold.log。

纯色测试后再次配置 PL 时，旧 PS 应用仍在运行，VDMA 进入 halted 状态。随后 PS DAP 无法访问 DDR 控制器。JTAG 软件复位没有恢复 DAP，断电重启后，联合 PL/PS 下载恢复正常。后续板上重配应先让 PS 停止或冷启动，再在同一 XSCT 脚本中配置 PL、初始化 PS 并下载 app。

最终产物和来源清单位于 out/flow/manifest.json。硬件输出位于 out/vivado/，软件交付位于 out/vitis/。

## BTN0–BTN3 无 ROM 菜单验收

BTN0–BTN3 直接接入 PL。它们从 XDC 的 btns[3:0] 进入 gba_config_mgr，同步后直接送到 GBA core。PS 菜单通过 STATUS0 镜像读取这些物理键。

此前 STATUS0 只随帧、错误、存档或内存状态变化更新。无 ROM 菜单没有帧事件，PS 因而持续读到复位值 0x000。这让菜单无法看到 BTN0–BTN3。现在 RTL 也在同步后的 physical key mask 变化时请求状态快照，继续使用现有 CDC mailbox 传送数据。

| 实体按键 | GBA 输入 | 实测 physical_keys |
| --- | --- | --- |
| BTN0 | Right，bit 4 | 0x010 |
| BTN1 | Down，bit 7 | 0x080 |
| BTN2 | Up，bit 6 | 0x040 |
| BTN3 | Left，bit 5 | 0x020 |

无 ROM 菜单下逐个按下并松开四个按键，串口状态快照在按下时出现对应掩码，松开后回到 0x000。日志为 [btn0_3_no_rom_physical_keys.log](../out/board-test/20261110/btn0_3_no_rom_physical_keys.log)。BTN0/BTN3 在 SW3 置高时会改映射为 R/L；这是现有板级键位复用设计。[Zybo Z7 Reference Manual](https://digilent.com/reference/_media/reference/programmable-logic/zybo-z7/zybo-z7_rm.pdf) 说明这些 PL 按键按下时输出高电平，XDC 管脚为 K18、P16、K19、Y16。

本次通过 Vivado MCP 运行一轮综合与实现，随后联合下载 PL 和 PS。当前已确认四个键的 PL 掩码正确；HDMI 菜单选中项是否逐键移动，没有取得单独的目视确认。

## Stage 清单恢复记录

第一次 platform cache 检查时，直接执行 tools/flow.py 的 Python 路径没有包含仓库根目录，导致 import tools.vitis_stages 失败。已修复统一入口的导入路径，并将最近成功清单归档机制加入 Flow。

该次失败覆盖了 platform 的当前 manifest 记录；我按原始 XPFM/FSBL SHA-256 校验生成物，并对现有 BSP 重新执行 FatFs --check，然后重建了 platform stage 来源记录。XPFM 与 FSBL 摘要分别与原成功记录一致；没有重建 platform。恢复证据保存在 out/flow/manifest.json 的 platform.recovered_manifest_record。

## 资源和时序

最终硬件 stage 用时约 29 分钟。Vivado route 报告 WNS 为 +0.050 ns，WHS 为 +0.023 ns，TNS/THS 均为 0。用户时序约束全部满足。

| 资源 | 使用量 |
| --- | ---: |
| Slice LUT | 28,170 / 53,200（52.95%） |
| Slice Registers | 30,792 / 106,400（28.94%） |
| Slice | 10,408 / 13,300（78.26%） |
| BRAM Tile | 127 / 140（90.71%） |
| DSP | 12 / 220（5.45%） |
| IOB | 30 / 125（24%） |

BTN0–BTN3 快照触发更新后，Vivado 2025.2.1 完成综合、实现和 bitstream 生成。后布线报告为 WNS +0.026 ns、WHS +0.050 ns、TNS/THS 为 0；DRC 0 errors。本次 placed 资源报告：Slice LUT 28,173/53,200（52.96%），Slice Registers 30,834/106,400（28.98%），Slice 10,655/13,300（80.11%），BRAM Tile 127/140（90.71%），DSP 12/220（5.45%），IOB 30/125（24.00%）。

Vitis ARM size 对比原成功 ELF 与 LVGL 9.6 ELF：text 从 1,740,132 B 增至 1,796,828 B（增加 56,696 B，约 3.26%）；data 均为 4,280 B，BSS 均为 1,659,888 B。包含 DWARF 调试信息的 ELF 文件字节数不等于装载段大小。

主机 LVGL 场景测试使用与目标相同的 96 KiB 配置、XRGB8888 部分绘制缓冲和像素字体，创建 128 个单对象 ROM 行与详情标题。内存监视器报告可分配总块 89,176 B、空闲 39,632 B、当前使用 49,544 B、峰值 53,800 B；20 次软件 flush 均在 640×480 边界内，末行滚动位置为 3,374 px。用同一主机测试把每行暂时改成 button + label 的对照实现时，空闲空间为 5,448 B；单标签行方案增加了 34,184 B 空闲空间。这个比较用于决定 LVGL 对象布局，不是 v9.5 与 v9.6 的设备性能对比。测试未创建整张产品界面的装饰控件，也不代替目标板上的 heap 峰值和刷新耗时测量。

本轮设定的 WNS ≥+0.300 ns 和 BRAM ≤119 tiles 目标未达到。当前 WNS/WHS 通过非负时序门槛，BRAM 使用量仍偏高。

DRC 检查 54 项、0 个错误。仍有生成 IP pipelining、RAM 控制和 LUT 方程等 warning。CDC 报告无 Critical 项；有 2,257 个 CDC-15 warning，表示 clock-enable controlled CDC structure。后续仍需逐项完成 CDC 签核。

## 未覆盖范围

- 当前机器没有 Windows 原生 Vivado/Vitis；Windows 原生 bitstream、XSA 和 app 构建未验证。
- 实板已验证 HDMI 菜单、DDC/EDID、VDMA、SD 目录只读扫描、音频 codec 配置和 BTN0–BTN3 的 PL 状态输入。实板存档写入/掉电恢复、扬声器/耳机声音与长时间运行仍未验证。
- 当前 USB Host 设备报告 VID/PID 0x2DC8:0x6013、HID class；固件日志为 interface unsupported。需要连接 XInput 模式或受支持的手柄，才能完成实体手柄测试。
- RTL 完整 suite 仅运行 seed 0；seed 1～31 未运行。
- 命令行尚无 board/profile 参数；输出目录也未按输入摘要分层。
- LVGL 9.6.0 已由 Vitis app collector 构建 598 个目标。LVGL 弃用的内存池扩展配置已移除，最终 app 日志中没有 LVGL 弃用警告。应用层不再引用弃用的 list、通用 flag 或 long-mode API。上游随包保留的 v9.5 API map 文件属于官方兼容层，不是旧 runtime。
- HDMI 总线接口由 EmbeddedVideoIP IP 仓库维护；LVGL 版本由应用依赖配置锁定，CherryUSB 版本记录在应用依赖清单中。
- 上一轮将 FreeRTOS 总堆调整到 262,144 B，并重建 platform/BSP/FSBL/app/BOOT.BIN。本次 BTN 快照更新只改 PL RTL；重新综合实现并生成 bit/XSA。PS 初始化文件与现有平台一致，因此复用 PS app。新 bit 尚未打包进 BOOT.BIN；当前 Flow 报告将 platform/app/boot 标为依赖过期。
- LVGL 主机回归证明目标配置下 128 个单标签 ROM 行场景没有分配失败。实板启动时没有出现 FreeRTOS malloc failure，完整菜单也已采集；LVGL heap 高水位和 Cortex-A9 刷新耗时尚未测量。长时间游戏运行仍待验证。

## 重建硬件交付

工程生成和仿真使用 out/vivado/project/，不会清除 hardware build 输出。下次硬件 stage 可独立运行：

~~~sh
python3 tools/flow.py build --stage hardware --jobs 4
python3 tools/flow.py report --json
~~~



## stripes.gba 白屏调查与修复（2026-11-10）

### 根因

用户确认 SD 卡中的 `stripes.gba` 与 `F:\02_Projects\GBA_ROM\stripes.gba` 字节一致。ROM 头、logo 校验和与运行入口均有效，排除 SD 复制损坏。反汇编可见它设置 BG0 和蓝色调色板，只初始化 tile 0，并只写入 screen map 中每隔一个的半字；tile 1、其余地图项依赖原有 VRAM 内容。

项目的 VRAM、OAM、BG/OBJ palette 位于不带内容复位的双口 RAM。ROM 切换前没有清空它们。因此 `stripes.gba` 在干净内存下显示蓝色竖条，前一 ROM 留下的图块/地图/调色板则能让相同 ROM 显示白屏。旧白屏采样中，原始 capture 行哈希对应全 `0xFFFFFFFF`，三个 PS framebuffer 也都是 `0x00FFFFFF`；VDMA `err=0`，说明白色已来自 GBA 像素源，不是 HDMI 或 VDMA 把正确图像变白。

### 实现

- `gba_memorymux.vhd` 在 core 关闭后，等 memorymux 和 savestate/debug 总线安全时，用已有 port-A 写口逐地址清零 VRAM low `0..16383`、VRAM high `0..8191`、OAM `0..255`、BG/OBJ palette `0..127`。最后一个 BRAM 写周期提交后才撤销 clear-busy；遇到调试/savestate 请求时在字边界暂停并从当前地址继续。
- `gba_top.vhd` 在清零完成前保持 CPU/GPU 关闭；core 关闭期间不转发旧 CPU/DMA bus valid。清零前会等待 savestate 状态退出，并保留/服务调试总线请求。
- `gba_cpu.vhd` 在 CPU reset 时撤销旧数据总线请求。`gba_savestates.vhd` 锁存 core-off 事件，取消可能等待 CPU 的 save/load 起始等待态；其他已发出事务继续排空后再进入 reset。

清零总计 16,384 个 100 MHz 周期，约 164 µs；暂停调试总线时按实际服务时间延长。没有修改 `stripes.gba`，也没有修改 CherryUSB。

### 综合、实现与实板结果

Vivado 2025.2.1 在 XC7Z020 上完成综合、布线、post-route physopt 和 bitstream。综合为 0 errors、0 critical warnings；写 bit 前 DRC 为 0 errors。布线报告显示 55,877/55,877 可布线网络完成路由，无 routing errors。Post-route timing summary：WNS `+0.138 ns`、TNS `0`、WHS `+0.014 ns`、THS `0`，setup/hold 均无 failing endpoint。`write_hw_platform -fixed -include_bit` 已生成新 XSA。

通过一份 XSCT 2025.2.1 脚本在同一操作中停止 CPU0、下载新 PL bit、执行 `ps7_init`/`ps7_post_config`、下载现有 ABI 兼容的 Vitis app ELF 并运行 15 秒；日志包含 `PL_CONFIGURED`、`PS_INITIALIZED`、`APP_RUNNING` 与 `APP_RAN_15S`。

| 实板组合 | 结果 |
| --- | --- |
| 冷启动 → stripes | HDMI 采集卡 C1-1 USB3 Video 显示蓝色竖条；`pctrace` 到 ROM 循环，`pixcap raw_hash=0x98AB9C45`、行哈希 `0x13CF4699`；`fbscan white_lines=0`、`anomaly=0`。 |
| MechPlatoon → stripes | 控制台确认 MechPlatoon PC 位于 ROM 区；之后切回 stripes，PC 稳定在 ROM 循环 `0x08000140..0x08000148`，原始 capture 与三缓冲均为蓝条，`white_lines=0`、VDMA `err=0`。完成多轮受控复测。 |
| 同 ROM 重载 stripes、core off/on、reset 1→0 | 受控复测后均恢复同一蓝条图案；C1-1 采集的最终画面为 [stripes_final.png](E:/Ubuntu-FPGA/stripes_final.png)。 | 最终 UART 记录：[stripes_vram_clear_final.log](../out/board-test/20261110/stripes_vram_clear_final.log)。
| MechPlatoon HDMI | C1-1 实际采到运行画面：[mechplatoon_after_load.png](E:/Ubuntu-FPGA/mechplatoon_after_load.png)。 |
| Skyland | ROM 成功装载，但几秒后 PC 仍在 BIOS `0x187C` 且 HDMI 白屏；目前没有足够证据区分游戏启动等待与此 ROM 的 BIOS/兼容性问题，不能归到 stripes 的 stale VRAM 根因。 |

受控切换测试中曾有一次 MechPlatoon→stripes 后观测到无效 PC 与全白帧；手动 core off/on 后恢复，随后受控的 MechPlatoon→stripes、Skyland→stripes 与同 ROM 重载均通过。该单次瞬态未被再次复现，仍应在下一轮板测继续观察；当前不能声称所有复位组合都已经证明无故障。

测试 Skyland 时，系统日志显示已预载 `0:/saves/Skyland.sav`，随后自动写回一次 65,536 字节 save，报告 checksum `0x00000000`。测试前没有保存该文件副本，故无法核实此次 flush 是否改变原存档；后续没有继续加载 Skyland 或操作其存档。`dozerrun.gba`、`boktoslr.gba` 的试探路径返回 `no_file`，未作为游戏测试结果。

板上最终停留在已验证的 stripes 蓝条画面。保留长时间运行、其他 ROM 存档行为以及 Skyland 启动问题为未覆盖项。


## PS 黑屏与 FreeRTOS Data Abort 复测（2026-11-10）

在之后的多 ROM 测试中，C1-1 采集到纯黑帧，UART 不再响应。XSCT 读到 PS Cortex-A9 CPSR mode=`0x17`（Abort），PC 落在 `Xil_DataAbortHandler` 的死循环。`DataAbortAddr=0x001B6590` 经 `addr2line` 指向 FreeRTOS `vTaskSwitchContext()` 的栈溢出检查；被检查的 `pxCurrentTCB->pxStack` 读取地址为 `0x9D5D53AA`，是无效指针。PS 应用因此停止调度，黑帧来自 UI/视频发布服务停止后的显示缓冲。

`PsAppMonitorTask` 同步处理 ROM load、save 与 feature restore，原栈为 2,000 words（8 KiB）。已新增 `PS_APP_MONITOR_TASK_STACK_WORDS=32*configMINIMAL_STACK_SIZE`（6,400 words，25.6 KiB），并将该专用栈用于 `mon` 任务；启动任务仍使用原系统栈。通过 Vitis 2025.2.1 app API，以现有 FreeRTOS XPFM 重新构建，`build/.buildstatus` 为 `hw=SUCCESS`，ELF 大小 31 MB。随后按要求以同一 XSCT 脚本联合配置 PL、初始化 PS、下载新 ELF 并运行 15 秒；不需重跑 PL 综合/实现。

新 ELF 上板后 UART 恢复，HDMI 菜单重新出现。MechPlatoon→stripes 回归成功：MechPlatoon PC 位于 `0x0800E5E8`；回切 stripes 后 `pctrace` 位于 `0x08000140` 循环，`pixcap raw_hash=0x98AB9C45`，`fbscan white_lines=0/anomaly=0`，VDMA `err=0`。C1-1 实际采到新画面：[screen_after_stackfix.png](E:/Ubuntu-FPGA/screen_after_stackfix.png)。最终 UART 记录：[stripes_after_monitor_stack_fix.log](../out/board-test/20261110/stripes_after_monitor_stack_fix.log)。

该栈扩容是针对 Data Abort 现场的保守缓解；任务 TCB 的 `pxStack` 已损坏，但现场无法安全读回当前 TCB 所属任务名，因此还不能证明溢出的就是 `mon` 任务。需将它作为 PS 调度/内存完整性风险继续观察，不把一次复测通过写成永久根因已完全签核。


### Skyland 白屏的后续区分

补充板上诊断显示，Skyland 的 raw capture 与三帧 PS framebuffer 均为全 `0xFFFFFFFF`，`fbscan` 为 `white_lines=17/anomaly=1`，但 VDMA 仍是 `err=0`、480 行、stride 2,560 B；采样期间 `vramdiag` 的 VRAM request/write 都是 0。PC 曾在 BIOS `0x0000187C`，后续进入 `0xE2...`（`region=OTHER`），没有进入 ROM 区或正常的 VRAM/MMIO 初始化。

这与 stripes 的旧白屏条件不同。GBA reset 默认 `DISPCNT=0x0080`，bit 7 是 Forced Blank；GPU 在该位有效时直接输出全白 RGB。Skyland 文件头和 checksum 合法，启动入口先进入 Thumb bootstrap，代码会复制初始化代码/数据到 EWRAM `0x02000000` 再执行。当前异常 PC 指向 E 区（SRAM/Flash 地址区）且无 VRAM 写入，说明其启动/取指路径尚未正确到达清除 Forced Blank 的游戏代码；现有数据不足以区分该 ROM 的启动兼容性与 GBA CPU/EWRAM 内存执行路径问题。F 盘与 SD 版本相同，复制损坏不是解释。

因此，当前结论是：**stripes 原白屏由 stale VRAM 引起并已在受控切换中修复；Skyland 白屏是另一条 CPU/启动路径问题，仍未定位。** 板上最新复测结束后重新停留在 stripes 蓝条画面。


## Elevator → Skyland 长白屏调查与修复（2026-11-11）

用户报告先运行 `电梯大战.gba`、再切到 Skyland 时，偶尔出现长时间白屏。源码检查确认，ROM 软切换会关闭 GBA 核心，但 IWRAM 使用的双口 BRAM 没有复位端口，旧内容会留在 RAM 中。PS 的加载期清屏只处理 HDMI DDR 帧缓冲，不能清除 PL IWRAM。

### 源码改动

- `src/rtl/core/gba_mister/rtl/gba_memorymux.vhd`：复用 `VIDEO_MEM_CLEAR` 状态清理 IWRAM 的 8,192 个 32 位字，并把索引 `0x1FFE`（GBA 地址 `0x03007FF8`）设置为 `0x00000001`。该清理与现有显存清零并行。
- `src/ps/app/src/App/Src/ps_app_runtime_rom.c`：当前工作树中已有一项未提交改动。在保存旧存档和读取新 ROM 前先清 HDMI 帧缓冲，防止加载时保留旧画面。它与 IWRAM 清理作用于不同内存。

### 综合和下载

使用 Vivado 2025.2.1 对当前硬件工程完整综合、实现一次，并生成 bit 和 XSA。DRC 错误数为 0；后布线 WNS `+0.100 ns`、TNS 为 0、WHS `+0.014 ns`、THS 为 0。板上使用 `tools/board/joint_program.tcl`，先系统复位，再配置 PL、运行 PS 初始化脚本并下载应用。复用了已有 PS app ELF 和 `ps7_init.tcl`，没有生成 BOOT.BIN。

### 实板复测

在 Zybo Z7-20 上按“电梯大战 → Skyland”连续复测两轮。两次都从电梯大战标题进入 Skyland 标题和游戏场景。UART 确认 SD 路径分别为 `0:/games/电梯大战.gba` 和 `0:/games/Skyland.gba`；游戏代码分别为 `ANWJ` 和 `SKLD`。

直接采集 OBS Virtual Camera，分别取得 70 帧和 80 帧，频率为 2 fps。中心区域近白像素占比的最大值为 14.06%，没有达到 90% 近白阈值的帧。第一轮 `hangsnap` 共 8 次、间隔 250 ms，CPU 在 BIOS、IWRAM 和 ROM 区间间推进，非法取指计数为 0；捕获序号持续增加，`FBSCAN white_lines=0`，VDMA 错误为 0。

完整摘要和截图见 `out/board-test/20261111/elevator_to_skyland_iwram_clear.log` 及同目录 PNG 文件。

### 证据边界

旧故障发生瞬间的 IWRAM 锁字值无法通过当前诊断接口直接读取。因此，记录确认 IWRAM 未随软 ROM 切换清理，并记录加入清理后的两轮复测结果；没有把故障瞬间的锁字值写成已实测事实。两轮通过不等于长时间运行或全部游戏组合都已验收。


## 2026-11-11 PPA 候选实现与板测

### 候选改动

- `ddram_mux.sv` 简化 burst 1、2、4 的 4 KiB 页尾限制。
- GamePak cache 从 128 KiB 改为 64 KiB。IWRAM 清理修复保留。
- 启用 Vivado 的 `power_opt_design` 和 `post_place_power_opt_design`。两个步骤都有成功完成标记。
- cache 读门控实验未通过整机测试，已回退。GPU RAM 映射实验发现碰撞行为不同，没有改生产映射。

### RTL 回归

8 个 memory、CPU、DDR 和 RAM bench 均 PASS。comprehensive DDR 为 23 pass、0 fail；burst 页尾测试有 1,536 项检查。保留的 64 KiB `tb_gba_top_full` 到达 PC `0x0808075C` 并 PASS。新工程中的一次重复整机仿真在 8.5 ms 处取消，没有计为通过。

### PPA 结果

| 指标 | 基线 | 候选 |
| --- | ---: | ---: |
| BRAM Tile | 127/140 | 107/140 |
| Slice LUT | 28,367/53,200 | 29,162/53,200 |
| Slice Registers | 30,844/106,400 | 30,742/106,400 |
| Unique Control Sets | 1,154/13,300 | 2,008/13,300 |
| DSP | 12/220 | 12/220 |
| 100 MHz WNS | +0.100 ns | +0.186 ns |
| 100 MHz TNS | 0 | 0 |
| 100 MHz WHS | +0.014 ns | +0.016 ns |
| 100 MHz THS | 0 | 0 |

BRAM 少 20 tiles。LUT 多 795 个，寄存器少 102 个。WNS 提升 0.086 ns，但低于 +0.300 ns 优化目标；setup、hold 硬门槛均通过。57,646 条可布线网络全部布通。DRC error 为 0。bit 和 XSA 已生成。

Vivado 的功耗估算为 2.338 W 到 2.219 W。两个报告置信度均为 Low，没有 SAIF。未做板级功耗测量，不能据此宣称实际节电。

### CDC 与方法学

CDC 报告的 CDC-15 warning 从 2,257 降到 2,237；CDC-3 info 为 45，CDC-9 info 为 1，没有新增类别。CDC-15 是按数据位统计的 clock-enable controlled bundled-data 路径。相关 mailbox 保持 payload，并使用 request/ack toggle 与部分 SVA；payload 延迟没有通过 `set_max_delay -datapath_only` 或 bus-skew 约束闭合。这是本轮前已有的 CDC 签核风险。

methodology 的控制集规则从 ULMTCS-1 变为 ULMTCS-2。placed 报告的控制集是 2,008/13,300（15.10%），基线为 1,154/13,300（8.68%）。DRC 多 1 条 VDMA XPM FIFO 的 REQP-1839 ENBWREN 异步控制 warning。原有 WEBWE 异步控制 warning 仍存在。power-opt 日志显示它把部分写使能移到 EN 端口。

check_timing 没有未约束的内部端点、无时钟寄存器或组合环路。8 个按键/开关输入和 12 个 HDMI/音频输出由 false-path 约束排除。具体报告在 `out/board-test/20261111/optimization-final-reports/`。

### 实板回归

使用 `joint_program.tcl` 联合复位并下载 PL、PS，复用 app ELF 和 `ps7_init.tcl`。OBS Virtual Camera 捕获到启动菜单、MechPlatoon 标题、Skyland 标题、stripes 条纹，以及 stripes 切回 Skyland 后的标题画面。

| 场景 | 捕获 FPS | blit FPS | present | CyclesMissing 增量 |
| --- | ---: | ---: | ---: | ---: |
| MechPlatoon | 59.33 | 58.53 | 98.7% | 0 |
| Skyland | 59.40 | 59.30 | 99.8% | 0 |
| stripes | 59.40 | 59.30 | 99.8% | 0 |
| stripes→Skyland | 59.30 | 59.30 | 100.0% | 0 |

MechPlatoon 旧基线是 59.30/58.50 FPS、98.7%、CyclesMissing 增量 0。本轮采样基本持平。Skyland 切回后连续采集 20 帧，近白比例最大值为 3.60%，没有帧达到 90%。

本轮按整体收益保留该 PPA 候选作为当前开发版本：BRAM 少 20 tiles，100 MHz WNS 改善 0.086 ns；MechPlatoon 与旧基线帧率持平，Skyland 和 stripes 样本约 59 FPS，CyclesMissing 增量均为 0。新增控制集与 ENBWREN warning 已记录。功耗估算置信度低，payload CDC 的物理时序也未闭合，因此不把它标为最终发布版。

Skyland 加载时日志显示先预载原有 `0:/saves/Skyland.sav`，随后自动 flush 成功。期间没有操作游戏；写后 checksum 未启用，没有逐字节对比存档。

UART console 过滤非 ASCII 字节，因此本轮未重新加载中文名的 Elevator ROM。之前两轮 Elevator→Skyland 复测仍记录在 IWRAM 修复条目中，不属于本轮 bit 的新实测。实体手柄、音频、掉电保存、长时间运行、全 ROM 矩阵、板级功耗和 Windows 原生构建未测。

## 2026-11-12 UART UTF-8 路径与 power-opt 候选复测

### UART 输入与 app 构建

原 UART 行接收器只保留 0x20～0x7E。中文 ROM 路径的 UTF-8 字节因此被丢弃，旧命令变成 0:/games/.gba。FatFs 当前启用 FILE_SYSTEM_USE_LFN=2 和 FF_LFN_UNICODE=2，路径 API 使用 UTF-8。存储格式和 ROM 加载接口无需改变。

新增行输入 helper，保留 UTF-8 字节和 192 字节总缓冲。退格按 UTF-8 字符删除。超过 191 字节的输入行整行拒绝，不再执行截断路径。Host 测试覆盖 ASCII 命令、完整 UTF-8 ROM 路径、多字节退格和超长行。

Python 单测 55/55 通过；Host C 回归 7 个 suite 全部通过。Vitis 2025.2.1 在现有 XPFM/BSP 上 app-only 构建成功，编译清单含 597 个条目。新 ELF SHA-256 为 813fe3468931c4a98df95d27f3103c4dfb1c9b754fd925c01ff9f7fa312a36e7。新 app 的 ps7_init.tcl 与候选 XSA 内脚本 SHA-256 一致。本轮没有重跑综合实现，也没有重建 platform、FSBL 或 BOOT.BIN。

联合 XSCT 脚本先复位 PS，再配置候选 PL、初始化 PS 和下载新 app。部署记录位于 out/board-test/20261112/utf8-poweropt/xsct_joint_utf8_app_20261112.log。测试结束后再次联合复位，应用回到未加载 ROM 的菜单。

### Elevator → Skyland 复测

使用 UTF-8 串口命令直接加载 0:/games/电梯大战.gba，共验证三次。每次都返回 rom load ok；ROM 为 8,388,608 字节，代码为 ANWJ。随后直接加载 0:/games/Skyland.gba，两次同步 OBS 采样均确认路径、大小和 ROM 头正确；大小为 24,693,968 字节，代码为 SKLD。

画面只从 OBS Virtual Camera 采集。round 2 和 round 3 各录制 90 帧，采样率 2 fps。录制起点、命令发送和加载完成时间保存在配套 UART 日志。两个同步样本里，命令发出后不到 1 秒便显示黑色加载画面；随后出现 Skyland 图像。每个样本中心区域近白像素的最大比例为 4.77%，没有帧达到 90% 阈值。黑色启动阶段不计作白屏。

Elevator 场景测得捕获 59.30 fps、blit 59.30 fps、CyclesMissing 增量 0。Skyland 场景的捕获和 blit 约为 59.3～59.4 fps，CyclesMissing 增量 0。ROM 路径、联合下载和 UART 诊断记录位于 out/board-test/20261112/utf8-poweropt/board-retest-summary.md 及同目录日志、OBS 截图。

### power-opt 风险检查

placed utilization 报告记录 control sets 2,008/13,300，基线为 1,154/13,300。Methodology 报告的 ULMTCS-2 消息另记 2,012；记录保留报告阶段与原始数值，不把两个计数混为一个结果。ULMTCS-2 warning 仍存在。

REQP-1839 总数从基线 8 增至候选 9。新增 ENBWREN 异步控制项位于 HDMI VDMA XPM FIFO RAMB36；同一 RAM 的 WEBWE 异步控制项在基线中已存在。DRC error 为 0。联合复位后的首个菜单画面可见，VDMA CR=0x00014001、SR=0x00011000、err=0。Elevator 和 Skyland 运行期间 VDMA error 保持 0。

在 Elevator 和 Skyland 场景都调用 hdmi park 1，再调用 hdmi park 0 恢复。命令均返回成功；恢复后屏幕继续更新。Skyland 的 10 秒采样为捕获 59.40 fps、blit 59.10 fps、成功提交比例 99.5%、CyclesMissing 增量 0。该实板检查没有消除 ENBWREN 的静态时序风险，也不能代替 ULMTCS-2 的资源建议。

功耗报告仍为 Low confidence，没有 SAIF 或板级功耗测量，不将估算写成实测节电。

### 来源和存档边界

flow.py report --json 仍因候选 bit 哈希与最后成功清单不匹配而报告 hardware stale。实际候选 bit/XSA 存在，Vivado 2025.2.1 构建和本轮联合下载记录已核对。没有为清除 stale 状态重跑硬件构建。

按用户指示，没有备份或逐字节核对 SD 存档。Skyland 加载过程中应用执行了自动 save flush，存档内容未核验。其他游戏、长时间运行、板级功耗和 CDC payload 时序未标为通过。

## 2026-11-16 HDMI 音频与 QSPI 当前状态

当前 EmbeddedVideoIP 版本为 0.2.0-dev.4，GBA 通过锁定的提交 2008d713bf3ee37495bbc940634ad7b917a0ba78 接入。LVGL 主菜单可以在启动游戏前选择 HDMI 或 I²S codec；I²S 实现留在 GBA，EVIP 只接收通用 PCM AXI4-Stream。完整迭代、修改路径和验证数据见[HDMI 音频与 QSPI 验证记录](embedded-video-audio-qspi-validation-2026-11-16.md)。

本轮定位并修复 HDMI 无信号的根因：像素域 proc_sys_reset 的辅助复位极性与固定低电平不匹配。修复后 C1-1 USB3 Video 采到 MechPlatoon 640×480、60 fps 画面；HDMI 音频样本也到达 C1-1 USB3 Audio。当前证据确认采集卡收到音频数据，未做显示器扬声器的主观听音。

PL 最终时序为 WNS +0.152 ns、TNS 0、WHS +0.012 ns、THS 0，DRC 错误和 Critical Warnings 均为 0。QSPI 在偏移 0 写入 4,549,304 bytes BOOT.BIN，blank check、program 和 readback verify 均成功；没有擦除整片 Flash。板卡启动模式仍为 JTAG，本轮没有进行 QSPI 冷启动验证。

## 2026-11-16 EVIP 文档和依赖状态

EmbeddedVideoIP 主分支现在包含文档提交 a7c480c。GBA 继续锁定板测时使用的代码提交 2008d713。Flow 接受该锁定提交的干净 Markdown-only 后续版本，并验证 RTL、PS 库、约束和依赖清单没有变化。新的 Flow 回归通过；输入清单经安全重键后，hardware、platform、app 和 boot 阶段仍通过。没有运行综合、实现或 QSPI 烧录。


## 2026-11-18 03-GBA 对话最新状态

本轮 Sony 电视上的音频切换失败已在真实电视连接下复现并修复。EDID block 0 的 DDC 发送失败使链路留在 DVI-safe 模式，进而触发 HDMI 音频路由错误 4。跳过 segment 0 的冗余 E-DDC segment pointer 写入后，电视 EDID 有效，HDMI VSDB 与 link mode 均确认，HDMI 音频自动路由成功。

启动时保留 I²S 为安全路径；收到有效 HDMI EDID 后自动切换 HDMI。开机音量恢复到 45%，I²S codec 曲线未改，HDMI Q15 增益映射未再改。Sony 电视软件路由实测 HDMI→I²S→HDMI 成功，错误数为 0。I²S 主观听感未由代理验收。

Sony EDID 基础块列出最高详细时序 1920×1080p60；CTA 扩展原始视频数据块未导出，因此完整最高能力仍未签核。EDID 可以确认 HDMI sink，但不足以直接确认 sink 的 HDMI 规范版本。

最终 BOOT 通过 QSPI 空白检查、写入和读回 verify；实际 Flash 型号警告已保留。板上随后由 JTAG 恢复同一最终 App，当前不是已验证的 QSPI 冷启动状态。用户豁免真实手柄操作，不能写成真实手柄通过。紫条问题仍保留采集卡/物理接收端证据边界。

详细内容和所有提交证据见 [03-GBA 与我的工具箱全对话归档索引](03-gba-toolbox-archive-index.md) 与 [2026-11-18 Sony 电视及最终 QSPI 验证](validation-2026-11-18-menu-audio-qspi.md)。

## 2026-11-19 HDMI 音频修复与实现策略

720p 游戏态 HDMI 音频的无声问题已定位为 PCM 位对齐错误。GBA 输出 signed 16-bit 样本，HDMI 音频包使用 24-bit LPCM；旧代码低位对齐导致约 48.16 dB 衰减。修复后适配器左对齐样本，RTL 回归同步检查 24-bit 打包和 FIFO 行为。

本轮 clean implementation 通过门槛：WNS `+0.111 ns`、WHS `+0.015 ns`、TNS/THS 为 0，DRC errors 和 Critical Warnings 为 0。增量实现 WNS 为 `-0.461 ns`，因此 GBA Flow 默认采用 clean placement/routing；只有显式设置 `ZYNQ_GBA_INCREMENTAL_IMPLEMENTATION=1` 才启用增量实现。

JTAG 部署、MechPlatoon ROM 加载和 1280 × 720 视频状态通过 UART 检查。C1-1 USB3 Audio 的游戏态采样 mean `-29.6 dBFS`、peak `-18.7 dBFS`。菜单本身静音，用户负责最终扬声器听感验收。证据和未覆盖边界见 [2026-11-19 HDMI 720p 音频修复与验收](validation-2026-11-19-hdmi-audio-720p.md)。

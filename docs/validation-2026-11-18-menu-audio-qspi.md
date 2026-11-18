# GBA 菜单、HDMI 音频与 Sony 电视兼容性记录

记录日期：2026 年 11 月 18 日。本文保存本轮 GBA 消费项目的代码变更、串口证据、构建产物和 QSPI 写入结果。

## 本轮结论

Sony 电视上的 HDMI 音频切换失败已定位并修复。根因是 PS 固件读取 EDID 基础块时，向 E-DDC segment pointer 地址 0x30 写入了默认值 0；电视对这个可选地址返回 NACK，固件便提前终止 EDID 读取并退回 DVI-safe 模式。跳过 segment 0 的这次冗余访问后，同一台电视的 EDID 读取成功，音频路由也切到 HDMI。

最终策略在有效 HDMI EDID 到达后自动优先 HDMI。EDID 无效、显示器未接或识别为 DVI 时，仍保留 I²S。用户手动选择输出后，启动时的自动选择不再覆盖用户选择。

最终启动音量恢复到 45%。I²S codec 音量曲线没有改动。HDMI 线性增益曲线也没有再改动。最终应用、BOOT 镜像已写入 QSPI 并通过读回验证。开发板随后以 JTAG 模式恢复运行最终应用；QSPI 断电启动未验证。

## 迭代背景

本轮承接了前几轮 GBA、EmbeddedVideoIP 和 FPGAFlow 修改。已处理 HDMI RGB 色彩声明、菜单刷新与 VDMA 帧选择、按键映射和 10 ms 去抖、音频路由刷新事务，以及启动和返回菜单后的显示恢复。新加的 FPGAFlow 消费端配置和板级验证也一起归档。

左侧紫条的证据边界仍按之前的结果记录：EmbeddedVideoIP 行首定向仿真生成 BMP，764 次行首检查通过；C1-1 原始采集数据曾出现行首色度收敛，更像采集卡处理伪影。此前 C1-1 录像中未复现异常条纹。本轮 Sony 电视上的检查聚焦于 DDC 和 HDMI 音频，未重新做紫条长时间或多接收端验证。

相关历史记录见 [2026-11-16 HDMI 音频与 QSPI 验证](embedded-video-audio-qspi-validation-2026-11-16.md)。本轮菜单、音量、Sony 电视问题及最终镜像身份见下文和同目录采集文件。

## Sony 电视问题与根因

用户照片显示菜单画面正常，状态栏报“音频切换失败 (4)，保留 I2S”。

切到 JTAG 并保持 Sony 电视连接后，串口读到：

    [CMD] audio rate=48000 bits=16 mute=0 vol=50 path=I2S route=failed requested=HDMI err=4
    [HDMI-DIAG] audio_ctrl=0x00000002 audio_status=0x00000000
    [HDMI-DIAG] hpd=1 edid_valid=0 sink=DVI link_mode_requested=DVI request_written=1 vsdb=0 cea_v3=0 cea_block=0 extensions=0 read_extensions=0
    [HDMI] warning: EDID block 0 read failed (3), retrying in DVI-safe 640x480@60 (fail=40)

错误码 3 是 DDC_SEND_FAILED。底层代码把两次发送都折叠成同一个错误：E-DDC segment pointer 写入，以及 EDID 地址 0x50 的 offset 写入。错误码本身不能区分是哪一次发送失败。

代码对每个 EDID block 都先向地址 0x30 写 segment。读取 block 0 和 block 1 时，segment 值都是 0。VESA E-DDC 标准说明 segment pointer 默认值为 0；只有读取 segment 1 及以上才需要完整的 segment pointer 操作。标准也说明，如果所有数据都位于 segment 0，显示器不必实现 segment pointer。

因此，Sony 电视在 segment 0 指针访问处 NACK 的情况会被原代码误判成整块 EDID 失败。系统因此停留在 DVI-safe 模式。I²S 到 HDMI 路由时，EVIP 的 HDMI 音频状态位由“音频请求使能”和 HDMI link mode 共同决定。DVI-safe 状态下，该位保持 0，PS 端便报告路由错误 4 并回滚至 I²S。这是路由失败的直接原因，不是电视拒绝了已发送的音频数据包。

依据：[VESA Enhanced Display Data Channel Standard 1.2，segment pointer 默认值与 segment 0 操作](https://ptacts.uspto.gov/ptacts/public-informations/petitions/1558236/download-documents?artifactId=Y9u8l99OzSU8NBC2E3orTQ2jqw5OgkjMpSNMU4nLGKWaAD-Wa0SWXRs)。该标准列出 segment 0 可直接访问 block 0 和 1，且全数据位于 segment 0 时不要求实现 pointer。

## 电视 EDID 能识别到的信息

我通过 JTAG 只读了运行中 app 缓存的 128 字节 EDID 基础块。校验和通过。基础块报告厂商码 SNY、产品码 0x5201、名称字符串“SONY TV XV”、EDID 结构 1.3，并声明 1 个扩展块。固件已确认扩展块是 CTA revision 3，含 HDMI VSDB。

基础块的两个详细时序为 1920×1080p60（148.5 MHz）和 1280×720p60（74.25 MHz）。所以目前能确认基础块声明的最高详细时序是 1080p60；这不是完整 EDID 下的最高分辨率结论，因为 CTA 扩展中的 Video Data Block 没有保存在当前运行状态，也未从串口导出。

这份 EDID 证明电视是 HDMI sink。它没有提供一个可直接当作“HDMI 1.4/2.0/2.1 版本号”的字段。本项目 HDMI transmitter 按 HDMI 1.4b 实现；不能据此把电视也标为 HDMI 1.4b。基础块原始数据和解析结果见 sony-tv-edid-block0.bin、sony-tv-edid-summary.json、tv-edid-readback.log。

## 代码修改

### DDC 读取

src/ps/app/src/Hdmi/Src/ps_app_hdmi_link.c 现在只在 segment 大于 0 时写 segment pointer。block 0 和 block 1 直接从 0x50 读取；更高的 EDID block 仍通过 E-DDC segment pointer 访问。

### 自动选择音频输出

src/ps/app/src/Common/Inc/ps_app_state.h 用音频状态中原先保留的字节记录启动时的自动 HDMI 选择状态。

src/ps/app/src/App/Src/ps_app_runtime_boot.c 开机先保留 I²S 作为安全路径。HDMI link 服务确认 HPD、EDID 有效、sink 为 HDMI 且 link mode 请求写入成功后，owner task 自动发起 HDMI 音频切换。有效 EDID 还没到达时继续保留 I²S。用户手动选择任一路径后，固件清除自动切换标志。

### 音量

I²S codec 的音量映射保持原值。本轮将共享开机音量从 50 恢复至原先的 45，匹配 I²S 上次稳定的默认响度。HDMI Q15 线性映射不变：0% 静音、50% 为 16384、100% 为 32768。最终自动 HDMI 启动时共享音量为 45，对应 Q15 增益 14746。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| Sony 电视 EDID | 修正前 block 0 读取错误 3，edid_valid=0；修正后 hpd=1、edid_valid=1、sink=HDMI、VSDB 有效、扩展块读取成功；基础块最高详细时序 1920×1080p60 |
| HDMI link mode | 修正后 link_mode_requested=HDMI、request_written=1 |
| 音频自动选择 | 最终启动后 vol=45、path=HDMI、route=idle、requested=HDMI、err=0、pcm_overflow=0 |
| HDMI 音频硬件状态 | 修正后 audio_ctrl=0x00000001、audio_status=0x00000001 |
| 手动路由回归 | HDMI → I²S → HDMI 均成功，路由错误为 0 |
| HDMI 视频状态 | 像素复位已释放、串行时钟与像素时钟已检测、MMCM 锁定、HPD 高；HDMI errors=0、VDMA error=0、DMA error=0 |
| 菜单帧缓存 | 最终检查 fb0 非零、fbscan anomaly=0；ROM=0 |
| App 构建 | 成功，ABI/build id 为 0x39EB86A3 |
| BOOT 构建与校验 | 成功，manifest 中 BOOT 依赖的 app SHA 与最终 app SHA 相同 |
| QSPI | offset 0、qspi-x4-single、-blank_check -verify；Erase、Blank Check、Program、Verify 均有成功文本 |

前一轮菜单回归记录 48 次真实音频路径切换和 4 次游戏退出返回菜单。包含 HDMI 音量映射调整的后续回归记录 12 次实际路由切换。Sony 电视验证单独记录在 sony-ddc-fix-live-uart.log、app-auto-hdmi-volume45-live.log 和 app-auto-hdmi-i2s-restore-route-test.log。最终 QSPI 证据在 final-qspi-detailed.log 和 final-qspi-deployment-record.json。

旧版音频采集测得默认 50 的 RMS 为 −61.9 dBFS，但该段发生在错误映射修正前。新映射的 50% 采集为 −31.9 dBFS、峰值 −19.6 dBFS，窗口内没有削顶。最终开机音量恢复为 45，未在 Sony 电视上另做扬声器主观响度测量。I²S codec 映射没有修改；最终版本的软件路由和音量字段检查通过，真实 I²S 听感仍由用户确认。

### 验证边界

实际 Flash 芯片识别为 Winbond w25q128jv，工具仍提示型号不匹配。本轮保留该警告；擦除、空白检查、写入和读回比较均成功。最终 manifest 标记 readback_verified=true、cold_boot_verified=false。

开发板当前保持 JTAG 启动模式，烧录后由 JTAG 重新下载同一最终 app。没有切到 QSPI 启动位置做断电冷启动，所以不能把读回验证写成 QSPI 冷启动通过。

真实手柄按用户要求豁免人工复测；此前串口注入及软件枚举不等于手柄真实操作通过。

## 最终镜像身份

远端仓库：/home/pzy/Projects/Zynq-GBA_MisTer-Vivado。分支：ps-runtime-hw-sync。本记录生成时 HEAD 为 73b3a2a8ef75c571b89e97e9a285863e97170aec；本轮相关修改当时尚未提交。

| 产物 | SHA-256 |
| --- | --- |
| App ELF | 7d9df0a402b84a5c51e54331850fab07f95f5fa08d7132319713214920f12012 |
| BOOT BIN | 04130d9438ca0dd051f4a3c58604f695e191db98d12bcda8cf47b365bd3504dc |
| PL bitstream | 91a235e28d3b60e265469d35626f20c0c355ee6fbd85e27259480a65e06c3338 |

BOOT 文件为 out/vitis/boot-39eb86a3-d39/BOOT_39eb86a3-d39.BIN，大小 4,578,680 字节。本地备份见 BOOT_39eb86a3-d39.BIN。最终 app 与 BOOT 身份和部署记录见 final-artifact-identities.json、final-manifest-records.json。

最终 QSPI 写入日志为远端 out/board/deploy/20261118T032021Z/qspi.log。日志时间为 11 月 18 日 11:20:21 至 11:25:58（北京时间）。部署没有使用 -erase_all，仅擦除镜像覆盖区域。

    Erase Operation successful.
    Blank Check Operation successful. The part is blank.
    Program Operation successful.
    Verify Operation successful.
    Flash Operation Successful

## 证据目录

本地证据目录为 E:\Ubuntu-FPGA\out\boardtest-20261118。该目录包含串口日志、构建日志、前后版本 ELF/BOOT、EDID block 0、QSPI 日志和回归脚本。最终 JTAG 恢复日志为 final-jtag-detailed.log。最终画面截图工具在本轮无法访问 C1-1 采集设备；Sony 电视串口与 HDMI/VDMA 状态已核对。

GitHub 归档目录 docs/validation-evidence/2026-11-18/ 保存了修复前后串口摘录、最终路由状态、Sony 电视基础 EDID 原始 128 字节及摘要、以及 QSPI 校验摘要。完整 program_flash 日志和部署日志 SHA 保存在本地证据目录。

本文将同步到仓库 docs/validation-2026-11-18-menu-audio-qspi.md，并随本轮相关源代码和测试改动一起提交。

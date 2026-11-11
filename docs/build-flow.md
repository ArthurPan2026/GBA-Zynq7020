# 构建与验证流程

## 目标和工具

本工程的目标板是 Zybo Z7-20，器件为 XC7Z020。当前验证环境是 Lubuntu，使用 Vivado 和 Vitis 2025.2.1。

Flow 脚本使用 Python 标准库。当前运行的 Python 版本是 3.13.0rc1。脚本按 Python 3.10 语法编写；Python 3.10 和 Windows 原生工具链尚未单独验证。

所有命令都从项目根目录运行。Linux 下使用 `python3`。Windows 下使用 `python`，并为 `--vivado` 和 `--vitis` 传入本机可执行文件路径。

## 常用命令

先检查工程契约、依赖 IP 和工具版本：

```sh
python3 tools/flow.py doctor
```

运行 Python 测试和 host C 回归：

```sh
python3 -m unittest discover -s tests
python3 tools/flow.py check --suite host
```

`unittest` 会运行 Python、CMake 源路径解析和 Vitis stage 单测。host suite 使用主机 C 编译器运行 6 个套件：5 个严格 C99 项目测试，以及一个用目标 LVGL 配置和像素字体构建的 LVGL 9.6 场景测试。场景覆盖 640×480 XRGB8888、128 个 ROM 行、中英文长名称、末项滚动、详情文本、刷新边界及 96 KiB LVGL 池余量。

生成 Vivado 工程，再运行 RTL 仿真：

```sh
python3 tools/flow.py project
python3 tools/flow.py sim --suite smoke --seed 0
python3 tools/flow.py sim --suite memory --seed 0
python3 tools/flow.py sim --suite cpu --seed 0
python3 tools/flow.py sim --suite system --seed 0
```

构建硬件、Vitis 平台、应用和启动镜像：

```sh
python3 tools/flow.py build --stage hardware --jobs 4
python3 tools/flow.py build --stage platform --jobs 4
python3 tools/flow.py build --stage app --jobs 4
python3 tools/flow.py build --stage boot --jobs 4
```

查看最终 stage、仿真和报告摘要：

```sh
python3 tools/flow.py report --json
```

`check` 目前只接受 `--suite host`。完整 Python 测试使用 `python3 -m unittest discover -s tests`。

## 工具路径和输出

可用根级参数指定工具和输出目录：

```sh
python3 tools/flow.py --vivado /path/to/vivado project
python3 tools/flow.py --vitis /path/to/vitis build --stage app --jobs 4
```

`--out` 只能指向仓库共享的 `out/`。project 和仿真工程写入 `out/vivado/project/`。hardware build 写入 `out/vivado/`。两个目录互不覆盖，仿真不会删除硬件 stage 的 bitstream。仿真会更新 project 工程文件；切换到另一个 suite 前，先运行 `python3 tools/flow.py project`。
当前输出还包括 `out/vitis/`、`out/sim/` 和 `out/flow/`。命令行还没有 `--board`、`--profile` 和按输入摘要分目录的选项；当前板卡设置固定在工程配置中。

主要输出如下。

| 路径 | 内容 |
| --- | --- |
| `out/vivado/project/` | project 和仿真使用的独立 Vivado 工程 |
| `out/vivado/` | 硬件综合实现结果、bitstream、XSA 和报告 |
| `out/vitis/` | Vitis platform、BSP、FSBL、应用 ELF 和 BOOT.BIN |
| `out/sim/<suite>/seed-<n>/` | 每个 RTL suite 和 seed 的日志、波形及中间文件 |
| `out/flow/manifest.json` | 输入、工具版本、stage 状态和产物 SHA-256 |

Flow 对每个 stage 只枚举实际相关的输入，记录相对路径、文件大小和纳秒级修改时间，再计算一个聚合签名；日常缓存检查不逐个读取源文件计算 SHA-256。普通源码修改会更新修改时间并使对应 stage 失效；如果手动恢复文件原修改时间且内容长度不变，应显式运行对应构建 stage。bit、XSA、ELF、XPFM、FSBL 和 BOOT.BIN 等构建产物仍逐项校验 SHA-256。失败时不会写入成功记录；成功 stage 必须同时具有有效状态和非空产物。

## Vitis 应用源文件

Vitis 的 source collector 会把文件名压成 basename。应用 CMake 用真实源树建立索引，再执行两步检查：

1. 精确路径存在时使用该路径。
2. 只有一个同名候选时使用该候选。零候选或多个候选都会停止配置。

Zybo 工程关闭了 LVGL VGLite。LVGL 的两个 VGLite provider 含同名的 `vg_lite_matrix.c`，当前 CMake 只滤掉这个已确认关闭功能的冲突项。若启用 VGLite，CMake 会要求增加显式路径选择；不要靠文件遍历顺序选择实现。

LVGL 固定为官方 v9.6.0，源码锁见 src/ps/app/src/ThirdParty/lvgl/LVGL_SOURCE_LOCK.json。该锁记录上游 tag、release commit 和导入时的官方树摘要；后续可修改的本地源文件通过 stage 输入指纹跟踪，不会要求整棵树保持原样。上游 MIT 许可证保存在同目录。LVGL 公共头位于 ThirdParty/lvgl/include/lvgl/，项目代码统一使用 <lvgl/lvgl.h>，项目 lv_conf.h 单独维护。

应用沿用 Vitis source collector，并按真实路径解析压平后的 basename。上游 v9.6 将公共 API 头移动到 include/lvgl/，但仍支持手写 lv_conf.h。本工程不导入 LVGL 自带 CMake、示例或测试；Vitis collector 负责收集 src/ 下源码，lv_conf.h 宏负责关闭未启用模块。参见 [LVGL v9.6.0 迁移指南](https://github.com/lvgl/lvgl/blob/v9.6.0/docs/src/changelog/migration-v9-6.mdx)。

Zybo profile 关闭了 LVGL VGLite。两个关闭的 provider 含同名 vg_lite_matrix.c，当前 CMake 只滤掉这一处已确认冲突；若启用 VGLite，必须显式选择完整路径。

硬件输入摘要只包含 RTL、BD/IP、约束、硬件契约和 Vivado Tcl。platform、app、boot 分别记录 Vitis stage 输入及其上游产物摘要。UI 或 LVGL 修改只使 app 和 boot 需要重新验证；硬件输入变化会被 stale gate 拦截，Vitis 不会自动启动综合或实现，需先显式运行 build --stage hardware。旧的全树清单只有在当前相关输入和产物哈希均匹配时才会安全重键。

项目树中的 compile_commands.json 与 .clangd 属于本机 IDE 生成元数据，不会复制进 Vitis 应用，也不参与 app 输入摘要；app.yaml 的模板和 domain 字段由 manifest 的 app metadata 单独跟踪。

## Vitis 平台和 FatFs

`platform` stage 从硬件 XSA 创建 Cortex-A9 / FreeRTOS 平台，配置并构建 BSP，再检查 XPFM 和 FSBL。FatFs 设置必须检查实际应用 BSP，当前值为 `FF_USE_LFN=2`、`FF_LFN_UNICODE=2`、`FF_CODE_PAGE=437`。

`app` stage 复用已构建的平台和 BSP。应用源码复制到独立 stage 输入目录，Vitis workspace 单独创建。CMake configure 不会自动修改 BSP 配置。

`boot` stage 使用匹配的 FSBL、bitstream 和 app ELF。Bootgen 生成后会再解析 BOOT.BIN，并检查来源摘要。不要把不同硬件 ABI 的 ELF、XSA 或 bitstream 混用。

## 第三方 IP 和依赖

Digilent `rgb2dvi 1.4` 已复制到 `third_party/digilent-vivado-library/`。其 upstream commit、文件摘要和 package SHA-256 记录在 `third_party/digilent-vivado-library/dependency-lock.json`。Vivado IP catalog 从本地 vendor 目录读取，不依赖外部路径。

LVGL 9.6.0 和 CherryUSB 保留在 src/ps/app/src/ThirdParty/。LVGL 使用 LVGL_SOURCE_LOCK.json 锁定上游源码与导入摘要；CherryUSB 当前仍没有独立上游版本锁。

## Windows 和实板验证

源码路径解析单测使用了带空格的临时目录。当前主机没有 Windows 原生 Vivado/Vitis，因此本机 Windows 的 bitstream、XSA、platform、app 和 BOOT.BIN 构建都尚未验证。

RTL 仿真不能代替实板测试。接板后仍需验证 USB 手柄、HDMI、音频、SD 卡读写、存档切换和掉电恢复。

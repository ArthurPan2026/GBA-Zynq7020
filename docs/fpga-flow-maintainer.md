# FPGAFlow 维护者构建

## Vitis 增量编译

项目阶段由 `fpga-project.toml` 声明，跨仓库依赖由 `fpga-workspace.toml` 连接。工具安装路径和串口配置保存在仓库外的 FPGAFlow 本地配置中。常用命令与 GUI 流程见[构建和部署](build-and-test.md)。

修改应用源码后运行：

```sh
fpga-flow build --project fpga-project.toml --stage app --with-deps
```

需要更新启动镜像时运行：

```sh
fpga-flow build --project fpga-project.toml --stage boot --with-deps
```

`--with-deps` 会核验前置产物。硬件与 platform 输入未变时，Flow 复用已成功且哈希匹配的产物。应用使用固定的 CMake/Ninja 工作区，保留对象文件与依赖记录。普通 C/C++ 源文件变化只重编受影响的编译单元，然后链接 ELF。共享头文件、编译选项或工具链变化可能触发更多文件重编。

可复用工作区位于 `build/fpga-flow/cache/vitis-app/<key>/`，按 platform、工具链路径、应用模板和 domain 隔离。platform 缓存位于 `build/fpga-flow/cache/vitis-platform/<key>/`，按 XSA 内容、Vitis 版本、FatFs 配置脚本和 FreeRTOS heap 配置隔离。复制到新 run 的相同 XSA 不会仅因路径变化而强制新建 platform。

每次应用构建把 ELF、配置日志和编译日志复制到该 run 的 `work/vitis-result/`，再发布到该 run 的 `work/artifacts/`。后续增量构建不会覆盖历史交付副本。`backend/app.json` 记录实际编译单元数量、是否链接、耗时与增量工作区。

首次建立某个缓存需要完整编译。删除 `cache/` 后，下一次会重新建立缓存。日常修改源码时保留缓存，不使用清理命令。

## 状态与证据

```sh
fpga-flow status --project fpga-project.toml --stage app
fpga-flow history --project fpga-project.toml --stage app
fpga-flow watch --project fpga-project.toml --run-id RUN_ID --follow
```

Flow 的输入锁与短索引保存在仓库外。完整命令、输入哈希、输出哈希和执行结果保存在 `build/fpga-flow/runs/<run-id>/run.json`。应用增量缓存用于加速编译，验收与部署仍以对应 run 的产物和哈希为准。

## canonical IP 更新

EmbeddedVideoIP 的 RTL/XDC 在相邻 canonical 仓库修改。使用 workspace 完成验证、生成发布包、校验导入与消费构建。硬件 IP 和 PS 库共享版本，依赖锁保存 ZIP、canonical 源码及导入树哈希。

```sh
fpga-flow --workspace fpga-workspace.toml plan --json
fpga-flow --workspace fpga-workspace.toml run --allow-side-effects --allow-destructive
```

`--include-optional` 选择 GBA host/RTL 回归。`board-runtime` 运行 UART 时钟、HDMI、VDMA 和音频路由检查；`gameplay-audio-signal` 单独运行 Linux ALSA 音频采集，执行时设置 `FPGA_CAPTURE_FORMAT=alsa` 与 `FPGA_CAPTURE_INPUT`。Windows DirectShow 采集结果单独记录。运行档案保存在 `build/fpga-flow/workspace/runs/`，导入备份 `.fpga-flow-import-*` 留在本地并由 Git 忽略。

## 中文字体

菜单使用 Fusion Pixel Font 的 12、18 和 24 像素字库。字体来源与 SIL OFL 1.1 位于 `src/ps/app/src/third-party/fonts/fusion-pixel-font/`，生成的 C 源码保留字体归属。准备 `fonttools` 和 `lv_font_conv` 后运行以下命令。

```sh
python scripts/maintenance/fonts/gen_lvgl_fusion_font.py --size 18 --lv-font-name ps_ui_font_fusion_18 --output src/ps/app/src/Ui/Assets/Fonts/ps_ui_font_fusion_18.c
python scripts/maintenance/fonts/gen_lvgl_fusion_font.py --size 24 --lv-font-name ps_ui_font_fusion_24 --output src/ps/app/src/Ui/Assets/Fonts/ps_ui_font_fusion_24.c
```

源字库完整字符集参与生成，C 文件随应用编译。调整字号时同步检查 LVGL 配置、菜单布局和链接内存。

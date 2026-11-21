# FPGAFlow 维护者构建

## Vitis 增量编译

项目只维护 `fpga-project.toml`。工具安装路径和串口配置保存在仓库外的 FPGAFlow 本地配置中。普通用户的 Vivado/Vitis GUI 流程见 [构建和部署](build-and-test.md)。

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

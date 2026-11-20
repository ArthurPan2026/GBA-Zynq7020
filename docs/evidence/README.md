# 验证证据

这里保存可读、可追踪、体积可控的验证结果。

## 文件规则

- 文件名使用小写短横线。
- 文件名包含日期或验证类别。
- 文本、JSON、TSV、RPT 和 UART 日志可以进入版本库。
- bit、XSA、ELF、BOOT.BIN、WAV、MKV、BMP 和原始 EDID 二进制进入 build/ 或外部归档。
- 每份证据记录命令、输入 commit、工具版本和运行 ID。
- 证据文件只记录观测值和判定。

## 分类

- timing/：时序摘要。
- drc/：DRC 摘要。
- qor/：资源和 QoR。
- rtl/：仿真结果。
- board/：UART、HDMI、QSPI 和板级诊断。

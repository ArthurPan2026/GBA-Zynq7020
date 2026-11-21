#!/usr/bin/env python3
"""Run the PS host C regression without invoking the legacy flow orchestrator."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = Path(os.environ.get("FPGA_FLOW_OUTPUT_DIR", str(ROOT / "build/fpga-flow")))
HOST_CFLAGS = ("-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic")
LVGL_VENDOR_REL = Path("src/ps/app/src/third-party/lvgl")
HOST_TESTS = [
    ("console-line-utf8", "tests/host/ps/test_console_line_utf8.c", ("src/ps/app/src/App/Src/ps_app_console_line.c",)),
    ("runtime-command-logic", "tests/host/ps/test_runtime_command_logic.c", ("src/ps/app/src/App/Src/ps_app_runtime_command_logic.c",)),
    ("xinput-parser", "tests/host/ps/test_xinput_parser.c", ("src/ps/app/src/Input/Src/ps_xinput_xbox360.c", "src/ps/app/src/Input/Drivers/ps_app_input_profile.c")),
    ("gba-regs-mailbox-timeout", "tests/host/ps/test_gba_regs_mailbox_timeout.c", ("src/ps/app/src/Gba/Src/ps_gba_regs.c",)),
    ("time-storage-save", "tests/host/ps/test_time_and_storage_txn.c", ("src/ps/app/src/Common/Src/ps_app_time_math.c", "src/ps/app/src/Storage/Src/ps_fatfs_txn.c", "src/ps/app/src/Save/Src/ps_app_save_logic.c")),
    ("input-driver-registry", "tests/host/ps/test_input_driver_registry.c", ("src/ps/app/src/Input/Drivers/ps_app_input_driver.c", "src/ps/app/src/Input/Src/ps_xinput_xbox360.c", "src/ps/app/src/Input/Drivers/ps_app_input_profile.c")),
    ("rom-load-progress", "tests/host/ps/test_rom_load_progress.c", ("src/ps/app/src/Common/Src/ps_app_rom_load_progress.c", "src/ps/app/src/Common/Src/ps_app_ui_launch_logic.c")),
    ("audio-route-logic", "tests/host/ps/test_audio_route_logic.c", ("src/ps/app/src/Common/Src/ps_app_audio_route_logic.c",)),
    ("hdmi-edid", "tests/host/ps/test_hdmi_edid.c", ("src/ps/app/src/Hdmi/Src/ps_app_edid.c",)),
    ("video-mode-logic", "tests/host/ps/test_video_mode_logic.c", ("src/ps/app/src/Video/Src/ps_app_video_mode_logic.c",)),
]
LVGL_SOURCES = tuple(
    path.relative_to(ROOT).as_posix()
    for path in sorted((ROOT / LVGL_VENDOR_REL / "src").rglob("*.c"))
)
HOST_TESTS.append((
    "lvgl96-runtime",
    "tests/host/ps/test_lvgl96_runtime.c",
    (*LVGL_SOURCES, "src/ps/app/src/Ui/Assets/Fonts/ps_ui_font_fusion_12.c"),
))
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
OUT = OUTPUT_DIR / "tests/host"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    include = [
        "-I", str(ROOT / "tests/host/ps/stubs"),
        "-I", str(ROOT / "src/ps/app/src"),
        "-I", str(ROOT / "src/generated/ps"),
        "-I", str(ROOT / LVGL_VENDOR_REL),
        "-I", str(ROOT / LVGL_VENDOR_REL / "include"),
    ]
    for name, test_rel, sources in HOST_TESTS:
        binary = OUT / name
        compile_log = OUT / f"{name}.compile.log"
        run_log = OUT / f"{name}.test.log"
        flags = ("-std=gnu11", "-w") if name == "lvgl96-runtime" else HOST_CFLAGS
        command = [
            "gcc", *flags, *include, str(ROOT / test_rel),
            *(str(ROOT / source) for source in sources),
            *([] if name != "lvgl96-runtime" else ["-lm"]),
            "-o", str(binary),
        ]
        compile = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
        compile_log.write_text((compile.stdout or "") + (compile.stderr or ""), encoding="utf-8")
        if compile.returncode:
            print(f"FPGA_FLOW_HOST_FAILED: compile {name}", file=sys.stderr)
            return compile.returncode or 2
        run = subprocess.run([str(binary)], cwd=ROOT, text=True, capture_output=True, check=False)
        run_log.write_text((run.stdout or "") + (run.stderr or ""), encoding="utf-8")
        if run.returncode:
            print(f"FPGA_FLOW_HOST_FAILED: test {name}", file=sys.stderr)
            return run.returncode or 2
        print(f"[HOST-PASS] {name}")
    (OUT / "unittest.log").write_text(
        f"HOST_TESTS_PASS count={len(HOST_TESTS)}\n",
        encoding="utf-8",
    )
    print(f"FPGA_FLOW_HOST_PASS count={len(HOST_TESTS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

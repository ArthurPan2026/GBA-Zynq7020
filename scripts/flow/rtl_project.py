#!/usr/bin/env python3
"""Create the isolated Vivado project used by RTL regression stages."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "build/vivado/rtl/gba-zynq7020-rtl.xpr"
BD = ROOT / "build/vivado/rtl/gba-zynq7020-rtl.srcs/sources_1/bd/zynq_gba_system/zynq_gba_system.bd"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vivado", default=os.environ.get("VIVADO_BIN", "/tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado"))
    args = parser.parse_args()
    contract = subprocess.run([sys.executable, str(ROOT / "scripts/flow/generate_hw_contract.py"), "--check"],
                              cwd=ROOT, text=True, capture_output=True, check=False)
    if contract.returncode:
        print(f"FPGA_FLOW_RTL_PROJECT_FAILED: stale PS/PL contract: {contract.stderr}", file=sys.stderr)
        return 2
    (ROOT / "build/vivado/rtl").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        "ZYNQ_GBA_REPO_ROOT": str(ROOT),
        "ZYNQ_GBA_OUT_DIR": str(ROOT / "build/vivado/rtl"),
        "ZYNQ_GBA_PYTHON": sys.executable,
        "EMBEDDED_VIDEO_IP_REPO": os.environ.get("EMBEDDED_VIDEO_IP_REPO", str(ROOT.parent / "EmbeddedVideoIP")),
    })
    command = [str(Path(args.vivado)), "-mode", "batch", "-source", str(ROOT / "scripts/vivado/rebuild_project.tcl")]
    result = subprocess.run(command, cwd=ROOT / "build/vivado/rtl", env=env, text=True, check=False)
    if result.returncode:
        return result.returncode
    if not PROJECT.is_file() or not BD.is_file():
        print("FPGA_FLOW_RTL_PROJECT_FAILED: required project outputs are missing", file=sys.stderr)
        return 2
    print("FPGA_FLOW_RTL_PROJECT_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Compatibility entry point; the canonical build/cache policy is tools/flow.py."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    vitis_root = Path(os.environ.get(
        "VITIS_ROOT", "/tools/AMDDesignTools/2025.2.1/Vitis"
    )).expanduser()
    vitis_bin = Path(os.environ.get("VITIS_BIN", str(vitis_root / "bin" / "vitis")))
    command = [
        sys.executable, str(repo_root / "tools" / "flow.py"),
        "--vitis", str(vitis_bin), "build", "--stage", "platform",
    ]
    return subprocess.run(command, cwd=repo_root, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())

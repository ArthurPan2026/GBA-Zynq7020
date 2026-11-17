#!/usr/bin/env python3
"""GBA-owned adapter that exports exact build artifacts for generic FPGAFlow."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Mapping

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "out/flow/manifest.json"
ARTIFACT_DIR = ROOT / "out/fpga-flow/artifacts"
VIVADO_BITSTREAM = Path("out/vivado/Zynq-GBA_MisTer-Vivado.runs/impl_1/zynq_gba_system_wrapper.bit")
VIVADO_XSA = Path("out/vivado/zynq_gba_system_wrapper.xsa")

STAGE_ARTIFACTS: dict[str, dict[str, str]] = {
    "hardware": {
        str(VIVADO_BITSTREAM): "bitstream.bit",
        str(VIVADO_XSA): "hardware.xsa",
    },
    "platform": {
        "ps7_init_tcl": "ps7_init.tcl",
        "fsbl_elf": "fsbl.elf",
        "xpfm": "platform.xpfm",
    },
    "app": {"app_elf": "app.elf"},
    "boot": {"boot_bin": "BOOT.BIN"},
}


def _backend_outputs(stage: str) -> Mapping[str, str]:
    if stage == "hardware":
        return {key: key for key in STAGE_ARTIFACTS[stage]}
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        record = manifest["runs"][stage]
        outputs = record["outputs"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise RuntimeError(f"cannot resolve successful GBA {stage} outputs from {MANIFEST}") from exc
    if not isinstance(outputs, dict) or not outputs:
        raise RuntimeError(f"GBA {stage} manifest has no outputs")
    if record.get("build_status") != "SUCCESS":
        raise RuntimeError(f"GBA {stage} build status is {record.get('build_status')!r}")
    return outputs


def _copy_atomic(source: Path, destination: Path) -> None:
    root = ROOT.resolve(strict=True)
    if source.is_symlink():
        raise RuntimeError(f"refusing symlink artifact: {source}")
    source = source.resolve(strict=True)
    try:
        source.relative_to(root)
    except ValueError as exc:
        raise RuntimeError(f"artifact escapes project root: {source}") from exc
    if not source.is_file():
        raise RuntimeError(f"artifact is not a file: {source}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    resolved_parent = destination.parent.resolve(strict=True)
    try:
        resolved_parent.relative_to(root)
    except ValueError as exc:
        raise RuntimeError(f"artifact destination escapes project root: {destination}") from exc
    if destination.is_symlink():
        raise RuntimeError(f"refusing symlink destination: {destination}")

    fd, temp_name = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".tmp",
                                     dir=destination.parent)
    os.close(fd)
    temp = Path(temp_name)
    try:
        shutil.copyfile(source, temp)
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)


def publish(stage: str) -> None:
    source_map = _backend_outputs(stage)
    for source_key, public_name in STAGE_ARTIFACTS[stage].items():
        relative = source_map.get(source_key)
        if not isinstance(relative, str) or not relative:
            raise RuntimeError(f"GBA {stage} manifest is missing output {source_key!r}")
        source = ROOT / relative
        destination = ARTIFACT_DIR / public_name
        _copy_atomic(source, destination)
        print(f"FPGA_FLOW_ARTIFACT stage={stage} name={public_name} source={relative}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=tuple(STAGE_ARTIFACTS), required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--vitis", required=True)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be between 1 and 8")

    command = [
        sys.executable, "tools/flow.py", "--vitis", args.vitis,
        "build", "--stage", args.stage, "--jobs", str(args.jobs),
    ]
    result = subprocess.run(command, cwd=ROOT, check=False)
    if result.returncode != 0:
        return result.returncode
    try:
        publish(args.stage)
    except Exception as exc:
        print(f"FPGA_FLOW_ARTIFACT_EXPORT_FAILED: {type(exc).__name__}: {exc}",
              file=sys.stderr, flush=True)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

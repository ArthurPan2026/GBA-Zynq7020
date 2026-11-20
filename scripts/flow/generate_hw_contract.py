#!/usr/bin/env python3
"""Generate checked-in PS and RTL constants from the PS/PL contract JSON."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "config" / "ps-pl-contract.json"
OUT_C = ROOT / "src" / "generated" / "ps" / "ps_pl_contract_generated.h"
OUT_SV = ROOT / "src" / "generated" / "rtl" / "ps_pl_contract_generated.vh"

def load_spec() -> tuple[dict, int]:
    data = json.loads(SPEC.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("unsupported contract schema_version")
    offsets = set()
    for reg in data["registers"]:
        offset = int(reg["offset"], 0)
        if offset < 0x200 or offset >= 0x300 or offset & 3 or offset in offsets:
            raise ValueError(f"invalid/duplicate register offset: {reg}")
        offsets.add(offset)
    canonical = json.dumps(data, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return data, int(hashlib.sha256(canonical).hexdigest()[:8], 16)

def render(data: dict, build_id: int) -> tuple[str, str]:
    lines = ["#ifndef PS_PL_CONTRACT_GENERATED_H", "#define PS_PL_CONTRACT_GENERATED_H", "", "/* Generated from config/ps-pl-contract.json. Do not edit. */",
             f"#define PS_PL_ABI_MAGIC {int(data['abi_magic'], 0)}U",
             f"#define PS_PL_ABI_VERSION {int(data['abi_version'], 0)}U",
             f"#define PS_PL_ABI_BUILD_ID 0x{build_id:08X}U", ""]
    for reg in data["registers"]:
        lines.append(f"#define GBA_REG_{reg['name']} {int(reg['offset'], 0)}U")
    lines.append("")
    for name, bit in data["capabilities"].items():
        lines.append(f"#define GBA_ABI_CAP_{name} (1U << {bit}U)")
    for name, value in data["commands"].items():
        lines.append(f"#define GBA_MEM_CMD_{name} {value}U")
    for name, bit in data["memory_status_bits"].items():
        lines.append(f"#define GBA_MEM_STATUS_{name} (1U << {bit}U)")
    for name, bit in data["frame_status_bits"].items():
        lines.append(f"#define GBA_FRAME_STATUS_{name} (1U << {bit}U)")
    for name, value in data["save_kinds"].items():
        lines.append(f"#define GBA_SAVE_KIND_{name} {value}U")
    for name, bit in data["save_status_bits"].items():
        lines.append(f"#define GBA_SAVE_STATUS_{name} (1U << {bit}U)")
    lines.extend(["", "#endif", ""])
    c_text = "\n".join(lines)

    sv = ["`ifndef PS_PL_CONTRACT_GENERATED_VH", "`define PS_PL_CONTRACT_GENERATED_VH", "", "// Generated from config/ps-pl-contract.json. Do not edit.",
          f"`define PS_PL_ABI_MAGIC 32'h{int(data['abi_magic'], 0):08X}",
          f"`define PS_PL_ABI_VERSION 32'h{int(data['abi_version'], 0):08X}",
          f"`define PS_PL_ABI_BUILD_ID 32'h{build_id:08X}"]
    for reg in data["registers"]:
        sv.append(f"`define PS_PL_REG_{reg['name']} 12'h{int(reg['offset'], 0):03X}")
    for name, bit in data["capabilities"].items():
        sv.append(f"`define PS_PL_ABI_CAP_{name} (32'h1 << {bit})")
    for name, value in data["commands"].items():
        sv.append(f"`define PS_PL_MEM_CMD_{name} 32'h{value:08X}")
    for name, bit in data["memory_status_bits"].items():
        sv.append(f"`define PS_PL_MEM_STATUS_{name} (32'h1 << {bit})")
    for name, bit in data["frame_status_bits"].items():
        sv.append(f"`define PS_PL_FRAME_STATUS_{name} (32'h1 << {bit})")
    for name, value in data["save_kinds"].items():
        sv.append(f"`define PS_PL_SAVE_KIND_{name} 2'd{value}")
    for name, bit in data["save_status_bits"].items():
        sv.append(f"`define PS_PL_SAVE_STATUS_{name} (32'h1 << {bit})")
    sv.extend(["", "`endif", ""])
    return c_text, "\n".join(sv)

def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        data, build_id = load_spec()
        expected = ((OUT_C, render(data, build_id)[0]), (OUT_SV, render(data, build_id)[1]))
    except Exception as exc:
        print(f"contract error: {exc}", file=sys.stderr)
        return 2
    if args.write:
        for path, text in expected:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
        print(f"generated contract headers; build id 0x{build_id:08X}")
        return 0
    mismatches = [str(path.relative_to(ROOT)) for path, text in expected if not path.is_file() or path.read_text(encoding="utf-8") != text]
    if mismatches:
        print("generated contract headers are stale: " + ", ".join(mismatches), file=sys.stderr)
        return 1
    print(f"contract headers valid; build id 0x{build_id:08X}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

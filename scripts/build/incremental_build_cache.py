#!/usr/bin/env python3
"""Content-addressed artifact cache for the GBA consumer's Vivado build."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
SOURCE_SUFFIXES = {
    ".bd", ".coe", ".mem", ".sv", ".tcl", ".v", ".vhd", ".vh", ".xdc", ".xci", ".xml",
}
IGNORED_DIRS = {
    ".git", ".Xil", ".build_cache", ".build_hashes", ".cache", "build", "out",
    "xsim.dir", "ip_user_files", "*.gen", "*.runs", "*.cache", "*.srcs", "*.sim", "*.hw",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    content = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _files_under(root: Path, directory: Path) -> dict[str, str]:
    if not directory.is_dir():
        return {}
    result: dict[str, str] = {}
    for current, directories, names in os.walk(directory, followlinks=False):
        current_path = Path(current)
        directories[:] = sorted(
            name for name in directories
            if name not in IGNORED_DIRS
            and not name.endswith((".gen", ".runs", ".cache", ".srcs", ".sim", ".hw"))
            and not (current_path / name).is_symlink()
        )
        for name in sorted(names):
            path = current_path / name
            if path.suffix.lower() not in SOURCE_SUFFIXES or path.is_symlink():
                continue
            result[path.relative_to(root).as_posix()] = sha256_file(path)
    return result


def collect_inputs(root: Path, dependency_root: Path, *, include_rtl: bool) -> dict[str, str]:
    root = root.resolve()
    dependency_root = dependency_root.resolve()
    inputs: dict[str, str] = {}
    for directory in (
        root / "src/bd",
        root / "src/constraints",
        root / "external/digilent-vivado-library",
    ):
        inputs.update(_files_under(root, directory))
    digilent_commit = root / "external/digilent-vivado-library/UPSTREAM_COMMIT"
    if digilent_commit.is_file():
        inputs[digilent_commit.relative_to(root).as_posix()] = sha256_file(digilent_commit)
    if include_rtl:
        inputs.update(_files_under(root, root / "src/rtl"))

    explicit = (
        root / "scripts/build/build_bitstream.tcl",
        root / "scripts/build/bd_ip_maintenance.tcl",
        root / "scripts/build/incremental_build_cache.py",
        root / "scripts/build/embedded_video_ip_consumer.tcl",
        root / "scripts/build/embedded_video_ip.lock.json",
    )
    for path in explicit:
        if path.is_file() and not path.is_symlink():
            inputs[path.relative_to(root).as_posix()] = sha256_file(path)

    version_file = dependency_root / "VERSION"
    component = dependency_root / "ip_repo/panfpga/video_pipeline/component.xml"
    if version_file.is_file():
        inputs["dependency/EmbeddedVideoIP/VERSION"] = sha256_file(version_file)
    if component.is_file():
        inputs["dependency/EmbeddedVideoIP/component.xml"] = sha256_file(component)
    if include_rtl:
        inputs.update({
            f"dependency/EmbeddedVideoIP/{relative}": digest
            for relative, digest in _files_under(
                dependency_root, dependency_root / "ip_repo/panfpga/video_pipeline"
            ).items()
        })
    return dict(sorted(inputs.items()))


def fingerprints(root: Path, dependency_root: Path, tool_version: str, part: str,
                 synth_strategy: str, impl_strategy: str) -> tuple[str, str]:
    build = {
        "schema_version": SCHEMA_VERSION,
        "tool_version": tool_version,
        "part": part,
        "synth_strategy": synth_strategy,
        "impl_strategy": impl_strategy,
        "top": "zynq_gba_system_wrapper",
        "board_part": "digilentinc.com:zybo-z7-20:part0:1.2",
    }
    full_hash = sha256_json({
        **build,
        "inputs": collect_inputs(root, dependency_root, include_rtl=True),
    })
    identity_hash = sha256_json({
        **build,
        "inputs": collect_inputs(root, dependency_root, include_rtl=False),
    })
    return full_hash, identity_hash


def _load_record(root: Path) -> dict[str, Any] | None:
    path = root / ".build_cache/last_success.json"
    if not path.is_file():
        return None
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return record if isinstance(record, dict) else None


def _checked_output(root: Path, entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    relative, expected = entry.get("path"), entry.get("sha256")
    if not isinstance(relative, str) or not isinstance(expected, str):
        return False
    path = (root / relative).resolve()
    if root.resolve() not in path.parents or not path.is_file() or path.is_symlink():
        return False
    return sha256_file(path) == expected


def prepare(root: Path, dependency_root: Path, tool_version: str, part: str,
            synth_strategy: str, impl_strategy: str) -> tuple[str, str, bool, str]:
    full_hash, identity_hash = fingerprints(
        root, dependency_root, tool_version, part, synth_strategy, impl_strategy
    )
    record = _load_record(root)
    if record is None or record.get("schema_version") != SCHEMA_VERSION:
        return full_hash, identity_hash, False, ""

    current = (
        record.get("input_sha256") == full_hash
        and record.get("outputs_passed") is True
        and _checked_output(root, record.get("bitstream"))
        and _checked_output(root, record.get("xsa"))
        and _checked_output(root, record.get("routed_dcp"))
    )

    reference = ""
    if (record.get("identity_sha256") == identity_hash and
            record.get("qor_passed") is True and
            _checked_output(root, record.get("routed_dcp"))):
        reference = str((root / record["routed_dcp"]["path"]).resolve())
    return full_hash, identity_hash, current, reference


def timing_metrics(report_path: Path) -> dict[str, float]:
    text = report_path.read_text(encoding="utf-8", errors="replace")
    start = text.find("Design Timing Summary")
    if start < 0:
        raise ValueError("missing Design Timing Summary")
    number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
    row_pattern = re.compile(
        rf"(?m)^\s*({number})\s+({number})\s+\d+\s+\d+\s+"
        rf"({number})\s+({number})\s+\d+\s+\d+\s+"
        rf"({number})\s+({number})\s+\d+\s+\d+\s*$"
    )
    match = row_pattern.search(text[start:])
    if match is None:
        raise ValueError("missing min_max WNS/TNS/WHS/THS summary row")
    wns, tns, whs, ths = (float(value) for value in match.groups()[:4])
    return {"wns_ns": wns, "tns_ns": tns, "whs_ns": whs, "ths_ns": ths}


def gate(report_path: Path, drc_errors: int, critical_warnings: int) -> tuple[bool, dict[str, float]]:
    timing = timing_metrics(report_path)
    passed = (
        timing["wns_ns"] >= 0.0
        and abs(timing["tns_ns"]) < 0.0005
        and timing["whs_ns"] >= 0.0
        and abs(timing["ths_ns"]) < 0.0005
        and drc_errors == 0
        and critical_warnings == 0
    )
    return passed, timing


def record_success(root: Path, dependency_root: Path, tool_version: str, part: str,
                   synth_strategy: str, impl_strategy: str, routed_dcp: Path,
                   bitstream: Path, xsa: Path, timing_report: Path,
                   drc_errors: int, critical_warnings: int) -> dict[str, Any]:
    passed, timing = gate(timing_report, drc_errors, critical_warnings)
    if not passed:
        raise ValueError("QoR/DRC acceptance gate failed; refusing to update last-success cache")

    root = root.resolve()
    cache = root / ".build_cache"
    cache.mkdir(parents=True, exist_ok=True)
    cache_dcp = cache / "last_success_routed.dcp"
    temporary_dcp = cache / "last_success_routed.dcp.tmp"
    shutil.copy2(routed_dcp, temporary_dcp)
    os.replace(temporary_dcp, cache_dcp)

    full_hash, identity_hash = fingerprints(
        root, dependency_root, tool_version, part, synth_strategy, impl_strategy
    )

    def output_entry(path: Path) -> dict[str, str]:
        resolved = path.resolve()
        if root not in resolved.parents or not resolved.is_file():
            raise ValueError(f"build output is outside the project or missing: {resolved}")
        return {"path": resolved.relative_to(root).as_posix(), "sha256": sha256_file(resolved)}

    record = {
        "schema_version": SCHEMA_VERSION,
        "input_sha256": full_hash,
        "identity_sha256": identity_hash,
        "tool_version": tool_version,
        "part": part,
        "synth_strategy": synth_strategy,
        "impl_strategy": impl_strategy,
        "qor": timing,
        "drc_errors": drc_errors,
        "critical_warnings": critical_warnings,
        "qor_passed": True,
        "outputs_passed": True,
        "routed_dcp": output_entry(cache_dcp),
        "bitstream": output_entry(bitstream),
        "xsa": output_entry(xsa),
    }
    manifest = cache / "last_success.json"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache,
                                     prefix="last_success.", suffix=".tmp", delete=False) as stream:
        temporary_manifest = Path(stream.name)
        json.dump(record, stream, sort_keys=True, indent=2)
        stream.write("\n")
    os.replace(temporary_manifest, manifest)
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument("--dependency-root", type=Path, required=True)
    prepare_parser.add_argument("--tool-version", required=True)
    prepare_parser.add_argument("--part", required=True)
    prepare_parser.add_argument("--synth-strategy", required=True)
    prepare_parser.add_argument("--impl-strategy", required=True)

    gate_parser = sub.add_parser("gate")
    gate_parser.add_argument("--timing-report", type=Path, required=True)
    gate_parser.add_argument("--drc-errors", type=int, required=True)
    gate_parser.add_argument("--critical-warnings", type=int, required=True)

    record_parser = sub.add_parser("record")
    record_parser.add_argument("--root", type=Path, required=True)
    record_parser.add_argument("--dependency-root", type=Path, required=True)
    record_parser.add_argument("--tool-version", required=True)
    record_parser.add_argument("--part", required=True)
    record_parser.add_argument("--synth-strategy", required=True)
    record_parser.add_argument("--impl-strategy", required=True)
    record_parser.add_argument("--routed-dcp", type=Path, required=True)
    record_parser.add_argument("--bitstream", type=Path, required=True)
    record_parser.add_argument("--xsa", type=Path, required=True)
    record_parser.add_argument("--timing-report", type=Path, required=True)
    record_parser.add_argument("--drc-errors", type=int, required=True)
    record_parser.add_argument("--critical-warnings", type=int, required=True)
    args = parser.parse_args()

    try:
        if args.command == "prepare":
            full_hash, identity_hash, current, reference = prepare(
                args.root, args.dependency_root, args.tool_version, args.part,
                args.synth_strategy, args.impl_strategy,
            )
            print("\t".join((full_hash, identity_hash, "1" if current else "0", reference or "-")))
        elif args.command == "gate":
            passed, timing = gate(args.timing_report, args.drc_errors, args.critical_warnings)
            print("\t".join((
                "1" if passed else "0",
                str(timing["wns_ns"]), str(timing["tns_ns"]),
                str(timing["whs_ns"]), str(timing["ths_ns"]),
                str(args.drc_errors), str(args.critical_warnings),
            )))
        else:
            record = record_success(
                args.root, args.dependency_root, args.tool_version, args.part,
                args.synth_strategy, args.impl_strategy, args.routed_dcp,
                args.bitstream, args.xsa, args.timing_report,
                args.drc_errors, args.critical_warnings,
            )
            print(f"GBA_BUILD_CACHE_RECORD_PASS: {record['input_sha256']}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[GBA-BUILD-CACHE] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Parse Vivado timing reports and enforce QoR gates.

Persistent build inputs, artifacts, and last-good DCP metadata live in
build/flow/manifest.json. This helper intentionally has no independent cache.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    gate_parser = sub.add_parser("gate")
    gate_parser.add_argument("--timing-report", type=Path, required=True)
    gate_parser.add_argument("--drc-errors", type=int, required=True)
    gate_parser.add_argument("--critical-warnings", type=int, required=True)
    args = parser.parse_args()
    try:
        passed, timing = gate(args.timing_report, args.drc_errors, args.critical_warnings)
        print("\t".join((
            "1" if passed else "0",
            str(timing["wns_ns"]), str(timing["tns_ns"]),
            str(timing["whs_ns"]), str(timing["ths_ns"]),
            str(args.drc_errors), str(args.critical_warnings),
        )))
        return 0 if passed else 2
    except (OSError, ValueError) as exc:
        print(f"[GBA-QOR-GATE] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

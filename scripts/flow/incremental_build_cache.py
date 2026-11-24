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


def gate(report_path: Path, drc_errors: int, critical_warnings: int,
         pre_route: bool = False) -> tuple[bool, dict[str, float]]:
    timing = timing_metrics(report_path)
    setup_pass = pre_route or (
        timing["wns_ns"] > 0.0 and abs(timing["tns_ns"]) < 0.0005
    )
    hold_pass = pre_route or (
        timing["whs_ns"] > 0.0 and abs(timing["ths_ns"]) < 0.0005
    )
    passed = (
        setup_pass
        and hold_pass
        and drc_errors == 0
        and critical_warnings == 0
    )
    return passed, timing


def pulse_gate(path: Path, experiment: bool) -> tuple[bool, list[str]]:
    content = path.read_text(encoding="utf-8", errors="replace")
    if "Pulse Width" not in content and "pulse width" not in content:
        raise ValueError("missing pulse width report header")
    clock = ""
    violations = []
    unexpected = []
    row = re.compile(r"^\s*(Min Period|Max Period|Low Pulse Width|High Pulse Width|Max Skew)\s+\S+\s+(\S+)\s+\S+\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+\S+\s+(\S+)")
    for line in content.splitlines():
        if line.strip().startswith("Clock Name:"):
            clock = line.split(":", 1)[1].strip()
        match = row.match(line)
        if match is None or float(match[5]) >= 0:
            continue
        violations.append(clock + " " + line.strip())
        expected = (experiment and clock == "evip_1080p60_serial"
                    and match[1] == "Min Period" and match[2] == "OSERDESE2/CLK"
                    and "/hdmi_tx/" in match[6] and match[6].endswith("/CLK"))
        if not expected:
            unexpected.append(line)
    return not unexpected, violations


def bus_skew_gate(path: Path) -> tuple[bool, list[float]]:
    content = path.read_text(encoding="utf-8", errors="replace")
    if "Bus Skew Report Summary" not in content:
        raise ValueError("missing bus skew report summary")
    number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
    met = [float(value) for value in re.findall(rf"Slack \(MET\)\s*:\s*({number})ns", content)]
    violated = re.findall(rf"Slack \(VIOLATED\)\s*:\s*({number})ns", content)
    if not met and not violated:
        raise ValueError("bus skew report contains no checked paths")
    return not violated, met


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    gate_parser = sub.add_parser("gate")
    gate_parser.add_argument("--timing-report", type=Path, required=True)
    gate_parser.add_argument("--drc-errors", type=int, required=True)
    gate_parser.add_argument("--critical-warnings", type=int, required=True)
    gate_parser.add_argument("--pulse-report", type=Path, required=True)
    gate_parser.add_argument("--bus-skew-report", type=Path, required=True)
    gate_parser.add_argument("--experiment-1080p60", action="store_true")
    gate_parser.add_argument("--pre-route", action="store_true",
                             help="screen reports and DRC before timing-driven routing; final timing/skew remain mandatory")
    args = parser.parse_args()
    try:
        passed, timing = gate(args.timing_report, args.drc_errors, args.critical_warnings,
                              pre_route=args.pre_route)
        pulse_ok, pulse_violations = pulse_gate(args.pulse_report, args.experiment_1080p60)
        bus_skew_ok, bus_skew_slack = bus_skew_gate(args.bus_skew_report)
        passed = passed and pulse_ok and (args.pre_route or bus_skew_ok)
        record = args.pulse_report.with_name("experiment_1080p60.json")
        import json
        record.write_text(json.dumps({"experiment_1080p60": args.experiment_1080p60,
            "pre_route": args.pre_route, "ordinary_timing": timing,
            "pulse_violations": pulse_violations,
            "pulse_gate_passed": pulse_ok, "bus_skew_slacks_ns": bus_skew_slack,
            "bus_skew_gate_passed": bus_skew_ok, "accepted": passed}, indent=2) + "\n")
        print("\t".join((
            "1" if passed else "0",
            str(timing["wns_ns"]), str(timing["tns_ns"]),
            str(timing["whs_ns"]), str(timing["ths_ns"]),
            str(args.drc_errors), str(args.critical_warnings),
        )))
        return 0  # Tcl reads the explicit passed field and retains failed metrics.
    except (OSError, ValueError) as exc:
        print(f"[GBA-QOR-GATE] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

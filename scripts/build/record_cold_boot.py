#!/usr/bin/env python3
"""Validate and record explicit QSPI cold-boot evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="out/current/bundle.json")
    parser.add_argument("--evidence", required=True, help="JSON produced by the board cold-boot procedure")
    parser.add_argument("--output", default="out/board/speaker_cold_boot.json")
    args = parser.parse_args()
    bundle_path = ROOT / args.bundle
    evidence_path = ROOT / args.evidence
    if not bundle_path.is_file() or not evidence_path.is_file():
        print("SPEAKER_COLD_BOOT_FAILED: bundle and evidence JSON are required", file=sys.stderr)
        return 2
    try:
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"SPEAKER_COLD_BOOT_FAILED: invalid JSON: {exc}", file=sys.stderr)
        return 2
    required = ("qspi_programmed", "cold_boot_observed", "runtime_health", "speaker_signal")
    missing = [key for key in required if evidence.get(key) is not True]
    if missing:
        print(f"SPEAKER_COLD_BOOT_FAILED: missing positive evidence: {', '.join(missing)}", file=sys.stderr)
        return 2
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "passed",
        "bundle_id": bundle.get("bundle_id"),
        "bundle_sha256": sha256(bundle_path),
        "evidence_source": evidence_path.relative_to(ROOT).as_posix(),
        "evidence": evidence,
        "cold_boot_verified": True,
    }
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("SPEAKER_COLD_BOOT_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

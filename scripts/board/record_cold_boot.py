#!/usr/bin/env python3
"""Bind a manual cold-boot and listening attestation to recorded board checks."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def _load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def _time(value: object, label: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"missing timestamp: {label}")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"invalid timestamp: {label}") from exc
    if result.tzinfo is None:
        raise ValueError(f"timestamp must include a timezone: {label}")
    return result.astimezone(timezone.utc)


def _run(root: Path, run_id: object, stage: str) -> dict:
    if not isinstance(run_id, str) or not _RUN_ID.fullmatch(run_id) or run_id in {".", ".."}:
        raise ValueError(f"invalid {stage} run identifier")
    path = root / "build/fpga-flow/runs" / run_id / "run.json"
    if path.is_symlink():
        raise ValueError(f"linked run record: {path}")
    result = _load(path)
    if result.get("run_id") != run_id or result.get("stage") != stage or result.get("status") != "succeeded":
        raise ValueError(f"{stage} run did not succeed: {run_id}")
    return result


def _evidence_file(root: Path, record: dict, relative: str) -> Path:
    hashes = record.get("evidence")
    expected = hashes.get(relative) if isinstance(hashes, dict) else None
    path = root / relative
    if not isinstance(expected, str) or not path.is_file() or path.is_symlink():
        raise ValueError(f"run evidence is missing: {relative}")
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError(f"run evidence hash does not match: {relative}")
    return path


def verify(root: Path, bundle: dict, evidence: dict) -> dict:
    """Combine recorded QSPI/health results with explicitly manual observations."""
    bundle_id = bundle.get("bundle_id")
    if not isinstance(bundle_id, str) or evidence.get("bundle_id") != bundle_id:
        raise ValueError("attestation does not identify the current bundle")
    if not isinstance(evidence.get("operator"), str) or not evidence["operator"].strip():
        raise ValueError("attestation must identify its operator")
    if evidence.get("cold_boot_observed") is not True or evidence.get("speaker_signal") is not True:
        raise ValueError("cold boot and speaker observations must both be confirmed")
    verification = bundle.get("verification")
    pointers = bundle.get("verification_evidence")
    if not isinstance(verification, dict) or not isinstance(pointers, dict):
        raise ValueError("bundle has no QSPI verification evidence")
    if verification.get("qspi_programmed") is not True or verification.get("qspi_readback_verified") is not True:
        raise ValueError("the current bundle has not passed QSPI readback")
    qspi_id = pointers.get("qspi_readback_verified")
    qspi = _run(root, qspi_id, "deploy_qspi_release")
    if "-verify" not in qspi.get("command", []):
        raise ValueError("QSPI run does not record the readback option")
    selection = _load(_evidence_file(root, qspi, f"build/fpga-flow/runs/{qspi_id}/bundle-selection.json"))
    if selection.get("bundle_id") != bundle_id:
        raise ValueError("QSPI run selected a different bundle")
    manifest = _load(root / "build/fpga-flow/manifest.json")
    summary = manifest.get("stages", {}).get("runtime_health", {})
    if not isinstance(summary, dict) or summary.get("status") != "succeeded":
        raise ValueError("the latest runtime health check did not pass")
    health_id = summary.get("run_id")
    health = _run(root, health_id, "runtime_health")
    _evidence_file(root, health, f"build/fpga-flow/runs/{health_id}/stdout.log")
    programmed = _time(qspi.get("completed_at_utc"), "QSPI completion")
    booted = _time(evidence.get("power_cycle_at_utc"), "cold boot")
    health_started = _time(health.get("started_at_utc"), "runtime health start")
    if not programmed <= booted <= health_started <= datetime.now(timezone.utc):
        raise ValueError("cold boot must occur after QSPI programming and before the runtime check")
    return {"status": "passed", "bundle_id": bundle_id, "qspi_run_id": qspi_id,
            "runtime_health_run_id": health_id, "cold_boot_verified": True,
            "scope": "operator-attested power cycle and speaker signal with recorded QSPI readback and runtime health",
            "attestation": evidence}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="build/current/bundle.json")
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--output", default="build/board/speaker_cold_boot.json")
    args = parser.parse_args()
    try:
        bundle_path = ROOT / args.bundle
        evidence_path = ROOT / args.evidence
        report = verify(ROOT, _load(bundle_path), _load(evidence_path))
        with evidence_path.open("rb") as stream:
            report["attestation_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
        report["attestation_source"] = evidence_path.relative_to(ROOT).as_posix()
        output = ROOT / args.output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"SPEAKER_COLD_BOOT_FAILED: {exc}", file=sys.stderr)
        return 2
    print("SPEAKER_COLD_BOOT_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

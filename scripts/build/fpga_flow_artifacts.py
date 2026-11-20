#!/usr/bin/env python3
"""Project-owned stage backends invoked by the generic FPGAFlow engine.

This module performs one concrete build stage and publishes only the artifacts
declared by fpga-flow.toml. Scheduling, caching, dependency checks and run
records stay in FPGAFlow.
"""
from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_DIR = ROOT / "out/fpga-flow/artifacts"
BACKEND_DIR = ROOT / "out/fpga-flow/backend"
VIVADO_BITSTREAM = ROOT / "out/vivado/Zynq-GBA_MisTer-Vivado.runs/impl_1/zynq_gba_system_wrapper.bit"
VIVADO_XSA = ROOT / "out/vivado/zynq_gba_system_wrapper.xsa"
STAGE_ARTIFACTS = {
    "hardware": {"bitstream": "bitstream.bit", "xsa": "hardware.xsa"},
    "platform": {"xpfm": "platform.xpfm", "fsbl_elf": "fsbl.elf", "ps7_init_tcl": "ps7_init.tcl"},
    "app": {"app_elf": "app.elf"},
    "boot": {"boot_bin": "BOOT.BIN"},
}


class BackendError(RuntimeError):
    pass


def _check_hw_contract() -> None:
    command = [sys.executable, str(ROOT / "tools/generate_hw_contract.py"), "--check"]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
    if result.returncode:
        raise BackendError(f"PS/PL contract validation failed: {result.stdout}{result.stderr}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_file(path: Path, label: str) -> Path:
    path = path.expanduser()
    if path.is_symlink():
        raise BackendError(f"{label} is a symlink: {path}")
    path = path.resolve()
    if not path.is_file() or path.stat().st_size == 0:
        raise BackendError(f"{label} is missing or empty: {path}")
    return path


def _copy_atomic(source: Path, destination: Path) -> None:
    source = _require_file(source, "source artifact")
    root = ROOT.resolve(strict=True)
    try:
        source.relative_to(root)
        destination.resolve(strict=False).relative_to(root)
    except ValueError as exc:
        raise BackendError(f"artifact path escapes project root: {source} -> {destination}") from exc
    if destination.is_symlink():
        raise BackendError(f"refusing symlink destination: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    shutil.copyfile(source, temporary)
    os.replace(temporary, destination)


def _write_backend_state(stage: str, result: Mapping[str, Any], published: Mapping[str, str]) -> None:
    BACKEND_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "stage": stage,
        "result": result,
        "published": dict(published),
    }
    (BACKEND_DIR / f"{stage}.json").write_text(
        json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def _run(command: list[str], stage: str, *, cwd: Path = ROOT, env: Mapping[str, str] | None = None) -> str:
    BACKEND_DIR.mkdir(parents=True, exist_ok=True)
    # FPGAFlow owns the process group and stage timeout. Stream Vivado output
    # so its run log and watch command remain useful while the tool is active.
    tail: deque[str] = deque(maxlen=200)
    markers: list[str] = []
    with (BACKEND_DIR / f"{stage}.log").open("w", encoding="utf-8") as log:
        proc = subprocess.Popen(command, cwd=cwd, env=dict(env) if env is not None else None,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace", bufsize=1)
        assert proc.stdout is not None
        for line in proc.stdout:
            log.write(line)
            log.flush()
            sys.stdout.write(line)
            sys.stdout.flush()
            tail.append(line)
            if line.startswith(("GBA_BUILD_BITSTREAM=", "GBA_BUILD_XSA=", "GBA_BUILD_ROUTED_DCP=")):
                markers.append(line)
        proc.stdout.close()
        returncode = proc.wait()
    output = "".join(markers + list(tail))
    if returncode:
        raise BackendError(
            f"{stage} command failed with exit code {returncode}: "
            + " ".join(command)
        )
    return output


def _publish(stage: str, sources: Mapping[str, Path]) -> dict[str, str]:
    published: dict[str, str] = {}
    for key, public_name in STAGE_ARTIFACTS[stage].items():
        source = _require_file(sources[key], f"{stage} {key}")
        destination = ARTIFACT_DIR / public_name
        _copy_atomic(source, destination)
        published[key] = destination.relative_to(ROOT).as_posix()
    return published


def _hardware(vivado: Path, jobs: int) -> dict[str, Any]:
    _check_hw_contract()
    env = os.environ.copy()
    env.update({
        "ZYNQ_GBA_REPO_ROOT": str(ROOT),
        "ZYNQ_GBA_OUT_DIR": str(ROOT / "out/vivado"),
        "ZYNQ_GBA_PYTHON": sys.executable,
        "EMBEDDED_VIDEO_IP_REPO": os.environ.get(
            "EMBEDDED_VIDEO_IP_REPO", str(ROOT.parent / "EmbeddedVideoIP")
        ),
        "ZYNQ_GBA_REBUILD_PROJECT": "1",
        "ZYNQ_GBA_INCREMENTAL_DCP": "",
        "ZYNQ_GBA_JOBS": str(max(1, min(8, jobs))),
    })
    output = _run(
        [str(vivado), "-mode", "batch", "-source", str(ROOT / "scripts/build/build_bitstream.tcl")],
        "hardware",
        env=env,
    )
    for marker in ("GBA_BUILD_BITSTREAM=", "GBA_BUILD_XSA=", "GBA_BUILD_ROUTED_DCP="):
        if marker not in output:
            raise BackendError(f"Vivado did not report {marker}; refusing to publish existing artifacts")
    gate = ROOT / "out/vivado/reports/qor_gate.tsv"
    values = dict(line.strip().split("=", 1) for line in gate.read_text(encoding="utf-8").splitlines() if "=" in line)
    try:
        gate_ok = (values.get("passed") == "1" and float(values["wns_ns"]) >= 0
                   and float(values["whs_ns"]) >= 0 and float(values["tns_ns"]) == 0
                   and float(values["ths_ns"]) == 0 and int(values["drc_errors"]) == 0
                   and int(values["critical_warnings"]) == 0)
    except (KeyError, ValueError) as exc:
        raise BackendError(f"invalid implementation QoR report: {gate}") from exc
    if not gate_ok:
        raise BackendError(f"implementation did not pass timing and DRC gates: {gate}")
    published = _publish("hardware", {"bitstream": VIVADO_BITSTREAM, "xsa": VIVADO_XSA})
    return {
        "build_status": "SUCCESS",
        "command_output_summary": output[-4000:],
        "source_artifacts": {
            "bitstream": VIVADO_BITSTREAM.relative_to(ROOT).as_posix(),
            "xsa": VIVADO_XSA.relative_to(ROOT).as_posix(),
        },
    } | {"published": published}


def _vitis_module():
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from tools import vitis_stages
    return vitis_stages


def _read_backend_state(stage: str) -> dict[str, Any]:
    path = BACKEND_DIR / f"{stage}.json"
    if not path.is_file():
        raise BackendError(f"backend state for {stage} is missing: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BackendError(f"backend state for {stage} is invalid: {path}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("result"), dict):
        raise BackendError(f"backend state for {stage} has invalid structure")
    return payload


def _artifact_from_state(state: Mapping[str, Any], key: str) -> Path:
    result = state.get("result")
    artifacts = result.get("artifacts") if isinstance(result, Mapping) else None
    item = artifacts.get(key) if isinstance(artifacts, Mapping) else None
    path = item.get("path") if isinstance(item, Mapping) else None
    if not isinstance(path, str):
        raise BackendError(f"backend state does not contain artifact {key!r}")
    return _require_file(Path(path), f"backend artifact {key}")


def _parse_app_yaml() -> tuple[str, str]:
    path = ROOT / "src/ps/app/src/app.yaml"
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and ":" in line:
            key, value = line.split(":", 1)
            values[key.strip()] = value.strip().strip("\"'")
    domain_path = values.get("domain_path", "").replace("\\", "/")
    domain = Path(domain_path).name
    if not domain.startswith("freertos_") or not values.get("template"):
        raise BackendError(f"invalid app.yaml: {path}")
    return values["template"], domain


def _platform(vitis: Path, jobs: int) -> dict[str, Any]:
    xsa = _require_file(
        ARTIFACT_DIR / "hardware.xsa", "published hardware XSA"
    )
    stages = _vitis_module()
    vitis_version = os.environ.get("FPGA_FLOW_VITIS_VERSION")
    if not vitis_version:
        raise BackendError("FPGA_FLOW_VITIS_VERSION is required for platform reuse")
    os.environ["VITIS_BUILD_JOBS"] = str(max(1, min(8, jobs)))
    try:
        result = stages.run_platform_stage(
            vitis,
            ROOT / "out/vitis",
            xsa,
            sha256_file(xsa)[:16],
            vitis_version=vitis_version,
        )
    finally:
        os.environ.pop("VITIS_BUILD_JOBS", None)
    if not isinstance(result, dict) or result.get("build_status") != "SUCCESS":
        raise BackendError("Vitis platform stage did not report SUCCESS")
    sources = {key: _artifact_from_result(result, key) for key in ("xpfm", "fsbl_elf", "ps7_init_tcl")}
    published = _publish("platform", sources)
    return {"build_status": "SUCCESS", "result": result, "published": published}


def _artifact_from_result(result: Mapping[str, Any], key: str) -> Path:
    artifacts = result.get("artifacts")
    item = artifacts.get(key) if isinstance(artifacts, Mapping) else None
    path = item.get("path") if isinstance(item, Mapping) else None
    expected = item.get("sha256") if isinstance(item, Mapping) else None
    if not isinstance(path, str) or not isinstance(expected, str):
        raise BackendError(f"stage result does not contain artifact {key!r}")
    source = _require_file(Path(path), f"stage result artifact {key}")
    try:
        source.relative_to(ROOT.resolve())
    except ValueError as exc:
        raise BackendError(f"stage result artifact escapes project root: {source}") from exc
    if sha256_file(source) != expected:
        raise BackendError(f"stage result artifact hash changed: {key}")
    return source


def _require_published_match(source: Path, filename: str) -> None:
    published = _require_file(ARTIFACT_DIR / filename, f"published {filename}")
    if sha256_file(source) != sha256_file(published):
        raise BackendError(f"backend artifact does not match published {filename}")


def _app(vitis: Path, jobs: int) -> dict[str, Any]:
    _check_hw_contract()
    platform = _read_backend_state("platform")
    xpfm = _artifact_from_result(platform["result"], "xpfm")
    _require_published_match(xpfm, "platform.xpfm")
    template, domain = _parse_app_yaml()
    stages = _vitis_module()
    os.environ["VITIS_BUILD_JOBS"] = str(max(1, min(8, jobs)))
    try:
        result = stages.run_app_stage(
            vitis,
            ROOT / "out/vitis",
            xpfm,
            ROOT / "src/ps/app/src",
            template,
            domain,
            sha256_file(xpfm)[:16],
        )
    finally:
        os.environ.pop("VITIS_BUILD_JOBS", None)
    if not isinstance(result, dict) or result.get("build_status") != "SUCCESS":
        raise BackendError("Vitis application stage did not report SUCCESS")
    published = _publish("app", {"app_elf": _artifact_from_result(result, "app_elf")})
    return {"build_status": "SUCCESS", "result": result, "published": published}


def _boot(vitis: Path, jobs: int) -> dict[str, Any]:
    del jobs
    platform = _read_backend_state("platform")
    app = _read_backend_state("app")
    fsbl = _artifact_from_result(platform["result"], "fsbl_elf")
    bitstream = _require_file(ARTIFACT_DIR / "bitstream.bit", "published bitstream")
    app_elf = _artifact_from_result(app["result"], "app_elf")
    _require_published_match(fsbl, "fsbl.elf")
    _require_published_match(app_elf, "app.elf")
    stages = _vitis_module()
    bootgen = vitis.parent / "bootgen"
    result = stages.run_boot_stage(
        bootgen,
        ROOT / "out/vitis" / f"boot-{sha256_file(app_elf)[:16]}",
        fsbl,
        bitstream,
        app_elf,
        sha256_file(app_elf)[:16],
    )
    if not isinstance(result, dict) or result.get("build_status") != "SUCCESS":
        raise BackendError("Bootgen stage did not report SUCCESS")
    published = _publish("boot", {"boot_bin": _artifact_from_result(result, "boot_bin")})
    return {"build_status": "SUCCESS", "result": result, "published": published}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=tuple(STAGE_ARTIFACTS), required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--vivado", type=Path, default=Path(
        os.environ.get("VIVADO_BIN", "/tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado")
    ))
    parser.add_argument("--vitis", type=Path, default=Path(
        os.environ.get("VITIS_BIN", "/tools/AMDDesignTools/2025.2.1/Vitis/bin/vitis")
    ))
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be between 1 and 8")
    try:
        if args.stage == "hardware":
            result = _hardware(args.vivado, args.jobs)
        elif args.stage == "platform":
            result = _platform(args.vitis, args.jobs)
        elif args.stage == "app":
            result = _app(args.vitis, args.jobs)
        else:
            result = _boot(args.vitis, args.jobs)
        _write_backend_state(args.stage, result.get("result", result), result.get("published", {}))
        print(f"FPGA_FLOW_ARTIFACT stage={args.stage} " + json.dumps(result.get("published", {}), sort_keys=True))
        return 0
    except Exception as exc:
        print(f"FPGA_FLOW_STAGE_FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run GBA RTL benches from fpga-project.toml with resumable bench records."""
from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.flow.rtl_manifest import RTLBench, RTLManifestError, benches_for_suite
OUTPUT_DIR = Path(os.environ.get("FPGA_FLOW_OUTPUT_DIR", str(ROOT / "build/fpga-flow")))
PROJECT = OUTPUT_DIR / "tests/vivado-rtl/gba-zynq7020-rtl.xpr"
if "FPGA_FLOW_DEPENDENCIES_JSON" in os.environ:
    dependency_outputs = json.loads(os.environ["FPGA_FLOW_DEPENDENCIES_JSON"]).get("rtl_project", {}).get("outputs", {})
    candidates = [path for path in dependency_outputs if path.endswith("/gba-zynq7020-rtl.xpr")]
    if len(candidates) != 1:
        raise RuntimeError("rtl_project dependency must provide one XPR")
    PROJECT = ROOT / candidates[0]


class RTLRunError(RuntimeError):
    pass


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fingerprint(bench: RTLBench, project: Path, seed: int, vivado: Path) -> str:
    try:
        dependencies = json.loads(os.environ["FPGA_FLOW_DEPENDENCIES_JSON"])
        tool_versions = json.loads(os.environ["FPGA_FLOW_TOOL_VERSIONS_JSON"])
    except (KeyError, json.JSONDecodeError) as exc:
        raise RTLRunError("run RTL through FPGAFlow so dependency and tool identities are recorded") from exc
    if not isinstance(dependencies, dict) or not dependencies.get("rtl_project") or not isinstance(tool_versions, dict) or not tool_versions.get("vivado"):
        raise RTLRunError("FPGAFlow did not provide the RTL project and Vivado identities")
    identity = {
        "schema_version": 2,
        "seed": seed,
        "vivado": str(vivado.resolve()),
        "tool_versions": tool_versions,
        "project_sha256": _hash_file(project),
        "project_dependency": dependencies["rtl_project"],
        "runner_sha256": _hash_file(Path(__file__)),
        "manifest_reader_sha256": _hash_file(ROOT / "scripts/flow/rtl_manifest.py"),
        "bench": asdict(bench),
        "source_sha256": {source: _hash_file(ROOT / source) for source in bench.sources},
    }
    fixture = ROOT / "tests/fixtures/anwj_rom_1m.hex"
    if fixture.is_file():
        identity["fixture_sha256"] = _hash_file(fixture)
    return hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _tcl_quote(value: Path | str) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("[", "\\[").replace("]", "\\]") + '"'


def _render_tcl(project: Path, output: Path, bench: RTLBench, seed: int) -> str:
    sources = " ".join(_tcl_quote(ROOT / source) for source in bench.sources)
    return f'''set project_file {_tcl_quote(project)}
set output_dir {_tcl_quote(output)}
set benches [list {sources}]
set top {_tcl_quote(bench.top)}
set seed {int(seed)}
file mkdir $output_dir
open_project $project_file
foreach bench $benches {{
  if {{[llength [get_files -quiet $bench]] == 0}} {{ add_files -fileset sim_1 -norecurse $bench }}
  set bench_obj [get_files -quiet $bench]
  if {{[string tolower [file extension $bench]] in {{.vhd .vhdl}}}} {{ set_property file_type {{VHDL 2008}} $bench_obj }}
}}
set_property top $top [get_filesets sim_1]
update_compile_order -fileset sim_1
set log_path [file join $output_dir xsim.log]
set sim_tcl_path [file join $output_dir run_test.tcl]
set sim_tcl_file [open $sim_tcl_path w]
puts $sim_tcl_file {{run all}}
puts $sim_tcl_file {{quit}}
close $sim_tcl_file
set_property -name xsim.simulate.custom_tcl -value $sim_tcl_path -objects [get_filesets sim_1]
set_property -name xsim.simulate.runtime -value {{}} -objects [get_filesets sim_1]
set_property -name xsim.simulate.wdb -value {{}} -objects [get_filesets sim_1]
set_property -name xsim.simulate.log_all_signals -value false -objects [get_filesets sim_1]
set xsim_options [list -sv_seed $seed -testplusarg "seed=$seed"]
set_property -name {{xsim.simulate.xsim.more_options}} -value $xsim_options -objects [get_filesets sim_1]
export_simulation -simulator xsim -directory $output_dir/xsim -force -absolute_path -exec
set simulator_log [file join $output_dir xsim xsim simulate.log]
if {{![file isfile $simulator_log]}} {{ error "XSim log was not produced: $simulator_log" }}
file copy -force $simulator_log $log_path
close_project
'''


def _simulator_log_path(output: Path) -> Path:
    return output / "xsim" / "xsim" / "simulate.log"


def _resume_hit(bench: RTLBench, output: Path, fingerprint: str) -> bool:
    record = output / "bench.json"
    log = output / "xsim.log"
    if not record.is_file() or not log.is_file():
        return False
    try:
        data = json.loads(record.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    text = log.read_text(encoding="utf-8", errors="replace")
    return (data.get("status") == "passed" and data.get("fingerprint") == fingerprint
            and data.get("log_sha256") == _hash_file(log)
            and not _has_failure(text) and any(marker in text for marker in bench.success_markers))


def _has_failure(text: str) -> bool:
    return bool(re.search(r"(?im)^.*(?:\bTEST_FAIL\b|\*\*\* SOME TESTS FAILED \*\*\*|\bFAIL\b(?!\s*:\s*0\b)).*$", text))


def _write_state(output: Path, bench: RTLBench, fingerprint: str, status: str, **values: object) -> None:
    temporary = output / "bench.json.tmp"
    temporary.write_text(json.dumps({"name": bench.name, "fingerprint": fingerprint,
                                     "status": status, **values}, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, output / "bench.json")


def _run_one(bench: RTLBench, vivado: Path, project: Path, root_out: Path, seed: int) -> None:
    output = root_out / bench.name
    output.mkdir(parents=True, exist_ok=True)
    fingerprint = _fingerprint(bench, project, seed, vivado)
    if _resume_hit(bench, output, fingerprint):
        print(f"[RTL-CACHE] {bench.name}", flush=True)
        return
    _write_state(output, bench, fingerprint, "running")
    (output / "xsim.log").unlink(missing_ok=True)
    print(f"[RTL-RUN] {bench.name}", flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix=f"rtl-project-{bench.name}-", dir=str(output)) as temporary:
            project_copy_root = Path(temporary) / "project"
            shutil.copytree(project.parent, project_copy_root)
            project_copy = project_copy_root / project.name
            # Every attempt gets a fresh simulation directory. Reusing an old
            # simulate.log could otherwise make an interrupted run look passed.
            simulation = Path(temporary) / "simulation"
            simulation.mkdir()
            fixture = ROOT / "tests/fixtures/anwj_rom_1m.hex"
            if fixture.is_file():
                local_fixture = simulation / "xsim" / "anwj_rom_1m.hex"
                local_fixture.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(fixture, local_fixture)
            tcl = output / "run.tcl"
            tcl.write_text(_render_tcl(project_copy, simulation, bench, seed), encoding="utf-8", newline="\n")
            log = output / "vivado.log"
            with log.open("w", encoding="utf-8") as stream:
                result = subprocess.run(
                    [str(vivado), "-mode", "batch", "-source", str(tcl)],
                    cwd=output, stdout=stream, stderr=subprocess.STDOUT,
                    timeout=bench.timeout_seconds, check=False,
                )
            xsim_log = output / "xsim.log"
            simulator_log = _simulator_log_path(simulation)
            if simulator_log.is_file():
                shutil.copyfile(simulator_log, xsim_log)
            if result.returncode or not xsim_log.is_file():
                raise RTLRunError(f"{bench.name} Vivado simulation failed; see {log}")
            text = xsim_log.read_text(encoding="utf-8", errors="replace")
            if _has_failure(text):
                raise RTLRunError(f"{bench.name} reported a failure; see {xsim_log}")
            if not any(marker in text for marker in bench.success_markers):
                raise RTLRunError(f"{bench.name} did not report a success marker; see {xsim_log}")
        if _fingerprint(bench, project, seed, vivado) != fingerprint:
            raise RTLRunError(f"{bench.name} inputs changed during simulation")
        _write_state(output, bench, fingerprint, "passed", log_sha256=_hash_file(output / "xsim.log"))
    except Exception as exc:
        _write_state(output, bench, fingerprint, "failed", error=str(exc))
        raise
    print(f"[RTL-PASS] {bench.name}", flush=True)


def _run_all(benches: Iterable[RTLBench], vivado: Path, project: Path, output: Path, seed: int, jobs: int) -> None:
    pending = list(benches)
    if jobs <= 1:
        for bench in pending:
            _run_one(bench, vivado, project, output, seed)
        return
    running: dict[object, tuple[RTLBench, set[str]]] = {}
    active_resources: set[str] = set()
    with ThreadPoolExecutor(max_workers=jobs, thread_name_prefix="gba-rtl") as pool:
        while pending or running:
            launched = False
            for bench in list(pending):
                resources = set(bench.resources)
                if resources & active_resources:
                    continue
                if not bench.parallel and running:
                    continue
                if any(not item.parallel for item, _ in running.values()):
                    continue
                future = pool.submit(_run_one, bench, vivado, project, output, seed)
                running[future] = (bench, resources)
                active_resources.update(resources)
                pending.remove(bench)
                launched = True
                if len(running) >= jobs:
                    break
            if running:
                done, _ = wait(tuple(running), return_when=FIRST_COMPLETED)
                for future in done:
                    bench, resources = running.pop(future)
                    active_resources.difference_update(resources)
                    future.result()
            elif pending and not launched:
                raise RTLRunError("RTL benches cannot be scheduled with declared resources")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", required=True)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--vivado", default=os.environ.get("VIVADO_BIN", "vivado"))
    args = parser.parse_args()
    if not 0 <= args.seed <= 2147483647 or args.jobs < 1:
        parser.error("invalid seed or jobs")
    try:
        benches = benches_for_suite(args.suite, ROOT)
    except RTLManifestError as exc:
        print(f"FPGA_FLOW_RTL_MANIFEST_FAILED: {exc}", file=sys.stderr)
        return 2
    if not PROJECT.is_file():
        print(f"FPGA_FLOW_RTL_PROJECT_MISSING: {PROJECT}", file=sys.stderr)
        return 2
    output = OUTPUT_DIR / "tests/rtl" / args.suite / f"seed-{args.seed}" / "current"
    output.mkdir(parents=True, exist_ok=True)
    if args.suite == "system":
        fixture = ROOT / "tests/fixtures/anwj_rom_1m.hex"
        fixture_cache = OUTPUT_DIR / "tests/rtl/system/tests/fixtures/anwj_rom_1m.hex"
        if not fixture.is_file():
            print(f"FPGA_FLOW_RTL_FIXTURE_MISSING: {fixture}", file=sys.stderr)
            return 2
        fixture_cache.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture, fixture_cache)
    try:
        _run_all(benches, Path(args.vivado), PROJECT, output, args.seed, min(args.jobs, 4))
    except Exception as exc:
        print(f"FPGA_FLOW_RTL_FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    print(f"FPGA_FLOW_RTL_PASS suite={args.suite} benches={len(benches)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

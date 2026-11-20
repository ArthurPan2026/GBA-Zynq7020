#!/usr/bin/env python3
"""Run portable RTL benches declared in the project manifest."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.rtl_manifest import load_rtl_manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--backend")
    args = parser.parse_args()
    benches = {bench.name: bench for bench in load_rtl_manifest(ROOT)}
    with (ROOT / "tests/rtl_manifest.toml").open("rb") as stream:
        raw = tomllib.load(stream)
    selected = [entry for entry in raw["bench"] if "iverilog_sources" in entry]
    if not selected:
        raise RuntimeError("manifest does not declare any portable benches")
    failures: list[str] = []
    for entry in selected:
        bench = benches[entry["name"]]
        sources = entry["iverilog_sources"]
        if not isinstance(sources, list) or not sources or not all(isinstance(s, str) for s in sources):
            raise ValueError(f"{bench.name}: invalid iverilog_sources")
        for source in sources:
            relative = Path(source)
            path = ROOT / relative
            if relative.is_absolute() or ".." in relative.parts or path.is_symlink() or not path.is_file():
                raise ValueError(f"{bench.name}: invalid source {source!r}")
        out = ROOT / "out/ci/iverilog" / bench.name
        out.mkdir(parents=True, exist_ok=True)
        command = [args.iverilog]
        if args.backend:
            command.extend(["-B", args.backend])
        command.extend(["-g2012", "-s", bench.top, "-o", str(out / "sim.vvp")])
        command.extend(str(ROOT / source) for source in (*sources, *bench.sources))
        try:
            compiled = subprocess.run(command, cwd=out, text=True, capture_output=True, timeout=120)
            (out / "compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
            if compiled.returncode:
                raise RuntimeError("compilation failed")
            simulated = subprocess.run([args.vvp, str(out / "sim.vvp")], cwd=out,
                                       text=True, capture_output=True, timeout=120)
            output = simulated.stdout + simulated.stderr
            (out / "run.log").write_text(output, encoding="utf-8")
            if (simulated.returncode or re.search(r"(?im)\bTEST_FAIL\b|^FATAL:", output)
                    or not any(marker in output for marker in bench.success_markers)):
                raise RuntimeError("simulation failed or did not report its pass marker")
            print(f"[IVERILOG-PASS] {bench.name}", flush=True)
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
            failures.append(f"{bench.name}: {exc}")
            print(f"[IVERILOG-FAIL] {bench.name}: {exc}", file=sys.stderr, flush=True)
    if failures:
        return 1
    print(f"IVERILOG_TESTS_PASS benches={len(selected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Ross Vitis headless platform, application and Zynq boot-image stages.

All generated Python wrappers, Vitis components, build outputs, BIFs and images stay
under the caller-supplied output workspace. The input source tree is read-only.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid
from typing import Any, Iterable

FREERTOS_TOTAL_HEAP_SIZE = 256 * 1024


class VitisStageError(RuntimeError):
    """A Vitis workflow stage failed or produced incomplete evidence."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _file_artifact(name: str, path: Path) -> dict[str, str]:
    resolved = path.resolve()
    if not resolved.is_file() or resolved.stat().st_size == 0:
        raise VitisStageError(f"Vitis stage did not produce {name}: {resolved}")
    return {"path": str(resolved), "sha256": sha256_file(resolved)}


def _python_literal(value: str) -> str:
    """JSON strings are valid Python string literals for our path/config values."""
    return json.dumps(value, ensure_ascii=True)


def _stage_root(workspace: Path, stage: str, stage_id: str) -> Path:
    root = workspace.resolve() / f"{stage}-{stage_id[:12]}-{uuid.uuid4().hex[:8]}"
    root.mkdir(parents=True, exist_ok=False)
    return root


def _vitis_workspace(stage_root: Path) -> Path:
    """Create an empty Vitis metadata root beside the stage control files."""
    workspace = stage_root / "workspace"
    workspace.mkdir(parents=True, exist_ok=False)
    return workspace


def _platform_workspace_for_xpfm(xpfm: Path) -> Path:
    """Resolve the Vitis workspace that owns an exported platform XPFM."""
    if len(xpfm.parents) < 4:
        raise VitisStageError(f"Platform XPFM path has no workspace root: {xpfm}")
    component_name = xpfm.stem
    if (
        xpfm.parent.name != component_name
        or xpfm.parents[1].name != "export"
        or xpfm.parents[2].name != component_name
    ):
        raise VitisStageError(
            f"Platform XPFM is not under workspace/component/export/component: {xpfm}"
        )
    workspace = xpfm.parents[3]
    if not workspace.is_dir():
        raise VitisStageError(f"Platform Vitis workspace is missing: {workspace}")
    return workspace.resolve()


def _run_vitis_script(vitis_bin: Path, stage_root: Path, script_body: Iterable[str], *, timeout: int = 3600) -> dict[str, Any]:
    """Run one isolated Vitis -s API script and require its structured result marker."""
    vitis_bin = vitis_bin.expanduser().resolve()
    if not vitis_bin.is_file():
        raise VitisStageError(f"Vitis executable does not exist: {vitis_bin}")
    script_path = stage_root / "stage.py"
    log_path = stage_root / "vitis.log"
    script_path.write_text("\n".join(script_body) + "\n", encoding="utf-8", newline="\n")
    env = os.environ.copy()
    data_dir = stage_root / ".vitis-data"
    data_dir.mkdir()
    env["XILINX_VITIS_DATA_DIR"] = str(data_dir)
    started = time.monotonic()
    try:
        result = subprocess.run(
            [str(vitis_bin), "-s", str(script_path)],
            cwd=stage_root,
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        stdout = getattr(exc, "stdout", "") or ""
        stderr = getattr(exc, "stderr", "") or ""
        log_path.write_text(f"EXCEPTION: {exc}\n{stdout}\n{stderr}", encoding="utf-8")
        raise VitisStageError(f"Vitis -s failed or timed out; see {log_path}: {exc}") from exc
    output = "\n".join(part for part in (result.stdout, result.stderr) if part)
    log_path.write_text(output, encoding="utf-8")
    marker = "ROSS_VITIS_RESULT="
    records = [line[len(marker):] for line in output.splitlines() if line.startswith(marker)]
    if result.returncode != 0:
        raise VitisStageError(
            f"Vitis -s exited with code {result.returncode}; see {log_path}\n"
            + output[-4000:]
        )
    if not records:
        raise VitisStageError(
            f"Vitis -s returned {result.returncode} without the result marker; "
            f"the script may not have run. See {log_path}"
        )
    try:
        payload = json.loads(records[-1])
    except json.JSONDecodeError as exc:
        raise VitisStageError(f"Vitis stage returned invalid JSON at {log_path}") from exc
    if not isinstance(payload, dict):
        raise VitisStageError(f"Vitis stage result must be an object: {log_path}")
    payload["vitis_exit_code"] = result.returncode
    payload["elapsed_seconds"] = round(time.monotonic() - started, 3)
    payload["log_path"] = str(log_path.resolve())
    payload["command_output_summary"] = output[-4000:]
    return payload


def _success_result(payload: dict[str, Any], stage: str) -> None:
    if payload.get("build_status") != "SUCCESS":
        raise VitisStageError(
            f"Vitis {stage} did not report build success; status={payload.get('build_status')!r}, "
            f"details={payload.get('build_result')!r}, log={payload.get('log_path')}"
        )


def _vitis_build_return_succeeded(value: object) -> bool:
    return value is True or (type(value) is int and value == 0)


def _platform_command_succeeded(value: object) -> bool:
    return type(value) is int and value == 0


def _platform_evidence_succeeded(value: object, require_heap: bool = True) -> bool:
    if not isinstance(value, dict):
        return False
    fsbls = value.get("fsbls")
    base_ok = (
        "export=SUCCESS" in str(value.get("export_status", ""))
        and value.get("xpfm_ok") is True
        and isinstance(fsbls, list)
        and bool(fsbls)
        and all(isinstance(path, str) and bool(path) for path in fsbls)
    )
    return base_ok and (
        not require_heap
        or value.get("freertos_heap_size_bytes") == FREERTOS_TOTAL_HEAP_SIZE
    )


def run_platform_stage(vitis_bin: Path, workspace: Path, xsa: Path, stage_id: str) -> dict[str, Any]:
    """Create and build one FreeRTOS platform from the exact XSA input."""
    xsa = xsa.expanduser().resolve()
    if not xsa.is_file() or xsa.stat().st_size == 0:
        raise VitisStageError(f"Required hardware XSA is missing or empty: {xsa}")

    workspace = workspace.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    stage_root = _stage_root(workspace, "platform", stage_id)
    vitis_workspace = _vitis_workspace(stage_root)
    component = f"zynq_gba_platform_{stage_id[:12]}"
    component_root = vitis_workspace / component
    xpfm = component_root / "export" / component / f"{component}.xpfm"
    fsbl_glob = component_root / "**" / "fsbl.elf"
    config_path = stage_root / "platform-input.json"
    config_path.write_text(
        json.dumps(
            {
                "workspace": str(vitis_workspace),
                "name": component,
                "component_root": str(component_root),
                "xsa": str(xsa),
                "cpu": "ps7_cortexa9_0",
                "os": "freertos",
                "domain": "freertos_ps7_cortexa9_0",
                "xpfm": str(xpfm),
                "domain_root": str(component_root / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"),
                "freertos_total_heap_size": FREERTOS_TOTAL_HEAP_SIZE,
                "fatfs_script": str(
                    Path(__file__).resolve().parents[1]
                    / "scripts"
                    / "fatfs"
                    / "configure_utf8_lfn.py"
                ),
                "python": sys.executable,
                "fsbl_glob": str(fsbl_glob),
            },
            sort_keys=True,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    body = [
        "import glob, json, os, subprocess, time, vitis",
        f"cfg = json.loads(open({_python_literal(str(config_path))}, encoding='utf-8').read())",
        "def build_succeeded(value):",
        "    return value is True or (type(value) is int and value == 0)",
        "def platform_evidence():",
        "    marker = os.path.join(cfg['component_root'], 'export', '.buildstatus')",
        "    marker_text = open(marker, encoding='utf-8').read() if os.path.isfile(marker) else ''",
        "    xpfm_ok = os.path.isfile(cfg['xpfm']) and os.path.getsize(cfg['xpfm']) > 0",
        "    freertos_config = os.path.join(cfg['domain_root'], 'bsp', 'include', 'FreeRTOSConfig.h')",
        "    config_text = open(freertos_config, encoding='utf-8').read() if os.path.isfile(freertos_config) else ''",
        "    heap_size = None",
        "    for line in config_text.splitlines():",
        "        if line.lstrip().startswith('#define') and 'configTOTAL_HEAP_SIZE' in line:",
        "            try: heap_size = int(line.rsplit(')', 2)[-2].strip())",
        "            except (ValueError, IndexError): pass",
        "    fsbls = sorted(",
        "        path for path in glob.glob(cfg['fsbl_glob'], recursive=True)",
        "        if os.path.isfile(path) and os.path.getsize(path) > 0",
        "    )",
        "    return {'export_status': marker_text, 'xpfm_ok': xpfm_ok, 'fsbls': fsbls, 'freertos_heap_size_bytes': heap_size}",
        "def wait_for_platform_evidence(timeout=30, expected_heap=None):",
        "    deadline = time.monotonic() + timeout",
        "    evidence = platform_evidence()",
        "    while not ('export=SUCCESS' in evidence['export_status'] and evidence['xpfm_ok'] and evidence['fsbls']) or (expected_heap is not None and evidence['freertos_heap_size_bytes'] != expected_heap):",
        "        if time.monotonic() >= deadline:",
        "            return evidence",
        "        time.sleep(0.5)",
        "        evidence = platform_evidence()",
        "    return evidence",
        "client = vitis.create_client()",
        "try:",
        "    client.set_workspace(cfg['workspace'])",
        "    platform = client.create_platform_component(",
        "        name=cfg['name'], hw_design=cfg['xsa'], os=cfg['os'],",
        "        cpu=cfg['cpu'], domain_name=cfg['domain'], generate_dtb=False)",
        "    domain = platform.get_domain(name=cfg['domain'])",
        "    domain.set_lib(lib_name='xilffs')",
        "    first_rc = platform.build()",
        "    first_evidence = wait_for_platform_evidence()",
        "    first_ok = (",
        "        build_succeeded(first_rc)",
        "        and 'export=SUCCESS' in first_evidence['export_status']",
        "        and first_evidence['xpfm_ok']",
        "        and bool(first_evidence['fsbls'])",
        "    )",
        "    fatfs_env = os.environ.copy()",
        "    fatfs_env.pop('PYTHONHOME', None)",
        "    fatfs_env.pop('PYTHONPATH', None)",
        "    heap_config_result = None",
        "    heap_build_rc = None",
        "    heap_evidence = {}",
        "    heap_ok = False",
        "    apply_result = None",
        "    rebuild_rc = None",
        "    rebuild_evidence = {}",
        "    check_result = None",
        "    if first_ok:",
        "        heap_config_result = domain.set_config(option='os', param='freertos_total_heap_size', value=cfg['freertos_total_heap_size'])",
        "        heap_build_rc = platform.build()",
        "        heap_evidence = wait_for_platform_evidence(expected_heap=cfg['freertos_total_heap_size'])",
        "        heap_ok = (",
        "            build_succeeded(heap_build_rc)",
        "            and 'export=SUCCESS' in heap_evidence['export_status']",
        "            and heap_evidence['xpfm_ok']",
        "            and bool(heap_evidence['fsbls'])",
        "            and heap_evidence['freertos_heap_size_bytes'] == cfg['freertos_total_heap_size']",
        "        )",
        "    if heap_ok:",
        "        apply_result = subprocess.run(",
        "            [cfg['python'], cfg['fatfs_script'], '--apply', '--bsp-root', cfg['domain_root']],",
        "            text=True, capture_output=True, check=False, env=fatfs_env)",
        "        if apply_result.returncode == 0:",
        "            rebuild_rc = platform.build()",
        "            rebuild_evidence = wait_for_platform_evidence(expected_heap=cfg['freertos_total_heap_size'])",
        "            check_result = subprocess.run(",
        "                [cfg['python'], cfg['fatfs_script'], '--check', '--bsp-root', cfg['domain_root']],",
        "                text=True, capture_output=True, check=False, env=fatfs_env)",
        "    apply_rc = apply_result.returncode if apply_result is not None else None",
        "    check_rc = check_result.returncode if check_result is not None else None",
        "    final_ok = (",
        "        first_ok",
        "        and heap_config_result is True",
        "        and heap_ok",
        "        and apply_rc == 0",
        "        and build_succeeded(rebuild_rc)",
        "        and 'export=SUCCESS' in str(rebuild_evidence.get('export_status', ''))",
        "        and rebuild_evidence.get('xpfm_ok') is True",
        "        and bool(rebuild_evidence.get('fsbls'))",
        "        and rebuild_evidence.get('freertos_heap_size_bytes') == cfg['freertos_total_heap_size']",
        "        and check_rc == 0",
        "    )",
        "    build_result = {",
        "        'first': {'return_value': first_rc, 'evidence': first_evidence},",
        "        'heap_reconfigure': {'return_value': heap_build_rc, 'evidence': heap_evidence},",
        "        'freertos_set_config_return': heap_config_result,",
        "        'fatfs_apply_return_code': apply_rc,",
        "        'rebuild': {'return_value': rebuild_rc, 'evidence': rebuild_evidence},",
        "        'fatfs_check_return_code': check_rc,",
        "        'freertos_total_heap_size': cfg['freertos_total_heap_size'],",
        "        'freertos_config_heap_size': rebuild_evidence.get('freertos_heap_size_bytes'),",
        "    }",
        "    print('ROSS_VITIS_RESULT=' + json.dumps({",
        "        'build_status': 'SUCCESS' if final_ok else 'FAILURE',",
        "        'return_value': rebuild_rc,",
        "        'first_build_return': first_rc,",
        "        'first_evidence': first_evidence,",
        "        'heap_build_return': heap_build_rc,",
        "        'heap_evidence': heap_evidence,",
        "        'rebuild_return': rebuild_rc,",
        "        'rebuild_evidence': rebuild_evidence,",
        "        'fatfs_apply_return_code': apply_rc,",
        "        'fatfs_check_return_code': check_rc,",
        "        'freertos_total_heap_size': cfg['freertos_total_heap_size'],",
        "        'freertos_set_config_return': heap_config_result,",
        "        'freertos_config_heap_size': rebuild_evidence.get('freertos_heap_size_bytes'),",
        "        'build_result': build_result,",
        "        'fatfs_apply': (apply_result.stdout + apply_result.stderr) if apply_result is not None else '',",
        "        'fatfs_check': (check_result.stdout + check_result.stderr) if check_result is not None else '',",
        "        'component': cfg['name'], 'xpfm': cfg['xpfm'],",
        "        'fsbl_glob': cfg['fsbl_glob']}))",
        "finally:",
        "    vitis.dispose()",
    ]

    payload = _run_vitis_script(vitis_bin, stage_root, body)
    _success_result(payload, "platform")

    first_build_return = payload.get("first_build_return")
    heap_build_return = payload.get("heap_build_return")
    rebuild_return = payload.get("rebuild_return")
    if not _vitis_build_return_succeeded(first_build_return):
        raise VitisStageError(
            f"Initial platform.build() returned failure: {first_build_return!r}"
        )
    if not _vitis_build_return_succeeded(heap_build_return):
        raise VitisStageError(
            f"FreeRTOS heap configuration platform.build() returned failure: {heap_build_return!r}"
        )
    if not _vitis_build_return_succeeded(rebuild_return):
        raise VitisStageError(
            f"Post-FatFs platform.build() returned failure: {rebuild_return!r}"
        )
    if not _platform_evidence_succeeded(payload.get("first_evidence"), require_heap=False):
        raise VitisStageError("Initial platform build lacks .xpfm/FSBL/export or FreeRTOS heap-size evidence.")
    if not _platform_evidence_succeeded(payload.get("heap_evidence")):
        raise VitisStageError("FreeRTOS heap configuration was not verified in the generated BSP.")
    if not _platform_evidence_succeeded(payload.get("rebuild_evidence")):
        raise VitisStageError("Post-FatFs platform build lacks .xpfm/FSBL/export or FreeRTOS heap-size evidence.")
    if not _platform_command_succeeded(payload.get("fatfs_apply_return_code")):
        raise VitisStageError(
            f"FatFs --apply failed: {payload.get('fatfs_apply_return_code')!r}"
        )
    if not _platform_command_succeeded(payload.get("fatfs_check_return_code")):
        raise VitisStageError(
            f"FatFs --check failed: {payload.get('fatfs_check_return_code')!r}"
        )

    xpfm_artifact = _file_artifact("built .xpfm", xpfm)
    fsbl_candidates = sorted(
        path for path in component_root.rglob("fsbl.elf")
        if path.is_file() and path.stat().st_size > 0
    )
    if not fsbl_candidates:
        raise VitisStageError(f"Built platform has no FSBL ELF: {component_root}")
    fsbl = max(fsbl_candidates, key=lambda path: path.stat().st_size)
    return {
        "build_status": "SUCCESS",
        "artifacts": {
            "xpfm": xpfm_artifact,
            "fsbl_elf": _file_artifact("FSBL ELF", fsbl),
        },
        "component_name": component,
        "domain": "freertos_ps7_cortexa9_0",
        "bsp_domain_root": str(
            component_root / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"
        ),
        "freertos_heap_size_bytes": FREERTOS_TOTAL_HEAP_SIZE,
        "hardware_xsa_sha256": sha256_file(xsa),
        "vitis_result": payload,
    }

def _copy_app_source(source: Path, destination: Path) -> None:
    """Copy app inputs into an isolated Vitis import tree, excluding generated files."""
    source = source.expanduser().resolve()
    if not source.is_dir():
        raise VitisStageError(f"Application source directory is missing: {source}")
    ignored = {"build", ".cache", "_ide", "__pycache__"}
    for current, directories, files in os.walk(source):
        current_path = Path(current)
        rel = current_path.relative_to(source)
        directories[:] = sorted(name for name in directories if name not in ignored)
        target_dir = destination / rel
        target_dir.mkdir(parents=True, exist_ok=True)
        for filename in sorted(files):
            if filename in {"app.yaml", "compile_commands.json", ".clangd"} or filename.endswith((".o", ".d", ".pyc")):
                continue
            src = current_path / filename
            if src.is_symlink() or not src.is_file():
                continue
            shutil.copy2(src, target_dir / filename)


def run_app_stage(
    vitis_bin: Path,
    workspace: Path,
    xpfm: Path,
    app_source: Path,
    app_template: str,
    app_domain: str,
    stage_id: str,
) -> dict[str, Any]:
    """Import and build the existing C application on a built, exact-match platform."""
    xpfm = xpfm.expanduser().resolve()
    if not xpfm.is_file() or xpfm.stat().st_size == 0:
        raise VitisStageError(f"Built platform .xpfm is missing: {xpfm}")
    if not app_template or not app_domain:
        raise VitisStageError("Application template and platform domain are required.")
    vitis_workspace = _platform_workspace_for_xpfm(xpfm)
    workspace = workspace.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    stage_root = _stage_root(workspace, "app", stage_id)
    staged_source = stage_root / "import" / "src"
    _copy_app_source(app_source, staged_source)
    component = f"gba_app_{stage_id[:12]}_{uuid.uuid4().hex[:8]}"
    component_root = vitis_workspace / component
    config_path = stage_root / "app-input.json"
    config_path.write_text(json.dumps({
        "workspace": str(vitis_workspace),
        "name": component,
        "xpfm": str(xpfm),
        "domain": app_domain,
        "template": app_template,
        "app_source": str(staged_source),
        "component_root": str(component_root),
    }, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    body = [
        "import json, vitis",
        f"cfg = json.loads(open({_python_literal(str(config_path))}, encoding='utf-8').read())",
        "client = vitis.create_client()",
        "try:",
        "    client.set_workspace(cfg['workspace'])",
        "    app = client.create_app_component(",
        "        name=cfg['name'], platform=cfg['xpfm'],",
        "        domain=cfg['domain'], template=cfg['template'])",
        "    app.import_files(from_loc=cfg['app_source'], dest_dir_in_cmp='src')",
        "    rc = app.build()",
        "    status = str(rc).upper()",
        "    build_succeeded = (rc is True) or (type(rc) is int and rc == 0)",
        "    build_dir = __import__('os').path.join(cfg['component_root'], 'build')",
        "    import glob, os",
        "    elfs = [p for p in glob.glob(os.path.join(build_dir, '**', '*.elf'), recursive=True)",
        "            if os.path.isfile(p) and os.path.getsize(p) > 0]",
        "    elf = max(elfs, key=os.path.getsize) if elfs else None",
        "    ok = build_succeeded and (elf is not None)",
        "    if ok:",
        "        open(os.path.join(build_dir, '.buildstatus'), 'w', encoding='utf-8').write('hw=SUCCESS\\n')",
        "    print('ROSS_VITIS_RESULT=' + json.dumps({",
        "        'build_status': 'SUCCESS' if ok else 'FAILURE',",
        "        'return_value': status, 'build_return': rc, 'elf': elf,",
        "        'elf_candidates': elfs, 'component': cfg['name']}))",
        "finally:",
        "    vitis.dispose()",
    ]
    payload = _run_vitis_script(vitis_bin, stage_root, body)
    _success_result(payload, "application")
    build_return = payload.get("build_return")
    if not _vitis_build_return_succeeded(build_return):
        raise VitisStageError(f"Application build returned failure: {build_return!r}")
    elf = Path(str(payload["elf"])).resolve()
    build_dir = component_root / "build"
    marker = build_dir / ".buildstatus"
    marker_lines = (
        {line.strip() for line in marker.read_text(encoding="utf-8").splitlines()}
        if marker.is_file()
        else set()
    )
    if "hw=SUCCESS" not in marker_lines:
        raise VitisStageError(f"Application build status marker is missing or unsuccessful: {marker}")
    return {
        "build_status": "SUCCESS",
        "artifacts": {"app_elf": _file_artifact("application ELF", elf)},
        "component_name": component,
        "xpfm_sha256": sha256_file(xpfm),
        "vitis_workspace": str(vitis_workspace),
        "source_path": str(Path(app_source).resolve()),
        "vitis_result": payload,
    }


def run_boot_stage(
    bootgen_bin: Path,
    output_dir: Path,
    fsbl: Path,
    bitstream: Path,
    elf: Path,
    stage_id: str,
) -> dict[str, Any]:
    """Build and parse a non-secure Zynq BOOT.BIN from matched artifacts."""
    bootgen_bin = bootgen_bin.expanduser().resolve()
    if not bootgen_bin.is_file():
        raise VitisStageError(f"Bootgen executable is missing: {bootgen_bin}")
    inputs = {
        "fsbl": fsbl.expanduser().resolve(),
        "bitstream": bitstream.expanduser().resolve(),
        "app_elf": elf.expanduser().resolve(),
    }
    for name, path in inputs.items():
        if not path.is_file() or path.stat().st_size == 0:
            raise VitisStageError(f"BOOT.BIN input is missing or empty ({name}): {path}")
    output_dir = output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    bif = output_dir / f"boot_{stage_id[:12]}.bif"
    boot_bin = output_dir / f"BOOT_{stage_id[:12]}.BIN"
    # Zynq-7000 BIF: FSBL, PL bitstream, then the application ELF.
    content = (
        "the_ROM_image:\n{\n"
        f"  [bootloader] {inputs['fsbl']}\n"
        f"  {inputs['bitstream']}\n"
        f"  {inputs['app_elf']}\n"
        "}\n"
    )
    bif.write_text(content, encoding="utf-8", newline="\n")
    result = subprocess.run(
        [str(bootgen_bin), "-arch", "zynq", "-image", str(bif),
         "-o", str(boot_bin), "-w", "on", "-log", "error"],
        cwd=output_dir,
        text=True,
        capture_output=True,
        timeout=900,
        check=False,
    )
    log_path = output_dir / f"bootgen_{stage_id[:12]}.log"
    log_path.write_text("\n".join(part for part in (result.stdout, result.stderr) if part), encoding="utf-8")
    if result.returncode != 0:
        raise VitisStageError(f"Bootgen failed with code {result.returncode}; see {log_path}")
    if not boot_bin.is_file() or boot_bin.stat().st_size < 1024:
        raise VitisStageError(f"Bootgen returned success without a valid-sized BOOT.BIN: {boot_bin}")
    readback = subprocess.run(
        [str(bootgen_bin), "-arch", "zynq", "-read", str(boot_bin)],
        cwd=output_dir,
        text=True,
        capture_output=True,
        timeout=300,
        check=False,
    )
    log_path.write_text(
        (result.stdout or "") + "\n" + (result.stderr or "") + "\n"
        + (readback.stdout or "") + "\n" + (readback.stderr or ""),
        encoding="utf-8",
    )
    if readback.returncode != 0:
        raise VitisStageError(f"Bootgen could not parse the generated BOOT.BIN; see {log_path}")
    return {
        "build_status": "SUCCESS",
        "artifacts": {
            "bif": _file_artifact("boot BIF", bif),
            "boot_bin": _file_artifact("BOOT.BIN", boot_bin),
        },
        "input_sha256": {name: sha256_file(path) for name, path in inputs.items()},
        "log_path": str(log_path),
        "command_output_summary": (readback.stdout or result.stdout or "")[-4000:],
    }

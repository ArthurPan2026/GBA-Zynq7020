#!/usr/bin/env python3
"""Ross Vitis headless platform, application and Zynq boot-image stages.

All generated Python wrappers, Vitis components, build outputs, BIFs and images stay
under the caller-supplied output workspace. The input source tree is read-only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
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


def _platform_component_software(component_root: Path) -> Path:
    matches = sorted(component_root.rglob("cortexa9_toolchain.cmake"))
    exported = [path for path in matches if "/export/" in path.as_posix()]
    if exported:
        return exported[0].parent
    if matches:
        return matches[0].parent
    raise VitisStageError(f"Exported FreeRTOS toolchain was not found under {component_root}")


def _platform_disk_evidence(cfg: dict[str, Any]) -> dict[str, Any]:
    component_root = Path(cfg["component_root"])
    marker = component_root / "export" / ".buildstatus"
    marker_text = marker.read_text(encoding="utf-8") if marker.is_file() else ""
    xpfm = Path(cfg["xpfm"])
    config_path = Path(cfg["domain_root"]) / "bsp" / "include" / "FreeRTOSConfig.h"
    config_text = config_path.read_text(encoding="utf-8", errors="replace") if config_path.is_file() else ""
    heap_size = None
    for line in config_text.splitlines():
        if line.lstrip().startswith("#define") and "configTOTAL_HEAP_SIZE" in line:
            try:
                heap_size = int(line.rsplit(")", 2)[-2].strip())
            except (ValueError, IndexError):
                pass
    fsbls = sorted(
        str(path) for path in component_root.rglob("fsbl.elf")
        if path.is_file() and path.stat().st_size > 0
    )
    return {
        "export_status": marker_text,
        "xpfm_ok": xpfm.is_file() and xpfm.stat().st_size > 0,
        "fsbls": fsbls,
        "freertos_heap_size_bytes": heap_size,
    }


def _find_reusable_platform(
    workspace: Path, xsa: Path, expected_vitis_version: str | None,
) -> tuple[Path, dict[str, Any], dict[str, Any], Path] | None:
    current_xsa_sha256 = sha256_file(xsa)
    candidates = sorted(workspace.glob("platform-*/platform-input.json"))
    for config_path in reversed(candidates):
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8"))
            stage_root = config_path.parent.resolve()
            component_root = Path(cfg["component_root"]).resolve()
            if component_root.parent != (stage_root / "workspace").resolve():
                continue
            if Path(cfg["xsa"]).resolve() != xsa.resolve():
                continue
            # 仅检查路径不够：Vivado 会在相同路径覆盖新XSA。
            # 旧配置没有内容哈希时一律不复用，强制按当前XSA全量首建。
            if cfg.get("xsa_sha256") != current_xsa_sha256:
                continue
            if cfg.get("freertos_total_heap_size") != FREERTOS_TOTAL_HEAP_SIZE:
                continue
            if cfg.get("os") != "freertos" or cfg.get("domain") != "freertos_ps7_cortexa9_0":
                continue
            vitis_log = stage_root / "vitis.log"
            if expected_vitis_version:
                version_token = next(
                    (part.strip("v()") for part in expected_vitis_version.split()
                     if part.strip("v()").count(".") == 2
                     and part.strip("v()").replace(".", "").isdigit()),
                    expected_vitis_version,
                )
                if not vitis_log.is_file() or version_token not in vitis_log.read_text(
                    encoding="utf-8", errors="replace"
                ):
                    continue
            evidence = _platform_disk_evidence(cfg)
            if not _platform_evidence_succeeded(evidence):
                continue
            if not list(component_root.rglob("ps7_init.tcl")):
                continue
            xilffs_header = Path(cfg["domain_root"]) / "bsp" / "include" / "xilffs_config.h"
            if not xilffs_header.is_file() or not re.search(
                r"(?m)^#define\s+FILE_SYSTEM_USE_LFN\s+2\b",
                xilffs_header.read_text(encoding="utf-8", errors="replace"),
            ):
                continue
            return stage_root, cfg, evidence, vitis_log
        except (KeyError, OSError, json.JSONDecodeError, ValueError):
            continue
    return None


def _copy_if_changed(source: Path, destination: Path) -> None:
    if destination.is_file() and sha256_file(source) == sha256_file(destination):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".flow-tmp")
    shutil.copy2(source, temporary)
    os.replace(temporary, destination)


def _configure_fatfs_and_build_xilffs(
    component_root: Path, cfg: dict[str, Any], stage_root: Path,
) -> tuple[Path, Path, Path]:
    domain_root = Path(cfg["domain_root"])
    platform_sw = _platform_component_software(component_root)
    fatfs_script = Path(cfg["fatfs_script"])
    environment = os.environ.copy()
    environment.pop("PYTHONHOME", None)
    environment.pop("PYTHONPATH", None)
    environment["PS_APP_PLATFORM_DOMAIN_DIR"] = str(domain_root)
    environment["PS_APP_PLATFORM_SW_DIR"] = str(platform_sw)
    log_parts = ["COMMAND: configure_utf8_lfn.py --apply"]
    fatfs_log = stage_root / "fatfs-xilffs.log"

    apply = subprocess.run(
        [sys.executable, str(fatfs_script), "--apply"],
        cwd=Path(__file__).resolve().parents[2],
        env=environment, text=True, capture_output=True, check=False,
    )
    log_parts.extend([apply.stdout or "", apply.stderr or ""])
    if apply.returncode:
        fatfs_log.write_text("\n".join(log_parts), encoding="utf-8")
        raise VitisStageError(f"FatFs --apply failed; see {fatfs_log}")

    build_dir = domain_root / "bsp" / "libsrc" / "build_configs" / "gen_bsp"
    toolchain_bin = None
    cache_file = build_dir / 'CMakeCache.txt'
    if cache_file.is_file():
        for line in cache_file.read_text(encoding='utf-8', errors='replace').splitlines():
            if line.startswith('CMAKE_C_COMPILER_AR:FILEPATH='):
                compiler_ar = Path(line.partition('=')[2].strip())
                if compiler_ar.is_file():
                    toolchain_bin = compiler_ar.parent
                    break
    if toolchain_bin is not None and (toolchain_bin / 'arm-none-eabi-ar').is_file():
        environment['PATH'] = os.pathsep.join((str(toolchain_bin), environment.get('PATH', '')))
        log_parts.append(f'Vitis cross-toolchain bin: {toolchain_bin}')
    else:
        toolchain_bin = None
    cmake_text = os.environ.get("CMAKE_BIN")
    if not cmake_text:
        cmake_text = "/usr/bin/cmake" if Path("/usr/bin/cmake").is_file() else shutil.which("cmake")
    cmake = Path(cmake_text) if cmake_text else None
    if cmake is None or not cmake.is_file() or not (build_dir / "build.ninja").is_file():
        fatfs_log.write_text("\n".join(log_parts), encoding="utf-8")
        raise VitisStageError(
            f"Generated BSP Ninja build or CMake is missing: build_dir={build_dir} "
            f"dir={build_dir.is_dir()} ninja={(build_dir / 'build.ninja').is_file()} "
            f"cmake={cmake} cmake_file={cmake is not None and cmake.is_file()}"
        )

    jobs = max(1, min(8, int(os.environ.get("VITIS_BUILD_JOBS", "8"))))
    configure_command = [
        str(cmake), '-S', str(domain_root / 'bsp'), '-B', str(build_dir), '-G', 'Ninja',
    ]
    if toolchain_bin is not None:
        configure_command.extend([
            '-DCMAKE_AR=' + str(toolchain_bin / 'arm-none-eabi-ar'),
            '-DCMAKE_RANLIB=' + str(toolchain_bin / 'arm-none-eabi-ranlib'),
        ])
    configured = subprocess.run(
        configure_command, cwd=build_dir, env=environment,
        text=True, capture_output=True, timeout=900, check=False,
    )
    log_parts.extend([f"COMMAND: {configure_command!r}", configured.stdout or "", configured.stderr or ""])
    if configured.returncode:
        fatfs_log.write_text("\n".join(log_parts), encoding="utf-8")
        raise VitisStageError(f"Reconfiguring the generated BSP build directory failed; see {fatfs_log}")

    archive = build_dir / "libsrc" / "xilffs" / "src" / "libxilffs.a"
    # A previous failed link may leave a partial archive that Ninja sees as current.
    archive.unlink(missing_ok=True)
    cmake_command = [
        str(cmake), "--build", str(build_dir), "--target", "xilffs", "--parallel", str(jobs),
    ]
    built = subprocess.run(
        cmake_command, cwd=build_dir, env=environment,
        text=True, capture_output=True, timeout=3600, check=False,
    )
    log_parts.extend([f"COMMAND: {cmake_command!r}", built.stdout or "", built.stderr or ""])
    if built.returncode or not archive.is_file() or archive.stat().st_size == 0:
        fatfs_log.write_text("\n".join(log_parts), encoding="utf-8")
        raise VitisStageError(f"Rebuilding only the xilffs BSP target failed; see {fatfs_log}")

    _copy_if_changed(archive, domain_root / "bsp" / "lib" / "libxilffs.a")
    _copy_if_changed(archive, platform_sw / "lib" / "libxilffs.a")

    log_parts.append("COMMAND: configure_utf8_lfn.py --check")
    check = subprocess.run(
        [sys.executable, str(fatfs_script), "--check"],
        cwd=Path(__file__).resolve().parents[2],
        env=environment, text=True, capture_output=True, check=False,
    )
    log_parts.extend([check.stdout or "", check.stderr or ""])
    fatfs_log.write_text("\n".join(log_parts), encoding="utf-8")
    if check.returncode:
        raise VitisStageError(f"FatFs --check failed after xilffs rebuild; see {fatfs_log}")
    return platform_sw, fatfs_log, archive

def run_platform_stage(
    vitis_bin: Path, workspace: Path, xsa: Path, stage_id: str,
    vitis_version: str | None = None,
) -> dict[str, Any]:
    """Build one configured platform, then patch FatFs and rebuild only xilffs."""
    xsa = xsa.expanduser().resolve()
    if not xsa.is_file() or xsa.stat().st_size == 0:
        raise VitisStageError(f"Required hardware XSA is missing or empty: {xsa}")
    workspace = workspace.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)

    reusable = _find_reusable_platform(workspace, xsa, vitis_version)
    if reusable is not None:
        stage_root, cfg, evidence, vitis_log = reusable
        component = str(cfg["name"])
        component_root = Path(cfg["component_root"]).resolve()
        xpfm = Path(cfg["xpfm"]).resolve()
        domain_root = Path(cfg["domain_root"]).resolve()
        payload: dict[str, Any] = {
            "build_status": "SUCCESS", "build_return": 0,
            "evidence": evidence, "log_path": str(vitis_log.resolve()),
            "reused_existing_platform": True,
        }
        print(f"[FLOW-PLATFORM-RESUME] reuse XPFM/BSP generated for this XSA: {xpfm}")
    else:
        stage_root = _stage_root(workspace, "platform", stage_id)
        vitis_workspace = _vitis_workspace(stage_root)
        component = f"zynq_gba_platform_{stage_id[:12]}"
        component_root = vitis_workspace / component
        xpfm = component_root / "export" / component / f"{component}.xpfm"
        fsbl_glob = component_root / "**" / "fsbl.elf"
        domain_root = component_root / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"
        config_path = stage_root / "platform-input.json"
        config = {
            "workspace": str(vitis_workspace),
            "name": component,
            "component_root": str(component_root),
            "xsa": str(xsa),
            "xsa_sha256": sha256_file(xsa),
            "cpu": "ps7_cortexa9_0",
            "os": "freertos",
            "domain": "freertos_ps7_cortexa9_0",
            "xpfm": str(xpfm),
            "domain_root": str(domain_root),
            "freertos_total_heap_size": FREERTOS_TOTAL_HEAP_SIZE,
            "fatfs_script": str(
                Path(__file__).resolve().parents[2] / "scripts" / "vitis" / "fatfs" / "configure_utf8_lfn.py"
            ),
            "python": sys.executable,
            "fsbl_glob": str(fsbl_glob),
            "vitis_bin": str(vitis_bin.expanduser().resolve()),
        }
        config_path.write_text(json.dumps(config, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        body = [
            "import glob, json, os, time, vitis",
            f"cfg = json.loads(open({_python_literal(str(config_path))}, encoding='utf-8').read())",
            "def build_succeeded(value):",
            "    return value is True or (type(value) is int and value == 0)",
            "def platform_evidence():",
            "    marker = os.path.join(cfg['component_root'], 'export', '.buildstatus')",
            "    marker_text = open(marker, encoding='utf-8').read() if os.path.isfile(marker) else ''",
            "    xpfm_ok = os.path.isfile(cfg['xpfm']) and os.path.getsize(cfg['xpfm']) > 0",
            "    config_path = os.path.join(cfg['domain_root'], 'bsp', 'include', 'FreeRTOSConfig.h')",
            "    config_text = open(config_path, encoding='utf-8').read() if os.path.isfile(config_path) else ''",
            "    heap_size = None",
            "    for line in config_text.splitlines():",
            "        if line.lstrip().startswith('#define') and 'configTOTAL_HEAP_SIZE' in line:",
            "            try: heap_size = int(line.rsplit(')', 2)[-2].strip())",
            "            except (ValueError, IndexError): pass",
            "    fsbls = sorted(path for path in glob.glob(cfg['fsbl_glob'], recursive=True)",
            "                   if os.path.isfile(path) and os.path.getsize(path) > 0)",
            "    return {'export_status': marker_text, 'xpfm_ok': xpfm_ok, 'fsbls': fsbls,",
            "            'freertos_heap_size_bytes': heap_size}",
            "def wait_for_platform_evidence(timeout=45):",
            "    deadline = time.monotonic() + timeout",
            "    evidence = platform_evidence()",
            "    while not ('export=SUCCESS' in evidence['export_status'] and evidence['xpfm_ok']",
            "               and evidence['fsbls'] and evidence['freertos_heap_size_bytes'] == cfg['freertos_total_heap_size']):",
            "        if time.monotonic() >= deadline: return evidence",
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
            "    heap_config = domain.set_config(option='os', param='freertos_total_heap_size',",
            "                                    value=str(cfg['freertos_total_heap_size']))",
            "    lfn_config = domain.set_config(option='lib', param='XILFFS_use_lfn',",
            "                                   value='2', lib_name='xilffs')",
            "    build_rc = platform.build()",
            "    evidence = wait_for_platform_evidence()",
            "    final_ok = (build_succeeded(build_rc)",
            "                and 'export=SUCCESS' in evidence['export_status'] and evidence['xpfm_ok']",
            "                and bool(evidence['fsbls'])",
            "                and evidence['freertos_heap_size_bytes'] == cfg['freertos_total_heap_size'])",
            "    print('ROSS_VITIS_RESULT=' + json.dumps({",
            "        'build_status': 'SUCCESS' if final_ok else 'FAILURE',",
            "        'build_return': build_rc, 'configuration_return_values': [heap_config, lfn_config],",
            "        'evidence': evidence, 'component': cfg['name'],",
            "        'xpfm': cfg['xpfm'], 'fsbl_glob': cfg['fsbl_glob']}))",
            "finally:",
            "    vitis.dispose()",
        ]
        payload = _run_vitis_script(vitis_bin, stage_root, body)
        _success_result(payload, "platform")
        if not _vitis_build_return_succeeded(payload.get("build_return")):
            raise VitisStageError(f"Configured platform.build() returned failure: {payload.get('build_return')!r}")
        if not _platform_evidence_succeeded(payload.get("evidence")):
            raise VitisStageError("Single configured platform build lacks .xpfm/FSBL/export or heap evidence.")
        cfg = config
        evidence = payload["evidence"]

    platform_sw, fatfs_log, xilffs_archive = _configure_fatfs_and_build_xilffs(
        component_root, cfg, stage_root
    )
    fsbl_candidates = sorted(
        path for path in component_root.rglob("fsbl.elf")
        if path.is_file() and path.stat().st_size > 0
    )
    if not fsbl_candidates:
        raise VitisStageError(f"Built platform has no FSBL ELF: {component_root}")
    fsbl = max(fsbl_candidates, key=lambda path: path.stat().st_size)
    ps_init_candidates = sorted(
        path for path in component_root.rglob("ps7_init.tcl")
        if path.is_file() and path.stat().st_size > 0
    )
    exported_ps_init = [path for path in ps_init_candidates if "/export/" in path.as_posix()]
    if exported_ps_init:
        ps_init_candidates = exported_ps_init
    if not ps_init_candidates:
        raise VitisStageError(f"Built platform has no ps7_init.tcl: {component_root}")
    ps_init = ps_init_candidates[0]
    artifacts = {
        "xpfm": _file_artifact("built .xpfm", xpfm),
        "fsbl_elf": _file_artifact("FSBL ELF", fsbl),
        "ps7_init_tcl": _file_artifact("PS7 initialization Tcl", ps_init),
        "fatfs_xilffs_log": _file_artifact("FatFs/xilffs configuration log", fatfs_log),
    }
    vitis_log = Path(str(payload.get("log_path", "")))
    if vitis_log.is_file() and vitis_log.stat().st_size > 0:
        artifacts["vitis_log"] = _file_artifact("Vitis platform log", vitis_log)
    return {
        "build_status": "SUCCESS",
        "artifacts": artifacts,
        "command": (
            [str(vitis_bin.expanduser().resolve()), "-s",
             str((vitis_log.parent / "stage.py").resolve())]
            if vitis_log.is_file() else []
        ),
        "platform_build_mode": "resumed-existing" if payload.get("reused_existing_platform") else "full",
        "component_name": component,
        "domain": "freertos_ps7_cortexa9_0",
        "bsp_domain_root": str(domain_root),
        "platform_sw_path": str(platform_sw),
        "freertos_heap_size_bytes": FREERTOS_TOTAL_HEAP_SIZE,
        "hardware_xsa_sha256": sha256_file(xsa),
        "xilffs_archive_sha256": sha256_file(xilffs_archive),
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


def _sync_app_tree(source: Path, destination: Path) -> None:
    """Sync staged source by content so unchanged files keep their compile timestamps."""
    source = source.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    expected: set[str] = set()
    for path in sorted(source.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(source).as_posix()
        expected.add(relative)
        target = destination / relative
        if target.is_file() and sha256_file(target) == sha256_file(path):
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        os.utime(target, None)
    for path in sorted(destination.rglob("*"), reverse=True):
        if path.is_file() and path.relative_to(destination).as_posix() not in expected:
            path.unlink()
        elif path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass


def _run_logged(
    command: list[str], cwd: Path, env: dict[str, str], log_path: Path, timeout: int = 3600
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command, cwd=cwd, env=env, text=True, capture_output=True,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        stdout = getattr(exc, "stdout", "") or ""
        stderr = getattr(exc, "stderr", "") or ""
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(f"COMMAND: {command!r}\nEXCEPTION: {exc}\n{stdout}\n{stderr}",
                            encoding="utf-8")
        raise VitisStageError(f"Application command failed; see {log_path}: {exc}") from exc
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(
        f"COMMAND: {command!r}\nEXIT_CODE: {result.returncode}\n"
        f"{result.stdout or ''}\n{result.stderr or ''}",
        encoding="utf-8",
    )
    return result


def run_app_stage(
    vitis_bin: Path,
    workspace: Path,
    xpfm: Path,
    app_source: Path,
    app_template: str,
    app_domain: str,
    stage_id: str,
) -> dict[str, Any]:
    """Incrementally build the PS app from a stable source/build directory for this XSA."""
    xpfm = xpfm.expanduser().resolve()
    if not xpfm.is_file() or xpfm.stat().st_size == 0:
        raise VitisStageError(f"Built platform .xpfm is missing: {xpfm}")
    if not app_template or not app_domain:
        raise VitisStageError("Application template and platform domain are required.")

    component_root = xpfm.parents[2]
    workspace = workspace.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    toolchain_files = sorted(component_root.rglob("cortexa9_toolchain.cmake"))
    exported = [path for path in toolchain_files if "/export/" in path.as_posix()]
    if exported:
        platform_sw = exported[0].parent
    elif toolchain_files:
        platform_sw = toolchain_files[0].parent
    else:
        raise VitisStageError(f"Generated FreeRTOS toolchain was not found under {component_root}")
    domain_root = component_root / "ps7_cortexa9_0" / app_domain
    if not (platform_sw / "include" / "xparameters.h").is_file():
        raise VitisStageError(f"Generated platform headers are missing: {platform_sw}")
    if not (platform_sw / "lib" / "libxilffs.a").is_file():
        raise VitisStageError(f"Generated xilffs library is missing: {platform_sw}")
    if not (domain_root / "bsp" / "libsrc" / "build_configs" / "gen_bsp" / "build.ninja").is_file():
        raise VitisStageError(f"Generated FreeRTOS BSP tree is missing: {domain_root}")

    repo_root = Path(__file__).resolve().parents[2]
    platform_key = sha256_file(xpfm)[:16]
    source_root = workspace / "app-source" / platform_key
    staging_root = workspace / "app-source-staging" / f"{platform_key}-{__import__('uuid').uuid4().hex[:8]}"
    build_root = workspace / "app-build" / platform_key
    logs_root = build_root / "logs"
    staging_root.mkdir(parents=True, exist_ok=False)
    try:
        _copy_app_source(app_source, staging_root)
        _sync_app_tree(staging_root, source_root)
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)

    config_check = subprocess.run(
        [sys.executable, str(repo_root / "scripts" / "fatfs" / "configure_utf8_lfn.py"),
         "--check", "--bsp-root", str(domain_root)],
        cwd=repo_root, text=True, capture_output=True, check=False,
    )
    if config_check.returncode:
        raise VitisStageError(
            f"Generated FatFs BSP is not UTF-8/LFN=2 configured: "
            f"{config_check.stdout}{config_check.stderr}"
        )

    vitis_root = vitis_bin.expanduser().resolve().parent.parent
    ninja = vitis_root / "bin" / "ninja"
    cmake = os.environ.get("CMAKE_BIN")
    if not cmake:
        cmake = "/usr/bin/cmake" if Path("/usr/bin/cmake").is_file() else shutil.which("cmake")
    if not cmake or not ninja.is_file():
        raise VitisStageError(f"CMake or Vitis Ninja is missing (cmake={cmake}, ninja={ninja})")
    compiler_dir = vitis_root / "gnu" / "aarch32" / "lin" / "gcc-arm-none-eabi" / "bin"
    compiler = compiler_dir / "arm-none-eabi-gcc"
    if not compiler.is_file():
        raise VitisStageError(f"ARM GCC is missing: {compiler}")
    build_root.mkdir(parents=True, exist_ok=True)
    logs_root.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["VITIS_ROOT"] = str(vitis_root)
    env["ESW_REPO"] = os.environ.get("ESW_REPO", str(vitis_root / "data" / "embeddedsw"))
    env["PS_APP_PROJECT_ROOT"] = str(repo_root)
    env["PS_APP_SOURCE_TREE_MODE"] = "1"
    env["PS_APP_PLATFORM_SW_DIR"] = str(platform_sw)
    env["PS_APP_PLATFORM_DOMAIN_DIR"] = str(domain_root)
    env["PATH"] = os.pathsep.join(
        [str(vitis_root / "bin"), str(compiler_dir), env.get("PATH", "")]
    )
    library_paths = [str(vitis_root / "lib" / "lnx64.o"),
                     str(vitis_root / "aietools" / "lib" / "lnx64.o")]
    if env.get("LD_LIBRARY_PATH"):
        library_paths.append(env["LD_LIBRARY_PATH"])
    env["LD_LIBRARY_PATH"] = os.pathsep.join(library_paths)

    specs_file = Path(env["ESW_REPO"]) / "scripts" / "specs" / "arm" / "Xilinx.spec"
    cmake_cache = build_root / "CMakeCache.txt"
    if cmake_cache.is_file():
        cache_text = cmake_cache.read_text(encoding="utf-8", errors="replace")
        stale_specs = "-specs=/scripts/specs/arm/Xilinx.spec" in cache_text
        if stale_specs:
            try:
                build_root.resolve().relative_to((workspace / "app-build").resolve())
            except ValueError as exc:
                raise VitisStageError(f"Refusing to reset app cache outside build/vitis/app-build: {build_root}") from exc
            shutil.rmtree(build_root)
            build_root.mkdir(parents=True, exist_ok=True)
            logs_root.mkdir(parents=True, exist_ok=True)

    configure_command = [
        cmake, "-S", str(source_root), "-B", str(build_root), "-G", "Ninja",
        f"-DCMAKE_TOOLCHAIN_FILE={platform_sw / 'cortexa9_toolchain.cmake'}",
        f"-DCMAKE_MODULE_PATH={platform_sw}",
        f"-DCMAKE_INCLUDE_PATH={platform_sw / 'include'}",
        f"-DCMAKE_LIBRARY_PATH={platform_sw / 'lib'}",
        f"-DCMAKE_SPECS_FILE={Path(env['ESW_REPO']) / 'scripts' / 'specs' / 'arm' / 'Xilinx.spec'}",
        f"-DCMAKE_MAKE_PROGRAM={ninja}",
    ]
    configure_log = logs_root / "cmake-configure.log"
    configured = _run_logged(configure_command, workspace, env, configure_log)
    if configured.returncode:
        raise VitisStageError(f"CMake configuration failed; see {configure_log}")
    configured_cache = (build_root / "CMakeCache.txt").read_text(encoding="utf-8", errors="replace")
    if f"-specs={specs_file}" not in configured_cache:
        raise VitisStageError(
            f"CMake did not resolve the Vitis ARM specs file {specs_file}; see {configure_log}"
        )

    jobs = max(1, min(8, int(os.environ.get("VITIS_BUILD_JOBS", "8"))))
    build_command = [cmake, "--build", str(build_root), "--target", "app.elf",
                     "--parallel", str(jobs)]
    build_log = logs_root / "app-build.log"
    built = _run_logged(build_command, workspace, env, build_log)
    elf = build_root / "app.elf"
    if built.returncode or not elf.is_file() or elf.stat().st_size == 0:
        raise VitisStageError(f"Incremental CMake/Ninja app build failed; see {build_log}")

    return {
        "build_status": "SUCCESS",
        "artifacts": {
            "app_elf": _file_artifact("application ELF", elf),
            "app_build_log": _file_artifact("application build log", build_log),
            "cmake_configure_log": _file_artifact("CMake configure log", configure_log),
        },
        "commands": [configure_command, build_command],
        "platform_xpfm_sha256": sha256_file(xpfm),
        "platform_sw_path": str(platform_sw),
        "domain_root": str(domain_root),
        "source_path": str(source_root),
        "build_path": str(build_root),
        "build_mode": "incremental-capable",
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
            "bootgen_log": _file_artifact("Bootgen log", log_path),
        },
        "commands": [
            [str(bootgen_bin), "-arch", "zynq", "-image", str(bif),
             "-o", str(boot_bin), "-w", "on", "-log", "error"],
            [str(bootgen_bin), "-arch", "zynq", "-read", str(boot_bin)],
        ],
        "input_sha256": {name: sha256_file(path) for name, path in inputs.items()},
        "log_path": str(log_path),
        "command_output_summary": (readback.stdout or result.stdout or "")[-4000:],
    }

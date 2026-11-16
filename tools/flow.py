#!/usr/bin/env python3
"""Portable standard-library FPGA build flow."""
from __future__ import annotations
import argparse
import ast
import copy
import fnmatch
from datetime import datetime, timezone
import hashlib, json, os, re, shlex, shutil, subprocess, sys, uuid
from pathlib import Path
from typing import Callable, Iterable, Mapping

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
OUT_ROOT = ROOT / "out"
MANIFEST_PATH = OUT_ROOT / "flow" / "manifest.json"
SCHEMA_VERSION = 2
REQUIRED_PYTHON_VERSION = (3, 15)
REQUIRED_VIVADO_VERSION = "2025.2.1"
REQUIRED_VITIS_VERSION = "2025.2.1"
PINNED_DIGILENT_COMMIT = "f4613fff005b098065fd5d619a2b88e55720a423"
CONTRACT_PATH = ROOT / "config/ps_pl_contract.json"
CONTRACT_GENERATOR = ROOT / "tools/generate_hw_contract.py"
APP_YAML = ROOT / "src/ps/app/src/app.yaml"
CANONICAL_BUILD_SCRIPTS = ("scripts/build/bd_ip_maintenance.tcl", "scripts/build/embedded_video_ip_bd.tcl", "scripts/build/rebuild_project.tcl", "scripts/build/build_bitstream.tcl")
EXCLUDED_SOURCE_DIRS = {"src/ps/platform", "src/ps/app/build", "src/ps/app/src/build"}
PROJECT_NAME = "Zynq-GBA_MisTer-Vivado"
PROJECT_REL = Path("out/vivado") / f"{PROJECT_NAME}.xpr"
LOCAL_BD_REL = Path("out/vivado") / f"{PROJECT_NAME}.srcs/sources_1/bd/zynq_gba_system/zynq_gba_system.bd"
PROJECT_WORK_DIR = Path("out/vivado/project")
SIM_PROJECT_REL = PROJECT_WORK_DIR / f"{PROJECT_NAME}.xpr"
SIM_LOCAL_BD_REL = PROJECT_WORK_DIR / f"{PROJECT_NAME}.srcs/sources_1/bd/zynq_gba_system/zynq_gba_system.bd"
BITSTREAM_REL = Path("out/vivado") / f"{PROJECT_NAME}.runs/impl_1/zynq_gba_system_wrapper.bit"
ROUTED_DCP_REL = Path("out/vivado") / f"{PROJECT_NAME}.runs/impl_1/zynq_gba_system_wrapper_routed.dcp"
TIMING_SUMMARY_REL = Path("out/vivado/reports/timing_summary.rpt")
DRC_REPORT_REL = Path("out/vivado/reports/drc.rpt")
QOR_GATE_REL = Path("out/vivado/reports/qor_gate.tsv")
XSA_REL = Path("out/vivado/zynq_gba_system_wrapper.xsa")
ACTION_OUTPUTS = {
    "project": (SIM_PROJECT_REL, SIM_LOCAL_BD_REL),
    "build": (PROJECT_REL, LOCAL_BD_REL, BITSTREAM_REL, ROUTED_DCP_REL, TIMING_SUMMARY_REL, DRC_REPORT_REL, QOR_GATE_REL, XSA_REL),
}
ACTION_TCL = {"project": "scripts/build/rebuild_project.tcl", "build": "scripts/build/build_bitstream.tcl"}
SIM_SUITE_PATTERNS: dict[str, tuple[str, ...]] = {
    "smoke": ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv", "tb_gba_pcm_audio_axis.sv"),
    "memory": ("tb_cache_dword_timing.vhd", "tb_comprehensive_ddr.vhd", "tb_ddram_mux_epoch_fairness.sv", "tb_ddram_mux_burst_boundary.sv", "tb_ddr_axi_backend_fault_drain.sv", "tb_sync_ram_dual_collision.vhd"),
    "cpu": ("tb_cpu_anwj_step.vhd", "tb_memorymux_anwj_fetch.vhd"),
    "system": ("tb_frame_capture_descriptor.sv", "tb_gba_top_full.vhd"),
}
HOST_TESTS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("console-line-utf8", "tests/ps/test_console_line_utf8.c", ("src/ps/app/src/App/Src/ps_app_console_line.c",)),
    ("runtime-command-logic", "tests/ps/test_runtime_command_logic.c", ("src/ps/app/src/App/Src/ps_app_runtime_command_logic.c",)),
    ("xinput-parser", "tests/ps/test_xinput_parser.c", ("src/ps/app/src/Input/Src/ps_xinput_xbox360.c", "src/ps/app/src/Input/Drivers/ps_app_input_profile.c")),
    ("gba-regs-mailbox-timeout", "tests/ps/test_gba_regs_mailbox_timeout.c", ("src/ps/app/src/Gba/Src/ps_gba_regs.c",)),
    ("time-storage-save", "tests/ps/test_time_and_storage_txn.c", ("src/ps/app/src/Common/Src/ps_app_time_math.c", "src/ps/app/src/Storage/Src/ps_fatfs_txn.c", "src/ps/app/src/Save/Src/ps_app_save_logic.c")),
    ("input-driver-registry", "tests/ps/test_input_driver_registry.c", ("src/ps/app/src/Input/Drivers/ps_app_input_driver.c", "src/ps/app/src/Input/Src/ps_xinput_xbox360.c", "src/ps/app/src/Input/Drivers/ps_app_input_profile.c")),
    ("rom-load-progress", "tests/ps/test_rom_load_progress.c", ("src/ps/app/src/Common/Src/ps_app_rom_load_progress.c", "src/ps/app/src/Common/Src/ps_app_ui_launch_logic.c")),
    ("audio-route-logic", "tests/ps/test_audio_route_logic.c", ("src/ps/app/src/Common/Src/ps_app_audio_route_logic.c",)),
)
HOST_TEST_HEADERS: dict[str, tuple[str, ...]] = {
    "audio-route-logic": ("src/ps/app/src/Common/Inc/ps_app_audio_route_logic.h",),
    "console-line-utf8": ("src/ps/app/src/App/Inc/ps_app_console_line.h",),
    "rom-load-progress": (
        "src/ps/app/src/Common/Inc/ps_app_rom_load_progress.h",
        "src/ps/app/src/Common/Inc/ps_app_ui_launch_logic.h",
        "src/ps/app/src/Common/Inc/ps_app_state.h",
        "src/ps/app/src/Common/Inc/ps_project_config.h",
    ),
}
HOST_CFLAGS = ("-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic")
LVGL_VENDOR_REL = Path("src/ps/app/src/ThirdParty/lvgl")
LVGL_RUNTIME_TEST_REL = "tests/ps/test_lvgl96_runtime.c"
LVGL_FONT_SOURCE_REL = "src/ps/app/src/Ui/Assets/Fonts/ps_ui_font_fusion_12.c"
LVGL_RUNTIME_SOURCES = tuple(
    path.relative_to(ROOT).as_posix()
    for path in sorted((ROOT / LVGL_VENDOR_REL / "src").rglob("*.c"))
)
HOST_TESTS = (*HOST_TESTS, (
    "lvgl96-runtime",
    LVGL_RUNTIME_TEST_REL,
    (*LVGL_RUNTIME_SOURCES, LVGL_FONT_SOURCE_REL),
))

class FlowError(Exception):
    """Expected user-facing error with stable code."""
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def digest_json(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()


def relative_name(path: Path, root: Path = ROOT) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as exc:
        raise FlowError("FLOW-PATH-OUTSIDE-ROOT", f"Path outside project root: {path}") from exc


def safe_out_path(path_text: str, root: Path = ROOT) -> Path:
    rel = Path(path_text)
    if rel.is_absolute() or ".." in rel.parts or not rel.parts or rel.parts[0] != "out":
        raise FlowError("FLOW-MANIFEST-PATH", f"Artifact outside out/: {path_text}")
    return root / rel


def iter_source_files(root: Path = ROOT) -> Iterable[Path]:
    files: list[Path] = []
    for scan_root in (root / "src", root / "third_party", root / "tests/rtl"):
        if not scan_root.is_dir():
            if scan_root.name == "src":
                raise FlowError("FLOW-SOURCE-MISSING", f"Source missing: {scan_root}")
            continue
        for current, directories, names in os.walk(scan_root, followlinks=False):
            current_path = Path(current)
            rel_dir = current_path.relative_to(root).as_posix()
            directories[:] = sorted(n for n in directories if not (current_path / n).is_symlink() and f"{rel_dir}/{n}" not in EXCLUDED_SOURCE_DIRS and n not in {".cache", "_ide", "build", "__pycache__"})
            for name in names:
                path = current_path / name
                if path.is_file() and not path.is_symlink():
                    files.append(path)
    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def build_input_paths(root: Path = ROOT) -> list[Path]:
    paths = list(iter_source_files(root))
    extras = [root / "config/ps_pl_contract.json", root / "tools/generate_hw_contract.py", root / "tools/flow.py", *(root / rel for rel in CANONICAL_BUILD_SCRIPTS)]
    if (root / "tools/vitis_stages.py").is_file():
        extras.append(root / "tools/vitis_stages.py")
    for path in extras:
        if not path.is_file():
            raise FlowError("FLOW-INPUT-MISSING", f"Missing required input: {path}")
        paths.append(path)
    return sorted(set(paths), key=lambda p: p.relative_to(root).as_posix())



_HARDWARE_SOURCE_PREFIXES = ("src/bd/", "src/constraints/", "src/rtl/", "third_party/digilent-vivado-library/")
_VIVADO_COMMON_INPUT_FILES = (
    "src/dfx_runtime.txt", "config/ps_pl_contract.json", "tools/generate_hw_contract.py",
    "tools/flow.py", "scripts/build/bd_ip_maintenance.tcl",
    "scripts/build/embedded_video_ip_bd.tcl", "scripts/build/embedded_video_ip_consumer.tcl",
)
_HARDWARE_INPUT_FILES = (
    *_VIVADO_COMMON_INPUT_FILES,
    "scripts/build/incremental_build_cache.py", "scripts/build/build_bitstream.tcl",
)
_PROJECT_INPUT_FILES = (
    *_VIVADO_COMMON_INPUT_FILES,
    "scripts/build/rebuild_project.tcl",
)
_PLATFORM_INPUT_FILES = ("scripts/fatfs/configure_utf8_lfn.py",)
_APP_INPUT_FILES = ("scripts/build/embedded_video_ip_consumer.tcl", "scripts/fatfs/configure_utf8_lfn.py")
_BOOT_INPUT_FILES: tuple[str, ...] = ()
_APP_SOURCE_PREFIXES = ("src/ps/app/src/",)
_VITIS_COMMON_INPUT_FILES = ("scripts/fatfs/configure_utf8_lfn.py",)


def stage_input_paths(root: Path = ROOT, stage: str = "hardware") -> list[Path]:
    """Select only inputs that can affect one independently reproducible build stage."""
    stage_key = stage.split(":", 1)[0]
    if stage_key == "build":
        stage_key = "hardware"
    if stage_key not in {"hardware", "project", "sim", "platform", "app", "boot"}:
        raise FlowError("FLOW-STAGE-INPUTS", f"Unknown build stage {stage!r}.")
    files = list(iter_source_files(root))
    selected: list[Path] = []
    if stage_key in {"hardware", "project", "sim"}:
        selected.extend(path for path in files if path.relative_to(root).as_posix().startswith(_HARDWARE_SOURCE_PREFIXES))
        stage_files = _HARDWARE_INPUT_FILES if stage_key == "hardware" else _PROJECT_INPUT_FILES
        selected.extend(root / rel for rel in stage_files if (root / rel).is_file())
        if stage_key == "sim":
            selected.extend(path for path in files if path.relative_to(root).as_posix().startswith("tests/rtl/"))
    elif stage_key == "platform":
        selected.extend(root / rel for rel in _PLATFORM_INPUT_FILES if (root / rel).is_file())
        selected.extend(root / rel for rel in _VITIS_COMMON_INPUT_FILES if (root / rel).is_file())
    elif stage_key == "app":
        generated_app_metadata = {
            "src/ps/app/src/compile_commands.json",
            "src/ps/app/src/.clangd",
            "src/ps/app/src/ThirdParty/lvgl/LVGL_SOURCE_LOCK.json",
        }
        selected.extend(
            path for path in files
            if path.relative_to(root).as_posix().startswith(_APP_SOURCE_PREFIXES)
            and path.relative_to(root).as_posix() not in generated_app_metadata
        )
        selected.extend(root / rel for rel in _APP_INPUT_FILES if (root / rel).is_file())
    else:
        selected.extend(root / rel for rel in _BOOT_INPUT_FILES if (root / rel).is_file())
    return sorted(set(selected), key=lambda path: path.relative_to(root).as_posix())


def _legacy_platform_patch_was_verified(record: Mapping[str, object], name: str, root: Path) -> bool:
    if (
        record.get("input_partition_version") is not None
        or record.get("stage") != "platform"
        or name != "scripts/fatfs/configure_utf8_lfn.py"
    ):
        return False
    summary = str(record.get("command_output_summary", ""))
    if not re.search(r'"fatfs_check_return_code"\s*:\s*0', summary):
        return False
    if "[fatfs-utf8-lfn] verified: FF_USE_LFN=2 FF_LFN_UNICODE=2 FF_CODE_PAGE=437" not in summary:
        return False
    try:
        completed = datetime.fromisoformat(str(record["completed_at_utc"]).replace("Z", "+00:00")).timestamp()
        modified = (root / name).stat().st_mtime
    except (KeyError, OSError, ValueError):
        return False
    return modified <= completed


def _record_inputs_match(
    record: Mapping[str, object], current_inputs: Mapping[str, str], root: Path = ROOT
) -> bool:
    """Only exact content-hash manifests are eligible for reuse."""
    old_inputs = record.get("input_files")
    return (
        record.get("input_fingerprint_type") == "sha256-v1"
        and isinstance(old_inputs, dict)
        and bool(current_inputs)
        and old_inputs == dict(current_inputs)
    )


def vivado_input_hash(
    action: str,
    inputs: Mapping[str, str],
    version: str,
    jobs: int | None,
    contract: Mapping[str, str],
    ip: Mapping[str, object],
) -> str:
    return digest_json({
        "schema_version": SCHEMA_VERSION,
        "action": action,
        "vivado": version,
        "jobs": jobs,
        "inputs": inputs,
        "contract": contract,
        "ip": ip,
        "toolchain": [REQUIRED_VIVADO_VERSION, REQUIRED_VITIS_VERSION],
        "python": ".".join(map(str, sys.version_info[:3])),
    })


def hardware_identity_sha256(
    inputs: Mapping[str, str], version: str, jobs: int | None,
    contract: Mapping[str, str], ip: Mapping[str, object],
) -> str:
    stable_inputs = {
        name: digest for name, digest in inputs.items()
        if not name.startswith("src/rtl/")
    }
    return digest_json({
        "schema_version": SCHEMA_VERSION,
        "vivado": version,
        "jobs": jobs,
        "contract": contract,
        "ip": ip,
        "toolchain": [REQUIRED_VIVADO_VERSION, REQUIRED_VITIS_VERSION],
        "python": ".".join(map(str, sys.version_info[:3])),
        "non_rtl_inputs": stable_inputs,
    })


def compatible_incremental_dcp(
    manifest: Mapping[str, object], identity_sha256: str, root: Path = ROOT,
) -> Path | None:
    cache = manifest.get("hardware_cache")
    if not isinstance(cache, dict) or cache.get("identity_sha256") != identity_sha256:
        return None
    relative, expected = cache.get("routed_dcp"), cache.get("routed_dcp_sha256")
    if not isinstance(relative, str) or not isinstance(expected, str):
        return None
    try:
        path = safe_out_path(relative, root)
    except FlowError:
        return None
    if not path.is_file() or sha256_file(path) != expected:
        return None
    return path


def resumable_partial_vivado_build(
    record: object, current_inputs: Mapping[str, str], version: str,
    contract: Mapping[str, str], ip: Mapping[str, object],
    jobs: int | None, root: Path = ROOT,
) -> bool:
    if not isinstance(record, dict) or record.get("status") != "failed":
        return False
    if record.get("error_code") != "FLOW-VIVADO-FAILED":
        return False
    if (
        record.get("vivado_version") != version
        or record.get("hardware_contract") != contract
        or record.get("vendored_ip") != ip
        or record.get("jobs") != jobs
        or record.get("input_fingerprint_type") != "sha256-v1"
    ):
        return False
    previous_inputs = record.get("input_files")
    if not isinstance(previous_inputs, dict) or set(previous_inputs) != set(current_inputs):
        return False
    changed = {
        name for name in current_inputs
        if previous_inputs.get(name) != current_inputs[name]
    }
    if not changed.issubset({"scripts/build/build_bitstream.tcl", "tools/flow.py"}):
        return False
    if (
        record.get("input_sha256")
        != vivado_input_hash("build", previous_inputs, version, jobs, contract, ip)
        or record.get("source_sha256") != source_digest(previous_inputs)
    ):
        return False
    required_paths = (
        PROJECT_REL, LOCAL_BD_REL, BITSTREAM_REL, ROUTED_DCP_REL,
        TIMING_SUMMARY_REL, DRC_REPORT_REL,
    )
    if not all((root / rel).is_file() and (root / rel).stat().st_size > 0 for rel in required_paths):
        return False
    synth_log = root / Path("out/vivado") / f"{PROJECT_NAME}.runs/synth_1/runme.log"
    impl_log = root / Path("out/vivado") / f"{PROJECT_NAME}.runs/impl_1/runme.log"
    try:
        synth_ok = "synth_design completed successfully" in synth_log.read_text(
            encoding="utf-8", errors="replace"
        )
        impl_ok = "write_bitstream completed successfully" in impl_log.read_text(
            encoding="utf-8", errors="replace"
        )
    except OSError:
        return False
    return synth_ok and impl_ok


def archive_previous_failure(runs: dict[str, object], key: str) -> None:
    previous = runs.get(key)
    if not isinstance(previous, dict) or previous.get("status") != "failed":
        return
    signature = digest_json({
        "input": previous.get("input_sha256"),
        "completed": previous.get("completed_at_utc"),
        "error": previous.get("error_code"),
    })[:12]
    archive_key = f"{key}:previous-failure:{signature}"
    if archive_key not in runs:
        archived = copy.deepcopy(previous)
        archived["archived_failure"] = True
        archived["archived_at_utc"] = utc_now()
        runs[archive_key] = archived


def _hardware_inputs_match_for_rekey(
    record: Mapping[str, object], current_inputs: Mapping[str, str],
) -> bool:
    old = record.get("input_files")
    if not isinstance(old, dict):
        return False
    # Older hardware manifests included rebuild_project.tcl in the PL
    # fingerprint. That script only creates a disposable simulation project;
    # it does not participate in build_bitstream.tcl or the produced bit/XSA.
    old_hardware_inputs = {
        name: value for name, value in old.items()
        if name != "scripts/build/rebuild_project.tcl"
    }
    if set(old_hardware_inputs) != set(current_inputs):
        return False
    changed = {name for name in current_inputs if old_hardware_inputs.get(name) != current_inputs[name]}
    return changed.issubset({"tools/flow.py"}) and all(
        isinstance(value, str) and len(value) == 64
        for value in old_hardware_inputs.values()
    )


def _rekey_legacy_vivado_record(record: dict[str, object], inputs: Mapping[str, str], input_hash: str,
                                version: str, contract: Mapping[str, str], ip: Mapping[str, object],
                                jobs: int | None, root: Path) -> bool:
    """Re-key a previous whole-tree run only when its PL input subset is unchanged."""
    if (record.get("status") != "succeeded" or record.get("vivado_version") != version
            or record.get("hardware_contract") != contract or record.get("vendored_ip") != ip
            or record.get("jobs") != jobs
            or not _hardware_inputs_match_for_rekey(record, inputs)
            or not check_out_outputs(record, root)):
        return False
    record.update({"input_sha256": input_hash, "source_sha256": source_digest(inputs),
                   "input_files": dict(inputs), "input_partition": record.get("action"),
                   "input_partition_version": 2, "input_fingerprint_type": "sha256-v1",
                   "rekeyed_at_utc": utc_now()})
    return True

def file_manifest(paths: Iterable[Path], root: Path = ROOT) -> dict[str, str]:
    result = {}
    for path in sorted(paths, key=lambda p: p.relative_to(root).as_posix()):
        if not path.is_file():
            raise FlowError("FLOW-INPUT-MISSING", f"Missing input: {path}")
        result[path.relative_to(root).as_posix()] = sha256_file(path)
    return result


def input_sha256_manifest(paths: Iterable[Path], root: Path = ROOT) -> dict[str, str]:
    """Compatibility name for a path-keyed content SHA-256 input manifest."""
    return file_manifest(paths, root)


def _embedded_video_ip_root(root: Path) -> Path:
    configured = os.environ.get("EMBEDDED_VIDEO_IP_REPO")
    return Path(configured).expanduser().resolve() if configured else (root.parent / "EmbeddedVideoIP").resolve()


def _embedded_video_ip_lock(root: Path) -> tuple[Path, str, str] | None:
    consumer = root / "scripts/build/embedded_video_ip_consumer.tcl"
    if not consumer.is_file():
        if root.resolve() != ROOT.resolve():
            return None
        raise FlowError("FLOW-EVIP-LOCK", f"Missing consumer dependency lock: {consumer}")
    source = consumer.read_text(encoding="utf-8")
    version = re.search(r'(?m)^\s*set\s+evip_expected_version\s+"([^"]+)"', source)
    commit = re.search(r'(?m)^\s*set\s+evip_expected_commit\s+"([0-9a-f]{40})"', source)
    if not version or not commit:
        raise FlowError("FLOW-EVIP-LOCK", "Consumer lock must pin EmbeddedVideoIP version and 40-character commit.")
    return _embedded_video_ip_root(root), version.group(1), commit.group(1)


def _embedded_video_ip_docs_only_paths(
    dependency: Path, expected_commit: str, checkout_commit: str,
) -> tuple[str, ...] | None:
    if checkout_commit == expected_commit:
        return ()
    try:
        ancestor = subprocess.run(
            ["git", "-C", str(dependency), "merge-base", "--is-ancestor",
             expected_commit, checkout_commit],
            text=True, capture_output=True, check=False, timeout=15,
        )
        if ancestor.returncode != 0:
            return None
        diff = subprocess.run(
            ["git", "-C", str(dependency), "diff", "--name-only", "-z",
             f"{expected_commit}..{checkout_commit}"],
            text=True, capture_output=True, check=True, timeout=15,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise FlowError("FLOW-EVIP-GIT", f"Cannot compare EmbeddedVideoIP commits: {exc}") from exc
    changed_paths = tuple(name for name in diff.split("\0") if name)
    if all(
        name == "README.md"
        or (name.startswith("docs/") and name.lower().endswith(".md"))
        for name in changed_paths
    ):
        return changed_paths
    return None


def check_embedded_video_ip(root: Path = ROOT) -> dict[str, str]:
    lock = _embedded_video_ip_lock(root)
    if lock is None:
        return {}
    dependency, expected_version, expected_commit = lock
    version_file = dependency / "VERSION"
    if not version_file.is_file():
        raise FlowError("FLOW-EVIP-MISSING", f"EmbeddedVideoIP VERSION is missing: {version_file}")
    version = version_file.read_text(encoding="utf-8").strip()
    try:
        checkout_commit = subprocess.run(
            ["git", "-C", str(dependency), "rev-parse", "HEAD"],
            text=True, capture_output=True, check=True, timeout=15,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(dependency), "status", "--porcelain", "--untracked-files=normal"],
            text=True, capture_output=True, check=True, timeout=15,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        raise FlowError("FLOW-EVIP-GIT", f"Cannot verify EmbeddedVideoIP repository: {exc}") from exc
    if version != expected_version or status:
        raise FlowError(
            "FLOW-EVIP-MISMATCH",
            f"Expected clean EmbeddedVideoIP {expected_version}@{expected_commit}; got {version}@{checkout_commit}"
            + (f"; dirty status: {status[:300]}" if status else ""),
        )
    docs_only_paths = _embedded_video_ip_docs_only_paths(
        dependency, expected_commit, checkout_commit,
    )
    if docs_only_paths is None:
        raise FlowError(
            "FLOW-EVIP-MISMATCH",
            f"EmbeddedVideoIP checkout {checkout_commit} differs from pinned code {expected_commit}; "
            "only a clean descendant that changes README.md or docs/*.md can reuse the pinned hardware inputs.",
        )
    result = {"version": version, "commit": expected_commit}
    if checkout_commit != expected_commit:
        result["checkout_commit"] = checkout_commit
        result["docs_only_paths"] = ",".join(docs_only_paths) if docs_only_paths else "(empty docs-only commit)"
    return result


_VITIS_STAGE_FUNCTIONS = {
    "platform": (
        "sha256_file", "_file_artifact", "_python_literal", "_stage_root",
        "_vitis_workspace", "_run_vitis_script", "_success_result",
        "_vitis_build_return_succeeded", "_platform_evidence_succeeded",
        "_platform_component_software", "_platform_disk_evidence",
        "_find_reusable_platform", "_copy_if_changed",
        "_configure_fatfs_and_build_xilffs", "run_platform_stage",
    ),
    "app": (
        "VitisStageError", "sha256_file", "_file_artifact", "_platform_workspace_for_xpfm",
        "_copy_app_source", "_sync_app_tree", "_run_logged", "run_app_stage",
    ),
    "boot": ("VitisStageError", "sha256_file", "_file_artifact", "run_boot_stage"),
}


def vitis_stage_code_sha256(root: Path, stage: str) -> str:
    source_path = root / "tools/vitis_stages.py"
    if not source_path.is_file():
        return ""
    try:
        source = source_path.read_text(encoding="utf-8")
        tree = ast.parse(source)
    except (OSError, SyntaxError) as exc:
        raise FlowError("FLOW-VITIS-CODE", f"Cannot parse Vitis stage source {source_path}: {exc}") from exc
    selected_names = set(_VITIS_STAGE_FUNCTIONS[stage])
    selected_nodes = []
    found = set()
    referenced_names = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in selected_names:
            selected_nodes.append(node)
            found.add(node.name)
            referenced_names.update(child.id for child in ast.walk(node) if isinstance(child, ast.Name))
        elif isinstance(node, ast.ClassDef) and node.name == "VitisStageError":
            selected_nodes.append(node)
            found.add(node.name)
            referenced_names.update(child.id for child in ast.walk(node) if isinstance(child, ast.Name))
        elif stage == "platform" and isinstance(node, ast.Assign):
            assigned = {target.id for target in node.targets if isinstance(target, ast.Name)}
            if "FREERTOS_TOTAL_HEAP_SIZE" in assigned:
                selected_nodes.append(node)
                found.update(assigned)
                referenced_names.update(child.id for child in ast.walk(node) if isinstance(child, ast.Name))
    missing = selected_names - found
    if missing:
        raise FlowError("FLOW-VITIS-CODE", f"Vitis stage source lacks {stage} functions: {sorted(missing)}")
    import_nodes = []
    for node in tree.body:
        if isinstance(node, ast.Import):
            names = {alias.asname or alias.name.split(".")[0] for alias in node.names}
            if names & referenced_names:
                import_nodes.append(node)
        elif isinstance(node, ast.ImportFrom):
            names = {alias.asname or alias.name for alias in node.names}
            if node.module == "__future__" or names & referenced_names:
                import_nodes.append(node)
    segments = [ast.get_source_segment(source, node) or "" for node in import_nodes + selected_nodes]
    payload = "\\n".join(segments).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def stage_input_manifest(root: Path = ROOT, stage: str = "hardware") -> dict[str, str]:
    """Hash local build inputs plus the exact private dependency content used by a stage."""
    inputs = file_manifest(stage_input_paths(root, stage), root)
    stage_key = stage.split(":", 1)[0]
    if stage_key in _VITIS_STAGE_FUNCTIONS:
        digest = vitis_stage_code_sha256(root, stage_key)
        if digest:
            inputs[f"@VitisStage/{stage_key}/source_sha256"] = digest
    lock = _embedded_video_ip_lock(root)
    if lock is None:
        return inputs
    dependency, _, _ = lock
    check_embedded_video_ip(root)
    stage_key = stage.split(":", 1)[0]
    if stage_key == "build":
        stage_key = "hardware"
    try:
        tracked = subprocess.run(
            ["git", "-C", str(dependency), "ls-files", "-z"],
            text=True, capture_output=True, check=True, timeout=15,
        ).stdout.split("\0")
    except (OSError, subprocess.SubprocessError) as exc:
        raise FlowError("FLOW-EVIP-GIT", f"Cannot enumerate EmbeddedVideoIP inputs: {exc}") from exc
    if stage_key in {"hardware", "project", "sim"}:
        selected = [name for name in tracked if name.startswith("ip_repo/panfpga/video_pipeline/")]
    elif stage_key == "app":
        selected = [
            name for name in tracked
            if name.startswith(("software/", "platforms/amd_7series/"))
            or name == "tools/install_ps_library.py"
        ]
    else:
        selected = []
    selected.extend(name for name in ("VERSION", "dependencies.lock.json") if name in tracked)
    for name in sorted(set(selected)):
        source = dependency / name
        if not source.is_file():
            raise FlowError("FLOW-EVIP-INPUT", f"Locked EmbeddedVideoIP input is missing: {source}")
        inputs[f"@EmbeddedVideoIP/{name}"] = sha256_file(source)
    inputs["@EmbeddedVideoIP/commit"] = hashlib.sha256(check_embedded_video_ip(root)["commit"].encode("ascii")).hexdigest()
    return dict(sorted(inputs.items()))


def source_digest(inputs: Mapping[str, str]) -> str:
    return digest_json(dict(sorted(inputs.items())))


def parse_qor_gate(path: Path) -> dict[str, object]:
    try:
        values = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key.strip()] = value.strip()
        result = {
            "passed": values.get("passed") == "1",
            "wns_ns": float(values["wns_ns"]),
            "tns_ns": float(values["tns_ns"]),
            "whs_ns": float(values["whs_ns"]),
            "ths_ns": float(values["ths_ns"]),
            "drc_errors": int(values["drc_errors"]),
            "critical_warnings": int(values["critical_warnings"]),
        }
    except (OSError, KeyError, ValueError) as exc:
        raise FlowError("FLOW-QOR-REPORT", f"Cannot read machine-readable QoR gate {path}: {exc}") from exc
    result["validated_pass"] = (
        result["passed"] is True
        and result["wns_ns"] >= 0.0
        and abs(result["tns_ns"]) < 0.0005
        and result["whs_ns"] >= 0.0
        and abs(result["ths_ns"]) < 0.0005
        and result["drc_errors"] == 0
        and result["critical_warnings"] == 0
    )
    return result




def contract_info(path: Path = CONTRACT_PATH) -> dict[str, str]:
    try:
        spec = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FlowError("FLOW-CONTRACT-READ", f"Cannot read contract: {exc}") from exc
    sha = hashlib.sha256(json.dumps(spec, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
    return {"sha256": sha, "abi_build_id": f"0x{sha[:8].upper()}"}


def check_hardware_contract(root: Path = ROOT) -> None:
    generator = root / "tools/generate_hw_contract.py"
    if not generator.is_file():
        raise FlowError("FLOW-CONTRACT-GENERATOR", f"Missing contract generator: {generator}")
    result = subprocess.run([sys.executable, str(generator), "--check"], cwd=root, text=True, capture_output=True, check=False)
    output = "\n".join(x for x in (result.stdout.strip(), result.stderr.strip()) if x)
    if output:
        print(output)
    if result.returncode:
        raise FlowError("FLOW-CONTRACT-STALE", f"Generated contract headers stale (exit {result.returncode}); ask contract owner to regenerate/review.")


def check_vendored_ip(root: Path = ROOT) -> dict[str, object]:
    package = root / "third_party/digilent-vivado-library"
    try:
        lock = json.loads((package / "dependency-lock.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FlowError("FLOW-IP-LOCK", f"Cannot read IP lock: {exc}") from exc
    expected = lock.get("files_sha256")
    if lock.get("schema_version") != 1 or lock.get("upstream_commit") != PINNED_DIGILENT_COMMIT or lock.get("upstream_repository") != "https://github.com/Digilent/vivado-library.git":
        raise FlowError("FLOW-IP-LOCK", "Digilent IP lock does not match the pinned official source.")
    if lock.get("ip_vlnv") != "digilentinc.com:ip:rgb2dvi:1.4" or lock.get("core_revision") != 8 or not isinstance(expected, dict) or not expected or lock.get("package_sha256") != digest_json(expected):
        raise FlowError("FLOW-IP-LOCK", "Digilent lock must identify rgb2dvi 1.4 revision 8 with valid hashes.")
    for rel, sha in expected.items():
        path = package / str(rel)
        if not path.is_file() or sha256_file(path) != sha:
            raise FlowError("FLOW-IP-CONTENT", f"Vendored IP missing/changed: {rel}")
    actual = {p.relative_to(package).as_posix() for p in package.rglob("*") if p.is_file() and p.name not in {"README.md", "dependency-lock.json"} and not p.is_symlink()}
    if actual != set(expected):
        raise FlowError("FLOW-IP-CONTENT", "Vendored IP has unlisted or missing files.")
    return {"repository": lock["upstream_repository"], "commit": lock["upstream_commit"], "ip_vlnv": lock["ip_vlnv"], "core_revision": lock["core_revision"], "package_sha256": lock["package_sha256"], "file_count": len(expected)}


def contract_check(root: Path = ROOT) -> dict[str, object]:
    check_hardware_contract(root)
    digilent = check_vendored_ip(root)
    evip = check_embedded_video_ip(root)
    if evip:
        # Keep the fingerprint bound to the tested code commit. A clean docs-only
        # descendant is allowed, but its checkout hash is not a PL input.
        digilent["embedded_video_ip"] = {
            "version": evip["version"],
            "commit": evip["commit"],
        }
    return digilent


def resolve_executable(executable: str) -> Path:
    candidate = Path(executable).expanduser()
    path = candidate if candidate.is_absolute() or candidate.parent != Path(".") else None
    if path is None:
        found = shutil.which(executable)
        if not found:
            raise FlowError("FLOW-TOOL-NOT-FOUND", f"Cannot find {executable!r}; set VIVADO_BIN or pass --vivado.")
        path = Path(found)
    if not path.is_file():
        raise FlowError("FLOW-TOOL-NOT-FOUND", f"Executable does not exist: {path}")
    return path.resolve()


def resolve_vitis_executable(executable: str) -> Path:
    """Resolve explicit --vitis, VITIS_BIN, or PATH to an absolute executable."""
    return resolve_executable(executable)


def _probe_version(executable: Path, name: str, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None, flag: str = "-version") -> str:
    try:
        result = (runner or subprocess.run)([str(executable), flag], cwd=ROOT, text=True, capture_output=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FlowError(f"FLOW-{name.upper()}-VERSION", f"Cannot probe {name}: {exc}") from exc
    output = "\n".join(p.strip() for p in (result.stdout, result.stderr) if p.strip())
    if result.returncode:
        raise FlowError(f"FLOW-{name.upper()}-VERSION", f"{name} version failed ({result.returncode}): {output}")
    return output


def read_tool_version(executable: Path, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> str:
    output = _probe_version(executable, "vivado", runner)
    if not re.search(rf"(?<!\d){re.escape(REQUIRED_VIVADO_VERSION)}(?!\d)", output):
        raise FlowError("FLOW-TOOL-VERSION", f"Vivado {REQUIRED_VIVADO_VERSION} required; detected {output!r}")
    return next((line.strip() for line in output.splitlines() if re.search(r"Vivado\s+v?\d", line, re.I)), output.splitlines()[0].strip())


def read_vitis_version(executable: Path, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> str:
    output = _probe_version(executable, "vitis", runner, "-v")
    if not re.search(rf"(?<!\d){re.escape(REQUIRED_VITIS_VERSION)}(?!\d)", output):
        raise FlowError("FLOW-VITIS-VERSION", f"Vitis {REQUIRED_VITIS_VERSION} required; detected {output!r}")
    return next((line.strip() for line in output.splitlines() if re.search(r"Vitis\s+v?\d", line, re.I)), output.splitlines()[0].strip())


def load_manifest(path: Path = MANIFEST_PATH) -> dict[str, object]:
    if not path.is_file():
        return {"schema_version": SCHEMA_VERSION, "runs": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema_version": SCHEMA_VERSION, "runs": {}}
    if not isinstance(data, dict) or not isinstance(data.get("runs"), dict):
        return {"schema_version": SCHEMA_VERSION, "runs": {}}
    if data.get("schema_version") != SCHEMA_VERSION:
        # Preserve historical evidence, but never treat an older fingerprint schema as cacheable.
        return {"schema_version": SCHEMA_VERSION, "runs": {}, "legacy_manifest": data}
    return data


def manifest_for(root: Path = ROOT) -> dict[str, object]:
    return load_manifest(root / "out/flow/manifest.json")


def write_manifest(data: Mapping[str, object], path: Path = MANIFEST_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, sort_keys=True, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")




def run_captured(command: list[str], cwd: Path, env: Mapping[str, str], log_path: Path, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> subprocess.CompletedProcess[str]:
    result = (runner or subprocess.run)(command, cwd=cwd, env=dict(env), text=True, capture_output=True, check=False)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text((result.stdout or "") + "\n" + (result.stderr or ""), encoding="utf-8", newline="\n")
    return result


def check_out_outputs(record: Mapping[str, object], root: Path = ROOT, output_hashes_key: str | None = None) -> bool:
    outputs = record.get("outputs")
    hashes = record.get(output_hashes_key) if output_hashes_key else None
    if not isinstance(outputs, dict) or not outputs:
        return False
    for key, value in outputs.items():
        rel, sha = (value, hashes.get(key)) if isinstance(hashes, dict) else (key, value)
        if not isinstance(rel, str) or not isinstance(sha, str):
            return False
        try:
            path = safe_out_path(rel, root)
        except FlowError:
            return False
        if not path.is_file() or sha256_file(path) != sha:
            return False
    return True


def cache_is_valid(record: Mapping[str, object], input_hash: str, tool_version: str, root: Path = ROOT) -> bool:
    if record.get("status") != "succeeded" or record.get("input_sha256") != input_hash or record.get("vivado_version") != tool_version:
        return False
    outputs = record.get("outputs")
    required = ACTION_OUTPUTS.get(str(record.get("action", "")))
    if required and (not isinstance(outputs, dict) or not {p.as_posix() for p in required}.issubset(outputs)):
        return False
    return check_out_outputs(record, root)


def stage_cache_valid(record: Mapping[str, object], input_hash: str, vitis_version: str, root: Path = ROOT) -> bool:
    return record.get("status") == "succeeded" and record.get("input_sha256") == input_hash and record.get("vitis_version") == vitis_version and check_out_outputs(record, root, "output_hashes")




def discover_suite_benches(suite: str, root: Path = ROOT) -> list[Path]:
    patterns = SIM_SUITE_PATTERNS.get(suite)
    if patterns is None:
        raise FlowError("FLOW-SIM-SUITE", f"Unknown suite {suite!r}.")
    bench_root = root / "tests/rtl"
    candidates = sorted((p for p in bench_root.glob("tb_*") if p.is_file() and p.suffix.lower() in {".sv", ".v", ".vhd", ".vhdl"}), key=lambda p: p.name)
    missing = [pat for pat in patterns if not any(fnmatch.fnmatchcase(p.name, pat) for p in candidates)]
    if missing:
        raise FlowError("FLOW-SIM-SUITE-MISSING", f"Suite {suite!r} missing configured benches: {', '.join(missing)}")
    selected = [p for p in candidates if any(fnmatch.fnmatchcase(p.name, pat) for pat in patterns)]
    if not selected:
        raise FlowError("FLOW-SIM-SUITE-MISSING", f"Suite {suite!r} has no tests/rtl benches.")
    return selected


def tcl_quote(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise FlowError("FLOW-SIM-PATH", "Tcl paths cannot contain newlines.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("[", "\\[").replace("]", "\\]") + '"'


def render_sim_runner(project_file: Path, output_dir: Path, benches: Iterable[Path], seed: int) -> str:
    bench_list = " ".join(tcl_quote(str(p.resolve())) for p in benches)
    project = tcl_quote(str(project_file.resolve()))
    output = tcl_quote(str(output_dir.resolve()))
    return f'''set project_file {project}
set output_dir {output}
set seed {int(seed)}
file mkdir $output_dir
open_project $project_file
foreach bench [list {bench_list}] {{
  set top [file rootname [file tail $bench]]
  set bench_dir [file join $output_dir $top]
  file mkdir $bench_dir
  if {{[llength [get_files -quiet $bench]] == 0}} {{ add_files -fileset sim_1 -norecurse $bench }}
  set bench_obj [get_files -quiet $bench]
  if {{[string tolower [file extension $bench]] in {{.vhd .vhdl}}}} {{ set_property file_type {{VHDL 2008}} $bench_obj }}
  set_property top $top [get_filesets sim_1]
  update_compile_order -fileset sim_1
  set log_path [file join $bench_dir xsim.log]
  set sim_tcl_path [file join $bench_dir run_test.tcl]
  set sim_tcl_file [open $sim_tcl_path w]
  puts $sim_tcl_file {{run all}}
  puts $sim_tcl_file {{quit}}
  close $sim_tcl_file
  set_property -name xsim.simulate.custom_tcl -value $sim_tcl_path -objects [get_filesets sim_1]
  set_property -name xsim.simulate.runtime -value {{}} -objects [get_filesets sim_1]
  set_property -name xsim.simulate.wdb -value {{}} -objects [get_filesets sim_1]
  set_property -name xsim.simulate.log_all_signals -value false -objects [get_filesets sim_1]
  set xsim_options [list -sv_seed $seed -testplusarg \"seed=$seed\"]
  set_property -name {{xsim.simulate.xsim.more_options}} -value $xsim_options -objects [get_filesets sim_1]
  export_simulation -simulator xsim -directory $bench_dir -force -absolute_path -exec
  set simulator_log [file join $bench_dir xsim simulate.log]
  if {{![file isfile $simulator_log]}} {{ error "XSim log was not produced: $simulator_log" }}
  file copy -force $simulator_log $log_path
  remove_files -fileset sim_1 $bench_obj
}}
close_project
'''


def expected_project_record(root: Path = ROOT) -> dict[str, object]:
    manifest = manifest_for(root)
    runs = manifest.get("runs", {})
    inputs = stage_input_manifest(root, "project")
    current_source = source_digest(inputs)
    contract = contract_info(root / "config/ps_pl_contract.json")
    for key in ("project",):
        rec = runs.get(key) if isinstance(runs, dict) else None
        if (not isinstance(rec, dict) or rec.get("status") != "succeeded"
                or (rec.get("source_sha256") != current_source and not _record_inputs_match(rec, inputs, root))):
            continue
        built = rec.get("hardware_contract")
        outputs = rec.get("outputs")
        if not isinstance(built, dict) or built.get("abi_build_id") != contract["abi_build_id"] or not isinstance(outputs, dict):
            continue
        expected = outputs.get(SIM_PROJECT_REL.as_posix())
        project = safe_out_path(SIM_PROJECT_REL.as_posix(), root)
        if isinstance(expected, str) and project.is_file() and sha256_file(project) == expected:
            return rec
    raise FlowError("FLOW-SIM-PROJECT-MISSING", "Run `project` for current sources before simulation.")


def run_simulation(suite: str, seed: int, executable_text: str = "vivado", root: Path = ROOT, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> int:
    key = f"sim:{suite}:seed-{seed}"
    details: dict[str, object] = {"suite": suite, "seed": seed}
    try:
        if seed < 0 or seed > 2147483647:
            raise FlowError("FLOW-SIM-SEED", "Seed must be between 0 and 2147483647.")
        benches = discover_suite_benches(suite, root)
        check_hardware_contract(root)
        check_vendored_ip(root)
        project_rec = expected_project_record(root)
        executable = resolve_executable(executable_text)
        version = read_tool_version(executable, runner)
        inputs = stage_input_manifest(root, "sim")
        contract = contract_info(root / "config/ps_pl_contract.json")
        project_outputs = project_rec.get("outputs", {})
        input_hash = digest_json({"action": "sim", "suite": suite, "seed": seed, "vivado": version, "inputs": inputs, "project_xpr": project_outputs.get(SIM_PROJECT_REL.as_posix()) if isinstance(project_outputs, dict) else None, "contract": contract})
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + uuid.uuid4().hex[:8]
        out = root / "out/sim" / suite / f"seed-{seed}" / run_id
        out.mkdir(parents=True, exist_ok=False)
        tcl = out / "run_suite.tcl"
        tcl.write_text(render_sim_runner(root / SIM_PROJECT_REL, out, benches, seed), encoding="utf-8", newline="\n")
        command = [str(executable), "-mode", "batch", "-source", str(tcl)]
        manifest = manifest_for(root)
        runs = manifest.setdefault("runs", {})
        if not isinstance(runs, dict):
            runs = {}
            manifest["runs"] = runs
        record: dict[str, object] = {"schema_version": SCHEMA_VERSION, "action": "sim", "suite": suite, "seed": seed, "entry": [p.relative_to(root).as_posix() for p in benches], "runner": tcl.relative_to(root).as_posix(), "output_dir": out.relative_to(root).as_posix(), "input_sha256": input_hash, "source_sha256": source_digest(inputs), "input_files": inputs, "input_fingerprint_type": "sha256-v1", "vivado_version": version, "hardware_contract": contract, "status": "running", "started_at_utc": utc_now(), "command": [executable.name, "-mode", "batch", "-source", tcl.relative_to(root).as_posix()], "outputs": {}}
        archive_previous_success(runs, key)
        runs[key] = record
        manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs})
        write_manifest(manifest, root / "out/flow/manifest.json")
        env = os.environ.copy()
        env["ZYNQ_GBA_REPO_ROOT"] = str(root)
        env["ZYNQ_GBA_OUT_DIR"] = str(root / PROJECT_WORK_DIR)
        project_snapshot: dict[Path, bytes] = {}
        if not isinstance(project_outputs, dict) or not project_outputs:
            raise FlowError("FLOW-SIM-PROJECT-MISSING", "Simulation project output manifest is empty.")
        for relative in project_outputs:
            if not isinstance(relative, str):
                raise FlowError("FLOW-SIM-PROJECT-MISSING", "Simulation project output manifest is malformed.")
            project_output = safe_out_path(relative, root)
            if not project_output.is_file():
                raise FlowError("FLOW-SIM-PROJECT-MISSING", f"Simulation project output is missing: {relative}")
            project_snapshot[project_output] = project_output.read_bytes()
        try:
            result = run_captured(command, out, env, out / "vivado.log", runner)
        finally:
            # Vivado persists sim_1 top/options into the XPR. Keep the validated
            # project artifact immutable so another suite can reuse its cache.
            for project_output, contents in project_snapshot.items():
                if not project_output.is_file() or project_output.read_bytes() != contents:
                    project_output.write_bytes(contents)
        if any(not path.is_file() or path.read_bytes() != contents for path, contents in project_snapshot.items()):
            raise FlowError("FLOW-SIM-PROJECT-RESTORE", "Vivado modified the validated simulation project and it could not be restored.")
        record["exit_code"] = result.returncode
        record["completed_at_utc"] = utc_now()
        if result.returncode:
            raise FlowError("FLOW-SIM-FAILED", f"Vivado sim exited {result.returncode}.")
        artifacts: dict[str, Path] = {"runner": tcl, "vivado_log": out / "vivado.log"}
        for bench in benches:
            top = bench.stem
            xsimlog = out / top / "xsim.log"
            if not xsimlog.is_file():
                raise FlowError("FLOW-SIM-LOG-MISSING", f"XSim log missing: {xsimlog.relative_to(root)}")
            if re.search(r"(?im)^.*(?:\bTEST_FAIL\b|\*\*\* SOME TESTS FAILED \*\*\*).*$", xsimlog.read_text(encoding="utf-8", errors="replace")) or re.search(r"(?im)^.*\bFAIL\b(?!\s*:\s*0\b).*$", xsimlog.read_text(encoding="utf-8", errors="replace")):
                raise FlowError("FLOW-SIM-ASSERTION", f"XSim log reports failure: {xsimlog.relative_to(root)}")
            if "TEST_PASS" not in xsimlog.read_text(encoding="utf-8", errors="replace"):
                raise FlowError("FLOW-SIM-PASS-MISSING", f"XSim log is missing TEST_PASS marker: {xsimlog.relative_to(root)}")
            artifacts[f"xsim:{top}"] = xsimlog
            wdb = out / top / "xsim" / f"{top}.wdb"
            if wdb.is_file():
                artifacts[f"wdb:{top}"] = wdb
        record.update({"status": "succeeded", "completed_at_utc": utc_now(), "outputs": {p.relative_to(root).as_posix(): sha256_file(p) for p in artifacts.values()}})
        write_manifest(manifest, root / "out/flow/manifest.json")
        print(f"[FLOW-SIM-SUCCESS] {suite} seed={seed}; {len(benches)} benches; {out.relative_to(root)}")
        return 0
    except FlowError as exc:
        persist_stage_failure(key, exc, root, details)
        raise
    except OSError as exc:
        error = FlowError("FLOW-SIM-EXECUTION", str(exc))
        persist_stage_failure(key, error, root, details)
        raise error from exc


def audit_manifest_record(record: object, root: Path = ROOT) -> dict[str, object]:
    if not isinstance(record, dict):
        return {"status": "pending", "detail": "no manifest record"}
    status = str(record.get("status", "pending"))
    if status == "failed":
        return {"status": "fail", "detail": record.get("error", record.get("error_code", "failed"))}
    if status != "succeeded":
        return {"status": "pending", "detail": f"manifest state is {status}"}
    outputs = record.get("outputs")
    hashes = record.get("output_hashes")
    if not isinstance(outputs, dict) or not outputs:
        return {"status": "fail", "detail": "successful record has no outputs"}
    for name, value in outputs.items():
        rel, expected = (value, hashes.get(name)) if isinstance(hashes, dict) else (name, value)
        if not isinstance(rel, str) or not isinstance(expected, str):
            return {"status": "fail", "detail": "malformed output entry"}
        try:
            path = safe_out_path(rel, root)
        except FlowError as exc:
            return {"status": "fail", "detail": str(exc)}
        if not path.is_file() or sha256_file(path) != expected:
            return {"status": "fail", "detail": f"output missing/hash mismatch: {rel}"}
    return {"status": "succeeded", "detail": "all recorded output hashes verified"}


def audit_stage_inputs(record: object, stage: str, root: Path = ROOT) -> dict[str, str]:
    if not isinstance(record, dict):
        return {"status": "pending", "detail": "no manifest record"}
    try:
        current = stage_input_manifest(root, stage)
    except (FlowError, OSError) as exc:
        return {"status": "fail", "detail": f"cannot read {stage} inputs: {exc}"}
    stored = record.get("input_files")
    if not isinstance(stored, dict):
        return {"status": "fail", "detail": "stage input manifest is missing"}
    if record.get("input_fingerprint_type") != "sha256-v1":
        return {"status": "fail", "detail": "stage uses an obsolete input fingerprint schema"}
    if stored != current:
        if stage == "hardware" and _hardware_inputs_match_for_rekey(record, current):
            return {"status": "succeeded", "detail": "verified PL inputs and outputs unchanged; safe metadata re-key excludes project-only Tcl"}
        return {"status": "fail", "detail": "stage content hashes changed; rerun the stage before reuse"}
    return {"status": "succeeded", "detail": "all stage input SHA-256 hashes match"}


def _stage_artifact_hash(record: object, name: str) -> str | None:
    if not isinstance(record, dict):
        return None
    hashes = record.get("output_hashes")
    if isinstance(hashes, dict) and isinstance(hashes.get(name), str):
        return hashes[name]
    outputs = record.get("outputs")
    value = outputs.get(name) if isinstance(outputs, dict) else None
    return value if isinstance(value, str) else None


def validate_stage_dependencies(
    runs: Mapping[str, object],
    stages: dict[str, dict[str, object]],
) -> None:
    def invalidate(stage: str, detail: str) -> None:
        if stages[stage]["status"] == "succeeded":
            stages[stage] = {"status": "fail", "detail": detail}

    def record(name: str) -> dict[str, object]:
        value = runs.get(name)
        return value if isinstance(value, dict) else {}

    def check(stage: str, expected: Mapping[str, object]) -> None:
        if stages[stage]["status"] != "succeeded":
            return
        dependencies = record(stage).get("dependencies")
        if not isinstance(dependencies, dict):
            invalidate(stage, "stage dependency record is missing")
            return
        mismatches = [
            name
            for name, value in expected.items()
            if value is None or dependencies.get(name) != value
        ]
        if mismatches:
            invalidate(stage, f"dependency mismatch: {', '.join(mismatches)}")

    hardware = record("build")
    if stages["hardware"]["status"] != "succeeded":
        reason = f"upstream hardware stage is {stages['hardware']['status']}"
        invalidate("platform", reason)
        invalidate("app", reason)
        invalidate("boot", reason)
        return

    hardware_bit = _stage_artifact_hash(hardware, BITSTREAM_REL.as_posix())
    hardware_xsa = _stage_artifact_hash(hardware, XSA_REL.as_posix())
    hardware_input = hardware.get("input_sha256")
    contract = hardware.get("hardware_contract")

    check(
        "platform",
        {
            "bit_sha256": hardware_bit,
            "xsa_sha256": hardware_xsa,
            "hardware_contract": contract,
        },
    )
    if stages["platform"]["status"] != "succeeded":
        reason = "upstream platform stage is not valid"
        invalidate("app", reason)
        invalidate("boot", reason)
        return

    platform = record("platform")
    platform_input = platform.get("input_sha256")
    xpfm_hash = _stage_artifact_hash(platform, "xpfm")
    fsbl_hash = _stage_artifact_hash(platform, "fsbl_elf")

    check(
        "app",
        {
            "bit_sha256": hardware_bit,
            "xsa_sha256": hardware_xsa,
            "hardware_contract": contract,
            "xpfm_sha256": xpfm_hash,
        },
    )
    if stages["app"]["status"] != "succeeded":
        invalidate("boot", "upstream application stage is not valid")
        return

    app = record("app")
    check(
        "boot",
        {
            "bit_sha256": hardware_bit,
            "xsa_sha256": hardware_xsa,
            "hardware_contract": contract,
            "xpfm_sha256": xpfm_hash,
            "fsbl_sha256": fsbl_hash,
            "app_elf_sha256": _stage_artifact_hash(app, "app_elf"),
        },
    )


def build_report(root: Path = ROOT) -> dict[str, object]:
    manifest_path = root / "out/flow/manifest.json"
    manifest_status = "pending"
    manifest_error = None
    data = None
    if manifest_path.is_file():
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION or not isinstance(data.get("runs"), dict):
                raise ValueError("unsupported manifest schema")
            manifest_status = "present"
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            manifest_status = "fail"
            manifest_error = str(exc)
    runs = data.get("runs", {}) if data else {}
    stages = {name: audit_manifest_record(runs.get(key), root) for name, key in (("hardware", "build"), ("platform", "platform"), ("app", "app"), ("boot", "boot"))}
    for name, key in (("hardware", "build"), ("platform", "platform"), ("app", "app"), ("boot", "boot")):
        if stages[name]["status"] == "succeeded":
            input_audit = audit_stage_inputs(runs.get(key), name, root)
            if input_audit["status"] != "succeeded":
                stages[name] = input_audit
            elif "safe metadata re-key" in input_audit["detail"]:
                stages[name]["detail"] = input_audit["detail"]
            elif isinstance(runs.get(key), dict) and runs[key].get("input_partition_version") != 2:
                stages[name]["detail"] = f"{stages[name]['detail']}; {input_audit['detail']} (re-key on reuse)"
    validate_stage_dependencies(runs, stages)
    suites = {name: {"status": "pending", "detail": "no manifest record"} for name in SIM_SUITE_PATTERNS}
    sims = []
    for key, rec in sorted(runs.items()):
        if not isinstance(rec, dict) or rec.get("action") != "sim":
            continue
        result = audit_manifest_record(rec, root)
        suite = str(rec.get("suite", "unknown"))
        sims.append({"key": key, "suite": suite, "seed": rec.get("seed"), "entry": rec.get("entry", []), "output_dir": rec.get("output_dir"), **result})
        if suite in suites and result["status"] in {"succeeded", "fail"}:
            suites[suite] = result
    reports = []
    sim_logs = []
    out = root / "out"
    if out.is_dir():
        for path in sorted(out.rglob("*.rpt")):
            if path.is_file():
                reports.append({"path": path.relative_to(root).as_posix(), "size_bytes": path.stat().st_size, "sha256": sha256_file(path)})
        for path in sorted(out.rglob("xsim.log")):
            if path.is_file():
                sim_logs.append({"path": path.relative_to(root).as_posix(), "size_bytes": path.stat().st_size, "sha256": sha256_file(path)})
    statuses = [item["status"] for item in stages.values()] + [item["status"] for item in suites.values()]
    overall = "fail" if manifest_status == "fail" or "fail" in statuses else "pending" if manifest_status != "present" or "pending" in statuses or not reports else "succeeded"
    return {"schema_version": SCHEMA_VERSION, "overall_status": overall, "manifest": {"status": manifest_status, "path": "out/flow/manifest.json", "error": manifest_error}, "stages": stages, "sim_suites": suites, "simulations": sims, "reports": reports, "simulation_logs": sim_logs}


def run_report(root: Path = ROOT, as_json: bool = False) -> int:
    report = build_report(root)
    if as_json:
        print(json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False))
        return 1 if report["overall_status"] == "fail" else 0
    print(f"Flow report: {report['overall_status']}")
    print(f"Manifest: {report['manifest']['status']} ({report['manifest']['path']})")
    for key, item in report["stages"].items():
        print(f"{key}: {item['status']} — {item['detail']}")
    for key, item in report["sim_suites"].items():
        print(f"sim {key}: {item['status']} — {item['detail']}")
    print(f"Existing reports: {len(report['reports'])}")
    for item in report["reports"]:
        print(f"  {item['path']} ({item['size_bytes']} bytes, sha256 {item['sha256']})")
    print(f"Existing XSim logs: {len(report['simulation_logs'])}")
    for item in report["simulation_logs"]:
        print(f"  {item['path']} ({item['size_bytes']} bytes, sha256 {item['sha256']})")
    if report["manifest"]["error"]:
        print(f"Manifest error: {report['manifest']['error']}")
    return 1 if report["overall_status"] == "fail" else 0


# ----- CLI ------------------------------------------------------------------














def archive_previous_success(runs: dict[str, object], key: str) -> None:
    previous = runs.get(key)
    if not isinstance(previous, dict) or previous.get("status") != "succeeded":
        return
    signature = str(previous.get("input_sha256", "unknown"))[:12]
    archive_key = f"{key}:previous-success:{signature}"
    if archive_key in runs:
        return
    archived = copy.deepcopy(previous)
    archived["archived_success"] = True
    archived["archived_at_utc"] = utc_now()
    runs[archive_key] = archived


def persist_stage_failure(key: str, error: FlowError, root: Path = ROOT, details: Mapping[str, object] | None = None) -> None:
    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs
    previous = runs.get(key)
    if isinstance(previous, dict) and previous.get("status") == "running":
        record = copy.deepcopy(previous)
        record.update({
            "status": "failed", "error_code": error.code, "error": str(error),
            "completed_at_utc": utc_now(),
        })
    else:
        record = {
            "schema_version": SCHEMA_VERSION, "action": key.split(":", 1)[0],
            "status": "failed", "error_code": error.code, "error": str(error),
            "completed_at_utc": utc_now(), "outputs": {},
        }
    if details:
        record.update(details)
    archive_previous_failure(runs, key)
    archive_previous_success(runs, key)
    runs[key] = record
    manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs})
    write_manifest(manifest, root / "out/flow/manifest.json")


def project_command(action: str, executable: Path, root: Path = ROOT) -> list[str]:
    if action not in ACTION_TCL:
        raise FlowError("FLOW-ACTION-UNSUPPORTED", f"Unsupported Vivado action {action!r}.")
    return [str(executable), "-mode", "batch", "-source", str(root / ACTION_TCL[action])]


def run_vivado_action(
    action: str,
    executable_text: str = "vivado",
    root: Path = ROOT,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
    jobs: int | None = None,
) -> int:
    if action not in ACTION_TCL:
        raise FlowError("FLOW-ACTION-UNSUPPORTED", f"Unsupported Vivado action {action!r}.")

    selected_jobs = normalize_jobs(jobs) if action == "build" else None
    ip = contract_check(root)
    executable = resolve_executable(executable_text)
    version = read_tool_version(executable, runner)
    inputs = stage_input_manifest(root, action)
    contract = contract_info(root / "config/ps_pl_contract.json")
    input_hash = vivado_input_hash(action, inputs, version, selected_jobs, contract, ip)

    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs

    previous = runs.get(action)
    if isinstance(previous, dict):
        if not cache_is_valid(previous, input_hash, version, root):
            if _rekey_legacy_vivado_record(previous, inputs, input_hash, version, contract, ip, selected_jobs, root):
                if action == "build" and isinstance(manifest.get("hardware_cache"), dict):
                    cache = manifest["hardware_cache"]
                    cache.update({
                        "identity_sha256": hardware_identity_sha256(inputs, version, selected_jobs, contract, ip),
                        "input_sha256": input_hash,
                        "updated_at_utc": utc_now(),
                    })
                write_manifest(manifest, root / "out/flow/manifest.json")
                print(f"[FLOW-CACHE-REKEY] {action}: design inputs and artifact hashes match")
        if cache_is_valid(previous, input_hash, version, root):
            print(f"[FLOW-CACHE-HIT] {action}: hashes match")
            return 0

    partial_resume = (
        action == "build"
        and resumable_partial_vivado_build(previous, inputs, version, contract, ip, selected_jobs, root)
    )
    if partial_resume:
        print("[FLOW-PARTIAL-RESUME] verified synth/route/bit outputs exist; resuming at final QoR check and XSA export")

    output_dir = root / (PROJECT_WORK_DIR if action == "project" else Path("out/vivado"))
    output_dir.mkdir(parents=True, exist_ok=True)
    command = project_command(action, executable, root)
    env = os.environ.copy()
    env["ZYNQ_GBA_REPO_ROOT"] = str(root)
    env["ZYNQ_GBA_OUT_DIR"] = str(output_dir)
    env["ZYNQ_GBA_PYTHON"] = sys.executable
    env["EMBEDDED_VIDEO_IP_REPO"] = str(_embedded_video_ip_root(root))
    env["DIGILENT_VIVADO_LIBRARY"] = str(root / "third_party/digilent-vivado-library")
    if action == "build":
        identity = hardware_identity_sha256(inputs, version, selected_jobs, contract, ip)
        previous_dcp = compatible_incremental_dcp(manifest, identity, root)
        env["ZYNQ_GBA_INCREMENTAL_DCP"] = str(previous_dcp) if previous_dcp else ""
        env["ZYNQ_GBA_REBUILD_PROJECT"] = "0" if partial_resume else "1"
    if selected_jobs is not None:
        env["ZYNQ_GBA_JOBS"] = str(selected_jobs)

    record: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "action": action,
        "status": "running",
        "started_at_utc": utc_now(),
        "input_sha256": input_hash,
        "source_sha256": source_digest(inputs),
        "input_files": inputs,
        "input_partition": action,
        "input_partition_version": 2,
        "input_fingerprint_type": "sha256-v1",
        "python_version": ".".join(map(str, sys.version_info[:3])),
        "vivado_version": version,
        "hardware_contract": contract,
        "vendored_ip": ip,
        "jobs": selected_jobs,
        "partial_resume": partial_resume,
        "command": [executable.name, "-mode", "batch", "-source", ACTION_TCL[action]],
        "outputs": {},
    }
    archive_previous_failure(runs, action)
    archive_previous_success(runs, action)
    runs[action] = record
    manifest.update(
        {
            "schema_version": SCHEMA_VERSION,
            "generated_at_utc": utc_now(),
            "toolchain_policy": {
                "vivado_required": REQUIRED_VIVADO_VERSION,
                "vitis_required": REQUIRED_VITIS_VERSION,
            },
            "hardware_contract": contract,
            "runs": runs,
        }
    )
    write_manifest(manifest, root / "out/flow/manifest.json")

    try:
        result = (runner or subprocess.run)(
            command,
            cwd=output_dir,
            env=env,
            check=False,
        )
    except OSError as exc:
        error = FlowError("FLOW-SUBPROCESS", f"Cannot start Vivado: {exc}")
        record.update(
            {
                "status": "failed",
                "error_code": error.code,
                "error": str(error),
                "completed_at_utc": utc_now(),
            }
        )
        write_manifest(manifest, root / "out/flow/manifest.json")
        raise error from exc

    record["exit_code"] = result.returncode
    record["completed_at_utc"] = utc_now()

    post_inputs: dict[str, str] = {}
    input_scan_error: str | None = None
    try:
        post_inputs = stage_input_manifest(root, action)
    except (FlowError, OSError) as exc:
        input_scan_error = str(exc)

    if input_scan_error is not None or post_inputs != inputs:
        before_paths = set(inputs)
        after_paths = set(post_inputs)
        changes = {
            "added": sorted(after_paths - before_paths),
            "removed": sorted(before_paths - after_paths),
            "changed": sorted(
                path for path in before_paths & after_paths if inputs[path] != post_inputs[path]
            ),
        }
        error = FlowError(
            "FLOW-SOURCE-MUTATED",
            f"Source inputs changed during Vivado {action}: {changes}",
        )
        record.update(
            {
                "status": "failed",
                "error_code": error.code,
                "error": str(error),
                "post_input_files": post_inputs,
                "post_source_sha256": source_digest(post_inputs),
                "source_changes": changes,
            }
        )
        if input_scan_error is not None:
            record["post_input_scan_error"] = input_scan_error
        write_manifest(manifest, root / "out/flow/manifest.json")
        raise error

    if result.returncode:
        record.update({"status": "failed", "error_code": "FLOW-VIVADO-FAILED"})
        write_manifest(manifest, root / "out/flow/manifest.json")
        raise FlowError(
            "FLOW-VIVADO-FAILED",
            f"Vivado returned exit {result.returncode}; failed runs are not cached.",
        )

    outputs = {}
    for rel in ACTION_OUTPUTS[action]:
        path = root / rel
        if not path.is_file():
            record.update(
                {
                    "status": "failed",
                    "error_code": "FLOW-OUTPUT-MISSING",
                    "error": rel.as_posix(),
                }
            )
            write_manifest(manifest, root / "out/flow/manifest.json")
            raise FlowError(
                "FLOW-OUTPUT-MISSING",
                f"Expected output was not produced: {rel}",
            )
        outputs[rel.as_posix()] = sha256_file(path)

    logs = {}
    for name in ("vivado.log", "vivado.jou"):
        path = output_dir / name
        if path.is_file() and path.stat().st_size:
            logs[path.relative_to(root).as_posix()] = sha256_file(path)
    if logs:
        record["logs"] = logs

    if action == "build":
        try:
            qor = parse_qor_gate(root / QOR_GATE_REL)
        except FlowError as exc:
            record.update({"status": "failed", "error_code": exc.code, "error": str(exc), "completed_at_utc": utc_now()})
            write_manifest(manifest, root / "out/flow/manifest.json")
            raise
        if not qor["validated_pass"]:
            record.update({"status": "failed", "error_code": "FLOW-QOR-GATE", "qor": qor, "completed_at_utc": utc_now()})
            write_manifest(manifest, root / "out/flow/manifest.json")
            raise FlowError("FLOW-QOR-GATE", f"PL timing/DRC gate failed: {qor}")
        record["qor"] = qor
    record.update({"status": "succeeded", "outputs": outputs, "completed_at_utc": utc_now()})
    if action == "build":
        identity = hardware_identity_sha256(inputs, version, selected_jobs, contract, ip)
        manifest["hardware_cache"] = {
            "identity_sha256": identity,
            "input_sha256": input_hash,
            "vivado_version": version,
            "routed_dcp": ROUTED_DCP_REL.as_posix(),
            "routed_dcp_sha256": outputs[ROUTED_DCP_REL.as_posix()],
            "updated_at_utc": utc_now(),
        }
    write_manifest(manifest, root / "out/flow/manifest.json")
    print(f"[FLOW-SUCCESS] {action}; {len(outputs)} output hashes recorded")
    return 0

def parse_app_yaml(path: Path = APP_YAML) -> dict[str, str]:
    if not path.is_file():
        raise FlowError("FLOW-APP-YAML-MISSING", f"app.yaml is missing: {path}")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip("\"'")
    domain_path = values.get("domain_path", "").replace("\\", "/")
    domain = Path(domain_path).name
    if not domain.startswith("freertos_") or not domain.removeprefix("freertos_"):
        raise FlowError("FLOW-APP-DOMAIN", f"Expected FreeRTOS PS7 domain, got {domain_path!r}.")
    if not values.get("template"):
        raise FlowError("FLOW-APP-YAML", "app.yaml must name an application template.")
    return {"domain_path": domain_path, "domain": domain, "os": "freertos", "cpu": domain.removeprefix("freertos_"), "template": values["template"], "lang": values.get("lang", "")}


def _recorded_output(record: Mapping[str, object], name: str, root: Path = ROOT) -> tuple[Path, str]:
    outputs = record.get("outputs")
    hashes = record.get("output_hashes")
    if not isinstance(outputs, dict):
        raise FlowError("FLOW-STAGE-OUTPUT-MISSING", "Upstream manifest has no outputs.")
    rel, sha = (outputs.get(name), hashes.get(name)) if isinstance(hashes, dict) else (name, outputs.get(name))
    if not isinstance(rel, str) or not isinstance(sha, str):
        raise FlowError("FLOW-STAGE-OUTPUT-MISSING", f"Missing upstream output {name!r}.")
    path = safe_out_path(rel, root)
    if not path.is_file():
        raise FlowError("FLOW-STAGE-OUTPUT-MISSING", f"Upstream output missing: {rel}")
    if sha256_file(path) != sha:
        raise FlowError("FLOW-STAGE-OUTPUT-HASH", f"Upstream output hash mismatch: {rel}")
    return path, sha


def _require_hardware_build(
    root: Path = ROOT,
    vivado_version: str | None = None,
    current_ip: Mapping[str, object] | None = None,
):
    manifest = manifest_for(root)
    runs = manifest.get("runs", {})
    record = runs.get("build") if isinstance(runs, dict) else None
    if not isinstance(record, dict) or record.get("status") != "succeeded":
        raise FlowError("FLOW-HW-BUILD-REQUIRED", "Run build --stage hardware successfully first.")
    contract = contract_info(root / "config/ps_pl_contract.json")
    built = record.get("hardware_contract")
    if not isinstance(built, dict) or built.get("sha256") != contract["sha256"] or built.get("abi_build_id") != contract["abi_build_id"]:
        raise FlowError("FLOW-BUILD-ID-MISMATCH", "Current XSA manifest has a different PS/PL ID.")
    version = vivado_version or record.get("vivado_version")
    ip = current_ip if current_ip is not None else record.get("vendored_ip")
    current_inputs = stage_input_manifest(root, "hardware")
    if (
        not isinstance(version, str)
        or record.get("vivado_version") != version
        or not isinstance(ip, Mapping)
        or record.get("vendored_ip") != ip
        or not (
            _record_inputs_match(record, current_inputs, root)
            or _hardware_inputs_match_for_rekey(record, current_inputs)
        )
        or not check_out_outputs(record, root)
    ):
        raise FlowError("FLOW-HW-STAGE-STALE", "Hardware inputs or artifacts do not match the successful record; run build --stage hardware to verify/rebuild before Vitis.")
    input_hash = vivado_input_hash("build", current_inputs, version, record.get("jobs"), contract, ip)
    if (
        record.get("input_fingerprint_type") == "sha256-v1"
        and record.get("input_files") == current_inputs
        and record.get("input_sha256") == input_hash
    ):
        pass
    else:
        if not (
            _record_inputs_match(record, current_inputs, root)
            or _hardware_inputs_match_for_rekey(record, current_inputs)
        ) or not _rekey_legacy_vivado_record(
            record, current_inputs, input_hash, version, contract, ip, record.get("jobs"), root
        ):
            raise FlowError("FLOW-HW-STAGE-STALE", "Hardware stage input signature is stale; run build --stage hardware.")
        runs["build"] = record
        manifest["runs"] = runs
        if isinstance(manifest.get("hardware_cache"), dict):
            manifest["hardware_cache"].update({
                "identity_sha256": hardware_identity_sha256(current_inputs, str(version),
                                                           record.get("jobs"), contract, ip),
                "input_sha256": input_hash,
                "updated_at_utc": utc_now(),
            })
        write_manifest(manifest, root / "out/flow/manifest.json")
        print("[FLOW-CACHE-REKEY] hardware: current PL inputs and outputs match; no synthesis launched")
    xsa, xsha = _recorded_output(record, XSA_REL.as_posix(), root)
    bit, bsha = _recorded_output(record, BITSTREAM_REL.as_posix(), root)
    return manifest, record, xsa, xsha, bit, bsha, contract


def _check_stage_contract(record: Mapping[str, object], contract: Mapping[str, str], label: str) -> None:
    value = record.get("hardware_contract")
    if not isinstance(value, dict) or value.get("sha256") != contract.get("sha256") or value.get("abi_build_id") != contract.get("abi_build_id"):
        raise FlowError("FLOW-BUILD-ID-MISMATCH", f"{label} has a different hardware ABI ID.")


def _verify_stage_artifacts(result: Mapping[str, object], root: Path) -> tuple[dict[str, str], dict[str, str]]:
    artifacts = result.get("artifacts")
    if not isinstance(artifacts, dict) or not artifacts:
        raise FlowError("FLOW-STAGE-ARTIFACTS", "Vitis helper returned no artifact map.")
    outputs = {}
    hashes = {}
    for name, item in artifacts.items():
        if not isinstance(item, dict) or not isinstance(item.get("path"), str) or not isinstance(item.get("sha256"), str):
            raise FlowError("FLOW-STAGE-ARTIFACTS", f"Artifact {name!r} has no path/hash.")
        path = Path(item["path"]).resolve()
        try:
            rel = path.relative_to((root / "out").resolve()).as_posix()
        except ValueError as exc:
            raise FlowError("FLOW-STAGE-OUTPUT-OUTSIDE", f"Artifact outside out/: {path}") from exc
        if not path.is_file() or sha256_file(path) != item["sha256"]:
            raise FlowError("FLOW-STAGE-ARTIFACT-HASH", f"Artifact missing/hash mismatch: {path}")
        outputs[name] = f"out/{rel}"
        hashes[name] = item["sha256"]
    return outputs, hashes


def normalize_jobs(jobs: int | None) -> int:
    value = jobs if jobs is not None else min(8, os.cpu_count() or 1)
    if not isinstance(value, int) or value < 1 or value > 8:
        raise FlowError("FLOW-JOBS", "--jobs must be an integer from 1 through 8.")
    return value


def _rekey_legacy_vitis_record(record: dict[str, object], stage: str, inputs: Mapping[str, str],
                               input_hash: str, vitis_version: str, vivado_version: str,
                               contract: Mapping[str, str], dependencies: Mapping[str, object],
                               stage_id: str, root: Path) -> bool:
    """Reuse a Vitis artifact when unrelated whole-project inputs are removed."""
    if (record.get("status") != "succeeded" or record.get("stage") != stage
            or record.get("vitis_version") != vitis_version
            or record.get("vivado_version") != vivado_version
            or record.get("hardware_contract") != contract
            or not _record_inputs_match(record, inputs, root)
            or not check_out_outputs(record, root, "output_hashes")):
        return False
    old_deps = record.get("dependencies")
    if not isinstance(old_deps, dict):
        return False
    content_deps = {"bit_sha256", "xsa_sha256", "hardware_contract", "app_metadata",
                    "xpfm_sha256", "fsbl_sha256", "app_elf_sha256"}
    if any(name in dependencies and old_deps.get(name) != dependencies[name] for name in content_deps):
        return False
    record.update({"input_sha256": input_hash, "source_sha256": source_digest(inputs),
                   "input_files": dict(inputs), "input_partition": stage,
                   "input_partition_version": 2, "input_fingerprint_type": "sha256-v1",
                   "dependencies": dict(dependencies),
                   "stage_id": stage_id, "rekeyed_at_utc": utc_now()})
    return True


def run_vitis_stage_adapter(stage: str, vitis_text: str | None, vivado_text: str = "vivado", root: Path = ROOT, jobs: int | None = None) -> int:
    details: dict[str, object] = {"stage": stage}
    try:
        if stage not in {"platform", "app", "boot"}:
            raise FlowError("FLOW-VITIS-STAGE", f"Unsupported stage {stage!r}.")
        selected_jobs = normalize_jobs(jobs)
        if not vitis_text:
            raise FlowError("FLOW-VITIS-PATH-ABSOLUTE", "Pass --vitis as an absolute Vitis path.")
        vitis_bin = resolve_vitis_executable(vitis_text)
        vitis_version = read_vitis_version(vitis_bin)
        vivado_bin = resolve_executable(vivado_text)
        vivado_version = read_tool_version(vivado_bin)
        current_ip = contract_check(root)
        manifest, hardware, xsa, xsa_hash, bit, bit_hash, contract = _require_hardware_build(root, vivado_version, current_ip)
        metadata = parse_app_yaml(root / "src/ps/app/src/app.yaml")
        try:
            from tools import vitis_stages
        except ImportError as exc:
            raise FlowError("FLOW-VITIS-STAGES-MISSING", f"Cannot import tools.vitis_stages: {exc}") from exc
        runs = manifest.get("runs", {})
        platform_record = None
        app_record = None
        xpfm = fsbl = app_elf = None
        xpfm_hash = fsbl_hash = app_hash = None
        if stage in {"app", "boot"}:
            platform_record = runs.get("platform") if isinstance(runs, dict) else None
            if not isinstance(platform_record, dict) or platform_record.get("status") != "succeeded":
                raise FlowError("FLOW-PLATFORM-REQUIRED", "Run build --stage platform first.")
            _check_stage_contract(platform_record, contract, "platform")
            xpfm, xpfm_hash = _recorded_output(platform_record, "xpfm", root)
        if stage == "boot":
            app_record = runs.get("app") if isinstance(runs, dict) else None
            if not isinstance(app_record, dict) or app_record.get("status") != "succeeded":
                raise FlowError("FLOW-APP-REQUIRED", "Run build --stage app first.")
            _check_stage_contract(app_record, contract, "application")
            app_elf, app_hash = _recorded_output(app_record, "app_elf", root)
            fsbl, fsbl_hash = _recorded_output(platform_record, "fsbl_elf", root)
        inputs = stage_input_manifest(root, stage)
        deps: dict[str, object] = {
            "hardware_input_sha256": hardware.get("input_sha256"),
            "xsa_sha256": xsa_hash,
            "bit_sha256": bit_hash,
            "hardware_contract": contract,
        }
        if stage == "app":
            deps["app_metadata"] = metadata
        if platform_record:
            deps.update({"platform_input_sha256": platform_record.get("input_sha256"), "xpfm_sha256": xpfm_hash})
        if app_record:
            deps.update({"app_input_sha256": app_record.get("input_sha256"), "app_elf_sha256": app_hash, "fsbl_sha256": fsbl_hash})
        input_hash = digest_json({"schema_version": SCHEMA_VERSION, "stage": stage, "inputs": inputs, "dependencies": deps, "vitis_version": vitis_version, "vivado_version": vivado_version, "python_version": ".".join(map(str, sys.version_info[:3])), "jobs": selected_jobs})
        source_sha = source_digest(inputs)
        runs = manifest.setdefault("runs", {})
        if not isinstance(runs, dict):
            runs = {}
            manifest["runs"] = runs
        stage_id = f"{contract['abi_build_id'][2:].lower()}-{input_hash[:16]}"
        old = runs.get(stage)
        if isinstance(old, dict):
            if not stage_cache_valid(old, input_hash, vitis_version, root):
                if _rekey_legacy_vitis_record(old, stage, inputs, input_hash, vitis_version,
                                              vivado_version, contract, deps, stage_id, root):
                    write_manifest(manifest, root / "out/flow/manifest.json")
                    print(f"[FLOW-CACHE-REKEY] {stage}: unchanged stage inputs and verified artifacts")
            if stage_cache_valid(old, input_hash, vitis_version, root):
                print(f"[FLOW-CACHE-HIT] {stage}: input/output hashes match")
                return 0
        workspace = root / "out/vitis"
        workspace.mkdir(parents=True, exist_ok=True)
        record: dict[str, object] = {"schema_version": SCHEMA_VERSION, "action": stage, "stage": stage, "status": "running", "started_at_utc": utc_now(), "input_sha256": input_hash, "source_sha256": source_sha, "input_files": inputs, "input_partition": stage, "input_partition_version": 2, "input_fingerprint_type": "sha256-v1", "python_version": ".".join(map(str, sys.version_info[:3])), "hardware_contract": contract, "vitis_version": vitis_version, "vivado_version": vivado_version, "dependencies": deps, "stage_id": stage_id, "outputs": {}, "output_hashes": {}}
        archive_previous_failure(runs, stage)
        archive_previous_success(runs, stage)
        runs[stage] = record
        manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs, "toolchain_policy": {"vivado_required": REQUIRED_VIVADO_VERSION, "vitis_required": REQUIRED_VITIS_VERSION}})
        write_manifest(manifest, root / "out/flow/manifest.json")
        old_parallel = os.environ.get("CMAKE_BUILD_PARALLEL_LEVEL")
        os.environ["CMAKE_BUILD_PARALLEL_LEVEL"] = str(selected_jobs)
        os.environ["VITIS_BUILD_JOBS"] = str(selected_jobs)
        try:
            if stage == "platform":
                result = vitis_stages.run_platform_stage(vitis_bin, workspace, xsa, stage_id, vitis_version=vitis_version)
                required = {"xpfm", "fsbl_elf", "ps7_init_tcl"}
            elif stage == "app":
                result = vitis_stages.run_app_stage(vitis_bin, workspace, xpfm, root / "src/ps/app/src", metadata["template"], metadata["domain"], stage_id)
                required = {"app_elf"}
            else:
                bootgen = vitis_bin.parent / "bootgen"
                if not bootgen.is_file():
                    raise FlowError("FLOW-BOOTGEN-MISSING", f"bootgen missing beside Vitis: {bootgen}")
                result = vitis_stages.run_boot_stage(bootgen, workspace / f"boot-{stage_id[:12]}", fsbl, bit, app_elf, stage_id)
                required = {"boot_bin", "bif"}
        finally:
            if old_parallel is None:
                os.environ.pop("CMAKE_BUILD_PARALLEL_LEVEL", None)
            else:
                os.environ["CMAKE_BUILD_PARALLEL_LEVEL"] = old_parallel
            os.environ.pop("VITIS_BUILD_JOBS", None)
        if not isinstance(result, dict) or result.get("build_status") != "SUCCESS":
            raise FlowError("FLOW-VITIS-BUILD-FAILED", f"{stage} did not report a successful build status.")
        if stage == "platform":
            expected_heap = vitis_stages.FREERTOS_TOTAL_HEAP_SIZE
            if result.get("freertos_heap_size_bytes") != expected_heap:
                raise FlowError(
                    "FLOW-PLATFORM-HEAP",
                    f"Generated FreeRTOS heap is {result.get('freertos_heap_size_bytes')!r}; expected {expected_heap}.",
                )
        outputs, hashes = _verify_stage_artifacts(result, root)
        if not required.issubset(outputs):
            raise FlowError("FLOW-STAGE-ARTIFACTS", f"Missing required outputs: {', '.join(sorted(required-set(outputs)))}")
        summary = result.get("command_output_summary")
        if summary is None and isinstance(result.get("vitis_result"), dict):
            summary = result["vitis_result"].get("command_output_summary")
        record.update({
            "status": "succeeded", "completed_at_utc": utc_now(),
            "build_status": "SUCCESS", "outputs": outputs, "output_hashes": hashes,
            "command_output_summary": summary or "",
        })
        if isinstance(result.get("command"), list):
            record["command"] = result["command"]
        elif isinstance(result.get("commands"), list):
            record["commands"] = result["commands"]
        if stage == "platform":
            record["freertos_heap_size_bytes"] = result["freertos_heap_size_bytes"]
            record["platform_build_mode"] = result.get("platform_build_mode", "full")
        write_manifest(manifest, root / "out/flow/manifest.json")
        print(f"[FLOW-SUCCESS] {stage}; ABI {contract['abi_build_id']}; {len(outputs)} artifact(s) hashed")
        return 0
    except FlowError as exc:
        persist_stage_failure(stage, exc, root, details)
        raise
    except Exception as exc:
        error = FlowError("FLOW-VITIS-STAGE-FAILED", f"{stage} failed: {exc}")
        persist_stage_failure(stage, error, root, details)
        raise error from exc

def run_python_checks(
    root: Path = ROOT,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> int:
    inputs = list(iter_source_files(root))
    inputs.extend(
        path for base in (root / "tools", root / "scripts", root / "tests")
        if base.is_dir()
        for path in base.rglob("*.py")
        if path.is_file() and not path.is_symlink()
        and not any(part in {"build", "__pycache__", ".git"} for part in path.parts)
    )
    input_map = file_manifest(inputs, root)
    python_version = ".".join(map(str, sys.version_info[:3]))
    input_hash = digest_json({
        "schema_version": SCHEMA_VERSION, "python_version": python_version,
        "inputs": input_map,
    })
    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs
    old = runs.get("python_tests")
    if (
        isinstance(old, dict)
        and old.get("status") == "succeeded"
        and old.get("input_sha256") == input_hash
        and old.get("python_version") == python_version
        and check_out_outputs(old, root)
    ):
        print("[FLOW-CACHE-HIT] Python unit tests")
        return 0

    out = root / "out/test-python" / input_hash[:12]
    out.mkdir(parents=True, exist_ok=True)
    log = out / "unittest.log"
    record: dict[str, object] = {
        "schema_version": SCHEMA_VERSION, "action": "python_tests",
        "status": "running", "started_at_utc": utc_now(),
        "input_sha256": input_hash, "input_files": input_map,
        "input_fingerprint_type": "sha256-v1", "python_version": python_version,
        "command": [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
        "outputs": {},
    }
    archive_previous_failure(runs, "python_tests")
    archive_previous_success(runs, "python_tests")
    runs["python_tests"] = record
    manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs})
    write_manifest(manifest, root / "out/flow/manifest.json")
    result = run_captured(record["command"], root, os.environ.copy(), log, runner)
    if result.returncode:
        record.update({
            "status": "failed", "error_code": "FLOW-PYTHON-TEST",
            "error": f"unittest exited {result.returncode}",
            "completed_at_utc": utc_now(),
            "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
        })
        write_manifest(manifest, root / "out/flow/manifest.json")
        raise FlowError("FLOW-PYTHON-TEST", f"Python tests failed; see {log.relative_to(root)}")
    record.update({
        "status": "succeeded", "completed_at_utc": utc_now(),
        "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
    })
    write_manifest(manifest, root / "out/flow/manifest.json")
    print(f"[FLOW-PYTHON-TEST-SUCCESS] Python {python_version}; log={log.relative_to(root)}")
    return 0


# Host C suites compile/run into out/test-host/ with strict C99 flags.
def resolve_host_compiler(cc_text: str | None = None) -> tuple[list[str], str]:
    tokens = shlex.split(cc_text or os.environ.get("CC", "cc"))
    if not tokens:
        raise FlowError("FLOW-HOST-CC", "CC is empty.")
    compiler = resolve_executable(tokens[0])
    result = subprocess.run([str(compiler), "--version"], text=True, capture_output=True, check=False)
    if result.returncode:
        raise FlowError("FLOW-HOST-CC", f"Compiler version probe failed: {result.stderr}")
    version = next((line.strip() for line in result.stdout.splitlines() if line.strip()), compiler.name)
    return [str(compiler), *tokens[1:]], version


def run_host_checks(root: Path = ROOT, cc_text: str | None = None, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> int:
    compiler, compiler_version = resolve_host_compiler(cc_text)
    inputs = []
    for name, test_rel, sources in HOST_TESTS:
        inputs.extend([root / test_rel, *(root / source for source in sources)])
        inputs.extend(root / header for header in HOST_TEST_HEADERS.get(name, ()))
    inputs.extend(path for path in (root / "tests/ps/stubs").rglob("*") if path.is_file())
    lvgl_vendor = root / LVGL_VENDOR_REL
    if lvgl_vendor.is_dir():
        inputs.extend(
            path for path in lvgl_vendor.rglob("*")
            if path.is_file() and not path.is_symlink() and path.name != "LVGL_SOURCE_LOCK.json"
        )
    input_map = input_sha256_manifest(inputs, root)
    suite_flags = {"default": HOST_CFLAGS, "lvgl96-runtime": ("-std=gnu11", "-w", "-lm")}
    input_hash = digest_json({"suite": "host", "compiler": compiler_version, "flags": suite_flags, "inputs": input_map})
    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs
    old = runs.get("host")
    if isinstance(old, dict) and old.get("status") == "succeeded" and check_out_outputs(old, root):
        old_input_map = old.get("input_files")
        if (
            old.get("input_fingerprint_type") is None
            and old.get("input_sha256") == input_hash
            and old_input_map == input_map
            and all(isinstance(value, str) and len(value) == 64 for value in input_map.values())
        ):
            old["input_fingerprint_type"] = "sha256-v1"
            write_manifest(manifest, root / "out/flow/manifest.json")
            print("[FLOW-CACHE-REKEY] host C suites: verified existing SHA-256 input map")
        if old.get("input_sha256") == input_hash and old.get("input_fingerprint_type") == "sha256-v1":
            print("[FLOW-CACHE-HIT] host C suites")
            return 0
        if (
            old.get("compiler_version") == compiler_version
            and old.get("flags") == list(HOST_CFLAGS)
            and _record_inputs_match(old, input_map, root)
        ):
            archive_previous_success(runs, "host")
            old.update({
                "input_sha256": input_hash,
                "source_sha256": source_digest(input_map),
                "input_files": input_map,
                "input_fingerprint_type": "sha256-v1",
                "rekeyed_at_utc": utc_now(),
            })
            write_manifest(manifest, root / "out/flow/manifest.json")
            print("[FLOW-CACHE-REKEY] host: unchanged test inputs and verified outputs")
            return 0
    out = root / "out/test-host" / input_hash[:12]
    out.mkdir(parents=True, exist_ok=True)
    record: dict[str, object] = {"schema_version": SCHEMA_VERSION, "action": "host", "status": "running", "input_sha256": input_hash, "source_sha256": source_digest(input_map), "input_files": input_map, "input_fingerprint_type": "sha256-v1", "compiler_version": compiler_version, "flags": list(HOST_CFLAGS), "output_dir": out.relative_to(root).as_posix(), "outputs": {}}
    archive_previous_failure(runs, "host")
    archive_previous_success(runs, "host")
    runs["host"] = record
    manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs})
    write_manifest(manifest, root / "out/flow/manifest.json")
    run = runner or subprocess.run
    include = [
        "-I", str(root / "tests/ps/stubs"),
        "-I", str(root / "src/ps/app/src"),
        "-I", str(lvgl_vendor),
        "-I", str(lvgl_vendor / "include"),
    ]
    outputs = {}
    for name, test_rel, sources in HOST_TESTS:
        binary = out / name
        compile_log = out / f"{name}.compile.log"
        test_log = out / f"{name}.test.log"
        test_flags = suite_flags["lvgl96-runtime"][:-1] if name == "lvgl96-runtime" else HOST_CFLAGS
        link_flags = ["-lm"] if name == "lvgl96-runtime" else []
        command = [*compiler, *test_flags, *include, str(root / test_rel),
                   *(str(root / source) for source in sources), *link_flags, "-o", str(binary)]
        result = run_captured(command, out, os.environ.copy(), compile_log, run)
        if result.returncode:
            record.update({"status": "failed", "error_code": "FLOW-HOST-COMPILE", "error": f"{name} compile exit {result.returncode}"})
            write_manifest(manifest, root / "out/flow/manifest.json")
            raise FlowError("FLOW-HOST-COMPILE", f"{name} compile failed; see {compile_log.relative_to(root)}")
        result = run_captured([str(binary)], out, os.environ.copy(), test_log, run)
        if result.returncode:
            record.update({"status": "failed", "error_code": "FLOW-HOST-TEST", "error": f"{name} exit {result.returncode}"})
            write_manifest(manifest, root / "out/flow/manifest.json")
            raise FlowError("FLOW-HOST-TEST", f"{name} failed; see {test_log.relative_to(root)}")
        for path in (binary, compile_log, test_log):
            outputs[path.relative_to(root).as_posix()] = sha256_file(path)
    record.update({"status": "succeeded", "completed_at_utc": utc_now(), "outputs": outputs})
    write_manifest(manifest, root / "out/flow/manifest.json")
    print(f"[FLOW-HOST-SUCCESS] {len(HOST_TESTS)} suites; {compiler_version}")
    return 0


def _report_stage_ok(report: Mapping[str, object], name: str) -> bool:
    stages = report.get("stages")
    item = stages.get(name) if isinstance(stages, dict) else None
    return isinstance(item, dict) and item.get("status") == "succeeded"


def run_plan(target: str = "all", root: Path = ROOT) -> int:
    report = build_report(root)
    stages = report.get("stages", {})
    selected = ["hardware", "platform", "app"] + (
        ["boot"] if target in {"qspi", "all"} else []
    )
    print("Build plan (no tools launched):")
    for name in selected:
        item = stages.get(name, {}) if isinstance(stages, dict) else {}
        status = item.get("status", "pending") if isinstance(item, dict) else "pending"
        detail = item.get("detail", "no stage state") if isinstance(item, dict) else "no stage state"
        if status == "succeeded":
            action = "cache hit"
        elif name == "hardware":
            action = "full Vivado build required"
        elif name == "platform" and not _report_stage_ok(report, "hardware"):
            action = "blocked until a current XSA is available"
        elif name == "platform":
            action = "full Vitis platform first build required"
        elif name == "app" and not _report_stage_ok(report, "platform"):
            action = "blocked until the current XPFM is available"
        elif name == "app":
            action = "incremental Ninja build in stable XSA-specific directory"
        elif name == "boot" and not _report_stage_ok(report, "app"):
            action = "blocked until a current app ELF is available"
        else:
            action = "build BOOT.BIN required"
        print(f"  {name}: {action} ({status}: {detail})")
    print("  deployment: explicit only; no board writes performed by plan")
    return 0


def _validate_artifact_stages(target: str, root: Path = ROOT) -> dict[str, object]:
    if target not in {"jtag", "qspi", "all"}:
        raise FlowError("FLOW-VALIDATE-TARGET", "Validation target must be jtag, qspi, or all.")
    report = build_report(root)
    required = ["hardware", "platform", "app"]
    if target in {"qspi", "all"}:
        required.append("boot")
    stages = report.get("stages", {})
    failures = []
    for name in required:
        item = stages.get(name, {}) if isinstance(stages, dict) else {}
        if not isinstance(item, dict) or item.get("status") != "succeeded":
            detail = item.get("detail", "missing") if isinstance(item, dict) else "missing"
            failures.append(f"{name}: {detail}")
    if failures:
        raise FlowError("FLOW-VALIDATE-STAGES", "Required stages are not valid: " + "; ".join(failures))
    manifest = manifest_for(root)
    runs = manifest.get("runs", {})
    hardware = runs.get("build") if isinstance(runs, dict) else None
    qor = hardware.get("qor") if isinstance(hardware, dict) else None
    if not isinstance(qor, dict) or qor.get("validated_pass") is not True:
        qor = parse_qor_gate(root / QOR_GATE_REL)
    if qor.get("validated_pass") is not True:
        raise FlowError("FLOW-VALIDATE-QOR", f"PL timing/DRC gate failed: {qor}")
    return {"report": report, "manifest": manifest, "qor": qor}


def _select_serial_device(serial_path: str | None) -> str:
    from tools.board.validation import preferred_uart_candidates, serial_candidates
    if serial_path:
        return serial_path
    candidates = serial_candidates()
    preferred = preferred_uart_candidates(candidates)
    if len(preferred) == 1:
        return preferred[0]
    if len(candidates) == 1:
        return candidates[0]
    raise FlowError(
        "FLOW-UART-AMBIGUOUS",
        "Pass --serial with a stable /dev/serial/by-id path; candidates="
        + repr(candidates),
    )


def run_board_uart_validation(
    root: Path = ROOT, serial_path: str | None = None,
    rom_path: str | None = None, run_fps: bool = True,
) -> dict[str, object]:
    from tools.board.validation import BoardValidationError, validate_uart
    device = _select_serial_device(serial_path)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = root / "out/board/validation" / timestamp
    out.mkdir(parents=True, exist_ok=False)
    log = out / "uart.log"
    key = "validate:board"
    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs
    record: dict[str, object] = {
        "schema_version": SCHEMA_VERSION, "action": "validate", "target": "board",
        "status": "running", "serial_device": device, "rom_path": rom_path,
        "fps_test": run_fps, "started_at_utc": utc_now(), "outputs": {},
    }
    archive_previous_success(runs, key)
    runs[key] = record
    write_manifest(manifest, root / "out/flow/manifest.json")
    try:
        result = validate_uart(device, rom_path=rom_path, run_fps=run_fps)
        log.write_text(str(result["transcript"]) + "\n", encoding="utf-8")
        record.update({
            "status": "succeeded", "completed_at_utc": utc_now(),
            "rom_loaded": result["rom_loaded"], "rom_bytes": result["rom_bytes"],
            "rom_path_observed": result["rom_path"], "frame_index": result["frame_index"],
            "cycles_missing": result["cycles_missing"], "vsync_speed": result["vsync_speed"],
            "vdma_status": result["vdma_status"], "vdma_irq_count": result["vdma_irq_count"],
            "vdma_error_count": result["vdma_error_count"], "dma_error_mask": result["dma_error_mask"],
            "capture_sequence_start": result["capture_sequence_start"], "capture_sequence": result["capture_sequence"], "capture_sequence_delta": result["capture_sequence_delta"], "capture_buffer": result["capture_buffer"],
            "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
        })
        write_manifest(manifest, root / "out/flow/manifest.json")
        print(
            f"[FLOW-BOARD-VALID] UART {device}; ROM {result['rom_bytes']} bytes; "
            f"frame={result['frame_index']} CyclesMissing={result['cycles_missing']} "
            f"VDMA_ERR={result['vdma_error_count']} DMA_ERR={result['dma_error_mask']}"
        )
        return record
    except (BoardValidationError, OSError) as exc:
        record.update({
            "status": "failed", "error_code": "FLOW-BOARD-UART",
            "error": str(exc), "completed_at_utc": utc_now(),
        })
        if log.is_file():
            record["outputs"] = {log.relative_to(root).as_posix(): sha256_file(log)}
        write_manifest(manifest, root / "out/flow/manifest.json")
        raise FlowError("FLOW-BOARD-UART", str(exc)) from exc


def run_validate(
    target: str = "jtag", root: Path = ROOT, board: bool = False,
    serial_path: str | None = None, rom_path: str | None = None,
    run_fps: bool = True,
) -> int:
    validation = _validate_artifact_stages(target, root)
    qor = validation["qor"]
    print(
        f"[FLOW-VALID] PL WNS={qor['wns_ns']} ns TNS={qor['tns_ns']} ns "
        f"WHS={qor['whs_ns']} ns THS={qor['ths_ns']} ns "
        f"DRC={qor['drc_errors']} CriticalWarnings={qor['critical_warnings']}"
    )
    if board:
        run_board_uart_validation(root, serial_path, rom_path, run_fps)
    return 0


def _program_flash_targets(program_flash: Path, server_url: str) -> tuple[str, list[dict[str, str]]]:
    try:
        result = subprocess.run(
            [str(program_flash), "-jtagtargets", "-url", server_url],
            cwd=program_flash.parent, text=True, capture_output=True,
            timeout=90, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FlowError("FLOW-JTAG-PROBE", f"Cannot query JTAG targets: {exc}") from exc
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    if result.returncode:
        raise FlowError("FLOW-JTAG-PROBE", f"program_flash target query failed: {output[-2000:]}")
    pattern = re.compile(
        r"(?m)^\s*(\d+)\s+(.+?)\s+\(name\s+(\S+)\s+idcode\s+([0-9a-fA-F]+)\)\s*$"
    )
    targets = [
        {"id": m.group(1), "target_name": m.group(2).strip(),
         "device_name": m.group(3), "idcode": m.group(4).lower()}
        for m in pattern.finditer(output)
    ]
    arm = [t for t in targets if t["device_name"] == "arm_dap" and "Zybo Z7" in t["target_name"]]
    fpga = [t for t in targets if t["device_name"] == "xc7z020" and "Zybo Z7" in t["target_name"]]
    if len(arm) != 1 or len(fpga) != 1:
        raise FlowError(
            "FLOW-JTAG-TARGET",
            f"Expected one Zybo Z7-20 ARM DAP and XC7Z020 target; detected {targets}",
        )
    return arm[0]["target_name"], targets


def _start_operation_record(
    key: str, root: Path, target: str, dependencies: Mapping[str, object],
    command: list[str],
) -> tuple[dict[str, object], dict[str, object]]:
    manifest = manifest_for(root)
    runs = manifest.setdefault("runs", {})
    if not isinstance(runs, dict):
        runs = {}
        manifest["runs"] = runs
    record: dict[str, object] = {
        "schema_version": SCHEMA_VERSION, "action": "deploy", "target": target,
        "status": "running", "started_at_utc": utc_now(),
        "dependencies": dict(dependencies), "command": command, "outputs": {},
    }
    archive_previous_success(runs, key)
    runs[key] = record
    manifest.update({"schema_version": SCHEMA_VERSION, "generated_at_utc": utc_now(), "runs": runs})
    write_manifest(manifest, root / "out/flow/manifest.json")
    return manifest, record


def qspi_program_command(
    program_flash: Path, boot_bin: Path, fsbl: Path, target_name: str,
    server_url: str,
) -> list[str]:
    return [
        str(program_flash), "-f", str(boot_bin), "-fsbl", str(fsbl),
        "-flash_type", "qspi-x4-single", "-offset", "0",
        "-blank_check", "-verify", "-target_name", target_name,
        "-url", server_url,
    ]


def run_deploy(
    target: str, root: Path = ROOT, vitis_text: str | None = None,
    hw_server_url: str = "tcp:127.0.0.1:3121", run_ms: int = 1000,
) -> int:
    if target not in {"jtag", "qspi"}:
        raise FlowError("FLOW-DEPLOY-TARGET", "Deployment target must be jtag or qspi.")
    _validate_artifact_stages(target, root)
    if run_ms < 0:
        raise FlowError("FLOW-DEPLOY-RUN-MS", "--run-ms must be non-negative.")
    vitis_bin = resolve_vitis_executable(vitis_text or os.environ.get("VITIS_BIN") or "vitis")
    program_flash = vitis_bin.parent / "program_flash"
    target_name, targets = _program_flash_targets(program_flash, hw_server_url)
    manifest = manifest_for(root)
    runs = manifest.get("runs", {})
    if not isinstance(runs, dict):
        raise FlowError("FLOW-MANIFEST-RUNS", "Flow manifest has no stage records.")
    hardware, platform, app = runs.get("build"), runs.get("platform"), runs.get("app")
    if not all(isinstance(item, dict) for item in (hardware, platform, app)):
        raise FlowError("FLOW-DEPLOY-MANIFEST", "Required PL and PS stage records are missing.")
    bit, bit_sha = _recorded_output(hardware, BITSTREAM_REL.as_posix(), root)
    if target == "jtag":
        xsct = vitis_bin.parent / "xsct"
        ps_init, ps_init_sha = _recorded_output(platform, "ps7_init_tcl", root)
        app_elf, app_sha = _recorded_output(app, "app_elf", root)
        script = root / "tools/board/joint_program.tcl"
        command = [str(xsct), str(script), str(bit), str(ps_init), str(app_elf),
                   str(run_ms), hw_server_url]
        dependencies = {
            "bit_sha256": bit_sha, "ps7_init_sha256": ps_init_sha,
            "app_elf_sha256": app_sha, "arm_dap_target": target_name,
            "hw_server_url": hw_server_url,
        }
        key = "deploy:jtag"
    else:
        boot = runs.get("boot")
        if not isinstance(boot, dict):
            raise FlowError("FLOW-BOOT-REQUIRED", "Build a validated BOOT.BIN before QSPI deployment.")
        boot_bin, boot_sha = _recorded_output(boot, "boot_bin", root)
        fsbl, fsbl_sha = _recorded_output(platform, "fsbl_elf", root)
        command = qspi_program_command(
            program_flash, boot_bin, fsbl, target_name, hw_server_url
        )
        dependencies = {
            "boot_bin_sha256": boot_sha, "fsbl_sha256": fsbl_sha,
            "target_name": target_name, "offset": 0,
            "flash_type": "qspi-x4-single", "verify": True, "erase_all": False,
        }
        key = "deploy:qspi"

    out = root / "out/board/deploy" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out.mkdir(parents=True, exist_ok=False)
    log = out / f"{target}.log"
    command_record = [str(token) for token in command]
    op_manifest, record = _start_operation_record(key, root, target, dependencies, command_record)
    result = run_captured(command, root, os.environ.copy(), log)
    if result.returncode:
        record.update({
            "status": "failed", "error_code": f"FLOW-{target.upper()}-DEPLOY",
            "error": f"deployment command exited {result.returncode}",
            "completed_at_utc": utc_now(),
            "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
        })
        write_manifest(op_manifest, root / "out/flow/manifest.json")
        raise FlowError(f"FLOW-{target.upper()}-DEPLOY", f"{target} deployment failed; log={log}")
    if target == "jtag":
        expected = ("PS_SYSTEM_RESET_DONE", "PL_CONFIGURED", "PS_INITIALIZED",
                    "APP_ELF_DOWNLOADED", "APP_RUNNING")
        missing = [marker for marker in expected if marker not in result.stdout + result.stderr]
        if missing:
            record.update({
                "status": "failed", "error_code": "FLOW-JTAG-MARKERS",
                "error": f"missing XSCT markers: {missing}",
                "completed_at_utc": utc_now(),
                "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
            })
            write_manifest(op_manifest, root / "out/flow/manifest.json")
            raise FlowError("FLOW-JTAG-MARKERS", f"JTAG stage markers missing: {missing}; log={log}")
    record.update({
        "status": "succeeded", "completed_at_utc": utc_now(),
        "jtag_targets": targets,
        "outputs": {log.relative_to(root).as_posix(): sha256_file(log)},
    })
    if target == "qspi":
        record.update({"readback_verified": True, "cold_boot_verified": False})
    write_manifest(op_manifest, root / "out/flow/manifest.json")
    print(f"[FLOW-{target.upper()}-DEPLOYED] log={log.relative_to(root)}")
    return 0


def run_release(
    target: str, vivado_text: str, vitis_text: str | None,
    jobs: int | None, root: Path = ROOT,
    hw_server_url: str = "tcp:127.0.0.1:3121",
    serial_path: str | None = None, rom_path: str | None = None,
    run_fps: bool = True,
) -> int:
    if target not in {"jtag", "qspi"}:
        raise FlowError("FLOW-RELEASE-TARGET", "Release target must be jtag or qspi.")
    run_vivado_action("build", vivado_text, root, jobs=jobs)
    run_vitis_stage_adapter("platform", vitis_text, vivado_text, root, jobs)
    run_vitis_stage_adapter("app", vitis_text, vivado_text, root, jobs)
    if target == "qspi":
        run_vitis_stage_adapter("boot", vitis_text, vivado_text, root, jobs)
    run_validate(target, root)
    run_deploy(target, root, vitis_text, hw_server_url)
    if target == "jtag":
        run_board_uart_validation(root, serial_path, rom_path, run_fps)
    return 0


def run_doctor(vivado_text: str = "vivado", vitis_text: str | None = None, root: Path = ROOT) -> int:
    if sys.version_info < REQUIRED_PYTHON_VERSION:
        raise FlowError(
            "FLOW-PYTHON-VERSION",
            "Python 3.15 or newer required; use the pinned .python-version runtime.",
        )
    ip = contract_check(root)
    vivado = read_tool_version(resolve_executable(vivado_text))
    vitis = read_vitis_version(resolve_vitis_executable(vitis_text)) if vitis_text else "not probed"
    print(
        f"[FLOW-DOCTOR-OK] Python {sys.version.split()[0]}; Vivado {vivado}; Vitis {vitis}; "
        f"ABI {contract_info(root / 'config/ps_pl_contract.json')['abi_build_id']}; "
        f"rgb2dvi {ip['commit']}"
    )
    evip = ip.get("embedded_video_ip")
    if isinstance(evip, dict):
        print(f"[FLOW-EVIP-OK] {evip.get('version')}@{evip.get('commit')}")
        checkout = check_embedded_video_ip(root)
        if checkout.get("checkout_commit") and checkout.get("checkout_commit") != checkout.get("commit"):
            print(
                f"[FLOW-EVIP-DOCS-ONLY] checkout={checkout['checkout_commit']}; "
                f"pinned_code={checkout['commit']}; files={checkout.get('docs_only_paths')}"
            )
    from tools.board.validation import preferred_uart_candidates, serial_candidates
    candidates = serial_candidates()
    preferred = preferred_uart_candidates(candidates)
    print(f"[FLOW-DOCTOR-UART] candidates={candidates}; FTDI-interface-B={preferred}")
    if vitis_text:
        vitis_bin = resolve_vitis_executable(vitis_text)
        for name in ("xsct", "program_flash"):
            if not (vitis_bin.parent / name).is_file():
                raise FlowError("FLOW-BOARD-TOOL", f"Required Vitis board tool is missing: {vitis_bin.parent / name}")
        try:
            target_name, targets = _program_flash_targets(vitis_bin.parent / "program_flash", "tcp:127.0.0.1:3121")
            print(f"[FLOW-DOCTOR-JTAG] Zybo Z7-20 target={target_name}; chain={targets}")
        except FlowError as exc:
            print(f"[FLOW-DOCTOR-JTAG-PENDING] {exc}")
    return 0


def run_fatfs_apply(root: Path = ROOT, bsp_root: Path | None = None) -> int:
    command = [sys.executable, str(root / "scripts/fatfs/configure_utf8_lfn.py"), "--apply"]
    if bsp_root is not None:
        try:
            bsp_root.resolve().relative_to((root / "out").resolve())
        except ValueError as exc:
            raise FlowError("FLOW-FATFS-BSP-OUTSIDE", "--bsp-root must be beneath out/.") from exc
        command.extend(["--bsp-root", str(bsp_root.resolve())])
    result = subprocess.run(command, cwd=root, check=False)
    if result.returncode:
        raise FlowError("FLOW-FATFS-APPLY-FAILED", f"FatFs updater exited {result.returncode}.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Portable Zynq-GBA build, validation, and board flow.")
    parser.add_argument("--vivado", default=os.environ.get("VIVADO_BIN") or shutil.which("vivado") or "/tools/AMDDesignTools/2025.2.1/Vivado/bin/vivado",
                        help="Vivado executable or PATH name.")
    parser.add_argument("--out", default="out",
                        help="Repository output root; constrained to the shared out/ directory.")
    parser.add_argument("--vitis", default=os.environ.get("VITIS_BIN") or shutil.which("vitis") or "/tools/AMDDesignTools/2025.2.1/Vitis/bin/vitis",
                        help="Vitis 2025.2.1 executable.")
    subs = parser.add_subparsers(dest="action", required=True)

    subs.add_parser("doctor", help="check Python, toolchain, dependencies, UART and JTAG")
    plan = subs.add_parser("plan", help="show stage cache decisions without launching tools")
    plan.add_argument("--target", choices=("all", "jtag", "qspi"), default="all")

    check = subs.add_parser("check", help="check tools or run host C suites")
    check.add_argument("--suite", choices=("host",), default=None)

    test = subs.add_parser("test", help="run host regression or a seeded RTL test suite")
    test.add_argument("--suite", choices=("host", *SIM_SUITE_PATTERNS), default="host")
    test.add_argument("--seed", type=int, default=None)

    subs.add_parser("project", help="generate the simulation Vivado project under out/vivado/project")
    build = subs.add_parser("build", help="build one PL or PS stage")
    build.add_argument("--stage", choices=("hardware", "platform", "app", "boot"), default="hardware")
    build.add_argument("--jobs", type=int, default=None,
                       help="Build parallelism (1-8); default is min(8, available CPUs).")

    sim = subs.add_parser("sim", help="run a versioned RTL suite")
    sim.add_argument("--suite", choices=tuple(SIM_SUITE_PATTERNS), required=True)
    sim.add_argument("--seed", type=int, required=True)

    report = subs.add_parser("report", help="summarize actual manifests/reports under out/")
    report.add_argument("--json", action="store_true")

    validate = subs.add_parser("validate", help="validate artifacts and optionally query the board")
    validate.add_argument("--target", choices=("jtag", "qspi", "all"), default="jtag")
    validate.add_argument("--board", action="store_true", help="run the standard-library UART smoke check")
    validate.add_argument("--serial", default=None, help="UART device, preferably /dev/serial/by-id/...-if01-port0")
    validate.add_argument("--rom", default=None, help="optional ROM path to load; does not issue save commands")
    validate.add_argument("--skip-fps", action="store_true", help="skip the 10 second fps 10 100 sample")

    deploy = subs.add_parser("deploy", help="deploy only manifest-validated current artifacts")
    deploy.add_argument("--target", choices=("jtag", "qspi"), required=True)
    deploy.add_argument("--hw-server", default="tcp:127.0.0.1:3121")
    deploy.add_argument("--run-ms", type=int, default=1000)

    release = subs.add_parser("release", help="explicit build, validate, and deploy pipeline")
    release.add_argument("--target", choices=("jtag", "qspi"), required=True)
    release.add_argument("--jobs", type=int, default=None)
    release.add_argument("--hw-server", default="tcp:127.0.0.1:3121")
    release.add_argument("--serial", default=None)
    release.add_argument("--rom", default=None)
    release.add_argument("--skip-fps", action="store_true")

    fatfs = subs.add_parser("fatfs", help="explicitly configure a generated FatFs BSP")
    fatfs.add_argument("--apply", action="store_true")
    fatfs.add_argument("--bsp-root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if sys.version_info < REQUIRED_PYTHON_VERSION:
            raise FlowError(
                "FLOW-PYTHON-VERSION",
                "Python 3.15 or newer required; run Flow with the pinned user runtime.",
            )
        selected_out = Path(args.out).expanduser()
        if not selected_out.is_absolute():
            selected_out = ROOT / selected_out
        if selected_out.resolve() != (ROOT / "out").resolve():
            raise FlowError("FLOW-OUT-ROOT", "--out must resolve to the repository out/ directory.")

        if args.action == "doctor":
            return run_doctor(args.vivado, args.vitis)
        if args.action == "plan":
            return run_plan(args.target)
        if args.action == "check":
            return run_host_checks() if args.suite == "host" else run_doctor(args.vivado, args.vitis)
        if args.action == "test":
            if args.suite == "host":
                run_python_checks()
                return run_host_checks()
            if args.seed is None:
                raise FlowError("FLOW-SIM-SEED", "Pass --seed when running an RTL suite.")
            return run_simulation(args.suite, args.seed, args.vivado)
        if args.action == "project":
            return run_vivado_action("project", args.vivado)
        if args.action == "build":
            return (
                run_vivado_action("build", args.vivado, jobs=args.jobs)
                if args.stage == "hardware"
                else run_vitis_stage_adapter(args.stage, args.vitis, args.vivado, jobs=args.jobs)
            )
        if args.action == "sim":
            return run_simulation(args.suite, args.seed, args.vivado)
        if args.action == "report":
            return run_report(as_json=args.json)
        if args.action == "validate":
            return run_validate(
                args.target, board=args.board, serial_path=args.serial,
                rom_path=args.rom, run_fps=not args.skip_fps,
            )
        if args.action == "deploy":
            return run_deploy(args.target, vitis_text=args.vitis,
                              hw_server_url=args.hw_server, run_ms=args.run_ms)
        if args.action == "release":
            return run_release(
                args.target, args.vivado, args.vitis, args.jobs,
                hw_server_url=args.hw_server, serial_path=args.serial,
                rom_path=args.rom, run_fps=not args.skip_fps,
            )
        if args.action == "fatfs":
            if not args.apply:
                raise FlowError("FLOW-FATFS-EXPLICIT", "Pass fatfs --apply; CMake configure never patches the BSP.")
            return run_fatfs_apply(bsp_root=args.bsp_root)
        raise FlowError("FLOW-ACTION-UNSUPPORTED", f"Unsupported action {args.action!r}.")
    except FlowError as exc:
        print(f"[{exc.code}] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

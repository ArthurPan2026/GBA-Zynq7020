#!/usr/bin/env python3
"""Build the consumer FreeRTOS platform with the required heap and FatFs BSP config."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import sys

REQUIRED_HEAP_BYTES = 262144
REQUIRED_LIBRARIES = ["xilffs"]
REQUIRED_LIBRARY_CONFIG = {"XILFFS_use_lfn": "2"}
DOMAIN_NAME = "freertos_ps7_cortexa9_0"

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def find_platform_sw(platform_root: Path) -> Path:
    matches = sorted(platform_root.rglob("cortexa9_toolchain.cmake"))
    matches = [path.parent for path in matches if DOMAIN_NAME in path.as_posix()]
    exported = [path for path in matches if "/export/" in path.as_posix()]
    if exported:
        return exported[0]
    if not matches:
        raise RuntimeError(f"Generated FreeRTOS domain was not found under {platform_root}")
    return matches[0]

def find_platform_domain(platform_root: Path) -> Path:
    domain = platform_root / "ps7_cortexa9_0" / DOMAIN_NAME
    if not domain.is_dir():
        raise RuntimeError(f"FreeRTOS BSP source directory is missing: {domain}")
    return domain

def define_is(path: Path, name: str, value: str) -> bool:
    if not path.is_file():
        return False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "#define" and fields[1] == name:
            return fields[2] == value
    return False

def has_required_heap(platform_sw: Path) -> bool:
    path = platform_sw / "include/FreeRTOSConfig.h"
    if not path.is_file():
        return False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "#define" and fields[1] == "configTOTAL_HEAP_SIZE":
            digits = "".join(character for character in fields[2] if character.isdigit())
            return digits.isdigit() and int(digits) == REQUIRED_HEAP_BYTES
    return False

def has_required_lfn(platform_sw: Path) -> bool:
    return define_is(platform_sw / "include/xilffs_config.h", "FILE_SYSTEM_USE_LFN", "2")

def main() -> int:
    xsa = Path(os.environ["PS_APP_XSA"]).resolve()
    workspace = Path(os.environ["PS_APP_VITIS_WORKSPACE"]).resolve()
    if not xsa.is_file():
        raise FileNotFoundError(xsa)
    workspace.mkdir(parents=True, exist_ok=True)
    platform_name = "gba_consumer_platform"
    state_path = workspace / "platform_state.json"
    sw_path_file = workspace / "platform_sw_path.txt"
    domain_path_file = workspace / "platform_domain_path.txt"
    xsa_sha = sha256(xsa)
    vitis_root = Path(os.environ.get("VITIS_ROOT", "/tools/AMDDesignTools/2025.2.1/Vitis")).resolve()
    esw_repo = Path(os.environ.get("ESW_REPO", str(vitis_root / "data/embeddedsw"))).resolve()
    platform_config = {
        "os": "freertos",
        "cpu": "ps7_cortexa9_0",
        "domain_name": DOMAIN_NAME,
        "generate_dtb": False,
    }
    os_config = {"freertos_total_heap_size": str(REQUIRED_HEAP_BYTES)}
    platform_key = hashlib.sha256(json.dumps(
        {"xsa_sha256": xsa_sha, "vitis_root": str(vitis_root),
         "esw_repo": str(esw_repo), "platform_config": platform_config,
         "os_config": os_config, "required_libraries": REQUIRED_LIBRARIES,
         "library_config": REQUIRED_LIBRARY_CONFIG},
        sort_keys=True, separators=(",", ":"),
    ).encode("utf-8")).hexdigest()
    state = {}
    if state_path.is_file():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {}
    cached_sw = Path(sw_path_file.read_text(encoding="utf-8").strip()) if sw_path_file.is_file() else None
    cached_domain = Path(domain_path_file.read_text(encoding="utf-8").strip()) if domain_path_file.is_file() else None
    if (state.get("platform_key") == platform_key and cached_sw is not None and
            cached_domain is not None and
            (cached_sw / "cortexa9_toolchain.cmake").is_file() and
            (cached_sw / "include/xparameters.h").is_file() and
            (cached_sw / "include/ff.h").is_file() and
            (cached_sw / "lib/libxilffs.a").is_file() and
            (cached_domain / "bsp/libsrc/build_configs/gen_bsp/build.ninja").is_file() and
            has_required_heap(cached_sw) and has_required_lfn(cached_sw)):
        print(f"PS_PLATFORM_CACHE_HIT: {cached_sw}")
        return 0

    import vitis
    client = vitis.create_client()
    try:
        client.set_workspace(str(workspace))
        try:
            platform = client.get_component(name=platform_name)
        except Exception:
            platform = client.create_platform_component(
                name=platform_name, hw_design=str(xsa), **platform_config,
            )
        else:
            platform.update_hw(hw_design=str(xsa))
        domain = platform.get_domain(name=DOMAIN_NAME)
        domain.set_config(option="os", param="freertos_total_heap_size",
                          value=os_config["freertos_total_heap_size"])
        configured = {item.get("name") for item in domain.get_libs()}
        if "xilffs" not in configured:
            applicable = next((item for item in domain.get_applicable_libs()
                               if item.get("name") == "xilffs"), None)
            if applicable is None:
                raise RuntimeError("Vitis does not report xilffs as applicable to the FreeRTOS domain")
            paths = [Path(item) for item in applicable.get("paths", [])]
            library_paths = [path for path in paths if path.is_relative_to(esw_repo) and path.is_dir()]
            if not library_paths:
                library_paths = [path for path in paths if path.is_dir()]
            if not library_paths:
                raise RuntimeError(f"No installed xilffs library path found: {paths}")
            domain.set_lib(lib_name="xilffs", path=str(library_paths[0]))
        domain.set_config(option="lib", param="XILFFS_use_lfn", value="2", lib_name="xilffs")
        platform.build()
        platform_root = Path(platform.project_location).resolve()
        platform_sw = find_platform_sw(platform_root)
        platform_domain = find_platform_domain(platform_root)
        if not (platform_sw / "include/ff.h").is_file() or not (platform_sw / "lib/libxilffs.a").is_file():
            raise RuntimeError(f"xilffs was not generated in the FreeRTOS BSP at {platform_sw}")
        if not has_required_heap(platform_sw):
            raise RuntimeError(f"FreeRTOS heap did not become {REQUIRED_HEAP_BYTES} bytes at {platform_sw}")
        if not has_required_lfn(platform_sw):
            raise RuntimeError(f"xilffs LFN config did not become 2 at {platform_sw}")
        if not (platform_domain / "bsp/libsrc/build_configs/gen_bsp/build.ninja").is_file():
            raise RuntimeError(f"Generated BSP build tree is missing under {platform_domain}")
        sw_path_file.write_text(str(platform_sw) + chr(10), encoding="utf-8")
        domain_path_file.write_text(str(platform_domain) + chr(10), encoding="utf-8")
        state_path.write_text(json.dumps({
            "xsa": str(xsa),
            "xsa_sha256": xsa_sha,
            "platform_key": platform_key,
            "platform_name": platform_name,
            "domain": DOMAIN_NAME,
            "platform_sw": str(platform_sw),
            "platform_domain": str(platform_domain),
            "libraries": REQUIRED_LIBRARIES,
            "library_config": REQUIRED_LIBRARY_CONFIG,
            "os_config": os_config,
        }, sort_keys=True, indent=2) + chr(10), encoding="utf-8")
        print(f"PS_PLATFORM_UPDATE_PASS: {platform_sw} heap={REQUIRED_HEAP_BYTES} lfn=2")
    finally:
        vitis.dispose()
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[PS-PLATFORM] {exc}", file=sys.stderr)
        raise SystemExit(2)

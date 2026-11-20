"""Validated declarative RTL simulation manifest for the project flow."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Any
import tomllib


SCHEMA_VERSION = 1
_ALLOWED_SUFFIXES = {".sv", ".v", ".vhd", ".vhdl"}


class RTLManifestError(ValueError):
    """Malformed or unsafe RTL manifest."""


@dataclass(frozen=True)
class RTLBench:
    name: str
    suite: str
    top: str
    sources: tuple[str, ...]
    success_markers: tuple[str, ...]
    timeout_seconds: int | None
    parallel: bool
    resources: tuple[str, ...]


def _path(value: object, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RTLManifestError(f"{where} must be a non-empty string")
    value = value.strip().replace("\\", "/")
    rel = Path(value)
    if rel.is_absolute() or ".." in rel.parts or "\x00" in value:
        raise RTLManifestError(f"{where} must stay inside the project: {value!r}")
    return rel.as_posix()


def _strings(value: object, where: str, default: tuple[str, ...] = ()) -> tuple[str, ...]:
    if value is None:
        return default
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise RTLManifestError(f"{where} must be a string array")
    result = tuple(item.strip() for item in value)
    if len(set(result)) != len(result):
        raise RTLManifestError(f"{where} contains duplicates")
    return result


def load_rtl_manifest(root: Path) -> tuple[RTLBench, ...]:
    manifest_path = root / "tests/manifests/rtl.toml"
    try:
        with manifest_path.open("rb") as stream:
            raw: Any = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RTLManifestError(f"cannot read {manifest_path}: {exc}") from exc
    if raw.get("schema_version") != SCHEMA_VERSION:
        raise RTLManifestError(f"unsupported RTL manifest schema: {raw.get('schema_version')!r}")
    entries = raw.get("bench")
    if not isinstance(entries, list) or not entries:
        raise RTLManifestError("manifest must contain [[bench]] entries")
    benches: list[RTLBench] = []
    names: set[str] = set()
    for index, item in enumerate(entries):
        where = f"bench[{index}]"
        if not isinstance(item, dict):
            raise RTLManifestError(f"{where} must be a TOML table")
        name = item.get("name")
        suite = item.get("suite")
        top = item.get("top", name)
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or name.casefold() in names:
            raise RTLManifestError(f"{where}.name is missing or duplicated")
        if not isinstance(suite, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", suite):
            raise RTLManifestError(f"{where}.suite is required")
        if not isinstance(top, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top):
            raise RTLManifestError(f"{where}.top is required")
        source_values = item.get("sources")
        if not isinstance(source_values, list) or not source_values:
            raise RTLManifestError(f"{where}.sources must be a non-empty array")
        sources = tuple(_path(value, f"{where}.sources") for value in source_values)
        for source in sources:
            source_path = root / source
            if source_path.suffix.lower() not in _ALLOWED_SUFFIXES:
                raise RTLManifestError(f"unsupported HDL source: {source}")
            if not source_path.is_file() or source_path.is_symlink():
                raise RTLManifestError(f"missing or linked HDL source: {source}")
        markers = _strings(item.get("success_markers"), f"{where}.success_markers", ("TEST_PASS",))
        if not markers:
            raise RTLManifestError(f"{where}.success_markers must not be empty")
        timeout = item.get("timeout_seconds")
        if timeout is not None and (type(timeout) is not int or timeout <= 0):
            raise RTLManifestError(f"{where}.timeout_seconds must be positive")
        parallel = item.get("parallel", True)
        if type(parallel) is not bool:
            raise RTLManifestError(f"{where}.parallel must be boolean")
        resources = _strings(item.get("resources"), f"{where}.resources")
        benches.append(RTLBench(
            name=name.strip(),
            suite=suite.strip(),
            top=top.strip(),
            sources=sources,
            success_markers=markers,
            timeout_seconds=timeout,
            parallel=parallel,
            resources=resources,
        ))
        names.add(name.casefold())
    return tuple(benches)


def suite_names(root: Path) -> tuple[str, ...]:
    return tuple(sorted({bench.suite for bench in load_rtl_manifest(root)}))


def benches_for_suite(suite: str, root: Path) -> tuple[RTLBench, ...]:
    benches = tuple(bench for bench in load_rtl_manifest(root) if bench.suite == suite)
    if not benches:
        raise RTLManifestError(f"unknown or empty RTL suite: {suite!r}")
    return benches


def manifest_source_paths(root: Path) -> tuple[Path, ...]:
    return tuple(
        root / source
        for source in sorted({source for bench in load_rtl_manifest(root) for source in bench.sources})
    )

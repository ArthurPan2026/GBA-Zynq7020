"""Focused tests for staged Vitis source-path resolution."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "src/ps/app/src/cmake/ResolveAppSources.cmake"
CMAKE_SCRIPT = ROOT / "tests/cmake/test_resolve_app_sources.cmake"
CMAKE = shutil.which("cmake")


@unittest.skipUnless(CMAKE, "CMake is not installed")
class AppSourceResolverTests(unittest.TestCase):
    def run_case(self, scenario: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="zynq-gba cmake ") as test_root:
            return subprocess.run(
                [
                    CMAKE,
                    f"-DRESOLVER_FILE={RESOLVER}",
                    f"-DTEST_ROOT={test_root}",
                    f"-DTEST_SCENARIO={scenario}",
                    "-P",
                    str(CMAKE_SCRIPT),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_flattened_collector_name_resolves_nested_hdmi_source(self) -> None:
        result = self.run_case("nested")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_exact_path_wins_when_basename_is_duplicated(self) -> None:
        result = self.run_case("exact_path")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ambiguous_basename_fails_with_candidates(self) -> None:
        result = self.run_case("ambiguous")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous by basename", result.stdout + result.stderr)
        self.assertIn("A/duplicate.c", result.stdout + result.stderr)
        self.assertIn("B/duplicate.c", result.stdout + result.stderr)

    def test_missing_basename_fails_clearly(self) -> None:
        result = self.run_case("missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matched no staged source", result.stdout + result.stderr)

    def test_empty_selection_fails_with_clear_diagnostic(self) -> None:
        result = self.run_case("empty")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Vitis app source entries were selected", result.stdout + result.stderr)

    def test_disabled_vglite_collision_is_filtered(self) -> None:
        result = self.run_case("lvgl_disabled")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_enabled_vglite_requires_pathful_source_selection(self) -> None:
        result = self.run_case("lvgl_enabled")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("add explicit source paths", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

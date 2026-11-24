from __future__ import annotations

from pathlib import Path
import unittest

from scripts.flow.rtl_manifest import benches_for_suite, load_rtl_manifest, suite_names


ROOT = Path(__file__).resolve().parents[2]


class RTLManifestTests(unittest.TestCase):
    def test_manifest_has_unique_benches_and_all_sources(self) -> None:
        benches = load_rtl_manifest(ROOT)
        self.assertTrue(benches)
        names = {bench.name for bench in benches}
        self.assertEqual(len(names), len(benches))
        self.assertTrue({
            "tb_gba_hdmi_pcm_profile_rates",
            "tb_gba_hdmi_video_timing_profiles",
        }.issubset(names))
        self.assertEqual(set(suite_names(ROOT)), {"smoke", "memory", "cpu", "system"})
        for bench in benches:
            self.assertTrue(all((ROOT / source).is_file() for source in bench.sources))
            self.assertTrue(bench.success_markers)
            if not bench.parallel:
                self.assertIn("vivado", bench.resources)

    def test_suite_selection_is_disjoint_and_declared(self) -> None:
        selected = [
            bench.name
            for suite in suite_names(ROOT)
            for bench in benches_for_suite(suite, ROOT)
        ]
        self.assertEqual(len(selected), len(set(selected)))
        self.assertEqual(set(selected), {bench.name for bench in load_rtl_manifest(ROOT)})


if __name__ == "__main__":
    unittest.main()

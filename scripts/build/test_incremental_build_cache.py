from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))
import incremental_build_cache as cache


class IncrementalBuildCacheTests(unittest.TestCase):
    def make_tree(self, root: Path) -> tuple[Path, Path]:
        project = root / "project"
        dependency = root / "EmbeddedVideoIP"
        files = {
            "src/rtl/top/top.sv": "module top; endmodule\n",
            "src/bd/design.bd": "block design v1\n",
            "src/constraints/board.xdc": "create_clock -period 10 [get_ports clk]\n",
            "scripts/build/build_bitstream.tcl": "build flow v1\n",
            "scripts/build/bd_ip_maintenance.tcl": "repair flow v1\n",
            "scripts/build/incremental_build_cache.py": "cache helper v1\n",
            "Zynq-GBA_MisTer-Vivado.xpr": "project settings v1\n",
        }
        for relative, text in files.items():
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        (dependency / "ip_repo/panfpga/video_pipeline/src").mkdir(parents=True)
        (dependency / "VERSION").write_text("0.1.0-dev\n", encoding="utf-8")
        (dependency / "ip_repo/panfpga/video_pipeline/component.xml").write_text(
            "<component/>\n", encoding="utf-8"
        )
        (dependency / "ip_repo/panfpga/video_pipeline/src/core.sv").write_text(
            "module core; endmodule\n", encoding="utf-8"
        )
        return project, dependency

    def write_timing(self, path: Path, wns: float = 1.0, whs: float = 0.1) -> None:
        path.write_text(
            """| Design Timing Summary
 WNS(ns) TNS(ns) TNSFail TNSTotal WHS(ns) THS(ns) THSFail THSTotal WPWS(ns) TPWS(ns) PFail PTotal
  %(wns).3f 0.000 0 10 %(whs).3f 0.000 0 10 0.500 0.000 0 10
""" % {"wns": wns, "whs": whs},
            encoding="utf-8",
        )

    def test_rtl_changes_can_reuse_static_identity_but_xdc_changes_cannot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project, dependency = self.make_tree(root)
            routed = root / "source_routed.dcp"
            bitstream = project / "output.bit"
            xsa = project / "output.xsa"
            timing = root / "timing.rpt"
            routed.write_bytes(b"routed dcp")
            bitstream.write_bytes(b"bitstream")
            xsa.write_bytes(b"xsa")
            self.write_timing(timing)

            cache.record_success(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default", routed, bitstream, xsa,
                timing, 0, 0,
            )
            full_before, identity_before, current, reference = cache.prepare(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default",
            )
            self.assertTrue(current)
            self.assertTrue(reference)

            rtl = project / "src/rtl/top/top.sv"
            rtl.write_text("module top; wire changed; endmodule\n", encoding="utf-8")
            full_after, identity_after, current, reference = cache.prepare(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default",
            )
            self.assertNotEqual(full_before, full_after)
            self.assertEqual(identity_before, identity_after)
            self.assertFalse(current)
            self.assertTrue(reference)

            constraint = project / "src/constraints/board.xdc"
            constraint.write_text("create_clock -period 9 [get_ports clk]\n", encoding="utf-8")
            _, identity_changed, _, reference = cache.prepare(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default",
            )
            self.assertNotEqual(identity_after, identity_changed)
            self.assertEqual(reference, "")

    def test_last_success_cache_rejects_tampered_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project, dependency = self.make_tree(root)
            routed = root / "source_routed.dcp"
            bitstream = project / "output.bit"
            xsa = project / "output.xsa"
            timing = root / "timing.rpt"
            routed.write_bytes(b"routed dcp")
            bitstream.write_bytes(b"bitstream")
            xsa.write_bytes(b"xsa")
            self.write_timing(timing)
            cache.record_success(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default", routed, bitstream, xsa,
                timing, 0, 0,
            )
            (project / ".build_cache/last_success_routed.dcp").write_bytes(b"tampered")
            _, _, current, reference = cache.prepare(
                project, dependency, "2025.2.1", "xc7z020clg400-1",
                "synth-default", "route-default",
            )
            self.assertFalse(current)
            self.assertEqual(reference, "")

    def test_qor_gate_rejects_setup_hold_and_drc_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "timing.rpt"
            self.write_timing(report)
            self.assertTrue(cache.gate(report, 0, 0)[0])
            self.write_timing(report, wns=-0.1)
            self.assertFalse(cache.gate(report, 0, 0)[0])
            self.write_timing(report, whs=-0.1)
            self.assertFalse(cache.gate(report, 0, 0)[0])
            self.write_timing(report)
            self.assertFalse(cache.gate(report, 1, 0)[0])
            self.assertFalse(cache.gate(report, 0, 1)[0])


if __name__ == "__main__":
    unittest.main()

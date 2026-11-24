from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parents[2] / "scripts" / "flow"
sys.path.insert(0, str(HELPER_DIR))
import incremental_build_cache as gate_helper


class QorGateTests(unittest.TestCase):
    def write_timing(self, path: Path, wns: float = 1.0, whs: float = 0.1) -> None:
        path.write_text(
            """| Design Timing Summary
 WNS(ns) TNS(ns) TNSFail TNSTotal WHS(ns) THS(ns) THSFail THSTotal WPWS(ns) TPWS(ns) PFail PTotal
  %(wns).3f 0.000 0 10 %(whs).3f 0.000 0 10 0.500 0.000 0 10
""" % {"wns": wns, "whs": whs},
            encoding="utf-8",
        )

    def test_qor_gate_rejects_setup_hold_and_drc_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "timing.rpt"
            self.write_timing(report)
            self.assertTrue(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report, wns=-0.1)
            self.assertFalse(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report, whs=-0.1)
            self.assertFalse(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report)
            self.assertFalse(gate_helper.gate(report, 1, 0)[0])
            self.assertFalse(gate_helper.gate(report, 0, 1)[0])

    def test_pre_route_allows_router_to_repair_timing_but_final_gate_is_strict(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "timing.rpt"
            self.write_timing(report, wns=0.0, whs=0.1)
            self.assertFalse(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report, wns=0.1, whs=0.0)
            self.assertFalse(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report, wns=0.1, whs=-0.1)
            self.assertFalse(gate_helper.gate(report, 0, 0)[0])
            self.write_timing(report, wns=-5.6, whs=-0.1)
            self.assertTrue(gate_helper.gate(report, 0, 0, pre_route=True)[0])
            self.assertFalse(gate_helper.gate(report, 1, 0, pre_route=True)[0])
            self.assertFalse(gate_helper.gate(report, 0, 1, pre_route=True)[0])

    def test_pre_route_allows_bus_skew_repair_but_final_gate_requires_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            timing = root / "timing.rpt"
            pulse = root / "pulse_width.rpt"
            skew = root / "bus_skew.rpt"
            self.write_timing(timing, wns=-0.1, whs=-0.1)
            pulse.write_text("Pulse Width\n", encoding="utf-8")
            skew.write_text("Bus Skew Report Summary\nSlack (VIOLATED) : -0.200ns\n", encoding="utf-8")
            argv = ["incremental_build_cache.py", "gate", "--timing-report", str(timing), "--drc-errors", "0",
                    "--critical-warnings", "0", "--pulse-report", str(pulse),
                    "--bus-skew-report", str(skew), "--pre-route"]
            from unittest.mock import patch
            from contextlib import redirect_stdout
            from io import StringIO
            output = StringIO()
            with patch.object(sys, "argv", argv), redirect_stdout(output):
                self.assertEqual(gate_helper.main(), 0)
            self.assertTrue(output.getvalue().startswith("1\t"))
            output = StringIO()
            with patch.object(sys, "argv", argv[:-1]), redirect_stdout(output):
                self.assertEqual(gate_helper.main(), 0)
            self.assertTrue(output.getvalue().startswith("0\t"))

    def test_bus_skew_gate_rejects_missing_checked_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "bus_skew.rpt"
            report.write_text("Bus Skew Report Summary\nNo bus skew paths found.\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "no checked paths"):
                gate_helper.bus_skew_gate(report)


if __name__ == "__main__":
    unittest.main()

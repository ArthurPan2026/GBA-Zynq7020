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


if __name__ == "__main__":
    unittest.main()

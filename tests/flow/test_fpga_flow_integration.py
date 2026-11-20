from __future__ import annotations

from dataclasses import replace
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import tomllib
import unittest
from unittest.mock import patch

from scripts.flow import fpga_flow_artifacts as backend
from scripts.flow import run_rtl_manifest as rtl
from scripts.flow.rtl_manifest import RTLBench


ROOT = Path(__file__).resolve().parents[2]


class ProjectProfileTests(unittest.TestCase):
    def test_dependency_pin_and_deployment_policy_are_consistent(self) -> None:
        with (ROOT / "fpga-flow.toml").open("rb") as stream:
            profile = tomllib.load(stream)
        consumer = (ROOT / "scripts/vivado/embedded_video_ip_consumer.tcl").read_text()
        pin = re.search(r'set evip_expected_commit "([0-9a-f]{40})"', consumer)
        self.assertIsNotNone(pin)
        for name in ("video_pl", "video_ps"):
            self.assertEqual(profile["external_dependencies"][name]["revision"], pin.group(1))
        stages = profile["stages"]
        self.assertEqual(stages["hardware"]["external_inputs"], ["video_pl"])
        self.assertEqual(stages["app"]["external_inputs"], ["video_ps"])
        self.assertFalse(stages["deploy_qspi"]["options"]["verify"])
        self.assertTrue(stages["deploy_qspi_release"]["options"]["verify"])
        for name in ("deploy_qspi", "deploy_qspi_release"):
            self.assertEqual(stages[name]["options"]["boot_image"], "build/current/BOOT.BIN")
            self.assertEqual(stages[name]["options"]["fsbl"], "build/current/fsbl.elf")

    def test_platform_and_application_use_reported_artifact_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "platform.xpfm"
            output.write_bytes(b"platform")
            result = {"artifacts": {"xpfm": {"path": str(output),
                "sha256": hashlib.sha256(b"platform").hexdigest()}}}
            with patch.object(backend, "ROOT", root):
                self.assertEqual(backend._artifact_from_result(result, "xpfm"), output)
                output.write_bytes(b"changed")
                with self.assertRaisesRegex(backend.BackendError, "hash changed"):
                    backend._artifact_from_result(result, "xpfm")

    def test_hardware_will_not_publish_without_current_success_markers(self) -> None:
        with patch.object(backend, "_check_hw_contract"), \
             patch.object(backend, "_run", return_value="Vivado finished"), \
             patch.object(backend, "_publish") as publish:
            with self.assertRaisesRegex(backend.BackendError, "refusing to publish"):
                backend._hardware(Path("/fake/vivado"), 2)
            publish.assert_not_called()

    def test_backend_streams_and_records_tool_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = io.StringIO()
            with patch.object(backend, "BACKEND_DIR", root), redirect_stdout(output):
                text = backend._run([sys.executable, "-c", "print('GBA_BUILD_XSA=ready')"], "fake", cwd=root)
            self.assertIn("GBA_BUILD_XSA=ready", output.getvalue())
            self.assertIn("GBA_BUILD_XSA=ready", (root / "fake.log").read_text())
            self.assertIn("GBA_BUILD_XSA=ready", text)

    def test_hardware_rejects_negative_hold_even_if_pass_flag_is_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gate = root / "build/vivado/hardware/reports/qor_gate.tsv"
            gate.parent.mkdir(parents=True)
            gate.write_text("passed=1\nwns_ns=0.1\ntns_ns=0\nwhs_ns=-0.001\nths_ns=0\ndrc_errors=0\ncritical_warnings=0\n")
            markers = "GBA_BUILD_BITSTREAM=bit\nGBA_BUILD_XSA=xsa\nGBA_BUILD_ROUTED_DCP=dcp\n"
            with patch.object(backend, "ROOT", root), patch.object(backend, "_check_hw_contract"), \
                 patch.object(backend, "_run", return_value=markers), patch.object(backend, "_publish") as publish:
                with self.assertRaisesRegex(backend.BackendError, "timing and DRC"):
                    backend._hardware(Path("/fake/vivado"), 2)
                publish.assert_not_called()


class RTLRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts/flow").mkdir(parents=True)
        (self.root / "scripts/flow/rtl_manifest.py").write_text("loader")
        (self.root / "bench.sv").write_text("module bench; endmodule\n")
        self.project = self.root / "project.xpr"
        self.project.write_text("project")
        self.bench = RTLBench(name="bench", suite="smoke", top="bench", sources=("bench.sv",),
                              success_markers=("TEST_PASS",), timeout_seconds=20,
                              parallel=True, resources=())
        self.root_patch = patch.object(rtl, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.env = patch.dict(os.environ, {"FPGA_FLOW_DEPENDENCIES_JSON": json.dumps({
            "rtl_project": {"fingerprint": "project-v1", "outputs": {"project.xpr": "abc"}}}),
            "FPGA_FLOW_TOOL_VERSIONS_JSON": json.dumps({"vivado": "version 1"})})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_resume_binds_project_tool_and_log_hashes(self) -> None:
        output = self.root / "result"
        output.mkdir()
        log = output / "xsim.log"
        log.write_text("TEST_PASS: bench\n")
        fingerprint = rtl._fingerprint(self.bench, self.project, 1, Path("/fake/vivado"))
        rtl._write_state(output, self.bench, fingerprint, "passed", log_sha256=rtl._hash_file(log))
        self.assertTrue(rtl._resume_hit(self.bench, output, fingerprint))
        with patch.dict(os.environ, {"FPGA_FLOW_TOOL_VERSIONS_JSON": '{"vivado":"version 2"}'}):
            self.assertNotEqual(fingerprint, rtl._fingerprint(self.bench, self.project, 1, Path("/fake/vivado")))
        log.write_text("TEST_PASS: bench\nTEST_FAIL: later failure\n")
        self.assertFalse(rtl._resume_hit(self.bench, output, fingerprint))

    def test_nonparallel_bench_waits_for_running_benches(self) -> None:
        benches = [replace(self.bench, name="first"), replace(self.bench, name="second"),
                   replace(self.bench, name="exclusive", parallel=False)]
        lock = threading.Lock()
        active = 0
        maximum = 0
        overlap = False
        def fake_run(bench, *args):
            nonlocal active, maximum, overlap
            with lock:
                active += 1
                maximum = max(maximum, active)
                overlap |= bench.name == "exclusive" and active != 1
            time.sleep(0.04)
            with lock:
                active -= 1
        with patch.object(rtl, "_run_one", side_effect=fake_run):
            rtl._run_all(benches, Path("/fake/vivado"), self.project, self.root, 1, 2)
        self.assertEqual(maximum, 2)
        self.assertFalse(overlap)


if __name__ == "__main__":
    unittest.main()

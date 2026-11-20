from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.board import record_cold_boot, validate_capture_signal


class BoardEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.bundle = {"bundle_id": "fixture-bundle", "verification": {
            "qspi_programmed": True, "qspi_readback_verified": True},
            "verification_evidence": {"qspi_readback_verified": "qspi-run"}}
        self.attestation = {"bundle_id": "fixture-bundle", "operator": "operator",
            "cold_boot_observed": True, "speaker_signal": True,
            "power_cycle_at_utc": (self.now - timedelta(minutes=2)).isoformat()}
        selection = self._file("build/fpga-flow/runs/qspi-run/bundle-selection.json",
                               json.dumps({"bundle_id": "fixture-bundle"}))
        self._file("build/fpga-flow/runs/qspi-run/run.json", json.dumps({
            "run_id": "qspi-run", "stage": "deploy_qspi_release", "status": "succeeded",
            "command": ["program_flash", "-verify"],
            "completed_at_utc": (self.now - timedelta(minutes=3)).isoformat(),
            "evidence": {selection: self._sha(selection)}}))
        stdout = self._file("build/fpga-flow/runs/health-run/stdout.log", "healthy\n")
        self._file("build/fpga-flow/runs/health-run/run.json", json.dumps({
            "run_id": "health-run", "stage": "runtime_health", "status": "succeeded",
            "started_at_utc": (self.now - timedelta(minutes=1)).isoformat(),
            "evidence": {stdout: self._sha(stdout)}}))
        self._file("build/fpga-flow/manifest.json", json.dumps({"stages": {
            "runtime_health": {"status": "succeeded", "run_id": "health-run"}}}))

    def _file(self, relative: str, content: str) -> str:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return relative

    def _sha(self, relative: str) -> str:
        return hashlib.sha256((self.root / relative).read_bytes()).hexdigest()

    def test_attestation_requires_current_qspi_and_fresh_health_evidence(self) -> None:
        report = record_cold_boot.verify(self.root, self.bundle, self.attestation)
        self.assertTrue(report["cold_boot_verified"])
        self.assertEqual(report["qspi_run_id"], "qspi-run")
        self.attestation["power_cycle_at_utc"] = (self.now - timedelta(minutes=4)).isoformat()
        with self.assertRaisesRegex(ValueError, "after QSPI"):
            record_cold_boot.verify(self.root, self.bundle, self.attestation)

    def test_foreign_or_modified_evidence_is_rejected(self) -> None:
        self.attestation["bundle_id"] = "other"
        with self.assertRaisesRegex(ValueError, "current bundle"):
            record_cold_boot.verify(self.root, self.bundle, self.attestation)
        self.attestation["bundle_id"] = "fixture-bundle"
        (self.root / "build/fpga-flow/runs/health-run/stdout.log").write_text("modified")
        with self.assertRaisesRegex(ValueError, "hash does not match"):
            record_cold_boot.verify(self.root, self.bundle, self.attestation)

    def test_audio_status_rejects_wrong_route_and_accepts_valid_status(self) -> None:
        good = "[CMD] audio rate=48000 bits=16 mute=0 vol=45 path=HDMI route=idle requested=HDMI err=0 pcm_overflow=0\r\n> "
        with patch.object(validate_capture_signal.os, "open", return_value=42), \
             patch.object(validate_capture_signal.os, "close"), \
             patch.object(validate_capture_signal, "_configure_uart"), \
             patch.object(validate_capture_signal.termios, "tcflush"), \
             patch.object(validate_capture_signal, "_command", return_value=good):
            self.assertEqual(validate_capture_signal._audio_status("fake"), good)
        with patch.object(validate_capture_signal.os, "open", return_value=42), \
             patch.object(validate_capture_signal.os, "close"), \
             patch.object(validate_capture_signal, "_configure_uart"), \
             patch.object(validate_capture_signal.termios, "tcflush"), \
             patch.object(validate_capture_signal, "_command", return_value=good.replace("path=HDMI", "path=I2S")):
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                validate_capture_signal._audio_status("fake")


if __name__ == "__main__":
    unittest.main()

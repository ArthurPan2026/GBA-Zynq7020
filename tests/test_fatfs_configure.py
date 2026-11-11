from __future__ import annotations
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "fatfs" / "configure_utf8_lfn.py"


class FatFsConfigureTests(unittest.TestCase):
    def test_apply_and_check_target_a_vitis_domain_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "domain"
            include = root / "include"
            include.mkdir(parents=True)
            (include / "ffconf.h").write_text(
                "#define FF_CODE_PAGE 932\n#define FF_MAX_LFN 12\n"
                "#define FF_LFN_UNICODE 0\n#define FF_LFN_BUF 12\n#define FF_SFN_BUF 12\n",
                encoding="utf-8",
            )
            (include / "xilffs_config.h").write_text("/* #undef FILE_SYSTEM_USE_LFN */\n", encoding="utf-8")
            applied = subprocess.run(
                [sys.executable, str(SCRIPT), "--apply", "--bsp-root", str(root)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
            verified = subprocess.run(
                [sys.executable, str(SCRIPT), "--check", "--bsp-root", str(root)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            self.assertIn("#define FF_LFN_UNICODE\t2", (include / "ffconf.h").read_text())
            self.assertIn("#define FILE_SYSTEM_USE_LFN 2", (include / "xilffs_config.h").read_text())

    def test_missing_bsp_targets_fail_instead_of_claiming_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--check", "--bsp-root", tmp],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No ffconf.h", result.stderr)
            self.assertIn("No xilffs_config.h", result.stderr)


if __name__ == "__main__":
    unittest.main()

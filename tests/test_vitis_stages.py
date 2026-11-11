from __future__ import annotations
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys

from tools import vitis_stages


class VitisStageTests(unittest.TestCase):
    def test_app_stage_copies_sources_and_checks_real_elf(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / "src"
            (src / "Common").mkdir(parents=True)
            source_file = src / "Common" / "logic.c"
            source_file.write_text("int f(void){return 7;}\n")
            (src / "CMakeLists.txt").write_text("project(test)\n")
            (src / "app.yaml").write_text("domain_path: windows-path\n")
            (src / "compile_commands.json").write_text("[]\n")
            (src / "build").mkdir()
            (src / "build" / "old.c").write_text("stale\n")

            platform_workspace = root / "vitis-platform-workspace"
            platform_name = "zynq_gba_platform_stageid"
            platform_component = platform_workspace / platform_name
            xpfm = (
                platform_component
                / "export"
                / platform_name
                / f"{platform_name}.xpfm"
            )
            xpfm.parent.mkdir(parents=True)
            xpfm.write_bytes(b"xpfm")

            app_output = root / "out" / "vitis"

            def fake_run(_vitis, stage_root, _body, timeout=3600):
                compile("\n".join(_body), "vitis-stage.py", "exec")
                cfg = json.loads((stage_root / "app-input.json").read_text())
                vitis_workspace = Path(cfg["workspace"])
                self.assertEqual(vitis_workspace, platform_workspace.resolve())
                self.assertNotEqual(vitis_workspace, stage_root.resolve())
                self.assertTrue(platform_component.is_dir())
                self.assertTrue((stage_root / "app-input.json").is_file())
                self.assertFalse((vitis_workspace / "app-input.json").exists())
                component = Path(cfg["component_root"])
                self.assertEqual(component.parent, vitis_workspace)
                self.assertTrue(component.name.startswith("gba_app_"))
                src_copy = Path(cfg["app_source"])
                self.assertTrue(src_copy.is_relative_to(stage_root.resolve()))
                self.assertTrue((src_copy / "Common" / "logic.c").is_file())
                self.assertTrue((src_copy / "CMakeLists.txt").is_file())
                self.assertFalse((src_copy / "app.yaml").exists())
                self.assertFalse((src_copy / "compile_commands.json").exists())
                self.assertFalse((src_copy / "build" / "old.c").exists())
                elf = component / "build" / "app.elf"
                elf.parent.mkdir(parents=True)
                elf.write_bytes(b"ELF-test")
                (elf.parent / ".buildstatus").write_text("# Vitis status header\nhw=SUCCESS\n")
                return {
                    "build_status": "SUCCESS",
                    "return_value": "0",
                    "build_return": 0,
                    "elf": str(elf),
                }

            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run):
                result = vitis_stages.run_app_stage(
                    Path("/fake/vitis"),
                    app_output,
                    xpfm,
                    src,
                    "empty_application",
                    "freertos_ps7_cortexa9_0",
                    "a1b2c3d4",
                )
            self.assertEqual(result["build_status"], "SUCCESS")
            self.assertEqual(result["vitis_workspace"], str(platform_workspace.resolve()))
            self.assertEqual(
                result["artifacts"]["app_elf"]["sha256"],
                vitis_stages.sha256_file(Path(result["artifacts"]["app_elf"]["path"])),
            )
            self.assertEqual(source_file.read_text(), "int f(void){return 7;}\n")

    def test_platform_requires_success_marker_and_fsbl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")
            def fake_run(_vitis, stage_root, _body, timeout=3600):
                compile("\n".join(_body), "vitis-stage.py", "exec")
                cfg = json.loads((stage_root / "platform-input.json").read_text())
                name = cfg["name"]
                vitis_workspace = Path(cfg["workspace"])
                self.assertEqual(vitis_workspace.parent, stage_root.resolve())
                self.assertEqual(list(vitis_workspace.iterdir()), [])
                self.assertTrue((stage_root / "platform-input.json").is_file())
                self.assertFalse((vitis_workspace / "platform-input.json").exists())
                component = Path(cfg["component_root"])
                self.assertEqual(component, vitis_workspace / name)
                domain_root = Path(cfg["domain_root"])
                self.assertEqual(
                    domain_root,
                    component / "ps7_cortexa9_0" / cfg["domain"],
                )
                self.assertNotIn("zynq_fsbl", domain_root.parts)
                self.assertEqual(cfg["freertos_total_heap_size"], vitis_stages.FREERTOS_TOTAL_HEAP_SIZE)
                script = "\\n".join(_body)
                set_lib = "domain.set_lib(lib_name='xilffs')"
                set_heap = "domain.set_config(option='os', param='freertos_total_heap_size', value=cfg['freertos_total_heap_size'])"
                self.assertIn(set_heap, script)
                self.assertIn("freertos_heap_size_bytes", script)
                first_build = "first_rc = platform.build()"
                self.assertLess(script.index(set_lib), script.index(first_build))
                self.assertLess(script.index(first_build), script.index(set_heap))
                self.assertLess(script.index(set_heap), script.index("rebuild_rc = platform.build()"))
                self.assertIn("--apply", script)
                self.assertIn("--check", script)
                self.assertIn("fatfs_env = os.environ.copy()", script)
                self.assertIn("fatfs_env.pop", script)
                self.assertIn("PYTHONHOME", script)
                self.assertIn("env=fatfs_env", script)
                self.assertIn("cfg['domain_root']", script)
                xpfm = component / "export" / name / f"{name}.xpfm"
                xpfm.parent.mkdir(parents=True)
                xpfm.write_bytes(b"xpfm")
                (component / "export" / ".buildstatus").write_text("#test\nexport=SUCCESS\n")
                fsbl = component / "sw" / "boot" / "fsbl.elf"
                fsbl.parent.mkdir(parents=True)
                fsbl.write_bytes(b"fsbl")
                evidence = {
                    "export_status": "#test\nexport=SUCCESS\n",
                    "xpfm_ok": True,
                    "fsbls": [str(fsbl)],
                    "freertos_heap_size_bytes": vitis_stages.FREERTOS_TOTAL_HEAP_SIZE,
                }
                script = "\n".join(_body)
                self.assertIn("type(value) is int and value == 0", script)
                self.assertIn("--check", script)
                self.assertIn("os.path.getsize(cfg['xpfm']) > 0", script)
                self.assertIn("os.path.getsize(path) > 0", script)
                return {
                    "build_status": "SUCCESS",
                    "first_build_return": 0,
                    "heap_build_return": 0,
                    "rebuild_return": 0,
                    "first_evidence": evidence,
                    "heap_evidence": evidence,
                    "rebuild_evidence": evidence,
                    "fatfs_apply_return_code": 0,
                    "fatfs_check_return_code": 0,
                    "build_result": {"success": True},
                }
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run):
                result = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4")
            self.assertEqual(result["build_status"], "SUCCESS")
            self.assertEqual(result["freertos_heap_size_bytes"], 256 * 1024)
            self.assertIn("xpfm", result["artifacts"])
            self.assertIn("fsbl_elf", result["artifacts"])

    def test_fatfs_apply_and_check_only_touch_requested_app_domain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_domain = root / "platform" / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"
            app_ffconf = app_domain / "bsp" / "include" / "ffconf.h"
            app_xilffs = app_domain / "bsp" / "include" / "xilffs_config.h"
            app_ffconf.parent.mkdir(parents=True)
            app_ffconf.write_text(
                "#define FF_CODE_PAGE 1\n"
                "#define FF_MAX_LFN 64\n"
                "#define FF_LFN_UNICODE 0\n"
                "#define FF_LFN_BUF 255\n"
                "#define FF_SFN_BUF 12\n",
                encoding="utf-8",
            )
            app_xilffs.write_text("/* #undef FILE_SYSTEM_USE_LFN */\n", encoding="utf-8")

            fsbl_domain = root / "platform" / "zynq_fsbl" / "zynq_fsbl_bsp"
            fsbl_ffconf = fsbl_domain / "include" / "ffconf.h"
            fsbl_xilffs = fsbl_domain / "include" / "xilffs_config.h"
            fsbl_ffconf.parent.mkdir(parents=True)
            fsbl_ffconf.write_text("FSBL sentinel\n", encoding="utf-8")
            fsbl_xilffs.write_text("FSBL xilffs sentinel\n", encoding="utf-8")

            script = Path(__file__).resolve().parents[1] / "scripts" / "fatfs" / "configure_utf8_lfn.py"

            def invoke(mode, bsp_root):
                return subprocess.run(
                    [sys.executable, str(script), mode, "--bsp-root", str(bsp_root)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

            applied = invoke("--apply", app_domain)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertIn("#define FF_CODE_PAGE\t437", app_ffconf.read_text(encoding="utf-8"))
            self.assertIn("#define FILE_SYSTEM_USE_LFN 2", app_xilffs.read_text(encoding="utf-8"))
            self.assertEqual(fsbl_ffconf.read_text(encoding="utf-8"), "FSBL sentinel\n")
            self.assertEqual(fsbl_xilffs.read_text(encoding="utf-8"), "FSBL xilffs sentinel\n")

            checked = invoke("--check", app_domain)
            self.assertEqual(checked.returncode, 0, checked.stderr)

            empty_domain = root / "empty-domain"
            empty_domain.mkdir()
            no_objects = invoke("--apply", empty_domain)
            self.assertNotEqual(no_objects.returncode, 0)
            self.assertIn("No ffconf.h", no_objects.stderr)
            self.assertIn("No xilffs_config.h", no_objects.stderr)

    def test_vitis_build_return_accepts_only_true_or_integer_zero(self):
        self.assertTrue(vitis_stages._vitis_build_return_succeeded(True))
        self.assertTrue(vitis_stages._vitis_build_return_succeeded(0))
        self.assertFalse(vitis_stages._vitis_build_return_succeeded(False))
        self.assertFalse(vitis_stages._vitis_build_return_succeeded(1))
        self.assertFalse(vitis_stages._vitis_build_return_succeeded(0.0))

    def test_platform_missing_xpfm_or_fsbl_evidence_fails(self):
        for missing in ("xpfm", "fsbl"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                xsa = root / "design.xsa"
                xsa.write_bytes(b"xsa")

                def fake_run(_vitis, stage_root, _body, timeout=3600):
                    cfg = json.loads((stage_root / "platform-input.json").read_text())
                    component = Path(cfg["component_root"])
                    xpfm = component / "export" / cfg["name"] / f"{cfg['name']}.xpfm"
                    if missing != "xpfm":
                        xpfm.parent.mkdir(parents=True)
                        xpfm.write_bytes(b"xpfm")
                    fsbl = component / "sw" / "boot" / "fsbl.elf"
                    if missing != "fsbl":
                        fsbl.parent.mkdir(parents=True)
                        fsbl.write_bytes(b"fsbl")
                    evidence = {
                        "export_status": "export=SUCCESS",
                        "xpfm_ok": missing != "xpfm",
                        "fsbls": [str(fsbl)] if missing != "fsbl" else [],
                        "freertos_heap_size_bytes": vitis_stages.FREERTOS_TOTAL_HEAP_SIZE,
                    }
                    return {
                        "build_status": "SUCCESS",
                        "first_build_return": 0,
                        "heap_build_return": 0,
                        "rebuild_return": 0,
                        "first_evidence": evidence,
                        "heap_evidence": evidence,
                        "rebuild_evidence": evidence,
                        "fatfs_apply_return_code": 0,
                        "fatfs_check_return_code": 0,
                    }

                with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run):
                    with self.assertRaises(vitis_stages.VitisStageError):
                        vitis_stages.run_platform_stage(
                            Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4"
                        )

    def test_platform_fatfs_check_failure_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")

            def fake_run(_vitis, stage_root, _body, timeout=3600):
                cfg = json.loads((stage_root / "platform-input.json").read_text())
                name = cfg["name"]
                component = Path(cfg["component_root"])
                xpfm = component / "export" / name / f"{name}.xpfm"
                xpfm.parent.mkdir(parents=True)
                xpfm.write_bytes(b"xpfm")
                fsbl = component / "sw" / "boot" / "fsbl.elf"
                fsbl.parent.mkdir(parents=True)
                fsbl.write_bytes(b"fsbl")
                evidence = {
                    "export_status": "export=SUCCESS",
                    "xpfm_ok": True,
                    "fsbls": [str(fsbl)],
                    "freertos_heap_size_bytes": vitis_stages.FREERTOS_TOTAL_HEAP_SIZE,
                }
                return {
                    "build_status": "SUCCESS",
                    "first_build_return": 0,
                    "heap_build_return": 0,
                    "rebuild_return": 0,
                    "first_evidence": evidence,
                    "heap_evidence": evidence,
                    "rebuild_evidence": evidence,
                    "fatfs_apply_return_code": 0,
                    "fatfs_check_return_code": 1,
                }

            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run):
                with self.assertRaisesRegex(vitis_stages.VitisStageError, "FatFs --check failed"):
                    vitis_stages.run_platform_stage(
                        Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4"
                    )

    def test_platform_missing_success_evidence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")
            def fake_run(_vitis, stage_root, _body, timeout=3600):
                compile("\n".join(_body), "vitis-stage.py", "exec")
                cfg = json.loads((stage_root / "platform-input.json").read_text())
                name = cfg["name"]
                vitis_workspace = Path(cfg["workspace"])
                self.assertEqual(vitis_workspace.parent, stage_root.resolve())
                self.assertEqual(list(vitis_workspace.iterdir()), [])
                self.assertTrue((stage_root / "platform-input.json").is_file())
                self.assertFalse((vitis_workspace / "platform-input.json").exists())
                component = Path(cfg["component_root"])
                self.assertEqual(component, vitis_workspace / name)
                domain_root = Path(cfg["domain_root"])
                self.assertEqual(
                    domain_root,
                    component / "ps7_cortexa9_0" / cfg["domain"],
                )
                self.assertNotIn("zynq_fsbl", domain_root.parts)
                self.assertEqual(cfg["freertos_total_heap_size"], vitis_stages.FREERTOS_TOTAL_HEAP_SIZE)
                script = "\\n".join(_body)
                set_lib = "domain.set_lib(lib_name='xilffs')"
                set_heap = "domain.set_config(option='os', param='freertos_total_heap_size', value=cfg['freertos_total_heap_size'])"
                self.assertIn(set_heap, script)
                self.assertIn("freertos_heap_size_bytes", script)
                first_build = "first_rc = platform.build()"
                self.assertLess(script.index(set_lib), script.index(first_build))
                self.assertIn("--apply", script)
                self.assertIn("--check", script)
                self.assertIn("cfg['domain_root']", script)
                xpfm = component / "export" / name / f"{name}.xpfm"
                xpfm.parent.mkdir(parents=True)
                xpfm.write_bytes(b"stub")
                fsbl = component / "sw" / "boot" / "fsbl.elf"
                fsbl.parent.mkdir(parents=True)
                fsbl.write_bytes(b"fsbl")
                return {"build_status":"FAILURE","build_result":{"success":False}}
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run):
                with self.assertRaises(vitis_stages.VitisStageError):
                    vitis_stages.run_platform_stage(
                        Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4")

    def test_boot_bif_and_bootgen_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fsbl = root / "fsbl.elf"; fsbl.write_bytes(b"fsbl")
            bit = root / "design.bit"; bit.write_bytes(b"bit")
            elf = root / "app.elf"; elf.write_bytes(b"elf")
            bootgen = root / "bootgen"; bootgen.write_text("mock")
            def fake_run(cmd, cwd, text, capture_output, timeout, check):
                if "-read" in cmd:
                    return subprocess.CompletedProcess(cmd,0,"parsed","")
                output = Path(cmd[cmd.index("-o")+1])
                output.write_bytes(b"B" * 2048)
                return subprocess.CompletedProcess(cmd,0,"built","")
            with patch.object(vitis_stages.subprocess, "run", side_effect=fake_run):
                result = vitis_stages.run_boot_stage(
                    bootgen, root / "out", fsbl, bit, elf, "a1b2c3d4")
            bif = Path(result["artifacts"]["bif"]["path"]).read_text()
            self.assertIn("[bootloader]", bif)
            self.assertNotIn("destination_device", bif)
            self.assertNotIn("destination_cpu", bif)
            self.assertIn(str(elf.resolve()), bif)
            self.assertEqual(result["build_status"], "SUCCESS")
            self.assertGreater(Path(result["artifacts"]["boot_bin"]["path"]).stat().st_size, 1024)


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys

from scripts.vitis import vitis_stages


class VitisStageTests(unittest.TestCase):
    def _make_app_platform(self, root):
        workspace = root / "vitis-platform-workspace"
        name = "zynq_gba_platform_stageid"
        component = workspace / name
        xpfm = component / "export" / name / f"{name}.xpfm"
        xpfm.parent.mkdir(parents=True)
        xpfm.write_bytes(b"xpfm")
        platform_sw = component / "export" / name / "sw" / "freertos_ps7_cortexa9_0"
        (platform_sw / "include").mkdir(parents=True)
        (platform_sw / "include" / "xparameters.h").write_text("/* test */\n")
        (platform_sw / "lib").mkdir()
        (platform_sw / "lib" / "libxilffs.a").write_bytes(b"ffs")
        (platform_sw / "cortexa9_toolchain.cmake").write_text("# test\n")
        domain = component / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"
        bsp_build = domain / "bsp" / "libsrc" / "build_configs" / "gen_bsp"
        bsp_build.mkdir(parents=True)
        (bsp_build / "build.ninja").write_text("# test\n")
        return workspace, component, xpfm

    def test_app_stage_copies_sources_and_checks_real_elf(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / "src"
            (src / "Common").mkdir(parents=True)
            source_file = src / "Common" / "logic.c"
            source_file.write_text("int f(void){return 7;}\n")
            (src / "CMakeLists.txt").write_text("project(test)\n")
            (src / "UserConfig.cmake").write_text("# app config\n")
            (src / "app.yaml").write_text("domain_path: windows-path\n")
            (src / "compile_commands.json").write_text("[]\n")
            (src / "build").mkdir()
            (src / "build" / "old.c").write_text("stale\n")
            _, component, xpfm = self._make_app_platform(root)
            domain = component / "ps7_cortexa9_0" / "freertos_ps7_cortexa9_0"
            (domain / "bsp" / "include").mkdir(parents=True)
            (domain / "bsp" / "include" / "xilffs_config.h").write_text(
                "#define FILE_SYSTEM_USE_LFN 2\n")
            (domain / "bsp" / "include" / "ffconf.h").write_text("#define FF_CODE_PAGE 437\n")
            evip = root / "evip"
            (evip / "tools").mkdir(parents=True)
            (evip / "tools" / "install_ps_library.py").write_text("# test installer\n")
            (evip / "VERSION").write_text("0.1.0-dev.3\n")
            vitis_root = root / "Vitis"
            (vitis_root / "bin").mkdir(parents=True)
            (vitis_root / "bin" / "ninja").write_text("#!/bin/sh\n")
            compiler_dir = vitis_root / "gnu" / "aarch32" / "lin" / "gcc-arm-none-eabi" / "bin"
            compiler_dir.mkdir(parents=True)
            (compiler_dir / "arm-none-eabi-gcc").write_text("#!/bin/sh\n")
            cmake_path = str(root / "mock-cmake")
            Path(cmake_path).write_text("mock cmake")
            observed = {"source": None, "build": None, "build_calls": 0}

            def fake_subprocess_run(command, **kwargs):
                if command[0] == sys.executable and "install_ps_library.py" in command[1]:
                    return subprocess.CompletedProcess(command, 0, "installed\n", "")
                if command[0] == sys.executable and "configure_utf8_lfn.py" in command[1]:
                    return subprocess.CompletedProcess(command, 0, "verified\n", "")
                if command[0] == cmake_path and "--build" not in command:
                    observed["source"] = Path(command[command.index("-S") + 1])
                    observed["build"] = Path(command[command.index("-B") + 1])
                    spec = next(value.split("=", 1)[1] for value in command if value.startswith("-DCMAKE_SPECS_FILE="))
                    (observed["build"] / "CMakeCache.txt").write_text(
                        f"CMAKE_C_FLAGS:STRING=-specs={spec}\n", encoding="utf-8")
                    return subprocess.CompletedProcess(command, 0, "configured\n", "")
                if command[0] == cmake_path and "--build" in command:
                    observed["build_calls"] += 1
                    build_dir = Path(command[command.index("--build") + 1])
                    (build_dir / "app.elf").write_bytes(b"ELF-test")
                    return subprocess.CompletedProcess(command, 0, "ninja: no work to do\n", "")
                raise AssertionError(command)

            with patch.dict("os.environ", {"EMBEDDED_VIDEO_IP_REPO": str(evip), "CMAKE_BIN": cmake_path}), \
                 patch.object(vitis_stages.shutil, "which", return_value=cmake_path), \
                 patch.object(vitis_stages.subprocess, "run", side_effect=fake_subprocess_run):
                first = vitis_stages.run_app_stage(
                    vitis_root / "bin" / "vitis", root / "out" / "vitis", xpfm,
                    src, "empty_application", "freertos_ps7_cortexa9_0", "a1b2c3d4",
                )
                stable_source = observed["source"]
                stable_build = observed["build"]
                source_file.write_text("int f(void){return 8;}\n")
                second = vitis_stages.run_app_stage(
                    vitis_root / "bin" / "vitis", root / "out" / "vitis", xpfm,
                    src, "empty_application", "freertos_ps7_cortexa9_0", "changed-input",
                )

            self.assertEqual(first["build_status"], "SUCCESS")
            self.assertEqual(second["build_mode"], "incremental-capable")
            self.assertEqual(observed["source"], stable_source)
            self.assertEqual(observed["build"], stable_build)
            self.assertEqual(observed["build_calls"], 2)
            self.assertEqual((stable_source / "Common" / "logic.c").read_text(),
                             "int f(void){return 8;}\n")
            self.assertTrue((stable_source / "CMakeLists.txt").is_file())
            self.assertTrue((stable_source / "UserConfig.cmake").is_file())
            self.assertFalse((stable_source / "app.yaml").exists())
            self.assertFalse((stable_source / "compile_commands.json").exists())
            self.assertFalse((stable_source / "build" / "old.c").exists())
            self.assertEqual(second["build_path"], str(stable_build))
            self.assertTrue((Path(second["build_path"]) / "app.elf").is_file())
            self.assertEqual(
                second["artifacts"]["app_elf"]["sha256"],
                vitis_stages.sha256_file(Path(second["artifacts"]["app_elf"]["path"])),
            )

    def _platform_payload(self, stage_root, missing=None, build_status="SUCCESS"):
        cfg = json.loads((stage_root / "platform-input.json").read_text())
        component = Path(cfg["component_root"])
        xpfm = component / "export" / cfg["name"] / f"{cfg['name']}.xpfm"
        if missing != "xpfm":
            xpfm.parent.mkdir(parents=True, exist_ok=True)
            xpfm.write_bytes(b"xpfm")
        status_file = component / "export" / ".buildstatus"
        status_file.parent.mkdir(parents=True, exist_ok=True)
        status_file.write_text("export=SUCCESS\n")
        ps_init = component / "export" / cfg["name"] / "hw" / "sdt" / "ps7_init.tcl"
        ps_init.parent.mkdir(parents=True, exist_ok=True)
        ps_init.write_text("# PS init test\n")
        fsbl = component / "sw" / "boot" / "fsbl.elf"
        if missing != "fsbl":
            fsbl.parent.mkdir(parents=True, exist_ok=True)
            fsbl.write_bytes(b"fsbl")

        domain = Path(cfg["domain_root"])
        (domain / "bsp/include").mkdir(parents=True, exist_ok=True)
        (domain / "bsp/include/FreeRTOSConfig.h").write_text(
            "#define configTOTAL_HEAP_SIZE ((size_t)262144)\\n")
        (domain / "bsp/include/xilffs_config.h").write_text(
            "#define FILE_SYSTEM_USE_LFN 2\\n")
        platform_sw = component / "export" / cfg["name"] / "sw" / cfg["domain"]
        platform_sw.mkdir(parents=True, exist_ok=True)
        (platform_sw / "cortexa9_toolchain.cmake").write_text("# test\n")
        (platform_sw / "include").mkdir(exist_ok=True)
        (platform_sw / "include" / "xparameters.h").write_text("/* test */\n")
        (platform_sw / "lib").mkdir(exist_ok=True)

        ffconf = (
            "#define FF_CODE_PAGE 1\n#define FF_MAX_LFN 64\n"
            "#define FF_LFN_UNICODE 0\n#define FF_LFN_BUF 255\n#define FF_SFN_BUF 12\n"
        )
        for path in (
            domain / "bsp/include/ffconf.h",
            domain / "bsp/libsrc/xilffs/src/include/ffconf.h",
            domain / "bsp/libsrc/build_configs/gen_bsp/include/ffconf.h",
            platform_sw / "include/ffconf.h",
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(ffconf)
        xilffs = "/* #undef FILE_SYSTEM_USE_LFN */\n"
        for path in (
            domain / "bsp/include/xilffs_config.h",
            domain / "bsp/libsrc/build_configs/gen_bsp/include/xilffs_config.h",
            platform_sw / "include/xilffs_config.h",
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(xilffs)
        build_dir = domain / "bsp/libsrc/build_configs/gen_bsp"
        build_dir.mkdir(parents=True, exist_ok=True)
        (build_dir / "build.ninja").write_text("# fake ninja\n")
        toolchain_bin = stage_root / 'mock-toolchain' / 'bin'
        toolchain_bin.mkdir(parents=True, exist_ok=True)
        (toolchain_bin / 'arm-none-eabi-gcc-ar').write_text('mock gcc ar\n')
        (toolchain_bin / 'arm-none-eabi-ar').write_text('mock ar\n')
        (toolchain_bin / 'arm-none-eabi-ranlib').write_text('mock ranlib\n')
        (build_dir / 'CMakeCache.txt').write_text(
            'CMAKE_C_COMPILER_AR:FILEPATH=' + str(toolchain_bin / 'arm-none-eabi-gcc-ar') + '\n'
        )

        evidence = {
            "export_status": "export=SUCCESS\n",
            "xpfm_ok": missing != "xpfm",
            "fsbls": [str(fsbl)] if missing != "fsbl" else [],
            "freertos_heap_size_bytes": vitis_stages.FREERTOS_TOTAL_HEAP_SIZE,
        }
        return {
            "build_status": build_status,
            "build_return": 0,
            "configuration_return_values": [True, True],
            "evidence": evidence,
        }

    def _patch_platform_commands(self, check_fail=False):
        real_run = subprocess.run
        cmake_path = Path(tempfile.gettempdir()) / "flow-test-cmake"
        cmake_path.write_text("mock cmake")
        commands = []
        def fake_run(command, **kwargs):
            commands.append(list(command))
            if command[0] == str(cmake_path):
                if "--build" in command:
                    build_dir = Path(command[command.index("--build") + 1])
                    archive = build_dir / "libsrc/xilffs/src/libxilffs.a"
                    archive.parent.mkdir(parents=True, exist_ok=True)
                    archive.write_bytes(b"xilffs-archive")
                    return subprocess.CompletedProcess(command, 0, "xilffs built\n", "")
                return subprocess.CompletedProcess(command, 0, "BSP configured\n", "")
            if check_fail and "--check" in command:
                return subprocess.CompletedProcess(command, 1, "", "injected FatFs check failure")
            return real_run(command, **kwargs)
        return (
            patch.object(vitis_stages.subprocess, "run", side_effect=fake_run),
            patch.dict("os.environ", {"CMAKE_BIN": str(cmake_path)}),
            commands,
        )

    def test_platform_requires_success_marker_and_fsbl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")

            def fake_run(_vitis, stage_root, body, timeout=3600):
                compile("\n".join(body), "vitis-stage.py", "exec")
                script = "\n".join(body)
                self.assertIn("domain.set_lib(lib_name='xilffs')", script)
                self.assertIn("param='freertos_total_heap_size'", script)
                self.assertIn("param='XILFFS_use_lfn'", script)
                self.assertNotIn("--apply", script)
                self.assertNotIn("--check", script)
                self.assertEqual(script.count("platform.build()"), 1)
                self.assertLess(script.index("param='freertos_total_heap_size'"),
                                script.index("build_rc = platform.build()"))
                self.assertLess(script.index("param='XILFFS_use_lfn'"),
                                script.index("build_rc = platform.build()"))
                (stage_root / "vitis.log").write_text("Vitis v2025.2.1 (64-bit)\\n")
                return self._platform_payload(stage_root)

            patches = self._patch_platform_commands()
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run), patches[0], patches[1]:
                result = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4")
            self.assertEqual(result["build_status"], "SUCCESS")
            self.assertEqual(result["freertos_heap_size_bytes"], 256 * 1024)
            self.assertEqual(result["platform_build_mode"], "full")
            self.assertIn("xpfm", result["artifacts"])
            self.assertIn("fsbl_elf", result["artifacts"])
            self.assertIn("ps7_init_tcl", result["artifacts"])
            self.assertIn("fatfs_xilffs_log", result["artifacts"])

    def test_platform_retry_does_not_reuse_when_xsa_content_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"first-xsa")
            workspace = root / "workspace"
            calls = []

            def fake_vitis(_vitis, stage_root, _body, timeout=3600):
                calls.append(stage_root)
                (stage_root / "vitis.log").write_text("Vitis v2025.2.1 (64-bit)\\n")
                return self._platform_payload(stage_root)

            patches = self._patch_platform_commands()
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_vitis) as run_vitis, \
                 patches[0], patches[1]:
                first = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), workspace, xsa, "first-stage",
                    vitis_version="2025.2.1",
                )
                xsa.write_bytes(b"replacement-xsa")
                second = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), workspace, xsa, "second-stage",
                    vitis_version="2025.2.1",
                )
            self.assertEqual(first["platform_build_mode"], "full")
            self.assertEqual(second["platform_build_mode"], "full")
            self.assertEqual(run_vitis.call_count, 2)
            self.assertNotEqual(first["artifacts"]["xpfm"]["path"],
                                second["artifacts"]["xpfm"]["path"])

    def test_platform_retry_reuses_valid_xpfm_and_only_rebuilds_xilffs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")
            workspace = root / "workspace"
            calls = []

            def fake_vitis(_vitis, stage_root, _body, timeout=3600):
                calls.append(stage_root)
                (stage_root / "vitis.log").write_text("Vitis v2025.2.1 (64-bit)\n")
                return self._platform_payload(stage_root)

            patches = self._patch_platform_commands()
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_vitis) as run_vitis, \
                 patches[0], patches[1]:
                first = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), workspace, xsa, "first-stage",
                    vitis_version="2025.2.1",
                )
                second = vitis_stages.run_platform_stage(
                    Path("/fake/vitis"), workspace, xsa, "retry-stage",
                    vitis_version="2025.2.1",
                )
            self.assertEqual(first["platform_build_mode"], "full")
            self.assertEqual(second["platform_build_mode"], "resumed-existing")
            self.assertEqual(run_vitis.call_count, 1)
            self.assertEqual(first["artifacts"]["xpfm"]["sha256"], second["artifacts"]["xpfm"]["sha256"])
            self.assertIn("fatfs_xilffs_log", second["artifacts"])
            cmake_configure = next(command for command in patches[2]
                                   if command and '-G' in command and 'Ninja' in command)
            self.assertTrue(any(arg.startswith('-DCMAKE_AR=') and
                                arg.endswith('/arm-none-eabi-ar') for arg in cmake_configure))
            self.assertTrue(any(arg.startswith('-DCMAKE_RANLIB=') and
                                arg.endswith('/arm-none-eabi-ranlib') for arg in cmake_configure))

    def test_platform_missing_xpfm_or_fsbl_evidence_fails(self):
        for missing in ("xpfm", "fsbl"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                xsa = root / "design.xsa"
                xsa.write_bytes(b"xsa")
                with patch.object(
                    vitis_stages, "_run_vitis_script",
                    side_effect=lambda _bin, stage_root, _body, timeout=3600:
                        self._platform_payload(stage_root, missing=missing),
                ):
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
                return self._platform_payload(stage_root)
            patches = self._patch_platform_commands(check_fail=True)
            with patch.object(vitis_stages, "_run_vitis_script", side_effect=fake_run), patches[0], patches[1]:
                with self.assertRaisesRegex(vitis_stages.VitisStageError, "FatFs --check failed"):
                    vitis_stages.run_platform_stage(
                        Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4"
                    )

    def test_platform_missing_success_evidence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            xsa = root / "design.xsa"
            xsa.write_bytes(b"xsa")
            with patch.object(
                vitis_stages, "_run_vitis_script",
                side_effect=lambda _bin, stage_root, _body, timeout=3600:
                    self._platform_payload(stage_root, build_status="FAILURE"),
            ):
                with self.assertRaises(vitis_stages.VitisStageError):
                    vitis_stages.run_platform_stage(
                        Path("/fake/vitis"), root / "workspace", xsa, "a1b2c3d4"
                    )

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

            script = Path(__file__).resolve().parents[2] / "scripts" / "vitis" / "fatfs" / "configure_utf8_lfn.py"

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

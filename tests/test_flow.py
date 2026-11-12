"""Unit tests for the stdlib build-flow manifest and cache policy."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.flow import (
    HOST_TEST_HEADERS,
    FlowError,
    build_report,
    cache_is_valid,
    check_vendored_ip,
    contract_info,
    discover_suite_benches,
    digest_json,
    file_manifest,
    iter_source_files,
    render_sim_runner,
    run_simulation,
    run_vivado_action,
    run_host_checks,
    run_vitis_stage_adapter,
    resolve_vitis_executable,
    read_vitis_version,
    resolve_vitis_executable,
    build_parser,
    normalize_jobs,
    HOST_TESTS,
    source_digest,
    stage_input_paths,
    input_stat_manifest,
    vivado_input_hash,
)


class FlowManifestTests(unittest.TestCase):
    def test_project_workspace_is_separate_from_hardware_artifacts(self) -> None:
        from tools.flow import ACTION_OUTPUTS, PROJECT_REL, SIM_PROJECT_REL

        self.assertEqual(SIM_PROJECT_REL.parent, Path("out/vivado/project"))
        self.assertEqual(PROJECT_REL.parent, Path("out/vivado"))
        self.assertTrue(set(ACTION_OUTPUTS["project"]).isdisjoint(ACTION_OUTPUTS["build"]))

    def test_file_manifest_is_content_sensitive_and_uses_relative_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "src" / "one.sv"
            first.parent.mkdir()
            first.write_text("module one; endmodule\n", encoding="utf-8")
            before = file_manifest([first], root)
            self.assertEqual(set(before), {"src/one.sv"})
            self.assertNotIn(temporary, str(before))
            first.write_text("module one; wire x; endmodule\n", encoding="utf-8")
            after = file_manifest([first], root)
            self.assertNotEqual(source_digest(before), source_digest(after))

    def test_source_stat_fingerprint_tracks_file_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "source.c"
            source.parent.mkdir()
            source.write_text("int value = 1;\\n", encoding="utf-8")
            before = input_stat_manifest([source], root)
            source.write_text("int value = 20; int extra;\\n", encoding="utf-8")
            after = input_stat_manifest([source], root)
            self.assertNotEqual(before["src/source.c"], after["src/source.c"])
            self.assertNotEqual(source_digest(before), source_digest(after))

    def test_source_stat_fingerprint_tracks_normal_edits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "input.c"
            source.parent.mkdir(parents=True)
            source.write_text("int value=1;\\n", encoding="utf-8")
            before = input_stat_manifest([source], root)
            source.write_text("int value=2;\\n", encoding="utf-8")
            stat = source.stat()
            import os
            os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
            after = input_stat_manifest([source], root)
            self.assertNotEqual(before, after)
            self.assertNotEqual(source_digest(before), source_digest(after))

    def test_cached_run_requires_success_same_input_tool_and_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "out" / "design.bit"
            output.parent.mkdir()
            output.write_bytes(b"bitstream")
            output_hash = file_manifest([output], root)["out/design.bit"]
            record = {
                "status": "succeeded",
                "input_sha256": "input-v1",
                "vivado_version": "Vivado v2025.2.1 (64-bit)",
                "outputs": {"out/design.bit": output_hash},
            }
            self.assertTrue(cache_is_valid(record, "input-v1", record["vivado_version"], root))
            self.assertFalse(cache_is_valid(record, "input-v2", record["vivado_version"], root))
            self.assertFalse(cache_is_valid(record, "input-v1", "Vivado v2025.1", root))
            output.write_bytes(b"changed")
            self.assertFalse(cache_is_valid(record, "input-v1", record["vivado_version"], root))
            record["status"] = "failed"
            self.assertFalse(cache_is_valid(record, "input-v1", record["vivado_version"], root))

    def test_project_action_uses_output_tree_separate_from_hardware(self) -> None:
        import subprocess
        from tools import flow

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "rtl" / "source.sv"
            source.parent.mkdir(parents=True)
            source.write_text("module source; endmodule\n", encoding="utf-8")
            captured = {}

            def fake_vivado(command, *, cwd, env, check):
                captured["cwd"] = Path(cwd)
                captured["out_dir"] = Path(env["ZYNQ_GBA_OUT_DIR"])
                for relative_output in flow.ACTION_OUTPUTS["project"]:
                    output = root / relative_output
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(b"generated")
                return subprocess.CompletedProcess(command, 0, "", "")

            with (
                patch("tools.flow.contract_check", return_value={"sha256": "contract"}),
                patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}),
                patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")),
                patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"),
                patch("tools.flow.stage_input_paths", return_value=[source]),
            ):
                result = run_vivado_action("project", "vivado", root, runner=fake_vivado)

            isolated_dir = root / "out" / "vivado" / "project"
            self.assertEqual(result, 0)
            self.assertEqual(captured["cwd"], isolated_dir)
            self.assertEqual(captured["out_dir"], isolated_dir)
            self.assertFalse((root / flow.BITSTREAM_REL).exists())

    def test_report_requires_matching_vitis_stage_dependencies(self) -> None:
        from tools import flow

        contract = {"abi_build_id": "0x12345678", "sha256": "c" * 64}
        bit_hash = "b" * 64
        xsa_hash = "x" * 64
        xpfm_hash = "p" * 64
        fsbl_hash = "f" * 64
        app_hash = "a" * 64
        runs = {
            "build": {
                "input_sha256": "hardware-input",
                "hardware_contract": contract,
                "outputs": {
                    flow.BITSTREAM_REL.as_posix(): bit_hash,
                    flow.XSA_REL.as_posix(): xsa_hash,
                },
            },
            "platform": {
                "input_sha256": "platform-input",
                "dependencies": {
                    "hardware_input_sha256": "hardware-input",
                    "bit_sha256": bit_hash,
                    "xsa_sha256": xsa_hash,
                    "hardware_contract": contract,
                },
                "output_hashes": {"xpfm": xpfm_hash, "fsbl_elf": fsbl_hash},
            },
            "app": {
                "input_sha256": "app-input",
                "dependencies": {
                    "hardware_input_sha256": "hardware-input",
                    "bit_sha256": bit_hash,
                    "xsa_sha256": xsa_hash,
                    "hardware_contract": contract,
                    "platform_input_sha256": "platform-input",
                    "xpfm_sha256": xpfm_hash,
                },
                "output_hashes": {"app_elf": app_hash},
            },
            "boot": {
                "dependencies": {
                    "hardware_input_sha256": "hardware-input",
                    "bit_sha256": bit_hash,
                    "xsa_sha256": xsa_hash,
                    "hardware_contract": contract,
                    "platform_input_sha256": "platform-input",
                    "xpfm_sha256": xpfm_hash,
                    "fsbl_sha256": fsbl_hash,
                    "app_input_sha256": "app-input",
                    "app_elf_sha256": app_hash,
                }
            },
        }
        stage_results = {
            name: {"status": "succeeded", "detail": "recorded outputs verified"}
            for name in ("hardware", "platform", "app", "boot")
        }

        flow.validate_stage_dependencies(runs, stage_results)
        self.assertEqual(
            {name: result["status"] for name, result in stage_results.items()},
            {name: "succeeded" for name in stage_results},
        )

        runs["build"]["outputs"][flow.BITSTREAM_REL.as_posix()] = "d" * 64
        stage_results = {
            name: {"status": "succeeded", "detail": "recorded outputs verified"}
            for name in ("hardware", "platform", "app", "boot")
        }
        flow.validate_stage_dependencies(runs, stage_results)
        self.assertEqual(stage_results["hardware"]["status"], "succeeded")
        self.assertEqual(stage_results["platform"]["status"], "fail")
        self.assertEqual(stage_results["app"]["status"], "fail")
        self.assertEqual(stage_results["boot"]["status"], "fail")

    def test_vivado_action_rejects_source_mutation_without_success_cache(self) -> None:
        import subprocess

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src/rtl/common/source.sv"
            source.parent.mkdir(parents=True)
            source.write_text("module original; endmodule\\n", encoding="utf-8")

            def fake_vivado(command, *, cwd, env, check):
                source.write_text("module rewritten; endmodule\\n", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            with (
                patch("tools.flow.contract_check", return_value={"sha256": "contract"}),
                patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}),
                patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")),
                patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"),
                patch("tools.flow.stage_input_paths", return_value=[source]),
            ):
                with self.assertRaises(FlowError) as raised:
                    run_vivado_action("project", "vivado", root, runner=fake_vivado)

            self.assertEqual(raised.exception.code, "FLOW-SOURCE-MUTATED")
            manifest = __import__("json").loads((root / "out/flow/manifest.json").read_text(encoding="utf-8"))
            record = manifest["runs"]["project"]
            self.assertEqual(record["status"], "failed")
            self.assertEqual(record["error_code"], "FLOW-SOURCE-MUTATED")
            self.assertEqual(record["source_changes"]["added"], [])
            self.assertEqual(record["source_changes"]["removed"], [])
            self.assertEqual(record["source_changes"]["changed"], ["src/rtl/common/source.sv"])
            self.assertEqual(record["outputs"], {})
            self.assertFalse(cache_is_valid(record, record["input_sha256"], record["vivado_version"], root))

    def test_contract_build_id_is_derived_from_canonical_json_sha256(self) -> None:
        info = contract_info()
        self.assertEqual(len(info["sha256"]), 64)
        self.assertEqual(info["abi_build_id"], "0x" + info["sha256"][:8].upper())
        self.assertEqual(digest_json({"a": 1, "b": 2}), digest_json({"b": 2, "a": 1}))

    def test_source_inventory_finds_recursive_rtl_and_excludes_generated_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            nested_module = root / "src" / "rtl" / "common" / "nested" / "cdc_toggle_mailbox.sv"
            generated_header = root / "src" / "ps" / "platform" / "export" / "generated.h"
            vendored_ip = root / "third_party" / "digilent" / "ip" / "component.xml"
            nested_module.parent.mkdir(parents=True)
            generated_header.parent.mkdir(parents=True)
            vendored_ip.parent.mkdir(parents=True)
            nested_module.write_text("module cdc_toggle_mailbox; endmodule\n", encoding="utf-8")
            generated_header.write_text("/* generated */\n", encoding="utf-8")
            vendored_ip.write_text("<component/>\n", encoding="utf-8")
            names = {path.relative_to(root).as_posix() for path in iter_source_files(root)}
            self.assertIn("src/rtl/common/nested/cdc_toggle_mailbox.sv", names)
            self.assertIn("third_party/digilent/ip/component.xml", names)
            self.assertNotIn("src/ps/platform/export/generated.h", names)

    def test_vendored_ip_matches_immutable_dependency_lock(self) -> None:
        lock = check_vendored_ip()
        self.assertEqual(lock["commit"], "f4613fff005b098065fd5d619a2b88e55720a423")
        self.assertEqual(lock["ip_vlnv"], "digilentinc.com:ip:rgb2dvi:1.4")
        self.assertEqual(lock["core_revision"], 8)
        self.assertEqual(lock["file_count"], 20)

    def test_suite_catalog_selects_disjoint_auto_discovered_benches(self) -> None:
        selected = {
            suite: {path.name for path in discover_suite_benches(suite)}
            for suite in ("smoke", "memory", "cpu", "system")
        }
        flattened = [name for names in selected.values() for name in names]
        self.assertEqual(len(flattened), len(set(flattened)))
        expected = {path.name for path in (Path(__file__).resolve().parents[1] / "tests/rtl").glob("tb_*") if path.suffix.lower() in {".sv", ".v", ".vhd", ".vhdl"}}
        self.assertEqual(set(flattened), expected)

    def test_incomplete_suite_has_an_explicit_missing_suite_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tests/rtl").mkdir(parents=True)
            with self.assertRaises(FlowError) as raised:
                discover_suite_benches("smoke", root)
            self.assertEqual(raised.exception.code, "FLOW-SIM-SUITE-MISSING")

    def test_sim_runner_records_seed_entry_and_out_paths(self) -> None:
        project = Path("/checkout/out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr")
        output = Path("/checkout/out with spaces/sim/cpu/seed-19/run-1")
        bench = Path("/checkout/tests/rtl/tb_cpu_anwj_step.vhd")
        script = render_sim_runner(project, output, [bench], 19)
        self.assertIn("-sv_seed $seed", script)
        self.assertIn('seed=$seed', script)
        self.assertIn("set_property -name {xsim.simulate.xsim.more_options} -value $xsim_options -objects [get_filesets sim_1]", script)
        self.assertNotIn("set_property xsim.simulate.xsim.more_options $xsim_options", script)
        self.assertIn("set seed 19", script)
        self.assertIn(str(bench), script)
        self.assertIn(str(output), script)
        self.assertIn("xsim.log", script)
        self.assertIn("set sim_tcl_path", script)
        self.assertIn("xsim.simulate.custom_tcl", script)
        self.assertIn("file copy -force $simulator_log $log_path", script)
        self.assertIn("set_property -name xsim.simulate.wdb -value {}", script)
        self.assertIn("xsim.simulate.log_all_signals -value false", script)
        self.assertNotIn("set wdb_path", script)
        self.assertNotIn("-wdb [format", script)
        self.assertNotIn("-log [format", script)
        self.assertIn("export_simulation -simulator xsim -directory $bench_dir -force -absolute_path -exec", script)
        self.assertNotIn("launch_simulation", script)
        self.assertIn("puts $sim_tcl_file {run all}", script)
        self.assertIn("puts $sim_tcl_file {quit}", script)
        self.assertNotIn("-mode batch -type behavioral", script)
        zero_seed_script = render_sim_runner(project, output, [bench], 0)
        self.assertIn("set seed 0", zero_seed_script)
        self.assertIn("-testplusarg \"seed=$seed\"", zero_seed_script)

    def test_sim_mock_subprocess_uses_selected_benches_and_records_manifest_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_root = root / "tests/rtl"
            bench_root.mkdir(parents=True)
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")
            calls = []

            def fake_run(command, cwd, env, text, capture_output, check):
                calls.append((command, cwd, env))
                runner_path = Path(command[-1])
                for bench_path in bench_root.glob("tb_*"):
                    bench_output = runner_path.parent / bench_path.stem
                    bench_output.mkdir(parents=True, exist_ok=True)
                    (bench_output / "xsim.log").write_text(f"TEST_PASS {bench_path.stem}\n", encoding="utf-8")
                return __import__("subprocess").CompletedProcess(command, 0, "sim done", "")

            with patch("tools.flow.check_hardware_contract"), \
                 patch("tools.flow.check_vendored_ip", return_value={"commit": "test"}), \
                 patch("tools.flow.expected_project_record", return_value={"outputs": {"out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr": "xpr-hash"}}), \
                 patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")), \
                 patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"), \
                 patch("tools.flow.stage_input_paths", return_value=[input_file]), \
                 patch("tools.flow.file_manifest", return_value={"src/rtl/input.v": "input-hash"}), \
                 patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}), \
                 patch("tools.flow.subprocess.run", side_effect=fake_run):
                result = run_simulation("smoke", 23, "vivado", root)

            self.assertEqual(result, 0)
            self.assertEqual(len(calls), 1)
            command, cwd, env = calls[0]
            self.assertEqual(command[1:4], ["-mode", "batch", "-source"])
            self.assertTrue(str(command[4]).startswith(str(root / "out/sim/smoke/seed-23")))
            self.assertEqual(cwd, Path(command[4]).parent)
            self.assertEqual(env["ZYNQ_GBA_REPO_ROOT"], str(root))
            run_manifest = __import__("json").loads((root / "out/flow/manifest.json").read_text(encoding="utf-8"))
            record = run_manifest["runs"]["sim:smoke:seed-23"]
            self.assertEqual(record["seed"], 23)
            self.assertEqual(set(Path(path).name for path in record["entry"]), {"tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv"})
            self.assertTrue((root / record["runner"]).is_file())
            self.assertTrue(record["output_dir"].startswith("out/sim/smoke/seed-23/"))

    def test_report_never_passes_missing_manifest_or_stages_and_only_lists_real_reports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = build_report(root)
            self.assertEqual(report["overall_status"], "pending")
            self.assertEqual(report["manifest"]["status"], "pending")
            self.assertTrue(all(stage["status"] == "pending" for stage in report["stages"].values()))
            real_report = root / "out/reference/reports/timing.rpt"
            real_report.parent.mkdir(parents=True)
            real_report.write_text("WNS: 0.125\n", encoding="utf-8")
            report = build_report(root)
            self.assertEqual(report["overall_status"], "pending")
            self.assertEqual([item["path"] for item in report["reports"]], ["out/reference/reports/timing.rpt"])

    def test_report_fails_when_manifested_output_is_missing_or_corrupted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "out/vivado/design.xsa"
            output.parent.mkdir(parents=True)
            output.write_bytes(b"xsa")
            output_hash = file_manifest([output], root)["out/vivado/design.xsa"]
            manifest_path = root / "out/flow/manifest.json"
            manifest_path.parent.mkdir(parents=True)
            source = root / "src/rtl/input.sv"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("module input; endmodule\\n", encoding="utf-8")
            record = {
                "status": "succeeded",
                "outputs": {"out/vivado/design.xsa": output_hash},
                "input_files": input_stat_manifest(stage_input_paths(root, "hardware"), root),
                "input_partition_version": 2,
                "input_fingerprint_type": "stat-v1",
            }
            manifest_path.write_text(__import__("json").dumps({"schema_version": 1, "runs": {"build": record}}), encoding="utf-8")
            report = build_report(root)
            self.assertEqual(report["stages"]["hardware"]["status"], "succeeded")
            self.assertEqual(report["stages"]["platform"]["status"], "pending")
            self.assertEqual(report["overall_status"], "pending")
            output.write_bytes(b"changed")
            report = build_report(root)
            self.assertEqual(report["stages"]["hardware"]["status"], "fail")
            self.assertEqual(report["overall_status"], "fail")

    def test_sim_failed_subprocess_is_written_as_failed_and_never_cached(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_root = root / "tests/rtl"
            bench_root.mkdir(parents=True)
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")
            failed = __import__("subprocess").CompletedProcess(["vivado"], 4, "", "compile failed")
            with patch("tools.flow.check_hardware_contract"), \
                 patch("tools.flow.check_vendored_ip", return_value={"commit": "test"}), \
                 patch("tools.flow.expected_project_record", return_value={"outputs": {"out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr": "xpr-hash"}}), \
                 patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")), \
                 patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"), \
                 patch("tools.flow.stage_input_paths", return_value=[input_file]), \
                 patch("tools.flow.file_manifest", return_value={"src/rtl/input.v": "input-hash"}), \
                 patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}), \
                 patch("tools.flow.subprocess.run", return_value=failed):
                with self.assertRaises(FlowError) as raised:
                    run_simulation("smoke", 29, "vivado", root)
            self.assertEqual(raised.exception.code, "FLOW-SIM-FAILED")
            run_manifest = __import__("json").loads((root / "out/flow/manifest.json").read_text(encoding="utf-8"))
            record = run_manifest["runs"]["sim:smoke:seed-29"]
            self.assertEqual(record["status"], "failed")
            self.assertEqual(record["outputs"], {})

    def _write_hardware_manifest(self, root: Path, *, include_xsa: bool = True) -> dict[str, str]:
        import json
        from tools.flow import BITSTREAM_REL, XSA_REL
        contract_path = root / "config/ps_pl_contract.json"
        contract_path.parent.mkdir(parents=True, exist_ok=True)
        contract_path.write_text('{"schema_version":1,"abi":"host-test"}\n', encoding="utf-8")
        info = contract_info(contract_path)
        bit = root / BITSTREAM_REL
        bit.parent.mkdir(parents=True, exist_ok=True)
        bit.write_bytes(b"bit")
        outputs = {BITSTREAM_REL.as_posix(): file_manifest([bit], root)[BITSTREAM_REL.as_posix()]}
        if include_xsa:
            xsa = root / XSA_REL
            xsa.parent.mkdir(parents=True, exist_ok=True)
            xsa.write_bytes(b"xsa")
            outputs[XSA_REL.as_posix()] = file_manifest([xsa], root)[XSA_REL.as_posix()]
        source = root / "src/rtl/hardware_input.sv"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("module hardware_input; endmodule\\n", encoding="utf-8")
        inputs = input_stat_manifest(stage_input_paths(root, "hardware"), root)
        ip = {"commit": "test"}
        version = "Vivado v2025.2.1 (64-bit)"
        record = {
            "action": "build",
            "status": "succeeded",
            "input_sha256": vivado_input_hash("build", inputs, version, None, info, ip),
            "source_sha256": source_digest(inputs),
            "input_files": inputs,
            "input_partition_version": 2,
            "input_fingerprint_type": "stat-v1",
            "completed_at_utc": __import__("tools.flow", fromlist=["utc_now"]).utc_now(),
            "hardware_contract": info,
            "vendored_ip": ip,
            "vivado_version": version,
            "jobs": None,
            "outputs": outputs,
        }
        manifest_path = root / "out/flow/manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps({"schema_version":1,"runs":{"build":record}}), encoding="utf-8")
        return info

    def _patch_vitis_probe(self):
        return (
            patch("tools.flow.contract_check", return_value={"commit": "test"}),
            patch("tools.flow.resolve_vitis_executable", return_value=Path("/mock/Vitis/bin/vitis")),
            patch("tools.flow.read_vitis_version", return_value="Vitis v2025.2.1 (64-bit)"),
            patch("tools.flow.resolve_executable", return_value=Path("/mock/Vivado/bin/vivado")),
            patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"),
        )

    def test_hardware_reuse_guard_rejects_changed_rtl(self) -> None:
        from tools.flow import _require_hardware_build

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_hardware_manifest(root)
            source = root / "src/rtl/hardware_input.sv"
            source.write_text("module hardware_input; wire changed; endmodule\\n", encoding="utf-8")
            with self.assertRaises(FlowError) as raised:
                _require_hardware_build(root, "Vivado v2025.2.1 (64-bit)", {"commit": "test"})
            self.assertEqual(raised.exception.code, "FLOW-HW-STAGE-STALE")

    def test_hardware_legacy_input_record_is_rekeyed_without_build(self) -> None:
        import json
        from tools.flow import _require_hardware_build

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_hardware_manifest(root)
            manifest_path = root / "out/flow/manifest.json"
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            data["runs"]["build"]["input_sha256"] = "legacy-whole-tree-signature"
            manifest_path.write_text(json.dumps(data), encoding="utf-8")
            _require_hardware_build(root, "Vivado v2025.2.1 (64-bit)", {"commit": "test"})
            rekeyed = json.loads(manifest_path.read_text(encoding="utf-8"))["runs"]["build"]
            self.assertEqual(rekeyed["input_partition_version"], 2)
            self.assertIn("rekeyed_at_utc", rekeyed)
            self.assertEqual(rekeyed["status"], "succeeded")

    def test_vitis_version_probe_uses_documented_minus_v(self) -> None:
        calls=[]
        def fake(command, **kwargs):
            calls.append(command)
            return __import__("subprocess").CompletedProcess(command, 0, "Vitis v2025.2.1 (64-bit)\n", "")
        version = read_vitis_version(Path("/mock/vitis"), fake)
        self.assertIn("2025.2.1", version)
        self.assertEqual(calls[0][-1], "-v")

    def test_vitis_stage_rejects_missing_xsa_before_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); self._write_hardware_manifest(root, include_xsa=False)
            with self._patch_vitis_probe()[0], self._patch_vitis_probe()[1], self._patch_vitis_probe()[2], self._patch_vitis_probe()[3], self._patch_vitis_probe()[4], patch("tools.vitis_stages.run_platform_stage") as platform:
                with self.assertRaises(FlowError) as raised:
                    run_vitis_stage_adapter("platform", "/mock/Vitis/bin/vitis", "vivado", root)
            self.assertEqual(raised.exception.code, "FLOW-STAGE-OUTPUT-MISSING")
            platform.assert_not_called()
            saved=__import__("json").loads((root/"out/flow/manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["runs"]["platform"]["status"], "failed")

    def test_app_stage_rejects_missing_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); self._write_hardware_manifest(root)
            cfg=root/"src/ps/app/src/app.yaml"; cfg.parent.mkdir(parents=True,exist_ok=True)
            cfg.write_text("domain_path: ../../platform/export/platform/sw/freertos_ps7_cortexa9_0\ntemplate: empty_application\nlang: c\n",encoding="utf-8")
            contexts=self._patch_vitis_probe()
            with contexts[0],contexts[1],contexts[2],contexts[3],contexts[4]:
                with self.assertRaises(FlowError) as raised:
                    run_vitis_stage_adapter("app","/mock/Vitis/bin/vitis","vivado",root)
            self.assertEqual(raised.exception.code,"FLOW-PLATFORM-REQUIRED")

    def test_app_stage_rejects_platform_with_different_contract_id(self) -> None:
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); info=self._write_hardware_manifest(root)
            cfg=root/"src/ps/app/src/app.yaml"; cfg.parent.mkdir(parents=True,exist_ok=True)
            cfg.write_text("domain_path: ../../platform/export/platform/sw/freertos_ps7_cortexa9_0\ntemplate: empty_application\nlang: c\n",encoding="utf-8")
            xpfm=root/"out/vitis/platform.xpfm"; xpfm.parent.mkdir(parents=True,exist_ok=True); xpfm.write_bytes(b"xpfm")
            xsha=file_manifest([xpfm],root)["out/vitis/platform.xpfm"]
            manifest_path=root/"out/flow/manifest.json"; manifest=json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["runs"]["platform"]={"action":"platform","status":"succeeded","hardware_contract":{"sha256":"wrong","abi_build_id":"0x00000000"},"outputs":{"xpfm":"out/vitis/platform.xpfm"},"output_hashes":{"xpfm":xsha}}
            manifest_path.write_text(json.dumps(manifest),encoding="utf-8")
            contexts=self._patch_vitis_probe()
            with contexts[0],contexts[1],contexts[2],contexts[3],contexts[4]:
                with self.assertRaises(FlowError) as raised:
                    run_vitis_stage_adapter("app","/mock/Vitis/bin/vitis","vivado",root)
            self.assertEqual(raised.exception.code,"FLOW-BUILD-ID-MISMATCH")

    def test_vitis_stage_failure_is_manifested_failed_not_cached(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); self._write_hardware_manifest(root)
            cfg=root/"src/ps/app/src/app.yaml"; cfg.parent.mkdir(parents=True,exist_ok=True)
            cfg.write_text("domain_path: ../../platform/export/platform/sw/freertos_ps7_cortexa9_0\ntemplate: empty_application\nlang: c\n",encoding="utf-8")
            contexts=self._patch_vitis_probe()
            with contexts[0],contexts[1],contexts[2],contexts[3],contexts[4], patch("tools.vitis_stages.run_platform_stage",side_effect=RuntimeError("mock failure")):
                with self.assertRaises(FlowError) as raised:
                    run_vitis_stage_adapter("platform","/mock/Vitis/bin/vitis","vivado",root)
            self.assertEqual(raised.exception.code,"FLOW-VITIS-STAGE-FAILED")
            saved=__import__("json").loads((root/"out/flow/manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["runs"]["platform"]["status"],"failed")
            self.assertEqual(saved["runs"]["platform"]["outputs"],{})

    def test_host_suite_mock_compiles_and_runs_only_under_out(self) -> None:
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for name,test_rel,sources in __import__("tools.flow",fromlist=["HOST_TESTS"]).HOST_TESTS:
                for rel in (test_rel,*sources,*HOST_TEST_HEADERS.get(name,())):
                    path=root/rel; path.parent.mkdir(parents=True,exist_ok=True); path.write_text("int placeholder;\n",encoding="utf-8")
            (root/"tests/ps/stubs/xil_types.h").parent.mkdir(parents=True,exist_ok=True)
            (root/"tests/ps/stubs/xil_types.h").write_text("/* stub */\n",encoding="utf-8")
            (root/"tests/ps/stubs/xstatus.h").write_text("/* stub */\n",encoding="utf-8")
            calls=[]
            def fake(command,cwd,env,text,capture_output,check):
                calls.append(command)
                if "-o" in command:
                    Path(command[command.index("-o")+1]).write_bytes(b"binary")
                return subprocess.CompletedProcess(command,0,"ok\n","")
            with patch("tools.flow.resolve_host_compiler",return_value=(["/mock/cc"],"mock cc 1")):
                run_host_checks(root,runner=fake)
            self.assertEqual(len(calls), 2 * len(HOST_TESTS))
            self.assertTrue(all(str(root/"out/test-host") in " ".join(command) for command in calls))
            record=__import__("json").loads((root/"out/flow/manifest.json").read_text(encoding="utf-8"))["runs"]["host"]
            self.assertEqual(record["status"],"succeeded")
            self.assertIn("src/ps/app/src/Input/Drivers/ps_app_input_profile.c", record["input_files"])
            self.assertIn("src/ps/app/src/App/Inc/ps_app_console_line.h", record["input_files"])
            self.assertTrue(all(path.startswith("out/") for path in record["outputs"]))

    def test_vitis_resolution_and_build_jobs_cli(self) -> None:
        resolved = Path("/mock/Vitis/bin/vitis")
        with patch("tools.flow.resolve_executable", return_value=resolved) as resolver:
            self.assertEqual(resolve_vitis_executable("vitis"), resolved)
            resolver.assert_called_once_with("vitis")
        args = build_parser().parse_args(["--out", "out", "build", "--stage", "platform", "--jobs", "4"])
        self.assertEqual(args.stage, "platform")
        self.assertEqual(args.jobs, 4)
        self.assertEqual(normalize_jobs(1), 1)
        self.assertEqual(normalize_jobs(8), 8)
        with self.assertRaises(FlowError):
            normalize_jobs(9)

    def test_sim_missing_test_pass_marker_fails_and_is_not_cached(self) -> None:
        self._run_mock_sim_log_case("ordinary completion without marker", "FLOW-SIM-PASS-MISSING", 31)

    def test_sim_explicit_fail_marker_fails_even_when_pass_is_present(self) -> None:
        self._run_mock_sim_log_case("TEST_PASS tb\nFAIL assertion\n", "FLOW-SIM-ASSERTION", 32)

    def test_sim_vhdl_zero_failure_counter_is_not_failure(self) -> None:
        self._run_mock_sim_log_case("TEST_PASS tb\nFAIL: 0\n", None, 33)

    def _run_mock_sim_log_case(self, log_text: str, expected_code: str | None, seed: int) -> None:
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_root = root / "tests/rtl"
            bench_root.mkdir(parents=True)
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")

            def fake_run(command, cwd, env, text, capture_output, check):
                runner_path = Path(command[-1])
                for bench_path in bench_root.glob("tb_*"):
                    bench_output = runner_path.parent / bench_path.stem
                    bench_output.mkdir(parents=True, exist_ok=True)
                    (bench_output / "xsim.log").write_text(log_text, encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "simulation ended", "")

            with patch("tools.flow.check_hardware_contract"), \
                 patch("tools.flow.check_vendored_ip", return_value={"commit": "test"}), \
                 patch("tools.flow.expected_project_record", return_value={"outputs": {"out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr": "xpr-hash"}}), \
                 patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")), \
                 patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"), \
                 patch("tools.flow.stage_input_paths", return_value=[input_file]), \
                 patch("tools.flow.file_manifest", return_value={"src/rtl/input.v": "input-hash"}), \
                 patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}), \
                 patch("tools.flow.subprocess.run", side_effect=fake_run):
                if expected_code is None:
                    self.assertEqual(run_simulation("smoke", seed, "vivado", root), 0)
                else:
                    with self.assertRaises(FlowError) as raised:
                        run_simulation("smoke", seed, "vivado", root)
                    self.assertEqual(raised.exception.code, expected_code)
            run_manifest = __import__("json").loads((root / "out/flow/manifest.json").read_text(encoding="utf-8"))
            record = run_manifest["runs"][f"sim:smoke:seed-{seed}"]
            if expected_code is None:
                self.assertEqual(record["status"], "succeeded")
                self.assertTrue(record["outputs"])
            else:
                self.assertEqual(record["status"], "failed")
                self.assertEqual(record["outputs"], {})


class StageInputSelectionTests(unittest.TestCase):
    def _create_input_tree(self, root: Path) -> dict[str, Path]:
        fixture_contents = {
            "config/ps_pl_contract.json": '{"schema_version":1,"abi":"test"}\n',
            "tools/flow.py": "# flow\n",
            "tools/generate_hw_contract.py": "# generator\n",
            "tools/vitis_stages.py": "# Vitis stages\n",
            "scripts/build/bd_ip_maintenance.tcl": "# BD and IP configuration\n",
            "scripts/build/rebuild_project.tcl": "# project creation\n",
            "scripts/build/build_bitstream.tcl": "# hardware build\n",
            "src/rtl/core/gba_core.sv": "module gba_core; endmodule\n",
            "src/constraints/zybo_z7_20.xdc": "set_property PACKAGE_PIN K17 [get_ports clk]\n",
            "src/bd/zynq_gba_system/zynq_gba_system.bd": '{"design":"zynq_gba_system"}\n',
            "src/bd/zynq_gba_system/ipshared/abc/hdl/ip_core.v": "module ip_core; endmodule\n",
            "src/ps/app/src/app.yaml": "template: standalone\ndomain: standalone_domain\n",
            "src/ps/app/src/CMakeLists.txt": "project(test_app C)\n",
            "src/ps/app/src/Ui/Src/ps_app_ui.c": "void ui_render(void) {}\n",
            "src/ps/app/src/ThirdParty/lvgl/lv_conf.h": "#define LV_USE_OS LV_OS_NONE\n",
            "src/ps/app/src/ThirdParty/lvgl/src/core/lv_obj.c": "void lv_obj_init(void) {}\n",
            "src/ps/app/src/ThirdParty/CherryUSB/core/usbh_core.c": "void usbh_init(void) {}\n",
            "tests/rtl/tb_core.sv": "module tb_core; endmodule\n",
            "third_party/digilent-vivado-library/ip/rgb2dvi/component.xml": "<component/>\n",
            "third_party/digilent-vivado-library/dependency-lock.json": '{"schema_version":1}\n',
        }
        paths: dict[str, Path] = {}
        for relative, content in fixture_contents.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            paths[relative] = path
        return paths

    def _stage_digests(self, root: Path) -> dict[str, str]:
        from tools.flow import stage_input_paths

        stages = ("hardware", "project", "sim", "app")
        return {
            stage: source_digest(input_stat_manifest(stage_input_paths(root, stage), root))
            for stage in stages
        }

    def test_app_stage_excludes_local_generated_compile_database(self) -> None:
        from tools.flow import stage_input_paths

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._create_input_tree(root)
            generated = root / "src/ps/app/src/compile_commands.json"
            generated.write_text('{"command":"old workstation command"}\\n', encoding="utf-8")
            clangd = root / "src/ps/app/src/.clangd"
            clangd.write_text("CompileFlags: {}\\n", encoding="utf-8")
            selected = {path.relative_to(root).as_posix() for path in stage_input_paths(root, "app")}
            self.assertNotIn("src/ps/app/src/compile_commands.json", selected)
            self.assertNotIn("src/ps/app/src/.clangd", selected)
            self.assertIn("src/ps/app/src/app.yaml", selected)

    def test_ui_and_lvgl_changes_only_change_app_input_digest(self) -> None:
        from tools.flow import stage_input_paths

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._create_input_tree(root)
            selected = {
                stage: {path.relative_to(root).as_posix() for path in stage_input_paths(root, stage)}
                for stage in ("hardware", "project", "sim", "app")
            }

            self.assertIn("src/ps/app/src/Ui/Src/ps_app_ui.c", selected["app"])
            self.assertIn("src/ps/app/src/ThirdParty/lvgl/src/core/lv_obj.c", selected["app"])
            self.assertTrue({"src/rtl/core/gba_core.sv", "src/constraints/zybo_z7_20.xdc", "src/bd/zynq_gba_system/zynq_gba_system.bd"}.issubset(selected["hardware"]))
            for stage in ("hardware", "project", "sim"):
                self.assertFalse(any(name.startswith("src/ps/app/") for name in selected[stage]))

            before = self._stage_digests(root)
            paths["src/ps/app/src/Ui/Src/ps_app_ui.c"].write_text("void ui_render(void) { /* changed */ }\n", encoding="utf-8")
            paths["src/ps/app/src/ThirdParty/lvgl/src/core/lv_obj.c"].write_text("void lv_obj_init(void) { /* 9.6 */ }\n", encoding="utf-8")
            after = self._stage_digests(root)

            self.assertNotEqual(before["app"], after["app"])
            for stage in ("hardware", "project", "sim"):
                self.assertEqual(before[stage], after[stage], f"UI/LVGL edits must not invalidate {stage}")

    def test_rtl_xdc_and_bd_changes_invalidate_hardware_project_and_sim_only(self) -> None:
        paths_to_change = (
            "src/rtl/core/gba_core.sv",
            "src/constraints/zybo_z7_20.xdc",
            "src/bd/zynq_gba_system/zynq_gba_system.bd",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._create_input_tree(root)
            current = self._stage_digests(root)

            for index, relative in enumerate(paths_to_change):
                paths[relative].write_text(f"changed input {index}\n", encoding="utf-8")
                updated = self._stage_digests(root)
                for stage in ("hardware", "project", "sim"):
                    self.assertNotEqual(current[stage], updated[stage], f"{relative} must invalidate {stage}")
                self.assertEqual(current["app"], updated["app"], f"{relative} is not an app source input")
                current = updated


if __name__ == "__main__":
    unittest.main()

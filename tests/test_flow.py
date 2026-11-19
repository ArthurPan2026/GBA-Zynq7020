"""Unit tests for the stdlib build-flow manifest and cache policy."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.flow import (
    SCHEMA_VERSION,
    HOST_TEST_HEADERS,
    FlowError,
    build_report,
    cache_is_valid,
    _embedded_video_ip_stage_files,
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
    input_sha256_manifest,
    vivado_input_hash,
)


class FlowManifestTests(unittest.TestCase):
    def test_project_workspace_is_separate_from_hardware_artifacts(self) -> None:
        from tools.flow import ACTION_OUTPUTS, PROJECT_REL, SIM_PROJECT_REL

        self.assertEqual(SIM_PROJECT_REL.parent, Path("out/vivado/project"))
        self.assertEqual(PROJECT_REL.parent, Path("out/vivado"))
        self.assertTrue(set(ACTION_OUTPUTS["project"]).isdisjoint(ACTION_OUTPUTS["build"]))

    def test_project_registers_evip_tmds_interface_and_keeps_zybo_board(self) -> None:
        repo = Path(__file__).resolve().parents[1]
        project_tcl = repo / "scripts/build/rebuild_project.tcl"
        build_tcl = repo / "scripts/build/build_bitstream.tcl"
        bd_tcl = repo / "scripts/build/embedded_video_ip_bd.tcl"
        project_source = project_tcl.read_text(encoding="utf-8")
        build_source = build_tcl.read_text(encoding="utf-8")
        bd_source = bd_tcl.read_text(encoding="utf-8")
        self.assertIn("embedded_video_ip_consumer.tcl", project_source)
        self.assertIn("embedded_video_ip_bd.tcl", project_source)
        self.assertIn("set evip_ip_repo [file join $evip_root ip_repo]", project_source)
        self.assertIn("panfpga embedded_video_ip component.xml", project_source)
        self.assertIn("set_property ip_repo_paths [list $evip_ip_repo] [current_project]", project_source)
        self.assertIn("set ip_repos [list $evip_ip_repo]", build_source)
        self.assertIn("evip_validate_tmds_interface_repo $evip_ip_repo", project_source)
        self.assertIn("evip_validate_tmds_interface_repo $evip_ip_repo", build_source)
        self.assertIn("file join $evip_ip_repo if tmds_v1_0", bd_source)
        self.assertIn("tmds.xml tmds_rtl.xml", bd_source)
        self.assertIn("delete_bd_objs $tmds_port", bd_source)
        self.assertIn("embedded_video_ip_video_out_clk_wiz_vga_0.xdc", bd_source)
        self.assertIn("embedded_video_ip_video_out_clk_wiz_hd_0.xdc", bd_source)
        self.assertIn("[llength $clk_wiz_vga_xdc] != 1", bd_source)
        self.assertIn("evip_bd_configure_composite", project_source)
        self.assertIn("rev-parse HEAD", project_source)
        self.assertIn("set_property board_part digilentinc.com:zybo-z7-20:part0:1.2", project_source)
        self.assertIn("tmds_tx_clk_p", (repo / "src/constraints/zybo_z7_20.xdc").read_text(encoding="utf-8"))
        self.assertNotIn("DIGILENT_VIVADO_LIBRARY", build_source)
        self.assertNotIn("third_party/digilent-vivado-library", project_source + build_source)
        self.assertNotIn("rgb2dvi", project_source + build_source + bd_source)

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

    def test_old_manifest_is_preserved_but_not_reused(self) -> None:
        import json
        from tools.flow import load_manifest
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            old = {"schema_version": 1, "runs": {"build": {"status": "succeeded"}}}
            path.write_text(json.dumps(old), encoding="utf-8")
            migrated = load_manifest(path)
            self.assertEqual(migrated["schema_version"], SCHEMA_VERSION)
            self.assertEqual(migrated["runs"], {})
            self.assertEqual(migrated["legacy_manifest"], old)

    def test_qor_parser_requires_timing_and_drc_gates(self) -> None:
        from tools.flow import parse_qor_gate
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "qor_gate.tsv"
            report.write_text(
                "passed=1\nwns_ns=0.125\ntns_ns=0.0\nwhs_ns=0.01\nths_ns=0.0\n"
                "drc_errors=0\ncritical_warnings=0\n",
                encoding="utf-8",
            )
            self.assertTrue(parse_qor_gate(report)["validated_pass"])
            report.write_text(
                "passed=0\nwns_ns=-0.1\ntns_ns=-0.1\nwhs_ns=0.01\nths_ns=0.0\n"
                "drc_errors=1\ncritical_warnings=0\n",
                encoding="utf-8",
            )
            self.assertFalse(parse_qor_gate(report)["validated_pass"])

    def test_qor_parser_rejects_hold_only_violations(self) -> None:
        from tools.flow import parse_qor_gate
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "qor_gate.tsv"
            for whs, ths in ((-0.001, 0.0), (0.0, -0.001)):
                report.write_text(
                    f"passed=1\nwns_ns=0.125\ntns_ns=0.0\n"
                    f"whs_ns={whs}\nths_ns={ths}\n"
                    "drc_errors=0\ncritical_warnings=0\n",
                    encoding="utf-8",
                )
                result = parse_qor_gate(report)
                self.assertFalse(result["validated_pass"])
                self.assertGreaterEqual(result["wns_ns"], 0.0)
                self.assertAlmostEqual(result["tns_ns"], 0.0)

    def test_incremental_dcp_requires_matching_identity_and_hash(self) -> None:
        from tools.flow import compatible_incremental_dcp, sha256_file
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dcp = root / "out/vivado/cache/routed.dcp"
            dcp.parent.mkdir(parents=True)
            dcp.write_bytes(b"verified dcp")
            entry = {
                "identity_sha256": "identity",
                "routed_dcp": "out/vivado/cache/routed.dcp",
                "routed_dcp_sha256": sha256_file(dcp),
            }
            self.assertEqual(compatible_incremental_dcp({"hardware_cache": entry}, "identity", root), dcp)
            self.assertIsNone(compatible_incremental_dcp({"hardware_cache": entry}, "changed", root))
            dcp.write_bytes(b"corrupted")
            self.assertIsNone(compatible_incremental_dcp({"hardware_cache": entry}, "identity", root))

    def test_incremental_dcp_reuses_last_good_checkpoint_for_same_contract(self) -> None:
        from tools.flow import compatible_incremental_dcp, sha256_file
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dcp = root / "out/vivado/cache/routed.dcp"
            dcp.parent.mkdir(parents=True)
            dcp.write_bytes(b"verified dcp")
            contract = {"sha256": "contract"}
            entry = {
                "identity_sha256": "previous-design",
                "vivado_version": "Vivado v2025.2.1",
                "routed_dcp": "out/vivado/cache/routed.dcp",
                "routed_dcp_sha256": sha256_file(dcp),
            }
            manifest = {"hardware_cache": entry, "hardware_contract": contract}
            self.assertEqual(
                compatible_incremental_dcp(
                    manifest, "changed-design", root,
                    vivado_version="Vivado v2025.2.1", hardware_contract=contract,
                ),
                dcp,
            )
            self.assertIsNone(
                compatible_incremental_dcp(
                    manifest, "changed-design", root,
                    vivado_version="Vivado v2025.2.1", hardware_contract={"sha256": "other"},
                )
            )

    def test_synth_checkpoint_resume_after_implementation_failure(self) -> None:
        from tools.flow import (
            LOCAL_BD_REL, PROJECT_REL, PROJECT_NAME, resumable_synth_checkpoint_build,
            source_digest, vivado_input_hash,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            synth_dir = root / "out/vivado" / f"{PROJECT_NAME}.runs/synth_1"
            synth_dir.mkdir(parents=True)
            for rel in (PROJECT_REL, LOCAL_BD_REL):
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("generated", encoding="utf-8")
            (synth_dir / "zynq_gba_system_wrapper.dcp").write_bytes(b"synth")
            (synth_dir / "runme.log").write_text(
                "synth_design completed successfully", encoding="utf-8"
            )
            version = "Vivado v2025.2.1"
            contract = {"sha256": "contract"}
            ip = {"version": "1.0", "commit": "pinned"}
            previous_inputs = {
                "scripts/build/build_bitstream.tcl": "old-build-script",
                "tools/flow.py": "old-flow",
                "src/rtl/top.sv": "unchanged-rtl",
            }
            record = {
                "status": "failed",
                "error_code": "FLOW-VIVADO-FAILED",
                "vivado_version": version,
                "hardware_contract": contract,
                "vendored_ip": ip,
                "jobs": 4,
                "input_fingerprint_type": "sha256-v1",
                "input_files": previous_inputs,
                "input_sha256": vivado_input_hash(
                    "build", previous_inputs, version, 4, contract, ip
                ),
                "source_sha256": source_digest(previous_inputs),
            }
            current_inputs = {
                **previous_inputs,
                "scripts/build/build_bitstream.tcl": "new-build-script",
                "tools/flow.py": "new-flow",
            }
            self.assertTrue(resumable_synth_checkpoint_build(
                record, current_inputs, version, contract, ip, 4, root
            ))
            current_inputs["src/rtl/top.sv"] = "changed-rtl"
            self.assertFalse(resumable_synth_checkpoint_build(
                record, current_inputs, version, contract, ip, 4, root
            ))

    def test_hardware_dcp_identity_ignores_only_rtl_content(self) -> None:
        from tools.flow import hardware_identity_sha256
        contract = {"sha256": "contract"}
        ip = {"commit": "ip"}
        base = {"src/rtl/core.v": "rtl-a", "src/bd/design.bd": "bd-a"}
        first = hardware_identity_sha256(base, "Vivado v2025.2.1", 4, contract, ip)
        rtl_changed = {**base, "src/rtl/core.v": "rtl-b"}
        bd_changed = {**base, "src/bd/design.bd": "bd-b"}
        self.assertEqual(first, hardware_identity_sha256(rtl_changed, "Vivado v2025.2.1", 4, contract, ip))
        self.assertNotEqual(first, hardware_identity_sha256(bd_changed, "Vivado v2025.2.1", 4, contract, ip))

    def test_private_evip_content_enters_hardware_and_app_fingerprints(self) -> None:
        import subprocess
        import os
        from tools.flow import stage_input_manifest
        with tempfile.TemporaryDirectory() as temporary:
            temp_root = Path(temporary)
            root = temp_root / "GBA"
            dep = temp_root / "EmbeddedVideoIP"
            root.mkdir()
            (root / "src").mkdir()
            dep.mkdir()
            files = {
                "VERSION": "0.1.0-test\n",
                "dependencies.lock.json": "{}\n",
                "ip_repo/if/tmds_v1_0/tmds.xml": "<busDefinition/>\n",
                "ip_repo/if/tmds_v1_0/tmds_rtl.xml": "<abstractionDefinition/>\n",
                "ip_repo/panfpga/embedded_video_ip/component.xml": "<component/>\n",
                "ip_repo/panfpga/embedded_video_ip/src/core.sv": "module core; endmodule\n",
                "software/video_out.c": "void video_out(void) {}\n",
                "platforms/amd_7series/board_profile.json": "{}\n",
                "tools/install_ps_library.py": "# installer\n",
            }
            for relative, content in files.items():
                path = dep / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            subprocess.run(["git", "-C", str(dep), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(dep), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(dep), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(dep), "add", "."], check=True)
            subprocess.run(["git", "-C", str(dep), "commit", "-qm", "fixture"], check=True)
            commit = subprocess.run(
                ["git", "-C", str(dep), "rev-parse", "HEAD"],
                text=True, capture_output=True, check=True,
            ).stdout.strip()
            consumer = root / "scripts/build/embedded_video_ip_consumer.tcl"
            consumer.parent.mkdir(parents=True)
            consumer.write_text(
                f'set evip_expected_version "0.1.0-test"\nset evip_expected_commit "{commit}"\n',
                encoding="utf-8",
            )
            with patch.dict(os.environ, {"EMBEDDED_VIDEO_IP_REPO": str(dep)}):
                hardware = stage_input_manifest(root, "hardware")
                app = stage_input_manifest(root, "app")
                self.assertIn("@EmbeddedVideoIP/ip_repo/if/tmds_v1_0/tmds.xml", hardware)
                self.assertIn("@EmbeddedVideoIP/ip_repo/if/tmds_v1_0/tmds_rtl.xml", hardware)
                self.assertIn("@EmbeddedVideoIP/ip_repo/panfpga/embedded_video_ip/component.xml", hardware)
                self.assertIn("@EmbeddedVideoIP/ip_repo/panfpga/embedded_video_ip/src/core.sv", hardware)
                self.assertIn("@EmbeddedVideoIP/software/video_out.c", app)
                self.assertIn("@EmbeddedVideoIP/tools/install_ps_library.py", app)
                changed = dep / "software/video_out.c"
                changed.write_text("void video_out(void) { }\n", encoding="utf-8")
                with self.assertRaises(FlowError) as raised:
                    stage_input_manifest(root, "app")
                self.assertEqual(raised.exception.code, "FLOW-EVIP-MISMATCH")

    def test_evip_docs_only_descendant_preserves_pinned_stage_fingerprints(self) -> None:
        import os
        import subprocess
        from tools.flow import check_embedded_video_ip, stage_input_manifest

        with tempfile.TemporaryDirectory() as temporary:
            temp_root = Path(temporary)
            root = temp_root / "GBA"
            dep = temp_root / "EmbeddedVideoIP"
            (root / "src").mkdir(parents=True)
            files = {
                "VERSION": "0.2.0-dev.4\n",
                "dependencies.lock.json": "{}\n",
                "README.md": "# EmbeddedVideoIP\n",
                "docs/validation.md": "initial validation\n",
                "ip_repo/if/tmds_v1_0/tmds.xml": "<busDefinition/>\n",
                "ip_repo/if/tmds_v1_0/tmds_rtl.xml": "<abstractionDefinition/>\n",
                "ip_repo/panfpga/embedded_video_ip/component.xml": "<component/>\n",
                "ip_repo/panfpga/embedded_video_ip/src/core.sv": "module core; endmodule\n",
                "software/video_out.c": "void video_out(void) {}\n",
            }
            for relative, content in files.items():
                path = dep / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            subprocess.run(["git", "-C", str(dep), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(dep), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(dep), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(dep), "add", "."], check=True)
            subprocess.run(["git", "-C", str(dep), "commit", "-qm", "library baseline"], check=True)
            pinned = subprocess.run(
                ["git", "-C", str(dep), "rev-parse", "HEAD"],
                text=True, capture_output=True, check=True,
            ).stdout.strip()
            consumer = root / "scripts/build/embedded_video_ip_consumer.tcl"
            consumer.parent.mkdir(parents=True)
            consumer.write_text(
                f'set evip_expected_version "0.2.0-dev.4"\nset evip_expected_commit "{pinned}"\n',
                encoding="utf-8",
            )
            with patch.dict(os.environ, {"EMBEDDED_VIDEO_IP_REPO": str(dep)}):
                hardware_before = stage_input_manifest(root, "hardware")
                app_before = stage_input_manifest(root, "app")

                (dep / "README.md").write_text("# Documentation update\n", encoding="utf-8")
                (dep / "docs/validation.md").write_text("board prevalidation\n", encoding="utf-8")
                subprocess.run(["git", "-C", str(dep), "add", "."], check=True)
                subprocess.run(["git", "-C", str(dep), "commit", "-qm", "docs: record board prevalidation"], check=True)

                dependency = check_embedded_video_ip(root)
                self.assertEqual(dependency["commit"], pinned)
                self.assertNotEqual(dependency["checkout_commit"], pinned)
                self.assertEqual(
                    set(dependency["docs_only_paths"].split(",")),
                    {"README.md", "docs/validation.md"},
                )
                self.assertEqual(hardware_before, stage_input_manifest(root, "hardware"))
                self.assertEqual(app_before, stage_input_manifest(root, "app"))

                (dep / "software/video_out.c").write_text("void video_out(void) { return; }\n", encoding="utf-8")
                subprocess.run(["git", "-C", str(dep), "add", "."], check=True)
                subprocess.run(["git", "-C", str(dep), "commit", "-qm", "change software"], check=True)
                with self.assertRaises(FlowError) as raised:
                    check_embedded_video_ip(root)
                self.assertEqual(raised.exception.code, "FLOW-EVIP-MISMATCH")

    def test_source_sha256_fingerprint_tracks_file_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "source.c"
            source.parent.mkdir()
            source.write_text("int value = 1;\\n", encoding="utf-8")
            before = input_sha256_manifest([source], root)
            source.write_text("int value = 20; int extra;\\n", encoding="utf-8")
            after = input_sha256_manifest([source], root)
            self.assertNotEqual(before["src/source.c"], after["src/source.c"])
            self.assertNotEqual(source_digest(before), source_digest(after))

    def test_content_fingerprint_detects_same_size_edit_with_restored_mtime(self) -> None:
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "same_size.c"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"aaaaaaaa")
            original = source.stat()
            before = input_sha256_manifest([source], root)
            source.write_bytes(b"bbbbbbbb")
            os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
            after = input_sha256_manifest([source], root)
            self.assertNotEqual(before, after)
            self.assertEqual(len(before["src/same_size.c"]), 64)

    def test_source_sha256_fingerprint_tracks_normal_edits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src" / "input.c"
            source.parent.mkdir(parents=True)
            source.write_text("int value=1;\\n", encoding="utf-8")
            before = input_sha256_manifest([source], root)
            source.write_text("int value=2;\\n", encoding="utf-8")
            stat = source.stat()
            import os
            os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
            after = input_sha256_manifest([source], root)
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

        # Upstream source-stage identities may change during a safe metadata
        # re-key while the actual PL/PS artifacts remain byte-identical.
        runs["build"]["input_sha256"] = "hardware-input-v2"
        runs["platform"]["input_sha256"] = "platform-input-v2"
        runs["app"]["input_sha256"] = "app-input-v2"
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

    def test_source_inventory_finds_rtl_and_excludes_generated_and_unselected_trees(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            nested_module = root / "src" / "rtl" / "common" / "nested" / "cdc_toggle_mailbox.sv"
            generated_header = root / "src" / "ps" / "platform" / "export" / "generated.h"
            unselected_file = root / "third_party" / "library" / "component.xml"
            nested_module.parent.mkdir(parents=True)
            generated_header.parent.mkdir(parents=True)
            unselected_file.parent.mkdir(parents=True)
            nested_module.write_text("module cdc_toggle_mailbox; endmodule\n", encoding="utf-8")
            generated_header.write_text("/* generated */\n", encoding="utf-8")
            unselected_file.write_text("<component/>\n", encoding="utf-8")
            names = {path.relative_to(root).as_posix() for path in iter_source_files(root)}
            self.assertIn("src/rtl/common/nested/cdc_toggle_mailbox.sv", names)
            self.assertNotIn("src/ps/platform/export/generated.h", names)
            self.assertNotIn("third_party/library/component.xml", names)

    def test_evip_stage_inputs_include_tmds_definitions_and_selected_ip(self) -> None:
        tracked = (
            "VERSION",
            "dependencies.lock.json",
            "ip_repo/if/tmds_v1_0/tmds.xml",
            "ip_repo/if/tmds_v1_0/tmds_rtl.xml",
            "ip_repo/panfpga/embedded_video_ip/component.xml",
            "ip_repo/panfpga/video_pipeline/component.xml",
            "software/video_out.c",
            "platforms/amd_7series/video_out_xilinx.c",
            "tools/install_ps_library.py",
        )
        hardware = set(_embedded_video_ip_stage_files(tracked, "hardware"))
        app = set(_embedded_video_ip_stage_files(tracked, "app"))
        self.assertIn("ip_repo/if/tmds_v1_0/tmds.xml", hardware)
        self.assertIn("ip_repo/if/tmds_v1_0/tmds_rtl.xml", hardware)
        self.assertIn("ip_repo/panfpga/embedded_video_ip/component.xml", hardware)
        self.assertNotIn("ip_repo/panfpga/video_pipeline/component.xml", hardware)
        self.assertNotIn("software/video_out.c", hardware)
        self.assertIn("software/video_out.c", app)
        self.assertIn("tools/install_ps_library.py", app)
        self.assertNotIn("ip_repo/if/tmds_v1_0/tmds.xml", app)
        for stage in ("hardware", "project", "sim", "app"):
            selected = set(_embedded_video_ip_stage_files(tracked, stage))
            self.assertIn("VERSION", selected)
            self.assertIn("dependencies.lock.json", selected)

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
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv", "tb_gba_pcm_audio_axis.sv", "tb_gba_physical_key_mapper.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")
            project_file = root / "out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr"
            project_file.parent.mkdir(parents=True, exist_ok=True)
            project_file.write_bytes(b"validated simulation project")
            calls = []

            def fake_run(command, cwd, env, text, capture_output, check):
                calls.append((command, cwd, env))
                project_file.write_bytes(b"mutated by Vivado")
                runner_path = Path(command[-1])
                for bench_path in bench_root.glob("tb_*"):
                    bench_output = runner_path.parent / bench_path.stem
                    bench_output.mkdir(parents=True, exist_ok=True)
                    (bench_output / "xsim.log").write_text(f"TEST_PASS {bench_path.stem}\n", encoding="utf-8")
                return __import__("subprocess").CompletedProcess(command, 0, "sim done", "")

            with patch("tools.flow.check_hardware_contract"), \
                 patch("tools.flow.expected_project_record", return_value={"outputs": {"out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr": "xpr-hash"}}), \
                 patch("tools.flow.resolve_executable", return_value=Path("/mock/vivado")), \
                 patch("tools.flow.read_tool_version", return_value="Vivado v2025.2.1 (64-bit)"), \
                 patch("tools.flow.stage_input_paths", return_value=[input_file]), \
                 patch("tools.flow.file_manifest", return_value={"src/rtl/input.v": "input-hash"}), \
                 patch("tools.flow.contract_info", return_value={"sha256": "contract", "abi_build_id": "0x12345678"}), \
                 patch("tools.flow.subprocess.run", side_effect=fake_run):
                result = run_simulation("smoke", 23, "vivado", root)

            self.assertEqual(result, 0)
            self.assertEqual(project_file.read_bytes(), b"validated simulation project")
            self.assertEqual(len(calls), 1)
            command, cwd, env = calls[0]
            self.assertEqual(command[1:4], ["-mode", "batch", "-source"])
            self.assertTrue(str(command[4]).startswith(str(root / "out/sim/smoke/seed-23")))
            self.assertEqual(cwd, Path(command[4]).parent)
            self.assertEqual(env["ZYNQ_GBA_REPO_ROOT"], str(root))
            run_manifest = __import__("json").loads((root / "out/flow/manifest.json").read_text(encoding="utf-8"))
            record = run_manifest["runs"]["sim:smoke:seed-23"]
            self.assertEqual(record["seed"], 23)
            self.assertEqual(set(Path(path).name for path in record["entry"]), {"tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv", "tb_gba_pcm_audio_axis.sv", "tb_gba_physical_key_mapper.sv"})
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
                "input_files": input_sha256_manifest(stage_input_paths(root, "hardware"), root),
                "input_partition_version": 2,
                "input_fingerprint_type": "sha256-v1",
            }
            manifest_path.write_text(__import__("json").dumps({"schema_version": SCHEMA_VERSION, "runs": {"build": record}}), encoding="utf-8")
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
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv", "tb_gba_pcm_audio_axis.sv", "tb_gba_physical_key_mapper.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")
            project_file = root / "out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr"
            project_file.parent.mkdir(parents=True, exist_ok=True)
            project_file.write_bytes(b"validated simulation project")
            failed = __import__("subprocess").CompletedProcess(["vivado"], 4, "", "compile failed")
            with patch("tools.flow.check_hardware_contract"), \
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
        inputs = input_sha256_manifest(stage_input_paths(root, "hardware"), root)
        ip = {"commit": "test"}
        version = "Vivado v2025.2.1 (64-bit)"
        record = {
            "action": "build",
            "status": "succeeded",
            "input_sha256": vivado_input_hash("build", inputs, version, None, info, ip),
            "source_sha256": source_digest(inputs),
            "input_files": inputs,
            "input_partition_version": 2,
            "input_fingerprint_type": "sha256-v1",
            "completed_at_utc": __import__("tools.flow", fromlist=["utc_now"]).utc_now(),
            "hardware_contract": info,
            "vendored_ip": ip,
            "vivado_version": version,
            "jobs": None,
            "outputs": outputs,
        }
        manifest_path = root / "out/flow/manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps({"schema_version":SCHEMA_VERSION,"runs":{"build":record}}), encoding="utf-8")
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
            flow_script = root / "tools/flow.py"
            flow_script.parent.mkdir(parents=True, exist_ok=True)
            flow_script.write_text("# orchestration v1\\n", encoding="utf-8")
            self._write_hardware_manifest(root)
            manifest_path = root / "out/flow/manifest.json"
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            data["runs"]["build"]["input_sha256"] = "legacy-whole-tree-signature"
            data["runs"]["build"]["input_files"]["scripts/build/rebuild_project.tcl"] = "a" * 64
            manifest_path.write_text(json.dumps(data), encoding="utf-8")
            flow_script.write_text("# orchestration v2\\n", encoding="utf-8")
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

    def test_new_cli_actions_and_qspi_readback_flags(self) -> None:
        from tools.flow import build_parser, qspi_program_command
        plan = build_parser().parse_args(["plan", "--target", "jtag"])
        self.assertEqual((plan.action, plan.target), ("plan", "jtag"))
        deploy = build_parser().parse_args(["deploy", "--target", "qspi"])
        self.assertEqual((deploy.action, deploy.target), ("deploy", "qspi"))
        release = build_parser().parse_args(["release", "--target", "jtag", "--skip-fps"])
        self.assertTrue(release.skip_fps)
        command = qspi_program_command(
            Path("/tools/Vitis/bin/program_flash"),
            Path("/repo/out/vitis/BOOT.BIN"),
            Path("/repo/out/vitis/fsbl.elf"),
            "jsn-Zybo-Z7-arm_dap",
            "tcp:127.0.0.1:3121",
        )
        self.assertIn("-blank_check", command)
        self.assertIn("-verify", command)
        self.assertEqual(command[command.index("-offset") + 1], "0")
        self.assertNotIn("-erase_all", command)

    def test_program_flash_target_parser_requires_one_zybo(self) -> None:
        import subprocess
        from tools.flow import _program_flash_targets
        output = (
            "2 jsn-Zybo Z7-210351BFB011A-4ba00477-0 (name arm_dap idcode 4ba00477)\n"
            "3 jsn-Zybo Z7-210351BFB011A-23727093-0 (name xc7z020 idcode 23727093)\n"
        )
        fake = subprocess.CompletedProcess(["program_flash"], 0, output, "")
        with patch("tools.flow.subprocess.run", return_value=fake):
            selected, targets = _program_flash_targets(Path("/mock/program_flash"), "tcp:3121")
        self.assertEqual(selected, "jsn-Zybo Z7-210351BFB011A-4ba00477-0")
        self.assertEqual(len(targets), 2)
        with patch("tools.flow.subprocess.run", return_value=subprocess.CompletedProcess(
            ["program_flash"], 0, output + output, ""
        )):
            with self.assertRaises(FlowError) as raised:
                _program_flash_targets(Path("/mock/program_flash"), "tcp:3121")
            self.assertEqual(raised.exception.code, "FLOW-JTAG-TARGET")

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
            for name in ("tb_cdc_mailbox_atomic.sv", "tb_ddram_lifecycle.sv", "tb_debug_snapshot_hold.sv", "tb_axi_lite_ctrl_regs_mem_ack_seq.sv", "tb_gba_pcm_audio_axis.sv", "tb_gba_physical_key_mapper.sv"):
                (bench_root / name).write_text("module tb; endmodule\n", encoding="utf-8")
            input_file = root / "src/rtl/input.v"
            input_file.parent.mkdir(parents=True)
            input_file.write_text("module input; endmodule\n", encoding="utf-8")
            project_file = root / "out/vivado/project/Zynq-GBA_MisTer-Vivado.xpr"
            project_file.parent.mkdir(parents=True, exist_ok=True)
            project_file.write_bytes(b"validated simulation project")

            def fake_run(command, cwd, env, text, capture_output, check):
                project_file.write_bytes(b"mutated by Vivado")
                runner_path = Path(command[-1])
                for bench_path in bench_root.glob("tb_*"):
                    bench_output = runner_path.parent / bench_path.stem
                    bench_output.mkdir(parents=True, exist_ok=True)
                    (bench_output / "xsim.log").write_text(log_text, encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "simulation ended", "")

            with patch("tools.flow.check_hardware_contract"), \
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
            self.assertEqual(project_file.read_bytes(), b"validated simulation project")
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
            "scripts/build/embedded_video_ip_consumer.tcl": "# pinned EVIP settings\n",
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
            stage: source_digest(input_sha256_manifest(stage_input_paths(root, stage), root))
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

    def test_vitis_stage_code_fingerprints_are_partitioned(self) -> None:
        from tools.flow import stage_input_manifest
        source_code = Path(__file__).resolve().parents[1] / "tools/vitis_stages.py"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "src").mkdir()
            stage_dir = root / "tools"
            stage_dir.mkdir()
            target = stage_dir / "vitis_stages.py"
            target.write_text(source_code.read_text(encoding="utf-8"), encoding="utf-8")
            platform_before = stage_input_manifest(root, "platform")
            app_before = stage_input_manifest(root, "app")
            text = target.read_text(encoding="utf-8")
            old = '"build_mode": "incremental-capable"'
            self.assertIn(old, text)
            target.write_text(text.replace(old, '"build_mode": "incremental-updated"'), encoding="utf-8")
            platform_after = stage_input_manifest(root, "platform")
            app_after = stage_input_manifest(root, "app")
            self.assertEqual(platform_before, platform_after)
            self.assertNotEqual(app_before, app_after)

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

    def test_project_script_change_does_not_invalidate_hardware(self) -> None:
        from tools.flow import stage_input_paths

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._create_input_tree(root)
            before = self._stage_digests(root)
            paths["scripts/build/rebuild_project.tcl"].write_text("# simulation project update\n", encoding="utf-8")
            after = self._stage_digests(root)
            self.assertEqual(before["hardware"], after["hardware"])
            self.assertNotEqual(before["project"], after["project"])
            self.assertNotEqual(before["sim"], after["sim"])
            self.assertIn("scripts/build/build_bitstream.tcl", {
                path.relative_to(root).as_posix() for path in stage_input_paths(root, "hardware")
            })
            self.assertNotIn("scripts/build/rebuild_project.tcl", {
                path.relative_to(root).as_posix() for path in stage_input_paths(root, "hardware")
            })

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

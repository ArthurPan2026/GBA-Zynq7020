"""Regression checks for the pinned LVGL 9.6 application migration."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ps/app/src"
VENDOR = APP / "ThirdParty/lvgl"


class LvglMigrationTests(unittest.TestCase):
    def test_vendor_lock_pins_official_origin_and_is_editable(self) -> None:
        lock = json.loads((VENDOR / "LVGL_SOURCE_LOCK.json").read_text(encoding="utf-8"))
        self.assertEqual(lock["upstream"]["tag"], "v9.6.0")
        self.assertEqual(lock["upstream"]["release_commit"], "80ca777e37a2b176770726a02e07a6fb79ef0b39")
        self.assertEqual(set(lock["imported_paths"]), {
            "src/", "include/", "lvgl.h", "lvgl_private.h", "lv_version.h",
            "lv_version.h.in", "lv_conf_template.h", "LICENCE.txt",
        })
        self.assertEqual(lock["file_count"], 1446)
        self.assertRegex(lock["tree_digest"]["value"], r"^[0-9a-f]{64}$")
        self.assertIn("local source edits are allowed", lock["tree_digest"]["scope"])
        self.assertEqual(lock["project_configuration"]["ownership"], "project-owned and editable")

    def test_all_version_headers_are_lvgl_9_6(self) -> None:
        version_headers = sorted(VENDOR.rglob("lv_version.h"))
        versions = []
        for header in version_headers:
            text = header.read_text(encoding="utf-8")
            matches = [
                re.search(rf"^#define LVGL_VERSION_{part} (\d+)$", text, re.M)
                for part in ("MAJOR", "MINOR", "PATCH")
            ]
            if all(matches):
                versions.append(tuple(int(match.group(1)) for match in matches))
        self.assertGreaterEqual(len(versions), 1)
        self.assertTrue(all(version == (9, 6, 0) for version in versions))

    def test_zynq_configuration_uses_supported_9_6_features(self) -> None:
        conf = (VENDOR / "lv_conf.h").read_text(encoding="utf-8")
        self.assertIn("#define LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_XRGB8888", conf)
        self.assertIn("#define LV_USE_OS LV_OS_NONE", conf)
        self.assertIn("#define LV_MEM_SIZE (2U * 1024U * 1024U)", conf)
        self.assertIn("#define LV_OBJ_STYLE_CACHE 1", conf)
        self.assertIn("#define LV_USE_CHECK_ARG 1", conf)
        self.assertIn("#define LV_USE_PRIVATE_API 0", conf)
        self.assertNotIn("#define LV_COLOR_DEPTH ", conf)

    def test_application_uses_public_header_and_non_deprecated_list_apis(self) -> None:
        ui = (APP / "Ui/Src/ps_app_ui.c").read_text(encoding="utf-8")
        theme = (APP / "Ui/Inc/ps_app_ui_theme.h").read_text(encoding="utf-8")
        font = (APP / "Ui/Assets/Fonts/ps_ui_font_fusion_12.h").read_text(encoding="utf-8")
        user_config = (APP / "UserConfig.cmake").read_text(encoding="utf-8")

        for source in (ui, theme, font):
            self.assertIn("#include <lvgl/lvgl.h>", source)
        self.assertIn("ThirdParty/lvgl/include", user_config)
        for obsolete in (
            "lv_list_create",
            "lv_list_add_button",
            "lv_obj_add_flag",
            "lv_obj_remove_flag",
            "lv_obj_set_flag",
            "lv_obj_has_flag",
            "LV_LABEL_LONG_DOT",
        ):
            self.assertNotIn(obsolete, ui)
        self.assertIn("LV_FLEX_FLOW_COLUMN", ui)
        self.assertIn("lv_label_set_max_lines(row, 1)", ui)
        self.assertIn("lv_label_set_text_static(row, s_ps_app_ui_runtime.games[idx].name)", ui)
        self.assertIn("PsAppUi_SetDetailTitleText(s_ps_app_ui_runtime.games[state->selected_index].name)", ui)
        self.assertIn("LV_LABEL_LONG_MODE_SCROLL_CIRCULAR", ui)

    def test_host_scene_exercises_full_list_scroll_long_names_and_heap(self) -> None:
        test = (ROOT / "tests/ps/test_lvgl96_runtime.c").read_text(encoding="utf-8")
        self.assertIn("#define TEST_ROW_COUNT 128U", test)
        self.assertIn("LV_COLOR_FORMAT_XRGB8888", test)
        self.assertIn("lv_obj_scroll_to_view(rows[TEST_ROW_COUNT - 1U]", test)
        self.assertIn("lv_mem_monitor(&memory)", test)
        self.assertIn("非常长的游戏名称", test)
        self.assertIn("VeryLongGameTitleWithoutTruncatingTheSourceName", test)
        self.assertIn("LVGL_HOST_PASS", test)


if __name__ == "__main__":
    unittest.main()

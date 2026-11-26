#include "Ui/Inc/ps_app_ui.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FreeRTOS.h"
#include "task.h"
#include "xil_cache.h"
#include "xil_printf.h"

#include "App/Inc/ps_app_runtime.h"
#include "Video/Inc/ps_app_video_mode_logic.h"
#include "Common/Inc/ps_project_config.h"
#include "Common/Inc/ps_app_rom_load_progress.h"
#include "Common/Inc/ps_app_ui_launch_logic.h"
#include "Gba/Inc/ps_gba_regs.h"
#include "Hdmi/Inc/ps_app_hdmi_link.h"
#include "Input/Inc/ps_app_input.h"
#include "Input/Inc/ps_xinput_xbox360.h"
#include "Storage/Inc/ps_fatfs_storage.h"
#include "Ui/Assets/Icons/ps_app_ui_icons.h"
#include "Ui/Inc/ps_app_ui_theme.h"
#include "Video/Inc/ps_app_video.h"
#include "Vdma/Inc/ps_hdmi_vdma.h"
#include <lvgl/lvgl.h>

#include "Common/Inc/ps_app_time.h"
#define PS_APP_UI_TARGET_FRAME_IDX  0U

#define PS_APP_UI_PANEL_SHADOW_OFFSET 2
#define PS_APP_UI_BLINK_INTERVAL_MS   520U
#define PS_APP_UI_SWEEP_PERIOD_MS     720U
#define PS_APP_UI_SWEEP_WIDTH_PX      20U
#define PS_APP_UI_CURSOR_WIDTH_PX     6U
#define PS_APP_UI_DETAIL_PATH_WIDTH   112
#define PS_APP_UI_DETAIL_TITLE_WIDTH  160
#define PS_APP_UI_DETAIL_FIELD_X      14
#define PS_APP_UI_DETAIL_VALUE_X      62
#define PS_APP_UI_DETAIL_ROW_PATH_Y   100
#define PS_APP_UI_DETAIL_ROW_SIZE_Y   124
#define PS_APP_UI_DETAIL_ROW_CODE_Y   148
#define PS_APP_UI_DETAIL_ROW_CRC_Y    178
#define PS_APP_UI_DETAIL_ROW_BIOS_Y   198
#define PS_APP_UI_DETAIL_ROW_SAVE_Y   220
#define PS_APP_UI_GBA_HEADER_PREVIEW_BYTES 0xC0U
#define PS_APP_UI_BJ_OFFSET_SEC       28800LL
#define PS_APP_UI_CLOCK_INVALID_UNIX  0xFFFFFFFFU
#define PS_APP_UI_EMPTY_LIST_TEXT_MAX 160U
#define PS_APP_UI_DISPLAY_OPTION_COUNT (PS_APP_VIDEO_MODE_COUNT + 1U)
/* STATUS0 低 10 位的物理按键定义与 GBA key bit 一致：
 * bit0=A, bit1=B, bit2=SELECT, bit3=START, bit4=RIGHT, bit5=LEFT, bit6=UP, bit7=DOWN, bit8=R, bit9=L */
#define PS_APP_UI_PHY_KEY_A      (1U << 0U)
#define PS_APP_UI_PHY_KEY_B      (1U << 1U)
#define PS_APP_UI_PHY_KEY_SELECT (1U << 2U)
#define PS_APP_UI_PHY_KEY_START  (1U << 3U)
#define PS_APP_UI_PHY_KEY_RIGHT  (1U << 4U)
#define PS_APP_UI_PHY_KEY_LEFT   (1U << 5U)
#define PS_APP_UI_PHY_KEY_UP     (1U << 6U)
#define PS_APP_UI_PHY_KEY_DOWN   (1U << 7U)

typedef struct {
    char name[PS_APP_UI_GAME_NAME_MAX_CHARS];
    char path[PS_APP_ROM_PATH_MAX_CHARS];
    u32 size_bytes;
    char game_code[5];
    char maker_code[3];
    u8 header_valid;
} PsAppUiGameEntry;

typedef enum {
    PS_APP_UI_STATUS_ROLE_INFO = 0U,
    PS_APP_UI_STATUS_ROLE_WARN = 1U,
    PS_APP_UI_STATUS_ROLE_PLAY = 2U
} PsAppUiStatusRole;

typedef struct {
    u8 mode;
    const char *name;
} PsAppUiDisplayOption;

static const PsAppUiDisplayOption s_ps_app_ui_display_options[] = {
#define GBA_VIDEO_MODE(name, w, h, hz, khz, vic) \
    {PS_APP_VIDEO_MODE_##name, #h "p" #hz},
#include "Video/Inc/video_modes.def"
#undef GBA_VIDEO_MODE
    {PS_APP_HDMI_MODE_AUTO, "AUTO"}
};

typedef struct {
    PsAppUiContext *ctx;
    PsAppUiGameEntry games[PS_APP_UI_MAX_GAMES];
    lv_obj_t *game_buttons[PS_APP_UI_MAX_GAMES];
    lv_display_t *display;
    lv_obj_t *root_screen;
    lv_obj_t *screen;
    lv_obj_t *shell_panel;
    lv_obj_t *header_panel;
    lv_obj_t *title_label;
    lv_obj_t *meta_label;
    lv_obj_t *clock_label;
    lv_obj_t *led;
    lv_obj_t *audio_route_label;
    lv_obj_t *list_panel;
    lv_obj_t *list;
    lv_obj_t *detail_panel;
    lv_obj_t *detail_title_label;
    lv_obj_t *detail_path_label;
    lv_obj_t *detail_slot_label;
    lv_obj_t *detail_size_value_label;
    lv_obj_t *detail_code_value_label;
    lv_obj_t *detail_crc_value_label;
    lv_obj_t *detail_bios_value_label;
    lv_obj_t *detail_save_value_label;
    lv_obj_t *detail_hint_label;
    lv_obj_t *status_panel;
    lv_obj_t *status_icon_info;
    lv_obj_t *status_icon_warn;
    lv_obj_t *status_icon_play;
    lv_obj_t *status_label;
    lv_obj_t *hint_label;
    lv_obj_t *status_progress;
    lv_obj_t *status_progress_fill;
    lv_obj_t *about_panel;
    lv_obj_t *about_title_label;
    lv_obj_t *about_body_label;
    lv_obj_t *about_hint_label;
    lv_obj_t *about_side_label;
    lv_obj_t *display_choice_labels[PS_APP_UI_DISPLAY_OPTION_COUNT];
    u8 system_page;
    u8 system_selection;
    u8 display_choice;
    u8 display_preview;
    u8 display_previous_mode;
    u8 display_preview_timer_started;
    u8 display_rows_valid;
    u8 display_rows_support_mask;
    u8 display_rows_active_mode;
    u8 display_rows_choice;
    u8 display_rows_preview;
    u8 display_rows_recovery_state;
    TickType_t display_started;
    lv_obj_t *sweep;
    lv_obj_t *cursor;
    u32 anim_elapsed_ms;
    u32 blink_elapsed_ms;
    u32 last_clock_unix;
    PsAppAudioRouteState last_audio_route;
    u8 audio_route_snapshot_valid;
    u8 audio_route_safe_flush_pending;
    u8 audio_route_safe_flush_dirty;
    u8 ui_target_frame_idx;
    PsAppVideoUiFrameUpdate audio_route_safe_update;
    u16 game_button_count;
    FRESULT last_scan_fs_result;
    char empty_list_text[PS_APP_UI_EMPTY_LIST_TEXT_MAX];
    u8 blink_phase;
    u8 about_visible;
    u8 ui_video_mode;
    lv_coord_t ui_canvas_width;
    lv_coord_t detail_title_width;
    lv_coord_t detail_path_width;
    lv_coord_t detail_value_width;
    u8 initialized;
    u8 last_scan_failed;
    u8 load_worker_active;
    u8 load_worker_done;
    u8 progress_fill_color_valid;
    u8 reserved_runtime0;
    s32 load_worker_status;
    u16 progress_fill_width;
    u16 reserved_runtime1;
    u32 progress_fill_color;
    u32 load_worker_attempt_id;
    u32 last_load_attempt_id;
    TickType_t first_frame_wait_start;
    u8 first_frame_wait_started;
    u8 first_frame_wait_reported;
    volatile u32 service_ticks;
    volatile u32 flush_calls;
    volatile u32 flush_completed;
    volatile u32 last_flush_pixel;
    u32 layout_height;
    u32 frame_elapsed_ms;
    u32 present_target;
    u32 present_pending;
    u32 submitted_frames;
    u32 presented_frames;
    u32 missed_deadlines;
    u32 max_draw_us;
    u32 last_frame_us;
    u32 last_lv_tick_ms;
    u16 visual_selection;
    u8 visual_blink;
    u8 visual_valid;
} PsAppUiRuntime;

typedef struct {
    PsAppRuntimeContext *runtime;
    char path[PS_APP_ROM_PATH_MAX_CHARS];
} PsAppUiLoadWorkerArgs;

typedef struct {
    PsAppUiGameEntry *games;
    u32 count;
    u8 overflow;
    u8 skipped_long_path;
} PsAppUiScanContext;

static PsAppUiRuntime s_ps_app_ui_runtime;
static PsAppUiLoadWorkerArgs s_ps_app_ui_load_worker_args;



static lv_coord_t PsAppUi_Px(lv_coord_t value) {
    u32 height = s_ps_app_ui_runtime.layout_height;
    if (!LV_COORD_IS_PX(value) || height == 0U) return value;
    return (lv_coord_t)(((int64_t)value * height) / 480);
}
static void PsAppUi_Pos(lv_obj_t *o, lv_coord_t x, lv_coord_t y) {
    lv_obj_set_pos(o, PsAppUi_Px(x), PsAppUi_Px(y));
}
static void PsAppUi_Size(lv_obj_t *o, lv_coord_t w, lv_coord_t h) {
    lv_obj_set_size(o, PsAppUi_Px(w), PsAppUi_Px(h));
}
static void PsAppUi_Width(lv_obj_t *o, lv_coord_t w) { lv_obj_set_width(o, PsAppUi_Px(w)); }
static void PsAppUi_Height(lv_obj_t *o, lv_coord_t h) { lv_obj_set_height(o, PsAppUi_Px(h)); }
static void PsAppUi_Align(lv_obj_t *o, lv_align_t align, lv_coord_t x, lv_coord_t y) {
    lv_obj_align(o, align, PsAppUi_Px(x), PsAppUi_Px(y));
}
static void PsAppUi_AlignTo(lv_obj_t *o, const lv_obj_t *base, lv_align_t align, lv_coord_t x, lv_coord_t y) {
    lv_obj_align_to(o, base, align, PsAppUi_Px(x), PsAppUi_Px(y));
}
static void PsAppUi_AbortAudioRouteSafeFlush(void);
static void PsAppUi_ConfigureNativeBuffers(PsAppUiContext *ctx);
static void PsAppUi_RefreshNative(void);
static void PsAppUi_UpdateSystemPanel(PsAppUiContext *ctx);

static lv_color_t PsAppUi_HexColor(u32 rgb) {
    return PsAppUiTheme_Color(rgb);
}

static const lv_font_t *PsAppUi_Font(void) {
    return PsAppUiTheme_FontBody();
}

static void PsAppUi_SetTextStyle(lv_obj_t *obj, u32 color_rgb) {
    if (obj == NULL) {
        return;
    }

    PsAppUiTheme_SetText(obj, color_rgb);
}

static void PsAppUi_SetBoxStyle(lv_obj_t *obj,
                                u32 bg_rgb,
                                u32 border_rgb,
                                lv_coord_t border_width) {
    if (obj == NULL) {
        return;
    }

    PsAppUiTheme_SetBox(obj, bg_rgb, border_rgb, border_width);
}

static lv_obj_t *PsAppUi_CreateText(lv_obj_t *parent,
                                    const char *text,
                                    u32 color_rgb,
                                    lv_coord_t x,
                                    lv_coord_t y) {
    lv_obj_t *label;

    label = lv_label_create(parent);
    lv_label_set_text(label, (text != NULL) ? text : "");
    PsAppUi_SetTextStyle(label, color_rgb);
    PsAppUi_Pos(label, x, y);
    return label;
}

static void PsAppUi_CreateBitmapIcon(lv_obj_t *parent,
                                     lv_coord_t x,
                                     lv_coord_t y,
                                     const PsAppUiBitmapIcon *icon,
                                     lv_coord_t scale,
                                     u32 color_rgb) {
    u8 row;

    if ((parent == NULL) || (icon == NULL) || (icon->rows == NULL) || (scale <= 0)) {
        return;
    }

    for (row = 0U; row < icon->height; ++row) {
        u8 col;
        u8 run_start;
        u8 run_len;
        u16 bits;

        bits = icon->rows[row];
        run_start = 0U;
        run_len = 0U;
        for (col = 0U; col < icon->width; ++col) {
            u8 bit_on;

            bit_on = (u8)(((bits >> (15U - col)) & 1U) != 0U);
            if (bit_on != 0U) {
                if (run_len == 0U) {
                    run_start = col;
                }
                run_len++;
            }

            if (((bit_on == 0U) || (col == (u8)(icon->width - 1U))) && (run_len > 0U)) {
                lv_obj_t *px;

                px = lv_obj_create(parent);
                lv_obj_remove_style_all(px);
                PsAppUi_Size(px, (lv_coord_t)run_len * scale, scale);
                PsAppUi_Pos(px, x + ((lv_coord_t)run_start * scale), y + ((lv_coord_t)row * scale));
                PsAppUi_SetBoxStyle(px, color_rgb, color_rgb, 0);
                lv_obj_set_scrollable(px, false);
                run_len = 0U;
            }
        }
    }
}

static void PsAppUi_CreateMonoBitmap(lv_obj_t *parent,
                                     lv_coord_t x,
                                     lv_coord_t y,
                                     const PsAppUiMonoBitmap *bitmap,
                                     lv_coord_t scale,
                                     u32 color_rgb) {
    u8 row;

    if ((parent == NULL) || (bitmap == NULL) || (bitmap->rows == NULL) ||
        (scale <= 0) || (bitmap->width == 0U) || (bitmap->width > 64U)) {
        return;
    }

    for (row = 0U; row < bitmap->height; ++row) {
        u8 col;
        u8 run_start;
        u8 run_len;
        u64 bits;

        bits = bitmap->rows[row];
        run_start = 0U;
        run_len = 0U;
        for (col = 0U; col < bitmap->width; ++col) {
            u8 bit_on;

            bit_on = (u8)(((bits >> (u8)(bitmap->width - 1U - col)) & 1ULL) != 0ULL);
            if (bit_on != 0U) {
                if (run_len == 0U) {
                    run_start = col;
                }
                run_len++;
            }

            if (((bit_on == 0U) || (col == (u8)(bitmap->width - 1U))) && (run_len > 0U)) {
                lv_obj_t *px;

                px = lv_obj_create(parent);
                lv_obj_remove_style_all(px);
                PsAppUi_Size(px, (lv_coord_t)run_len * scale, scale);
                PsAppUi_Pos(px, x + ((lv_coord_t)run_start * scale), y + ((lv_coord_t)row * scale));
                PsAppUi_SetBoxStyle(px, color_rgb, color_rgb, 0);
                lv_obj_set_scrollable(px, false);
                run_len = 0U;
            }
        }
    }
}

static lv_obj_t *PsAppUi_CreateIconLayer(lv_obj_t *parent,
                                         lv_coord_t x,
                                         lv_coord_t y,
                                         const PsAppUiBitmapIcon *icon,
                                         u32 color_rgb) {
    lv_obj_t *layer;

    layer = lv_obj_create(parent);
    lv_obj_remove_style_all(layer);
    PsAppUi_Size(layer, 16, 16);
    PsAppUi_Pos(layer, x, y);
    lv_obj_set_style_bg_opa(layer, LV_OPA_TRANSP, 0);
    lv_obj_set_scrollable(layer, false);
    PsAppUi_CreateBitmapIcon(layer, 0, 1, icon, 1, color_rgb);
    return layer;
}

static size_t PsAppUi_Utf8CharLen(unsigned char lead) {
    if ((lead & 0x80U) == 0U) {
        return 1U;
    }
    if ((lead & 0xE0U) == 0xC0U) {
        return 2U;
    }
    if ((lead & 0xF0U) == 0xE0U) {
        return 3U;
    }
    if ((lead & 0xF8U) == 0xF0U) {
        return 4U;
    }
    return 1U;
}

static u8 PsAppUi_IsUtf8Continuation(unsigned char byte) {
    return (u8)((byte & 0xC0U) == 0x80U);
}

static size_t PsAppUi_Utf8SafePrefixLen(const char *src, size_t src_len, size_t max_len) {
    size_t pos;
    size_t limit;

    if (src == NULL) {
        return 0U;
    }

    limit = (src_len < max_len) ? src_len : max_len;
    pos = 0U;
    while (pos < limit) {
        size_t char_len;
        size_t idx;
        u8 valid;

        char_len = PsAppUi_Utf8CharLen((unsigned char)src[pos]);
        if ((pos + char_len) > limit) {
            break;
        }

        valid = 1U;
        for (idx = 1U; idx < char_len; ++idx) {
            if (PsAppUi_IsUtf8Continuation((unsigned char)src[pos + idx]) == 0U) {
                valid = 0U;
                break;
            }
        }
        pos += (valid != 0U) ? char_len : 1U;
    }

    return pos;
}

static void PsAppUi_CopyUtf8TextBounded(char *dst,
                                        size_t dst_size,
                                        const char *src,
                                        size_t src_len) {
    size_t copy_len;

    if ((dst == NULL) || (dst_size == 0U)) {
        return;
    }

    if (src == NULL) {
        dst[0] = '\0';
        return;
    }

    copy_len = PsAppUi_Utf8SafePrefixLen(src, src_len, dst_size - 1U);
    memcpy(dst, src, copy_len);
    dst[copy_len] = '\0';
}

static void PsAppUi_CopyText(char *dst, size_t dst_size, const char *src) {
    PsAppUi_CopyUtf8TextBounded(dst, dst_size, src, (src != NULL) ? strlen(src) : 0U);
}

static const char *PsAppUi_StorageFailureText(FRESULT fs_result) {
    switch (fs_result) {
        case FR_NOT_READY:
            return "SD卡未插入或未就绪";
        case FR_NO_FILESYSTEM:
            return "SD卡未格式化或文件系统不支持";
        case FR_NO_PATH:
            return "缺少 0:/games 目录";
        case FR_DISK_ERR:
            return "SD卡读取错误";
        case FR_TIMEOUT:
        case FR_LOCKED:
            return "存储忙，请稍后重试";
        case FR_INVALID_DRIVE:
        case FR_NOT_ENABLED:
            return "SD卡驱动未就绪";
        case FR_INVALID_NAME:
            return "路径名无效";
        case FR_DENIED:
            return "SD卡访问被拒绝";
        case FR_OK:
            return "读取列表失败";
        default:
            return "存储异常";
    }
}

static void PsAppUi_SetEmptyListText(const char *text) {
    PsAppUi_CopyText(s_ps_app_ui_runtime.empty_list_text,
                     sizeof(s_ps_app_ui_runtime.empty_list_text),
                     text);
}

static void PsAppUi_SetScanDiagnostics(u8 failed, FRESULT fs_result) {
    s_ps_app_ui_runtime.last_scan_failed = failed;
    s_ps_app_ui_runtime.last_scan_fs_result = fs_result;
}

static u8 PsAppUi_StringFits(const char *text, size_t dst_size) {
    if ((text == NULL) || (dst_size == 0U)) {
        return 0U;
    }

    return (u8)(strlen(text) < dst_size);
}

static const char *PsAppUi_BaseName(const char *path) {
    const char *scan;
    const char *last_sep;

    if (path == NULL) {
        return "";
    }

    last_sep = path;
    scan = path;
    while (*scan != '\0') {
        if ((*scan == '/') || (*scan == '\\')) {
            last_sep = scan + 1;
        }
        scan++;
    }

    return last_sep;
}

static int PsAppUi_StrCaseCmp(const char *lhs, const char *rhs) {
    unsigned char lc;
    unsigned char rc;

    if (lhs == NULL) {
        lhs = "";
    }
    if (rhs == NULL) {
        rhs = "";
    }

    while ((*lhs != '\0') && (*rhs != '\0')) {
        lc = (unsigned char)tolower((unsigned char)*lhs);
        rc = (unsigned char)tolower((unsigned char)*rhs);
        if (lc != rc) {
            return (lc < rc) ? -1 : 1;
        }
        lhs++;
        rhs++;
    }

    if (*lhs == *rhs) {
        return 0;
    }

    return (*lhs == '\0') ? -1 : 1;
}

static u8 PsAppUi_HasGbaExtension(const char *name) {
    const char *dot;
    size_t ext_len;

    if (name == NULL) {
        return 0U;
    }

    dot = strrchr(name, '.');
    if (dot == NULL) {
        return 0U;
    }

    ext_len = strlen(dot);
    if (ext_len != 4U) {
        return 0U;
    }

    if ((tolower((unsigned char)dot[1]) == 'g') &&
        (tolower((unsigned char)dot[2]) == 'b') &&
        (tolower((unsigned char)dot[3]) == 'a') &&
        (dot[4] == '\0')) {
        return 1U;
    }

    return 0U;
}

static u8 PsAppUi_HeaderCodeIsPrintable(const char *text, size_t len) {
    size_t idx;

    if (text == NULL) {
        return 0U;
    }

    for (idx = 0U; idx < len; ++idx) {
        unsigned char ch;

        ch = (unsigned char)text[idx];
        if ((ch < 0x20U) || (ch > 0x7EU)) {
            return 0U;
        }
    }

    return 1U;
}

static void PsAppUi_ReadGameHeaderPreview(PsAppUiGameEntry *entry) {
    PsFatFsStorageReadResult read_result;
    u8 header[PS_APP_UI_GBA_HEADER_PREVIEW_BYTES];

    if ((entry == NULL) || (entry->path[0] == '\0')) {
        return;
    }

    memset(header, 0, sizeof(header));
    memset(&read_result, 0, sizeof(read_result));
    if ((PsFatFsStorage_ReadFilePrefix(entry->path,
                                       (UINTPTR)header,
                                       sizeof(header),
                                       &read_result) != XST_SUCCESS) ||
        (read_result.bytes_loaded < 0xB2U)) {
        entry->header_valid = 0U;
        entry->game_code[0] = '\0';
        entry->maker_code[0] = '\0';
        return;
    }

    memcpy(entry->game_code, &header[0xACU], 4U);
    entry->game_code[4] = '\0';
    memcpy(entry->maker_code, &header[0xB0U], 2U);
    entry->maker_code[2] = '\0';
    entry->header_valid =
        (u8)((PsAppUi_HeaderCodeIsPrintable(entry->game_code, 4U) != 0U) &&
             (PsAppUi_HeaderCodeIsPrintable(entry->maker_code, 2U) != 0U));
}

static void PsAppUi_FormatDisplayName(char *dst, size_t dst_size, const char *full_path) {
    const char *base;
    size_t len;

    if ((dst == NULL) || (dst_size == 0U)) {
        return;
    }

    base = PsAppUi_BaseName(full_path);
    len = strlen(base);
    if ((len > 4U) && (PsAppUi_HasGbaExtension(base) != 0U)) {
        len -= 4U;
    }

    PsAppUi_CopyUtf8TextBounded(dst, dst_size, base, len);
}

static int PsAppUi_GameEntryCompare(const void *lhs, const void *rhs) {
    const PsAppUiGameEntry *left;
    const PsAppUiGameEntry *right;
    int name_cmp;

    left = (const PsAppUiGameEntry *)lhs;
    right = (const PsAppUiGameEntry *)rhs;

    name_cmp = PsAppUi_StrCaseCmp(left->name, right->name);
    if (name_cmp != 0) {
        return name_cmp;
    }

    return PsAppUi_StrCaseCmp(left->path, right->path);
}

static u32 PsAppUi_StatusColor(const char *status_text) {
    if (status_text == NULL) {
        return PS_APP_UI_COLOR_INK;
    }

    if ((strstr(status_text, "失败") != NULL) ||
        (strstr(status_text, "错误") != NULL) ||
        (strstr(status_text, "异常") != NULL) ||
        (strstr(status_text, "未插入") != NULL)) {
        return PS_APP_UI_COLOR_RED;
    }
    if ((strstr(status_text, "扫描") != NULL) ||
        (strstr(status_text, "刷新") != NULL) ||
        (strstr(status_text, "加载") != NULL) ||
        (strstr(status_text, "切换中") != NULL) ||
        (strstr(status_text, "未找到") != NULL) ||
        (strstr(status_text, "返回") != NULL)) {
        return PS_APP_UI_COLOR_AMBER;
    }

    return PS_APP_UI_COLOR_INK;
}

static PsAppUiStatusRole PsAppUi_StatusRoleFromText(const char *status_text) {
    if (status_text == NULL) {
        return PS_APP_UI_STATUS_ROLE_INFO;
    }

    if ((strstr(status_text, "失败") != NULL) ||
        (strstr(status_text, "错误") != NULL) ||
        (strstr(status_text, "异常") != NULL) ||
        (strstr(status_text, "未插入") != NULL) ||
        (strstr(status_text, "未找到") != NULL)) {
        return PS_APP_UI_STATUS_ROLE_WARN;
    }
    if ((strstr(status_text, "运行") != NULL) ||
        (strstr(status_text, "加载") != NULL)) {
        return PS_APP_UI_STATUS_ROLE_PLAY;
    }

    return PS_APP_UI_STATUS_ROLE_INFO;
}

static void PsAppUi_ShowStatusIcon(PsAppUiStatusRole role) {
    if (s_ps_app_ui_runtime.status_icon_info != NULL) {
        if (role == PS_APP_UI_STATUS_ROLE_INFO) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_info, false);
        } else {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_info, true);
        }
    }
    if (s_ps_app_ui_runtime.status_icon_warn != NULL) {
        if (role == PS_APP_UI_STATUS_ROLE_WARN) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_warn, false);
        } else {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_warn, true);
        }
    }
    if (s_ps_app_ui_runtime.status_icon_play != NULL) {
        if (role == PS_APP_UI_STATUS_ROLE_PLAY) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_play, false);
        } else {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_icon_play, true);
        }
    }
}

static void PsAppUi_SetStatus(PsAppUiContext *ctx, const char *status_text) {
    PsAppUiStatusRole role;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    if (strcmp(ctx->state->status_line, (status_text != NULL) ? status_text : "") == 0) {
        return;
    }

    PsAppUi_CopyText(ctx->state->status_line, sizeof(ctx->state->status_line), status_text);
    role = PsAppUi_StatusRoleFromText(ctx->state->status_line);
    PsAppUi_ShowStatusIcon(role);
    if (s_ps_app_ui_runtime.status_label != NULL) {
        lv_obj_set_style_text_color(s_ps_app_ui_runtime.status_label,
                                    PsAppUi_HexColor(PsAppUi_StatusColor(ctx->state->status_line)),
                                    0);
        lv_label_set_text(s_ps_app_ui_runtime.status_label, ctx->state->status_line);
    }
}

static void PsAppUi_UpdateMetaLabels(PsAppUiContext *ctx) {
    char meta_text[96];

    if ((ctx == NULL) || (ctx->state == NULL) || (s_ps_app_ui_runtime.meta_label == NULL)) {
        return;
    }

    (void)snprintf(meta_text,
                   sizeof(meta_text),
                   "%u GAMES",
                   (unsigned int)ctx->state->game_count);
    lv_label_set_text(s_ps_app_ui_runtime.meta_label, meta_text);
}

static void PsAppUi_UpdateAudioRouteView(PsAppUiContext *ctx) {
    PsAppAudioRouteState route;
    PsAppAudioRouteState previous;
    const char *active_path_name;
    char status[96];
    u8 had_previous;
    u8 changed;

    if ((ctx == NULL) || (ctx->state == NULL) ||
        (ctx->runtime == NULL) || (ctx->runtime->audio == NULL)) {
        return;
    }
    PsAppRuntime_GetAudioRouteSnapshot(ctx->runtime, &route);
    active_path_name = PsAppAudioRouteLogic_PathName(route.active_path);
    if ((s_ps_app_ui_runtime.audio_route_label != NULL) &&
        (strcmp(lv_label_get_text(s_ps_app_ui_runtime.audio_route_label),
                active_path_name) != 0)) {
        lv_label_set_text(s_ps_app_ui_runtime.audio_route_label, active_path_name);
    }
    had_previous = s_ps_app_ui_runtime.audio_route_snapshot_valid;
    previous = s_ps_app_ui_runtime.last_audio_route;
    changed = (u8)((had_previous == 0U) ||
                   (route.active_path != previous.active_path) ||
                   (route.requested_path != previous.requested_path) ||
                   (route.status != previous.status) ||
                   (route.last_error != previous.last_error));
    if (changed == 0U) {
        return;
    }

    if ((had_previous != 0U) &&
        (ctx->state->mode == (u8)PS_APP_UI_MODE_MENU) &&
        (s_ps_app_ui_runtime.audio_route_label != NULL)) {
        lv_obj_invalidate(s_ps_app_ui_runtime.audio_route_label);
    }

    if (had_previous != 0U) {
        if ((route.status == (u8)PS_APP_AUDIO_ROUTE_PENDING) ||
            (route.status == (u8)PS_APP_AUDIO_ROUTE_SWITCHING)) {
            (void)snprintf(status, sizeof(status), "音频切换中：%s -> %s",
                           PsAppAudioRouteLogic_PathName(route.active_path),
                           PsAppAudioRouteLogic_PathName(route.requested_path));
            PsAppUi_SetStatus(ctx, status);
        } else if (route.status == (u8)PS_APP_AUDIO_ROUTE_FAILED) {
            (void)snprintf(status, sizeof(status), "音频切换失败(%u)，保留 %s",
                           (unsigned int)route.last_error,
                           PsAppAudioRouteLogic_PathName(route.active_path));
            PsAppUi_SetStatus(ctx, status);
        } else if ((route.status == (u8)PS_APP_AUDIO_ROUTE_IDLE) &&
                   (route.active_path != previous.active_path)) {
            (void)snprintf(status, sizeof(status), "音频输出：%s",
                           PsAppAudioRouteLogic_PathName(route.active_path));
            PsAppUi_SetStatus(ctx, status);
        }
    }
    if ((s_ps_app_ui_runtime.about_visible != 0U) &&
        (s_ps_app_ui_runtime.system_page == 2U)) {
        PsAppUi_UpdateSystemPanel(ctx);
    }

    s_ps_app_ui_runtime.last_audio_route = route;
    s_ps_app_ui_runtime.audio_route_snapshot_valid = 1U;
}

static void PsAppUi_UnixToDateTime(s64 unix_sec,
                                   s64 tz_offset_sec,
                                   s32 *year_out,
                                   u8 *month_out,
                                   u8 *day_out,
                                   u8 *hour_out,
                                   u8 *min_out,
                                   u8 *sec_out) {
    s64 shifted_sec;
    s64 days;
    s64 rem;
    s64 z;
    s64 era;
    u32 doe;
    u32 yoe;
    s64 y;
    u32 doy;
    u32 mp;
    u32 day;
    s32 month;

    if ((year_out == NULL) || (month_out == NULL) || (day_out == NULL) ||
        (hour_out == NULL) || (min_out == NULL) || (sec_out == NULL)) {
        return;
    }

    shifted_sec = unix_sec + tz_offset_sec;
    days = shifted_sec / 86400LL;
    rem = shifted_sec % 86400LL;
    if (rem < 0LL) {
        rem += 86400LL;
        days -= 1LL;
    }

    z = days + 719468LL;
    era = (z >= 0LL) ? (z / 146097LL) : ((z - 146096LL) / 146097LL);
    doe = (u32)(z - era * 146097LL);
    yoe = (doe - (doe / 1460U) + (doe / 36524U) - (doe / 146096U)) / 365U;
    y = (s64)yoe + era * 400LL;
    doy = doe - (365U * yoe + (yoe / 4U) - (yoe / 100U));
    mp = (5U * doy + 2U) / 153U;
    day = doy - (153U * mp + 2U) / 5U + 1U;
    month = (s32)mp + (((s32)mp < 10) ? 3 : -9);
    if (month <= 2) {
        y += 1LL;
    }

    *year_out = (s32)y;
    *month_out = (u8)month;
    *day_out = (u8)day;
    *hour_out = (u8)(rem / 3600LL);
    *min_out = (u8)((rem % 3600LL) / 60LL);
    *sec_out = (u8)(rem % 60LL);
}

static void PsAppUi_UpdateClockLabel(PsAppUiContext *ctx) {
    u32 unix_sec;
    s32 year;
    u8 month;
    u8 day;
    u8 hour;
    u8 minute;
    u8 second;
    char clock_text[48];

    if (s_ps_app_ui_runtime.clock_label == NULL) {
        return;
    }
    if ((ctx == NULL) || (ctx->runtime == NULL) || (ctx->runtime->config == NULL) ||
        (ctx->runtime->rtc == NULL) || (ctx->runtime->rtc->model_ready == 0U)) {
        if (s_ps_app_ui_runtime.last_clock_unix != PS_APP_UI_CLOCK_INVALID_UNIX) {
            lv_label_set_text(s_ps_app_ui_runtime.clock_label, "BJ ----/--/-- --:--:--");
            s_ps_app_ui_runtime.last_clock_unix = PS_APP_UI_CLOCK_INVALID_UNIX;
        }
        return;
    }

    unix_sec = ctx->runtime->config->rtc_timestamp;
    if (unix_sec == s_ps_app_ui_runtime.last_clock_unix) {
        return;
    }

    PsAppUi_UnixToDateTime((s64)unix_sec,
                           PS_APP_UI_BJ_OFFSET_SEC,
                           &year,
                           &month,
                           &day,
                           &hour,
                           &minute,
                           &second);
    (void)snprintf(clock_text,
                   sizeof(clock_text),
                   "BJ %04d-%02u-%02u %02u:%02u:%02u",
                   (int)year,
                   (unsigned int)month,
                   (unsigned int)day,
                   (unsigned int)hour,
                   (unsigned int)minute,
                   (unsigned int)second);
    lv_label_set_text(s_ps_app_ui_runtime.clock_label, clock_text);
    s_ps_app_ui_runtime.last_clock_unix = unix_sec;
}

static lv_obj_t *PsAppUi_CreatePixelPanel(lv_obj_t *parent,
                                          lv_coord_t x,
                                          lv_coord_t y,
                                          lv_coord_t w,
                                          lv_coord_t h,
                                          u32 bg_rgb,
                                          u32 border_rgb,
                                          u32 shadow_rgb) {
    lv_obj_t *shadow;
    lv_obj_t *panel;

    shadow = lv_obj_create(parent);
    lv_obj_remove_style_all(shadow);
    PsAppUi_Size(shadow, w, h);
    PsAppUi_Pos(shadow, x + PS_APP_UI_PANEL_SHADOW_OFFSET, y + PS_APP_UI_PANEL_SHADOW_OFFSET);
    PsAppUi_SetBoxStyle(shadow, shadow_rgb, shadow_rgb, 0);
    lv_obj_set_scrollable(shadow, false);

    panel = lv_obj_create(parent);
    lv_obj_remove_style_all(panel);
    PsAppUi_Size(panel, w, h);
    PsAppUi_Pos(panel, x, y);
    PsAppUi_SetBoxStyle(panel, bg_rgb, border_rgb, 2);
    lv_obj_set_scrollbar_mode(panel, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_scrollable(panel, false);

    return panel;
}

static lv_obj_t *PsAppUi_CreatePixelBlock(lv_obj_t *parent,
                                          lv_coord_t x,
                                          lv_coord_t y,
                                          lv_coord_t w,
                                          lv_coord_t h,
                                          u32 bg_rgb,
                                          u32 border_rgb) {
    lv_obj_t *block;

    block = lv_obj_create(parent);
    lv_obj_remove_style_all(block);
    PsAppUi_Size(block, w, h);
    PsAppUi_Pos(block, x, y);
    PsAppUi_SetBoxStyle(block, bg_rgb, border_rgb, 2);
    lv_obj_set_scrollbar_mode(block, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_scrollable(block, false);
    return block;
}

static void PsAppUi_BuildPixelDpad(lv_obj_t *parent, lv_coord_t x, lv_coord_t y) {
    const lv_coord_t block = 14;

    (void)PsAppUi_CreatePixelBlock(parent, x + block, y, block, block, PS_APP_UI_COLOR_SHELL_DARK, 0x080A08);
    (void)PsAppUi_CreatePixelBlock(parent, x, y + block, block, block, PS_APP_UI_COLOR_SHELL_DARK, 0x080A08);
    (void)PsAppUi_CreatePixelBlock(parent, x + block, y + block, block, block, 0x3A4037, 0x080A08);
    (void)PsAppUi_CreatePixelBlock(parent, x + (block * 2), y + block, block, block, PS_APP_UI_COLOR_SHELL_DARK, 0x080A08);
    (void)PsAppUi_CreatePixelBlock(parent, x + block, y + (block * 2), block, block, PS_APP_UI_COLOR_SHELL_DARK, 0x080A08);
}

static void PsAppUi_BuildPixelActionButtons(lv_obj_t *parent, lv_coord_t x, lv_coord_t y) {
    lv_obj_t *btn_a;
    lv_obj_t *btn_b;
    lv_obj_t *label_a;
    lv_obj_t *label_b;

    btn_b = PsAppUi_CreatePixelBlock(parent, x, y + 10, 18, 18, PS_APP_UI_COLOR_SHELL_DARK, 0x080A08);
    btn_a = PsAppUi_CreatePixelBlock(parent, x + 24, y, 18, 18, PS_APP_UI_COLOR_GREEN_DARK, 0x080A08);

    label_b = lv_label_create(btn_b);
    lv_label_set_text(label_b, "B");
    PsAppUi_SetTextStyle(label_b, PS_APP_UI_COLOR_TEXT_ON_DARK);
    lv_obj_center(label_b);

    label_a = lv_label_create(btn_a);
    lv_label_set_text(label_a, "A");
    PsAppUi_SetTextStyle(label_a, PS_APP_UI_COLOR_TEXT_ON_DARK);
    lv_obj_center(label_a);
}

static lv_obj_t *PsAppUi_CreateKeyHint(lv_obj_t *parent,
                                       lv_coord_t x,
                                       lv_coord_t y,
                                       const char *key_text,
                                       const char *action_text,
                                       u32 key_bg_rgb) {
    lv_obj_t *key_box;
    lv_obj_t *key_label;
    lv_obj_t *action_label;

    key_box = PsAppUi_CreatePixelBlock(parent, x, y, 42, 20, key_bg_rgb, PS_APP_UI_COLOR_SHELL_DARK);
    key_label = lv_label_create(key_box);
    lv_label_set_text(key_label, (key_text != NULL) ? key_text : "");
    PsAppUi_SetTextStyle(key_label, PS_APP_UI_COLOR_TEXT_ON_DARK);
    lv_obj_center(key_label);

    action_label = lv_label_create(parent);
    lv_label_set_text(action_label, (action_text != NULL) ? action_text : "");
    PsAppUi_SetTextStyle(action_label, PS_APP_UI_COLOR_INK);
    PsAppUi_AlignTo(action_label, key_box, LV_ALIGN_OUT_RIGHT_MID, 10, 0);

    return key_box;
}

static void PsAppUi_ResetSweepObject(void) {
    s_ps_app_ui_runtime.sweep = NULL;
    s_ps_app_ui_runtime.cursor = NULL;
}

static void PsAppUi_ResetGameButtons(void) {
    memset(s_ps_app_ui_runtime.game_buttons, 0, sizeof(s_ps_app_ui_runtime.game_buttons));
    s_ps_app_ui_runtime.game_button_count = 0U;
    PsAppUi_ResetSweepObject();
}

static void PsAppUi_StyleListRow(lv_obj_t *row) {
    if (row == NULL) {
        return;
    }

    PsAppUi_Width(row, lv_pct(100));
    PsAppUi_Height(row, 28);
    lv_obj_set_flex_grow(row, 0);
    lv_label_set_long_mode(row, LV_LABEL_LONG_MODE_DOTS);
    lv_label_set_max_lines(row, 1);
    lv_obj_set_style_radius(row, 0, 0);
    lv_obj_set_style_border_side(row, LV_BORDER_SIDE_FULL, 0);
    lv_obj_set_style_border_width(row, PsAppUi_Px(1), 0);
    lv_obj_set_style_border_color(row, PsAppUi_HexColor(PS_APP_UI_COLOR_LIST_BORDER), 0);
    lv_obj_set_style_bg_color(row, PsAppUi_HexColor(PS_APP_UI_COLOR_LIST_ROW), 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
    lv_obj_set_style_text_color(row, PsAppUi_HexColor(PS_APP_UI_COLOR_TEXT_MUTED), 0);
    lv_obj_set_style_text_font(row, PsAppUi_Font(), 0);
    lv_obj_set_style_pad_left(row, PsAppUi_Px(14), 0);
    lv_obj_set_style_pad_right(row, PsAppUi_Px(8), 0);
    lv_obj_set_style_pad_top(row, PsAppUi_Px(1), 0);
    lv_obj_set_style_pad_bottom(row, PsAppUi_Px(1), 0);
}

static void PsAppUi_UpdateListVisuals(PsAppUiContext *ctx, u8 reset_sweep) {
    PsAppUiState *state;
    u32 idx;
    u32 previous;
    lv_obj_t *selected_row;

    if ((ctx == NULL) || (ctx->state == NULL) || (s_ps_app_ui_runtime.list == NULL)) {
        return;
    }

    state = ctx->state;
    selected_row = NULL;

    if (state->game_count == 0U) {
        if (s_ps_app_ui_runtime.sweep != NULL) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.sweep, true);
        }
        if (s_ps_app_ui_runtime.cursor != NULL) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.cursor, true);
        }
        return;
    }

    if (state->selected_index >= state->game_count) {
        state->selected_index = (u8)(state->game_count - 1U);
    }

    if (!reset_sweep && s_ps_app_ui_runtime.visual_valid &&
        s_ps_app_ui_runtime.visual_selection == state->selected_index &&
        s_ps_app_ui_runtime.visual_blink == s_ps_app_ui_runtime.blink_phase) return;
    previous = s_ps_app_ui_runtime.visual_valid ?
        s_ps_app_ui_runtime.visual_selection : PS_APP_UI_MAX_GAMES;
    s_ps_app_ui_runtime.visual_valid = 1U;
    s_ps_app_ui_runtime.visual_selection = state->selected_index;
    s_ps_app_ui_runtime.visual_blink = s_ps_app_ui_runtime.blink_phase;

    /* Each ROM is one label row; explicit handles keep keyboard selection independent of child order. */
    for (idx = 0U; idx < (u32)state->game_count; ++idx) {
        lv_obj_t *row;

        if (idx != previous && idx != state->selected_index) continue;
        if (idx >= (u32)s_ps_app_ui_runtime.game_button_count) {
            break;
        }

        row = s_ps_app_ui_runtime.game_buttons[idx];
        if ((row == NULL) || (!lv_obj_is_valid(row))) {
            continue;
        }

        PsAppUi_StyleListRow(row);
        lv_obj_remove_state(row, LV_STATE_CHECKED);
        if (idx == (u32)state->selected_index) {
            selected_row = row;
            lv_obj_add_state(row, LV_STATE_CHECKED);
            lv_obj_set_style_bg_color(row, PsAppUi_HexColor(PS_APP_UI_COLOR_LIST_SELECTED), 0);
            lv_obj_set_style_border_side(row, LV_BORDER_SIDE_LEFT, 0);
            lv_obj_set_style_border_color(row,
                                          PsAppUi_HexColor((s_ps_app_ui_runtime.blink_phase == 0U) ?
                                                          PS_APP_UI_COLOR_GREEN_SOFT :
                                                          PS_APP_UI_COLOR_GREEN),
                                          0);
            lv_obj_set_style_text_color(row, PsAppUi_HexColor(PS_APP_UI_COLOR_TEXT_ON_DARK), 0);
            lv_obj_set_style_border_width(row, PsAppUi_Px(4), 0);
            lv_obj_set_style_pad_left(row, PsAppUi_Px(18), 0);
        }
    }

    if (selected_row == NULL) {
        if (s_ps_app_ui_runtime.sweep != NULL) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.sweep, true);
        }
        if (s_ps_app_ui_runtime.cursor != NULL) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.cursor, true);
        }
        return;
    }

    /* Keep the selected row visible; the left border carries the pixel cursor treatment. */
    if (reset_sweep) {
        lv_anim_enable_t animation = LV_ANIM_OFF;
        if (previous < state->game_count &&
            (previous + 1U == state->selected_index ||
             state->selected_index + 1U == previous)) {
            animation = LV_ANIM_ON;
        }
        lv_obj_scroll_to_view(selected_row, animation);
    }
    if (s_ps_app_ui_runtime.sweep != NULL) {
        lv_obj_set_hidden(s_ps_app_ui_runtime.sweep, true);
    }
    if (s_ps_app_ui_runtime.cursor != NULL) {
        lv_obj_set_hidden(s_ps_app_ui_runtime.cursor, true);
    }
}

static const char *PsAppUi_SaveKindName(u8 kind) {
    switch ((PsAppSaveKind)kind) {
        case PS_APP_SAVE_KIND_SRAM:
            return "SRAM";
        case PS_APP_SAVE_KIND_FLASH:
            return "FLASH";
        case PS_APP_SAVE_KIND_EEPROM:
            return "EEPROM";
        case PS_APP_SAVE_KIND_NONE:
        default:
            return "NONE";
    }
}

static const char *PsAppUi_BiosModeName(u8 mode) {
    switch ((PsAppBiosMode)mode) {
        case PS_APP_BIOS_MODE_EXTERNAL:
            return "EXT";
        case PS_APP_BIOS_MODE_FALLBACK:
            return "FALLBACK";
        case PS_APP_BIOS_MODE_INTERNAL:
        default:
            return "INT";
    }
}

static void PsAppUi_FormatBytes(char *dst, size_t dst_size, u32 bytes) {
    u32 mib100;

    if ((dst == NULL) || (dst_size == 0U)) {
        return;
    }

    if (bytes == 0U) {
        (void)snprintf(dst, dst_size, "--");
        return;
    }

    mib100 = (u32)(((u64)bytes * 100ULL) / (1024ULL * 1024ULL));
    (void)snprintf(dst,
                   dst_size,
                   "%u.%02u MiB",
                   (unsigned int)(mib100 / 100U),
                   (unsigned int)(mib100 % 100U));
}

static u8 PsAppUi_SelectedRomIsLoaded(PsAppUiContext *ctx, const char *selected_path) {
    if ((ctx == NULL) || (ctx->runtime == NULL) || (ctx->runtime->rom == NULL) ||
        (selected_path == NULL) || (selected_path[0] == '\0')) {
        return 0U;
    }

    if ((ctx->runtime->rom->loaded == 0U) || (ctx->runtime->rom->path[0] == '\0')) {
        return 0U;
    }

    return (u8)(strcmp(ctx->runtime->rom->path, selected_path) == 0 ? 1U : 0U);
}

static void PsAppUi_SetDetailPathText(const char *path_text) {
    lv_point_t text_size;
    char display_path[PS_APP_ROM_PATH_MAX_CHARS];
    lv_obj_t *label = s_ps_app_ui_runtime.detail_path_label;
    const lv_font_t *font = PsAppUi_Font();
    size_t i;

    if (label == NULL) {
        return;
    }

    PsAppUi_CopyText(display_path, sizeof(display_path), path_text != NULL ? path_text : "");
    for (i = 0U; display_path[i] != '\0'; ++i) {
        if (display_path[i] == '\r' || display_path[i] == '\n') display_path[i] = ' ';
    }
    if (strcmp(lv_label_get_text(label), display_path) == 0) return;
    lv_text_get_size(&text_size,
                     display_path,
                     font,
                     0,
                     0,
                     LV_COORD_MAX,
                     LV_TEXT_FLAG_NONE);
    lv_obj_set_height(label, LV_MAX(PsAppUi_Px(18), lv_font_get_line_height(font)));
    lv_obj_update_layout(label);
    if (text_size.x > lv_obj_get_content_width(label)) {
        lv_label_set_long_mode(label,
                               LV_LABEL_LONG_MODE_SCROLL_CIRCULAR);
    } else {
        lv_label_set_long_mode(label,
                               LV_LABEL_LONG_MODE_CLIP);
    }
    lv_label_set_text(label, display_path);
}

/*
 * Keep the complete selected ROM name available in the detail panel. Long names
 * scroll inside the fixed title field instead of being truncated like list rows.
 */
static void PsAppUi_SetDetailTitleText(const char *title_text) {
    lv_point_t text_size;
    const char *safe_text;
    lv_obj_t *label;

    label = s_ps_app_ui_runtime.detail_title_label;
    if (label == NULL) {
        return;
    }

    safe_text = (title_text != NULL) ? title_text : "";
    lv_text_get_size(&text_size,
                     safe_text,
                     PsAppUi_Font(),
                     0,
                     0,
                     LV_COORD_MAX,
                     LV_TEXT_FLAG_NONE);
    lv_label_set_long_mode(label,
                           (text_size.x > s_ps_app_ui_runtime.detail_title_width) ?
                           LV_LABEL_LONG_MODE_SCROLL_CIRCULAR :
                           LV_LABEL_LONG_MODE_CLIP);
    PsAppUi_Size(label, s_ps_app_ui_runtime.detail_title_width, 18);
    lv_label_set_text_static(label, safe_text);
}

static lv_obj_t *PsAppUi_CreateDetailFieldLabel(lv_obj_t *parent,
                                                const char *field_text,
                                                lv_coord_t y) {
    lv_obj_t *label;

    label = PsAppUi_CreateText(parent,
                               field_text,
                               PS_APP_UI_COLOR_INK_MUTED,
                               PS_APP_UI_DETAIL_FIELD_X,
                               y);
    PsAppUi_Width(label, PS_APP_UI_DETAIL_VALUE_X - PS_APP_UI_DETAIL_FIELD_X - 4);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, 0);
    return label;
}

static lv_obj_t *PsAppUi_CreateDetailValueLabel(lv_obj_t *parent,
                                                lv_coord_t y,
                                                u32 color_rgb) {
    lv_obj_t *label;

    label = lv_label_create(parent);
    PsAppUi_Width(label, s_ps_app_ui_runtime.detail_value_width);
    lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_DOTS);
    PsAppUi_SetTextStyle(label, color_rgb);
    PsAppUi_Pos(label, PS_APP_UI_DETAIL_VALUE_X, y);
    return label;
}

static void PsAppUi_UpdateDetailPanel(PsAppUiContext *ctx) {
    PsAppUiState *state;
    char slot_text[48];

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }
    if ((s_ps_app_ui_runtime.detail_title_label == NULL) ||
        (s_ps_app_ui_runtime.detail_path_label == NULL) ||
        (s_ps_app_ui_runtime.detail_slot_label == NULL) ||
        (s_ps_app_ui_runtime.detail_size_value_label == NULL) ||
        (s_ps_app_ui_runtime.detail_code_value_label == NULL) ||
        (s_ps_app_ui_runtime.detail_crc_value_label == NULL) ||
        (s_ps_app_ui_runtime.detail_bios_value_label == NULL) ||
        (s_ps_app_ui_runtime.detail_save_value_label == NULL) ||
        (s_ps_app_ui_runtime.detail_hint_label == NULL)) {
        return;
    }

    state = ctx->state;
    if (state->game_count == 0U) {
        if (s_ps_app_ui_runtime.last_scan_failed != 0U) {
            const char *reason;

            reason = PsAppUi_StorageFailureText(s_ps_app_ui_runtime.last_scan_fs_result);
            PsAppUi_SetDetailTitleText("STORAGE ERROR");
            PsAppUi_SetDetailPathText(PS_APP_GAMES_SD_DIR);
            lv_label_set_text(s_ps_app_ui_runtime.detail_slot_label, reason);
            lv_label_set_text(s_ps_app_ui_runtime.detail_size_value_label, "--");
            lv_label_set_text(s_ps_app_ui_runtime.detail_code_value_label, "--");
            lv_label_set_text(s_ps_app_ui_runtime.detail_crc_value_label, "--");
            lv_label_set_text(s_ps_app_ui_runtime.detail_bios_value_label, "READY");
            lv_label_set_text(s_ps_app_ui_runtime.detail_save_value_label, "CHECK SD");
            lv_label_set_text(s_ps_app_ui_runtime.detail_hint_label, "修复SD后按 X/START");
            return;
        }

        PsAppUi_SetDetailTitleText("NO CARTRIDGE");
        PsAppUi_SetDetailPathText("0:/games");
        lv_label_set_text(s_ps_app_ui_runtime.detail_slot_label, "EMPTY LIBRARY");
        lv_label_set_text(s_ps_app_ui_runtime.detail_size_value_label, "--");
        lv_label_set_text(s_ps_app_ui_runtime.detail_code_value_label, "--");
        lv_label_set_text(s_ps_app_ui_runtime.detail_crc_value_label, "--");
        lv_label_set_text(s_ps_app_ui_runtime.detail_bios_value_label, "READY");
        lv_label_set_text(s_ps_app_ui_runtime.detail_save_value_label, "WAITING FOR SD");
        lv_label_set_text(s_ps_app_ui_runtime.detail_hint_label, "放入游戏后按 X/START 刷新");
        return;
    }

    if (state->selected_index >= state->game_count) {
        state->selected_index = (u8)(state->game_count - 1U);
    }

    PsAppUi_SetDetailTitleText(s_ps_app_ui_runtime.games[state->selected_index].name);
    (void)snprintf(slot_text,
                   sizeof(slot_text),
                   "SLOT %03u / %03u",
                   (unsigned int)state->selected_index + 1U,
                   (unsigned int)state->game_count);
    lv_label_set_text(s_ps_app_ui_runtime.detail_slot_label, slot_text);
    PsAppUi_SetDetailPathText(s_ps_app_ui_runtime.games[state->selected_index].path);

    if (PsAppUi_SelectedRomIsLoaded(ctx, s_ps_app_ui_runtime.games[state->selected_index].path) != 0U) {
        char size_text[24];
        u32 crc32;
        const char *game_code;
        const char *maker_code;

        PsAppUi_FormatBytes(size_text, sizeof(size_text), ctx->runtime->rom->size_bytes);
        crc32 = (ctx->runtime->feature != NULL) ? ctx->runtime->feature->rom_crc32 : 0U;
        game_code = (ctx->runtime->rom->game_code[0] != '\0') ? ctx->runtime->rom->game_code : "....";
        maker_code = (ctx->runtime->rom->maker_code[0] != '\0') ? ctx->runtime->rom->maker_code : "..";
        (void)snprintf(slot_text, sizeof(slot_text), "%s / %s", game_code, maker_code);
        lv_label_set_text(s_ps_app_ui_runtime.detail_size_value_label, size_text);
        lv_label_set_text(s_ps_app_ui_runtime.detail_code_value_label, slot_text);
        (void)snprintf(slot_text, sizeof(slot_text), "%08X", (unsigned int)crc32);
        lv_label_set_text(s_ps_app_ui_runtime.detail_crc_value_label, slot_text);
        lv_label_set_text(s_ps_app_ui_runtime.detail_bios_value_label,
                          PsAppUi_BiosModeName(ctx->runtime->rom->bios_mode));
        (void)snprintf(slot_text,
                       sizeof(slot_text),
                       "%s %s",
                       (ctx->runtime->save != NULL) ? PsAppUi_SaveKindName(ctx->runtime->save->active_kind) : "NONE",
                       ((ctx->runtime->save != NULL) && (ctx->runtime->save->dirty != 0U)) ? "DIRTY" : "CLEAN");
        lv_label_set_text(s_ps_app_ui_runtime.detail_save_value_label, slot_text);
        lv_label_set_text(s_ps_app_ui_runtime.detail_hint_label, "A 重新启动此卡带");
    } else {
        PsAppUi_FormatBytes(slot_text,
                            sizeof(slot_text),
                            s_ps_app_ui_runtime.games[state->selected_index].size_bytes);
        lv_label_set_text(s_ps_app_ui_runtime.detail_size_value_label, slot_text);
        if (s_ps_app_ui_runtime.games[state->selected_index].header_valid != 0U) {
            (void)snprintf(slot_text,
                           sizeof(slot_text),
                           "%s / %s",
                           s_ps_app_ui_runtime.games[state->selected_index].game_code,
                           s_ps_app_ui_runtime.games[state->selected_index].maker_code);
            lv_label_set_text(s_ps_app_ui_runtime.detail_code_value_label, slot_text);
        } else {
            lv_label_set_text(s_ps_app_ui_runtime.detail_code_value_label, "HEADER N/A");
        }
        lv_label_set_text(s_ps_app_ui_runtime.detail_crc_value_label, "ON LAUNCH");
        lv_label_set_text(s_ps_app_ui_runtime.detail_bios_value_label, "READY");
        lv_label_set_text(s_ps_app_ui_runtime.detail_save_value_label, "AUTO DETECT");
        lv_label_set_text(s_ps_app_ui_runtime.detail_hint_label, "A 启动此卡带");
    }
}

static void PsAppUi_RebuildList(PsAppUiContext *ctx) {
    PsAppUiState *state;
    u32 idx;

    if ((ctx == NULL) || (ctx->state == NULL) || (s_ps_app_ui_runtime.list == NULL)) {
        return;
    }

    state = ctx->state;
    /* 每次重建列表都先清空容器，再重新登记按钮指针数组。
     * 这样 UpdateListVisuals 只会命中“本次创建”的有效按钮对象。 */
    lv_obj_clean(s_ps_app_ui_runtime.list);
    PsAppUi_ResetGameButtons();
    s_ps_app_ui_runtime.visual_valid = 0U;

    if (state->game_count == 0U) {
        lv_obj_t *empty_label;

        empty_label = lv_label_create(s_ps_app_ui_runtime.list);
        PsAppUi_Width(empty_label, lv_pct(100));
        lv_label_set_long_mode(empty_label, LV_LABEL_LONG_WRAP);
        lv_label_set_text(empty_label,
                          (s_ps_app_ui_runtime.empty_list_text[0] != '\0') ?
                          s_ps_app_ui_runtime.empty_list_text :
                          "没有找到 .gba 游戏\n请将 ROM 放入 0:/games 后刷新");
        PsAppUi_SetTextStyle(empty_label, PS_APP_UI_COLOR_TEXT_MUTED);
        lv_obj_set_style_text_align(empty_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_pad_top(empty_label, PsAppUi_Px(70), 0);
        lv_obj_set_style_pad_left(empty_label, PsAppUi_Px(12), 0);
        lv_obj_set_style_pad_right(empty_label, PsAppUi_Px(12), 0);
    } else {
        for (idx = 0U; idx < (u32)state->game_count; ++idx) {
            lv_obj_t *row;

            row = lv_label_create(s_ps_app_ui_runtime.list);
            lv_obj_remove_style_all(row);
            PsAppUi_StyleListRow(row);
            /* Game names live in the UI-owned fixed array for the row lifetime. */
            lv_label_set_text_static(row, s_ps_app_ui_runtime.games[idx].name);
            s_ps_app_ui_runtime.game_buttons[idx] = row;
            s_ps_app_ui_runtime.game_button_count = (u16)(idx + 1U);
        }
    }

    PsAppUi_UpdateMetaLabels(ctx);
    PsAppUi_UpdateListVisuals(ctx, 1U);
    PsAppUi_UpdateDetailPanel(ctx);
}

static u8 PsAppUi_ListDirectoryCallback(const char *name,
                                        const char *full_path,
                                        u8 is_dir,
                                        u32 size_bytes,
                                        void *user_ctx) {
    PsAppUiScanContext *scan_ctx;
    PsAppUiGameEntry *entry;

    if (is_dir != 0U) {
        return 1U;
    }

    if (PsAppUi_HasGbaExtension(name) == 0U) {
        return 1U;
    }

    scan_ctx = (PsAppUiScanContext *)user_ctx;
    if ((scan_ctx == NULL) || (scan_ctx->games == NULL)) {
        return 0U;
    }

    if (scan_ctx->count >= PS_APP_UI_MAX_GAMES) {
        scan_ctx->overflow = 1U;
        return 0U;
    }

    if ((full_path == NULL) || (PsAppUi_StringFits(full_path, sizeof(scan_ctx->games[0].path)) == 0U)) {
        scan_ctx->skipped_long_path = 1U;
        return 1U;
    }

    entry = &scan_ctx->games[scan_ctx->count];
    memset(entry, 0, sizeof(*entry));
    PsAppUi_FormatDisplayName(entry->name,
                              sizeof(entry->name),
                              (full_path != NULL) ? full_path : name);
    PsAppUi_CopyText(entry->path, sizeof(entry->path), full_path);
    entry->size_bytes = size_bytes;
    scan_ctx->count++;
    return 1U;
}

static XStatus PsAppUi_RefreshGames(PsAppUiContext *ctx) {
    PsAppUiScanContext scan_ctx;
    PsFatFsStorageListResult list_result;
    PsAppUiState *state;
    XStatus status;
    TickType_t retry_ticks;
    u8 scan_try;
    char status_text[PS_APP_UI_GAME_NAME_MAX_CHARS];
    u32 idx;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return XST_INVALID_PARAM;
    }

    state = ctx->state;
    scan_ctx.games = s_ps_app_ui_runtime.games;
    scan_ctx.count = 0U;
    scan_ctx.overflow = 0U;
    scan_ctx.skipped_long_path = 0U;
    memset(&list_result, 0, sizeof(list_result));
    PsAppUi_SetScanDiagnostics(0U, FR_OK);
    PsAppUi_SetEmptyListText("正在扫描 0:/games ...");

    retry_ticks = PsAppTime_MsToTicksCeil(120U);
    if (retry_ticks == 0U) {
        retry_ticks = 1U;
    }

    /* 扫描固定目录 0:/games，仅收集 .gba 文件。
     * 启动早期若出现“目录瞬态空视图”（visited=0 且 count=0），
     * 进行短延时重扫，覆盖 SD 初始化抖动窗口。 */
    status = XST_FAILURE;
    for (scan_try = 0U; scan_try < 3U; ++scan_try) {
        scan_ctx.count = 0U;
        scan_ctx.overflow = 0U;
        scan_ctx.skipped_long_path = 0U;
        memset(&list_result, 0, sizeof(list_result));

        status = PsFatFsStorage_ListDirectoryEx(PS_APP_GAMES_SD_DIR,
                                                PsAppUi_ListDirectoryCallback,
                                                &scan_ctx,
                                                &list_result);

        if ((status == XST_SUCCESS) &&
            (scan_ctx.count == 0U) &&
            (list_result.entries_visited == 0U) &&
            (scan_try < 2U)) {
            xil_printf("[UI] scan delayed-retry #%u path=%s\r\n",
                       (unsigned int)(scan_try + 1U),
                       PS_APP_GAMES_SD_DIR);
            vTaskDelay(retry_ticks);
            continue;
        }

        break;
    }

    state->game_count = (u8)((scan_ctx.count > 255U) ? 255U : scan_ctx.count);
    for (idx = 0U; idx < scan_ctx.count; ++idx) {
        PsAppUi_ReadGameHeaderPreview(&s_ps_app_ui_runtime.games[idx]);
    }
    /* 菜单展示按名称排序，保证每次刷新顺序稳定。 */
    if (scan_ctx.count > 1U) {
        qsort(s_ps_app_ui_runtime.games,
              scan_ctx.count,
              sizeof(s_ps_app_ui_runtime.games[0]),
              PsAppUi_GameEntryCompare);
    }

    /* 仅打印前 8 条样本，避免串口刷屏影响交互实时性。 */
    xil_printf("[UI] scan status=%d fs=%s count=%u visited=%u skip_long=%u overflow=%u\r\n",
               (int)status,
               PsFatFsStorage_StrError(list_result.fs_result),
               (unsigned int)scan_ctx.count,
               (unsigned int)list_result.entries_visited,
               (unsigned int)list_result.entries_skipped_long,
               (unsigned int)scan_ctx.overflow);
    for (idx = 0U; (idx < scan_ctx.count) && (idx < 8U); ++idx) {
        xil_printf("[UI] game[%u]=%s\r\n",
                   (unsigned int)idx,
                   s_ps_app_ui_runtime.games[idx].name);
    }
    if (scan_ctx.count > 8U) {
        xil_printf("[UI] ... (%u more)\r\n",
                   (unsigned int)(scan_ctx.count - 8U));
    }

    if (state->game_count == 0U) {
        state->selected_index = 0U;
    } else if (state->selected_index >= state->game_count) {
        state->selected_index = (u8)(state->game_count - 1U);
    }

    if (status == XST_SUCCESS) {
        PsAppUi_SetScanDiagnostics(0U, FR_OK);
        if (state->game_count == 0U) {
            PsAppUi_SetEmptyListText("没有找到 .gba 游戏\n请将 ROM 放入 0:/games 后刷新");
            PsAppUi_SetStatus(ctx, "未找到游戏");
        } else if (scan_ctx.skipped_long_path != 0U) {
            PsAppUi_SetEmptyListText("没有可显示的 .gba 游戏\n部分路径过长，已跳过");
            PsAppUi_SetStatus(ctx, "部分路径过长，已跳过");
        } else if (scan_ctx.overflow != 0U) {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "仅显示前%u项",
                           (unsigned int)PS_APP_UI_MAX_GAMES);
            PsAppUi_SetStatus(ctx, status_text);
        } else {
            PsAppUi_SetEmptyListText("");
            PsAppUi_SetStatus(ctx, "菜单就绪");
        }
    } else {
        const char *reason;

        reason = PsAppUi_StorageFailureText(list_result.fs_result);
        PsAppUi_SetScanDiagnostics(1U, list_result.fs_result);
        /* 扫描失败但已有部分结果时仍允许进入菜单，避免“全失败感知”。 */
        if (state->game_count > 0U) {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "菜单就绪(部分): %s",
                           reason);
            PsAppUi_SetStatus(ctx, status_text);
        } else {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "读取列表失败\n%s\n插入SD卡或修复后按 X/START 刷新",
                           reason);
            PsAppUi_SetEmptyListText(status_text);
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "读取列表失败: %s",
                           reason);
            PsAppUi_SetStatus(ctx, status_text);
        }
    }

    state->refresh_requested = 0U;
    PsAppUi_RebuildList(ctx);
    return status;
}

static u8 PsAppUi_ButtonPressedEdge(u16 prev_buttons, u16 cur_buttons, u16 button_mask) {
    if (((cur_buttons & button_mask) != 0U) &&
        ((prev_buttons & button_mask) == 0U)) {
        return 1U;
    }

    return 0U;
}

static u32 PsAppUi_ReadPhysicalKeys(const PsAppRuntimeContext *runtime) {
    if ((runtime == NULL) || (runtime->regs == NULL)) {
        return 0U;
    }

    /* 板载按键来自 PL 侧状态寄存器，不依赖 USB 手柄链路。 */
    return PsGbaRegs_Read(runtime->regs, GBA_REG_STATUS0) & 0x3FFU;
}

static u16 PsAppUi_MapPhysicalKeysToMenuButtons(u32 physical_keys) {
    u16 buttons;

    buttons = 0U;

    if ((physical_keys & PS_APP_UI_PHY_KEY_UP) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_UP;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_DOWN) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_DOWN;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_LEFT) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_LEFT;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_RIGHT) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_RIGHT;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_A) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_A;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_B) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_B;
    }
    /* 板载菜单映射：
     * START(物理 bit3) -> 刷新（等价 X）
     * SELECT(物理 bit2) -> 关于（等价 Y） */
    if ((physical_keys & PS_APP_UI_PHY_KEY_START) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_X;
    }
    if ((physical_keys & PS_APP_UI_PHY_KEY_SELECT) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_Y;
    }

    return buttons;
}

static u16 PsAppUi_GetMenuButtonMask(const PsAppRuntimeContext *runtime) {
    const PsAppInputState *input;
    u16 buttons;
    u32 src_mask;
    u32 physical_keys;

    if (runtime == NULL) {
        return 0U;
    }

    input = runtime->input;
    buttons = (input != NULL) ? input->buttons : 0U;
    src_mask = (input != NULL) ? input->source_snapshot_mask : 0U;
    physical_keys = PsAppUi_ReadPhysicalKeys(runtime);

    /* 兼容首进菜单阶段的方向输入来源差异：
     * 某些手柄/接收器在启动初期会把方向优先体现在左摇杆阈值位，
     * 而不是 XInput DPad 低 4 位。菜单统一把“摇杆方向位”折叠成 DPad 位，
     * 这样 UI 的上下选择逻辑不依赖具体报告形态。 */
    if ((src_mask & PS_APP_INPUT_SRC_MASK_LS_UP) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_UP;
    }
    if ((src_mask & PS_APP_INPUT_SRC_MASK_LS_DOWN) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_DOWN;
    }
    if ((src_mask & PS_APP_INPUT_SRC_MASK_LS_LEFT) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_LEFT;
    }
    if ((src_mask & PS_APP_INPUT_SRC_MASK_LS_RIGHT) != 0U) {
        buttons |= PS_XINPUT_BUTTON_MASK_RIGHT;
    }

    /* 菜单输入最终来源 = 手柄输入 OR 板载物理键输入。 */
    buttons |= PsAppUi_MapPhysicalKeysToMenuButtons(physical_keys);

    return buttons;
}

static void PsAppUi_ForceFullRedraw(void) {
    if ((s_ps_app_ui_runtime.display == NULL) || (s_ps_app_ui_runtime.root_screen == NULL)) {
        return;
    }

    /* GAME 态期间显示链路会持续写入视频帧。
     * 返回 MENU 后如果只靠 LVGL 的局部脏区刷新，可能残留黑底或旧帧碎片。
     * 这里强制把整屏标脏并立即刷新，确保菜单壳体/背景一次性完整恢复。 */
    lv_obj_invalidate(s_ps_app_ui_runtime.root_screen);
    PsAppUi_RefreshNative();
}

static void PsAppUi_EnsureMenuScreen(void) {
    if ((s_ps_app_ui_runtime.root_screen != NULL) &&
        (lv_screen_active() != s_ps_app_ui_runtime.root_screen)) {
        lv_screen_load(s_ps_app_ui_runtime.root_screen);
        PsAppUi_ForceFullRedraw();
    }
}

static u8 PsAppUi_ReadDisplaySupportMask(const PsAppHdmiLinkContext *link) {
    u8 support_mask = 0U;
    unsigned int mode;

    if ((link == NULL) || (link->state == NULL)) {
        return support_mask;
    }

    for (mode = 0U; mode < (unsigned int)PS_APP_VIDEO_MODE_COUNT; ++mode) {
        if (PsAppHdmiLink_ModeSupported(link, (u8)mode) != 0U) {
            support_mask |= (u8)(1U << mode);
        }
    }
    return support_mask;
}

static u8 PsAppUi_UpdateDisplayChoiceRows(PsAppUiContext *ctx, u8 support_mask) {
    PsAppHdmiLinkContext *link = (ctx != NULL) && (ctx->runtime != NULL)
        ? ctx->runtime->hdmi_ctx : NULL;
    u8 active_mode = PS_APP_VIDEO_MODE_VGA480;
    u8 recovery_state = 0U;
    u8 previous_choice = s_ps_app_ui_runtime.display_choice;
    u8 rows_changed;
    unsigned int index;

    if ((link != NULL) && (link->state != NULL)) {
        active_mode = link->state->video_mode_active;
        if (link->state->dvi_recovery_failed != 0U) {
            recovery_state = 2U;
        } else if (link->state->dvi_recovery_latched != 0U) {
            recovery_state = 1U;
        }
    }

    if (s_ps_app_ui_runtime.display_choice >= PS_APP_UI_DISPLAY_OPTION_COUNT) {
        s_ps_app_ui_runtime.display_choice = (u8)PS_APP_VIDEO_MODE_COUNT;
    } else if ((s_ps_app_ui_runtime.display_preview == 0U) &&
               (s_ps_app_ui_runtime.display_choice < PS_APP_VIDEO_MODE_COUNT) &&
               ((support_mask & (u8)(1U << s_ps_app_ui_runtime.display_choice)) == 0U)) {
        if ((active_mode < PS_APP_VIDEO_MODE_COUNT) &&
            ((support_mask & (u8)(1U << active_mode)) != 0U)) {
            s_ps_app_ui_runtime.display_choice = active_mode;
        } else {
            s_ps_app_ui_runtime.display_choice = (u8)PS_APP_VIDEO_MODE_COUNT;
        }
    }

    rows_changed = (u8)((s_ps_app_ui_runtime.display_rows_valid == 0U) ||
                        (s_ps_app_ui_runtime.display_rows_support_mask != support_mask) ||
                        (s_ps_app_ui_runtime.display_rows_active_mode != active_mode) ||
                        (s_ps_app_ui_runtime.display_rows_choice !=
                         s_ps_app_ui_runtime.display_choice) ||
                        (s_ps_app_ui_runtime.display_rows_preview !=
                         s_ps_app_ui_runtime.display_preview) ||
                        (s_ps_app_ui_runtime.display_rows_recovery_state != recovery_state));
    if (rows_changed == 0U) {
        return (u8)(previous_choice != s_ps_app_ui_runtime.display_choice);
    }

    for (index = 0U; index < (unsigned int)PS_APP_UI_DISPLAY_OPTION_COUNT; ++index) {
        lv_obj_t *label = s_ps_app_ui_runtime.display_choice_labels[index];
        const PsAppUiDisplayOption *option = &s_ps_app_ui_display_options[index];
        u8 supported = (u8)((option->mode == PS_APP_HDMI_MODE_AUTO) ||
                            ((support_mask & (u8)(1U << option->mode)) != 0U));
        u8 selected = (u8)((s_ps_app_ui_runtime.display_choice == index) &&
                           (supported != 0U));
        u8 active = (u8)(((option->mode == PS_APP_HDMI_MODE_AUTO) &&
                          (selected != 0U)) ||
                         ((option->mode < PS_APP_VIDEO_MODE_COUNT) &&
                          (option->mode == active_mode)));
        char row_text[32];

        if (label == NULL) {
            continue;
        }
        (void)snprintf(row_text, sizeof(row_text), "%c %s%s",
                       (selected != 0U) ? '>' : ' ',
                       option->name,
                       (active != 0U) ? "  *" : "");
        lv_label_set_text(label, row_text);
        lv_obj_set_style_text_color(label,
                                    PsAppUi_HexColor((supported != 0U) ?
                                        PS_APP_UI_COLOR_TEXT_ON_DARK :
                                        PS_APP_UI_COLOR_TEXT_MUTED),
                                    0);
    }

    s_ps_app_ui_runtime.display_rows_support_mask = support_mask;
    s_ps_app_ui_runtime.display_rows_active_mode = active_mode;
    s_ps_app_ui_runtime.display_rows_choice = s_ps_app_ui_runtime.display_choice;
    s_ps_app_ui_runtime.display_rows_preview = s_ps_app_ui_runtime.display_preview;
    s_ps_app_ui_runtime.display_rows_recovery_state = recovery_state;
    s_ps_app_ui_runtime.display_rows_valid = 1U;
    return (u8)((rows_changed != 0U) ||
                (previous_choice != s_ps_app_ui_runtime.display_choice));
}

static void PsAppUi_UpdateSystemPanel(PsAppUiContext *ctx) {
    PsAppAudioRouteState route;
    char body[256];
    char side[192];
    char hint[96];
    unsigned int index;

    if ((s_ps_app_ui_runtime.about_title_label == NULL) ||
        (s_ps_app_ui_runtime.about_body_label == NULL) ||
        (s_ps_app_ui_runtime.about_side_label == NULL) ||
        (s_ps_app_ui_runtime.about_hint_label == NULL)) {
        return;
    }

    body[0] = '\0';
    side[0] = '\0';
    hint[0] = '\0';
    if (s_ps_app_ui_runtime.system_page == 0U) {
        lv_label_set_text(s_ps_app_ui_runtime.about_title_label, "SYSTEM SETTINGS");
        (void)snprintf(body, sizeof(body), "%c DISPLAY\n%c AUDIO\n%c ABOUT",
                       (s_ps_app_ui_runtime.system_selection == 0U) ? '>' : ' ',
                       (s_ps_app_ui_runtime.system_selection == 1U) ? '>' : ' ',
                       (s_ps_app_ui_runtime.system_selection == 2U) ? '>' : ' ');
        (void)snprintf(side, sizeof(side), "PIXEL GBA\nSYSTEM MENU");
        (void)snprintf(hint, sizeof(hint), "UP/DOWN MOVE  A OPEN  B CLOSE");
    } else if (s_ps_app_ui_runtime.system_page == 1U) {
        PsAppHdmiLinkContext *link = (ctx != NULL) && (ctx->runtime != NULL)
            ? ctx->runtime->hdmi_ctx : NULL;
        u8 active = (link != NULL) && (link->state != NULL)
            ? link->state->video_mode_active : PS_APP_VIDEO_MODE_VGA480;

        lv_label_set_text(s_ps_app_ui_runtime.about_title_label, "DISPLAY OUTPUT");
        (void)PsAppUi_UpdateDisplayChoiceRows(ctx,
                                               PsAppUi_ReadDisplaySupportMask(link));
        (void)snprintf(side, sizeof(side), "CURRENT\n%s%s",
                       (active == PS_APP_VIDEO_MODE_1080P60) ? "1080p60" :
                       (active == PS_APP_VIDEO_MODE_1080P30) ? "1080p30" :
                       ((active == PS_APP_VIDEO_MODE_720P60) ? "720p60" : "480p60"),
                       ((link != NULL) && (link->state != NULL) &&
                        (link->state->dvi_recovery_failed != 0U)) ? "\nRECOVERY FAILED" :
                       (((link != NULL) && (link->state != NULL) &&
                         (link->state->dvi_recovery_latched != 0U)) ? "\nDVI RECOVERY" : ""));
        (void)snprintf(hint, sizeof(hint),
                       (s_ps_app_ui_runtime.display_preview != 0U) ?
                       "A KEEP  B RESTORE  AUTO 10 SEC" :
                       (((link != NULL) && (link->state != NULL) &&
                         (link->state->dvi_recovery_latched != 0U)) ?
                        "UP/DOWN SELECT  A TEST MODE  B BACK" :
                        "UP/DOWN SELECT  A APPLY  B BACK"));
    } else if (s_ps_app_ui_runtime.system_page == 2U) {
        PsAppRuntime_GetAudioRouteSnapshot(ctx->runtime, &route);
        lv_label_set_text(s_ps_app_ui_runtime.about_title_label, "AUDIO OUTPUT");
        (void)snprintf(body, sizeof(body), "ACTIVE\n%s\n\nA TOGGLE OUTPUT",
                       PsAppAudioRouteLogic_PathName(route.active_path));
        (void)snprintf(side, sizeof(side), "HDMI\nI2S CODEC");
        (void)snprintf(hint, sizeof(hint), "A TOGGLE OUTPUT  B BACK");
    } else {
        lv_label_set_text(s_ps_app_ui_runtime.about_title_label, "PIXEL GBA / SYSTEM INFO");
        (void)snprintf(body, sizeof(body),
                       "SYSTEM\nLVGL 9.6 / FreeRTOS\nFatFs UTF-8 LFN / XRGB8888\n"
                       "PROJECT\nZynq GBA / MiSTer-Vivado\n"
                       "PIXEL GBA handheld menu\n潘子彧 / 上海电机学院 2022级");
        (void)snprintf(side, sizeof(side),
                       "CREDITS\nLVGL graphics\nFreeRTOS\nFatFs\nCherryUSB\n"
                       "Xilinx Vitis\nFusion Pixel Font");
        (void)snprintf(hint, sizeof(hint), "B BACK TO SYSTEM MENU");
    }

    lv_label_set_text(s_ps_app_ui_runtime.about_body_label, body);
    lv_label_set_text(s_ps_app_ui_runtime.about_side_label, side);
    lv_label_set_text(s_ps_app_ui_runtime.about_hint_label, hint);
    lv_obj_set_hidden(s_ps_app_ui_runtime.about_body_label,
                      (s_ps_app_ui_runtime.system_page == 1U));
    for (index = 0U; index < (unsigned int)PS_APP_UI_DISPLAY_OPTION_COUNT; ++index) {
        if (s_ps_app_ui_runtime.display_choice_labels[index] != NULL) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.display_choice_labels[index],
                              (s_ps_app_ui_runtime.system_page != 1U));
        }
    }
}
static void PsAppUi_SetAboutVisible(PsAppUiContext *ctx, u8 visible) {
    PsAppUiState *state;
    const char *resume_status;
    char resume_buffer[96];

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    if (s_ps_app_ui_runtime.about_panel == NULL) {
        return;
    }

    state = ctx->state;
    if (visible != 0U) {
        /* The system panel owns menu input while it is visible. */
        lv_obj_set_hidden(s_ps_app_ui_runtime.about_panel, false);
        s_ps_app_ui_runtime.about_visible = 1U;
        s_ps_app_ui_runtime.system_page = 0U;
        s_ps_app_ui_runtime.system_selection = 0U;
        s_ps_app_ui_runtime.display_choice = 3U;
        s_ps_app_ui_runtime.display_preview = 0U;
        PsAppUi_SetStatus(ctx, "系统设置");
        PsAppUi_UpdateSystemPanel(ctx);
    } else {
        lv_obj_set_hidden(s_ps_app_ui_runtime.about_panel, true);
        s_ps_app_ui_runtime.about_visible = 0U;

        if (s_ps_app_ui_runtime.last_scan_failed != 0U) {
            (void)snprintf(resume_buffer,
                           sizeof(resume_buffer),
                           "读取列表失败: %s",
                           PsAppUi_StorageFailureText(s_ps_app_ui_runtime.last_scan_fs_result));
            resume_status = resume_buffer;
        } else if (state->game_count == 0U) {
            resume_status = "未找到游戏";
        } else {
            resume_status = "菜单就绪";
        }
        PsAppUi_SetStatus(ctx, resume_status);
    }
}

static u8 PsAppUi_ProcessDisplayMode(PsAppUiContext *ctx, u16 previous, u16 current) {
    PsAppHdmiLinkContext *link;
    u8 support_mask;
    u8 choice_before_refresh;
    u8 choice_changed;
    u8 back;
    u8 accept;
    u8 up;
    u8 down;
    u8 left;
    u8 right;
    int direction;
    unsigned int attempt;

    if ((ctx == NULL) || (ctx->runtime == NULL) ||
        (s_ps_app_ui_runtime.about_visible == 0U) ||
        (s_ps_app_ui_runtime.system_page != 1U)) {
        return 0U;
    }
    link = ctx->runtime->hdmi_ctx;
    back = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_B);
    accept = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_A);
    up = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_UP);
    down = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_DOWN);
    left = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_LEFT);
    right = PsAppUi_ButtonPressedEdge(previous, current, PS_XINPUT_BUTTON_MASK_RIGHT);

    if ((link != NULL) && (link->state != NULL) &&
        (s_ps_app_ui_runtime.display_preview == 0U) &&
        (link->state->dvi_recovery_preview != 0U)) {
        s_ps_app_ui_runtime.display_previous_mode = link->state->video_mode_confirmed;
        s_ps_app_ui_runtime.display_preview = 1U;
        s_ps_app_ui_runtime.display_preview_timer_started = 0U;
    }

    choice_before_refresh = s_ps_app_ui_runtime.display_choice;
    support_mask = PsAppUi_ReadDisplaySupportMask(link);
    if (PsAppUi_UpdateDisplayChoiceRows(ctx, support_mask) != 0U) {
        PsAppUi_UpdateSystemPanel(ctx);
    }
    choice_changed =
        (u8)(choice_before_refresh != s_ps_app_ui_runtime.display_choice);

    if ((link == NULL) || (link->state == NULL)) {
        if (back != 0U) {
            s_ps_app_ui_runtime.system_page = 0U;
            PsAppUi_UpdateSystemPanel(ctx);
        }
        return 1U;
    }

    if (s_ps_app_ui_runtime.display_preview != 0U) {
        if (link->state->video_mode_apply_pending != 0U) {
            return 1U;
        }
        if (link->state->dvi_recovery_failed != 0U) {
            s_ps_app_ui_runtime.display_preview = 0U;
            PsAppUi_SetStatus(ctx, "DVI兼容恢复失败，请查看串口状态");
            PsAppUi_UpdateSystemPanel(ctx);
            return 1U;
        }
        if ((link->state->dvi_recovery_latched != 0U) &&
            (link->state->dvi_recovery_preview == 0U)) {
            s_ps_app_ui_runtime.display_preview = 0U;
            PsAppUi_SetStatus(ctx, "已恢复到480p DVI兼容模式，按A手动选择模式");
            PsAppUi_UpdateSystemPanel(ctx);
            return 1U;
        }
        if ((link->state->last_error == PS_APP_HDMI_ERR_VIDEO_MODE_FAILED) &&
            (link->state->video_mode_active ==
             s_ps_app_ui_runtime.display_previous_mode)) {
            s_ps_app_ui_runtime.display_preview = 0U;
            PsAppUi_SetStatus(ctx, "切换失败，已恢复上次确认的模式");
            PsAppUi_UpdateSystemPanel(ctx);
            return 1U;
        }
        if (link->state->video_mode_active != link->state->video_mode_request) {
            return 1U;
        }
        if (s_ps_app_ui_runtime.display_preview_timer_started == 0U) {
            s_ps_app_ui_runtime.display_preview_timer_started = 1U;
            s_ps_app_ui_runtime.display_started = xTaskGetTickCount();
            return 1U;
        }
        if ((back != 0U) ||
            ((xTaskGetTickCount() - s_ps_app_ui_runtime.display_started) >=
             pdMS_TO_TICKS(10000U))) {
            if (link->state->dvi_recovery_preview != 0U) {
                PsAppHdmiLink_CancelModePreview(link);
            } else if (PsAppHdmiLink_RequestMode(link,
                                                 s_ps_app_ui_runtime.display_previous_mode) != XST_SUCCESS) {
                (void)PsAppHdmiLink_RequestMode(link, PS_APP_HDMI_MODE_SAFE);
            }
            s_ps_app_ui_runtime.display_preview = 0U;
            PsAppUi_SetStatus(ctx, "正在恢复原分辨率");
            PsAppUi_UpdateSystemPanel(ctx);
        } else if (accept != 0U) {
            PsAppHdmiLink_ConfirmMode(link);
            s_ps_app_ui_runtime.display_preview = 0U;
            PsAppUi_SetStatus(ctx, "已保留当前分辨率");
            PsAppUi_UpdateSystemPanel(ctx);
        }
        return 1U;
    }

    if (back != 0U) {
        s_ps_app_ui_runtime.system_page = 0U;
        PsAppUi_UpdateSystemPanel(ctx);
    } else if ((left != 0U) || (right != 0U) ||
               (up != 0U) || (down != 0U)) {
        direction = ((left != 0U) || (up != 0U)) ? -1 : 1;
        const int count = (int)PS_APP_UI_DISPLAY_OPTION_COUNT;
        for (attempt = 0U; attempt < (unsigned int)count; ++attempt) {
            s_ps_app_ui_runtime.display_choice =
                (u8)((s_ps_app_ui_runtime.display_choice + direction + count) % count);
            if ((s_ps_app_ui_display_options[s_ps_app_ui_runtime.display_choice].mode ==
                 PS_APP_HDMI_MODE_AUTO) ||
                ((support_mask & (u8)(1U <<
                    s_ps_app_ui_display_options[s_ps_app_ui_runtime.display_choice].mode)) != 0U)) {
                break;
            }
        }
        PsAppUi_UpdateSystemPanel(ctx);
    } else if (accept != 0U) {
        u8 requested_mode;

        if ((choice_changed != 0U) ||
            (s_ps_app_ui_runtime.display_choice >= PS_APP_UI_DISPLAY_OPTION_COUNT)) {
            return 1U;
        }
        requested_mode =
            s_ps_app_ui_display_options[s_ps_app_ui_runtime.display_choice].mode;
        if ((requested_mode < PS_APP_VIDEO_MODE_COUNT) &&
            ((support_mask & (u8)(1U << requested_mode)) == 0U)) {
            PsAppUi_UpdateSystemPanel(ctx);
            return 1U;
        }
        s_ps_app_ui_runtime.display_previous_mode = link->state->video_mode_active;
        if (PsAppHdmiLink_RequestMode(link, requested_mode) == XST_SUCCESS) {
            s_ps_app_ui_runtime.display_preview = 1U;
            s_ps_app_ui_runtime.display_preview_timer_started = 0U;
            PsAppUi_SetStatus(ctx, "A保留当前分辨率 B恢复 10秒自动恢复");
            PsAppUi_UpdateSystemPanel(ctx);
        } else {
            PsAppUi_SetStatus(ctx, "分辨率切换失败");
        }
    }
    return 1U;
}

static void PsAppUi_ProcessMenuInput(PsAppUiContext *ctx) {
    PsAppUiState *state;
    PsAppRuntimeContext *runtime;
    u16 prev_buttons;
    u16 cur_buttons;
    u8 need_rebuild;
    u8 back;
    u8 accept;
    u8 up;
    u8 down;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL)) {
        return;
    }

    state = ctx->state;
    runtime = ctx->runtime;
    prev_buttons = (u16)state->last_buttons;
    cur_buttons = PsAppUi_GetMenuButtonMask(runtime);
    need_rebuild = 0U;
    back = PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_B);
    accept = PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_A);
    up = PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_UP);
    down = PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_DOWN);

    if (s_ps_app_ui_runtime.about_visible != 0U) {
        if (s_ps_app_ui_runtime.system_page == 1U) {
            (void)PsAppUi_ProcessDisplayMode(ctx, prev_buttons, cur_buttons);
        } else if (s_ps_app_ui_runtime.system_page == 0U) {
            if (back != 0U) {
                PsAppUi_SetAboutVisible(ctx, 0U);
            } else if ((up != 0U) || (down != 0U)) {
                s_ps_app_ui_runtime.system_selection =
                    (u8)((s_ps_app_ui_runtime.system_selection + ((up != 0U) ? 2U : 1U)) % 3U);
                PsAppUi_UpdateSystemPanel(ctx);
            } else if (accept != 0U) {
                s_ps_app_ui_runtime.system_page =
                    (u8)(s_ps_app_ui_runtime.system_selection + 1U);
                if ((s_ps_app_ui_runtime.system_page == 1U) &&
                    (runtime->hdmi_ctx != NULL) &&
                    (runtime->hdmi_ctx->state != NULL) &&
                    (runtime->hdmi_ctx->state->video_mode_active <
                     PS_APP_VIDEO_MODE_COUNT)) {
                    s_ps_app_ui_runtime.display_choice =
                        runtime->hdmi_ctx->state->video_mode_active;
                }
                PsAppUi_UpdateSystemPanel(ctx);
            }
        } else if (s_ps_app_ui_runtime.system_page == 2U) {
            if (back != 0U) {
                s_ps_app_ui_runtime.system_page = 0U;
                PsAppUi_UpdateSystemPanel(ctx);
            } else if (accept != 0U) {
                PsAppAudioRouteState route;
                u8 target_path;
                PsAppRuntime_GetAudioRouteSnapshot(runtime, &route);
                target_path = (route.active_path == (u8)PS_APP_AUDIO_PATH_I2S_CODEC) ?
                              (u8)PS_APP_AUDIO_PATH_HDMI : (u8)PS_APP_AUDIO_PATH_I2S_CODEC;
                if (PsAppRuntime_RequestAudioOutputPath(runtime, target_path) != XST_SUCCESS) {
                    PsAppUi_SetStatus(ctx, "音频正在切换，稍后再试");
                }
                PsAppUi_UpdateSystemPanel(ctx);
            }
        } else if (back != 0U) {
            s_ps_app_ui_runtime.system_page = 0U;
            PsAppUi_UpdateSystemPanel(ctx);
        }
        state->last_buttons = cur_buttons;
        return;
    }

    if (PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_Y) != 0U) {
        PsAppUi_SetAboutVisible(ctx, 1U);
        state->last_buttons = cur_buttons;
        return;
    }

    if (back != 0U) {
        PsAppAudioRouteState route;
        u8 target_path;
        XStatus route_status;

        PsAppRuntime_GetAudioRouteSnapshot(runtime, &route);
        target_path = (route.active_path == (u8)PS_APP_AUDIO_PATH_I2S_CODEC) ?
                      (u8)PS_APP_AUDIO_PATH_HDMI : (u8)PS_APP_AUDIO_PATH_I2S_CODEC;
        route_status = PsAppRuntime_RequestAudioOutputPath(runtime, target_path);
        if (route_status != XST_SUCCESS) {
            PsAppUi_SetStatus(ctx, "音频正在切换，稍后再试");
        }
    }

    if ((state->game_count > 0U) && (up != 0U)) {
        if (state->selected_index == 0U) {
            state->selected_index = (u8)(state->game_count - 1U);
        } else {
            state->selected_index--;
        }
        need_rebuild = 1U;
    }

    if ((state->game_count > 0U) && (down != 0U)) {
        state->selected_index = (u8)((state->selected_index + 1U) % state->game_count);
        need_rebuild = 1U;
    }

    if (PsAppUi_ButtonPressedEdge(prev_buttons, cur_buttons, PS_XINPUT_BUTTON_MASK_X) != 0U) {
        state->refresh_requested = 1U;
        PsAppUi_SetStatus(ctx, "正在刷新...");
        xil_printf("[UI] refresh requested by X/START\r\n");
    }

    if ((state->game_count > 0U) && (accept != 0U)) {
        PsAppAudioRouteState route;
        PsAppRuntime_GetAudioRouteSnapshot(runtime, &route);
        if (PsAppAudioRouteLogic_IsTransitionInProgress(&route) != 0U) {
            PsAppUi_SetStatus(ctx, "音频切换中，请完成后再启动");
        } else {
            state->launch_requested = 1U;
            state->launch_index = state->selected_index;
            state->mode = (u8)PS_APP_UI_MODE_LOADING;
            PsAppUi_CopyText(state->launch_path,
                             sizeof(state->launch_path),
                             s_ps_app_ui_runtime.games[state->launch_index].path);
            PsAppUi_SetStatus(ctx, "正在加载ROM...");
            need_rebuild = 1U;
        }
    }

    state->last_buttons = cur_buttons;
    if (need_rebuild != 0U) {
        PsAppUi_UpdateListVisuals(ctx, 1U);
        PsAppUi_UpdateDetailPanel(ctx);
    }
}

static void PsAppUi_LoadWorkerTask(void *arg) {
    PsAppUiLoadWorkerArgs *worker_args;
    XStatus status;

    worker_args = (PsAppUiLoadWorkerArgs *)arg;
    if ((worker_args == NULL) || (worker_args->runtime == NULL)) {
        status = XST_INVALID_PARAM;
    } else {
        status = PsAppRuntime_LoadRomFromSd(worker_args->runtime,
                                            worker_args->path);
    }

    taskENTER_CRITICAL();
    s_ps_app_ui_runtime.load_worker_status = (s32)status;
    s_ps_app_ui_runtime.load_worker_done = 1U;
    s_ps_app_ui_runtime.load_worker_active = 0U;
    taskEXIT_CRITICAL();
    vTaskDelete(NULL);
}

static void PsAppUi_GetLoadWorkerSnapshot(u8 *active_out,
                                          u8 *done_out,
                                          s32 *status_out,
                                          u32 *attempt_id_out) {
    taskENTER_CRITICAL();
    if (active_out != NULL) {
        *active_out = s_ps_app_ui_runtime.load_worker_active;
    }
    if (done_out != NULL) {
        *done_out = s_ps_app_ui_runtime.load_worker_done;
    }
    if (status_out != NULL) {
        *status_out = s_ps_app_ui_runtime.load_worker_status;
    }
    if (attempt_id_out != NULL) {
        *attempt_id_out = s_ps_app_ui_runtime.load_worker_attempt_id;
    }
    taskEXIT_CRITICAL();
}

static void PsAppUi_SetProgressFill(u32 width, u32 color_rgb) {
    if (s_ps_app_ui_runtime.status_progress_fill == NULL) {
        return;
    }
    if (width < 2U) {
        width = 2U;
    }
    if (width > 90U) {
        width = 90U;
    }
    if (s_ps_app_ui_runtime.progress_fill_width != (u16)width) {
        PsAppUi_Width(s_ps_app_ui_runtime.status_progress_fill, (lv_coord_t)width);
        s_ps_app_ui_runtime.progress_fill_width = (u16)width;
    }
    if ((s_ps_app_ui_runtime.progress_fill_color_valid == 0U) ||
        (s_ps_app_ui_runtime.progress_fill_color != color_rgb)) {
        lv_color_t color = PsAppUi_HexColor(color_rgb);
        lv_obj_set_style_bg_color(s_ps_app_ui_runtime.status_progress_fill, color, 0);
        lv_obj_set_style_border_color(s_ps_app_ui_runtime.status_progress_fill, color, 0);
        s_ps_app_ui_runtime.progress_fill_color = color_rgb;
        s_ps_app_ui_runtime.progress_fill_color_valid = 1U;
    }
}

static void PsAppUi_SetProgressPercent(u8 percent) {
    u32 width;

    if (percent > 100U) {
        percent = 100U;
    }
    width = (90U * (u32)percent) / 100U;
    PsAppUi_SetProgressFill(width, PS_APP_UI_COLOR_AMBER);
}

static void PsAppUi_SetProgressIndeterminate(void) {
    u32 width;

    width = 16U + ((s_ps_app_ui_runtime.anim_elapsed_ms % 720U) * 74U / 720U);
    PsAppUi_SetProgressFill(width, PS_APP_UI_COLOR_AMBER);
}

static void PsAppUi_HandleLoadFailure(PsAppUiContext *ctx, s32 status) {
    PsAppUiState *state;
    PsAppRomLoadProgressSnapshot progress;
    char status_text[64];

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL)) {
        return;
    }

    state = ctx->state;
    PsAppUiLaunchLogic_ReturnToMenu(state);
    PsAppRomLoadProgress_GetSnapshot(ctx->runtime->rom, &progress);
    s_ps_app_ui_runtime.last_load_attempt_id = progress.attempt_id;
    state->last_buttons = PsAppUi_GetMenuButtonMask(ctx->runtime);
    PsAppUi_EnsureMenuScreen();
    if (status == XST_FAILURE) {
        PsAppUi_SetStatus(ctx, "加载失败，请检查 ROM 后重试");
    } else {
        (void)snprintf(status_text,
                       sizeof(status_text),
                       "加载失败 (status=%d)",
                       (int)status);
        PsAppUi_SetStatus(ctx, status_text);
    }
    if (s_ps_app_ui_runtime.status_progress != NULL) {
        lv_obj_set_hidden(s_ps_app_ui_runtime.status_progress, true);
    }
    PsAppUi_UpdateMetaLabels(ctx);
    PsAppUi_ForceFullRedraw();
    xil_printf("[UI] ROM load failed status=%d\r\n", (int)status);
}

static void PsAppUi_ProcessLaunch(PsAppUiContext *ctx) {
    PsAppUiState *state;
    PsAppRomLoadProgressSnapshot progress;
    BaseType_t task_status;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL) ||
        (ctx->runtime->rom == NULL)) {
        return;
    }

    state = ctx->state;
    if (state->launch_requested == 0U) {
        return;
    }

    PsAppRomLoadProgress_GetSnapshot(ctx->runtime->rom, &progress);
    s_ps_app_ui_load_worker_args.runtime = ctx->runtime;
    PsAppUi_CopyText(s_ps_app_ui_load_worker_args.path,
                     sizeof(s_ps_app_ui_load_worker_args.path),
                     state->launch_path);
    taskENTER_CRITICAL();
    s_ps_app_ui_runtime.load_worker_active = 1U;
    s_ps_app_ui_runtime.load_worker_done = 0U;
    s_ps_app_ui_runtime.load_worker_status = XST_SUCCESS;
    s_ps_app_ui_runtime.load_worker_attempt_id = progress.attempt_id;
    taskEXIT_CRITICAL();

    PsAppUi_EnsureMenuScreen();
    PsAppUi_UpdateDetailPanel(ctx);
    PsAppUi_ForceFullRedraw();
    task_status = xTaskCreate(PsAppUi_LoadWorkerTask,
                              "romload",
                              PS_APP_ROM_LOAD_WORKER_STACK_WORDS,
                              &s_ps_app_ui_load_worker_args,
                              PS_APP_ROM_LOAD_WORKER_PRIORITY,
                              NULL);
    if (task_status != pdPASS) {
        taskENTER_CRITICAL();
        s_ps_app_ui_runtime.load_worker_active = 0U;
        s_ps_app_ui_runtime.load_worker_done = 0U;
        taskEXIT_CRITICAL();
        (void)PsAppUiLaunchLogic_WorkerStartResult(state, 0U);
        (void)PsAppRomLoadProgress_FailIfUnchanged(ctx->runtime->rom,
                                                   progress.attempt_id,
                                                   XST_FAILURE);
        PsAppUi_HandleLoadFailure(ctx, XST_FAILURE);
        return;
    }

    (void)PsAppUiLaunchLogic_WorkerStartResult(state, 1U);
}

static void PsAppUi_UpdateRomLoadProgress(PsAppUiContext *ctx) {
    PsAppRomLoadProgressSnapshot progress;
    u8 worker_active;
    u8 worker_done;
    s32 worker_status;
    u32 worker_attempt_id;
    u8 percent;
    char status_text[80];

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL) ||
        (ctx->runtime->rom == NULL) ||
        (ctx->state->mode != (u8)PS_APP_UI_MODE_LOADING)) {
        return;
    }

    PsAppRomLoadProgress_GetSnapshot(ctx->runtime->rom, &progress);
    PsAppUi_GetLoadWorkerSnapshot(&worker_active,
                                  &worker_done,
                                  &worker_status,
                                  &worker_attempt_id);

    if ((worker_active != 0U) &&
        (worker_attempt_id == progress.attempt_id) &&
        (progress.result != (u8)PS_APP_ROM_LOAD_RESULT_RUNNING)) {
        /* The old attempt may have failed; while this new worker is waiting
         * for the runtime owner, keep the new UI attempt in its prepare phase. */
        PsAppUi_SetStatus(ctx, "准备中...");
        PsAppUi_SetProgressIndeterminate();
        return;
    }

    if ((worker_done != 0U) &&
        (worker_status != XST_SUCCESS) &&
        (worker_attempt_id == progress.attempt_id) &&
        (progress.result != (u8)PS_APP_ROM_LOAD_RESULT_RUNNING)) {
        (void)PsAppRomLoadProgress_FailIfUnchanged(ctx->runtime->rom,
                                                   worker_attempt_id,
                                                   (int)worker_status);
        PsAppRomLoadProgress_GetSnapshot(ctx->runtime->rom, &progress);
    }

    if (progress.result == (u8)PS_APP_ROM_LOAD_RESULT_FAILED) {
        PsAppUi_HandleLoadFailure(ctx, (s32)progress.error_status);
        return;
    }

    if (progress.result == (u8)PS_APP_ROM_LOAD_RESULT_SUCCESS) {
        PsAppUi_SetProgressPercent(100U);
        if ((ctx->runtime->rom->loaded != 0U) &&
            PsAppVideo_GameFrameScanning(ctx->video)) {
            PsAppUi_SetAboutVisible(ctx, 0U);
            ctx->state->mode = (u8)PS_APP_UI_MODE_GAME;
            ctx->state->lt_hold_ms = 0U;
            ctx->state->lt_exit_latched = 0U;
            ctx->state->board_exit_hold_ms = 0U;
            ctx->state->board_exit_latched = 0U;
            ctx->state->last_buttons = PsAppUi_GetMenuButtonMask(ctx->runtime);
            PsAppUi_SetStatus(ctx, "游戏运行中");
            PsAppUi_UpdateMetaLabels(ctx);
            xil_printf("[UI] first game frame presented; loading UI released\r\n");
            return;
        }
        if (s_ps_app_ui_runtime.first_frame_wait_started == 0U) {
            s_ps_app_ui_runtime.first_frame_wait_start = xTaskGetTickCount();
            s_ps_app_ui_runtime.first_frame_wait_started = 1U;
        } else if (s_ps_app_ui_runtime.first_frame_wait_reported == 0U &&
                   xTaskGetTickCount() - s_ps_app_ui_runtime.first_frame_wait_start >=
                   PsAppTime_MsToTicksCeil(2000U)) {
            s_ps_app_ui_runtime.first_frame_wait_reported = 1U;
            xil_printf("[UI] still waiting for game scanout: blits=%u\r\n",
                       (unsigned int)ctx->runtime->video->blit_count);
        }
        if (PsAppRomLoadProgress_GetPercent(&progress, &percent) != 0U) {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "读取完成 %u%%，等待游戏首帧",
                           (unsigned int)percent);
        } else {
            PsAppUi_CopyText(status_text, sizeof(status_text), "启动中，等待游戏首帧...");
        }
        PsAppUi_SetStatus(ctx, status_text);
        return;
    }

    if (progress.phase == (u8)PS_APP_ROM_LOAD_PHASE_READING) {
        if (PsAppRomLoadProgress_GetPercent(&progress, &percent) != 0U) {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "正在读取 ROM %u%%",
                           (unsigned int)percent);
            PsAppUi_SetStatus(ctx, status_text);
            PsAppUi_SetProgressPercent(percent);
        } else {
            PsAppUi_SetStatus(ctx, "正在读取 ROM...");
            PsAppUi_SetProgressIndeterminate();
        }
    } else if (progress.phase == (u8)PS_APP_ROM_LOAD_PHASE_FINALIZING) {
        if (PsAppRomLoadProgress_GetPercent(&progress, &percent) != 0U) {
            (void)snprintf(status_text,
                           sizeof(status_text),
                           "ROM 读取 %u%%，初始化/启动中",
                           (unsigned int)percent);
            PsAppUi_SetProgressPercent(percent);
        } else {
            PsAppUi_CopyText(status_text, sizeof(status_text), "初始化/启动中...");
            PsAppUi_SetProgressIndeterminate();
        }
        PsAppUi_SetStatus(ctx, status_text);
    } else {
        PsAppUi_SetStatus(ctx, "准备中...");
        PsAppUi_SetProgressIndeterminate();
    }
}

static void PsAppUi_ExitGameToMenu(PsAppUiContext *ctx, const char *trigger_name) {
    PsAppUiState *state;
    PsAppRuntimeContext *runtime;
    XStatus unload_status;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL)) {
        return;
    }

    state = ctx->state;
    runtime = ctx->runtime;
    state->mode = (u8)PS_APP_UI_MODE_LOADING;
    PsAppUi_SetStatus(ctx, "正在返回菜单...");
    PsAppUi_EnsureMenuScreen();
    PsAppUi_RebuildList(ctx);
    lv_tick_inc(1U);
    (void)lv_timer_handler();

    unload_status = PsAppRuntime_UnloadRom(runtime);
    if (unload_status == XST_SUCCESS) {
        /* 必须走安全卸载后再回菜单，避免 save/rtc 状态丢失。 */
        state->mode = (u8)PS_APP_UI_MODE_MENU;
        state->refresh_requested = 1U;
        state->lt_hold_ms = 0U;
        state->lt_exit_latched = 0U;
        state->board_exit_hold_ms = 0U;
        state->board_exit_latched = 0U;
        state->last_buttons = PsAppUi_GetMenuButtonMask(runtime);
        /* Unload parks frame 0; restart LVGL with the two menu buffers. */
        PsAppUi_AbortAudioRouteSafeFlush();
        s_ps_app_ui_runtime.ui_target_frame_idx = PS_APP_UI_TARGET_FRAME_IDX;
        PsAppUi_ConfigureNativeBuffers(ctx);
        PsAppUi_SetStatus(ctx, "已返回菜单");
        PsAppUi_RebuildList(ctx);
        /* 退出 GAME 后强制整屏重绘，消除局部刷新的残影。 */
        PsAppUi_ForceFullRedraw();
        xil_printf("[UI] %s exit: back to menu\r\n",
                   (trigger_name != NULL) ? trigger_name : "game");
    } else {
        state->mode = (u8)PS_APP_UI_MODE_GAME;
        PsAppUi_SetStatus(ctx, "退出失败");
        PsAppUi_UpdateMetaLabels(ctx);
        xil_printf("[UI] %s exit failed: %d\r\n",
                   (trigger_name != NULL) ? trigger_name : "game",
                   unload_status);
    }
}

static void PsAppUi_ProcessGameInput(PsAppUiContext *ctx) {
    PsAppUiState *state;
    PsAppRuntimeContext *runtime;
    u32 ps_btn_mask;
    u8 lt_value;
    u8 board_combo_pressed;
    u32 next_hold_ms;
    u8 lt_triggered;
    u8 board_triggered;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL)) {
        return;
    }

    state = ctx->state;
    runtime = ctx->runtime;
    lt_value = (runtime->input != NULL) ? runtime->input->lt : 0U;
    ps_btn_mask = PsAppRuntime_ReadPsButtonMask(runtime);
    board_combo_pressed = (u8)(((ps_btn_mask & PS_APP_UI_BOARD_EXIT_BTN_MASK) ==
                                PS_APP_UI_BOARD_EXIT_BTN_MASK) ? 1U : 0U);
    lt_triggered = 0U;
    board_triggered = 0U;

    /* LT 需要“按到底并持续 5 秒”才触发退出，短按/抖动不会误退出。 */
    if (lt_value >= PS_APP_UI_LT_EXIT_THRESHOLD) {
        next_hold_ms = state->lt_hold_ms + PS_APP_UI_SERVICE_INTERVAL_MS;
        if (next_hold_ms > PS_APP_UI_LT_EXIT_HOLD_MS) {
            next_hold_ms = PS_APP_UI_LT_EXIT_HOLD_MS;
        }
        state->lt_hold_ms = next_hold_ms;

        if ((state->lt_hold_ms >= PS_APP_UI_LT_EXIT_HOLD_MS) &&
            (state->lt_exit_latched == 0U)) {
            state->lt_exit_latched = 1U;
            lt_triggered = 1U;
        }
    } else {
        /* LT 放开后清零计时与锁存，下一次长按才允许重新触发。 */
        state->lt_hold_ms = 0U;
        state->lt_exit_latched = 0U;
    }

    /* 板载系统键退出：BTN4+BTN5 同时按住 2 秒触发一次退出。
     * 该通道与 LT 长按并行存在，用于无手柄或手柄异常时兜底返回菜单。 */
    if (board_combo_pressed != 0U) {
        next_hold_ms = state->board_exit_hold_ms + PS_APP_UI_SERVICE_INTERVAL_MS;
        if (next_hold_ms > PS_APP_UI_BOARD_EXIT_HOLD_MS) {
            next_hold_ms = PS_APP_UI_BOARD_EXIT_HOLD_MS;
        }
        state->board_exit_hold_ms = next_hold_ms;

        if ((state->board_exit_hold_ms >= PS_APP_UI_BOARD_EXIT_HOLD_MS) &&
            (state->board_exit_latched == 0U)) {
            state->board_exit_latched = 1U;
            board_triggered = 1U;
        }
    } else {
        state->board_exit_hold_ms = 0U;
        state->board_exit_latched = 0U;
    }

    if (lt_triggered != 0U) {
        /* 两个退出条件同周期同时满足时，优先记录 LT 触发。 */
        PsAppUi_ExitGameToMenu(ctx, "LT hold");
    } else if (board_triggered != 0U) {
        PsAppUi_ExitGameToMenu(ctx, "BTN4+BTN5 hold");
    }
}

static void PsAppUi_SyncModeWithRuntime(PsAppUiContext *ctx) {
    PsAppUiState *state;
    PsAppRuntimeContext *runtime;
    u8 rom_loaded;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL) || (ctx->runtime->rom == NULL)) {
        return;
    }

    state = ctx->state;
    runtime = ctx->runtime;
    rom_loaded = runtime->rom->loaded;

    {
        PsAppRomLoadProgressSnapshot progress;
        PsAppRomLoadProgress_GetSnapshot(runtime->rom, &progress);
        if (progress.attempt_id != s_ps_app_ui_runtime.last_load_attempt_id) {
            s_ps_app_ui_runtime.last_load_attempt_id = progress.attempt_id;
            s_ps_app_ui_runtime.first_frame_wait_started = 0U;
            s_ps_app_ui_runtime.first_frame_wait_reported = 0U;
            if (progress.result != (u8)PS_APP_ROM_LOAD_RESULT_IDLE) {
                if (state->mode != (u8)PS_APP_UI_MODE_LOADING) {
                    PsAppUi_SetAboutVisible(ctx, 0U);
                    state->mode = (u8)PS_APP_UI_MODE_LOADING;
                    state->launch_requested = 0U;
                    state->lt_hold_ms = 0U;
                    state->lt_exit_latched = 0U;
                    state->board_exit_hold_ms = 0U;
                    state->board_exit_latched = 0U;
                }
                PsAppUi_EnsureMenuScreen();
                /* GAME mode stops LVGL timers while the menu screen object
                 * remains active; redraw the complete opaque menu before the
                 * game frame is gated, including when UART starts the load. */
                PsAppUi_ForceFullRedraw();
                return;
            }
        }
        if (progress.result == (u8)PS_APP_ROM_LOAD_RESULT_RUNNING) {
            if (state->mode != (u8)PS_APP_UI_MODE_LOADING) {
                PsAppUi_SetAboutVisible(ctx, 0U);
                state->mode = (u8)PS_APP_UI_MODE_LOADING;
                state->launch_requested = 0U;
                state->lt_hold_ms = 0U;
                state->lt_exit_latched = 0U;
                state->board_exit_hold_ms = 0U;
                state->board_exit_latched = 0U;
            }
            PsAppUi_EnsureMenuScreen();
            return;
        }
    }

    if (state->mode == (u8)PS_APP_UI_MODE_LOADING) {
        return;
    }

    if (rom_loaded != 0U) {
        if (state->mode != (u8)PS_APP_UI_MODE_GAME &&
            PsAppVideo_GameFrameScanning(ctx->video)) {
            /* 外部路径（如串口命令）加载 ROM 时，同步 UI 模式到 GAME。 */
            PsAppUi_SetAboutVisible(ctx, 0U);
            state->mode = (u8)PS_APP_UI_MODE_GAME;
            state->lt_hold_ms = 0U;
            state->lt_exit_latched = 0U;
            state->board_exit_hold_ms = 0U;
            state->board_exit_latched = 0U;
            state->last_buttons = PsAppUi_GetMenuButtonMask(runtime);
            PsAppUi_SetStatus(ctx, "游戏运行中");
            PsAppUi_UpdateMetaLabels(ctx);
        }
    } else if (state->mode == (u8)PS_APP_UI_MODE_GAME) {
        /* ROM 已卸载但 UI 仍在 GAME，兜底拉回 MENU。 */
        state->mode = (u8)PS_APP_UI_MODE_MENU;
        state->refresh_requested = 1U;
        state->launch_requested = 0U;
        state->lt_hold_ms = 0U;
        state->lt_exit_latched = 0U;
        state->board_exit_hold_ms = 0U;
        state->board_exit_latched = 0U;
        state->last_buttons = PsAppUi_GetMenuButtonMask(runtime);
        PsAppUi_ConfigureNativeBuffers(ctx);
        PsAppUi_SetStatus(ctx, "菜单就绪");
        PsAppUi_RebuildList(ctx);
        /* 同步回菜单时同样需要整屏重绘。 */
        PsAppUi_ForceFullRedraw();
    }
}

static void PsAppUi_UpdateAnimation(PsAppUiContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    s_ps_app_ui_runtime.anim_elapsed_ms += s_ps_app_ui_runtime.frame_elapsed_ms;
    s_ps_app_ui_runtime.blink_elapsed_ms += s_ps_app_ui_runtime.frame_elapsed_ms;

    if (s_ps_app_ui_runtime.blink_elapsed_ms >= PS_APP_UI_BLINK_INTERVAL_MS) {
        s_ps_app_ui_runtime.blink_elapsed_ms = 0U;
        s_ps_app_ui_runtime.blink_phase ^= 1U;
    }

    if (s_ps_app_ui_runtime.led != NULL) {
        if (s_ps_app_ui_runtime.blink_phase == 0U) {
            lv_obj_set_style_bg_color(s_ps_app_ui_runtime.led, PsAppUi_HexColor(PS_APP_UI_COLOR_GREEN), 0);
        } else {
            lv_obj_set_style_bg_color(s_ps_app_ui_runtime.led, PsAppUi_HexColor(PS_APP_UI_COLOR_GREEN_DARK), 0);
        }
    }

    if (s_ps_app_ui_runtime.status_progress != NULL) {
        if ((ctx->state->mode == (u8)PS_APP_UI_MODE_LOADING) ||
            (ctx->state->refresh_requested != 0U)) {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_progress, false);
        } else {
            lv_obj_set_hidden(s_ps_app_ui_runtime.status_progress, true);
        }
    }

    if (s_ps_app_ui_runtime.status_progress_fill != NULL) {
        if (ctx->state->mode == (u8)PS_APP_UI_MODE_LOADING) {
            PsAppUi_SetProgressFill(s_ps_app_ui_runtime.progress_fill_width,
                                    PS_APP_UI_COLOR_AMBER);
        } else if (ctx->state->refresh_requested != 0U) {
            u32 fill_w = 24U + ((s_ps_app_ui_runtime.anim_elapsed_ms % 720U) * 66U / 720U);
            PsAppUi_SetProgressFill(fill_w, PS_APP_UI_COLOR_GREEN);
        } else {
            u32 fill_w = (ctx->state->game_count == 0U) ? 24U : 90U;
            u32 fill_color = (ctx->state->game_count == 0U) ?
                             PS_APP_UI_COLOR_AMBER :
                             PS_APP_UI_COLOR_GREEN_DARK;
            PsAppUi_SetProgressFill(fill_w, fill_color);
        }
    }

    PsAppUi_UpdateListVisuals(ctx, 0U);
    if (ctx->state->selected_index < s_ps_app_ui_runtime.game_button_count) {
        lv_obj_t *selected = s_ps_app_ui_runtime.game_buttons[ctx->state->selected_index];
        u32 phase = s_ps_app_ui_runtime.anim_elapsed_ms % 1200U;
        u32 triangle = phase <= 600U ? phase : 1200U - phase;
        lv_obj_set_style_border_color(selected,
            lv_color_mix(PsAppUi_HexColor(PS_APP_UI_COLOR_GREEN_SOFT),
                         PsAppUi_HexColor(PS_APP_UI_COLOR_GREEN_DARK),
                         (uint8_t)(triangle * 255U / 600U)), 0);
    }
}


static void PsAppUi_AbortAudioRouteSafeFlush(void) {
    if (s_ps_app_ui_runtime.audio_route_safe_update.active != 0U) {
        PsAppVideo_AbortUiFrameUpdate(&s_ps_app_ui_runtime.audio_route_safe_update);
    }
    s_ps_app_ui_runtime.audio_route_safe_flush_pending = 0U;
    s_ps_app_ui_runtime.audio_route_safe_flush_dirty = 0U;
}

static void PsAppUi_WaitFlush(lv_display_t *disp) {
    PsAppUiContext *ctx = (PsAppUiContext *)lv_display_get_user_data(disp);
    while (s_ps_app_ui_runtime.present_pending) {
        if (PsAppVideo_WaitUiFrame(ctx->video, s_ps_app_ui_runtime.present_target, 100U) == XST_SUCCESS) {
            s_ps_app_ui_runtime.presented_frames++;
            s_ps_app_ui_runtime.present_pending = 0U;
        } else {
            /* LVGL may reuse the old front buffer only after the park changes. */
            s_ps_app_ui_runtime.missed_deadlines++;
            (void)PsAppVideo_RequestFrame(ctx->video, s_ps_app_ui_runtime.present_target);
        }
    }
}

static void PsAppUi_RefreshNative(void) {
    PsAppUiContext *ctx = s_ps_app_ui_runtime.ctx;
    PsHdmiVdma *vdma = ctx->video->vdma;
    PsAppRomLoadProgressSnapshot progress;
    lv_display_t *display = s_ps_app_ui_runtime.display;
    u32 begin_us;
    u32 draw_us;
    if ((ctx != NULL) && (ctx->runtime != NULL) && (ctx->runtime->rom != NULL) &&
        (ctx->runtime->rom->loaded == 0U)) {
        (void)PsAppVideo_SetSourceMode(ctx->video, PS_APP_VIDEO_SOURCE_UI);
    }
    if (PsAppVideo_BeginUiRender() != XST_SUCCESS) return;
    PsAppRomLoadProgress_GetSnapshot(ctx->runtime->rom, &progress);
    /* Leave the loading frame parked while the game prepares its first frame. */
    if (ctx->runtime->rom->loaded != 0U &&
        progress.result == (u8)PS_APP_ROM_LOAD_RESULT_SUCCESS) {
        PsAppVideo_EndUiRender();
        return;
    }
    if (PsAppVideo_GameFrameSubmittedLocked(ctx->video) ||
        (u32)lv_display_get_horizontal_resolution(display) != vdma->width ||
        (u32)lv_display_get_vertical_resolution(display) != vdma->height) {
        PsAppVideo_EndUiRender();
        return;
    }
    begin_us = (u32)PsAppTime_GetMetUs();
    lv_refr_now(display);
    draw_us = (u32)PsAppTime_GetMetUs() - begin_us;
    s_ps_app_ui_runtime.last_frame_us = draw_us;
    if (draw_us > s_ps_app_ui_runtime.max_draw_us)
        s_ps_app_ui_runtime.max_draw_us = draw_us;
    if (draw_us > ((s_ps_app_ui_runtime.ui_video_mode == PS_APP_VIDEO_MODE_1080P30) ? 33333U : 16667U))
        s_ps_app_ui_runtime.missed_deadlines++;
    PsAppUi_WaitFlush(display);
    PsAppVideo_EndUiRender();
}

static void PsAppUi_LvglFlushCb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
    PsAppUiContext *ctx = (PsAppUiContext *)lv_display_get_user_data(disp);
    PsHdmiVdma *vdma = ctx->video->vdma;
    UINTPTR base = (UINTPTR)px_map;
    u32 target;
    int32_t y;
    s_ps_app_ui_runtime.flush_calls++;
    for (y = area->y1; y <= area->y2; ++y) {
        Xil_DCacheFlushRange((INTPTR)(base + (UINTPTR)y * vdma->line_stride_bytes + (UINTPTR)area->x1 * 4U),
                            (INTPTR)((area->x2 - area->x1 + 1) * 4));
    }
    if (lv_display_flush_is_last(disp)) {
        for (target = 0; target < vdma->frame_count; ++target)
            if (base == vdma->frame_addrs[target]) break;
        if (target < vdma->frame_count && PsAppVideo_RequestFrame(ctx->video, target) == XST_SUCCESS) {
            s_ps_app_ui_runtime.present_target = target;
            s_ps_app_ui_runtime.present_pending = 1U;
            s_ps_app_ui_runtime.submitted_frames++;
            s_ps_app_ui_runtime.ui_target_frame_idx = (u8)target;
        } else {
            s_ps_app_ui_runtime.missed_deadlines++;
            lv_display_flush_ready(disp);
        }
        /* flush_wait_cb holds buffer reuse until the hardware switches stores. */
    } else lv_display_flush_ready(disp);
    s_ps_app_ui_runtime.flush_completed++;
}

static void PsAppUi_SyncNativeRegion(lv_display_t *disp, const lv_area_t *area) {
    PsAppUiContext *ctx = (PsAppUiContext *)lv_display_get_user_data(disp);
    PsHdmiVdma *vdma = ctx->video->vdma;
    lv_draw_buf_t *buffer = lv_display_get_buf_active(disp);
    UINTPTR dst = (UINTPTR)buffer->data;
    UINTPTR src = vdma->frame_addrs[s_ps_app_ui_runtime.ui_target_frame_idx];
    int32_t y;
    for (y = area->y1; y <= area->y2; ++y) {
        UINTPTR offset = (UINTPTR)y * vdma->line_stride_bytes + (UINTPTR)area->x1 * 4U;
        u32 bytes = (u32)(area->x2 - area->x1 + 1) * 4U;
        memcpy((void *)(dst + offset), (void *)(src + offset), bytes);
        Xil_DCacheFlushRange((INTPTR)(dst + offset), bytes);
    }
    lv_display_sync_ready(disp);
}

static void PsAppUi_ConfigureNativeBuffers(PsAppUiContext *ctx) {
    PsHdmiVdma *vdma;
    u32 current;
    u32 first;
    u32 second;
    if ((ctx == NULL) || (ctx->video == NULL) ||
        (PsAppVideo_SetSourceMode(ctx->video, PS_APP_VIDEO_SOURCE_UI) != XST_SUCCESS)) {
        xil_printf("[UI] unable to restore native menu video source\r\n");
        return;
    }
    vdma = ctx->video->vdma;
    current = XAxiVdma_CurrFrameStore(&vdma->vdma, XAXIVDMA_READ);
    first = (current == 1U) ? 2U : 1U;
    second = (first == 1U) ? 2U : 1U;
    s_ps_app_ui_runtime.present_pending = 0U;
    s_ps_app_ui_runtime.ui_target_frame_idx = (u8)((current < vdma->frame_count) ? current : 0U);
    lv_display_set_buffers_with_stride(s_ps_app_ui_runtime.display,
        (void *)vdma->frame_addrs[first], (void *)vdma->frame_addrs[second],
        vdma->frame_size_bytes, vdma->line_stride_bytes, LV_DISPLAY_RENDER_MODE_DIRECT);
}

static void PsAppUi_BuildScreen(PsAppUiContext *ctx) {
    lv_obj_t *scanline;
    lv_obj_t *list_title;
    lv_obj_t *led_text;
    lv_obj_t *brand_plate;
    lv_obj_t *sd_capsule;
    lv_obj_t *sd_label;
    lv_obj_t *subtitle_label;
    lv_obj_t *about_content;
    u32 row;
    unsigned int display_index;
    lv_coord_t display_width;
    lv_coord_t display_height;
    lv_coord_t canvas_width;
    lv_coord_t shell_width;
    lv_coord_t content_width;
    lv_coord_t header_width;
    lv_coord_t list_width;
    lv_coord_t detail_x;
    lv_coord_t detail_width;
    lv_coord_t status_width;

    u8 video_mode;
    u8 wide;

    s_ps_app_ui_runtime.display_rows_valid = 0U;
    for (display_index = 0U;
         display_index < (unsigned int)PS_APP_UI_DISPLAY_OPTION_COUNT;
         ++display_index) {
        s_ps_app_ui_runtime.display_choice_labels[display_index] = NULL;
    }

    display_width = (lv_coord_t)lv_display_get_horizontal_resolution(s_ps_app_ui_runtime.display);
    display_height = (lv_coord_t)lv_display_get_vertical_resolution(s_ps_app_ui_runtime.display);
    video_mode = PS_APP_VIDEO_MODE_VGA480;
    if ((ctx->runtime->hdmi_ctx != NULL) && (ctx->runtime->hdmi_ctx->state != NULL)) {
        video_mode = ctx->runtime->hdmi_ctx->state->video_mode_active;
    }
    wide = (video_mode != PS_APP_VIDEO_MODE_VGA480) ? 1U : 0U;
    s_ps_app_ui_runtime.layout_height = (u32)display_height;
    canvas_width = (lv_coord_t)(((u32)display_width * 480U) / (u32)display_height);
    shell_width = canvas_width - 24;
    content_width = shell_width - 56;
    header_width = content_width;
    list_width = (wide != 0U) ? 480 : 360;
    detail_x = 28 + list_width + 12;
    detail_width = content_width - list_width - 12;
    status_width = content_width;
    s_ps_app_ui_runtime.ui_video_mode = video_mode;
    s_ps_app_ui_runtime.visual_valid = 0U;
    s_ps_app_ui_runtime.ui_canvas_width = canvas_width;
    s_ps_app_ui_runtime.detail_title_width = detail_width - 28;
    s_ps_app_ui_runtime.detail_path_width = detail_width - 76;
    s_ps_app_ui_runtime.detail_value_width = detail_width - 76;

    s_ps_app_ui_runtime.root_screen = lv_obj_create(NULL);
    lv_obj_remove_style_all(s_ps_app_ui_runtime.root_screen);
    lv_obj_set_size(s_ps_app_ui_runtime.root_screen, display_width, display_height);
    lv_obj_set_style_bg_opa(s_ps_app_ui_runtime.root_screen, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_ps_app_ui_runtime.root_screen, PsAppUi_HexColor(PS_APP_UI_COLOR_BG), 0);
    lv_obj_set_style_radius(s_ps_app_ui_runtime.root_screen, 0, 0);
    lv_obj_set_scrollable(s_ps_app_ui_runtime.root_screen, false);
    s_ps_app_ui_runtime.screen = lv_obj_create(s_ps_app_ui_runtime.root_screen);
    lv_obj_remove_style_all(s_ps_app_ui_runtime.screen);
    lv_obj_set_size(s_ps_app_ui_runtime.screen, display_width, display_height);
    lv_obj_set_pos(s_ps_app_ui_runtime.screen, 0, 0);
    lv_obj_set_style_bg_opa(s_ps_app_ui_runtime.screen, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_ps_app_ui_runtime.screen, PsAppUi_HexColor(PS_APP_UI_COLOR_BG), 0);
    lv_obj_set_style_radius(s_ps_app_ui_runtime.screen, 0, 0);
    lv_obj_set_scrollable(s_ps_app_ui_runtime.screen, false);

    for (row = 0U; row < PS_APP_UI_CANVAS_HEIGHT; row += 24U) {
        scanline = lv_obj_create(s_ps_app_ui_runtime.screen);
        lv_obj_remove_style_all(scanline);
        PsAppUi_Size(scanline, canvas_width, 1);
        PsAppUi_Pos(scanline, 0, (lv_coord_t)row);
        lv_obj_set_style_bg_opa(scanline, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(scanline, PsAppUi_HexColor(PS_APP_UI_COLOR_BG_STRIPE), 0);
        lv_obj_set_style_radius(scanline, 0, 0);
        lv_obj_set_scrollable(scanline, false);
    }

    s_ps_app_ui_runtime.shell_panel = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.screen,
                                                                12,
                                                                10,
                                                                shell_width,
                                                                460,
                                                                PS_APP_UI_COLOR_SHELL,
                                                                PS_APP_UI_COLOR_SHELL_DARK,
                                                                PS_APP_UI_COLOR_PANEL_SHADOW);
    (void)PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.shell_panel,
                                   14,
                                   14,
                                   shell_width - 28,
                                   432,
                                   PS_APP_UI_COLOR_PANEL_DIM,
                                   0x9B967FU);
    (void)PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.shell_panel,
                                   18,
                                   18,
                                   shell_width - 36,
                                   6,
                                   0xFFF8DFU,
                                   PS_APP_UI_COLOR_PANEL_DIM);

    s_ps_app_ui_runtime.header_panel = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.shell_panel,
                                                                 28,
                                                                 26,
                                                                 header_width,
                                                                 44,
                                                                 PS_APP_UI_COLOR_PANEL,
                                                                 PS_APP_UI_COLOR_SHELL_DARK,
                                                                 0x9B967FU);

    brand_plate = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.header_panel,
                                           10,
                                           6,
                                           174,
                                           32,
                                           PS_APP_UI_COLOR_GREEN,
                                           PS_APP_UI_COLOR_SHELL_DARK);
    PsAppUi_CreateMonoBitmap(brand_plate,
                             12,
                             6,
                             &ps_app_ui_wordmark_pixel_gba,
                             3,
                             PS_APP_UI_COLOR_INK);

    s_ps_app_ui_runtime.title_label = lv_label_create(s_ps_app_ui_runtime.header_panel);
    lv_label_set_text(s_ps_app_ui_runtime.title_label, "GAME LIBRARY");
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.title_label, PS_APP_UI_COLOR_INK);
    PsAppUi_Pos(s_ps_app_ui_runtime.title_label, 202, 7);

    subtitle_label = lv_label_create(s_ps_app_ui_runtime.header_panel);
    lv_label_set_text(subtitle_label, "FPGA CART SYSTEM");
    PsAppUi_SetTextStyle(subtitle_label, PS_APP_UI_COLOR_INK_MUTED);
    PsAppUi_Pos(subtitle_label, 202, 24);

    s_ps_app_ui_runtime.meta_label = lv_label_create(s_ps_app_ui_runtime.header_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.meta_label, 96);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.meta_label, PS_APP_UI_COLOR_INK_MUTED);
    lv_obj_set_style_text_align(s_ps_app_ui_runtime.meta_label, LV_TEXT_ALIGN_RIGHT, 0);
    PsAppUi_Pos(s_ps_app_ui_runtime.meta_label, header_width - 176, 7);

    s_ps_app_ui_runtime.clock_label = lv_label_create(s_ps_app_ui_runtime.header_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.clock_label, 168);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.clock_label, PS_APP_UI_COLOR_INK);
    lv_obj_set_style_text_align(s_ps_app_ui_runtime.clock_label, LV_TEXT_ALIGN_RIGHT, 0);
    PsAppUi_Pos(s_ps_app_ui_runtime.clock_label, header_width - 192, 24);
    lv_label_set_text(s_ps_app_ui_runtime.clock_label, "BJ ----/--/-- --:--:--");
    s_ps_app_ui_runtime.last_clock_unix = PS_APP_UI_CLOCK_INVALID_UNIX;
    PsAppUi_CreateBitmapIcon(s_ps_app_ui_runtime.header_panel,
                             header_width - 210,
                             24,
                             &ps_app_ui_icon_clock,
                             1,
                             PS_APP_UI_COLOR_INK_MUTED);

    s_ps_app_ui_runtime.led = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.header_panel,
                                                        header_width - 28,
                                                        7,
                                                        12,
                                                        12,
                                                        PS_APP_UI_COLOR_GREEN,
                                                        PS_APP_UI_COLOR_GREEN_DARK);
    led_text = lv_label_create(s_ps_app_ui_runtime.header_panel);
    lv_label_set_text(led_text, "--");
    PsAppUi_SetTextStyle(led_text, PS_APP_UI_COLOR_INK_MUTED);
    PsAppUi_Pos(led_text, header_width - 64, 7);
    s_ps_app_ui_runtime.audio_route_label = led_text;

    s_ps_app_ui_runtime.list_panel = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.shell_panel,
                                                               28,
                                                               84,
                                                               list_width,
                                                               270,
                                                               PS_APP_UI_COLOR_DISPLAY,
                                                               0x080D0AU,
                                                               PS_APP_UI_COLOR_PANEL_SHADOW);
    list_title = lv_label_create(s_ps_app_ui_runtime.list_panel);
    lv_label_set_text(list_title, "PIXEL GBA LIBRARY");
    PsAppUi_SetTextStyle(list_title, PS_APP_UI_COLOR_GREEN_SOFT);
    PsAppUi_Pos(list_title, 34, 8);
    PsAppUi_CreateBitmapIcon(s_ps_app_ui_runtime.list_panel,
                             14,
                             7,
                             &ps_app_ui_icon_cart,
                             1,
                             PS_APP_UI_COLOR_GREEN_SOFT);
    sd_capsule = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.list_panel,
                                          list_width - 122,
                                          8,
                                          96,
                                          18,
                                          PS_APP_UI_COLOR_DISPLAY_ALT,
                                          PS_APP_UI_COLOR_GRID);
    PsAppUi_CreateBitmapIcon(sd_capsule,
                             8,
                             1,
                             &ps_app_ui_icon_sd,
                             1,
                             PS_APP_UI_COLOR_TEXT_MUTED);
    sd_label = lv_label_create(sd_capsule);
    lv_label_set_text(sd_label, "0:/games");
    PsAppUi_SetTextStyle(sd_label, PS_APP_UI_COLOR_TEXT_MUTED);
    PsAppUi_Align(sd_label, LV_ALIGN_LEFT_MID, 30, 0);

    s_ps_app_ui_runtime.list = lv_obj_create(s_ps_app_ui_runtime.list_panel);
    lv_obj_remove_style_all(s_ps_app_ui_runtime.list);
    PsAppUi_Size(s_ps_app_ui_runtime.list, list_width - 24, 210);
    PsAppUi_Pos(s_ps_app_ui_runtime.list, 12, 34);
    lv_obj_set_flex_flow(s_ps_app_ui_runtime.list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_scrollable(s_ps_app_ui_runtime.list, true);
    lv_obj_set_flex_align(s_ps_app_ui_runtime.list,
                          LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START);
    lv_obj_set_style_bg_opa(s_ps_app_ui_runtime.list, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_ps_app_ui_runtime.list, PsAppUi_HexColor(0x0D1712), 0);
    lv_obj_set_style_border_width(s_ps_app_ui_runtime.list, PsAppUi_Px(2), 0);
    lv_obj_set_style_border_color(s_ps_app_ui_runtime.list, PsAppUi_HexColor(PS_APP_UI_COLOR_GRID), 0);
    lv_obj_set_style_radius(s_ps_app_ui_runtime.list, 0, 0);
    lv_obj_set_style_pad_all(s_ps_app_ui_runtime.list, PsAppUi_Px(6), 0);
    lv_obj_set_style_pad_row(s_ps_app_ui_runtime.list, PsAppUi_Px(5), 0);
    lv_obj_set_scrollbar_mode(s_ps_app_ui_runtime.list, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_style_bg_color(s_ps_app_ui_runtime.list, PsAppUi_HexColor(PS_APP_UI_COLOR_GREEN_DARK), LV_PART_SCROLLBAR);
    lv_obj_set_style_bg_opa(s_ps_app_ui_runtime.list, LV_OPA_COVER, LV_PART_SCROLLBAR);
    lv_obj_set_style_width(s_ps_app_ui_runtime.list, PsAppUi_Px(6), LV_PART_SCROLLBAR);
    lv_obj_set_style_radius(s_ps_app_ui_runtime.list, 0, LV_PART_SCROLLBAR);

    s_ps_app_ui_runtime.detail_panel = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.shell_panel,
                                                                 detail_x,
                                                                 84,
                                                                 detail_width,
                                                                 270,
                                                                 PS_APP_UI_COLOR_PANEL,
                                                                 PS_APP_UI_COLOR_SHELL_DARK,
                                                                 0x9B967FU);
    PsAppUi_CreateBitmapIcon(s_ps_app_ui_runtime.detail_panel,
                             14,
                             14,
                             &ps_app_ui_icon_cart,
                             2,
                             PS_APP_UI_COLOR_GREEN_DARK);
    (void)PsAppUi_CreateText(s_ps_app_ui_runtime.detail_panel,
                             "CARTRIDGE DETAIL",
                             PS_APP_UI_COLOR_INK_MUTED,
                             54,
                             14);
    s_ps_app_ui_runtime.detail_slot_label = lv_label_create(s_ps_app_ui_runtime.detail_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.detail_slot_label,
                     (detail_width > 184) ? 118 : (detail_width - 66));
    lv_label_set_long_mode(s_ps_app_ui_runtime.detail_slot_label, LV_LABEL_LONG_MODE_DOTS);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.detail_slot_label, PS_APP_UI_COLOR_INK);
    PsAppUi_Pos(s_ps_app_ui_runtime.detail_slot_label, 54, 30);

    s_ps_app_ui_runtime.detail_title_label = lv_label_create(s_ps_app_ui_runtime.detail_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.detail_title_label, s_ps_app_ui_runtime.detail_title_width);
    lv_label_set_long_mode(s_ps_app_ui_runtime.detail_title_label, LV_LABEL_LONG_MODE_DOTS);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.detail_title_label, PS_APP_UI_COLOR_INK);
    PsAppUi_Pos(s_ps_app_ui_runtime.detail_title_label, PS_APP_UI_DETAIL_FIELD_X, 64);
    (void)PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.detail_panel,
                                   PS_APP_UI_DETAIL_FIELD_X,
                                   88,
                                   s_ps_app_ui_runtime.detail_title_width,
                                   2,
                                   PS_APP_UI_COLOR_GREEN_DARK,
                                   PS_APP_UI_COLOR_GREEN_DARK);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "PATH",
                                         PS_APP_UI_DETAIL_ROW_PATH_Y);
    s_ps_app_ui_runtime.detail_path_label = lv_label_create(s_ps_app_ui_runtime.detail_panel);
    lv_label_set_long_mode(s_ps_app_ui_runtime.detail_path_label, LV_LABEL_LONG_MODE_CLIP);
    PsAppUi_Size(s_ps_app_ui_runtime.detail_path_label, s_ps_app_ui_runtime.detail_path_width, 18);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.detail_path_label, PS_APP_UI_COLOR_INK_MUTED);
    PsAppUi_Pos(s_ps_app_ui_runtime.detail_path_label, PS_APP_UI_DETAIL_VALUE_X, PS_APP_UI_DETAIL_ROW_PATH_Y);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "SIZE",
                                         PS_APP_UI_DETAIL_ROW_SIZE_Y);
    s_ps_app_ui_runtime.detail_size_value_label =
        PsAppUi_CreateDetailValueLabel(s_ps_app_ui_runtime.detail_panel,
                                       PS_APP_UI_DETAIL_ROW_SIZE_Y,
                                       PS_APP_UI_COLOR_INK);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "CODE",
                                         PS_APP_UI_DETAIL_ROW_CODE_Y);
    s_ps_app_ui_runtime.detail_code_value_label =
        PsAppUi_CreateDetailValueLabel(s_ps_app_ui_runtime.detail_panel,
                                       PS_APP_UI_DETAIL_ROW_CODE_Y,
                                       PS_APP_UI_COLOR_INK);

    (void)PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.detail_panel,
                                   PS_APP_UI_DETAIL_FIELD_X,
                                   168,
                                   160,
                                   2,
                                   PS_APP_UI_COLOR_PANEL_DIM,
                                   PS_APP_UI_COLOR_PANEL_DIM);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "CRC",
                                         PS_APP_UI_DETAIL_ROW_CRC_Y);
    s_ps_app_ui_runtime.detail_crc_value_label =
        PsAppUi_CreateDetailValueLabel(s_ps_app_ui_runtime.detail_panel,
                                       PS_APP_UI_DETAIL_ROW_CRC_Y,
                                       PS_APP_UI_COLOR_INK);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "BIOS",
                                         PS_APP_UI_DETAIL_ROW_BIOS_Y);
    s_ps_app_ui_runtime.detail_bios_value_label =
        PsAppUi_CreateDetailValueLabel(s_ps_app_ui_runtime.detail_panel,
                                       PS_APP_UI_DETAIL_ROW_BIOS_Y,
                                       PS_APP_UI_COLOR_INK_MUTED);

    (void)PsAppUi_CreateDetailFieldLabel(s_ps_app_ui_runtime.detail_panel,
                                         "SAVE",
                                         PS_APP_UI_DETAIL_ROW_SAVE_Y);
    s_ps_app_ui_runtime.detail_save_value_label =
        PsAppUi_CreateDetailValueLabel(s_ps_app_ui_runtime.detail_panel,
                                       PS_APP_UI_DETAIL_ROW_SAVE_Y,
                                       PS_APP_UI_COLOR_INK_MUTED);

    PsAppUi_CreateBitmapIcon(s_ps_app_ui_runtime.detail_panel,
                             PS_APP_UI_DETAIL_FIELD_X,
                             242,
                             &ps_app_ui_icon_play,
                             1,
                             PS_APP_UI_COLOR_GREEN_DARK);
    s_ps_app_ui_runtime.detail_hint_label = lv_label_create(s_ps_app_ui_runtime.detail_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.detail_hint_label, s_ps_app_ui_runtime.detail_value_width);
    lv_label_set_long_mode(s_ps_app_ui_runtime.detail_hint_label, LV_LABEL_LONG_MODE_DOTS);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.detail_hint_label, PS_APP_UI_COLOR_INK);
    PsAppUi_Pos(s_ps_app_ui_runtime.detail_hint_label, PS_APP_UI_DETAIL_VALUE_X, 244);

    s_ps_app_ui_runtime.status_panel = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.shell_panel,
                                                                 28,
                                                                 364,
                                                                 status_width,
                                                                 42,
                                                                 PS_APP_UI_COLOR_PANEL,
                                                                 PS_APP_UI_COLOR_SHELL_DARK,
                                                                 0x9B967FU);

    s_ps_app_ui_runtime.status_label = lv_label_create(s_ps_app_ui_runtime.status_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.status_label, status_width - 168);
    lv_label_set_long_mode(s_ps_app_ui_runtime.status_label, LV_LABEL_LONG_MODE_DOTS);
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.status_label, PS_APP_UI_COLOR_INK);
    PsAppUi_Pos(s_ps_app_ui_runtime.status_label, 34, 13);
    s_ps_app_ui_runtime.status_icon_info = PsAppUi_CreateIconLayer(s_ps_app_ui_runtime.status_panel,
                                                                   12,
                                                                   7,
                                                                   &ps_app_ui_icon_info,
                                                                   PS_APP_UI_COLOR_INK_MUTED);
    s_ps_app_ui_runtime.status_icon_warn = PsAppUi_CreateIconLayer(s_ps_app_ui_runtime.status_panel,
                                                                   12,
                                                                   7,
                                                                   &ps_app_ui_icon_warn,
                                                                   PS_APP_UI_COLOR_AMBER);
    s_ps_app_ui_runtime.status_icon_play = PsAppUi_CreateIconLayer(s_ps_app_ui_runtime.status_panel,
                                                                   12,
                                                                   7,
                                                                   &ps_app_ui_icon_play,
                                                                   PS_APP_UI_COLOR_GREEN_DARK);
    PsAppUi_ShowStatusIcon(PS_APP_UI_STATUS_ROLE_INFO);

    s_ps_app_ui_runtime.hint_label = lv_label_create(s_ps_app_ui_runtime.status_panel);
    PsAppUi_Width(s_ps_app_ui_runtime.hint_label, 1);
    lv_label_set_text(s_ps_app_ui_runtime.hint_label, "");
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.hint_label, PS_APP_UI_COLOR_INK_MUTED);
    PsAppUi_Pos(s_ps_app_ui_runtime.hint_label, 34, 24);
    lv_obj_set_hidden(s_ps_app_ui_runtime.hint_label, true);

    s_ps_app_ui_runtime.status_progress = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.status_panel,
                                                                    status_width - 120,
                                                                    14,
                                                                    96,
                                                                    12,
                                                                    PS_APP_UI_COLOR_PANEL_DIM,
                                                                    PS_APP_UI_COLOR_SHELL_DARK);
    lv_obj_set_style_border_width(s_ps_app_ui_runtime.status_progress, PsAppUi_Px(1), 0);
    lv_obj_set_style_pad_all(s_ps_app_ui_runtime.status_progress, PsAppUi_Px(2), 0);
    s_ps_app_ui_runtime.status_progress_fill = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.status_progress,
                                                                         0,
                                                                         0,
                                                                         2,
                                                                         6,
                                                                         PS_APP_UI_COLOR_GREEN_DARK,
                                                                         PS_APP_UI_COLOR_GREEN_DARK);
    lv_obj_set_hidden(s_ps_app_ui_runtime.status_progress, true);
    s_ps_app_ui_runtime.progress_fill_width = 2U;
    s_ps_app_ui_runtime.progress_fill_color = PS_APP_UI_COLOR_GREEN_DARK;
    s_ps_app_ui_runtime.progress_fill_color_valid = 1U;

    PsAppUi_BuildPixelDpad(s_ps_app_ui_runtime.shell_panel, 48, 410);
    PsAppUi_BuildPixelActionButtons(s_ps_app_ui_runtime.shell_panel, shell_width - 88, 410);

    brand_plate = PsAppUi_CreatePixelBlock(s_ps_app_ui_runtime.shell_panel,
                                           (shell_width - 400) / 2,
                                           416,
                                           412,
                                           26,
                                           PS_APP_UI_COLOR_PANEL,
                                           PS_APP_UI_COLOR_SHELL_DARK);
    (void)PsAppUi_CreateKeyHint(brand_plate, 4, 3, "上下", "选择", PS_APP_UI_COLOR_SHELL_DARK);
    (void)PsAppUi_CreateKeyHint(brand_plate, 84, 3, "A", "启动", PS_APP_UI_COLOR_GREEN_DARK);
    (void)PsAppUi_CreateKeyHint(brand_plate, 164, 3, "X", "刷新", PS_APP_UI_COLOR_AMBER);
    (void)PsAppUi_CreateKeyHint(brand_plate, 244, 3, "Y", "系统", PS_APP_UI_COLOR_SHELL_DARK);
    (void)PsAppUi_CreateKeyHint(brand_plate, 324, 3, "B", "音频", PS_APP_UI_COLOR_GREEN_DARK);

    /* “关于”叠层：默认隐藏，按 Y 显示/关闭。
     * 注意 CreatePixelPanel 会创建“shadow + panel”两个兄弟对象；
     * 若只隐藏 panel，会遗留一块阴影遮罩。这里加一层 about_panel 作为父容器，
     * 把 shadow/panel 都挂在容器内，隐藏容器即可整体隐藏。 */
    s_ps_app_ui_runtime.about_panel = lv_obj_create(s_ps_app_ui_runtime.shell_panel);
    lv_obj_remove_style_all(s_ps_app_ui_runtime.about_panel);
    PsAppUi_Size(s_ps_app_ui_runtime.about_panel, 536, 272);
    PsAppUi_Pos(s_ps_app_ui_runtime.about_panel, (shell_width - 536) / 2, 80);
    lv_obj_set_style_bg_opa(s_ps_app_ui_runtime.about_panel, LV_OPA_TRANSP, 0);
    lv_obj_set_scrollable(s_ps_app_ui_runtime.about_panel, false);

    about_content = PsAppUi_CreatePixelPanel(s_ps_app_ui_runtime.about_panel,
                                             0,
                                             0,
                                             534,
                                             270,
                                             PS_APP_UI_COLOR_DISPLAY,
                                             PS_APP_UI_COLOR_GREEN_SOFT,
                                             PS_APP_UI_COLOR_PANEL_SHADOW);
    s_ps_app_ui_runtime.about_title_label = lv_label_create(about_content);
    lv_label_set_text(s_ps_app_ui_runtime.about_title_label, "SYSTEM SETTINGS");
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.about_title_label, PS_APP_UI_COLOR_GREEN_SOFT);
    PsAppUi_Pos(s_ps_app_ui_runtime.about_title_label, 42, 14);
    PsAppUi_CreateBitmapIcon(about_content,
                             18,
                             13,
                             &ps_app_ui_icon_info,
                             1,
                             PS_APP_UI_COLOR_GREEN_SOFT);
    (void)PsAppUi_CreatePixelBlock(about_content,
                                   18,
                                   36,
                                   498,
                                   2,
                                   PS_APP_UI_COLOR_GRID,
                                   PS_APP_UI_COLOR_GRID);

    s_ps_app_ui_runtime.about_body_label = lv_label_create(about_content);
    PsAppUi_Width(s_ps_app_ui_runtime.about_body_label, 296);
    lv_label_set_long_mode(s_ps_app_ui_runtime.about_body_label, LV_LABEL_LONG_WRAP);
    lv_label_set_text(s_ps_app_ui_runtime.about_body_label,
                      "SYSTEM\n"
                      "LVGL 9.6 / FreeRTOS\n"
                      "FatFs UTF-8 LFN / XRGB8888\n"
                      "PROJECT\n"
                      "Zynq GBA / MiSTer-Vivado\n"
                      "PIXEL GBA handheld menu\n"
                      "潘子彧 / 上海电机学院 2022级");
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.about_body_label, PS_APP_UI_COLOR_TEXT_ON_DARK);
    PsAppUi_Pos(s_ps_app_ui_runtime.about_body_label, 18, 54);

    for (display_index = 0U;
         display_index < (unsigned int)PS_APP_UI_DISPLAY_OPTION_COUNT;
         ++display_index) {
        lv_obj_t *choice_label = lv_label_create(about_content);

        PsAppUi_Width(choice_label, 296);
        lv_label_set_long_mode(choice_label, LV_LABEL_LONG_CLIP);
        PsAppUi_SetTextStyle(choice_label, PS_APP_UI_COLOR_TEXT_ON_DARK);
        PsAppUi_Pos(choice_label, 18, (lv_coord_t)(54U + display_index * 26U));
        lv_obj_set_hidden(choice_label, true);
        s_ps_app_ui_runtime.display_choice_labels[display_index] = choice_label;
    }

    (void)PsAppUi_CreatePixelBlock(about_content,
                                   334,
                                   54,
                                   2,
                                   150,
                                   PS_APP_UI_COLOR_GRID,
                                   PS_APP_UI_COLOR_GRID);

    {
        lv_obj_t *credits_label;

        credits_label = lv_label_create(about_content);
        PsAppUi_Width(credits_label, 162);
        lv_label_set_long_mode(credits_label, LV_LABEL_LONG_WRAP);
        lv_label_set_text(credits_label,
                          "CREDITS\n"
                          "LVGL graphics\n"
                          "FreeRTOS scheduling\n"
                          "FatFs filesystem\n"
                          "CherryUSB host stack\n"
                          "Xilinx Vitis drivers\n"
                          "Fusion Pixel Font");
        PsAppUi_SetTextStyle(credits_label, PS_APP_UI_COLOR_TEXT_ON_DARK);
        PsAppUi_Pos(credits_label, 354, 54);
        s_ps_app_ui_runtime.about_side_label = credits_label;
    }

    (void)PsAppUi_CreatePixelBlock(about_content,
                                   18,
                                   214,
                                   498,
                                   2,
                                   PS_APP_UI_COLOR_GRID,
                                   PS_APP_UI_COLOR_GRID);

    s_ps_app_ui_runtime.about_hint_label = lv_label_create(about_content);
    PsAppUi_Width(s_ps_app_ui_runtime.about_hint_label, 498);
    lv_label_set_long_mode(s_ps_app_ui_runtime.about_hint_label, LV_LABEL_LONG_CLIP);
    lv_label_set_text(s_ps_app_ui_runtime.about_hint_label, "Y/SELECT 关闭    B 返回");
    PsAppUi_SetTextStyle(s_ps_app_ui_runtime.about_hint_label, PS_APP_UI_COLOR_AMBER);
    PsAppUi_Pos(s_ps_app_ui_runtime.about_hint_label, 18, 228);

    lv_obj_set_hidden(s_ps_app_ui_runtime.about_panel,
                      (s_ps_app_ui_runtime.about_visible == 0U));

    PsAppUi_UpdateMetaLabels(ctx);
    PsAppUi_UpdateClockLabel(ctx);
    PsAppUi_RebuildList(ctx);
    PsAppUi_UpdateSystemPanel(ctx);
    if (ctx->state->status_line[0] == '\0') {
        PsAppUi_SetStatus(ctx, "菜单就绪");
    } else {
        lv_label_set_text(s_ps_app_ui_runtime.status_label, ctx->state->status_line);
        PsAppUi_ShowStatusIcon(PsAppUi_StatusRoleFromText(ctx->state->status_line));
        lv_obj_set_style_text_color(s_ps_app_ui_runtime.status_label,
                                    PsAppUi_HexColor(PsAppUi_StatusColor(ctx->state->status_line)),
                                    0);
    }
    PsAppUi_UpdateAudioRouteView(ctx);
    lv_screen_load(s_ps_app_ui_runtime.root_screen);
}

static void PsAppUi_SyncOutputModeLayout(PsAppUiContext *ctx) {
    PsAppHdmiLinkContext *link;
    lv_obj_t *old_root;
    u8 mode;
    u16 width;
    u16 height;

    if ((ctx == NULL) || (ctx->runtime == NULL) ||
        (s_ps_app_ui_runtime.display == NULL)) {
        return;
    }
    link = ctx->runtime->hdmi_ctx;
    if ((link == NULL) || (link->state == NULL) ||
        (link->state->video_mode_apply_pending != 0U)) {
        return;
    }

    mode = link->state->video_mode_active;
    if (mode == s_ps_app_ui_runtime.ui_video_mode) {
        return;
    }

    switch (mode) {
        case PS_APP_VIDEO_MODE_720P60:
            width = 1280U;
            height = 720U;
            break;
        case PS_APP_VIDEO_MODE_1080P30:
        case PS_APP_VIDEO_MODE_1080P60:
            width = 1920U;
            height = 1080U;
            break;
        case PS_APP_VIDEO_MODE_VGA480:
        default:
            mode = PS_APP_VIDEO_MODE_VGA480;
            width = 640U;
            height = 480U;
            break;
    }

    if (PsAppVideo_BeginUiRender() != XST_SUCCESS) return;
    if (link->state->video_mode_apply_pending ||
        mode != link->state->video_mode_active ||
        width != ctx->video->vdma->width || height != ctx->video->vdma->height) {
        PsAppVideo_EndUiRender();
        return;
    }
    old_root = s_ps_app_ui_runtime.root_screen;
    lv_display_set_resolution(s_ps_app_ui_runtime.display, width, height);
    PsAppUi_ConfigureNativeBuffers(ctx);
    s_ps_app_ui_runtime.game_button_count = 0U;
    PsAppUi_BuildScreen(ctx);
    if ((old_root != NULL) && lv_obj_is_valid(old_root)) {
        lv_obj_delete(old_root);
    }
    PsAppUi_ForceFullRedraw();
    PsAppVideo_EndUiRender();
}
XStatus PsAppUi_Init(PsAppUiContext *ctx) {
    lv_display_t *display;
    u32 width;
    u32 height;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL) || (ctx->video == NULL)) {
        return XST_INVALID_PARAM;
    }

    if (s_ps_app_ui_runtime.initialized != 0U) {
        s_ps_app_ui_runtime.ctx = ctx;
        return XST_SUCCESS;
    }

    memset(&s_ps_app_ui_runtime, 0, sizeof(s_ps_app_ui_runtime));
    s_ps_app_ui_runtime.ui_target_frame_idx = PS_APP_UI_TARGET_FRAME_IDX;
    s_ps_app_ui_runtime.ctx = ctx;
    lv_init();

    width = PS_APP_HDMI_BOOT_WIDTH;
    height = PS_APP_HDMI_BOOT_HEIGHT;
    if ((ctx->runtime->hdmi_ctx != NULL) && (ctx->runtime->hdmi_ctx->state != NULL) &&
        (ctx->runtime->hdmi_ctx->state->video_mode_apply_pending == 0U)) {
        if (ctx->runtime->hdmi_ctx->state->video_mode_active == PS_APP_VIDEO_MODE_720P60) {
            width = 1280U;
            height = 720U;
        } else if ((ctx->runtime->hdmi_ctx->state->video_mode_active == PS_APP_VIDEO_MODE_1080P30) ||
                   (ctx->runtime->hdmi_ctx->state->video_mode_active == PS_APP_VIDEO_MODE_1080P60)) {
            width = 1920U;
            height = 1080U;
        }
    }
    display = lv_display_create((int32_t)width, (int32_t)height);
    if (display == NULL) {
        return XST_FAILURE;
    }

    s_ps_app_ui_runtime.display = display;
    lv_display_set_default(display);
    lv_display_set_user_data(display, ctx);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_XRGB8888);
    PsAppUi_ConfigureNativeBuffers(ctx);
    lv_display_set_flush_wait_cb(display, PsAppUi_WaitFlush);
    lv_display_set_sync_cb(display, PsAppUi_SyncNativeRegion);
    /* Keep the timer for lv_refr_now(), but disable automatic refresh. */
    lv_timer_set_cb(lv_display_get_refr_timer(display), NULL);
    lv_display_set_flush_cb(display, PsAppUi_LvglFlushCb);

    PsAppUi_BuildScreen(ctx);
    s_ps_app_ui_runtime.initialized = 1U;
    return XST_SUCCESS;
}

void PsAppUi_RequestRefresh(PsAppUiContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    ctx->state->refresh_requested = 1U;
}

void PsAppUiTask(void *arg) {
    PsAppUiContext *ctx;
    TickType_t delay_ticks;
    PsAppUiState *state;
    XStatus init_status;

    ctx = (PsAppUiContext *)arg;
    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->runtime == NULL)) {
        xil_printf("[UI] invalid context\r\n");
        vTaskDelete(NULL);
        return;
    }

    PsAppVideo_RegisterUiFrameWaiter();
    init_status = PsAppUi_Init(ctx);
    if (init_status != XST_SUCCESS) {
        xil_printf("[UI] init failed: %d\r\n", init_status);
        vTaskDelete(NULL);
        return;
    }

    state = ctx->state;
    state->mode = (u8)PS_APP_UI_MODE_MENU;
    state->refresh_requested = 1U;
    state->launch_requested = 0U;
    state->lt_hold_ms = 0U;
    state->lt_exit_latched = 0U;
    state->board_exit_hold_ms = 0U;
    state->board_exit_latched = 0U;
    state->last_buttons = PsAppUi_GetMenuButtonMask(ctx->runtime);
    s_ps_app_ui_runtime.anim_elapsed_ms = 0U;
    s_ps_app_ui_runtime.blink_elapsed_ms = 0U;
    s_ps_app_ui_runtime.blink_phase = 0U;

    PsAppUi_SetStatus(ctx, "扫描游戏中...");
    PsAppUi_RebuildList(ctx);

    /* Paint the menu before the synchronous SD game scan can block this task. */
    lv_tick_inc(PS_APP_UI_SERVICE_INTERVAL_MS);
    (void)lv_timer_handler();
    PsAppUi_RefreshNative();
    delay_ticks = PsAppTime_MsToTicksCeil(PS_APP_UI_SERVICE_INTERVAL_MS);
    if (delay_ticks == 0U) {
        delay_ticks = 1U;
    }

    s_ps_app_ui_runtime.last_lv_tick_ms = PsAppTime_GetNowMs();
    for (;;) {
        PsAppUi_WaitFlush(s_ps_app_ui_runtime.display);
        u32 submitted_before = s_ps_app_ui_runtime.submitted_frames;
        u32 now_ms = PsAppTime_GetNowMs();
        s_ps_app_ui_runtime.frame_elapsed_ms = now_ms - s_ps_app_ui_runtime.last_lv_tick_ms;
        if (s_ps_app_ui_runtime.frame_elapsed_ms == 0U) s_ps_app_ui_runtime.frame_elapsed_ms = 1U;
        lv_tick_inc(s_ps_app_ui_runtime.frame_elapsed_ms);
        s_ps_app_ui_runtime.last_lv_tick_ms = now_ms;
        s_ps_app_ui_runtime.service_ticks++;
        PsAppUi_SyncModeWithRuntime(ctx);

        if ((state->mode == (u8)PS_APP_UI_MODE_MENU) ||
            (state->mode == (u8)PS_APP_UI_MODE_LOADING)) {
            PsAppUi_SyncOutputModeLayout(ctx);
            PsAppUi_EnsureMenuScreen();
            PsAppUi_UpdateClockLabel(ctx);
        }

        if (state->mode == (u8)PS_APP_UI_MODE_MENU) {
            if (state->refresh_requested != 0U) {
                (void)PsAppUi_RefreshGames(ctx);
            }
            PsAppUi_ProcessMenuInput(ctx);
            PsAppUi_UpdateAudioRouteView(ctx);
            PsAppUi_UpdateAnimation(ctx);
        } else if (state->mode == (u8)PS_APP_UI_MODE_LOADING) {
            PsAppUi_ProcessLaunch(ctx);
            PsAppUi_UpdateAudioRouteView(ctx);
            PsAppUi_UpdateAnimation(ctx);
            PsAppUi_UpdateRomLoadProgress(ctx);
        } else {
            PsAppUi_ProcessGameInput(ctx);
        }

        if ((state->mode == (u8)PS_APP_UI_MODE_MENU) ||
            (state->mode == (u8)PS_APP_UI_MODE_LOADING)) {
            (void)lv_timer_handler();
            /* Force one refresh opportunity per display frame, independent of
             * the millisecond timer rounding (16/17 ms at 60 Hz). */
            PsAppUi_RefreshNative();
            if (s_ps_app_ui_runtime.submitted_frames == submitted_before)
                (void)ulTaskNotifyTake(pdTRUE, PsAppTime_MsToTicksCeil(40U));
        } else vTaskDelay(delay_ticks);
    }
}
static void PsAppUi_PrintFramebufferDiagnostics(PsAppUiContext *ctx) {
    PsAppVideoVdmaDiagnostics diag;
    PsHdmiVdma *vdma;
    u32 *pixels;
    u32 frame_idx;
    u32 stride_pixels;
    u32 rgb_peak = 0U;
    u32 bright_samples = 0U;
    u32 sample_count = 0U;
    u32 x;
    u32 y;
    XStatus status;

    if ((ctx == NULL) || (ctx->video == NULL) || (ctx->video->vdma == NULL) ||
        (ctx->video->vdma->is_ready == 0U)) {
        xil_printf("[UI-FB] VDMA unavailable\r\n");
        return;
    }

    vdma = ctx->video->vdma;
    status = PsAppVideo_ReadVdmaDiagnostics(ctx->video, &diag);
    if (status != XST_SUCCESS) {
        xil_printf("[UI-FB] VDMA diagnostic failed=%d\r\n", (int)status);
        return;
    }

    frame_idx = diag.current_frame;
    if (frame_idx >= vdma->frame_count) {
        frame_idx = 0U;
    }
    stride_pixels = vdma->line_stride_bytes / sizeof(u32);
    Xil_DCacheInvalidateRange((INTPTR)vdma->frame_addrs[frame_idx],
                               (INTPTR)vdma->frame_size_bytes);
    pixels = (u32 *)vdma->frame_addrs[frame_idx];

    for (y = 0U; y < vdma->height; y += 16U) {
        for (x = 0U; x < vdma->width; x += 16U) {
            u32 rgb = pixels[y * stride_pixels + x] & 0x00FFFFFFU;
            u32 component = (rgb >> 16U) & 0xFFU;
            u32 green = (rgb >> 8U) & 0xFFU;
            u32 blue = rgb & 0xFFU;
            if (green > component) component = green;
            if (blue > component) component = blue;
            if (component > rgb_peak) rgb_peak = component;
            if (component > 64U) bright_samples++;
            sample_count++;
        }
    }

    xil_printf("[UI-FB] current=%u park=0x%08x cr=0x%08x sr=0x%08x err=0x%03x "
               "rgb_peak=%u bright=%u/%u\r\n",
               (unsigned int)diag.current_frame,
               (unsigned int)diag.park_pointer,
               (unsigned int)diag.control_reg,
               (unsigned int)diag.channel_status_reg,
               (unsigned int)diag.error_mask,
               (unsigned int)rgb_peak,
               (unsigned int)bright_samples,
               (unsigned int)sample_count);
}
void PsAppUi_PrintDiagnostics(void) {
    PsAppUiContext *ctx = s_ps_app_ui_runtime.ctx;
    PsAppUiState *state = (ctx != NULL) ? ctx->state : NULL;
    u32 rom_loaded = 0U;
    if ((ctx != NULL) && (ctx->runtime != NULL) && (ctx->runtime->rom != NULL)) {
        rom_loaded = ctx->runtime->rom->loaded;
    }
    xil_printf("[UI-DIAG] init=%u disp=%u root=%u loops=%u flush=%u done=%u "
               "pixel=0x%08x mode=%u games=%u refresh=%u scan=%u fs=%s rom=%u\r\n",
               (unsigned int)s_ps_app_ui_runtime.initialized,
               (unsigned int)(s_ps_app_ui_runtime.display != NULL),
               (unsigned int)(s_ps_app_ui_runtime.root_screen != NULL),
               (unsigned int)s_ps_app_ui_runtime.service_ticks,
               (unsigned int)s_ps_app_ui_runtime.flush_calls,
               (unsigned int)s_ps_app_ui_runtime.flush_completed,
               (unsigned int)s_ps_app_ui_runtime.last_flush_pixel,
               (unsigned int)((state != NULL) ? state->mode : 0xFFU),
               (unsigned int)((state != NULL) ? state->game_count : 0U),
               (unsigned int)((state != NULL) ? state->refresh_requested : 0U),
               (unsigned int)s_ps_app_ui_runtime.last_scan_failed,
               PsFatFsStorage_StrError(s_ps_app_ui_runtime.last_scan_fs_result),
               (unsigned int)rom_loaded);
    xil_printf("[UI-PERF] submit=%u present=%u missed=%u draw_last_us=%u draw_max_us=%u native=%ux%u\r\n",
        (unsigned int)s_ps_app_ui_runtime.submitted_frames,
        (unsigned int)s_ps_app_ui_runtime.presented_frames,
        (unsigned int)s_ps_app_ui_runtime.missed_deadlines,
        (unsigned int)s_ps_app_ui_runtime.last_frame_us,
        (unsigned int)s_ps_app_ui_runtime.max_draw_us,
        (unsigned int)lv_display_get_horizontal_resolution(s_ps_app_ui_runtime.display),
        (unsigned int)lv_display_get_vertical_resolution(s_ps_app_ui_runtime.display));
    PsAppUi_PrintFramebufferDiagnostics(ctx);
}

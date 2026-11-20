#include <lvgl/lvgl.h>
#include <lvgl/stdlib/lv_mem.h>
#include "Ui/Assets/Fonts/ps_ui_font_fusion_12.h"

#include <stdio.h>
#include <string.h>

#define TEST_WIDTH 640
#define TEST_HEIGHT 480
#define TEST_ROW_COUNT 128U
#define TEST_LIST_WIDTH 336
#define TEST_LIST_HEIGHT 210
#define TEST_ROW_LABEL_WIDTH 272
#define TEST_DETAIL_WIDTH 160

static LV_ATTRIBUTE_MEM_ALIGN uint8_t s_draw_buffer[TEST_WIDTH * 24 * 4];
static char s_game_names[TEST_ROW_COUNT][128];
static unsigned int s_flush_count;
static int s_flush_out_of_bounds;

#define TEST_REQUIRE(condition, message) \
    do { \
        if(!(condition)) { \
            fprintf(stderr, "LVGL_HOST_FAIL: %s (%s:%d)\n", message, __FILE__, __LINE__); \
            return 1; \
        } \
    } while(0)

static void test_flush_cb(lv_display_t * display, const lv_area_t * area, uint8_t * pixel_map)
{
    (void)pixel_map;
    if(area->x1 < 0 || area->y1 < 0 || area->x2 >= TEST_WIDTH || area->y2 >= TEST_HEIGHT) {
        s_flush_out_of_bounds = 1;
    }
    s_flush_count++;
    lv_display_flush_ready(display);
}

int main(void)
{
    static const char long_name[] =
        "非常长的游戏名称 Extremely Long English ROM Name 中文字符重复测试 "
        "VeryLongGameTitleWithoutTruncatingTheSourceName 这是保存在 ROM 元数据中的完整标题";
    lv_display_t * display;
    lv_obj_t * screen;
    lv_obj_t * list;
    lv_obj_t * empty_label;
    lv_obj_t * detail_title;
    lv_obj_t * rows[TEST_ROW_COUNT];
    lv_mem_monitor_t memory;
    lv_point_t text_size;
    lv_area_t area;
    unsigned int i;

    memset(rows, 0, sizeof(rows));
    lv_init();

    display = lv_display_create(TEST_WIDTH, TEST_HEIGHT);
    TEST_REQUIRE(display != NULL, "display allocation");
    lv_display_set_color_format(display, LV_COLOR_FORMAT_XRGB8888);
    lv_display_set_buffers(display, s_draw_buffer, NULL, sizeof(s_draw_buffer),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display, test_flush_cb);

    screen = lv_display_get_screen_active(display);
    TEST_REQUIRE(screen != NULL, "active screen");
    lv_obj_remove_style_all(screen);
    lv_obj_set_size(screen, TEST_WIDTH, TEST_HEIGHT);

    list = lv_obj_create(screen);
    TEST_REQUIRE(list != NULL, "game list allocation");
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, TEST_LIST_WIDTH, TEST_LIST_HEIGHT);
    lv_obj_set_pos(list, 12, 34);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_scrollable(list, true);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    empty_label = lv_label_create(list);
    TEST_REQUIRE(empty_label != NULL, "empty-list label allocation");
    lv_label_set_text_static(empty_label, "没有找到游戏 / No games found");
    TEST_REQUIRE(strcmp(lv_label_get_text(empty_label), "没有找到游戏 / No games found") == 0,
                 "empty-list text");
    lv_obj_clean(list);

    for(i = 0; i < TEST_ROW_COUNT; i++) {
        lv_obj_t * row;
        const char * name;

        if(i == 0) {
            name = long_name;
        }
        else {
            (void)snprintf(s_game_names[i], sizeof(s_game_names[i]),
                           (i & 1U) ? "GBA ROM %03u - Long English Name" :
                                      "游戏卡带 %03u - 中文名称",
                           i);
            name = s_game_names[i];
        }

        row = lv_label_create(list);
        TEST_REQUIRE(row != NULL, "ROM row allocation");
        rows[i] = row;
        lv_obj_remove_style_all(row);
        lv_obj_set_width(row, lv_pct(100));
        lv_obj_set_height(row, 28);
        lv_label_set_long_mode(row, LV_LABEL_LONG_MODE_DOTS);
        lv_label_set_max_lines(row, 1);
        lv_obj_set_style_text_font(row, &ps_ui_font_fusion_12, 0);
        lv_obj_set_style_border_side(row, LV_BORDER_SIDE_FULL, 0);
        lv_obj_set_style_border_width(row, 1, 0);
        lv_obj_set_style_pad_left(row, 14, 0);
        lv_label_set_text_static(row, name);
        TEST_REQUIRE(strcmp(lv_label_get_text(row), name) == 0,
                     "list display must retain full source name");
    }

    detail_title = lv_label_create(screen);
    TEST_REQUIRE(detail_title != NULL, "detail-title allocation");
    lv_obj_set_size(detail_title, TEST_DETAIL_WIDTH, 18);
    lv_obj_set_pos(detail_title, 400, 84);
    lv_obj_set_style_text_font(detail_title, &ps_ui_font_fusion_12, 0);
    lv_label_set_long_mode(detail_title, LV_LABEL_LONG_MODE_SCROLL_CIRCULAR);
    lv_label_set_text_static(detail_title, long_name);
    TEST_REQUIRE(strcmp(lv_label_get_text(detail_title), long_name) == 0,
                 "detail title must keep complete long name");

    lv_text_get_size(&text_size, long_name, &ps_ui_font_fusion_12, 0, 0,
                     LV_COORD_MAX, LV_TEXT_FLAG_NONE);
    TEST_REQUIRE(text_size.x > TEST_DETAIL_WIDTH, "long title should require scrolling");

    lv_obj_update_layout(screen);
    lv_obj_scroll_to_view(rows[TEST_ROW_COUNT - 1U], LV_ANIM_OFF);
    lv_obj_update_layout(list);
    TEST_REQUIRE(lv_obj_get_scroll_y(list) > 0, "selecting the last row scrolls it into view");

    lv_obj_add_state(rows[TEST_ROW_COUNT - 1U], LV_STATE_CHECKED);
    TEST_REQUIRE(lv_obj_has_state(rows[TEST_ROW_COUNT - 1U], LV_STATE_CHECKED),
                 "selected row state");

    lv_obj_get_coords(list, &area);
    TEST_REQUIRE(area.x1 >= 0 && area.y1 >= 0 &&
                 area.x2 < TEST_WIDTH && area.y2 < TEST_HEIGHT,
                 "list remains within 640x480 viewport");
    lv_obj_get_coords(detail_title, &area);
    TEST_REQUIRE(area.x1 >= 0 && area.y1 >= 0 &&
                 area.x2 < TEST_WIDTH && area.y2 < TEST_HEIGHT,
                 "detail title remains within 640x480 viewport");

    lv_mem_monitor(&memory);
    printf("LVGL_HOST_HEAP total=%zu free=%zu used=%zu max_used=%zu\\n",
           memory.total_size, memory.free_size,
           memory.total_size - memory.free_size, memory.max_used);
    TEST_REQUIRE(memory.total_size >= (80U * 1024U), "configured LVGL heap is present");
    TEST_REQUIRE(memory.free_size > 0, "128 ROM rows fit without exhausting the 96 KiB LVGL pool");

    lv_tick_inc(16);
    lv_refr_now(display);
    TEST_REQUIRE(s_flush_count > 0, "software renderer produced a flush");
    TEST_REQUIRE(s_flush_out_of_bounds == 0, "flush stayed inside display bounds");

    printf("LVGL_HOST_PASS rows=%u heap_total=%zu heap_free=%zu heap_max_used=%zu flushes=%u scroll_y=%d\n",
           TEST_ROW_COUNT, memory.total_size, memory.free_size, memory.max_used,
           s_flush_count, lv_obj_get_scroll_y(list));
    return 0;
}

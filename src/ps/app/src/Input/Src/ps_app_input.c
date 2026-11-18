#include "Input/Inc/ps_app_input.h"
#include "Input/Inc/ps_app_input_driver.h"

#include <string.h>

#include "xil_printf.h"
#include "queue.h"
#include "semphr.h"
#include "portmacro.h"

#include "Common/Inc/ps_project_config.h"
#include "Common/Inc/ps_app_time.h"

#ifndef PS_APP_INPUT_ENABLE_DEFAULT
#define PS_APP_INPUT_ENABLE_DEFAULT 1U
#endif

#ifndef PS_APP_INPUT_MAP_AB_BY_POSITION
#define PS_APP_INPUT_MAP_AB_BY_POSITION 1U
#endif

#ifndef PS_APP_INPUT_LSTICK_DEADZONE
#define PS_APP_INPUT_LSTICK_DEADZONE 12000
#endif

#ifndef PS_APP_INPUT_TRIGGER_THRESHOLD
#define PS_APP_INPUT_TRIGGER_THRESHOLD 80U
#endif

#ifndef PS_APP_INPUT_STABLE_SAMPLE_COUNT
#define PS_APP_INPUT_STABLE_SAMPLE_COUNT 2U
#endif

#ifndef PS_APP_INPUT_SHORT_PULSE_TICKS
#define PS_APP_INPUT_SHORT_PULSE_TICKS 8U
#endif

#ifndef PS_APP_INPUT_PRESS_DEBOUNCE_TICKS
#define PS_APP_INPUT_PRESS_DEBOUNCE_TICKS 2U
#endif

#ifndef PS_APP_INPUT_RELEASE_DEBOUNCE_TICKS
#define PS_APP_INPUT_RELEASE_DEBOUNCE_TICKS 6U
#endif

#define PS_APP_GBA_KEY_A       (1U << 0U)
#define PS_APP_GBA_KEY_B       (1U << 1U)
#define PS_APP_GBA_KEY_SELECT  (1U << 2U)
#define PS_APP_GBA_KEY_START   (1U << 3U)
#define PS_APP_GBA_KEY_RIGHT   (1U << 4U)
#define PS_APP_GBA_KEY_LEFT    (1U << 5U)
#define PS_APP_GBA_KEY_UP      (1U << 6U)
#define PS_APP_GBA_KEY_DOWN    (1U << 7U)
#define PS_APP_GBA_KEY_R       (1U << 8U)
#define PS_APP_GBA_KEY_L       (1U << 9U)
#define PS_APP_GBA_KEY_MASK_ALL 0x3FFU
#define PS_APP_GBA_KEY_COUNT    10U
#define PS_APP_GBA_KEY_MASK_DPAD \
    (PS_APP_GBA_KEY_RIGHT | PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)
#define PS_APP_GBA_KEY_MASK_ACTION (PS_APP_GBA_KEY_MASK_ALL & ~PS_APP_GBA_KEY_MASK_DPAD)
#define PS_APP_INPUT_DPAD_SOURCE_MASK \
    (PS_XINPUT_BUTTON_MASK_UP | PS_XINPUT_BUTTON_MASK_DOWN | \
     PS_XINPUT_BUTTON_MASK_LEFT | PS_XINPUT_BUTTON_MASK_RIGHT)
#define PS_APP_INPUT_NONSTICK_SOURCE_MASK \
    (PS_XINPUT_BUTTON_MASK_UP | PS_XINPUT_BUTTON_MASK_DOWN | \
     PS_XINPUT_BUTTON_MASK_LEFT | PS_XINPUT_BUTTON_MASK_RIGHT | \
     PS_XINPUT_BUTTON_MASK_START | PS_XINPUT_BUTTON_MASK_BACK | \
     PS_XINPUT_BUTTON_MASK_LB | PS_XINPUT_BUTTON_MASK_RB | \
     PS_XINPUT_BUTTON_MASK_A | PS_XINPUT_BUTTON_MASK_B | \
     PS_APP_INPUT_SRC_MASK_LT | PS_APP_INPUT_SRC_MASK_RT)

static XStatus PsAppInput_ApplyUsbAttached(PsAppInputContext *ctx,
                                           const PsAppInputUsbDeviceInfo *info);
static void PsAppInput_ApplyUsbDetached(PsAppInputContext *ctx, u32 device_generation);
static XStatus PsAppInput_UpdateFromReport(PsAppInputContext *ctx,
                                           u32 device_generation,
                                           const u8 *report,
                                           u32 report_len);

static u8 PsAppInput_ShouldSwapAbByPosition(const PsAppInputContext *ctx) {
    if ((ctx != NULL) && (ctx->active_driver != NULL) &&
        (ctx->active_driver->id == PS_APP_INPUT_DRIVER_ID_SWITCH_HID)) {
        return 0U;
    }

#if (PS_APP_INPUT_MAP_AB_BY_POSITION != 0U)
    return 1U;
#else
    return 0U;
#endif
}

static u32 PsAppInput_MapXinputToGbaKeys(const PsAppInputContext *ctx, const PsXinputPadState *pad) {
    u32 keys;
    u8 swap_ab;

    if (pad == NULL) {
        return 0U;
    }

    keys = 0U;
    swap_ab = PsAppInput_ShouldSwapAbByPosition(ctx);

    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_RIGHT) != 0U) {
        keys |= PS_APP_GBA_KEY_RIGHT;
    }
    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_LEFT) != 0U) {
        keys |= PS_APP_GBA_KEY_LEFT;
    }
    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_UP) != 0U) {
        keys |= PS_APP_GBA_KEY_UP;
    }
    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_DOWN) != 0U) {
        keys |= PS_APP_GBA_KEY_DOWN;
    }
    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_BACK) != 0U) {
        keys |= PS_APP_GBA_KEY_SELECT;
    }
    if ((pad->buttons & PS_XINPUT_BUTTON_MASK_START) != 0U) {
        keys |= PS_APP_GBA_KEY_START;
    }

    if (swap_ab != 0U) {
        if ((pad->buttons & PS_XINPUT_BUTTON_MASK_B) != 0U) {
            keys |= PS_APP_GBA_KEY_A;
        }
        if ((pad->buttons & PS_XINPUT_BUTTON_MASK_A) != 0U) {
            keys |= PS_APP_GBA_KEY_B;
        }
    } else {
        if ((pad->buttons & PS_XINPUT_BUTTON_MASK_A) != 0U) {
            keys |= PS_APP_GBA_KEY_A;
        }
        if ((pad->buttons & PS_XINPUT_BUTTON_MASK_B) != 0U) {
            keys |= PS_APP_GBA_KEY_B;
        }
    }

    if (((pad->buttons & PS_XINPUT_BUTTON_MASK_LB) != 0U) ||
        (pad->lt >= PS_APP_INPUT_TRIGGER_THRESHOLD)) {
        keys |= PS_APP_GBA_KEY_L;
    }
    if (((pad->buttons & PS_XINPUT_BUTTON_MASK_RB) != 0U) ||
        (pad->rt >= PS_APP_INPUT_TRIGGER_THRESHOLD)) {
        keys |= PS_APP_GBA_KEY_R;
    }

    if (pad->lx >= PS_APP_INPUT_LSTICK_DEADZONE) {
        keys |= PS_APP_GBA_KEY_RIGHT;
    } else if (pad->lx <= (-PS_APP_INPUT_LSTICK_DEADZONE)) {
        keys |= PS_APP_GBA_KEY_LEFT;
    }

    if (pad->ly >= PS_APP_INPUT_LSTICK_DEADZONE) {
        keys |= PS_APP_GBA_KEY_UP;
    } else if (pad->ly <= (-PS_APP_INPUT_LSTICK_DEADZONE)) {
        keys |= PS_APP_GBA_KEY_DOWN;
    }

    if ((keys & (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) ==
        (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) {
        keys &= ~(PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT);
    }
    if ((keys & (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) ==
        (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) {
        keys &= ~(PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN);
    }

    return keys & 0x3FFU;
}

static u32 PsAppInput_BuildSourceMaskFromPad(const PsXinputPadState *pad) {
    u32 source_mask;

    if (pad == NULL) {
        return 0U;
    }

    source_mask = (u32)pad->buttons;
    if (pad->lt >= PS_APP_INPUT_TRIGGER_THRESHOLD) {
        source_mask |= PS_APP_INPUT_SRC_MASK_LT;
    }
    if (pad->rt >= PS_APP_INPUT_TRIGGER_THRESHOLD) {
        source_mask |= PS_APP_INPUT_SRC_MASK_RT;
    }
    if (pad->lx >= PS_APP_INPUT_LSTICK_DEADZONE) {
        source_mask |= PS_APP_INPUT_SRC_MASK_LS_RIGHT;
    } else if (pad->lx <= (-PS_APP_INPUT_LSTICK_DEADZONE)) {
        source_mask |= PS_APP_INPUT_SRC_MASK_LS_LEFT;
    }
    if (pad->ly >= PS_APP_INPUT_LSTICK_DEADZONE) {
        source_mask |= PS_APP_INPUT_SRC_MASK_LS_UP;
    } else if (pad->ly <= (-PS_APP_INPUT_LSTICK_DEADZONE)) {
        source_mask |= PS_APP_INPUT_SRC_MASK_LS_DOWN;
    }

    return source_mask;
}

static void PsAppInput_IncrementCounter(u32 *counter) {
    if ((counter != NULL) && (*counter < 0xFFFFFFFFU)) {
        (*counter)++;
    }
}

static void PsAppInput_LogParseDrop(const PsAppInputState *state,
                                    const char *reason,
                                    const u8 *report,
                                    u32 report_len) {
    u32 idx;
    u32 dump_len;

    if ((state == NULL) || (report == NULL) || (report_len == 0U)) {
        return;
    }

    if (!((state->parse_error_count <= 6U) || ((state->parse_error_count % 64U) == 0U))) {
        return;
    }

    dump_len = report_len;
    if (dump_len > 16U) {
        dump_len = 16U;
    }

    xil_printf("[INPUT] parse drop reason=%s err=%u len=%u vid=0x%04x pid=0x%04x raw=",
               (reason != NULL) ? reason : "unknown",
               (unsigned int)state->parse_error_count,
               (unsigned int)report_len,
               (unsigned int)state->vendor_id,
               (unsigned int)state->product_id);
    for (idx = 0U; idx < dump_len; ++idx) {
        xil_printf("%s%02x",
                   (idx == 0U) ? "" : " ",
                   (unsigned int)report[idx]);
    }
    if (report_len > dump_len) {
        xil_printf(" ...");
    }
    xil_printf("\r\n");
}

static void PsAppInput_ResetKeyConditioner(PsAppInputState *state) {
    if (state == NULL) {
        return;
    }

    state->raw_mapped_keys = 0U;
    state->source_snapshot_mask = 0U;
    state->last_logged_source_mask = 0U;
    state->mapped_keys = 0U;
    state->sampled_keys = 0U;
    state->frame_press_keys = 0U;
    state->report_press_latch_keys = 0U;
    state->pending_mapped_keys = 0U;
    state->debounced_nonstick_keys = 0U;
    state->frame_sync_ready = 0U;
    state->frame_sync_token = 0U;
    memset(state->debounce_count, 0, sizeof(state->debounce_count));
    memset(state->short_pulse_ticks, 0, sizeof(state->short_pulse_ticks));
}

static u32 PsAppInput_StickMappedKeysFromSource(u32 source_mask) {
    u32 stick_keys = 0U;

    if ((source_mask & PS_APP_INPUT_SRC_MASK_LS_RIGHT) != 0U) {
        stick_keys |= PS_APP_GBA_KEY_RIGHT;
    }
    if ((source_mask & PS_APP_INPUT_SRC_MASK_LS_LEFT) != 0U) {
        stick_keys |= PS_APP_GBA_KEY_LEFT;
    }
    if ((source_mask & PS_APP_INPUT_SRC_MASK_LS_UP) != 0U) {
        stick_keys |= PS_APP_GBA_KEY_UP;
    }
    if ((source_mask & PS_APP_INPUT_SRC_MASK_LS_DOWN) != 0U) {
        stick_keys |= PS_APP_GBA_KEY_DOWN;
    }

    return stick_keys & PS_APP_GBA_KEY_MASK_ALL;
}

static u32 PsAppInput_MapNonStickSourceToGbaKeys(const PsAppInputContext *ctx, u32 source_mask) {
    u32 keys = 0U;
    u8 swap_ab;

    swap_ab = PsAppInput_ShouldSwapAbByPosition(ctx);

    if ((source_mask & PS_XINPUT_BUTTON_MASK_RIGHT) != 0U) {
        keys |= PS_APP_GBA_KEY_RIGHT;
    }
    if ((source_mask & PS_XINPUT_BUTTON_MASK_LEFT) != 0U) {
        keys |= PS_APP_GBA_KEY_LEFT;
    }
    if ((source_mask & PS_XINPUT_BUTTON_MASK_UP) != 0U) {
        keys |= PS_APP_GBA_KEY_UP;
    }
    if ((source_mask & PS_XINPUT_BUTTON_MASK_DOWN) != 0U) {
        keys |= PS_APP_GBA_KEY_DOWN;
    }
    if ((source_mask & PS_XINPUT_BUTTON_MASK_BACK) != 0U) {
        keys |= PS_APP_GBA_KEY_SELECT;
    }
    if ((source_mask & PS_XINPUT_BUTTON_MASK_START) != 0U) {
        keys |= PS_APP_GBA_KEY_START;
    }
    if (swap_ab != 0U) {
        if ((source_mask & PS_XINPUT_BUTTON_MASK_B) != 0U) {
            keys |= PS_APP_GBA_KEY_A;
        }
        if ((source_mask & PS_XINPUT_BUTTON_MASK_A) != 0U) {
            keys |= PS_APP_GBA_KEY_B;
        }
    } else {
        if ((source_mask & PS_XINPUT_BUTTON_MASK_A) != 0U) {
            keys |= PS_APP_GBA_KEY_A;
        }
        if ((source_mask & PS_XINPUT_BUTTON_MASK_B) != 0U) {
            keys |= PS_APP_GBA_KEY_B;
        }
    }
    if ((source_mask & (PS_XINPUT_BUTTON_MASK_LB | PS_APP_INPUT_SRC_MASK_LT)) != 0U) {
        keys |= PS_APP_GBA_KEY_L;
    }
    if ((source_mask & (PS_XINPUT_BUTTON_MASK_RB | PS_APP_INPUT_SRC_MASK_RT)) != 0U) {
        keys |= PS_APP_GBA_KEY_R;
    }

    /* 行业常见防御：对互斥方向做消抖前归一化，避免过渡态把“左右/上下同时按下”
     * 误送进后级状态机，导致短按边沿被拆成多次触发。 */
    if ((keys & (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) ==
        (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) {
        keys &= ~(PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT);
    }
    if ((keys & (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) ==
        (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) {
        keys &= ~(PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN);
    }

    return keys & PS_APP_GBA_KEY_MASK_ALL;
}

static void PsAppInput_UpdatePulseAndDebounce(const PsAppInputContext *ctx,
                                              u32 source_mask) {
    PsAppInputState *state;
    u32 nonstick_source_mask;
    u32 nonstick_level_keys;
    u32 bit;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }
    state = ctx->state;

    nonstick_source_mask = source_mask & PS_APP_INPUT_NONSTICK_SOURCE_MASK;
    nonstick_level_keys = PsAppInput_MapNonStickSourceToGbaKeys(ctx, nonstick_source_mask) &
                          PS_APP_GBA_KEY_MASK_ACTION;
    state->pending_mapped_keys = nonstick_source_mask;

    for (bit = 0U; bit < PS_APP_GBA_KEY_COUNT; ++bit) {
        u8 raw_pressed;
        u8 debounced_pressed;
        u8 threshold;
        const u32 bit_mask = (1U << bit);

        raw_pressed = ((nonstick_level_keys & bit_mask) != 0U) ? 1U : 0U;
        debounced_pressed = ((state->debounced_nonstick_keys & bit_mask) != 0U) ? 1U : 0U;
        if (raw_pressed == debounced_pressed) {
            state->debounce_count[bit] = 0U;
            continue;
        }

        if (state->debounce_count[bit] < 0xFFU) {
            state->debounce_count[bit]++;
        }
        threshold = (raw_pressed != 0U) ?
                    (u8)PS_APP_INPUT_PRESS_DEBOUNCE_TICKS :
                    (u8)PS_APP_INPUT_RELEASE_DEBOUNCE_TICKS;
        if (threshold == 0U) {
            threshold = 1U;
        }
        if (state->debounce_count[bit] < threshold) {
            continue;
        }

        state->debounce_count[bit] = 0U;
        if (raw_pressed != 0U) {
            /* 仅在“去抖后的上升沿”装载一次短脉冲，按住不重触发。 */
            state->debounced_nonstick_keys |= bit_mask;
            state->short_pulse_ticks[bit] = (u8)PS_APP_INPUT_SHORT_PULSE_TICKS;
        } else {
            state->debounced_nonstick_keys &= ~bit_mask;
        }
    }
}

static void PsAppInput_RefreshMappedKeys(const PsAppInputContext *ctx,
                                         u32 source_mask,
                                         u8 consume_pulse_tick) {
    PsAppInputState *state;
    u32 conditioned_keys;
    u32 stick_keys;
    u32 dpad_keys;
    u32 nonstick_keys;
    u32 bit;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }
    state = ctx->state;

    stick_keys = PsAppInput_StickMappedKeysFromSource(source_mask);
    dpad_keys = PsAppInput_MapNonStickSourceToGbaKeys(ctx, source_mask & PS_APP_INPUT_DPAD_SOURCE_MASK) &
                PS_APP_GBA_KEY_MASK_DPAD;
    nonstick_keys = state->debounced_nonstick_keys & PS_APP_GBA_KEY_MASK_ACTION;
    conditioned_keys = (stick_keys | dpad_keys | nonstick_keys);

    for (bit = 0U; bit < PS_APP_GBA_KEY_COUNT; ++bit) {
        const u32 bit_mask = (1U << bit);
        if (((stick_keys & bit_mask) != 0U) ||
            ((PS_APP_GBA_KEY_MASK_DPAD & bit_mask) != 0U)) {
            /* 摇杆方向保持“按住即连续”行为。 */
            continue;
        }
        if (state->short_pulse_ticks[bit] > 0U) {
            conditioned_keys |= bit_mask;
            if (consume_pulse_tick != 0U) {
                state->short_pulse_ticks[bit]--;
            }
        }
    }

    if ((conditioned_keys & (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) ==
        (PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT)) {
        conditioned_keys &= ~(PS_APP_GBA_KEY_LEFT | PS_APP_GBA_KEY_RIGHT);
    }
    if ((conditioned_keys & (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) ==
        (PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN)) {
        conditioned_keys &= ~(PS_APP_GBA_KEY_UP | PS_APP_GBA_KEY_DOWN);
    }

    state->sampled_keys = (conditioned_keys & PS_APP_GBA_KEY_MASK_ALL);
}

static XStatus PsAppInput_UpdateFromReport(PsAppInputContext *ctx,
                                           u32 device_generation,
                                           const u8 *report,
                                           u32 report_len) {
    PsAppInputPadState parsed;
    PsAppInputState *state;
    const PsAppInputDriverOps *ops;
    u32 copy_len;
    u32 raw_mapped_keys;
    u32 previous_raw_mapped_keys;
    XStatus status;

    if ((ctx == NULL) || (ctx->state == NULL) || (report == NULL)) {
        return XST_INVALID_PARAM;
    }
    state = ctx->state;
    if ((state->enabled == 0U) || (ctx->active_driver == NULL) ||
        (ctx->active_driver->ops == NULL)) {
        return XST_FAILURE;
    }
    if (PsAppInputDriver_IsReportGenerationCurrent(ctx->active_device_generation,
                                                   device_generation) == 0U) {
        if (state->stale_report_count < 0xFFFFFFFFU) state->stale_report_count++;
        return XST_FAILURE;
    }

    ops = ctx->active_driver->ops;
    if ((ops->ignore_report != NULL) &&
        (ops->ignore_report(&ctx->active_device, report, report_len) != 0U)) {
        return XST_SUCCESS;
    }
    if ((ops->accept_report != NULL) &&
        (ops->accept_report(&ctx->active_device, report, report_len) == 0U)) {
        state->parse_error_count++;
        PsAppInput_LogParseDrop(state, "unexpected-main-report", report, report_len);
        return XST_FAILURE;
    }
    if (ops->parse_input == NULL) return XST_FAILURE;
    status = ops->parse_input(&ctx->active_device, report, report_len, &parsed);
    if (status != XST_SUCCESS) {
        state->parse_error_count++;
        PsAppInput_LogParseDrop(state, "driver-parse-failed", report, report_len);
        return status;
    }

    raw_mapped_keys = PsAppInput_MapXinputToGbaKeys(ctx, &parsed);
    previous_raw_mapped_keys = state->raw_mapped_keys & PS_APP_GBA_KEY_MASK_ALL;
    state->report_press_latch_keys |=
        raw_mapped_keys & ~previous_raw_mapped_keys & PS_APP_GBA_KEY_MASK_ALL;
    state->active = 1U;
    state->protocol_is_xinput = 1U;
    state->device_generation = ctx->active_device_generation;
    state->report_valid = 1U;
    state->buttons = parsed.buttons;
    state->lt = parsed.lt;
    state->rt = parsed.rt;
    state->lx = parsed.lx;
    state->ly = parsed.ly;
    state->rx = parsed.rx;
    state->ry = parsed.ry;
    state->source_snapshot_mask = PsAppInput_BuildSourceMaskFromPad(&parsed);
    state->raw_mapped_keys = raw_mapped_keys & PS_APP_GBA_KEY_MASK_ALL;
    state->pending_mapped_keys = state->source_snapshot_mask & PS_APP_INPUT_NONSTICK_SOURCE_MASK;
    state->report_count++;

    copy_len = report_len;
    if (copy_len > sizeof(state->last_report)) copy_len = sizeof(state->last_report);
    state->last_report_len = (u8)copy_len;
    if (copy_len > 0U) memcpy(state->last_report, report, copy_len);
    return XST_SUCCESS;
}

#ifdef __GNUC__
__attribute__((weak))
#endif
void PsAppInput_BackendPoll(PsAppInputContext *ctx) {
    (void)ctx;
}

void PsAppInput_Init(PsAppInputContext *ctx) {
    PsAppInputState *state;

    if ((ctx == NULL) || (ctx->state == NULL)) return;
    state = ctx->state;
    memset(state, 0, sizeof(*state));
    ctx->active_driver = NULL;
    ctx->active_device_generation = 0U;
    ctx->producer_generation = 0U;
    memset(&ctx->active_device, 0, sizeof(ctx->active_device));
    if (ctx->event_control_lock == NULL) {
        ctx->event_control_lock = xSemaphoreCreateMutex();
    }
    state->enabled = (u8)((PS_APP_INPUT_ENABLE_DEFAULT != 0U) ? 1U : 0U);
    state->last_committed_keys = 0U;
    PsAppInput_ResetKeyConditioner(state);

    if (ctx->event_queue == NULL) {
        ctx->event_queue = xQueueCreate(PS_APP_INPUT_EVENT_QUEUE_DEPTH,
                                        sizeof(PsAppInputEvent));
    }
    if ((ctx->event_queue == NULL) || (ctx->event_control_lock == NULL)) {
        state->enabled = 0U;
        xil_printf("[INPUT] event queue/lock allocation failed; input disabled\r\n");
    }
}

void PsAppInput_Service(PsAppInputContext *ctx) {
    PsAppInputEvent event;
    u32 prev_sampled_keys;
    u32 curr_sampled_keys;
    u32 transient_report_press_keys;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->event_queue == NULL)) return;

    while (xQueueReceive(ctx->event_queue, &event, 0U) == pdTRUE) {
        switch ((PsAppInputEventType)event.type) {
            case PS_APP_INPUT_EVENT_ATTACHED:
                (void)PsAppInput_ApplyUsbAttached(ctx, &event.data.device);
                break;
            case PS_APP_INPUT_EVENT_DETACHED:
                PsAppInput_ApplyUsbDetached(ctx, event.device_generation);
                break;
            case PS_APP_INPUT_EVENT_REPORT:
                (void)PsAppInput_UpdateFromReport(ctx,
                                                  event.device_generation,
                                                  event.data.report,
                                                  event.report_len);
                break;
            case PS_APP_INPUT_EVENT_INJECT_REPORT:
                if (ctx->state->active == 0U) {
                    PsAppInputUsbDeviceInfo fake_info;
                    memset(&fake_info, 0, sizeof(fake_info));
                    fake_info.vendor_id = 0x2DC8U;
                    fake_info.product_id = 0x3106U;
                    fake_info.interface_class = PS_XINPUT_INTERFACE_CLASS;
                    fake_info.interface_subclass = PS_XINPUT_INTERFACE_SUBCLASS;
                    fake_info.interface_protocol = PS_XINPUT_INTERFACE_PROTOCOL;
                    fake_info.ep_in_addr = 0x81U;
                    fake_info.ep_out_addr = 0x01U;
                    fake_info.ep_in_interval_ms = 4U;
                    fake_info.ep_out_interval_ms = 8U;
                    fake_info.device_generation = ctx->active_device_generation + 1U;
                    if (fake_info.device_generation == 0U) fake_info.device_generation = 1U;
                    (void)PsAppInput_ApplyUsbAttached(ctx, &fake_info);
                }
                (void)PsAppInput_UpdateFromReport(ctx,
                                                  ctx->active_device_generation,
                                                  event.data.report,
                                                  event.report_len);
                break;
            case PS_APP_INPUT_EVENT_UNSUPPORTED:
                if (ctx->state->unsupported_report_count < 0xFFFFFFFFU) {
                    ctx->state->unsupported_report_count++;
                }
                break;
            default:
                break;
        }
    }

    if (ctx->state->enabled == 0U) return;
    /*
     * Keep a press that was observed and released before this service pass.
     * The normal conditioner still owns stable levels; this latch only
     * supplies the one-shot edge that the final report level would hide.
     */
    transient_report_press_keys =
        ctx->state->report_press_latch_keys &
        ~(ctx->state->raw_mapped_keys & PS_APP_GBA_KEY_MASK_ALL);
    ctx->state->report_press_latch_keys = 0U;
    prev_sampled_keys = ctx->state->sampled_keys & PS_APP_GBA_KEY_MASK_ALL;
    ctx->state->frame_press_keys |= transient_report_press_keys;
    /* USB producers enqueue copied reports; the Input task owns parsing and
     * writes every shared PsAppInputState field. */
    PsAppInput_UpdatePulseAndDebounce(ctx, ctx->state->source_snapshot_mask);
    PsAppInput_RefreshMappedKeys(ctx, ctx->state->source_snapshot_mask, 1U);
    curr_sampled_keys = ctx->state->sampled_keys & PS_APP_GBA_KEY_MASK_ALL;
    ctx->state->frame_press_keys |= (curr_sampled_keys & ~prev_sampled_keys);
    PsAppInput_BackendPoll(ctx);
}

void PsAppInput_PublishFrame(PsAppInputContext *ctx, u32 frame_token) {
    PsAppInputState *state;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    state = ctx->state;
    if (state->enabled == 0U) {
        return;
    }
    if ((state->frame_sync_ready != 0U) && (state->frame_sync_token == frame_token)) {
        return;
    }

    state->mapped_keys = (state->sampled_keys | state->frame_press_keys) & PS_APP_GBA_KEY_MASK_ALL;
    state->frame_press_keys = 0U;
    state->frame_sync_token = frame_token;
    state->frame_sync_ready = 1U;
}

static XStatus PsAppInput_ApplyUsbAttached(PsAppInputContext *ctx,
                                            const PsAppInputUsbDeviceInfo *info) {
    PsAppInputState *state;
    const PsAppInputDriver *driver;
    u32 generation;

    if ((ctx == NULL) || (ctx->state == NULL) || (info == NULL)) return XST_INVALID_PARAM;
    state = ctx->state;
    if (state->enabled == 0U) return XST_FAILURE;

    driver = PsAppInputDriver_Select(info);
    generation = info->device_generation;
    if (generation == 0U) {
        generation = ctx->active_device_generation + 1U;
        if (generation == 0U) generation = 1U;
    }
    if ((ctx->active_device_generation != 0U) &&
        (PsAppInputDriver_IsNewerGeneration(generation, ctx->active_device_generation) == 0U)) {
        if (state->stale_report_count < 0xFFFFFFFFU) state->stale_report_count++;
        return XST_FAILURE;
    }

    if (driver == NULL) {
        if (ctx->active_device_generation != 0U) {
            PsAppInput_ApplyUsbDetached(ctx, ctx->active_device_generation);
        }
        ctx->active_device_generation = generation;
        state->device_generation = generation;
        if (state->unsupported_report_count < 0xFFFFFFFFU) state->unsupported_report_count++;
        return PS_APP_INPUT_DRIVER_STATUS_UNSUPPORTED;
    }

    if ((ctx->active_driver != NULL) && (ctx->active_driver->ops != NULL) &&
        (ctx->active_driver->ops->detach != NULL)) {
        ctx->active_driver->ops->detach(&ctx->active_device,
                                        ctx->active_device_generation);
    }
    if ((driver->ops == NULL) || (driver->ops->init == NULL) ||
        (driver->ops->init(info) != XST_SUCCESS)) {
        if (ctx->active_device_generation != 0U) {
            PsAppInput_ApplyUsbDetached(ctx, ctx->active_device_generation);
        }
        ctx->active_device_generation = generation;
        state->device_generation = generation;
        if (state->unsupported_report_count < 0xFFFFFFFFU) state->unsupported_report_count++;
        return XST_FAILURE;
    }

    ctx->active_device = *info;
    ctx->active_device.device_generation = generation;
    ctx->active_device_generation = generation;
    ctx->active_driver = driver;

    state->active = 1U;
    state->release_pending = 0U;
    state->report_valid = 0U;
    state->protocol_is_xinput = 1U;
    state->output_capable = (u8)((info->ep_out_addr != 0U) &&
                                 (driver->ops->build_output != NULL));
    state->vendor_id = info->vendor_id;
    state->product_id = info->product_id;
    state->interface_number = info->interface_number;
    state->interface_class = info->interface_class;
    state->interface_subclass = info->interface_subclass;
    state->interface_protocol = info->interface_protocol;
    state->device_generation = generation;
    state->ep_in_addr = info->ep_in_addr;
    state->ep_out_addr = info->ep_out_addr;
    state->ep_in_interval_ms = info->ep_in_interval_ms;
    state->ep_out_interval_ms = info->ep_out_interval_ms;
    PsAppInput_ResetKeyConditioner(state);
    state->buttons = 0U;
    state->lt = 0U;
    state->rt = 0U;
    state->lx = 0;
    state->ly = 0;
    state->rx = 0;
    state->ry = 0;
    state->last_report_len = 0U;

    xil_printf("[INPUT] attached driver=%s vid=0x%04x pid=0x%04x intf=%u gen=%u ep_in=0x%02x ep_out=0x%02x\\r\\n",
               driver->name,
               (unsigned int)state->vendor_id,
               (unsigned int)state->product_id,
               (unsigned int)state->interface_number,
               (unsigned int)generation,
               (unsigned int)state->ep_in_addr,
               (unsigned int)state->ep_out_addr);
    return XST_SUCCESS;
}

static void PsAppInput_ApplyUsbDetached(PsAppInputContext *ctx, u32 device_generation) {
    PsAppInputState *state;
    u8 need_release;

    if ((ctx == NULL) || (ctx->state == NULL)) return;
    state = ctx->state;
    if (PsAppInputDriver_IsReportGenerationCurrent(
            ctx->active_device_generation, device_generation) == 0U) {
        if (state->stale_report_count < 0xFFFFFFFFU) state->stale_report_count++;
        return;
    }

    if ((ctx->active_driver != NULL) && (ctx->active_driver->ops != NULL) &&
        (ctx->active_driver->ops->detach != NULL)) {
        ctx->active_driver->ops->detach(&ctx->active_device,
                                        ctx->active_device_generation);
    }
    if (state->active != 0U) {
        xil_printf("[INPUT] detached gen=%u\\r\\n",
                   (unsigned int)ctx->active_device_generation);
    }
    need_release = ((state->active != 0U) ||
                    (state->report_valid != 0U) ||
                    (state->mapped_keys != 0U)) ? 1U : 0U;
    ctx->active_driver = NULL;
    memset(&ctx->active_device, 0, sizeof(ctx->active_device));
    state->active = 0U;
    state->release_pending = need_release;
    state->report_valid = 0U;
    state->protocol_is_xinput = 0U;
    state->output_capable = 0U;
    state->vendor_id = 0U;
    state->product_id = 0U;
    state->interface_number = 0U;
    state->interface_class = 0U;
    state->interface_subclass = 0U;
    state->interface_protocol = 0U;
    state->ep_in_addr = 0U;
    state->ep_out_addr = 0U;
    state->ep_in_interval_ms = 0U;
    state->ep_out_interval_ms = 0U;
    state->buttons = 0U;
    state->lt = 0U;
    state->rt = 0U;
    state->lx = 0;
    state->ly = 0;
    state->rx = 0;
    state->ry = 0;
    PsAppInput_ResetKeyConditioner(state);
    state->last_report_len = 0U;
}

static XStatus PsAppInput_EnqueueEvent(PsAppInputContext *ctx,
                                        const PsAppInputEvent *event,
                                        u8 replace_pending) {
    if ((ctx == NULL) || (ctx->event_queue == NULL) || (event == NULL)) {
        return XST_FAILURE;
    }
    if (xQueueSend(ctx->event_queue, event, 0U) == pdTRUE) return XST_SUCCESS;
    PsAppInput_IncrementCounter(&ctx->state->event_queue_overflow_count);
    if (replace_pending != 0U) {
        /* Attach/detach supersedes stale pending reports. */
        PsAppInput_IncrementCounter(&ctx->state->event_queue_reset_count);
        (void)xQueueReset(ctx->event_queue);
        if (xQueueSend(ctx->event_queue, event, 0U) == pdTRUE) return XST_SUCCESS;
    }
    return XST_FAILURE;
}

static XStatus PsAppInput_EnqueueReportFromIsr(PsAppInputContext *ctx,
                                                const PsAppInputEvent *event) {
    BaseType_t higher_priority_task_woken = pdFALSE;

    if ((ctx == NULL) || (ctx->event_queue == NULL) || (event == NULL)) return XST_FAILURE;
    if (xQueueSendFromISR(ctx->event_queue, event, &higher_priority_task_woken) != pdTRUE) {
        PsAppInput_IncrementCounter(&ctx->state->event_queue_overflow_count);
        return XST_FAILURE;
    }
    portYIELD_FROM_ISR(higher_priority_task_woken);
    return XST_SUCCESS;
}

static XStatus PsAppInput_QueueUsbAttachInternal(
    PsAppInputContext *ctx,
    const PsAppInputUsbDeviceInfo *info,
    u8 *driver_id_out,
    u32 *host_init_policy_out,
    u8 allow_legacy_generation) {
    PsAppInputEvent event;
    PsAppInputUsbDeviceInfo normalized;
    const PsAppInputDriver *driver;
    TickType_t lock_wait;
    XStatus enqueue_status;
    u32 generation;

    if ((ctx == NULL) || (info == NULL) || (ctx->event_control_lock == NULL)) {
        return XST_INVALID_PARAM;
    }
    lock_wait = PsAppTime_MsToTicksCeil(PS_APP_INPUT_CONTROL_LOCK_WAIT_MS);
    if (xSemaphoreTake(ctx->event_control_lock, lock_wait) != pdTRUE) return XST_DEVICE_BUSY;

    normalized = *info;
    generation = normalized.device_generation;
    if (generation == 0U) {
        if (allow_legacy_generation == 0U) {
            (void)xSemaphoreGive(ctx->event_control_lock);
            return XST_INVALID_PARAM;
        }
        generation = ctx->producer_generation + 1U;
        if (generation == 0U) generation = 1U;
        normalized.device_generation = generation;
    }
    if ((ctx->producer_generation != 0U) &&
        (PsAppInputDriver_IsNewerGeneration(generation, ctx->producer_generation) == 0U)) {
        (void)xSemaphoreGive(ctx->event_control_lock);
        return XST_FAILURE;
    }
    ctx->producer_generation = generation;

    driver = PsAppInputDriver_Select(&normalized);
    if (driver_id_out != NULL) *driver_id_out = (driver != NULL) ? (u8)driver->id : 0U;
    if (host_init_policy_out != NULL) {
        *host_init_policy_out = (driver != NULL) ?
                                PsAppInputDriver_GetHostInitPolicy(driver, &normalized) :
                                PS_APP_INPUT_HOST_INIT_NONE;
    }
    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_ATTACHED;
    event.device_generation = generation;
    event.data.device = normalized;
    enqueue_status = PsAppInput_EnqueueEvent(ctx, &event, 1U);
    (void)xSemaphoreGive(ctx->event_control_lock);
    if (enqueue_status != XST_SUCCESS) return enqueue_status;
    return (driver != NULL) ? XST_SUCCESS : PS_APP_INPUT_DRIVER_STATUS_UNSUPPORTED;
}

XStatus PsAppInput_QueueUsbAttach(PsAppInputContext *ctx,
                                  const PsAppInputUsbDeviceInfo *info,
                                  u8 *driver_id_out,
                                  u32 *host_init_policy_out) {
    return PsAppInput_QueueUsbAttachInternal(ctx,
                                             info,
                                             driver_id_out,
                                             host_init_policy_out,
                                             0U);
}

XStatus PsAppInput_OnUsbXInputAttached(PsAppInputContext *ctx,
                                       const PsAppInputUsbDeviceInfo *info) {
    XStatus status = PsAppInput_QueueUsbAttachInternal(ctx, info, NULL, NULL, 1U);
    return (status == PS_APP_INPUT_DRIVER_STATUS_UNSUPPORTED) ? XST_INVALID_PARAM : status;
}

XStatus PsAppInput_OnUsbDetachedGeneration(PsAppInputContext *ctx, u32 device_generation) {
    PsAppInputEvent event;
    TickType_t lock_wait;
    XStatus status;

    if ((ctx == NULL) || (PsAppInputDriver_IsGenerationValid(device_generation) == 0U) ||
        (ctx->event_queue == NULL) || (ctx->event_control_lock == NULL)) {
        return XST_INVALID_PARAM;
    }
    lock_wait = PsAppTime_MsToTicksCeil(PS_APP_INPUT_CONTROL_LOCK_WAIT_MS);
    if (xSemaphoreTake(ctx->event_control_lock, lock_wait) != pdTRUE) return XST_DEVICE_BUSY;
    if ((ctx->producer_generation != 0U) &&
        (PsAppInputDriver_IsReportGenerationCurrent(ctx->producer_generation,
                                                    device_generation) == 0U)) {
        (void)xSemaphoreGive(ctx->event_control_lock);
        return XST_SUCCESS; /* A newer attach already superseded this detach. */
    }
    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_DETACHED;
    event.device_generation = device_generation;
    status = PsAppInput_EnqueueEvent(ctx, &event, 1U);
    (void)xSemaphoreGive(ctx->event_control_lock);
    return status;
}

void PsAppInput_OnUsbDetached(PsAppInputContext *ctx) {
    PsAppInputEvent event;
    TickType_t lock_wait;
    u32 active_generation;
    u8 replace_pending;

    if ((ctx == NULL) || (ctx->event_queue == NULL) ||
        (ctx->event_control_lock == NULL)) {
        return;
    }
    lock_wait = PsAppTime_MsToTicksCeil(PS_APP_INPUT_CONTROL_LOCK_WAIT_MS);
    if (xSemaphoreTake(ctx->event_control_lock, lock_wait) != pdTRUE) return;

    /* Snapshot the active generation now; never bind this legacy detach later. */
    active_generation = ctx->active_device_generation;
    if (active_generation == 0U) {
        (void)xSemaphoreGive(ctx->event_control_lock);
        return;
    }

    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_DETACHED;
    event.device_generation = active_generation;

    /* Preserve a newer queued attach; otherwise detach may replace stale reports. */
    replace_pending = (u8)((ctx->producer_generation == 0U) ||
                           (PsAppInputDriver_IsNewerGeneration(
                                ctx->producer_generation, active_generation) == 0U));
    (void)PsAppInput_EnqueueEvent(ctx, &event, replace_pending);
    (void)xSemaphoreGive(ctx->event_control_lock);
}

XStatus PsAppInput_OnTransportReport(PsAppInputContext *ctx,
                                     u32 device_generation,
                                     const u8 *report,
                                     u32 report_len) {
    PsAppInputEvent event;

    if ((ctx == NULL) || (PsAppInputDriver_IsGenerationValid(device_generation) == 0U) ||
        (report == NULL) || (report_len == 0U) ||
        (report_len > PS_XINPUT_MAX_REPORT_BYTES)) return XST_INVALID_PARAM;
    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_REPORT;
    event.report_len = (u8)report_len;
    event.device_generation = device_generation;
    memcpy(event.data.report, report, report_len);
    return PsAppInput_EnqueueReportFromIsr(ctx, &event);
}

XStatus PsAppInput_OnInterruptInReport(PsAppInputContext *ctx,
                                       const u8 *report,
                                       u32 report_len) {
    PsAppInputEvent event;
    u32 active_generation;

    if ((ctx == NULL) || (report == NULL) || (report_len == 0U) ||
        (report_len > PS_XINPUT_MAX_REPORT_BYTES)) return XST_INVALID_PARAM;
    active_generation = ctx->active_device_generation;
    if (active_generation == 0U) return XST_INVALID_PARAM;
    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_REPORT;
    event.report_len = (u8)report_len;
    event.device_generation = active_generation;
    memcpy(event.data.report, report, report_len);
    return PsAppInput_EnqueueReportFromIsr(ctx, &event);
}

XStatus PsAppInput_InjectRawReport(PsAppInputContext *ctx,
                                   const u8 *report,
                                   u32 report_len) {
    PsAppInputEvent event;

    if ((ctx == NULL) || (report == NULL) || (report_len == 0U) ||
        (report_len > PS_XINPUT_MAX_REPORT_BYTES)) return XST_INVALID_PARAM;
    memset(&event, 0, sizeof(event));
    event.type = (u8)PS_APP_INPUT_EVENT_INJECT_REPORT;
    event.report_len = (u8)report_len;
    memcpy(event.data.report, report, report_len);
    return PsAppInput_EnqueueEvent(ctx, &event, 0U);
}

u8 PsAppInput_ShouldOverrideKeys(const PsAppInputContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return 0U;
    }
    if (ctx->state->enabled == 0U) {
        return 0U;
    }
    if ((ctx->state->active != 0U) || (ctx->state->release_pending != 0U)) {
        return 1U;
    }
    return 0U;
}

u8 PsAppInput_IsReleasePending(const PsAppInputContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return 0U;
    }
    return ctx->state->release_pending;
}

void PsAppInput_ClearReleasePending(PsAppInputContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }
    ctx->state->release_pending = 0U;
}

u32 PsAppInput_GetMappedKeys(const PsAppInputContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return 0U;
    }
    return (ctx->state->mapped_keys & PS_APP_GBA_KEY_MASK_ALL);
}

XStatus PsAppInput_BuildRumbleReportForDriver(u8 driver_id,
                                              const PsAppInputUsbDeviceInfo *device,
                                              u8 large_motor,
                                              u8 small_motor,
                                              u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]) {
    const PsAppInputDriver *driver = PsAppInputDriver_GetById((PsAppInputDriverId)driver_id);
    if (out_report == NULL) return XST_INVALID_PARAM;
    memset(out_report, 0, PS_XINPUT_REPORT_SIZE_OUTPUT);
    if ((driver == NULL) || (driver->ops == NULL) || (driver->ops->build_output == NULL)) {
        return XST_FAILURE;
    }
    driver->ops->build_output(device, large_motor, small_motor, out_report);
    return XST_SUCCESS;
}

void PsAppInput_BuildRumbleReport(u8 large_motor,
                                  u8 small_motor,
                                  u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]) {
    (void)PsAppInput_BuildRumbleReportForDriver((u8)PS_APP_INPUT_DRIVER_ID_GENERIC_XINPUT,
                                                NULL,
                                                large_motor,
                                                small_motor,
                                                out_report);
}

void PsAppInput_PrintStatus(const PsAppInputContext *ctx) {
    const PsAppInputState *state;
    u8 driver_id;
    u32 idx;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        xil_printf("[INPUT] status unavailable\r\n");
        return;
    }

    state = ctx->state;
    driver_id = (ctx->active_driver != NULL) ?
                (u8)ctx->active_driver->id :
                (u8)PS_APP_INPUT_DRIVER_ID_NONE;
    xil_printf("[INPUT] en=%u active=%u rel=%u valid=%u proto=%u out=%u driver=%u gen=%u stale=%u queue_overflow=%u queue_reset=%u\r\n",
               (unsigned int)state->enabled,
               (unsigned int)state->active,
               (unsigned int)state->release_pending,
               (unsigned int)state->report_valid,
               (unsigned int)state->protocol_is_xinput,
               (unsigned int)state->output_capable,
               (unsigned int)driver_id,
               (unsigned int)state->device_generation,
               (unsigned int)state->stale_report_count,
               (unsigned int)state->event_queue_overflow_count,
               (unsigned int)state->event_queue_reset_count);
    xil_printf("[INPUT] vid=0x%04x pid=0x%04x intf=%u class=%02x/%02x/%02x ep_in=0x%02x@%ums ep_out=0x%02x@%ums\r\n",
               (unsigned int)state->vendor_id,
               (unsigned int)state->product_id,
               (unsigned int)state->interface_number,
               (unsigned int)state->interface_class,
               (unsigned int)state->interface_subclass,
               (unsigned int)state->interface_protocol,
               (unsigned int)state->ep_in_addr,
               (unsigned int)state->ep_in_interval_ms,
               (unsigned int)state->ep_out_addr,
               (unsigned int)state->ep_out_interval_ms);
    xil_printf("[INPUT] reports=%u parse_err=%u unsupported=%u raw=0x%03x src_nonstick=0x%08x deb_nonstick=0x%03x mapped=0x%03x committed=0x%03x btn=0x%04x lt=%u rt=%u lx=%d ly=%d rx=%d ry=%d\r\n",
               (unsigned int)state->report_count,
               (unsigned int)state->parse_error_count,
               (unsigned int)state->unsupported_report_count,
               (unsigned int)(state->raw_mapped_keys & PS_APP_GBA_KEY_MASK_ALL),
               (unsigned int)(state->pending_mapped_keys & PS_APP_INPUT_NONSTICK_SOURCE_MASK),
               (unsigned int)(state->debounced_nonstick_keys & PS_APP_GBA_KEY_MASK_ALL),
               (unsigned int)(state->mapped_keys & 0x3FFU),
               (unsigned int)(state->last_committed_keys & 0x3FFU),
               (unsigned int)state->buttons,
               (unsigned int)state->lt,
               (unsigned int)state->rt,
               (int)state->lx,
               (int)state->ly,
               (int)state->rx,
               (int)state->ry);
    if (PsAppInput_ShouldSwapAbByPosition(ctx) != 0U) {
        xil_printf("[INPUT] map=A<=B(right) B<=A(bottom) deadzone=%d trigger_th=%u\r\n",
                   (int)PS_APP_INPUT_LSTICK_DEADZONE,
                   (unsigned int)PS_APP_INPUT_TRIGGER_THRESHOLD);
    } else {
        xil_printf("[INPUT] map=A<=A(bottom) B<=B(right) deadzone=%d trigger_th=%u\r\n",
                   (int)PS_APP_INPUT_LSTICK_DEADZONE,
                   (unsigned int)PS_APP_INPUT_TRIGGER_THRESHOLD);
    }

    if (state->last_report_len != 0U) {
        xil_printf("[INPUT] last_report(%u)=", (unsigned int)state->last_report_len);
        for (idx = 0U; idx < (u32)state->last_report_len; ++idx) {
            xil_printf("%s%02x",
                       (idx == 0U) ? "" : " ",
                       (unsigned int)state->last_report[idx]);
        }
        xil_printf("\r\n");
    }
}

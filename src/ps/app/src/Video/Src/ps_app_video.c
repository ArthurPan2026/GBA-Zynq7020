#include "Video/Inc/ps_app_video.h"

#include <string.h>
#include "Common/Inc/ps_app_time.h"

#include "FreeRTOS.h"
#include "portmacro.h"
#include "task.h"
#include "semphr.h"
#include "xaxivdma_hw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "xinterrupt_wrap.h"
#include "xparameters.h"

#include "Gba/Inc/ps_gba_regs.h"
#include "ps_pl_contract_generated.h"
#include "Vdma/Inc/ps_hdmi_vdma.h"

#if defined(XPAR_ZYNQ_GBA_SYSTEM_FB_CAP_BRAM_CTRL_0_S_AXI_BASEADDR)
#define PS_APP_FB_CAP_BRAM_BASE_ADDR XPAR_ZYNQ_GBA_SYSTEM_FB_CAP_BRAM_CTRL_0_S_AXI_BASEADDR
#elif defined(XPAR_FB_CAP_BRAM_CTRL_0_S_AXI_BASEADDR)
#define PS_APP_FB_CAP_BRAM_BASE_ADDR XPAR_FB_CAP_BRAM_CTRL_0_S_AXI_BASEADDR
#else
#define PS_APP_FB_CAP_BRAM_BASE_ADDR 0x44000000U
#endif

#if defined(XPAR_XAXIVDMA_0_INTERRUPTS) && defined(XPAR_XAXIVDMA_0_INTERRUPT_PARENT)
#define PS_APP_VDMA_READ_INTR_ID XPAR_XAXIVDMA_0_INTERRUPTS
#define PS_APP_VDMA_READ_INTR_PARENT XPAR_XAXIVDMA_0_INTERRUPT_PARENT
#elif defined(XPAR_HDMI_VDMA_INTERRUPTS) && defined(XPAR_HDMI_VDMA_INTERRUPT_PARENT)
#define PS_APP_VDMA_READ_INTR_ID XPAR_HDMI_VDMA_INTERRUPTS
#define PS_APP_VDMA_READ_INTR_PARENT XPAR_HDMI_VDMA_INTERRUPT_PARENT
#else
#define PS_APP_VDMA_READ_INTR_ID 0U
#define PS_APP_VDMA_READ_INTR_PARENT 0U
#endif

/*
 * HDMI 这里使用的是 MM2S 持续显示链路。
 * 该场景下必须保持 circular/parking 语义，不能再把 READ 通道切到
 * FrameCounter 模式，否则 VDMA 会在固定帧数后自动 halted，最终黑屏。
 * 因此这里只保留 error interrupt，用于故障检测；显示推进仍由现有
 * VSYNC/服务循环驱动。
 */
#define PS_APP_VDMA_READ_IRQ_MASK XAXIVDMA_IXR_ERROR_MASK

static u16 s_ps_app_video_capture_shadow[PS_APP_GBA_FRAME_WIDTH * PS_APP_GBA_FRAME_HEIGHT];
/* One converted source row is reused for the 2-3 scaled output rows. */
static u32 s_ps_app_video_converted_source_row[PS_APP_GBA_FRAME_WIDTH];
static u16 s_ps_app_video_scale_x_lut[PS_APP_HDMI_WIDTH];
static u16 s_ps_app_video_scale_y_lut[PS_APP_HDMI_HEIGHT];
static u32 s_ps_app_video_scale_lut_width = 0U;
static u32 s_ps_app_video_scale_lut_height = 0U;
/* The HDMI viewport letterboxes 3:2 GBA pixels inside a 4:3 frame.
 * Clear each rotating frame store once per ROM generation so the unused
 * bands cannot retain the LVGL load/menu pixels. */
static u32 s_ps_app_video_frame_clear_generation[8];
static u32 s_ps_app_video_blit_fail_log_count = 0U;
static u32 s_ps_app_video_stale_seq_ticks = 0U;
static u32 s_ps_app_video_stale_seq_log_count = 0U;
static const u32 PS_APP_VIDEO_STALE_SEQ_FORCE_BLIT_TICKS = 16U;
static SemaphoreHandle_t s_ps_app_video_vdma_owner_lock;

static XStatus PsAppVideo_InitInterruptsLocked(PsAppVideoContext *ctx);
static XStatus PsAppVideo_RequestFrameLocked(PsAppVideoContext *ctx, u32 frame_idx);
static void PsAppVideo_AttemptRecoverLocked(PsAppVideoContext *ctx,
                                             u32 vdma_status,
                                             u32 vdma_errs);
static void PsAppVideo_SyncDisplayFrameLocked(PsAppVideoContext *ctx);
static XStatus PsAppVideo_RenderBootFramesLocked(PsAppVideoContext *ctx);
static XStatus PsAppVideo_FillAllFramesLocked(PsAppVideoContext *ctx,
                                               u32 color_xrgb8888);

static u8 PsAppVideo_IsCoreContextValid(const PsAppVideoContext *ctx) {
    if ((ctx == NULL) || (ctx->vdma == NULL) || (ctx->regs == NULL) || (ctx->state == NULL)) {
        return 0U;
    }
    return 1U;
}

static u8 PsAppVideo_IsPresentContextValid(const PsAppVideoContext *ctx) {
    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (ctx->rom == NULL)) {
        return 0U;
    }
    return 1U;
}

static XStatus PsAppVideo_EnsureVdmaOwnerLock(void) {
    if (s_ps_app_video_vdma_owner_lock != NULL) return XST_SUCCESS;
    if (xTaskGetSchedulerState() != taskSCHEDULER_RUNNING) return XST_FAILURE;
    s_ps_app_video_vdma_owner_lock = xSemaphoreCreateMutex();
    return (s_ps_app_video_vdma_owner_lock != NULL) ? XST_SUCCESS : XST_FAILURE;
}

static XStatus PsAppVideo_TakeVdmaOwnerLock(void) {
    TickType_t wait_ticks;
    if (PsAppVideo_EnsureVdmaOwnerLock() != XST_SUCCESS) return XST_FAILURE;
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_VIDEO_OWNER_WAIT_MS);
    return (xSemaphoreTake(s_ps_app_video_vdma_owner_lock, wait_ticks) == pdTRUE) ?
           XST_SUCCESS : XST_TIMEOUT;
}

static void PsAppVideo_GiveVdmaOwnerLock(void) {
    if (s_ps_app_video_vdma_owner_lock != NULL) {
        (void)xSemaphoreGive(s_ps_app_video_vdma_owner_lock);
    }
}

static void PsAppVideo_UpdateDisplayFrameState(PsAppVideoContext *ctx) {
    u32 frame_idx;

    if ((ctx == NULL) || (ctx->vdma->is_ready == 0U)) {
        return;
    }

    frame_idx = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    if (frame_idx >= ctx->vdma->frame_count) {
        frame_idx = 0U;
    }

    if ((ctx->state->pending_frame_idx >= ctx->vdma->frame_count) ||
        (ctx->state->pending_frame_idx == (u8)frame_idx)) {
        ctx->state->pending_frame_idx = (u8)frame_idx;
    }

    if (ctx->state->display_frame_idx != (u8)frame_idx) {
        /* 0xFF is the uninitialized sentinel, not a real frame-store transition. */
        if (ctx->state->display_frame_idx < ctx->vdma->frame_count) {
            ctx->state->display_frame_change_count++;
        }
        ctx->state->display_frame_idx = (u8)frame_idx;
        PsGbaRegs_SetDisplayFrameIdx(ctx->regs, frame_idx);
    }
}

static void PsAppVideo_VdmaGeneralCallback(void *ref, u32 intr_mask) {
    PsAppVideoContext *ctx = (PsAppVideoContext *)ref;

    if (ctx == NULL) {
        return;
    }

    ctx->state->vdma_last_intr_mask = intr_mask;
    ctx->state->vdma_irq_count++;
    ctx->state->vdma_frame_update_pending = 1U;
}

static void PsAppVideo_VdmaErrorCallback(void *ref, u32 err_mask) {
    PsAppVideoContext *ctx = (PsAppVideoContext *)ref;

    if (ctx == NULL) {
        return;
    }

    ctx->state->vdma_last_err_mask = err_mask;
    ctx->state->vdma_err_count++;
}

static UINTPTR PsAppVideo_CaptureBufferBaseAddr(u32 buf_idx) {
    return (UINTPTR)(PS_APP_FB_CAP_BRAM_BASE_ADDR +
                     ((buf_idx & 0x1U) * PS_APP_GBA_FB_CAPTURE_FRAME_BYTES));
}

static u32 PsAppVideo_ResolveBackbufferFrame(u32 display_frame_idx) {
    switch (display_frame_idx % 3U) {
        case 0U:
            return 2U;
        case 1U:
            return 0U;
        default:
            return 1U;
    }
}

static u32 PsAppVideo_SelectSafeFrame(PsAppVideoContext *ctx, u32 current_frame) {
    u32 preferred_frame;
    u32 idx;

    if ((ctx == NULL) || (ctx->vdma->frame_count == 0U)) {
        return 0U;
    }

    preferred_frame = PsAppVideo_ResolveBackbufferFrame(current_frame);
    if ((preferred_frame < ctx->vdma->frame_count) &&
        (preferred_frame != current_frame) &&
        ((ctx->state->pending_frame_idx >= ctx->vdma->frame_count) ||
         (ctx->state->pending_frame_idx == current_frame) ||
         (preferred_frame != ctx->state->pending_frame_idx))) {
        return preferred_frame;
    }

    for (idx = 0U; idx < ctx->vdma->frame_count; ++idx) {
        if (idx == current_frame) {
            continue;
        }
        if ((ctx->state->pending_frame_idx < ctx->vdma->frame_count) &&
            (ctx->state->pending_frame_idx != current_frame) &&
            (idx == ctx->state->pending_frame_idx)) {
            continue;
        }
        return idx;
    }

    return current_frame;
}

static void PsAppVideo_LoadCaptureShadowFromBram(u32 buf_idx) {
    volatile const u32 *src_words;
    u32 word_idx;
    u32 pixel_idx;

    src_words = (volatile const u32 *)(PS_APP_FB_CAP_BRAM_BASE_ADDR +
                                       ((buf_idx & 0x1U) * PS_APP_GBA_FB_CAPTURE_FRAME_BYTES));
    pixel_idx = 0U;
    for (word_idx = 0U; word_idx < PS_APP_GBA_FB_CAPTURE_WORDS; ++word_idx) {
        u32 packed = src_words[word_idx];
        s_ps_app_video_capture_shadow[pixel_idx++] = (u16)(packed & 0xFFFFU);
        s_ps_app_video_capture_shadow[pixel_idx++] = (u16)((packed >> 16) & 0xFFFFU);
    }
}

static u32 PsAppVideo_ComputeShadowSparseHash(void) {
    const u32 sample_count = 64U;
    const u32 pixel_count = PS_APP_GBA_FRAME_WIDTH * PS_APP_GBA_FRAME_HEIGHT;
    const u32 step = pixel_count / sample_count;
    u32 sample;
    u32 hash = 2166136261U;

    for (sample = 0U; sample < sample_count; ++sample) {
        hash ^= s_ps_app_video_capture_shadow[sample * step];
        hash *= 16777619U;
    }
    return hash;
}

static void PsAppVideo_UpdateScaleLut(u32 dst_w, u32 dst_h) {
    u32 dst_px;
    u32 dst_py;

    if (dst_w > PS_APP_HDMI_WIDTH) {
        dst_w = PS_APP_HDMI_WIDTH;
    }
    if (dst_h > PS_APP_HDMI_HEIGHT) {
        dst_h = PS_APP_HDMI_HEIGHT;
    }
    if ((dst_w == s_ps_app_video_scale_lut_width) && (dst_h == s_ps_app_video_scale_lut_height)) {
        return;
    }

    for (dst_px = 0U; dst_px < dst_w; ++dst_px) {
        u32 src_x = (dst_px * PS_APP_GBA_FRAME_WIDTH) / dst_w;
        if (src_x >= PS_APP_GBA_FRAME_WIDTH) {
            src_x = PS_APP_GBA_FRAME_WIDTH - 1U;
        }
        s_ps_app_video_scale_x_lut[dst_px] = (u16)src_x;
    }

    for (dst_py = 0U; dst_py < dst_h; ++dst_py) {
        u32 src_y = (dst_py * PS_APP_GBA_FRAME_HEIGHT) / dst_h;
        if (src_y >= PS_APP_GBA_FRAME_HEIGHT) {
            src_y = PS_APP_GBA_FRAME_HEIGHT - 1U;
        }
        s_ps_app_video_scale_y_lut[dst_py] = (u16)src_y;
    }

    s_ps_app_video_scale_lut_width = dst_w;
    s_ps_app_video_scale_lut_height = dst_h;
}

static u32 PsAppVideo_TicksToUs(u64 ticks) {
#if defined(COUNTS_PER_SECOND) && (COUNTS_PER_SECOND != 0)
    u64 scaled = (ticks * 1000000ULL) + ((u64)COUNTS_PER_SECOND / 2ULL);
    return (u32)(scaled / (u64)COUNTS_PER_SECOND);
#else
    return (u32)ticks;
#endif
}

static void PsAppVideo_UpdateBlitStats(PsAppVideoContext *ctx,
                                       u32 prev_frame_seq,
                                       u32 frame_seq,
                                       u32 blit_us) {
    u32 seq_gap;

    if (ctx == NULL) {
        return;
    }

    if (ctx->state->blit_count < 0xFFFFFFFFU) {
        ctx->state->blit_count++;
    }
    ctx->state->blit_last_us = blit_us;
    if (blit_us > ctx->state->blit_max_us) {
        ctx->state->blit_max_us = blit_us;
    }
    if ((0xFFFFFFFFU - ctx->state->blit_total_us) < blit_us) {
        ctx->state->blit_total_us = 0xFFFFFFFFU;
    } else {
        ctx->state->blit_total_us += blit_us;
    }

    if ((prev_frame_seq != 0U) && (frame_seq > prev_frame_seq)) {
        seq_gap = frame_seq - prev_frame_seq;
        if (seq_gap > ctx->state->blit_seq_gap_max) {
            ctx->state->blit_seq_gap_max = seq_gap;
        }
    }
}

static XStatus PsAppVideo_BlitCapturedFrameToHdmi(PsAppVideoContext *ctx,
                                                   const PsGbaFrameSnapshot *before) {
    u32 current_frame;
    u32 target_frame;
    u32 *fb32;
    u32 prev_frame_seq;
    u32 dst_x;
    u32 dst_y;
    u32 dst_w;
    u32 dst_h;
    u32 dst_py;
    u32 cached_src_y;
    XTime tick_begin;
    XTime tick_end;
    UINTPTR flush_base_addr;
    u32 flush_bytes;
    u32 frame_seq;
    u32 buf_idx;
    u32 bank;
    u32 rom_generation;
    PsGbaFrameSnapshot after;
    u32 after_seq;
    u32 shadow_hash;

    if ((ctx == NULL) || (before == NULL) || (ctx->rom == NULL) ||
        (ctx->vdma->is_ready == 0U)) {
        return XST_FAILURE;
    }

    if (((before->status & GBA_FRAME_STATUS_VALID) == 0U) ||
        ((before->status & GBA_FRAME_STATUS_ERROR) != 0U)) {
        return XST_FAILURE;
    }
    bank = ((before->status & GBA_FRAME_STATUS_PUBLISHED_BANK1) != 0U) ? 1U : 0U;
    if (((bank == 0U) && ((before->status & GBA_FRAME_STATUS_BANK0_WRITING) != 0U)) ||
        ((bank == 1U) && ((before->status & GBA_FRAME_STATUS_BANK1_WRITING) != 0U))) {
        return XST_FAILURE;
    }
    frame_seq = before->sequence;
    buf_idx = bank;
    rom_generation = ctx->rom->generation;

    XTime_GetTime(&tick_begin);
    prev_frame_seq = ctx->state->fbcap_last_frame_seq;

    current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    if (current_frame >= ctx->vdma->frame_count) {
        current_frame = 0U;
    }

    target_frame = PsAppVideo_SelectSafeFrame(ctx, current_frame);
    if (target_frame >= ctx->vdma->frame_count) {
        target_frame = 0U;
    }

    fb32 = (u32 *)ctx->vdma->frame_addrs[target_frame];
    PsAppVideo_ComputeDisplayWindow(ctx, &dst_x, &dst_y, &dst_w, &dst_h);
    if ((dst_w == 0U) || (dst_h == 0U)) {
        return XST_FAILURE;
    }

    if (target_frame >= 8U) {
        return XST_FAILURE;
    }
    if (s_ps_app_video_frame_clear_generation[target_frame] != rom_generation) {
        XStatus clear_status = PsHdmiVdma_FillFrame(ctx->vdma,
                                                    target_frame,
                                                    0x00000000U);
        if (clear_status != XST_SUCCESS) {
            return clear_status;
        }
        s_ps_app_video_frame_clear_generation[target_frame] = rom_generation;
    }

    PsAppVideo_LoadCaptureShadowFromBram(buf_idx);
    ctx->frame_snapshot_request_sequence++;
    if (ctx->frame_snapshot_request_sequence == 0U) {
        ctx->frame_snapshot_request_sequence = 1U;
    }
    after_seq = ctx->frame_snapshot_request_sequence;
    if (PsGbaRegs_ReadFrameSnapshot(ctx->regs,
                                    after_seq,
                                    PS_APP_VIDEO_FRAME_SNAPSHOT_TIMEOUT_MS,
                                    &after) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    {
        u32 writer_mask = (bank == 0U) ? GBA_FRAME_STATUS_BANK0_WRITING : GBA_FRAME_STATUS_BANK1_WRITING;
        if (((after.status & GBA_FRAME_STATUS_VALID) == 0U) ||
            ((after.status & GBA_FRAME_STATUS_ERROR) != 0U) ||
            (after.bank_generation[bank] != before->bank_generation[bank]) ||
            (after.rom_epoch != before->rom_epoch) ||
            ((after.status & writer_mask) != 0U)) {
            return XST_FAILURE;
        }
    }
    PsAppVideo_UpdateScaleLut(dst_w, dst_h);
    cached_src_y = 0xFFFFFFFFU;

    for (dst_py = 0U; dst_py < dst_h; ++dst_py) {
        UINTPTR line_base =
            (UINTPTR)fb32 +
            (((dst_y + dst_py) * ctx->vdma->line_stride_bytes) + (dst_x * sizeof(u32)));
        u32 *line_ptr = (u32 *)line_base;
        u32 src_y = s_ps_app_video_scale_y_lut[dst_py];
        u32 dst_px;

        if (src_y != cached_src_y) {
            const u16 *src_row = &s_ps_app_video_capture_shadow[src_y * PS_APP_GBA_FRAME_WIDTH];
            u32 src_x;

            for (src_x = 0U; src_x < PS_APP_GBA_FRAME_WIDTH; ++src_x) {
                s_ps_app_video_converted_source_row[src_x] =
                    PsAppVideo_ConvertRgb565ToXrgb8888(src_row[src_x]);
            }
            cached_src_y = src_y;
        }

        for (dst_px = 0U; dst_px < dst_w; ++dst_px) {
            line_ptr[dst_px] =
                s_ps_app_video_converted_source_row[s_ps_app_video_scale_x_lut[dst_px]];
        }
    }


    flush_base_addr = (UINTPTR)fb32 +
                      ((dst_y * ctx->vdma->line_stride_bytes) + (dst_x * sizeof(u32)));
    flush_bytes = ((dst_h - 1U) * ctx->vdma->line_stride_bytes) + (dst_w * sizeof(u32));
    Xil_DCacheFlushRange((INTPTR)flush_base_addr, (INTPTR)flush_bytes);

    /* Reject a shadow frame if a ROM switch began while scaling was in progress. */
    if ((ctx->rom->is_loading != 0U) ||
        (ctx->rom->generation != rom_generation)) {
        return XST_FAILURE;
    }
    if (PsAppVideo_RequestFrameLocked(ctx, target_frame) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XTime_GetTime(&tick_end);
    shadow_hash = PsAppVideo_ComputeShadowSparseHash();
    if (ctx->state->blit_shadow_hash_valid != 0U) {
        if ((shadow_hash != ctx->state->blit_shadow_hash_last) &&
            (ctx->state->blit_shadow_hash_change_count < 0xFFFFFFFFU)) {
            ctx->state->blit_shadow_hash_change_count++;
        }
    } else {
        ctx->state->blit_shadow_hash_valid = 1U;
    }
    ctx->state->blit_shadow_hash_last = shadow_hash;
    PsAppVideo_UpdateBlitStats(ctx,
                               prev_frame_seq,
                               frame_seq,
                               PsAppVideo_TicksToUs((u64)(tick_end - tick_begin)));
    ctx->state->fbcap_last_frame_seq = frame_seq;
    ctx->state->fbcap_last_buf_idx = (u8)(buf_idx & 0x1U);
    ctx->state->fbcap_last_frame_idx = (u8)target_frame;
    return XST_SUCCESS;
}

static XStatus PsAppVideo_InitInterruptsLocked(PsAppVideoContext *ctx) {
    XStatus status;

    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (ctx->vdma->is_ready == 0U)) {
        return XST_FAILURE;
    }

    if ((PS_APP_VDMA_READ_INTR_ID == 0U) || (PS_APP_VDMA_READ_INTR_PARENT == 0U)) {
        return XST_FAILURE;
    }

    ctx->state->vdma_irq_count = 0U;
    ctx->state->vdma_err_count = 0U;
    ctx->state->vdma_last_intr_mask = 0U;
    ctx->state->vdma_last_err_mask = 0U;

    XAxiVdma_IntrDisable(&ctx->vdma->vdma, XAXIVDMA_IXR_ALL_MASK, XAXIVDMA_READ);
    XAxiVdma_IntrClear(&ctx->vdma->vdma, XAXIVDMA_IXR_ALL_MASK, XAXIVDMA_READ);

    /*
     * 这里仍然注册 general callback，是因为官方驱动的 ReadIntrHandler()
     * 会先检查 CompletionCallBack 是否为空；若为空会直接 return，连
     * error callback 也不会继续分发。
     * 但我们不会打开 FRMCNT/DELAY completion 中断，只让它作为驱动入口
     * 的占位回调存在。
     */
    status = XAxiVdma_SetCallBack(&ctx->vdma->vdma,
                                  XAXIVDMA_HANDLER_GENERAL,
                                  (void *)PsAppVideo_VdmaGeneralCallback,
                                  (void *)ctx,
                                  XAXIVDMA_READ);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = XAxiVdma_SetCallBack(&ctx->vdma->vdma,
                                  XAXIVDMA_HANDLER_ERROR,
                                  (void *)PsAppVideo_VdmaErrorCallback,
                                  (void *)ctx,
                                  XAXIVDMA_READ);
    if (status != XST_SUCCESS) {
        return status;
    }

    /*
     * 不调用 XAxiVdma_SetFrameCounter() / XAxiVdma_StartFrmCntEnable()。
     * 它们对应的是 frame-count 传输语义，适合测试/计数型中断示例，
     * 不适合当前 HDMI MM2S 持续输出。
     */
    status = XSetupInterruptSystem(&ctx->vdma->vdma,
                                   (void *)XAxiVdma_ReadIntrHandler,
                                   PS_APP_VDMA_READ_INTR_ID,
                                   PS_APP_VDMA_READ_INTR_PARENT,
                                   XINTERRUPT_DEFAULT_PRIORITY);
    if (status != XST_SUCCESS) {
        return status;
    }

    XAxiVdma_IntrClear(&ctx->vdma->vdma, XAXIVDMA_IXR_ALL_MASK, XAXIVDMA_READ);
    XAxiVdma_IntrEnable(&ctx->vdma->vdma, PS_APP_VDMA_READ_IRQ_MASK, XAXIVDMA_READ);
    PsAppVideo_UpdateDisplayFrameState(ctx);
    xil_printf("[VDMA] interrupt mode: read error irq enabled\r\n");
    return XST_SUCCESS;
}

XStatus PsAppVideo_InitDisplay(PsAppVideoContext *ctx,
                               u32 vdma_base_addr,
                               UINTPTR video_core_register_base,
                               UINTPTR frame0_addr,
                               u32 frame_stride_bytes,
                               u32 width,
                               u32 height,
                               u32 bytes_per_pixel) {
    XStatus status;

    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) return XST_INVALID_PARAM;
    status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsHdmiVdma_Init(ctx->vdma,
                             vdma_base_addr,
                             video_core_register_base,
                             frame0_addr,
                             frame_stride_bytes,
                             width,
                             height,
                             bytes_per_pixel);
    if (status == XST_SUCCESS) {
        status = PsAppVideo_InitInterruptsLocked(ctx);
    }
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

XStatus PsAppVideo_InitInterrupts(PsAppVideoContext *ctx) {
    XStatus status;

    status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsAppVideo_InitInterruptsLocked(ctx);
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

static XStatus PsAppVideo_RequestFrameLocked(PsAppVideoContext *ctx, u32 frame_idx) {
    BaseType_t use_critical;
    XStatus status;
    u32 current_frame;
    u32 requested_frame;
    u32 park_pointer;
    u32 vdma_control;
    u32 vdma_status;
    u32 rollback_frame;

    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (ctx->vdma->is_ready == 0U)) {
        return XST_FAILURE;
    }

    if (frame_idx >= ctx->vdma->frame_count) {
        frame_idx = 0U;
    }

    vdma_status = XAxiVdma_GetStatus(&ctx->vdma->vdma, XAXIVDMA_READ);
    vdma_control = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr + XAXIVDMA_TX_OFFSET,
                                     XAXIVDMA_CR_OFFSET);
    park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr,
                                    XAXIVDMA_PARKPTR_OFFSET);
    requested_frame = park_pointer & XAXIVDMA_PARKPTR_READREF_MASK;
    current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    if (current_frame >= ctx->vdma->frame_count) {
        current_frame = 0U;
    }

    /*
     * PARKPTR contains two independent values: the requested read frame in
     * bits [4:0] and the frame currently being read in bits [20:16].  The
     * current-frame value can equal the requested frame while an older park
     * request is still pending.  Do not return early in that state: rewrite
     * the request so a stale target cannot switch the display later.
     */
    if (((vdma_status & XAXIVDMA_SR_HALTED_MASK) == 0U) &&
        ((vdma_control & XAXIVDMA_CR_RUNSTOP_MASK) != 0U) &&
        ((vdma_control & XAXIVDMA_CR_TAIL_EN_MASK) == 0U) &&
        (requested_frame == frame_idx) &&
        (current_frame == frame_idx)) {
        ctx->state->pending_frame_idx = (u8)frame_idx;
        return XST_SUCCESS;
    }

    use_critical = (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) ? pdTRUE : pdFALSE;
    if (use_critical != pdFALSE) {
        taskENTER_CRITICAL();
    }

    status = PsHdmiVdma_Park(ctx->vdma, frame_idx);
    park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr,
                                    XAXIVDMA_PARKPTR_OFFSET);
    requested_frame = park_pointer & XAXIVDMA_PARKPTR_READREF_MASK;
    if ((status == XST_SUCCESS) && (requested_frame != frame_idx)) {
        /* The driver writes PARKPTR before changing the channel mode.  Treat
         * a failed readback as a failed request instead of publishing a stale
         * pending frame index to the UI. */
        status = XST_FAILURE;
        xil_printf("[VDMA] park target readback mismatch: want=%u got=%u park=0x%08x\r\n",
                   (unsigned int)frame_idx,
                   (unsigned int)requested_frame,
                   (unsigned int)park_pointer);
    }
    if (status != XST_SUCCESS) {
        vdma_status = XAxiVdma_GetStatus(&ctx->vdma->vdma, XAXIVDMA_READ);
        vdma_control = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr + XAXIVDMA_TX_OFFSET,
                                         XAXIVDMA_CR_OFFSET);
        park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr,
                                        XAXIVDMA_PARKPTR_OFFSET);
        requested_frame = park_pointer & XAXIVDMA_PARKPTR_READREF_MASK;
        current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
        if (current_frame >= ctx->vdma->frame_count) {
            current_frame = 0U;
        }
        if (((vdma_status & XAXIVDMA_SR_HALTED_MASK) == 0U) &&
            ((vdma_control & XAXIVDMA_CR_RUNSTOP_MASK) != 0U) &&
            ((vdma_control & XAXIVDMA_CR_TAIL_EN_MASK) == 0U) &&
            (requested_frame == frame_idx) &&
            (current_frame == frame_idx)) {
            status = XST_SUCCESS;
        } else {
            /*
             * XAxiVdma_StartParking() writes PARKPTR before it asks the
             * channel to enter parking mode.  If that second step fails, the
             * write can survive even though the request is reported failed.
             * Restore the observed current frame instead of the old requested
             * value: the old value may itself be the stale target we are
             * trying to remove.
             */
            rollback_frame = current_frame;
            park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr,
                                            XAXIVDMA_PARKPTR_OFFSET);
            park_pointer &= ~XAXIVDMA_PARKPTR_READREF_MASK;
            park_pointer |= rollback_frame & XAXIVDMA_PARKPTR_READREF_MASK;
            XAxiVdma_WriteReg(ctx->vdma->vdma.BaseAddr,
                              XAXIVDMA_PARKPTR_OFFSET,
                              park_pointer);
            park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr,
                                            XAXIVDMA_PARKPTR_OFFSET);
            requested_frame = park_pointer & XAXIVDMA_PARKPTR_READREF_MASK;
            if (requested_frame != rollback_frame) {
                xil_printf("[VDMA] park rollback readback mismatch: want=%u got=%u park=0x%08x\r\n",
                           (unsigned int)rollback_frame,
                           (unsigned int)requested_frame,
                           (unsigned int)park_pointer);
            }
        }
    }
    if (status == XST_SUCCESS) {
        ctx->state->pending_frame_idx = (u8)frame_idx;
    }

    if (use_critical != pdFALSE) {
        taskEXIT_CRITICAL();
    }

    return status;
}

XStatus PsAppVideo_RequestFrame(PsAppVideoContext *ctx, u32 frame_idx) {
    XStatus status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsAppVideo_RequestFrameLocked(ctx, frame_idx);
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

static void PsAppVideo_AttemptRecoverLocked(PsAppVideoContext *ctx,
                                             u32 vdma_status,
                                             u32 vdma_errs) {
    u32 is_halted;

    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) {
        return;
    }

    is_halted = (vdma_status & XAXIVDMA_SR_HALTED_MASK) ? 1U : 0U;
    if ((vdma_errs == 0U) && (is_halted == 0U)) {
        return;
    }

    xil_printf("[VDMA] recover: sr=0x%08x err=0x%03x halted=%u\r\n",
               (unsigned int)vdma_status,
               (unsigned int)vdma_errs,
               (unsigned int)is_halted);

    if (vdma_errs != 0U) {
        (void)XAxiVdma_ClearDmaChannelErrors(&ctx->vdma->vdma, XAXIVDMA_READ, vdma_errs);
    }

    if (is_halted != 0U) {
        /*
         * 恢复时只重新启动连续输出通道，不要重新打开 FrameCounter。
         * 之前黑屏的根因就是在 recover 路径里把 FRMCNT_EN 重新拉起，
         * 导致 VDMA 反复“启动后又按固定帧数停机”。
         */
        (void)XAxiVdma_DmaStart(&ctx->vdma->vdma, XAXIVDMA_READ);
    }

    (void)PsAppVideo_RequestFrameLocked(ctx, 0U);
    /* 恢复后重新打开 error irq，继续监控真实的 DMA 故障。 */
    XAxiVdma_IntrClear(&ctx->vdma->vdma, XAXIVDMA_IXR_ALL_MASK, XAXIVDMA_READ);
    XAxiVdma_IntrEnable(&ctx->vdma->vdma, PS_APP_VDMA_READ_IRQ_MASK, XAXIVDMA_READ);
    PsAppVideo_UpdateDisplayFrameState(ctx);
}

void PsAppVideo_AttemptRecover(PsAppVideoContext *ctx, u32 vdma_status, u32 vdma_errs) {
    if (PsAppVideo_TakeVdmaOwnerLock() != XST_SUCCESS) return;
    PsAppVideo_AttemptRecoverLocked(ctx, vdma_status, vdma_errs);
    PsAppVideo_GiveVdmaOwnerLock();
}

static void PsAppVideo_SyncDisplayFrameLocked(PsAppVideoContext *ctx) {
    PsAppVideo_UpdateDisplayFrameState(ctx);
    if ((ctx != NULL) && (ctx->state != NULL)) ctx->state->vdma_frame_update_pending = 0U;
}

void PsAppVideo_SyncDisplayFrame(PsAppVideoContext *ctx) {
    if (PsAppVideo_TakeVdmaOwnerLock() != XST_SUCCESS) return;
    PsAppVideo_SyncDisplayFrameLocked(ctx);
    PsAppVideo_GiveVdmaOwnerLock();
}

XStatus PsAppVideo_BeginUiFrameUpdate(PsAppVideoContext *ctx,
                                      PsAppVideoUiFrameUpdate *update) {
    XStatus status;
    UINTPTR source_addr;
    UINTPTR target_addr;
    u32 current_frame;
    u32 target_frame;

    if (update == NULL) {
        return XST_INVALID_PARAM;
    }
    memset(update, 0, sizeof(*update));
    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) ||
        (ctx->vdma->is_ready == 0U) ||
        (ctx->vdma->frame_count < 2U) ||
        (ctx->vdma->frame_size_bytes == 0U)) {
        return XST_FAILURE;
    }

    status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) {
        return status;
    }
    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) ||
        (ctx->vdma->is_ready == 0U) ||
        (ctx->vdma->frame_count < 2U) ||
        (ctx->vdma->frame_size_bytes == 0U)) {
        PsAppVideo_GiveVdmaOwnerLock();
        return XST_FAILURE;
    }

    current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    if (current_frame >= ctx->vdma->frame_count) {
        current_frame = 0U;
    }
    target_frame = PsAppVideo_SelectSafeFrame(ctx, current_frame);
    if ((target_frame >= ctx->vdma->frame_count) ||
        (target_frame == current_frame)) {
        PsAppVideo_GiveVdmaOwnerLock();
        return XST_FAILURE;
    }

    source_addr = ctx->vdma->frame_addrs[current_frame];
    target_addr = ctx->vdma->frame_addrs[target_frame];
    if ((source_addr == 0U) || (target_addr == 0U) ||
        (source_addr == target_addr)) {
        PsAppVideo_GiveVdmaOwnerLock();
        return XST_FAILURE;
    }

    Xil_DCacheInvalidateRange((INTPTR)source_addr, (INTPTR)ctx->vdma->frame_size_bytes);
    memcpy((void *)target_addr, (const void *)source_addr, ctx->vdma->frame_size_bytes);
    Xil_DCacheFlushRange((INTPTR)target_addr, (INTPTR)ctx->vdma->frame_size_bytes);

    update->video = ctx;
    update->source_frame_idx = current_frame;
    update->target_frame_idx = target_frame;
    update->active = 1U;
    return XST_SUCCESS;
}

void PsAppVideo_AbortUiFrameUpdate(PsAppVideoUiFrameUpdate *update) {
    PsAppVideoContext *ctx;
    u32 current_frame;

    if ((update == NULL) || (update->active == 0U)) {
        return;
    }
    ctx = update->video;
    if ((PsAppVideo_IsCoreContextValid(ctx) != 0U) &&
        (ctx->vdma->is_ready != 0U) &&
        (update->target_frame_idx < ctx->vdma->frame_count) &&
        (ctx->vdma->frame_size_bytes != 0U)) {
        current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
        if (current_frame >= ctx->vdma->frame_count) {
            current_frame = update->source_frame_idx;
        }
        if ((current_frame < ctx->vdma->frame_count) &&
            (current_frame != update->target_frame_idx)) {
            UINTPTR source_addr = ctx->vdma->frame_addrs[current_frame];
            UINTPTR target_addr = ctx->vdma->frame_addrs[update->target_frame_idx];
            Xil_DCacheInvalidateRange((INTPTR)source_addr, (INTPTR)ctx->vdma->frame_size_bytes);
            memcpy((void *)target_addr, (const void *)source_addr, ctx->vdma->frame_size_bytes);
            Xil_DCacheFlushRange((INTPTR)target_addr, (INTPTR)ctx->vdma->frame_size_bytes);
        }
    }

    update->active = 0U;
    update->video = NULL;
    PsAppVideo_GiveVdmaOwnerLock();
}

XStatus PsAppVideo_EndUiFrameUpdate(PsAppVideoUiFrameUpdate *update) {
    PsAppVideoContext *ctx;
    XStatus status;

    if ((update == NULL) || (update->active == 0U) || (update->video == NULL)) {
        return XST_INVALID_PARAM;
    }
    ctx = update->video;
    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) ||
        (ctx->vdma->is_ready == 0U) ||
        (update->target_frame_idx >= ctx->vdma->frame_count)) {
        PsAppVideo_AbortUiFrameUpdate(update);
        return XST_FAILURE;
    }

    status = PsAppVideo_RequestFrameLocked(ctx, update->target_frame_idx);
    if (status != XST_SUCCESS) {
        PsAppVideo_AbortUiFrameUpdate(update);
        return status;
    }
    PsAppVideo_SyncDisplayFrameLocked(ctx);
    update->active = 0U;
    update->video = NULL;
    PsAppVideo_GiveVdmaOwnerLock();
    return XST_SUCCESS;
}

static XStatus PsAppVideo_RenderBootFramesLocked(PsAppVideoContext *ctx) {
    XStatus status;

    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) {
        return XST_FAILURE;
    }

    status = PsAppVideo_FillAllFramesLocked(ctx, 0x00000000U);
    if (status != XST_SUCCESS) {
        return status;
    }

    (void)PsAppVideo_RequestFrameLocked(ctx, 0U);
    PsAppVideo_SyncDisplayFrameLocked(ctx);
    return XST_SUCCESS;
}

XStatus PsAppVideo_RenderBootFrames(PsAppVideoContext *ctx) {
    XStatus status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsAppVideo_RenderBootFramesLocked(ctx);
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

void PsAppVideo_PresentCapturedFrameIfReady(PsAppVideoContext *ctx) {
    PsGbaFrameSnapshot snapshot;
    u32 last_seq;
    u32 sampled_buf_idx;
    u32 request_sequence;

    if ((PsAppVideo_IsPresentContextValid(ctx) == 0U) ||
        (ctx->rom->loaded == 0U) ||
        (ctx->rom->is_loading != 0U) ||
        (ctx->rom->load_result == (u8)PS_APP_ROM_LOAD_RESULT_RUNNING) ||
        (ctx->rom->load_result == (u8)PS_APP_ROM_LOAD_RESULT_FAILED)) {
        return;
    }
    if (PsAppVideo_TakeVdmaOwnerLock() != XST_SUCCESS) return;

    ctx->frame_snapshot_request_sequence++;
    if (ctx->frame_snapshot_request_sequence == 0U) {
        ctx->frame_snapshot_request_sequence = 1U;
    }
    request_sequence = ctx->frame_snapshot_request_sequence;
    if (PsGbaRegs_ReadFrameSnapshot(ctx->regs,
                                    request_sequence,
                                    PS_APP_VIDEO_FRAME_SNAPSHOT_TIMEOUT_MS,
                                    &snapshot) != XST_SUCCESS) {
        PsAppVideo_GiveVdmaOwnerLock();
        return;
    }
    ctx->state->fbcap_snapshot_status = snapshot.status;
    ctx->state->fbcap_snapshot_seq = snapshot.sequence;
    ctx->state->fbcap_bank_generation[0] = snapshot.bank_generation[0];
    ctx->state->fbcap_bank_generation[1] = snapshot.bank_generation[1];
    ctx->state->fbcap_snapshot_rom_epoch = snapshot.rom_epoch;
    ctx->state->fbcap_published_bank = (u8)(((snapshot.status & GBA_FRAME_STATUS_PUBLISHED_BANK1) != 0U) ? 1U : 0U);
    ctx->state->fbcap_snapshot_valid = 1U;

    sampled_buf_idx = ctx->state->fbcap_published_bank;
    last_seq = ctx->state->fbcap_last_frame_seq;
    if ((snapshot.sequence == 0U) ||
        ((snapshot.status & GBA_FRAME_STATUS_VALID) == 0U) ||
        ((snapshot.status & GBA_FRAME_STATUS_ERROR) != 0U)) {
        s_ps_app_video_stale_seq_ticks = 0U;
        PsAppVideo_GiveVdmaOwnerLock();
        return;
    }
    if (snapshot.sequence == last_seq) {
        if (s_ps_app_video_stale_seq_ticks < 0xFFFFFFFFU) {
            s_ps_app_video_stale_seq_ticks++;
        }

        /* Preserve the stale-sequence fallback, but only copy a published,
         * non-writer bank after the before/after generation check. */
        if (s_ps_app_video_stale_seq_ticks < PS_APP_VIDEO_STALE_SEQ_FORCE_BLIT_TICKS) {
            PsAppVideo_GiveVdmaOwnerLock();
            return;
        }
        s_ps_app_video_stale_seq_ticks = 0U;
        if (s_ps_app_video_stale_seq_log_count < 8U) {
            xil_printf("[BLIT] stale-seq fallback seq=%u buf=%u\r\n",
                       (unsigned int)snapshot.sequence,
                       (unsigned int)sampled_buf_idx);
            s_ps_app_video_stale_seq_log_count++;
        }
    } else {
        s_ps_app_video_stale_seq_ticks = 0U;
    }
    if ((last_seq != 0U) && (snapshot.sequence < last_seq)) {
        if (ctx->state->blit_seq_glitch_drop < 0xFFFFFFFFU) {
            ctx->state->blit_seq_glitch_drop++;
        }
    }

    if (PsAppVideo_BlitCapturedFrameToHdmi(ctx, &snapshot) != XST_SUCCESS) {
        if (s_ps_app_video_blit_fail_log_count < 5U) {
            xil_printf("[BLIT] fail seq=%u buf=%u\r\n",
                       (unsigned int)snapshot.sequence,
                       (unsigned int)sampled_buf_idx);
            s_ps_app_video_blit_fail_log_count++;
        }
    }
    PsAppVideo_GiveVdmaOwnerLock();
}

static XStatus PsAppVideo_FillFrameLocked(PsAppVideoContext *ctx,
                                              u32 frame_idx,
                                              u32 color_xrgb8888) {
    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) return XST_FAILURE;
    return PsHdmiVdma_FillFrame(ctx->vdma, frame_idx, color_xrgb8888);
}

static XStatus PsAppVideo_FillAllFramesLocked(PsAppVideoContext *ctx,
                                               u32 color_xrgb8888) {
    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) return XST_FAILURE;
    return PsHdmiVdma_FillAllFrames(ctx->vdma, color_xrgb8888);
}

XStatus PsAppVideo_FillFrame(PsAppVideoContext *ctx, u32 frame_idx, u32 color_xrgb8888) {
    XStatus status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsAppVideo_FillFrameLocked(ctx, frame_idx, color_xrgb8888);
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

XStatus PsAppVideo_FillAllFrames(PsAppVideoContext *ctx, u32 color_xrgb8888) {
    XStatus status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    status = PsAppVideo_FillAllFramesLocked(ctx, color_xrgb8888);
    PsAppVideo_GiveVdmaOwnerLock();
    return status;
}

XStatus PsAppVideo_GetVdmaStatus(PsAppVideoContext *ctx,
                                 u32 *current_frame_out,
                                 u32 *status_out,
                                 u32 *error_mask_out) {
    XStatus status;
    u32 current_frame;
    u32 channel_status;

    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (ctx->vdma->is_ready == 0U)) {
        return XST_FAILURE;
    }
    status = PsAppVideo_TakeVdmaOwnerLock();
    if (status != XST_SUCCESS) return status;
    channel_status = XAxiVdma_GetStatus(&ctx->vdma->vdma, XAXIVDMA_READ);
    current_frame = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    if (current_frame >= ctx->vdma->frame_count) current_frame = 0U;
    if (current_frame_out != NULL) *current_frame_out = current_frame;
    if (status_out != NULL) *status_out = channel_status;
    if (error_mask_out != NULL) *error_mask_out = channel_status & XAXIVDMA_SR_ERR_ALL_MASK;
    PsAppVideo_GiveVdmaOwnerLock();
    return XST_SUCCESS;
}

XStatus PsAppVideo_ReadVdmaDiagnostics(PsAppVideoContext *ctx,
                                       PsAppVideoVdmaDiagnostics *out) {
    UINTPTR channel_base;
    UINTPTR config_base;
    u32 frame_idx;

    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) ||
        (ctx->vdma->is_ready == 0U) || (out == NULL)) {
        return XST_INVALID_PARAM;
    }
    if (PsAppVideo_TakeVdmaOwnerLock() != XST_SUCCESS) return XST_TIMEOUT;
    channel_base = ctx->vdma->vdma.BaseAddr + XAXIVDMA_TX_OFFSET;
    config_base = ctx->vdma->vdma.BaseAddr + XAXIVDMA_MM2S_ADDR_OFFSET;
    out->control_reg = XAxiVdma_ReadReg(channel_base, XAXIVDMA_CR_OFFSET);
    out->channel_status_reg = XAxiVdma_ReadReg(channel_base, XAXIVDMA_SR_OFFSET);
    out->status = XAxiVdma_GetStatus(&ctx->vdma->vdma, XAXIVDMA_READ);
    out->error_mask = out->channel_status_reg & XAXIVDMA_SR_ERR_ALL_MASK;
    out->vertical_size = XAxiVdma_ReadReg(config_base, XAXIVDMA_VSIZE_OFFSET);
    out->horizontal_size = XAxiVdma_ReadReg(config_base, XAXIVDMA_HSIZE_OFFSET);
    out->stride_frame_delay = XAxiVdma_ReadReg(config_base, XAXIVDMA_STRD_FRMDLY_OFFSET);
    out->park_pointer = XAxiVdma_ReadReg(ctx->vdma->vdma.BaseAddr, XAXIVDMA_PARKPTR_OFFSET);
    out->frame_start[0] = XAxiVdma_ReadReg(config_base, XAXIVDMA_START_ADDR_OFFSET);
    out->frame_start[1] = XAxiVdma_ReadReg(config_base, XAXIVDMA_START_ADDR_OFFSET + 4U);
    out->frame_start[2] = XAxiVdma_ReadReg(config_base, XAXIVDMA_START_ADDR_OFFSET + 8U);
    frame_idx = XAxiVdma_CurrFrameStore(&ctx->vdma->vdma, XAXIVDMA_READ);
    out->current_frame = (frame_idx < ctx->vdma->frame_count) ? frame_idx : 0U;
    PsAppVideo_GiveVdmaOwnerLock();
    return XST_SUCCESS;
}

u32 PsAppVideo_DefaultCaptureBuffer(PsAppVideoContext *ctx) {
    u32 seq;
    u32 buf_idx;

    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) {
        return 0U;
    }

    if ((ctx->state->fbcap_last_frame_seq != 0U) && (ctx->state->fbcap_last_buf_idx < 2U)) {
        return ctx->state->fbcap_last_buf_idx;
    }

    PsAppVideo_ReadCaptureStatus(ctx, &seq, &buf_idx);
    (void)seq;
    return buf_idx & 0x1U;
}

u32 PsAppVideo_DefaultFrameIndex(PsAppVideoContext *ctx) {
    u32 frame_idx;

    if (PsAppVideo_IsCoreContextValid(ctx) == 0U) {
        return 0U;
    }

    if ((ctx->vdma->frame_count != 0U) && (ctx->state->display_frame_idx < ctx->vdma->frame_count)) {
        return ctx->state->display_frame_idx;
    }

    if (ctx->vdma->is_ready == 0U) {
        return 0U;
    }

    if (PsAppVideo_GetVdmaStatus(ctx, &frame_idx, NULL, NULL) != XST_SUCCESS) {
        return 0U;
    }
    return frame_idx;
}

void PsAppVideo_ReadCaptureStatus(PsAppVideoContext *ctx, u32 *seq_out, u32 *buf_out) {
    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (seq_out == NULL) || (buf_out == NULL)) {
        return;
    }
    *seq_out = (ctx->state->fbcap_snapshot_valid != 0U) ?
               ctx->state->fbcap_snapshot_seq : 0U;
    *buf_out = (ctx->state->fbcap_snapshot_valid != 0U) ?
               (u32)ctx->state->fbcap_published_bank : 0U;
}

u32 PsAppVideo_ReadCaptureWord(u32 buf_idx, u32 word_idx) {
    if (word_idx >= PS_APP_GBA_FB_CAPTURE_WORDS) {
        return 0U;
    }

    return Xil_In32(PsAppVideo_CaptureBufferBaseAddr(buf_idx) + (word_idx * sizeof(u32)));
}

u16 PsAppVideo_ReadCapturePixelRgb565(u32 buf_idx, u32 x, u32 y) {
    u32 packed;
    u32 word_idx;

    if ((x >= PS_APP_GBA_FRAME_WIDTH) || (y >= PS_APP_GBA_FRAME_HEIGHT)) {
        return 0U;
    }

    word_idx = (y * PS_APP_GBA_FB_CAPTURE_ROW_WORDS) + (x >> 1);
    packed = PsAppVideo_ReadCaptureWord(buf_idx, word_idx);
    if ((x & 0x1U) != 0U) {
        return (u16)((packed >> 16) & 0xFFFFU);
    }

    return (u16)(packed & 0xFFFFU);
}

u32 PsAppVideo_ComputeCaptureSparseHash(u32 buf_idx, u32 samples) {
    u32 word_count;
    u32 step_words;
    u32 idx;
    u32 word_idx;
    u32 hash;

    word_count = PS_APP_GBA_FB_CAPTURE_WORDS;
    if (word_count == 0U) {
        return 0U;
    }

    if ((samples == 0U) || (samples > word_count)) {
        samples = word_count;
    }

    step_words = word_count / samples;
    if (step_words == 0U) {
        step_words = 1U;
    }

    hash = 2166136261U;
    word_idx = 0U;
    for (idx = 0U; idx < samples; ++idx) {
        hash ^= PsAppVideo_ReadCaptureWord(buf_idx, word_idx);
        hash *= 16777619U;

        if ((word_count - word_idx) <= step_words) {
            break;
        }
        word_idx += step_words;
    }

    return hash;
}

u32 PsAppVideo_ComputeCaptureRowHash(u32 buf_idx, u32 y) {
    u32 hash;
    u32 idx;
    u32 base_word_idx;

    if (y >= PS_APP_GBA_FRAME_HEIGHT) {
        return 0U;
    }

    hash = 2166136261U;
    base_word_idx = y * PS_APP_GBA_FB_CAPTURE_ROW_WORDS;
    for (idx = 0U; idx < PS_APP_GBA_FB_CAPTURE_ROW_WORDS; ++idx) {
        hash ^= PsAppVideo_ReadCaptureWord(buf_idx, base_word_idx + idx);
        hash *= 16777619U;
    }

    return hash;
}

u32 PsAppVideo_ComputeSparseHash(UINTPTR base_addr, u32 bytes, u32 samples) {
    volatile const u32 *ptr;
    u32 word_count;
    u32 step_words;
    u32 idx;
    u32 word_idx;
    u32 hash;

    if (bytes < 4U) {
        return 0U;
    }

    Xil_DCacheInvalidateRange((INTPTR)base_addr, bytes);

    ptr = (volatile const u32 *)base_addr;
    word_count = bytes >> 2;
    if (word_count == 0U) {
        return 0U;
    }

    if ((samples == 0U) || (samples > word_count)) {
        samples = word_count;
    }

    step_words = word_count / samples;
    if (step_words == 0U) {
        step_words = 1U;
    }

    hash = 2166136261U;
    word_idx = 0U;
    for (idx = 0U; idx < samples; ++idx) {
        hash ^= ptr[word_idx];
        hash *= 16777619U;

        if ((word_count - word_idx) <= step_words) {
            break;
        }
        word_idx += step_words;
    }

    return hash;
}

u32 PsAppVideo_ReadHdmiFramePixel(PsAppVideoContext *ctx, u32 frame_idx, u32 x, u32 y) {
    UINTPTR addr;

    if ((PsAppVideo_IsCoreContextValid(ctx) == 0U) || (ctx->vdma->is_ready == 0U) ||
        (frame_idx >= ctx->vdma->frame_count) ||
        (x >= ctx->vdma->width) ||
        (y >= ctx->vdma->height)) {
        return 0U;
    }

    Xil_DCacheInvalidateRange((INTPTR)ctx->vdma->frame_addrs[frame_idx],
                              (INTPTR)ctx->vdma->frame_size_bytes);
    addr = ctx->vdma->frame_addrs[frame_idx] +
           (y * ctx->vdma->line_stride_bytes) +
           (x * sizeof(u32));
    return Xil_In32(addr);
}

u32 PsAppVideo_ConvertRgb565ToXrgb8888(u16 pixel) {
    u32 r5;
    u32 g6;
    u32 b5;
    u32 r8;
    u32 g8;
    u32 b8;

    r5 = (pixel >> 11) & 0x1FU;
    g6 = (pixel >> 5) & 0x3FU;
    b5 = pixel & 0x1FU;

    r8 = (r5 << 3) | (r5 >> 2);
    g8 = (g6 << 2) | (g6 >> 4);
    b8 = (b5 << 3) | (b5 >> 2);

    return (r8 << 16) | (g8 << 8) | b8;
}

void PsAppVideo_ComputeDisplayWindow(PsAppVideoContext *ctx,
                                     u32 *x_out,
                                     u32 *y_out,
                                     u32 *w_out,
                                     u32 *h_out) {
    u32 x;
    u32 y;
    u32 w;
    u32 h;

    x = 0U;
    y = 0U;
    w = 0U;
    h = 0U;

    if ((PsAppVideo_IsCoreContextValid(ctx) != 0U) && (ctx->vdma->is_ready != 0U) &&
        (ctx->vdma->width != 0U) && (ctx->vdma->height != 0U)) {
        if ((ctx->vdma->width * PS_APP_GBA_FRAME_HEIGHT) <=
            (ctx->vdma->height * PS_APP_GBA_FRAME_WIDTH)) {
            w = ctx->vdma->width;
            h = (ctx->vdma->width * PS_APP_GBA_FRAME_HEIGHT) / PS_APP_GBA_FRAME_WIDTH;
        } else {
            h = ctx->vdma->height;
            w = (ctx->vdma->height * PS_APP_GBA_FRAME_WIDTH) / PS_APP_GBA_FRAME_HEIGHT;
        }

        if (w == 0U) {
            w = 1U;
        }
        if (h == 0U) {
            h = 1U;
        }

        x = (ctx->vdma->width - w) / 2U;
        y = (ctx->vdma->height - h) / 2U;
    }

    if (x_out != NULL) {
        *x_out = x;
    }
    if (y_out != NULL) {
        *y_out = y;
    }
    if (w_out != NULL) {
        *w_out = w;
    }
    if (h_out != NULL) {
        *h_out = h;
    }
}


#include "Vdma/Inc/ps_hdmi_vdma.h"

#include "xil_cache.h"
#include "xil_printf.h"
#include <string.h>

#include "Common/Inc/ps_project_config.h"

#ifndef PS_APP_FB_FRAME_COUNT
#define PS_APP_FB_FRAME_COUNT 3U
#endif
#ifndef PS_APP_FB_REGION_BYTES
#define PS_APP_FB_REGION_BYTES (PS_APP_FB_FRAME_STORE_BYTES * PS_APP_FB_FRAME_COUNT)
#endif

static u8 PsHdmiVdma_FrameRangeFitsReservedRegion(UINTPTR frame0_addr,
                                                   u32 frame_stride_bytes,
                                                   u32 frame_count) {
    UINTPTR address_max = (UINTPTR)(~(UINTPTR)0);
    UINTPTR region_base = (UINTPTR)PS_APP_FB_REGION_BASE_ADDR;
    UINTPTR region_bytes = (UINTPTR)PS_APP_FB_REGION_BYTES;
    UINTPTR region_end;
    UINTPTR total_span;

    if ((frame_stride_bytes == 0U) || (frame_count == 0U) ||
        (region_bytes == 0U) || (region_base > (address_max - region_bytes)) ||
        ((UINTPTR)frame_stride_bytes > (address_max / (UINTPTR)frame_count))) {
        return 0U;
    }
    region_end = region_base + region_bytes;
    total_span = (UINTPTR)frame_stride_bytes * (UINTPTR)frame_count;
    if ((frame0_addr < region_base) || (frame0_addr > region_end) ||
        (total_span > (region_end - frame0_addr)) ||
        (frame0_addr > (address_max - total_span))) {
        return 0U;
    }
    return 1U;
}

static XStatus PsHdmiVdma_ValidateFrameIndex(const PsHdmiVdma *ctx, u32 frame_idx) {
    if ((ctx == 0) || (ctx->is_ready == 0U)) {
        return XST_FAILURE;
    }

    if (frame_idx >= ctx->frame_count) {
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

static XStatus PsHdmiVdma_ValidateGeometry(const PsHdmiVdma *ctx) {
    if (ctx == 0) {
        return XST_FAILURE;
    }
    if ((ctx->width == 0U) || (ctx->height == 0U)) {
        return XST_FAILURE;
    }
    /* 防御式上限，避免异常内存污染把 blit 变成超大循环。 */
    if ((ctx->width > 4096U) || (ctx->height > 2160U)) {
        return XST_FAILURE;
    }
    if ((ctx->frame_count == 0U) || (ctx->frame_count > 8U)) {
        return XST_FAILURE;
    }
    if (ctx->line_stride_bytes == 0U) {
        return XST_FAILURE;
    }
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_Init(PsHdmiVdma *ctx,
                        u32 vdma_base_addr,
                        UINTPTR video_core_register_base,
                        UINTPTR frame0_addr,
                        u32 frame_stride_bytes,
                        u32 width,
                        u32 height,
                        u32 bytes_per_pixel) {
    XAxiVdma_Config *cfg;
    VideoOutConfig video_config;
    u32 pitch_bytes;
    u32 frame_count;
    XStatus status;
    u8 native_input;

    native_input = ((width == PS_APP_VIDEO_MODE_NATIVE_INPUT_WIDTH) &&
                    (height == PS_APP_VIDEO_MODE_NATIVE_INPUT_HEIGHT)) ? 1U : 0U;
    frame_count = PS_APP_FB_FRAME_COUNT;
    if ((ctx == 0) ||
        (video_core_register_base == 0U) ||
        (frame_stride_bytes == 0U) ||
        (frame_count == 0U) ||
        (frame_count > (u32)(sizeof(ctx->frame_addrs) / sizeof(ctx->frame_addrs[0]))) ||
        (PsHdmiVdma_FrameRangeFitsReservedRegion(frame0_addr, frame_stride_bytes,
                                                  frame_count) == 0U) ||
        (((width != PS_APP_VIDEO_MODE_VGA_INPUT_WIDTH) ||
          (height != PS_APP_VIDEO_MODE_VGA_INPUT_HEIGHT)) &&
         (native_input == 0U)) ||
        (bytes_per_pixel != 4U) ||
        (width > (0xFFFFFFFFU / bytes_per_pixel))) {
        return XST_FAILURE;
    }

    pitch_bytes = width * bytes_per_pixel;
    if ((pitch_bytes > frame_stride_bytes) ||
        (height > (0xFFFFFFFFU / pitch_bytes)) ||
        ((pitch_bytes * height) > frame_stride_bytes)) {
        return XST_FAILURE;
    }

    cfg = XAxiVdma_LookupConfig(vdma_base_addr);
    if (cfg == 0) {
        return XST_FAILURE;
    }

    status = XAxiVdma_CfgInitialize(&ctx->vdma, cfg, cfg->BaseAddress);
    if (status != XST_SUCCESS) {
        return status;
    }

    if (cfg->HasMm2S == 0U) {
        return XST_FAILURE;
    }

    ctx->width = width;
    ctx->height = height;
    ctx->bytes_per_pixel = bytes_per_pixel;
    ctx->frame_buffer_span_bytes = frame_stride_bytes;
    ctx->frame_pitch_bytes = pitch_bytes;
    ctx->line_stride_bytes = pitch_bytes;
    ctx->frame_size_bytes = pitch_bytes * height;
    ctx->frame_count = frame_count;
    ctx->is_ready = 0U;

    ctx->frame_addrs[0] = frame0_addr;
    ctx->frame_addrs[1] = frame0_addr + frame_stride_bytes;
    ctx->frame_addrs[2] = frame0_addr + (2U * frame_stride_bytes);

    status = VideoOutXilinx_Bind(&ctx->video_out, &ctx->vdma,
                                 video_core_register_base, frame0_addr,
                                 frame_stride_bytes, ctx->frame_count);
    if (status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    video_config.source = VIDEO_OUT_SOURCE_VDMA;
    video_config.format = VIDEO_OUT_PIX_XRGB8888;
    video_config.width = (uint16_t)width;
    video_config.height = (uint16_t)height;
    video_config.stride_bytes = pitch_bytes;
    video_config.scale = VIDEO_OUT_SCALE_BYPASS;
    video_config.aspect = VIDEO_OUT_ASPECT_FIT;
    video_config.enabled = 1U;
    video_config.initial_frame_index = 0U;

    if (native_input == 0U) {
        /* Preserve the existing default 640x480 XRGB8888 low-load path. */
        status = (XStatus)VideoOutXilinx_Configure(&ctx->video_out, &video_config,
                                                   bytes_per_pixel);
        if (status != XST_SUCCESS) {
            xil_printf("[VIDEO] initial pipeline config failed: %d\r\n", (int)status);
            return XST_FAILURE;
        }
        ctx->video_config = video_config;
        ctx->is_ready = 1U;
        return XST_SUCCESS;
    }

    /* Optional native 1280x720 input path. The shared VideoOut_Configure() API
     * is pinned to a 640x480 output profile, so configure this consumer's MM2S
     * channel directly and stage VGA-fit scaler geometry before starting VDMA. */
    {
        XAxiVdma_DmaSetup setup;
        UINTPTR frame_addrs[VIDEO_OUT_XILINX_MAX_FRAMES];
        VideoOutIo video_io;
        PsAppVideoModeRegisterIo register_io;
        PsAppVideoModeProfile initial_vga_profile;
        u32 index;
        int mode_result;

        if (ctx->frame_count > VIDEO_OUT_XILINX_MAX_FRAMES) {
            return XST_FAILURE;
        }
        for (index = 0U; index < ctx->frame_count; ++index) {
            frame_addrs[index] = ctx->frame_addrs[index];
        }

        setup.VertSizeInput = height;
        setup.HoriSizeInput = pitch_bytes;
        setup.Stride = pitch_bytes;
        setup.FrameDelay = 0U;
        setup.EnableCircularBuf = 1U;
        setup.EnableSync = 0U;
        setup.PointNum = 0U;
        setup.EnableFrameCounter = 0U;
        setup.FixedFrameStoreAddr = 0U;
        setup.GenLockRepeat = 0U;
        setup.EnableVFlip = 0U;

        status = XAxiVdma_DmaConfig(&ctx->vdma, XAXIVDMA_READ, &setup);
        if (status != XST_SUCCESS) {
            return status;
        }
        status = XAxiVdma_DmaSetBufferAddr(&ctx->vdma, XAXIVDMA_READ, frame_addrs);
        if (status != XST_SUCCESS) {
            return status;
        }

        /* This is a geometry-only VGA boot commit. The mode controller owns its
         * startup lock/VSYNC sequence, so no mode-request pulse is sent here. */
        video_io = VideoOutXilinx_GetIo(&ctx->video_out);
        register_io.read_reg = video_io.read_reg;
        register_io.write_reg = video_io.write_reg;
        register_io.context = video_io.context;
        mode_result = PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_VGA480,
                                             (u16)width, (u16)height,
                                             &initial_vga_profile);
        if (mode_result != PS_APP_VIDEO_MODE_OK) {
            return XST_FAILURE;
        }
        mode_result = PsAppVideoMode_CommitScalerOnly(&register_io,
                                                      &initial_vga_profile,
                                                      (u16)width,
                                                      (u16)height,
                                                      pitch_bytes,
                                                      (u32)frame0_addr);
        if (mode_result != PS_APP_VIDEO_MODE_OK) {
            return XST_FAILURE;
        }

        status = XAxiVdma_DmaStart(&ctx->vdma, XAXIVDMA_READ);
        if (status != XST_SUCCESS) {
            return status;
        }
        status = XAxiVdma_StartParking(&ctx->vdma, 0, XAXIVDMA_READ);
        if (status != XST_SUCCESS) {
            (void)XAxiVdma_DmaStop(&ctx->vdma, XAXIVDMA_READ);
            return status;
        }

        ctx->video_out.is_ready = 1U;
        ctx->video_config.scale = VIDEO_OUT_SCALE_NEAREST;
        ctx->is_ready = 1U;
    }
    ctx->video_config = video_config;
    ctx->video_config.scale = VIDEO_OUT_SCALE_NEAREST;
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_ConfigureVideo(PsHdmiVdma *ctx,
                                  u32 width,
                                  u32 height,
                                  VideoOutScaleMode scale_mode) {
    VideoOutConfig config;
    int status;

    if ((ctx == 0) || (ctx->is_ready == 0U) ||
        (ctx->bytes_per_pixel == 0U) || (ctx->frame_pitch_bytes == 0U) ||
        (width == 0U) || (height == 0U) ||
        (width > VIDEO_OUT_MAX_INPUT_WIDTH) ||
        (height > VIDEO_OUT_MAX_INPUT_HEIGHT) ||
        (width > (0xFFFFFFFFU / ctx->bytes_per_pixel)) ||
        ((width * ctx->bytes_per_pixel) > ctx->frame_pitch_bytes) ||
        (height > (ctx->frame_buffer_span_bytes / ctx->frame_pitch_bytes)) ||
        (height > (0xFFFFFFFFU / ctx->frame_pitch_bytes))) {
        return XST_FAILURE;
    }

    config = ctx->video_config;
    config.source = VIDEO_OUT_SOURCE_VDMA;
    config.format = VIDEO_OUT_PIX_XRGB8888;
    config.width = (uint16_t)width;
    config.height = (uint16_t)height;
    config.stride_bytes = ctx->frame_pitch_bytes;
    config.scale = scale_mode;
    config.aspect = VIDEO_OUT_ASPECT_FIT;
    config.enabled = 1U;
    status = VideoOutXilinx_Configure(&ctx->video_out, &config,
                                      ctx->bytes_per_pixel);
    if (status != 0) {
        xil_printf("[VIDEO] configure %ux%u scale=%u failed\r\n",
                   (unsigned int)width, (unsigned int)height,
                   (unsigned int)scale_mode);
        return XST_FAILURE;
    }

    ctx->video_config = config;
    ctx->width = width;
    ctx->height = height;
    ctx->line_stride_bytes = config.stride_bytes;
    ctx->frame_size_bytes = config.stride_bytes * height;
    xil_printf("[VIDEO] configure %ux%u scale=%u stride=%u pass\r\n",
               (unsigned int)width, (unsigned int)height,
               (unsigned int)scale_mode, (unsigned int)config.stride_bytes);
    return XST_SUCCESS;
}


/* Native mode geometry changes are serialized with the VDMA owner lock. */
XStatus PsHdmiVdma_ConfigureSourceGeometry(PsHdmiVdma *ctx,
                                              u32 width,
                                              u32 height) {
    XAxiVdma_DmaSetup setup;
    UINTPTR frame_addrs[VIDEO_OUT_XILINX_MAX_FRAMES];
    u32 pitch_bytes;
    u32 index;
    u32 retry;
    XStatus status;

    if ((ctx == NULL) || (ctx->is_ready == 0U) ||
        (ctx->bytes_per_pixel != PS_APP_HDMI_BPP) ||
        (width == 0U) ||
        (ctx->frame_count == 0U) ||
        (ctx->frame_count > VIDEO_OUT_XILINX_MAX_FRAMES) ||
        (ctx->frame_buffer_span_bytes < (PS_APP_HDMI_WIDTH * PS_APP_HDMI_BPP)) ||
        (height > (ctx->frame_buffer_span_bytes / (width * PS_APP_HDMI_BPP))) ||
        !(((width == 240U) && (height == 160U)) ||
          ((width == 640U) && (height == 480U)) ||
          ((width == 1280U) && (height == 720U)) ||
          ((width == 1920U) && (height == 1080U)))) {
        return XST_INVALID_PARAM;
    }
    if ((width == ctx->width) && (height == ctx->height)) {
        return XST_SUCCESS;
    }

    pitch_bytes = width * PS_APP_HDMI_BPP;
    for (index = 0U; index < ctx->frame_count; ++index) {
        frame_addrs[index] = ctx->frame_addrs[index];
    }

    XAxiVdma_DmaStop(&ctx->vdma, XAXIVDMA_READ);
    for (retry = 0U; retry < 100000U; ++retry) {
        if (XAxiVdma_IsBusy(&ctx->vdma, XAXIVDMA_READ) == 0U) {
            break;
        }
    }
    if (retry == 100000U) {
        XAxiVdma_Reset(&ctx->vdma, XAXIVDMA_READ);
        for (retry = 0U; retry < 100000U; ++retry) {
            if (XAxiVdma_ResetNotDone(&ctx->vdma, XAXIVDMA_READ) == 0U) {
                break;
            }
        }
        if (retry == 100000U) {
            return XST_FAILURE;
        }
    }

    memset(&setup, 0, sizeof(setup));
    setup.VertSizeInput = height;
    setup.HoriSizeInput = pitch_bytes;
    setup.Stride = pitch_bytes;
    setup.EnableCircularBuf = 1U;

    status = XAxiVdma_DmaConfig(&ctx->vdma, XAXIVDMA_READ, &setup);
    if (status == XST_SUCCESS) {
        status = XAxiVdma_DmaSetBufferAddr(&ctx->vdma, XAXIVDMA_READ, frame_addrs);
    }
    if (status != XST_SUCCESS) {
        return status;
    }

    ctx->width = width;
    ctx->height = height;
    ctx->frame_pitch_bytes = pitch_bytes;
    ctx->line_stride_bytes = pitch_bytes;
    ctx->frame_size_bytes = pitch_bytes * height;
    ctx->video_out.width = width;
    ctx->video_out.height = height;
    ctx->video_out.stride_bytes = pitch_bytes;
    ctx->video_config.width = (uint16_t)width;
    ctx->video_config.height = (uint16_t)height;
    ctx->video_config.stride_bytes = pitch_bytes;

    status = PsHdmiVdma_FillAllFrames(ctx, 0x00000000U);
    if (status != XST_SUCCESS) {
        return status;
    }
    status = XAxiVdma_DmaStart(&ctx->vdma, XAXIVDMA_READ);
    if (status == XST_SUCCESS) {
        status = XAxiVdma_StartParking(&ctx->vdma, 0, XAXIVDMA_READ);
    }
    if (status != XST_SUCCESS) {
        xil_printf("[VDMA] native mode reconfigure failed %ux%u status=%d\r\n",
                   (unsigned int)width,
                   (unsigned int)height,
                   (int)status);
    }
    return status;
}
static XStatus PsHdmiVdma_CommitSourceProfile(PsHdmiVdma *ctx,
                                               u8 mode_id,
                                               u32 source_width,
                                               u32 source_height,
                                               u8 request_output_mode) {
    VideoOutIo video_io;
    PsAppVideoModeRegisterIo register_io;
    PsAppVideoModeProfile profile;
    int result;
    int commit_result;
    XStatus geometry_status;

    if ((ctx == NULL) || (ctx->is_ready == 0U) ||
        (ctx->frame_count == 0U) || (ctx->frame_addrs[0] == 0U) ||
        (source_width > 0xFFFFU) || (source_height > 0xFFFFU)) {
        return XST_FAILURE;
    }
    result = PsAppVideoMode_Compute(mode_id, (u16)source_width,
                                    (u16)source_height, &profile);
    if (result != PS_APP_VIDEO_MODE_OK) return XST_INVALID_PARAM;

    geometry_status = PsHdmiVdma_ConfigureSourceGeometry(ctx, source_width,
                                                         source_height);
    if (geometry_status != XST_SUCCESS) return geometry_status;
    if ((ctx->line_stride_bytes < (ctx->width * ctx->bytes_per_pixel)) ||
        (ctx->frame_pitch_bytes != ctx->line_stride_bytes)) {
        return XST_FAILURE;
    }

    video_io = VideoOutXilinx_GetIo(&ctx->video_out);
    register_io.read_reg = video_io.read_reg;
    register_io.write_reg = video_io.write_reg;
    register_io.context = video_io.context;
    if (request_output_mode != 0U) {
        commit_result = PsAppVideoMode_Commit(&register_io, &profile,
                                               (u16)ctx->width, (u16)ctx->height,
                                               ctx->line_stride_bytes,
                                               (u32)ctx->frame_addrs[0]);
    } else {
        commit_result = PsAppVideoMode_CommitScalerOnly(&register_io, &profile,
                                                         (u16)ctx->width, (u16)ctx->height,
                                                         ctx->line_stride_bytes,
                                                         (u32)ctx->frame_addrs[0]);
    }
    if (commit_result == PS_APP_VIDEO_MODE_ERR_BUSY) return XST_DEVICE_BUSY;
    if (commit_result != PS_APP_VIDEO_MODE_OK) return XST_FAILURE;

    ctx->video_config.source = VIDEO_OUT_SOURCE_VDMA;
    ctx->video_config.format = VIDEO_OUT_PIX_XRGB8888;
    ctx->video_config.width = (uint16_t)ctx->width;
    ctx->video_config.height = (uint16_t)ctx->height;
    ctx->video_config.stride_bytes = ctx->line_stride_bytes;
    ctx->video_config.scale = VIDEO_OUT_SCALE_NEAREST;
    ctx->video_config.aspect = VIDEO_OUT_ASPECT_FIT;
    ctx->video_config.enabled = 1U;
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_ApplyOutputMode(PsHdmiVdma *ctx,
                                  const PsAppVideoModeProfile *profile) {
    u32 source_width;
    u32 source_height;
    XStatus status;

    if ((ctx == NULL) || (ctx->is_ready == 0U) || (profile == NULL) ||
        (ctx->bytes_per_pixel != PS_APP_HDMI_BPP)) {
        return XST_FAILURE;
    }
    if (ctx->source_mode == PS_HDMI_VDMA_SOURCE_GAME) {
        source_width = PS_APP_GBA_FRAME_WIDTH;
        source_height = PS_APP_GBA_FRAME_HEIGHT;
    } else {
        source_width = profile->output_width;
        source_height = profile->output_height;
    }
    status = PsHdmiVdma_CommitSourceProfile(ctx, profile->mode_id,
                                            source_width, source_height, 1U);
    if (status == XST_SUCCESS) {
        ctx->output_mode_id = profile->mode_id;
        ctx->output_mode_valid = 1U;
    }
    return status;
}

XStatus PsHdmiVdma_SetSourceMode(PsHdmiVdma *ctx, u8 source_mode) {
    u32 source_width;
    u32 source_height;

    if ((ctx == NULL) || (ctx->is_ready == 0U) ||
        (ctx->bytes_per_pixel != PS_APP_HDMI_BPP) ||
        (source_mode > PS_HDMI_VDMA_SOURCE_GAME)) {
        return XST_INVALID_PARAM;
    }
    if ((ctx->source_mode == source_mode) && (ctx->width != 0U) &&
        (ctx->height != 0U)) {
        return XST_SUCCESS;
    }
    if (ctx->output_mode_valid == 0U) return XST_FAILURE;

    if (source_mode == PS_HDMI_VDMA_SOURCE_GAME) {
        source_width = PS_APP_GBA_FRAME_WIDTH;
        source_height = PS_APP_GBA_FRAME_HEIGHT;
    } else {
        source_width = PS_APP_VIDEO_MODE_VGA_INPUT_WIDTH;
        source_height = PS_APP_VIDEO_MODE_VGA_INPUT_HEIGHT;
        switch (ctx->output_mode_id) {
          case PS_APP_VIDEO_MODE_720P60:
            source_width = 1280U; source_height = 720U; break;
          case PS_APP_VIDEO_MODE_1080P30:
          case PS_APP_VIDEO_MODE_1080P60:
            source_width = 1920U; source_height = 1080U; break;
          default:
            break;
        }
    }
    if (PsHdmiVdma_CommitSourceProfile(ctx, ctx->output_mode_id,
                                       source_width, source_height, 0U) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    ctx->source_mode = source_mode;
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_ReadOutputModeStatus(PsHdmiVdma *ctx,
                                        PsAppVideoModeStatus *status) {
    VideoOutIo video_io;
    PsAppVideoModeRegisterIo register_io;

    if ((ctx == NULL) || (ctx->is_ready == 0U) || (status == NULL)) {
        return XST_FAILURE;
    }
    video_io = VideoOutXilinx_GetIo(&ctx->video_out);
    register_io.read_reg = video_io.read_reg;
    register_io.write_reg = video_io.write_reg;
    register_io.context = video_io.context;
    return (PsAppVideoMode_ReadStatus(&register_io, status) == PS_APP_VIDEO_MODE_OK) ?
           XST_SUCCESS : XST_FAILURE;
}

XStatus PsHdmiVdma_Park(PsHdmiVdma *ctx, u32 frame_idx) {
    XStatus status;

    status = PsHdmiVdma_ValidateFrameIndex(ctx, frame_idx);
    if (status != XST_SUCCESS) {
        return status;
    }

    /* Park 仅切换当前显示帧，不会改变初始化时的 continuous/circular 策略。 */
    return XAxiVdma_StartParking(&ctx->vdma, (int)frame_idx, XAXIVDMA_READ);
}

XStatus PsHdmiVdma_SetHdmiAudioEnabled(PsHdmiVdma *ctx, u8 enabled) {
    if ((ctx == 0) || (ctx->is_ready == 0U) || (enabled > 1U)) {
        return XST_FAILURE;
    }
    return (XStatus)VideoOutXilinx_SetHdmiAudioEnabled(&ctx->video_out, enabled);
}

XStatus PsHdmiVdma_SetAudioMute(PsHdmiVdma *ctx, u8 mute) {
    if ((ctx == 0) || (ctx->is_ready == 0U) || (mute > 1U)) {
        return XST_FAILURE;
    }
    return (XStatus)VideoOutXilinx_SetAudioMute(&ctx->video_out, mute);
}

XStatus PsHdmiVdma_SetAudioGainQ15(PsHdmiVdma *ctx, u16 gain_q15) {
    if ((ctx == 0) || (ctx->is_ready == 0U) || (gain_q15 > 32768U)) {
        return XST_FAILURE;
    }
    return (XStatus)VideoOutXilinx_SetAudioGainQ15(&ctx->video_out, gain_q15);
}

XStatus PsHdmiVdma_EnableCircular(PsHdmiVdma *ctx) {
    if ((ctx == 0) || (ctx->is_ready == 0U)) {
        return XST_FAILURE;
    }

    /* 退出 park 后恢复 circular mode，让 VDMA 在 frame store 间持续运行。 */
    XAxiVdma_StopParking(&ctx->vdma, XAXIVDMA_READ);
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_FillFrame(PsHdmiVdma *ctx, u32 frame_idx, u32 color_xrgb8888) {
    u32 y;
    u32 x;
    u32 stride_pixels;
    u32 *fb32;
    XStatus status;

    status = PsHdmiVdma_ValidateFrameIndex(ctx, frame_idx);
    if (status != XST_SUCCESS) {
        return status;
    }
    status = PsHdmiVdma_ValidateGeometry(ctx);
    if (status != XST_SUCCESS) {
        xil_printf("[VDMA] fill frame rejected: bad geometry w=%u h=%u stride=%u count=%u\r\n",
                   (unsigned int)ctx->width,
                   (unsigned int)ctx->height,
                   (unsigned int)ctx->line_stride_bytes,
                   (unsigned int)ctx->frame_count);
        return XST_FAILURE;
    }

    fb32 = (u32 *)ctx->frame_addrs[frame_idx];
    if ((ctx->bytes_per_pixel != 4U) || ((ctx->line_stride_bytes & 3U) != 0U)) {
        return XST_FAILURE;
    }
    stride_pixels = ctx->line_stride_bytes / sizeof(u32);
    for (y = 0U; y < ctx->height; ++y) {
        u32 *line = &fb32[y * stride_pixels];
        for (x = 0U; x < ctx->width; ++x) {
            line[x] = color_xrgb8888;
        }
    }

    Xil_DCacheFlushRange((INTPTR)ctx->frame_addrs[frame_idx], (INTPTR)ctx->frame_size_bytes);
    return XST_SUCCESS;
}

XStatus PsHdmiVdma_FillAllFrames(PsHdmiVdma *ctx, u32 color_xrgb8888) {
    u32 idx;
    XStatus status;

    if ((ctx == 0) || (ctx->is_ready == 0U)) {
        return XST_FAILURE;
    }
    if (PsHdmiVdma_ValidateGeometry(ctx) != XST_SUCCESS) {
        xil_printf("[VDMA] fill all rejected: bad geometry w=%u h=%u stride=%u count=%u\r\n",
                   (unsigned int)ctx->width,
                   (unsigned int)ctx->height,
                   (unsigned int)ctx->line_stride_bytes,
                   (unsigned int)ctx->frame_count);
        return XST_FAILURE;
    }

    for (idx = 0U; idx < ctx->frame_count; ++idx) {
        status = PsHdmiVdma_FillFrame(ctx, idx, color_xrgb8888);
        if (status != XST_SUCCESS) {
            return status;
        }
    }

    return XST_SUCCESS;
}

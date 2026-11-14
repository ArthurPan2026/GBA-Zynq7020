#include "Vdma/Inc/ps_hdmi_vdma.h"

#include "xil_cache.h"
#include "xil_printf.h"

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
    XStatus status;

    if ((ctx == 0) ||
        (video_core_register_base == 0U) ||
        (frame_stride_bytes == 0U) ||
        (width == 0U) ||
        (height == 0U) ||
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
    ctx->frame_count = 3U;
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

XStatus PsHdmiVdma_Park(PsHdmiVdma *ctx, u32 frame_idx) {
    XStatus status;

    status = PsHdmiVdma_ValidateFrameIndex(ctx, frame_idx);
    if (status != XST_SUCCESS) {
        return status;
    }

    /* Park 仅切换当前显示帧，不会改变初始化时的 continuous/circular 策略。 */
    return XAxiVdma_StartParking(&ctx->vdma, (int)frame_idx, XAXIVDMA_READ);
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

#include "video_out.h"

#define REG_CTRL          0x00U
#define REG_SIZE          0x04U
#define REG_STRIDE        0x08U
#define REG_BRAM_BASE     0x0cU
#define REG_STATUS        0x10U
#define REG_FRAME_COUNT   0x14U
#define REG_ERRORS        0x18U
#define REG_ACTIVE_CFG    0x1cU
#define REG_OFFSETS       0x20U
#define REG_SOURCE_ORIGIN 0x24U
#define REG_X_RATIO       0x28U
#define REG_Y_RATIO       0x2cU
#define REG_ACTIVE_SIZE   0x30U
#define REG_AUDIO_CTRL    0x34U
#define REG_AUDIO_GAIN_Q15 0x38U
#define REG_AUDIO_STATUS  0x3cU

#define CTRL_ENABLE       (1U << 0)
#define CTRL_SOURCE_SHIFT 1U
#define CTRL_SCALE        (1U << 3)
#define CTRL_STRETCH      (1U << 4)
#define CTRL_FORMAT_SHIFT 5U
#define CTRL_COMMIT       (1U << 8)
#define CTRL_CLEAR_ERRORS (1U << 10)
#define CTRL_ABORT_STREAM (1U << 11)
#define CTRL_RESUME_STREAM (1U << 12)
#define CTRL_HDMI_LINK_MODE (1U << 13)
#define VIDEO_OUT_STATUS_ENABLED       (1U << 0)
#define VIDEO_OUT_STATUS_STREAM_HELD   (1U << 1)
#define VIDEO_OUT_STATUS_CONFIG_PENDING (1U << 2)
#define VIDEO_OUT_STATUS_BUSY          (1U << 4)
#define VIDEO_OUT_CONFIG_WAIT_READS    1000000U
#define AUDIO_CTRL_HDMI_ENABLE          (1U << 0)
#define AUDIO_CTRL_MUTE                 (1U << 1)
#define AUDIO_STATUS_HDMI_ENABLED       (1U << 0)
#define AUDIO_STATUS_FIFO_UNDERFLOW     (1U << 1)
#define AUDIO_STATUS_FIFO_OVERFLOW      (1U << 2)
#define AUDIO_GAIN_Q15_UNITY            32768U

static void VideoOut_WriteControlPulse(const VideoOutIo *io, uint32_t pulse)
{
    uint32_t control = io->read_reg(io->context, REG_CTRL);
    control &= ~(CTRL_COMMIT | CTRL_CLEAR_ERRORS | CTRL_ABORT_STREAM |
                 CTRL_RESUME_STREAM);
    io->write_reg(io->context, REG_CTRL, control | pulse);
}

typedef struct {
    uint16_t active_width, active_height;
    uint16_t x_offset, y_offset;
    uint16_t source_x_origin, source_y_origin;
    uint16_t x_step, x_rem, y_step, y_rem;
} VideoOutGeometry;

static uint32_t VideoOut_FormatBytes(VideoOutPixelFormat format)
{
    switch (format) {
    case VIDEO_OUT_PIX_RGB565: return 2U;
    case VIDEO_OUT_PIX_RGB888: return 3U;
    case VIDEO_OUT_PIX_XRGB8888:
    case VIDEO_OUT_PIX_BGRX8888: return 4U;
    default: return 0U;
    }
}

static int VideoOut_ValidIo(const VideoOutIo *io)
{
    return (io != 0) && (io->read_reg != 0) && (io->write_reg != 0);
}

static int VideoOut_CalcGeometry(const VideoOutConfig *config,
                                 VideoOutGeometry *geometry)
{
    uint32_t width = config->width;
    uint32_t height = config->height;
    uint32_t active_width;
    uint32_t active_height;
    uint32_t lhs;
    uint32_t rhs;

    if (config->scale == VIDEO_OUT_SCALE_BYPASS) {
        active_width = (width < VIDEO_OUT_OUTPUT_WIDTH) ? width : VIDEO_OUT_OUTPUT_WIDTH;
        active_height = (height < VIDEO_OUT_OUTPUT_HEIGHT) ? height : VIDEO_OUT_OUTPUT_HEIGHT;
        geometry->source_x_origin = (uint16_t)((width - active_width) / 2U);
        geometry->source_y_origin = (uint16_t)((height - active_height) / 2U);
    } else if (config->aspect == VIDEO_OUT_ASPECT_STRETCH) {
        active_width = VIDEO_OUT_OUTPUT_WIDTH;
        active_height = VIDEO_OUT_OUTPUT_HEIGHT;
        geometry->source_x_origin = 0U;
        geometry->source_y_origin = 0U;
    } else {
        lhs = width * VIDEO_OUT_OUTPUT_HEIGHT;
        rhs = height * VIDEO_OUT_OUTPUT_WIDTH;
        if (lhs >= rhs) {
            active_width = VIDEO_OUT_OUTPUT_WIDTH;
            active_height = (height * VIDEO_OUT_OUTPUT_WIDTH) / width;
            if (active_height == 0U) active_height = 1U;
        } else {
            active_height = VIDEO_OUT_OUTPUT_HEIGHT;
            active_width = (width * VIDEO_OUT_OUTPUT_HEIGHT) / height;
            if (active_width == 0U) active_width = 1U;
        }
        geometry->source_x_origin = 0U;
        geometry->source_y_origin = 0U;
    }

    geometry->active_width = (uint16_t)active_width;
    geometry->active_height = (uint16_t)active_height;
    geometry->x_offset = (uint16_t)((VIDEO_OUT_OUTPUT_WIDTH - active_width) / 2U);
    geometry->y_offset = (uint16_t)((VIDEO_OUT_OUTPUT_HEIGHT - active_height) / 2U);
    geometry->x_step = (uint16_t)(width / active_width);
    geometry->x_rem = (uint16_t)(width % active_width);
    geometry->y_step = (uint16_t)(height / active_height);
    geometry->y_rem = (uint16_t)(height % active_height);
    return 0;
}

int VideoOut_Configure(const VideoOutIo *io, const VideoOutConfig *config,
                       uint64_t frame0, uint32_t vdma_bytes_per_pixel)
{
    uint32_t format_bytes, control, active_cfg, offsets, origin, status;
    uint32_t retry;
    VideoOutGeometry geometry;
    int stream_aborted = 0;

    if (!VideoOut_ValidIo(io) || (config == 0))
        return -1;
    if ((config->source > VIDEO_OUT_SOURCE_VDMA) ||
        (config->format > VIDEO_OUT_PIX_BGRX8888) ||
        (config->scale > VIDEO_OUT_SCALE_NEAREST) ||
        (config->aspect > VIDEO_OUT_ASPECT_STRETCH) ||
        (config->width == 0U) || (config->height == 0U) ||
        (config->width > VIDEO_OUT_MAX_INPUT_WIDTH) ||
        (config->height > VIDEO_OUT_MAX_INPUT_HEIGHT))
        return -1;

    format_bytes = VideoOut_FormatBytes(config->format);
    if ((format_bytes == 0U) ||
        (config->width > (UINT32_MAX / format_bytes)) ||
        (config->stride_bytes < ((uint32_t)config->width * format_bytes)))
        return -1;
    if (VideoOut_CalcGeometry(config, &geometry) != 0)
        return -1;
    if (config->source == VIDEO_OUT_SOURCE_VDMA) {
        if (io->configure_vdma == 0) return -1;
        if (vdma_bytes_per_pixel == 0U) vdma_bytes_per_pixel = format_bytes;
        // V1 VDMA 流每拍为一个补齐到 32-bit 的 RGB 像素。
        if ((vdma_bytes_per_pixel != 4U) ||
            (config->format == VIDEO_OUT_PIX_RGB565)) return -1;
        if (config->stride_bytes < ((uint32_t)config->width * vdma_bytes_per_pixel))
            return -1;
    }

    // 等当前帧完成期间保持当前源使能。先切换默认源可能在帧中途停止 AXI-Stream，
    // 使 scaler 无法收到 TLAST/SOF 而一直处于忙状态。
    {
        for (retry = 0U; retry < VIDEO_OUT_CONFIG_WAIT_READS; ++retry) {
            if ((io->read_reg(io->context, REG_STATUS) & VIDEO_OUT_STATUS_BUSY) == 0U)
                break;
        }
        if (retry == VIDEO_OUT_CONFIG_WAIT_READS) {
            // 连续 AXI-Stream 源可能不会向软件呈现空闲周期。此时先暂停输入并中止部分帧，
            // 再应用新配置，然后继续接收下一帧的 SOF。
            VideoOut_WriteControlPulse(io, CTRL_ABORT_STREAM);
            stream_aborted = 1;
            for (retry = 0U; retry < VIDEO_OUT_CONFIG_WAIT_READS; ++retry) {
                status = io->read_reg(io->context, REG_STATUS);
                if (((status & VIDEO_OUT_STATUS_BUSY) == 0U) &&
                    ((status & VIDEO_OUT_STATUS_STREAM_HELD) != 0U))
                    break;
            }
            if (retry == VIDEO_OUT_CONFIG_WAIT_READS)
                return -1;
        }
    }
    io->write_reg(io->context, REG_SIZE,
                  ((uint32_t)config->height << 16) | config->width);
    io->write_reg(io->context, REG_STRIDE, config->stride_bytes);
    io->write_reg(io->context, REG_BRAM_BASE, (uint32_t)frame0);

    active_cfg = ((uint32_t)geometry.active_height << 16) | geometry.active_width;
    offsets = ((uint32_t)geometry.y_offset << 16) | geometry.x_offset;
    origin = (((uint32_t)geometry.source_y_origin & 0x7ffU) << 16) |
             ((uint32_t)geometry.source_x_origin & 0x7ffU);
    io->write_reg(io->context, REG_ACTIVE_CFG, active_cfg);
    io->write_reg(io->context, REG_OFFSETS, offsets);
    io->write_reg(io->context, REG_SOURCE_ORIGIN, origin);
    io->write_reg(io->context, REG_X_RATIO,
                  (((uint32_t)geometry.x_rem & 0x7ffU) << 16) |
                  ((uint32_t)geometry.x_step & 0x7ffU));
    io->write_reg(io->context, REG_Y_RATIO,
                  (((uint32_t)geometry.y_rem & 0x7ffU) << 16) |
                  ((uint32_t)geometry.y_step & 0x7ffU));

    // Keep the link protocol selected by the consumer's HPD/EDID service.
    control = io->read_reg(io->context, REG_CTRL) & CTRL_HDMI_LINK_MODE;
    control |= ((uint32_t)config->source << CTRL_SOURCE_SHIFT) |
               ((uint32_t)config->format << CTRL_FORMAT_SHIFT);
    if (config->scale == VIDEO_OUT_SCALE_NEAREST) control |= CTRL_SCALE;
    if (config->aspect == VIDEO_OUT_ASPECT_STRETCH) control |= CTRL_STRETCH;

    // 此回调只配置标准 AXI VDMA，不负责写视频核寄存器。
    if ((config->source == VIDEO_OUT_SOURCE_VDMA) &&
        (io->configure_vdma(io->context, frame0, config->width,
                            config->height, vdma_bytes_per_pixel,
                            config->stride_bytes,
                            config->initial_frame_index) != 0)) {
        if (stream_aborted)
            VideoOut_WriteControlPulse(io, CTRL_RESUME_STREAM);
        return -1;
    }

    if (config->enabled != 0U) control |= CTRL_ENABLE;
    io->write_reg(io->context, REG_CTRL, control | CTRL_COMMIT);

    if (stream_aborted) {
        for (retry = 0U; retry < VIDEO_OUT_CONFIG_WAIT_READS; ++retry) {
            status = io->read_reg(io->context, REG_STATUS);
            if (((status & VIDEO_OUT_STATUS_STREAM_HELD) == 0U) &&
                ((status & VIDEO_OUT_STATUS_CONFIG_PENDING) == 0U))
                return 0;
        }
        VideoOut_WriteControlPulse(io, CTRL_RESUME_STREAM);
        return -1;
    }
    return 0;
}

int VideoOut_SetLinkMode(const VideoOutIo *io, VideoOutLinkMode mode)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io) ||
        (mode != VIDEO_OUT_LINK_DVI && mode != VIDEO_OUT_LINK_HDMI))
        return -1;
    control = io->read_reg(io->context, REG_CTRL);
    control &= ~(CTRL_COMMIT | CTRL_CLEAR_ERRORS | CTRL_ABORT_STREAM |
                 CTRL_RESUME_STREAM | CTRL_HDMI_LINK_MODE);
    if (mode == VIDEO_OUT_LINK_HDMI)
        control |= CTRL_HDMI_LINK_MODE;
    io->write_reg(io->context, REG_CTRL, control);
    return 0;
}

int VideoOut_GetLinkMode(const VideoOutIo *io, VideoOutLinkMode *mode)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io) || mode == 0)
        return -1;
    control = io->read_reg(io->context, REG_CTRL);
    *mode = (control & CTRL_HDMI_LINK_MODE) ? VIDEO_OUT_LINK_HDMI : VIDEO_OUT_LINK_DVI;
    return 0;
}

int VideoOut_Start(const VideoOutIo *io)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io)) return -1;
    control = io->read_reg(io->context, REG_CTRL);
    control = (control | CTRL_ENABLE) & ~CTRL_COMMIT;
    if (((control >> CTRL_SOURCE_SHIFT) & 3U) == VIDEO_OUT_SOURCE_BRAM)
        control |= (1U << 9);
    io->write_reg(io->context, REG_CTRL, control | CTRL_COMMIT);
    return 0;
}

int VideoOut_BramSubmit(const VideoOutIo *io, uint32_t frame_base_word)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io))
        return -1;
    control = io->read_reg(io->context, REG_CTRL);
    if (((control >> CTRL_SOURCE_SHIFT) & 3U) != VIDEO_OUT_SOURCE_BRAM)
        return -1;
    io->write_reg(io->context, REG_BRAM_BASE, frame_base_word);
    control = (control & ~CTRL_COMMIT) | (1U << 9);
    io->write_reg(io->context, REG_CTRL, control);
    return 0;
}

int VideoOut_Stop(const VideoOutIo *io)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io)) return -1;
    control = io->read_reg(io->context, REG_CTRL);
    control = (control & ~CTRL_ENABLE) & ~CTRL_COMMIT;
    io->write_reg(io->context, REG_CTRL, control | CTRL_COMMIT);
    return 0;
}

int VideoOut_GetStatus(const VideoOutIo *io, VideoOutStatus *status)
{
    uint32_t state, active_size;
    if (!VideoOut_ValidIo(io) || (status == 0)) return -1;
    state = io->read_reg(io->context, REG_STATUS);
    active_size = io->read_reg(io->context, REG_ACTIVE_SIZE);
    status->busy = (uint8_t)((state >> 4) & 1U);
    status->enabled = (uint8_t)(state & VIDEO_OUT_STATUS_ENABLED);
    status->stream_held = (uint8_t)((state & VIDEO_OUT_STATUS_STREAM_HELD) != 0U);
    status->config_pending = (uint8_t)((state & VIDEO_OUT_STATUS_CONFIG_PENDING) != 0U);
    status->active_source = (state >> 6) & 3U;
    status->active_width = active_size & 0x7ffU;
    status->active_height = (active_size >> 16) & 0x7ffU;
    status->frame_count = io->read_reg(io->context, REG_FRAME_COUNT);
    status->error_flags = io->read_reg(io->context, REG_ERRORS);
    status->hdmi_pixel_reset_released = (uint8_t)((state >> 8) & 1U);
    status->hdmi_serial_clock_seen = (uint8_t)((state >> 9) & 1U);
    status->hdmi_vsync_seen = (uint8_t)((state >> 10) & 1U);
    status->hdmi_mmcm_locked = (uint8_t)((state >> 11) & 1U);
    status->hdmi_pixel_clock_seen = (uint8_t)((state >> 12) & 1U);
    status->hdmi_pixel_reset_ext_asserted = (uint8_t)((state >> 13) & 1U);
    return 0;
}

static int VideoOut_UpdateAudioControl(const VideoOutIo *io, uint32_t mask, uint32_t value)
{
    uint32_t control;
    if (!VideoOut_ValidIo(io))
        return -1;
    control = io->read_reg(io->context, REG_AUDIO_CTRL);
    control = (control & ~mask) | (value & mask);
    io->write_reg(io->context, REG_AUDIO_CTRL, control);
    return 0;
}

int VideoOut_SetHdmiAudioEnabled(const VideoOutIo *io, uint8_t enabled)
{
    if (enabled > 1U)
        return -1;
    if (VideoOut_UpdateAudioControl(io, AUDIO_CTRL_HDMI_ENABLE,
                                    enabled ? AUDIO_CTRL_HDMI_ENABLE : 0U) != 0)
        return -1;
    if (enabled != 0U &&
        (io->read_reg(io->context, REG_AUDIO_STATUS) & AUDIO_STATUS_HDMI_ENABLED) == 0U)
        return -1;
    return 0;
}

int VideoOut_SetAudioMute(const VideoOutIo *io, uint8_t muted)
{
    if (muted > 1U)
        return -1;
    return VideoOut_UpdateAudioControl(io, AUDIO_CTRL_MUTE,
                                       muted ? AUDIO_CTRL_MUTE : 0U);
}

int VideoOut_SetAudioGainQ15(const VideoOutIo *io, uint32_t gain_q15)
{
    if (!VideoOut_ValidIo(io) || (gain_q15 > AUDIO_GAIN_Q15_UNITY))
        return -1;
    io->write_reg(io->context, REG_AUDIO_GAIN_Q15, gain_q15);
    return 0;
}

int VideoOut_GetAudioStatus(const VideoOutIo *io, VideoOutAudioStatus *status)
{
    uint32_t value;
    if (!VideoOut_ValidIo(io) || (status == 0))
        return -1;
    value = io->read_reg(io->context, REG_AUDIO_STATUS);
    status->hdmi_audio_enabled = (uint8_t)((value & AUDIO_STATUS_HDMI_ENABLED) != 0U);
    status->fifo_underflow = (uint8_t)((value & AUDIO_STATUS_FIFO_UNDERFLOW) != 0U);
    status->fifo_overflow = (uint8_t)((value & AUDIO_STATUS_FIFO_OVERFLOW) != 0U);
    return 0;
}

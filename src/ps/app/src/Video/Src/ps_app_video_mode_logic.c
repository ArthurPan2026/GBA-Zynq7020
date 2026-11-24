#include "Video/Inc/ps_app_video_mode_logic.h"

#include <stddef.h>

#define PS_APP_VIDEO_MODE_WAIT_READS 1000000U
#define CTRL_ABORT_STREAM PS_APP_VIDEO_MODE_CTRL_ABORT_STREAM
#define CTRL_RESUME_STREAM (1U << 12)
#define CTRL_BRAM_START (1U << 9)
#define CTRL_W1P_MASK (PS_APP_VIDEO_MODE_CTRL_COMMIT | CTRL_BRAM_START | \
                       PS_APP_VIDEO_MODE_CTRL_CLEAR_ERRORS | CTRL_ABORT_STREAM | \
                       CTRL_RESUME_STREAM | PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT)
#define VIDEO_OUT_COMPONENT_BYTES 4U
#define VIDEO_OUT_MAX_ACTIVE_DIMENSION 2047U
#define VIDEO_OUT_MAX_RATIO_STEP 1023U
#define VIDEO_OUT_MAX_RATIO_REM 2047U

static const struct { u16 width, height; u32 clock_khz; u8 vic; } modes[] = {
#define GBA_VIDEO_MODE(name, w, h, hz, khz, vic) {w, h, khz, vic},
#include "Video/Inc/video_modes.def"
#undef GBA_VIDEO_MODE
};

static int PsAppVideoMode_SetOutputSize(u8 mode, u16 *width, u16 *height, u8 *vic) {
    if (mode >= PS_APP_VIDEO_MODE_COUNT) return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    *width = modes[mode].width;
    *height = modes[mode].height;
    *vic = modes[mode].vic;
    return PS_APP_VIDEO_MODE_OK;
}

static u8 PsAppVideoMode_IsSupportedInput(u16 width, u16 height) {
    for (u8 mode = 0U; mode < PS_APP_VIDEO_MODE_COUNT; ++mode) {
        if (width == modes[mode].width && height == modes[mode].height) return 1U;
    }
    return 0U;
}

static u8 PsAppVideoMode_HasVic(const PsAppHdmiEdidInfo *edid, u8 vic) {
    if ((edid == NULL) || (vic == 0U) || (vic > 127U)) {
        return 0U;
    }
    return (u8)((edid->cea_vic_bitmap[vic >> 5] >> (vic & 0x1FU)) & 1U);
}

int PsAppVideoMode_Compute(u8 mode_id,
                           u16 source_width,
                           u16 source_height,
                           PsAppVideoModeProfile *profile) {
    u32 lhs;
    u32 rhs;
    u32 active_width;
    u32 active_height;
    int result;

    if ((profile == NULL) || (source_width == 0U) || (source_height == 0U) ||
        (PsAppVideoMode_IsSupportedInput(source_width, source_height) == 0U)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }

    profile->mode_id = mode_id;
    result = PsAppVideoMode_SetOutputSize(mode_id, &profile->output_width,
                                          &profile->output_height, &profile->vic);
    if (result != PS_APP_VIDEO_MODE_OK) {
        return result;
    }

    lhs = (u32)source_width * (u32)profile->output_height;
    rhs = (u32)source_height * (u32)profile->output_width;
    if (lhs <= rhs) {
        active_height = profile->output_height;
        active_width = ((u32)source_width * active_height) / source_height;
    } else {
        active_width = profile->output_width;
        active_height = ((u32)source_height * active_width) / source_width;
    }

    if ((active_width == 0U) || (active_height == 0U) ||
        (active_width > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (active_height > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (active_width > profile->output_width) ||
        (active_height > profile->output_height)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }

    profile->active_width = (u16)active_width;
    profile->active_height = (u16)active_height;
    profile->x_offset = (u16)(((u32)profile->output_width - active_width) / 2U);
    profile->y_offset = (u16)(((u32)profile->output_height - active_height) / 2U);
    profile->source_x_origin = 0U;
    profile->source_y_origin = 0U;
    profile->source_x_step = (u16)(source_width / active_width);
    profile->source_x_rem = (u16)(source_width % active_width);
    profile->source_y_step = (u16)(source_height / active_height);
    profile->source_y_rem = (u16)(source_height % active_height);

    if ((profile->source_x_step > VIDEO_OUT_MAX_RATIO_STEP) ||
        (profile->source_x_rem > VIDEO_OUT_MAX_RATIO_REM) ||
        (profile->source_y_step > VIDEO_OUT_MAX_RATIO_STEP) ||
        (profile->source_y_rem > VIDEO_OUT_MAX_RATIO_REM)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }
    return PS_APP_VIDEO_MODE_OK;
}

int PsAppVideoMode_ComputeNative(u8 mode, PsAppVideoModeProfile *profile) {
    if (mode >= PS_APP_VIDEO_MODE_COUNT) return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    return PsAppVideoMode_Compute(mode, modes[mode].width, modes[mode].height, profile);
}

u8 PsAppVideoMode_HardwareMask(u32 status) {
    /* Legacy images leave STATUS[19:14] zero. */
    return ((status >> 18) & 3U) == 1U ? (u8)((status >> 14) & 15U) : 1U;
}

u8 PsAppVideoMode_SinkSupports(const PsAppHdmiEdidInfo *edid, u8 hardware_mask, u8 mode) {
    if (mode >= PS_APP_VIDEO_MODE_COUNT || (hardware_mask & (1U << mode)) == 0U) return 0U;
    if (mode == PS_APP_VIDEO_MODE_VGA480) return 1U;
    return edid != NULL && edid->edid_valid && edid->cea_v3_valid &&
           edid->sink_type == (u8)PS_APP_HDMI_SINK_HDMI && edid->hdmi_vsdb_present &&
           (u32)edid->max_tmds_clock_mhz * 1000U >= modes[mode].clock_khz &&
           PsAppVideoMode_HasVic(edid, modes[mode].vic);
}

u8 PsAppVideoMode_Preferred(const PsAppHdmiEdidInfo *edid, u8 hardware_mask) {
    for (u8 mode = PS_APP_VIDEO_MODE_COUNT; mode > 0U; --mode) {
        if (PsAppVideoMode_SinkSupports(edid, hardware_mask, mode - 1U)) return mode - 1U;
    }
    return PS_APP_VIDEO_MODE_COUNT;
}

int PsAppVideoMode_Select(const PsAppHdmiEdidInfo *edid, u16 source_width,
                          u16 source_height, PsAppVideoModeProfile *profile) {
    return PsAppVideoMode_Compute(PsAppVideoMode_Preferred(edid, (1U << PS_APP_VIDEO_MODE_COUNT) - 1U),
                                  source_width, source_height, profile);
}

int PsAppVideoMode_ReadStatus(const PsAppVideoModeRegisterIo *io,
                              PsAppVideoModeStatus *status) {
    u32 value;

    if ((io == NULL) || (io->read_reg == NULL) || (status == NULL)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }
    value = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_STATUS);
    status->active_mode = (u8)((value & PS_APP_VIDEO_MODE_STATUS_MODE_MASK) >>
                               PS_APP_VIDEO_MODE_STATUS_MODE_SHIFT);
    status->busy = (value & PS_APP_VIDEO_MODE_STATUS_MODE_BUSY) != 0U ? 1U : 0U;
    status->error = (value & PS_APP_VIDEO_MODE_STATUS_MODE_ERROR) != 0U ? 1U : 0U;
    return PS_APP_VIDEO_MODE_OK;
}

static int PsAppVideoMode_CommitInternal(const PsAppVideoModeRegisterIo *io,
                                         const PsAppVideoModeProfile *profile,
                                         u16 source_width,
                                         u16 source_height,
                                         u32 stride_bytes,
                                         u32 frame0_address,
                                         u8 submit_mode_request) {
    u32 retry;
    u32 status;
    u32 control;
    u32 active_cfg;
    u32 offsets;
    u32 origin;
    u32 x_ratio;
    u32 y_ratio;
    PsAppVideoModeProfile expected;

    if ((io == NULL) || (io->read_reg == NULL) || (io->write_reg == NULL) ||
        (profile == NULL) || (profile->mode_id >= PS_APP_VIDEO_MODE_COUNT) ||
        (source_width == 0U) || (source_height == 0U) ||
        (PsAppVideoMode_IsSupportedInput(source_width, source_height) == 0U) ||
        (stride_bytes < ((u32)source_width * VIDEO_OUT_COMPONENT_BYTES)) ||
        (profile->active_width == 0U) || (profile->active_height == 0U) ||
        (profile->active_width > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->active_height > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->x_offset > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->y_offset > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->source_x_origin > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->source_y_origin > VIDEO_OUT_MAX_ACTIVE_DIMENSION) ||
        (profile->source_x_step > VIDEO_OUT_MAX_RATIO_STEP) ||
        (profile->source_x_rem > VIDEO_OUT_MAX_RATIO_REM) ||
        (profile->source_y_step > VIDEO_OUT_MAX_RATIO_STEP) ||
        (profile->source_y_rem > VIDEO_OUT_MAX_RATIO_REM) ||
        (PsAppVideoMode_Compute(profile->mode_id, source_width, source_height,
                                &expected) != PS_APP_VIDEO_MODE_OK) ||
        (profile->vic != expected.vic) ||
        (profile->output_width != expected.output_width) ||
        (profile->output_height != expected.output_height) ||
        (profile->active_width != expected.active_width) ||
        (profile->active_height != expected.active_height) ||
        (profile->x_offset != expected.x_offset) ||
        (profile->y_offset != expected.y_offset) ||
        (profile->source_x_origin != expected.source_x_origin) ||
        (profile->source_y_origin != expected.source_y_origin) ||
        (profile->source_x_step != expected.source_x_step) ||
        (profile->source_x_rem != expected.source_x_rem) ||
        (profile->source_y_step != expected.source_y_step) ||
        (profile->source_y_rem != expected.source_y_rem)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }

    status = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_STATUS);
    if ((submit_mode_request != 0U) &&
        ((status & PS_APP_VIDEO_MODE_STATUS_MODE_BUSY) != 0U)) {
        return PS_APP_VIDEO_MODE_ERR_BUSY;
    }

    for (retry = 0U; retry < PS_APP_VIDEO_MODE_WAIT_READS; ++retry) {
        status = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_STATUS);
        if ((status & PS_APP_VIDEO_MODE_STATUS_VIDEO_BUSY) == 0U) {
            break;
        }
    }
    if (retry == PS_APP_VIDEO_MODE_WAIT_READS) {
        control = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_CTRL) & ~CTRL_W1P_MASK;
        io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_CTRL,
                      control | CTRL_ABORT_STREAM);
        for (retry = 0U; retry < PS_APP_VIDEO_MODE_WAIT_READS; ++retry) {
            status = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_STATUS);
            if (((status & PS_APP_VIDEO_MODE_STATUS_VIDEO_BUSY) == 0U) &&
                ((status & PS_APP_VIDEO_MODE_STATUS_STREAM_HELD) != 0U)) {
                break;
            }
        }
        if (retry == PS_APP_VIDEO_MODE_WAIT_READS) {
            return PS_APP_VIDEO_MODE_ERR_TIMEOUT;
        }
    }

    active_cfg = ((u32)profile->active_height << 16) | profile->active_width;
    offsets = ((u32)profile->y_offset << 16) | profile->x_offset;
    origin = ((u32)profile->source_y_origin << 16) | profile->source_x_origin;
    x_ratio = ((u32)profile->source_x_rem << 16) | profile->source_x_step;
    y_ratio = ((u32)profile->source_y_rem << 16) | profile->source_y_step;

    /* Keep the VDMA reader at source geometry; only change the PL output viewport. */
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_SIZE,
                  ((u32)source_height << 16) | source_width);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_STRIDE, stride_bytes);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_BRAM_BASE, frame0_address);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_ACTIVE_CFG, active_cfg);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_OFFSETS, offsets);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_SOURCE_ORIGIN, origin);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_X_RATIO, x_ratio);
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_Y_RATIO, y_ratio);

    control = io->read_reg(io->context, PS_APP_VIDEO_MODE_REG_CTRL) &
              PS_APP_VIDEO_MODE_CTRL_HDMI_LINK;
    control |= PS_APP_VIDEO_MODE_CTRL_ENABLE |
               PS_APP_VIDEO_MODE_CTRL_SOURCE_VDMA |
               PS_APP_VIDEO_MODE_CTRL_SCALE_NEAREST |
               PS_APP_VIDEO_MODE_CTRL_FORMAT_XRGB8888 |
               ((u32)profile->mode_id << PS_APP_VIDEO_MODE_CTRL_MODE_SHIFT) |
               PS_APP_VIDEO_MODE_CTRL_CLEAR_ERRORS |
               PS_APP_VIDEO_MODE_CTRL_COMMIT;
    if (submit_mode_request != 0U) {
        control |= PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT;
    }
    io->write_reg(io->context, PS_APP_VIDEO_MODE_REG_CTRL, control);

    /* With a mode request, the combined CTRL write commits scaler and mode atomically. */
    return PS_APP_VIDEO_MODE_OK;
}

int PsAppVideoMode_Commit(const PsAppVideoModeRegisterIo *io,
                          const PsAppVideoModeProfile *profile,
                          u16 source_width,
                          u16 source_height,
                          u32 stride_bytes,
                          u32 frame0_address) {
    return PsAppVideoMode_CommitInternal(io, profile, source_width, source_height,
                                         stride_bytes, frame0_address, 1U);
}

int PsAppVideoMode_CommitScalerOnly(const PsAppVideoModeRegisterIo *io,
                                    const PsAppVideoModeProfile *profile,
                                    u16 source_width,
                                    u16 source_height,
                                    u32 stride_bytes,
                                    u32 frame0_address) {
    if ((profile == NULL) || (profile->mode_id != PS_APP_VIDEO_MODE_VGA480)) {
        return PS_APP_VIDEO_MODE_ERR_ARGUMENT;
    }
    return PsAppVideoMode_CommitInternal(io, profile, source_width, source_height,
                                         stride_bytes, frame0_address, 0U);
}

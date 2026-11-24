#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Video/Inc/ps_app_video_mode_logic.h"

typedef struct {
    uint32_t regs[16];
    uint32_t write_offsets[32];
    uint32_t write_values[32];
    uint32_t write_count;
} FakeVideoRegs;

static uint32_t fake_read_reg(void *context, uint32_t offset) {
    FakeVideoRegs *fake = (FakeVideoRegs *)context;
    assert(fake != NULL);
    assert((offset & 3U) == 0U && offset < sizeof(fake->regs));
    return fake->regs[offset / 4U];
}

static void fake_write_reg(void *context, uint32_t offset, uint32_t value) {
    FakeVideoRegs *fake = (FakeVideoRegs *)context;
    assert(fake != NULL);
    assert((offset & 3U) == 0U && offset < sizeof(fake->regs));
    assert(fake->write_count <
           (uint32_t)(sizeof(fake->write_offsets) / sizeof(fake->write_offsets[0])));
    fake->write_offsets[fake->write_count] = offset;
    fake->write_values[fake->write_count] = value;
    fake->write_count++;
    fake->regs[offset / 4U] = value;
    if ((offset == PS_APP_VIDEO_MODE_REG_CTRL) &&
        ((value & PS_APP_VIDEO_MODE_CTRL_ABORT_STREAM) != 0U)) {
        fake->regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] &=
            ~PS_APP_VIDEO_MODE_STATUS_VIDEO_BUSY;
        fake->regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] |=
            PS_APP_VIDEO_MODE_STATUS_STREAM_HELD;
    }
    if ((offset == PS_APP_VIDEO_MODE_REG_CTRL) &&
        ((value & PS_APP_VIDEO_MODE_CTRL_COMMIT) != 0U)) {
        fake->regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] &=
            ~(PS_APP_VIDEO_MODE_STATUS_STREAM_HELD |
              PS_APP_VIDEO_MODE_STATUS_CFG_PENDING |
              PS_APP_VIDEO_MODE_STATUS_MODE_BUSY |
              PS_APP_VIDEO_MODE_STATUS_MODE_ERROR |
              PS_APP_VIDEO_MODE_STATUS_MODE_MASK);
        fake->regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] |=
            ((value & PS_APP_VIDEO_MODE_CTRL_MODE_MASK) <<
             (PS_APP_VIDEO_MODE_STATUS_MODE_SHIFT -
              PS_APP_VIDEO_MODE_CTRL_MODE_SHIFT));
    }
}

static void make_hdmi_edid(PsAppHdmiEdidInfo *info, uint16_t max_tmds_mhz) {
    memset(info, 0, sizeof(*info));
    info->edid_valid = 1U;
    info->sink_type = (u8)PS_APP_HDMI_SINK_HDMI;
    info->cea_v3_valid = 1U;
    info->hdmi_vsdb_present = 1U;
    info->max_tmds_clock_mhz = max_tmds_mhz;
}

static void add_vic(PsAppHdmiEdidInfo *info, uint8_t vic) {
    assert(vic != 0U && vic <= 127U);
    info->cea_vic_bitmap[vic >> 5] |= ((uint32_t)1U << (vic & 0x1FU));
}

static void test_vga_default_and_fit_geometry(void) {
    PsAppHdmiEdidInfo edid;
    PsAppVideoModeProfile profile;

    memset(&edid, 0, sizeof(edid));
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_VGA480 && profile.vic == 1U);
    assert(profile.output_width == 640U && profile.output_height == 480U);
    assert(profile.active_width == 640U && profile.active_height == 480U);
    assert(profile.x_offset == 0U && profile.y_offset == 0U);
    assert(profile.source_x_step == 1U && profile.source_x_rem == 0U);
    assert(profile.source_y_step == 1U && profile.source_y_rem == 0U);
}

static void test_edid_mode_priority_and_tmds_limits(void) {
    PsAppHdmiEdidInfo edid;
    PsAppVideoModeProfile profile;

    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 4U);
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_HardwareMask(0U) == 1U);
    assert(PsAppVideoMode_HardwareMask((1U << 18) | (3U << 14)) == 3U);
    assert(PsAppVideoMode_Preferred(&edid, 7U) == PS_APP_VIDEO_MODE_1080P30);
    assert(PsAppVideoMode_Preferred(&edid, 1U) == PS_APP_VIDEO_MODE_VGA480);
    assert(PsAppVideoMode_Compute(PsAppVideoMode_Preferred(&edid, 3U), 640U, 480U,
                                  &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_720P60 && profile.vic == 4U);
    assert(profile.output_width == 1280U && profile.output_height == 720U);
    assert(profile.active_width == 960U && profile.active_height == 720U);
    assert(profile.x_offset == 160U && profile.y_offset == 0U);
    assert(profile.source_x_step == 0U && profile.source_x_rem == 640U);
    assert(profile.source_y_step == 0U && profile.source_y_rem == 480U);

    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_1080P30 && profile.vic == 34U);
    assert(profile.output_width == 1920U && profile.output_height == 1080U);
    assert(profile.active_width == 1440U && profile.active_height == 1080U);
    assert(profile.x_offset == 240U && profile.y_offset == 0U);
    assert(profile.source_x_step == 0U && profile.source_x_rem == 640U);
    assert(profile.source_y_step == 0U && profile.source_y_rem == 480U);

    make_hdmi_edid(&edid, 74U);
    add_vic(&edid, 4U);
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_VGA480);

    make_hdmi_edid(&edid, 0U); /* Unknown TMDS maximum is not sufficient evidence. */
    add_vic(&edid, 4U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_VGA480);

    make_hdmi_edid(&edid, 75U);
    edid.sink_type = (u8)PS_APP_HDMI_SINK_DVI;
    add_vic(&edid, 4U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_VGA480);

    make_hdmi_edid(&edid, 75U);
    edid.cea_v3_valid = 0U;
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_VGA480);
}


static void test_native_1280x720_input_contract(void) {
    PsAppHdmiEdidInfo edid;
    PsAppVideoModeProfile profile;

    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 4U);
    assert(PsAppVideoMode_Select(&edid, 1280U, 720U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_720P60 && profile.vic == 4U);
    assert(profile.active_width == 1280U && profile.active_height == 720U);
    assert(profile.x_offset == 0U && profile.y_offset == 0U);
    assert(profile.source_x_step == 1U && profile.source_x_rem == 0U);
    assert(profile.source_y_step == 1U && profile.source_y_rem == 0U);

    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_Select(&edid, 1280U, 720U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.mode_id == PS_APP_VIDEO_MODE_1080P30 && profile.vic == 34U);
    assert(profile.active_width == 1920U && profile.active_height == 1080U);
    assert(profile.x_offset == 0U && profile.y_offset == 0U);
    assert(profile.source_x_step == 0U && profile.source_x_rem == 1280U);
    assert(profile.source_y_step == 0U && profile.source_y_rem == 720U);

    assert(PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_VGA480, 1280U, 720U,
                                  &profile) == PS_APP_VIDEO_MODE_OK);
    assert(profile.active_width == 640U && profile.active_height == 360U);
    assert(profile.x_offset == 0U && profile.y_offset == 60U);
    assert(profile.source_x_step == 2U && profile.source_x_rem == 0U);
    assert(profile.source_y_step == 2U && profile.source_y_rem == 0U);
    assert(PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_VGA480, 1024U, 768U,
                                  &profile) == PS_APP_VIDEO_MODE_ERR_ARGUMENT);
}

static void test_native_input_commit_keeps_vdma_source_geometry_and_11bit_ratio(void) {
    FakeVideoRegs fake;
    PsAppVideoModeRegisterIo io;
    PsAppVideoModeProfile profile;

    memset(&fake, 0, sizeof(fake));
    fake.regs[PS_APP_VIDEO_MODE_REG_CTRL / 4U] = PS_APP_VIDEO_MODE_CTRL_HDMI_LINK;
    io.read_reg = fake_read_reg;
    io.write_reg = fake_write_reg;
    io.context = &fake;

    assert(PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_1080P30, 1280U, 720U,
                                  &profile) == PS_APP_VIDEO_MODE_OK);
    assert(PsAppVideoMode_Commit(&io, &profile, 1280U, 720U, 5120U,
                                 0x18000000U) == PS_APP_VIDEO_MODE_OK);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_SIZE / 4U] == ((720U << 16) | 1280U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_STRIDE / 4U] == 5120U);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_ACTIVE_CFG / 4U] == ((1080U << 16) | 1920U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_OFFSETS / 4U] == 0U);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_X_RATIO / 4U] == (1280U << 16));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_Y_RATIO / 4U] == (720U << 16));
    assert(fake.write_offsets[fake.write_count - 1U] == PS_APP_VIDEO_MODE_REG_CTRL);
    assert((fake.write_values[fake.write_count - 1U] &
            PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT) != 0U);
}

static void test_atomic_geometry_and_mode_commit(void) {
    FakeVideoRegs fake;
    PsAppVideoModeRegisterIo io;
    PsAppHdmiEdidInfo edid;
    PsAppVideoModeProfile profile;
    uint32_t ctrl_writes = 0U;
    uint32_t idx;
    uint32_t last_ctrl = 0U;

    memset(&fake, 0, sizeof(fake));
    fake.regs[PS_APP_VIDEO_MODE_REG_CTRL / 4U] = PS_APP_VIDEO_MODE_CTRL_HDMI_LINK;
    io.read_reg = fake_read_reg;
    io.write_reg = fake_write_reg;
    io.context = &fake;

    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 34U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);
    assert(PsAppVideoMode_Commit(&io, &profile, 640U, 480U, 2560U,
                                 0x10000000U) == PS_APP_VIDEO_MODE_OK);
    assert(fake.write_count == 9U);
    assert(fake.write_offsets[0] == PS_APP_VIDEO_MODE_REG_SIZE);
    assert(fake.write_offsets[1] == PS_APP_VIDEO_MODE_REG_STRIDE);
    assert(fake.write_offsets[2] == PS_APP_VIDEO_MODE_REG_BRAM_BASE);
    assert(fake.write_offsets[3] == PS_APP_VIDEO_MODE_REG_ACTIVE_CFG);
    assert(fake.write_offsets[4] == PS_APP_VIDEO_MODE_REG_OFFSETS);
    assert(fake.write_offsets[5] == PS_APP_VIDEO_MODE_REG_SOURCE_ORIGIN);
    assert(fake.write_offsets[6] == PS_APP_VIDEO_MODE_REG_X_RATIO);
    assert(fake.write_offsets[7] == PS_APP_VIDEO_MODE_REG_Y_RATIO);
    assert(fake.write_offsets[8] == PS_APP_VIDEO_MODE_REG_CTRL);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_SIZE / 4U] == ((480U << 16) | 640U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_STRIDE / 4U] == 2560U);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_ACTIVE_CFG / 4U] == ((1080U << 16) | 1440U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_OFFSETS / 4U] == 240U);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_SOURCE_ORIGIN / 4U] == 0U);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_X_RATIO / 4U] == (640U << 16));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_Y_RATIO / 4U] == (480U << 16));
    for (idx = 0U; idx < fake.write_count; ++idx) {
        if (fake.write_offsets[idx] == PS_APP_VIDEO_MODE_REG_CTRL) {
            ctrl_writes++;
            last_ctrl = fake.write_values[idx];
        }
    }
    assert(ctrl_writes == 1U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_COMMIT) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT) != 0U);
    assert(((last_ctrl & PS_APP_VIDEO_MODE_CTRL_MODE_MASK) >>
            PS_APP_VIDEO_MODE_CTRL_MODE_SHIFT) == PS_APP_VIDEO_MODE_1080P30);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_HDMI_LINK) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_ENABLE) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_SOURCE_VDMA) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_SCALE_NEAREST) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_FORMAT_XRGB8888) != 0U);
    assert((last_ctrl & PS_APP_VIDEO_MODE_CTRL_CLEAR_ERRORS) != 0U);
}


static void test_native_vga_boot_geometry_commit_does_not_pulse_mode(void) {
    FakeVideoRegs fake;
    PsAppVideoModeRegisterIo io;
    PsAppVideoModeProfile profile;

    memset(&fake, 0, sizeof(fake));
    fake.regs[PS_APP_VIDEO_MODE_REG_CTRL / 4U] = 0U;
    fake.regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] =
        PS_APP_VIDEO_MODE_STATUS_MODE_BUSY; /* Boot controller may still be waiting for VGA VSYNC. */
    io.read_reg = fake_read_reg;
    io.write_reg = fake_write_reg;
    io.context = &fake;

    assert(PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_VGA480, 1280U, 720U,
                                  &profile) == PS_APP_VIDEO_MODE_OK);
    assert(PsAppVideoMode_CommitScalerOnly(&io, &profile, 1280U, 720U, 5120U,
                                           0x18000000U) == PS_APP_VIDEO_MODE_OK);
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_SIZE / 4U] == ((720U << 16) | 1280U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_ACTIVE_CFG / 4U] == ((360U << 16) | 640U));
    assert(fake.regs[PS_APP_VIDEO_MODE_REG_OFFSETS / 4U] == (60U << 16));
    assert(fake.write_offsets[fake.write_count - 1U] == PS_APP_VIDEO_MODE_REG_CTRL);
    assert((fake.write_values[fake.write_count - 1U] &
            PS_APP_VIDEO_MODE_CTRL_COMMIT) != 0U);
    assert((fake.write_values[fake.write_count - 1U] &
            PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT) == 0U);
}


static void test_mode_status_register_decode(void) {
    FakeVideoRegs fake;
    PsAppVideoModeRegisterIo io;
    PsAppVideoModeStatus status;

    memset(&fake, 0, sizeof(fake));
    fake.regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] =
        ((uint32_t)PS_APP_VIDEO_MODE_1080P30 <<
         PS_APP_VIDEO_MODE_STATUS_MODE_SHIFT) |
        PS_APP_VIDEO_MODE_STATUS_MODE_BUSY | PS_APP_VIDEO_MODE_STATUS_MODE_ERROR;
    io.read_reg = fake_read_reg;
    io.write_reg = fake_write_reg;
    io.context = &fake;

    assert(PsAppVideoMode_ReadStatus(&io, &status) == PS_APP_VIDEO_MODE_OK);
    assert(status.active_mode == PS_APP_VIDEO_MODE_1080P30);
    assert(status.busy == 1U && status.error == 1U);
}

static void test_commit_rejects_busy_mode_and_invalid_geometry(void) {
    FakeVideoRegs fake;
    PsAppVideoModeRegisterIo io;
    PsAppVideoModeProfile profile;
    PsAppHdmiEdidInfo edid;

    memset(&fake, 0, sizeof(fake));
    io.read_reg = fake_read_reg;
    io.write_reg = fake_write_reg;
    io.context = &fake;
    make_hdmi_edid(&edid, 75U);
    add_vic(&edid, 4U);
    assert(PsAppVideoMode_Select(&edid, 640U, 480U, &profile) == PS_APP_VIDEO_MODE_OK);

    fake.regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] =
        PS_APP_VIDEO_MODE_STATUS_MODE_BUSY;
    assert(PsAppVideoMode_Commit(&io, &profile, 640U, 480U, 2560U,
                                 0x10000000U) == PS_APP_VIDEO_MODE_ERR_BUSY);
    assert(fake.write_count == 0U);

    fake.regs[PS_APP_VIDEO_MODE_REG_STATUS / 4U] = 0U;
    assert(PsAppVideoMode_Commit(&io, &profile, 640U, 480U, 100U,
                                 0x10000000U) == PS_APP_VIDEO_MODE_ERR_ARGUMENT);
    assert(fake.write_count == 0U);
    assert(PsAppVideoMode_Compute(PS_APP_VIDEO_MODE_720P60, 0U, 480U,
                                  &profile) == PS_APP_VIDEO_MODE_ERR_ARGUMENT);
}

int main(void) {
    test_vga_default_and_fit_geometry();
    test_edid_mode_priority_and_tmds_limits();
    test_native_1280x720_input_contract();
    test_atomic_geometry_and_mode_commit();
    test_native_input_commit_keeps_vdma_source_geometry_and_11bit_ratio();
    test_native_vga_boot_geometry_commit_does_not_pulse_mode();
    test_mode_status_register_decode();
    test_commit_rejects_busy_mode_and_invalid_geometry();
    puts("GBA HDMI mode logic tests passed");
    return 0;
}

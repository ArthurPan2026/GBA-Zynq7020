#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Hdmi/Inc/ps_app_edid.h"

typedef struct {
    const uint8_t *blocks[256];
    uint16_t read_indices[8];
    uint8_t read_count;
    uint16_t fail_block;
} FakeEdid;

static void finish_checksum(uint8_t block[PS_APP_EDID_BLOCK_SIZE]) {
    uint32_t sum = 0U;
    uint16_t idx;
    block[127] = 0U;
    for (idx = 0U; idx < 127U; ++idx) {
        sum += block[idx];
    }
    block[127] = (uint8_t)(0U - (uint8_t)sum);
}

static void make_base(uint8_t block[PS_APP_EDID_BLOCK_SIZE], uint8_t extension_count) {
    static const uint8_t header[8] = {0x00U, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0x00U};
    memset(block, 0, PS_APP_EDID_BLOCK_SIZE);
    memcpy(block, header, sizeof(header));
    block[18] = 1U;
    block[19] = 3U;
    block[126] = extension_count;
    finish_checksum(block);
}

static void make_cea(uint8_t block[PS_APP_EDID_BLOCK_SIZE], int with_hdmi_vsdb) {
    memset(block, 0, PS_APP_EDID_BLOCK_SIZE);
    block[0] = PS_APP_EDID_CEA_TAG;
    block[1] = 3U;
    if (with_hdmi_vsdb) {
        /* Vendor-specific data block, length 6, HDMI OUI is little-endian 03-0C-00. */
        block[2] = 11U;
        block[4] = (uint8_t)((3U << 5) | 6U);
        block[5] = 0x03U;
        block[6] = 0x0CU;
        block[7] = 0x00U;
        block[8] = 0x10U;
        block[9] = 0x00U;
        block[10] = 0x00U;
    } else {
        block[2] = 4U;
    }
    finish_checksum(block);
}

static void make_block_map(uint8_t block[PS_APP_EDID_BLOCK_SIZE]) {
    memset(block, 0, PS_APP_EDID_BLOCK_SIZE);
    block[0] = PS_APP_EDID_BLOCK_MAP_TAG;
    block[1] = PS_APP_EDID_CEA_TAG; /* Block 2 */
    block[2] = PS_APP_EDID_CEA_TAG; /* Block 3 */
    finish_checksum(block);
}

static uint8_t fake_read(void *context, uint16_t block_index,
                         uint8_t block_out[PS_APP_EDID_BLOCK_SIZE]) {
    FakeEdid *fake = (FakeEdid *)context;
    assert(fake != NULL);
    assert(fake->read_count < (uint8_t)(sizeof(fake->read_indices) / sizeof(fake->read_indices[0])));
    fake->read_indices[fake->read_count++] = block_index;
    if ((block_index == fake->fail_block) || (fake->blocks[block_index] == NULL)) {
        return 0U;
    }
    memcpy(block_out, fake->blocks[block_index], PS_APP_EDID_BLOCK_SIZE);
    return 1U;
}

static void test_two_block_edid_detects_hdmi_vsdb(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    make_cea(cea, 1);
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U);
    assert(info.extension_count == 1U);
    assert(info.cea_v3_valid == 1U);
    assert(info.hdmi_vsdb_present == 1U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_HDMI);
    assert(info.link_mode_requested == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.link_mode_request_written == 0U);
    assert(info.cea_extension_block == 1U);
    assert(fake.read_count == 1U && fake.read_indices[0] == 1U);
}

static void test_four_block_extension_map_reads_block_two_with_segment_one(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t map[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea2[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea3[PS_APP_EDID_BLOCK_SIZE];
    uint8_t segment;
    uint8_t offset;
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 3U);
    make_block_map(map);
    make_cea(cea2, 1);
    make_cea(cea3, 0);
    fake.blocks[1] = map;
    fake.blocks[2] = cea2;
    fake.blocks[3] = cea3;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_HDMI);
    assert(info.cea_extension_block == 2U);
    assert(fake.read_count == 2U);
    assert(fake.read_indices[0] == 1U && fake.read_indices[1] == 2U);
    assert(PsAppHdmiEdid_GetEddcLocation(0U, &segment, &offset) != 0U);
    assert(segment == 0U && offset == 0x00U);
    assert(PsAppHdmiEdid_GetEddcLocation(1U, &segment, &offset) != 0U);
    assert(segment == 0U && offset == 0x80U);
    assert(PsAppHdmiEdid_GetEddcLocation(2U, &segment, &offset) != 0U);
    assert(segment == 1U && offset == 0x00U);
    assert(PsAppHdmiEdid_GetEddcLocation(3U, &segment, &offset) != 0U);
    assert(segment == 1U && offset == 0x80U);
}

static void test_missing_vsdb_classifies_valid_sink_as_dvi(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    make_cea(cea, 0);
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U);
    assert(info.hdmi_vsdb_present == 0U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.link_mode_requested == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.link_mode_request_written == 0U);
}

static void test_later_cea_v3_does_not_override_first_extension_requirement(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea_v2[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea_v3[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 2U);
    make_cea(cea_v2, 0);
    cea_v2[1] = 2U;
    finish_checksum(cea_v2);
    make_cea(cea_v3, 1);
    fake.blocks[1] = cea_v2;
    fake.blocks[2] = cea_v3;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U);
    assert(info.cea_v3_valid == 0U);
    assert(info.hdmi_vsdb_present == 0U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(fake.read_count == 2U);
}

static void test_invalid_base_and_extension_checksums_fail_dvi_safe(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    make_cea(cea, 1);
    base[20] ^= 1U;
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_ERR_BASE_CHECKSUM);
    assert(info.edid_valid == 0U && info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);

    make_base(base, 1U);
    cea[40] ^= 1U;
    memset(&fake, 0, sizeof(fake));
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_ERR_EXTENSION_CHECKSUM);
    assert(info.edid_valid == 0U && info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
}

static void test_hpd_reset_clears_edid_and_restores_dvi_safe_mode(void) {
    PsAppHdmiEdidInfo info;
    memset(&info, 0xA5, sizeof(info));
    info.edid_valid = 1U;
    info.sink_type = (u8)PS_APP_HDMI_SINK_HDMI;
    info.link_mode_requested = (u8)PS_APP_HDMI_SINK_HDMI;
    info.link_mode_request_written = 1U;
    info.hdmi_vsdb_present = 1U;
    info.extension_count = 3U;
    PsAppHdmiEdid_ResetInfo(&info);
    assert(info.edid_valid == 0U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.link_mode_requested == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.link_mode_request_written == 0U);
    assert(info.hdmi_vsdb_present == 0U);
    assert(info.extension_count == 0U);
}

int main(void) {
    test_two_block_edid_detects_hdmi_vsdb();
    test_four_block_extension_map_reads_block_two_with_segment_one();
    test_missing_vsdb_classifies_valid_sink_as_dvi();
    test_later_cea_v3_does_not_override_first_extension_requirement();
    test_invalid_base_and_extension_checksums_fail_dvi_safe();
    test_hpd_reset_clears_edid_and_restores_dvi_safe_mode();
    puts("HDMI EDID parsing tests passed");
    return 0;
}

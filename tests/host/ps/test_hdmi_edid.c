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


static uint16_t append_cea_data_block(uint8_t block[PS_APP_EDID_BLOCK_SIZE],
                                      uint16_t cursor, uint8_t tag,
                                      const uint8_t *payload, uint8_t length) {
    assert(length <= 31U);
    assert((uint16_t)(cursor + 1U + length) <= 127U);
    block[cursor] = (uint8_t)((tag << 5) | length);
    if (length != 0U) {
        memcpy(&block[cursor + 1U], payload, length);
    }
    return (uint16_t)(cursor + 1U + length);
}

static void init_cea_data_collection(uint8_t block[PS_APP_EDID_BLOCK_SIZE]) {
    memset(block, 0, PS_APP_EDID_BLOCK_SIZE);
    block[0] = PS_APP_EDID_CEA_TAG;
    block[1] = 3U;
}

static void finish_cea_data_collection(uint8_t block[PS_APP_EDID_BLOCK_SIZE],
                                       uint16_t cursor) {
    assert(cursor >= 4U && cursor <= 127U);
    block[2] = (uint8_t)cursor;
    finish_checksum(block);
}

static uint8_t cea_vic_supported(const PsAppHdmiEdidInfo *info, uint8_t vic) {
    assert(vic > 0U && vic <= 127U);
    return (uint8_t)((info->cea_vic_bitmap[vic >> 5] >> (vic & 0x1FU)) & 1U);
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


static void test_cta_capabilities_include_target_vics_lpcm_tmds_deep_color_and_speakers(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    const uint8_t vics[] = {0x84U, 19U, 32U, 34U, 93U, 94U, 95U, 96U, 97U};
    const uint8_t lpcm_sads[] = {0x09U, 0x7FU, 0x07U, 0x0DU, 0x03U, 0x05U};
    const uint8_t speakers[] = {0x15U, 0x01U, 0x03U};
    const uint8_t hdmi_vsdb[] = {0x03U, 0x0CU, 0x00U, 0x10U, 0x00U, 0x38U, 0x3CU};
    const uint8_t forum_vsdb[] = {0xD8U, 0x5DU, 0xC4U, 0x01U, 0x78U};
    uint16_t cursor = 4U;
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    init_cea_data_collection(cea);
    cursor = append_cea_data_block(cea, cursor, 2U, vics, sizeof(vics));
    cursor = append_cea_data_block(cea, cursor, 1U, lpcm_sads, sizeof(lpcm_sads));
    cursor = append_cea_data_block(cea, cursor, 4U, speakers, sizeof(speakers));
    cursor = append_cea_data_block(cea, cursor, 3U, hdmi_vsdb, sizeof(hdmi_vsdb));
    cursor = append_cea_data_block(cea, cursor, 3U, forum_vsdb, sizeof(forum_vsdb));
    finish_cea_data_collection(cea, cursor);
    fake.blocks[1] = cea;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U && info.cea_v3_valid == 1U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_HDMI);
    assert(info.link_mode_requested == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.video_vic_count == sizeof(vics));
    assert(info.video_vics[0].vic == 4U && info.video_vics[0].native == 1U);
    assert(info.video_vics[1].vic == 19U && info.video_vics[1].native == 0U);
    assert(cea_vic_supported(&info, 4U) == 1U);
    assert(cea_vic_supported(&info, 19U) == 1U);
    assert(cea_vic_supported(&info, 32U) == 1U);
    assert(cea_vic_supported(&info, 34U) == 1U); /* 1080p30 / CTA VIC34. */
    assert(cea_vic_supported(&info, 33U) == 0U);
    assert(cea_vic_supported(&info, 93U) == 1U);
    assert(cea_vic_supported(&info, 94U) == 1U);
    assert(cea_vic_supported(&info, 95U) == 1U);
    assert(cea_vic_supported(&info, 96U) == 1U);
    assert(cea_vic_supported(&info, 97U) == 1U);
    assert(cea_vic_supported(&info, 98U) == 0U);
    assert(info.max_tmds_clock_mhz == 600U);
    assert((info.deep_color_flags & PS_APP_HDMI_DEEP_COLOR_30) != 0U);
    assert((info.deep_color_flags & PS_APP_HDMI_DEEP_COLOR_36) != 0U);
    assert((info.deep_color_flags & PS_APP_HDMI_DEEP_COLOR_48) == 0U);
    assert((info.deep_color_flags & PS_APP_HDMI_DEEP_COLOR_Y444) != 0U);
    assert(info.audio_sad_count == 2U);
    assert(info.audio_sads[0].format_code == 1U);
    assert(info.audio_sads[0].max_channels == 2U);
    assert(info.audio_sads[0].sample_rates == 0x7FU);
    assert(info.audio_sads[0].format_detail == 0x07U);
    assert(info.audio_max_channels == 6U && info.lpcm_max_channels == 6U);
    assert(info.lpcm_sample_rates == 0x7FU);
    assert(info.lpcm_sample_sizes == 0x07U);
    assert(info.speaker_allocation_valid == 1U);
    assert(info.speaker_allocation[0] == speakers[0]);
    assert(info.speaker_allocation[1] == speakers[1]);
    assert(info.speaker_allocation[2] == speakers[2]);
}


static void test_cta_vic_order_duplicates_and_reserved_zero(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    const uint8_t vics[] = {0x00U, 0x80U, 0xA2U, 4U, 0xA2U, 0x00U};
    uint16_t cursor = 4U;
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    init_cea_data_collection(cea);
    cursor = append_cea_data_block(cea, cursor, 2U, vics, sizeof(vics));
    finish_cea_data_collection(cea, cursor);
    fake.blocks[1] = cea;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.video_vic_count == 3U);
    assert(info.video_vics[0].vic == 34U && info.video_vics[0].native == 1U);
    assert(info.video_vics[1].vic == 4U && info.video_vics[1].native == 0U);
    assert(info.video_vics[2].vic == 34U && info.video_vics[2].native == 1U);
    assert(cea_vic_supported(&info, 34U) == 1U);
    assert(cea_vic_supported(&info, 4U) == 1U);
}

static void test_truncated_cta_video_block_fails_closed(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    init_cea_data_collection(cea);
    cea[4] = (uint8_t)((2U << 5) | 3U); /* Claims three SVDs, data end allows only one. */
    cea[5] = 34U;
    finish_cea_data_collection(cea, 6U);
    fake.blocks[1] = cea;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_ERR_CEA_BLOCK);
    assert(info.edid_valid == 0U && info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.video_vic_count == 0U);
    assert(info.cea_vic_bitmap[0] == 0U && info.cea_vic_bitmap[1] == 0U);
}

static void test_cta_video_collection_storage_at_maximum_collection_boundary(void) {
    static const uint8_t lengths[] = {31U, 31U, 31U, 26U};
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    uint8_t payload[31];
    uint16_t cursor = 4U;
    uint8_t block_index;
    uint16_t total_vics = 0U;
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    init_cea_data_collection(cea);
    for (block_index = 0U; block_index < sizeof(lengths); ++block_index) {
        uint8_t item;
        for (item = 0U; item < lengths[block_index]; ++item) {
            payload[item] = (uint8_t)(((total_vics + item) % 127U) + 1U);
        }
        cursor = append_cea_data_block(cea, cursor, 2U, payload, lengths[block_index]);
        total_vics = (uint16_t)(total_vics + lengths[block_index]);
    }
    assert(cursor == 127U && total_vics == 119U);
    finish_cea_data_collection(cea, cursor);
    fake.blocks[1] = cea;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.video_vic_count == total_vics);
    assert(cea_vic_supported(&info, 1U) == 1U);
    assert(cea_vic_supported(&info, 34U) == 1U);
    assert(cea_vic_supported(&info, 119U) == 1U);
    assert(cea_vic_supported(&info, 120U) == 0U);
}

static void test_cta_audio_collection_storage_at_maximum_sad_boundary(void) {
    static const uint8_t lengths[] = {30U, 30U, 30U, 27U};
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    uint8_t payload[30];
    uint16_t cursor = 4U;
    uint8_t block_index;
    uint8_t sad_count = 0U;
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 1U);
    init_cea_data_collection(cea);
    for (block_index = 0U; block_index < sizeof(lengths); ++block_index) {
        uint8_t item;
        for (item = 0U; item < lengths[block_index]; item = (uint8_t)(item + 3U)) {
            payload[item] = 0x08U; /* LPCM, one channel. */
            payload[item + 1U] = 0x7FU;
            payload[item + 2U] = 0x07U;
            sad_count++;
        }
        cursor = append_cea_data_block(cea, cursor, 1U, payload, lengths[block_index]);
    }
    assert(cursor <= 127U && sad_count == 39U);
    finish_cea_data_collection(cea, cursor);
    fake.blocks[1] = cea;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.audio_sad_count == sad_count);
    assert(info.lpcm_max_channels == 1U);
    assert(info.lpcm_sample_rates == 0x7FU);
    assert(info.lpcm_sample_sizes == 0x07U);
}

static void test_truncated_cta_audio_and_speaker_blocks_fail_closed(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea[PS_APP_EDID_BLOCK_SIZE];
    FakeEdid fake;
    PsAppHdmiEdidInfo info;

    make_base(base, 1U);
    memset(&fake, 0, sizeof(fake));
    init_cea_data_collection(cea);
    cea[4] = (uint8_t)((1U << 5) | 1U); /* Audio DB with a partial SAD. */
    cea[5] = 0x09U;
    finish_cea_data_collection(cea, 6U);
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_ERR_CEA_BLOCK);
    assert(info.edid_valid == 0U && info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.video_vic_count == 0U && info.audio_sad_count == 0U);
    assert(info.max_tmds_clock_mhz == 0U && info.deep_color_flags == 0U);

    memset(&fake, 0, sizeof(fake));
    init_cea_data_collection(cea);
    cea[4] = (uint8_t)((4U << 5) | 2U); /* Speaker DB requires its 3-byte bitmap. */
    cea[5] = 0x01U;
    cea[6] = 0x00U;
    finish_cea_data_collection(cea, 7U);
    fake.blocks[1] = cea;
    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_ERR_CEA_BLOCK);
    assert(info.edid_valid == 0U && info.speaker_allocation_valid == 0U);
}

static void test_later_cea_block_is_not_trusted_for_capabilities(void) {
    uint8_t base[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea_v2[PS_APP_EDID_BLOCK_SIZE];
    uint8_t cea_v3[PS_APP_EDID_BLOCK_SIZE];
    const uint8_t vics[] = {4U, 19U};
    FakeEdid fake;
    PsAppHdmiEdidInfo info;
    uint16_t cursor;

    memset(&fake, 0, sizeof(fake));
    make_base(base, 2U);
    make_cea(cea_v2, 0);
    cea_v2[1] = 2U;
    finish_checksum(cea_v2);
    init_cea_data_collection(cea_v3);
    cursor = append_cea_data_block(cea_v3, 4U, 2U, vics, sizeof(vics));
    cursor = append_cea_data_block(cea_v3, cursor, 3U,
                                   (const uint8_t[]){0x03U, 0x0CU, 0x00U}, 3U);
    finish_cea_data_collection(cea_v3, cursor);
    fake.blocks[1] = cea_v2;
    fake.blocks[2] = cea_v3;

    assert(PsAppHdmiEdid_Parse(base, fake_read, &fake, &info) == PS_APP_EDID_OK);
    assert(info.edid_valid == 1U && info.cea_v3_valid == 0U);
    assert(info.sink_type == (u8)PS_APP_HDMI_SINK_DVI);
    assert(info.hdmi_vsdb_present == 0U && info.video_vic_count == 0U);
    assert(cea_vic_supported(&info, 4U) == 0U);
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
    assert(info.video_vic_count == 0U && info.audio_sad_count == 0U);
    assert(info.max_tmds_clock_mhz == 0U && info.deep_color_flags == 0U);
    assert(info.speaker_allocation_valid == 0U);
}

int main(void) {
    test_two_block_edid_detects_hdmi_vsdb();
    test_four_block_extension_map_reads_block_two_with_segment_one();
    test_missing_vsdb_classifies_valid_sink_as_dvi();
    test_later_cea_v3_does_not_override_first_extension_requirement();
    test_invalid_base_and_extension_checksums_fail_dvi_safe();
    test_cta_capabilities_include_target_vics_lpcm_tmds_deep_color_and_speakers();
    test_cta_vic_order_duplicates_and_reserved_zero();
    test_truncated_cta_video_block_fails_closed();
    test_cta_video_collection_storage_at_maximum_collection_boundary();
    test_cta_audio_collection_storage_at_maximum_sad_boundary();
    test_truncated_cta_audio_and_speaker_blocks_fail_closed();
    test_later_cea_block_is_not_trusted_for_capabilities();
    test_hpd_reset_clears_edid_and_restores_dvi_safe_mode();
    puts("HDMI EDID parsing tests passed");
    return 0;
}

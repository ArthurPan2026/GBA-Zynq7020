#include "Hdmi/Inc/ps_app_edid.h"

#include <string.h>

static const u8 s_ps_app_edid_header[8] = {
    0x00U, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0x00U
};

void PsAppHdmiEdid_ResetInfo(PsAppHdmiEdidInfo *info) {
    if (info == NULL) {
        return;
    }
    memset(info, 0, sizeof(*info));
    info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
    info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
}

u8 PsAppHdmiEdid_ChecksumValid(const u8 block[PS_APP_EDID_BLOCK_SIZE]) {
    u16 idx;
    u32 sum = 0U;

    if (block == NULL) {
        return 0U;
    }
    for (idx = 0U; idx < PS_APP_EDID_BLOCK_SIZE; ++idx) {
        sum += (u32)block[idx];
    }
    return ((sum & 0xFFU) == 0U) ? 1U : 0U;
}

u8 PsAppHdmiEdid_GetEddcLocation(u16 block_index, u8 *segment, u8 *offset) {
    if ((segment == NULL) || (offset == NULL) || (block_index > 255U)) {
        return 0U;
    }
    *segment = (u8)(block_index >> 1);
    *offset = ((block_index & 1U) != 0U) ? 0x80U : 0x00U;
    return 1U;
}

static u8 PsAppHdmiEdid_IsBaseHeaderValid(const u8 *block) {
    return (memcmp(block, s_ps_app_edid_header, sizeof(s_ps_app_edid_header)) == 0) ? 1U : 0U;
}

static void PsAppHdmiEdid_ClearCapabilities(PsAppHdmiEdidInfo *info) {
    info->hdmi_vsdb_present = 0U;
    info->video_vic_count = 0U;
    memset(info->video_vics, 0, sizeof(info->video_vics));
    memset(info->cea_vic_bitmap, 0, sizeof(info->cea_vic_bitmap));
    info->max_tmds_clock_mhz = 0U;
    info->deep_color_flags = 0U;
    info->audio_sad_count = 0U;
    memset(info->audio_sads, 0, sizeof(info->audio_sads));
    info->audio_max_channels = 0U;
    info->lpcm_max_channels = 0U;
    info->lpcm_sample_rates = 0U;
    info->lpcm_sample_sizes = 0U;
    info->speaker_allocation_valid = 0U;
    memset(info->speaker_allocation, 0, sizeof(info->speaker_allocation));
}

static void PsAppHdmiEdid_RecordMaxTmds(PsAppHdmiEdidInfo *info, u8 rate_5mhz) {
    u16 rate_mhz = (u16)rate_5mhz * 5U;
    if (rate_mhz > info->max_tmds_clock_mhz) {
        info->max_tmds_clock_mhz = rate_mhz;
    }
}

static PsAppEdidError PsAppHdmiEdid_ParseCtaDataBlocks(
    const u8 *cea, PsAppHdmiEdidInfo *info) {
    u16 data_end;
    u16 cursor;

    if ((cea == NULL) || (info == NULL)) {
        return PS_APP_EDID_ERR_ARGUMENT;
    }
    data_end = (u16)cea[2];
    if (data_end == 0U) {
        return PS_APP_EDID_OK;
    }
    if ((data_end < 4U) || (data_end > 127U)) {
        return PS_APP_EDID_ERR_CEA_BLOCK;
    }

    cursor = 4U;
    while (cursor < data_end) {
        u8 header = cea[cursor];
        u8 tag = (u8)((header >> 5) & 0x07U);
        u8 length = (u8)(header & 0x1FU);
        u16 payload = (u16)(cursor + 1U);
        u16 next = (u16)(payload + (u16)length);
        u16 item;

        if (next > data_end) {
            return PS_APP_EDID_ERR_CEA_BLOCK;
        }

        if (tag == 0x02U) { /* Video Data Block: Short Video Descriptors. */
            for (item = 0U; item < (u16)length; ++item) {
                u8 svd = cea[payload + item];
                u8 vic = (u8)(svd & 0x7FU);
                if (vic != 0U) {
                    if (info->video_vic_count < PS_APP_EDID_MAX_VIDEO_VICS) {
                        PsAppEdidVideoVic *entry = &info->video_vics[info->video_vic_count];
                        entry->vic = vic;
                        entry->native = (u8)((svd >> 7) & 0x01U);
                        info->video_vic_count++;
                    }
                    info->cea_vic_bitmap[vic >> 5] |= ((u32)1U << (vic & 0x1FU));
                }
            }
        } else if (tag == 0x01U) { /* Audio Data Block: three-byte SADs. */
            if ((length % 3U) != 0U) {
                return PS_APP_EDID_ERR_CEA_BLOCK;
            }
            for (item = 0U; item < (u16)length; item = (u16)(item + 3U)) {
                u8 first = cea[payload + item];
                u8 format = (u8)((first >> 3) & 0x0FU);
                u8 channels = (u8)((first & 0x07U) + 1U);
                u8 sample_rates = cea[payload + item + 1U];
                u8 format_detail = cea[payload + item + 2U];

                if (info->audio_sad_count < PS_APP_EDID_MAX_AUDIO_SADS) {
                    PsAppEdidAudioSad *sad = &info->audio_sads[info->audio_sad_count];
                    sad->format_code = format;
                    sad->max_channels = channels;
                    sad->sample_rates = sample_rates;
                    sad->format_detail = format_detail;
                    info->audio_sad_count++;
                }
                if (format != 0U && channels > info->audio_max_channels) {
                    info->audio_max_channels = channels;
                }
                if (format == 1U) { /* LPCM */
                    info->lpcm_sample_rates |= sample_rates;
                    info->lpcm_sample_sizes |= (u8)(format_detail & 0x07U);
                    if (channels > info->lpcm_max_channels) {
                        info->lpcm_max_channels = channels;
                    }
                }
            }
        } else if (tag == 0x03U) { /* Vendor-Specific Data Block. */
            if (length >= 3U) {
                u32 oui = (u32)cea[payload] |
                          ((u32)cea[payload + 1U] << 8) |
                          ((u32)cea[payload + 2U] << 16);
                if (oui == PS_APP_EDID_HDMI_VSDB_OUI) {
                    info->hdmi_vsdb_present = 1U;
                    /* HDMI VSDB flags follow the OUI and physical address. */
                    if (length >= 6U) {
                        u8 flags = cea[payload + 5U];
                        if ((flags & 0x10U) != 0U) {
                            info->deep_color_flags |= PS_APP_HDMI_DEEP_COLOR_30;
                        }
                        if ((flags & 0x20U) != 0U) {
                            info->deep_color_flags |= PS_APP_HDMI_DEEP_COLOR_36;
                        }
                        if ((flags & 0x40U) != 0U) {
                            info->deep_color_flags |= PS_APP_HDMI_DEEP_COLOR_48;
                        }
                        if ((flags & 0x08U) != 0U) {
                            info->deep_color_flags |= PS_APP_HDMI_DEEP_COLOR_Y444;
                        }
                    }
                    /* Max_TMDS_Clock uses 5 MHz units and follows the flags byte. */
                    if (length >= 7U) {
                        PsAppHdmiEdid_RecordMaxTmds(info, cea[payload + 6U]);
                    }
                } else if ((oui == PS_APP_EDID_HDMI_FORUM_VSDB_OUI) && (length >= 5U)) {
                    /* HDMI Forum VSDB byte 4 is Max TMDS Character Rate in 5 MHz units. */
                    PsAppHdmiEdid_RecordMaxTmds(info, cea[payload + 4U]);
                }
            }
        } else if (tag == 0x04U) { /* Speaker Allocation Data Block. */
            if (length < 3U) {
                return PS_APP_EDID_ERR_CEA_BLOCK;
            }
            info->speaker_allocation[0] |= cea[payload];
            info->speaker_allocation[1] |= cea[payload + 1U];
            info->speaker_allocation[2] |= cea[payload + 2U];
            info->speaker_allocation_valid = 1U;
        }
        cursor = next;
    }
    return PS_APP_EDID_OK;
}

PsAppEdidError PsAppHdmiEdid_Parse(const u8 base_block[PS_APP_EDID_BLOCK_SIZE],
                                   PsAppEdidReadBlockFn read_block,
                                   void *read_context,
                                   PsAppHdmiEdidInfo *info) {
    u8 block[PS_APP_EDID_BLOCK_SIZE];
    u8 block_map[PS_APP_EDID_BLOCK_SIZE];
    u8 block_map_valid = 0U;
    u8 first_non_map_seen = 0U;
    u8 first_non_map_is_cea_v3 = 0U;
    u16 first_non_map_index = 0U;
    u16 block_map_index = 0U;
    u16 block_index;
    PsAppEdidError error;

    if (info == NULL) {
        return PS_APP_EDID_ERR_ARGUMENT;
    }
    PsAppHdmiEdid_ResetInfo(info);
    if (base_block == NULL) {
        return PS_APP_EDID_ERR_ARGUMENT;
    }
    if (PsAppHdmiEdid_IsBaseHeaderValid(base_block) == 0U) {
        return PS_APP_EDID_ERR_HEADER;
    }
    if ((base_block[18] != 1U) || (base_block[19] != 3U)) {
        return PS_APP_EDID_ERR_VERSION;
    }
    if (PsAppHdmiEdid_ChecksumValid(base_block) == 0U) {
        return PS_APP_EDID_ERR_BASE_CHECKSUM;
    }

    info->edid_valid = 1U;
    info->extension_count = base_block[126];
    if (info->extension_count == 0U) {
        return PS_APP_EDID_OK;
    }
    if (read_block == NULL) {
        PsAppHdmiEdid_ResetInfo(info);
        return PS_APP_EDID_ERR_EXTENSION_READ;
    }

    for (block_index = 1U; block_index <= (u16)info->extension_count; ++block_index) {
        if (read_block(read_context, block_index, block) == 0U) {
            info->edid_valid = 0U;
            info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
            info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
            PsAppHdmiEdid_ClearCapabilities(info);
            return PS_APP_EDID_ERR_EXTENSION_READ;
        }
        if (info->extension_blocks_read < 0xFFU) {
            info->extension_blocks_read++;
        }
        if (PsAppHdmiEdid_ChecksumValid(block) == 0U) {
            info->edid_valid = 0U;
            info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
            info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
            PsAppHdmiEdid_ClearCapabilities(info);
            return PS_APP_EDID_ERR_EXTENSION_CHECKSUM;
        }

        if (block_map_valid != 0U) {
            u16 map_entry = (u16)(block_index - block_map_index);
            if ((map_entry >= 1U) && (map_entry <= 126U) &&
                (block_map[map_entry] != block[0])) {
                info->edid_valid = 0U;
                info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
                info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
                PsAppHdmiEdid_ClearCapabilities(info);
                return PS_APP_EDID_ERR_EXTENSION_MAP_MISMATCH;
            }
        }

        if (block[0] == PS_APP_EDID_BLOCK_MAP_TAG) {
            if ((block_index != 1U) && (block_index != 128U)) {
                info->edid_valid = 0U;
                PsAppHdmiEdid_ClearCapabilities(info);
                return PS_APP_EDID_ERR_EXTENSION_MAP;
            }
            memcpy(block_map, block, sizeof(block_map));
            block_map_index = block_index;
            block_map_valid = 1U;
            continue;
        }

        if (first_non_map_seen == 0U) {
            first_non_map_seen = 1U;
            first_non_map_index = block_index;
            first_non_map_is_cea_v3 =
                ((block[0] == PS_APP_EDID_CEA_TAG) && (block[1] == 3U)) ? 1U : 0U;
        }

        if ((block[0] == PS_APP_EDID_CEA_TAG) && (block[1] == 3U)) {
            u8 is_first_cea_v3 =
                ((first_non_map_is_cea_v3 != 0U) && (block_index == first_non_map_index)) ? 1U : 0U;
            info->cea_v3_valid = is_first_cea_v3;
            info->cea_extension_block = (u8)block_index;
            error = PsAppHdmiEdid_ParseCtaDataBlocks(block, info);
            if (error != PS_APP_EDID_OK) {
                info->edid_valid = 0U;
                info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
                info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
                PsAppHdmiEdid_ClearCapabilities(info);
                return error;
            }
            if (is_first_cea_v3 == 0U) {
                /* Retain the established first-non-map CTA gate for all capabilities. */
                PsAppHdmiEdid_ClearCapabilities(info);
            }
            info->sink_type = (u8)(info->hdmi_vsdb_present != 0U ?
                                   PS_APP_HDMI_SINK_HDMI : PS_APP_HDMI_SINK_DVI);
            /* Keep the link in DVI-safe mode until the adapter confirms HDMI mode. */
            info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
            return PS_APP_EDID_OK;
        }
    }

    info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
    info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
    return PS_APP_EDID_OK;
}

const char *PsAppHdmiEdid_SinkName(u8 sink_type) {
    return (sink_type == (u8)PS_APP_HDMI_SINK_HDMI) ? "HDMI" : "DVI";
}

const char *PsAppHdmiEdid_LinkModeName(u8 link_mode) {
    return (link_mode == (u8)PS_APP_HDMI_SINK_HDMI) ? "HDMI" : "DVI";
}

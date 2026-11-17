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

static PsAppEdidError PsAppHdmiEdid_FindHdmiVsdb(const u8 *cea, u8 *found) {
    u16 data_end;
    u16 cursor;

    if ((cea == NULL) || (found == NULL)) {
        return PS_APP_EDID_ERR_ARGUMENT;
    }
    *found = 0U;
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
        u16 next = (u16)(cursor + 1U + (u16)length);

        if (next > data_end) {
            return PS_APP_EDID_ERR_CEA_BLOCK;
        }
        if ((tag == 0x03U) && (length >= 3U)) {
            u32 oui = (u32)cea[cursor + 1U] |
                      ((u32)cea[cursor + 2U] << 8) |
                      ((u32)cea[cursor + 3U] << 16);
            if (oui == PS_APP_EDID_HDMI_VSDB_OUI) {
                *found = 1U;
                return PS_APP_EDID_OK;
            }
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
            return PS_APP_EDID_ERR_EXTENSION_READ;
        }
        if (info->extension_blocks_read < 0xFFU) {
            info->extension_blocks_read++;
        }
        if (PsAppHdmiEdid_ChecksumValid(block) == 0U) {
            info->edid_valid = 0U;
            info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
            info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
            return PS_APP_EDID_ERR_EXTENSION_CHECKSUM;
        }

        if (block_map_valid != 0U) {
            u16 map_entry = (u16)(block_index - block_map_index);
            if ((map_entry >= 1U) && (map_entry <= 126U) &&
                (block_map[map_entry] != block[0])) {
                info->edid_valid = 0U;
                info->sink_type = (u8)PS_APP_HDMI_SINK_DVI;
                info->link_mode_requested = (u8)PS_APP_HDMI_SINK_DVI;
                return PS_APP_EDID_ERR_EXTENSION_MAP_MISMATCH;
            }
        }

        if (block[0] == PS_APP_EDID_BLOCK_MAP_TAG) {
            if ((block_index != 1U) && (block_index != 128U)) {
                info->edid_valid = 0U;
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
            u8 found = 0U;
            u8 is_first_cea_v3 =
                ((first_non_map_is_cea_v3 != 0U) && (block_index == first_non_map_index)) ? 1U : 0U;
            info->cea_v3_valid = is_first_cea_v3;
            info->cea_extension_block = (u8)block_index;
            error = PsAppHdmiEdid_FindHdmiVsdb(block, &found);
            if (error != PS_APP_EDID_OK) {
                info->edid_valid = 0U;
                return error;
            }
            info->hdmi_vsdb_present = (found != 0U && is_first_cea_v3 != 0U) ? 1U : 0U;
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

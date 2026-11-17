#ifndef PS_APP_EDID_H
#define PS_APP_EDID_H

#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PS_APP_EDID_BLOCK_SIZE 128U
#define PS_APP_EDID_BLOCK_MAP_TAG 0xF0U
#define PS_APP_EDID_CEA_TAG 0x02U
#define PS_APP_EDID_HDMI_VSDB_OUI 0x000C03U

typedef enum {
    PS_APP_HDMI_SINK_DVI = 0U,
    PS_APP_HDMI_SINK_HDMI = 1U
} PsAppHdmiSinkType;

typedef struct {
    u8 edid_valid;
    u8 sink_type;
    u8 link_mode_requested;
    u8 link_mode_request_written;
    u8 hdmi_vsdb_present;
    u8 cea_v3_valid;
    u8 extension_count;
    u8 extension_blocks_read;
    u8 cea_extension_block;
} PsAppHdmiEdidInfo;

typedef enum {
    PS_APP_EDID_OK = 0U,
    PS_APP_EDID_ERR_ARGUMENT = 1U,
    PS_APP_EDID_ERR_HEADER = 2U,
    PS_APP_EDID_ERR_VERSION = 3U,
    PS_APP_EDID_ERR_BASE_CHECKSUM = 4U,
    PS_APP_EDID_ERR_EXTENSION_READ = 5U,
    PS_APP_EDID_ERR_EXTENSION_CHECKSUM = 6U,
    PS_APP_EDID_ERR_EXTENSION_MAP = 7U,
    PS_APP_EDID_ERR_EXTENSION_MAP_MISMATCH = 8U,
    PS_APP_EDID_ERR_CEA_BLOCK = 9U
} PsAppEdidError;

typedef u8 (*PsAppEdidReadBlockFn)(void *context, u16 block_index,
                                   u8 block_out[PS_APP_EDID_BLOCK_SIZE]);

void PsAppHdmiEdid_ResetInfo(PsAppHdmiEdidInfo *info);
u8 PsAppHdmiEdid_ChecksumValid(const u8 block[PS_APP_EDID_BLOCK_SIZE]);
u8 PsAppHdmiEdid_GetEddcLocation(u16 block_index, u8 *segment, u8 *offset);
PsAppEdidError PsAppHdmiEdid_Parse(const u8 base_block[PS_APP_EDID_BLOCK_SIZE],
                                   PsAppEdidReadBlockFn read_block,
                                   void *read_context,
                                   PsAppHdmiEdidInfo *info);
const char *PsAppHdmiEdid_SinkName(u8 sink_type);
const char *PsAppHdmiEdid_LinkModeName(u8 link_mode);

#ifdef __cplusplus
}
#endif

#endif

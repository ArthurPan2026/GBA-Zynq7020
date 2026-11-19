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
#define PS_APP_EDID_HDMI_FORUM_VSDB_OUI 0xC45DD8U

/* Conservative storage bounds: the CTA data block collection has at most 123 bytes. */
#define PS_APP_EDID_MAX_VIDEO_VICS 123U
#define PS_APP_EDID_MAX_AUDIO_SADS 41U
#define PS_APP_EDID_CTA_VIC_BITMAP_WORDS 4U

#define PS_APP_HDMI_DEEP_COLOR_30 0x01U
#define PS_APP_HDMI_DEEP_COLOR_36 0x02U
#define PS_APP_HDMI_DEEP_COLOR_48 0x04U
#define PS_APP_HDMI_DEEP_COLOR_Y444 0x08U

typedef enum {
    PS_APP_HDMI_SINK_DVI = 0U,
    PS_APP_HDMI_SINK_HDMI = 1U
} PsAppHdmiSinkType;

typedef struct {
    u8 vic;       /* CTA VIC, 1..127; zero is reserved and not stored. */
    u8 native;    /* CTA SVD native bit. */
} PsAppEdidVideoVic;

typedef struct {
    u8 format_code;  /* SAD format code (1 is LPCM). */
    u8 max_channels; /* SAD channel count, decoded from channels-minus-one. */
    u8 sample_rates; /* Raw CTA SAD sampling-frequency bitmap. */
    u8 format_detail;/* Raw byte 3: LPCM bit depths or format-specific details. */
} PsAppEdidAudioSad;

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

    u8 video_vic_count;
    PsAppEdidVideoVic video_vics[PS_APP_EDID_MAX_VIDEO_VICS];
    u32 cea_vic_bitmap[PS_APP_EDID_CTA_VIC_BITMAP_WORDS];

    u16 max_tmds_clock_mhz;
    u8 deep_color_flags;

    u8 audio_sad_count;
    PsAppEdidAudioSad audio_sads[PS_APP_EDID_MAX_AUDIO_SADS];
    u8 audio_max_channels;
    u8 lpcm_max_channels;
    u8 lpcm_sample_rates;
    u8 lpcm_sample_sizes;

    u8 speaker_allocation_valid;
    u8 speaker_allocation[3];
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

#ifndef PS_APP_VIDEO_MODE_LOGIC_H
#define PS_APP_VIDEO_MODE_LOGIC_H

#include "xil_types.h"
#include "Hdmi/Inc/ps_app_edid.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PS_APP_VIDEO_MODE_VGA_INPUT_WIDTH   640U
#define PS_APP_VIDEO_MODE_VGA_INPUT_HEIGHT  480U
#define PS_APP_VIDEO_MODE_NATIVE_INPUT_WIDTH  1280U
#define PS_APP_VIDEO_MODE_NATIVE_INPUT_HEIGHT 720U
#define PS_APP_VIDEO_MODE_SOURCE_MAX_WIDTH  PS_APP_VIDEO_MODE_NATIVE_INPUT_WIDTH
#define PS_APP_VIDEO_MODE_SOURCE_MAX_HEIGHT PS_APP_VIDEO_MODE_NATIVE_INPUT_HEIGHT
#define PS_APP_VIDEO_MODE_MIN_TMDS_MHZ      75U

#define PS_APP_VIDEO_MODE_REG_CTRL          0x00U
#define PS_APP_VIDEO_MODE_REG_SIZE          0x04U
#define PS_APP_VIDEO_MODE_REG_STRIDE        0x08U
#define PS_APP_VIDEO_MODE_REG_BRAM_BASE     0x0CU
#define PS_APP_VIDEO_MODE_REG_STATUS        0x10U
#define PS_APP_VIDEO_MODE_REG_ACTIVE_CFG    0x1CU
#define PS_APP_VIDEO_MODE_REG_OFFSETS       0x20U
#define PS_APP_VIDEO_MODE_REG_SOURCE_ORIGIN 0x24U
#define PS_APP_VIDEO_MODE_REG_X_RATIO       0x28U
#define PS_APP_VIDEO_MODE_REG_Y_RATIO       0x2CU

#define PS_APP_VIDEO_MODE_CTRL_ENABLE        (1U << 0)
#define PS_APP_VIDEO_MODE_CTRL_SOURCE_VDMA  (2U << 1)
#define PS_APP_VIDEO_MODE_CTRL_SCALE_NEAREST (1U << 3)
#define PS_APP_VIDEO_MODE_CTRL_FORMAT_XRGB8888 (2U << 5)
#define PS_APP_VIDEO_MODE_CTRL_COMMIT        (1U << 8)
#define PS_APP_VIDEO_MODE_CTRL_CLEAR_ERRORS  (1U << 10)
#define PS_APP_VIDEO_MODE_CTRL_HDMI_LINK     (1U << 13)
#define PS_APP_VIDEO_MODE_CTRL_MODE_SHIFT    14U
#define PS_APP_VIDEO_MODE_CTRL_MODE_MASK     (3U << PS_APP_VIDEO_MODE_CTRL_MODE_SHIFT)
#define PS_APP_VIDEO_MODE_CTRL_ABORT_STREAM  (1U << 11)
#define PS_APP_VIDEO_MODE_CTRL_MODE_COMMIT   (1U << 16)

#define PS_APP_VIDEO_MODE_STATUS_VIDEO_BUSY  (1U << 4)
#define PS_APP_VIDEO_MODE_STATUS_STREAM_HELD (1U << 1)
#define PS_APP_VIDEO_MODE_STATUS_CFG_PENDING (1U << 2)
#define PS_APP_VIDEO_MODE_STATUS_MODE_BUSY   (1U << 30)
#define PS_APP_VIDEO_MODE_STATUS_MODE_ERROR  (1U << 31)
#define PS_APP_VIDEO_MODE_STATUS_MODE_SHIFT  28U
#define PS_APP_VIDEO_MODE_STATUS_MODE_MASK   (3U << PS_APP_VIDEO_MODE_STATUS_MODE_SHIFT)

typedef enum {
    PS_APP_VIDEO_MODE_VGA480 = 0U,
    PS_APP_VIDEO_MODE_720P60 = 1U,
    PS_APP_VIDEO_MODE_1080P30 = 2U
} PsAppVideoModeId;

typedef struct {
    u8 mode_id;
    u8 vic;
    u16 output_width;
    u16 output_height;
    u16 active_width;
    u16 active_height;
    u16 x_offset;
    u16 y_offset;
    u16 source_x_origin;
    u16 source_y_origin;
    u16 source_x_step;
    u16 source_x_rem;
    u16 source_y_step;
    u16 source_y_rem;
} PsAppVideoModeProfile;

typedef struct {
    u32 (*read_reg)(void *context, u32 offset);
    void (*write_reg)(void *context, u32 offset, u32 value);
    void *context;
} PsAppVideoModeRegisterIo;

typedef struct {
    u8 active_mode;
    u8 busy;
    u8 error;
} PsAppVideoModeStatus;

typedef enum {
    PS_APP_VIDEO_MODE_OK = 0,
    PS_APP_VIDEO_MODE_ERR_ARGUMENT = -1,
    PS_APP_VIDEO_MODE_ERR_BUSY = -2,
    PS_APP_VIDEO_MODE_ERR_TIMEOUT = -3
} PsAppVideoModeResult;

/* Select 720p60 first, then 1080p30; otherwise return the VGA480 fallback. */
int PsAppVideoMode_Select(const PsAppHdmiEdidInfo *edid,
                          u16 source_width,
                          u16 source_height,
                          PsAppVideoModeProfile *profile);

/* Compute a centered aspect-fit window and DDA ratios for the selected output. */
int PsAppVideoMode_Compute(u8 mode_id,
                           u16 source_width,
                           u16 source_height,
                           PsAppVideoModeProfile *profile);

/* Stage geometry and mode request, then issue one combined scaler+mode commit. */
int PsAppVideoMode_Commit(const PsAppVideoModeRegisterIo *io,
                          const PsAppVideoModeProfile *profile,
                          u16 source_width,
                          u16 source_height,
                          u32 stride_bytes,
                          u32 frame0_address);
/* Initial native-input boot setup uses the fixed VGA timing without a mode request pulse. */
int PsAppVideoMode_CommitScalerOnly(const PsAppVideoModeRegisterIo *io,
                                    const PsAppVideoModeProfile *profile,
                                    u16 source_width,
                                    u16 source_height,
                                    u32 stride_bytes,
                                    u32 frame0_address);

int PsAppVideoMode_ReadStatus(const PsAppVideoModeRegisterIo *io,
                              PsAppVideoModeStatus *status);

#ifdef __cplusplus
}
#endif
#endif

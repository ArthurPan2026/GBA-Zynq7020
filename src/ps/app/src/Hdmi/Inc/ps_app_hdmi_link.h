#ifndef PS_APP_HDMI_LINK_H
#define PS_APP_HDMI_LINK_H

#include "xstatus.h"

#include "Hdmi/Inc/ps_app_hdmi_link_context.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Shared last_error values consumed by the link service and UI. */
enum {
    PS_APP_HDMI_ERR_NONE = 0U,
    PS_APP_HDMI_ERR_I2C1_CONFIG_MISSING = 1U,
    PS_APP_HDMI_ERR_I2C1_INIT_FAILED = 2U,
    PS_APP_HDMI_ERR_DDC_SEND_FAILED = 3U,
    PS_APP_HDMI_ERR_DDC_RECV_FAILED = 4U,
    PS_APP_HDMI_ERR_DDC_BUSY_TIMEOUT = 5U,
    PS_APP_HDMI_ERR_EDID_HEADER_INVALID = 6U,
    PS_APP_HDMI_ERR_EDID_CHECKSUM_INVALID = 7U,
    PS_APP_HDMI_ERR_EDID_VERSION_INVALID = 8U,
    PS_APP_HDMI_ERR_EDID_EXTENSION_READ_FAILED = 9U,
    PS_APP_HDMI_ERR_EDID_EXTENSION_CHECKSUM_INVALID = 10U,
    PS_APP_HDMI_ERR_EDID_EXTENSION_INVALID = 11U,
    PS_APP_HDMI_ERR_LINK_MODE_FAILED = 12U,
    PS_APP_HDMI_ERR_VIDEO_MODE_FAILED = 13U
};

XStatus PsAppHdmiLink_Init(PsAppHdmiLinkContext *ctx);
void PsAppHdmiLink_Service(PsAppHdmiLinkContext *ctx);
#define PS_APP_HDMI_MODE_AUTO 255U
#define PS_APP_HDMI_MODE_SAFE 254U
u8 PsAppHdmiLink_ModeSupported(const PsAppHdmiLinkContext *ctx, u8 mode);
XStatus PsAppHdmiLink_RequestMode(PsAppHdmiLinkContext *ctx, u8 mode);
void PsAppHdmiLink_ConfirmMode(PsAppHdmiLinkContext *ctx);
void PsAppHdmiLink_CancelModePreview(PsAppHdmiLinkContext *ctx);
u8 PsAppHdmiLink_PresentEnabled(const PsAppHdmiLinkContext *ctx);

#ifdef __cplusplus
}
#endif

#endif

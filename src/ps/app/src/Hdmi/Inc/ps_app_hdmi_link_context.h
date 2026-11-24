#ifndef PS_APP_HDMI_LINK_CONTEXT_H
#define PS_APP_HDMI_LINK_CONTEXT_H

#include "xil_types.h"
#include "xiicps.h"
#include "Common/Inc/ps_xgpiops_compat.h"

#include "Common/Inc/ps_app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

struct PsHdmiVdma;
struct PsAppVideoContext;

typedef struct PsAppHdmiLinkContext {
    PsAppHdmiLinkState *state;
    XGpioPs *ps_gpio;
    struct PsHdmiVdma *vdma;
    struct PsAppVideoContext *video_ctx;
    XIicPs i2c_ddc;
    u8 i2c_ready;
    u8 hpd_pin;
    u8 reserved0;
    u8 reserved1;
    u32 last_poll_tick;
} PsAppHdmiLinkContext;

#ifdef __cplusplus
}
#endif

#endif

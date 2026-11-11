#ifndef PS_APP_INPUT_PROFILE_H
#define PS_APP_INPUT_PROFILE_H

#include "Input/Inc/ps_app_input_device.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PS_APP_INPUT_DRIVER_ID_NONE = 0U,
    PS_APP_INPUT_DRIVER_ID_SWITCH_HID = 1U,
    PS_APP_INPUT_DRIVER_ID_8BITDO = 2U,
    PS_APP_INPUT_DRIVER_ID_GENERIC_XINPUT = 3U,
    PS_APP_INPUT_DRIVER_ID_8BITDO_HID = 4U
} PsAppInputDriverId;

enum {
    PS_APP_INPUT_HOST_INIT_NONE = 0U,
    PS_APP_INPUT_HOST_INIT_SWITCH_REPORT_MODE = (1U << 0U),
    PS_APP_INPUT_HOST_INIT_SIDEBAND = (1U << 1U),
    PS_APP_INPUT_HOST_INIT_SIDEBAND_ONE_SHOT = (1U << 2U),
    PS_APP_INPUT_HOST_INIT_SHORT_FIRST_REPORT_FALLBACK = (1U << 3U)
};

enum {
    PS_APP_INPUT_PROFILE_MATCH_CLASS = (1U << 0U),
    PS_APP_INPUT_PROFILE_MATCH_SUBCLASS = (1U << 1U),
    PS_APP_INPUT_PROFILE_MATCH_PROTOCOL = (1U << 2U)
};

typedef struct PsAppInputDeviceProfile {
    PsAppInputDriverId driver_id;
    u16 vendor_id;
    u16 product_id;
    u8 interface_class;
    u8 interface_subclass;
    u8 interface_protocol;
    u8 interface_match_mask;
    u32 host_init_policy;
    u32 first_report_fallback_timeout_ms;
} PsAppInputDeviceProfile;

/* FindByIds ignores the interface descriptor; FindForDevice enforces it. */
const PsAppInputDeviceProfile *PsAppInputProfile_FindByIds(u16 vendor_id, u16 product_id);
const PsAppInputDeviceProfile *PsAppInputProfile_FindForDevice(
    const PsAppInputUsbDeviceInfo *device);
u8 PsAppInputProfile_Is8BitDo(u16 vendor_id, u16 product_id);

#ifdef __cplusplus
}
#endif

#endif

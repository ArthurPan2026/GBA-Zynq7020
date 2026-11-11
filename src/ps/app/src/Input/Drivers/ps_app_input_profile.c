#include "Input/Inc/ps_app_input_profile.h"

#include <stddef.h>

#define PS_APP_INPUT_INTERFACE_CLASS_HID 0x03U
#define PS_APP_INPUT_INTERFACE_CLASS_XINPUT 0xFFU
#define PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT 0x5DU
#define PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT 0x01U

#define PS_APP_INPUT_MATCH_XINPUT \
    (PS_APP_INPUT_PROFILE_MATCH_CLASS | \
     PS_APP_INPUT_PROFILE_MATCH_SUBCLASS | \
     PS_APP_INPUT_PROFILE_MATCH_PROTOCOL)

static const PsAppInputDeviceProfile s_device_profiles[] = {
    {
        PS_APP_INPUT_DRIVER_ID_SWITCH_HID,
        0x057EU, 0x2009U,
        PS_APP_INPUT_INTERFACE_CLASS_HID, 0U, 0U,
        PS_APP_INPUT_PROFILE_MATCH_CLASS,
        PS_APP_INPUT_HOST_INIT_SWITCH_REPORT_MODE,
        0U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO_HID,
        0x2DC8U, 0x6013U,
        PS_APP_INPUT_INTERFACE_CLASS_HID, 0U, 0U,
        PS_APP_INPUT_PROFILE_MATCH_CLASS,
        PS_APP_INPUT_HOST_INIT_NONE,
        0U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO,
        0x2DC8U, 0x3106U,
        PS_APP_INPUT_INTERFACE_CLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT,
        PS_APP_INPUT_MATCH_XINPUT,
        PS_APP_INPUT_HOST_INIT_SIDEBAND,
        0U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO,
        0x2DC8U, 0x3109U,
        PS_APP_INPUT_INTERFACE_CLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT,
        PS_APP_INPUT_MATCH_XINPUT,
        PS_APP_INPUT_HOST_INIT_SIDEBAND,
        0U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO,
        0x2DC8U, 0x310BU,
        PS_APP_INPUT_INTERFACE_CLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT,
        PS_APP_INPUT_MATCH_XINPUT,
        PS_APP_INPUT_HOST_INIT_SIDEBAND |
            PS_APP_INPUT_HOST_INIT_SIDEBAND_ONE_SHOT |
            PS_APP_INPUT_HOST_INIT_SHORT_FIRST_REPORT_FALLBACK,
        3000U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO,
        0x2DC8U, 0x3110U,
        PS_APP_INPUT_INTERFACE_CLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT,
        PS_APP_INPUT_MATCH_XINPUT,
        PS_APP_INPUT_HOST_INIT_SIDEBAND,
        0U
    },
    {
        PS_APP_INPUT_DRIVER_ID_8BITDO,
        0x2DC8U, 0x3111U,
        PS_APP_INPUT_INTERFACE_CLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_SUBCLASS_XINPUT,
        PS_APP_INPUT_INTERFACE_PROTOCOL_XINPUT,
        PS_APP_INPUT_MATCH_XINPUT,
        PS_APP_INPUT_HOST_INIT_SIDEBAND,
        0U
    }
};

const PsAppInputDeviceProfile *PsAppInputProfile_FindByIds(u16 vendor_id, u16 product_id) {
    size_t index;

    for (index = 0U; index < (sizeof(s_device_profiles) / sizeof(s_device_profiles[0])); ++index) {
        const PsAppInputDeviceProfile *profile = &s_device_profiles[index];
        if ((profile->vendor_id == vendor_id) && (profile->product_id == product_id)) {
            return profile;
        }
    }
    return NULL;
}

const PsAppInputDeviceProfile *PsAppInputProfile_FindForDevice(
    const PsAppInputUsbDeviceInfo *device) {
    const PsAppInputDeviceProfile *profile;

    if (device == NULL) {
        return NULL;
    }
    profile = PsAppInputProfile_FindByIds(device->vendor_id, device->product_id);
    if (profile == NULL) {
        return NULL;
    }
    if (((profile->interface_match_mask & PS_APP_INPUT_PROFILE_MATCH_CLASS) != 0U) &&
        (device->interface_class != profile->interface_class)) {
        return NULL;
    }
    if (((profile->interface_match_mask & PS_APP_INPUT_PROFILE_MATCH_SUBCLASS) != 0U) &&
        (device->interface_subclass != profile->interface_subclass)) {
        return NULL;
    }
    if (((profile->interface_match_mask & PS_APP_INPUT_PROFILE_MATCH_PROTOCOL) != 0U) &&
        (device->interface_protocol != profile->interface_protocol)) {
        return NULL;
    }
    return profile;
}

u8 PsAppInputProfile_Is8BitDo(u16 vendor_id, u16 product_id) {
    const PsAppInputDeviceProfile *profile =
        PsAppInputProfile_FindByIds(vendor_id, product_id);

    return (u8)((profile != NULL) &&
                ((profile->driver_id == PS_APP_INPUT_DRIVER_ID_8BITDO) ||
                 (profile->driver_id == PS_APP_INPUT_DRIVER_ID_8BITDO_HID)));
}

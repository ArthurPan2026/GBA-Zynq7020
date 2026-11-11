#include "Input/Inc/ps_app_input_driver.h"

#include <string.h>

static XStatus PsAppInputDriver_ProbeProfile(const PsAppInputUsbDeviceInfo *device,
                                               PsAppInputDriverId driver_id) {
    const PsAppInputDeviceProfile *profile = PsAppInputProfile_FindForDevice(device);

    return (profile != NULL && profile->driver_id == driver_id) ? XST_SUCCESS : XST_FAILURE;
}

static XStatus PsAppInputDriver_ProbeSwitch(const PsAppInputUsbDeviceInfo *device) {
    return PsAppInputDriver_ProbeProfile(device, PS_APP_INPUT_DRIVER_ID_SWITCH_HID);
}

static XStatus PsAppInputDriver_Probe8BitDo(const PsAppInputUsbDeviceInfo *device) {
    return PsAppInputDriver_ProbeProfile(device, PS_APP_INPUT_DRIVER_ID_8BITDO);
}

static XStatus PsAppInputDriver_ProbeGenericXinput(const PsAppInputUsbDeviceInfo *device) {
    if ((device != NULL) &&
        (PsXinput_IsInterfaceCompatible(device->interface_class,
                                        device->interface_subclass,
                                        device->interface_protocol) != 0U)) {
        return XST_SUCCESS;
    }
    return XST_FAILURE;
}

static XStatus PsAppInputDriver_InitSwitch(const PsAppInputUsbDeviceInfo *device) {
    if ((PsAppInputDriver_ProbeSwitch(device) == XST_SUCCESS) &&
        (device->ep_in_addr != 0U)) {
        return XST_SUCCESS;
    }
    return XST_INVALID_PARAM;
}

static XStatus PsAppInputDriver_Init8BitDo(const PsAppInputUsbDeviceInfo *device) {
    if ((PsAppInputDriver_Probe8BitDo(device) == XST_SUCCESS) &&
        (device->ep_in_addr != 0U)) {
        return XST_SUCCESS;
    }
    return XST_INVALID_PARAM;
}

static XStatus PsAppInputDriver_InitGenericXinput(const PsAppInputUsbDeviceInfo *device) {
    if ((PsAppInputDriver_ProbeGenericXinput(device) == XST_SUCCESS) &&
        (device->ep_in_addr != 0U)) {
        return XST_SUCCESS;
    }
    return XST_INVALID_PARAM;
}

static u8 PsAppInputDriver_AcceptAny(const PsAppInputUsbDeviceInfo *device,
                                     const u8 *report,
                                     u32 report_len) {
    (void)device;
    return (u8)((report != NULL) && (report_len > 0U));
}

static u8 PsAppInputDriver_IgnoreNone(const PsAppInputUsbDeviceInfo *device,
                                      const u8 *report,
                                      u32 report_len) {
    (void)device;
    (void)report;
    (void)report_len;
    return 0U;
}

static u8 PsAppInputDriver_Accept8BitDoMain(const PsAppInputUsbDeviceInfo *device,
                                            const u8 *report,
                                            u32 report_len) {
    (void)device;
    if (report == NULL) return 0U;
    return (u8)(((report_len >= 20U) &&
                 (report[0] == PS_XINPUT_REPORT_ID_DEFAULT) &&
                 (report[1] == PS_XINPUT_REPORT_SIZE_INPUT)) ||
                ((report_len >= 19U) &&
                 (report[0] == PS_XINPUT_REPORT_SIZE_INPUT)));
}

static u8 PsAppInputDriver_IgnoreSwitchSimple(const PsAppInputUsbDeviceInfo *device,
                                              const u8 *report,
                                              u32 report_len) {
    (void)device;
    return (u8)((report != NULL) && (report_len > 0U) && (report[0] == 0x3FU));
}

static u8 PsAppInputDriver_AcceptSwitchFull(const PsAppInputUsbDeviceInfo *device,
                                            const u8 *report,
                                            u32 report_len) {
    (void)device;
    return (u8)((report != NULL) &&
                (report_len >= 13U) &&
                ((report[0] == 0x30U) || (report[0] == 0x21U)));
}

static XStatus PsAppInputDriver_ParseXinput(const PsAppInputUsbDeviceInfo *device,
                                            const u8 *report,
                                            u32 report_len,
                                            PsAppInputPadState *out_pad) {
    (void)device;
    return PsXinput_ParseInputReport(report, report_len, out_pad);
}

static XStatus PsAppInputDriver_ParseSwitch(const PsAppInputUsbDeviceInfo *device,
                                            const u8 *report,
                                            u32 report_len,
                                            PsAppInputPadState *out_pad) {
    if ((PsAppInputDriver_AcceptSwitchFull(device, report, report_len) == 0U) &&
        (PsAppInputDriver_Accept8BitDoMain(device, report, report_len) == 0U)) {
        return XST_INVALID_PARAM;
    }
    /* Keep the existing Switch/XInput parser as the single protocol implementation. */
    return PsXinput_ParseInputReport(report, report_len, out_pad);
}

static XStatus PsAppInputDriver_Probe8BitDoHid(const PsAppInputUsbDeviceInfo *device) {
    return PsAppInputDriver_ProbeProfile(device, PS_APP_INPUT_DRIVER_ID_8BITDO_HID);
}

static XStatus PsAppInputDriver_Init8BitDoHid(const PsAppInputUsbDeviceInfo *device) {
    if ((PsAppInputDriver_Probe8BitDoHid(device) == XST_SUCCESS) &&
        (device->ep_in_addr != 0U)) {
        return XST_SUCCESS;
    }
    return XST_INVALID_PARAM;
}

static void PsAppInputDriver_BuildXinputOutput(const PsAppInputUsbDeviceInfo *device,
                                               u8 large_motor,
                                               u8 small_motor,
                                               u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]) {
    (void)device;
    PsXinput_BuildRumbleOutputReport(large_motor, small_motor, out_report);
}

static void PsAppInputDriver_Detach(const PsAppInputUsbDeviceInfo *device, u32 generation) {
    (void)device;
    (void)generation;
}

static const PsAppInputDriverOps s_switch_hid_ops = {
    PsAppInputDriver_ProbeSwitch,
    PsAppInputDriver_InitSwitch,
    PsAppInputDriver_IgnoreSwitchSimple,
    PsAppInputDriver_AcceptSwitchFull,
    PsAppInputDriver_ParseSwitch,
    NULL,
    PsAppInputDriver_Detach
};

static const PsAppInputDriverOps s_8bitdo_ops = {
    PsAppInputDriver_Probe8BitDo,
    PsAppInputDriver_Init8BitDo,
    PsAppInputDriver_IgnoreNone,
    PsAppInputDriver_Accept8BitDoMain,
    PsAppInputDriver_ParseXinput,
    PsAppInputDriver_BuildXinputOutput,
    PsAppInputDriver_Detach
};

static const PsAppInputDriverOps s_8bitdo_hid_ops = {
    PsAppInputDriver_Probe8BitDoHid,
    PsAppInputDriver_Init8BitDoHid,
    PsAppInputDriver_IgnoreNone,
    PsAppInputDriver_AcceptAny,
    PsAppInputDriver_ParseSwitch,
    NULL,
    PsAppInputDriver_Detach
};

static const PsAppInputDriverOps s_generic_xinput_ops = {
    PsAppInputDriver_ProbeGenericXinput,
    PsAppInputDriver_InitGenericXinput,
    PsAppInputDriver_IgnoreNone,
    PsAppInputDriver_AcceptAny,
    PsAppInputDriver_ParseXinput,
    PsAppInputDriver_BuildXinputOutput,
    PsAppInputDriver_Detach
};

static const PsAppInputDriver s_driver_registry[] = {
    { PS_APP_INPUT_DRIVER_ID_SWITCH_HID,
      "switch-hid-057e-2009",
      &s_switch_hid_ops },
    { PS_APP_INPUT_DRIVER_ID_8BITDO,
      "8bitdo-xinput-profile",
      &s_8bitdo_ops },
    { PS_APP_INPUT_DRIVER_ID_GENERIC_XINPUT,
      "generic-xinput",
      &s_generic_xinput_ops },
    { PS_APP_INPUT_DRIVER_ID_8BITDO_HID,
      "8bitdo-hid-gamepad",
      &s_8bitdo_hid_ops }
};

const PsAppInputDriver *PsAppInputDriver_Select(const PsAppInputUsbDeviceInfo *device) {
    size_t idx;

    if (device == NULL) return NULL;
    for (idx = 0U; idx < (sizeof(s_driver_registry) / sizeof(s_driver_registry[0])); ++idx) {
        const PsAppInputDriver *driver = &s_driver_registry[idx];
        if ((driver->ops != NULL) && (driver->ops->probe != NULL) &&
            (driver->ops->probe(device) == XST_SUCCESS)) {
            return driver;
        }
    }
    return NULL;
}

const PsAppInputDriver *PsAppInputDriver_GetById(PsAppInputDriverId id) {
    size_t idx;

    for (idx = 0U; idx < (sizeof(s_driver_registry) / sizeof(s_driver_registry[0])); ++idx) {
        if (s_driver_registry[idx].id == id) return &s_driver_registry[idx];
    }
    return NULL;
}


u32 PsAppInputDriver_GetHostInitPolicy(const PsAppInputDriver *driver,
                                       const PsAppInputUsbDeviceInfo *device) {
    const PsAppInputDeviceProfile *profile;

    if ((driver == NULL) || (device == NULL)) return PS_APP_INPUT_HOST_INIT_NONE;
    profile = PsAppInputProfile_FindForDevice(device);
    if ((profile == NULL) || (profile->driver_id != driver->id)) {
        return PS_APP_INPUT_HOST_INIT_NONE;
    }
    return profile->host_init_policy;
}


u8 PsAppInputDriver_IsGenerationValid(u32 generation) {
    return (u8)(generation != 0U);
}

u8 PsAppInputDriver_IsNewerGeneration(u32 candidate, u32 current) {
    u32 delta;
    if (PsAppInputDriver_IsGenerationValid(candidate) == 0U) return 0U;
    if (PsAppInputDriver_IsGenerationValid(current) == 0U) return 1U;
    delta = candidate - current;
    return (u8)((delta != 0U) && (delta < 0x80000000U));
}

u8 PsAppInputDriver_IsReportGenerationCurrent(u32 active, u32 report_generation) {
    return (u8)((PsAppInputDriver_IsGenerationValid(active) != 0U) &&
                (PsAppInputDriver_IsGenerationValid(report_generation) != 0U) &&
                (active == report_generation));
}

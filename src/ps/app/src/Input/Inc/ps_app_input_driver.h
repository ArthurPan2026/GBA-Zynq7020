#ifndef PS_APP_INPUT_DRIVER_H
#define PS_APP_INPUT_DRIVER_H

#include "Input/Inc/ps_app_input_device.h"
#include "Input/Inc/ps_app_input_profile.h"
#include "Input/Inc/ps_xinput_xbox360.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PS_APP_INPUT_DRIVER_STATUS_UNSUPPORTED XST_DEVICE_NOT_FOUND

typedef struct PsAppInputDriverOps {
    XStatus (*probe)(const PsAppInputUsbDeviceInfo *device);
    XStatus (*init)(const PsAppInputUsbDeviceInfo *device);
    u8 (*ignore_report)(const PsAppInputUsbDeviceInfo *device,
                        const u8 *report,
                        u32 report_len);
    u8 (*accept_report)(const PsAppInputUsbDeviceInfo *device,
                        const u8 *report,
                        u32 report_len);
    XStatus (*parse_input)(const PsAppInputUsbDeviceInfo *device,
                           const u8 *report,
                           u32 report_len,
                           PsAppInputPadState *out_pad);
    void (*build_output)(const PsAppInputUsbDeviceInfo *device,
                         u8 large_motor,
                         u8 small_motor,
                         u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]);
    void (*detach)(const PsAppInputUsbDeviceInfo *device, u32 generation);
} PsAppInputDriverOps;

typedef struct PsAppInputDriver {
    PsAppInputDriverId id;
    const char *name;
    const PsAppInputDriverOps *ops;
} PsAppInputDriver;

/* Registry order is deterministic: exact VID/PID, VID profile, generic XInput.
 * A NULL selection means unsupported; QueueUsbAttach reports the same via
 * PS_APP_INPUT_DRIVER_STATUS_UNSUPPORTED while preserving the legacy wrapper. */
const PsAppInputDriver *PsAppInputDriver_Select(const PsAppInputUsbDeviceInfo *device);
const PsAppInputDriver *PsAppInputDriver_GetById(PsAppInputDriverId id);
u32 PsAppInputDriver_GetHostInitPolicy(const PsAppInputDriver *driver,
                                       const PsAppInputUsbDeviceInfo *device);
u8 PsAppInputDriver_IsGenerationValid(u32 generation);
u8 PsAppInputDriver_IsNewerGeneration(u32 candidate, u32 current);
/* Strict transport reports require a nonzero generation equal to the active device. */
u8 PsAppInputDriver_IsReportGenerationCurrent(u32 active, u32 report_generation);

#ifdef __cplusplus
}
#endif

#endif

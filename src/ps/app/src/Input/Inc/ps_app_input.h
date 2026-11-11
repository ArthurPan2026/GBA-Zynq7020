#ifndef PS_APP_INPUT_H
#define PS_APP_INPUT_H

#include "xstatus.h"

#include "Input/Inc/ps_app_input_context.h"
#include "Input/Inc/ps_xinput_xbox360.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 输入源位图：
 * [0..15] 直接复用 XInput buttons 位；
 * [16..] 为触发键/摇杆阈值后的数字化方向。 */
#define PS_APP_INPUT_SRC_MASK_LT        (1UL << 16U)
#define PS_APP_INPUT_SRC_MASK_RT        (1UL << 17U)
#define PS_APP_INPUT_SRC_MASK_LS_RIGHT  (1UL << 18U)
#define PS_APP_INPUT_SRC_MASK_LS_LEFT   (1UL << 19U)
#define PS_APP_INPUT_SRC_MASK_LS_UP     (1UL << 20U)
#define PS_APP_INPUT_SRC_MASK_LS_DOWN   (1UL << 21U)

void PsAppInput_Init(PsAppInputContext *ctx);
void PsAppInput_Service(PsAppInputContext *ctx);
void PsAppInput_PublishFrame(PsAppInputContext *ctx, u32 frame_token);

/* Generation-tagged attach API; info->device_generation must be nonzero. */
XStatus PsAppInput_QueueUsbAttach(PsAppInputContext *ctx,
                                      const PsAppInputUsbDeviceInfo *info,
                                      u8 *driver_id_out,
                                      u32 *host_init_policy_out);
XStatus PsAppInput_OnUsbXInputAttached(PsAppInputContext *ctx,
                                       const PsAppInputUsbDeviceInfo *info);
/* Legacy generation-less adapter; snapshots the current generation at enqueue. */
void PsAppInput_OnUsbDetached(PsAppInputContext *ctx);
/* Strict detach API; device_generation must be nonzero and current. */
XStatus PsAppInput_OnUsbDetachedGeneration(PsAppInputContext *ctx, u32 device_generation);
/* Strict transport path: device_generation must be nonzero and current. */
XStatus PsAppInput_OnTransportReport(PsAppInputContext *ctx,
                                     u32 device_generation,
                                     const u8 *report,
                                     u32 report_len);
/* Legacy interrupt-IN adapter; snapshots the active generation at enqueue. */
XStatus PsAppInput_OnInterruptInReport(PsAppInputContext *ctx,
                                       const u8 *report,
                                       u32 report_len);
XStatus PsAppInput_InjectRawReport(PsAppInputContext *ctx,
                                   const u8 *report,
                                   u32 report_len);

u8 PsAppInput_ShouldOverrideKeys(const PsAppInputContext *ctx);
u8 PsAppInput_IsReleasePending(const PsAppInputContext *ctx);
void PsAppInput_ClearReleasePending(PsAppInputContext *ctx);
u32 PsAppInput_GetMappedKeys(const PsAppInputContext *ctx);
XStatus PsAppInput_BuildRumbleReportForDriver(u8 driver_id,
                                              const PsAppInputUsbDeviceInfo *device,
                                              u8 large_motor,
                                              u8 small_motor,
                                              u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]);
void PsAppInput_BuildRumbleReport(u8 large_motor,
                                  u8 small_motor,
                                  u8 out_report[PS_XINPUT_REPORT_SIZE_OUTPUT]);
void PsAppInput_PrintStatus(const PsAppInputContext *ctx);

void PsAppInput_BackendPoll(PsAppInputContext *ctx);

#ifdef __cplusplus
}
#endif

#endif

#ifndef PS_APP_VIDEO_H
#define PS_APP_VIDEO_H

#include "xstatus.h"

#include "Video/Inc/ps_app_video_context.h"
#include "Video/Inc/ps_app_video_mode_logic.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    u32 current_frame;
    u32 status;
    u32 error_mask;
    u32 control_reg;
    u32 channel_status_reg;
    u32 vertical_size;
    u32 horizontal_size;
    u32 stride_frame_delay;
    u32 park_pointer;
    u32 frame_start[3];
} PsAppVideoVdmaDiagnostics;

/* Holds the VDMA owner lock from begin through end/abort. */
typedef struct {
    PsAppVideoContext *video;
    u32 source_frame_idx;
    u32 target_frame_idx;
    u8 active;
} PsAppVideoUiFrameUpdate;

XStatus PsAppVideo_InitDisplay(PsAppVideoContext *ctx,
                               u32 vdma_base_addr,
                               UINTPTR video_core_register_base,
                               UINTPTR frame0_addr,
                               u32 frame_stride_bytes,
                               u32 width,
                               u32 height,
                               u32 bytes_per_pixel);
XStatus PsAppVideo_ApplyOutputMode(PsAppVideoContext *ctx, const PsAppVideoModeProfile *profile);
#define PS_APP_VIDEO_SOURCE_UI   0U
#define PS_APP_VIDEO_SOURCE_GAME 1U
XStatus PsAppVideo_SetSourceMode(PsAppVideoContext *ctx, u8 source_mode);
XStatus PsAppVideo_InitInterrupts(PsAppVideoContext *ctx);
XStatus PsAppVideo_FillFrame(PsAppVideoContext *ctx, u32 frame_idx, u32 color_xrgb8888);
XStatus PsAppVideo_FillAllFrames(PsAppVideoContext *ctx, u32 color_xrgb8888);
XStatus PsAppVideo_GetVdmaStatus(PsAppVideoContext *ctx,
                                 u32 *current_frame_out,
                                 u32 *status_out,
                                 u32 *error_mask_out);
XStatus PsAppVideo_ReadVdmaDiagnostics(PsAppVideoContext *ctx,
                                       PsAppVideoVdmaDiagnostics *out);
XStatus PsAppVideo_RequestFrame(PsAppVideoContext *ctx, u32 frame_idx);
XStatus PsAppVideo_BeginUiRender(void);
u8 PsAppVideo_GameFrameSubmittedLocked(PsAppVideoContext *ctx);
u8 PsAppVideo_GameFrameScanning(PsAppVideoContext *ctx);
void PsAppVideo_EndUiRender(void);
void PsAppVideo_RegisterUiFrameWaiter(void);
XStatus PsAppVideo_WaitUiFrame(PsAppVideoContext *ctx, u32 frame_idx, u32 timeout_ms);
XStatus PsAppVideo_BeginUiFrameUpdate(PsAppVideoContext *ctx,
                                      PsAppVideoUiFrameUpdate *update);
XStatus PsAppVideo_EndUiFrameUpdate(PsAppVideoUiFrameUpdate *update);
void PsAppVideo_AbortUiFrameUpdate(PsAppVideoUiFrameUpdate *update);
void PsAppVideo_AttemptRecover(PsAppVideoContext *ctx, u32 vdma_status, u32 vdma_errs);
void PsAppVideo_SyncDisplayFrame(PsAppVideoContext *ctx);
XStatus PsAppVideo_RenderBootFrames(PsAppVideoContext *ctx);
void PsAppVideo_PresentCapturedFrameIfReady(PsAppVideoContext *ctx);
void PsAppVideo_SetInterframeMode(PsAppVideoContext *ctx, u32 mode);
void PsAppVideo_SetShadeMode(PsAppVideoContext *ctx, u32 mode);
u32 PsAppVideo_GetInterframeMode(const PsAppVideoContext *ctx);
u32 PsAppVideo_GetShadeMode(const PsAppVideoContext *ctx);

u32 PsAppVideo_DefaultCaptureBuffer(PsAppVideoContext *ctx);
u32 PsAppVideo_DefaultFrameIndex(PsAppVideoContext *ctx);
void PsAppVideo_ReadCaptureStatus(PsAppVideoContext *ctx, u32 *seq_out, u32 *buf_out);
u32 PsAppVideo_ReadCaptureWord(u32 buf_idx, u32 word_idx);
u16 PsAppVideo_ReadCapturePixelRgb565(u32 buf_idx, u32 x, u32 y);
u32 PsAppVideo_ComputeCaptureSparseHash(u32 buf_idx, u32 samples);
u32 PsAppVideo_ComputeCaptureRowHash(u32 buf_idx, u32 y);
u32 PsAppVideo_ComputeSparseHash(UINTPTR base_addr, u32 bytes, u32 samples);
u32 PsAppVideo_ReadHdmiFramePixel(PsAppVideoContext *ctx, u32 frame_idx, u32 x, u32 y);
u32 PsAppVideo_ConvertRgb565ToXrgb8888(u16 pixel);
void PsAppVideo_ComputeDisplayWindow(PsAppVideoContext *ctx,
                                     u32 *x_out,
                                     u32 *y_out,
                                     u32 *w_out,
                                     u32 *h_out);

#ifdef __cplusplus
}
#endif

#endif

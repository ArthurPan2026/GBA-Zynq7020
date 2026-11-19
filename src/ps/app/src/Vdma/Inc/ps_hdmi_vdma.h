#ifndef PS_HDMI_VDMA_H
#define PS_HDMI_VDMA_H

#include "xaxivdma.h"
#include "xstatus.h"
#include "xil_types.h"
#include "video_out_xilinx.h"
#include "Video/Inc/ps_app_video_mode_logic.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PsHdmiVdma {
    XAxiVdma vdma;
    VideoOutXilinx video_out;
    VideoOutConfig video_config;
    UINTPTR frame_addrs[3];
    u32 frame_buffer_span_bytes;
    u32 frame_pitch_bytes;
    u32 width;
    u32 height;
    u32 bytes_per_pixel;
    u32 line_stride_bytes;
    u32 frame_size_bytes;
    u32 frame_count;
    u8 is_ready;
} PsHdmiVdma;

XStatus PsHdmiVdma_Init(PsHdmiVdma *ctx,
                        u32 vdma_base_addr,
                        UINTPTR video_core_register_base,
                        UINTPTR frame0_addr,
                        u32 frame_stride_bytes,
                        u32 width,
                        u32 height,
                        u32 bytes_per_pixel);
XStatus PsHdmiVdma_ConfigureVideo(PsHdmiVdma *ctx,
                                  u32 width,
                                  u32 height,
                                  VideoOutScaleMode scale_mode);
/* Change only PL output timing/scaler geometry; VDMA source stays at 640x480 XRGB8888. */
XStatus PsHdmiVdma_ApplyOutputMode(PsHdmiVdma *ctx,
                                  const PsAppVideoModeProfile *profile);
XStatus PsHdmiVdma_ReadOutputModeStatus(PsHdmiVdma *ctx,
                                        PsAppVideoModeStatus *status);
XStatus PsHdmiVdma_Park(PsHdmiVdma *ctx, u32 frame_idx);
XStatus PsHdmiVdma_EnableCircular(PsHdmiVdma *ctx);
XStatus PsHdmiVdma_SetHdmiAudioEnabled(PsHdmiVdma *ctx, u8 enabled);
XStatus PsHdmiVdma_SetAudioMute(PsHdmiVdma *ctx, u8 mute);
XStatus PsHdmiVdma_SetAudioGainQ15(PsHdmiVdma *ctx, u16 gain_q15);
XStatus PsHdmiVdma_FillFrame(PsHdmiVdma *ctx, u32 frame_idx, u32 color_xrgb8888);
XStatus PsHdmiVdma_FillAllFrames(PsHdmiVdma *ctx, u32 color_xrgb8888);

#ifdef __cplusplus
}
#endif

#endif

#ifndef VIDEO_OUT_XILINX_H
#define VIDEO_OUT_XILINX_H

#include "video_out.h"
#include "xaxivdma.h"

#ifdef __cplusplus
extern "C" {
#endif

#define VIDEO_OUT_XILINX_MAX_FRAMES 8U

typedef struct {
    XAxiVdma *vdma;
    UINTPTR core_register_base;
    UINTPTR frame_base;
    uint32_t frame_buffer_span_bytes;
    uint32_t frame_count;
    uint32_t width;
    uint32_t height;
    uint32_t stride_bytes;
    uint8_t is_ready;
} VideoOutXilinx;

int VideoOutXilinx_Bind(VideoOutXilinx *adapter, XAxiVdma *vdma,
                        UINTPTR core_register_base, UINTPTR frame_base,
                        uint32_t frame_buffer_span_bytes, uint32_t frame_count);
VideoOutIo VideoOutXilinx_GetIo(VideoOutXilinx *adapter);
int VideoOutXilinx_Configure(VideoOutXilinx *adapter,
                             const VideoOutConfig *config,
                             uint32_t vdma_bytes_per_pixel);
int VideoOutXilinx_SetLinkMode(VideoOutXilinx *adapter, VideoOutLinkMode mode);
int VideoOutXilinx_SetHdmiAudioEnabled(VideoOutXilinx *adapter, uint8_t enabled);
int VideoOutXilinx_SetAudioMute(VideoOutXilinx *adapter, uint8_t muted);
int VideoOutXilinx_SetAudioGainQ15(VideoOutXilinx *adapter, uint32_t gain_q15);
int VideoOutXilinx_GetAudioStatus(VideoOutXilinx *adapter, VideoOutAudioStatus *status);

#ifdef __cplusplus
}
#endif
#endif

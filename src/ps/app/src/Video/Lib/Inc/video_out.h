#ifndef VIDEO_OUT_H
#define VIDEO_OUT_H

#include <stdint.h>

#define VIDEO_OUT_VERSION "0.3.0-dev.2"

#define VIDEO_OUT_OUTPUT_WIDTH 640U
#define VIDEO_OUT_OUTPUT_HEIGHT 480U
#define VIDEO_OUT_MAX_INPUT_WIDTH 1280U
#define VIDEO_OUT_MAX_INPUT_HEIGHT 720U

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { VIDEO_OUT_SOURCE_BRAM=0, VIDEO_OUT_SOURCE_HLS=1, VIDEO_OUT_SOURCE_VDMA=2 } VideoOutSource;
/* AXI4-Stream 视频 RGB888 按 AMD RBG 分量顺序传输；XRGB/BGRX 描述内存像素容器。 */
typedef enum {
    VIDEO_OUT_PIX_RGB565 = 0,
    VIDEO_OUT_PIX_RGB888 = 1,
    VIDEO_OUT_PIX_XRGB8888 = 2,
    VIDEO_OUT_PIX_BGRX8888 = 3
} VideoOutPixelFormat;
typedef enum { VIDEO_OUT_SCALE_BYPASS=0, VIDEO_OUT_SCALE_NEAREST=1 } VideoOutScaleMode;
typedef enum { VIDEO_OUT_ASPECT_FIT=0, VIDEO_OUT_ASPECT_STRETCH=1 } VideoOutAspectMode;
typedef enum { VIDEO_OUT_LINK_DVI=0, VIDEO_OUT_LINK_HDMI=1 } VideoOutLinkMode;

typedef struct {
    VideoOutSource source;
    VideoOutPixelFormat format;
    uint16_t width;
    uint16_t height;
    uint32_t stride_bytes;
    VideoOutScaleMode scale;
    VideoOutAspectMode aspect;
    uint8_t enabled;
    uint8_t initial_frame_index;
} VideoOutConfig;

typedef struct {
    uint8_t hdmi_audio_enabled;
    uint8_t fifo_underflow;
    uint8_t fifo_overflow;
} VideoOutAudioStatus;

typedef struct {
    uint32_t (*read_reg)(void *context, uint32_t offset);
    void (*write_reg)(void *context, uint32_t offset, uint32_t value);
    int (*configure_vdma)(void *context, uint64_t frame0,
                          uint32_t width, uint32_t height,
                          uint32_t bytes_per_pixel, uint32_t stride_bytes,
                          uint32_t initial_frame_index);
    void *context;
} VideoOutIo;

typedef struct {
    uint32_t frame_count;
    uint32_t error_flags;
    uint32_t active_source;
    uint32_t active_width;
    uint32_t active_height;
    uint8_t busy;
    uint8_t enabled;
    uint8_t stream_held;
    uint8_t config_pending;
    uint8_t hdmi_pixel_reset_released;
    uint8_t hdmi_serial_clock_seen;
    uint8_t hdmi_vsync_seen;
    uint8_t hdmi_mmcm_locked;
    uint8_t hdmi_pixel_clock_seen;
    uint8_t hdmi_pixel_reset_ext_asserted;
} VideoOutStatus;

int VideoOut_Configure(const VideoOutIo *io, const VideoOutConfig *config,
                       uint64_t frame0, uint32_t vdma_bytes_per_pixel);
int VideoOut_SetLinkMode(const VideoOutIo *io, VideoOutLinkMode mode);
int VideoOut_GetLinkMode(const VideoOutIo *io, VideoOutLinkMode *mode);
int VideoOut_Start(const VideoOutIo *io);
int VideoOut_BramSubmit(const VideoOutIo *io, uint32_t frame_base_word);
int VideoOut_Stop(const VideoOutIo *io);
int VideoOut_GetStatus(const VideoOutIo *io, VideoOutStatus *status);
int VideoOut_SetHdmiAudioEnabled(const VideoOutIo *io, uint8_t enabled);
int VideoOut_SetAudioMute(const VideoOutIo *io, uint8_t muted);
int VideoOut_SetAudioGainQ15(const VideoOutIo *io, uint32_t gain_q15);
int VideoOut_GetAudioStatus(const VideoOutIo *io, VideoOutAudioStatus *status);

#ifdef __cplusplus
}
#endif
#endif

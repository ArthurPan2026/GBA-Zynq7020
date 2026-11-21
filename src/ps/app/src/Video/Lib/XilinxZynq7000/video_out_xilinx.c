#include "video_out_xilinx.h"

#include "xil_io.h"
#include "xstatus.h"

static uint32_t VideoOutXilinx_ReadReg(void *context, uint32_t offset)
{
    VideoOutXilinx *adapter = (VideoOutXilinx *)context;
    return Xil_In32(adapter->core_register_base + offset);
}

static void VideoOutXilinx_WriteReg(void *context, uint32_t offset, uint32_t value)
{
    VideoOutXilinx *adapter = (VideoOutXilinx *)context;
    Xil_Out32(adapter->core_register_base + offset, value);
}

static int VideoOutXilinx_StopRead(VideoOutXilinx *adapter)
{
    uint32_t retry;
    if (adapter->is_ready == 0U)
        return 0;

    XAxiVdma_DmaStop(adapter->vdma, XAXIVDMA_READ);
    for (retry = 0U; retry < 100000U; ++retry) {
        if (XAxiVdma_IsBusy(adapter->vdma, XAXIVDMA_READ) == 0)
            return 0;
    }

    XAxiVdma_Reset(adapter->vdma, XAXIVDMA_READ);
    for (retry = 0U; retry < 100000U; ++retry) {
        if (XAxiVdma_ResetNotDone(adapter->vdma, XAXIVDMA_READ) == 0)
            return 0;
    }
    return -1;
}

static int VideoOutXilinx_ConfigureVdma(void *context, uint64_t frame0,
                                        uint32_t width, uint32_t height,
                                        uint32_t bytes_per_pixel,
                                        uint32_t stride_bytes, uint32_t initial_frame_index)
{
    VideoOutXilinx *adapter = (VideoOutXilinx *)context;
    XAxiVdma_DmaSetup setup;
    UINTPTR frame_addrs[VIDEO_OUT_XILINX_MAX_FRAMES];
    uint32_t required_bytes;
    uint32_t index;
    int status;

    if ((adapter == 0) || (adapter->vdma == 0) ||
        (adapter->frame_count == 0U) ||
        (adapter->frame_count > VIDEO_OUT_XILINX_MAX_FRAMES) ||
        (initial_frame_index >= adapter->frame_count) ||
        (width == 0U) || (height == 0U) ||
        (bytes_per_pixel != 4U) ||
        (stride_bytes < (width * bytes_per_pixel)))
        return -1;

    if (height > (UINT32_MAX / stride_bytes))
        return -1;
    required_bytes = stride_bytes * height;
    if (adapter->frame_buffer_span_bytes < required_bytes)
        return -1;

    if (VideoOutXilinx_StopRead(adapter) != 0)
        return -1;

    for (index = 0U; index < adapter->frame_count; ++index) {
        frame_addrs[index] = (UINTPTR)frame0 +
                             ((UINTPTR)index * adapter->frame_buffer_span_bytes);
    }

    setup.VertSizeInput = height;
    setup.HoriSizeInput = width * bytes_per_pixel;
    setup.Stride = stride_bytes;
    setup.FrameDelay = 0U;
    setup.EnableCircularBuf = 1U;
    setup.EnableSync = 0U;
    setup.PointNum = 0U;
    setup.EnableFrameCounter = 0U;
    setup.FixedFrameStoreAddr = 0U;
    setup.GenLockRepeat = 0U;
    setup.EnableVFlip = 0U;

    status = XAxiVdma_DmaConfig(adapter->vdma, XAXIVDMA_READ, &setup);
    if (status != XST_SUCCESS)
        return -1;
    status = XAxiVdma_DmaSetBufferAddr(adapter->vdma, XAXIVDMA_READ,
                                       frame_addrs);
    if (status != XST_SUCCESS)
        return -1;
    status = XAxiVdma_DmaStart(adapter->vdma, XAXIVDMA_READ);
    if (status != XST_SUCCESS)
        return -1;
    status = XAxiVdma_StartParking(adapter->vdma, (int)initial_frame_index, XAXIVDMA_READ);
    if (status != XST_SUCCESS) {
        XAxiVdma_DmaStop(adapter->vdma, XAXIVDMA_READ);
        return -1;
    }

    adapter->frame_base = (UINTPTR)frame0;
    adapter->width = width;
    adapter->height = height;
    adapter->stride_bytes = stride_bytes;
    adapter->is_ready = 1U;
    return 0;
}

int VideoOutXilinx_Bind(VideoOutXilinx *adapter, XAxiVdma *vdma,
                        UINTPTR core_register_base, UINTPTR frame_base,
                        uint32_t frame_buffer_span_bytes, uint32_t frame_count)
{
    if ((adapter == 0) || (vdma == 0) || (frame_buffer_span_bytes == 0U) ||
        (frame_count == 0U) || (frame_count > VIDEO_OUT_XILINX_MAX_FRAMES))
        return -1;

    adapter->vdma = vdma;
    adapter->core_register_base = core_register_base;
    adapter->frame_base = frame_base;
    adapter->frame_buffer_span_bytes = frame_buffer_span_bytes;
    adapter->frame_count = frame_count;
    adapter->width = 0U;
    adapter->height = 0U;
    adapter->stride_bytes = 0U;
    adapter->is_ready = 0U;
    return 0;
}

VideoOutIo VideoOutXilinx_GetIo(VideoOutXilinx *adapter)
{
    VideoOutIo io;
    io.read_reg = VideoOutXilinx_ReadReg;
    io.write_reg = VideoOutXilinx_WriteReg;
    io.configure_vdma = VideoOutXilinx_ConfigureVdma;
    io.context = adapter;
    return io;
}

int VideoOutXilinx_Configure(VideoOutXilinx *adapter,
                             const VideoOutConfig *config,
                             uint32_t vdma_bytes_per_pixel)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_Configure(&io, config, adapter->frame_base,
                              vdma_bytes_per_pixel);
}

int VideoOutXilinx_SetLinkMode(VideoOutXilinx *adapter, VideoOutLinkMode mode)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_SetLinkMode(&io, mode);
}

int VideoOutXilinx_SetHdmiAudioEnabled(VideoOutXilinx *adapter, uint8_t enabled)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_SetHdmiAudioEnabled(&io, enabled);
}

int VideoOutXilinx_SetAudioMute(VideoOutXilinx *adapter, uint8_t muted)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_SetAudioMute(&io, muted);
}

int VideoOutXilinx_SetAudioGainQ15(VideoOutXilinx *adapter, uint32_t gain_q15)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_SetAudioGainQ15(&io, gain_q15);
}

int VideoOutXilinx_GetAudioStatus(VideoOutXilinx *adapter,
                                  VideoOutAudioStatus *status)
{
    VideoOutIo io;
    if (adapter == 0)
        return -1;
    io = VideoOutXilinx_GetIo(adapter);
    return VideoOut_GetAudioStatus(&io, status);
}

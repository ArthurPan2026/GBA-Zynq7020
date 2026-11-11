#ifndef PS_APP_INPUT_CONTEXT_H
#define PS_APP_INPUT_CONTEXT_H

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"

#include "Common/Inc/ps_app_state.h"
#include "Input/Inc/ps_xinput_xbox360.h"
#include "Input/Inc/ps_app_input_device.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PS_APP_INPUT_EVENT_REPORT = 1U,
    PS_APP_INPUT_EVENT_ATTACHED = 2U,
    PS_APP_INPUT_EVENT_DETACHED = 3U,
    PS_APP_INPUT_EVENT_UNSUPPORTED = 4U,
    PS_APP_INPUT_EVENT_INJECT_REPORT = 5U
} PsAppInputEventType;

typedef struct {
    u8 type;
    u8 report_len;
    u16 reserved;
    u32 device_generation;
    union {
        PsAppInputUsbDeviceInfo device;
        u8 report[PS_XINPUT_MAX_REPORT_BYTES];
    } data;
} PsAppInputEvent;

#define PS_APP_INPUT_EVENT_QUEUE_DEPTH 16U

struct PsAppInputDriver;

typedef struct PsAppInputContext {
    PsAppInputState *state;
    QueueHandle_t event_queue;
    SemaphoreHandle_t event_control_lock;
    u32 producer_generation;
    const struct PsAppInputDriver *active_driver;
    PsAppInputUsbDeviceInfo active_device;
    u32 active_device_generation;
} PsAppInputContext;

#ifdef __cplusplus
}
#endif

#endif

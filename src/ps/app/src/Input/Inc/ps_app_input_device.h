#ifndef PS_APP_INPUT_DEVICE_H
#define PS_APP_INPUT_DEVICE_H

#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PsAppInputPadState {
    u16 buttons;
    u8 lt;
    u8 rt;
    s16 lx;
    s16 ly;
    s16 rx;
    s16 ry;
} PsAppInputPadState;

typedef struct PsAppInputUsbDeviceInfo {
    u16 vendor_id;
    u16 product_id;
    u8 interface_number;
    u8 interface_class;
    u8 interface_subclass;
    u8 interface_protocol;
    u8 ep_in_addr;
    u8 ep_out_addr;
    u8 ep_in_interval_ms;
    u8 ep_out_interval_ms;
    u32 device_generation;
} PsAppInputUsbDeviceInfo;

#ifdef __cplusplus
}
#endif

#endif

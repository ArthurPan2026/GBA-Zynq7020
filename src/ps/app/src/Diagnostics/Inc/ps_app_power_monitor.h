#ifndef PS_APP_POWER_MONITOR_H
#define PS_APP_POWER_MONITOR_H

#ifdef __cplusplus
extern "C" {
#endif

#include "xil_types.h"

typedef struct {
    u16 raw12;
    u32 current_ma;
} PsAppPowerSample;

int PsAppPowerMonitor_Init(void);
int PsAppPowerMonitor_Read(PsAppPowerSample *sample);

#ifdef __cplusplus
}
#endif

#endif

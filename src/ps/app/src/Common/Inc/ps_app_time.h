#ifndef PS_APP_TIME_H
#define PS_APP_TIME_H

#include "FreeRTOS.h"
#include "task.h"

#include "Common/Inc/ps_app_time_math.h"

#ifdef __cplusplus
extern "C" {
#endif

/* FreeRTOS adapter: durations are rounded up at the active tick rate. */
TickType_t PsAppTime_MsToTicksCeil(uint32_t milliseconds);
uint32_t PsAppTime_TicksToMsFloor(TickType_t ticks);
uint32_t PsAppTime_GetNowMs(void);
uint64_t PsAppTime_GetMetUs(void);
void PsAppTime_DelayMs(uint32_t milliseconds);

#ifdef __cplusplus
}
#endif

#endif

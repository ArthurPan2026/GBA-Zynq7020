#ifndef PS_APP_TIME_MATH_H
#define PS_APP_TIME_MATH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pure conversions shared by the FreeRTOS adapter and host-side tests. */
uint32_t PsAppTimeMath_MsToTicksCeil(uint32_t milliseconds,
                                    uint32_t tick_rate_hz,
                                    uint32_t max_ticks);
uint32_t PsAppTimeMath_TicksToMsFloor(uint64_t ticks,
                                      uint32_t tick_rate_hz);
uint64_t PsAppTimeMath_TicksToUs(uint64_t ticks,
                                uint32_t tick_rate_hz);

#ifdef __cplusplus
}
#endif

#endif

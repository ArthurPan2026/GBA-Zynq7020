#include "Common/Inc/ps_app_time_math.h"

#include <limits.h>

uint32_t PsAppTimeMath_MsToTicksCeil(uint32_t milliseconds,
                                    uint32_t tick_rate_hz,
                                    uint32_t max_ticks) {
    uint64_t scaled;
    uint64_t ticks;

    if ((milliseconds == 0U) || (tick_rate_hz == 0U) || (max_ticks == 0U)) {
        return 0U;
    }

    scaled = (uint64_t)milliseconds * (uint64_t)tick_rate_hz;
    ticks = scaled / 1000ULL;
    if ((scaled % 1000ULL) != 0ULL) {
        ticks++;
    }
    if (ticks == 0ULL) {
        ticks = 1ULL;
    }
    if (ticks > (uint64_t)max_ticks) {
        return max_ticks;
    }
    return (uint32_t)ticks;
}

uint32_t PsAppTimeMath_TicksToMsFloor(uint64_t ticks,
                                      uint32_t tick_rate_hz) {
    uint64_t whole_seconds;
    uint64_t remainder;
    uint64_t milliseconds;

    if (tick_rate_hz == 0U) {
        return 0U;
    }

    whole_seconds = ticks / (uint64_t)tick_rate_hz;
    remainder = ticks % (uint64_t)tick_rate_hz;
    if (whole_seconds > ((uint64_t)UINT32_MAX / 1000ULL)) {
        return UINT32_MAX;
    }
    milliseconds = (whole_seconds * 1000ULL) +
                   ((remainder * 1000ULL) / (uint64_t)tick_rate_hz);
    if (milliseconds > (uint64_t)UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)milliseconds;
}

uint64_t PsAppTimeMath_TicksToUs(uint64_t ticks,
                                uint32_t tick_rate_hz) {
    uint64_t whole_seconds;
    uint64_t remainder;
    uint64_t whole_us;
    uint64_t remainder_us;

    if (tick_rate_hz == 0U) {
        return 0ULL;
    }

    whole_seconds = ticks / (uint64_t)tick_rate_hz;
    remainder = ticks % (uint64_t)tick_rate_hz;
    if (whole_seconds > (UINT64_MAX / 1000000ULL)) {
        return UINT64_MAX;
    }
    whole_us = whole_seconds * 1000000ULL;
    remainder_us = (remainder * 1000000ULL) / (uint64_t)tick_rate_hz;
    if (whole_us > (UINT64_MAX - remainder_us)) {
        return UINT64_MAX;
    }
    return whole_us + remainder_us;
}

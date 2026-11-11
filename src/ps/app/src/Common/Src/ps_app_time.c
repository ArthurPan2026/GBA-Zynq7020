#include "Common/Inc/ps_app_time.h"

#include "sleep.h"

TickType_t PsAppTime_MsToTicksCeil(uint32_t milliseconds) {
    return (TickType_t)PsAppTimeMath_MsToTicksCeil(milliseconds,
                                                   (uint32_t)configTICK_RATE_HZ,
                                                   (uint32_t)portMAX_DELAY);
}

uint32_t PsAppTime_TicksToMsFloor(TickType_t ticks) {
    return PsAppTimeMath_TicksToMsFloor((uint64_t)ticks,
                                        (uint32_t)configTICK_RATE_HZ);
}

uint32_t PsAppTime_GetNowMs(void) {
    return PsAppTime_TicksToMsFloor(xTaskGetTickCount());
}

uint64_t PsAppTime_GetMetUs(void) {
    static TickType_t last_ticks = 0U;
    static uint64_t wrap_base = 0ULL;
    TickType_t now_ticks;
    uint64_t ticks_extended;

    taskENTER_CRITICAL();
    now_ticks = xTaskGetTickCount();
    if (now_ticks < last_ticks) {
        if (sizeof(TickType_t) < sizeof(uint64_t)) {
            wrap_base += (uint64_t)portMAX_DELAY + 1ULL;
        } else {
            wrap_base = 0ULL;
        }
    }
    last_ticks = now_ticks;
    ticks_extended = wrap_base + (uint64_t)now_ticks;
    taskEXIT_CRITICAL();

    return PsAppTimeMath_TicksToUs(ticks_extended,
                                   (uint32_t)configTICK_RATE_HZ);
}

void PsAppTime_DelayMs(uint32_t milliseconds) {
    TickType_t delay_ticks;

    if (milliseconds == 0U) {
        return;
    }
    if (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) {
        delay_ticks = PsAppTime_MsToTicksCeil(milliseconds);
        if (delay_ticks == 0U) {
            delay_ticks = 1U;
        }
        vTaskDelay(delay_ticks);
        return;
    }

    usleep((unsigned int)(milliseconds * 1000U));
}

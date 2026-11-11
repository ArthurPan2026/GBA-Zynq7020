#include "Save/Inc/ps_app_save_logic.h"

#include <limits.h>

void PsAppSaveLogic_Observe(PsAppSaveKindRuntime *runtime,
                            uint8_t dirty,
                            uint8_t busy,
                            uint32_t generation) {
    uint8_t pending;

    if (runtime == 0) return;
    pending = ((dirty != 0U) || (busy != 0U)) ? 1U : 0U;
    if (pending == 0U) {
        runtime->generation = generation;
        runtime->quiet_ticks = 0U;
        runtime->dirty_age_ticks = 0U;
        runtime->dirty = 0U;
        return;
    }
    if ((runtime->dirty == 0U) || (runtime->generation != generation)) {
        runtime->quiet_ticks = 0U;
        runtime->dirty_age_ticks = 0U;
    }
    runtime->generation = generation;
    runtime->dirty = 1U;
}

PsAppSaveLogicDecision PsAppSaveLogic_Tick(PsAppSaveKindRuntime *runtime,
                                           uint8_t busy,
                                           uint32_t quiet_threshold,
                                           uint32_t hard_threshold) {
    if ((runtime == 0) || (runtime->dirty == 0U)) {
        return PS_APP_SAVE_LOGIC_CLEAN;
    }
    if (busy != 0U) {
        return PS_APP_SAVE_LOGIC_WAIT_BUSY;
    }
    if (runtime->quiet_ticks < UINT32_MAX) runtime->quiet_ticks++;
    if (runtime->dirty_age_ticks < UINT32_MAX) runtime->dirty_age_ticks++;
    if ((runtime->quiet_ticks >= quiet_threshold) ||
        (runtime->dirty_age_ticks >= hard_threshold)) {
        return PS_APP_SAVE_LOGIC_FLUSH_DUE;
    }
    return PS_APP_SAVE_LOGIC_WAIT_QUIET;
}

void PsAppSaveLogic_ResetRetry(PsAppSaveKindRuntime *runtime) {
    if (runtime == 0) return;
    runtime->quiet_ticks = 0U;
    runtime->dirty_age_ticks = 0U;
}

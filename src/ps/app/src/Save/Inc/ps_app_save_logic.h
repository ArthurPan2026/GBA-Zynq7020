#ifndef PS_APP_SAVE_LOGIC_H
#define PS_APP_SAVE_LOGIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t generation;
    uint32_t quiet_ticks;
    uint32_t dirty_age_ticks;
    uint8_t dirty;
} PsAppSaveKindRuntime;

typedef enum {
    PS_APP_SAVE_LOGIC_CLEAN = 0U,
    PS_APP_SAVE_LOGIC_WAIT_BUSY = 1U,
    PS_APP_SAVE_LOGIC_WAIT_QUIET = 2U,
    PS_APP_SAVE_LOGIC_FLUSH_DUE = 3U
} PsAppSaveLogicDecision;

void PsAppSaveLogic_Observe(PsAppSaveKindRuntime *runtime,
                            uint8_t dirty,
                            uint8_t busy,
                            uint32_t generation);
PsAppSaveLogicDecision PsAppSaveLogic_Tick(PsAppSaveKindRuntime *runtime,
                                           uint8_t busy,
                                           uint32_t quiet_threshold,
                                           uint32_t hard_threshold);
void PsAppSaveLogic_ResetRetry(PsAppSaveKindRuntime *runtime);

#ifdef __cplusplus
}
#endif

#endif

#ifndef PS_APP_RUNTIME_COMMAND_LOGIC_H
#define PS_APP_RUNTIME_COMMAND_LOGIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t capacity;
    uint32_t outstanding;
    uint8_t owner_busy;
} PsAppRuntimeCommandQueueState;

typedef enum {
    PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED = 0U,
    PS_APP_RUNTIME_COMMAND_LOGIC_BUSY = 1U
} PsAppRuntimeCommandAdmission;

void PsAppRuntimeCommandLogic_Init(PsAppRuntimeCommandQueueState *state,
                                   uint32_t capacity);
PsAppRuntimeCommandAdmission PsAppRuntimeCommandLogic_TryReserve(PsAppRuntimeCommandQueueState *state);
void PsAppRuntimeCommandLogic_Release(PsAppRuntimeCommandQueueState *state);
uint8_t PsAppRuntimeCommandLogic_TryBegin(PsAppRuntimeCommandQueueState *state);
void PsAppRuntimeCommandLogic_Complete(PsAppRuntimeCommandQueueState *state);

#ifdef __cplusplus
}
#endif

#endif

#include "App/Inc/ps_app_runtime_command_logic.h"

void PsAppRuntimeCommandLogic_Init(PsAppRuntimeCommandQueueState *state,
                                   uint32_t capacity) {
    if (state == 0) return;
    state->capacity = capacity;
    state->outstanding = 0U;
    state->owner_busy = 0U;
}

PsAppRuntimeCommandAdmission PsAppRuntimeCommandLogic_TryReserve(PsAppRuntimeCommandQueueState *state) {
    if ((state == 0) || (state->outstanding >= state->capacity)) {
        return PS_APP_RUNTIME_COMMAND_LOGIC_BUSY;
    }
    state->outstanding++;
    return PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED;
}

void PsAppRuntimeCommandLogic_Release(PsAppRuntimeCommandQueueState *state) {
    if ((state != 0) && (state->outstanding > 0U)) state->outstanding--;
}

uint8_t PsAppRuntimeCommandLogic_TryBegin(PsAppRuntimeCommandQueueState *state) {
    if ((state == 0) || (state->owner_busy != 0U) || (state->outstanding == 0U)) {
        return 0U;
    }
    state->owner_busy = 1U;
    return 1U;
}

void PsAppRuntimeCommandLogic_Complete(PsAppRuntimeCommandQueueState *state) {
    if (state != 0) state->owner_busy = 0U;
}

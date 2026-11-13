#include "Common/Inc/ps_app_ui_launch_logic.h"

#include <stddef.h>

void PsAppUiLaunchLogic_ReturnToMenu(PsAppUiState *state) {
    if (state == NULL) {
        return;
    }

    state->mode = (u8)PS_APP_UI_MODE_MENU;
    state->refresh_requested = 0U;
    state->launch_requested = 0U;
    state->lt_hold_ms = 0U;
    state->lt_exit_latched = 0U;
    state->board_exit_hold_ms = 0U;
    state->board_exit_latched = 0U;
}

u8 PsAppUiLaunchLogic_WorkerStartResult(PsAppUiState *state, u8 worker_created) {
    if (state == NULL) {
        return 0U;
    }
    if (worker_created != 0U) {
        state->launch_requested = 0U;
        return 1U;
    }

    PsAppUiLaunchLogic_ReturnToMenu(state);
    return 0U;
}

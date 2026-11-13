#ifndef PS_APP_UI_LAUNCH_LOGIC_H
#define PS_APP_UI_LAUNCH_LOGIC_H

#include "Common/Inc/ps_app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

u8 PsAppUiLaunchLogic_WorkerStartResult(PsAppUiState *state, u8 worker_created);
void PsAppUiLaunchLogic_ReturnToMenu(PsAppUiState *state);

#ifdef __cplusplus
}
#endif

#endif

#ifndef PS_APP_RUNTIME_COMMAND_H
#define PS_APP_RUNTIME_COMMAND_H

#include "xstatus.h"

#include "App/Inc/ps_app_runtime_context.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG = 1U,
    PS_APP_RUNTIME_COMMAND_LOAD_ROM = 2U,
    PS_APP_RUNTIME_COMMAND_UNLOAD_ROM = 3U,
    PS_APP_RUNTIME_COMMAND_SAVE_STATE = 4U,
    PS_APP_RUNTIME_COMMAND_LOAD_STATE = 5U,
    PS_APP_RUNTIME_COMMAND_SET_STATE_SLOT = 6U
} PsAppRuntimeCommandType;

/* Initialize the fixed 16-entry Runtime command queue before the scheduler.
 * UI/console producers block for the completed result; a full queue returns
 * XST_DEVICE_BUSY. The bootstrap task executes synchronously before Monitor
 * becomes the Runtime owner, so autoload cannot wait on an unstarted owner. */
XStatus PsAppRuntimeCommand_Init(void);
void PsAppRuntimeCommand_SetBootstrapTask(void);
void PsAppRuntimeCommand_SetOwnerTask(void);
u8 PsAppRuntimeCommand_IsOwnerTask(void);
u8 PsAppRuntimeCommand_IsBootstrapTask(void);
u8 PsAppRuntimeCommand_IsReady(void);
XStatus PsAppRuntimeCommand_Submit(PsAppRuntimeContext *ctx,
                                   PsAppRuntimeCommandType command,
                                   const char *path,
                                   u32 value);
void PsAppRuntimeCommand_ProcessOne(PsAppRuntimeContext *ctx);

#ifdef __cplusplus
}
#endif

#endif

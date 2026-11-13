#ifndef PS_APP_ROM_LOAD_PROGRESS_H
#define PS_APP_ROM_LOAD_PROGRESS_H

#include "Common/Inc/ps_app_state.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    u8 phase;
    u8 result;
    u16 reserved0;
    u32 bytes_done;
    u32 total_bytes;
    u32 error_status;
    u32 attempt_id;
} PsAppRomLoadProgressSnapshot;

u32 PsAppRomLoadProgress_Begin(PsAppRomState *rom);
void PsAppRomLoadProgress_SetPhase(PsAppRomState *rom, PsAppRomLoadPhase phase);
void PsAppRomLoadProgress_UpdateRead(PsAppRomState *rom,
                                     u32 bytes_done,
                                     u32 total_bytes);
void PsAppRomLoadProgress_Complete(PsAppRomState *rom, int status);
u8 PsAppRomLoadProgress_FailIfUnchanged(PsAppRomState *rom,
                                        u32 expected_attempt_id,
                                        int status);
void PsAppRomLoadProgress_GetSnapshot(const PsAppRomState *rom,
                                      PsAppRomLoadProgressSnapshot *snapshot_out);
u8 PsAppRomLoadProgress_GetPercent(const PsAppRomLoadProgressSnapshot *snapshot,
                                   u8 *percent_out);

#ifdef __cplusplus
}
#endif

#endif

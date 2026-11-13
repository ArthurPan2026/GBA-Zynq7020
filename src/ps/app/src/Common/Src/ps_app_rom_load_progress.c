#include "Common/Inc/ps_app_rom_load_progress.h"

#include <stddef.h>

#include "FreeRTOS.h"
#include "task.h"
#include "xstatus.h"

u32 PsAppRomLoadProgress_Begin(PsAppRomState *rom) {
    u32 attempt_id;

    if (rom == NULL) {
        return 0U;
    }

    taskENTER_CRITICAL();
    attempt_id = rom->load_attempt_id + 1U;
    if (attempt_id == 0U) {
        attempt_id = 1U;
    }
    rom->load_attempt_id = attempt_id;
    rom->load_phase = (u8)PS_APP_ROM_LOAD_PHASE_PREPARE;
    rom->load_result = (u8)PS_APP_ROM_LOAD_RESULT_RUNNING;
    rom->load_bytes_done = 0U;
    rom->load_total_bytes = 0U;
    rom->load_error_status = 0U;
    taskEXIT_CRITICAL();

    return attempt_id;
}

void PsAppRomLoadProgress_SetPhase(PsAppRomState *rom, PsAppRomLoadPhase phase) {
    if (rom == NULL) {
        return;
    }

    taskENTER_CRITICAL();
    if (rom->load_result == (u8)PS_APP_ROM_LOAD_RESULT_RUNNING) {
        rom->load_phase = (u8)phase;
    }
    taskEXIT_CRITICAL();
}

void PsAppRomLoadProgress_UpdateRead(PsAppRomState *rom,
                                     u32 bytes_done,
                                     u32 total_bytes) {
    if (rom == NULL) {
        return;
    }

    taskENTER_CRITICAL();
    if (rom->load_result == (u8)PS_APP_ROM_LOAD_RESULT_RUNNING) {
        rom->load_phase = (u8)PS_APP_ROM_LOAD_PHASE_READING;
        rom->load_total_bytes = total_bytes;
        if ((total_bytes != 0U) && (bytes_done > total_bytes)) {
            bytes_done = total_bytes;
        }
        rom->load_bytes_done = (total_bytes == 0U) ? 0U : bytes_done;
    }
    taskEXIT_CRITICAL();
}

void PsAppRomLoadProgress_Complete(PsAppRomState *rom, int status) {
    if (rom == NULL) {
        return;
    }

    taskENTER_CRITICAL();
    rom->load_error_status = (u32)status;
    if (status == XST_SUCCESS) {
        rom->load_phase = (u8)PS_APP_ROM_LOAD_PHASE_WAIT_FRAME;
        rom->load_result = (u8)PS_APP_ROM_LOAD_RESULT_SUCCESS;
    } else {
        rom->load_phase = (u8)PS_APP_ROM_LOAD_PHASE_FAILED;
        rom->load_result = (u8)PS_APP_ROM_LOAD_RESULT_FAILED;
    }
    taskEXIT_CRITICAL();
}

u8 PsAppRomLoadProgress_FailIfUnchanged(PsAppRomState *rom,
                                        u32 expected_attempt_id,
                                        int status) {
    u8 changed = 0U;
    u32 attempt_id;

    if (rom == NULL) {
        return 0U;
    }

    taskENTER_CRITICAL();
    if ((rom->load_attempt_id == expected_attempt_id) &&
        (rom->load_result != (u8)PS_APP_ROM_LOAD_RESULT_RUNNING)) {
        attempt_id = expected_attempt_id + 1U;
        if (attempt_id == 0U) {
            attempt_id = 1U;
        }
        rom->load_attempt_id = attempt_id;
        rom->load_phase = (u8)PS_APP_ROM_LOAD_PHASE_FAILED;
        rom->load_result = (u8)PS_APP_ROM_LOAD_RESULT_FAILED;
        rom->load_bytes_done = 0U;
        rom->load_total_bytes = 0U;
        rom->load_error_status = (u32)status;
        changed = 1U;
    }
    taskEXIT_CRITICAL();

    return changed;
}

void PsAppRomLoadProgress_GetSnapshot(const PsAppRomState *rom,
                                      PsAppRomLoadProgressSnapshot *snapshot_out) {
    if (snapshot_out == NULL) {
        return;
    }
    snapshot_out->phase = (u8)PS_APP_ROM_LOAD_PHASE_IDLE;
    snapshot_out->result = (u8)PS_APP_ROM_LOAD_RESULT_IDLE;
    snapshot_out->reserved0 = 0U;
    snapshot_out->bytes_done = 0U;
    snapshot_out->total_bytes = 0U;
    snapshot_out->error_status = 0U;
    snapshot_out->attempt_id = 0U;
    if (rom == NULL) {
        return;
    }

    taskENTER_CRITICAL();
    snapshot_out->phase = rom->load_phase;
    snapshot_out->result = rom->load_result;
    snapshot_out->bytes_done = rom->load_bytes_done;
    snapshot_out->total_bytes = rom->load_total_bytes;
    snapshot_out->error_status = rom->load_error_status;
    snapshot_out->attempt_id = rom->load_attempt_id;
    taskEXIT_CRITICAL();
}

u8 PsAppRomLoadProgress_GetPercent(const PsAppRomLoadProgressSnapshot *snapshot,
                                   u8 *percent_out) {
    u32 bytes_done;
    u64 scaled_percent;

    if ((snapshot == NULL) ||
        (percent_out == NULL) ||
        (snapshot->result == (u8)PS_APP_ROM_LOAD_RESULT_IDLE) ||
        (snapshot->result == (u8)PS_APP_ROM_LOAD_RESULT_FAILED) ||
        (snapshot->total_bytes == 0U)) {
        return 0U;
    }

    if ((snapshot->phase != (u8)PS_APP_ROM_LOAD_PHASE_READING) &&
        (snapshot->phase != (u8)PS_APP_ROM_LOAD_PHASE_FINALIZING) &&
        (snapshot->phase != (u8)PS_APP_ROM_LOAD_PHASE_WAIT_FRAME)) {
        return 0U;
    }

    bytes_done = snapshot->bytes_done;
    if (bytes_done > snapshot->total_bytes) {
        bytes_done = snapshot->total_bytes;
    }
    scaled_percent = ((u64)bytes_done * 100ULL) / (u64)snapshot->total_bytes;
    if (scaled_percent > 100ULL) {
        scaled_percent = 100ULL;
    }
    *percent_out = (u8)scaled_percent;
    return 1U;
}

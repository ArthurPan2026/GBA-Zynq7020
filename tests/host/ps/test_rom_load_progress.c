#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "Common/Inc/ps_app_rom_load_progress.h"
#include "Common/Inc/ps_app_ui_launch_logic.h"
#include "xstatus.h"

#define READ_CHUNK_BYTES (128U * 1024U)

static u8 read_percent(PsAppRomState *rom) {
    PsAppRomLoadProgressSnapshot snapshot;
    u8 percent = 0U;

    PsAppRomLoadProgress_GetSnapshot(rom, &snapshot);
    assert(PsAppRomLoadProgress_GetPercent(&snapshot, &percent) != 0U);
    return percent;
}

static void test_chunk_progress_is_monotonic_and_finishes_at_total(void) {
    PsAppRomState rom;
    PsAppRomLoadProgressSnapshot snapshot;
    const u32 total_bytes = (2U * READ_CHUNK_BYTES) + 73U;
    u32 bytes_done = 0U;
    u8 last_percent = 0U;

    memset(&rom, 0, sizeof(rom));
    assert(PsAppRomLoadProgress_Begin(&rom) != 0U);
    PsAppRomLoadProgress_UpdateRead(&rom, 0U, total_bytes);
    assert(read_percent(&rom) == 0U);

    while (bytes_done < total_bytes) {
        u32 chunk = total_bytes - bytes_done;

        if (chunk > READ_CHUNK_BYTES) {
            chunk = READ_CHUNK_BYTES;
        }
        bytes_done += chunk;
        PsAppRomLoadProgress_UpdateRead(&rom, bytes_done, total_bytes);
        assert(read_percent(&rom) >= last_percent);
        last_percent = read_percent(&rom);
    }
    assert(bytes_done == total_bytes);
    assert(last_percent == 100U);

    PsAppRomLoadProgress_SetPhase(&rom, PS_APP_ROM_LOAD_PHASE_FINALIZING);
    PsAppRomLoadProgress_Complete(&rom, XST_SUCCESS);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(snapshot.phase == (u8)PS_APP_ROM_LOAD_PHASE_WAIT_FRAME);
    assert(snapshot.result == (u8)PS_APP_ROM_LOAD_RESULT_SUCCESS);
    assert(read_percent(&rom) == 100U);
}

static void test_zero_total_is_indeterminate_and_overrun_clamps(void) {
    PsAppRomState rom;
    PsAppRomLoadProgressSnapshot snapshot;
    u8 percent = 0xFFU;

    memset(&rom, 0, sizeof(rom));
    (void)PsAppRomLoadProgress_Begin(&rom);
    PsAppRomLoadProgress_UpdateRead(&rom, 0U, 0U);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(PsAppRomLoadProgress_GetPercent(&snapshot, &percent) == 0U);

    (void)PsAppRomLoadProgress_Begin(&rom);
    PsAppRomLoadProgress_UpdateRead(&rom, 150U, 100U);
    assert(read_percent(&rom) == 100U);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(snapshot.bytes_done == 100U);
}

static void test_failure_never_reports_full_success(void) {
    PsAppRomState rom;
    PsAppRomLoadProgressSnapshot snapshot;
    u8 percent = 0xFFU;

    memset(&rom, 0, sizeof(rom));
    (void)PsAppRomLoadProgress_Begin(&rom);
    PsAppRomLoadProgress_UpdateRead(&rom, 100U, 100U);
    assert(read_percent(&rom) == 100U);
    PsAppRomLoadProgress_Complete(&rom, XST_FAILURE);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(snapshot.phase == (u8)PS_APP_ROM_LOAD_PHASE_FAILED);
    assert(snapshot.result == (u8)PS_APP_ROM_LOAD_RESULT_FAILED);
    assert(PsAppRomLoadProgress_GetPercent(&snapshot, &percent) == 0U);
}

static void test_worker_and_queue_failures_return_to_menu(void) {
    PsAppRomState rom;
    PsAppRomLoadProgressSnapshot snapshot;
    PsAppUiState ui;
    u32 first_attempt;
    u32 active_attempt;

    memset(&ui, 0, sizeof(ui));
    ui.mode = (u8)PS_APP_UI_MODE_LOADING;
    ui.launch_requested = 1U;
    assert(PsAppUiLaunchLogic_WorkerStartResult(&ui, 0U) == 0U);
    assert(ui.mode == (u8)PS_APP_UI_MODE_MENU);
    assert(ui.launch_requested == 0U);

    memset(&rom, 0, sizeof(rom));
    first_attempt = PsAppRomLoadProgress_Begin(&rom);
    active_attempt = PsAppRomLoadProgress_Begin(&rom);
    assert(active_attempt != first_attempt);
    assert(PsAppRomLoadProgress_FailIfUnchanged(&rom,
                                                first_attempt,
                                                XST_TIMEOUT) == 0U);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(snapshot.attempt_id == active_attempt);
    assert(snapshot.result == (u8)PS_APP_ROM_LOAD_RESULT_RUNNING);

    PsAppRomLoadProgress_Complete(&rom, XST_SUCCESS);
    assert(PsAppRomLoadProgress_FailIfUnchanged(&rom,
                                                active_attempt,
                                                XST_TIMEOUT) != 0U);
    PsAppRomLoadProgress_GetSnapshot(&rom, &snapshot);
    assert(snapshot.result == (u8)PS_APP_ROM_LOAD_RESULT_FAILED);
    assert(snapshot.error_status == XST_TIMEOUT);

    ui.mode = (u8)PS_APP_UI_MODE_LOADING;
    ui.launch_requested = 1U;
    PsAppUiLaunchLogic_ReturnToMenu(&ui); /* Runtime queue returned busy. */
    assert(ui.mode == (u8)PS_APP_UI_MODE_MENU);
    assert(ui.launch_requested == 0U);
}

int main(void) {
    test_chunk_progress_is_monotonic_and_finishes_at_total();
    test_zero_total_is_indeterminate_and_overrun_clamps();
    test_failure_never_reports_full_success();
    test_worker_and_queue_failures_return_to_menu();
    puts("ROM load progress tests passed");
    return 0;
}

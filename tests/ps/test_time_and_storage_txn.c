#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Common/Inc/ps_app_time_math.h"
#include "Storage/Inc/ps_fatfs_txn.h"
#include "Save/Inc/ps_app_save_logic.h"

static void test_time_math(void) {
    const uint32_t max_ticks = 0xFFFFFFFEU;

    assert(PsAppTimeMath_MsToTicksCeil(0U, 100U, max_ticks) == 0U);
    assert(PsAppTimeMath_MsToTicksCeil(1U, 100U, max_ticks) == 1U);
    assert(PsAppTimeMath_MsToTicksCeil(10U, 100U, max_ticks) == 1U);
    assert(PsAppTimeMath_MsToTicksCeil(11U, 100U, max_ticks) == 2U);
    assert(PsAppTimeMath_MsToTicksCeil(31U, 100U, max_ticks) == 4U);
    assert(PsAppTimeMath_MsToTicksCeil(1000U, 100U, max_ticks) == 100U);
    assert(PsAppTimeMath_MsToTicksCeil(1U, 0U, max_ticks) == 0U);
    assert(PsAppTimeMath_MsToTicksCeil(5000U, 100U, 1U) == 1U);

    assert(PsAppTimeMath_TicksToMsFloor(0U, 100U) == 0U);
    assert(PsAppTimeMath_TicksToMsFloor(1U, 100U) == 10U);
    assert(PsAppTimeMath_TicksToMsFloor(123U, 100U) == 1230U);
    assert(PsAppTimeMath_TicksToMsFloor(1U, 0U) == 0U);
    assert(PsAppTimeMath_TicksToUs(100U, 100U) == 1000000ULL);
    assert(PsAppTimeMath_TicksToUs(1U, 0U) == 0ULL);
}

static void test_crc_and_marker(void) {
    static const uint8_t bytes[] = "123456789";
    uint8_t marker[PS_FATFS_TXN_READY_MARKER_BYTES];
    uint32_t state;
    uint32_t size_out;
    uint32_t crc_out;

    assert(PsFatFsTxn_Crc32(bytes, sizeof(bytes) - 1U) == 0xCBF43926U);
    state = PsFatFsTxn_Crc32Begin();
    state = PsFatFsTxn_Crc32Update(state, bytes, 4U);
    state = PsFatFsTxn_Crc32Update(state, &bytes[4], 5U);
    assert(PsFatFsTxn_Crc32Finish(state) == 0xCBF43926U);

    PsFatFsTxn_MakeReadyMarker((uint32_t)(sizeof(bytes) - 1U),
                               PsFatFsTxn_Crc32(bytes, sizeof(bytes) - 1U),
                               marker);
    assert(PsFatFsTxn_CheckReadyMarker(marker, &size_out, &crc_out) == 1);
    assert(size_out == sizeof(bytes) - 1U);
    assert(crc_out == 0xCBF43926U);
    marker[0] ^= 1U;
    assert(PsFatFsTxn_CheckReadyMarker(marker, NULL, NULL) == 0);
}

static void test_sidecar_paths_and_recovery(void) {
    char temporary[128];
    char backup[128];
    char ready[128];
    char tiny[8];

    assert(PsFatFsTxn_BuildSidecarPaths("0:/saves/game.sav",
                                       temporary, sizeof(temporary),
                                       backup, sizeof(backup),
                                       ready, sizeof(ready)) == 1);
    assert(strncmp(temporary, "0:/saves/", 9U) == 0);
    assert(strcmp(temporary, backup) != 0);
    assert(strcmp(temporary, ready) != 0);
    assert(PsFatFsTxn_BuildSidecarPaths("0:/saves/game.sav",
                                       tiny, sizeof(tiny),
                                       backup, sizeof(backup),
                                       ready, sizeof(ready)) == 0);

    assert(PsFatFsTxn_SelectRecoveryAction(1, 1, 1, 1) ==
           PS_FATFS_TXN_RECOVER_CLEAN_SIDECARS);
    assert(PsFatFsTxn_SelectRecoveryAction(0, 1, 1, 1) ==
           PS_FATFS_TXN_RECOVER_RESTORE_BACKUP);
    assert(PsFatFsTxn_SelectRecoveryAction(0, 1, 0, 1) ==
           PS_FATFS_TXN_RECOVER_PROMOTE_TEMP);
    assert(PsFatFsTxn_SelectRecoveryAction(0, 1, 0, 2) ==
           PS_FATFS_TXN_RECOVER_DISCARD_TEMP);
    assert(PsFatFsTxn_SelectRecoveryAction(0, 0, 0, 2) ==
           PS_FATFS_TXN_RECOVER_DISCARD_TEMP);
    assert(PsFatFsTxn_SelectRecoveryAction(0, 0, 0, 0) ==
           PS_FATFS_TXN_RECOVER_NONE);
}


static void test_save_kind_state_machine(void) {
    PsAppSaveKindRuntime sram = { 0U, 0U, 0U, 0U };
    PsAppSaveKindRuntime eeprom = { 0U, 0U, 0U, 0U };

    PsAppSaveLogic_Observe(&sram, 1U, 0U, 10U);
    PsAppSaveLogic_Observe(&eeprom, 1U, 0U, 44U);
    assert(sram.dirty != 0U && eeprom.dirty != 0U);
    assert(sram.generation == 10U && eeprom.generation == 44U);
    assert(PsAppSaveLogic_Tick(&sram, 0U, 3U, 10U) == PS_APP_SAVE_LOGIC_WAIT_QUIET);
    assert(PsAppSaveLogic_Tick(&eeprom, 1U, 1U, 2U) == PS_APP_SAVE_LOGIC_WAIT_BUSY);
    assert(eeprom.quiet_ticks == 0U && eeprom.dirty_age_ticks == 0U);

    assert(PsAppSaveLogic_Tick(&sram, 0U, 3U, 10U) == PS_APP_SAVE_LOGIC_WAIT_QUIET);
    assert(PsAppSaveLogic_Tick(&sram, 0U, 3U, 10U) == PS_APP_SAVE_LOGIC_FLUSH_DUE);
    PsAppSaveLogic_Observe(&sram, 1U, 0U, 11U);
    assert(sram.generation == 11U);
    assert(sram.quiet_ticks == 0U && sram.dirty_age_ticks == 0U);

    PsAppSaveLogic_ResetRetry(&sram);
    assert(sram.dirty != 0U && sram.generation == 11U);
    PsAppSaveLogic_Observe(&sram, 0U, 0U, 11U);
    assert(sram.dirty == 0U && sram.quiet_ticks == 0U);
    assert(PsAppSaveLogic_Tick(&sram, 0U, 1U, 1U) == PS_APP_SAVE_LOGIC_CLEAN);
}

int main(void) {
    test_time_math();
    test_crc_and_marker();
    test_sidecar_paths_and_recovery();
    test_save_kind_state_machine();
    puts("PS pure helper tests passed");
    return 0;
}

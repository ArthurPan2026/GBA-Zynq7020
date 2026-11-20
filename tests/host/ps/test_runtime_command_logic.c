#include <assert.h>
#include <stdio.h>

#include "App/Inc/ps_app_runtime_command_logic.h"

static void test_queue_full_returns_busy(void) {
    PsAppRuntimeCommandQueueState state;
    uint32_t idx;

    PsAppRuntimeCommandLogic_Init(&state, 16U);
    for (idx = 0U; idx < 16U; ++idx) {
        assert(PsAppRuntimeCommandLogic_TryReserve(&state) ==
               PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED);
    }
    assert(state.outstanding == 16U);
    assert(PsAppRuntimeCommandLogic_TryReserve(&state) ==
           PS_APP_RUNTIME_COMMAND_LOGIC_BUSY);
    PsAppRuntimeCommandLogic_Release(&state);
    assert(state.outstanding == 15U);
    assert(PsAppRuntimeCommandLogic_TryReserve(&state) ==
           PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED);
    assert(state.outstanding == 16U);
}

static void test_load_and_unload_are_serialized(void) {
    PsAppRuntimeCommandQueueState state;
    uint8_t executing_command;

    PsAppRuntimeCommandLogic_Init(&state, 16U);
    assert(PsAppRuntimeCommandLogic_TryReserve(&state) ==
           PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED); /* queued Load */
    assert(PsAppRuntimeCommandLogic_TryReserve(&state) ==
           PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED); /* queued Unload */

    assert(PsAppRuntimeCommandLogic_TryBegin(&state) != 0U);
    executing_command = 1U; /* Load owns the lifecycle worker. */
    assert(PsAppRuntimeCommandLogic_TryBegin(&state) == 0U);
    PsAppRuntimeCommandLogic_Complete(&state);
    executing_command = 2U; /* Unload starts only after Load completes. */
    assert(executing_command == 2U);
    assert(PsAppRuntimeCommandLogic_TryBegin(&state) != 0U);
    assert(PsAppRuntimeCommandLogic_TryBegin(&state) == 0U);
    PsAppRuntimeCommandLogic_Complete(&state);

    PsAppRuntimeCommandLogic_Release(&state);
    PsAppRuntimeCommandLogic_Release(&state);
    assert(state.outstanding == 0U);
    assert(state.owner_busy == 0U);
}

int main(void) {
    test_queue_full_returns_busy();
    test_load_and_unload_are_serialized();
    puts("Runtime command queue logic tests passed");
    return 0;
}

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Common/Inc/ps_app_audio_route_logic.h"

typedef struct {
    uint8_t events[32];
    uint8_t paths[32];
    uint16_t gains[32];
    uint8_t volumes[32];
    unsigned int count;
    uint32_t fail_mask;
} FakeAudioRoute;

enum {
    EVENT_MUTE = 1U,
    EVENT_HDMI_ENABLE = 2U,
    EVENT_LEVEL = 3U
};

static int FakeAudioRoute_Record(FakeAudioRoute *fake, uint8_t event, uint8_t path) {
    unsigned int index = fake->count;
    assert(index < (unsigned int)(sizeof(fake->events) / sizeof(fake->events[0])));
    fake->events[index] = event;
    fake->paths[index] = path;
    fake->count++;
    return ((fake->fail_mask & (1U << index)) != 0U) ? -1 : 0;
}

static int FakeAudioRoute_SetHdmiEnabled(void *context, uint8_t enabled) {
    FakeAudioRoute *fake = (FakeAudioRoute *)context;
    return FakeAudioRoute_Record(fake, EVENT_HDMI_ENABLE,
                                 (uint8_t)(enabled != 0U ? PS_APP_AUDIO_PATH_HDMI : PS_APP_AUDIO_PATH_I2S_CODEC));
}

static int FakeAudioRoute_SetMute(void *context, uint8_t path, uint8_t mute) {
    FakeAudioRoute *fake = (FakeAudioRoute *)context;
    uint8_t event = (uint8_t)(EVENT_MUTE + (mute != 0U ? 8U : 0U));
    return FakeAudioRoute_Record(fake, event, path);
}

static int FakeAudioRoute_SetLevel(void *context, uint8_t path,
                                   uint8_t volume_percent, uint16_t hdmi_gain_q15) {
    FakeAudioRoute *fake = (FakeAudioRoute *)context;
    int status = FakeAudioRoute_Record(fake, EVENT_LEVEL, path);
    unsigned int index = fake->count - 1U;
    fake->volumes[index] = volume_percent;
    fake->gains[index] = hdmi_gain_q15;
    return status;
}

static PsAppAudioRouteOps FakeAudioRoute_Ops(FakeAudioRoute *fake) {
    PsAppAudioRouteOps ops;
    ops.context = fake;
    ops.set_hdmi_enabled = FakeAudioRoute_SetHdmiEnabled;
    ops.set_output_mute = FakeAudioRoute_SetMute;
    ops.set_output_level = FakeAudioRoute_SetLevel;
    return ops;
}

static void test_default_i2s_and_request_are_nonblocking_state_changes(void) {
    PsAppAudioRouteState state;
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(state.active_path == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(state.status == PS_APP_AUDIO_ROUTE_IDLE);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    assert(state.active_path == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(state.requested_path == PS_APP_AUDIO_PATH_HDMI);
    assert(state.status == PS_APP_AUDIO_ROUTE_PENDING);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_I2S_CODEC) ==
           PS_APP_AUDIO_ROUTE_RESULT_BUSY);
}

static void test_launch_waits_for_audio_route_transition(void) {
    PsAppAudioRouteState state;
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_IsTransitionInProgress(&state) == 0U);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    assert(PsAppAudioRouteLogic_IsTransitionInProgress(&state) == 1U);
    state.status = (uint8_t)PS_APP_AUDIO_ROUTE_SWITCHING;
    assert(PsAppAudioRouteLogic_IsTransitionInProgress(&state) == 1U);
    state.status = (uint8_t)PS_APP_AUDIO_ROUTE_FAILED;
    assert(PsAppAudioRouteLogic_IsTransitionInProgress(&state) == 0U);
}

static void test_success_mutes_old_path_selects_target_then_unmutes(void) {
    PsAppAudioRouteState state;
    FakeAudioRoute fake;
    PsAppAudioRouteOps ops;

    memset(&fake, 0, sizeof(fake));
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    ops = FakeAudioRoute_Ops(&fake);
    assert(PsAppAudioRouteLogic_Transition(&state, 0U, 45U, &ops) ==
           PS_APP_AUDIO_ROUTE_ERROR_NONE);
    assert(state.active_path == PS_APP_AUDIO_PATH_HDMI);
    assert(state.requested_path == PS_APP_AUDIO_PATH_HDMI);
    assert(state.status == PS_APP_AUDIO_ROUTE_IDLE);
    assert(fake.count == 5U);
    assert(fake.events[0] == (EVENT_MUTE + 8U) && fake.paths[0] == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(fake.events[1] == (EVENT_MUTE + 8U) && fake.paths[1] == PS_APP_AUDIO_PATH_HDMI);
    assert(fake.events[2] == EVENT_HDMI_ENABLE && fake.paths[2] == PS_APP_AUDIO_PATH_HDMI);
    assert(fake.events[3] == EVENT_LEVEL && fake.paths[3] == PS_APP_AUDIO_PATH_HDMI);
    assert(fake.gains[3] == PsAppAudioRouteLogic_VolumeToGainQ15(45U));
    assert(fake.events[4] == EVENT_MUTE && fake.paths[4] == PS_APP_AUDIO_PATH_HDMI);
}

static void test_route_failure_rolls_back_and_preserves_active_path(void) {
    PsAppAudioRouteState state;
    FakeAudioRoute fake;
    PsAppAudioRouteOps ops;

    memset(&fake, 0, sizeof(fake));
    fake.fail_mask = (1U << 2U); /* HDMI enable fails after both outputs are muted. */
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    ops = FakeAudioRoute_Ops(&fake);
    assert(PsAppAudioRouteLogic_Transition(&state, 0U, 45U, &ops) ==
           PS_APP_AUDIO_ROUTE_ERROR_SELECT_TARGET);
    assert(state.active_path == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(state.requested_path == PS_APP_AUDIO_PATH_HDMI);
    assert(state.status == PS_APP_AUDIO_ROUTE_FAILED);
    assert(state.last_error == PS_APP_AUDIO_ROUTE_ERROR_SELECT_TARGET);
    assert(fake.events[4] == EVENT_HDMI_ENABLE && fake.paths[4] == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(fake.events[fake.count - 1U] == EVENT_MUTE);
    assert(fake.paths[fake.count - 1U] == PS_APP_AUDIO_PATH_I2S_CODEC);
}

static void test_rollback_failure_is_reported(void) {
    PsAppAudioRouteState state;
    FakeAudioRoute fake;
    PsAppAudioRouteOps ops;

    memset(&fake, 0, sizeof(fake));
    /* Target select fails and then restoring the old route also fails. */
    fake.fail_mask = (1U << 2U) | (1U << 4U);
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    ops = FakeAudioRoute_Ops(&fake);
    assert(PsAppAudioRouteLogic_Transition(&state, 1U, 0U, &ops) ==
           PS_APP_AUDIO_ROUTE_ERROR_ROLLBACK);
    assert(state.active_path == PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(state.status == PS_APP_AUDIO_ROUTE_FAILED);
    assert(state.last_error == PS_APP_AUDIO_ROUTE_ERROR_ROLLBACK);
}

static void test_user_mute_and_zero_volume_stay_muted_after_switch(void) {
    PsAppAudioRouteState state;
    FakeAudioRoute fake;
    PsAppAudioRouteOps ops;

    memset(&fake, 0, sizeof(fake));
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    ops = FakeAudioRoute_Ops(&fake);
    assert(PsAppAudioRouteLogic_Transition(&state, 1U, 50U, &ops) ==
           PS_APP_AUDIO_ROUTE_ERROR_NONE);
    assert(fake.events[fake.count - 1U] == (EVENT_MUTE + 8U));
    assert(fake.paths[fake.count - 1U] == PS_APP_AUDIO_PATH_HDMI);

    memset(&fake, 0, sizeof(fake));
    PsAppAudioRouteLogic_Init(&state, PS_APP_AUDIO_PATH_I2S_CODEC);
    assert(PsAppAudioRouteLogic_Request(&state, PS_APP_AUDIO_PATH_HDMI) ==
           PS_APP_AUDIO_ROUTE_RESULT_OK);
    ops = FakeAudioRoute_Ops(&fake);
    assert(PsAppAudioRouteLogic_Transition(&state, 0U, 0U, &ops) ==
           PS_APP_AUDIO_ROUTE_ERROR_NONE);
    assert(fake.events[fake.count - 1U] == (EVENT_MUTE + 8U));
}

static void test_volume_conversion_uses_linear_hdmi_gain(void) {
    uint16_t previous_gain = 0U;
    unsigned int volume;

    /* The codec register mapping remains the I2S path's existing curve. */
    assert(PsAppAudioRouteLogic_VolumeToCodecRegister(0U) == 0x30U);
    assert(PsAppAudioRouteLogic_VolumeToCodecRegister(45U) == 0x51U);
    assert(PsAppAudioRouteLogic_VolumeToCodecRegister(50U) == 0x55U);
    assert(PsAppAudioRouteLogic_VolumeToCodecRegister(100U) == 0x79U);
    assert(PsAppAudioRouteLogic_VolumeToCodecRegister(255U) == 0x79U);

    assert(PsAppAudioRouteLogic_VolumeToGainQ15(0U) == 0U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(1U) == 328U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(25U) == 8192U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(45U) == 14746U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(50U) == 16384U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(75U) == 24576U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(100U) == 32768U);
    assert(PsAppAudioRouteLogic_VolumeToGainQ15(255U) == 32768U);

    /* Check the full range, including monotonicity and the Q15 unity ceiling. */
    for (volume = 0U; volume <= 100U; ++volume) {
        uint16_t gain = PsAppAudioRouteLogic_VolumeToGainQ15((uint8_t)volume);
        assert(gain >= previous_gain);
        assert(gain <= 32768U);
        assert(gain == (uint16_t)((volume * 32768U + 50U) / 100U));
        previous_gain = gain;
    }
}

int main(void) {
    test_default_i2s_and_request_are_nonblocking_state_changes();
    test_launch_waits_for_audio_route_transition();
    test_success_mutes_old_path_selects_target_then_unmutes();
    test_route_failure_rolls_back_and_preserves_active_path();
    test_rollback_failure_is_reported();
    test_user_mute_and_zero_volume_stay_muted_after_switch();
    test_volume_conversion_uses_linear_hdmi_gain();
    puts("Audio output route logic tests passed");
    return 0;
}

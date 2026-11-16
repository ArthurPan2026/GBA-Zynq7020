#include "Common/Inc/ps_app_audio_route_logic.h"

static uint8_t PsAppAudioRouteLogic_PathValid(uint8_t path) {
    return (uint8_t)((path == (uint8_t)PS_APP_AUDIO_PATH_I2S_CODEC) ||
                     (path == (uint8_t)PS_APP_AUDIO_PATH_HDMI));
}

void PsAppAudioRouteLogic_Init(PsAppAudioRouteState *state, uint8_t default_path) {
    if (state == 0) {
        return;
    }
    if (PsAppAudioRouteLogic_PathValid(default_path) == 0U) {
        default_path = (uint8_t)PS_APP_AUDIO_PATH_I2S_CODEC;
    }
    state->active_path = default_path;
    state->requested_path = default_path;
    state->status = (uint8_t)PS_APP_AUDIO_ROUTE_IDLE;
    state->reserved = 0U;
    state->last_error = (uint32_t)PS_APP_AUDIO_ROUTE_ERROR_NONE;
}

PsAppAudioRouteResult PsAppAudioRouteLogic_Request(PsAppAudioRouteState *state,
                                                    uint8_t requested_path) {
    if ((state == 0) || (PsAppAudioRouteLogic_PathValid(requested_path) == 0U)) {
        return PS_APP_AUDIO_ROUTE_RESULT_INVALID;
    }
    if ((state->status == (uint8_t)PS_APP_AUDIO_ROUTE_PENDING) ||
        (state->status == (uint8_t)PS_APP_AUDIO_ROUTE_SWITCHING)) {
        return PS_APP_AUDIO_ROUTE_RESULT_BUSY;
    }

    state->requested_path = requested_path;
    state->last_error = (uint32_t)PS_APP_AUDIO_ROUTE_ERROR_NONE;
    if (requested_path == state->active_path) {
        state->status = (uint8_t)PS_APP_AUDIO_ROUTE_IDLE;
    } else {
        state->status = (uint8_t)PS_APP_AUDIO_ROUTE_PENDING;
    }
    return PS_APP_AUDIO_ROUTE_RESULT_OK;
}

uint8_t PsAppAudioRouteLogic_IsTransitionInProgress(const PsAppAudioRouteState *state) {
    if (state == 0) {
        return 0U;
    }
    return (uint8_t)((state->status == (uint8_t)PS_APP_AUDIO_ROUTE_PENDING) ||
                     (state->status == (uint8_t)PS_APP_AUDIO_ROUTE_SWITCHING));
}

/*
 * SSM2603 输出音量按 1 dB 一档；这里保存 0..73 dB 衰减对应的 Q15 幅度，
 * 避免运行时浮点运算，并让 HDMI 与 codec 使用完全相同的音量曲线。
 */
static const uint16_t g_audio_gain_q15_by_attenuation_db[74] = {
    32768U, 29205U, 26029U, 23198U, 20675U, 18427U, 16423U, 14637U,
    13045U, 11627U, 10362U, 9235U, 8231U, 7336U, 6538U, 5827U,
    5193U, 4629U, 4125U, 3677U, 3277U, 2920U, 2603U, 2320U,
    2068U, 1843U, 1642U, 1464U, 1305U, 1163U, 1036U, 924U,
    823U, 734U, 654U, 583U, 519U, 463U, 413U, 368U,
    328U, 292U, 260U, 232U, 207U, 184U, 164U, 146U,
    130U, 116U, 104U, 92U, 82U, 73U, 65U, 58U,
    52U, 46U, 41U, 37U, 33U, 29U, 26U, 23U,
    21U, 18U, 16U, 15U, 13U, 12U, 10U, 9U,
    8U, 7U
};

uint8_t PsAppAudioRouteLogic_VolumeToCodecRegister(uint8_t volume_percent) {
    const uint32_t codec_min = 0x30U;
    const uint32_t codec_unity = 0x79U;
    uint32_t volume = (uint32_t)volume_percent;
    uint32_t range = codec_unity - codec_min;

    if (volume > 100U) {
        volume = 100U;
    }
    return (uint8_t)(codec_min + ((volume * range + 50U) / 100U));
}

uint16_t PsAppAudioRouteLogic_VolumeToGainQ15(uint8_t volume_percent) {
    uint8_t codec_register;
    uint8_t attenuation_db;

    if (volume_percent == 0U) {
        return 0U;
    }
    codec_register = PsAppAudioRouteLogic_VolumeToCodecRegister(volume_percent);
    attenuation_db = (uint8_t)(0x79U - codec_register);
    return g_audio_gain_q15_by_attenuation_db[attenuation_db];
}

static int PsAppAudioRouteLogic_SetMute(const PsAppAudioRouteOps *ops,
                                        uint8_t path,
                                        uint8_t mute) {
    if ((ops == 0) || (ops->set_output_mute == 0)) {
        return -1;
    }
    return ops->set_output_mute(ops->context, path, mute);
}

static int PsAppAudioRouteLogic_SetRoute(const PsAppAudioRouteOps *ops,
                                         uint8_t path) {
    if ((ops == 0) || (ops->set_hdmi_enabled == 0)) {
        return -1;
    }
    return ops->set_hdmi_enabled(ops->context,
                                 (uint8_t)(path == (uint8_t)PS_APP_AUDIO_PATH_HDMI));
}

static int PsAppAudioRouteLogic_SetLevel(const PsAppAudioRouteOps *ops,
                                         uint8_t path,
                                         uint8_t volume_percent) {
    if ((ops == 0) || (ops->set_output_level == 0)) {
        return -1;
    }
    return ops->set_output_level(ops->context,
                                 path,
                                 volume_percent,
                                 PsAppAudioRouteLogic_VolumeToGainQ15(volume_percent));
}

static PsAppAudioRouteError PsAppAudioRouteLogic_Restore(
    PsAppAudioRouteState *state,
    uint8_t old_path,
    uint8_t user_mute,
    uint8_t volume_percent,
    const PsAppAudioRouteOps *ops,
    PsAppAudioRouteError cause) {
    uint8_t restore_failed = 0U;
    uint8_t output_mute = (uint8_t)((user_mute != 0U) || (volume_percent == 0U));

    if (PsAppAudioRouteLogic_SetMute(ops, state->requested_path, 1U) != 0) {
        restore_failed = 1U;
    }
    if (PsAppAudioRouteLogic_SetRoute(ops, old_path) != 0) {
        restore_failed = 1U;
    }
    if (PsAppAudioRouteLogic_SetLevel(ops, old_path, volume_percent) != 0) {
        restore_failed = 1U;
    }
    if (PsAppAudioRouteLogic_SetMute(ops, old_path, output_mute) != 0) {
        restore_failed = 1U;
    }

    state->active_path = old_path;
    state->status = (uint8_t)PS_APP_AUDIO_ROUTE_FAILED;
    state->last_error = (uint32_t)(restore_failed != 0U ?
                                   PS_APP_AUDIO_ROUTE_ERROR_ROLLBACK : cause);
    return (PsAppAudioRouteError)state->last_error;
}

PsAppAudioRouteError PsAppAudioRouteLogic_Transition(PsAppAudioRouteState *state,
                                                      uint8_t user_mute,
                                                      uint8_t volume_percent,
                                                      const PsAppAudioRouteOps *ops) {
    uint8_t old_path;
    uint8_t target_path;
    uint8_t output_mute;
    int status;

    if ((state == 0) || (PsAppAudioRouteLogic_PathValid(state->active_path) == 0U) ||
        (PsAppAudioRouteLogic_PathValid(state->requested_path) == 0U) ||
        (ops == 0)) {
        return PS_APP_AUDIO_ROUTE_ERROR_INVALID;
    }

    old_path = state->active_path;
    target_path = state->requested_path;
    output_mute = (uint8_t)((user_mute != 0U) || (volume_percent == 0U));
    if (volume_percent > 100U) {
        volume_percent = 100U;
    }
    if (target_path == old_path) {
        state->status = (uint8_t)PS_APP_AUDIO_ROUTE_IDLE;
        state->last_error = (uint32_t)PS_APP_AUDIO_ROUTE_ERROR_NONE;
        return PS_APP_AUDIO_ROUTE_ERROR_NONE;
    }

    state->status = (uint8_t)PS_APP_AUDIO_ROUTE_SWITCHING;
    state->last_error = (uint32_t)PS_APP_AUDIO_ROUTE_ERROR_NONE;

    status = PsAppAudioRouteLogic_SetMute(ops, old_path, 1U);
    if (status != 0) {
        return PsAppAudioRouteLogic_Restore(state, old_path, user_mute,
                                            volume_percent, ops,
                                            PS_APP_AUDIO_ROUTE_ERROR_MUTE_OLD);
    }
    status = PsAppAudioRouteLogic_SetMute(ops, target_path, 1U);
    if (status != 0) {
        return PsAppAudioRouteLogic_Restore(state, old_path, user_mute,
                                            volume_percent, ops,
                                            PS_APP_AUDIO_ROUTE_ERROR_MUTE_TARGET);
    }
    status = PsAppAudioRouteLogic_SetRoute(ops, target_path);
    if (status != 0) {
        return PsAppAudioRouteLogic_Restore(state, old_path, user_mute,
                                            volume_percent, ops,
                                            PS_APP_AUDIO_ROUTE_ERROR_SELECT_TARGET);
    }
    status = PsAppAudioRouteLogic_SetLevel(ops, target_path, volume_percent);
    if (status != 0) {
        return PsAppAudioRouteLogic_Restore(state, old_path, user_mute,
                                            volume_percent, ops,
                                            PS_APP_AUDIO_ROUTE_ERROR_SET_LEVEL);
    }
    status = PsAppAudioRouteLogic_SetMute(ops, target_path, output_mute);
    if (status != 0) {
        return PsAppAudioRouteLogic_Restore(state, old_path, user_mute,
                                            volume_percent, ops,
                                            PS_APP_AUDIO_ROUTE_ERROR_UNMUTE_TARGET);
    }

    state->active_path = target_path;
    state->status = (uint8_t)PS_APP_AUDIO_ROUTE_IDLE;
    state->last_error = (uint32_t)PS_APP_AUDIO_ROUTE_ERROR_NONE;
    return PS_APP_AUDIO_ROUTE_ERROR_NONE;
}

const char *PsAppAudioRouteLogic_PathName(uint8_t path) {
    switch (path) {
        case PS_APP_AUDIO_PATH_I2S_CODEC: return "I2S";
        case PS_APP_AUDIO_PATH_HDMI: return "HDMI";
        default: return "UNKNOWN";
    }
}

const char *PsAppAudioRouteLogic_StatusName(uint8_t status) {
    switch (status) {
        case PS_APP_AUDIO_ROUTE_IDLE: return "idle";
        case PS_APP_AUDIO_ROUTE_PENDING: return "pending";
        case PS_APP_AUDIO_ROUTE_SWITCHING: return "switching";
        case PS_APP_AUDIO_ROUTE_FAILED: return "failed";
        default: return "unknown";
    }
}

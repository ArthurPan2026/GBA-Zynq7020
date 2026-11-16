#ifndef PS_APP_AUDIO_ROUTE_LOGIC_H
#define PS_APP_AUDIO_ROUTE_LOGIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PS_APP_AUDIO_PATH_I2S_CODEC = 0U,
    PS_APP_AUDIO_PATH_HDMI = 1U
} PsAppAudioPath;

typedef enum {
    PS_APP_AUDIO_ROUTE_IDLE = 0U,
    PS_APP_AUDIO_ROUTE_PENDING = 1U,
    PS_APP_AUDIO_ROUTE_SWITCHING = 2U,
    PS_APP_AUDIO_ROUTE_FAILED = 3U
} PsAppAudioRouteStatus;

typedef enum {
    PS_APP_AUDIO_ROUTE_ERROR_NONE = 0U,
    PS_APP_AUDIO_ROUTE_ERROR_INVALID = 1U,
    PS_APP_AUDIO_ROUTE_ERROR_MUTE_OLD = 2U,
    PS_APP_AUDIO_ROUTE_ERROR_MUTE_TARGET = 3U,
    PS_APP_AUDIO_ROUTE_ERROR_SELECT_TARGET = 4U,
    PS_APP_AUDIO_ROUTE_ERROR_SET_LEVEL = 5U,
    PS_APP_AUDIO_ROUTE_ERROR_UNMUTE_TARGET = 6U,
    PS_APP_AUDIO_ROUTE_ERROR_ROLLBACK = 7U
} PsAppAudioRouteError;

typedef enum {
    PS_APP_AUDIO_ROUTE_RESULT_OK = 0U,
    PS_APP_AUDIO_ROUTE_RESULT_INVALID = 1U,
    PS_APP_AUDIO_ROUTE_RESULT_BUSY = 2U
} PsAppAudioRouteResult;

typedef struct {
    uint8_t active_path;
    uint8_t requested_path;
    uint8_t status;
    uint8_t reserved;
    uint32_t last_error;
} PsAppAudioRouteState;

typedef struct {
    void *context;
    int (*set_hdmi_enabled)(void *context, uint8_t enabled);
    int (*set_output_mute)(void *context, uint8_t path, uint8_t mute);
    int (*set_output_level)(void *context,
                            uint8_t path,
                            uint8_t volume_percent,
                            uint16_t hdmi_gain_q15);
} PsAppAudioRouteOps;

void PsAppAudioRouteLogic_Init(PsAppAudioRouteState *state, uint8_t default_path);
PsAppAudioRouteResult PsAppAudioRouteLogic_Request(PsAppAudioRouteState *state,
                                                    uint8_t requested_path);
uint8_t PsAppAudioRouteLogic_IsTransitionInProgress(const PsAppAudioRouteState *state);
uint8_t PsAppAudioRouteLogic_VolumeToCodecRegister(uint8_t volume_percent);
PsAppAudioRouteError PsAppAudioRouteLogic_Transition(PsAppAudioRouteState *state,
                                                      uint8_t user_mute,
                                                      uint8_t volume_percent,
                                                      const PsAppAudioRouteOps *ops);
uint16_t PsAppAudioRouteLogic_VolumeToGainQ15(uint8_t volume_percent);
const char *PsAppAudioRouteLogic_PathName(uint8_t path);
const char *PsAppAudioRouteLogic_StatusName(uint8_t status);

#ifdef __cplusplus
}
#endif
#endif

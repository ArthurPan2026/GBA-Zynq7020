#include "App/Src/ps_app_console_internal.h"

#include <string.h>

#include "xil_printf.h"
#include "xil_io.h"

#include "Audio/Inc/ps_audio_codec.h"
#include "Diagnostics/Inc/ps_app_diag.h"
#include "Gba/Inc/ps_gba_regs.h"
#include "Video/Inc/ps_app_video.h"
#include "Vdma/Inc/ps_hdmi_vdma.h"

void PsAppConsole_PrintMediaHelp(void) {
    xil_printf("  audio status\r\n");
    xil_printf("  audio path i2s|hdmi\r\n");
    xil_printf("  audio reinit\r\n");
    xil_printf("  audio mute on|off\r\n");
    xil_printf("  audio vol <0-100>\r\n");
    xil_printf("  audio fmt <sample_rate_hz> <bits>\r\n");
    xil_printf("  rom status\r\n");
    xil_printf("  rom probe\r\n");
    xil_printf("  rom load [path]\r\n");
    xil_printf("  hdmi diag\r\n");
    xil_printf("  hdmi park <0|1|2>\r\n");
    xil_printf("  hdmi fill <idx|all> <hex>\r\n");
}

u8 PsAppConsole_HandleMediaCommands(PsAppConsoleContext *ctx, const char *cmd) {
    PsAppRuntimeContext *app;
    PsAppVideoContext *video;
    PsAppDiagContext *diag;
    char *arg1;
    char *arg2;
    char *arg3;
    u32 value;

    if ((ctx == NULL) || (ctx->runtime == NULL) || (cmd == NULL)) {
        return 0U;
    }

    app = ctx->runtime;
    video = ctx->video;
    diag = ctx->diag;

    if (strcmp(cmd, "audio") == 0) {
        arg1 = strtok(NULL, " \t");

        if ((arg1 != NULL) && (strcmp(arg1, "status") == 0)) {
            PsAppAudioRouteState route;
            PsAppRuntime_GetAudioRouteSnapshot(app, &route);
            xil_printf("[CMD] audio rate=%u bits=%u mute=%u vol=%u path=%s route=%s requested=%s err=%u pcm_overflow=%u\r\n",
                       (unsigned int)app->audio->sample_rate_hz,
                       (unsigned int)app->audio->bits_per_sample,
                       (unsigned int)((app->audio->mute != 0U) || (app->audio->volume == 0U)),
                       (unsigned int)app->audio->volume,
                       PsAppAudioRouteLogic_PathName(route.active_path),
                       PsAppAudioRouteLogic_StatusName(route.status),
                       PsAppAudioRouteLogic_PathName(route.requested_path),
                       (unsigned int)route.last_error,
                       (unsigned int)app->audio->pcm_source_overflow);
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "path") == 0)) {
            PsAppAudioRouteState route;
            XStatus status;
            arg2 = strtok(NULL, " \t");
            if (arg2 == NULL) {
                xil_printf("[CMD] usage: audio path i2s|hdmi\r\n");
                return 1U;
            }
            if (strcmp(arg2, "i2s") == 0) {
                status = PsAppRuntime_RequestAudioOutputPath(app,
                    (u8)PS_APP_AUDIO_PATH_I2S_CODEC);
            } else if (strcmp(arg2, "hdmi") == 0) {
                status = PsAppRuntime_RequestAudioOutputPath(app,
                    (u8)PS_APP_AUDIO_PATH_HDMI);
            } else {
                xil_printf("[CMD] usage: audio path i2s|hdmi\r\n");
                return 1U;
            }
            if (status == XST_SUCCESS) {
                PsAppRuntime_GetAudioRouteSnapshot(app, &route);
                xil_printf("[CMD] audio path request=%s state=%s\r\n",
                           PsAppAudioRouteLogic_PathName(route.requested_path),
                           PsAppAudioRouteLogic_StatusName(route.status));
            } else {
                xil_printf("[CMD] audio path request rejected st=%d\r\n", (int)status);
            }
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "reinit") == 0)) {
            if (PsAppRuntime_ProgramAudio(app) == XST_SUCCESS) {
                xil_printf("[CMD] audio reinit ok\r\n");
            } else {
                xil_printf("[CMD] audio reinit failed\r\n");
            }
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "mute") == 0)) {
            arg2 = strtok(NULL, " \t");
            if (PsAppConsole_ParseOnOff(arg2, &value) == 0) {
                if (PsAppRuntime_SetAudioMute(app, (u8)value) == XST_SUCCESS) {
                    xil_printf("[CMD] audio mute=%u\r\n", (unsigned int)value);
                } else {
                    xil_printf("[CMD] audio mute failed\r\n");
                }
                return 1U;
            }
            xil_printf("[CMD] usage: audio mute on|off\r\n");
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "vol") == 0)) {
            arg2 = strtok(NULL, " \t");
            if ((arg2 != NULL) && (PsAppConsole_ParseU32Value(arg2, &value) == 0)) {
                if (PsAppRuntime_SetAudioVolume(app, value) == XST_SUCCESS) {
                    xil_printf("[CMD] audio vol=%u\r\n", (unsigned int)app->audio->volume);
                } else {
                    xil_printf("[CMD] audio vol failed\r\n");
                }
                return 1U;
            }
            xil_printf("[CMD] usage: audio vol <0-100>\r\n");
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "fmt") == 0)) {
            u32 bits_u32;
            u16 bits;

            arg2 = strtok(NULL, " \t");
            arg3 = strtok(NULL, " \t");
            if ((arg2 != NULL) && (arg3 != NULL) &&
                (PsAppConsole_ParseU32Value(arg2, &value) == 0) &&
                (PsAppConsole_ParseU32Value(arg3, &bits_u32) == 0) &&
                (bits_u32 <= 0xFFFFU)) {
                bits = (u16)bits_u32;
                if (PsAppRuntime_SetAudioFormat(app, value, bits) == XST_SUCCESS) {
                    xil_printf("[CMD] audio fmt=%uHz/%u-bit\r\n",
                               (unsigned int)app->audio->sample_rate_hz,
                               (unsigned int)app->audio->bits_per_sample);
                } else {
                    xil_printf("[CMD] unsupported/apply failed audio fmt\r\n");
                }
                return 1U;
            }
            xil_printf("[CMD] usage: audio fmt <sample_rate_hz> <bits>\r\n");
            return 1U;
        }
    }

    if (strcmp(cmd, "rom") == 0) {
        arg1 = strtok(NULL, " \t");
        arg2 = strtok(NULL, " \t");

        if ((arg1 != NULL) && (strcmp(arg1, "status") == 0)) {
            xil_printf("[CMD] rom loaded=%u busy=%u bytes=%u aligned=%u maxpak=0x%08x\r\n",
                       (unsigned int)app->rom->loaded,
                       (unsigned int)(PsGbaRegs_Read(app->regs, GBA_REG_ROM_STATUS) & 0x1U),
                       (unsigned int)app->rom->size_bytes,
                       (unsigned int)app->rom->size_aligned,
                       (unsigned int)app->config->max_pak_addr);
            xil_printf("[CMD] bios mode=%s ext=%u load_ok=%u bytes=%u\r\n",
                       PsAppConsole_BiosModeName(app->rom->bios_mode),
                       (unsigned int)app->rom->bios_external_present,
                       (unsigned int)app->rom->bios_load_ok,
                       (unsigned int)app->rom->bios_bytes_loaded);
            xil_printf("[CMD] rom path=%s\r\n",
                       app->rom->path[0] != '\0' ? app->rom->path : "(none)");
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "probe") == 0)) {
            PsAppDiag_PrintRomProbe(diag);
            return 1U;
        }

        if ((arg1 != NULL) && (strcmp(arg1, "load") == 0)) {
            if (PsAppRuntime_LoadRomFromSd(app, arg2) == XST_SUCCESS) {
                xil_printf("[CMD] rom load ok\r\n");
            } else {
                xil_printf("[CMD] rom load failed\r\n");
            }
            return 1U;
        }

        xil_printf("[CMD] usage: rom status | rom probe | rom load [path]\r\n");
        return 1U;
    }

    if ((strcmp(cmd, "hdmi") == 0) || (strcmp(cmd, "vdma") == 0)) {
        arg1 = strtok(NULL, " \t");
        if ((strcmp(cmd, "hdmi") == 0) && (arg1 != NULL) &&
            (strcmp(arg1, "diag") == 0)) {
            if ((app->vdma == NULL) || (app->vdma->is_ready == 0U)) {
                xil_printf("[HDMI-DIAG] VDMA/video output is not initialized\r\n");
                return 1U;
            }
            {
                VideoOutIo io = VideoOutXilinx_GetIo(&app->vdma->video_out);
                UINTPTR core_base = app->vdma->video_out.core_register_base;
                u32 fclk0 = Xil_In32((UINTPTR)0xF8000170U);
                u32 ctrl = io.read_reg(io.context, 0x00U);
                u32 size = io.read_reg(io.context, 0x04U);
                u32 status = io.read_reg(io.context, 0x10U);
                u32 frame_count = io.read_reg(io.context, 0x14U);
                u32 errors = io.read_reg(io.context, 0x18U);
                u32 active_cfg = io.read_reg(io.context, 0x1CU);
                u32 active_size = io.read_reg(io.context, 0x30U);
                u32 audio_ctrl = io.read_reg(io.context, 0x34U);
                u32 audio_status = io.read_reg(io.context, 0x3CU);
                xil_printf("[HDMI-DIAG] base=0x%08x fclk0=0x%08x ctrl=0x%08x status=0x%08x\r\n",
                           (unsigned int)core_base, (unsigned int)fclk0,
                           (unsigned int)ctrl, (unsigned int)status);
                xil_printf("[HDMI-DIAG] size=0x%08x active_cfg=0x%08x active_size=0x%08x frames=%u errors=0x%08x\r\n",
                           (unsigned int)size, (unsigned int)active_cfg,
                           (unsigned int)active_size, (unsigned int)frame_count,
                           (unsigned int)errors);
                xil_printf("[HDMI-DIAG] pixel_reset_released=%u serial_seen=%u vsync_seen=%u mmcm_locked=%u pixel_clk_seen=%u pixel_ext_reset=%u\r\n",
                           (unsigned int)((status >> 8) & 1U),
                           (unsigned int)((status >> 9) & 1U),
                           (unsigned int)((status >> 10) & 1U),
                           (unsigned int)((status >> 11) & 1U),
                           (unsigned int)((status >> 12) & 1U),
                           (unsigned int)((status >> 13) & 1U));
                xil_printf("[HDMI-DIAG] audio_ctrl=0x%08x audio_status=0x%08x\r\n",
                           (unsigned int)audio_ctrl, (unsigned int)audio_status);
                if (app->hdmi != NULL) {
                    xil_printf("[HDMI-DIAG] hpd=%u edid_valid=%u sink=%s link_mode_requested=%s request_written=%u vsdb=%u cea_v3=%u cea_block=%u extensions=%u read_extensions=%u\r\n",
                               (unsigned int)app->hdmi->hpd_level,
                               (unsigned int)app->hdmi->edid.edid_valid,
                               PsAppHdmiEdid_SinkName(app->hdmi->edid.sink_type),
                               PsAppHdmiEdid_LinkModeName(app->hdmi->edid.link_mode_requested),
                               (unsigned int)app->hdmi->edid.link_mode_request_written,
                               (unsigned int)app->hdmi->edid.hdmi_vsdb_present,
                               (unsigned int)app->hdmi->edid.cea_v3_valid,
                               (unsigned int)app->hdmi->edid.cea_extension_block,
                               (unsigned int)app->hdmi->edid.extension_count,
                               (unsigned int)app->hdmi->edid.extension_blocks_read);
                }
            }
            return 1U;
        }
        if ((arg1 != NULL) && (strcmp(arg1, "park") == 0)) {
            arg2 = strtok(NULL, " \t");
            if ((arg2 != NULL) && (PsAppConsole_ParseU32Value(arg2, &value) == 0)) {
                value %= app->vdma->frame_count;
                if (PsAppVideo_RequestFrame(video, value) == XST_SUCCESS) {
                    PsAppVideo_SyncDisplayFrame(video);
                    xil_printf("[CMD] %s park=%u\r\n", cmd, (unsigned int)value);
                } else {
                    xil_printf("[CMD] %s park failed\r\n", cmd);
                }
                return 1U;
            }
            xil_printf("[CMD] usage: %s park <0|1|2>\r\n", cmd);
            return 1U;
        }

        if ((strcmp(cmd, "hdmi") == 0) && (arg1 != NULL) && (strcmp(arg1, "fill") == 0)) {
            arg2 = strtok(NULL, " \t");
            arg3 = strtok(NULL, " \t");
            if ((arg2 != NULL) && (arg3 != NULL) && (PsAppConsole_ParseU32Value(arg3, &value) == 0)) {
                if (strcmp(arg2, "all") == 0) {
                    if (PsAppVideo_FillAllFrames(video, value) == XST_SUCCESS) {
                        xil_printf("[CMD] hdmi fill all color=0x%08x\r\n", (unsigned int)value);
                    } else {
                        xil_printf("[CMD] hdmi fill all failed\r\n");
                    }
                } else {
                    u32 idx;
                    if (PsAppConsole_ParseU32Value(arg2, &idx) == 0) {
                        idx %= app->vdma->frame_count;
                        if (PsAppVideo_FillFrame(video, idx, value) == XST_SUCCESS) {
                            xil_printf("[CMD] hdmi fill frame=%u color=0x%08x\r\n",
                                       (unsigned int)idx,
                                       (unsigned int)value);
                        } else {
                            xil_printf("[CMD] hdmi fill failed\r\n");
                        }
                    } else {
                        xil_printf("[CMD] usage: hdmi fill <idx|all> <hex>\r\n");
                    }
                }
                return 1U;
            }
            xil_printf("[CMD] usage: hdmi fill <idx|all> <hex>\r\n");
            return 1U;
        }

        xil_printf("[CMD] usage: %s park <0|1|2>\r\n", cmd);
        return 1U;
    }

    return 0U;
}

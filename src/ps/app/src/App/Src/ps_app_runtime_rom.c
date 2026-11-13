#include "App/Inc/ps_app_runtime.h"
#include "App/Inc/ps_app_runtime_command.h"

#include "FreeRTOS.h"
#include "task.h"

#include <string.h>

#include "sleep.h"
#include "xil_printf.h"

#include "Diagnostics/Inc/ps_app_diag.h"
#include "Gba/Inc/ps_gba_regs.h"
#include "Gba/Inc/ps_pl_contract_generated.h"
#include "Save/Inc/ps_app_save.h"
#include "Video/Inc/ps_app_video.h"
#include "Rom/Inc/ps_rom_loader.h"
#include "Storage/Inc/ps_fatfs_storage.h"
#include "Common/Inc/ps_app_time.h"
#include "Common/Inc/ps_app_rom_load_progress.h"

static u32 s_ps_app_runtime_memory_command_sequence;

static void PsAppRuntimeRom_OnReadProgress(u32 bytes_done,
                                           u32 total_bytes,
                                           void *user_ctx) {
    PsAppRomLoadProgress_UpdateRead((PsAppRomState *)user_ctx,
                                   bytes_done,
                                   total_bytes);
}

static u32 PsAppRuntimeRom_NextMemorySequence(void) {
    s_ps_app_runtime_memory_command_sequence++;
    if (s_ps_app_runtime_memory_command_sequence == 0U) {
        s_ps_app_runtime_memory_command_sequence = 1U;
    }
    return s_ps_app_runtime_memory_command_sequence;
}

static XStatus PsAppRuntimeRom_ReadMemoryCommand(PsAppRuntimeContext *ctx,
                                                 u32 command,
                                                 u32 *status_out,
                                                 u32 *error_out) {
    if ((ctx == NULL) || (ctx->regs == NULL)) return XST_INVALID_PARAM;
    return PsGbaRegs_MemoryCommand(ctx->regs,
                                   command,
                                   PsAppRuntimeRom_NextMemorySequence(),
                                   PS_APP_ROM_MEMORY_TIMEOUT_MS,
                                   status_out,
                                   error_out);
}

static u8 PsAppRuntimeRom_IsSafeSoftFault(u32 status) {
    const u32 required = GBA_MEM_STATUS_QUIESCED | GBA_MEM_STATUS_DRAINED;
    return (u8)(((status & GBA_MEM_STATUS_FAULTED) != 0U) &&
                ((status & GBA_MEM_STATUS_FATAL_FAULT) == 0U) &&
                ((status & required) == required) &&
                ((status & GBA_MEM_STATUS_FLUSH_BUSY) == 0U));
}

static XStatus PsAppRuntimeRom_ClearSafeSoftFault(PsAppRuntimeContext *ctx,
                                                  u32 status,
                                                  u32 *status_out,
                                                  u32 *error_out) {
    XStatus result;
    u32 after_status;
    u32 after_error;

    if (PsAppRuntimeRom_IsSafeSoftFault(status) == 0U) return XST_FAILURE;
    after_status = status;
    after_error = 0U;
    result = PsAppRuntimeRom_ReadMemoryCommand(ctx,
                                               GBA_MEM_CMD_CLEAR_ERROR,
                                               &after_status,
                                               &after_error);
    if ((result != XST_SUCCESS) ||
        ((after_status & (GBA_MEM_STATUS_FATAL_FAULT | GBA_MEM_STATUS_FAULTED)) != 0U) ||
        ((after_status & (GBA_MEM_STATUS_QUIESCED | GBA_MEM_STATUS_DRAINED)) !=
         (GBA_MEM_STATUS_QUIESCED | GBA_MEM_STATUS_DRAINED)) ||
        ((after_status & GBA_MEM_STATUS_FLUSH_BUSY) != 0U)) {
        return (result != XST_SUCCESS) ? result : XST_FAILURE;
    }
    if (status_out != NULL) *status_out = after_status;
    if (error_out != NULL) *error_out = after_error;
    return XST_SUCCESS;
}

static XStatus PsAppRuntimeRom_RunMemoryCommand(PsAppRuntimeContext *ctx,
                                                u32 command,
                                                u32 *status_out,
                                                u32 *error_out) {
    XStatus result;
    u32 status;
    u32 error;
    const u32 drained_quiesced = GBA_MEM_STATUS_QUIESCED | GBA_MEM_STATUS_DRAINED;

    status = 0U;
    error = 0U;
    result = PsAppRuntimeRom_ReadMemoryCommand(ctx, command, &status, &error);
    if ((command == GBA_MEM_CMD_FLUSH_ROM) &&
        (PsAppRuntimeRom_IsSafeSoftFault(status) != 0U)) {
        if (PsAppRuntimeRom_ClearSafeSoftFault(ctx, status, &status, &error) != XST_SUCCESS) {
            result = XST_FAILURE;
        } else {
            /* The soft fault is cleared only with both drain and quiesce
             * acknowledged; retry the bounded ROM flush once. */
            result = PsAppRuntimeRom_ReadMemoryCommand(ctx,
                                                       command,
                                                       &status,
                                                       &error);
        }
    }
    if (result != XST_SUCCESS) {
        xil_printf("[ROM] memory command=%u failed status=0x%08x error=0x%08x result=%d\r\n",
                   (unsigned int)command,
                   (unsigned int)status,
                   (unsigned int)error,
                   result);
        if (status_out != NULL) *status_out = status;
        if (error_out != NULL) *error_out = error;
        return result;
    }
    if ((status & GBA_MEM_STATUS_FATAL_FAULT) != 0U) {
        result = XST_FAILURE;
    } else if ((status & GBA_MEM_STATUS_FAULTED) != 0U) {
        result = XST_FAILURE;
    } else if ((command == GBA_MEM_CMD_QUIESCE) &&
               ((status & drained_quiesced) != drained_quiesced)) {
        result = XST_FAILURE;
    } else if ((command == GBA_MEM_CMD_FLUSH_ROM) &&
               (((status & drained_quiesced) != drained_quiesced) ||
                ((status & GBA_MEM_STATUS_FLUSH_BUSY) != 0U))) {
        result = XST_FAILURE;
    } else if ((command == GBA_MEM_CMD_RESUME) &&
               ((status & GBA_MEM_STATUS_QUIESCED) != 0U)) {
        result = XST_FAILURE;
    }
    if (status_out != NULL) *status_out = status;
    if (error_out != NULL) *error_out = error;
    return result;
}

static XStatus PsAppRuntimeRom_ResumeAfterAbort(PsAppRuntimeContext *ctx) {
    XStatus status;

    status = PsAppRuntimeRom_RunMemoryCommand(ctx,
                                               GBA_MEM_CMD_FLUSH_ROM,
                                               NULL,
                                               NULL);
    if (status != XST_SUCCESS) {
        xil_printf("[ROM] abort cleanup: ROM flush failed\r\n");
        return status;
    }

    status = PsAppRuntimeRom_RunMemoryCommand(ctx,
                                               GBA_MEM_CMD_RESUME,
                                               NULL,
                                               NULL);
    if (status != XST_SUCCESS) {
        xil_printf("[ROM] abort cleanup: memory resume failed\r\n");
    }
    return status;
}

static void PsAppRuntimeRom_AdvanceGeneration(PsAppRomState *rom) {
    if (rom == NULL) return;
    rom->generation++;
    if (rom->generation == 0U) rom->generation = 1U;
}

static void PsAppRuntime_CopyText(char *dst, size_t dst_size, const char *src) {
    size_t src_len;

    if ((dst == NULL) || (dst_size == 0U)) {
        return;
    }

    if (src == NULL) {
        dst[0] = '\0';
        return;
    }

    src_len = strlen(src);
    if (src_len >= dst_size) {
        src_len = dst_size - 1U;
    }

    memcpy(dst, src, src_len);
    dst[src_len] = '\0';
}

static const char *PsAppRuntime_BiosModeName(u8 bios_mode) {
    switch ((PsAppBiosMode)bios_mode) {
        case PS_APP_BIOS_MODE_EXTERNAL:
            return "external";
        case PS_APP_BIOS_MODE_FALLBACK:
            return "fallback";
        case PS_APP_BIOS_MODE_INTERNAL:
        default:
            return "internal";
    }
}

static u32 PsAppRuntime_ReadLe32(const u8 *data) {
    if (data == NULL) {
        return 0U;
    }

    return ((u32)data[0]) |
           ((u32)data[1] << 8) |
           ((u32)data[2] << 16) |
           ((u32)data[3] << 24);
}

static int PsAppRuntime_LoadExternalBios(PsAppRuntimeContext *ctx,
                                         u8 *external_present_out,
                                         u32 *bytes_loaded_out,
                                         const char **reason_out) {
    static u8 s_ps_app_runtime_external_bios_image[PS_APP_GBA_BIOS_BYTES];
    PsFatFsStorageReadResult read_result;
    XStatus status;
    u32 word_idx;
    u8 external_present;

    if (external_present_out != NULL) {
        *external_present_out = 0U;
    }
    if (bytes_loaded_out != NULL) {
        *bytes_loaded_out = 0U;
    }
    if (reason_out != NULL) {
        *reason_out = "none";
    }

    if ((ctx == NULL) || (ctx->regs == NULL)) {
        if (reason_out != NULL) {
            *reason_out = "invalid_ctx";
        }
        return -1;
    }

    memset(&read_result, 0, sizeof(read_result));
    status = PsFatFsStorage_ReadFileToMemory(PS_APP_BIOS_SD_PATH,
                                             (UINTPTR)s_ps_app_runtime_external_bios_image,
                                             PS_APP_GBA_BIOS_BYTES,
                                             &read_result);
    if (status != XST_SUCCESS) {
        const char *read_reason;

        external_present = (u8)(((read_result.fs_result != FR_NO_FILE) &&
                                 (read_result.fs_result != FR_NO_PATH)) ? 1U : 0U);
        read_reason = PsFatFsStorage_StrError(read_result.fs_result);
        if ((external_present != 0U) && (read_result.fs_result == FR_OK)) {
            read_reason = "size_invalid";
        }
        if (external_present_out != NULL) {
            *external_present_out = external_present;
        }
        if (reason_out != NULL) {
            *reason_out = read_reason;
        }
        return 0;
    }

    if (external_present_out != NULL) {
        *external_present_out = 1U;
    }
    if (bytes_loaded_out != NULL) {
        *bytes_loaded_out = read_result.bytes_loaded;
    }
    if (read_result.bytes_loaded != PS_APP_GBA_BIOS_BYTES) {
        if (reason_out != NULL) {
            *reason_out = "size_invalid";
        }
        return 0;
    }

    for (word_idx = 0U; word_idx < PS_APP_GBA_BIOS_WORDS; ++word_idx) {
        const u8 *word_ptr;
        u32 word_data;

        word_ptr = &s_ps_app_runtime_external_bios_image[word_idx * 4U];
        word_data = PsAppRuntime_ReadLe32(word_ptr);
        status = PsGbaRegs_WriteBiosWord(ctx->regs,
                                         word_idx,
                                         word_data,
                                         PS_APP_GBA_BIOS_WRITE_TIMEOUT_LOOPS);
        if (status != XST_SUCCESS) {
            if (reason_out != NULL) {
                *reason_out = "pl_ack_timeout";
            }
            return -1;
        }
    }

    if (reason_out != NULL) {
        *reason_out = "ok";
    }
    return 1;
}

static XStatus PsAppRuntime_PrepareBiosForRom(PsAppRuntimeContext *ctx) {
    int load_result;
    u8 external_present;
    u32 bytes_loaded;
    const char *reason;

    if ((ctx == NULL) || (ctx->rom == NULL)) {
        return XST_FAILURE;
    }

    ctx->rom->bios_mode = (u8)PS_APP_BIOS_MODE_INTERNAL;
    ctx->rom->bios_load_ok = 0U;
    ctx->rom->bios_external_present = 0U;
    ctx->rom->bios_bytes_loaded = 0U;

    external_present = 0U;
    bytes_loaded = 0U;
    reason = "none";
    load_result = PsAppRuntime_LoadExternalBios(ctx,
                                                &external_present,
                                                &bytes_loaded,
                                                &reason);

    ctx->rom->bios_external_present = external_present;
    ctx->rom->bios_bytes_loaded = bytes_loaded;

    if (load_result > 0) {
        ctx->rom->bios_mode = (u8)PS_APP_BIOS_MODE_EXTERNAL;
        ctx->rom->bios_load_ok = 1U;
        xil_printf("[BIOS] mode=%s path=%s bytes=%u\r\n",
                   PsAppRuntime_BiosModeName(ctx->rom->bios_mode),
                   PS_APP_BIOS_SD_PATH,
                   (unsigned int)ctx->rom->bios_bytes_loaded);
        return XST_SUCCESS;
    }

    ctx->rom->bios_mode = (u8)PS_APP_BIOS_MODE_FALLBACK;
    ctx->rom->bios_load_ok = 0U;
    if (load_result == 0) {
        xil_printf("[BIOS] mode=%s path=%s reason=%s (use internal BIOS)\r\n",
                   PsAppRuntime_BiosModeName(ctx->rom->bios_mode),
                   PS_APP_BIOS_SD_PATH,
                   (reason != NULL) ? reason : "unknown");
        return XST_SUCCESS;
    }

    xil_printf("[BIOS] mode=%s fatal reason=%s\r\n",
               PsAppRuntime_BiosModeName(ctx->rom->bios_mode),
               (reason != NULL) ? reason : "unknown");
    return XST_FAILURE;
}

static u8 PsAppRuntime_Code3Eq(const char *code, const char *prefix3) {
    if ((code == NULL) || (prefix3 == NULL)) {
        return 0U;
    }
    return (memcmp(code, prefix3, 3U) == 0) ? 1U : 0U;
}

static u8 PsAppRuntime_Code4Eq(const char *code, const char *exact4) {
    if ((code == NULL) || (exact4 == NULL)) {
        return 0U;
    }
    return (memcmp(code, exact4, 4U) == 0) ? 1U : 0U;
}

static u8 PsAppRuntime_Code4InList(const char *code,
                                   const char *const *list,
                                   size_t count) {
    size_t idx;

    if ((code == NULL) || (list == NULL)) {
        return 0U;
    }

    for (idx = 0U; idx < count; ++idx) {
        if (PsAppRuntime_Code4Eq(code, list[idx]) != 0U) {
            return 1U;
        }
    }

    return 0U;
}

static void PsAppRuntime_ApplyRomDetection(PsAppRuntimeContext *ctx,
                                           const PsRomLoadResult *load_result) {
    static const char *const s_ps_app_runtime_remap_codes[] = {
        "FBME", "FADE", "FDKE", "FDME", "FEBE", "FICE", "FMRE", "FP7E",
        "FSME", "FZLE", "FXVE", "FLBE", "FSRJ", "FGZJ", "FSDJ", "FADJ",
        "FM2J", "FGGJ", "FTWJ", "FMKJ", "FTBJ", "FDDJ", "FDMJ", "FWCJ",
        "FVFJ", "FCLJ", "FMBJ", "FSOJ", "FBMJ", "FMPJ", "FXVJ", "FZLJ",
        "FEBJ", "FICJ", "FDKJ", "FSMJ"
    };
    const char *game_code;
    u8 quirk_remap;
    u8 quirk_sram_disable;
    u8 quirk_gpio;
    u8 quirk_tilt;
    u8 quirk_solar;

    if ((ctx == NULL) || (load_result == NULL)) {
        return;
    }

    game_code = load_result->game_code;

    ctx->rom->sig_flash1m = (load_result->flash1m_offset != 0xFFFFFFFFU) ? 1U : 0U;
    ctx->rom->sig_flash = (load_result->flash_offset != 0xFFFFFFFFU) ? 1U : 0U;
    ctx->rom->sig_sram = (load_result->sram_offset != 0xFFFFFFFFU) ? 1U : 0U;
    ctx->rom->sig_eeprom = (load_result->eeprom_offset != 0xFFFFFFFFU) ? 1U : 0U;
    ctx->rom->flash1m_offset = load_result->flash1m_offset;
    ctx->rom->flash_offset = load_result->flash_offset;
    ctx->rom->sram_offset = load_result->sram_offset;
    ctx->rom->eeprom_offset = load_result->eeprom_offset;
    PsAppRuntime_CopyText(ctx->rom->game_code, sizeof(ctx->rom->game_code), load_result->game_code);
    PsAppRuntime_CopyText(ctx->rom->maker_code, sizeof(ctx->rom->maker_code), load_result->maker_code);

    quirk_remap = PsAppRuntime_Code4InList(game_code,
                                           s_ps_app_runtime_remap_codes,
                                           sizeof(s_ps_app_runtime_remap_codes) / sizeof(s_ps_app_runtime_remap_codes[0]));
    quirk_sram_disable =
        PsAppRuntime_Code3Eq(game_code, "AR8") || PsAppRuntime_Code3Eq(game_code, "ARO") ||
        PsAppRuntime_Code3Eq(game_code, "ALG") || PsAppRuntime_Code3Eq(game_code, "ALF") ||
        PsAppRuntime_Code3Eq(game_code, "BLF") || PsAppRuntime_Code3Eq(game_code, "BDB") ||
        PsAppRuntime_Code3Eq(game_code, "BG3") || PsAppRuntime_Code3Eq(game_code, "BDV") ||
        PsAppRuntime_Code3Eq(game_code, "A2Y") || PsAppRuntime_Code3Eq(game_code, "AI2") ||
        PsAppRuntime_Code3Eq(game_code, "BT4") ||
        quirk_remap;
    /* ANWJ(电梯大战) 仅命中 EEPROM 签名，若强制 sram_dis=1 会关闭 0xE/0xF 区访问，
     * 导致该游戏启动阶段的存储探测路径异常。这里保留默认行为，不再对 ANWJ 施加禁用。 */
    quirk_gpio =
        PsAppRuntime_Code3Eq(game_code, "BPE") || PsAppRuntime_Code3Eq(game_code, "AXV") ||
        PsAppRuntime_Code3Eq(game_code, "AXP") || PsAppRuntime_Code3Eq(game_code, "RZW") ||
        PsAppRuntime_Code3Eq(game_code, "BKA") || PsAppRuntime_Code3Eq(game_code, "BR4") ||
        PsAppRuntime_Code3Eq(game_code, "V49") || PsAppRuntime_Code3Eq(game_code, "2GB") ||
        PsAppRuntime_Code3Eq(game_code, "U3I") || PsAppRuntime_Code3Eq(game_code, "U32") ||
        PsAppRuntime_Code3Eq(game_code, "U33");
    quirk_tilt =
        PsAppRuntime_Code3Eq(game_code, "KHP") || PsAppRuntime_Code3Eq(game_code, "KYG");
    quirk_solar =
        PsAppRuntime_Code3Eq(game_code, "U3I") ||
        PsAppRuntime_Code3Eq(game_code, "U32") ||
        PsAppRuntime_Code3Eq(game_code, "U33");
    ctx->rom->quirk_remap = quirk_remap;
    ctx->rom->quirk_sram_disable = quirk_sram_disable;
    ctx->rom->quirk_gpio = quirk_gpio;
    ctx->rom->quirk_tilt = quirk_tilt;
    ctx->rom->quirk_solar = quirk_solar;

    ctx->config->ctrl &= ~(GBA_CTRL_MEMORY_REMAP |
                           GBA_CTRL_FLASH_1M |
                           GBA_CTRL_SPECIAL_GPIO |
                           GBA_CTRL_TILT);
    ctx->config->ctrl |= GBA_CTRL_SRAM_FLASH_EN;

    if (quirk_remap != 0U) {
        ctx->config->ctrl |= GBA_CTRL_MEMORY_REMAP;
    }
    if (ctx->rom->sig_flash1m != 0U) {
        ctx->config->ctrl |= GBA_CTRL_FLASH_1M;
    }
    if (quirk_gpio != 0U) {
        ctx->config->ctrl |= GBA_CTRL_SPECIAL_GPIO;
    }
    if (quirk_tilt != 0U) {
        ctx->config->ctrl |= GBA_CTRL_TILT;
    }
    if (quirk_sram_disable != 0U) {
        ctx->config->ctrl &= ~GBA_CTRL_SRAM_FLASH_EN;
    }
    xil_printf("[ROMCFG] code=%s maker=%s sig flash1m=%u flash=%u sram=%u eeprom=%u\r\n",
               ctx->rom->game_code[0] != '\0' ? ctx->rom->game_code : "....",
               ctx->rom->maker_code[0] != '\0' ? ctx->rom->maker_code : "..",
               (unsigned int)ctx->rom->sig_flash1m,
               (unsigned int)ctx->rom->sig_flash,
               (unsigned int)ctx->rom->sig_sram,
               (unsigned int)ctx->rom->sig_eeprom);
    xil_printf("[ROMCFG] quirk remap=%u sram_dis=%u gpio=%u tilt=%u solar=%u ctrl=0x%08x\r\n",
               (unsigned int)ctx->rom->quirk_remap,
               (unsigned int)ctx->rom->quirk_sram_disable,
               (unsigned int)ctx->rom->quirk_gpio,
               (unsigned int)ctx->rom->quirk_tilt,
               (unsigned int)ctx->rom->quirk_solar,
               (unsigned int)ctx->config->ctrl);
}

static int PsAppRuntime_ResolveRomPath(const char *input,
                                       char *resolved_path,
                                       size_t resolved_path_size) {
    const char *effective_path;
    size_t input_len;

    if ((resolved_path == NULL) || (resolved_path_size == 0U)) {
        return -1;
    }

    effective_path = (input != NULL) ? input : PS_APP_DEFAULT_ROM_SD_PATH;
    input_len = strlen(effective_path);

    if (strstr(effective_path, ":/") != NULL) {
        if (input_len >= resolved_path_size) {
            return -1;
        }
        PsAppRuntime_CopyText(resolved_path, resolved_path_size, effective_path);
        return 0;
    }

    if ((input_len + 3U) >= resolved_path_size) {
        return -1;
    }

    resolved_path[0] = '0';
    resolved_path[1] = ':';
    resolved_path[2] = '/';
    memcpy(&resolved_path[3], effective_path, input_len);
    resolved_path[input_len + 3U] = '\0';
    return 0;
}

static XStatus PsAppRuntime_LoadRomFromSdOwned(PsAppRuntimeContext *ctx, const char *requested_path) {
    PsRomLoadResult load_result;
    char resolved_path[PS_APP_ROM_PATH_MAX_CHARS];
    XStatus status;

    if ((ctx == NULL) ||
        (PsAppRuntime_ResolveRomPath(requested_path, resolved_path, sizeof(resolved_path)) != 0)) {
        xil_printf("[ROM] invalid path\r\n");
        return XST_INVALID_PARAM;
    }

    PsAppRuntimeRom_AdvanceGeneration(ctx->rom);
    {
        u32 memory_status = 0U;
        u32 memory_error = 0U;
        XStatus memory_result;

        /* Stop periodic save/RTC work, drain PL memory requests, then flush the
         * previous game's exact dirty generations before touching ROM DDR. */
        ctx->rom->is_loading = 1U;
        memory_result = PsAppRuntimeRom_RunMemoryCommand(ctx,
                                                        GBA_MEM_CMD_QUIESCE,
                                                        &memory_status,
                                                        &memory_error);
        if (memory_result != XST_SUCCESS) {
            ctx->rom->is_loading = 0U;
            return memory_result;
        }
    }

    if (PsAppRuntimeFeature_OnRomPreUnload(ctx) != XST_SUCCESS) {
        if (PsAppRuntimeRom_ResumeAfterAbort(ctx) != XST_SUCCESS) {
            ctx->config->ctrl &= ~GBA_CTRL_CORE_ON;
            PsAppRuntime_ApplyShadowConfig(ctx);
            PsGbaRegs_SetSwReset(ctx->regs, 1U);
        }
        ctx->rom->is_loading = 0U;
        return XST_FAILURE;
    }

    ctx->rom->loaded = 0U;
    ctx->rom->size_bytes = 0U;
    ctx->rom->size_aligned = 0U;
    ctx->rom->sig_flash1m = 0U;
    ctx->rom->sig_flash = 0U;
    ctx->rom->sig_sram = 0U;
    ctx->rom->sig_eeprom = 0U;
    ctx->rom->quirk_remap = 0U;
    ctx->rom->quirk_sram_disable = 0U;
    ctx->rom->quirk_gpio = 0U;
    ctx->rom->quirk_tilt = 0U;
    ctx->rom->quirk_solar = 0U;
    ctx->rom->bios_mode = (u8)PS_APP_BIOS_MODE_INTERNAL;
    ctx->rom->bios_load_ok = 0U;
    ctx->rom->bios_external_present = 0U;
    ctx->rom->bios_bytes_loaded = 0U;
    ctx->rom->flash1m_offset = 0xFFFFFFFFU;
    ctx->rom->flash_offset = 0xFFFFFFFFU;
    ctx->rom->sram_offset = 0xFFFFFFFFU;
    ctx->rom->eeprom_offset = 0xFFFFFFFFU;
    ctx->rom->game_code[0] = '\0';
    ctx->rom->maker_code[0] = '\0';
    ctx->video->fbcap_last_buf_idx = 0xFFU;
    ctx->video->fbcap_last_frame_idx = 0xFFU;
    ctx->video->blit_count = 0U;
    ctx->video->blit_last_us = 0U;
    ctx->video->blit_max_us = 0U;
    ctx->video->blit_total_us = 0U;
    ctx->video->blit_seq_gap_max = 0U;
    ctx->video->blit_seq_glitch_drop = 0U;
    ctx->diag->stall_last_pc = 0U;
    ctx->diag->stall_last_mem = 0U;
    ctx->diag->stall_last_dma = 0U;
    ctx->diag->stall_last_frame = 0U;
    ctx->diag->stall_same_sample_count = 0U;
    ctx->diag->auto_stall_audit_printed = 0U;
    PsAppRuntime_CopyText(ctx->rom->path, sizeof(ctx->rom->path), resolved_path);

    ctx->config->ctrl |= PS_APP_GBA_CTRL_BOOT_REQUIRED;
    ctx->config->ctrl &= ~GBA_CTRL_CORE_ON;
    ctx->config->ctrl |= GBA_CTRL_ROM_LOADING;
    ctx->config->max_pak_addr = 0U;
    PsAppRuntime_ApplyShadowConfig(ctx);
    PsAppDiag_PrintConfigReadback(ctx->diag_ctx, "rom-preload");

    PsGbaRegs_SetSwReset(ctx->regs, 1U);
    usleep(2000U);
    PsAppDiag_PrintConfigReadback(ctx->diag_ctx, "reset-assert");

    xil_printf("[ROM] load %s\r\n", ctx->rom->path);
    xil_printf("[ROM] target addr=0x%08x limit=%u\r\n",
               (unsigned int)PS_APP_GBA_ROM_REGION_BASE_ADDR,
               (unsigned int)PS_APP_GBA_ROM_REGION_MAX_BYTES);
    status = PsRomLoader_LoadSdFile(ctx->rom->path,
                                    (UINTPTR)PS_APP_GBA_ROM_REGION_BASE_ADDR,
                                    PS_APP_GBA_ROM_REGION_MAX_BYTES,
                                    ctx->rom->generation,
                                    &load_result,
                                    PsAppRuntimeRom_OnReadProgress,
                                    ctx->rom);
    if ((status == XST_SUCCESS) &&
        ((ctx->rom->generation != load_result.generation) ||
         (load_result.generation == 0U))) {
        status = XST_FAILURE;
    }
    if (status != XST_SUCCESS) {
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        ctx->config->max_pak_addr = 0U;
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        ctx->rom->loaded = 0U;
        ctx->rom->size_bytes = 0U;
        ctx->rom->size_aligned = 0U;
        (void)PsAppRuntimeRom_ResumeAfterAbort(ctx);
        ctx->rom->is_loading = 0U;
        xil_printf("[ROM] load failed: %s\r\n", PsRomLoader_StrError(load_result.fs_result));
        return status;
    }

    PsAppRomLoadProgress_SetPhase(ctx->rom,
                                  PS_APP_ROM_LOAD_PHASE_FINALIZING);
    status = PsAppRuntime_PrepareBiosForRom(ctx);
    if (status != XST_SUCCESS) {
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        ctx->config->max_pak_addr = 0U;
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        ctx->rom->loaded = 0U;
        ctx->rom->size_bytes = 0U;
        ctx->rom->size_aligned = 0U;
        (void)PsAppRuntimeRom_ResumeAfterAbort(ctx);
        ctx->rom->is_loading = 0U;
        xil_printf("[ROM] aborted: BIOS prepare failed\r\n");
        return status;
    }

    if (PsAppSave_PrepareForRom(ctx->save_ctx, ctx->rom->path) != XST_SUCCESS) {
        xil_printf("[SAVE] preload skipped\r\n");
    }

    status = PsAppRuntimeRom_RunMemoryCommand(ctx,
                                               GBA_MEM_CMD_FLUSH_ROM,
                                               NULL,
                                               NULL);
    if (status != XST_SUCCESS) {
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        ctx->config->max_pak_addr = 0U;
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        ctx->rom->loaded = 0U;
        ctx->rom->size_bytes = 0U;
        ctx->rom->size_aligned = 0U;
        ctx->rom->is_loading = 0U;
        return status;
    }

    ctx->config->max_pak_addr = load_result.max_pak_addr & 0x1FFFFFFU;
    ctx->config->ctrl &= ~GBA_CTRL_ROM_LOADING;
    ctx->config->ctrl |= (GBA_CTRL_CORE_ON | PS_APP_GBA_CTRL_BOOT_REQUIRED);
    PsAppRuntime_ApplyRomDetection(ctx, &load_result);
    PsAppRuntime_ApplyShadowConfig(ctx);
    status = PsAppRuntimeRom_RunMemoryCommand(ctx,
                                               GBA_MEM_CMD_RESUME,
                                               NULL,
                                               NULL);
    if (status != XST_SUCCESS) {
        /* Keep the guest stopped and release the loader gate. No ROM was
         * committed, so periodic save/feature services must not remain stuck. */
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        ctx->config->max_pak_addr = 0U;
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        ctx->rom->loaded = 0U;
        ctx->rom->size_bytes = 0U;
        ctx->rom->size_aligned = 0U;
        ctx->rom->is_loading = 0U;
        xil_printf("[ROM] resume failed; core remains stopped\r\n");
        return status;
    }
    /* Keep the loading page parked until a complete game frame is ready.
     * The presenter clears each target store before first use for this ROM. */
    (void)PsAppVideo_RequestFrame(ctx->video_ctx, 0U);
    PsAppVideo_SyncDisplayFrame(ctx->video_ctx);
    ctx->video->fbcap_last_frame_seq = PsGbaRegs_Read(ctx->regs, GBA_REG_FB_CAP_SEQ);
    PsAppDiag_PrintConfigReadback(ctx->diag_ctx, "rom-postload");

    usleep(2000U);
    PsGbaRegs_SetSwReset(ctx->regs, 0U);
    usleep(2000U);
    PsAppDiag_PrintConfigReadback(ctx->diag_ctx, "reset-release");
    usleep(2000U);
    PsAppDiag_PrintConfigReadback(ctx->diag_ctx, "post-release");

    ctx->rom->loaded = 1U;
    ctx->rom->size_bytes = load_result.bytes_loaded;
    ctx->rom->size_aligned = load_result.bytes_aligned;
    /* Keep periodic feature/save/video consumers gated while the newly loaded
     * ROM's cheat/RTC state is restored on the serialized runtime path. */
    PsAppRuntimeFeature_OnRomLoaded(ctx);
    ctx->rom->is_loading = 0U;

    xil_printf("[ROM] ready bytes=%u aligned=%u maxpak=0x%08x addr=0x%08x\r\n",
               (unsigned int)ctx->rom->size_bytes,
               (unsigned int)ctx->rom->size_aligned,
               (unsigned int)ctx->config->max_pak_addr,
               (unsigned int)PS_APP_GBA_ROM_REGION_BASE_ADDR);
    xil_printf("[ROM] bios mode=%s ext=%u load_ok=%u bytes=%u\r\n",
               PsAppRuntime_BiosModeName(ctx->rom->bios_mode),
               (unsigned int)ctx->rom->bios_external_present,
               (unsigned int)ctx->rom->bios_load_ok,
               (unsigned int)ctx->rom->bios_bytes_loaded);
    PsAppDiag_PrintRomProbe(ctx->diag_ctx);
    PsAppDiag_PrintLaunchTrace(ctx->diag_ctx,
                               PS_APP_LAUNCH_DIAG_SAMPLES,
                               PS_APP_LAUNCH_DIAG_INTERVAL_MS);

    return XST_SUCCESS;
}

static XStatus PsAppRuntime_UnloadRomOwned(PsAppRuntimeContext *ctx) {
    if ((ctx == NULL) ||
        (ctx->rom == NULL) ||
        (ctx->config == NULL) ||
        (ctx->regs == NULL)) {
        return XST_FAILURE;
    }

    if (ctx->rom->is_loading != 0U) {
        return XST_DEVICE_BUSY;
    }

    PsAppRuntimeRom_AdvanceGeneration(ctx->rom);
    ctx->rom->is_loading = 1U;
    if (PsAppRuntimeRom_RunMemoryCommand(ctx,
                                         GBA_MEM_CMD_QUIESCE,
                                         NULL,
                                         NULL) != XST_SUCCESS) {
        ctx->rom->is_loading = 0U;
        return XST_FAILURE;
    }
    if (PsAppRuntimeFeature_OnRomPreUnload(ctx) != XST_SUCCESS) {
        if (PsAppRuntimeRom_ResumeAfterAbort(ctx) != XST_SUCCESS) {
            ctx->config->ctrl &= ~GBA_CTRL_CORE_ON;
            PsAppRuntime_ApplyShadowConfig(ctx);
            PsGbaRegs_SetSwReset(ctx->regs, 1U);
        }
        ctx->rom->is_loading = 0U;
        return XST_FAILURE;
    }
    /* RESUME is valid only after a cache flush in this quiesce generation. */
    if (PsAppRuntimeRom_RunMemoryCommand(ctx,
                                         GBA_MEM_CMD_FLUSH_ROM,
                                         NULL,
                                         NULL) != XST_SUCCESS) {
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        ctx->rom->is_loading = 0U;
        return XST_FAILURE;
    }

    ctx->config->keys = 0U;
    ctx->config->max_pak_addr = 0U;
    ctx->config->ctrl |= PS_APP_GBA_CTRL_BOOT_REQUIRED;
    ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON |
                           GBA_CTRL_ROM_LOADING |
                           GBA_CTRL_MEMORY_REMAP |
                           GBA_CTRL_FLASH_1M |
                           GBA_CTRL_SPECIAL_GPIO |
                           GBA_CTRL_TILT);
    ctx->config->ctrl |= GBA_CTRL_SRAM_FLASH_EN;
    PsAppRuntime_ApplyShadowConfig(ctx);

    PsGbaRegs_SetSwReset(ctx->regs, 1U);
    usleep(2000U);

    ctx->rom->loaded = 0U;
    ctx->rom->size_bytes = 0U;
    ctx->rom->size_aligned = 0U;
    ctx->rom->sig_flash1m = 0U;
    ctx->rom->sig_flash = 0U;
    ctx->rom->sig_sram = 0U;
    ctx->rom->sig_eeprom = 0U;
    ctx->rom->quirk_remap = 0U;
    ctx->rom->quirk_sram_disable = 0U;
    ctx->rom->quirk_gpio = 0U;
    ctx->rom->quirk_tilt = 0U;
    ctx->rom->quirk_solar = 0U;
    ctx->rom->bios_mode = (u8)PS_APP_BIOS_MODE_INTERNAL;
    ctx->rom->bios_load_ok = 0U;
    ctx->rom->bios_external_present = 0U;
    ctx->rom->bios_bytes_loaded = 0U;
    ctx->rom->flash1m_offset = 0xFFFFFFFFU;
    ctx->rom->flash_offset = 0xFFFFFFFFU;
    ctx->rom->sram_offset = 0xFFFFFFFFU;
    ctx->rom->eeprom_offset = 0xFFFFFFFFU;
    ctx->rom->game_code[0] = '\0';
    ctx->rom->maker_code[0] = '\0';
    ctx->rom->path[0] = '\0';

    if (ctx->feature != NULL) {
        ctx->feature->pending_save = 0U;
        ctx->feature->pending_load = 0U;
        ctx->feature->rewind_active = 0U;
        ctx->feature->input_prev_buttons = 0U;
        ctx->feature->input_prev_lt = 0U;
        ctx->feature->input_prev_rt = 0U;
    }

    if ((ctx->video_ctx != NULL) && (ctx->vdma != NULL)) {
        (void)PsAppVideo_FillAllFrames(ctx->video_ctx, 0x00000000U);
        (void)PsAppVideo_RequestFrame(ctx->video_ctx, 0U);
        PsAppVideo_SyncDisplayFrame(ctx->video_ctx);
    }

    if (PsAppRuntimeRom_RunMemoryCommand(ctx,
                                         GBA_MEM_CMD_RESUME,
                                         NULL,
                                         NULL) != XST_SUCCESS) {
        ctx->rom->is_loading = 0U;
        ctx->config->ctrl &= ~(GBA_CTRL_CORE_ON | GBA_CTRL_ROM_LOADING);
        PsAppRuntime_ApplyShadowConfig(ctx);
        PsGbaRegs_SetSwReset(ctx->regs, 1U);
        return XST_FAILURE;
    }
    ctx->rom->is_loading = 0U;
    return XST_SUCCESS;
}



XStatus PsAppRuntime_LoadRomFromSd(PsAppRuntimeContext *ctx, const char *requested_path) {
    XStatus status;

    if ((ctx == NULL) || (ctx->rom == NULL)) {
        return XST_INVALID_PARAM;
    }

    if ((PsAppRuntimeCommand_IsOwnerTask() != 0U) ||
        (PsAppRuntimeCommand_IsBootstrapTask() != 0U)) {
        (void)PsAppRomLoadProgress_Begin(ctx->rom);
        status = PsAppRuntime_LoadRomFromSdOwned(ctx, requested_path);
        PsAppRomLoadProgress_Complete(ctx->rom, status);
        return status;
    }

    {
        PsAppRomLoadProgressSnapshot before;

        PsAppRomLoadProgress_GetSnapshot(ctx->rom, &before);
        status = PsAppRuntimeCommand_Submit(ctx,
                                            PS_APP_RUNTIME_COMMAND_LOAD_ROM,
                                            requested_path,
                                            0U);
        if (status != XST_SUCCESS) {
            (void)PsAppRomLoadProgress_FailIfUnchanged(ctx->rom,
                                                       before.attempt_id,
                                                       status);
        }
    }
    return status;
}

XStatus PsAppRuntime_UnloadRom(PsAppRuntimeContext *ctx) {
    if ((PsAppRuntimeCommand_IsOwnerTask() != 0U) ||
        (PsAppRuntimeCommand_IsBootstrapTask() != 0U)) {
        return PsAppRuntime_UnloadRomOwned(ctx);
    }
    return PsAppRuntimeCommand_Submit(ctx,
                                      PS_APP_RUNTIME_COMMAND_UNLOAD_ROM,
                                      NULL,
                                      0U);
}

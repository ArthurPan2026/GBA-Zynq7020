#ifndef PS_ROM_LOADER_H
#define PS_ROM_LOADER_H

#include "xil_types.h"
#include "xstatus.h"
#include "ff.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*PsRomLoaderProgressCallback)(u32 bytes_done,
                                             u32 total_bytes,
                                             void *user_ctx);

typedef struct {
    u32 generation;
    u32 bytes_loaded;
    u32 bytes_aligned;
    u32 max_pak_addr;
    u32 flash1m_offset;
    u32 flash_offset;
    u32 sram_offset;
    u32 eeprom_offset;
    char game_code[5];
    char maker_code[3];
    UINTPTR ddr_base_addr;
    FRESULT fs_result;
} PsRomLoadResult;

XStatus PsRomLoader_LoadSdFile(const char *path,
                               UINTPTR ddr_base_addr,
                               u32 ddr_capacity_bytes,
                               u32 generation,
                               PsRomLoadResult *result_out,
                               PsRomLoaderProgressCallback progress_callback,
                               void *progress_user_ctx);

const char *PsRomLoader_StrError(FRESULT result);

#ifdef __cplusplus
}
#endif

#endif

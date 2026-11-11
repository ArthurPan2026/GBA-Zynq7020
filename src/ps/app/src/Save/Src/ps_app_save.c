#include "Save/Inc/ps_app_save.h"
#include "Save/Inc/ps_app_save_logic.h"

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"

#include <string.h>

#include "Gba/Inc/ps_gba_regs.h"
#include "Gba/Inc/ps_pl_contract_generated.h"
#include "Storage/Inc/ps_fatfs_storage.h"
#include "Common/Inc/ps_app_time.h"
#include "xil_cache.h"
#include "xil_printf.h"

#define PS_APP_SAVE_ENABLE_POSTWRITE_CHECKSUM 0U

/* 关键防坑：
 * 保存数据先快照到 PS DDR 常驻缓冲，再交给 FatFs 写盘，避免写盘过程中直接反复访问
 * 0x10000000 保存窗口带来的时序/总线耦合风险。
 * 64B 对齐用于配合 DCache 维护，降低缓存行边界副作用。 */
static u8 s_ps_app_save_snapshot[PS_APP_GBA_SAVE_REGION_MAX_BYTES] __attribute__((aligned(64)));

#define PS_APP_SAVE_REQUEST_POOL_COUNT PS_APP_SAVE_COMMAND_QUEUE_DEPTH

typedef enum {
    PS_APP_SAVE_OP_RESET = 1U,
    PS_APP_SAVE_OP_PREPARE_ROM = 2U,
    PS_APP_SAVE_OP_FLUSH = 3U
} PsAppSaveOperation;

typedef struct PsAppSaveRequest {
    PsAppSaveOperation operation;
    PsAppSaveContext *context;
    char rom_path[PS_APP_ROM_PATH_MAX_CHARS];
    XStatus result;
    u8 in_use;
    SemaphoreHandle_t completed;
} PsAppSaveRequest;

static QueueHandle_t s_ps_app_save_request_queue;
static SemaphoreHandle_t s_ps_app_save_pool_lock;
static PsAppSaveRequest s_ps_app_save_requests[PS_APP_SAVE_REQUEST_POOL_COUNT];
static TaskHandle_t s_ps_app_save_owner_task;
static u32 s_ps_app_save_snapshot_sequence;
static u32 s_ps_app_save_ack_sequence;

static void PsAppSave_ResetImpl(PsAppSaveContext *ctx);
static XStatus PsAppSave_PrepareForRomImpl(PsAppSaveContext *ctx, const char *rom_path);
static XStatus PsAppSave_FlushIfDirtyImpl(PsAppSaveContext *ctx);
static void PsAppSave_ServiceImpl(PsAppSaveContext *ctx);
static XStatus PsAppSave_FlushKind(PsAppSaveContext *ctx,
                                   PsAppSaveKind kind,
                                   u32 generation);
static u8 PsAppSave_IsKindBusy(const PsGbaSaveSnapshot *snapshot, u32 index);
static u8 PsAppSave_IsKindDirty(const PsGbaSaveSnapshot *snapshot, u32 index);

static int PsAppSave_IsPtrInDdr(const void *ptr) {
    UINTPTR addr;
    addr = (UINTPTR)ptr;
    return (addr >= 0x00100000U) && (addr < 0x40000000U);
}

static XStatus PsAppSave_SnapshotWindow(PsAppSaveContext *ctx,
                                        UINTPTR base_addr,
                                        u32 bytes,
                                        UINTPTR *snapshot_addr_out) {
    xil_printf("[SAVE] snapshot enter base=0x%08x bytes=%u\r\n",
               (unsigned int)base_addr,
               (unsigned int)bytes);
    xil_printf("[SAVE] snapshot ctx=0x%08x regs_ptr=0x%08x\r\n",
               (unsigned int)(UINTPTR)ctx,
               (unsigned int)(UINTPTR)((ctx != NULL) ? ctx->regs : NULL));
    if ((ctx == NULL) || (ctx->regs == NULL) || (snapshot_addr_out == NULL)) {
        xil_printf("[SAVE] snapshot invalid ctx\r\n");
        return XST_FAILURE;
    }
    if ((!PsAppSave_IsPtrInDdr(ctx)) ||
        (!PsAppSave_IsPtrInDdr(ctx->state)) ||
        (!PsAppSave_IsPtrInDdr(ctx->rom)) ||
        (!PsAppSave_IsPtrInDdr(ctx->regs))) {
        /* 关键防坑：
         * 一旦上下文指针跑飞，继续执行通常会直接硬挂。这里先 fail-fast 打印，便于现场定位。 */
        xil_printf("[SAVE] snapshot ptr invalid ctx=0x%08x state=0x%08x rom=0x%08x regs=0x%08x\r\n",
                   (unsigned int)(UINTPTR)ctx,
                   (unsigned int)(UINTPTR)ctx->state,
                   (unsigned int)(UINTPTR)ctx->rom,
                   (unsigned int)(UINTPTR)ctx->regs);
        return XST_FAILURE;
    }
    if ((base_addr == 0U) || (bytes == 0U) || (bytes > sizeof(s_ps_app_save_snapshot))) {
        xil_printf("[SAVE] snapshot invalid range\r\n");
        return XST_INVALID_PARAM;
    }

    /* 关键防坑：
     * 保存热路径不再读/改 SW_RESET。历史上该路径出现过读寄存器后系统停滞，
     * 因此保持“只做窗口快照，不碰控制寄存器”更稳妥。 */
    xil_printf("[SAVE] snapshot step skip reset toggle\r\n");

    xil_printf("[SAVE] snapshot step dcache inv\r\n");
    Xil_DCacheInvalidateRange((INTPTR)base_addr, bytes);
    xil_printf("[SAVE] snapshot step memcpy begin\r\n");
    memcpy(s_ps_app_save_snapshot, (const void *)base_addr, bytes);
    xil_printf("[SAVE] snapshot step memcpy done\r\n");
    Xil_DCacheFlushRange((INTPTR)s_ps_app_save_snapshot, bytes);
    xil_printf("[SAVE] snapshot step dcache flush done\r\n");

    *snapshot_addr_out = (UINTPTR)s_ps_app_save_snapshot;
    xil_printf("[SAVE] snapshot exit ok\r\n");
    return XST_SUCCESS;
}

/* 逻辑 save 类型 -> DDR 窗口基址：
 * SRAM 与 FLASH 在 core 侧复用同一段窗口（起点一致，按不同逻辑长度解释）。
 * EEPROM 则放在后续独立窗口，避免覆盖 SRAM/FLASH 区域。 */
static UINTPTR PsAppSave_BaseAddr(PsAppSaveKind kind) {
    switch (kind) {
        case PS_APP_SAVE_KIND_SRAM:
        case PS_APP_SAVE_KIND_FLASH:
            return (UINTPTR)PS_APP_GBA_SAVE_REGION_BASE_ADDR;
        case PS_APP_SAVE_KIND_EEPROM:
            /* 这里使用 FLASH 逻辑长度作为偏移锚点，是为了和 RTL softmap 地址保持一致。
             * 该偏移不是“展开字节”概念，窗口展开由 WindowByteCount 单独处理。 */
            return (UINTPTR)(PS_APP_GBA_SAVE_REGION_BASE_ADDR + PS_APP_GBA_SAVE_FLASH_BYTES);
        default:
            return 0U;
    }
}

static u32 PsAppSave_ByteCount(PsAppSaveKind kind) {
    switch (kind) {
        case PS_APP_SAVE_KIND_SRAM:
            return PS_APP_GBA_SAVE_SRAM_BYTES;
        case PS_APP_SAVE_KIND_FLASH:
            return PS_APP_GBA_SAVE_FLASH_BYTES;
        case PS_APP_SAVE_KIND_EEPROM:
            return PS_APP_GBA_SAVE_EEPROM_BYTES;
        default:
            return 0U;
    }
}

static u32 PsAppSave_WindowByteCount(PsAppSaveKind kind) {
    /* window 字节数 = 逻辑字节数 * stride(4)。
     * 任何对 DDR 保存窗口的 memcpy/memset 都必须用这个值，不能直接用逻辑大小。 */
    switch (kind) {
        case PS_APP_SAVE_KIND_SRAM:
            return PS_APP_GBA_SAVE_SRAM_WINDOW_BYTES;
        case PS_APP_SAVE_KIND_FLASH:
            return PS_APP_GBA_SAVE_FLASH_WINDOW_BYTES;
        case PS_APP_SAVE_KIND_EEPROM:
            return PS_APP_GBA_SAVE_EEPROM_WINDOW_BYTES;
        default:
            return 0U;
    }
}

static const char *PsAppSave_Extension(PsAppSaveKind kind) {
    switch (kind) {
        case PS_APP_SAVE_KIND_SRAM:
            return ".sav";
        case PS_APP_SAVE_KIND_FLASH:
            return ".fla";
        case PS_APP_SAVE_KIND_EEPROM:
            return ".eep";
        default:
            return ".bin";
    }
}

static u32 PsAppSave_Checksum(UINTPTR base_addr, u32 bytes) {
    const u8 *ptr;
    u32 idx;
    u32 hash;

    if ((base_addr == 0U) || (bytes == 0U)) {
        return 0U;
    }

    ptr = (const u8 *)base_addr;
    hash = 2166136261U;
    for (idx = 0U; idx < bytes; ++idx) {
        hash ^= ptr[idx];
        hash *= 16777619U;
    }
    return hash;
}

static size_t PsAppSave_Utf8SafePrefixLen(const char *src, size_t src_len, size_t max_len) {
    size_t pos;
    size_t limit;

    if (src == NULL) {
        return 0U;
    }

    pos = 0U;
    limit = (src_len < max_len) ? src_len : max_len;
    while (pos < limit) {
        size_t char_len;
        size_t idx;
        u8 valid;
        unsigned char lead;

        lead = (unsigned char)src[pos];
        if ((lead & 0x80U) == 0U) {
            char_len = 1U;
        } else if ((lead & 0xE0U) == 0xC0U) {
            char_len = 2U;
        } else if ((lead & 0xF0U) == 0xE0U) {
            char_len = 3U;
        } else if ((lead & 0xF8U) == 0xF0U) {
            char_len = 4U;
        } else {
            char_len = 1U;
        }

        if ((pos + char_len) > limit) {
            break;
        }

        valid = 1U;
        for (idx = 1U; idx < char_len; ++idx) {
            if (((unsigned char)src[pos + idx] & 0xC0U) != 0x80U) {
                valid = 0U;
                break;
            }
        }
        pos += (valid != 0U) ? char_len : 1U;
    }

    return pos;
}

static void PsAppSave_CopyTextBounded(char *dst,
                                      size_t dst_size,
                                      const char *src,
                                      size_t src_max_len) {
    size_t src_len;
    size_t copy_len;

    if ((dst == NULL) || (dst_size == 0U)) {
        return;
    }

    if (src == NULL) {
        dst[0] = '\0';
        return;
    }

    src_len = 0U;
    while ((src_len < src_max_len) && (src[src_len] != '\0')) {
        src_len++;
    }
    copy_len = PsAppSave_Utf8SafePrefixLen(src, src_len, dst_size - 1U);
    memcpy(dst, src, copy_len);
    dst[copy_len] = '\0';
}

static void PsAppSave_CopyText(char *dst, size_t dst_size, const char *src) {
    PsAppSave_CopyTextBounded(dst, dst_size, src, (src != NULL) ? strlen(src) : 0U);
}

static void PsAppSave_SanitizeAsciiInPlace(char *text) {
    size_t idx;

    if (text == NULL) {
        return;
    }

    for (idx = 0U; text[idx] != '\0'; ++idx) {
        unsigned char ch = (unsigned char)text[idx];
        if ((ch < 0x20U) || (ch > 0x7EU)) {
            text[idx] = '?';
        }
    }
}

static void PsAppSave_RomStem(const char *rom_path, char *stem_out, size_t stem_size) {
    const char *name_ptr;
    const char *dot_ptr;
    size_t copy_len;

    if ((stem_out == NULL) || (stem_size == 0U)) {
        return;
    }

    stem_out[0] = '\0';
    if ((rom_path == NULL) || (*rom_path == '\0')) {
        return;
    }

    name_ptr = strrchr(rom_path, '/');
    if (name_ptr == NULL) {
        name_ptr = strrchr(rom_path, '\\');
    }
    name_ptr = (name_ptr == NULL) ? rom_path : (name_ptr + 1);
    dot_ptr = strrchr(name_ptr, '.');
    copy_len = (dot_ptr != NULL) ? (size_t)(dot_ptr - name_ptr) : strlen(name_ptr);
    PsAppSave_CopyTextBounded(stem_out, stem_size, name_ptr, copy_len);
}

static void PsAppSave_BuildPath(const char *rom_path,
                                PsAppSaveKind kind,
                                char *path_out,
                                size_t path_size) {
    char stem[PS_APP_ROM_PATH_MAX_CHARS];
    const char *ext;
    size_t dir_len;
    size_t stem_len;
    size_t ext_len;

    if ((path_out == NULL) || (path_size == 0U)) {
        return;
    }

    path_out[0] = '\0';
    PsAppSave_RomStem(rom_path, stem, sizeof(stem));
    if (stem[0] == '\0') {
        return;
    }

    ext = PsAppSave_Extension(kind);
    dir_len = strlen(PS_APP_SAVE_SD_DIR);
    stem_len = strlen(stem);
    ext_len = strlen(ext);
    if ((dir_len + 1U + stem_len + ext_len + 1U) > path_size) {
        return;
    }

    memcpy(path_out, PS_APP_SAVE_SD_DIR, dir_len);
    path_out[dir_len] = '/';
    memcpy(&path_out[dir_len + 1U], stem, stem_len);
    memcpy(&path_out[dir_len + 1U + stem_len], ext, ext_len);
    path_out[dir_len + 1U + stem_len + ext_len] = '\0';
}

static void PsAppSave_ClearWindow(PsAppSaveKind kind) {
    UINTPTR base_addr;
    u32 bytes;

    base_addr = PsAppSave_BaseAddr(kind);
    bytes = PsAppSave_WindowByteCount(kind);
    if ((base_addr == 0U) || (bytes == 0U)) {
        return;
    }

    /* 用 0xFF 清窗口，匹配大多数卡带保存介质“擦除态”语义。 */
    memset((void *)base_addr, 0xFF, bytes);
    Xil_DCacheFlushRange((INTPTR)base_addr, bytes);
}

static XStatus PsAppSave_TryLoadKind(PsAppSaveContext *ctx,
                                     const char *rom_path,
                                     PsAppSaveKind kind,
                                     u8 *loaded_out) {
    PsFatFsStorageReadResult read_result;
    char path[PS_APP_ROM_PATH_MAX_CHARS];
    UINTPTR base_addr;
    u8 *window_ptr;
    u32 logical_bytes;
    u32 window_bytes;
    u32 idx;
    XStatus status;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return XST_FAILURE;
    }

    PsAppSave_BuildPath(rom_path, kind, path, sizeof(path));
    if (path[0] == '\0') {
        return XST_INVALID_PARAM;
    }

    logical_bytes = PsAppSave_ByteCount(kind);
    window_bytes = PsAppSave_WindowByteCount(kind);
    base_addr = PsAppSave_BaseAddr(kind);
    if ((logical_bytes == 0U) || (window_bytes == 0U) || (base_addr == 0U) ||
        (logical_bytes > sizeof(s_ps_app_save_snapshot))) {
        return XST_FAILURE;
    }

    memset(&read_result, 0, sizeof(read_result));
    status = PsFatFsStorage_ReadFileToMemory(path,
                                             (UINTPTR)s_ps_app_save_snapshot,
                                             logical_bytes,
                                             &read_result);
    if (status != XST_SUCCESS) {
        return status;
    }

    /* gba_mister 的保存窗口是 4x 展开格式：每个逻辑字节占用一个 32-bit 槽位。
     * 从磁盘加载时需要把标准存档格式“解包”到 core 可直接读取的窗口布局。 */
    window_ptr = (u8 *)base_addr;
    memset(window_ptr, 0xFF, window_bytes);
    for (idx = 0U; idx < read_result.bytes_loaded; ++idx) {
        u8 v = s_ps_app_save_snapshot[idx];
        u32 off = idx * PS_APP_GBA_SAVE_EXPAND_STRIDE;
        window_ptr[off + 0U] = v;
        window_ptr[off + 1U] = v;
        window_ptr[off + 2U] = v;
        window_ptr[off + 3U] = v;
    }
    Xil_DCacheFlushRange((INTPTR)base_addr, window_bytes);

    ctx->state->loaded_from_sd = 1U;
    ctx->state->last_bytes = read_result.bytes_loaded;
    ctx->state->last_checksum = PsAppSave_Checksum((UINTPTR)s_ps_app_save_snapshot, read_result.bytes_loaded);
    ctx->state->active_kind = (u8)kind;
    PsAppSave_CopyText(ctx->state->path, sizeof(ctx->state->path), path);
    if (loaded_out != NULL) {
        *loaded_out = 1U;
    }
    return XST_SUCCESS;
}

static u32 PsAppSave_KindIndex(PsAppSaveKind kind) {
    if ((kind < PS_APP_SAVE_KIND_SRAM) || (kind > PS_APP_SAVE_KIND_EEPROM)) {
        return 0xFFFFFFFFU;
    }
    return (u32)kind - 1U;
}

static PsAppSaveKind PsAppSave_KindFromIndex(u32 index) {
    return (index < 3U) ? (PsAppSaveKind)(index + 1U) : PS_APP_SAVE_KIND_NONE;
}

static u32 PsAppSave_HardwareKind(u32 index) {
    static const u32 kinds[3] = {
        GBA_SAVE_KIND_SRAM,
        GBA_SAVE_KIND_FLASH,
        GBA_SAVE_KIND_EEPROM
    };
    return (index < 3U) ? kinds[index] : 0xFFFFFFFFU;
}

static u32 PsAppSave_DirtyStatusBit(u32 index) {
    static const u32 bits[3] = {
        GBA_SAVE_STATUS_DIRTY_SRAM,
        GBA_SAVE_STATUS_DIRTY_FLASH,
        GBA_SAVE_STATUS_DIRTY_EEPROM
    };
    return (index < 3U) ? bits[index] : 0U;
}

static u32 PsAppSave_BusyStatusBit(u32 index) {
    static const u32 bits[3] = {
        GBA_SAVE_STATUS_BUSY_SRAM,
        GBA_SAVE_STATUS_BUSY_FLASH,
        GBA_SAVE_STATUS_BUSY_EEPROM
    };
    return (index < 3U) ? bits[index] : 0U;
}

static XStatus PsAppSave_ReadSnapshot(PsAppSaveContext *ctx,
                                     PsGbaSaveSnapshot *snapshot_out) {
    if ((ctx == NULL) || (ctx->regs == NULL) || (snapshot_out == NULL)) {
        return XST_INVALID_PARAM;
    }
    s_ps_app_save_snapshot_sequence++;
    if (s_ps_app_save_snapshot_sequence == 0U) {
        s_ps_app_save_snapshot_sequence = 1U;
    }
    return PsGbaRegs_ReadSaveSnapshot(ctx->regs,
                                      s_ps_app_save_snapshot_sequence,
                                      PS_APP_SAVE_SNAPSHOT_TIMEOUT_MS,
                                      snapshot_out);
}

static void PsAppSave_SyncStateFromSnapshot(PsAppSaveContext *ctx,
                                            const PsGbaSaveSnapshot *snapshot) {
    u32 idx;
    u8 dirty_mask;
    u32 active_index;

    if ((ctx == NULL) || (ctx->state == NULL) || (snapshot == NULL)) {
        return;
    }
    ctx->state->event_counters = snapshot->legacy_counters;
    dirty_mask = 0U;
    active_index = 0xFFFFFFFFU;
    for (idx = 0U; idx < 3U; ++idx) {
        PsAppSaveKindRuntime runtime;
        u8 dirty;
        u8 busy;

        runtime.generation = ctx->state->generation_by_kind[idx];
        runtime.quiet_ticks = ctx->state->quiet_ticks_by_kind[idx];
        runtime.dirty_age_ticks = ctx->state->dirty_age_ticks_by_kind[idx];
        runtime.dirty = (u8)((ctx->state->dirty_mask & (u8)(1U << idx)) != 0U);
        dirty = PsAppSave_IsKindDirty(snapshot, idx);
        busy = PsAppSave_IsKindBusy(snapshot, idx);
        PsAppSaveLogic_Observe(&runtime, dirty, busy, snapshot->generation[idx]);
        ctx->state->generation_by_kind[idx] = runtime.generation;
        ctx->state->quiet_ticks_by_kind[idx] = runtime.quiet_ticks;
        ctx->state->dirty_age_ticks_by_kind[idx] = runtime.dirty_age_ticks;
        if (runtime.dirty != 0U) {
            dirty_mask |= (u8)(1U << idx);
            active_index = idx;
        }
    }
    ctx->state->dirty_mask = dirty_mask;
    ctx->state->dirty = (dirty_mask != 0U) ? 1U : 0U;
    if (active_index != 0xFFFFFFFFU) {
        ctx->state->active_kind = (u8)PsAppSave_KindFromIndex(active_index);
        ctx->state->quiet_ticks = ctx->state->quiet_ticks_by_kind[active_index];
        ctx->state->dirty_age_ticks = ctx->state->dirty_age_ticks_by_kind[active_index];
    } else {
        /* Preserve the most recently loaded/saved kind for the UI while clean. */
        ctx->state->quiet_ticks = 0U;
        ctx->state->dirty_age_ticks = 0U;
    }
}

static u8 PsAppSave_IsKindBusy(const PsGbaSaveSnapshot *snapshot, u32 index) {
    return (u8)(((snapshot->status & PsAppSave_BusyStatusBit(index)) != 0U) ? 1U : 0U);
}

static u8 PsAppSave_IsKindDirty(const PsGbaSaveSnapshot *snapshot, u32 index) {
    return (u8)(((snapshot->status & PsAppSave_DirtyStatusBit(index)) != 0U) ? 1U : 0U);
}

static XStatus PsAppSave_FlushKind(PsAppSaveContext *ctx,
                                   PsAppSaveKind kind,
                                   u32 generation) {
    PsGbaSaveSnapshot before;
    PsGbaSaveSnapshot after;
    PsGbaSaveSnapshot current;
    PsFatFsStorageWriteResult write_result;
    char path[PS_APP_ROM_PATH_MAX_CHARS];
    UINTPTR base_addr;
    UINTPTR snapshot_addr;
    u32 logical_bytes;
    u32 window_bytes;
    u32 index;
    XStatus status;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->rom == NULL) ||
        (ctx->regs == NULL) || (ctx->rom->path[0] == '\0')) {
        return XST_FAILURE;
    }
    index = PsAppSave_KindIndex(kind);
    if (index >= 3U) return XST_INVALID_PARAM;

    PsAppSave_BuildPath(ctx->rom->path, kind, path, sizeof(path));
    if (path[0] == '\0') return XST_INVALID_PARAM;

    /* A generation is saved only from a stable, idle window. The second
     * snapshot brackets the DDR copy; writes during or immediately after the
     * copy leave the hardware dirty because ACK matches this exact generation. */
    status = PsAppSave_ReadSnapshot(ctx, &before);
    if (status != XST_SUCCESS) return status;
    PsAppSave_SyncStateFromSnapshot(ctx, &before);
    if ((PsAppSave_IsKindBusy(&before, index) != 0U) ||
        (PsAppSave_IsKindDirty(&before, index) == 0U) ||
        (before.generation[index] != generation)) {
        return XST_FAILURE;
    }

    base_addr = PsAppSave_BaseAddr(kind);
    logical_bytes = PsAppSave_ByteCount(kind);
    window_bytes = PsAppSave_WindowByteCount(kind);
    if ((logical_bytes == 0U) || (window_bytes == 0U)) return XST_FAILURE;
    xil_printf("[SAVE] flush begin %s logical=%u window=%u generation=%u\r\n",
               path,
               (unsigned int)logical_bytes,
               (unsigned int)window_bytes,
               (unsigned int)generation);

    if (PsAppSave_SnapshotWindow(ctx,
                                 base_addr,
                                 window_bytes,
                                 &snapshot_addr) != XST_SUCCESS) {
        xil_printf("[SAVE] snapshot failed base=0x%08x bytes=%u\r\n",
                   (unsigned int)base_addr,
                   (unsigned int)window_bytes);
        return XST_FAILURE;
    }

    status = PsAppSave_ReadSnapshot(ctx, &after);
    if (status != XST_SUCCESS) return status;
    PsAppSave_SyncStateFromSnapshot(ctx, &after);
    if ((PsAppSave_IsKindBusy(&after, index) != 0U) ||
        (PsAppSave_IsKindDirty(&after, index) == 0U) ||
        (before.generation[index] != after.generation[index])) {
        xil_printf("[SAVE] copy discarded kind=%u gen_before=%u gen_after=%u busy_before=%u busy_after=%u\r\n",
                   (unsigned int)kind,
                   (unsigned int)before.generation[index],
                   (unsigned int)after.generation[index],
                   (unsigned int)PsAppSave_IsKindBusy(&before, index),
                   (unsigned int)PsAppSave_IsKindBusy(&after, index));
        return XST_FAILURE;
    }

    /* The file format remains the original raw .sav/.fla/.eep byte stream. */
    {
        u32 idx;
        for (idx = 0U; idx < logical_bytes; ++idx) {
            s_ps_app_save_snapshot[idx] =
                s_ps_app_save_snapshot[idx * PS_APP_GBA_SAVE_EXPAND_STRIDE];
        }
    }
    Xil_DCacheFlushRange((INTPTR)s_ps_app_save_snapshot, logical_bytes);

    memset(&write_result, 0, sizeof(write_result));
    if (PsFatFsStorage_WriteMemoryToFile(path,
                                         (UINTPTR)s_ps_app_save_snapshot,
                                         logical_bytes,
                                         &write_result) != XST_SUCCESS) {
        xil_printf("[SAVE] flush failed %s fs=%s\r\n",
                   path,
                   PsFatFsStorage_StrError(write_result.fs_result));
        return XST_FAILURE;
    }

    s_ps_app_save_ack_sequence++;
    if (s_ps_app_save_ack_sequence == 0U) s_ps_app_save_ack_sequence = 1U;
    status = PsGbaRegs_AckSaveGeneration(ctx->regs,
                                         PsAppSave_HardwareKind(index),
                                         generation,
                                         s_ps_app_save_ack_sequence,
                                         PS_APP_SAVE_ACK_TIMEOUT_MS);
    if (status != XST_SUCCESS) {
        xil_printf("[SAVE] ACK failed kind=%u generation=%u status=%d; keep dirty\r\n",
                   (unsigned int)kind,
                   (unsigned int)generation,
                   status);
        return status;
    }

    if ((!PsAppSave_IsPtrInDdr(ctx)) ||
        (!PsAppSave_IsPtrInDdr(ctx->state)) ||
        (!PsAppSave_IsPtrInDdr(ctx->rom))) {
        xil_printf("[SAVE] postwrite ptr invalid ctx=0x%08x state=0x%08x rom=0x%08x\r\n",
                   (unsigned int)(UINTPTR)ctx,
                   (unsigned int)(UINTPTR)ctx->state,
                   (unsigned int)(UINTPTR)ctx->rom);
        return XST_FAILURE;
    }

    ctx->state->flush_count++;
    ctx->state->active_kind = (u8)kind;
    ctx->state->last_bytes = write_result.bytes_written;
#if PS_APP_SAVE_ENABLE_POSTWRITE_CHECKSUM
    ctx->state->last_checksum = PsAppSave_Checksum((UINTPTR)s_ps_app_save_snapshot, logical_bytes);
#else
    ctx->state->last_checksum = 0U;
#endif
    PsAppSave_CopyText(ctx->state->path, sizeof(ctx->state->path), path);

    if (PsAppSave_ReadSnapshot(ctx, &current) == XST_SUCCESS) {
        PsAppSave_SyncStateFromSnapshot(ctx, &current);
    }
    xil_printf("[SAVE] flush %s bytes=%u gen=%u checksum=0x%08x\r\n",
               path,
               (unsigned int)ctx->state->last_bytes,
               (unsigned int)generation,
               (unsigned int)ctx->state->last_checksum);
    return XST_SUCCESS;
}

static void PsAppSave_ResetImpl(PsAppSaveContext *ctx) {
    if ((ctx == NULL) || (ctx->state == NULL)) {
        return;
    }

    memset(ctx->state, 0, sizeof(*ctx->state));
    /* FLASH 窗口覆盖 SRAM/FLASH 共享区域，因此清 FLASH 即可同时清 SRAM 视图。 */
    PsAppSave_ClearWindow(PS_APP_SAVE_KIND_FLASH);
    PsAppSave_ClearWindow(PS_APP_SAVE_KIND_EEPROM);
}

static XStatus PsAppSave_PrepareForRomImpl(PsAppSaveContext *ctx, const char *rom_path) {
    char log_path[PS_APP_ROM_PATH_MAX_CHARS];
    const char *print_path;
    u8 loaded;

    if ((ctx == NULL) || (ctx->state == NULL)) {
        return XST_FAILURE;
    }

    PsAppSave_ResetImpl(ctx);
    if ((rom_path == NULL) || (*rom_path == '\0')) {
        return XST_INVALID_PARAM;
    }

    if (PsFatFsStorage_EnsureDirectory(PS_APP_SAVE_SD_DIR) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    if ((ctx->rom != NULL) && (ctx->rom->path[0] != '\0')) {
        PsAppSave_CopyTextBounded(log_path,
                                  sizeof(log_path),
                                  ctx->rom->path,
                                  sizeof(log_path) - 1U);
    } else {
        PsAppSave_CopyTextBounded(log_path,
                                  sizeof(log_path),
                                  rom_path,
                                  sizeof(log_path) - 1U);
    }
    PsAppSave_SanitizeAsciiInPlace(log_path);
    print_path = (log_path[0] != '\0') ? log_path : "(unknown)";

    loaded = 0U;
    /* 加载优先级说明：
     * 1) 先尝试 FLASH（覆盖 FLASH1M/FLASH 场景）；
     * 2) FLASH 不存在再尝试 SRAM；
     * 3) EEPROM 独立尝试（可与前两者并存于窗口布局中）。
     * 这样可兼容历史文件命名并最大化命中可恢复存档。 */
    if (PsAppSave_TryLoadKind(ctx, rom_path, PS_APP_SAVE_KIND_FLASH, &loaded) != XST_SUCCESS) {
        (void)PsAppSave_TryLoadKind(ctx, rom_path, PS_APP_SAVE_KIND_SRAM, &loaded);
    }
    if (PsAppSave_TryLoadKind(ctx, rom_path, PS_APP_SAVE_KIND_EEPROM, NULL) == XST_SUCCESS) {
        loaded = 1U;
    }
    if (loaded != 0U) {
        xil_printf("[SAVE] preload %s\r\n", ctx->state->path);
    } else {
        xil_printf("[SAVE] no existing save for %s\r\n", print_path);
    }

    return XST_SUCCESS;
}

static void PsAppSave_ServiceImpl(PsAppSaveContext *ctx) {
    PsGbaSaveSnapshot snapshot;
    XStatus status;
    u32 index;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->regs == NULL) ||
        (ctx->rom == NULL) || (ctx->rom->loaded == 0U) ||
        (ctx->rom->is_loading != 0U)) {
        return;
    }

    status = PsAppSave_ReadSnapshot(ctx, &snapshot);
    if (status != XST_SUCCESS) {
        return;
    }
    PsAppSave_SyncStateFromSnapshot(ctx, &snapshot);

    for (index = 0U; index < 3U; ++index) {
        u8 dirty;
        u8 busy;
        PsAppSaveKind kind;

        dirty = PsAppSave_IsKindDirty(&snapshot, index);
        busy = PsAppSave_IsKindBusy(&snapshot, index);
        PsAppSaveKindRuntime runtime;
        PsAppSaveLogicDecision decision;

        if ((dirty == 0U) && (busy == 0U)) continue;
        runtime.generation = ctx->state->generation_by_kind[index];
        runtime.quiet_ticks = ctx->state->quiet_ticks_by_kind[index];
        runtime.dirty_age_ticks = ctx->state->dirty_age_ticks_by_kind[index];
        runtime.dirty = (u8)((ctx->state->dirty_mask & (u8)(1U << index)) != 0U);
        decision = PsAppSaveLogic_Tick(&runtime,
                                       busy,
                                       PS_APP_SAVE_FLUSH_QUIET_TICKS,
                                       PS_APP_SAVE_FLUSH_HARD_TICKS);
        ctx->state->quiet_ticks_by_kind[index] = runtime.quiet_ticks;
        ctx->state->dirty_age_ticks_by_kind[index] = runtime.dirty_age_ticks;
        if (decision != PS_APP_SAVE_LOGIC_FLUSH_DUE) continue;

        kind = PsAppSave_KindFromIndex(index);
        if (PsAppSave_FlushKind(ctx, kind, snapshot.generation[index]) != XST_SUCCESS) {
            /* Keep the dirty generation and back off before another storage retry. */
            runtime.quiet_ticks = ctx->state->quiet_ticks_by_kind[index];
            runtime.dirty_age_ticks = ctx->state->dirty_age_ticks_by_kind[index];
            PsAppSaveLogic_ResetRetry(&runtime);
            ctx->state->quiet_ticks_by_kind[index] = runtime.quiet_ticks;
            ctx->state->dirty_age_ticks_by_kind[index] = runtime.dirty_age_ticks;
        }
    }

    if (ctx->state->dirty_mask != 0U) {
        for (index = 0U; index < 3U; ++index) {
            if ((ctx->state->dirty_mask & (u8)(1U << index)) != 0U) {
                ctx->state->active_kind = (u8)PsAppSave_KindFromIndex(index);
                ctx->state->quiet_ticks = ctx->state->quiet_ticks_by_kind[index];
                ctx->state->dirty_age_ticks = ctx->state->dirty_age_ticks_by_kind[index];
            }
        }
    }
}

static XStatus PsAppSave_FlushIfDirtyImpl(PsAppSaveContext *ctx) {
    PsGbaSaveSnapshot snapshot;
    XStatus status;
    XStatus overall_status;
    u32 index;

    if ((ctx == NULL) || (ctx->state == NULL) || (ctx->rom == NULL) || (ctx->regs == NULL)) {
        return XST_FAILURE;
    }
    if (ctx->rom->loaded == 0U) {
        return XST_SUCCESS;
    }

    status = PsAppSave_ReadSnapshot(ctx, &snapshot);
    if (status != XST_SUCCESS) return status;
    PsAppSave_SyncStateFromSnapshot(ctx, &snapshot);
    if (ctx->state->dirty_mask == 0U) return XST_SUCCESS;

    overall_status = XST_SUCCESS;
    for (index = 0U; index < 3U; ++index) {
        PsAppSaveKind kind;
        if ((ctx->state->dirty_mask & (u8)(1U << index)) == 0U) continue;
        if (PsAppSave_IsKindBusy(&snapshot, index) != 0U) {
            overall_status = XST_FAILURE;
            continue;
        }
        kind = PsAppSave_KindFromIndex(index);
        if (PsAppSave_FlushKind(ctx, kind, snapshot.generation[index]) != XST_SUCCESS) {
            overall_status = XST_FAILURE;
        }
    }
    return overall_status;
}


static PsAppSaveRequest *PsAppSave_AcquireRequest(void) {
    TickType_t wait_ticks;
    u32 idx;
    PsAppSaveRequest *request;

    if ((s_ps_app_save_request_queue == NULL) || (s_ps_app_save_pool_lock == NULL)) {
        return NULL;
    }
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_SAVE_COMMAND_WAIT_MS);
    if (xSemaphoreTake(s_ps_app_save_pool_lock, wait_ticks) != pdTRUE) {
        return NULL;
    }
    request = NULL;
    for (idx = 0U; idx < PS_APP_SAVE_REQUEST_POOL_COUNT; ++idx) {
        if (s_ps_app_save_requests[idx].in_use == 0U) {
            request = &s_ps_app_save_requests[idx];
            request->in_use = 1U;
            break;
        }
    }
    (void)xSemaphoreGive(s_ps_app_save_pool_lock);
    if (request != NULL) {
        (void)xSemaphoreTake(request->completed, 0U);
        request->result = XST_FAILURE;
        request->rom_path[0] = '\0';
    }
    return request;
}

static void PsAppSave_ReleaseRequest(PsAppSaveRequest *request) {
    if ((request == NULL) || (s_ps_app_save_pool_lock == NULL)) return;
    if (xSemaphoreTake(s_ps_app_save_pool_lock, portMAX_DELAY) == pdTRUE) {
        request->in_use = 0U;
        (void)xSemaphoreGive(s_ps_app_save_pool_lock);
    }
}

static XStatus PsAppSave_ExecuteRequest(PsAppSaveRequest *request) {
    if ((request == NULL) || (request->context == NULL)) return XST_INVALID_PARAM;
    switch (request->operation) {
        case PS_APP_SAVE_OP_RESET:
            PsAppSave_ResetImpl(request->context);
            return XST_SUCCESS;
        case PS_APP_SAVE_OP_PREPARE_ROM:
            return PsAppSave_PrepareForRomImpl(request->context, request->rom_path);
        case PS_APP_SAVE_OP_FLUSH:
            return PsAppSave_FlushIfDirtyImpl(request->context);
        default:
            return XST_INVALID_PARAM;
    }
}

static XStatus PsAppSave_Submit(PsAppSaveOperation operation,
                                PsAppSaveContext *ctx,
                                const char *rom_path) {
    PsAppSaveRequest *request;
    TickType_t wait_ticks;
    size_t path_len;
    XStatus status;

    if ((ctx == NULL) || (operation < PS_APP_SAVE_OP_RESET) ||
        (operation > PS_APP_SAVE_OP_FLUSH)) {
        return XST_INVALID_PARAM;
    }
    if ((xTaskGetSchedulerState() != taskSCHEDULER_RUNNING) ||
        (xTaskGetCurrentTaskHandle() == s_ps_app_save_owner_task)) {
        PsAppSaveRequest local_request;
        memset(&local_request, 0, sizeof(local_request));
        local_request.operation = operation;
        local_request.context = ctx;
        if (operation == PS_APP_SAVE_OP_PREPARE_ROM) {
            if ((rom_path == NULL) || (*rom_path == '\0')) return XST_INVALID_PARAM;
            path_len = strlen(rom_path);
            if (path_len >= sizeof(local_request.rom_path)) return XST_INVALID_PARAM;
            memcpy(local_request.rom_path, rom_path, path_len + 1U);
        }
        return PsAppSave_ExecuteRequest(&local_request);
    }

    request = PsAppSave_AcquireRequest();
    if (request == NULL) return XST_TIMEOUT;
    request->operation = operation;
    request->context = ctx;
    if (operation == PS_APP_SAVE_OP_PREPARE_ROM) {
        if ((rom_path == NULL) || (*rom_path == '\0')) {
            PsAppSave_ReleaseRequest(request);
            return XST_INVALID_PARAM;
        }
        path_len = strlen(rom_path);
        if (path_len >= sizeof(request->rom_path)) {
            PsAppSave_ReleaseRequest(request);
            return XST_INVALID_PARAM;
        }
        memcpy(request->rom_path, rom_path, path_len + 1U);
    }
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_SAVE_COMMAND_WAIT_MS);
    if (xQueueSend(s_ps_app_save_request_queue, &request, wait_ticks) != pdTRUE) {
        PsAppSave_ReleaseRequest(request);
        return XST_TIMEOUT;
    }
    (void)xSemaphoreTake(request->completed, portMAX_DELAY);
    status = request->result;
    PsAppSave_ReleaseRequest(request);
    return status;
}

static void PsAppSave_CleanupInit(void) {
    u32 idx;
    for (idx = 0U; idx < PS_APP_SAVE_REQUEST_POOL_COUNT; ++idx) {
        if (s_ps_app_save_requests[idx].completed != NULL) {
            (void)vSemaphoreDelete(s_ps_app_save_requests[idx].completed);
            s_ps_app_save_requests[idx].completed = NULL;
        }
    }
    if (s_ps_app_save_pool_lock != NULL) {
        (void)vSemaphoreDelete(s_ps_app_save_pool_lock);
        s_ps_app_save_pool_lock = NULL;
    }
    if (s_ps_app_save_request_queue != NULL) {
        vQueueDelete(s_ps_app_save_request_queue);
        s_ps_app_save_request_queue = NULL;
    }
    s_ps_app_save_owner_task = NULL;
}

XStatus PsAppSave_Init(PsAppSaveContext *ctx) {
    u32 idx;

    if ((ctx == NULL) || (ctx->state == NULL)) return XST_INVALID_PARAM;
    if (s_ps_app_save_request_queue != NULL) return XST_SUCCESS;
    if (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) return XST_FAILURE;

    s_ps_app_save_request_queue = xQueueCreate(PS_APP_SAVE_COMMAND_QUEUE_DEPTH,
                                                sizeof(PsAppSaveRequest *));
    s_ps_app_save_pool_lock = xSemaphoreCreateMutex();
    if ((s_ps_app_save_request_queue == NULL) || (s_ps_app_save_pool_lock == NULL)) {
        PsAppSave_CleanupInit();
        return XST_FAILURE;
    }
    for (idx = 0U; idx < PS_APP_SAVE_REQUEST_POOL_COUNT; ++idx) {
        s_ps_app_save_requests[idx].completed = xSemaphoreCreateBinary();
        if (s_ps_app_save_requests[idx].completed == NULL) {
            PsAppSave_CleanupInit();
            return XST_FAILURE;
        }
        s_ps_app_save_requests[idx].in_use = 0U;
    }
    return XST_SUCCESS;
}

void PsAppSave_Task(void *arg) {
    PsAppSaveContext *ctx = (PsAppSaveContext *)arg;
    PsAppSaveRequest *request;
    TickType_t service_ticks;

    s_ps_app_save_owner_task = xTaskGetCurrentTaskHandle();
    service_ticks = PsAppTime_MsToTicksCeil(PS_APP_MONITOR_INTERVAL_MS);
    if (service_ticks == 0U) service_ticks = 1U;
    for (;;) {
        if (xQueueReceive(s_ps_app_save_request_queue,
                          &request,
                          service_ticks) == pdTRUE) {
            request->result = PsAppSave_ExecuteRequest(request);
            (void)xSemaphoreGive(request->completed);
        } else {
            PsAppSave_ServiceImpl(ctx);
        }
    }
}

void PsAppSave_Reset(PsAppSaveContext *ctx) {
    XStatus status = PsAppSave_Submit(PS_APP_SAVE_OP_RESET, ctx, NULL);
    if (status != XST_SUCCESS) {
        xil_printf("[SAVE] reset request failed status=%d\r\n", status);
    }
}

XStatus PsAppSave_PrepareForRom(PsAppSaveContext *ctx, const char *rom_path) {
    return PsAppSave_Submit(PS_APP_SAVE_OP_PREPARE_ROM, ctx, rom_path);
}

XStatus PsAppSave_FlushIfDirty(PsAppSaveContext *ctx) {
    return PsAppSave_Submit(PS_APP_SAVE_OP_FLUSH, ctx, NULL);
}

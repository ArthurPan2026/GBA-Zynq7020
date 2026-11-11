#include "Storage/Inc/ps_fatfs_storage.h"

#include <string.h>

#include "FreeRTOS.h"
#include "semphr.h"
#include "task.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "diskio.h"

#include "Common/Inc/ps_project_config.h"
#include "Common/Inc/ps_app_time.h"
#include "Storage/Inc/ps_fatfs_txn.h"

#define PS_FATFS_STORAGE_DRIVE_PATH       "0:/"
#define PS_FATFS_STORAGE_READ_CHUNK_BYTES  (128U * 1024U)
#define PS_FATFS_STORAGE_WRITE_CHUNK_BYTES (8U * 1024U)
/* 不允许无限期等待存储锁：
 * ROM 切换、RTC 持久化、save 周期落盘会并发触发 FatFs 访问。
 * 若某条路径异常卡住，有限超时可以避免整个 PS 运行时被“连坐”死锁。 */
#define PS_FATFS_STORAGE_PATH_COPY_MAX     PS_APP_ROM_PATH_MAX_CHARS
#define PS_FATFS_STORAGE_SAVEWR_VERBOSE    0U

#if PS_FATFS_STORAGE_SAVEWR_VERBOSE
#define PS_SAVEWR_LOG(...) xil_printf(__VA_ARGS__)
#else
#define PS_SAVEWR_LOG(...) do { } while (0)
#endif

/* One task owns the FatFs instance. Requests use a fixed pool and a bounded
 * queue; a caller retains its buffers until the accepted request completes. */
#define PS_FATFS_STORAGE_SLOT_COUNT PS_APP_STORAGE_QUEUE_DEPTH
/* Matches the UI list bound and caps work/results for one list command. */
#define PS_FATFS_STORAGE_LIST_MAX_ENTRIES 128U

typedef enum {
    PS_FATFS_STORAGE_OP_READ_EX = 1U,
    PS_FATFS_STORAGE_OP_READ_PREFIX = 2U,
    PS_FATFS_STORAGE_OP_WRITE = 3U,
    PS_FATFS_STORAGE_OP_DELETE = 4U,
    PS_FATFS_STORAGE_OP_ENSURE_DIR = 5U,
    PS_FATFS_STORAGE_OP_LIST_EX = 6U
} PsFatFsStorageOp;

typedef struct {
    char full_path[PS_APP_ROM_PATH_MAX_CHARS];
    u32 size_bytes;
    u8 is_dir;
} PsFatFsStorageCapturedEntry;

typedef struct PsFatFsStorageRequest {
    PsFatFsStorageOp op;
    char path[PS_FATFS_STORAGE_PATH_COPY_MAX];
    UINTPTR address;
    u32 byte_count;
    PsFatFsStorageReadChunkCallback read_callback;
    void *callback_ctx;
    PsFatFsStorageListEntryCallback list_callback;
    void *list_ctx;
    u8 deleted;
    PsFatFsStorageReadResult read_result;
    PsFatFsStorageWriteResult write_result;
    PsFatFsStorageListResult list_result;
    XStatus status;
    u8 in_use;
    SemaphoreHandle_t completed;
} PsFatFsStorageRequest;

static FATFS s_ps_fatfs_storage_fs;
static QueueHandle_t s_ps_fatfs_storage_queue;
static SemaphoreHandle_t s_ps_fatfs_storage_slots_lock;
static PsFatFsStorageRequest s_ps_fatfs_storage_requests[PS_FATFS_STORAGE_SLOT_COUNT];
static PsFatFsStorageCapturedEntry s_ps_fatfs_storage_list_entries[PS_FATFS_STORAGE_LIST_MAX_ENTRIES];
static u32 s_ps_fatfs_storage_list_count;
static SemaphoreHandle_t s_ps_fatfs_storage_list_lock;
static TaskHandle_t s_ps_fatfs_storage_owner;
static u8 s_ps_fatfs_list_cfg_logged;

static XStatus PsFatFsStorage_ReadFileToMemoryExImpl(const char *path,
                                                      UINTPTR dst_addr,
                                                      u32 capacity_bytes,
                                                      PsFatFsStorageReadResult *result_out,
                                                      PsFatFsStorageReadChunkCallback chunk_callback,
                                                      void *user_ctx);
static XStatus PsFatFsStorage_ReadFilePrefixImpl(const char *path,
                                                  UINTPTR dst_addr,
                                                  u32 max_bytes,
                                                  PsFatFsStorageReadResult *result_out);
static void PsFatFsStorage_YieldAfterWriteChunk(void);
static FRESULT PsFatFsStorage_Mount(void);
static FRESULT PsFatFsStorage_GetPathPresence(const char *path, u8 *exists_out);
static FRESULT PsFatFsStorage_UnlinkIfPresent(const char *path);
static FRESULT PsFatFsStorage_WriteReadyMarker(const char *path, u32 bytes, u32 crc32);
static FRESULT PsFatFsStorage_RecoverPath(const char *path);
static XStatus PsFatFsStorage_WriteMemoryToFileImpl(const char *path,
                                                     UINTPTR src_addr,
                                                     u32 bytes_to_write,
                                                     PsFatFsStorageWriteResult *result_out) {
    char temporary_path[PS_APP_ROM_PATH_MAX_CHARS];
    char backup_path[PS_APP_ROM_PATH_MAX_CHARS];
    char ready_path[PS_APP_ROM_PATH_MAX_CHARS];
    FIL file;
    FRESULT fs_result;
    FRESULT close_result;
    UINT bytes_written;
    const u8 *src_ptr;
    u32 offset;
    u32 chunk_index;
    u32 crc32;
    u8 primary_exists;
    u8 moved_primary;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->src_addr = src_addr;
        result_out->fs_result = FR_INVALID_PARAMETER;
    }
    if ((path == NULL) || (*path == '\0') || (bytes_to_write == 0U)) {
        return XST_INVALID_PARAM;
    }
    if (bytes_to_write > PS_APP_GBA_ROM_REGION_MAX_BYTES) {
        return XST_INVALID_PARAM;
    }
    if (PsFatFsTxn_BuildSidecarPaths(path,
                                    temporary_path,
                                    sizeof(temporary_path),
                                    backup_path,
                                    sizeof(backup_path),
                                    ready_path,
                                    sizeof(ready_path)) == 0) {
        if (result_out != NULL) result_out->fs_result = FR_INVALID_NAME;
        return XST_INVALID_PARAM;
    }

    status = XST_FAILURE;
    src_ptr = (const u8 *)src_addr;
    offset = 0U;
    chunk_index = 0U;
    moved_primary = 0U;
    memset(&file, 0, sizeof(file));
    PS_SAVEWR_LOG("[SAVEWR] transaction begin path=%s bytes=%u\r\n",
                  path,
                  (unsigned int)bytes_to_write);

    fs_result = PsFatFsStorage_Mount();
    if (fs_result != FR_OK) goto finish;
    fs_result = PsFatFsStorage_RecoverPath(path);
    if (fs_result != FR_OK) goto finish;
    fs_result = PsFatFsStorage_UnlinkIfPresent(temporary_path);
    if (fs_result != FR_OK) goto finish;
    fs_result = PsFatFsStorage_UnlinkIfPresent(backup_path);
    if (fs_result != FR_OK) goto finish;
    fs_result = PsFatFsStorage_UnlinkIfPresent(ready_path);
    if (fs_result != FR_OK) goto finish;

    fs_result = f_open(&file, temporary_path, FA_CREATE_ALWAYS | FA_WRITE);
    if (fs_result != FR_OK) goto finish;
    Xil_DCacheFlushRange((INTPTR)src_addr, bytes_to_write);
    while (offset < bytes_to_write) {
        u32 chunk_bytes = bytes_to_write - offset;
        if (chunk_bytes > PS_FATFS_STORAGE_WRITE_CHUNK_BYTES) {
            chunk_bytes = PS_FATFS_STORAGE_WRITE_CHUNK_BYTES;
        }
        bytes_written = 0U;
        fs_result = f_write(&file, &src_ptr[offset], chunk_bytes, &bytes_written);
        if ((fs_result != FR_OK) || (bytes_written != chunk_bytes)) {
            if (fs_result == FR_OK) fs_result = FR_DISK_ERR;
            break;
        }
        offset += bytes_written;
        chunk_index++;
        PsFatFsStorage_YieldAfterWriteChunk();
    }
    if (fs_result == FR_OK) {
        fs_result = f_sync(&file);
    }
    close_result = f_close(&file);
    if ((fs_result == FR_OK) && (close_result != FR_OK)) {
        fs_result = close_result;
    }
    if (fs_result != FR_OK) goto finish;

    crc32 = PsFatFsTxn_Crc32(src_ptr, bytes_to_write);
    fs_result = PsFatFsStorage_WriteReadyMarker(ready_path, bytes_to_write, crc32);
    if (fs_result != FR_OK) goto finish;

    fs_result = PsFatFsStorage_GetPathPresence(path, &primary_exists);
    if (fs_result != FR_OK) goto finish;
    if (primary_exists != 0U) {
        fs_result = f_rename(path, backup_path);
        if (fs_result != FR_OK) goto finish;
        moved_primary = 1U;
    }

    fs_result = f_rename(temporary_path, path);
    if (fs_result != FR_OK) {
        if (moved_primary != 0U) {
            FRESULT rollback_result = f_rename(backup_path, path);
            if (rollback_result != FR_OK) {
                xil_printf("[FATFS] save rollback pending path=%s rename=%s rollback=%s\r\n",
                           path,
                           PsFatFsStorage_StrError(fs_result),
                           PsFatFsStorage_StrError(rollback_result));
            }
        }
        goto finish;
    }

    /* The primary path now contains the complete raw file. Sidecar cleanup is
     * recoverable: a later read removes leftovers while keeping the primary. */
    (void)PsFatFsStorage_UnlinkIfPresent(ready_path);
    (void)PsFatFsStorage_UnlinkIfPresent(backup_path);
    if (result_out != NULL) {
        result_out->bytes_written = bytes_to_write;
        result_out->fs_result = FR_OK;
    }
    status = XST_SUCCESS;
    return status;

finish:
    if (result_out != NULL) result_out->fs_result = fs_result;
    PS_SAVEWR_LOG("[SAVEWR] transaction failed path=%s fs=%s bytes=%u chunks=%u\r\n",
                  path,
                  PsFatFsStorage_StrError(fs_result),
                  (unsigned int)offset,
                  (unsigned int)chunk_index);
    return status;
}

static XStatus PsFatFsStorage_DeleteFileIfExistsImpl(const char *path, u8 *deleted_out);
static XStatus PsFatFsStorage_EnsureDirectoryImpl(const char *path);
static XStatus PsFatFsStorage_ListDirectoryExImpl(const char *path,
                                                   PsFatFsStorageListEntryCallback callback,
                                                   void *user_ctx,
                                                   PsFatFsStorageListResult *result_out);

static void PsFatFsStorage_YieldAfterWriteChunk(void) {
    if (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) {
        taskYIELD();
    }
}

static FRESULT PsFatFsStorage_Mount(void) {
    return f_mount(&s_ps_fatfs_storage_fs, PS_FATFS_STORAGE_DRIVE_PATH, 0);
}

static FRESULT PsFatFsStorage_CloseFile(FIL *file, FRESULT prior_result) {
    FRESULT close_result;

    if (file == NULL) {
        return (prior_result == FR_OK) ? FR_INVALID_PARAMETER : prior_result;
    }
    close_result = f_close(file);
    return (prior_result == FR_OK) ? close_result : prior_result;
}

#define PS_FATFS_TXN_VERIFY_CHUNK_BYTES (8U * 1024U)
static u8 s_ps_fatfs_txn_verify_buffer[PS_FATFS_TXN_VERIFY_CHUNK_BYTES];

static FRESULT PsFatFsStorage_GetPathPresence(const char *path, u8 *exists_out) {
    FILINFO info;
    FRESULT fs_result;

    if ((path == NULL) || (exists_out == NULL)) {
        return FR_INVALID_PARAMETER;
    }
    *exists_out = 0U;
    memset(&info, 0, sizeof(info));
    fs_result = f_stat(path, &info);
    if (fs_result == FR_OK) {
        *exists_out = 1U;
        return FR_OK;
    }
    if ((fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH)) {
        return FR_OK;
    }
    return fs_result;
}

static FRESULT PsFatFsStorage_UnlinkIfPresent(const char *path) {
    FRESULT fs_result;

    fs_result = f_unlink(path);
    if ((fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH)) {
        return FR_OK;
    }
    return fs_result;
}

static FRESULT PsFatFsStorage_WriteReadyMarker(const char *path,
                                              u32 bytes,
                                              u32 crc32) {
    FIL marker_file;
    u8 marker[PS_FATFS_TXN_READY_MARKER_BYTES];
    UINT bytes_written;
    FRESULT fs_result;
    FRESULT close_result;

    PsFatFsTxn_MakeReadyMarker(bytes, crc32, marker);
    memset(&marker_file, 0, sizeof(marker_file));
    fs_result = f_open(&marker_file, path, FA_CREATE_ALWAYS | FA_WRITE);
    if (fs_result != FR_OK) {
        return fs_result;
    }
    bytes_written = 0U;
    fs_result = f_write(&marker_file, marker, sizeof(marker), &bytes_written);
    if ((fs_result == FR_OK) && (bytes_written != sizeof(marker))) {
        fs_result = FR_DISK_ERR;
    }
    if (fs_result == FR_OK) {
        fs_result = f_sync(&marker_file);
    }
    close_result = f_close(&marker_file);
    if ((fs_result == FR_OK) && (close_result != FR_OK)) {
        fs_result = close_result;
    }
    return fs_result;
}

static FRESULT PsFatFsStorage_ValidateReadyMarker(const char *temporary_path,
                                                  const char *ready_path,
                                                  u8 *valid_out) {
    FIL marker_file;
    FIL temporary_file;
    FILINFO marker_info;
    FILINFO temporary_info;
    u8 marker[PS_FATFS_TXN_READY_MARKER_BYTES];
    UINT bytes_read;
    FRESULT fs_result;
    FRESULT close_result;
    u32 expected_bytes;
    u32 expected_crc;
    u32 remaining;
    u32 crc_state;

    if ((temporary_path == NULL) || (ready_path == NULL) || (valid_out == NULL)) {
        return FR_INVALID_PARAMETER;
    }
    *valid_out = 0U;
    memset(&marker_info, 0, sizeof(marker_info));
    fs_result = f_stat(ready_path, &marker_info);
    if ((fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH)) return FR_OK;
    if (fs_result != FR_OK) return fs_result;
    if (marker_info.fsize != (FSIZE_t)PS_FATFS_TXN_READY_MARKER_BYTES) return FR_OK;

    memset(&marker_file, 0, sizeof(marker_file));
    fs_result = f_open(&marker_file, ready_path, FA_READ);
    if (fs_result != FR_OK) {
        return (fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH) ? FR_OK : fs_result;
    }
    bytes_read = 0U;
    fs_result = f_read(&marker_file, marker, sizeof(marker), &bytes_read);
    if ((fs_result == FR_OK) && (bytes_read != sizeof(marker))) {
        *valid_out = 0U;
    }
    close_result = f_close(&marker_file);
    if ((fs_result == FR_OK) && (close_result != FR_OK)) {
        fs_result = close_result;
    }
    if (fs_result != FR_OK) {
        return fs_result;
    }
    if ((bytes_read != sizeof(marker)) ||
        (PsFatFsTxn_CheckReadyMarker(marker, &expected_bytes, &expected_crc) == 0)) {
        return FR_OK;
    }

    memset(&temporary_info, 0, sizeof(temporary_info));
    fs_result = f_stat(temporary_path, &temporary_info);
    if ((fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH)) {
        return FR_OK;
    }
    if (fs_result != FR_OK) {
        return fs_result;
    }
    if (temporary_info.fsize != (FSIZE_t)expected_bytes) {
        return FR_OK;
    }

    memset(&temporary_file, 0, sizeof(temporary_file));
    fs_result = f_open(&temporary_file, temporary_path, FA_READ);
    if (fs_result != FR_OK) {
        return fs_result;
    }
    remaining = expected_bytes;
    crc_state = PsFatFsTxn_Crc32Begin();
    while (remaining > 0U) {
        u32 chunk_bytes = (remaining > sizeof(s_ps_fatfs_txn_verify_buffer)) ?
                          (u32)sizeof(s_ps_fatfs_txn_verify_buffer) : remaining;
        bytes_read = 0U;
        fs_result = f_read(&temporary_file,
                           s_ps_fatfs_txn_verify_buffer,
                           chunk_bytes,
                           &bytes_read);
        if ((fs_result != FR_OK) || (bytes_read != chunk_bytes)) {
            if (fs_result == FR_OK) {
                fs_result = FR_DISK_ERR;
            }
            break;
        }
        crc_state = PsFatFsTxn_Crc32Update(crc_state,
                                           s_ps_fatfs_txn_verify_buffer,
                                           bytes_read);
        remaining -= bytes_read;
    }
    close_result = f_close(&temporary_file);
    if ((fs_result == FR_OK) && (close_result != FR_OK)) {
        fs_result = close_result;
    }
    if (fs_result != FR_OK) {
        return fs_result;
    }
    if (PsFatFsTxn_Crc32Finish(crc_state) == expected_crc) {
        *valid_out = 1U;
    }
    return FR_OK;
}

static FRESULT PsFatFsStorage_RecoverPath(const char *path) {
    char temporary_path[PS_APP_ROM_PATH_MAX_CHARS];
    char backup_path[PS_APP_ROM_PATH_MAX_CHARS];
    char ready_path[PS_APP_ROM_PATH_MAX_CHARS];
    u8 primary_exists;
    u8 temporary_exists;
    u8 backup_exists;
    u8 ready_exists;
    u8 ready_valid;
    FRESULT fs_result;
    PsFatFsTxnRecoveryAction action;

    if (PsFatFsTxn_BuildSidecarPaths(path,
                                    temporary_path,
                                    sizeof(temporary_path),
                                    backup_path,
                                    sizeof(backup_path),
                                    ready_path,
                                    sizeof(ready_path)) == 0) {
        return FR_INVALID_NAME;
    }
    fs_result = PsFatFsStorage_GetPathPresence(path, &primary_exists);
    if (fs_result != FR_OK) return fs_result;
    fs_result = PsFatFsStorage_GetPathPresence(temporary_path, &temporary_exists);
    if (fs_result != FR_OK) return fs_result;
    fs_result = PsFatFsStorage_GetPathPresence(backup_path, &backup_exists);
    if (fs_result != FR_OK) return fs_result;
    fs_result = PsFatFsStorage_GetPathPresence(ready_path, &ready_exists);
    if (fs_result != FR_OK) return fs_result;

    ready_valid = 0U;
    if ((ready_exists != 0U) && (temporary_exists != 0U)) {
        fs_result = PsFatFsStorage_ValidateReadyMarker(temporary_path,
                                                       ready_path,
                                                       &ready_valid);
        if (fs_result != FR_OK) return fs_result;
    }
    action = PsFatFsTxn_SelectRecoveryAction(primary_exists,
                                             temporary_exists,
                                             backup_exists,
                                             (ready_exists == 0U) ? 0 :
                                             ((ready_valid != 0U) ? 1 : 2));
    switch (action) {
        case PS_FATFS_TXN_RECOVER_CLEAN_SIDECARS:
            fs_result = PsFatFsStorage_UnlinkIfPresent(temporary_path);
            if (fs_result == FR_OK) fs_result = PsFatFsStorage_UnlinkIfPresent(backup_path);
            if (fs_result == FR_OK) fs_result = PsFatFsStorage_UnlinkIfPresent(ready_path);
            return fs_result;
        case PS_FATFS_TXN_RECOVER_RESTORE_BACKUP:
            fs_result = f_rename(backup_path, path);
            if (fs_result != FR_OK) return fs_result;
            fs_result = PsFatFsStorage_UnlinkIfPresent(temporary_path);
            if (fs_result == FR_OK) fs_result = PsFatFsStorage_UnlinkIfPresent(ready_path);
            return fs_result;
        case PS_FATFS_TXN_RECOVER_PROMOTE_TEMP:
            fs_result = f_rename(temporary_path, path);
            if (fs_result != FR_OK) return fs_result;
            return PsFatFsStorage_UnlinkIfPresent(ready_path);
        case PS_FATFS_TXN_RECOVER_DISCARD_TEMP:
            fs_result = PsFatFsStorage_UnlinkIfPresent(temporary_path);
            if (fs_result == FR_OK) fs_result = PsFatFsStorage_UnlinkIfPresent(ready_path);
            return fs_result;
        case PS_FATFS_TXN_RECOVER_NONE:
        default:
            return FR_OK;
    }
}

static XStatus PsFatFsStorage_CopyPath(char *dst, size_t dst_size, const char *src) {
    size_t length;

    if ((dst == NULL) || (dst_size == 0U) || (src == NULL) || (*src == '\0')) {
        return XST_INVALID_PARAM;
    }
    length = strlen(src);
    if (length >= dst_size) {
        return XST_INVALID_PARAM;
    }
    memcpy(dst, src, length + 1U);
    return XST_SUCCESS;
}

static PsFatFsStorageRequest *PsFatFsStorage_AcquireRequest(void) {
    TickType_t wait_ticks;
    u32 idx;
    PsFatFsStorageRequest *request;

    if ((s_ps_fatfs_storage_queue == NULL) ||
        (s_ps_fatfs_storage_slots_lock == NULL)) {
        return NULL;
    }
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_STORAGE_QUEUE_WAIT_MS);
    if (xSemaphoreTake(s_ps_fatfs_storage_slots_lock, wait_ticks) != pdTRUE) {
        return NULL;
    }
    request = NULL;
    for (idx = 0U; idx < PS_FATFS_STORAGE_SLOT_COUNT; ++idx) {
        if (s_ps_fatfs_storage_requests[idx].in_use == 0U) {
            request = &s_ps_fatfs_storage_requests[idx];
            request->in_use = 1U;
            break;
        }
    }
    (void)xSemaphoreGive(s_ps_fatfs_storage_slots_lock);
    if (request != NULL) {
        (void)xSemaphoreTake(request->completed, 0U);
        memset(&request->read_result, 0, sizeof(request->read_result));
        memset(&request->write_result, 0, sizeof(request->write_result));
        memset(&request->list_result, 0, sizeof(request->list_result));
        request->status = XST_FAILURE;
    }
    return request;
}

static void PsFatFsStorage_ReleaseRequest(PsFatFsStorageRequest *request) {
    if ((request == NULL) || (s_ps_fatfs_storage_slots_lock == NULL)) {
        return;
    }
    if (xSemaphoreTake(s_ps_fatfs_storage_slots_lock, portMAX_DELAY) == pdTRUE) {
        request->in_use = 0U;
        (void)xSemaphoreGive(s_ps_fatfs_storage_slots_lock);
    }
}

static XStatus PsFatFsStorage_Submit(PsFatFsStorageRequest *request) {
    TickType_t wait_ticks;

    if ((request == NULL) || (s_ps_fatfs_storage_queue == NULL)) {
        return XST_FAILURE;
    }
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_STORAGE_QUEUE_WAIT_MS);
    if (xQueueSend(s_ps_fatfs_storage_queue, &request, wait_ticks) != pdTRUE) {
        return XST_FAILURE;
    }
    /* A queued request keeps pointers into the caller's buffers and callback
     * context alive. Each operation is bounded by its byte/path limits; the
     * submitter waits for completion before those pointers can go out of scope. */
    (void)xSemaphoreTake(request->completed, portMAX_DELAY);
    return request->status;
}

static u8 PsFatFsStorage_CaptureListEntry(const char *name,
                                            const char *full_path,
                                            u8 is_dir,
                                            u32 size_bytes,
                                            void *user_ctx) {
    PsFatFsStorageCapturedEntry *entry;
    size_t path_len;

    (void)name;
    (void)user_ctx;
    if ((full_path == NULL) ||
        (s_ps_fatfs_storage_list_count >= PS_FATFS_STORAGE_LIST_MAX_ENTRIES)) {
        return 0U;
    }
    path_len = strlen(full_path);
    if (path_len >= sizeof(s_ps_fatfs_storage_list_entries[0].full_path)) {
        return 1U;
    }
    entry = &s_ps_fatfs_storage_list_entries[s_ps_fatfs_storage_list_count++];
    memcpy(entry->full_path, full_path, path_len + 1U);
    entry->is_dir = is_dir;
    entry->size_bytes = size_bytes;
    return (s_ps_fatfs_storage_list_count < PS_FATFS_STORAGE_LIST_MAX_ENTRIES) ? 1U : 0U;
}

static XStatus PsFatFsStorage_Execute(PsFatFsStorageRequest *request) {
    if (request == NULL) {
        return XST_INVALID_PARAM;
    }
    switch (request->op) {
        case PS_FATFS_STORAGE_OP_READ_EX:
            request->status = PsFatFsStorage_ReadFileToMemoryExImpl(request->path,
                                                                     request->address,
                                                                     request->byte_count,
                                                                     &request->read_result,
                                                                     request->read_callback,
                                                                     request->callback_ctx);
            break;
        case PS_FATFS_STORAGE_OP_READ_PREFIX:
            request->status = PsFatFsStorage_ReadFilePrefixImpl(request->path,
                                                                 request->address,
                                                                 request->byte_count,
                                                                 &request->read_result);
            break;
        case PS_FATFS_STORAGE_OP_WRITE:
            request->status = PsFatFsStorage_WriteMemoryToFileImpl(request->path,
                                                                    request->address,
                                                                    request->byte_count,
                                                                    &request->write_result);
            break;
        case PS_FATFS_STORAGE_OP_DELETE:
            request->deleted = 0U;
            request->status = PsFatFsStorage_DeleteFileIfExistsImpl(request->path, &request->deleted);
            break;
        case PS_FATFS_STORAGE_OP_ENSURE_DIR:
            request->status = PsFatFsStorage_EnsureDirectoryImpl(request->path);
            break;
        case PS_FATFS_STORAGE_OP_LIST_EX:
            s_ps_fatfs_storage_list_count = 0U;
            request->status = PsFatFsStorage_ListDirectoryExImpl(request->path,
                                                                  PsFatFsStorage_CaptureListEntry,
                                                                  NULL,
                                                                  &request->list_result);
            break;
        default:
            request->status = XST_INVALID_PARAM;
            break;
    }
    (void)xSemaphoreGive(request->completed);
    return request->status;
}

static void PsFatFsStorage_CleanupInit(void) {
    u32 idx;
    for (idx = 0U; idx < PS_FATFS_STORAGE_SLOT_COUNT; ++idx) {
        if (s_ps_fatfs_storage_requests[idx].completed != NULL) {
            (void)vSemaphoreDelete(s_ps_fatfs_storage_requests[idx].completed);
            s_ps_fatfs_storage_requests[idx].completed = NULL;
        }
    }
    if (s_ps_fatfs_storage_list_lock != NULL) {
        (void)vSemaphoreDelete(s_ps_fatfs_storage_list_lock);
        s_ps_fatfs_storage_list_lock = NULL;
    }
    if (s_ps_fatfs_storage_slots_lock != NULL) {
        (void)vSemaphoreDelete(s_ps_fatfs_storage_slots_lock);
        s_ps_fatfs_storage_slots_lock = NULL;
    }
    if (s_ps_fatfs_storage_queue != NULL) {
        vQueueDelete(s_ps_fatfs_storage_queue);
        s_ps_fatfs_storage_queue = NULL;
    }
    s_ps_fatfs_storage_owner = NULL;
}

XStatus PsFatFsStorage_Init(void) {
    BaseType_t task_status;
    u32 idx;

    if (s_ps_fatfs_storage_queue != NULL) {
        return XST_SUCCESS;
    }
    if (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) {
        return XST_FAILURE;
    }

    s_ps_fatfs_storage_queue = xQueueCreate(PS_APP_STORAGE_QUEUE_DEPTH,
                                             sizeof(PsFatFsStorageRequest *));
    s_ps_fatfs_storage_slots_lock = xSemaphoreCreateMutex();
    s_ps_fatfs_storage_list_lock = xSemaphoreCreateMutex();
    if ((s_ps_fatfs_storage_queue == NULL) ||
        (s_ps_fatfs_storage_slots_lock == NULL) ||
        (s_ps_fatfs_storage_list_lock == NULL)) {
        PsFatFsStorage_CleanupInit();
        return XST_FAILURE;
    }
    for (idx = 0U; idx < PS_FATFS_STORAGE_SLOT_COUNT; ++idx) {
        s_ps_fatfs_storage_requests[idx].completed = xSemaphoreCreateBinary();
        if (s_ps_fatfs_storage_requests[idx].completed == NULL) {
            PsFatFsStorage_CleanupInit();
            return XST_FAILURE;
        }
        s_ps_fatfs_storage_requests[idx].in_use = 0U;
    }

    task_status = xTaskCreate(PsFatFsStorage_Task,
                              "store",
                              PS_APP_STORAGE_TASK_STACK_WORDS,
                              NULL,
                              PS_APP_STORAGE_TASK_PRIORITY,
                              &s_ps_fatfs_storage_owner);
    if (task_status != pdPASS) {
        PsFatFsStorage_CleanupInit();
        return XST_FAILURE;
    }
    return XST_SUCCESS;
}

void PsFatFsStorage_Task(void *arg) {
    PsFatFsStorageRequest *request;

    (void)arg;
    s_ps_fatfs_storage_owner = xTaskGetCurrentTaskHandle();
    for (;;) {
        if (xQueueReceive(s_ps_fatfs_storage_queue,
                          &request,
                          portMAX_DELAY) == pdTRUE) {
            (void)PsFatFsStorage_Execute(request);
        }
    }
}

static XStatus PsFatFsStorage_RunOrSubmit(PsFatFsStorageRequest *request) {
    if (xTaskGetSchedulerState() != taskSCHEDULER_RUNNING) {
        return PsFatFsStorage_Execute(request);
    }
    if (xTaskGetCurrentTaskHandle() == s_ps_fatfs_storage_owner) {
        return PsFatFsStorage_Execute(request);
    }
    return PsFatFsStorage_Submit(request);
}

XStatus PsFatFsStorage_ReadFileToMemoryEx(const char *path,
                                         UINTPTR dst_addr,
                                         u32 capacity_bytes,
                                         PsFatFsStorageReadResult *result_out,
                                         PsFatFsStorageReadChunkCallback chunk_callback,
                                         void *user_ctx) {
    PsFatFsStorageRequest *request;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->dst_addr = dst_addr;
    }
    if ((capacity_bytes == 0U) ||
        (capacity_bytes > PS_APP_GBA_ROM_REGION_MAX_BYTES) ||
        (path == NULL) || (*path == '\0') ||
        (strlen(path) >= PS_APP_ROM_PATH_MAX_CHARS)) {
        if (result_out != NULL) result_out->fs_result = FR_INVALID_PARAMETER;
        return XST_INVALID_PARAM;
    }
    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) {
        if (result_out != NULL) {
            result_out->fs_result = FR_TIMEOUT;
        }
        return XST_FAILURE;
    }
    request->op = PS_FATFS_STORAGE_OP_READ_EX;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    request->address = dst_addr;
    request->byte_count = capacity_bytes;
    request->read_callback = chunk_callback;
    request->callback_ctx = user_ctx;
    if (status == XST_SUCCESS) {
        status = PsFatFsStorage_RunOrSubmit(request);
    }
    if (result_out != NULL) {
        *result_out = request->read_result;
    }
    PsFatFsStorage_ReleaseRequest(request);
    return status;
}

XStatus PsFatFsStorage_ReadFileToMemory(const char *path,
                                       UINTPTR dst_addr,
                                       u32 capacity_bytes,
                                       PsFatFsStorageReadResult *result_out) {
    return PsFatFsStorage_ReadFileToMemoryEx(path,
                                             dst_addr,
                                             capacity_bytes,
                                             result_out,
                                             NULL,
                                             NULL);
}

XStatus PsFatFsStorage_ReadFilePrefix(const char *path,
                                      UINTPTR dst_addr,
                                      u32 max_bytes,
                                      PsFatFsStorageReadResult *result_out) {
    PsFatFsStorageRequest *request;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->dst_addr = dst_addr;
    }
    if ((max_bytes == 0U) ||
        (max_bytes > PS_APP_GBA_ROM_REGION_MAX_BYTES) ||
        (path == NULL) || (*path == '\0')) {
        return XST_INVALID_PARAM;
    }
    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) {
        if (result_out != NULL) result_out->fs_result = FR_TIMEOUT;
        return XST_FAILURE;
    }
    request->op = PS_FATFS_STORAGE_OP_READ_PREFIX;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    request->address = dst_addr;
    request->byte_count = max_bytes;
    if (status == XST_SUCCESS) status = PsFatFsStorage_RunOrSubmit(request);
    if (result_out != NULL) *result_out = request->read_result;
    PsFatFsStorage_ReleaseRequest(request);
    return status;
}

XStatus PsFatFsStorage_WriteMemoryToFile(const char *path,
                                        UINTPTR src_addr,
                                        u32 bytes_to_write,
                                        PsFatFsStorageWriteResult *result_out) {
    PsFatFsStorageRequest *request;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->src_addr = src_addr;
    }
    if ((bytes_to_write == 0U) || (path == NULL) || (*path == '\0')) {
        return XST_INVALID_PARAM;
    }
    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) {
        if (result_out != NULL) result_out->fs_result = FR_TIMEOUT;
        return XST_FAILURE;
    }
    request->op = PS_FATFS_STORAGE_OP_WRITE;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    request->address = src_addr;
    request->byte_count = bytes_to_write;
    if (status == XST_SUCCESS) status = PsFatFsStorage_RunOrSubmit(request);
    if (result_out != NULL) *result_out = request->write_result;
    PsFatFsStorage_ReleaseRequest(request);
    return status;
}

XStatus PsFatFsStorage_DeleteFileIfExists(const char *path, u8 *deleted_out) {
    PsFatFsStorageRequest *request;
    XStatus status;

    if (deleted_out != NULL) *deleted_out = 0U;
    if ((path == NULL) || (*path == '\0')) return XST_INVALID_PARAM;
    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) return XST_FAILURE;
    request->op = PS_FATFS_STORAGE_OP_DELETE;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    if (status == XST_SUCCESS) status = PsFatFsStorage_RunOrSubmit(request);
    if (deleted_out != NULL) *deleted_out = request->deleted;
    PsFatFsStorage_ReleaseRequest(request);
    return status;
}

XStatus PsFatFsStorage_EnsureDirectory(const char *path) {
    PsFatFsStorageRequest *request;
    XStatus status;

    if ((path == NULL) || (*path == '\0')) return XST_INVALID_PARAM;
    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) return XST_FAILURE;
    request->op = PS_FATFS_STORAGE_OP_ENSURE_DIR;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    if (status == XST_SUCCESS) status = PsFatFsStorage_RunOrSubmit(request);
    PsFatFsStorage_ReleaseRequest(request);
    return status;
}

XStatus PsFatFsStorage_ListDirectoryEx(const char *path,
                                     PsFatFsStorageListEntryCallback callback,
                                     void *user_ctx,
                                     PsFatFsStorageListResult *result_out) {
    PsFatFsStorageRequest *request;
    XStatus status;
    TickType_t wait_ticks;
    u32 idx;
    u32 entries_to_deliver;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->fs_result = FR_INVALID_PARAMETER;
    }
    if ((path == NULL) || (*path == '\0')) return XST_INVALID_PARAM;

    if ((xTaskGetSchedulerState() != taskSCHEDULER_RUNNING) ||
        (xTaskGetCurrentTaskHandle() == s_ps_fatfs_storage_owner)) {
        return PsFatFsStorage_ListDirectoryExImpl(path, callback, user_ctx, result_out);
    }
    if (s_ps_fatfs_storage_list_lock == NULL) return XST_FAILURE;
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_STORAGE_QUEUE_WAIT_MS);
    if (xSemaphoreTake(s_ps_fatfs_storage_list_lock, wait_ticks) != pdTRUE) {
        if (result_out != NULL) result_out->fs_result = FR_TIMEOUT;
        return XST_FAILURE;
    }

    request = PsFatFsStorage_AcquireRequest();
    if (request == NULL) {
        (void)xSemaphoreGive(s_ps_fatfs_storage_list_lock);
        if (result_out != NULL) result_out->fs_result = FR_TIMEOUT;
        return XST_FAILURE;
    }
    request->op = PS_FATFS_STORAGE_OP_LIST_EX;
    status = PsFatFsStorage_CopyPath(request->path, sizeof(request->path), path);
    request->list_callback = callback;
    request->list_ctx = user_ctx;
    if (status == XST_SUCCESS) status = PsFatFsStorage_Submit(request);
    if (result_out != NULL) *result_out = request->list_result;

    entries_to_deliver = request->list_result.entries_visited;
    if (entries_to_deliver > s_ps_fatfs_storage_list_count) {
        entries_to_deliver = s_ps_fatfs_storage_list_count;
    }
    if (callback != NULL) {
        u32 callbacks_delivered = 0U;
        u8 callback_stopped = 0U;
        for (idx = 0U; idx < entries_to_deliver; ++idx) {
            const PsFatFsStorageCapturedEntry *entry = &s_ps_fatfs_storage_list_entries[idx];
            const char *name = entry->full_path;
            const char *slash = strrchr(entry->full_path, '/');
            const char *backslash = strrchr(entry->full_path, '\\');
            if ((backslash != NULL) && ((slash == NULL) || (backslash > slash))) {
                slash = backslash;
            }
            if (slash != NULL) name = slash + 1;
            callbacks_delivered++;
            if (callback(name,
                         entry->full_path,
                         entry->is_dir,
                         entry->size_bytes,
                         user_ctx) == 0U) {
                callback_stopped = 1U;
                break;
            }
        }
        if ((callback_stopped != 0U) && (result_out != NULL)) {
            result_out->entries_visited = callbacks_delivered;
        }
    }
    PsFatFsStorage_ReleaseRequest(request);
    (void)xSemaphoreGive(s_ps_fatfs_storage_list_lock);
    return status;
}

const char *PsFatFsStorage_StrError(FRESULT result) {
    switch (result) {
        case FR_OK: return "ok";
        case FR_DISK_ERR: return "disk_err";
        case FR_INT_ERR: return "int_err";
        case FR_NOT_READY: return "not_ready";
        case FR_NO_FILE: return "no_file";
        case FR_NO_PATH: return "no_path";
        case FR_INVALID_NAME: return "invalid_name";
        case FR_DENIED: return "denied";
        case FR_EXIST: return "exist";
        case FR_INVALID_OBJECT: return "invalid_object";
        case FR_WRITE_PROTECTED: return "write_protected";
        case FR_INVALID_DRIVE: return "invalid_drive";
        case FR_NOT_ENABLED: return "not_enabled";
        case FR_NO_FILESYSTEM: return "no_filesystem";
        case FR_MKFS_ABORTED: return "mkfs_aborted";
        case FR_TIMEOUT: return "timeout";
        case FR_LOCKED: return "locked";
        case FR_NOT_ENOUGH_CORE: return "no_core";
        case FR_TOO_MANY_OPEN_FILES: return "too_many_open";
        case FR_INVALID_PARAMETER: return "invalid_param";
        default: return "unknown";
    }
}

static XStatus PsFatFsStorage_ReadFileToMemoryExImpl(const char *path,
                                         UINTPTR dst_addr,
                                         u32 capacity_bytes,
                                         PsFatFsStorageReadResult *result_out,
                                         PsFatFsStorageReadChunkCallback chunk_callback,
                                         void *user_ctx) {
    FIL file;
    FRESULT fs_result;
    FSIZE_t file_size;
    UINT bytes_read;
    u8 *dst_ptr;
    u32 offset;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->dst_addr = dst_addr;
    }

    if ((path == NULL) || (*path == '\0') || (capacity_bytes == 0U)) {
        return XST_INVALID_PARAM;
    }

    status = XST_FAILURE;
    dst_ptr = (u8 *)dst_addr;
    offset = 0U;
    memset(&file, 0, sizeof(file));

    fs_result = PsFatFsStorage_Mount();
    if (fs_result == FR_OK) {
        fs_result = PsFatFsStorage_RecoverPath(path);
    }
    if (result_out != NULL) {
        result_out->fs_result = fs_result;
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    fs_result = f_open(&file, path, FA_READ);
    if (result_out != NULL) {
        result_out->fs_result = fs_result;
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    file_size = f_size(&file);
    if ((file_size == 0U) || (file_size > (FSIZE_t)capacity_bytes)) {
        fs_result = PsFatFsStorage_CloseFile(&file, FR_INVALID_PARAMETER);
        if (result_out != NULL) result_out->fs_result = fs_result;
        goto cleanup;
    }

    while (offset < (u32)file_size) {
        u32 chunk_bytes;

        chunk_bytes = (u32)file_size - offset;
        if (chunk_bytes > PS_FATFS_STORAGE_READ_CHUNK_BYTES) {
            chunk_bytes = PS_FATFS_STORAGE_READ_CHUNK_BYTES;
        }

        bytes_read = 0U;
        fs_result = f_read(&file, &dst_ptr[offset], chunk_bytes, &bytes_read);
        if (result_out != NULL) {
            result_out->fs_result = fs_result;
        }
        if ((fs_result != FR_OK) || (bytes_read != chunk_bytes)) {
            if (fs_result == FR_OK) fs_result = FR_DISK_ERR;
            fs_result = PsFatFsStorage_CloseFile(&file, fs_result);
            if (result_out != NULL) result_out->fs_result = fs_result;
            goto cleanup;
        }

        Xil_DCacheFlushRange((INTPTR)&dst_ptr[offset], bytes_read);
        if (chunk_callback != NULL) {
            chunk_callback(&dst_ptr[offset], offset, bytes_read, user_ctx);
        }
        offset += bytes_read;
    }

    fs_result = PsFatFsStorage_CloseFile(&file, FR_OK);
    if (result_out != NULL) result_out->fs_result = fs_result;
    if (fs_result != FR_OK) goto cleanup;

    if (result_out != NULL) {
        result_out->bytes_loaded = (u32)file_size;
        result_out->fs_result = FR_OK;
    }
    status = XST_SUCCESS;

cleanup:
    return status;
}

static XStatus PsFatFsStorage_ReadFilePrefixImpl(const char *path,
                                      UINTPTR dst_addr,
                                      u32 max_bytes,
                                      PsFatFsStorageReadResult *result_out) {
    FIL file;
    FRESULT fs_result;
    FSIZE_t file_size;
    UINT bytes_read;
    u32 read_bytes;
    XStatus status;

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->dst_addr = dst_addr;
    }

    if ((path == NULL) || (*path == '\0') || (max_bytes == 0U)) {
        return XST_INVALID_PARAM;
    }

    status = XST_FAILURE;
    memset(&file, 0, sizeof(file));

    fs_result = PsFatFsStorage_Mount();
    if (fs_result == FR_OK) {
        fs_result = PsFatFsStorage_RecoverPath(path);
    }
    if (result_out != NULL) {
        result_out->fs_result = fs_result;
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    fs_result = f_open(&file, path, FA_READ);
    if (result_out != NULL) {
        result_out->fs_result = fs_result;
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    file_size = f_size(&file);
    read_bytes = (file_size < (FSIZE_t)max_bytes) ? (u32)file_size : max_bytes;
    if (read_bytes == 0U) {
        fs_result = PsFatFsStorage_CloseFile(&file, FR_INVALID_PARAMETER);
        if (result_out != NULL) result_out->fs_result = fs_result;
        goto cleanup;
    }

    bytes_read = 0U;
    fs_result = f_read(&file, (void *)dst_addr, read_bytes, &bytes_read);
    if ((fs_result == FR_OK) && (bytes_read != read_bytes)) {
        fs_result = FR_DISK_ERR;
    }
    fs_result = PsFatFsStorage_CloseFile(&file, fs_result);
    if (result_out != NULL) result_out->fs_result = fs_result;
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    Xil_DCacheFlushRange((INTPTR)dst_addr, bytes_read);
    if (result_out != NULL) {
        result_out->bytes_loaded = bytes_read;
        result_out->fs_result = FR_OK;
    }
    status = XST_SUCCESS;

cleanup:
    return status;
}


static XStatus PsFatFsStorage_DeleteFileIfExistsImpl(const char *path, u8 *deleted_out) {
    FRESULT fs_result;
    XStatus status;

    if (deleted_out != NULL) {
        *deleted_out = 0U;
    }
    if ((path == NULL) || (*path == '\0')) {
        return XST_INVALID_PARAM;
    }

    status = XST_FAILURE;
    fs_result = PsFatFsStorage_Mount();
    if (fs_result == FR_OK) {
        fs_result = PsFatFsStorage_RecoverPath(path);
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    /* 刻意不做 f_stat 预检查：
     * 1) f_unlink 本身就能给出“文件不存在/路径不存在”的结果；
     * 2) 少一次 FatFs API 交互，缩短临界区；
     * 3) 历史上在高压并发路径里，f_stat 额外分支更容易放大异常。 */
    fs_result = f_unlink(path);
    if ((fs_result == FR_NO_FILE) || (fs_result == FR_NO_PATH)) {
        status = XST_SUCCESS;
        goto cleanup;
    }
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    if (deleted_out != NULL) {
        *deleted_out = 1U;
    }
    status = XST_SUCCESS;

cleanup:
    return status;
}

static XStatus PsFatFsStorage_EnsureDirectoryImpl(const char *path) {
    DIR dir;
    FRESULT fs_result;
    XStatus status;

    if ((path == NULL) || (*path == '\0')) {
        return XST_INVALID_PARAM;
    }

    status = XST_FAILURE;

    fs_result = PsFatFsStorage_Mount();
    if (fs_result != FR_OK) {
        goto cleanup;
    }

    /* 目录存在性同样不走 f_stat：
     * 直接 f_opendir 检查最简路径，必要时再 mkdir。 */
    memset(&dir, 0, sizeof(dir));
    fs_result = f_opendir(&dir, path);
    if (fs_result == FR_OK) {
        fs_result = f_closedir(&dir);
        status = (fs_result == FR_OK) ? XST_SUCCESS : XST_FAILURE;
        goto cleanup;
    }
    if ((fs_result != FR_NO_FILE) && (fs_result != FR_NO_PATH)) {
        goto cleanup;
    }

    fs_result = f_mkdir(path);
    if ((fs_result == FR_OK) || (fs_result == FR_EXIST)) {
        status = XST_SUCCESS;
        goto cleanup;
    }

cleanup:
    return status;
}

XStatus PsFatFsStorage_ListDirectory(const char *path,
                                     PsFatFsStorageListEntryCallback callback,
                                     void *user_ctx) {
    return PsFatFsStorage_ListDirectoryEx(path, callback, user_ctx, NULL);
}

static XStatus PsFatFsStorage_ListDirectoryExImpl(const char *path,
                                       PsFatFsStorageListEntryCallback callback,
                                       void *user_ctx,
                                       PsFatFsStorageListResult *result_out) {
    DIR dir;
    FILINFO info;
    FRESULT fs_result;
    XStatus status;
    size_t base_len;
    u8 need_separator;
    u32 visited_count;
    u32 skipped_long_count;
    u8 scan_attempt;
    u8 did_retry_after_empty;
    u8 did_media_reinit_after_empty;
    DSTATUS disk_status;
    int if_sd;
    int if_ram;

    if ((path == NULL) || (*path == '\0')) {
        return XST_INVALID_PARAM;
    }

    if (result_out != NULL) {
        memset(result_out, 0, sizeof(*result_out));
        result_out->fs_result = FR_INVALID_PARAMETER;
    }

    status = XST_FAILURE;
    fs_result = FR_OK;
    visited_count = 0U;
    skipped_long_count = 0U;
    scan_attempt = 0U;
    did_retry_after_empty = 0U;
    did_media_reinit_after_empty = 0U;
    disk_status = 0U;
    if_sd = 0;
    if_ram = 0;

#ifdef FILE_SYSTEM_INTERFACE_SD
    if_sd = 1;
#endif
#ifdef FILE_SYSTEM_INTERFACE_RAM
    if_ram = 1;
#endif

    if (s_ps_fatfs_list_cfg_logged == 0U) {
        s_ps_fatfs_list_cfg_logged = 1U;
        /* 启动后首次扫描打印一次 FatFs 关键配置，便于现场定位：
         * - lfn: 是否启用长文件名
         * - cp:  代码页
         * - unicode: 2 表示路径 API 为 UTF-8，中文 ROM 名可原样传递
         * - if_sd/if_ram: 当前启用的底层介质接口
         * - FILINFO/DIR 大小：可快速判断编译配置是否一致 */
        xil_printf("[FATFS] list cfg lfn=%d unicode=%d cp=%d if_sd=%d if_ram=%d filinfo=%u dir=%u\r\n",
                   (int)FF_USE_LFN,
                   (int)FF_LFN_UNICODE,
                   (int)FF_CODE_PAGE,
                   if_sd,
                   if_ram,
                   (unsigned int)sizeof(FILINFO),
                   (unsigned int)sizeof(DIR));
    }

    base_len = strlen(path);
    need_separator = (u8)((base_len > 0U) &&
                          (path[base_len - 1U] != '/') &&
                          (path[base_len - 1U] != '\\') ? 1U : 0U);

    for (scan_attempt = 0U; scan_attempt < 3U; ++scan_attempt) {
        visited_count = 0U;
        skipped_long_count = 0U;

        fs_result = PsFatFsStorage_Mount();
        if (result_out != NULL) {
            result_out->fs_result = fs_result;
        }
        if (fs_result != FR_OK) {
            status = XST_FAILURE;
            break;
        }

        memset(&dir, 0, sizeof(dir));
        fs_result = f_opendir(&dir, path);
        if (result_out != NULL) {
            result_out->fs_result = fs_result;
        }
        if (fs_result != FR_OK) {
            status = XST_FAILURE;
            break;
        }

        for (;;) {
            char full_path[PS_APP_ROM_PATH_MAX_CHARS];
            size_t name_len;
            size_t full_len;
            u8 is_dir;

            memset(&info, 0, sizeof(info));
            fs_result = f_readdir(&dir, &info);
            if (result_out != NULL) {
                result_out->fs_result = fs_result;
            }
            if (fs_result != FR_OK) {
                if (visited_count > 0U) {
                    /* 这里最常见的是 FR_INVALID_OBJECT：
                     * 说明目录对象在遍历过程中失效（例如底层状态变化）。
                     * 日志保留“已读取条目数”，方便区分“全失败”还是“中途失败”。 */
                    xil_printf("[FATFS] list warn: %s (%u entries kept)\r\n",
                               PsFatFsStorage_StrError(fs_result),
                               (unsigned int)visited_count);
                }
                /* 返回失败让上层感知“扫描不完整”，由 UI 决定显示“部分可用”。 */
                status = XST_FAILURE;
                break;
            }

            if (info.fname[0] == '\0') {
                if (result_out != NULL) {
                    result_out->fs_result = FR_OK;
                }
                status = XST_SUCCESS;
                break;
            }

            /* 跳过伪目录项。 */
            if ((strcmp(info.fname, ".") == 0) || (strcmp(info.fname, "..") == 0)) {
                continue;
            }
            visited_count++;

            name_len = strlen(info.fname);
            full_len = base_len + (size_t)need_separator + name_len;
            /* 超过缓冲上限则跳过该项，避免把 UTF-8 路径截断后交给上层加载。 */
            if (full_len >= sizeof(full_path)) {
                skipped_long_count++;
                continue;
            }

            memcpy(full_path, path, base_len);
            if (need_separator != 0U) {
                full_path[base_len] = '/';
                memcpy(&full_path[base_len + 1U], info.fname, name_len);
                full_path[base_len + 1U + name_len] = '\0';
            } else {
                memcpy(&full_path[base_len], info.fname, name_len);
                full_path[base_len + name_len] = '\0';
            }

            is_dir = (u8)(((info.fattrib & AM_DIR) != 0U) ? 1U : 0U);
            if (callback != NULL) {
                /* 回调返回 0 表示上层主动停止遍历（如达到上限）。 */
                if (callback(info.fname, full_path, is_dir, (u32)info.fsize, user_ctx) == 0U) {
                    status = XST_SUCCESS;
                    break;
                }
            }
        }

        {
            FRESULT close_result = f_closedir(&dir);
            if ((status == XST_SUCCESS) && (close_result != FR_OK)) {
                status = XST_FAILURE;
                if (result_out != NULL) result_out->fs_result = close_result;
            }
        }
        if (status != XST_SUCCESS) {
            break;
        }

        if ((visited_count > 0U) || (scan_attempt > 1U)) {
            break;
        }

        if (scan_attempt == 0U) {
            did_retry_after_empty = 1U;
            xil_printf("[FATFS] list retry-after-empty path=%s\r\n", path);
        } else {
            did_media_reinit_after_empty = 1U;
            disk_status = disk_initialize(0);
            xil_printf("[FATFS] list media-reinit path=%s ds=0x%02X\r\n",
                       path,
                       (unsigned int)disk_status);
            if ((disk_status & STA_NOINIT) != 0U) {
                status = XST_FAILURE;
                if (result_out != NULL) {
                    result_out->fs_result = FR_NOT_READY;
                }
                break;
            }
        }

        (void)f_mount(NULL, PS_FATFS_STORAGE_DRIVE_PATH, 0);
        fs_result = f_mount(&s_ps_fatfs_storage_fs, PS_FATFS_STORAGE_DRIVE_PATH, 1);
        if (result_out != NULL) {
            result_out->fs_result = fs_result;
        }
        if (fs_result != FR_OK) {
            status = XST_FAILURE;
            break;
        }
    }

    if ((did_media_reinit_after_empty != 0U) && (status == XST_SUCCESS) && (visited_count > 0U)) {
        xil_printf("[FATFS] list recovered after media-reinit path=%s entries=%u\r\n",
                   path,
                   (unsigned int)visited_count);
    } else if ((did_retry_after_empty != 0U) && (status == XST_SUCCESS) && (visited_count > 0U)) {
        xil_printf("[FATFS] list recovered after retry path=%s entries=%u\r\n",
                   path,
                   (unsigned int)visited_count);
    }
    if ((status == XST_SUCCESS) && (visited_count == 0U)) {
        xil_printf("[FATFS] list empty path=%s\r\n", path);
    }
    if (skipped_long_count > 0U) {
        xil_printf("[FATFS] list skipped %u path(s) over %u bytes\r\n",
                   (unsigned int)skipped_long_count,
                   (unsigned int)PS_APP_ROM_PATH_MAX_CHARS);
    }

    if (result_out != NULL) {
        result_out->entries_visited = visited_count;
        result_out->entries_skipped_long = skipped_long_count;
        if ((status == XST_SUCCESS) && (result_out->fs_result != FR_OK)) {
            result_out->fs_result = FR_OK;
        }
    }
    return status;
}


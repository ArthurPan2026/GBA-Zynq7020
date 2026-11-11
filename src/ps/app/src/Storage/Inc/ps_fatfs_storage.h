#ifndef PS_FATFS_STORAGE_H
#define PS_FATFS_STORAGE_H

#include "ff.h"
#include "xil_types.h"
#include "xstatus.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    u32 bytes_loaded;
    UINTPTR dst_addr;
    FRESULT fs_result;
} PsFatFsStorageReadResult;

/* Invoked by the storage owner task while a read request is active. Keep the
 * callback bounded and do not start another FatFs operation from it. */
typedef void (*PsFatFsStorageReadChunkCallback)(const u8 *chunk_ptr,
                                                u32 chunk_offset,
                                                u32 chunk_bytes,
                                                void *user_ctx);

typedef struct {
    u32 bytes_written;
    UINTPTR src_addr;
    FRESULT fs_result;
} PsFatFsStorageWriteResult;

typedef struct {
    FRESULT fs_result;
    u32 entries_visited;
    u32 entries_skipped_long;
} PsFatFsStorageListResult;

/* Called synchronously on the requesting task after the owner task has
 * collected the bounded directory result. */
typedef u8 (*PsFatFsStorageListEntryCallback)(const char *name,
                                              const char *full_path,
                                              u8 is_dir,
                                              u32 size_bytes,
                                              void *user_ctx);

XStatus PsFatFsStorage_ReadFileToMemory(const char *path,
                                       UINTPTR dst_addr,
                                       u32 capacity_bytes,
                                       PsFatFsStorageReadResult *result_out);
XStatus PsFatFsStorage_ReadFilePrefix(const char *path,
                                      UINTPTR dst_addr,
                                      u32 max_bytes,
                                      PsFatFsStorageReadResult *result_out);
XStatus PsFatFsStorage_ReadFileToMemoryEx(const char *path,
                                         UINTPTR dst_addr,
                                         u32 capacity_bytes,
                                         PsFatFsStorageReadResult *result_out,
                                         PsFatFsStorageReadChunkCallback chunk_callback,
                                         void *user_ctx);

XStatus PsFatFsStorage_WriteMemoryToFile(const char *path,
                                        UINTPTR src_addr,
                                        u32 bytes_to_write,
                                        PsFatFsStorageWriteResult *result_out);

/* Deletes a file under the same global FatFs mutex used by read/write paths.
 * This avoids cross-task reentrancy hazards from direct f_unlink/f_stat calls. */
XStatus PsFatFsStorage_DeleteFileIfExists(const char *path, u8 *deleted_out);

XStatus PsFatFsStorage_EnsureDirectory(const char *path);
XStatus PsFatFsStorage_ListDirectory(const char *path,
                                     PsFatFsStorageListEntryCallback callback,
                                     void *user_ctx);
XStatus PsFatFsStorage_ListDirectoryEx(const char *path,
                                       PsFatFsStorageListEntryCallback callback,
                                       void *user_ctx,
                                       PsFatFsStorageListResult *result_out);

/* Create the bounded command queue and its single FatFs owner task before
 * starting the scheduler. All public operations are synchronous queue calls. */
XStatus PsFatFsStorage_Init(void);
void PsFatFsStorage_Task(void *arg);

const char *PsFatFsStorage_StrError(FRESULT result);

#ifdef __cplusplus
}
#endif

#endif

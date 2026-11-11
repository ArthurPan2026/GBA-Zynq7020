#ifndef PS_FATFS_TXN_H
#define PS_FATFS_TXN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PS_FATFS_TXN_READY_MARKER_BYTES 12U

typedef enum {
    PS_FATFS_TXN_RECOVER_NONE = 0U,
    PS_FATFS_TXN_RECOVER_CLEAN_SIDECARS = 1U,
    PS_FATFS_TXN_RECOVER_RESTORE_BACKUP = 2U,
    PS_FATFS_TXN_RECOVER_PROMOTE_TEMP = 3U,
    PS_FATFS_TXN_RECOVER_DISCARD_TEMP = 4U
} PsFatFsTxnRecoveryAction;

int PsFatFsTxn_BuildSidecarPaths(const char *target,
                                 char *temporary,
                                 size_t temporary_capacity,
                                 char *backup,
                                 size_t backup_capacity,
                                 char *ready,
                                 size_t ready_capacity);
uint32_t PsFatFsTxn_Crc32Begin(void);
uint32_t PsFatFsTxn_Crc32Update(uint32_t state, const uint8_t *data, size_t bytes);
uint32_t PsFatFsTxn_Crc32Finish(uint32_t state);
uint32_t PsFatFsTxn_Crc32(const uint8_t *data, size_t bytes);
void PsFatFsTxn_MakeReadyMarker(uint32_t bytes,
                                uint32_t crc32,
                                uint8_t marker[PS_FATFS_TXN_READY_MARKER_BYTES]);
int PsFatFsTxn_CheckReadyMarker(const uint8_t marker[PS_FATFS_TXN_READY_MARKER_BYTES],
                                uint32_t *bytes_out,
                                uint32_t *crc32_out);
PsFatFsTxnRecoveryAction PsFatFsTxn_SelectRecoveryAction(int primary_exists,
                                                        int temporary_exists,
                                                        int backup_exists,
                                                        int ready_state);

#ifdef __cplusplus
}
#endif

#endif

#include "Storage/Inc/ps_fatfs_txn.h"

#include <string.h>

#define PS_FATFS_TXN_MARKER_MAGIC 0x50535458U

static void PsFatFsTxn_WriteU32Le(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)(value & 0xFFU);
    dst[1] = (uint8_t)((value >> 8U) & 0xFFU);
    dst[2] = (uint8_t)((value >> 16U) & 0xFFU);
    dst[3] = (uint8_t)((value >> 24U) & 0xFFU);
}

static uint32_t PsFatFsTxn_ReadU32Le(const uint8_t *src) {
    return (uint32_t)src[0] |
           ((uint32_t)src[1] << 8U) |
           ((uint32_t)src[2] << 16U) |
           ((uint32_t)src[3] << 24U);
}

static uint64_t PsFatFsTxn_PathHash(const char *text) {
    uint64_t hash;

    hash = 14695981039346656037ULL;
    while (*text != '\0') {
        hash ^= (uint8_t)*text++;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static int PsFatFsTxn_BuildOneSidecar(const char *target,
                                      const char *tag,
                                      char *out,
                                      size_t out_capacity) {
    static const char hex[] = "0123456789abcdef";
    const char *slash;
    const char *backslash;
    size_t directory_bytes;
    size_t tag_bytes;
    size_t required;
    uint64_t hash;
    uint32_t idx;
    char *cursor;

    if ((target == NULL) || (tag == NULL) || (out == NULL) || (out_capacity == 0U)) {
        return 0;
    }
    slash = strrchr(target, '/');
    backslash = strrchr(target, '\\');
    if ((backslash != NULL) && ((slash == NULL) || (backslash > slash))) {
        slash = backslash;
    }
    directory_bytes = (slash != NULL) ? (size_t)(slash - target + 1) : 0U;
    tag_bytes = strlen(tag);
    required = directory_bytes + 3U + 16U + tag_bytes + 1U;
    if (required > out_capacity) {
        return 0;
    }

    if (directory_bytes > 0U) {
        memcpy(out, target, directory_bytes);
    }
    cursor = &out[directory_bytes];
    cursor[0] = '.';
    cursor[1] = 'p';
    cursor[2] = 's';
    hash = PsFatFsTxn_PathHash(target);
    for (idx = 0U; idx < 16U; ++idx) {
        uint32_t shift = (15U - idx) * 4U;
        cursor[3U + idx] = hex[(uint32_t)((hash >> shift) & 0x0FU)];
    }
    memcpy(&cursor[19U], tag, tag_bytes + 1U);
    return 1;
}

int PsFatFsTxn_BuildSidecarPaths(const char *target,
                                 char *temporary,
                                 size_t temporary_capacity,
                                 char *backup,
                                 size_t backup_capacity,
                                 char *ready,
                                 size_t ready_capacity) {
    if ((target == NULL) || (*target == '\0') ||
        (PsFatFsTxn_BuildOneSidecar(target, ".tmp", temporary, temporary_capacity) == 0) ||
        (PsFatFsTxn_BuildOneSidecar(target, ".bak", backup, backup_capacity) == 0) ||
        (PsFatFsTxn_BuildOneSidecar(target, ".ready", ready, ready_capacity) == 0)) {
        return 0;
    }
    return 1;
}

uint32_t PsFatFsTxn_Crc32Begin(void) {
    return 0xFFFFFFFFU;
}

uint32_t PsFatFsTxn_Crc32Update(uint32_t state, const uint8_t *data, size_t bytes) {
    size_t idx;
    uint32_t bit;

    if ((data == NULL) && (bytes != 0U)) {
        return state;
    }
    for (idx = 0U; idx < bytes; ++idx) {
        state ^= data[idx];
        for (bit = 0U; bit < 8U; ++bit) {
            uint32_t mask = 0U - (state & 1U);
            state = (state >> 1U) ^ (0xEDB88320U & mask);
        }
    }
    return state;
}

uint32_t PsFatFsTxn_Crc32Finish(uint32_t state) {
    return ~state;
}

uint32_t PsFatFsTxn_Crc32(const uint8_t *data, size_t bytes) {
    return PsFatFsTxn_Crc32Finish(PsFatFsTxn_Crc32Update(PsFatFsTxn_Crc32Begin(),
                                                          data,
                                                          bytes));
}

void PsFatFsTxn_MakeReadyMarker(uint32_t bytes,
                                uint32_t crc32,
                                uint8_t marker[PS_FATFS_TXN_READY_MARKER_BYTES]) {
    if (marker == NULL) {
        return;
    }
    PsFatFsTxn_WriteU32Le(&marker[0], PS_FATFS_TXN_MARKER_MAGIC);
    PsFatFsTxn_WriteU32Le(&marker[4], bytes);
    PsFatFsTxn_WriteU32Le(&marker[8], crc32);
}

int PsFatFsTxn_CheckReadyMarker(const uint8_t marker[PS_FATFS_TXN_READY_MARKER_BYTES],
                                uint32_t *bytes_out,
                                uint32_t *crc32_out) {
    if ((marker == NULL) ||
        (PsFatFsTxn_ReadU32Le(&marker[0]) != PS_FATFS_TXN_MARKER_MAGIC) ||
        (PsFatFsTxn_ReadU32Le(&marker[4]) == 0U)) {
        return 0;
    }
    if (bytes_out != NULL) {
        *bytes_out = PsFatFsTxn_ReadU32Le(&marker[4]);
    }
    if (crc32_out != NULL) {
        *crc32_out = PsFatFsTxn_ReadU32Le(&marker[8]);
    }
    return 1;
}

PsFatFsTxnRecoveryAction PsFatFsTxn_SelectRecoveryAction(int primary_exists,
                                                        int temporary_exists,
                                                        int backup_exists,
                                                        int ready_state) {
    if (primary_exists != 0) {
        return (temporary_exists != 0) || (backup_exists != 0) || (ready_state != 0) ?
               PS_FATFS_TXN_RECOVER_CLEAN_SIDECARS : PS_FATFS_TXN_RECOVER_NONE;
    }
    if (backup_exists != 0) {
        return PS_FATFS_TXN_RECOVER_RESTORE_BACKUP;
    }
    if ((temporary_exists != 0) && (ready_state == 1)) {
        return PS_FATFS_TXN_RECOVER_PROMOTE_TEMP;
    }
    if ((temporary_exists != 0) || (ready_state != 0)) {
        return PS_FATFS_TXN_RECOVER_DISCARD_TEMP;
    }
    return PS_FATFS_TXN_RECOVER_NONE;
}

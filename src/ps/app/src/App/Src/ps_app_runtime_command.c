#include "App/Inc/ps_app_runtime_command.h"

#include <string.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"

#include "App/Inc/ps_app_runtime.h"
#include "App/Inc/ps_app_runtime_command_logic.h"
#include "Common/Inc/ps_app_time.h"
#include "Common/Inc/ps_project_config.h"
#include "Gba/Inc/ps_gba_regs.h"
#include "xil_printf.h"

#define PS_APP_RUNTIME_COMMAND_QUEUE_DEPTH 16U
#define PS_APP_RUNTIME_COMMAND_POOL_COUNT PS_APP_RUNTIME_COMMAND_QUEUE_DEPTH
#define PS_APP_RUNTIME_COMMAND_LOCK_WAIT_MS 10U

typedef struct PsAppRuntimeCommandRequest {
    PsAppRuntimeContext *context;
    PsAppRuntimeCommandType command;
    u32 value;
    char path[PS_APP_ROM_PATH_MAX_CHARS];
    PsAppShadowConfig config_snapshot;
    XStatus result;
    u8 in_use;
    SemaphoreHandle_t completed;
} PsAppRuntimeCommandRequest;

static QueueHandle_t s_ps_app_runtime_command_queue;
static SemaphoreHandle_t s_ps_app_runtime_command_pool_lock;
static PsAppRuntimeCommandRequest s_ps_app_runtime_command_pool[PS_APP_RUNTIME_COMMAND_POOL_COUNT];
static PsAppRuntimeCommandQueueState s_ps_app_runtime_command_logic;
static TaskHandle_t s_ps_app_runtime_command_owner_task;
static TaskHandle_t s_ps_app_runtime_command_bootstrap_task;

static XStatus PsAppRuntimeCommand_Execute(PsAppRuntimeContext *ctx,
                                           PsAppRuntimeCommandType command,
                                           const char *path,
                                           u32 value,
                                           const PsAppShadowConfig *config_snapshot) {
    if (ctx == NULL) return XST_INVALID_PARAM;
    switch (command) {
        case PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG:
            if ((ctx->regs == NULL) || (config_snapshot == NULL)) return XST_INVALID_PARAM;
            PsGbaRegs_CommitConfig(ctx->regs,
                                   config_snapshot->ctrl,
                                   config_snapshot->keys,
                                   config_snapshot->max_pak_addr,
                                   config_snapshot->cycle_precalc,
                                   config_snapshot->rtc_timestamp,
                                   config_snapshot->rtc_timestamp_saved);
            return XST_SUCCESS;
        case PS_APP_RUNTIME_COMMAND_LOAD_ROM:
            return PsAppRuntime_LoadRomFromSd(ctx, path);
        case PS_APP_RUNTIME_COMMAND_UNLOAD_ROM:
            return PsAppRuntime_UnloadRom(ctx);
        case PS_APP_RUNTIME_COMMAND_SAVE_STATE:
            return PsAppRuntimeFeature_RunStateCommand(ctx, 0U, (u8)value);
        case PS_APP_RUNTIME_COMMAND_LOAD_STATE:
            return PsAppRuntimeFeature_RunStateCommand(ctx, 1U, (u8)value);
        case PS_APP_RUNTIME_COMMAND_SET_STATE_SLOT:
            return PsAppRuntimeFeature_SetStateSlotCommand(ctx, (u8)value);
        default:
            return XST_INVALID_PARAM;
    }
}

static void PsAppRuntimeCommand_CleanupInit(void) {
    u32 idx;
    for (idx = 0U; idx < PS_APP_RUNTIME_COMMAND_POOL_COUNT; ++idx) {
        if (s_ps_app_runtime_command_pool[idx].completed != NULL) {
            (void)vSemaphoreDelete(s_ps_app_runtime_command_pool[idx].completed);
            s_ps_app_runtime_command_pool[idx].completed = NULL;
        }
    }
    if (s_ps_app_runtime_command_pool_lock != NULL) {
        (void)vSemaphoreDelete(s_ps_app_runtime_command_pool_lock);
        s_ps_app_runtime_command_pool_lock = NULL;
    }
    if (s_ps_app_runtime_command_queue != NULL) {
        vQueueDelete(s_ps_app_runtime_command_queue);
        s_ps_app_runtime_command_queue = NULL;
    }
    s_ps_app_runtime_command_owner_task = NULL;
    s_ps_app_runtime_command_bootstrap_task = NULL;
    PsAppRuntimeCommandLogic_Init(&s_ps_app_runtime_command_logic, 0U);
}

XStatus PsAppRuntimeCommand_Init(void) {
    u32 idx;

    if (s_ps_app_runtime_command_queue != NULL) return XST_SUCCESS;
    if (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) return XST_FAILURE;

    s_ps_app_runtime_command_queue = xQueueCreate(PS_APP_RUNTIME_COMMAND_QUEUE_DEPTH,
                                                   sizeof(PsAppRuntimeCommandRequest *));
    s_ps_app_runtime_command_pool_lock = xSemaphoreCreateMutex();
    if ((s_ps_app_runtime_command_queue == NULL) ||
        (s_ps_app_runtime_command_pool_lock == NULL)) {
        PsAppRuntimeCommand_CleanupInit();
        return XST_FAILURE;
    }
    for (idx = 0U; idx < PS_APP_RUNTIME_COMMAND_POOL_COUNT; ++idx) {
        s_ps_app_runtime_command_pool[idx].completed = xSemaphoreCreateBinary();
        if (s_ps_app_runtime_command_pool[idx].completed == NULL) {
            PsAppRuntimeCommand_CleanupInit();
            return XST_FAILURE;
        }
        s_ps_app_runtime_command_pool[idx].in_use = 0U;
    }
    PsAppRuntimeCommandLogic_Init(&s_ps_app_runtime_command_logic,
                                 PS_APP_RUNTIME_COMMAND_QUEUE_DEPTH);
    return XST_SUCCESS;
}

void PsAppRuntimeCommand_SetBootstrapTask(void) {
    if (s_ps_app_runtime_command_owner_task == NULL) {
        s_ps_app_runtime_command_bootstrap_task = xTaskGetCurrentTaskHandle();
    }
}

void PsAppRuntimeCommand_SetOwnerTask(void) {
    s_ps_app_runtime_command_owner_task = xTaskGetCurrentTaskHandle();
    s_ps_app_runtime_command_bootstrap_task = NULL;
}

u8 PsAppRuntimeCommand_IsOwnerTask(void) {
    return (u8)((s_ps_app_runtime_command_owner_task != NULL) &&
                (xTaskGetCurrentTaskHandle() == s_ps_app_runtime_command_owner_task));
}

u8 PsAppRuntimeCommand_IsBootstrapTask(void) {
    return (u8)((s_ps_app_runtime_command_owner_task == NULL) &&
                (s_ps_app_runtime_command_bootstrap_task != NULL) &&
                (xTaskGetCurrentTaskHandle() == s_ps_app_runtime_command_bootstrap_task));
}

u8 PsAppRuntimeCommand_IsReady(void) {
    return (s_ps_app_runtime_command_queue != NULL) ? 1U : 0U;
}

static PsAppRuntimeCommandRequest *PsAppRuntimeCommand_Acquire(PsAppRuntimeContext *ctx,
                                                              PsAppRuntimeCommandType command,
                                                              const char *path,
                                                              u32 value) {
    TickType_t wait_ticks;
    PsAppRuntimeCommandRequest *request;
    u32 idx;

    if ((ctx == NULL) || (s_ps_app_runtime_command_queue == NULL) ||
        (s_ps_app_runtime_command_pool_lock == NULL)) return NULL;
    wait_ticks = PsAppTime_MsToTicksCeil(PS_APP_RUNTIME_COMMAND_LOCK_WAIT_MS);
    if (xSemaphoreTake(s_ps_app_runtime_command_pool_lock, wait_ticks) != pdTRUE) return NULL;
    if (PsAppRuntimeCommandLogic_TryReserve(&s_ps_app_runtime_command_logic) !=
        PS_APP_RUNTIME_COMMAND_LOGIC_ACCEPTED) {
        (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);
        return NULL;
    }

    request = NULL;
    for (idx = 0U; idx < PS_APP_RUNTIME_COMMAND_POOL_COUNT; ++idx) {
        if (s_ps_app_runtime_command_pool[idx].in_use == 0U) {
            request = &s_ps_app_runtime_command_pool[idx];
            request->in_use = 1U;
            break;
        }
    }
    if (request == NULL) {
        PsAppRuntimeCommandLogic_Release(&s_ps_app_runtime_command_logic);
        (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);
        return NULL;
    }
    (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);

    (void)xSemaphoreTake(request->completed, 0U);
    request->context = ctx;
    request->command = command;
    request->value = value;
    request->result = XST_FAILURE;
    request->path[0] = '\0';
    if (command == PS_APP_RUNTIME_COMMAND_LOAD_ROM) {
        size_t path_len;
        if ((path == NULL) || (*path == '\0')) return request;
        path_len = strlen(path);
        if (path_len >= sizeof(request->path)) return request;
        memcpy(request->path, path, path_len + 1U);
    }
    if (command == PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG) {
        if (ctx->config == NULL) return request;
        request->config_snapshot = *ctx->config;
    }
    return request;
}

static void PsAppRuntimeCommand_Release(PsAppRuntimeCommandRequest *request) {
    if ((request == NULL) || (s_ps_app_runtime_command_pool_lock == NULL)) return;
    if (xSemaphoreTake(s_ps_app_runtime_command_pool_lock, portMAX_DELAY) == pdTRUE) {
        request->in_use = 0U;
        PsAppRuntimeCommandLogic_Release(&s_ps_app_runtime_command_logic);
        (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);
    }
}

XStatus PsAppRuntimeCommand_Submit(PsAppRuntimeContext *ctx,
                                   PsAppRuntimeCommandType command,
                                   const char *path,
                                   u32 value) {
    PsAppRuntimeCommandRequest *request;
    XStatus status;

    if ((ctx == NULL) || (command < PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG) ||
        (command > PS_APP_RUNTIME_COMMAND_SET_STATE_SLOT)) {
        return XST_INVALID_PARAM;
    }
    if ((PsAppRuntimeCommand_IsOwnerTask() != 0U) ||
        (PsAppRuntimeCommand_IsBootstrapTask() != 0U)) {
        PsAppShadowConfig config_snapshot;
        const PsAppShadowConfig *snapshot_ptr = NULL;
        if (command == PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG) {
            if (ctx->config == NULL) return XST_INVALID_PARAM;
            config_snapshot = *ctx->config;
            snapshot_ptr = &config_snapshot;
        }
        /* The owner never queues to itself; bootstrap is the only pre-owner
         * lifecycle path, used while InitSystem handles optional autoload. */
        return PsAppRuntimeCommand_Execute(ctx, command, path, value, snapshot_ptr);
    }
    if (xTaskGetSchedulerState() != taskSCHEDULER_RUNNING) {
        return XST_DEVICE_BUSY;
    }

    request = PsAppRuntimeCommand_Acquire(ctx, command, path, value);
    if (request == NULL) return XST_DEVICE_BUSY;
    if ((command == PS_APP_RUNTIME_COMMAND_LOAD_ROM) &&
        ((path == NULL) || (request->path[0] == '\0'))) {
        PsAppRuntimeCommand_Release(request);
        return XST_INVALID_PARAM;
    }
    if ((command == PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG) && (ctx->config == NULL)) {
        PsAppRuntimeCommand_Release(request);
        return XST_INVALID_PARAM;
    }

    if (xQueueSend(s_ps_app_runtime_command_queue, &request, 0U) != pdTRUE) {
        PsAppRuntimeCommand_Release(request);
        return XST_DEVICE_BUSY;
    }
    /* Accepted commands retain only the bounded static request. The caller
     * remains blocked until the Runtime owner has produced the result. */
    (void)xSemaphoreTake(request->completed, portMAX_DELAY);
    status = request->result;
    PsAppRuntimeCommand_Release(request);
    return status;
}

void PsAppRuntimeCommand_ProcessOne(PsAppRuntimeContext *ctx) {
    PsAppRuntimeCommandRequest *request;
    BaseType_t got_request;
    BaseType_t owner_lock;
    XStatus status;

    if ((ctx == NULL) || (PsAppRuntimeCommand_IsOwnerTask() == 0U) ||
        (s_ps_app_runtime_command_queue == NULL)) return;
    got_request = xQueueReceive(s_ps_app_runtime_command_queue, &request, 0U);
    if (got_request != pdTRUE) return;

    owner_lock = xSemaphoreTake(s_ps_app_runtime_command_pool_lock,
                                PsAppTime_MsToTicksCeil(PS_APP_RUNTIME_COMMAND_LOCK_WAIT_MS));
    if (owner_lock != pdTRUE) {
        request->result = XST_FAILURE;
        (void)xSemaphoreGive(request->completed);
        return;
    }
    if (PsAppRuntimeCommandLogic_TryBegin(&s_ps_app_runtime_command_logic) == 0U) {
        (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);
        request->result = XST_FAILURE;
        (void)xSemaphoreGive(request->completed);
        return;
    }
    (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);

    status = PsAppRuntimeCommand_Execute(ctx,
                                         request->command,
                                         (request->path[0] != '\0') ? request->path : NULL,
                                         request->value,
                                         (request->command == PS_APP_RUNTIME_COMMAND_COMMIT_CONFIG) ?
                                             &request->config_snapshot : NULL);
    request->result = status;

    if (xSemaphoreTake(s_ps_app_runtime_command_pool_lock, portMAX_DELAY) == pdTRUE) {
        PsAppRuntimeCommandLogic_Complete(&s_ps_app_runtime_command_logic);
        (void)xSemaphoreGive(s_ps_app_runtime_command_pool_lock);
    }
    (void)xSemaphoreGive(request->completed);
}

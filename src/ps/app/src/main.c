#include "FreeRTOS.h"
#include "task.h"

#include "sleep.h"
#include "xil_cache.h"
#include "xil_printf.h"

#include "Common/Inc/ps_project_config.h"
#include "Common/Inc/ps_app_context.h"
#include "Common/Inc/ps_app_time.h"
#include "App/Inc/ps_app_console.h"
#include "App/Inc/ps_app_runtime.h"
#include "App/Inc/ps_app_runtime_command.h"
#include "Diagnostics/Inc/ps_app_diag.h"
#include "Save/Inc/ps_app_save.h"
#include "Storage/Inc/ps_fatfs_storage.h"
#include "Ui/Inc/ps_app_ui.h"
#include "Video/Inc/ps_app_video.h"

static PsAppContext s_ps_app_context;

static void PsAppStartup_Fatal(const char *message, XStatus status) {
    xil_printf("[PS] startup failed: %s status=%d\r\n",
               (message != NULL) ? message : "unknown",
               status);
    taskDISABLE_INTERRUPTS();
    for (;;) {
    }
}

static void PsAppStartupTask(void *arg) {
    PsAppContext *app = (PsAppContext *)arg;
    BaseType_t task_status;
    XStatus status;

    if (app == NULL) PsAppStartup_Fatal("null app context", XST_FAILURE);
    PsAppRuntimeCommand_SetBootstrapTask();

    status = PsAppRuntime_InitSystem(&app->runtime_ctx);
    if (status != XST_SUCCESS) PsAppStartup_Fatal("init_system", status);

    PsAppTime_DelayMs(PS_APP_AUTO_BOOT_AUDIT_DELAY_MS);
    PsAppVideo_PresentCapturedFrameIfReady(&app->video_ctx);
    PsAppVideo_SyncDisplayFrame(&app->video_ctx);
    PsAppDiag_PrintAutoBootAudit(&app->diag_ctx);

    xil_printf("[PS] init done: VDMA+Audio+Regs+UART ready\r\n");
    xil_printf("[PS] boot selftest done: HDMI framebuffers cleared, audio playback configured\r\n");

    task_status = xTaskCreate(PsAppMonitorTask,
                              "mon",
                              PS_APP_MONITOR_TASK_STACK_WORDS,
                              &app->runtime_ctx,
                              PS_APP_SYS_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) PsAppStartup_Fatal("monitor task", XST_FAILURE);

    task_status = xTaskCreate(PsAppVideoPresentTask,
                              "video",
                              PS_APP_VIDEO_TASK_STACK_WORDS,
                              &app->runtime_ctx,
                              PS_APP_VIDEO_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) PsAppStartup_Fatal("video task", XST_FAILURE);

    task_status = xTaskCreate(PsAppConsoleTask,
                              "cons",
                              PS_APP_CONSOLE_TASK_STACK_WORDS,
                              &app->console_ctx,
                              PS_APP_CONSOLE_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) PsAppStartup_Fatal("console task", XST_FAILURE);

    task_status = xTaskCreate(PsAppUiTask,
                              "ui",
                              PS_APP_UI_TASK_STACK_WORDS,
                              &app->ui_ctx,
                              PS_APP_UI_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) PsAppStartup_Fatal("ui task", XST_FAILURE);

    vTaskDelete(NULL);
}

int main(void) {
    BaseType_t task_status;
    XStatus status;

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    PsAppContext_Init(&s_ps_app_context);
    status = PsAppRuntimeCommand_Init();
    if (status != XST_SUCCESS) {
        xil_printf("[PS] runtime command owner init failed: %d\r\n", status);
        return 1;
    }
    status = PsFatFsStorage_Init();
    if (status != XST_SUCCESS) {
        xil_printf("[PS] storage owner init failed: %d\r\n", status);
        return 1;
    }
    status = PsAppSave_Init(&s_ps_app_context.save_ctx);
    if (status != XST_SUCCESS) {
        xil_printf("[PS] save owner init failed: %d\r\n", status);
        return 1;
    }
    status = PsAppRuntime_InitUart(&s_ps_app_context.runtime_ctx);
    if (status != XST_SUCCESS) {
        xil_printf("[PS] uart init failed: %d\r\n", status);
        return 1;
    }

    xil_printf("\r\n=== Zynq GBA PS Runtime(Made by SDJU Panziyu) ===\r\n");

    task_status = xTaskCreate(PsAppSaveTask,
                              "save",
                              PS_APP_SAVE_TASK_STACK_WORDS,
                              &s_ps_app_context.save_ctx,
                              PS_APP_SAVE_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) {
        xil_printf("[PS] failed to create save owner task\r\n");
        return 1;
    }

    task_status = xTaskCreate(PsAppStartupTask,
                              "start",
                              PS_APP_STARTUP_TASK_STACK_WORDS,
                              &s_ps_app_context,
                              PS_APP_SYS_TASK_PRIORITY,
                              NULL);
    if (task_status != pdPASS) {
        xil_printf("[PS] failed to create startup task\r\n");
        return 1;
    }

    vTaskStartScheduler();

    for (;;) {
        usleep(1000000U);
    }
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName) {
    (void)xTask;
    xil_printf("\r\n[RTOS][FATAL] stack overflow task=%s\r\n",
               (pcTaskName != NULL) ? pcTaskName : "(null)");
    taskDISABLE_INTERRUPTS();
    for (;;) {
    }
}

void vApplicationMallocFailedHook(void) {
    xil_printf("\r\n[RTOS][FATAL] malloc failed free=%u min=%u\r\n",
               (unsigned int)xPortGetFreeHeapSize(),
               (unsigned int)xPortGetMinimumEverFreeHeapSize());
    taskDISABLE_INTERRUPTS();
    for (;;) {
    }
}

void vApplicationAssert(const char *pcFile, uint32_t ulLine) {
    xil_printf("\r\n[RTOS][FATAL] assert %s:%lu\r\n",
               (pcFile != NULL) ? pcFile : "(null)",
               (unsigned long)ulLine);
    taskDISABLE_INTERRUPTS();
    for (;;) {
    }
}

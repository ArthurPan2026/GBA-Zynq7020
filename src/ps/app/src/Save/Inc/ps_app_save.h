#ifndef PS_APP_SAVE_H
#define PS_APP_SAVE_H

#include "xstatus.h"

#include "Save/Inc/ps_app_save_context.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Create the fixed command pool before the scheduler starts. */
XStatus PsAppSave_Init(PsAppSaveContext *ctx);
/* Save state and generation mailboxes are owned by this task. */
void PsAppSave_Task(void *arg);
/* Clear runtime state and reset DDR save windows on the save owner task. */
void PsAppSave_Reset(PsAppSaveContext *ctx);
/* ROM 装载阶段调用：
 * 创建保存目录并尝试从 SD 把存档“加载+展开”到 core 可读窗口。 */
XStatus PsAppSave_PrepareForRom(PsAppSaveContext *ctx, const char *rom_path);
/* ROM 卸载前兜底：
 * 若仍有 dirty 数据，强制立即落盘。 */
XStatus PsAppSave_FlushIfDirty(PsAppSaveContext *ctx);

#ifdef __cplusplus
}
#endif

#endif

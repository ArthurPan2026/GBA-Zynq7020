#include "Diagnostics/Inc/ps_app_power_monitor.h"

#include <stddef.h>

#include "xadcps.h"
#include "xparameters.h"
#include "xstatus.h"

static XAdcPs s_ps_app_power_xadc;
static u8 s_ps_app_power_xadc_ready;

int PsAppPowerMonitor_Init(void) {
    XAdcPs_Config *config;
    int status;

    if (s_ps_app_power_xadc_ready != 0U) {
        return XST_SUCCESS;
    }

    config = XAdcPs_LookupConfig(XPAR_XXADCPS_0_BASEADDR);
    if (config == NULL) {
        return XST_FAILURE;
    }

    status = XAdcPs_CfgInitialize(&s_ps_app_power_xadc,
                                  config,
                                  config->BaseAddress);
    if (status != XST_SUCCESS) {
        return status;
    }

    XAdcPs_SetSequencerMode(&s_ps_app_power_xadc, XADCPS_SEQ_MODE_SINGCHAN);
    XAdcPs_SetAvg(&s_ps_app_power_xadc, XADCPS_AVG_256_SAMPLES);
    status = XAdcPs_SetSingleChParams(&s_ps_app_power_xadc,
                                      XADCPS_CH_VPVN,
                                      1,
                                      0,
                                      1);
    if (status != XST_SUCCESS) {
        return status;
    }

    s_ps_app_power_xadc_ready = 1U;
    return XST_SUCCESS;
}

int PsAppPowerMonitor_Read(PsAppPowerSample *sample) {
    u16 raw16;
    u32 raw12;
    u64 scaled;

    if ((sample == NULL) || (s_ps_app_power_xadc_ready == 0U)) {
        return XST_FAILURE;
    }

    raw16 = XAdcPs_GetAdcData(&s_ps_app_power_xadc, XADCPS_CH_VPVN);
    raw12 = ((u32)raw16 >> 4) & 0x0FFFU;
    scaled = (u64)raw12 * 244000U;

    /* Zybo Z7 RM Figure 1.4.1:
     * I(A) = ((X * 244 / 3900) - 0.8) / 52.
     * Convert directly to mA while retaining integer precision.
     */
    if (scaled <= 3120000U) {
        return XST_FAILURE;
    }

    sample->raw12 = (u16)raw12;
    sample->current_ma = (u32)((scaled - 3120000U + 101400U) / 202800U);
    return XST_SUCCESS;
}

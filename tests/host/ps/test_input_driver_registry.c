#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "Input/Inc/ps_app_input_driver.h"
#include "Input/Inc/ps_app_input.h"

typedef char PsAppInputLegacyAttachApiDeclared[
    (sizeof(&PsAppInput_OnUsbXInputAttached) > 0U) ? 1 : -1];
typedef char PsAppInputLegacyDetachApiDeclared[
    (sizeof(&PsAppInput_OnUsbDetached) > 0U) ? 1 : -1];
typedef char PsAppInputLegacyInterruptReportApiDeclared[
    (sizeof(&PsAppInput_OnInterruptInReport) > 0U) ? 1 : -1];
typedef char PsAppInputStrictTransportApiDeclared[
    (sizeof(&PsAppInput_OnTransportReport) > 0U) ? 1 : -1];
typedef char PsAppInputStrictDetachApiDeclared[
    (sizeof(&PsAppInput_OnUsbDetachedGeneration) > 0U) ? 1 : -1];

static PsAppInputUsbDeviceInfo device_info(u16 vid, u16 pid, u8 cls, u8 sub, u8 proto) {
    PsAppInputUsbDeviceInfo info;
    memset(&info, 0, sizeof(info));
    info.vendor_id = vid;
    info.product_id = pid;
    info.interface_class = cls;
    info.interface_subclass = sub;
    info.interface_protocol = proto;
    info.ep_in_addr = 0x81U;
    info.ep_out_addr = 0x01U;
    return info;
}

static void fill_xinput_report(u8 report[PS_XINPUT_REPORT_SIZE_INPUT]) {
    memset(report, 0, PS_XINPUT_REPORT_SIZE_INPUT);
    report[0] = PS_XINPUT_REPORT_ID_DEFAULT;
    report[1] = PS_XINPUT_REPORT_SIZE_INPUT;
    report[3] = 0x10U; /* XInput A button. */
    report[6] = 0x34U;
    report[7] = 0x12U;
}

static void test_deterministic_match_priority(void) {
    PsAppInputUsbDeviceInfo info;
    const PsAppInputDriver *driver;

    info = device_info(0x057EU, 0x2009U, 0x03U, 0U, 0U);
    driver = PsAppInputDriver_Select(&info);
    assert(driver != NULL && driver->id == PS_APP_INPUT_DRIVER_ID_SWITCH_HID);

    info = device_info(0x2DC8U, 0x3106U, 0xFFU, 0x5DU, 0x01U);
    driver = PsAppInputDriver_Select(&info);
    assert(driver != NULL && driver->id == PS_APP_INPUT_DRIVER_ID_8BITDO);
    info.interface_class = 0x03U;
    info.interface_subclass = 0U;
    info.interface_protocol = 0U;
    assert(PsAppInputDriver_Select(&info) == NULL);

    info = device_info(0x1234U, 0x5678U, 0xFFU, 0x5DU, 0x01U);
    driver = PsAppInputDriver_Select(&info);
    assert(driver != NULL && driver->id == PS_APP_INPUT_DRIVER_ID_GENERIC_XINPUT);

    info = device_info(0x1234U, 0x5678U, 0x03U, 0U, 0U);
    assert(PsAppInputDriver_Select(&info) == NULL);
}

static void test_profile_host_init_policies(void) {
    PsAppInputUsbDeviceInfo info;
    const PsAppInputDriver *driver;
    const PsAppInputDeviceProfile *profile;
    u32 policy;

    info = device_info(0x2DC8U, 0x3106U, 0xFFU, 0x5DU, 0x01U);
    driver = PsAppInputDriver_Select(&info);
    policy = PsAppInputDriver_GetHostInitPolicy(driver, &info);
    profile = PsAppInputProfile_FindForDevice(&info);
    assert(policy == PS_APP_INPUT_HOST_INIT_SIDEBAND);
    assert(profile != NULL && profile->first_report_fallback_timeout_ms == 0U);

    info.product_id = 0x310BU;
    driver = PsAppInputDriver_Select(&info);
    policy = PsAppInputDriver_GetHostInitPolicy(driver, &info);
    profile = PsAppInputProfile_FindForDevice(&info);
    assert(policy == (PS_APP_INPUT_HOST_INIT_SIDEBAND |
                      PS_APP_INPUT_HOST_INIT_SIDEBAND_ONE_SHOT |
                      PS_APP_INPUT_HOST_INIT_SHORT_FIRST_REPORT_FALLBACK));
    assert(profile != NULL && profile->first_report_fallback_timeout_ms == 3000U);

    info = device_info(0x057EU, 0x2009U, 0x03U, 0U, 0U);
    driver = PsAppInputDriver_Select(&info);
    policy = PsAppInputDriver_GetHostInitPolicy(driver, &info);
    profile = PsAppInputProfile_FindForDevice(&info);
    assert(policy == PS_APP_INPUT_HOST_INIT_SWITCH_REPORT_MODE);
    assert(profile != NULL && profile->first_report_fallback_timeout_ms == 0U);

    assert(PsXinput_IsLikely8BitDo(0x2DC8U, 0x3106U) != 0U);
    assert(PsXinput_IsLikely8BitDo(0x1234U, 0x3106U) == 0U);
}

static void test_generation_checks_are_strict(void) {
    assert(PsAppInputDriver_IsGenerationValid(0U) == 0U);
    assert(PsAppInputDriver_IsGenerationValid(1U) != 0U);
    assert(PsAppInputDriver_IsNewerGeneration(2U, 1U) != 0U);
    assert(PsAppInputDriver_IsNewerGeneration(1U, 2U) == 0U);
    assert(PsAppInputDriver_IsNewerGeneration(1U, 0xFFFFFFFFU) != 0U);
    assert(PsAppInputDriver_IsNewerGeneration(0xFFFFFFFFU, 1U) == 0U);

    assert(PsAppInputDriver_IsReportGenerationCurrent(7U, 7U) != 0U);
    assert(PsAppInputDriver_IsReportGenerationCurrent(8U, 7U) == 0U);
    assert(PsAppInputDriver_IsReportGenerationCurrent(8U, 0U) == 0U);
    assert(PsAppInputDriver_IsReportGenerationCurrent(0U, 7U) == 0U);
}

static void test_switch_report_profile(void) {
    PsAppInputUsbDeviceInfo info = device_info(0x057EU, 0x2009U, 0x03U, 0U, 0U);
    const PsAppInputDriver *driver = PsAppInputDriver_Select(&info);
    u8 report[13] = { 0U };
    PsAppInputPadState pad;

    assert(driver != NULL && driver->ops != NULL);
    assert(driver->ops->init(&info) == XST_SUCCESS);
    assert(driver->ops->build_output == NULL);
    report[0] = 0x30U;
    report[3] = (1U << 2U); /* Switch B. */
    report[7] = 0x08U;
    report[8] = 0x80U;
    report[10] = 0x08U;
    report[11] = 0x80U;

    assert(driver->ops->ignore_report(&info, report, sizeof(report)) == 0U);
    assert(driver->ops->accept_report(&info, report, sizeof(report)) != 0U);
    assert(driver->ops->parse_input(&info, report, sizeof(report), &pad) == XST_SUCCESS);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_B) != 0U);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_A) == 0U);
    assert(pad.lx == 0 && pad.ly == 0 && pad.rx == 0 && pad.ry == 0);

    report[0] = 0x3FU;
    assert(driver->ops->ignore_report(&info, report, sizeof(report)) != 0U);
}

static void test_xinput_profiles_parse_reports(void) {
    PsAppInputUsbDeviceInfo info;
    const PsAppInputDriver *driver;
    u8 report[PS_XINPUT_REPORT_SIZE_INPUT];
    PsAppInputPadState pad;
    u8 output[PS_XINPUT_REPORT_SIZE_OUTPUT];

    fill_xinput_report(report);
    info = device_info(0x2DC8U, 0x3106U, 0xFFU, 0x5DU, 0x01U);
    driver = PsAppInputDriver_Select(&info);
    assert(driver != NULL && driver->id == PS_APP_INPUT_DRIVER_ID_8BITDO);
    assert(driver->ops->accept_report(&info, report, sizeof(report)) != 0U);
    assert(driver->ops->parse_input(&info, report, sizeof(report), &pad) == XST_SUCCESS);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_A) != 0U);
    assert(pad.lx == 0x1234);

    driver->ops->build_output(&info, 0xA5U, 0x5AU, output);
    assert(output[3] == 0xA5U && output[4] == 0x5AU);

    info = device_info(0x1234U, 0x5678U, 0xFFU, 0x5DU, 0x01U);
    driver = PsAppInputDriver_Select(&info);
    assert(driver != NULL && driver->id == PS_APP_INPUT_DRIVER_ID_GENERIC_XINPUT);
    assert(driver->ops->accept_report(&info, report, sizeof(report)) != 0U);
    assert(driver->ops->parse_input(&info, report, sizeof(report), &pad) == XST_SUCCESS);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_A) != 0U);
    assert(pad.lx == 0x1234);
}

int main(void) {
    test_deterministic_match_priority();
    test_profile_host_init_policies();
    test_generation_checks_are_strict();
    test_switch_report_profile();
    test_xinput_profiles_parse_reports();
    puts("PS input driver registry tests passed");
    return 0;
}

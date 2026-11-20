#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Input/Inc/ps_xinput_xbox360.h"

static void test_xinput_prefixed_report(void) {
    const u8 report[20] = {
        0x00U, 0x14U,
        0x05U, 0x10U,
        0x21U, 0x43U,
        0x34U, 0x12U,
        0xFEU, 0xFFU,
        0x00U, 0x80U,
        0xFFU, 0x7FU,
        0U, 0U, 0U, 0U, 0U, 0U
    };
    PsXinputPadState pad;

    memset(&pad, 0, sizeof(pad));
    assert(PsXinput_ParseInputReport(report, sizeof(report), &pad) == XST_SUCCESS);
    assert(pad.buttons == 0x1005U);
    assert(pad.lt == 0x21U && pad.rt == 0x43U);
    assert(pad.lx == 0x1234 && pad.ly == -2);
    assert(pad.rx == -32768 && pad.ry == 32767);
}

static void test_xinput_length_prefix(void) {
    const u8 report[19] = {
        0x14U,
        0x20U, 0x00U,
        0x10U, 0x11U,
        0xFFU, 0xFFU,
        0x00U, 0x00U,
        0x00U, 0x00U,
        0x00U, 0x00U,
        0U, 0U, 0U, 0U, 0U, 0U
    };
    PsXinputPadState pad;

    assert(PsXinput_ParseInputReport(report, sizeof(report), &pad) == XST_SUCCESS);
    assert(pad.buttons == 0x20U);
    assert(pad.lt == 0x10U && pad.rt == 0x11U);
    assert(pad.lx == -1 && pad.ly == 0);
}

static void test_switch_packed_report(void) {
    const u8 report[13] = {
        0x30U, 0U, 0U,
        (1U << 3U), /* B0: Switch A/right -> XInput A */
        0U,
        (1U << 1U) | (1U << 7U), /* up + left trigger */
        0x00U, 0x08U, /* lx raw 2048 */
        0x80U,        /* ly raw 2048 */
        0x00U, 0x08U, /* rx raw 2048 */
        0x80U         /* ry raw 2048 */
    };
    PsXinputPadState pad;

    assert(PsXinput_ParseInputReport(report, sizeof(report), &pad) == XST_SUCCESS);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_A) != 0U);
    assert((pad.buttons & PS_XINPUT_BUTTON_MASK_UP) != 0U);
    assert(pad.lt == 255U);
    assert(pad.lx == 0 && pad.ly == 0 && pad.rx == 0 && pad.ry == 0);
}

static void test_input_bounds_and_profiles(void) {
    const u8 short_report[11] = { 0U };
    PsXinputPadState pad;

    assert(PsXinput_ParseInputReport(NULL, 0U, &pad) == XST_INVALID_PARAM);
    assert(PsXinput_ParseInputReport(short_report, sizeof(short_report), &pad) == XST_INVALID_PARAM);
    assert(PsXinput_IsInterfaceCompatible(0xFFU, 0x5DU, 0x01U) == 1U);
    assert(PsXinput_IsInterfaceCompatible(0x03U, 0x5DU, 0x01U) == 0U);
    assert(PsXinput_IsLikely8BitDo(0x2DC8U, 0x3106U) == 1U);
    assert(PsXinput_IsLikely8BitDo(0x1234U, 0x3106U) == 0U);
}

int main(void) {
    test_xinput_prefixed_report();
    test_xinput_length_prefix();
    test_switch_packed_report();
    test_input_bounds_and_profiles();
    puts("PS XInput parser tests passed");
    return 0;
}

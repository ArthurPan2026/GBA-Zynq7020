#include "App/Inc/ps_app_console_line.h"

#include <string.h>

static size_t PsAppConsoleLineInput_Utf8SequenceLength(uint8_t lead_byte) {
    if (lead_byte < 0x80U) {
        return 1U;
    }
    if ((lead_byte >= 0xC2U) && (lead_byte <= 0xDFU)) {
        return 2U;
    }
    if ((lead_byte >= 0xE0U) && (lead_byte <= 0xEFU)) {
        return 3U;
    }
    if ((lead_byte >= 0xF0U) && (lead_byte <= 0xF4U)) {
        return 4U;
    }
    return 0U;
}

void PsAppConsoleLineInput_Reset(PsAppConsoleLineInput *line) {
    if (line == NULL) {
        return;
    }
    memset(line, 0, sizeof(*line));
}

static PsAppConsoleLineInputEvent PsAppConsoleLineInput_Backspace(PsAppConsoleLineInput *line) {
    size_t start;
    size_t expected_length;
    size_t previous_length;

    if ((line == NULL) || (line->length == 0U) || (line->overflowed != 0U)) {
        return PS_APP_CONSOLE_LINE_IGNORED;
    }

    previous_length = line->length;
    start = line->length - 1U;
    while ((start > 0U) && (((uint8_t)line->bytes[start] & 0xC0U) == 0x80U)) {
        start--;
    }

    expected_length = PsAppConsoleLineInput_Utf8SequenceLength((uint8_t)line->bytes[start]);
    if ((expected_length > 1U) && ((start + expected_length) >= line->length)) {
        line->length = start;
    } else {
        line->length--;
    }
    line->bytes[line->length] = '\0';
    return ((previous_length - line->length) > 1U) ?
           PS_APP_CONSOLE_LINE_BACKSPACED_WIDE : PS_APP_CONSOLE_LINE_BACKSPACED;
}

PsAppConsoleLineInputEvent PsAppConsoleLineInput_Consume(PsAppConsoleLineInput *line,
                                                         uint8_t byte) {
    if (line == NULL) {
        return PS_APP_CONSOLE_LINE_IGNORED;
    }

    if ((byte == '\r') || (byte == '\n')) {
        return (line->overflowed != 0U) ? PS_APP_CONSOLE_LINE_TOO_LONG :
                                         PS_APP_CONSOLE_LINE_READY;
    }

    if ((byte == 0x08U) || (byte == 0x7FU)) {
        return PsAppConsoleLineInput_Backspace(line);
    }

    if ((line->overflowed != 0U) || (byte < 0x20U)) {
        return PS_APP_CONSOLE_LINE_IGNORED;
    }

    if (line->length >= (PS_APP_CONSOLE_LINE_CAPACITY - 1U)) {
        line->overflowed = 1U;
        return PS_APP_CONSOLE_LINE_IGNORED;
    }

    /* Keep UTF-8 bytes unchanged; FatFs is configured for UTF-8 LFN paths. */
    line->bytes[line->length++] = (char)byte;
    line->bytes[line->length] = '\0';
    return PS_APP_CONSOLE_LINE_APPENDED;
}

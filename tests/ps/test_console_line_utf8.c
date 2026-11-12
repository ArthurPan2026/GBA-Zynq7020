#include "App/Inc/ps_app_console_line.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed_bytes(PsAppConsoleLineInput *line, const char *bytes, size_t length) {
    size_t i;
    for (i = 0U; i < length; ++i) {
        (void)PsAppConsoleLineInput_Consume(line, (uint8_t)(unsigned char)bytes[i]);
    }
}

static void test_ascii_command(void) {
    static const char command[] = "rom status";
    PsAppConsoleLineInput line;

    PsAppConsoleLineInput_Reset(&line);
    feed_bytes(&line, command, sizeof(command) - 1U);
    assert(PsAppConsoleLineInput_Consume(&line, '\r') == PS_APP_CONSOLE_LINE_READY);
    assert(strcmp(line.bytes, command) == 0);
}

static void test_utf8_rom_path_round_trips(void) {
    static const char command[] =
        "rom load 0:/games/\xE7\x94\xB5\xE6\xA2\xAF\xE5\xA4\xA7\xE6\x88\x98.gba";
    PsAppConsoleLineInput line;

    PsAppConsoleLineInput_Reset(&line);
    feed_bytes(&line, command, sizeof(command) - 1U);
    assert(PsAppConsoleLineInput_Consume(&line, '\r') == PS_APP_CONSOLE_LINE_READY);
    assert(line.length == sizeof(command) - 1U);
    assert(memcmp(line.bytes, command, sizeof(command)) == 0);
}

static void test_backspace_removes_one_utf8_character(void) {
    static const char text[] = "A\xE7\x94\xB5\xE6\xA2\xAF";
    static const char expected[] = "A\xE7\x94\xB5";
    PsAppConsoleLineInput line;

    PsAppConsoleLineInput_Reset(&line);
    feed_bytes(&line, text, sizeof(text) - 1U);
    assert(PsAppConsoleLineInput_Consume(&line, 0x08U) ==
           PS_APP_CONSOLE_LINE_BACKSPACED_WIDE);
    assert(strcmp(line.bytes, expected) == 0);
    assert(PsAppConsoleLineInput_Consume(&line, 0x7FU) ==
           PS_APP_CONSOLE_LINE_BACKSPACED_WIDE);
    assert(strcmp(line.bytes, "A") == 0);
    assert(PsAppConsoleLineInput_Consume(&line, 0x08U) ==
           PS_APP_CONSOLE_LINE_BACKSPACED);
    assert(strcmp(line.bytes, "") == 0);
}

static void test_overlong_line_is_rejected_as_a_whole(void) {
    PsAppConsoleLineInput line;
    size_t i;

    PsAppConsoleLineInput_Reset(&line);
    for (i = 0U; i < (PS_APP_CONSOLE_LINE_CAPACITY - 1U); ++i) {
        assert(PsAppConsoleLineInput_Consume(&line, 'A') ==
               PS_APP_CONSOLE_LINE_APPENDED);
    }
    assert(PsAppConsoleLineInput_Consume(&line, 'B') ==
           PS_APP_CONSOLE_LINE_IGNORED);
    assert(line.overflowed != 0U);
    assert(PsAppConsoleLineInput_Consume(&line, '\r') ==
           PS_APP_CONSOLE_LINE_TOO_LONG);

    PsAppConsoleLineInput_Reset(&line);
    feed_bytes(&line, "help", 4U);
    assert(PsAppConsoleLineInput_Consume(&line, '\n') ==
           PS_APP_CONSOLE_LINE_READY);
    assert(strcmp(line.bytes, "help") == 0);
}

int main(void) {
    test_ascii_command();
    test_utf8_rom_path_round_trips();
    test_backspace_removes_one_utf8_character();
    test_overlong_line_is_rejected_as_a_whole();
    puts("TEST_PASS console-line-utf8");
    return 0;
}

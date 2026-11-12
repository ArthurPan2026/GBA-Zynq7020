#ifndef PS_APP_CONSOLE_LINE_H
#define PS_APP_CONSOLE_LINE_H

#include <stddef.h>
#include <stdint.h>

#define PS_APP_CONSOLE_LINE_CAPACITY 192U

typedef struct {
    char bytes[PS_APP_CONSOLE_LINE_CAPACITY];
    size_t length;
    uint8_t overflowed;
} PsAppConsoleLineInput;

typedef enum {
    PS_APP_CONSOLE_LINE_IGNORED = 0,
    PS_APP_CONSOLE_LINE_APPENDED,
    PS_APP_CONSOLE_LINE_BACKSPACED,
    PS_APP_CONSOLE_LINE_BACKSPACED_WIDE,
    PS_APP_CONSOLE_LINE_READY,
    PS_APP_CONSOLE_LINE_TOO_LONG
} PsAppConsoleLineInputEvent;

void PsAppConsoleLineInput_Reset(PsAppConsoleLineInput *line);
PsAppConsoleLineInputEvent PsAppConsoleLineInput_Consume(PsAppConsoleLineInput *line,
                                                         uint8_t byte);

#endif

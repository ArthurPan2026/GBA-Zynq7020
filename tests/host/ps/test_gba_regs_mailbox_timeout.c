#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "Gba/Inc/ps_gba_regs.h"
#include "Common/Inc/ps_app_time.h"

#define TEST_MMIO_BASE ((UINTPTR)0x1000U)
#define TEST_REGISTER_WORDS 256U
#define TEST_SEQUENCE 42U
#define TEST_EXPECTED_TOGGLE 1U

static u32 s_registers[TEST_REGISTER_WORDS];
static u32 s_time_values[16];
static size_t s_time_value_count;
static size_t s_time_value_index;
static u32 s_time_calls;
static u32 s_last_time;
static u32 s_ack_after_time_calls;
static u8 s_ack_enabled;

static u32 register_index(UINTPTR address) {
    assert(address >= TEST_MMIO_BASE);
    assert(((address - TEST_MMIO_BASE) & 3U) == 0U);
    return (u32)((address - TEST_MMIO_BASE) >> 2U);
}

u32 Xil_In32(UINTPTR address) {
    u32 index = register_index(address);
    u32 ack_toggle_index = (GBA_REG_MEM_CMD_REQ_TOGGLE >> 2U);
    u32 ack_seq_index = (GBA_REG_MEM_CMD_ACK_SEQ >> 2U);

    if ((s_ack_enabled != 0U) && (s_time_calls >= s_ack_after_time_calls) &&
        ((index == ack_toggle_index) || (index == ack_seq_index))) {
        s_registers[ack_toggle_index] = TEST_EXPECTED_TOGGLE;
        s_registers[ack_seq_index] = TEST_SEQUENCE;
    }
    assert(index < TEST_REGISTER_WORDS);
    return s_registers[index];
}

void Xil_Out32(UINTPTR address, u32 value) {
    u32 index = register_index(address);
    assert(index < TEST_REGISTER_WORDS);
    s_registers[index] = value;
}

uint32_t PsAppTime_GetNowMs(void) {
    u32 value;

    if (s_time_value_index < s_time_value_count) {
        value = s_time_values[s_time_value_index++];
    } else {
        value = s_last_time + 1U;
    }
    s_last_time = value;
    s_time_calls++;
    return value;
}

static void begin_case(const u32 *times, size_t count, u8 ack_enabled, u32 ack_after_calls) {
    memset(s_registers, 0, sizeof(s_registers));
    memset(s_time_values, 0, sizeof(s_time_values));
    if (count > (sizeof(s_time_values) / sizeof(s_time_values[0]))) {
        assert(0);
    }
    if ((times != NULL) && (count > 0U)) {
        memcpy(s_time_values, times, count * sizeof(times[0]));
        s_last_time = times[0];
    } else {
        s_last_time = 0U;
    }
    s_time_value_count = count;
    s_time_value_index = 0U;
    s_time_calls = 0U;
    s_ack_enabled = ack_enabled;
    s_ack_after_time_calls = ack_after_calls;
}

static XStatus run_memory_command(u32 timeout_ms) {
    PsGbaRegs regs;
    PsGbaRegs_Init(&regs, TEST_MMIO_BASE);
    return PsGbaRegs_MemoryCommand(&regs, 1U, TEST_SEQUENCE, timeout_ms, NULL, NULL);
}

static void test_zero_timeout_checks_ack_once(void) {
    begin_case(NULL, 0U, 0U, 0U);
    assert(run_memory_command(0U) == XST_TIMEOUT);
    assert(s_time_calls == 1U);

    begin_case(NULL, 0U, 1U, 1U);
    assert(run_memory_command(0U) == XST_SUCCESS);
    assert(s_time_calls == 1U);
}

static void test_timeout_boundary(void) {
    const u32 before_deadline[] = { 100U, 109U };
    const u32 at_deadline[] = { 100U, 110U };

    begin_case(before_deadline, 2U, 1U, 2U);
    assert(run_memory_command(10U) == XST_SUCCESS);
    assert(s_time_calls == 2U);

    begin_case(at_deadline, 2U, 0U, 0U);
    assert(run_memory_command(10U) == XST_TIMEOUT);
    assert(s_time_calls == 2U);
}

static void test_timeout_across_millisecond_wrap(void) {
    const u32 across_wrap[] = { UINT32_MAX - 1U, 0U, 1U };

    begin_case(across_wrap, 3U, 0U, 0U);
    assert(run_memory_command(3U) == XST_TIMEOUT);
    assert(s_time_calls == 3U);
}

static void test_timeout_returns_memory_snapshot(void) {
    PsGbaRegs regs;
    u32 status = 0U;
    u32 error = 0U;

    begin_case(NULL, 0U, 0U, 0U);
    s_registers[GBA_REG_MEM_STATUS >> 2U] = GBA_MEM_STATUS_QUIESCED |
                                               GBA_MEM_STATUS_DRAINED;
    s_registers[GBA_REG_MEM_ERROR >> 2U] = 0x5U;
    PsGbaRegs_Init(&regs, TEST_MMIO_BASE);

    assert(PsGbaRegs_MemoryCommand(&regs,
                                   GBA_MEM_CMD_RESUME,
                                   TEST_SEQUENCE,
                                   0U,
                                   &status,
                                   &error) == XST_TIMEOUT);
    assert(status == (GBA_MEM_STATUS_QUIESCED | GBA_MEM_STATUS_DRAINED));
    assert(error == 0x5U);
}

int main(void) {
    test_zero_timeout_checks_ack_once();
    test_timeout_boundary();
    test_timeout_across_millisecond_wrap();
    test_timeout_returns_memory_snapshot();
    puts("GBA mailbox timeout tests passed");
    return 0;
}

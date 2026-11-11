#include "Diagnostics/Inc/ps_app_diag_disasm.h"
#include "xil_io.h"
#include "xil_printf.h"

#define ROM_PS_BASE   0x100C0000U
#define ROM_GBA_BASE  0x08000000U
#define ROM_MAX_BYTES (32U * 1024U * 1024U)

static u32 gba_to_ps_addr(u32 gba_addr) {
    if (gba_addr < 0x08000000U || gba_addr >= 0x0A000000U) return 0U;
    u32 offset = gba_addr - 0x08000000U;
    if (offset >= ROM_MAX_BYTES) return 0U;
    return ROM_PS_BASE + (offset & ~3U);  /* word-align */
}

static u16 read_rom_u16(u32 ps_addr) {
    if (ps_addr == 0U) return 0xFFFFU;
    u32 w = Xil_In32(ps_addr & ~3U);
    return (u16)((ps_addr & 2U) ? (w >> 16) : (w & 0xFFFFU));
}

/* --- Thumb disasm (prints directly) --- */
static void print_thumb_instr(u16 instr, u32 pc) {
    u32 imm8 = instr & 0xFFU;
    u32 op5, rd, rs, rn, op2;

    /* SWI */
    if ((instr >> 8) == 0xDFU) {
        xil_printf("SWI #%u", (unsigned)imm8);
        return;
    }
    /* Conditional branch: bits 15:12 = 1101, bits 11:8 = cond */
    if ((instr >> 12) == 0xDU) {
        static const char *tc[16] = {
            "EQ","NE","CS","CC","MI","PL","VS","VC",
            "HI","LS","GE","LT","GT","LE","","??"
        };
        s32 off = (s32)(instr & 0xFFU);
        if (off & 0x80) off |= 0xFFFFFF00;
        xil_printf("B%s 0x%08x", tc[(instr>>8)&0xFU], (unsigned)(pc+4+off*2));
        return;
    }
    /* Unconditional branch: bits 15:11 = 11100 */
    if ((instr >> 11) == 0x1CU) {
        s32 off = (s32)(instr & 0x7FFU);
        if (off & 0x400) off |= 0xFFFFF800;
        xil_printf("B 0x%08x", (unsigned)(pc+4+off*2));
        return;
    }
    /* BL/BLX: bits 15:11 >= 11110 (30-31) */
    if ((instr >> 11) >= 0x1EU) {
        xil_printf("BL/BLX");
        return;
    }

    op5 = (instr >> 11) & 0x1FU;
    rd  = instr & 7U;
    rs  = (instr >> 3) & 7U;
    rn  = (instr >> 6) & 7U;
    op2 = (instr >> 9) & 3U;
    switch (op5) {
    case 0U: xil_printf("LSL r%u, r%u, #%u", (unsigned)rd, (unsigned)rs, (unsigned)((instr>>6)&0x1FU)); return;
    case 1U: xil_printf("LSR r%u, r%u, #%u", (unsigned)rd, (unsigned)rs, (unsigned)((instr>>6)&0x1FU ?: 32U)); return;
    case 2U: xil_printf("ASR r%u, r%u, #%u", (unsigned)rd, (unsigned)rs, (unsigned)((instr>>6)&0x1FU ?: 32U)); return;
    case 3U:
        if (instr & 0x0400U) {
            xil_printf("SUB r%u, r%u, ", (unsigned)rd, (unsigned)rs);
        } else {
            xil_printf("ADD r%u, r%u, ", (unsigned)rd, (unsigned)rs);
        }
        if (instr & 0x0200U) xil_printf("#%u", (unsigned)rn);
        else xil_printf("r%u", (unsigned)rn);
        return;
    case 4U:
        switch (op2) {
        case 0U: xil_printf("MOV"); break;
        case 1U: xil_printf("CMP"); break;
        case 2U: xil_printf("ADD"); break;
        case 3U: xil_printf("SUB"); break;
        }
        xil_printf(" r%u, #%u", (unsigned)rd, (unsigned)imm8);
        return;
    case 5U:
        switch (op2) {
        case 0U: xil_printf("ADD"); break;
        case 1U: xil_printf("CMP"); break;
        case 2U: xil_printf("MOV"); break;
        case 3U: xil_printf("%s", (instr&0x80U)?"BLX":"BX"); break;
        }
        if (op2 < 3U) xil_printf(" r%u, r%u", (unsigned)(rd|(instr&0x80U?8U:0U)), (unsigned)(rs|(instr&0x40U?8U:0U)));
        else xil_printf(" r%u", (unsigned)(rs|(instr&0x40U?8U:0U)));
        return;
    case 6U: case 7U:
        xil_printf("LDR r%u, [pc, #%u]", (unsigned)((instr>>8)&7U), (unsigned)(imm8*4U));
        return;
    case 8U:
        xil_printf("%s r%u, [r%u, r%u]",
            (instr&0x0400U)?((instr&0x0800U)?"LDRB":"STRB"):((instr&0x0800U)?"LDRH":"STRH"),
            (unsigned)rd, (unsigned)rs, (unsigned)rn);
        return;
    case 9U:
        xil_printf("%s r%u, [r%u, #%u]",
            (instr&0x0800U)?"LDR":"STR", (unsigned)rd, (unsigned)rs, (unsigned)(imm8*4U));
        return;
    case 10U:
        if (instr & 0x0800U) {
            xil_printf("LDR%s r%u, [r%u, #%u]",
                (instr&0x0400U)?"H":"B", (unsigned)rd, (unsigned)rs, (unsigned)((instr&0xFFU)*2U));
        } else {
            xil_printf("STRH r%u, [r%u, #%u]", (unsigned)rd, (unsigned)rs, (unsigned)((instr&0xFFU)*2U));
        }
        return;
    case 11U:
        xil_printf("%s r%u, [sp, #%u]",
            (instr&0x0800U)?"LDR":"STR", (unsigned)((instr>>8)&7U), (unsigned)(imm8*4U));
        return;
    case 12U:
        if (instr & 0x0800U) xil_printf("ADD r%u, sp, #%u", (unsigned)((instr>>8)&7U), (unsigned)(imm8*4U));
        else xil_printf("ADD r%u, pc, #%u", (unsigned)((instr>>8)&7U), (unsigned)(imm8*4U));
        return;
    case 13U:
        if ((instr & 0x0F00U) == 0x0000U) {
            xil_printf("ADD sp, #%c%u", (instr&0x80U)?'-':'+', (unsigned)((instr&0x7FU)*4U));
        } else if ((instr & 0x0F00U) >= 0x0600U) {
            xil_printf("%s {", (instr&0x0800U)?"POP":"PUSH");
            u32 list = instr & 0xFFU;
            u32 first = 1U;
            for (u32 i = 0U; i < 8U; i++) {
                if (list & (1U << i)) {
                    if (!first) xil_printf(",");
                    xil_printf("r%u", (unsigned)i);
                    first = 0U;
                }
            }
            if (instr & 0x0100U) { if (!first) xil_printf(","); xil_printf("%s", (instr&0x0800U)?"pc":"lr"); }
            xil_printf("}");
        } else {
            xil_printf("??? [0x%04x]", (unsigned)instr);
        }
        return;
    case 14U: case 15U:
        xil_printf("%s r%u!, {", (instr&0x0800U)?"LDMIA":"STMIA", (unsigned)((instr>>8)&7U));
        {
            u32 list = instr & 0xFFU;
            u32 first = 1U;
            for (u32 i = 0U; i < 8U; i++) {
                if (list & (1U << i)) {
                    if (!first) xil_printf(",");
                    xil_printf("r%u", (unsigned)i);
                    first = 0U;
                }
            }
        }
        xil_printf("}");
        return;
    default:
        xil_printf("??? [0x%04x]", (unsigned)instr);
        break;
    }
}

/* --- Public API --- */
u32 PsAppDiag_DisasmAtPc(u32 gba_pc, u32 num_lines) {
    u32 ps_base = gba_to_ps_addr(gba_pc);
    u32 offset  = gba_pc - ROM_GBA_BASE;

    if (ps_base == 0U || offset >= ROM_MAX_BYTES) {
        xil_printf("[DISASM] PC=0x%08x NOT IN ROM\r\n", (unsigned)gba_pc);
        return 0U;
    }
    if (num_lines == 0U || num_lines > 32U) num_lines = 16U;

    /* Determine alignment: walk back to nearest Thumb halfword */
    u32 start_ps = ps_base;
    u32 start_pc = gba_pc;

    /* Verify: read 2 words at start address to confirm mapping works */
    u32 probe0 = Xil_In32(start_ps);
    u32 probe1 = Xil_In32(start_ps + 4U);

    xil_printf("[DISASM] PC=0x%08x ROM+0x%x PS=0x%08x probe=%08x %08x\r\n",
        (unsigned)gba_pc, (unsigned)offset, (unsigned)start_ps,
        (unsigned)probe0, (unsigned)probe1);

    xil_printf("[DISASM]     (Thumb, 2-byte instrs)\r\n");

    for (u32 i = 0U; i < num_lines; i++) {
        u32 instr_pc = start_pc + i * 2U;
        u32 instr_ps = start_ps + i * 2U;
        u16 code = read_rom_u16(instr_ps);

        xil_printf("  0x%08x: %04x  ", (unsigned)instr_pc, (unsigned)code);

        /* Handle BL upper/lower pairs */
        if ((code >> 11) >= 28U) {
            u16 next = read_rom_u16(instr_ps + 2U);
            xil_printf("%04x  ", (unsigned)next);

            /* Compute BL target: sign-extend upper 11 bits + lower 11 bits */
            s32 off = (s32)(code & 0x7FFU);
            if (off & 0x400) off |= 0xFFFFF800;
            off <<= 12;
            s32 off2 = (s32)(next & 0x7FFU);
            if (off2 & 0x400) off2 |= 0xFFFFF800;
            u32 tgt = (u32)((s32)(instr_pc + 4U) + off + (off2 << 1));
            xil_printf("BL 0x%08X", (unsigned)tgt);
            i++; /* skip next */
        } else {
            xil_printf("     ");
            print_thumb_instr(code, instr_pc);
        }
        xil_printf("\r\n");
    }
    return num_lines;
}

void PsAppDiag_DisasmHangPcs(const u32 *pc_list, u32 pc_count) {
    u32 rom_pcs[32];
    u32 rom_cnt = 0U;
    const u32 kMinGap = 32U;

    if (pc_list == NULL || pc_count == 0U) return;

    for (u32 i = 0U; i < pc_count && rom_cnt < 30U; i++) {
        u32 pc = pc_list[i];
        if (pc < 0x08000000U || pc >= 0x0A000000U) continue;

        u32 dup = 0U;
        for (u32 j = 0U; j < rom_cnt; j++) {
            u32 d = (pc > rom_pcs[j]) ? (pc - rom_pcs[j]) : (rom_pcs[j] - pc);
            if (d < kMinGap) { dup = 1U; break; }
        }
        if (!dup) rom_pcs[rom_cnt++] = pc;
    }

    if (rom_cnt == 0U) return;

    xil_printf("\r\n[DISASM] === hang ROM code ===\r\n");
    for (u32 i = 0U; i < rom_cnt; i++) {
        PsAppDiag_DisasmAtPc(rom_pcs[i], 12U);
        xil_printf("\r\n");
    }
}

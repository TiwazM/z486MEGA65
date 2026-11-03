; ****************************************************************************
; z486 for MEGA65: bios_patch.asm's test in the QNICE emulator (bios_run.sh)
;
; For every file of T_FILES it sums the words as PC_ROM_LOAD does (two bytes
; per word, the first in the low byte; BPT_CLR, BPT_ADD), runs BIOS_PATCH and
; prints what it wrote (BPT_POKE: P <window> <word> <value>), the sums and its
; result; bios_test.py compares them with tools/bios_patch.py's.
; ****************************************************************************

#undef RAM_MONITOR
#define EAE_NO_WAIT
                .ORG    0x0000
#include "sysdef.asm"
                ABRA    TEST_MAIN, 1
#include "io_library.asm"
#include "string_library.asm"
#include "mem_library.asm"
#include "debug_library.asm"
#include "misc_library.asm"
#include "uart_library.asm"
#include "usb_keyboard_library.asm"
#include "vga_library.asm"
#include "math_library.asm"
#include "sd_library.asm"
#include "fat32_library.asm"
QMON$LAST_ADDR  HALT
QMON$WARMSTART  HALT
#include "bios_patch.asm"

; BPT_POKE: prints P <window> <word> <value>
BPT_POKE        INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    T_S_P, R8
                RSUB    IO$PUTS, 1
                MOVE    R0, R8
                RSUB    T_HEXSP, 1
                MOVE    R1, R8
                RSUB    T_HEXSP, 1
                MOVE    R2, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                DECRB
                RET

TEST_MAIN       AND     0x00FF, SR
                MOVE    VAR$STACK_START, SP
                MOVE    _SD$DEVICEHANDLE, R8
                MOVE    1, R9
                RSUB    FAT32$MOUNT_SD, 1
                CMP     0, R9
                RBRA    T_MOUNTED, Z
                MOVE    T_S_MNTERR, R8
                RSUB    IO$PUTS, 1
                MOVE    R9, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                HALT

T_MOUNTED       MOVE    T_FILES, R0
T_FILE          MOVE    @R0++, R1               ; R1: the path (0: the end)
                CMP     0, R1
                RBRA    T_END, Z
                MOVE    T_S_CASE, R8
                RSUB    IO$PUTS, 1
                MOVE    R1, R8
                RSUB    IO$PUTS, 1
                RSUB    IO$PUT_CRLF, 1

                MOVE    _SD$DEVICEHANDLE, R8
                MOVE    T_FDH, R9
                MOVE    R1, R10
                XOR     R11, R11
                RSUB    FAT32$FILE_OPEN, 1
                CMP     0, R10
                RBRA    T_OPENOK, Z
                MOVE    T_S_OPENERR, R8
                RSUB    IO$PUTS, 1
                MOVE    R10, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                RBRA    T_FILE, 1

T_OPENOK        RSUB    BPT_CLR, 1
T_RD            MOVE    T_FDH, R8
                RSUB    FAT32$FILE_RB, 1        ; R9: the low byte
                CMP     FAT32$EOF, R10
                RBRA    T_SUMS, Z
                MOVE    R9, R2
                MOVE    T_FDH, R8
                RSUB    FAT32$FILE_RB, 1        ; R9: the high byte
                CMP     FAT32$EOF, R10          ; odd size: 0
                RBRA    T_ADD, Z
                SWAP    R9, R9
                OR      R9, R2
T_ADD           MOVE    R2, R8
                RSUB    BPT_ADD, 1
                CMP     FAT32$EOF, R10
                RBRA    T_RD, !Z

T_SUMS          MOVE    0x5A5A, R9              ; (R9, R10 must come back)
                MOVE    0xA5A5, R10
                MOVE    T_FDH, R8
                RSUB    BIOS_PATCH, 1
                MOVE    R8, R3
                MOVE    T_S_S, R8               ; S <s1> <s2>
                RSUB    IO$PUTS, 1
                MOVE    BPT_SUM, R4
                MOVE    @R4++, R8
                RSUB    T_HEXSP, 1
                MOVE    @R4, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                MOVE    T_S_RES, R8             ; R <result> <r9> <r10>
                RSUB    IO$PUTS, 1
                MOVE    R3, R8
                RSUB    T_HEXSP, 1
                MOVE    R9, R8
                RSUB    T_HEXSP, 1
                MOVE    R10, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                RBRA    T_FILE, 1

T_END           MOVE    T_S_END, R8
                RSUB    IO$PUTS, 1
                RSUB    IO$PUT_CRLF, 1
                HALT

T_HEXSP         RSUB    IO$PUT_W_HEX, 1
                MOVE    T_S_SP, R8
                RSUB    IO$PUTS, 1
                RET

T_S_MNTERR      .ASCII_W "MOUNT ERROR "
T_S_OPENERR     .ASCII_W "OPEN ERROR "
T_S_CASE        .ASCII_W "CASE "
T_S_P           .ASCII_W "P "
T_S_S           .ASCII_W "S "
T_S_RES         .ASCII_W "R "
T_S_SP          .ASCII_W " "
T_S_END         .ASCII_W "END"

T_FILES         .DW     T_F1, T_F2, T_F3, T_F4, 0
T_F1            .ASCII_W "/Z486/BOOT0.ROM"
T_F2            .ASCII_W "/Z486/OTHER.ROM"
T_F3            .ASCII_W "/Z486/SHORT.ROM"
T_F4            .ASCII_W "/Z486/LONG.ROM"

                .ORG    0xC000
T_FDH           .BLOCK  FAT32$FDH_STRUCT_SIZE
BPT_SUM         .BLOCK  2
#include "variables.asm"

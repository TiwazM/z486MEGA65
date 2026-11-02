; ****************************************************************************
; z486 for MEGA65: cdimage.asm's test in the QNICE emulator (run.sh)
;
; For every case of cases.inc (a folder and a file on the SD image) it opens
; the file in its folder, runs CD_PREP and prints its result, then the track
; table and the extent map; check.py compares them with its own layout.
; The table, the cue text and the map are RAM here (CDI_SEL).
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
#include "cdimage.asm"

T_TAB           .EQU    0x8000                  ; the windows: table,
T_SCR0          .EQU    0x9000                  ; the cue text,
T_SCR1          .EQU    0xA000
T_MAP           .EQU    0xB000                  ; unit 3's map (2K words),
T_STG           .EQU    0xB800                  ; its staging copy (2K words)

; CDI_SEL: R8 = 0..4 -> R8 = the window's address
CDI_SEL         CMP     0, R8
                RBRA    _TS_1, !Z
                MOVE    T_TAB, R8
                RET
_TS_1           CMP     1, R8
                RBRA    _TS_2, !Z
                MOVE    T_SCR0, R8
                RET
_TS_2           CMP     2, R8
                RBRA    _TS_3, !Z
                MOVE    T_SCR1, R8
                RET
_TS_3           CMP     3, R8
                RBRA    _TS_4, !Z
                MOVE    T_STG, R8
                RET
_TS_4           MOVE    T_MAP, R8
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

T_MOUNTED       MOVE    T_CASES, R0
T_CASE          MOVE    @R0++, R1               ; R1: the folder (0: the end)
                CMP     0, R1
                RBRA    T_END, Z
                MOVE    @R0++, R2               ; R2: the file

                ; the windows cleared
                MOVE    T_TAB, R4
                MOVE    0x4000, R5
T_CLR           MOVE    0, @R4++
                SUB     1, R5
                RBRA    T_CLR, !Z

                MOVE    T_S_CASE, R8
                RSUB    IO$PUTS, 1
                MOVE    R2, R8
                RSUB    IO$PUTS, 1
                RSUB    IO$PUT_CRLF, 1

                MOVE    _SD$DEVICEHANDLE, R8
                MOVE    R1, R9
                XOR     R10, R10
                RSUB    FAT32$CD, 1
                CMP     0, R9
                RBRA    T_CDOK, Z
                MOVE    T_S_CDERR, R8
                RSUB    IO$PUTS, 1
                MOVE    R9, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                RBRA    T_CASE, 1
T_CDOK          MOVE    _SD$DEVICEHANDLE, R8
                MOVE    T_FDH, R9
                MOVE    R2, R10
                XOR     R11, R11
                RSUB    FAT32$FILE_OPEN, 1
                CMP     0, R10
                RBRA    T_OPENOK, Z
                MOVE    T_S_OPENERR, R8
                RSUB    IO$PUTS, 1
                MOVE    R10, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
                RBRA    T_CASE, 1

T_OPENOK        MOVE    0x5A5A, R11             ; (R11, R12 must come back)
                MOVE    0xA5A5, R12
                MOVE    T_FDH, R8
                RSUB    CD_PREP, 1
                MOVE    R8, R4
                MOVE    R9, R5
                MOVE    R10, R6
                MOVE    T_S_RES, R8             ; R <code> <sects lo> <sects hi> <r11> <r12>
                RSUB    IO$PUTS, 1
                MOVE    R4, R8
                RSUB    T_HEXSP, 1
                MOVE    R5, R8
                RSUB    T_HEXSP, 1
                MOVE    R6, R8
                RSUB    T_HEXSP, 1
                MOVE    R11, R8
                RSUB    T_HEXSP, 1
                MOVE    R12, R8
                RSUB    T_HEXSP, 1
                RSUB    IO$PUT_CRLF, 1
                CMP     0, R4
                RBRA    T_CASE, !Z

                ; H: the header's 7 words
                MOVE    T_S_H, R8
                MOVE    T_TAB, R9
                MOVE    7, R10
                RSUB    T_LINE, 1
                ; E: the tracks
                MOVE    T_TAB, R4
                MOVE    @R4, R5                 ; R5: N
                MOVE    T_TAB, R6
                ADD     CDT_ENT, R6
                MOVE    R5, R7
T_ENT           CMP     0, R7
                RBRA    T_TOC, Z
                MOVE    T_S_E, R8
                MOVE    R6, R9
                MOVE    16, R10
                RSUB    T_LINE, 1
                ADD     16, R6
                SUB     1, R7
                RBRA    T_ENT, 1
                ; L, M: the descriptors, N + 1 each
T_TOC           MOVE    T_TAB, R6
                ADD     CDT_TOC_LBA, R6
                MOVE    R5, R7
                ADD     1, R7
T_TOCL          MOVE    T_S_L, R8
                MOVE    R6, R9
                MOVE    4, R10
                RSUB    T_LINE, 1
                ADD     4, R6
                SUB     1, R7
                RBRA    T_TOCL, !Z
                MOVE    T_TAB, R6
                ADD     CDT_TOC_MSF, R6
                MOVE    R5, R7
                ADD     1, R7
T_TOCM          MOVE    T_S_M, R8
                MOVE    R6, R9
                MOVE    4, R10
                RSUB    T_LINE, 1
                ADD     4, R6
                SUB     1, R7
                RBRA    T_TOCM, !Z
                ; X: the map's extents
                MOVE    T_MAP, R6
                MOVE    @R6++, R7
                MOVE    T_S_XN, R8
                RSUB    IO$PUTS, 1
                MOVE    R7, R8
                RSUB    T_HEXSP, 1
                RSUB    IO$PUT_CRLF, 1
T_MAPL          CMP     0, R7
                RBRA    T_CASE, Z
                MOVE    T_S_X, R8
                MOVE    R6, R9
                MOVE    4, R10
                RSUB    T_LINE, 1
                ADD     4, R6
                SUB     1, R7
                RBRA    T_MAPL, 1

T_END           MOVE    T_S_END, R8
                RSUB    IO$PUTS, 1
                RSUB    IO$PUT_CRLF, 1
                HALT

; T_LINE: the string R8, then R10 words from R9, then a line end
T_LINE          INCRB
                MOVE    R9, R0
                MOVE    R10, R1
                RSUB    IO$PUTS, 1
_TL_LOOP        MOVE    @R0++, R8
                RSUB    T_HEXSP, 1
                SUB     1, R1
                RBRA    _TL_LOOP, !Z
                RSUB    IO$PUT_CRLF, 1
                DECRB
                RET

T_HEXSP         RSUB    IO$PUT_W_HEX, 1
                MOVE    T_S_SP, R8
                RSUB    IO$PUTS, 1
                RET

T_S_MNTERR      .ASCII_W "MOUNT ERROR "
T_S_CDERR       .ASCII_W "CD ERROR "
T_S_OPENERR     .ASCII_W "OPEN ERROR "
T_S_CASE        .ASCII_W "CASE "
T_S_RES         .ASCII_W "R "
T_S_H           .ASCII_W "H "
T_S_E           .ASCII_W "E "
T_S_L           .ASCII_W "L "
T_S_M           .ASCII_W "M "
T_S_XN          .ASCII_W "XN "
T_S_X           .ASCII_W "X "
T_S_SP          .ASCII_W " "
T_S_END         .ASCII_W "END"

#include "cases.inc"

                .ORG    0xC000
T_FDH           .BLOCK  FAT32$FDH_STRUCT_SIZE
#include "cdimage_vars.asm"
#include "variables.asm"

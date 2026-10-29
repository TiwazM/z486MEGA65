; ****************************************************************************
; z486 for MEGA65
;
; QNICE firmware (the M2M "Shell" plus the core's callbacks)
;
; The Shell does almost everything: SD cards, the settings file, the menu. The
; callbacks below are the ones the Megamiga fork's Shell needs: the M2M
; template's plus HANDLE_CORE_IO (core-io-hook), BROWSE_EXTRA (cfg-strings),
; FAR_CALL (code-banks) and CFG_SIGCHECK / CFG_SIGSET (the settings file
; signature). No ROMs, drives or devices yet: they come with the boot image,
; the IDE/floppy bridge and the keyboard.
;
; Based on the MiSTer2MEGA65 template (sy2002 and MJoergen) and pc10-iii's
; firmware (Johan Smolinski); licensed under GPL v3
; ****************************************************************************

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

#include "../../M2M/rom/main.asm"
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific constants
; ----------------------------------------------------------------------------

#include "osm_const.asm"

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
;
; SUBMENU_SUMMARY: R8 = 0 = the standard semantics (the selected item of the
; submenu's first group replaces the %s).
; ----------------------------------------------------------------------------

SUBMENU_SUMMARY XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and image mounting (none)
; ----------------------------------------------------------------------------

; FILTER_FILES: R8 = 0 = show every file
FILTER_FILES    XOR     R8, R8
                RET

; PREP_LOAD_IMAGE: nothing to prepare.
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE XOR     R8, R8
                XOR     R9, R9
                RET

; BROWSE_EXTRA (M2M-UPSTREAM cfg-strings): no browser entries that are no
; files. Output R8 = 0; R10..R12 preserved.
BROWSE_EXTRA    XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Core startup
;
; PREP_START is called after the ROMs were auto-loaded and before the Shell
; releases the core's reset. Nothing to check yet.
;
; Output: R8: 0 = OK, else pointer to the error message (fatal)
;         R9: 0 = OK, else error code
; ----------------------------------------------------------------------------

PREP_START      XOR     R8, R8
                XOR     R9, R9
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: OSM selections
;
; OSM_SEL_PRE / OSM_SEL_POST: R8 = the selected group, R9 = the selected item
; (single-select: 1 = selected), R10 = the key. Output R8/R9: 0 = OK.
;
; "Reset the PC" is momentary: OSM_SEL_POST resets the core through the CSR
; and unselects the item again (pc10-iii's way).
; ----------------------------------------------------------------------------

OSM_SEL_PRE     XOR     R8, R8
                XOR     R9, R9
                RET

OSM_SEL_POST    INCRB
                CMP     PC_OPTM_G_RESET, R8
                RBRA    _OSP_RET, !Z

                MOVE    M2M$CSR, R0             ; reset the core..
                OR      M2M$CSR_RESET, @R0
                MOVE    0x2000, R1              ; ..for about a millisecond
_OSP_WAIT       SUB     1, R1
                RBRA    _OSP_WAIT, !Z
                AND     M2M$CSR_UN_RESET, @R0

                MOVE    OPTM_CUR_SEL, R8        ; momentary: unselect again
                MOVE    @R8, R8
                XOR     R9, R9
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1

_OSP_RET        XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages, background work, the
; settings file
; ----------------------------------------------------------------------------

; CUSTOM_MSG: R8 = 0 = no custom message
CUSTOM_MSG      XOR     R8, R8
                RET

; HANDLE_CORE_IO (M2M-UPSTREAM core-io-hook): the Shell's time slice for
; background work. Must preserve all registers. Nothing yet.
HANDLE_CORE_IO  RET

; FAR_CALL (M2M-UPSTREAM code-banks): call a routine in a code bank through
; its stub (two words: the bank, the address). No banks yet; kept because
; cfgstr.asm references it.
FAR_CALL        INCRB
                MOVE    @SP++, R0               ; R0: the two words of the stub
                MOVE    M2M$CODE_BANK, R3
                MOVE    @R3, R4                 ; R4: the bank of the caller
                MOVE    @R0++, @R3              ; select the bank
                MOVE    @R0, R0
                ASUB    R0, 1
                MOVE    R4, @R3                 ; the caller's bank again
                DECRB
                RET

; CFG_SIGCHECK (M2M-UPSTREAM cfg-strings): C=1 = the settings file R8 (open,
; its text loaded by CFGS_LOAD) belongs to this menu: its text has the line
; "menu=" CFG_SIG_VAL. For C=0 the Shell uses the defaults and calls
; CFG_SIGSET, and the next save writes the file in this layout. Bytes of a
; longer, older menu (0 or 1) in front of the text are dropped first.
; Registers preserved. (pc10-iii's routine, unchanged.)
CFG_SIGCHECK    SYSCALL(enter, 1)
                MOVE    CFGS_LEN, R3            ; R2: characters left
                MOVE    @R3, R2
                MOVE    CFGS_BUF, R0
                MOVE    R0, R1                  ; R1: the first character
_CFGSC_SK       CMP     0, R2                   ; that is not a menu byte
                RBRA    _CFGSC_MV, Z
                CMP     @R1, 1
                RBRA    _CFGSC_MV, N            ; (above 1)
                ADD     1, R1
                SUB     1, R2
                RBRA    _CFGSC_SK, 1
_CFGSC_MV       MOVE    R2, @R3                 ; the text to the front,
_CFGSC_M1       MOVE    @R1++, @R0++            ; with its zero
                SUB     1, R2
                RBRA    _CFGSC_M1, !N
                SUB     4, SP                   ; SP: the file's value
                MOVE    CFG_SIG_KEY, R8
                MOVE    SP, R9
                MOVE    4, R10
                RSUB    CFGS_GET, 1
                MOVE    SP, R8
                MOVE    CFG_SIG_VAL, R9
                SYSCALL(strcmp, 1)
                ADD     4, SP
                CMP     0, R10
                RBRA    _CFGSC_OK, Z
                SYSCALL(leave, 1)
                AND     0xFFFB, SR              ; C=0
                RET
_CFGSC_OK       SYSCALL(leave, 1)
                OR      0x0004, SR              ; C=1
                RET

; CFG_SIGSET: a new (or reset) settings file: its text gets this menu's
; signature (CFGS_DIRTY: the next save writes it). Registers preserved.
CFG_SIGSET      SYSCALL(enter, 1)
                MOVE    CFG_SIG_KEY, R8
                MOVE    CFG_SIG_VAL, R9
                RSUB    CFGS_SET, 1
                SYSCALL(leave, 1)
                RET

; The menu's layout version (config.vhd): change it with every change of the
; menu lines. At most 3 characters (CFG_SIGCHECK's buffer).
CFG_SIG_KEY     .ASCII_W "menu"
CFG_SIG_VAL     .ASCII_W "1"

; ----------------------------------------------------------------------------
; The FAT32 write layer, flat (the Shell creates and resizes the settings
; file with it)
; ----------------------------------------------------------------------------

#include "../../M2M/QNICE/monitor/fat32_wglue.asm"
#include "../../M2M/QNICE/monitor/fat32_write.asm"
#include "../../M2M/QNICE/monitor/fat32_wfile.asm"

; ----------------------------------------------------------------------------
; END_OF_ROM must stay the last ROM item (make_rom.sh checks it)
; ----------------------------------------------------------------------------

END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0xA000                  ; RAM starts at 0xA000: the 4k device
                                                ; window takes 0x8000-0x8FFF (M2M-UPSTREAM
                                                ; rom-32k), the code window 0x9000-0x9FFF
                                                ; (code-banks)
#endif

#include "../../M2M/rom/shell_vars.asm"

; The menu heap (Megamiga hard rule 11): the menu structure plus OPTM_HEAP;
; for this 14-line menu: 20 + 167 item characters + 1 + 4 x 14 + 1 + (1
; submenu + 1) x 30 = 305 words; the Shell checks it at boot
; (ERR_FATAL_HEAP1/2). The rest of the heap is the file browser's.
MENU_HEAP_SIZE  .EQU 512

#ifndef RELEASE
HEAP_SIZE       .EQU 0
HEAP            .BLOCK 1
#else
; HEAP + MENU_HEAP_SIZE + HEAP_SIZE must stay below VAR$STACK_START -
; STACK_SIZE (check HEAP and VAR$STACK_START in m2m-rom.lis)
HEAP_SIZE       .EQU 19296
HEAP            .BLOCK 1

                .ORG    0xFED0                  ; as Megamiga: the FAT32 write layer's
                                                ; larger device handle (main_vars.asm)
#endif

STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"

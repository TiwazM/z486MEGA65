; ****************************************************************************
; z486 for MEGA65
;
; QNICE firmware (the M2M "Shell" plus the core's callbacks)
;
; The Shell does almost everything: SD cards, the settings file, the menu. The
; callbacks below are the ones the Megamiga fork's Shell needs: the M2M
; template's plus HANDLE_CORE_IO (core-io-hook), BROWSE_EXTRA (cfg-strings),
; FAR_CALL (code-banks) and CFG_SIGCHECK / CFG_SIGSET (the settings file
; signature). PREP_START loads the PC's BIOS ROMs and mounts the floppy image
; /z486/floppy.img, if there is one; the menu's "Floppy A:" line mounts others
; (PREP_LOAD_IMAGE, FDD_PREP).
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
; Core specific callback functions: File browsing and image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES: R8 = 0 = show every file
FILTER_FILES    XOR     R8, R8
                RET

; PREP_LOAD_IMAGE: R8 = file handle, R9 = context, R10 = the menu line's group.
; The only manual load is the "Floppy A:" line: FDD_PREP mounts the image and
; the Shell streams nothing into the device.
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE RSUB    FDD_PREP, 1
                RET

; ----------------------------------------------------------------------------
; Floppy drive A: (fdd_sd.vhd): the image file is read and written in place
; through the SD host controller's engine port; its extent map tells the
; hardware where the sectors are (Megamac's DISK_PREP, for a floppy).
;
; FDD_PREP: mount the image file R8 (an open handle) as drive A:
;   1. its size must be a standard floppy's (FDD_SIZES): the geometry;
;   2. drive A: goes away (MODE 0) while it changes;
;   3. the file's extent map into window 1 (FAT32$FILE_MAP: up to 511
;      extents, so fragmented files are fine);
;   4. sectors, the cluster base (DEV_CLUSTER - (2 << shift)), shift and
;      geometry, then MODE (mounted, the card's slot) last: pc_mgmt.vhd then
;      inserts the disk;
;   5. the handle to its end: the Shell's manual load streams nothing.
; Output: R8 = 0 (OK) or an error code with R9 = the message; R10..R12 kept.
; ----------------------------------------------------------------------------

FDD_E_SIZE      .EQU    0x00F1
FDD_E_FRAG      .EQU    0x00F2

FDD_PREP        INCRB
                MOVE    R10, @--SP
                MOVE    R11, @--SP
                MOVE    R12, @--SP
                MOVE    R8, R0                  ; R0: the handle

                ; 1. the size: one of FDD_SIZES
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R2                 ; R2: size hi
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                MOVE    @R1, R3                 ; R3: size lo
                MOVE    FDD_SIZES, R4
_FP_SIZE        MOVE    @R4, R5                 ; R5: sectors (0: the end)
                RBRA    _FP_BADSZ, Z
                MOVE    R4, R6
                ADD     1, R6
                CMP     @R6++, R2
                RBRA    _FP_NEXT, !Z
                CMP     @R6++, R3
                RBRA    _FP_FOUND, Z            ; R6: cylinders, sectors/track
_FP_NEXT        ADD     5, R4
                RBRA    _FP_SIZE, 1

                ; 2. drive A: away while it changes
_FP_FOUND       MOVE    M2M$RAMROM_DEV, R1
                MOVE    PC_DEV_FDD, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                MOVE    M2M$RAMROM_DATA, R7     ; R7: the registers (window 0)
                MOVE    0, @R7                  ; MODE: no image

                ; 3. the extent map into window 1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    1, @R1
                MOVE    R0, R8
                MOVE    M2M$RAMROM_DATA, R9
                MOVE    2048, R10
                RSUB    FAT32$FILE_MAP, 1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                CMP     0, R9
                RBRA    _FP_MAPOK, Z
                CMP     FAT32$ERR_MAPSIZE, R9
                RBRA    _FP_FRAG, Z
                MOVE    R9, R8                  ; another FAT32 error: its code
                MOVE    ERR_FDD_FAT, R9
                RBRA    _FP_RET, 1

                ; 4. shift = log2(sectors per cluster), base, geometry, mode
_FP_MAPOK       MOVE    @R0, R4                 ; R4: the device (FDH_DEVICE = 0)
                MOVE    R4, R1
                ADD     FAT32$DEV_SECT_PER_CLUS, R1
                MOVE    @R1, R1                 ; R1: sectors per cluster
                XOR     R3, R3                  ; R3: the shift
_FP_SHL         CMP     R1, 1
                RBRA    _FP_SHD, !N             ; R1 <= 1: done
                AND     0xFFFB, SR
                SHR     1, R1
                ADD     1, R3
                RBRA    _FP_SHL, 1
_FP_SHD         MOVE    2, R2
                AND     0xFFFD, SR
                SHL     R3, R2                  ; R2: 2 << shift
                MOVE    R4, R1
                ADD     FAT32$DEV_CLUSTER_LO, R1
                MOVE    @R1++, R10              ; R11:R10 = DEV_CLUSTER
                MOVE    @R1, R11
                SUB     R2, R10
                SUBC    0, R11
                MOVE    R4, R8                  ; the card the file is on
                RSUB    SDC$SLOT, 1             ; R8: its slot
                AND     0xFFFD, SR
                SHL     1, R8
                OR      1, R8                   ; R8: MODE = mounted, the slot
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    PC_DEV_FDD, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                MOVE    R7, R1
                ADD     1, R1
                MOVE    R5, @R1++               ; 1 SECTS lo
                MOVE    0, @R1++                ; 2 SECTS hi
                MOVE    R10, @R1++              ; 3 BASE lo
                MOVE    R11, @R1++              ; 4 BASE hi
                MOVE    R3, @R1++               ; 5 SHIFT
                MOVE    @R6++, @R1++            ; 6 cylinders
                MOVE    @R6, @R1++              ; 7 sectors per track
                MOVE    2, @R1                  ; 8 heads
                MOVE    R8, @R7                 ; MODE last

                ; 5. the handle to its end
                MOVE    R0, R8
                MOVE    R0, R9
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9
                MOVE    R0, R10
                ADD     FAT32$FDH_SIZE_HI, R10
                MOVE    @R10, R10
                RSUB    FAT32$FILE_SEEK, 1
                CMP     0, R9
                RBRA    _FP_OK, Z
                MOVE    R9, R8
                MOVE    ERR_FDD_FAT, R9
                RBRA    _FP_RET, 1

_FP_OK          XOR     R8, R8
                XOR     R9, R9
                RBRA    _FP_RET, 1
_FP_BADSZ       MOVE    FDD_E_SIZE, R8
                MOVE    ERR_FDD_SIZE, R9
                RBRA    _FP_RET, 1
_FP_FRAG        MOVE    FDD_E_FRAG, R8
                MOVE    ERR_FDD_FRAG, R9
_FP_RET         MOVE    @SP++, R12
                MOVE    @SP++, R11
                MOVE    @SP++, R10
                DECRB
                RET

; The floppy sizes: sectors, size in bytes (hi, lo), cylinders, sectors per
; track (all with two heads); sectors 0 ends the table
FDD_SIZES       .DW     720,  0x0005, 0xA000, 40, 9      ; 360 KB
                .DW     1440, 0x000B, 0x4000, 80, 9      ; 720 KB
                .DW     2400, 0x0012, 0xC000, 80, 15     ; 1.2 MB
                .DW     2880, 0x0016, 0x8000, 80, 18     ; 1.44 MB
                .DW     5760, 0x002D, 0x0000, 80, 36     ; 2.88 MB
                .DW     0

ERR_FDD_SIZE    .ASCII_P "Not a floppy image: it\n"
                .ASCII_W "must be 360K, 720K,\n1.2M, 1.44M or 2.88M.\n"
ERR_FDD_FRAG    .ASCII_W "The image file has too\nmany fragments.\n"
ERR_FDD_FAT     .ASCII_W "Cannot read the image\nfile (FAT32 error).\n"
FDD_AUTO        .ASCII_W "/z486/floppy.img"

; FDD_AUTO_NAME: the "Floppy A:" line shows the auto-mounted image like a
; manual load (Megamac's DISK_AUTO_NAME): CRTROM_MAN_LDF[0] = 1 and the file
; name after the last '/' in the line's OPTM_HEAP buffer ((vdrives + submenus
; + 0) * OSM_O_DX), at most the width - 2 characters, one more for the
; ellipsis, the "%s is replaced" flag in the buffer's last word = 0. R8 = the
; path. Registers preserved.
FDD_AUTO_NAME   SYSCALL(enter, 1)
                MOVE    R8, R0                  ; R0: the path
                MOVE    OPTM_HEAP, R4
                MOVE    @R4, R4                 ; R4: the heap (0: no menu yet)
                RBRA    _FAN_RET, Z
                MOVE    CRTROM_MAN_LDF, R5
                MOVE    1, @R5                  ; manual load 0: loaded
                MOVE    R0, R5                  ; R5: the name = after the last '/'
                MOVE    R0, R6
_FAN_BN         CMP     0, @R6
                RBRA    _FAN_BN1, Z
                CMP     0x002F, @R6             ; '/'
                RBRA    _FAN_BN2, !Z
                MOVE    R6, R5
                ADD     1, R5
_FAN_BN2        ADD     1, R6
                RBRA    _FAN_BN, 1
_FAN_BN1        MOVE    VDRIVES_NUM, R8
                MOVE    @R8, R8
                MOVE    OPTM_SCOUNT, R9
                ADD     @R9, R8                 ; vdrives + submenus
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9                 ; R9: the line's width
                SYSCALL(mulu, 1)                ; R10: the buffer's offset
                ADD     R10, R4                 ; R4: the line's buffer
                MOVE    R9, R6
                SUB     2, R6                   ; R6: the longest name
                MOVE    R5, R8
                SYSCALL(strlen, 1)              ; R9: the name's length
                CMP     R9, R6                  ; longer than the frame?
                RBRA    _FAN_LONG, N            ; yes
                MOVE    R5, R8
                MOVE    R4, R9
                SYSCALL(strcpy, 1)
                RBRA    _FAN_FLAG, 1
_FAN_LONG       MOVE    R5, R8                  ; the longest + 1: the ellipsis
                MOVE    R4, R9
                MOVE    R6, R10
                ADD     1, R10
                SYSCALL(memcpy, 1)
                ADD     R10, R9
                MOVE    0, @R9
_FAN_FLAG       MOVE    SCR$OSM_O_DX, R8        ; "%s is replaced" = 0
                MOVE    @R8, R8
                SUB     1, R8
                ADD     R4, R8
                MOVE    0, @R8
_FAN_RET        SYSCALL(leave, 1)
                RET

; BROWSE_EXTRA (M2M-UPSTREAM cfg-strings): no browser entries that are no
; files. Output R8 = 0; R10..R12 preserved.
BROWSE_EXTRA    XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Core startup
;
; PREP_START is called after the Shell's reset management, before it connects
; keyboard and joysticks. It loads the PC's BIOS ROMs. z486's boot loader
; copies the ROM window 0xC0000..0xFFFFF (256 KB) from its DDR3 window into
; the SDRAM the moment the PC leaves reset (on MiSTer, Main_MiSTer stages the
; ROMs there). Here that window is HyperRAM 0x2C0000 (globals.vhd,
; mega65.vhd), and the PC stays in reset until PC_DEV_CTL says the ROMs are
; in:
;
;   /z486/boot1.rom  the VGA BIOS     at 0xC0000
;   /z486/boot0.rom  the system BIOS  at 0xF0000 (0xE0000 above 64 KB)
;
; from the SD card of the settings file. The window is cleared first: the PC
; copies all of it, and the BIOS scans the rest for option ROMs.
;
; Output: R8: 0 = OK, else pointer to the error message (fatal)
;         R9: 0 = OK, else error code
; ----------------------------------------------------------------------------

PC_ROM_WIN      .EQU    0x0160                  ; HyperRAM 0x2C0000 = 0xC0000
PC_ROM_WINS     .EQU    0x0020                  ; 32 4K word windows: 256 KB
PC_BIOS_WIN     .EQU    0x0178                  ; 0xF0000
PC_BIOS128_WIN  .EQU    0x0170                  ; 0xE0000

PREP_START      INCRB
                MOVE    R10, R0                 ; R10..R12 preserved
                MOVE    R11, R1
                MOVE    R12, R2

                ; clear the window
                MOVE    PC_ROM_WIN, R3          ; R3: 4K window
                MOVE    PC_ROM_WINS, R4         ; R4: windows left
_PCS_CLR1       MOVE    M2M$RAMROM_DEV, R5
                MOVE    M2M$HYPERRAM, @R5
                MOVE    M2M$RAMROM_4KWIN, R5
                MOVE    R3, @R5
                MOVE    M2M$RAMROM_DATA, R5
                MOVE    0x1000, R6
_PCS_CLR2       MOVE    0, @R5++
                SUB     1, R6
                RBRA    _PCS_CLR2, !Z
                ADD     1, R3
                SUB     1, R4
                RBRA    _PCS_CLR1, !Z

                ; the SD card
                RSUB    WAIT_FOR_SD, 1          ; stability workaround
                RSUB    SDC$HOMEDEV, 1          ; R8: device handle
                CMP     0, R9                   ; R9: error code
                RBRA    _PCS_VGA, Z
                MOVE    ERR_PC_NOSD, R8
                RBRA    _PCS_RET, 1

                ; the VGA BIOS from 0xC0000 (at most 128 KB), the system BIOS
                ; up to 0xFFFFF
_PCS_VGA        MOVE    R8, R7                  ; R7: device handle
                MOVE    ERR_PC_BOOT1, R9
                MOVE    PC_BOOT1, R10
                MOVE    PC_ROM_WIN, R11
                MOVE    PC_ROM_WIN, R12
                RSUB    PC_ROM_LOAD, 1
                RBRA    _PCS_RET, C
                MOVE    R7, R8
                MOVE    ERR_PC_BOOT0, R9
                MOVE    PC_BOOT0, R10
                MOVE    PC_BIOS_WIN, R11
                MOVE    PC_BIOS128_WIN, R12
                RSUB    PC_ROM_LOAD, 1
                RBRA    _PCS_RET, C

                ; floppy drive A: /z486/floppy.img, if it is there (then
                ; 150 ms, so that pc_mgmt.vhd has inserted it, 100 ms after
                ; the eject, before the BIOS looks for drives)
                MOVE    R7, R8
                MOVE    PC_ROM_FILE, R9
                MOVE    FDD_AUTO, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _PCS_GO, !Z             ; not there: no floppy
                MOVE    PC_ROM_FILE, R8
                RSUB    FDD_PREP, 1
                CMP     0, R8
                RBRA    _PCS_GO, !Z             ; not a floppy: no floppy
                MOVE    FDD_AUTO, R8
                RSUB    FDD_AUTO_NAME, 1
                MOVE    150, R3                 ; 150 x about 1 ms
_PCS_FDW1       MOVE    0x2000, R4              ; (OSM_SEL_POST's 1 ms loop)
_PCS_FDW2       SUB     1, R4
                RBRA    _PCS_FDW2, !Z
                SUB     1, R3
                RBRA    _PCS_FDW1, !Z

                ; the PC may leave reset
_PCS_GO         MOVE    M2M$RAMROM_DEV, R8
                MOVE    PC_DEV_CTL, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    0, @R8
                MOVE    M2M$RAMROM_DATA, R8
                MOVE    1, @R8
                XOR     R8, R8
                XOR     R9, R9

_PCS_RET        MOVE    R0, R10
                MOVE    R1, R11
                MOVE    R2, R12
                DECRB
                RET

; PC_ROM_LOAD: loads the file R10 (its path) from the device R8 into HyperRAM:
; from 4K window R11 if it has at most 64 KB, from R12 if it has up to 128 KB.
; Two bytes per word, the first one in the low byte: z486 reads the window as
; little-endian 64-bit words. Output: C=0: loaded; C=1: R8 = R9 (the message
; for the error), R9 = the error code (FAT32's; 0: larger than 128 KB).
; R10..R12 preserved.
PC_ROM_LOAD     INCRB
                MOVE    R9, R0                  ; R0: the message
                MOVE    R10, R1                 ; R1..R3: preserved
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    PC_ROM_FILE, R9
                XOR     R11, R11                ; / separates the path
                SYSCALL(f32_fopen, 1)
                CMP     0, R10                  ; R10: error code
                RBRA    _PRL_ERR, !Z

                ; the size in 64 KB, rounded up, chooses the window
                MOVE    PC_ROM_FILE, R4
                ADD     FAT32$FDH_SIZE_HI, R4
                MOVE    @R4, R4                 ; R4: 64 KB units
                MOVE    PC_ROM_FILE, R5
                ADD     FAT32$FDH_SIZE_LO, R5
                CMP     0, @R5
                RBRA    _PRL_1, Z
                ADD     1, R4
_PRL_1          MOVE    R2, R6                  ; R6: 4K window
                CMP     R4, 1                   ; above 64 KB?
                RBRA    _PRL_2, !N              ; no
                MOVE    R3, R6
                CMP     R4, 2                   ; above 128 KB?
                RBRA    _PRL_2, !N              ; no
                XOR     R10, R10
                RBRA    _PRL_ERR, 1

_PRL_2          MOVE    M2M$RAMROM_DATA, R5     ; R5: target address
                MOVE    M2M$RAMROM_DATA, R7
                ADD     0x1000, R7              ; R7: end of the 4K window
_PRL_RD         MOVE    PC_ROM_FILE, R8
                SYSCALL(f32_fread, 1)           ; R9: the low byte
                CMP     FAT32$EOF, R10
                RBRA    _PRL_OK, Z
                CMP     0, R10
                RBRA    _PRL_ERR, !Z
                MOVE    R9, R4                  ; R4: the word
                MOVE    PC_ROM_FILE, R8
                SYSCALL(f32_fread, 1)           ; R9: the high byte
                CMP     FAT32$EOF, R10          ; odd size: 0
                RBRA    _PRL_WR, Z
                CMP     0, R10
                RBRA    _PRL_ERR, !Z
                SWAP    R9, R9
                OR      R9, R4
_PRL_WR         MOVE    M2M$RAMROM_DEV, R8      ; (the FAT32 routines use
                MOVE    M2M$HYPERRAM, @R8       ; devices of their own)
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    R6, @R8
                MOVE    R4, @R5++
                CMP     R5, R7                  ; end of the window?
                RBRA    _PRL_RD, !Z
                MOVE    M2M$RAMROM_DATA, R5     ; yes: the next one
                ADD     1, R6
                RBRA    _PRL_RD, 1

_PRL_OK         MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                AND     0xFFFB, SR              ; C=0
                RET

_PRL_ERR        MOVE    R0, R8
                MOVE    R10, R9
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                OR      0x0004, SR              ; C=1
                RET

PC_BOOT1        .ASCII_W "/z486/boot1.rom"
PC_BOOT0        .ASCII_W "/z486/boot0.rom"

ERR_PC_NOSD     .ASCII_P "z486 loads its BIOS from /z486 on\n"
                .ASCII_W "the SD card, but cannot mount one.\n"
ERR_PC_BOOT1    .ASCII_P "Cannot load the VGA BIOS\n"
                .ASCII_W "/z486/boot1.rom (at most 128 KB).\n"
ERR_PC_BOOT0    .ASCII_P "Cannot load the system BIOS\n"
                .ASCII_W "/z486/boot0.rom (at most 128 KB).\n"

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
CFG_SIG_VAL     .ASCII_W "2"

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

; PREP_START's file handle for the BIOS ROMs
PC_ROM_FILE     .BLOCK  FAT32$FDH_STRUCT_SIZE

; The menu heap (Megamiga hard rule 11): the menu structure plus OPTM_HEAP;
; for this 16-line menu: 20 + 182 item characters + 1 + 4 x 16 + 1 + (1
; submenu + 1 manual load + 1) x 30 = 358 words; the Shell checks it at boot
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

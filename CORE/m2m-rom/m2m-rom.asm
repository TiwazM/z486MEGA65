; ****************************************************************************
; z486 for MEGA65
;
; QNICE firmware (the M2M "Shell" plus the core's callbacks)
;
; The Shell does almost everything: SD cards, the settings file, the menu. The
; callbacks below are the ones the Megamiga fork's Shell needs: the M2M
; template's plus HANDLE_CORE_IO (core-io-hook), BROWSE_EXTRA (cfg-strings),
; FAR_CALL (code-banks) and CFG_SIGCHECK / CFG_SIGSET (the settings file
; signature). PREP_START loads the PC's BIOS ROMs and mounts /z486/hdd.img,
; /z486/cdrom.iso and /z486/floppy.img, if they are there; the menu's
; "Floppy A:", "Floppy B:", "Hard disk:" and "CD-ROM:" lines mount others
; (PREP_LOAD_IMAGE, DISK_PREP).
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
; The manual loads are the "Floppy A:", "Floppy B:", "Hard disk:" and
; "CD-ROM:" lines: DISK_PREP mounts the image and the Shell streams nothing
; into the device.
; The browser's "<No Disk>" (BROWSE_EXTRA, SF_VIRTUAL /= 0: an empty handle)
; ejects the line's drive instead (DISK_EJECT); the line then shows
; "<No Disk>".
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE XOR     R9, R9                  ; R9: the unit
                CMP     PC_OPTM_G_FDD_B, R10
                RBRA    _PLI_HDD, !Z
                MOVE    1, R9
_PLI_HDD        CMP     PC_OPTM_G_HDD, R10
                RBRA    _PLI_CD, !Z
                MOVE    2, R9
_PLI_CD         CMP     PC_OPTM_G_CD, R10
                RBRA    _PLI_GO, !Z
                MOVE    3, R9
_PLI_GO         MOVE    R10, @--SP
                MOVE    SF_VIRTUAL, R10
                CMP     0, @R10
                RBRA    _PLI_EJECT, !Z
                MOVE    @SP++, R10
                RSUB    DISK_PREP, 1
                RET
_PLI_EJECT      MOVE    @SP++, R10
                RSUB    DISK_EJECT, 1
                RET

; DISK_EJECT: unit R9 (0 A:, 1 B:, 2 the hard disk, 3 the CD-ROM) has no
; image any more: MODE 0, which pc_mgmt.vhd sees as an eject (a floppy's
; change line; the hard disk is gone for the PC at once; the CD-ROM drive has
; no disc). Output: R8 = R9 = 0; R10..R12 kept.
DISK_EJECT      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    PC_DEV_DISK, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0
                MOVE    R9, R0
                AND     0xFFFD, SR              ; (SHL shifts X in)
                SHL     5, R0
                ADD     M2M$RAMROM_DATA, R0
                MOVE    0, @R0                  ; MODE: no image
                DECRB
                XOR     R8, R8
                XOR     R9, R9
                RET

; ----------------------------------------------------------------------------
; The disks (disk_sd.vhd): floppy drives A: and B:, the hard disk and the
; CD-ROM's disc. An image file is read and written in place through the SD
; host controller's engine port; its extent map tells the hardware where the
; sectors are (Megamac's DISK_PREP).
;
; DISK_PREP: mount the image file R8 (an open handle) as unit R9 (0 = A:,
; 1 = B:, 2 = the hard disk, 3 = the CD-ROM; its registers at 0x20 * R9, its
; extent map at map word 2048 * R9: window 1 + R9 / 2, offset 2048 *
; (R9 & 1)):
;   1. a floppy's size must be a standard one (FDD_SIZES): its geometry; a
;      hard disk's any whole number of 512-byte sectors, a CD-ROM's (an ISO
;      image) of 2048-byte sectors;
;   2. the unit goes away (MODE 0) while it changes;
;   3. the file's extent map (FAT32$FILE_MAP: up to 511 extents, so
;      fragmented files are fine);
;   4. sectors, the cluster base (DEV_CLUSTER - (2 << shift)), shift and a
;      floppy's geometry, then MODE (mounted, the card's slot; a CD-ROM write
;      protected) last: pc_mgmt.vhd then inserts the floppy, or has the hard
;      disk for the PC's next start; pc_cdrom.vhd has a new disc;
;   5. the handle to its end: the Shell's manual load streams nothing.
; Output: R8 = 0 (OK) or an error code with R9 = the message; R10..R12 kept.
; ----------------------------------------------------------------------------

DISK_E_SIZE     .EQU    0x00F1
DISK_E_FRAG     .EQU    0x00F2

DISK_PREP       INCRB
                MOVE    R10, @--SP
                MOVE    R11, @--SP
                MOVE    R12, @--SP
                MOVE    R9, @--SP               ; @SP: the unit
                MOVE    R8, R0                  ; R0: the handle
                MOVE    R9, R7                  ; R7: the unit's registers
                AND     0xFFFD, SR
                SHL     5, R7
                ADD     M2M$RAMROM_DATA, R7

                ; 1. the size
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R2                 ; R2: size hi
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                MOVE    @R1, R3                 ; R3: size lo
                MOVE    0x01FF, R4              ; R4: the sector size - 1
                CMP     3, @SP
                RBRA    _DP_HDD, !Z
                RBRA    _DP_CD, 1               ; the CD-ROM: cdimage.asm
_DP_HDD         CMP     2, @SP
                RBRA    _DP_FDD, !Z
_DP_WHOLE       MOVE    R3, R1                  ; the hard disk, the CD-ROM: whole
                AND     R4, R1                  ; sectors, at least one
                RBRA    _DP_BADHD, !Z
                MOVE    R3, R5                  ; R6:R5 = size >> 9
                AND     0xFFFB, SR
                SHR     9, R5
                MOVE    R2, R6
                AND     0xFFFD, SR
                SHL     7, R6
                OR      R6, R5
                MOVE    R2, R6
                AND     0xFFFB, SR
                SHR     9, R6
                MOVE    R5, R1
                OR      R6, R1
                RBRA    _DP_BADHD, Z
                RBRA    _DP_FOUND, 1
_DP_FDD         MOVE    FDD_SIZES, R4
_DP_SIZE        MOVE    @R4, R5                 ; R5: sectors (0: the end)
                RBRA    _DP_BADSZ, Z
                MOVE    R4, R6
                ADD     1, R6
                CMP     @R6++, R2
                RBRA    _DP_NEXT, !Z
                CMP     @R6++, R3
                RBRA    _DP_FOUND, Z            ; R6: cylinders, sectors/track
_DP_NEXT        ADD     5, R4
                RBRA    _DP_SIZE, 1

                ; 2. the unit away while it changes
_DP_FOUND       MOVE    M2M$RAMROM_DEV, R1
                MOVE    PC_DEV_DISK, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                MOVE    0, @R7                  ; MODE: no image

                ; 3. the extent map: window 1 + unit / 2, offset 2048 * (unit & 1)
                MOVE    @SP, R1
                AND     0xFFFB, SR
                SHR     1, R1
                ADD     1, R1
                MOVE    M2M$RAMROM_4KWIN, R4
                MOVE    R1, @R4
                MOVE    @SP, R9
                AND     1, R9
                AND     0xFFFD, SR
                SHL     11, R9
                ADD     M2M$RAMROM_DATA, R9
                MOVE    R0, R8
                MOVE    2048, R10
                RSUB    FAT32$FILE_MAP, 1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                CMP     0, R9
                RBRA    _DP_MAPOK, Z
                CMP     FAT32$ERR_MAPSIZE, R9
                RBRA    _DP_FRAG, Z
                MOVE    R9, R8                  ; another FAT32 error: its code
                MOVE    ERR_DISK_FAT, R9
                RBRA    _DP_RET, 1

                ; the CD-ROM: away, then CD_PREP writes the track table and the
                ; extent map of an ISO, a raw .bin or a .cue's files; R6:R5 =
                ; the virtual image's sectors
_DP_CD          MOVE    M2M$RAMROM_DEV, R1
                MOVE    PC_DEV_DISK, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                MOVE    0, @R7                  ; MODE: no image
                MOVE    R0, R8
                RSUB    CD_PREP_X, 1
                MOVE    R9, R5
                MOVE    R10, R6
                MOVE    CD_ERRS, R1             ; its error: the message
_DP_CDE         CMP     0, R8
                RBRA    _DP_MAPOK, Z
                CMP     0, @R1
                RBRA    _DP_CDEX, Z             ; (the table's end: unknown)
                CMP     @R1++, R8
                RBRA    _DP_CDEM, Z
                ADD     1, R1
                RBRA    _DP_CDE, 1
_DP_CDEM        MOVE    @R1, R9
                RBRA    _DP_RET, 1
_DP_CDEX        MOVE    ERR_DISK_FAT, R9
                RBRA    _DP_RET, 1

                ; 4. shift = log2(sectors per cluster), base, sectors, geometry,
                ; mode
_DP_MAPOK       MOVE    @R0, R4                 ; R4: the device (FDH_DEVICE = 0)
                MOVE    R4, R1
                ADD     FAT32$DEV_SECT_PER_CLUS, R1
                MOVE    @R1, R1                 ; R1: sectors per cluster
                XOR     R3, R3                  ; R3: the shift
_DP_SHL         CMP     R1, 1
                RBRA    _DP_SHD, !N             ; R1 <= 1: done
                AND     0xFFFB, SR
                SHR     1, R1
                ADD     1, R3
                RBRA    _DP_SHL, 1
_DP_SHD         MOVE    2, R2
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
                MOVE    PC_DEV_DISK, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    0, @R1
                MOVE    R7, R1
                ADD     1, R1
                MOVE    R5, @R1++               ; 1 SECTS lo
                MOVE    @SP, R4
                AND     2, R4                   ; units 2 and 3: no floppy
                RBRA    _DP_FSECT, Z
                MOVE    R6, @R1++               ; 2 SECTS hi (the hard disk, the CD-ROM)
                RBRA    _DP_BASE, 1
_DP_FSECT       MOVE    0, @R1++                ; 2 SECTS hi (a floppy)
_DP_BASE        MOVE    R10, @R1++              ; 3 BASE lo
                MOVE    R11, @R1++              ; 4 BASE hi
                MOVE    R3, @R1++               ; 5 SHIFT
                MOVE    @SP, R4
                AND     2, R4
                RBRA    _DP_MODE, !Z            ; (the hard disk, the CD-ROM: no geometry)
                MOVE    @R6++, @R1++            ; 6 cylinders
                MOVE    @R6, @R1++              ; 7 sectors per track
                MOVE    2, @R1                  ; 8 heads
_DP_MODE        CMP     3, @SP
                RBRA    _DP_MODE2, !Z
                OR      4, R8                   ; the CD-ROM: write protected
_DP_MODE2       MOVE    R8, @R7                 ; MODE last

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
                RBRA    _DP_OK, Z
                MOVE    R9, R8
                MOVE    ERR_DISK_FAT, R9
                RBRA    _DP_RET, 1

_DP_OK          XOR     R8, R8
                XOR     R9, R9
                RBRA    _DP_RET, 1
_DP_BADHD       MOVE    DISK_E_SIZE, R8
                MOVE    ERR_HDD_SIZE, R9
                RBRA    _DP_RET, 1
_DP_BADSZ       MOVE    DISK_E_SIZE, R8
                MOVE    ERR_FDD_SIZE, R9
                RBRA    _DP_RET, 1
_DP_FRAG        MOVE    DISK_E_FRAG, R8
                MOVE    ERR_DISK_FRAG, R9
_DP_RET         ADD     1, SP                   ; (the unit)
                MOVE    @SP++, R12
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
ERR_HDD_SIZE    .ASCII_P "Not a disk image: its\n"
                .ASCII_W "size must be whole\n512-byte sectors.\n"
ERR_CD_SIZE     .ASCII_P "Not a CD image: an ISO\n"
                .ASCII_P "must be whole 2048-byte\n"
                .ASCII_W "sectors, a BIN 2352.\n"
ERR_DISK_FRAG   .ASCII_W "The image file has too\nmany fragments.\n"
ERR_DISK_FAT    .ASCII_W "Cannot read the image\nfile (FAT32 error).\n"
ERR_CUE         .ASCII_P "Cannot read the cue\n"
                .ASCII_W "sheet (TRACK, INDEX).\n"
ERR_CUE_FILE    .ASCII_P "A FILE of the cue sheet\n"
                .ASCII_W "is not in its folder.\n"
ERR_CUE_LONG    .ASCII_W "The cue sheet is too\nlong (16K at most).\n"
ERR_CUE_WAVE    .ASCII_P "A WAVE file must be\n"
                .ASCII_W "PCM, 16-bit stereo,\n44.1 kHz.\n"
ERR_CUE_TYPE    .ASCII_P "MP3 and other compressed\n"
                .ASCII_W "audio: convert it to\nBIN or WAVE.\n"
; CD_PREP's errors (cdimage.asm, CDI_E_*) and their messages
CD_ERRS         .DW     0x00F1, ERR_CD_SIZE
                .DW     0x00F2, ERR_DISK_FRAG
                .DW     0x00F3, ERR_CUE
                .DW     0x00F4, ERR_CUE_FILE
                .DW     0x00F5, ERR_DISK_FAT
                .DW     0x00F6, ERR_CUE_LONG
                .DW     0x00F7, ERR_CUE_WAVE
                .DW     0x00F8, ERR_CUE_TYPE
                .DW     0
FDD_AUTO        .ASCII_W "/z486/floppy.img"
HDD_AUTO        .ASCII_W "/z486/hdd.img"
CD_AUTO         .ASCII_W "cdrom.cue"
CD_AUTO_DIR     .ASCII_W "/z486"
CD_AUTO_ROOT    .ASCII_W "/"
CD_AUTO_ISO     .ASCII_W "/z486/cdrom.iso"

; DISK_AUTO: mount the file R10 (a path) from the device R8 as unit R9, if it
; is there; its menu line then shows its name. Output: C = 1: mounted.
; Registers preserved.
DISK_AUTO       SYSCALL(enter, 1)
                MOVE    R9, R0                  ; R0: the unit
                MOVE    R10, R1                 ; R1: the path
                MOVE    PC_ROM_FILE, R9
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _DA_NO, !Z              ; not there
                MOVE    PC_ROM_FILE, R8
                MOVE    R0, R9
                RSUB    DISK_PREP, 1
                CMP     0, R8
                RBRA    _DA_NO, !Z              ; not an image
                MOVE    R1, R8
                MOVE    R0, R9
                RSUB    DISK_AUTO_NAME, 1
                SYSCALL(leave, 1)
                OR      0x0004, SR              ; C = 1
                RET
_DA_NO          SYSCALL(leave, 1)
                AND     0xFFFB, SR              ; C = 0
                RET

; DISK_AUTO_NAME: the menu line of manual load R9 (0 A:, 1 B:, 2 the hard
; disk, 3 the CD-ROM) shows the auto-mounted image R8 (a path) like a manual load
; (Megamac's DISK_AUTO_NAME): its device's CSR (PC_DEV_DISK + R9) says
; "loaded", and DAN_FLUSH puts the name into the line once the menu has its
; heap. At PREP_START it has none yet (HELP_MENU makes it when the menu first
; opens): before, the name was skipped, the menu drew the line unloaded (the
; line's text in its buffer), then the Shell's poll of the CSR marked it loaded
; and put that text in for the name: "Hard disk:  Hard dis...". Registers
; preserved.
DISK_AUTO_NAME  SYSCALL(enter, 1)
                MOVE    PC_DEV_DISK, R4         ; its device's CSR: loaded
                ADD     R9, R4
                MOVE    M2M$RAMROM_DEV, R5
                MOVE    R4, @R5
                MOVE    M2M$RAMROM_4KWIN, R5
                MOVE    CRTROM_CSR_4KWIN, @R5
                MOVE    CRTROM_CSR_STATUS, R5
                MOVE    CRTROM_CSR_ST_OK, @R5
                MOVE    DAN_PEND, R4            ; the name, for DAN_FLUSH
                ADD     R9, R4
                MOVE    R8, @R4
                SYSCALL(leave, 1)
                RET

; DAN_FLUSH (from HANDLE_CORE_IO): once the Shell has the menu heap, the
; names that DISK_AUTO_NAME keeps for the auto-mounted images go into their
; lines' OPTM_HEAP buffers ((vdrives + submenus + unit) * @SCR$OSM_O_DX): the
; file name after the last '/', at most the width - 2 characters, one more for
; the ellipsis, the "%s is replaced" flag in the buffer's last word = 0, as
; shell.asm's _HM_SDMOUNTED3..5 do it. In the menu's key loop HANDLE_IO comes
; before the Shell's poll of the CSRs (CRTROM_MLST_GET), which then sees the
; line loaded and draws it with the name. Registers preserved.
DAN_FLUSH       SYSCALL(enter, 1)
                XOR     R1, R1                  ; R1: the unit
_DANF_UNIT      MOVE    OPTM_HEAP, R4
                MOVE    @R4, R4                 ; R4: the heap (0: no menu yet)
                RBRA    _DAN_RET, Z
                MOVE    DAN_PEND, R2
                ADD     R1, R2
                MOVE    @R2, R0                 ; R0: the unit's path (0: none)
                RBRA    _DANF_NEXT, Z
                MOVE    0, @R2
                MOVE    R0, R5                  ; R5: the name = after the last '/'
                MOVE    R0, R6
_DAN_BN         CMP     0, @R6
                RBRA    _DAN_BN1, Z
                CMP     0x002F, @R6             ; '/'
                RBRA    _DAN_BN2, !Z
                MOVE    R6, R5
                ADD     1, R5
_DAN_BN2        ADD     1, R6
                RBRA    _DAN_BN, 1
_DAN_BN1        MOVE    VDRIVES_NUM, R8
                MOVE    @R8, R8
                MOVE    OPTM_SCOUNT, R9
                ADD     @R9, R8
                ADD     R1, R8                  ; vdrives + submenus + the load
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9                 ; R9: the line's width
                SYSCALL(mulu, 1)                ; R10: the buffer's offset
                ADD     R10, R4                 ; R4: the line's buffer
                MOVE    R9, R6
                SUB     2, R6                   ; R6: the longest name
                MOVE    R5, R8
                SYSCALL(strlen, 1)              ; R9: the name's length
                CMP     R9, R6                  ; longer than the frame?
                RBRA    _DAN_LONG, N            ; yes
                MOVE    R5, R8
                MOVE    R4, R9
                SYSCALL(strcpy, 1)
                RBRA    _DAN_FLAG, 1
_DAN_LONG       MOVE    R5, R8                  ; the longest + 1: the ellipsis
                MOVE    R4, R9
                MOVE    R6, R10
                ADD     1, R10
                SYSCALL(memcpy, 1)
                ADD     R10, R9
                MOVE    0, @R9
_DAN_FLAG       MOVE    SCR$OSM_O_DX, R8        ; "%s is replaced" = 0
                MOVE    @R8, R8
                SUB     1, R8
                ADD     R4, R8
                MOVE    0, @R8
_DANF_NEXT      ADD     1, R1
                CMP     4, R1
                RBRA    _DANF_UNIT, !Z
_DAN_RET        SYSCALL(leave, 1)
                RET

; BROWSE_EXTRA (M2M-UPSTREAM cfg-strings): the browser's entries that are no
; files. Input: R8 = the entry's index, R9 = the context, R10 = its data, R11
; = 0xFFFF in a directory, else the slot (the list of the cards). Output: R8 =
; its name (0: no more), R9 = its id; R10..R12 preserved.
; The disk lines (manual loads) start every directory with "<No Disk>", right
; after "<..>": it ejects the line's drive (PREP_LOAD_IMAGE, DISK_EJECT).
BROWSE_EXTRA    CMP     0, R8                   ; one entry
                RBRA    _BX_NONE, !Z
                CMP     CTX_LOAD_ROM, R9
                RBRA    _BX_NONE, !Z
                CMP     0xFFFF, R11             ; in a directory
                RBRA    _BX_NONE, !Z
                MOVE    BX_NO_DISK, R8
                XOR     R9, R9
                RET
_BX_NONE        XOR     R8, R8
                RET

BX_NO_DISK      .ASCII_W "<No Disk>"

; ----------------------------------------------------------------------------
; Core specific callback functions: Core startup
;
; PREP_START is called after the Shell's reset management, before it connects
; keyboard and joysticks. It loads the PC's BIOS ROMs. z486's boot loader
; copies the ROM window 0xC0000..0xFFFFF (256 KB) from its DDR3 window into
; the SDRAM the moment the PC leaves reset (on MiSTer, Main_MiSTer stages the
; ROMs there). Here that window is HyperRAM 0x3C0000 (globals.vhd,
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

PC_ROM_WIN      .EQU    0x01E0                  ; HyperRAM 0x3C0000 = 0xC0000
PC_ROM_WINS     .EQU    0x0020                  ; 32 4K word windows: 256 KB
PC_BIOS_WIN     .EQU    0x01F8                  ; 0xF0000
PC_BIOS128_WIN  .EQU    0x01F0                  ; 0xE0000

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
                MOVE    PC_ROM_FILE, R8         ; z486_MiSTer's: the mouse
                RSUB    BIOS_PATCH, 1           ; handler's sync check

                ; the hard disk /z486/hdd.img, the CD-ROM /z486/cdrom.iso and
                ; floppy drive A: /z486/floppy.img, if they are there (then
                ; 150 ms for a floppy, so that pc_mgmt.vhd has inserted it,
                ; 100 ms after the eject, before the BIOS looks for drives)
                MOVE    DAN_PEND, R8            ; no names kept (RAM outlives
                MOVE    0, @R8++                ; a QNICE reset)
                MOVE    0, @R8++
                MOVE    0, @R8++
                MOVE    0, @R8
                MOVE    R7, R8
                MOVE    2, R9
                MOVE    HDD_AUTO, R10
                RSUB    DISK_AUTO, 1
                MOVE    R7, R8                  ; the CD-ROM: /z486/cdrom.cue
                MOVE    CD_AUTO_DIR, R9         ; from its folder (its FILEs are
                XOR     R10, R10                ; relative to it), else
                SYSCALL(f32_cd, 1)              ; /z486/cdrom.iso
                CMP     0, R9
                RBRA    _PCS_CDISO, !Z
                MOVE    R7, R8
                MOVE    3, R9
                MOVE    CD_AUTO, R10
                RSUB    DISK_AUTO, 1
                MOVE    0, R6                   ; R6: 1 = mounted
                RBRA    _PCS_CDROOT, !C
                MOVE    1, R6
_PCS_CDROOT     MOVE    R7, R8                  ; back to the root
                MOVE    CD_AUTO_ROOT, R9
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     1, R6
                RBRA    _PCS_FDD, Z
_PCS_CDISO      MOVE    R7, R8
                MOVE    3, R9
                MOVE    CD_AUTO_ISO, R10
                RSUB    DISK_AUTO, 1
_PCS_FDD        MOVE    R7, R8
                XOR     R9, R9
                MOVE    FDD_AUTO, R10
                RSUB    DISK_AUTO, 1
                RBRA    _PCS_GO, !C             ; no floppy: no wait
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
                RSUB    BPT_CLR, 1              ; the file's sums (bios_patch.asm)
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
                MOVE    R4, R8
                RSUB    BPT_ADD, 1
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

; BPT_POKE (bios_patch.asm): writes the word R10 at word R9 of HyperRAM's 4K
; window R8
BPT_POKE        INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    M2M$HYPERRAM, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    R8, @R0
                MOVE    M2M$RAMROM_DATA, R0
                ADD     R9, R0
                MOVE    R10, @R0
                DECRB
                RET

#include "bios_patch.asm"

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
; background work, in its main loop and in every wait loop (the menu, the file
; browser, the help screens). Must preserve all registers.
;
; The serial commands (the MEGA65's USB serial port, 115200 8N1; tools/qmon.py)
; give the debug registers without the debug mode, while the Shell and the PC
; run (as MegaMac's firmware does): a letter, then hex fields of four digits,
; no separators, each digit within ~10 ms of the one before:
;   R aaaa nnnn              read n words from QNICE address a
;   W aaaa vvvv              write v to QNICE address a
;   D dddd wwww aaaa nnnn    read n words at a (0x8000..0x8FFF) of device d,
;                            4K window w
;   P dddd wwww aaaa vvvv    write v at a of device d, window w
; Reads answer as the monitor's M D does (lines "AAAA: WWWW ..." of eight
; words); every command ends with "QMON> ", a broken one after "?". Any other
; byte is ignored. The Shell's device and window are put back afterwards.
HANDLE_CORE_IO  SYSCALL(enter, 1)
                RSUB    DAN_FLUSH, 1            ; auto-mounted names into the menu
                MOVE    IO$UART_SRA, R0
                MOVE    @R0, R1
                AND     0x0001, R1              ; a byte from the serial port?
                RBRA    _HCIO_RET, Z
                MOVE    IO$UART_RHRA, R0
                MOVE    @R0, R6                 ; R6: the command
                MOVE    M2M$RAMROM_DEV, R0      ; R4, R5: the Shell's device
                MOVE    @R0, R4                 ; and window
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    @R0, R5
                CMP     0x0052, R6              ; 'R'
                RBRA    _HCIO_RD, Z
                CMP     0x0057, R6              ; 'W'
                RBRA    _HCIO_WR, Z
                CMP     0x0044, R6              ; 'D'
                RBRA    _HCIO_DEV, Z
                CMP     0x0050, R6              ; 'P'
                RBRA    _HCIO_DEV, Z
                RBRA    _HCIO_RET, 1

_HCIO_DEV       RSUB    SER_HEX4, 1             ; the device
                RBRA    _HCIO_ERR, !C
                MOVE    R8, R2
                RSUB    SER_HEX4, 1             ; the window
                RBRA    _HCIO_ERR, !C
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    R2, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    R8, @R0
                CMP     0x0044, R6
                RBRA    _HCIO_WR, !Z            ; 'P': on as 'W'

_HCIO_RD        RSUB    SER_HEX4, 1             ; the address
                RBRA    _HCIO_ERR, !C
                MOVE    R8, R2                  ; R2: the address
                RSUB    SER_HEX4, 1             ; the count
                RBRA    _HCIO_ERR, !C
                MOVE    R8, R3                  ; R3: words left
                XOR     R7, R7                  ; R7: words on the line
_HCIO_RD1       CMP     0, R3
                RBRA    _HCIO_OK, Z
                CMP     0, R7
                RBRA    _HCIO_RD2, !Z
                SYSCALL(crlf, 1)                ; a line: its address
                MOVE    R2, R8
                SYSCALL(puthex, 1)
                MOVE    SER_COLON, R8
                SYSCALL(puts, 1)
_HCIO_RD2       MOVE    @R2++, R8
                SYSCALL(puthex, 1)
                MOVE    SER_SPACE, R8
                SYSCALL(puts, 1)
                ADD     1, R7
                AND     0x0007, R7
                SUB     1, R3
                RBRA    _HCIO_RD1, 1

_HCIO_WR        RSUB    SER_HEX4, 1             ; the address
                RBRA    _HCIO_ERR, !C
                MOVE    R8, R2
                RSUB    SER_HEX4, 1             ; the value
                RBRA    _HCIO_ERR, !C
                MOVE    R8, @R2
                RBRA    _HCIO_OK, 1

_HCIO_ERR       MOVE    SER_ERR, R8
                SYSCALL(puts, 1)
_HCIO_OK        SYSCALL(crlf, 1)
                MOVE    SER_PROMPT, R8
                SYSCALL(puts, 1)
                MOVE    M2M$RAMROM_DEV, R0      ; the Shell's device and window
                MOVE    R4, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    R5, @R0
_HCIO_RET       SYSCALL(leave, 1)
                RET

; SER_HEX4: four hex digits (0-9, A-F) from the serial port, each within about
; 10 ms -> R8. C = 1: OK; C = 0: a timeout or no hex digit. R9..R12 kept.
SER_HEX4        INCRB
                XOR     R8, R8
                MOVE    4, R0                   ; R0: digits left
_SH4_DIGIT      MOVE    0xFFFF, R1              ; R1: the timeout
_SH4_WAIT       MOVE    IO$UART_SRA, R2
                MOVE    @R2, R2
                AND     0x0001, R2
                RBRA    _SH4_GOT, !Z
                SUB     1, R1
                RBRA    _SH4_WAIT, !Z
                RBRA    _SH4_FAIL, 1
_SH4_GOT        MOVE    IO$UART_RHRA, R2
                MOVE    @R2, R2                 ; R2: the character
                MOVE    SER_HEXDIG, R3
                XOR     R4, R4                  ; R4: its value
_SH4_FIND       CMP     @R3++, R2
                RBRA    _SH4_FOUND, Z
                ADD     1, R4
                CMP     16, R4
                RBRA    _SH4_FIND, !Z
                RBRA    _SH4_FAIL, 1
_SH4_FOUND      AND     0xFFFD, SR              ; (SHL shifts X in)
                SHL     4, R8
                OR      R4, R8
                SUB     1, R0
                RBRA    _SH4_DIGIT, !Z
                DECRB
                OR      0x0004, SR              ; C = 1
                RET
_SH4_FAIL       DECRB
                AND     0xFFFB, SR              ; C = 0
                RET

SER_HEXDIG      .ASCII_W "0123456789ABCDEF"
SER_COLON       .ASCII_W ": "
SER_SPACE       .ASCII_W " "
SER_ERR         .ASCII_W "?"
SER_PROMPT      .ASCII_W "QMON> "

; FAR_CALL (M2M-UPSTREAM code-banks): call a routine in a code bank through
; its stub (two words: the bank, the address), for the FAT32 write layer's
; stubs below. FAR_CALL selects the bank, calls the routine and selects the
; caller's bank again; R8..R12 and the Carry pass through both ways (the other
; flags do not). Code in a bank may call the fixed ROM directly, never another
; bank except through a stub.
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
CFG_SIG_VAL     .ASCII_W "15"                   ; 15: "Real floppy speed", "Internal
                                                ; drive" under "Floppy B:" (64 lines)

; ----------------------------------------------------------------------------
; The FAT32 write layer (M2M/QNICE/monitor/fat32_write.asm, fat32_wfile.asm;
; the Shell creates and resizes the settings file with it). A release build
; has it in two 4K-word code banks as Megamiga and MegaMac do (M2M-UPSTREAM
; code-banks, QNICE_CODE_BANKS in globals.vhd): the core is code bank
; BANK_F32W, writing files is BANK_F32F, and these stubs are their entry
; points - the names fat32_wglue.asm gives them in a flat program - including
; the core routines that the file part calls. A develop build has it flat.
; ----------------------------------------------------------------------------

#ifdef RELEASE
BANK_F32W       .EQU    0                       ; FAT32 write layer: core
BANK_F32F       .EQU    1                       ; FAT32 write layer: files

FAT32$W_CREATE  RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_CREATE
FAT32$W_DELETE  RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_DELETE
FAT32$W_SETDE   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_SETDE
FAT32$W_MKDIR   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_MKDIR
FAT32$W_RENAME  RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_RENAME
FAT32$W_FDH     RSUB    FAR_CALL, 1
                .DW     BANK_F32F, _F32W_FDH
FAT32$W_PUT     RSUB    FAR_CALL, 1
                .DW     BANK_F32F, _F32W_PUT
FAT32$W_ADV     RSUB    FAR_CALL, 1
                .DW     BANK_F32F, _F32W_ADV
FAT32$W_SYNC    RSUB    FAR_CALL, 1
                .DW     BANK_F32F, _F32W_SYNC
FAT32$W_SETSIZE RSUB    FAR_CALL, 1
                .DW     BANK_F32F, _F32W_SETSIZE
_F32WX_BEGIN    RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_BEGIN
_F32WX_END      RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_END
_F32WX_SCAN     RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_SCAN
_F32WX_FATGET   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_FATGET
_F32WX_FATSET   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_FATSET
_F32WX_ISDATA   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_ISDATA
_F32WX_ALLOC    RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_ALLOC
_F32WX_FREE     RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_FREE
_F32WX_ZEROCL   RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_ZEROCL
_F32WX_CLSEC    RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_CLSEC
_F32WX_SEC      RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_SEC
_F32WX_SETDE    RSUB    FAR_CALL, 1
                .DW     BANK_F32W, _F32W_SETDE

; CD images (cdimage.asm: ISO, raw .bin, .cue + .bin/.wav) for DISK_PREP
BANK_CDI        .EQU    2
CD_PREP_X       RSUB    FAR_CALL, 1
                .DW     BANK_CDI, CD_PREP
#else
#include "../../M2M/QNICE/monitor/fat32_wglue.asm"
#include "../../M2M/QNICE/monitor/fat32_write.asm"
#include "../../M2M/QNICE/monitor/fat32_wfile.asm"
CD_PREP_X       RBRA    CD_PREP, 1
#include "cdimage.asm"
#include "cdimage_sel.asm"
#endif

; ----------------------------------------------------------------------------
; END_OF_ROM must stay the last ROM item (make_rom.sh checks it); the code
; banks follow it
; ----------------------------------------------------------------------------

END_OF_ROM      .DW 0

#ifdef RELEASE
                .ORG    0x9000                  ; the code window (.ORG takes no symbol)
                .DW     0x4B00                  ; bank 0: BANK_F32W
#include "../../M2M/QNICE/monitor/fat32_write.asm"

                .ORG    0x9000
                .DW     0x4B01                  ; bank 1: BANK_F32F
#include "../../M2M/QNICE/monitor/fat32_wfile.asm"

                .ORG    0x9000
                .DW     0x4B02                  ; bank 2: BANK_CDI
#include "cdimage.asm"
#include "cdimage_sel.asm"
#endif

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
BPT_SUM         .BLOCK  2                       ; its sums (bios_patch.asm)

; DISK_AUTO_NAME's auto-mounted paths per unit (0: none), for DAN_FLUSH
DAN_PEND        .BLOCK  4

; CD_PREP's (cdimage.asm)
#include "cdimage_vars.asm"

; The menu heap (Megamiga hard rule 11): the menu structure plus OPTM_HEAP;
; for this 64-line menu: 20 + 664 item characters + 1 + 5 x 64 (the line
; arrays and the dependency array) + 1 + (6 submenus + 4 manual loads + 1) x
; 26 (SCR$OSM_O_DX) = 1292 words (the 63-line "Internal drive" one: 1268; the
; 61-line "Drive sounds" one: 1230; the
; 54-line one before it: 1100; the 53-line one before the joystick's "Off":
; 1081). The Shell checks it when the menu first opens
; (ERR_FATAL_HEAP1/2; with 768, the 38-line menu was 13 short: "Heap
; corruption", error code 000D; with 832, the 46-line one 107: 006B; the
; 46-line one needed 939 of 960, before the "Refresh" submenu).
; The rest of the heap is the file browser's.
MENU_HEAP_SIZE  .EQU 1344

#ifndef RELEASE
HEAP_SIZE       .EQU 0
HEAP            .BLOCK 1
#else
; HEAP + MENU_HEAP_SIZE + HEAP_SIZE must stay below VAR$STACK_START -
; STACK_SIZE (check HEAP and VAR$STACK_START in m2m-rom.lis)
HEAP_SIZE       .EQU 18656                      ; (18720 before MENU_HEAP_SIZE
HEAP            .BLOCK 1                        ; grew by 64: the same end)

                .ORG    0xFED0                  ; as Megamiga: the FAT32 write layer's
                                                ; larger device handle (main_vars.asm)
#endif

STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"

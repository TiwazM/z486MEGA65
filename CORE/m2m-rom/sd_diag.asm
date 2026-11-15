; ****************************************************************************
; z486 for MEGA65: the state of both SD card slots as text
;
; Which bus each card runs on, and for users whose card does not work in one
; slot, which card failed and how (a photo of the text). Shown
;   * on the fatal screen when PREP_START cannot start the PC (no card that
;     mounts, no BIOS files), after its message, and
;   * in the file browser: the list of the cards (above the roots) has an
;     "<SD card info>" entry under each card (BROWSE_EXTRA); choosing it shows
;     this text (PREP_LOAD_IMAGE returns it with M2M$LOAD_INFO: shell.asm
;     shows it without "Error code") and leaves the drive and its menu line
;     as they are (SDD_SNAP, SDD_RESTORE below).
; From the v0.1 diagnostic build (branch v0.1-sddiag), with v0.2.2's SD host.
;
; Per slot (the back slot first): whether a card is in (SDC_PRES), its type
; and bus (sdhost.vhd's registers through M2M$SD_SLOT, put back afterwards):
; native 4-bit at 25 or 50 MHz, or SPI at 25 or 12.5 MHz. A card in SPI mode
; that the controller did not choose (register 6 bit 3, "SPI only", clear) is
; one that the MEGA65's own start-up read in SPI mode (with the internal slot
; empty it reads the back card): a card leaves SPI mode only when it loses
; power, so the text says to take it out and put it back. Then the
; controller's last error (EE31 init, EE33 data, EE34 no card), its CSR and
; mode register (bits 15..8: the transfers it retried), and the FAT32 mount
; result at the card's current generation ("----": not tried); then the card
; of the settings file. At most 24 characters a line (the browser's window).
; ****************************************************************************

SDD_IO_MODE     .EQU    0xFF26                  ; sdhost.vhd register 6

; SD_DIAG: R8 = a message to put first (0: none, at most 80 characters).
; Output: R8 = the text (SDD_BUF). All other registers preserved.
SD_DIAG         INCRB
                MOVE    R9, R6                  ; R6, R5: R9 and R10 back
                MOVE    R10, R5
                MOVE    SDD_BUF, R9             ; R9: the text's end
                MOVE    0, @R9
                CMP     0, R8
                RBRA    _SDD_NOMSG, Z
                RSUB    _SDD_APP, 1             ; the message, a blank line
                MOVE    SDD_S_NL, R8
                RSUB    _SDD_APP, 1
_SDD_NOMSG      MOVE    SDD_S_HEAD, R8
                RSUB    _SDD_APP, 1
                MOVE    M2M$SD_SLOT, R0         ; R0: the slot register
                MOVE    @R0, R7                 ; R7: its value, put back
                MOVE    1, R4                   ; R4: slot, the back one first

_SDD_SLOT       MOVE    _SDD_NAMES, R8
                ADD     R4, R8
                MOVE    @R8, R8
                RSUB    _SDD_APP, 1
                MOVE    SDC_PRES, R8            ; a card in it (debounced)?
                ADD     R4, R8
                CMP     0, @R8
                RBRA    _SDD_CARD, !Z
                MOVE    SDD_S_NOCARD, R8
                RSUB    _SDD_APP, 1
                RBRA    _SDD_NEXT, 1

_SDD_CARD       MOVE    R4, @R0                 ; its controller
                MOVE    IO$SD_CSR, R1
                MOVE    @R1, R1                 ; R1: CSR
                MOVE    IO$SD_ERROR, R2
                MOVE    @R2, R2                 ; R2: the last error
                MOVE    SDD_IO_MODE, R3
                MOVE    @R3, R3                 ; R3: the bus mode

                MOVE    R1, R8                  ; the type: CSR bits 13..12
                SHR     12, R8
                AND     3, R8
                ADD     _SDD_TYPES, R8
                MOVE    @R8, R8
                RSUB    _SDD_APP, 1

                MOVE    SDD_S_NREADY, R8        ; the bus
                MOVE    R3, R10
                AND     0x0004, R10             ; ready?
                RBRA    _SDD_BUS, Z
                MOVE    R3, R10
                AND     0x0001, R10             ; native?
                RBRA    _SDD_SPI, Z
                MOVE    SDD_S_NAT25, R8
                MOVE    R3, R10
                AND     0x0010, R10             ; high speed?
                RBRA    _SDD_BUS, Z
                MOVE    SDD_S_NAT50, R8
                RBRA    _SDD_BUS, 1
_SDD_SPI        MOVE    SDD_S_SPI25, R8
                MOVE    R3, R10
                AND     0x0002, R10             ; 12.5 MHz?
                RBRA    _SDD_SPI2, Z
                MOVE    SDD_S_SPI12, R8
_SDD_SPI2       RSUB    _SDD_APP, 1
                MOVE    SDD_S_REINS, R8         ; not chosen ("SPI only"):
                MOVE    R3, R10                 ; the card was in SPI mode
                AND     0x0008, R10
                RBRA    _SDD_BUS, Z
                RBRA    _SDD_BUSE, 1
_SDD_BUS        RSUB    _SDD_APP, 1

_SDD_BUSE       MOVE    SDD_S_ERR, R8           ; the last error
                RSUB    _SDD_APP, 1
                MOVE    R2, R8
                RSUB    _SDD_HEX, 1
                MOVE    SDD_S_F32, R8           ; FAT32, if tried at this
                RSUB    _SDD_APP, 1             ; card's generation
                MOVE    SDC_MGEN, R8
                ADD     R4, R8
                MOVE    SDC_GEN, R10
                ADD     R4, R10
                CMP     @R8, @R10
                RBRA    _SDD_F32, Z
                MOVE    SDD_S_UNTRIED, R8
                RSUB    _SDD_APP, 1
                RBRA    _SDD_REGS, 1
_SDD_F32        MOVE    SDC_MERR, R8
                ADD     R4, R8
                MOVE    @R8, R8
                RSUB    _SDD_HEX, 1
_SDD_REGS       MOVE    SDD_S_CSR, R8           ; the raw registers
                RSUB    _SDD_APP, 1
                MOVE    R1, R8
                RSUB    _SDD_HEX, 1
                MOVE    SDD_S_MODE, R8
                RSUB    _SDD_APP, 1
                MOVE    R3, R8
                RSUB    _SDD_HEX, 1

_SDD_NEXT       MOVE    SDD_S_NL, R8
                RSUB    _SDD_APP, 1
                SUB     1, R4
                RBRA    _SDD_SLOT, !N
                MOVE    R7, @R0                 ; the slot selected before

                MOVE    SDD_S_HOME, R8          ; the settings file's card
                RSUB    _SDD_APP, 1
                MOVE    SDC_HOME, R8
                MOVE    @R8, R8
                CMP     0xFFFF, R8
                RBRA    _SDD_H, !Z
                MOVE    2, R8                   ; none
_SDD_H          ADD     _SDD_HOMES, R8
                MOVE    @R8, R8
                RSUB    _SDD_APP, 1

                MOVE    SDD_BUF, R8
                MOVE    R6, R9
                MOVE    R5, R10
                DECRB
                RET

; _SDD_APP: appends the string R8 at R9; R9: its zero terminator afterwards.
; R8 changed.
_SDD_APP        MOVE    @R8++, @R9
                RBRA    _SDD_APE, Z
                ADD     1, R9
                RBRA    _SDD_APP, 1
_SDD_APE        RET

; _SDD_HEX: appends the word R8 as 4 hex digits at R9 (as _SDD_APP).
_SDD_HEX        RSUB    WORD2HEXSTR, 1          ; 4 digits and a zero at R9
                ADD     4, R9
                RET

SDD_S_HEAD      .ASCII_W "SD cards:\n"
_SDD_NAMES      .DW     SDD_S_SD0, SDD_S_SD1
SDD_S_SD0       .ASCII_W "SD0 bottom: "
SDD_S_SD1       .ASCII_W "SD1 back: "
SDD_S_NOCARD    .ASCII_W "no card"
_SDD_TYPES      .DW     SDD_S_T0, SDD_S_T1, SDD_S_T2, SDD_S_T3
SDD_S_T0        .ASCII_W "type ?"
SDD_S_T1        .ASCII_W "SD V1"
SDD_S_T2        .ASCII_W "SD V2"
SDD_S_T3        .ASCII_W "SDHC"
SDD_S_NREADY    .ASCII_W "\n not ready"
SDD_S_NAT25     .ASCII_W "\n native 4-bit 25 MHz"
SDD_S_NAT50     .ASCII_W "\n native 4-bit 50 MHz"
SDD_S_SPI25     .ASCII_W "\n SPI 25 MHz"
SDD_S_SPI12     .ASCII_W "\n SPI 12.5 MHz"
SDD_S_REINS     .ASCII_W "\n re-insert for native"
SDD_S_ERR       .ASCII_W "\n err "
SDD_S_F32       .ASCII_W " fat32 "
SDD_S_UNTRIED   .ASCII_W "----"
SDD_S_CSR       .ASCII_W "\n csr "
SDD_S_MODE      .ASCII_W " mode "
SDD_S_NL        .ASCII_W "\n"
SDD_S_HOME      .ASCII_W "Settings file: "
_SDD_HOMES      .DW     SDD_S_H0, SDD_S_H1, SDD_S_H2
SDD_S_H0        .ASCII_W "SD0\n"
SDD_S_H1        .ASCII_W "SD1\n"
SDD_S_H2        .ASCII_W "none\n"

BX_SD_INFO      .ASCII_W "<SD card info>"

; ----------------------------------------------------------------------------
; The disk line around "<SD card info>": before it calls PREP_LOAD_IMAGE, the
; Shell puts the chosen entry's name into the line's text (its OPTM_HEAP
; buffer, shell.asm's _HM_SDMOUNTED3..5) and sets the line's device CSR to
; "loading" (LOAD_IMAGE); as the info is no load, the CSR stayed there and the
; menu drew the line as not loaded ("<No Disk>") although the image was still
; mounted. So BROWSE_EXTRA keeps the line's text and "loaded" flag while it
; lists the cards (SDD_SNAP, before anything is chosen), and the info puts
; them back (SDD_RESTORE): the text, and the CSR as the flag says (the Shell's
; poll, CRTROM_MLST_GET, takes the flag from it).
; ----------------------------------------------------------------------------

SDD_LINE_MAX    .EQU    64                      ; SDD_LINE's size (the width: 26)

; SDD_SNAP: R10 = the menu group of the line the browser is for (BROWSE_EXTRA's
; context data). All registers preserved.
SDD_SNAP        SYSCALL(enter, 1)
                RSUB    _SDD_UNIT, 1            ; R8: the unit
                MOVE    R8, R0                  ; R0: the unit
                RSUB    _SDD_LINEBUF, 1         ; R8: the text, R9: the width
                CMP     0, R8
                RBRA    _SDDS_RET, Z            ; no menu heap (yet)
                RSUB    _SDD_WIDTH, 1           ; R9: the words to keep
                MOVE    SDD_SV_W, R1
                MOVE    R9, @R1
                MOVE    SDD_LINE, R2
_SDDS_CP        MOVE    @R8++, @R2++
                SUB     1, R9
                RBRA    _SDDS_CP, !Z
                MOVE    CRTROM_MAN_LDF, R1      ; the "loaded" flag
                ADD     R0, R1
                MOVE    SDD_SV_LDF, R2
                MOVE    @R1, @R2
                MOVE    SDD_SV_UNIT, R1         ; valid for this unit
                MOVE    R0, @R1
_SDDS_RET       SYSCALL(leave, 1)
                RET

; SDD_RESTORE: R9 = the unit (PREP_LOAD_IMAGE's). All registers preserved.
SDD_RESTORE     SYSCALL(enter, 1)
                MOVE    SDD_SV_UNIT, R0
                CMP     @R0, R9
                RBRA    _SDDR_RET, !Z           ; nothing kept for this line
                MOVE    R9, R0                  ; R0: the unit
                MOVE    R9, R8
                RSUB    _SDD_LINEBUF, 1         ; R8: the text
                CMP     0, R8
                RBRA    _SDDR_RET, Z
                MOVE    SDD_SV_W, R3
                MOVE    @R3, R3
                MOVE    SDD_LINE, R2
_SDDR_CP        MOVE    @R2++, @R8++
                SUB     1, R3
                RBRA    _SDDR_CP, !Z

                MOVE    SDD_DEVSEL, R8          ; the device's CSR: loaded or
                RSUB    SAVE_DEVSEL, 1          ; not, as before
                MOVE    PC_DEV_DISK, R1
                ADD     R0, R1
                MOVE    M2M$RAMROM_DEV, R2
                MOVE    R1, @R2
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    CRTROM_CSR_4KWIN, @R2
                MOVE    CRTROM_CSR_ST_IDLE, R2
                MOVE    SDD_SV_LDF, R1
                CMP     0, @R1
                RBRA    _SDDR_ST, Z
                MOVE    CRTROM_CSR_ST_OK, R2
_SDDR_ST        MOVE    CRTROM_CSR_STATUS, R1
                MOVE    R2, @R1
                MOVE    SDD_DEVSEL, R8
                RSUB    RESTORE_DEVSEL, 1
_SDDR_RET       SYSCALL(leave, 1)
                RET

; _SDD_UNIT: R10 = a disk line's menu group -> R8 = its unit (0 A:, 1 B:, 2
; the hard disk, 3 the CD-ROM; as PREP_LOAD_IMAGE)
_SDD_UNIT       XOR     R8, R8
                CMP     PC_OPTM_G_FDD_B, R10
                RBRA    _SDDU_1, !Z
                MOVE    1, R8
_SDDU_1         CMP     PC_OPTM_G_HDD, R10
                RBRA    _SDDU_2, !Z
                MOVE    2, R8
_SDDU_2         CMP     PC_OPTM_G_CD, R10
                RBRA    _SDDU_3, !Z
                MOVE    3, R8
_SDDU_3         RET

; _SDD_LINEBUF: R8 = a unit -> R8 = its line's text buffer in OPTM_HEAP ((vdrives
; + submenus + unit) * @SCR$OSM_O_DX, as DAN_FLUSH; 0: no heap yet), R9 = the
; width. R10, R11 changed.
_SDD_LINEBUF    MOVE    OPTM_HEAP, R10
                MOVE    @R10, R10
                RBRA    _SDDL_NONE, Z
                MOVE    R10, @--SP              ; (the heap)
                MOVE    VDRIVES_NUM, R9
                ADD     @R9, R8
                MOVE    OPTM_SCOUNT, R9
                ADD     @R9, R8
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9
                SYSCALL(mulu, 1)                ; R10: the offset
                MOVE    @SP++, R8
                ADD     R10, R8
                RET
_SDDL_NONE      XOR     R8, R8
                RET

; _SDD_WIDTH: R9 = the width -> R9 = the words to keep (at most SDD_LINE_MAX)
_SDD_WIDTH      MOVE    SDD_LINE_MAX, R10
                SUB     R9, R10                 ; SDD_LINE_MAX - width
                RBRA    _SDDW_RET, !N
                MOVE    SDD_LINE_MAX, R9
_SDDW_RET       RET

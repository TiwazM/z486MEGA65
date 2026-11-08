; ****************************************************************************
; z486 for MEGA65
;
; CD images for the CD-ROM drive (pc_cdrom.vhd): CD_PREP mounts the chosen
; file as the disc. It may be
;   * an ISO image: one data track of 2048-byte sectors;
;   * a raw .bin: one data track of 2352-byte sectors (the sync pattern
;     00 FF x 10 00 at its start; MODE2 when byte 15 is 2);
;   * a .cue sheet (text) with its files in the same folder: FILE (BINARY,
;     MOTOROLA = big-endian audio, WAVE = PCM 16-bit stereo 44.1 kHz), TRACK
;     (AUDIO, MODE1/2048, MODE1/2352, MODE2/2352, MODE2/2336), INDEX 00/01,
;     PREGAP, POSTGAP; REM, TITLE, FLAGS and the rest are skipped.
; It writes
;   * unit 3's extent map (disk_sd.vhd): the disc's files back to back, each
;     from a cluster boundary, one "virtual image" of SECTS 512-byte sectors;
;     made in a staging copy that QNICE can read back (FAT32$FILE_MAP writes
;     a file's count over the word before its extents: the previous file's
;     last word, put back), then copied to disk_sd's map, which QNICE can
;     only write (CDI_PUTMAP);
;   * pc_cdrom.vhd's track table (device PC_DEV_CDTOC, window 0; the layout
;     is described there and below at CDT_*).
; The disc's layout is DOSBox's and MiSTer's: LBA 0 is track 1's INDEX 01;
; INDEX 00..01 is the track's pregap, data in its file; PREGAP and POSTGAP
; are silence in no file and move every later track; a track's sectors come
; from its file's exact size. One file may hold tracks of different sector
; sizes (MODE1/2048 data, then 2352-byte audio): the cue's frames in it are
; each the size of the track they belong to (CDI_REL, CDI_FEND).
;
; The release firmware has this in a code bank (m2m-rom.asm, FAR_CALL); the
; QNICE emulator test (CORE/m2m-rom/test/) has it flat. The includer gives
;   CDI_SEL      R8 = 0 the table, 1/2 the cue text's two windows, 3 the
;                extent map's staging copy (a third window), 4 unit 3's extent
;                map (written only): selects it, R8 = its address; registers
;                kept
;   the variables of cdimage_vars.asm (RAM)
; CD_PREP: R8 = the chosen file's handle (open). Output: R8 = 0, R9/R10 =
; SECTS lo/hi; or R8 = an error code (CDI_E_*). R11, R12 kept.
; ****************************************************************************

; the track table (16-bit words)
CDT_N           .EQU    0x0000                  ; tracks
CDT_TRK         .EQU    0x0001                  ; the first track | the last << 8
CDT_LEAD        .EQU    0x0002                  ; the lead-out's LBA lo, hi
CDT_MEDIUM      .EQU    0x0004                  ; 01h data, 02h audio, 03h both
CDT_LEADMS      .EQU    0x0005                  ; the lead-out's M | S << 8
CDT_LEADF       .EQU    0x0006                  ; and its F
CDT_TOC_LBA     .EQU    0x0100                  ; READ TOC's track descriptors
CDT_TOC_MSF     .EQU    0x0300                  ; (8 bytes, 4 words: byte 2k low)
CDT_ENT         .EQU    0x0800                  ; the tracks, 16 words each:
CDE_NUM         .EQU    0                       ; number | control << 8
CDE_SSIZE       .EQU    1                       ; sector size in the file
CDE_OFF         .EQU    2                       ; user data offset in a sector
CDE_FLAGS       .EQU    3                       ; 1 audio, 2 big-endian audio
CDE_START       .EQU    4                       ; its first LBA (INDEX 00)
CDE_IDX1        .EQU    6                       ; INDEX 01
CDE_FB          .EQU    8                       ; the first LBA in its file
CDE_FE          .EQU    10                      ; the end of those (excl.)
CDE_END         .EQU    12                      ; its end (excl.)
CDE_BYTE        .EQU    14                      ; the virtual image's byte of FB

CDI_E_SIZE      .EQU    0x00F1                  ; ISO/BIN: not whole sectors
CDI_E_FRAG      .EQU    0x00F2                  ; the extent map is full
CDI_E_CUE       .EQU    0x00F3                  ; a cue the parser can't read
CDI_E_FILE      .EQU    0x00F4                  ; a FILE is not there
CDI_E_FAT       .EQU    0x00F5                  ; a FAT32 error (CDI_FATERR)
CDI_E_LONG      .EQU    0x00F6                  ; the cue is over 16K characters
CDI_E_WAVE      .EQU    0x00F7                  ; a WAVE that isn't 16/2/44100
CDI_E_TYPE      .EQU    0x00F8                  ; MP3 or another file type

CDI_MAXLEN      .EQU    16384                   ; the cue text: 2 windows x 4K x 2

; a track as the parser collects it (CDI_PREV, CDI_CUR)
CDR_NUM         .EQU    0
CDR_CTL         .EQU    1
CDR_SSIZE       .EQU    2
CDR_OFF         .EQU    3
CDR_FLAGS       .EQU    4
CDR_HAS0        .EQU    5
CDR_HAS1        .EQU    6
CDR_IDX0        .EQU    7                       ; frames in the file (2 words)
CDR_IDX1        .EQU    9
CDR_PRE         .EQU    11
CDR_POST        .EQU    13
CDR_SHB         .EQU    15                      ; the gaps before it
CDR_FSTART      .EQU    17                      ; its file's first frame
CDR_FBASE       .EQU    19                      ; its file's virtual byte
CDR_FSECT       .EQU    21                      ; its file's sectors
CDR_FID         .EQU    23
CDR_FREL        .EQU    24                      ; its first frame's byte in its file
CDR_SIZE        .EQU    26

; ----------------------------------------------------------------------------
; CD_PREP
; ----------------------------------------------------------------------------

CD_PREP         INCRB
                MOVE    R11, @--SP
                MOVE    R12, @--SP
                MOVE    CDI_HFDH, R0
                MOVE    R8, @R0

                ; the state, the table's header
                MOVE    CDI_VSTART, R0
_CDP_CLR        MOVE    0, @R0++
                CMP     CDI_VEND, R0
                RBRA    _CDP_CLR, !Z
                MOVE    CDI_HFDH, R0            ; (cleared above)
                MOVE    R8, @R0
                MOVE    @R8, R1                 ; FDH_DEVICE = 0
                MOVE    CDI_DEV, R0
                MOVE    R1, @R0
                XOR     R8, R8
                RSUB    CDI_SEL, 1
                MOVE    16, R2
_CDP_CLRT       MOVE    0, @R8++
                SUB     1, R2
                RBRA    _CDP_CLRT, !Z

                ; the cluster shift: 9 + log2(sectors per cluster)
                ADD     FAT32$DEV_SECT_PER_CLUS, R1
                MOVE    @R1, R1
                MOVE    9, R2
_CDP_CS         CMP     R1, 1
                RBRA    _CDP_CSD, !N            ; R1 <= 1
                AND     0xFFFB, SR
                SHR     1, R1
                ADD     1, R2
                RBRA    _CDP_CS, 1
_CDP_CSD        MOVE    CDI_CSH, R0
                MOVE    R2, @R0

                ; the first 16 bytes (an end of file reads as a line feed)
                MOVE    CDI_HDR, R4
                MOVE    16, R5
_CDP_HDR        MOVE    CDI_HFDH, R8
                MOVE    @R8, R8
                RSUB    FAT32$FILE_RB, 1
                CMP     0, R10
                RBRA    _CDP_HDRZ, !Z
                MOVE    R9, @R4++
                RBRA    _CDP_HDRN, 1
_CDP_HDRZ       MOVE    0x000A, @R4++
_CDP_HDRN       SUB     1, R5
                RBRA    _CDP_HDR, !Z
                MOVE    CDI_HFDH, R8
                MOVE    @R8, R8
                XOR     R9, R9
                XOR     R10, R10
                RSUB    FAT32$FILE_SEEK, 1
                CMP     0, R9
                RBRA    _CDP_FAT, !Z

                ; the sync pattern: a raw .bin
                MOVE    CDI_HDR, R4
                CMP     0, @R4++
                RBRA    _CDP_NSYNC, !Z
                MOVE    10, R5
_CDP_SY         CMP     0x00FF, @R4++
                RBRA    _CDP_NSYNC, !Z
                SUB     1, R5
                RBRA    _CDP_SY, !Z
                CMP     0, @R4
                RBRA    _CDP_BIN, Z

                ; text (tab, LF, CR, 20h..7Eh, a UTF-8 byte order mark) in a
                ; file under 32K: a cue. An ISO 9660 image is 18 sectors (36K)
                ; at least, and its first 16 bytes may well be text.
_CDP_NSYNC      MOVE    CDI_HFDH, R0
                MOVE    @R0, R0
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_HI, R1
                CMP     0, @R1
                RBRA    _CDP_ISO, !Z
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                CMP     @R1, 0x7FFF             ; 32K or more
                RBRA    _CDP_ISO, N
                MOVE    CDI_HDR, R4
                MOVE    16, R5
                CMP     0x00EF, @R4
                RBRA    _CDP_TX, !Z
                ADD     3, R4
                SUB     3, R5
_CDP_TX         MOVE    @R4++, R6
                CMP     0x0009, R6
                RBRA    _CDP_TXN, Z
                CMP     0x000A, R6
                RBRA    _CDP_TXN, Z
                CMP     0x000D, R6
                RBRA    _CDP_TXN, Z
                CMP     0x0020, R6              ; below 20h
                RBRA    _CDP_ISO, N
                CMP     R6, 0x007E              ; above 7Eh
                RBRA    _CDP_ISO, N
_CDP_TXN        SUB     1, R5
                RBRA    _CDP_TX, !Z
                RBRA    _CDP_CUE, 1

                ; an ISO or a raw .bin: one data track, the whole file
_CDP_ISO        MOVE    2048, R6                ; R6: the sector size
                XOR     R7, R7                  ; R7: the user data offset
                RBRA    _CDP_ONE, 1
_CDP_BIN        MOVE    2352, R6
                MOVE    16, R7
                MOVE    CDI_HDR, R4
                ADD     15, R4
                CMP     2, @R4
                RBRA    _CDP_ONE, !Z
                MOVE    24, R7
_CDP_ONE        MOVE    CDI_HFDH, R0
                MOVE    @R0, R0                 ; R0: the handle
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                MOVE    @R1, R8
                MOVE    R0, R1
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R9
                MOVE    R6, R10
                XOR     R11, R11
                RSUB    MTH$DIVU32, 1           ; R9:R8 sectors, R11:R10 rest
                CMP     0, R10
                RBRA    _CDP_ESIZE, !Z
                MOVE    R8, R4                  ; R5:R4: the sectors
                MOVE    R9, R5
                OR      R9, R8
                RBRA    _CDP_ESIZE, Z
                MOVE    R0, R8
                RSUB    CDI_MAP, 1              ; R10:R9: its virtual byte
                CMP     0, R8
                RBRA    _CDP_RET, !Z
                MOVE    CDI_CUR, R0
                MOVE    1, @R0++                ; NUM
                MOVE    0x0014, @R0++           ; CTL
                MOVE    R6, @R0++               ; SSIZE
                MOVE    R7, @R0++               ; OFF
                MOVE    0, @R0++                ; FLAGS
                MOVE    0, @R0++                ; HAS0
                MOVE    1, @R0++                ; HAS1
                MOVE    CDI_CUR, R0
                ADD     CDR_FBASE, R0
                MOVE    R9, @R0++
                MOVE    R10, @R0++
                MOVE    R4, @R0++               ; FSECT
                MOVE    R5, @R0++
                MOVE    CDI_CUR, R8
                MOVE    R4, R9
                MOVE    R5, R10
                RSUB    CDI_FINAL, 1
                CMP     0, R8
                RBRA    _CDP_RET, !Z
                RBRA    _CDP_HEAD, 1

                ; a cue: its text into the scratch windows, then parsed
_CDP_CUE        RSUB    CDI_LOAD, 1
                CMP     0, R8
                RBRA    _CDP_RET, !Z
                RSUB    CDI_PARSE, 1
                CMP     0, R8
                RBRA    _CDP_RET, !Z
                MOVE    CDI_NTR, R0
                CMP     0, @R0
                RBRA    _CDP_ECUE, Z

                ; the map to unit 3, the header; SECTS = clusters << (shift - 9)
_CDP_HEAD       RSUB    CDI_PUTMAP, 1
                RSUB    CDI_HEADER, 1
                MOVE    CDI_CLUS, R0
                MOVE    @R0++, R9
                MOVE    @R0, R10
                MOVE    CDI_CSH, R0
                MOVE    @R0, R0
                SUB     9, R0
                RBRA    _CDP_OK, Z
_CDP_SECT       ADD     R9, R9
                ADDC    R10, R10
                SUB     1, R0
                RBRA    _CDP_SECT, !Z
_CDP_OK         XOR     R8, R8
                RBRA    _CDP_RET, 1

_CDP_ESIZE      MOVE    CDI_E_SIZE, R8
                RBRA    _CDP_RET, 1
_CDP_ECUE       MOVE    CDI_E_CUE, R8
                RBRA    _CDP_RET, 1
_CDP_FAT        MOVE    CDI_FATERR, R0
                MOVE    R9, @R0
                MOVE    CDI_E_FAT, R8
_CDP_RET        MOVE    @SP++, R12
                MOVE    @SP++, R11
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_MAP: append the extents of the open file R8 to the map's staging copy;
; the file starts at the next cluster of the virtual image. Output: R8 = 0,
; R10:R9 = its virtual byte; or R8 = an error code. CDI_CLUS grows by its
; clusters.
; ----------------------------------------------------------------------------

CDI_MAP         INCRB
                MOVE    R8, R7                  ; R7: the handle
                MOVE    CDI_NEXT, R6
                MOVE    @R6, R6                 ; R6: the extents so far
                CMP     R6, 510                 ; room for one more?
                RBRA    _CDM_FRAG, N            ; (R6 > 510: no)
                MOVE    3, R8
                RSUB    CDI_SEL, 1
                MOVE    R8, R0                  ; R0: the map (staging)
                MOVE    R6, R1
                AND     0xFFFD, SR
                SHL     2, R1
                ADD     R0, R1                  ; R1: where its count goes
                MOVE    @R1, R2                 ; R2: the word it overwrites
                MOVE    R7, R8
                MOVE    R1, R9
                MOVE    2048, R10
                SUB     R6, R10
                SUB     R6, R10
                SUB     R6, R10
                SUB     R6, R10
                RSUB    FAT32$FILE_MAP, 1
                CMP     FAT32$ERR_MAPSIZE, R9
                RBRA    _CDM_FRAG, Z
                CMP     0, R9
                RBRA    _CDM_FAT, !Z
                MOVE    R10, R3                 ; R3: its extents
                MOVE    3, R8
                RSUB    CDI_SEL, 1
                CMP     0, R6
                RBRA    _CDM_N0, Z
                MOVE    R2, @R1                 ; the earlier extent's last word
_CDM_N0         ADD     R3, R6
                MOVE    R6, @R0                 ; the count of all
                MOVE    CDI_NEXT, R2
                MOVE    R6, @R2

                ; its virtual byte: CDI_CLUS << shift
                MOVE    CDI_CLUS, R0
                MOVE    @R0++, R9
                MOVE    @R0, R10
                MOVE    CDI_CSH, R4
                MOVE    @R4, R4
_CDM_VB         ADD     R9, R9
                ADDC    R10, R10
                SUB     1, R4
                RBRA    _CDM_VB, !Z

                ; its clusters: (size + cluster - 1) >> shift
                MOVE    R7, R0
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R2
                MOVE    R7, R0
                ADD     FAT32$FDH_SIZE_HI, R0
                MOVE    @R0, R3                 ; R3:R2: the size
                MOVE    1, R4                   ; R5:R4: the cluster - 1
                XOR     R5, R5
                MOVE    CDI_CSH, R0
                MOVE    @R0, R0
_CDM_CB         ADD     R4, R4
                ADDC    R5, R5
                SUB     1, R0
                RBRA    _CDM_CB, !Z
                SUB     1, R4
                SUBC    0, R5
                ADD     R4, R2
                ADDC    R5, R3
                MOVE    CDI_CSH, R0
                MOVE    @R0, R0
_CDM_SH         RSUB    CDI_SHR1, 1             ; R3:R2 >> 1
                SUB     1, R0
                RBRA    _CDM_SH, !Z
                MOVE    CDI_CLUS, R0
                ADD     R2, @R0++
                ADDC    R3, @R0
                XOR     R8, R8
                DECRB
                RET
_CDM_FRAG       MOVE    CDI_E_FRAG, R8
                DECRB
                RET
_CDM_FAT        MOVE    CDI_FATERR, R0
                MOVE    R9, @R0
                MOVE    CDI_E_FAT, R8
                DECRB
                RET

; CDI_SHR1: the caller's own R3:R2 >> 1 (no INCRB); R8 changes
CDI_SHR1        MOVE    R3, R8
                AND     1, R8
                AND     0xFFFB, SR
                SHR     1, R3
                AND     0xFFFB, SR
                CMP     0, R8
                RBRA    _CDS1_C0, Z
                OR      0x0004, SR
_CDS1_C0        SHR     1, R2
                RET

; ----------------------------------------------------------------------------
; CDI_PUTMAP: the map from its staging copy to unit 3's (disk_sd.vhd's map
; RAM: QNICE writes it, reads give 0), word 0 and CDI_NEXT extents. Registers
; kept.
; ----------------------------------------------------------------------------

CDI_PUTMAP      INCRB
                MOVE    R8, R4
                MOVE    CDI_NEXT, R2
                MOVE    @R2, R2
                AND     0xFFFD, SR
                SHL     2, R2
                ADD     1, R2                   ; R2: words
                XOR     R3, R3                  ; R3: the word
_CDPM_LOOP      MOVE    3, R8
                RSUB    CDI_SEL, 1
                ADD     R3, R8
                MOVE    @R8, R1
                MOVE    4, R8
                RSUB    CDI_SEL, 1
                ADD     R3, R8
                MOVE    R1, @R8
                ADD     1, R3
                SUB     1, R2
                RBRA    _CDPM_LOOP, !Z
                MOVE    R4, R8
                DECRB
                RET

; ----------------------------------------------------------------------------
; The cue text: CDI_LOAD reads the file into the scratch windows (two
; characters a word, the first in the low byte); CDI_GETC R8 = the character
; at R8 (0 past the end); CDI_PUTC puts R9 at R8. Registers kept but R8.
; ----------------------------------------------------------------------------

CDI_LOAD        INCRB
                XOR     R4, R4                  ; R4: characters
_CDL_LOOP       MOVE    CDI_HFDH, R8
                MOVE    @R8, R8
                RSUB    FAT32$FILE_RB, 1
                CMP     FAT32$EOF, R10
                RBRA    _CDL_EOF, Z
                CMP     0, R10
                RBRA    _CDL_FAT, !Z
                CMP     CDI_MAXLEN, R4
                RBRA    _CDL_LONG, Z
                MOVE    R4, R8
                RSUB    CDI_PUTC, 1
                ADD     1, R4
                RBRA    _CDL_LOOP, 1
_CDL_EOF        MOVE    CDI_LEN, R0
                MOVE    R4, @R0
                XOR     R8, R8
                DECRB
                RET
_CDL_LONG       MOVE    CDI_E_LONG, R8
                DECRB
                RET
_CDL_FAT        MOVE    CDI_FATERR, R0
                MOVE    R10, @R0
                MOVE    CDI_E_FAT, R8
                DECRB
                RET

; R8: the character's index -> R0: its word's address (the window selected),
; R1: 0 the low byte, 1 the high one
_CDI_CADDR      MOVE    R8, R1
                AND     1, R1
                AND     0xFFFB, SR
                SHR     1, R8                   ; R8: the word
                MOVE    R8, R0
                AND     0x0FFF, R0
                AND     0xFFFB, SR
                SHR     12, R8
                ADD     1, R8                   ; window 1 or 2
                RSUB    CDI_SEL, 1
                ADD     R8, R0
                RET

CDI_PUTC        INCRB
                RSUB    _CDI_CADDR, 1
                AND     0x00FF, R9
                CMP     0, R1
                RBRA    _CDPC_HI, !Z
                MOVE    R9, @R0
                DECRB
                RET
_CDPC_HI        SWAP    R9, R9
                OR      R9, @R0
                DECRB
                RET

CDI_GETC        INCRB
                MOVE    CDI_LEN, R0
                CMP     @R0, R8                 ; past the end?
                RBRA    _CDGC_IN, N             ; (len > R8: no)
                XOR     R8, R8
                DECRB
                RET
_CDGC_IN        RSUB    _CDI_CADDR, 1
                MOVE    @R0, R8
                CMP     0, R1
                RBRA    _CDGC_LO, Z
                SWAP    R8, R8
_CDGC_LO        AND     0x00FF, R8
                DECRB
                RET

; CDI_PEEK: R8 = the character at CDI_POS; CDI_ADV: CDI_POS + 1
CDI_PEEK        MOVE    CDI_POS, R8
                MOVE    @R8, R8
                RSUB    CDI_GETC, 1
                RET
CDI_ADV         MOVE    R8, @--SP
                MOVE    CDI_POS, R8
                ADD     1, @R8
                MOVE    @SP++, R8
                RET

; CDI_SKIPWS: past spaces and tabs; R8 = the next character
CDI_SKIPWS      RSUB    CDI_PEEK, 1
                CMP     0x0020, R8
                RBRA    _CDSW_ADV, Z
                CMP     0x0009, R8
                RBRA    _CDSW_ADV, Z
                RET
_CDSW_ADV       RSUB    CDI_ADV, 1
                RBRA    CDI_SKIPWS, 1

; CDI_SKIPLINE: past the line's end (LF; a CR alone ends it too)
CDI_SKIPLINE    RSUB    CDI_PEEK, 1
                CMP     0, R8
                RBRA    _CDSL_RET, Z
                RSUB    CDI_ADV, 1
                CMP     0x000A, R8
                RBRA    _CDSL_RET, Z
                CMP     0x000D, R8
                RBRA    CDI_SKIPLINE, !Z
                RSUB    CDI_PEEK, 1             ; CR LF
                CMP     0x000A, R8
                RBRA    _CDSL_RET, !Z
                RSUB    CDI_ADV, 1
_CDSL_RET       RET

; CDI_ISEND: C = 1 when R8 ends a word: 0, space, tab, CR, LF (C: RET is a
; MOVE to the PC, which sets Z and N)
CDI_ISEND       CMP     0, R8
                RBRA    _CDIE_YES, Z
                CMP     0x0020, R8
                RBRA    _CDIE_YES, Z
                CMP     0x0009, R8
                RBRA    _CDIE_YES, Z
                CMP     0x000D, R8
                RBRA    _CDIE_YES, Z
                CMP     0x000A, R8
                RBRA    _CDIE_YES, Z
                AND     0xFFFB, SR
                RET
_CDIE_YES       OR      0x0004, SR
                RET

; CDI_WORD: the next word, upper case, into CDI_TOK (15 characters at most,
; the rest skipped)
CDI_WORD        INCRB
                RSUB    CDI_SKIPWS, 1
                MOVE    CDI_TOK, R0
                MOVE    15, R1
_CDW_LOOP       RSUB    CDI_PEEK, 1
                RSUB    CDI_ISEND, 1
                RBRA    _CDW_END, C
                RSUB    CDI_ADV, 1
                CMP     0, R1
                RBRA    _CDW_LOOP, Z
                CMP     0x0061, R8              ; a..z -> A..Z
                RBRA    _CDW_PUT, N
                CMP     R8, 0x007A
                RBRA    _CDW_PUT, N
                SUB     0x0020, R8
_CDW_PUT        MOVE    R8, @R0++
                SUB     1, R1
                RBRA    _CDW_LOOP, 1
_CDW_END        MOVE    0, @R0
                DECRB
                RET

; CDI_NAMEP: the FILE's name, quoted or a word, into CDI_NAME. Output: R8 = 0
; or CDI_E_CUE
CDI_NAMEP       INCRB
                RSUB    CDI_SKIPWS, 1
                MOVE    CDI_NAME, R0
                MOVE    127, R1
                XOR     R2, R2                  ; R2: 1 = quoted
                CMP     0x0022, R8
                RBRA    _CDN_LOOP, !Z
                MOVE    1, R2
                RSUB    CDI_ADV, 1
_CDN_LOOP       RSUB    CDI_PEEK, 1
                CMP     0, R2
                RBRA    _CDN_BARE, Z
                CMP     0x0022, R8              ; the closing quote
                RBRA    _CDN_QEND, Z
                CMP     0, R8
                RBRA    _CDN_ERR, Z
                CMP     0x000A, R8
                RBRA    _CDN_ERR, Z
                CMP     0x000D, R8
                RBRA    _CDN_ERR, Z
                RBRA    _CDN_PUT, 1
_CDN_BARE       RSUB    CDI_ISEND, 1
                RBRA    _CDN_END, C
_CDN_PUT        CMP     0, R1
                RBRA    _CDN_ERR, Z
                MOVE    R8, @R0++
                SUB     1, R1
                RSUB    CDI_ADV, 1
                RBRA    _CDN_LOOP, 1
_CDN_QEND       RSUB    CDI_ADV, 1
_CDN_END        MOVE    0, @R0
                CMP     CDI_NAME, R0            ; an empty name
                RBRA    _CDN_ERR, Z
                XOR     R8, R8
                DECRB
                RET
_CDN_ERR        MOVE    CDI_E_CUE, R8
                DECRB
                RET

; CDI_NUM: a decimal number. Output: R8 = it; C = 1: none
CDI_NUM         INCRB
                RSUB    CDI_SKIPWS, 1
                XOR     R0, R0                  ; R0: the value
                XOR     R1, R1                  ; R1: digits
_CDNU_LOOP      RSUB    CDI_PEEK, 1
                CMP     0x0030, R8
                RBRA    _CDNU_END, N
                CMP     R8, 0x0039
                RBRA    _CDNU_END, N
                RSUB    CDI_ADV, 1
                SUB     0x0030, R8
                MOVE    R0, R2                  ; R0 * 10 + digit
                AND     0xFFFD, SR
                SHL     3, R0
                ADD     R2, R0
                ADD     R2, R0
                ADD     R8, R0
                ADD     1, R1
                RBRA    _CDNU_LOOP, 1
_CDNU_END       MOVE    R0, R8
                CMP     0, R1
                RBRA    _CDNU_NONE, Z
                AND     0xFFFB, SR              ; C = 0
                DECRB
                RET
_CDNU_NONE      OR      0x0004, SR              ; C = 1
                DECRB
                RET

; CDI_MSF: mm:ss:ff. Output: R9:R8 = (mm * 60 + ss) * 75 + ff; C = 1: no MSF
CDI_MSF         INCRB
                RSUB    CDI_NUM, 1
                RBRA    _CDMS_ERR, C
                MOVE    R8, R0                  ; R0: minutes
                RSUB    CDI_PEEK, 1
                CMP     0x003A, R8
                RBRA    _CDMS_ERR, !Z
                RSUB    CDI_ADV, 1
                RSUB    CDI_NUM, 1
                RBRA    _CDMS_ERR, C
                MOVE    R8, R1                  ; R1: seconds
                RSUB    CDI_PEEK, 1
                CMP     0x003A, R8
                RBRA    _CDMS_ERR, !Z
                RSUB    CDI_ADV, 1
                RSUB    CDI_NUM, 1
                RBRA    _CDMS_ERR, C
                MOVE    R8, R2                  ; R2: frames
                MOVE    R0, R8
                MOVE    60, R9
                RSUB    MTH$MULU, 1               ; R11:R10
                ADD     R1, R10
                MOVE    R10, R8
                MOVE    75, R9
                RSUB    MTH$MULU, 1
                ADD     R2, R10
                ADDC    0, R11
                MOVE    R10, R8
                MOVE    R11, R9
                AND     0xFFFB, SR
                DECRB
                RET
_CDMS_ERR       OR      0x0004, SR
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_PARSE: the cue, line by line. Output: R8 = 0 or an error code
; ----------------------------------------------------------------------------

CDI_PARSE       INCRB
                XOR     R8, R8                  ; a byte order mark
                RSUB    CDI_GETC, 1
                CMP     0x00EF, R8
                RBRA    _CPA_LINE, !Z
                MOVE    CDI_POS, R0
                MOVE    3, @R0

_CPA_LINE       RSUB    CDI_SKIPWS, 1
                CMP     0, R8
                RBRA    _CPA_EOF, Z
                RSUB    CDI_ISEND, 1            ; an empty line
                RBRA    _CPA_NEXT, C
                RSUB    CDI_WORD, 1
                MOVE    CDI_TOK, R8
                MOVE    CDK_FILE, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_FILE, Z
                MOVE    CDK_TRACK, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_TRACK, Z
                MOVE    CDK_INDEX, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_INDEX, Z
                MOVE    CDK_PREGAP, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_PREGAP, Z
                MOVE    CDK_POSTGAP, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_POSTGAP, Z
_CPA_NEXT       RSUB    CDI_SKIPLINE, 1         ; anything else: skipped
                RBRA    _CPA_LINE, 1

                ; FILE name type
_CPA_FILE       RSUB    CDI_DONE, 1
                CMP     0, R8
                RBRA    _CPA_RET, !Z
                RSUB    CDI_NAMEP, 1
                CMP     0, R8
                RBRA    _CPA_RET, !Z
                RSUB    CDI_WORD, 1
                XOR     R0, R0                  ; R0: 0 BINARY, 2 MOTOROLA, 1 WAVE
                MOVE    CDI_TOK, R8
                MOVE    CDK_BINARY, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_FTY, Z
                MOVE    2, R0
                MOVE    CDK_MOTOROLA, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_FTY, Z
                MOVE    1, R0
                MOVE    CDK_WAVE, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_FTY, Z
                MOVE    CDI_E_TYPE, R8
                RBRA    _CPA_RET, 1
_CPA_FTY        MOVE    R0, R8
                RSUB    CDI_FILE, 1
                CMP     0, R8
                RBRA    _CPA_RET, !Z
                RBRA    _CPA_NEXT, 1

                ; TRACK nn mode
_CPA_TRACK      RSUB    CDI_DONE, 1
                CMP     0, R8
                RBRA    _CPA_RET, !Z
                MOVE    CDI_FID, R0             ; a FILE first
                CMP     0, @R0
                RBRA    _CPA_ECUE, Z
                RSUB    CDI_NUM, 1
                RBRA    _CPA_ECUE, C
                CMP     0, R8
                RBRA    _CPA_ECUE, Z
                CMP     R8, 99
                RBRA    _CPA_ECUE, N
                MOVE    R8, R1                  ; R1: the number
                RSUB    CDI_WORD, 1
                MOVE    CDK_MODES, R0           ; the modes: name, size, offset
_CPA_MODE       CMP     0, @R0                  ; (the table's end)
                RBRA    _CPA_ECUE, Z
                MOVE    CDI_TOK, R8
                MOVE    @R0, R9
                RSUB    STR$CMP, 1
                CMP     0, R10
                RBRA    _CPA_MODEF, Z
                ADD     4, R0
                RBRA    _CPA_MODE, 1
_CPA_MODEF      MOVE    CDI_CUR, R2             ; the track
                MOVE    R2, R3
                MOVE    CDR_SIZE, R4
_CPA_CCLR       MOVE    0, @R3++
                SUB     1, R4
                RBRA    _CPA_CCLR, !Z
                MOVE    R1, @R2                 ; NUM
                ADD     1, R0
                MOVE    @R0++, R4               ; R4: the sector size
                MOVE    R2, R3
                ADD     CDR_SSIZE, R3
                MOVE    R4, @R3++               ; SSIZE
                MOVE    @R0++, @R3++            ; OFF
                MOVE    @R0, R5                 ; R5: 1 audio
                MOVE    CDI_FFLAGS, R6
                OR      @R6, R5
                MOVE    R5, @R3                 ; FLAGS
                MOVE    R2, R3
                ADD     CDR_CTL, R3
                MOVE    0x0014, @R3
                AND     1, R5
                RBRA    _CPA_CTL, Z
                MOVE    0x0010, @R3
_CPA_CTL        MOVE    CDI_S, R3               ; SHB: the gaps so far
                MOVE    R2, R5
                ADD     CDR_SHB, R5
                MOVE    @R3++, @R5++
                MOVE    @R3, @R5
                MOVE    CDI_FSTART, R3          ; its file
                MOVE    R2, R5
                ADD     CDR_FSTART, R5
                MOVE    @R3++, @R5++
                MOVE    @R3, @R5++
                MOVE    CDI_FBASE, R3
                MOVE    @R3++, @R5++
                MOVE    @R3, @R5++
                MOVE    CDI_FSSIZE, R3          ; the file's sectors: from its
                CMP     0, @R3                  ; first track's sector size
                RBRA    _CPA_FSD, !Z
                MOVE    R4, @R3
                MOVE    CDI_FSIZE, R3
                MOVE    @R3++, R8
                MOVE    @R3, R9
                MOVE    R4, R10
                XOR     R11, R11
                RSUB    MTH$DIVU32, 1
                MOVE    CDI_FSECT, R3
                MOVE    R8, @R3++
                MOVE    R9, @R3
_CPA_FSD        MOVE    CDI_FSECT, R3
                MOVE    @R3++, @R5++            ; FSECT
                MOVE    @R3, @R5++
                MOVE    CDI_FID, R3
                MOVE    @R3, @R5                ; FID
                MOVE    CDI_CV, R3
                MOVE    1, @R3
                RBRA    _CPA_NEXT, 1

                ; INDEX nn mm:ss:ff
_CPA_INDEX      MOVE    CDI_CV, R0
                CMP     0, @R0
                RBRA    _CPA_ECUE, Z
                RSUB    CDI_NUM, 1
                RBRA    _CPA_ECUE, C
                MOVE    R8, R1
                RSUB    CDI_MSF, 1
                RBRA    _CPA_ECUE, C
                MOVE    CDI_CUR, R2
                CMP     0, R1
                RBRA    _CPA_IDX0, Z
                CMP     1, R1
                RBRA    _CPA_NEXT, !Z           ; INDEX 02.. : skipped
                MOVE    R2, R3
                ADD     CDR_HAS1, R3
                MOVE    1, @R3
                MOVE    R2, R3
                ADD     CDR_IDX1, R3
                RBRA    _CPA_IDXS, 1
_CPA_IDX0       MOVE    R2, R3
                ADD     CDR_HAS0, R3
                MOVE    1, @R3
                MOVE    R2, R3
                ADD     CDR_IDX0, R3
_CPA_IDXS       MOVE    R8, @R3++
                MOVE    R9, @R3
                RBRA    _CPA_NEXT, 1

                ; PREGAP / POSTGAP mm:ss:ff
_CPA_PREGAP     MOVE    CDR_PRE, R1
                RBRA    _CPA_GAP, 1
_CPA_POSTGAP    MOVE    CDR_POST, R1
_CPA_GAP        MOVE    CDI_CV, R0
                CMP     0, @R0
                RBRA    _CPA_ECUE, Z
                RSUB    CDI_MSF, 1
                RBRA    _CPA_ECUE, C
                ADD     CDI_CUR, R1
                MOVE    R8, @R1++
                MOVE    R9, @R1
                RBRA    _CPA_NEXT, 1

                ; the end: the last tracks
_CPA_EOF        RSUB    CDI_DONE, 1
                CMP     0, R8
                RBRA    _CPA_RET, !Z
                RSUB    CDI_FEND, 1             ; the last file's frames
                XOR     R8, R8
                MOVE    CDI_PV, R0
                CMP     0, @R0
                RBRA    _CPA_RET, Z             ; (R8 = 0)
                MOVE    CDI_PREV, R8
                MOVE    R8, R0
                ADD     CDR_FSECT, R0
                MOVE    @R0++, R9
                MOVE    @R0, R10
                RSUB    CDI_FINAL, 1
                RBRA    _CPA_RET, 1
_CPA_ECUE       MOVE    CDI_E_CUE, R8
_CPA_RET        DECRB
                RET

CDK_FILE        .ASCII_W "FILE"
CDK_TRACK       .ASCII_W "TRACK"
CDK_INDEX       .ASCII_W "INDEX"
CDK_PREGAP      .ASCII_W "PREGAP"
CDK_POSTGAP     .ASCII_W "POSTGAP"
CDK_BINARY      .ASCII_W "BINARY"
CDK_MOTOROLA    .ASCII_W "MOTOROLA"
CDK_WAVE        .ASCII_W "WAVE"
CDK_AUDIO       .ASCII_W "AUDIO"
CDK_M1_2048     .ASCII_W "MODE1/2048"
CDK_M1_2352     .ASCII_W "MODE1/2352"
CDK_M2_2352     .ASCII_W "MODE2/2352"
CDK_M2_2336     .ASCII_W "MODE2/2336"
; the track modes: the name, the sector size, the user data offset, 1 audio
CDK_MODES       .DW     CDK_AUDIO,   2352, 0,  1
                .DW     CDK_M1_2048, 2048, 0,  0
                .DW     CDK_M1_2352, 2352, 16, 0
                .DW     CDK_M2_2352, 2352, 24, 0
                .DW     CDK_M2_2336, 2336, 8,  0
                .DW     0

; ----------------------------------------------------------------------------
; CDI_FILE: a FILE line's file (its name in CDI_NAME; R8 = 0 BINARY, 2
; MOTOROLA, 1 WAVE) becomes the current file: it starts after the last one's
; sectors, its extents go into the map. Output: R8 = 0 or an error code
; ----------------------------------------------------------------------------

CDI_FILE        INCRB
                MOVE    R8, R7                  ; R7: the type
                MOVE    CDI_FID, R0             ; after the last file
                CMP     0, @R0
                RBRA    _CDF_FIRST, Z
                RSUB    CDI_FEND, 1
                MOVE    CDI_FSTART, R1
                MOVE    CDI_FSECT, R2
                ADD     @R2++, @R1++
                ADDC    @R2, @R1
_CDF_FIRST      ADD     1, @R0
                MOVE    CDI_FSSIZE, R0
                MOVE    0, @R0
                MOVE    CDI_RSZ, R0             ; no track of it yet (CDI_REL)
                MOVE    0, @R0
                MOVE    CDI_FSECT, R0
                MOVE    0, @R0++
                MOVE    0, @R0
                MOVE    CDI_FFLAGS, R0
                MOVE    R7, @R0
                AND     2, @R0                  ; (MOTOROLA: big-endian audio)

                MOVE    CDI_DEV, R8
                MOVE    @R8, R8
                MOVE    CDI_FDH, R9
                MOVE    CDI_NAME, R10
                XOR     R11, R11
                RSUB    FAT32$FILE_OPEN, 1
                CMP     0, R10
                RBRA    _CDF_NOF, !Z

                MOVE    CDI_FDH, R0             ; R3:R2: its size
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R2
                MOVE    CDI_FDH, R0
                ADD     FAT32$FDH_SIZE_HI, R0
                MOVE    @R0, R3
                XOR     R4, R4                  ; R5:R4: the data's offset
                XOR     R5, R5
                CMP     1, R7
                RBRA    _CDF_MAP, !Z
                RSUB    CDI_WAVE, 1             ; R5:R4 offset, R3:R2 length
                CMP     0, R8
                RBRA    _CDF_RET, !Z
_CDF_MAP        MOVE    CDI_FSIZE, R0
                MOVE    R2, @R0++
                MOVE    R3, @R0
                MOVE    CDI_FDH, R8
                RSUB    CDI_MAP, 1
                CMP     0, R8
                RBRA    _CDF_RET, !Z
                ADD     R4, R9                  ; FBASE: + the data's offset
                ADDC    R5, R10
                MOVE    CDI_FBASE, R0
                MOVE    R9, @R0++
                MOVE    R10, @R0
                XOR     R8, R8
                RBRA    _CDF_RET, 1
_CDF_NOF        MOVE    CDI_E_FILE, R8
_CDF_RET        DECRB
                RET

; CDI_WAVE: CDI_FDH is a RIFF WAVE file: its "fmt " must be PCM, 2 channels,
; 44100 Hz, 16 bits. Output in the caller's own R2..R5 (no INCRB): R5:R4 =
; the "data" chunk's offset, R3:R2 = its length; R8 = 0 or an error code
CDI_WAVE        MOVE    R0, @--SP
                MOVE    R1, @--SP
                MOVE    R6, @--SP
                MOVE    R7, @--SP
                XOR     R4, R4                  ; R5:R4: the position
                XOR     R5, R5
                RSUB    _CDWV_R32, 1            ; "RIFF"
                RBRA    _CDWV_ERR, C
                CMP     0x4952, R8              ; "RI" (little-endian words)
                RBRA    _CDWV_ERR, !Z
                CMP     0x4646, R9              ; "FF"
                RBRA    _CDWV_ERR, !Z
                RSUB    _CDWV_R32, 1            ; its size
                RBRA    _CDWV_ERR, C
                RSUB    _CDWV_R32, 1            ; "WAVE"
                RBRA    _CDWV_ERR, C
                CMP     0x4157, R8              ; "WA"
                RBRA    _CDWV_ERR, !Z
                CMP     0x4556, R9              ; "VE"
                RBRA    _CDWV_ERR, !Z
                XOR     R7, R7                  ; R7: 1 = "fmt " was right
_CDWV_CHUNK     RSUB    _CDWV_R32, 1            ; a chunk: id, length
                RBRA    _CDWV_ERR, C
                MOVE    R8, R0                  ; R1:R0: the id
                MOVE    R9, R1
                RSUB    _CDWV_R32, 1
                RBRA    _CDWV_ERR, C
                MOVE    R8, R2                  ; R3:R2: the length
                MOVE    R9, R3
                CMP     0x6164, R0              ; "da"
                RBRA    _CDWV_NDATA, !Z
                CMP     0x6174, R1              ; "ta"
                RBRA    _CDWV_NDATA, !Z
                CMP     0, R7
                RBRA    _CDWV_ERR, Z            ; no "fmt " before it
                XOR     R8, R8
                RBRA    _CDWV_RET, 1
_CDWV_NDATA     CMP     0x6D66, R0              ; "fm"
                RBRA    _CDWV_SKIP, !Z
                CMP     0x2074, R1              ; "t "
                RBRA    _CDWV_SKIP, !Z
                RSUB    _CDWV_R32, 1            ; format 1, 2 channels
                RBRA    _CDWV_ERR, C
                CMP     1, R8
                RBRA    _CDWV_ERR, !Z
                CMP     2, R9
                RBRA    _CDWV_ERR, !Z
                RSUB    _CDWV_R32, 1            ; 44100 Hz
                RBRA    _CDWV_ERR, C
                CMP     44100, R8
                RBRA    _CDWV_ERR, !Z
                CMP     0, R9
                RBRA    _CDWV_ERR, !Z
                RSUB    _CDWV_R32, 1            ; bytes per second
                RBRA    _CDWV_ERR, C
                RSUB    _CDWV_R32, 1            ; alignment, 16 bits
                RBRA    _CDWV_ERR, C
                CMP     16, R9
                RBRA    _CDWV_ERR, !Z
                MOVE    1, R7
                SUB     16, R2                  ; the rest of it
                SUBC    0, R3
_CDWV_SKIP      MOVE    R2, R8                  ; even lengths: a pad byte
                AND     1, R8
                ADD     R8, R2
                ADDC    0, R3
                ADD     R2, R4
                ADDC    R3, R5
                MOVE    CDI_FDH, R8
                MOVE    R4, R9
                MOVE    R5, R10
                RSUB    FAT32$FILE_SEEK, 1
                CMP     0, R9
                RBRA    _CDWV_ERR, !Z
                RBRA    _CDWV_CHUNK, 1
_CDWV_ERR       MOVE    CDI_E_WAVE, R8
_CDWV_RET       MOVE    @SP++, R7
                MOVE    @SP++, R6
                MOVE    @SP++, R1
                MOVE    @SP++, R0
                RET

; four bytes, little-endian: R9:R8; R5:R4 + 4; C = 1 at the end
_CDWV_R32       MOVE    R0, @--SP
                MOVE    R1, @--SP
                MOVE    4, R0
                XOR     R1, R1                  ; R1: the shift (0, 8: R8; 16, 24: R9)
                MOVE    R6, @--SP
                XOR     R6, R6
                MOVE    R7, @--SP
                XOR     R7, R7
_CDWR_LOOP      MOVE    CDI_FDH, R8
                RSUB    FAT32$FILE_RB, 1
                CMP     0, R10
                RBRA    _CDWR_EOF, !Z
                AND     0x00FF, R9
                CMP     8, R1
                RBRA    _CDWR_NS, Z
                CMP     24, R1
                RBRA    _CDWR_NS, Z
                RBRA    _CDWR_PUT, 1
_CDWR_NS        SWAP    R9, R9
_CDWR_PUT       CMP     16, R1
                RBRA    _CDWR_HI, !N            ; (R1 >= 16)
                OR      R9, R6
                RBRA    _CDWR_NX, 1
_CDWR_HI        OR      R9, R7
_CDWR_NX        ADD     8, R1
                ADD     1, R4
                ADDC    0, R5
                SUB     1, R0
                RBRA    _CDWR_LOOP, !Z
                MOVE    R6, R8
                MOVE    R7, R9
                MOVE    @SP++, R7
                MOVE    @SP++, R6
                MOVE    @SP++, R1
                MOVE    @SP++, R0
                AND     0xFFFB, SR
                RET
_CDWR_EOF       MOVE    @SP++, R7
                MOVE    @SP++, R6
                MOVE    @SP++, R1
                MOVE    @SP++, R0
                OR      0x0004, SR
                RET

; ----------------------------------------------------------------------------
; CDI_DONE: the current track has all its lines: the one before it gets its
; end (where this one's file data starts, or its file's end) and goes into
; the table; the gaps grow by this one's. Output: R8 = 0 or an error code
; ----------------------------------------------------------------------------

CDI_DONE        INCRB
                MOVE    CDI_CV, R0
                CMP     0, @R0
                RBRA    _CDD_OK, Z
                MOVE    CDI_CUR, R1
                MOVE    R1, R2
                ADD     CDR_HAS1, R2
                CMP     0, @R2
                RBRA    _CDD_ECUE, Z            ; no INDEX 01
                RSUB    CDI_REL, 1              ; its byte in its file
                MOVE    CDI_PV, R2
                CMP     0, @R2
                RBRA    _CDD_NOPREV, Z
                MOVE    CDI_PREV, R3            ; the one before: its end
                MOVE    R3, R4
                ADD     CDR_FID, R4
                MOVE    R1, R5
                ADD     CDR_FID, R5
                CMP     @R4, @R5
                RBRA    _CDD_OTHER, !Z
                MOVE    R1, R4                  ; the same file: this one's
                ADD     CDR_IDX1, R4            ; INDEX 00 or 01
                MOVE    R1, R5
                ADD     CDR_HAS0, R5
                CMP     0, @R5
                RBRA    _CDD_FE, Z
                MOVE    R1, R4
                ADD     CDR_IDX0, R4
                RBRA    _CDD_FE, 1
_CDD_OTHER      MOVE    R3, R4                  ; another file: its file's end
                ADD     CDR_FSECT, R4
_CDD_FE         MOVE    @R4++, R9
                MOVE    @R4, R10
                MOVE    R3, R8
                RSUB    CDI_FINAL, 1
                CMP     0, R8
                RBRA    _CDD_RET, !Z

                ; the gaps: + PREGAP (not track 1's) + POSTGAP
_CDD_NOPREV     MOVE    CDI_S, R3
                MOVE    CDI_PV, R2              ; track 1: the first track
                CMP     0, @R2
                RBRA    _CDD_POST, Z
                MOVE    R1, R4
                ADD     CDR_PRE, R4
                ADD     @R4++, @R3++
                ADDC    @R4, @R3
                MOVE    CDI_S, R3
_CDD_POST       MOVE    R1, R4
                ADD     CDR_POST, R4
                ADD     @R4++, @R3++
                ADDC    @R4, @R3

                MOVE    CDI_PREV, R3            ; it becomes the one before
                MOVE    CDR_SIZE, R4
_CDD_CP         MOVE    @R1++, @R3++
                SUB     1, R4
                RBRA    _CDD_CP, !Z
                MOVE    CDI_PV, R2
                MOVE    1, @R2
                MOVE    0, @R0                  ; CV
_CDD_OK         XOR     R8, R8
_CDD_RET        DECRB
                RET
_CDD_ECUE       MOVE    CDI_E_CUE, R8
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_REL: the current track (CDI_CUR, all its lines read) gets the byte in its
; file of its first frame there, FB (INDEX 00, or 01; track 1: always INDEX
; 01): the frames from the FB of the track before it in the same file are
; that track's sectors, the first track of a file counts its own. As DOSBox:
; a .bin with MODE1/2048 data and then 2352-byte audio (KQ6's).
;   FREL = RBY + (FB - RFB) * RSZ, or FB * its own size; then RFB = FB,
;   RBY = FREL, RSZ = its size
; ----------------------------------------------------------------------------

CDI_REL         INCRB
                MOVE    CDI_CUR, R7
                MOVE    R7, R2                  ; R1:R0 = FB
                ADD     CDR_IDX1, R2
                MOVE    CDI_PV, R3
                CMP     0, @R3
                RBRA    _CDRL_FB, Z             ; track 1: INDEX 01
                MOVE    R7, R3
                ADD     CDR_HAS0, R3
                CMP     0, @R3
                RBRA    _CDRL_FB, Z
                MOVE    R7, R2
                ADD     CDR_IDX0, R2
_CDRL_FB        MOVE    @R2++, R0
                MOVE    @R2, R1

                MOVE    R0, R2                  ; R3:R2: the frames before FB,
                MOVE    R1, R3
                MOVE    R7, R4                  ; R4: their size,
                ADD     CDR_SSIZE, R4
                MOVE    @R4, R4
                XOR     R5, R5                  ; R6:R5: the byte they start at
                XOR     R6, R6
                MOVE    CDI_RSZ, R8
                CMP     0, @R8
                RBRA    _CDRL_MUL, Z            ; (its file's first track)
                MOVE    @R8, R4
                MOVE    CDI_RFB, R8
                SUB     @R8++, R2
                SUBC    @R8, R3
                MOVE    R3, R8                  ; FB before RFB (a bad cue): none
                AND     0x8000, R8
                RBRA    _CDRL_POS, Z
                XOR     R2, R2
                XOR     R3, R3
_CDRL_POS       MOVE    CDI_RBY, R8
                MOVE    @R8++, R5
                MOVE    @R8, R6
_CDRL_MUL       MOVE    R3, R8                  ; R11:R10 = R3:R2 * R4 + R6:R5
                MOVE    R4, R9
                RSUB    MTH$MULU, 1
                MOVE    R10, R3                 ; (the high word's low word)
                MOVE    R2, R8
                MOVE    R4, R9
                RSUB    MTH$MULU, 1
                ADD     R3, R11
                ADD     R5, R10
                ADDC    R6, R11

                MOVE    R7, R8                  ; FREL, RBY, RFB, RSZ
                ADD     CDR_FREL, R8
                MOVE    R10, @R8++
                MOVE    R11, @R8
                MOVE    CDI_RBY, R8
                MOVE    R10, @R8++
                MOVE    R11, @R8
                MOVE    CDI_RFB, R8
                MOVE    R0, @R8++
                MOVE    R1, @R8
                MOVE    R7, R8
                ADD     CDR_SSIZE, R8
                MOVE    CDI_RSZ, R9
                MOVE    @R8, @R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_FEND: the current file's sectors, from its last track (CDI_REL's RFB,
; RBY, RSZ): RFB + (FSIZE - RBY) / RSZ, at least RFB; into CDI_FSECT and the
; track before (CDI_PREV, that last track). A file without tracks keeps its
; own. All registers kept but R8..R11
; ----------------------------------------------------------------------------

CDI_FEND        INCRB
                MOVE    CDI_RSZ, R0
                CMP     0, @R0
                RBRA    _CDFE_RET, Z
                MOVE    CDI_FSIZE, R1           ; R9:R8 = FSIZE - RBY
                MOVE    @R1++, R8
                MOVE    @R1, R9
                MOVE    CDI_RBY, R1
                SUB     @R1++, R8
                SUBC    @R1, R9
                MOVE    R9, R2                  ; past the file's end: none
                AND     0x8000, R2
                RBRA    _CDFE_DIV, Z
                XOR     R8, R8
                XOR     R9, R9
_CDFE_DIV       MOVE    @R0, R10                ; / RSZ
                XOR     R11, R11
                RSUB    MTH$DIVU32, 1
                MOVE    CDI_RFB, R1             ; + RFB
                ADD     @R1++, R8
                ADDC    @R1, R9
                MOVE    CDI_FSECT, R1
                MOVE    R8, @R1++
                MOVE    R9, @R1
                MOVE    CDI_PV, R1
                CMP     0, @R1
                RBRA    _CDFE_RET, Z
                MOVE    CDI_PREV, R1
                ADD     CDR_FSECT, R1
                MOVE    R8, @R1++
                MOVE    R9, @R1
_CDFE_RET       DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_FINAL: track R8 (a CDR_ record) into the table as the next track, its
; file data up to frame R10:R9 of its file. Output: R8 = 0 or CDI_E_CUE
; (over 99 tracks)
;
;   base  = its file's first frame + the gaps before it
;   start = base + FB (INDEX 00, or 01; track 1: always INDEX 01)
;   fb    = start + PREGAP (track 1: none)
;   idx1  = base + INDEX 01 + PREGAP
;   fe    = base + R10:R9 + PREGAP (at least fb)
;   end   = fe + POSTGAP
;   byte  = its file's virtual byte + FB's byte in its file (CDI_REL)
; LBA = frame - track 1's INDEX 01 frame
; ----------------------------------------------------------------------------

CDI_FINAL       INCRB
                MOVE    R8, R7                  ; R7: the track
                MOVE    R9, R5                  ; R6:R5: the end in its file
                MOVE    R10, R6
                MOVE    CDI_NTR, R0
                CMP     99, @R0
                RBRA    _CDFI_ECUE, Z

                ; R1:R0 = FB in the file
                MOVE    R7, R2
                ADD     CDR_IDX1, R2
                MOVE    CDI_NTR, R3
                CMP     0, @R3
                RBRA    _CDFI_FB, Z             ; track 1: INDEX 01
                MOVE    R7, R3
                ADD     CDR_HAS0, R3
                CMP     0, @R3
                RBRA    _CDFI_FB, Z
                MOVE    R7, R2
                ADD     CDR_IDX0, R2
_CDFI_FB        MOVE    @R2++, R0
                MOVE    @R2, R1

                ; R3:R2 = base
                MOVE    R7, R4
                ADD     CDR_FSTART, R4
                MOVE    @R4++, R2
                MOVE    @R4, R3
                MOVE    R7, R4
                ADD     CDR_SHB, R4
                ADD     @R4++, R2
                ADDC    @R4, R3

                ; start, fb
                MOVE    R2, R8
                MOVE    R3, R9
                ADD     R0, R8
                ADDC    R1, R9
                MOVE    CDI_T_START, R4
                MOVE    R8, @R4++
                MOVE    R9, @R4
                MOVE    CDI_NTR, R4             ; PREGAP (not track 1's): fb and
                CMP     0, @R4                  ; the base
                RBRA    _CDFI_P0, Z
                MOVE    R7, R4
                ADD     CDR_PRE, R4
                MOVE    @R4++, R10
                MOVE    @R4, R11
                ADD     R10, R8
                ADDC    R11, R9
                ADD     R10, R2
                ADDC    R11, R3
_CDFI_P0        MOVE    CDI_T_FB, R4
                MOVE    R8, @R4++
                MOVE    R9, @R4

                ; idx1 = base + INDEX 01; fe = base + the end (at least fb)
                MOVE    R7, R4
                ADD     CDR_IDX1, R4
                MOVE    R2, R10
                MOVE    R3, R11
                ADD     @R4++, R10
                ADDC    @R4, R11
                MOVE    CDI_T_IDX1, R4
                MOVE    R10, @R4++
                MOVE    R11, @R4
                ADD     R2, R5
                ADDC    R3, R6
                CMP     R9, R6                  ; fe < fb: fe = fb
                RBRA    _CDFI_FEMIN, N          ; (fb hi > fe hi)
                RBRA    _CDFI_FESET, !Z         ; (fb hi < fe hi)
                CMP     R8, R5
                RBRA    _CDFI_FESET, !N         ; (fb lo <= fe lo)
_CDFI_FEMIN     MOVE    R8, R5
                MOVE    R9, R6
_CDFI_FESET     MOVE    CDI_T_FE, R4
                MOVE    R5, @R4++
                MOVE    R6, @R4
                MOVE    R7, R4                  ; end = fe + POSTGAP
                ADD     CDR_POST, R4
                ADD     @R4++, R5
                ADDC    @R4, R6
                MOVE    CDI_T_END, R4
                MOVE    R5, @R4++
                MOVE    R6, @R4

                ; byte = FBASE + FREL (FB's byte in its file, CDI_REL)
                MOVE    R7, R4
                ADD     CDR_FREL, R4
                MOVE    @R4++, R10
                MOVE    @R4, R11
                MOVE    R7, R4
                ADD     CDR_FBASE, R4
                ADD     @R4++, R10
                ADDC    @R4, R11
                MOVE    CDI_T_BYTE, R4
                MOVE    R10, @R4++
                MOVE    R11, @R4

                ; track 1: LBA 0 = its INDEX 01
                MOVE    CDI_NTR, R4
                CMP     0, @R4
                RBRA    _CDFI_LBA, !Z
                MOVE    CDI_T_IDX1, R4
                MOVE    CDI_ORG, R5
                MOVE    @R4++, @R5++
                MOVE    @R4, @R5
_CDFI_LBA       MOVE    CDI_T_START, R4         ; the five frames - ORG
                MOVE    5, R5
_CDFI_SUB       MOVE    CDI_ORG, R6
                SUB     @R6++, @R4++
                SUBC    @R6, @R4++
                SUB     1, R5
                RBRA    _CDFI_SUB, !Z

                ; the entry
                XOR     R8, R8
                RSUB    CDI_SEL, 1
                MOVE    CDI_NTR, R4
                MOVE    @R4, R4
                MOVE    R4, R5
                AND     0xFFFD, SR
                SHL     4, R5
                ADD     CDT_ENT, R5
                ADD     R8, R5                  ; R5: the entry
                MOVE    R7, R6
                MOVE    @R6++, R0               ; NUM
                MOVE    @R6++, R1               ; CTL
                MOVE    R1, R2
                SWAP    R2, R2
                OR      R0, R2
                MOVE    R2, @R5++               ; number | control << 8
                MOVE    @R6++, @R5++            ; SSIZE
                MOVE    @R6++, @R5++            ; OFF
                MOVE    @R6, @R5++              ; FLAGS
                MOVE    CDI_T_START, R6
                MOVE    @R6++, @R5++            ; START
                MOVE    @R6++, @R5++
                MOVE    CDI_T_IDX1, R6
                MOVE    @R6++, @R5++            ; IDX1
                MOVE    @R6++, @R5++
                MOVE    CDI_T_FB, R6
                MOVE    @R6++, @R5++            ; FB
                MOVE    @R6++, @R5++
                MOVE    CDI_T_FE, R6
                MOVE    @R6++, @R5++            ; FE
                MOVE    @R6++, @R5++
                MOVE    CDI_T_END, R6
                MOVE    @R6++, @R5++            ; END
                MOVE    @R6++, @R5++
                MOVE    CDI_T_BYTE, R6
                MOVE    @R6++, @R5++            ; BYTE
                MOVE    @R6, @R5

                ; READ TOC's descriptors (INDEX 01)
                MOVE    R4, R8
                MOVE    R0, R9
                MOVE    R1, R10
                MOVE    CDI_T_IDX1, R11
                RSUB    CDI_DESC, 1

                ; the disc
                MOVE    CDI_NTR, R4
                CMP     0, @R4
                RBRA    _CDFI_NF, !Z
                MOVE    CDI_FIRST, R5
                MOVE    R0, @R5
_CDFI_NF        ADD     1, @R4
                MOVE    CDI_LAST, R5
                MOVE    R0, @R5
                MOVE    CDI_LCTL, R5
                MOVE    R1, @R5
                MOVE    CDI_T_END, R5
                MOVE    CDI_LEAD, R6
                MOVE    @R5++, @R6++
                MOVE    @R5, @R6
                MOVE    R7, R5
                ADD     CDR_FLAGS, R5
                MOVE    @R5, R5
                MOVE    CDI_MEDIA, R6
                AND     1, R5
                RBRA    _CDFI_DATA, Z
                OR      2, @R6
                RBRA    _CDFI_OK, 1
_CDFI_DATA      OR      1, @R6
_CDFI_OK        XOR     R8, R8
                DECRB
                RET
_CDFI_ECUE      MOVE    CDI_E_CUE, R8
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_DESC: READ TOC's descriptor R8 (0..99): track R9, control R10, the LBA
; at R11 (2 words): in LBA form at CDT_TOC_LBA and in MSF form at CDT_TOC_MSF.
; A descriptor's bytes: 0, control, track, 0, the address (big-endian; MSF:
; 0, M, S, F); a word holds bytes 2k (low) and 2k + 1.
; ----------------------------------------------------------------------------

CDI_DESC        INCRB
                MOVE    R8, R4
                AND     0xFFFD, SR
                SHL     2, R4                   ; R4: the descriptor's offset
                MOVE    @R11++, R0              ; R1:R0: the LBA
                MOVE    @R11, R1
                MOVE    R10, R2
                SWAP    R2, R2                  ; R2: control << 8
                MOVE    R9, R3                  ; R3: the track
                XOR     R8, R8
                RSUB    CDI_SEL, 1
                MOVE    R8, R5
                ADD     CDT_TOC_LBA, R5
                ADD     R4, R5
                MOVE    R2, @R5++
                MOVE    R3, @R5++
                MOVE    R1, R6
                SWAP    R6, R6
                MOVE    R6, @R5++
                MOVE    R0, R6
                SWAP    R6, R6
                MOVE    R6, @R5
                MOVE    R0, R8                  ; MSF
                MOVE    R1, R9
                RSUB    CDI_TOMSF, 1            ; R8 M, R9 S, R10 F
                MOVE    R8, R6
                SWAP    R6, R6
                SWAP    R10, R10
                OR      R9, R10
                XOR     R8, R8
                RSUB    CDI_SEL, 1
                MOVE    R8, R5
                ADD     CDT_TOC_MSF, R5
                ADD     R4, R5
                MOVE    R2, @R5++
                MOVE    R3, @R5++
                MOVE    R6, @R5++               ; 0, M
                MOVE    R10, @R5                ; S, F
                DECRB
                RET

; CDI_TOMSF: R9:R8 = an LBA -> R8 M, R9 S, R10 F of LBA + 150
CDI_TOMSF       INCRB
                ADD     150, R8
                ADDC    0, R9
                MOVE    75, R10
                XOR     R11, R11
                RSUB    MTH$DIVU32, 1           ; R9:R8 seconds, R10 F
                MOVE    R10, R0
                MOVE    60, R10
                XOR     R11, R11
                RSUB    MTH$DIVU32, 1           ; R8 M, R10 S
                MOVE    R10, R9
                MOVE    R0, R10
                DECRB
                RET

; ----------------------------------------------------------------------------
; CDI_HEADER: the table's header and the lead-out's descriptors
; ----------------------------------------------------------------------------

CDI_HEADER      INCRB
                XOR     R8, R8
                RSUB    CDI_SEL, 1
                MOVE    R8, R0                  ; R0: the table
                MOVE    CDI_NTR, R1
                MOVE    @R1, R1
                MOVE    R1, @R0                 ; N
                MOVE    CDI_LAST, R2
                MOVE    @R2, R2
                SWAP    R2, R2
                MOVE    CDI_FIRST, R3
                OR      @R3, R2
                MOVE    R0, R3
                ADD     CDT_TRK, R3
                MOVE    R2, @R3++
                MOVE    CDI_LEAD, R2
                MOVE    @R2++, @R3++            ; LEAD
                MOVE    @R2, @R3++
                MOVE    CDI_MEDIA, R2
                MOVE    @R2, @R3++              ; MEDIUM
                MOVE    CDI_LEAD, R2
                MOVE    @R2++, R8
                MOVE    @R2, R9
                RSUB    CDI_TOMSF, 1
                SWAP    R9, R9
                OR      R8, R9
                XOR     R8, R8
                MOVE    R10, R4
                RSUB    CDI_SEL, 1
                MOVE    R8, R3
                ADD     CDT_LEADMS, R3
                MOVE    R9, @R3++               ; M | S << 8
                MOVE    R4, @R3                 ; F
                MOVE    R1, R8                  ; the lead-out's descriptors
                MOVE    0x00AA, R9
                MOVE    CDI_LCTL, R10
                MOVE    @R10, R10
                MOVE    CDI_LEAD, R11
                RSUB    CDI_DESC, 1
                DECRB
                RET

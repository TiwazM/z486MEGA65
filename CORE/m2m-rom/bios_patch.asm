; ****************************************************************************
; z486 for MEGA65: a sync check for the system BIOS's mouse handler, a dated
; ID string, and a RAM clear at every normal POST
;
; z486_MiSTer's system BIOS (verilator/boot0.rom, the Bochs BIOS of 2017)
; files the mouse's bytes by position in its IRQ12 handler (F000:51B8): a byte
; goes to EBDA 28h + the position (EBDA 26h), and after the third the handler
; calls the driver and starts over. Nothing checks a packet's first byte (bit 3
; is set in it), so one lost byte puts every packet after it one position off
; for good: the pointer jumps between the screen edges until the driver
; initialises the mouse again (INT 15h C205). A byte gets lost when a program
; resets the mouse driver (INT 33h 0) while a packet is on its way: the
; driver's commands to the mouse (INT 15h C200, C202) drop the rest of it (I/O
; trace: Phantasmagoria and EDIT, 2026-11-03). A real mouse does the same.
;
; When /z486/boot0.rom is that file (64 KB, BPT_S1 and BPT_S2), BIOS_PATCH
; changes its copy in HyperRAM before the PC starts: at F000:5209 the handler
; calls F000:E000 (filler up to the POST entry at E05B), which does what the 8
; bytes there did (the position into [bp-2]) and then drops a byte at position
; 0 without bit 3, as other BIOSes and mouse drivers do. The packets fall back
; into step within a few. It also writes "(C)1991, Bochs BIOS for z486." at
; F000:D800 (filler too): SpeedSys 4.78 scans the BIOS for "198x"/"199x"
; followed by ',', '-' or ' ' to show its name, and when there is none it
; leaves its scan without its POP DS and later sorts its timing samples in ROM,
; forever (the Bochs BIOS has only "(c) 2001-2017"). And at every normal POST
; (shutdown status 0, 0Dh and up; the 05h/0Ah..0Ch returns jump away before it)
; it clears conventional memory, a z486 compatibility choice: the Bochs BIOS
; has no memory test, so every reset kept RAM as it was. OS/2's OS2BOOT reads
; with INT 13h AH=42h when it finds 'I13X' at 3000:0000, which an OS/2 that ran
; before leaves there, and the Bochs BIOS has no AH=42h on the boot CD's El
; Torito floppy: SYS02025, printed from DS=3000 as garbage. Warm boots are
; cleared too (real BIOSes often skip their test there): OS/2 Setup's own
; restarts must find it gone. At F000:E0BD, where the POST zeroes the BIOS data
; area, it calls F000:E020 (filler), which does that, then zeroes
; 0000:0500..FBFF (below the POST's stack at 0000:FFFE) and 1000:0000..9000:FFFF
; (the EBDA is built later); it leaves DS, SS, BX, DX and IF as they were, and
; ES = AX = 0, CX = 0, DI = 500h, DF = 0 as the code after it expects. Any
; other BIOS file stays as it is.
; tools/bios_patch.py makes BPT_S1, BPT_S2 and BPT_TAB from the file (--check
; compares, --dis shows the patched code); test/bios_run.sh runs this in the
; QNICE emulator.
;
; PC_ROM_LOAD calls BPT_CLR, then BPT_ADD with every word it loads; BIOS_PATCH
; writes through BPT_POKE (the includer's: R8 = 4K window, R9 = the word in
; it, R10 = the new word). BPT_SUM (2 words) is the includer's RAM.
; ****************************************************************************

BPT_S1          .EQU    0x9D49
BPT_S2          .EQU    0x3527

; BPT_CLR: zeroes the sums
BPT_CLR         INCRB
                MOVE    BPT_SUM, R0
                MOVE    0, @R0++
                MOVE    0, @R0
                DECRB
                RET

; BPT_ADD: adds the word R8 to the sums: S1 += R8, S2 += S1
BPT_ADD         INCRB
                MOVE    BPT_SUM, R0
                ADD     R8, @R0
                MOVE    @R0++, R1
                ADD     R1, @R0
                DECRB
                RET

; BIOS_PATCH: R8 = the system BIOS's file handle, the file just loaded.
; Output: R8 = 1: patched, 0: another file. R9, R10 preserved.
BIOS_PATCH      INCRB
                MOVE    R8, R0
                ADD     FAT32$FDH_SIZE_HI, R0
                MOVE    R8, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                XOR     R8, R8
                CMP     1, @R0                  ; 64 KB
                RBRA    _BPT_RET, !Z
                CMP     0, @R1
                RBRA    _BPT_RET, !Z
                MOVE    BPT_SUM, R0
                CMP     BPT_S1, @R0++
                RBRA    _BPT_RET, !Z
                CMP     BPT_S2, @R0
                RBRA    _BPT_RET, !Z

                MOVE    R9, R4
                MOVE    R10, R5
                MOVE    BPT_TAB, R0
_BPT_NEXT       MOVE    @R0++, R8               ; the 4K window (0: the end)
                CMP     0, R8
                RBRA    _BPT_DONE, Z
                MOVE    @R0++, R9               ; the word in it
                MOVE    @R0++, R10              ; its new value
                RSUB    BPT_POKE, 1
                RBRA    _BPT_NEXT, 1
_BPT_DONE       MOVE    R4, R9
                MOVE    R5, R10
                MOVE    1, R8
_BPT_RET        DECRB
                RET

; (4K window, word in it, new word): F000:5208..5211 (the call, five NOPs),
; F000:D800..D81D (the ID string), F000:E000..E015 (the check), F000:E020..E049
; (the RAM clear) and F000:E0BC..E0C5 (its call, six NOPs), from
; tools/bios_patch.py
BPT_TAB         .DW     0x01FA, 0x0904, 0xE8FD
                .DW     0x01FA, 0x0905, 0x8DF4
                .DW     0x01FA, 0x0906, 0x9090
                .DW     0x01FA, 0x0907, 0x9090
                .DW     0x01FA, 0x0908, 0x8A90
                .DW     0x01FE, 0x0C00, 0x4328
                .DW     0x01FE, 0x0C01, 0x3129
                .DW     0x01FE, 0x0C02, 0x3939
                .DW     0x01FE, 0x0C03, 0x2C31
                .DW     0x01FE, 0x0C04, 0x4220
                .DW     0x01FE, 0x0C05, 0x636F
                .DW     0x01FE, 0x0C06, 0x7368
                .DW     0x01FE, 0x0C07, 0x4220
                .DW     0x01FE, 0x0C08, 0x4F49
                .DW     0x01FE, 0x0C09, 0x2053
                .DW     0x01FE, 0x0C0A, 0x6F66
                .DW     0x01FE, 0x0C0B, 0x2072
                .DW     0x01FE, 0x0C0C, 0x347A
                .DW     0x01FE, 0x0C0D, 0x3638
                .DW     0x01FE, 0x0C0E, 0x002E
                .DW     0x01FF, 0x0000, 0x468A
                .DW     0x01FF, 0x0001, 0x24FC
                .DW     0x01FF, 0x0002, 0x8807
                .DW     0x01FF, 0x0003, 0xFE46
                .DW     0x01FF, 0x0004, 0x0A75
                .DW     0x01FF, 0x0005, 0x46F6
                .DW     0x01FF, 0x0006, 0x08FF
                .DW     0x01FF, 0x0007, 0x0475
                .DW     0x01FF, 0x0008, 0xEC89
                .DW     0x01FF, 0x0009, 0xC35D
                .DW     0x01FF, 0x000A, 0x00C3
                .DW     0x01FF, 0x0010, 0x80B9
                .DW     0x01FF, 0x0011, 0xBF00
                .DW     0x01FF, 0x0012, 0x0400
                .DW     0x01FF, 0x0013, 0xF3FC
                .DW     0x01FF, 0x0014, 0xB9AB
                .DW     0x01FF, 0x0015, 0x7B80
                .DW     0x01FF, 0x0016, 0xABF3
                .DW     0x01FF, 0x0017, 0xBA52
                .DW     0x01FF, 0x0018, 0x1000
                .DW     0x01FF, 0x0019, 0xC28E
                .DW     0x01FF, 0x001A, 0xFF31
                .DW     0x01FF, 0x001B, 0x00B9
                .DW     0x01FF, 0x001C, 0xF380
                .DW     0x01FF, 0x001D, 0x80AB
                .DW     0x01FF, 0x001E, 0x10C6
                .DW     0x01FF, 0x001F, 0xFE80
                .DW     0x01FF, 0x0020, 0x72A0
                .DW     0x01FF, 0x0021, 0x5AEF
                .DW     0x01FF, 0x0022, 0xC08E
                .DW     0x01FF, 0x0023, 0x00BF
                .DW     0x01FF, 0x0024, 0xC305
                .DW     0x01FF, 0x005E, 0xE8C0
                .DW     0x01FF, 0x005F, 0xFF60
                .DW     0x01FF, 0x0060, 0x9090
                .DW     0x01FF, 0x0061, 0x9090
                .DW     0x01FF, 0x0062, 0x9090
                .DW     0

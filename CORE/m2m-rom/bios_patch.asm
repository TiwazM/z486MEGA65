; ****************************************************************************
; z486 for MEGA65: a sync check for the system BIOS's mouse handler
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
; into step within a few. Any other BIOS file stays as it is.
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

; (4K window, word in it, new word): F000:5208..5211 (the call, five NOPs)
; and F000:E000..E015 (the check), from tools/bios_patch.py
BPT_TAB         .DW     0x01FA, 0x0904, 0xE8FD
                .DW     0x01FA, 0x0905, 0x8DF4
                .DW     0x01FA, 0x0906, 0x9090
                .DW     0x01FA, 0x0907, 0x9090
                .DW     0x01FA, 0x0908, 0x8A90
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
                .DW     0

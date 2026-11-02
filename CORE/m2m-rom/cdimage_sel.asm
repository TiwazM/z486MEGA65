; ****************************************************************************
; z486 for MEGA65: cdimage.asm's windows in the firmware. CDI_SEL: R8 = 0 the
; track table (PC_DEV_CDTOC window 0), 1/2 the cue text (its windows 1, 2),
; 3 the extent map's staging copy (its window 3), 4 unit 3's extent map
; (PC_DEV_DISK window 2 from 2048: disk_sd's map RAM, which QNICE can only
; write; it reads as 0): selects it, R8 = its address. Registers kept but R8.
; ****************************************************************************

CDI_SEL         MOVE    R0, @--SP
                MOVE    R1, @--SP
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    M2M$RAMROM_4KWIN, R1
                CMP     4, R8
                RBRA    _CDSEL_MAP, Z
                MOVE    PC_DEV_CDTOC, @R0
                MOVE    R8, @R1
                MOVE    M2M$RAMROM_DATA, R8
                RBRA    _CDSEL_RET, 1
_CDSEL_MAP      MOVE    PC_DEV_DISK, @R0
                MOVE    2, @R1
                MOVE    M2M$RAMROM_DATA, R8
                ADD     2048, R8
_CDSEL_RET      MOVE    @SP++, R1
                MOVE    @SP++, R0
                RET

; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Keyboard controller (expects low-active keys in the QNICE register)
;
; The basic idea is: A key first has to be released until it can be counted
; as pressed again.
;
; originally made for gbc4mega65 by sy2002 in 2021
; adpoted for MiSTer2MEGA65 by sy2002 in 2021 and licensed under GPL v3
; ****************************************************************************

; call this before working with this library
KEYB$INIT       INCRB
                MOVE    KEYB_PRESSED, R0
                MOVE    0xFFFF, @R0             ; low active, i.e. no keys
                MOVE    KEYB_NEWKEYS, R0
                MOVE    0, @R0                  ; high active, i.e. no keys
                MOVE    KEYB_CDN_DELAY, R0
                MOVE    0, @R0++
                MOVE    0, @R0++
                MOVE    0, @R0++
                MOVE    0, @R0
                DECRB
                RET

; perform one scan iteration; meant to be called repeatedly
KEYB$SCAN       INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                INCRB

                MOVE    M2M$KEYBOARD, R0        ; R0: keyboard status
                MOVE    @R0, R0
                NOT     R0, R0                  ; convert to high-active

                MOVE    KEYB_PRESSED, R1        ; R1 points to PRESSED
                MOVE    KEYB_NEWKEYS, R2        ; R2 points to NEWKEYS

                ; keys need to be released first to count as new keys again
                NOT     @R1, R3
                AND     R0, R3
                OR      R3, @R2

                ; store currently pressed keys
                MOVE    R0, @R1

                ; typematic repeat for up/down cursor keys
                ; (only inside QNICE as Game Boy does its own thing)
                MOVE    M2M$KEY_DOWN, R8        ; handle cursor down
                MOVE    R1, R9
                MOVE    KEYB_CDN_DELAY, R10
                MOVE    KEYB_CDN_TRIG, R11
                RSUB    _KEYB_TYPEMATIC, 1
                MOVE    M2M$KEY_UP, R8          ; handle cursor up
                MOVE    KEYB_CUP_DELAY, R10
                MOVE    KEYB_CUP_TRIG, R11
                RSUB    _KEYB_TYPEMATIC, 1

                DECRB
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                DECRB
                RET

; returns new key in R8
KEYB$GETKEY     INCRB

                MOVE    1, R0                   ; R0: key scanner
                MOVE    KEYB_NEWKEYS, R1        ; R1: list of new keys

_KEYB_GK_LOOP   MOVE    @R1, R2                 ; scan at current R0 pos.
                AND     R0, R2
                RBRA    _KEYBGK_RET_R2, !Z      ; key found? return it
                AND     0xFFFD, SR              ; no: clear X-flag, shift in 0
                SHL     1, R0                   ; move "scanner"
                RBRA    _KEYB_GK_LOOP, !Z       ; loop if not yet done
                RBRA    _KEYBGK_RET_0, 1        ; return 0, if nothing found

_KEYBGK_RET_R2  MOVE    R2, R8                  ; return new key
                NOT     R2, R2
                AND     R2, @R1                 ; unmark this key as new
                RBRA    _KEYBGK_RET, 1

_KEYBGK_RET_0   MOVE    0, R8
_KEYBGK_RET     DECRB
                RET

; internal helper function for typematic repeat
; R8: key code of key that shall be handled
; R9: pointer to PRESSED flag-word
; R10: pointer to the time of the press or of the last repeat
; R11: pointer to the state: 0 = not pressed, 2 = pressed (the delay runs),
;      1 = repeating
; M2M-UPSTREAM typematic-time: the delay and the repeat are timed with the
; cycle counter (IO$CYC_MID), no longer counted in calls
_KEYB_TYPEMATIC INCRB

                MOVE    @R9, R0
                AND     R8, R0                  ; to-be-handled key pressed?
                RBRA    _KEYB_TYPEM_DTD, Z      ; no: delete trg./dly. vars
                MOVE    IO$CYC_MID, R1          ; R1: now
                MOVE    @R1, R1
                CMP     0, @R11                 ; just pressed?
                RBRA    _KEYB_TYPEM_H, !Z
                MOVE    R1, @R10                ; yes: the delay starts now
                MOVE    2, @R11
                RBRA    _KEYB_TYPEM_RET, 1
_KEYB_TYPEM_H   MOVE    M2M$TYPEMATIC_DLY, R6   ; held: the delay first..
                CMP     2, @R11
                RBRA    _KEYB_TYPEM_C, Z
                MOVE    M2M$TYPEMATIC_SPD, R6   ; ..then the repeat speed
_KEYB_TYPEM_C   MOVE    R1, R2
                SUB     @R10, R2                ; R2: ticks since then
                CMP     R6, R2                  ; reached?
                RBRA    _KEYB_TYPEM_RET, N      ; no (R6 > R2, unsigned)

                MOVE    R8, R0                  ; yes: unpress key
                NOT     R0, R0
                AND     R0, @R9
                MOVE    1, @R11                 ; repeating
                MOVE    R1, @R10                ; the next one from now
                RBRA    _KEYB_TYPEM_RET, 1

_KEYB_TYPEM_DTD MOVE    0, @R11                 ; not pressed
                MOVE    0, @R10

_KEYB_TYPEM_RET DECRB
                RET

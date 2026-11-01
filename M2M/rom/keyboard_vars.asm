; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Variables for Keyboard Controller (keyboard.asm): Need to be located in RAM
;
; originally made for gbc4mega65 by sy2002 in 2021
; adpoted for MiSTer2MEGA65 by sy2002 in 2021 and licensed under GPL v3
; ****************************************************************************

; each key represented by one bit in these two words
KEYB_PRESSED    .BLOCK 1                        ; currently pressed
KEYB_NEWKEYS    .BLOCK 1                        ; newly pressed since last..
                                                ; ..call of KEYB_GETKEY

; typematic delay variables (expected to be a consecutive block of for words
; overall starting with KEYB_CDN_DELAY); M2M-UPSTREAM typematic-time: *_DELAY
; is the IO$CYC_MID time of the press or the last repeat, *_TRIG the state
; (0 not pressed, 2 pressed, 1 repeating)
KEYB_CDN_DELAY  .BLOCK 1
KEYB_CDN_TRIG   .BLOCK 1
KEYB_CUP_DELAY  .BLOCK 1
KEYB_CUP_TRIG   .BLOCK 1

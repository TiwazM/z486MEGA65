; ****************************************************************************
; z486 for MEGA65: cdimage.asm's variables (RAM). CD_PREP clears CDI_VSTART
; up to CDI_VEND.
; ****************************************************************************

CDI_VSTART      .BLOCK  1
CDI_HFDH        .BLOCK  1                       ; the chosen file's handle
CDI_DEV         .BLOCK  1                       ; its device
CDI_CSH         .BLOCK  1                       ; log2(cluster bytes)
CDI_NEXT        .BLOCK  1                       ; extents in the map
CDI_CLUS        .BLOCK  2                       ; clusters in the virtual image
CDI_NTR         .BLOCK  1                       ; tracks in the table
CDI_FIRST       .BLOCK  1
CDI_LAST        .BLOCK  1
CDI_LCTL        .BLOCK  1                       ; the last track's control
CDI_MEDIA       .BLOCK  1                       ; 1 data, 2 audio
CDI_ORG         .BLOCK  2                       ; track 1's INDEX 01 frame
CDI_LEAD        .BLOCK  2                       ; the lead-out's LBA
CDI_S           .BLOCK  2                       ; PREGAP + POSTGAP so far
CDI_FID         .BLOCK  1                       ; FILE lines so far
CDI_FSTART      .BLOCK  2                       ; the current file: its first frame,
CDI_FBASE       .BLOCK  2                       ; its virtual byte (WAVE: its data),
CDI_FSIZE       .BLOCK  2                       ; its bytes (WAVE: its data's),
CDI_FSSIZE      .BLOCK  1                       ; its sector size (0: no track yet),
CDI_FSECT       .BLOCK  2                       ; its sectors,
CDI_FFLAGS      .BLOCK  1                       ; 2: big-endian audio
CDI_RFB         .BLOCK  2                       ; its last track so far (CDI_REL): FB,
CDI_RBY         .BLOCK  2                       ; FB's byte in the file,
CDI_RSZ         .BLOCK  1                       ; its sector size (0: none yet)
CDI_CV          .BLOCK  1                       ; CDI_CUR / CDI_PREV hold a track
CDI_PV          .BLOCK  1
CDI_CUR         .BLOCK  26                      ; CDR_SIZE
CDI_PREV        .BLOCK  26
CDI_T_START     .BLOCK  2                       ; CDI_FINAL's frames, in this order
CDI_T_IDX1      .BLOCK  2
CDI_T_FB        .BLOCK  2
CDI_T_FE        .BLOCK  2
CDI_T_END       .BLOCK  2
CDI_T_BYTE      .BLOCK  2
CDI_LEN         .BLOCK  1                       ; the cue's characters
CDI_POS         .BLOCK  1                       ; the parser's position
CDI_FATERR      .BLOCK  1                       ; CDI_E_FAT: the FAT32 error
CDI_VEND        .BLOCK  1
CDI_HDR         .BLOCK  16                      ; the file's first bytes
CDI_TOK         .BLOCK  16                      ; a word of the cue
CDI_NAME        .BLOCK  128                     ; a FILE's name
CDI_FDH         .BLOCK  FAT32$FDH_STRUCT_SIZE   ; a FILE's handle

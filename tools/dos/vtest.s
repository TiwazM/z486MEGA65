/*
 * z486 for MEGA65: VTEST.COM, a test of the SVGA video memory (and of conventional RAM).
 *
 * Sets VESA mode 101h (640x480, 256 colours) and repeats, until a key (or VTEST n: n passes):
 *   A  every 64 KB bank of the video memory (VBE's total, at most 64) filled through the bank
 *      window, one bank after the other, then read back;
 *   B  the first five banks (the visible picture) filled 32 bytes at a time, switching the
 *      bank after each 32 bytes (as a decoder that draws small blocks does), then read back;
 *   C  the conventional RAM above the program, 64 KB at a time, filled and read back;
 *   D  every bank filled by REP MOVSW (even passes) or REP MOVSD (odd ones) from a RAM
 *      buffer, as games copy their pictures, then read back;
 *   E  CDPAT.BIN (in the current directory: the test CD) read through DOS in 32 KB pieces,
 *      every word checked (word w of the file: w ^ (w >> 16) * 3C6Fh ^ A5C3h, 16 bits);
 *   F  1 MB of XMS (HIMEM's moves) written from RAM, 64 KB at a time, and read back.
 * VTEST W writes CDPAT.BIN (4 MB) into the current directory and ends: on C:, the hard disk's
 * reads get phase E.
 * Meanwhile, as a game's load: the timer interrupts 10000 times a second (the string copies
 * stop and go on), and a Sound Blaster at 220h (IRQ 5, DMA 1), when there is one, plays
 * silence by auto-init DMA, its interrupts counted.
 * The bank is set in the window VBE marks writable and in the one it marks readable (the
 * ET4000's BIOS writes through window A and reads through window B, both at A000).
 * Each pass uses other values. Then text mode, the passes, the errors of the video memory
 * and of the RAM, and the first eight mismatches (bank or segment, offset, written, read).
 *
 * Build: tools/dos/build.sh (GNU as in the m65build image). Licensed under GPL v3.
 */
        .code16
        .intel_syntax noprefix
        .text
        .globl  _start
_start:
        cld
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        call    parse_num
        mov     dx, offset msg_banner
        call    puts
        mov     ax, cs
        add     ax, 0x1000
        mov     word ptr [ramlo], ax
        cmp     byte ptr [mkfile], 0
        je      70f
        jmp     mkpat
70:

        mov     dword ptr [vbeinfo], 0x32454256         /* "VBE2" */
        mov     ax, 0x4F00
        mov     di, offset vbeinfo
        int     0x10
        cmp     ax, 0x004F
        jne     err_vbe
        mov     ax, word ptr [vbeinfo + 0x12]           /* total memory, 64 KB blocks */
        cmp     ax, 64
        jbe     1f
        mov     ax, 64
1:      mov     word ptr [nbanks], ax
        mov     bx, 5
        cmp     ax, bx
        jae     2f
        mov     bx, ax
2:      mov     word ptr [nb2], bx

        mov     ax, 0x4F01
        mov     cx, 0x0101
        mov     di, offset modeinfo
        int     0x10
        cmp     ax, 0x004F
        jne     err_vbe
        mov     bx, word ptr [modeinfo + 4]             /* window granularity, KB */
        test    bx, bx
        jz      err_vbe
        mov     ax, 64
        xor     dx, dx
        div     bx
        mov     word ptr [gstep], ax                    /* granularity steps per 64 KB */
        /* the windows: write through the writable one, read through the readable one */
        mov     al, byte ptr [modeinfo + 2]             /* window A's attributes */
        mov     ah, byte ptr [modeinfo + 3]             /* window B's */
        mov     bx, word ptr [modeinfo + 8]             /* A's segment */
        mov     cx, word ptr [modeinfo + 10]            /* B's */
        mov     word ptr [wwin], 0
        mov     word ptr [wseg], bx
        test    al, 4
        jnz     32f
        mov     word ptr [wwin], 1
        mov     word ptr [wseg], cx
32:     mov     word ptr [rwin], 0
        mov     word ptr [rseg], bx
        test    al, 2
        jnz     33f
        mov     word ptr [rwin], 1
        mov     word ptr [rseg], cx
33:

        mov     ax, cs
        add     ax, 0x1000
        mov     word ptr [ramlo], ax
        mov     si, 2
        mov     ax, word ptr [si]                       /* PSP: the top of our memory */
        mov     word ptr [ramhi], ax

        mov     ax, 0x4F02
        mov     bx, 0x0101
        int     0x10
        cmp     ax, 0x004F
        jne     err_vbe
        call    xms_open
        call    load_start

pass_loop:
        mov     ax, word ptr [pass]
        mov     dx, 0x6F37
        mul     dx
        xor     ax, 0xA5C3
        mov     word ptr [seed], ax

        /* A: bank after bank */
        mov     word ptr [curseed], ax
        xor     ax, ax
3:      call    fillbank
        inc     ax
        cmp     ax, word ptr [nbanks]
        jb      3b
        xor     ax, ax
4:      call    checkbank
        inc     ax
        cmp     ax, word ptr [nbanks]
        jb      4b
        call    keycheck
        jc      done

        /* B: 32 bytes per bank switch */
        mov     ax, word ptr [seed]
        xor     ax, 0x5A5A
        mov     word ptr [curseed], ax
        call    fill_interleaved
        xor     ax, ax
5:      call    checkbank
        inc     ax
        cmp     ax, word ptr [nb2]
        jb      5b
        call    keycheck
        jc      done

        /* C: conventional RAM */
        mov     ax, word ptr [seed]
        xor     ax, 0x3C3C
        mov     word ptr [curseed], ax
        call    ramtest
        call    keycheck
        jc      done

        /* D: string copies from RAM */
        mov     ax, word ptr [seed]
        xor     ax, 0x7777
        mov     word ptr [curseed], ax
        call    phase_d
        xor     ax, ax
35:     call    checkbank
        inc     ax
        cmp     ax, word ptr [nbanks]
        jb      35b
        call    keycheck
        jc      done

        /* E: the CD; F: XMS */
        call    cdtest
        call    keycheck
        jc      done
        mov     ax, word ptr [seed]
        xor     ax, 0x1E1E
        mov     word ptr [curseed], ax
        call    xmstest

        inc     word ptr [pass]
        mov     ax, word ptr [maxpass]
        test    ax, ax
        jz      6f
        cmp     word ptr [pass], ax
        jae     done
6:      call    keycheck
        jc      done
        jmp     pass_loop

done:
        call    load_stop
        call    xms_close
        mov     ax, 0x0003
        int     0x10
        call    report
        mov     ax, 0x4C00
        int     0x21

err_vbe:
        mov     dx, offset msg_novbe
        call    puts
        mov     ax, 0x4C01
        int     0x21

/* ---- the banks ------------------------------------------------------------------------ */

/* setbank: window A to the 64 KB bank AX */
setbank:
        push    ax
        push    bx
        push    dx
        mul     word ptr [gstep]
        mov     dx, ax
        push    dx
        mov     bx, word ptr [wwin]
        mov     ax, 0x4F05
        int     0x10
        pop     dx
        mov     bx, word ptr [rwin]
        cmp     bx, word ptr [wwin]
        je      34f
        mov     ax, 0x4F05
        int     0x10
34:     pop     dx
        pop     bx
        pop     ax
        ret

/* startval: BX = the first value of bank (or segment) AX under curseed */
startval:
        push    ax
        push    dx
        mov     dx, 0x3C6F
        mul     dx
        xor     ax, word ptr [curseed]
        mov     bx, ax
        pop     dx
        pop     ax
        ret

/* fillbank: bank AX through the window, from its first value on */
fillbank:
        push    ax
        push    bx
        push    cx
        push    di
        push    es
        call    setbank
        call    startval
        mov     es, word ptr [wseg]
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
7:      stosw
        add     ax, 0x9E37
        rol     ax, 1
        loop    7b
        pop     es
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

/* checkbank: bank AX read back */
checkbank:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    es
        mov     word ptr [curbank], ax
        call    setbank
        call    startval
        mov     es, word ptr [rseg]
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
8:      mov     dx, word ptr es:[di]
        cmp     dx, ax
        jne     10f
9:      add     di, 2
        add     ax, 0x9E37
        rol     ax, 1
        loop    8b
        pop     es
        pop     di
        pop     cx
        pop     dx
        pop     bx
        pop     ax
        ret
10:     mov     bl, 'V'
        call    recerr
        jmp     9b

/* fill_interleaved: banks 0 .. nb2-1, 32 bytes of one, then of the next */
fill_interleaved:
        push    ax
        push    bx
        push    cx
        push    si
        push    di
        push    es
        xor     ax, ax
11:     call    startval
        mov     si, ax
        shl     si, 1
        mov     word ptr [state + si], bx
        inc     ax
        cmp     ax, word ptr [nb2]
        jb      11b
        xor     di, di
12:     xor     ax, ax
13:     call    setbank
        mov     es, word ptr [wseg]
        mov     si, ax
        shl     si, 1
        push    ax
        push    di
        mov     ax, word ptr [state + si]
        mov     cx, 16
14:     stosw
        add     ax, 0x9E37
        rol     ax, 1
        loop    14b
        mov     word ptr [state + si], ax
        pop     di
        pop     ax
        inc     ax
        cmp     ax, word ptr [nb2]
        jb      13b
        add     di, 32
        jnz     12b
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

/* phase_d: every bank from the buffer at ramlo:0 (its values made first) by REP MOVS */
phase_d:
        push    ax
        push    bx
        push    cx
        push    si
        push    di
        push    es
        xor     ax, ax
36:     call    startval
        push    ax
        mov     es, word ptr [ramlo]
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
37:     stosw
        add     ax, 0x9E37
        rol     ax, 1
        loop    37b
        pop     ax
        call    setbank
        mov     es, word ptr [wseg]
        xor     di, di
        xor     si, si
        mov     bx, word ptr [ramlo]
        test    word ptr [pass], 1
        push    ds
        mov     ds, bx
        jnz     38f
        mov     cx, 32768
        rep     movsw
        jmp     39f
38:     mov     cx, 16384
        rep     movsd
39:     pop     ds
        inc     ax
        cmp     ax, word ptr [nbanks]
        jb      36b
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

/* mkpat: CDPAT.BIN (128 pieces of 32 KB, the pattern cdtest checks) into the current
   directory, then the end */
mkpat:
        mov     ah, 0x3C
        xor     cx, cx
        mov     dx, offset cdname
        int     0x21
        jc      78f
        mov     word ptr [cdhandle], ax
        xor     bp, bp                                  /* the piece */
74:     mov     ax, bp
        mov     bx, ax
        shr     bx, 2
        mov     dx, ax
        and     dx, 3
        mov     si, 14
75:     shl     dx, 1
        dec     si
        jnz     75b
        push    dx
        mov     ax, bx
        mov     dx, 0x3C6F
        mul     dx
        xor     ax, 0xA5C3
        mov     bx, ax
        pop     dx
        mov     es, word ptr [ramlo]
        xor     di, di
        mov     cx, 16384
76:     mov     ax, dx
        xor     ax, bx
        stosw
        inc     dx
        loop    76b
        mov     bx, word ptr [cdhandle]
        mov     cx, 32768
        xor     dx, dx
        push    ds
        mov     ds, word ptr [ramlo]
        mov     ah, 0x40
        int     0x21
        pop     ds
        jc      78f
        cmp     ax, 32768
        jne     78f
        inc     bp
        cmp     bp, 128
        jb      74b
        mov     bx, word ptr [cdhandle]
        mov     ah, 0x3E
        int     0x21
        mov     dx, offset msg_wrote
        call    puts
        mov     ax, 0x4C00
        int     0x21
78:     mov     dx, offset msg_wfail
        call    puts
        mov     ax, 0x4C02
        int     0x21

/* cdtest: CDPAT.BIN read in 32 KB pieces into ramlo:0, every word checked */
cdtest:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     ax, 0x3D00
        mov     dx, offset cdname
        int     0x21
        jc      54f
        mov     word ptr [cdhandle], ax
        mov     byte ptr [cdfound], 1
        mov     word ptr [curbank], 0                   /* the piece */
50:     mov     bx, word ptr [cdhandle]
        mov     cx, 32768
        xor     dx, dx
        push    ds
        mov     ds, word ptr [ramlo]
        mov     ah, 0x3F
        int     0x21
        pop     ds
        jc      53f
        test    ax, ax
        jz      53f
        add     word ptr [cdbytes], ax
        adc     word ptr [cdbytes + 2], 0
        mov     cx, ax
        shr     cx, 1                                   /* words in this piece */
        /* the first word's value: piece k starts at word k*16384 */
        mov     ax, word ptr [curbank]
        mov     bx, ax
        shr     bx, 2                                   /* w >> 16 */
        mov     dx, ax
        and     dx, 3
        mov     si, 14
51:     shl     dx, 1
        dec     si
        jnz     51b                                     /* dx = (k & 3) * 16384: w & FFFFh */
        push    dx
        mov     ax, bx
        mov     dx, 0x3C6F
        mul     dx
        xor     ax, 0xA5C3
        mov     bx, ax                                  /* the piece's mask */
        pop     dx
        mov     es, word ptr [ramlo]
        xor     di, di
52:     mov     ax, dx
        xor     ax, bx
        cmp     ax, word ptr es:[di]
        je      55f
        push    dx
        push    bx
        mov     dx, word ptr es:[di]
        mov     bl, 'C'
        call    recerr
        pop     bx
        pop     dx
55:     add     di, 2
        inc     dx
        loop    52b
        inc     word ptr [curbank]
        jmp     50b
53:     mov     bx, word ptr [cdhandle]
        mov     ah, 0x3E
        int     0x21
54:     pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

/* xms_open: the XMS driver and 1 MB of it, else xmsok stays 0 */
xms_open:
        mov     ax, 0x4300
        int     0x2F
        cmp     al, 0x80
        jne     56f
        push    es
        mov     ax, 0x4310
        int     0x2F
        mov     word ptr [xmsentry], bx
        mov     word ptr [xmsentry + 2], es
        pop     es
        mov     ah, 0x09
        mov     dx, 1024
        call    dword ptr [xmsentry]
        cmp     ax, 1
        jne     56f
        mov     word ptr [xmshandle], dx
        mov     byte ptr [xmsok], 1
56:     ret

xms_close:
        cmp     byte ptr [xmsok], 0
        je      57f
        mov     ah, 0x0A
        mov     dx, word ptr [xmshandle]
        call    dword ptr [xmsentry]
57:     ret

/* xmsmove: 64 KB between ramlo:0 and XMS block AX; BL = 0: to XMS, 1: from it */
xmsmove:
        push    ax
        push    bx
        push    dx
        push    si
        mov     word ptr [emm_len], 0
        mov     word ptr [emm_len + 2], 1               /* 65536 bytes */
        mov     dx, word ptr [ramlo]
        mov     si, word ptr [xmshandle]
        test    bl, bl
        jnz     58f
        mov     word ptr [emm_sh], 0                    /* from RAM ramlo:0 */
        mov     word ptr [emm_so], 0
        mov     word ptr [emm_so + 2], dx
        mov     word ptr [emm_dh], si                   /* to XMS AX * 64 KB */
        mov     word ptr [emm_do], 0
        mov     word ptr [emm_do + 2], ax
        jmp     59f
58:     mov     word ptr [emm_sh], si
        mov     word ptr [emm_so], 0
        mov     word ptr [emm_so + 2], ax
        mov     word ptr [emm_dh], 0
        mov     word ptr [emm_do], 0
        mov     word ptr [emm_do + 2], dx
59:     mov     si, offset emm_len
        mov     ah, 0x0B
        call    dword ptr [xmsentry]
        cmp     ax, 1
        je      60f
        add     word ptr [xmsfail], 1
60:     pop     si
        pop     dx
        pop     bx
        pop     ax
        ret

/* xmstest: 16 blocks of 64 KB through XMS and back, checked */
xmstest:
        cmp     byte ptr [xmsok], 0
        jne     61f
        ret
61:     push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    es
        xor     ax, ax
62:     call    startval
        push    ax
        mov     es, word ptr [ramlo]
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
63:     stosw
        add     ax, 0x9E37
        rol     ax, 1
        loop    63b
        pop     ax
        mov     bl, 0
        call    xmsmove
        inc     ax
        cmp     ax, 16
        jb      62b
        xor     ax, ax
64:     mov     bl, 1
        call    xmsmove
        mov     word ptr [curbank], ax
        call    startval
        push    ax
        mov     es, word ptr [ramlo]
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
65:     mov     dx, word ptr es:[di]
        cmp     dx, ax
        je      66f
        mov     bl, 'X'
        call    recerr
66:     add     di, 2
        add     ax, 0x9E37
        rol     ax, 1
        loop    65b
        pop     ax
        inc     ax
        cmp     ax, 16
        jb      64b
        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

/* ---- the load: a fast timer, Sound Blaster DMA ---------------------------------------- */

load_start:
        mov     ax, 0x3508
        int     0x21
        mov     word ptr [old08], bx
        mov     word ptr [old08 + 2], es
        push    ds
        pop     es
        mov     ax, 0x2508
        mov     dx, offset isr_timer
        int     0x21
        cli
        mov     al, 0x36
        out     0x43, al
        mov     al, 119                                 /* 1193182 / 119: 10 kHz */
        out     0x40, al
        xor     al, al
        out     0x40, al
        sti
        /* the Sound Blaster: DSP reset, then AAh */
        mov     dx, 0x226
        mov     al, 1
        out     dx, al
        mov     cx, 100
40:     in      al, dx
        loop    40b
        xor     al, al
        out     dx, al
        mov     cx, 0xFFFF
41:     mov     dx, 0x22E
        in      al, dx
        test    al, 0x80
        jnz     42f
        loop    41b
        ret
42:     mov     dx, 0x22A
        in      al, dx
        cmp     al, 0xAA
        je      43f
        ret
43:     mov     byte ptr [sbon], 1
        mov     ax, 0x350D
        int     0x21
        mov     word ptr [old0d], bx
        mov     word ptr [old0d + 2], es
        push    ds
        pop     es
        mov     ax, 0x250D
        mov     dx, offset isr_sb
        int     0x21
        in      al, 0x21
        mov     byte ptr [oldmask], al
        and     al, 0xDF                                /* IRQ 5 on */
        out     0x21, al
        /* 2 KB of silence in one 64 KB DMA page */
        mov     di, offset dmabuf
        mov     ax, cs
        mov     dx, 16
        mul     dx
        add     ax, di
        adc     dx, 0
        mov     bx, ax
        add     bx, 2047
        jnc     44f
        add     ax, 2048
        adc     dx, 0
        add     di, 2048
44:     mov     word ptr [dmaaddr], ax
        mov     byte ptr [dmapage], dl
        mov     cx, 2048
        mov     al, 0x80
        rep     stosb
        mov     al, 5
        out     0x0A, al                                /* channel 1 masked */
        out     0x0C, al                                /* the flip-flop */
        mov     al, 0x59                                /* single, auto-init, read, channel 1 */
        out     0x0B, al
        mov     ax, word ptr [dmaaddr]
        out     0x02, al
        mov     al, ah
        out     0x02, al
        mov     al, byte ptr [dmapage]
        out     0x83, al
        mov     ax, 2047
        out     0x03, al
        mov     al, ah
        out     0x03, al
        mov     al, 1
        out     0x0A, al                                /* channel 1 on */
        mov     al, 0xD1                                /* speaker on */
        call    dspw
        mov     al, 0x40                                /* 11025 Hz */
        call    dspw
        mov     al, 0xA5
        call    dspw
        mov     al, 0x48                                /* blocks of 1 KB */
        call    dspw
        mov     al, 0xFF
        call    dspw
        mov     al, 0x03
        call    dspw
        mov     al, 0x1C                                /* auto-init 8-bit output */
        call    dspw
        ret

load_stop:
        cmp     byte ptr [sbon], 0
        je      46f
        mov     al, 0xD0
        call    dspw
        mov     al, 0xDA
        call    dspw
        mov     al, 5
        out     0x0A, al
        mov     dx, 0x226
        mov     al, 1
        out     dx, al
        mov     cx, 100
47:     in      al, dx
        loop    47b
        xor     al, al
        out     dx, al
        mov     al, byte ptr [oldmask]
        out     0x21, al
        push    ds
        lds     dx, dword ptr [old0d]
        mov     ax, 0x250D
        int     0x21
        pop     ds
46:     cli
        mov     al, 0x36
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        sti
        push    ds
        lds     dx, dword ptr [old08]
        mov     ax, 0x2508
        int     0x21
        pop     ds
        ret

/* dspw: AL to the DSP */
dspw:
        push    dx
        push    ax
        mov     dx, 0x22C
45:     in      al, dx
        test    al, 0x80
        jnz     45b
        pop     ax
        out     dx, al
        pop     dx
        ret

isr_timer:
        add     word ptr cs:[ticks], 1
        adc     word ptr cs:[ticks + 2], 0
        push    ax
        mov     al, 0x20
        out     0x20, al
        pop     ax
        iret

isr_sb:
        push    ax
        push    dx
        mov     dx, 0x22E
        in      al, dx
        add     word ptr cs:[sbirq], 1
        adc     word ptr cs:[sbirq + 2], 0
        mov     al, 0x20
        out     0x20, al
        pop     dx
        pop     ax
        iret

/* ---- the RAM -------------------------------------------------------------------------- */

ramtest:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    es
        mov     ax, word ptr [ramlo]
15:     mov     dx, ax
        add     dx, 0x1000
        jc      19f
        cmp     dx, word ptr [ramhi]
        ja      19f
        mov     word ptr [curbank], ax
        mov     es, ax
        call    startval
        xor     di, di
        mov     cx, 32768
        push    ax
        mov     ax, bx
16:     stosw
        add     ax, 0x9E37
        rol     ax, 1
        loop    16b
        xor     di, di
        mov     cx, 32768
        mov     ax, bx
17:     mov     dx, word ptr es:[di]
        cmp     dx, ax
        jne     20f
18:     add     di, 2
        add     ax, 0x9E37
        rol     ax, 1
        loop    17b
        pop     ax
        add     ax, 0x1000
        jmp     15b
19:     pop     es
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
20:     mov     bl, 'R'
        call    recerr
        jmp     18b

/* recerr: an error of kind BL ('V' or 'R') at curbank:DI, AX written, DX read */
recerr:
        push    si
        push    cx
        mov     si, offset verr
        cmp     bl, 'V'
        je      21f
        mov     si, offset rerr
        cmp     bl, 'R'
        je      21f
        mov     si, offset cerr
        cmp     bl, 'C'
        je      21f
        mov     si, offset xerr
21:     add     word ptr [si], 1
        adc     word ptr [si + 2], 0
22:     mov     si, word ptr [nrec]
        cmp     si, 8
        jae     23f
        inc     word ptr [nrec]
        mov     cx, si
        shl     si, 3
        shl     cx, 1
        add     si, cx
        add     si, offset recs
        mov     byte ptr [si], bl
        mov     cx, word ptr [curbank]
        mov     word ptr [si + 2], cx
        mov     word ptr [si + 4], di
        mov     word ptr [si + 6], ax
        mov     word ptr [si + 8], dx
23:     pop     cx
        pop     si
        ret

/* ---- input and output ----------------------------------------------------------------- */

/* keycheck: CF = a key was pressed (and taken) */
keycheck:
        push    ax
        mov     ah, 1
        int     0x16
        jz      24f
        mov     ah, 0
        int     0x16
        pop     ax
        stc
        ret
24:     pop     ax
        clc
        ret

/* parse_num: the decimal number on the command line into maxpass (0: until a key) */
parse_num:
        mov     si, 0x81
        mov     cl, byte ptr [0x80]
        xor     ch, ch
        jcxz    72f
71:     mov     al, byte ptr [si]
        and     al, 0xDF
        cmp     al, 'W'
        jne     73f
        mov     byte ptr [mkfile], 1
73:     inc     si
        loop    71b
72:     mov     si, 0x81
        xor     bx, bx
25:     lodsb
        cmp     al, ' '
        je      25b
26:     cmp     al, '0'
        jb      27f
        cmp     al, '9'
        ja      27f
        sub     al, '0'
        xor     ah, ah
        push    ax
        mov     ax, bx
        mov     cx, 10
        mul     cx
        pop     bx
        add     bx, ax
        lodsb
        jmp     26b
27:     mov     word ptr [maxpass], bx
        ret

puts:
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

putc:
        push    ax
        push    dx
        mov     dl, al
        mov     ah, 2
        int     0x21
        pop     dx
        pop     ax
        ret

/* puthex: AX as four hex digits */
puthex:
        push    ax
        push    cx
        mov     cx, 4
28:     rol     ax, 4
        push    ax
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     29f
        add     al, 'A' - '9' - 1
29:     call    putc
        pop     ax
        loop    28b
        pop     cx
        pop     ax
        ret

report:
        mov     dx, offset msg_banks
        call    puts
        mov     ax, word ptr [nbanks]
        call    puthex
        mov     dx, offset msg_gran
        call    puts
        mov     ax, word ptr [modeinfo + 4]
        call    puthex
        mov     dx, offset msg_win
        call    puts
        mov     ax, word ptr [modeinfo + 2]
        call    puthex
        mov     dx, offset msg_wr
        call    puts
        mov     ax, word ptr [wwin]
        add     al, 'A'
        call    putc
        mov     dx, offset msg_rd
        call    puts
        mov     ax, word ptr [rwin]
        add     al, 'A'
        call    putc
        mov     dx, offset msg_pass
        call    puts
        mov     ax, word ptr [pass]
        call    puthex
        mov     dx, offset msg_verr
        call    puts
        mov     ax, word ptr [verr + 2]
        call    puthex
        mov     ax, word ptr [verr]
        call    puthex
        mov     dx, offset msg_rerr
        call    puts
        mov     ax, word ptr [rerr + 2]
        call    puthex
        mov     ax, word ptr [rerr]
        call    puthex
        mov     dx, offset msg_cerr
        call    puts
        mov     ax, word ptr [cerr + 2]
        call    puthex
        mov     ax, word ptr [cerr]
        call    puthex
        mov     dx, offset msg_cbytes
        call    puts
        mov     ax, word ptr [cdbytes + 2]
        call    puthex
        mov     ax, word ptr [cdbytes]
        call    puthex
        mov     dx, offset msg_h
        call    puts
        cmp     byte ptr [cdfound], 0
        jne     67f
        mov     dx, offset msg_nocd
        call    puts
67:
        mov     dx, offset msg_xerr
        call    puts
        mov     ax, word ptr [xerr + 2]
        call    puthex
        mov     ax, word ptr [xerr]
        call    puthex
        mov     dx, offset msg_xfail
        call    puts
        mov     ax, word ptr [xmsfail]
        call    puthex
        mov     dx, offset msg_h
        call    puts
        cmp     byte ptr [xmsok], 0
        jne     68f
        mov     dx, offset msg_noxms
        call    puts
68:
        mov     dx, offset msg_ticks
        call    puts
        mov     ax, word ptr [ticks + 2]
        call    puthex
        mov     ax, word ptr [ticks]
        call    puthex
        mov     dx, offset msg_sb
        call    puts
        mov     ax, word ptr [sbirq + 2]
        call    puthex
        mov     ax, word ptr [sbirq]
        call    puthex
        cmp     byte ptr [sbon], 0
        jne     48f
        mov     dx, offset msg_nosb
        call    puts
48:
        mov     dx, offset msg_ram
        call    puts
        mov     ax, word ptr [ramlo]
        call    puthex
        mov     al, '-'
        call    putc
        mov     ax, word ptr [ramhi]
        call    puthex
        mov     dx, offset msg_nl
        call    puts
        mov     si, offset recs
        mov     cx, word ptr [nrec]
        jcxz    31f
30:     mov     al, byte ptr [si]
        call    putc
        mov     dx, offset msg_at
        call    puts
        mov     ax, word ptr [si + 2]
        call    puthex
        mov     al, ':'
        call    putc
        mov     ax, word ptr [si + 4]
        call    puthex
        mov     dx, offset msg_want
        call    puts
        mov     ax, word ptr [si + 6]
        call    puthex
        mov     dx, offset msg_got
        call    puts
        mov     ax, word ptr [si + 8]
        call    puthex
        mov     dx, offset msg_nl
        call    puts
        add     si, 10
        loop    30b
31:     ret

/* ---- data ----------------------------------------------------------------------------- */

msg_banner: .ascii "VTEST: z486 video memory and RAM test, a key ends it\r\n$"
msg_novbe:  .ascii "No VESA mode 101h (640x480x256)\r\n$"
msg_banks:  .ascii "VTEST: banks $"
msg_gran:   .ascii "h, granularity $"
msg_win:    .ascii "h KB, window attributes (B A) $"
msg_wr:     .ascii "h, writes through $"
msg_rd:     .ascii ", reads through $"
msg_pass:   .ascii "\r\npasses $"
msg_verr:   .ascii "h, video memory errors $"
msg_rerr:   .ascii "h, RAM errors $"
msg_cerr:   .ascii "h\r\nCD errors $"
msg_cbytes: .ascii "h (bytes read $"
msg_nocd:   .ascii ", no CDPAT.BIN$"
msg_xerr:   .ascii "), XMS errors $"
msg_h:      .ascii "h$"
msg_xfail:  .ascii "h (failed moves $"
msg_noxms:  .ascii ", no XMS$"
msg_ticks:  .ascii ")\r\ntimer interrupts $"
cdname:     .ascii "CDPAT.BIN\0"
msg_wrote:  .ascii "CDPAT.BIN written (4 MB)\r\n$"
msg_wfail:  .ascii "CDPAT.BIN: cannot write it\r\n$"
msg_sb:     .ascii "h, Sound Blaster interrupts $"
msg_nosb:   .ascii " (none found)$"
msg_ram:    .ascii "h\r\nRAM tested: segments $"
msg_at:     .ascii " at $"
msg_want:   .ascii " wrote $"
msg_got:    .ascii " read $"
msg_nl:     .ascii "\r\n$"

        .balign 2
pass:       .word 0
maxpass:    .word 0
seed:       .word 0
curseed:    .word 0
curbank:    .word 0
nbanks:     .word 0
nb2:        .word 0
gstep:      .word 1
wwin:       .word 0
rwin:       .word 0
wseg:       .word 0xA000
rseg:       .word 0xA000
ramlo:      .word 0
ramhi:      .word 0
verr:       .word 0, 0
rerr:       .word 0, 0
cerr:       .word 0, 0
xerr:       .word 0, 0
cdbytes:    .word 0, 0
cdhandle:   .word 0
xmsentry:   .word 0, 0
xmshandle:  .word 0
xmsfail:    .word 0
emm_len:    .word 0, 0
emm_sh:     .word 0
emm_so:     .word 0, 0
emm_dh:     .word 0
emm_do:     .word 0, 0
cdfound:    .byte 0
xmsok:      .byte 0
mkfile:     .byte 0
        .balign 2
nrec:       .word 0
state:      .word 0, 0, 0, 0, 0
recs:       .space 80
ticks:      .word 0, 0
sbirq:      .word 0, 0
old08:      .word 0, 0
old0d:      .word 0, 0
dmaaddr:    .word 0
dmapage:    .byte 0
sbon:       .byte 0
oldmask:    .byte 0
        .balign 2
modeinfo:   .space 256
vbeinfo:    .space 512
dmabuf:     .space 4096

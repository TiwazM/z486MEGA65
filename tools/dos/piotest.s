/*
 * z486 for MEGA65: PIOTEST.COM, the hard disk's PIO reads by REP INSW against single INs.
 *
 * Reads PIOPAT.BIN (4 MB; PIOTEST writes it through DOS when it is missing) straight from
 * the primary IDE master's ports, past the BIOS and DOS, 64 sectors (32 KB) a command into
 * one buffer, every word checked after each command. Word i of the file's sector s is
 * T[i] ^ K(s): T 256 pseudo-random words, K(s) the sector's key, its low byte E[s mod 128],
 * its high byte E[(37 s + 11) mod 128], E the 128 bytes with an even number of ones (in a
 * scrambled order). So a byte that belongs to another sector, at the same place, is wrong
 * in an even number of bits, and its key byte names the sector (within 64 either way); a
 * byte with an odd number of bits wrong is no sector's byte (a bit flipped).
 * Each pass reads the whole file once by each method:
 *   S  REP INSW, 256 words a sector (as the BIOS and the CD-ROM drivers read);
 *   W  IN AX,DX and MOV to the buffer, 8 to a loop: no string instruction;
 *   D  REP INSD, 128 dwords a sector;
 *   C  IN AX,DX compared with the pattern in registers, nothing stored: a wrong word here
 *      came out of the drive's data port wrong, before the memory saw it.
 * PIOTEST [n] [S] [W] [D] [C] [T]: n passes (none: until a key), only the methods named
 * (none: all four), T: the timer at 10 kHz instead of 1 kHz (more interrupted REP INs).
 * Run it on C: (a FAT16 drive with 512-byte sectors), in the folder for PIOPAT.BIN. The
 * file's first cluster comes from its directory entry (FCB find), the others from the FAT,
 * the partition from the MBR; a command reads each contiguous run within a chunk. Sectors
 * whose first four words are all wrong count as foreign (not the file's) and are skipped.
 * Then, by method: MB read, wrong words, bad 16-byte groups, foreign sectors, KB/s, the
 * wrong bytes that belong to another sector and those that are no sector's, and the first
 * eight bad groups (method, pass, sector of the file and byte in it, the word wanted and
 * read, and for each wrong byte, high then low: -n / +n, the sector n before or after it;
 * ^xx, the bits wrong).
 * The timer drives our count only while it runs: DOS's clock falls behind.
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
        mov     dx, offset msg_banner
        call    puts
        call    parse_args
        mov     ax, cs
        add     ax, 0x1000
        mov     word ptr [bufseg], ax
        add     ax, 0x0800                              /* 32 KB */
        mov     word ptr [tabseg], ax
        add     ax, 0x0400                              /* the file's clusters, 16 KB */
        mov     si, 2
        cmp     ax, word ptr [si]                       /* PSP: the top of our memory */
        mov     dx, offset msg_mem
        ja      fail
        /* Ctrl+C must not end us with the timer hooked */
        mov     ax, 0x2523
        mov     dx, offset isr_break
        int     0x21
        call    init_tabs

        /* PIOPAT.BIN on C: (written if missing): its first cluster and size from its
           directory entry */
        mov     ah, 0x19
        int     0x21
        cmp     al, 2
        mov     dx, offset msg_drive
        jne     fail
        mov     ah, 0x1A
        mov     dx, offset dta
        int     0x21
        mov     ah, 0x11                                /* FCB find: the directory entry */
        mov     dx, offset fcb
        int     0x21
        test    al, al
        jz      9f
        call    make_pat
        mov     ah, 0x11
        mov     dx, offset fcb
        int     0x21
        test    al, al
        mov     dx, offset msg_open
        jnz     fail
9:
        mov     ax, word ptr [dta + 1 + 0x1A]
        mov     word ptr [cluster], ax
        mov     eax, dword ptr [dta + 1 + 0x1C]
        cmp     eax, 4 * 1024 * 1024
        mov     dx, offset msg_size
        jb      fail
        /* the drive's layout */
        push    ds
        mov     ah, 0x32
        xor     dl, dl
        int     0x21
        mov     ah, al
        mov     cx, word ptr [bx + 2]                   /* bytes per sector */
        mov     al, byte ptr [bx + 4]                   /* sectors per cluster - 1 */
        mov     dl, byte ptr [bx + 5]                   /* its shift */
        mov     si, word ptr [bx + 6]                   /* reserved sectors: the FAT */
        mov     di, word ptr [bx + 0x0D]                /* the highest cluster + 1 */
        mov     bx, word ptr [bx + 0x0B]                /* the first data sector */
        pop     ds
        cmp     ah, 0xFF
        je      1f
        cmp     cx, 512
        jne     1f
        cmp     di, 4087                                /* below: FAT12 */
        jb      1f
        inc     al
        mov     byte ptr [spc], al
        mov     byte ptr [shift], dl
        mov     word ptr [fatres], si
        mov     word ptr [fdata], bx
        jmp     2f
1:      mov     dx, offset msg_dpb
        jmp     fail
        /* the MBR: the first FAT16 partition */
2:      xor     eax, eax
        xor     di, di
        mov     cl, 1
        mov     byte ptr [method], 0
        call    ide_read
        jc      fail_ide
        mov     es, word ptr [bufseg]
        cmp     word ptr es:[510], 0xAA55
        jne     4f
        mov     si, 0x1BE
        mov     cx, 4
3:      mov     al, byte ptr es:[si + 4]
        cmp     al, 0x04
        je      5f
        cmp     al, 0x06
        je      5f
        cmp     al, 0x0E
        je      5f
        add     si, 16
        loop    3b
4:      push    ds
        pop     es
        mov     dx, offset msg_mbr
        jmp     fail
5:      mov     eax, dword ptr es:[si + 8]
        mov     dword ptr [pstart], eax
        push    ds
        pop     es
        movzx   eax, word ptr [fdata]
        add     eax, dword ptr [pstart]
        mov     dword ptr [dlba], eax                   /* cluster 2 */
        call    build_chain
        jc      fail_ide
        xor     si, si
        call    sector_lba
        mov     dword ptr [lba0], eax
        mov     dx, offset msg_at
        call    puts
        call    put32hex
        mov     dx, offset msg_part
        call    puts
        mov     eax, dword ptr [pstart]
        call    put32hex
        mov     dx, offset msg_clus
        call    puts
        mov     ax, word ptr [cluster]
        call    puthex
        mov     dx, offset msg_spc
        call    puts
        movzx   eax, byte ptr [spc]
        call    putdec
        mov     dx, offset msg_spc2
        call    puts
        movzx   eax, word ptr [pieces]
        call    putdec
        mov     dx, offset msg_spc3
        call    puts
        /* there, the file's first words */
        mov     eax, dword ptr [lba0]
        xor     di, di
        mov     cl, 1
        call    ide_read
        jc      fail_ide
        mov     es, word ptr [bufseg]
        xor     si, si
        call    sec_key
        mov     dx, ax
        mov     bx, offset ptab
        mov     cx, 4
6:      mov     ax, word ptr [bx]
        xor     ax, dx
        cmp     word ptr es:[di], ax
        jne     7f
        add     di, 2
        add     bx, 2
        loop    6b
        push    ds
        pop     es
        jmp     8f
7:      push    ds
        pop     es
        mov     dx, offset msg_where
        jmp     fail

8:      call    timer_start
pass_loop:
        xor     bx, bx
10:     mov     al, 1
        mov     cl, bl
        shl     al, cl
        test    byte ptr [mask], al
        jz      11f
        mov     byte ptr [method], bl
        call    run_method
        pushf
        call    status_line
        popf
        jc      done
11:     inc     bx
        cmp     bx, 4
        jb      10b
        inc     word ptr [pass]
        mov     ax, word ptr [maxpass]
        test    ax, ax
        jz      pass_loop
        cmp     word ptr [pass], ax
        jb      pass_loop
done:   call    timer_stop
        call    report
        mov     ax, 0x4C00
        int     0x21

fail_ide:
        call    timer_stop
        mov     dx, offset msg_ide
        call    puts
        mov     al, byte ptr [idest]
        xor     ah, ah
        call    puthex
        mov     dx, offset msg_nl
fail:   push    cs
        pop     ds
        call    puts
        mov     ax, 0x4C01
        int     0x21

/* run_method: the whole file by [method], in chunks of 64 sectors, a command for each
   contiguous run of them; CF: stop (a key or an IDE failure, [ideerr] set) */
run_method:
        pushad
        mov     eax, dword ptr [ms]
        mov     dword ptr [t0], eax
        movzx   si, byte ptr [method]
        shl     si, 2
        xor     bp, bp                                  /* the chunk */
12:     push    si
        mov     word ptr [lastgo], 0xFFFF
        mov     word ptr [r_chunk], bp
        mov     si, bp
        shl     si, 6                                   /* the chunk's first file sector */
        mov     word ptr [cend], si
        add     word ptr [cend], 64
16:     call    sector_lba
        mov     edx, eax
        mov     cx, 1
17:     mov     ax, si
        add     ax, cx
        cmp     ax, word ptr [cend]
        jae     18f
        push    si
        mov     si, ax
        call    sector_lba
        pop     si
        movzx   ebx, cx
        add     ebx, edx
        cmp     eax, ebx
        jne     18f
        inc     cx
        jmp     17b
18:     mov     di, si
        and     di, 63
        shl     di, 9
        mov     word ptr [c_sec], si                    /* the run's first file sector */
        mov     eax, edx
        call    ide_read
        jc      19f
        add     si, cx
        cmp     si, word ptr [cend]
        jb      16b
        pop     si
        cmp     byte ptr [method], 3
        je      86f
        call    verify
86:     add     dword ptr [st_kb + si], 32
        inc     bp
        call    keycheck
        jc      15f
        cmp     bp, 128
        jb      12b
        call    13f
        popad
        clc
        ret
19:     pop     si
14:     mov     byte ptr [ideerr], 1
15:     call    13f
        popad
        stc
        ret
13:     mov     eax, dword ptr [ms]
        sub     eax, dword ptr [t0]
        add     dword ptr [st_ms + si], eax
        ret

/* ide_read: CL sectors (1..128) from LBA EAX of the primary master into bufseg:DI, by
   [method], polled (nIEN); CF: an error or no answer, [idest] the status */
ide_read:
        pushad
        push    es
        mov     ebx, eax
        mov     ch, cl
        mov     dx, 0x3F6
        mov     al, 0x02
        out     dx, al
        call    wait_nbsy
        jc      19f
        mov     dx, 0x1F6
        mov     eax, ebx
        shr     eax, 24
        and     al, 0x0F
        or      al, 0xE0                                /* LBA, master */
        out     dx, al
        call    wait_nbsy
        jc      19f
        mov     dx, 0x1F2
        mov     al, ch
        out     dx, al
        inc     dx
        mov     al, bl
        out     dx, al
        inc     dx
        mov     al, bh
        out     dx, al
        inc     dx
        mov     eax, ebx
        shr     eax, 16
        out     dx, al
        mov     dx, 0x1F7
        mov     al, 0x20                                /* READ SECTORS */
        out     dx, al
        mov     es, word ptr [bufseg]
        movzx   bp, ch
16:     mov     dx, 0x3F6
        in      al, dx
        call    wait_nbsy
        jc      19f
        test    al, 0x01
        jnz     19f
        test    al, 0x08
        jz      19f
        mov     dx, 0x1F0
        cmp     byte ptr [method], 1
        je      17f
        cmp     byte ptr [method], 2
        je      18f
        cmp     byte ptr [method], 3
        je      80f
        mov     cx, 256
        rep     insw
        jmp     20f
17:     mov     cx, 32
21:     in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        in      ax, dx
        mov     word ptr es:[di], ax
        add     di, 2
        loop    21b
        jmp     20f
18:     mov     cx, 128
        rep     insd
        jmp     20f
80:     mov     cx, 256                                 /* C: compare, store nothing */
        mov     si, word ptr [c_sec]
        call    sec_key
        mov     si, ax                                  /* the sector's key */
        mov     bx, offset ptab
81:     in      ax, dx
        xor     ax, word ptr [bx]
        cmp     ax, si
        jne     83f
82:     add     bx, 2
        add     di, 2
        loop    81b
        inc     word ptr [c_sec]
        jmp     20f
83:     xor     ax, word ptr [bx]
        mov     word ptr [r_got], ax
        mov     ax, si
        xor     ax, word ptr [bx]
        mov     word ptr [r_want], ax
        mov     word ptr [r_boff], di
        call    record
        jmp     82b
20:     dec     bp
        jnz     16b
        mov     dx, 0x3F6
        in      al, dx
        call    wait_nbsy
        jc      19f
        test    al, 0x09                                /* an error, or data left */
        jnz     19f
        mov     dx, 0x3F6
        xor     al, al
        out     dx, al
        pop     es
        popad
        clc
        ret
19:     mov     byte ptr [idest], al
        mov     dx, 0x3F6
        xor     al, al
        out     dx, al
        pop     es
        popad
        stc
        ret

/* wait_nbsy: AL = the status once BSY is clear; CF: still busy after ~16M reads */
wait_nbsy:
        push    ecx
        push    dx
        mov     dx, 0x1F7
        mov     ecx, 0x01000000
22:     in      al, dx
        test    al, 0x80
        jz      23f
        dec     ecx
        jnz     22b
        pop     dx
        pop     ecx
        stc
        ret
23:     pop     dx
        pop     ecx
        clc
        ret

/* verify: chunk BP (file sectors BP*64 on) in bufseg:0, every word */
verify:
        pushad
        push    es
        mov     es, word ptr [bufseg]
        mov     si, bp
        shl     si, 6                                   /* the file sector */
        xor     di, di
        mov     bp, 64
24:     call    sec_key
        mov     dx, ax                                  /* its key */
        /* a foreign sector: its first four words all wrong */
        xor     cx, cx
        mov     ax, word ptr [ptab]
        xor     ax, dx
        cmp     ax, word ptr es:[di]
        jne     25f
        inc     cx
25:     mov     ax, word ptr [ptab + 2]
        xor     ax, dx
        cmp     ax, word ptr es:[di + 2]
        jne     26f
        inc     cx
26:     mov     ax, word ptr [ptab + 4]
        xor     ax, dx
        cmp     ax, word ptr es:[di + 4]
        jne     27f
        inc     cx
27:     mov     ax, word ptr [ptab + 6]
        xor     ax, dx
        cmp     ax, word ptr es:[di + 6]
        jne     28f
        inc     cx
28:     test    cx, cx
        jnz     29f
        movzx   ecx, byte ptr [method]
        add     dword ptr [st_for + ecx * 4], 1
        add     di, 512
        jmp     32f
29:     mov     cx, 256
        mov     bx, offset ptab
30:     mov     ax, word ptr [bx]
        xor     ax, dx
        cmp     ax, word ptr es:[di]
        je      31f
        call    recerr
31:     add     di, 2
        add     bx, 2
        loop    30b
32:     inc     si
        dec     bp
        jnz     24b
        pop     es
        popad
        ret

/* recerr: a wrong word at ES:DI of the buffer, AX wanted */
recerr:
        push    cx
        mov     word ptr [r_want], ax
        mov     cx, word ptr es:[di]
        mov     word ptr [r_got], cx
        mov     word ptr [r_boff], di
        pop     cx

/* record: a wrong word, [r_got] for [r_want], at [r_boff] in chunk [r_chunk]'s buffer */
record:
        pushad
        movzx   si, byte ptr [method]
        shl     si, 2
        add     dword ptr [st_err + si], 1
        call    rclass
        mov     cx, word ptr [r_cls]
        call    rcount
        mov     cx, word ptr [r_cls + 2]
        call    rcount
        mov     cx, word ptr [r_boff]
        and     cx, 0xFFF0
        cmp     cx, word ptr [lastgo]
        je      39f
        mov     word ptr [lastgo], cx
        add     dword ptr [st_grp + si], 1
        cmp     word ptr [nrec], 8
        jae     39f
        mov     si, word ptr [nrec]
        inc     word ptr [nrec]
        shl     si, 4
        add     si, offset recs
        movzx   bx, byte ptr [method]
        mov     al, byte ptr [mchar + bx]
        mov     byte ptr [si], al
        mov     al, byte ptr [pass]
        mov     byte ptr [si + 1], al
        mov     ax, word ptr [r_chunk]
        shl     ax, 6
        mov     bx, word ptr [r_boff]
        shr     bx, 9
        add     ax, bx
        mov     word ptr [si + 2], ax                   /* the file's sector */
        mov     ax, word ptr [r_boff]
        and     ax, 511
        mov     word ptr [si + 4], ax                   /* the byte in it */
        mov     ax, word ptr [r_want]
        mov     word ptr [si + 6], ax
        mov     cx, word ptr [r_got]
        mov     word ptr [si + 8], cx
        mov     eax, dword ptr [r_cls]
        mov     dword ptr [si + 12], eax
39:     popad
        ret

/* rcount: a wrong byte's class CL (rclass) into [method]'s counts */
rcount:
        push    si
        movzx   si, byte ptr [method]
        shl     si, 2
        cmp     cl, 1
        jne     1f
        add     dword ptr [st_sec + si], 1
1:      cmp     cl, 2
        jne     2f
        add     dword ptr [st_bit + si], 1
2:      pop     si
        ret

/* rclass: the wrong word's bytes, low and high, into [r_cls] and [r_cls + 2] (classify) */
rclass:
        pushad
        mov     si, word ptr [r_chunk]
        shl     si, 6
        mov     bx, word ptr [r_boff]
        shr     bx, 9
        add     si, bx                                  /* the file sector */
        mov     bx, word ptr [r_boff]
        and     bx, 511
        mov     dx, word ptr [ptab + bx]                /* its T word */
        mov     al, byte ptr [r_got]
        mov     ah, byte ptr [r_want]
        mov     bl, dl
        xor     cl, cl
        call    classify
        mov     word ptr [r_cls], ax
        mov     al, byte ptr [r_got + 1]
        mov     ah, byte ptr [r_want + 1]
        mov     bl, dh
        mov     cl, 1
        call    classify
        mov     word ptr [r_cls + 2], ax
        popad
        ret

/* classify: a byte, AL read, AH wanted, BL its T byte, CL 0 the low byte, 1 the high, SI the
   file sector: AL 0 right; 1 another sector's byte, AH that sector - SI (-64..63); 2 no
   sector's byte (an odd number of bits wrong), AH the bits wrong */
classify:
        cmp     al, ah
        jne     1f
        xor     ax, ax
        ret
1:      push    bx
        push    dx
        mov     dh, al
        xor     dh, ah                                  /* the bits wrong */
        xor     al, bl                                  /* the key byte read */
        movzx   bx, al
        mov     al, byte ptr [einv + bx]
        cmp     al, 0xFF
        je      3f
        test    cl, cl
        jz      2f
        sub     al, 11                                  /* high: k = 37 s + 11, s = 45 (k - 11) */
        mov     dl, 45
        mul     dl
2:      mov     dx, si
        sub     al, dl
        and     al, 0x7F
        cmp     al, 0x40
        jb      4f
        sub     al, 0x80
4:      mov     ah, al
        mov     al, 1
        pop     dx
        pop     bx
        ret
3:      mov     ah, dh
        mov     al, 2
        pop     dx
        pop     bx
        ret

/* sec_key: AX = K(SI), the file sector SI's key */
sec_key:
        push    bx
        mov     bx, si
        and     bx, 127
        mov     al, byte ptr [etab + bx]
        imul    bx, si, 37
        add     bx, 11
        and     bx, 127
        mov     ah, byte ptr [etab + bx]
        pop     bx
        ret

/* init_tabs: E (etab) and its inverse (einv, FFh for a byte with an odd number of ones),
   T (ptab) */
init_tabs:
        pushad
        mov     di, offset einv
        mov     cx, 256
        mov     al, 0xFF
        rep     stosb
        xor     bx, bx
        xor     dx, dx                                  /* the even bytes so far */
1:      test    bl, bl
        jnp     2f
        imul    si, dx, 29                              /* the m-th goes to E[29 m mod 128] */
        and     si, 127
        mov     byte ptr [etab + si], bl
        mov     ax, si
        mov     byte ptr [einv + bx], al
        inc     dx
2:      inc     bx
        cmp     bx, 256
        jb      1b
        mov     eax, 0x2486A5C3
        mov     di, offset ptab
        mov     cx, 256
3:      imul    eax, eax, 0x41C64E6D
        add     eax, 0x3039
        mov     edx, eax
        shr     edx, 16
        mov     word ptr [di], dx
        add     di, 2
        loop    3b
        popad
        ret

/* make_pat: PIOPAT.BIN, 8192 sectors, through DOS, then DOS's buffers to the disk */
make_pat:
        pushad
        mov     dx, offset msg_make
        call    puts
        mov     ah, 0x3C
        xor     cx, cx
        mov     dx, offset fname
        int     0x21
        mov     dx, offset msg_create
        jc      fail
        mov     word ptr [fh], ax
        xor     si, si                                  /* the file sector */
5:      push    es
        mov     es, word ptr [bufseg]
        xor     di, di
        mov     bp, 64
6:      call    sec_key
        mov     dx, ax
        mov     bx, offset ptab
        mov     cx, 256
7:      mov     ax, word ptr [bx]
        xor     ax, dx
        stosw
        add     bx, 2
        loop    7b
        inc     si
        dec     bp
        jnz     6b
        pop     es
        mov     bx, word ptr [fh]
        mov     cx, 0x8000
        mov     ax, word ptr [bufseg]
        push    ds
        mov     ds, ax
        xor     dx, dx
        mov     ah, 0x40
        int     0x21
        pop     ds
        jc      8f
        cmp     ax, 0x8000
        jne     8f
        cmp     si, 8192
        jb      5b
        mov     ah, 0x3E
        mov     bx, word ptr [fh]
        int     0x21
        jc      8f
        mov     ah, 0x0D
        int     0x21
        popad
        ret
8:      mov     dx, offset msg_write
        jmp     fail

/* build_chain: the file's clusters (8192 sectors' worth) into tabseg:0 from the FAT,
   [pieces] its contiguous runs; CF: an IDE failure or a chain cut short ([idest] FFh) */
build_chain:
        pushad
        push    es
        mov     ax, 8192
        mov     cl, byte ptr [shift]
        shr     ax, cl
        mov     word ptr [nclus], ax
        mov     dword ptr [fatlba], 0xFFFFFFFF
        mov     word ptr [pieces], 1
        xor     bx, bx
        mov     ax, word ptr [cluster]
70:     mov     es, word ptr [tabseg]
        mov     word ptr es:[bx], ax
        add     bx, 2
        dec     word ptr [nclus]
        jz      73f
        mov     dx, ax
        call    fat_next
        jc      74f
        cmp     ax, 2
        jb      72f
        cmp     ax, 0xFFF0
        jae     72f
        inc     dx
        cmp     ax, dx
        je      70b
        inc     word ptr [pieces]
        jmp     70b
72:     mov     byte ptr [idest], 0xFF
74:     pop     es
        popad
        stc
        ret
73:     pop     es
        popad
        clc
        ret

/* fat_next: AX = the FAT16 entry of cluster AX; CF: an IDE failure */
fat_next:
        push    ebx
        push    ecx
        push    di
        push    es
        movzx   ecx, ax
        mov     ebx, ecx
        shr     ebx, 8                                  /* 256 entries a sector */
        movzx   eax, word ptr [fatres]
        add     eax, ebx
        add     eax, dword ptr [pstart]
        cmp     eax, dword ptr [fatlba]
        je      75f
        mov     dword ptr [fatlba], eax
        push    cx
        xor     di, di
        mov     cl, 1
        call    ide_read
        pop     cx
        jnc     75f
        mov     dword ptr [fatlba], 0xFFFFFFFF
        jmp     76f
75:     mov     es, word ptr [bufseg]
        and     cx, 0xFF
        shl     cx, 1
        mov     bx, cx
        mov     ax, word ptr es:[bx]
        clc
76:     pop     es
        pop     di
        pop     ecx
        pop     ebx
        ret

/* sector_lba: EAX = the LBA of the file's sector SI */
sector_lba:
        push    es
        push    ebx
        push    ecx
        mov     es, word ptr [tabseg]
        mov     cl, byte ptr [shift]
        mov     bx, si
        shr     bx, cl
        shl     bx, 1
        movzx   eax, word ptr es:[bx]
        sub     eax, 2
        shl     eax, cl
        movzx   ebx, si
        movzx   ecx, byte ptr [spc]
        dec     ecx
        and     ebx, ecx
        add     eax, ebx
        add     eax, dword ptr [dlba]
        pop     ecx
        pop     ebx
        pop     es
        ret

/* ---- the timer ------------------------------------------------------------------------ */

timer_start:
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
        mov     ax, word ptr [divisor]
        out     0x40, al
        mov     al, ah
        out     0x40, al
        sti
        mov     byte ptr [hooked], 1
        ret

timer_stop:
        cmp     byte ptr [hooked], 0
        je      40f
        cli
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
        mov     byte ptr [hooked], 0
40:     ret

isr_timer:
        push    ax
        inc     word ptr cs:[subms]
        mov     ax, word ptr cs:[persms]
        cmp     word ptr cs:[subms], ax
        jb      41f
        mov     word ptr cs:[subms], 0
        add     word ptr cs:[ms], 1
        adc     word ptr cs:[ms + 2], 0
41:     mov     al, 0x20
        out     0x20, al
        pop     ax
        iret

isr_break:
        iret

/* ---- input and output ----------------------------------------------------------------- */

/* parse_args: digits: maxpass; S, W, D: the methods; T: the 10 kHz timer */
parse_args:
        mov     si, 0x81
        movzx   cx, byte ptr [0x80]
        xor     bx, bx
        jcxz    46f
42:     lodsb
        cmp     al, '0'
        jb      43f
        cmp     al, '9'
        ja      43f
        sub     al, '0'
        movzx   ax, al
        imul    bx, bx, 10
        add     bx, ax
        jmp     45f
43:     and     al, 0xDF
        cmp     al, 'S'
        jne     44f
        or      byte ptr [mask], 1
44:     cmp     al, 'W'
        jne     47f
        or      byte ptr [mask], 2
47:     cmp     al, 'D'
        jne     48f
        or      byte ptr [mask], 4
48:     cmp     al, 'C'
        jne     77f
        or      byte ptr [mask], 8
77:     cmp     al, 'T'
        jne     45f
        mov     word ptr [divisor], 119                 /* 1193182 / 119: 10 kHz */
        mov     word ptr [persms], 10
45:     loop    42b
46:     mov     word ptr [maxpass], bx
        cmp     byte ptr [mask], 0
        jne     49f
        mov     byte ptr [mask], 15
49:     ret

/* keycheck: CF = a key was pressed (and taken) */
keycheck:
        push    ax
        mov     ah, 1
        int     0x16
        jz      50f
        mov     ah, 0
        int     0x16
        pop     ax
        stc
        ret
50:     pop     ax
        clc
        ret

/* status_line: the pass and [method]'s totals so far */
status_line:
        pushad
        movzx   eax, word ptr [pass]
        inc     eax
        mov     cx, 4
        call    putdecw
        mov     al, ' '
        call    putc
        movzx   bx, byte ptr [method]
        call    method_row
        popad
        ret

/* method_row: BX's name, MB, wrong words, bad groups, foreign sectors, KB/s, a new line */
method_row:
        pushad
        mov     si, bx
        shl     si, 4
        lea     dx, [mname + si]
        call    puts
        shl     bx, 2
        mov     eax, dword ptr [st_kb + bx]
        shr     eax, 10
        mov     cx, 6
        call    putdecw
        mov     eax, dword ptr [st_err + bx]
        mov     cx, 9
        call    putdecw
        mov     eax, dword ptr [st_grp + bx]
        mov     cx, 9
        call    putdecw
        mov     eax, dword ptr [st_for + bx]
        mov     cx, 9
        call    putdecw
        mov     eax, dword ptr [st_kb + bx]
        mov     ecx, 1000
        mul     ecx
        mov     ecx, dword ptr [st_ms + bx]
        test    ecx, ecx
        jz      51f
        div     ecx
        jmp     52f
51:     xor     eax, eax
52:     mov     cx, 7
        call    putdecw
        mov     eax, dword ptr [st_sec + bx]
        mov     cx, 8
        call    putdecw
        mov     eax, dword ptr [st_bit + bx]
        mov     cx, 8
        call    putdecw
        mov     dx, offset msg_nl
        call    puts
        popad
        ret

report:
        mov     dx, offset msg_head
        call    puts
        xor     bx, bx
53:     mov     al, 1
        mov     cl, bl
        shl     al, cl
        test    byte ptr [mask], al
        jz      54f
        call    method_row
54:     inc     bx
        cmp     bx, 4
        jb      53b
        mov     dx, offset msg_rate
        call    puts
        movzx   eax, word ptr [persms]
        call    putdec
        mov     dx, offset msg_rate2
        call    puts
        cmp     byte ptr [ideerr], 0
        je      55f
        mov     dx, offset msg_ide
        call    puts
        mov     al, byte ptr [idest]
        xor     ah, ah
        call    puthex
        mov     dx, offset msg_nl
        call    puts
55:     mov     cx, word ptr [nrec]
        jcxz    57f
        mov     dx, offset msg_recs
        call    puts
        mov     si, offset recs
56:     mov     al, byte ptr [si]
        call    putc
        mov     al, ' '
        call    putc
        movzx   eax, byte ptr [si + 1]
        inc     eax
        push    cx
        mov     cx, 3
        call    putdecw
        movzx   eax, word ptr [si + 2]
        mov     cx, 7
        call    putdecw
        pop     cx
        mov     dx, offset msg_plus
        call    puts
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
        mov     ax, word ptr [si + 14]
        mov     dx, offset msg_hi
        call    put_cls
        mov     ax, word ptr [si + 12]
        mov     dx, offset msg_lo
        call    put_cls
        mov     dx, offset msg_nl
        call    puts
        add     si, 16
        loop    56b
57:     ret

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
58:     rol     ax, 4
        push    ax
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     59f
        add     al, 'A' - '9' - 1
59:     call    putc
        pop     ax
        loop    58b
        pop     cx
        pop     ax
        ret

/* puthex2: AL as two hex digits */
puthex2:
        push    ax
        push    cx
        mov     ah, al
        mov     cx, 2
1:      rol     ah, 4
        mov     al, ah
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     2f
        add     al, 'A' - '9' - 1
2:      call    putc
        loop    1b
        pop     cx
        pop     ax
        ret

/* put_cls: a byte's class AX (classify), after the label at DX, when it is wrong */
put_cls:
        test    al, al
        jz      2f
        call    puts
        cmp     al, 1
        jne     1f
        push    eax
        movsx   eax, ah
        call    putsdec
        pop     eax
        ret
1:      push    ax
        mov     al, '^'
        call    putc
        pop     ax
        push    ax
        mov     al, ah
        call    puthex2
        pop     ax
2:      ret

/* put32hex: EAX as eight hex digits */
put32hex:
        push    eax
        ror     eax, 16
        call    puthex
        ror     eax, 16
        call    puthex
        pop     eax
        ret

/* putdec: EAX in decimal; putdecw: right-aligned in CX columns */
putdec:
        push    cx
        xor     cx, cx
        call    putdecw
        pop     cx
        ret
putdecw:
        pushad
        mov     di, offset decbuf + 11
        mov     ebx, 10
60:     xor     edx, edx
        div     ebx
        add     dl, '0'
        dec     di
        mov     byte ptr [di], dl
        test    eax, eax
        jnz     60b
        mov     ax, offset decbuf + 11
        sub     ax, di                                  /* the digits */
61:     cmp     cx, ax
        jle     62f
        push    ax
        mov     al, ' '
        call    putc
        pop     ax
        dec     cx
        jmp     61b
62:     mov     dx, di
        call    puts
        popad
        ret

/* putsdec: EAX signed, with its sign */
putsdec:
        push    eax
        test    eax, eax
        mov     al, '+'
        jns     63f
        mov     al, '-'
63:     call    putc
        pop     eax
        push    eax
        test    eax, eax
        jns     64f
        neg     eax
64:     call    putdec
        pop     eax
        ret

/* ---- data ----------------------------------------------------------------------------- */

msg_banner: .ascii "PIOTEST: the hard disk's PIO reads, REP INSW against single INs, a key ends it\r\n$"
msg_mem:    .ascii "Not enough memory\r\n$"
msg_drive:  .ascii "Run PIOTEST on C:\r\n$"
msg_open:   .ascii "No PIOPAT.BIN here\r\n$"
msg_size:   .ascii "PIOPAT.BIN is under 4 MB\r\n$"
msg_make:   .ascii "Writing PIOPAT.BIN (4 MB)\r\n$"
msg_create: .ascii "Cannot create PIOPAT.BIN\r\n$"
msg_write:  .ascii "Writing PIOPAT.BIN failed (the disk full?)\r\n$"
msg_dpb:    .ascii "C: is not a FAT16 drive with 512-byte sectors\r\n$"
msg_mbr:    .ascii "No FAT16 partition in the MBR\r\n$"
msg_where:  .ascii "PIOPAT.BIN's first sector is not where DOS says (or an old PIOPAT.BIN)\r\n$"
msg_ide:    .ascii "IDE error or no answer, status $"
msg_at:     .ascii "PIOPAT.BIN at LBA $"
msg_part:   .ascii "h (partition at $"
msg_clus:   .ascii "h, cluster $"
msg_spc:    .ascii "h, $"
msg_spc2:   .ascii " sectors a cluster, $"
msg_spc3:   .ascii " pieces)\r\npass method       MB    wrong   groups  foreign   KB/s  sector    bits\r\n$"
msg_head:   .ascii "\r\nmethod       MB    wrong   groups  foreign   KB/s  sector    bits\r\n$"
msg_rate:   .ascii "timer $"
msg_rate2:  .ascii " kHz\r\n$"
msg_recs:   .ascii "first bad groups: method, pass, file sector +byte, wanted, read, wrong bytes\r\n"
            .ascii "(-n/+n: the byte of the sector n before/after; ^xx: bits xx wrong)\r\n$"
msg_plus:   .ascii " +$"
msg_want:   .ascii " want $"
msg_got:    .ascii " read $"
msg_hi:     .ascii " hi $"
msg_lo:     .ascii " lo $"
msg_nl:     .ascii "\r\n$"
fname:      .asciz "PIOPAT.BIN"
fcb:        .byte 0
            .ascii "PIOPAT  BIN"
            .space 25
mchar:      .ascii "SWDC"
        .balign 16
mname:      .ascii "REP INSW $"
        .space  6
            .ascii "IN loop  $"
        .space  6
            .ascii "REP INSD $"
        .space  6
            .ascii "IN check $"
        .space  6

        .balign 4
lba0:       .long 0
dlba:       .long 0
fatlba:     .long 0
pstart:     .long 0
ms:         .long 0
t0:         .long 0
r_cls:      .long 0                                     /* low byte's class, high byte's */
st_kb:      .long 0, 0, 0, 0
st_err:     .long 0, 0, 0, 0
st_grp:     .long 0, 0, 0, 0
st_for:     .long 0, 0, 0, 0
st_ms:      .long 0, 0, 0, 0
st_sec:     .long 0, 0, 0, 0                            /* bytes of another sector */
st_bit:     .long 0, 0, 0, 0                            /* bytes of no sector's */
old08:      .word 0, 0
bufseg:     .word 0
tabseg:     .word 0
fatres:     .word 0
nclus:      .word 0
pieces:     .word 0
cend:       .word 0
cluster:    .word 0
fdata:      .word 0
pass:       .word 0
maxpass:    .word 0
divisor:    .word 1193                                  /* 1193182 / 1193: 1 kHz */
persms:     .word 1
subms:      .word 0
lastgo:     .word 0
r_want:     .word 0
r_got:      .word 0
r_boff:     .word 0
r_chunk:    .word 0
c_sec:      .word 0
fh:         .word 0
nrec:       .word 0
spc:        .byte 0
shift:      .byte 0
method:     .byte 0
mask:       .byte 0
idest:      .byte 0
ideerr:     .byte 0
hooked:     .byte 0
decbuf:     .ascii "00000000000$"
        .balign 4
recs:       .space 128
dta:        .space 128
ptab:       .space 512                                  /* T */
etab:       .space 128                                  /* E */
einv:       .space 256

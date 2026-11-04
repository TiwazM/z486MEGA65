/*
 * z486 for MEGA65: CPUSPEED.COM, the CPU's clocks per instruction in real mode, beside a 486's.
 *
 * DOS speed tests (Dr. Hardware and the like) time a loop of one kind of instruction and divide
 * by the clocks a 486 takes for it: where z486 takes more, they report fewer MHz than it runs
 * at. This times each kind alone, so the one that costs more shows.
 *
 * Each test is a loop of K copies of the instruction (32; 16 for the pairs, 1 for the REP
 * moves), timed with the PIT's counter 2 (1193182 Hz, mode 2, gate on, the speaker off), with
 * interrupts off, the best of three runs (the first fills the cache). From the time go the
 * call's and the loop's own (DEC BP and JNZ, timed alone), and the rest is divided by the
 * copies: clocks per instruction at the clock rate given, 64 MHz unless CPUSPEED n says
 * otherwise. The last column, n * 486 clocks / measured clocks, is the MHz a test that times
 * that instruction would report.
 *
 * The 486's clocks are Intel's for cache hits in real mode (z486/tests/reference/
 * instruction_timing_table.txt has the same for those it lists), with a clock per prefix byte
 * (the 32-bit forms) and one for an address with a base and an index register. A miss row
 * reads 64 KB at a 32-byte stride (no 486 figure: that is the memory's time). The FPU rows
 * take the low end of Intel's range where it gives one (FADD 8-20: 8), and add up the
 * clocks of what a row pairs an instruction with (fld st 4, fstp st 3). CPUSPEED F shows
 * only those.
 *
 * The timer drives nothing else while a test runs: DOS's clock falls behind by about a second
 * per run. Build: tools/dos/build.sh (GNU as in the m65build image). Licensed under GPL v3.
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
        call    parse_mhz

        /* 64 KB for the miss row: this program's block cut to 64 KB, then a second one */
        mov     ah, 0x4A
        mov     bx, 0x1000
        int     0x21
        jc      1f
        mov     ah, 0x48
        mov     bx, 0x1000
        int     0x21
        jc      1f
        mov     [bigseg], ax
1:
        /* an FPU: FNSTSW after FNINIT stores 0 */
        fninit
        mov     word ptr [fpsw], 0x5A5A
        fnstsw  word ptr [fpsw]
        cmp     byte ptr [fpsw], 0
        jne     1f
        mov     byte ptr [hasfpu], 1
1:
        /* the PIT's counter 2: gate on, speaker off, mode 2 from 65536 */
        in      al, 0x61
        mov     [port61], al
        and     al, 0xFC
        or      al, 1
        out     0x61, al
        mov     al, 0xB4
        out     0x43, al
        xor     al, al
        out     0x42, al
        out     0x42, al

        mov     dx, offset msg_head
        call    print
        movzx   eax, word ptr [mhz]
        mov     dx, 1
        call    pdec
        mov     dx, offset msg_head2
        call    print

        /* the call's own time, then the loop's per pass */
        mov     word ptr [count], 1
        mov     bx, offset t_null
        call    measure3
        call    c100
        mov     [fixed100], eax
        mov     word ptr [count], 60000
        mov     bx, offset t_loop
        call    measure3
        call    c100
        sub     eax, [fixed100]
        jns     1f
        xor     eax, eax
1:      add     eax, 30000                              /* (rounded) */
        xor     edx, edx
        mov     ecx, 60000
        div     ecx
        mov     [loop100], eax
        mov     [per100], eax
        mov     word ptr [ref], 4
        mov     si, offset n_loop
        call    row

        mov     word ptr [tptr], offset tests
next:   mov     si, [tptr]
        mov     bx, [si]
        or      bx, bx
        jz      done
        mov     ax, [si + 10]
        test    al, 1
        jnz     1f
        cmp     byte ptr [fpuonly], 0
        jne     skip
        jmp     2f
1:      cmp     byte ptr [hasfpu], 0
        je      skip
2:      test    al, 2
        jz      1f
        cmp     word ptr [bigseg], 0
        je      skip
1:      mov     ax, [si + 2]
        mov     [count], ax
        call    measure3
        call    c100
        sub     eax, [fixed100]
        mov     ebx, eax
        mov     si, [tptr]
        movzx   ecx, word ptr [si + 2]
        mov     eax, [loop100]
        mul     ecx
        sub     ebx, eax                                /* the loop's time out */
        jns     1f
        xor     ebx, ebx
1:      mov     si, [tptr]
        movzx   eax, word ptr [si + 4]
        movzx   ecx, word ptr [si + 2]
        mul     ecx
        mov     ecx, eax                                /* copies: N * K */
        shr     eax, 1
        add     eax, ebx                                /* (rounded) */
        xor     edx, edx
        div     ecx
        mov     [per100], eax
        mov     si, [tptr]
        mov     ax, [si + 6]
        mov     [ref], ax
        mov     si, [si + 8]
        call    row
skip:   add     word ptr [tptr], 12
        jmp     next

done:   mov     al, [port61]
        out     0x61, al
        cmp     byte ptr [hasfpu], 0
        je      2f
        fninit
        jmp     1f
2:      mov     dx, offset msg_nofpu
        call    print
1:      cmp     word ptr [bigseg], 0
        jne     1f
        mov     dx, offset msg_nomem
        call    print
1:      mov     ax, 0x4C00
        int     0x21

/* ---------------------------------------------------------------------------------------- */

/* the command line, CPUSPEED [n] [F]: the clock rate n (MHz, 1 to 500, else 64); F only the
   FPU's rows (all of them are more than a screen: CPUSPEED > SPEED.TXT keeps them) */
parse_mhz:
        mov     si, 0x81
        xor     ax, ax
1:      mov     bl, [si]
        inc     si
        cmp     bl, 0x0D
        je      3f
        mov     bh, bl
        or      bh, 0x20
        cmp     bh, 'f'
        jne     2f
        mov     byte ptr [fpuonly], 1
        jmp     1b
2:      sub     bl, '0'
        cmp     bl, 9
        ja      1b                                      /* a space, or anything else */
        mov     cx, 10
        mul     cx
        xor     bh, bh
        add     ax, bx
        jmp     1b
3:      or      ax, ax
        jz      4f
        cmp     ax, 500
        jbe     5f
4:      mov     ax, 64
5:      mov     [mhz], ax
        ret

/* ax = the PIT's counter 2 now */
pit_read:
        mov     al, 0x80
        out     0x43, al
        in      al, 0x42
        mov     ah, al
        in      al, 0x42
        xchg    al, ah
        ret

/* eax = the PIT ticks routine bx takes, the fewest of three runs */
measure3:
        mov     dword ptr [best], 0xFFFFFFFF
        mov     byte ptr [tries], 3
1:      push    bx
        cli
        call    pit_read
        mov     [t0], ax
        call    bx
        call    pit_read
        sti
        pop     bx
        mov     dx, [t0]
        sub     dx, ax                                  /* it counts down */
        movzx   eax, dx
        cmp     eax, [best]
        jae     2f
        mov     [best], eax
2:      dec     byte ptr [tries]
        jnz     1b
        mov     eax, [best]
        ret

/* eax: PIT ticks in, clocks * 100 at mhz out (1e8 / 1193182 = 83.8095) */
c100:
        movzx   ecx, word ptr [mhz]
        mul     ecx
        mov     ecx, 838095
        mul     ecx
        mov     ecx, 10000
        div     ecx
        ret

/* a row: the name at si, the 486's clocks (ref, 0: none), the clocks measured (per100) and
   the MHz that makes */
row:
        call    puts
        mov     dx, 30
        sub     dx, cx
        call    spaces
        movzx   eax, word ptr [ref]
        or      ax, ax
        jnz     1f
        mov     dx, 5
        call    spaces
        mov     al, '-'
        call    putc
        jmp     2f
1:      mov     dx, 6
        call    pdec
2:      mov     eax, [per100]
        mov     dx, 10
        mov     bl, 2
        call    pfix
        movzx   eax, word ptr [ref]
        or      ax, ax
        jz      3f
        mov     ecx, [per100]
        or      ecx, ecx
        jz      3f
        movzx   ebx, word ptr [mhz]
        mul     ebx
        mov     ebx, 1000
        mul     ebx
        mov     edx, ecx
        shr     edx, 1
        add     eax, edx                                /* (rounded) */
        xor     edx, edx
        div     ecx                                     /* MHz * ref * 10 / clocks */
        mov     dx, 10
        mov     bl, 1
        call    pfix
3:      mov     dx, offset msg_crlf
        jmp     print

/* print: the $-terminated string at dx */
print:
        mov     ah, 0x09
        int     0x21
        ret

putc:
        push    ax
        push    dx
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        pop     dx
        pop     ax
        ret

/* the zero-terminated string at si; cx = its length */
puts:
        xor     cx, cx
1:      lodsb
        or      al, al
        jz      2f
        call    putc
        inc     cx
        jmp     1b
2:      ret

/* dx spaces (none if dx <= 0) */
spaces:
        or      dx, dx
        jle     2f
1:      mov     al, ' '
        call    putc
        dec     dx
        jnz     1b
2:      ret

/* the digits of eax at si, cx of them */
udec:
        mov     di, offset numend
        mov     ecx, 10
        xor     bx, bx
1:      xor     edx, edx
        div     ecx
        add     dl, '0'
        dec     di
        mov     [di], dl
        inc     bx
        or      eax, eax
        jnz     1b
        mov     si, di
        mov     cx, bx
        ret

/* eax in decimal, right-aligned in dx columns */
pdec:
        push    dx
        call    udec
        pop     dx
        sub     dx, cx
        call    spaces
3:      lodsb
        call    putc
        loop    3b
        ret

/* eax / 10^bl with bl (1 or 2) decimals, right-aligned in dx columns */
pfix:
        push    dx
        push    bx
        mov     ecx, 10
        cmp     bl, 1
        je      1f
        mov     ecx, 100
1:      xor     edx, edx
        div     ecx
        mov     [frac], edx
        pop     bx
        pop     dx
        sub     dx, 1
        sub     dl, bl
        push    bx
        call    pdec
        mov     al, '.'
        call    putc
        pop     bx
        mov     eax, [frac]
        cmp     bl, 1
        je      2f
        cmp     eax, 10
        jae     2f
        mov     al, '0'
        call    putc
        mov     eax, [frac]
2:      mov     dx, 1
        jmp     pdec

/* ---------------------------------------------------------------------------------------- */
/* The tests: each loops [count] times over its copies; bp is the loop's */

t_null: ret

t_loop: mov     bp, [count]
2:      dec     bp
        jnz     2b
        ret

        .macro  LOOP32 insn:vararg
        mov     bp, [count]
2:      .rept   32
        \insn
        .endr
        dec     bp
        jnz     2b
        ret
        .endm

t_nop:  LOOP32  nop
t_mov:  LOOP32  mov ax, bx
t_movi: LOOP32  mov ax, 0x1234
t_add:  LOOP32  add ax, bx
t_inc:  LOOP32  inc ax
t_cmp:  LOOP32  cmp ax, bx
t_ld:   mov     si, offset buf_a
        LOOP32  mov ax, [si]
t_st:   mov     di, offset buf_b
        LOOP32  mov [di], ax
t_addm: mov     si, offset buf_a
        LOOP32  add ax, [si]
t_madd: mov     di, offset buf_b
        LOOP32  add [di], ax
t_ldx:  mov     bx, offset buf_a
        xor     si, si
        LOOP32  mov ax, [bx + si]
t_lea:  LOOP32  lea ax, [bx + 8]
t_mov32: LOOP32 mov eax, ebx
t_xchg: LOOP32  xchg ax, bx
t_shl1: LOOP32  shl ax, 1
t_shl4: LOOP32  shl ax, 4

t_push: mov     bp, [count]
2:      .rept   16
        push    ax
        pop     ax
        .endr
        dec     bp
        jnz     2b
        ret

t_call: mov     bp, [count]
2:      .rept   16
        call    t_null
        .endr
        dec     bp
        jnz     2b
        ret

t_jmp:  mov     bp, [count]
2:      .rept   32
        jmp     1f
1:
        .endr
        dec     bp
        jnz     2b
        ret

t_jnz:  mov     bp, [count]
2:      .rept   32                                      /* ZF = 0 from DEC BP (and before) */
        jnz     1f
1:
        .endr
        dec     bp
        jnz     2b
        ret

t_jz:   mov     bp, [count]
2:      .rept   32
        jz      1f
1:
        .endr
        dec     bp
        jnz     2b
        ret

t_lp:   xor     cx, cx                                  /* 65536 passes before CX is 0 */
        mov     bp, [count]
2:      .rept   32
        loop    1f
1:
        .endr
        dec     bp
        jnz     2b
        ret

t_aam:  LOOP32  aam
t_aad:  LOOP32  aad
t_mul:  mov     bx, 3
        LOOP32  mul bx
t_div8: mov     bl, 7
        mov     ax, 1000
        LOOP32  div bl                                  /* AH < 7: the quotient fits */
t_div:  mov     bx, 7
        xor     dx, dx
        mov     ax, 1000
        LOOP32  div bx                                  /* DX < 7: the quotient fits */
t_div32: mov    ebx, 7
        xor     edx, edx
        mov     eax, 1000
        LOOP32  div ebx
t_idiv: mov     bx, 7
        mov     ax, 1000
        mov     bp, [count]
2:      .rept   32
        cwd
        idiv    bx
        .endr
        dec     bp
        jnz     2b
        ret
t_in:   LOOP32  in al, 0x61

t_movs: mov     bp, [count]
2:      mov     si, offset buf_a
        mov     di, offset buf_b
        mov     cx, 256
        rep     movsw
        dec     bp
        jnz     2b
        ret

t_stos: mov     bp, [count]
2:      mov     di, offset buf_b
        mov     cx, 256
        rep     stosw
        dec     bp
        jnz     2b
        ret

t_miss: mov     ax, [count]
        push    ds
        mov     ds, [bigseg]
        mov     bp, ax
        xor     si, si
2:      .rept   32
        mov     ax, [si]
        add     si, 32
        .endr
        dec     bp
        jnz     2b
        pop     ds
        ret

/* The FPU's: each starts from FNINIT and its own operands (si: memory, st and st(1)), and keeps
   them in range over its copies (1 + 1e-6 per add, 1.0000001 per multiply or divide); the slow
   ones work on a copy (fld st ... fstp st), whose clocks the 486 column includes. */

t_fldm32:
        fninit
        mov     si, offset f32_k
        mov     bp, [count]
2:      .rept   16
        fld     dword ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fldm64:
        fninit
        mov     si, offset f64_k
        mov     bp, [count]
2:      .rept   16
        fld     qword ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fldm80:
        fninit
        fld     qword ptr [f64_k]
        fstp    tbyte ptr [f80_v]
        mov     si, offset f80_v
        mov     bp, [count]
2:      .rept   16
        fld     tbyte ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fldst:
        fninit
        fld     qword ptr [f64_k]
        mov     bp, [count]
2:      .rept   16
        fld     st(0)
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fstm32:
        fninit
        fld     qword ptr [f64_k]
        mov     di, offset fp_out
        LOOP32  fst dword ptr [di]

t_fstm64:
        fninit
        fld     qword ptr [f64_k]
        mov     di, offset fp_out
        LOOP32  fst qword ptr [di]

t_fstm80:
        fninit
        fld     qword ptr [f64_k]
        mov     di, offset fp_out
        mov     bp, [count]
2:      .rept   16
        fld     st(0)
        fstp    tbyte ptr [di]
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fxch:
        fninit
        fld     qword ptr [f64_half]
        fld     qword ptr [f64_k]
        LOOP32  fxch st(1)

t_fild16:
        fninit
        mov     si, offset i16_v
        mov     bp, [count]
2:      .rept   16
        fild    word ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fild32:
        fninit
        mov     si, offset i32_v
        mov     bp, [count]
2:      .rept   16
        fild    dword ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fild64:
        fninit
        mov     si, offset i64_v
        mov     bp, [count]
2:      .rept   16
        fild    qword ptr [si]
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fist16:
        fninit
        fld     qword ptr [f64_num]
        mov     di, offset fp_out
        LOOP32  fist word ptr [di]

t_fist32:
        fninit
        fld     qword ptr [f64_num]
        mov     di, offset fp_out
        LOOP32  fist dword ptr [di]

t_fist64:
        fninit
        fld     qword ptr [f64_num]
        mov     di, offset fp_out
        mov     bp, [count]
2:      .rept   16
        fld     st(0)
        fistp   qword ptr [di]
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fadd:
        fninit
        fld     qword ptr [f64_e6]
        fld1
        LOOP32  fadd st, st(1)

t_fadd32:
        fninit
        fld1
        mov     si, offset f32_e6
        LOOP32  fadd dword ptr [si]

t_fadd64:
        fninit
        fld1
        mov     si, offset f64_e6
        LOOP32  fadd qword ptr [si]

t_fiadd:
        fninit
        fld1
        mov     si, offset i16_one
        LOOP32  fiadd word ptr [si]

t_fmul: fninit
        fld1
        fld1
        mov     bp, [count]
2:      .rept   32
        fmul    st, st(1)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fmul32:
        fninit
        fld1
        mov     si, offset f32_k
        LOOP32  fmul dword ptr [si]

t_fmul64:
        fninit
        fld1
        mov     si, offset f64_k
        LOOP32  fmul qword ptr [si]

t_fdiv:
        fninit
        fld     qword ptr [f64_k]
        fld1
        LOOP32  fdiv st, st(1)

t_fdiv64:
        fninit
        fld1
        mov     si, offset f64_k
        LOOP32  fdiv qword ptr [si]

t_fcom:
        fninit
        fld     qword ptr [f64_half]
        fld1
        mov     bp, [count]
2:      .rept   16
        fcom    st(1)
        fnstsw  ax
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fchs:
        fninit
        fld1
        LOOP32  fchs

t_fabs:
        fninit
        fld1
        LOOP32  fabs

t_fld1:
        fninit
        mov     bp, [count]
2:      .rept   16
        fld1
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fldcw:
        fninit
        mov     si, offset cw_def
        LOOP32  fldcw word ptr [si]

        .macro  FCOPY8 arg, insns:vararg                /* 8 copies of fld st, insns, fstp st */
        fninit
        fld     qword ptr [\arg]
        mov     bp, [count]
2:      .rept   8
        fld     st(0)
        \insns
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret
        .endm

t_fsqrt:   FCOPY8 f64_two, fsqrt
t_frndint: FCOPY8 f64_2p5, frndint
t_fsin:    FCOPY8 f64_half, fsin
t_fcos:    FCOPY8 f64_half, fcos
t_f2xm1:   FCOPY8 f64_half, f2xm1

t_fptan:                                                /* pushes 1.0 over tan: two pops */
        fninit
        fld     qword ptr [f64_half]
        mov     bp, [count]
2:      .rept   8
        fld     st(0)
        fptan
        fstp    st(0)
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fpatan:                                               /* atan(0.5 / 1), popping one */
        fninit
        fld     qword ptr [f64_half]
        mov     bp, [count]
2:      .rept   8
        fld     st(0)
        fld1
        fpatan
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fyl2x:                                                /* 1 * log2(3.3), popping one */
        fninit
        fld     qword ptr [f64_3p3]
        mov     bp, [count]
2:      .rept   8
        fld1
        fld     st(1)
        fyl2x
        fstp    st(0)
        .endr
        dec     bp
        jnz     2b
        fninit
        ret

t_fninit: LOOP32 fninit

t_fscale:  FCOPY8 f64_2p5, fscale                       /* 2.5 * 2^2, ST1 the original */

t_fwait:                                                /* the x87 idle */
        fninit
        LOOP32  fwait

        .macro  WAITED insn:vararg                      /* 16-bit compiler style: WAIT before each */
        mov     bp, [count]
2:      .rept   32
        fwait
        \insn
        .endr
        dec     bp
        jnz     2b
        fninit
        ret
        .endm

t_wfmul:
        fninit
        fld1
        fld1
        WAITED  fmul st, st(1)

t_wfadd64:
        fninit
        fld1
        mov     si, offset f64_e6
        WAITED  fadd qword ptr [si]

/* routine, passes N, copies K per pass, a 486's clocks per copy (0: none), name, flags
   (1: needs the FPU, 2: needs the 64 KB) */
        .balign 2
tests:
        .word   t_nop,   9000, 32,   1, n_nop,   0
        .word   t_mov,   9000, 32,   1, n_mov,   0
        .word   t_movi,  9000, 32,   1, n_movi,  0
        .word   t_add,   9000, 32,   1, n_add,   0
        .word   t_inc,   9000, 32,   1, n_inc,   0
        .word   t_cmp,   9000, 32,   1, n_cmp,   0
        .word   t_ld,    9000, 32,   1, n_ld,    0
        .word   t_st,    9000, 32,   1, n_st,    0
        .word   t_addm,  4500, 32,   2, n_addm,  0
        .word   t_madd,  3000, 32,   3, n_madd,  0
        .word   t_ldx,   4500, 32,   2, n_ldx,   0
        .word   t_lea,   9000, 32,   1, n_lea,   0
        .word   t_mov32, 4500, 32,   2, n_mov32, 0
        .word   t_xchg,  3000, 32,   3, n_xchg,  0
        .word   t_shl1,  3000, 32,   3, n_shl1,  0
        .word   t_shl4,  4500, 32,   2, n_shl4,  0
        .word   t_push,  9000, 16,   2, n_push,  0
        .word   t_call,  2300, 16,   8, n_call,  0
        .word   t_jmp,   3000, 32,   3, n_jmp,   0
        .word   t_jnz,   3000, 32,   3, n_jnz,   0
        .word   t_jz,    9000, 32,   1, n_jz,    0
        .word   t_lp,    1300, 32,   7, n_lp,    0
        .word   t_aam,    620, 32,  15, n_aam,   0
        .word   t_aad,    670, 32,  14, n_aad,   0
        .word   t_mul,    720, 32,  13, n_mul,   0
        .word   t_div8,   580, 32,  16, n_div8,  0
        .word   t_div,    390, 32,  24, n_div,   0
        .word   t_div32,  230, 32,  41, n_div32, 0
        .word   t_idiv,   310, 32,  30, n_idiv,  0
        .word   t_in,     670, 32,  14, n_in,    0
        .word   t_movs,   380,  1, 783, n_movs,  0
        .word   t_stos,   300,  1,   0, n_stos,  0
        .word   t_miss,   500, 32,   0, n_miss,  2
        .word   t_fldm32,  2604, 16,   6, n_fldm32,  1
        .word   t_fldm64,  2604, 16,   6, n_fldm64,  1
        .word   t_fldm80,  1736, 16,   9, n_fldm80,  1
        .word   t_fldst,   2232, 16,   7, n_fldst,   1
        .word   t_fstm32,  1116, 32,   7, n_fstm32,  1
        .word   t_fstm64,   977, 32,   8, n_fstm64,  1
        .word   t_fstm80,  1563, 16,  10, n_fstm80,  1
        .word   t_fxch,    1953, 32,   4, n_fxch,    1
        .word   t_fild16,   977, 16,  16, n_fild16,  1
        .word   t_fild32,  1302, 16,  12, n_fild32,  1
        .word   t_fild64,  1202, 16,  13, n_fild64,  1
        .word   t_fist16,   269, 32,  29, n_fist16,  1
        .word   t_fist32,   279, 32,  28, n_fist32,  1
        .word   t_fist64,   488, 16,  32, n_fist64,  1
        .word   t_fadd,     977, 32,   8, n_fadd,    1
        .word   t_fadd32,   977, 32,   8, n_fadd32,  1
        .word   t_fadd64,   977, 32,   8, n_fadd64,  1
        .word   t_fiadd,    391, 32,  20, n_fiadd,   1
        .word   t_fmul,     580, 32,  16, n_fmul,    1
        .word   t_fmul32,   710, 32,  11, n_fmul32,  1
        .word   t_fmul64,   558, 32,  14, n_fmul64,  1
        .word   t_fdiv,     107, 32,  73, n_fdiv,    1
        .word   t_fdiv64,   107, 32,  73, n_fdiv64,  1
        .word   t_fcom,    2232, 16,   7, n_fcom,    1
        .word   t_fchs,    1302, 32,   6, n_fchs,    1
        .word   t_fabs,    2604, 32,   3, n_fabs,    1
        .word   t_fld1,    2232, 16,   7, n_fld1,    1
        .word   t_fldcw,   1953, 32,   4, n_fldcw,   1
        .word   t_fsqrt,    347,  8,  90, n_fsqrt,   1
        .word   t_frndint, 1116,  8,  28, n_frndint, 1
        .word   t_fsin,     118,  8, 264, n_fsin,    1
        .word   t_fcos,     118,  8, 264, n_fcos,    1
        .word   t_fptan,    149,  8, 210, n_fptan,   1
        .word   t_fpatan,   136,  8, 229, n_fpatan,  1
        .word   t_f2xm1,    213,  8, 147, n_f2xm1,   1
        .word   t_fyl2x,    151,  8, 207, n_fyl2x,   1
        .word   t_fninit,   460, 32,  17, n_fninit,  1
        .word   t_fscale,   845,  8,  37, n_fscale,  1
        .word   t_fwait,   7800, 32,   1, n_fwait,   1
        .word   t_wfmul,    460, 32,  17, n_wfmul,   1
        .word   t_wfadd64,  868, 32,   9, n_wfadd64, 1
        .word   0

n_loop:  .asciz "dec bp + jnz (the test loop)"
n_nop:   .asciz "nop"
n_mov:   .asciz "mov ax, bx"
n_movi:  .asciz "mov ax, imm16"
n_add:   .asciz "add ax, bx"
n_inc:   .asciz "inc ax"
n_cmp:   .asciz "cmp ax, bx"
n_ld:    .asciz "mov ax, [si]"
n_st:    .asciz "mov [di], ax"
n_addm:  .asciz "add ax, [si]"
n_madd:  .asciz "add [di], ax"
n_ldx:   .asciz "mov ax, [bx+si]"
n_lea:   .asciz "lea ax, [bx+8]"
n_mov32: .asciz "mov eax, ebx (66h)"
n_xchg:  .asciz "xchg ax, bx"
n_shl1:  .asciz "shl ax, 1"
n_shl4:  .asciz "shl ax, 4"
n_push:  .asciz "push ax + pop ax"
n_call:  .asciz "call + ret (near)"
n_jmp:   .asciz "jmp short"
n_jnz:   .asciz "jnz taken"
n_jz:    .asciz "jz not taken"
n_lp:    .asciz "loop taken"
n_aam:   .asciz "aam"
n_aad:   .asciz "aad"
n_mul:   .asciz "mul bx (bx = 3)"
n_div8:  .asciz "div bl"
n_div:   .asciz "div bx"
n_div32: .asciz "div ebx (66h)"
n_idiv:  .asciz "cwd + idiv bx"
n_in:    .asciz "in al, 61h"
n_movs:  .asciz "rep movsw, 256 words + setup"
n_stos:  .asciz "rep stosw, 256 words + setup"
n_miss:  .asciz "mov+add, 64 KB stride 32"
n_fldm32:  .asciz "fld m32 + fstp st"
n_fldm64:  .asciz "fld m64 + fstp st"
n_fldm80:  .asciz "fld m80 + fstp st"
n_fldst:   .asciz "fld st + fstp st"
n_fstm32:  .asciz "fst m32"
n_fstm64:  .asciz "fst m64"
n_fstm80:  .asciz "fld st + fstp m80"
n_fxch:    .asciz "fxch st(1)"
n_fild16:  .asciz "fild m16 + fstp st"
n_fild32:  .asciz "fild m32 + fstp st"
n_fild64:  .asciz "fild m64 + fstp st"
n_fist16:  .asciz "fist m16"
n_fist32:  .asciz "fist m32"
n_fist64:  .asciz "fld st + fistp m64"
n_fadd:    .asciz "fadd st, st(1)"
n_fadd32:  .asciz "fadd m32"
n_fadd64:  .asciz "fadd m64"
n_fiadd:   .asciz "fiadd m16"
n_fmul:    .asciz "fmul st, st(1)"
n_fmul32:  .asciz "fmul m32"
n_fmul64:  .asciz "fmul m64"
n_fdiv:    .asciz "fdiv st, st(1)"
n_fdiv64:  .asciz "fdiv m64"
n_fcom:    .asciz "fcom st(1) + fnstsw ax"
n_fchs:    .asciz "fchs"
n_fabs:    .asciz "fabs"
n_fld1:    .asciz "fld1 + fstp st"
n_fldcw:   .asciz "fldcw m16"
n_fsqrt:   .asciz "fsqrt (fld st, fstp st)"
n_frndint: .asciz "frndint (fld st, fstp st)"
n_fsin:    .asciz "fsin (fld st, fstp st)"
n_fcos:    .asciz "fcos (fld st, fstp st)"
n_fptan:   .asciz "fptan (fld st, 2 fstp st)"
n_fpatan:  .asciz "fpatan (fld st, fld1, fstp)"
n_f2xm1:   .asciz "f2xm1 (fld st, fstp st)"
n_fyl2x:   .asciz "fyl2x (fld1, fld st1, fstp)"
n_fninit:  .asciz "fninit"
n_fscale:  .asciz "fscale (fld st, fstp st)"
n_fwait:   .asciz "fwait (x87 idle)"
n_wfmul:   .asciz "fwait + fmul st, st(1)"
n_wfadd64: .asciz "fwait + fadd m64"

msg_head:  .ascii "CPUSPEED: clocks per instruction in real mode at $"
msg_head2: .ascii " MHz (PIT counter 2)\r\n"
           .ascii "instruction                      486  measured  486 MHz\r\n$"
msg_nofpu: .ascii "(no FPU: no FPU rows)\r\n$"
msg_nomem: .ascii "(no 64 KB free: no miss row)\r\n$"
msg_crlf:  .ascii "\r\n$"

        .balign 4
best:     .long 0
fixed100: .long 0
loop100:  .long 0
per100:   .long 0
frac:     .long 0
t0:       .word 0
count:    .word 0
mhz:      .word 64
ref:      .word 0
tptr:     .word 0
bigseg:   .word 0
fpsw:     .word 0
tries:    .byte 0
hasfpu:   .byte 0
fpuonly:  .byte 0
port61:   .byte 0
numbuf:   .space 12
numend:
        .balign 8                                       /* the FPU rows' operands */
f64_half: .double 0.5
f64_two:  .double 2.0
f64_2p5:  .double 2.5
f64_3p3:  .double 3.3
f64_k:    .double 1.0000001
f64_e6:   .double 1.0e-6
f64_num:  .double 12345.6
i64_v:    .quad 1234567890123
f32_k:    .float 1.0000001
f32_e6:   .float 1.0e-6
i32_v:    .long 123456789
i16_v:    .word 1234
i16_one:  .word 1
cw_def:   .word 0x037F
f80_v:    .space 10
        .balign 8
fp_out:   .space 16
        .balign 2
buf_a:    .space 512
buf_b:    .space 512

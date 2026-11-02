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
 * reads 64 KB at a 32-byte stride (no 486 figure: that is the memory's time).
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
        jz      1f
        cmp     byte ptr [hasfpu], 0
        je      skip
1:      test    al, 2
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
        jne     1f
        mov     dx, offset msg_nofpu
        call    print
1:      cmp     word ptr [bigseg], 0
        jne     1f
        mov     dx, offset msg_nomem
        call    print
1:      mov     ax, 0x4C00
        int     0x21

/* ---------------------------------------------------------------------------------------- */

/* the clock rate: CPUSPEED n (MHz, 1 to 500), else 64 */
parse_mhz:
        mov     si, 0x81
        xor     ax, ax
1:      mov     bl, [si]
        inc     si
        cmp     bl, ' '
        je      1b
2:      sub     bl, '0'
        cmp     bl, 9
        ja      3f
        mov     cx, 10
        mul     cx
        xor     bh, bh
        add     ax, bx
        mov     bl, [si]
        inc     si
        jmp     2b
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
        .word   t_fmul,   580, 32,  16, n_fmul,  1
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
n_fmul:  .asciz "fmul st, st(1)"

msg_head:  .ascii "CPUSPEED: clocks per instruction in real mode at $"
msg_head2: .ascii " MHz (PIT counter 2)\r\n"
           .ascii "instruction                      486  measured  486 MHz\r\n$"
msg_nofpu: .ascii "(no FPU: no fmul row)\r\n$"
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
port61:   .byte 0
numbuf:   .space 12
numend:
        .balign 2
buf_a:    .space 512
buf_b:    .space 512

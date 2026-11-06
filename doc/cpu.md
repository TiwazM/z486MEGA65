# The CPU: speed

Part of [z486MEGA65](../README.md). Where z486's integer core (upstream commit
62ae68e) is slower than a 486, and what we changed. The FPU has its own page,
[x87](x87.md).

On the board Dr. Hardware gives about 26,900 Hardstones, against a DX4-120's
44,617, which at 64 MHz would be about 23,800: per clock the integer side does
about 113 % of a 486's work. Most instructions take a 486's clocks or fewer.
A few take more, and they are common in compiled code.

## Clocks per instruction

z486's full CPU in Verilator (`z486/tests/int_timing.py`, built with
`build_timing.sh`), each loop hot in the caches, eight of an instruction back to
back. 16-bit: real-mode code, as DOS programs, CPUSPEED and Dr. Hardware run;
32-bit: flat protected mode. The 486's from Intel's tables.

| Instruction | z486 16-bit | z486 32-bit | 486 |
|---|---:|---:|---:|
| ADD r,r; MOV r,m | 1 | 1 | 1 |
| ADD r,m | 1.1 | 1.1 | 2 |
| ADD r,m, its result used by the next instruction | +2 | +2 | 0 |
| CMP r,m; CMP m,r | 2.9 | 3 | 2 |
| SHL r,1; SHL r,imm | 2.75 | 2.9 | 3; 2 |
| PUSH r + POP r, back to back | 3 | 5 | 2 |
| JMP short; Jcc taken | 3; 3.4 | 3; 3.4 | 3; 3 |
| CALL rel + RET | **14.25** | 7.75 | 8 |

Each figure: (the loop's clocks - the empty loop's) / instructions.
`CPUSPEED` on the board agrees: CALL + RET 14.47 clocks in real mode
(`tools/dos/cpuspeed.s`).

- **16-bit CALL and RET** ran their whole 386 microcode: z486 kept a 16-bit
  CALL off the hardwired branch it gives a 32-bit one, and only a 32-bit RET
  on a flat 32-bit stack was a direct load of its target.
- **CMP r,m and the shifts** run a third microcode step their recipes do not
  need.
- **An ALU result from memory** (`ADD AX,[SI]`) comes about two clocks after
  a plain load's, which is forwarded to the next instruction at once. A faster
  path would lengthen the load forwarding, the build's slowest timing path.
- **POP right after a PUSH** of the same word waits for the store (32-bit);
  with any instruction between them it does not.

## Done

- **16-bit CALL and RET** (z486 `fpu` 7e189be): a 16-bit CALL rel16 is a
  hardwired branch with its ESP commit, as a 32-bit one (the target wraps at
  64K, as a 16-bit JMP's does). A 16-bit near RET in real or V86 mode is a
  direct load of its target when its stack and CS are 16-bit segments whose
  limits hold every 16-bit offset (as in real mode): the only access that
  could fault then is the word that straddles SP=FFFFh, and SP[1:0] = 3 keeps
  it on the ROM path (with the other words that would not fit in a dword
  anyway). Its target is the word, zero-extended; SP wraps in 16 bits; the
  return-address stack predicts it as a 32-bit RET's. Protected-mode 16-bit
  code (Windows 3.x) keeps the ROM path.

  | Loop, 16-bit code | Before | After | 32-bit code |
  |---|---:|---:|---:|
  | CALL + RET | 14.25 | **7.5** | 7.75 |
  | CALL + ADD + RET | 15.25 | **8.5** | 8.75 |
  | CALL + C frame (PUSH BP, MOV BP,SP, ADD, POP BP) + RET | 21 | **15** | 13 |

  The PC's BIOS reaches POST 77 about 5 % sooner in the whole-PC simulation
  (3.02 against 3.17 million clocks). The single-step tests (real 386EX
  captures) of every stack instruction pass as before; `call_ret16` and
  `v86_call_ret16` test the edges (SP and IP wrapping at 64K, RET imm16, odd
  SPs, the RET that faults, deeper than the return stack, a changed return
  address, single-stepping). Not built for the board yet.

## What to do, in order

1. ~~16-bit CALL and RET~~ (above).
2. CMP r,m and SHL in two steps instead of three: one clock each, in any code.
3. A 16-bit POP as a direct load, as the RET (the C frame above).
4. The ALU-from-memory result a clock sooner, if the timing allows.

Found on the way, in z486 as it was: a near JMP or CALL past the CS limit of
a protected-mode code segment does not fault (#GP), and instructions run on
past the limit. DOS programs never meet it.

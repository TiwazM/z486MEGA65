# Results so far (XC7A200T-2, Vivado 2022.2)

Part of [z486MEGA65](../README.md). Build and timing results.

## Summary

The whole core synthesizes, places and routes for the R6 (MiSTer2MEGA65, Megamiga's
fork) and meets timing with the PC at 66 MHz (twice CAPS LOCK's 33 MHz) with 0.56 ns to
spare (the PC's clock over-constrained by 0.3 ns in implementation); at 64 MHz it had
0.7 ns. Until 2026-11-10 it had 0.3 ns at 64 MHz, and 66.667 MHz, a DX2-66's clock,
missed by 0.25 ns (about 65.6 MHz), all inside the CPU.

2026-11-10 (fpu 4670ea5, z486 e60ec10): the three groups of paths that limited the
PC's clock in every build since v0.2 are shorter. The build takes z486's carry-chain
ALU (`alu_alt.sv`, as MiSTer), the dcache's VIPT tag compare starts from the TLB
entry's frame instead of the matched translation, and the x87 multiplier's lowest
partial product is registered for the round step. With the over-constraint raised
from 0.3 to 0.6 ns: **+0.738 ns** at 64 MHz (from +0.320; about 67.2 MHz), +0.138 ns
at the 0.6 ns target, hold met, 89.7K LUTs (66.6 %), 80.9 % slices (from 82.1 %),
257.5 block RAM tiles, 67 DSPs. The worst paths now start in the prefetch queue
(`k1q_r`, to the group ROM) and the address unit (`issue_ind_r`). The CPU and x87
tests and 186 single-step files pass as before; not on the board yet.

The next two (fpu 25c05b8, z486 36cbf92): the sidecar TLB is read at its three preread
candidates and the entry chosen after the RAM, and the decoder's entry/group ROM addresses
take their own two-byte early window (no longer on the 64-bit window's select, fanout 82).
**+0.827 ns** at 64 MHz (about 67.6 MHz), +0.227 ns at the 0.6 ns target, 88.5K LUTs
(65.8 %), 79.8 % slices. The group ROM path left the 50 worst; the TLB group went from 43
paths to 6 (the probe's own address, a five-way choice, still waits for issue). The worst
now: 44 paths from the decoder's window through the jump target's adders to the prefetch's
speculative line (`skel_window_raw_r` to `spec_line` CE, 23 levels, 10 CARRY4). Tests as
before; not on the board yet.

800x600 in True Color (fpu 059192c): **+0.607 ns** at 64 MHz, placement noise against
25c05b8 (the decoder's group-ROM path back on top). On the board (2026-11-10, in the
66 MHz trial core, `clk66` eb1d568, which carries it unchanged): VBEPROBE lists 115h
(800x600, 24 bit, R8@16 G8@8 B8@0, 2400 bytes a line) as available (`a1B`; v0.2: `a1A`)
and reads 101h, 103h and 110h-112h back after setting them; `HICOL 115` (800x600, 24
bit), `HICOL 117` (1024x768, 16 bit) and `HICOL 112` (640x480, 24 bit) each show the
three ramps, red, green, blue, each one ramp across the whole screen (117 in 565's 32
and 64 steps); `HICOL 116` (1024x768, 15 bit) too.

66 MHz (2026-11-10, branch `clk66`, eb1d568 on 059192c, merged into fpu): the PC at **66.0 MHz** (VCO 660
MHz, x33 / 5 / 10; twice CAPS LOCK's 33 MHz) meets timing with **+0.563 ns** (about 68.5
MHz), +0.263 ns at the 0.3 ns target, hold +0.062 ns, every clock met, 88.6K LUTs (65.9 %),
80.5 % slices. On the board (2026-11-10) it boots FreeDOS, shows the VESA modes right, and
Dr. Hardware's 16-bit System Performance gives 27,807 Hardstones and 8612 Softstones
(64 MHz, fpu7b: 26,987 and 8347), +3.0 % and +3.2 % for a 3.1 % faster clock; RAM
average 32.4 MB/s (64 MHz with the L2: 31.4), maximum 42.5, minimum 22.8; it names the
clock 57.7 MHz. PC Player Benchmark (VGA 320x200): 13.7 fps (hicol at 64 MHz: 13.2;
DX2-80s 13.4, DX4-100s 14.7); the Superscape benchmark from Virtual Reality Playhouse
49.5 fps (Superscape's 3DBench 1.0 at 64 MHz: 47.9); Quake 8.0 fps (64 MHz: 7.8). Wing Commander III (setup: CPU speed
12, "Very Fast") plays a mission with its conversations fine; its boot disk maker formats a 1.44 MB disk
in the internal drive (FORMAT /S, no bad sectors) and the PC boots from it. (The stray
last line of that disk's AUTOEXEC.BAT, two bytes, comes from the installer: the same on
an image.) No crash so far. The SDRAM clock phase (`qmon.py sweep`, a reset at each step,
27.06 ps steps, 560 a period of 15.15 ns, from 292.5 degrees): the BIOS boots from -116 to
+108 steps and hangs from -120 and +116 on, a window of about 6.1 ns (40 % of the period)
with 292.5 degrees 3 steps from its middle, about 3 ns of margin either way. Not checked
yet: sound pitch, the PIT, CAPS LOCK's 33 MHz.

v0.2.2 test core (`z486-R6-v022a.cor`, fpu f4fd85b: the x87 store hold, z486 aac6a40), `impl strong
incr` from the 66 MHz layout (99.97 % of cells, 99.95 % of nets reused, 28 minutes): **+0.618 ns** on
main_clk at 66 MHz (+0.318 ns at the target), hold +0.054 ns, every clock met, 88.7K LUTs. Not on
the board yet.

v0.2.2 test core b (`z486-R6-v022b.cor`, fpu bfc146b: the x87 store hold and the INTR error-code
fix for OS/2's TRAP 000D, z486 593bc26), `impl strong incr` from the same 66 MHz layout (99.97 % of
cells, 99.85 % of nets reused, 31 minutes): **+0.482 ns** on main_clk at 66 MHz (+0.182 ns at the
target), hold +0.054 ns, every clock met, 88.7K LUTs. Not on the board yet.

v0.2.2 test core c (`z486-R6-v022c.cor`, fpu 85418f3: v022b, plus z486 a3dbae9, setting PE keeps
the CS selector, for SpeedSys after its header, and the BIOS's "(C)1991" ID string from the
firmware, for SpeedSys's system box), `impl strong incr` from the same 66 MHz layout (96.87 % of
cells, 95.82 % of nets reused, 48 minutes, next to another build): **+0.304 ns** on main_clk at
66 MHz (+0.004 ns at the target), hold +0.008 ns, every clock met, 88.7K LUTs. On the board
(2026-11-11): Chris's 3D Benchmark runs to its end, **Chris's Bench Score 43.3, 25.9 frames per
second** (before: "Floating Point exception at eip=00003df5"). SpeedSys 4.78 runs through (before: it sat
after its header, or in its system box on older cores), MS-DOS 6.22: 80486DX 69 MHz (its own
measure), NPU yes, processor benchmark **23.26**, memory bandwidth 93.14 MB/s, L1 41.90 / L2 34.92
MB/s, memory throughput 30.32 MB/s, VESA ET4000 20728 KB/s; hard disk (fast test, 520C 128H 63S,
2.00 GB): random access 0.42 ms, buffered read 9440 KB/s, linear read 8721 KB/s, hard drive speed
**1684.85**; BIOS shown as "Bochs BIOS for z486. (06/02/26)".

## Builds

The whole core at **64 MHz** with the disks (floppies A: and B:, the IDE hard
disk, the keyboard, the SDRAM clock at 292.5 degrees, debug registers;
incremental from the previous build, CPU pblock, `main_clk` over-constrained
by 0.3 ns during implementation, 18 minutes with synthesis): **all timing
constraints met** with **+0.377 ns** on the PC's clock, no failing endpoint
out of 105,449, hold +0.012 ns, routing complete. 73.1K LUTs (54%), 36.8K
registers, 150.5 block RAM tiles, 86 DSPs.

| Clock | Period | Disks build | First booting build | BIOS loader build | Without the over-constraint |
|---|---|---|---|---|---|
| `main_clk` (the PC) | 15.625 ns | **+0.377 ns** (~65.6 MHz) | +0.327 ns | +0.303 ns | +0.016 ns |
| `hr_clk` (HyperRAM) | 10.000 ns | +0.284 ns | +0.179 ns | +0.194 ns | +0.182 ns |
| `hdmi_clk` | 13.468 ns | +1.707 ns | +2.032 ns | +1.599 ns | +1.854 ns |
| `qnice_clk` | 20.000 ns | +0.561 ns | +0.635 ns | +1.198 ns | +0.999 ns |
| `pc_audio_clk` | 40.723 ns | +3.308 ns | +7.496 ns | +8.900 ns | +7.557 ns |

A build can meet every constraint and still not start the PC: the first CD-ROM
build (2026-10-31) hung before the BIOS's POST 77, z486's watchdog reporting
`Z386 STALL R=1 C=F000 E=0000FFF0` (the first fetch never answered), at every
SDRAM clock phase and after a power cycle. The same sources with the drive
switched off booted, and so did the next full build with it on (a different
placement): something outside the timing analysis was marginal in that one
placement. If a new build shows no POST 77, build again before suspecting the
change.

The first booting build (the SDRAM clock at 292.5 degrees) had +0.327 ns, out of
97,745 endpoints, with 67.1K LUTs (50%), 33.8K registers and 141.5 block RAM
tiles. The debug build before it (a full `impl strong` with the phase still at 180
degrees) ended at +0.134 ns, short of the 0.3 ns target; the incremental run
(`impl incr`, 99.97 % of cells and nets reused, 38 minutes with synthesis)
reached it.

Vivado stops optimizing a clock once it meets timing, so without help the
64 MHz build ended at +0.016 ns, where the next build's variation could tip it
over. `CORE/CORE-impl.xdc` (implementation only) adds 0.3 ns of setup
uncertainty to `main_clk`: place, route and phys_opt aim for 15.325 ns
(65.25 MHz) and reach it (+0.002 and +0.003 ns there in the two builds so
far). `build_impl.tcl` takes the extra uncertainty out before the final
checkpoint and the reports, so they judge against the real 64 MHz;
`summary.txt` lists `main_clk` against both. The other clocks' slack moves
with placement and stays clean.

The slowest paths are still the CPU's, within a few ps of each other at the
target: the prefetch pointer into the decoder's group ROM (18-22 logic
levels), the address unit into the TLB (18) and into the data unit's
registers (21-23), the data unit's write-back (30).

The x87's direct loads and stores (`fpu` branch, z486 026ae5b, 2026-11-04;
[x87](x87.md)), against v0.1-preview:

| Build | `main_clk` | LUTs | Registers | Block RAM | DSPs |
|---|---|---|---|---|---|
| v0.1-preview (`impl incr`) | +0.436 ns | 83,232 | 44,162 | 258.5 tiles | 70 |
| Direct loads, `impl incr` from v0.1-preview | -0.533 ns (607 failing) | 83,704 | 44,315 | 258.5 | 70 |
| Direct loads and stores, `impl strong` | **+0.318 ns** (+0.018 at the target) | 82,904 | 44,399 | 258 | 70 |
| Plus overlap and the shorter retire (z486 74acd11), `impl strong` | **+0.544 ns** (+0.244 at the target) | 84,951 | 44,695 | 258 | 70 |
| Plus exp/log on the polynomial engine (z486 2d424f5), `impl strong` | **+0.326 ns** (+0.026 at the target) | 84,744 | 44,262 | 255 | 67 |
| Plus fast FRNDINT, FSCALE and WAIT (z486 dc48781), `impl strong`: never booted | +0.528 ns (+0.228 at the target) | 86,285 | 44,238 | 255 | 67 |
| The same, `impl strong incr` from the exp/log build (99.3 % of nets reused): boots | +0.305 ns (+0.005 at the target) | 86,195 | 44,260 | 255 | 67 |
| The same, `impl` (the strategy's Explore placer): boots | **+0.607 ns** (+0.307 at the target) | 85,661 | 44,207 | 255 | 67 |
| Plus faster stores (z486 fe56218), `impl strong`: boots | **+0.379 ns** (+0.079 at the target) | 86,048 | 44,383 | 255 | 67 |
| The same, `impl strong incr` from fpu3c (89 % of cells reused) | +0.317 ns (+0.017 at the target) | 85,957 | 44,329 | 255 | 67 |

The microcode ROM's 3072 words fit the block RAMs its 2560 had. The
incremental run reused 96.5 % of v0.1-preview's cells and squeezed the new
logic in around them: the paths that failed were old ones, routing 71-79 % of
their delay (the prefetch pointer into the group ROM, the x87 multiplier, the
TLB into OPR_R, the segment limit). A fresh `impl strong` placed it all with
room; its slowest paths are the load forwarding into the data unit's
registers, the x87 multiplier (+0.332 ns) and the TLB into the address unit.
With the overlap (2,000 more LUTs, in x87_control) the build came out
better still: no x87 path among the slowest, which are the data unit's
write-back, the prefetch pointer into the group ROM and the microcode ROM's
address. Exp/log on the engine freed the log/exp table's 3 block RAM tiles
and 3 DSPs (its interpolation); its slowest paths are the TLB into the data
cache's PLRU bits and the load forwarding, none in the x87
(`z486-R6-fpu2.cor`).

Fast FRNDINT, FSCALE and WAIT added about 1,500 LUTs. Their first build met
every constraint and did not start the PC, like the first CD-ROM build: the
CPU left the BIOS before POST 77 and ran leftover code in low memory (CS 0392,
0082, 0006...), in 10 of 11 boots at the usual SDRAM clock phase, with the L2
cache on or off (the one that got past POST 77 came during a phase sweep,
where -160..+160 all did; the next boot at 0 failed again). The same sources
boot FreeDOS in z486_MiSTer's whole-PC Verilator model, and placed again from
scratch with the Explore directive they boot on the board
(`z486-R6-fpu3c.cor`, the most slack of these builds; its slowest paths are
the load forwarding into the data unit's registers, the TLB into the address
unit and the prefetch pointer into the group ROM, none in the x87). The
incremental build from the exp/log placement (`z486-R6-fpu3b.cor`) boots
too. So a build that shows no POST 77 gets another placement before
anyone suspects the change. fpu3's layout fails the same way on a second
MEGA65, where fpu3c boots: a flaw of the layout that the timing analysis does
not see, not a weak spot of the first board. Both layouts that failed
(`z486-R6-cdrom.bit`, `z486-R6-fpu3.bit`) are kept to look for it.

The faster stores (`z486-R6-fpu4.cor`) closed with 0.38 ns to spare, their
slowest paths the CPU's (the load forwarding into ECX, the TLB into the
segment descriptor cache), and boot on the board; `z486-R6-fpu4b.cor` is the
same sources placed from fpu3c's layout, a spare.

The one-step add (`z486-R6-fpu5.cor`, z486 dbc5fe1; its barrel shift and
leading-zero count are about 330 more LUTs) closed with 0.30 ns to spare on
main_clk, its slowest paths the TLB into the TLB's own registers and into
the address unit, none in the x87. It boots on the board (8347 Softstones in
Dr. Hardware, from fpu4's 7950).

16-bit CALL and RET on the hardwired paths (`z486-R6-fpu6.cor`, z486 7e189be,
about 575 more LUTs) closed with 0.35 ns to spare on main_clk, its slowest
paths the microcode ROM's output into the address unit and the segment
registers, none of the RET's. It boots on the board (Hardstones 26,985,
from fpu5's 26,912).

CMP r,m as a direct ALU load (`z486-R6-fpu7.cor`, z486 533b8a1, on top of
fpu6; about 625 more LUTs) closed with 0.30 ns to spare on main_clk (0.002 ns
at the implementation target), its slowest paths a memory-load commit into
the general registers (whose write now skips a CMP), then the x87
multiplier (+0.517 ns). It never started the PC: POST 00, the CPU stuck in
the BIOS's copy helpers (F000:004C and 0068) with the SDRAM busy, no frames
out, while fpu6 booted on the same board right after. Another flawed layout,
as fpu3's: `z486-R6-fpu7.bit` is kept with the other two.

The same sources placed from fpu6's layout (`z486-R6-fpu7b.cor`, `impl strong
incr`, 99.97 % of cells reused; 87,750 LUTs, 44,435 registers, 255 block RAM
tiles, 67 DSPs) close with 0.136 ns to spare at the real 64 MHz, 0.164 ns
short of the implementation target (12 endpoints), hold +0.036 ns, every
other clock met. Its slowest paths are the data unit's shift into the TLB and
the prefetch pointer into the group ROM. It boots on the board: Hardstones
26,987 (fpu6 26,985), Softstones 8347 and Quake 7.8 fps (both as fpu5).

The VGA connector's sync polarity, the "Refresh" menu line and the SD slot fix
(c0ccc59, on top of fpu7b) missed by 0.100 ns at the real 64 MHz placed from
fpu7b's layout (`impl strong incr`, 99.97 % reused; 11 CPU endpoints, none of
the new logic's). Placed fresh (`z486-R6-vgasdb.cor`, `impl`, Explore; 87,218
LUTs, 44,459 registers, 255 block RAM tiles, 67 DSPs) they close with 0.482 ns
to spare at 64 MHz and 0.182 ns at the implementation target, hold +0.051 ns,
every other clock met: the most margin since the pblock. Its slowest path is
the TLB into the segment limit. Not on the board yet; a fresh layout, so the
first test is that the PC starts at all.

70 Hz native HDMI, the VGA connector fed from the HDMI picture and the menu's
"Joystick: Off" (`z486-R6-vga70b.cor`, on top of vgasdb): placed from vgasdb's
layout (`impl strong incr`) only 96 % of the nets could be kept (the VGA pins'
signals now come from the HDMI side), the router stuck on one congested node
and went from +0.1 to -2.4 ns in its rip-up iterations; stopped after 2 h 13 min.
Placed fresh (`impl`, Explore; 85,848 LUTs, 43,350 registers, 253 block RAM
tiles, 66 DSPs: the analog pipeline's VGA path is gone) it closes with 0.447
ns to spare at 64 MHz and 0.147 ns at the implementation target, hdmi_clk
+0.744 ns at 90 MHz, hold +0.036 ns, every clock met. Its slowest path is the
prefetch pointer into the decoder's group ROM. On the board it boots; VGA on a
Dell P1917S is 720x400 at 70 Hz with clean text (no shimmer, the first column
whole), HDMI 70 Hz in DOS too, and "Joystick: Off" lets DOS Quake start without
its calibration.

The RTC read check, the PC's clock on every restart, the drive LED and the
DSP's output stage (`z486-R6-rtcsnd.cor`, 1e699d1, on top of vga70b): placed
from vga70b's layout (`impl strong incr`, 98.4 % of cells and 94 % of nets
kept, 42 minutes; 86,272 LUTs, 43,554 registers, 253 block RAM tiles, 66 DSPs)
it closes with 0.473 ns to spare at 64 MHz and 0.173 ns at the implementation
target, hold +0.036 ns, every clock met. qnice_clk is down to +0.128 ns (from
+0.649), on QNICE's device reads into its CPU (one more register source).
On the board it boots and reads the clock right after the load; its drive LED
stays amber (it took the SD request toggle for a level; fixed in the source,
for the next build).

The drive LED fix, the 25-row menu canvas, the smaller menu (75 % in the
640/720-pixel modes) and the I/O trace's quiet mode (`z486-R6-osmled.cor`, on
top of rtcsnd): placed from rtcsnd's layout (`impl strong incr`, 99.3 % of
cells and 97 % of nets kept, 40 minutes; 86,338 LUTs, 43,568 registers) it
closes with 0.379 ns to spare at 64 MHz and 0.079 ns at the implementation
target, qnice_clk +0.130 ns, hold +0.036 ns, every clock met. On the board the
drive LED follows the disk accesses in Windows 95, and the file browser fits at
70 Hz; the 75 % menu, though, sat in from the corner and looked soft (fixed for
the next build: half size, anchored in the corner).

The Amiga mouse's right and middle buttons on a mouSTer's active POT lines
(`z486-R6-amouse.cor`, d0da0e9, on top of osmled): placed from osmled's layout
(98.8 % of nets kept, 25 minutes; 86,391 LUTs, 43,622 registers) it closes with
0.361 ns to spare at 64 MHz and 0.061 ns at the implementation target, hold
+0.036 ns, every clock met. Not on the board yet.

The menu at half size in the 640/720 modes, kept in the top right corner
(`z486-R6-osm50.cor`, 39ad0f7, on top of amouse, so with its mouse buttons):
placed from amouse's layout (97.8 % of nets kept, 25 minutes; 86,463 LUTs,
43,665 registers) it closes with 0.393 ns to spare at 64 MHz and 0.093 ns at
the implementation target, hold +0.036 ns, every clock met. On the board
(2026-11-07) it starts the PC, and the menu is right: half size, crisp, in the
top-right corner. A mouSTer in Amiga mode with `activepotlines=true` is seen
as an Amiga mouse with both lines driven (SID 0), and its right button works in
Windows 95. The middle button is not tested (Windows 95 ignores it). A soft
reset keeps the time (the RTC is copied into the CMOS again on the reset).
Switching the mouSTer between Amiga and 1351 mode while Windows 3.11 runs
works both ways (pointer and buttons).

The keyboard fix (`z486-R6-kbd.cor`, 516273d, on top of osm50: no release lost when
the event FIFO is full, the sweep, the translator reset with the PC, its state in
`qmon.py status`): placed from osm50's layout (97.8 % of nets kept, 41 minutes;
86,106 LUTs, 43,737 registers) it closes with 0.400 ns to spare at 64 MHz and
0.100 ns at the implementation target, qnice_clk +0.138 ns, hold +0.036 ns, every
clock met. On the board (2026-11-07) it starts the PC, and `qmon.py status` shows
the keyboard line (no Shift held back, no sweep releases). Shift+F7 (F8) at
Windows 95's start brings up its startup menu, and afterwards Shift, `:` and
the other added Shifts still work (no Shift held back, the sweep sent nothing:
the FIFO lost no release). PIOTEST on the card reformatted with 16 KB clusters:
REP INSW 3,040 KB/s, IN loop 1,918, REP INSD 3,655, IN check 2,226, 16 MB without
a wrong byte, as before.

Disk writes in runs (`z486-R6-wrun.cor`, dc297d1, on top of kbd: one CMD25 per IDE
write command, a four-slot write buffer): placed from kbd's layout (97.7 % of nets
kept, 25 minutes; 86,700 LUTs, 43,883 registers) it closes with 0.365 ns to spare at
64 MHz and 0.065 ns at the implementation target, qnice_clk +0.236 ns, hold
+0.036 ns, every clock met. On the board (2026-11-07) it starts the PC; 4,168
sectors written with nothing failed, a write answered in 51 us on average (the
slowest 2.8 ms: a command's last sector, which waits for its run to be on the
card), from 6,135 us with one CMD24 per sector on kbd; five copies of QBASIC.EXE
compare equal with `fc /b`; PIOTEST's reads as before (REP INSW 3,031 KB/s, REP
INSD 3,637, 20 MB without a wrong byte).
Crusader: No Remorse's 55 MB install from the CD: 62,151 sectors written in
its first 30 MB at 144 us a sector on average (the slowest 35 ms, the card's
own housekeeping), nothing failed: about 9 seconds of writing where one CMD24
per sector took about 6 minutes; the install now waits on the CD and the CPU.

HiColor and TrueColor in a PC's pixel order (`z486-R6-hicol.cor`, 5fc2e68, on top of
wrun: the framebuffer format BGR, 1555): placed from wrun's layout (99.98 % of nets
kept, 23 minutes; 86,710 LUTs, 43,884 registers) it closes with 0.365 ns to spare at
64 MHz and 0.065 ns at the implementation target, qnice_clk +0.154 ns, hold
+0.036 ns, every clock met. On the board (2026-11-07) Windows 95 at High Color
(16 bit), 800x600, has its colours right: the teal desktop, navy title bars, yellow
folders, the palette's rainbow; True Color (24 bit), 640x480, too. Display
Properties' sample bar shows the same stepped two rainbows at 16 and 24 bit (coarser
at 256 colours): Windows' picture, not the colour depth.
Benchmarks on hicol (2026-11-07): 3DBench 1.0 47.9 fps, where Phil's Computer Lab
lists 48.1 for a 486DX2-66 (its [benchmark sheet](https://docs.google.com/spreadsheets/d/1lvF9nOAMKLeCpHR_SaA48M7sUXItwIi72gHRcw0wpNU/)'s 29 DX2-66s: median 43.4, 20.9 to
51.7; Quake 6.7, at most 7.5, where z486 has 7.8; DX2-80s 56.1 and 8.1, DX4-100s
60.6 and 9.1); PC Player Benchmark (VGA 320x200) 13.2 fps (DX2-66s: median 10.9, at
most 12.5; DX2-80s 13.4; DX4-100s 14.7); Landmark System Speed Test 6.00: an
80486DX at 65.775 MHz with an 80487, CPU 322.32 MHz AT, FPU 293.33 MHz 80287,
video 25,869 chr/ms; Norton SI 8.0 CPU index 121.7; SpeedSys's VESA memory 20,786 KB/s (its own sample of a
Pentium MMX 200 with an S3 ViRGE: 11,289); SpeedSys itself stops after its system
box, in a loop reading port 61h (the I/O trace's timer option is for that).

Debug readouts (`z486-R6-natdbg.cor`, d255437 and 46be0ff, on top of hicol: native mode's
measurement in `qmon.py status`, the I/O trace's timer option): placed from hicol's layout
(98.5 % of nets kept, 30 minutes; 86,785 LUTs, 43,943 registers) it closes with 0.532 ns
to spare at 64 MHz and 0.232 ns at the implementation target, qnice_clk +0.741 ns,
hr_rwds +0.066 ns, hold +0.036 ns, every clock met. Not on the board yet.

Super VGA 16 colours (`z486-R6-svga16.cor`, 418ab4c and dd5cfab on top of natdbg: the
scaler at 16 bit for pictures wider than 720 pixels and ascal's 16-bit line fix; with
e85c57f, an ISO that starts with text is no cue sheet): placed from natdbg's
checkpoint, its only failures were `scaler_16bpp`'s crossing into hdmi_clk (-2.343 ns,
timed as synchronous with 0.347 ns). With `CORE.xdc`'s cut on the same layout it has
0.580 ns to spare at 64 MHz and 0.280 ns at the implementation target, hdmi_clk
+0.731 ns, hr_rwds +0.217 ns, hold +0.036 ns, every clock met (86,915 LUTs, 44,011
registers). On the board (2026-11-08) PAT.COM's 800x600 and 640x480 16-colour
pictures are right and steady, and Windows 3.11 at "Super VGA (800x600, 16 colors)"
no longer flickers, jumps or draws stray lines. Native mode leaves out PAT's top
frame line: the line it measures short. The Eleventh Hour's ISO, whose first sector
starts with text and which the firmware refused as a cue sheet over 16K, now mounts
and its installer runs.

Windows 95's CD-ROM driver (`z486-R6-cdsvc.cor`, b3413b4 on top of svga16: status
bit 4, SERVICE on a packet device, no longer set): placed from svga16's layout (99.8 %
of nets kept) it closes with 0.307 ns to spare at 64 MHz and 0.007 ns at the
implementation target, hdmi_clk +0.439 ns, hold +0.025 ns, every clock met (86,701
LUTs, 44,111 registers). On the board (2026-11-08) Windows 95 with its second IDE
controller back finds the CD-ROM drive and uses its own driver: AutoRun starts
Phantasmagoria's installer, Media Player plays Gabriel Knight 2's AVI from the CD, CD
Player plays King's Quest VI's audio tracks.

The HiColor DAC (`z486-R6-hdac.cor`, b87655c on top of cdsvc): placed from cdsvc's
layout (98.5 % of nets kept). Post-route phys_opt left two nets of the x87's command
ROM partially routed (DRC RTSTAT-2: no bitstream); `route_design` on the same
checkpoint finished them, and it closes with 0.131 ns to spare at 64 MHz, hdmi_clk
+0.519 ns, hr_rwds +0.209 ns, hold +0.025 ns, every clock met (86,759 LUTs, 44,193
registers). On the board (2026-11-08) VBEPROBE reads 4F03h as 0110h and 0111h after
setting them (cdsvc: 0101h for both), HICOL's 16-bit ramps are one ramp each (cdsvc:
red and green twice), 15- and 24-bit ramps right; Windows 95 at High Color shows
GRAD.BMP's ramps smooth. But the BIOS now offered 800x600 at 24 bit (115h), whose
picture came out as stripes: the next build's 8-bit register index takes that back.

v0.2 (`z486-R6-v0.2.cor`, built as `z486-R6-v02`: fcac637, the DAC's 8-bit register
index, on top of hdac): placed from hdac's finished layout (99.8 % of nets kept, 25
minutes) it closes with 0.411 ns to spare at 64 MHz and 0.111 ns at the implementation
target, hdmi_clk +0.519 ns, hr_rwds +0.216 ns, qnice_clk +0.844 ns, hold +0.025 ns,
every clock met, every net routed (86,795 LUTs, 44,199 registers). In the full-system
simulation the BIOS marks 115h unavailable again and still reads 110h/111h back. On the
board (2026-11-08, loaded over JTAG, then flashed with MEGAFLASH and started cold):
VBEPROBE reads 110h/111h back and lists 115h as unavailable (`a1A`), `HICOL 115` is
refused; The 7th Guest, Windows 3.11 at 800x600 in 16 colours, Phantasmagoria and King's
Quest VI as before, Quake's `timedemo demo1` as before (7.8 fps); SBMIX after a cold start shows every mixer volume at its reset value
(29 of 31). Once speech sounded quiet against the music (The 7th Guest, Phantasmagoria,
KQ6); it did not come back, on JTAG or flashed, and the Sound Blaster's path has not
changed since v0.1 apart from the output stage, which passes a playing sound as it is.

The road there, at 66.667 MHz (CORE-R6.xpr, Performance_ExplorePostRoutePhysOpt),
with and without the CPU's pblock (`pblock_z486_cpu` in CORE.xdc: clock regions
X0Y1..X1Y2, rows 50..149):

| `main_clk` (15.000 ns) | Without pblock | With pblock | Pblock, `impl strong` |
|---|---|---|---|
| Setup slack | -1.202 ns | -0.392 ns | **-0.249 ns** |
| Est. Fmax | ~61.7 MHz | ~65.0 MHz | **~65.6 MHz** |
| Failing endpoints | 1,848 | 508 | 317 |
| Total negative slack | -826 ns | -83 ns | -28.6 ns |

`impl strong` places with `-directive ExtraTimingOpt` (worse after placement,
-2.27 against -1.26 ns, better after routing, -1.16 against -1.56 ns) and adds a
post-route `phys_opt_design -directive AggressiveExplore` after the strategy's
`Explore` pass (-0.475 -> -0.249 ns).

| | Used | Of the FPGA |
|---|---|---|
| LUTs | 66.4K | 50% |
| Registers | 32.7K | 12% |
| Block RAM | 140.5 tiles | 38% |
| DSPs | 86 | 12% |

In all of these runs every other clock, hold, routing and every clock
crossing are clean.

Without the pblock the CPU spread over six clock regions across the full chip
width. With it, what still fails is a flat wall of CPU paths between -0.29 and
-0.39 ns: the data-cache address into the decoder's PLA ROM (18-19 logic
levels), the segment unit into the TLB and into itself (19-26), the data
unit's write-back (23-28). Routing is still 76-84 % of their delay; the x87
multiplier no longer fails.

From the 66.667 MHz `impl strong` result, 65 MHz would have had about
+0.14 ns and 64 MHz about +0.38 ns; 64 MHz then met timing as above.

Out of context, placed and routed:

| Build | Target | Setup slack | Est. Fmax | LUTs | Block RAM | DSPs |
|---|---|---|---|---|---|---|
| CPU + x87 | 66 MHz | +0.228 ns | ~67 MHz | 39.8K (30%) | 26 tiles | 25 |
| CPU + x87 | 85 MHz | -2.692 ns | ~69 MHz | 41.0K (31%) | 26 tiles | 25 |
| `system.sv` | 66 MHz | +0.005 ns | ~66 MHz | 48.8K (36%) | 101 tiles (28%) | 26 |

`system.sv` by block: CPU 40.2K LUTs, sound (OPL3/SB) 1.9K, VGA/ET4000 1.2K
with 64 RAMB36 for the 256 KB of plane memory, floppy 1.1K; the rest is small.
Hold failures in the out-of-context runs all start at input ports and exist
only out of context.

The slowest paths go through the CPU's address and segmentation logic (TLB,
segment descriptor cache, data-cache hit). +0.005 ns at 66 MHz is within the
build-to-build variation, so the real build needs margin: shorten those paths,
over-constrain, or both.

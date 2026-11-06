# Results so far (XC7A200T-2, Vivado 2022.2)

Part of [z486MEGA65](../README.md). Build and timing results.

## Summary

The whole core synthesizes, places and routes for the R6 (MiSTer2MEGA65, Megamiga's
fork) and meets timing at 64 MHz with 0.3 ns to spare (the CPU floorplanned,
`impl strong`, the PC's clock over-constrained in implementation). 66.667 MHz, a
DX2-66's clock, misses by 0.25 ns (about 65.6 MHz), all inside the CPU.

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
Not on the board yet.

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

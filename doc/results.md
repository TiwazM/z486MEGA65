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

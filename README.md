# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

Status: the MEGA65 shell exists, and the whole core synthesizes, places and
routes for the R6 (MiSTer2MEGA65, Megamiga's fork) and meets timing at 64 MHz
with 0.3 ns to spare (the CPU floorplanned, `impl strong`, the PC's clock
over-constrained in implementation). 66.667 MHz, a DX2-66's clock, misses by
0.25 ns (about 65.6 MHz), all inside the CPU. On an R6 the PC boots its BIOS
from the SD card to the end of POST: the VGA BIOS, the Bochs BIOS banner, then
"No bootable device", as there are no drives yet, nor a keyboard.

## Plan

- **Board:** MEGA65 R6 (XC7A200T-2), on MiSTer2MEGA65 in Megamiga's fork
  ([doc/m2m-provenance.md](doc/m2m-provenance.md)).
- **Memory:** the R6's 64 MB SDRAM for system RAM; HyperRAM for the SVGA
  framebuffer (VRAM) and the boot image.
- **Clock:** 64 MHz. A DX2-66 runs at 66.667 MHz, which the CPU's paths miss by
  0.25 ns with the framework in; 64 MHz meets timing with room for
  build-to-build variation.
- **Disks:** a hardware replacement for MiSTer's ARM-side IDE/floppy handling,
  after `mgmt_bridge.sv` in
  [PCXT-EGA-MEGA65](https://github.com/silent-command/PCXT-EGA-MEGA65)
  (same `ide.v` / `floppy.v`), fed by the fork's hardware SD engine as in
  [pc10-iii](https://github.com/johansmolinski/pc10-iii).
- **Keyboard and mouse:** MEGA65 keyboard and joystick-port mouse as PS/2
  devices, after PCXT-EGA-MEGA65's `keyboard.vhd` and `m65_mouse_ps2.vhd`.
- **Later:** a complete x87 FPU; perhaps a Voodoo 1.

## What the shell does now

- `CORE/sv/z486_mega65.sv` wires z486_MiSTer's `system.sv` (CPU, chipset,
  VGA/ET4000, OPL3/SB, IDE, floppy) and its SDRAM backend (64 MB on the R6's
  IS42S16320F, with DQM) as `z486_mister.sv` does on MiSTer, plus the SVGA
  framebuffer descriptor, the SB Pro mix, and a video stream for M2M
  (positive syncs, separate blanks).
- `CORE/vhdl/mega65.vhd` maps z486's MiSTer DDR3 port into HyperRAM:
  DDR3 `0x3F800000` (the SVGA framebuffer, 4 MB) to HyperRAM `0x400000`, the
  rest (the boot image at `0x300C0000`) into `0x200000`-`0x3FFFFF`, through
  `avm_fifo` and `avm_decrease` (64 to 16 bits). ascal shows the framebuffer
  from HyperRAM (M2M-UPSTREAM rtg-framebuffer).
- Clocks (`CORE/vhdl/clk.vhd`): 64 MHz for the PC and the video, 24.556 MHz
  for OPL3/SB (MiSTer uses 24.576 MHz; 0.08 % slow, about 1.4 cents), one
  MMCM at VCO 1280 MHz.
- The SDRAM clock is a third output of that MMCM at 292.5 degrees, through an
  ODDR (see [SDRAM clock](#sdram-clock)). `sdram.v`'s shortcut below 75 MHz
  (one cycle for tRCD and tRP, 15.6 ns at 64 MHz, under the chip's 18 ns) is
  patched out in the build copy (`tools/z486_sources.py`): two cycles each.
- BIOS: at startup the firmware (`CORE/m2m-rom/m2m-rom.asm`, `PREP_START`)
  loads `boot1.rom` (VGA BIOS, to `0xC0000`) and `boot0.rom` (system BIOS, to
  `0xF0000`, or `0xE0000` if above 64 KB) from the SD card into the HyperRAM
  window z486's boot loader copies from (`0x2C0000`, 256 KB, cleared first).
  The PC stays in reset until they are in (QNICE device `C_DEV_PC_CTL`,
  `mega65.vhd`). A missing or unreadable ROM stops with a message on screen.
  The framework's own ROM auto-loader is not used: it writes one byte per
  HyperRAM word, and z486 reads the ROMs packed.
- Keyboard: the MEGA65 keyboard is the PC's PS/2 keyboard
  (`CORE/vhdl/pc_keyboard.vhd`, `ps2_device.vhd`): scan code set 2, which the
  PC's 8042 translates to set 1, typematic repeat, and the replies to the
  BIOS's keyboard commands, which MiSTer's ARM side gives there. See
  [Keyboard](#keyboard). `CORE/sim/run_keyboard.sh` simulates it against
  z486's 8042 (`ps2.v`).
- Menu: HDMI mode, help, "Reset the PC".
- Debug: `C_DEV_PC_CTL` also holds the SDRAM clock's fine phase, a snapshot
  of the PC's state (boot stage, POST code, CS:EIP, VGA frame count) and a
  4096-entry log of the BIOS's debug port 0x402, z486's stall watchdog,
  POST code changes and the PS/2 keyboard's bytes both ways; `mega65.vhd` has the map. They are read with the M2M
  debug monitor over the JTAG adapter's serial port (115200 baud): hold
  Run/Stop + Cursor Up, then press Help, and run `tools/qmon.py status`
  (`boot` and `sweep` reset the PC at other SDRAM clock phases).

Not wired yet: the IDE/floppy management bus, the PS/2 mouse, joysticks.

## SD card

```
/z486/boot0.rom   the system BIOS
/z486/boot1.rom   the VGA BIOS
```

Both come with z486_MiSTer, in
[`z486_MiSTer/verilator/`](https://github.com/nand2mario/z486_MiSTer/tree/main/verilator)
(the same files MiSTer users put in `/media/fat/games/Z486`). `boot0.rom` is
the Bochs BIOS (LGPL), as in ao486; `boot1.rom` is Tseng Labs' ET4000 VGA
BIOS, which matches the core's ET4000 and is Tseng's code: neither is part of
this repository. The firmware takes them from the card the settings file is on;
without one, from the external microSD slot if it has a card, else from the
internal SD card.

## Keyboard

The keys go by their labels, as on a US PC keyboard (Shift+2 is @, as on a
PC):

| MEGA65 | PC |
|---|---|
| RUN/STOP, ESC | Esc |
| INST/DEL | Backspace; with Shift Insert, with MEGA Delete |
| CLR/HOME | Home; with Shift End |
| RESTORE | Delete |
| F1 F3 F5 F7 F9 F11 | the same; with Shift F2 F4 F6 F8 F10 F12, as on the keycaps (the PC sees no Shift while the key is down) |
| cursor keys | arrows; with MEGA, up/down = Page Up/Down, left/right = Home/End |
| CTRL, ALT, TAB, both shifts | Ctrl, Alt, Tab, Shift |
| CAPS LOCK | Caps Lock (it latches on the MEGA65: each change taps the PC's) |
| NO SCROLL | Scroll Lock |
| `+` and `=` | `=` (with Shift `+`) |
| `-` `:` `@` `*` `;` `£` | `-` `;` `[` `]` `'` `\` |
| arrow-left, arrow-up | `` ` `` |
| MEGA | the Fn key above, nothing by itself |
| F13 | nothing yet |
| HELP | the menu |

## SDRAM clock

`sdram.v` (z486_MiSTer) reads its data three clocks after each READ command.
MiSTer runs it at 85 MHz with the SDRAM clock at 180 degrees; at 64 MHz on the
R6 that phase puts the read outside the data window, and the first bitstream
ran garbage from F000:FFF0 on (black screen). With the phase swept at run
time (the MMCM's dynamic phase shift, in 13.95 ps steps), the PC boots for
every phase from 180 degrees + 130 steps to + 570 steps (1.81 to 7.95 ns
later), and fails at +120 and +580. The core uses the middle, +350 steps =
4.88 ns = 292.5 degrees, 3.07 ns from either edge. That window is one board's;
another R6 can be measured the same way.

## Layout

- `CORE/` - the MEGA65 core: `vhdl/`, `sv/`, the firmware (`m2m-rom/`), the
  constraints (`CORE.xdc`; `CORE-impl.xdc` for implementation only), the
  project (`CORE-R6.xpr`, generated), `build_synth.tcl` and `build_impl.tcl`
- `M2M/` - the framework (vendored from Megamiga, QNICE as a submodule)
- `z486/` - the CPU (submodule, nand2mario/z486)
- `z486_MiSTer/` - the MiSTer PC core (submodule, nand2mario/z486_MiSTer)
- `ooc/` - out-of-context Vivado builds of the CPU and of `system.sv`
- `tools/` - `build_r6.sh` (the core's build in Docker), `gen_xpr.py` (the
  project), `z486_sources.py` (the source list and the Vivado 2022.2 copies),
  `qmon.py` (the debug registers through the M2M debug monitor)

Clone with `git clone --recursive`, or run `git submodule update --init` after
cloning (z486_MiSTer's own submodules are not needed).

## Building

Vivado 2022.2 in the vivado-on-mac Docker setup (`m65build` image):

```sh
tools/build_r6.sh            # synthesize the core; reports in CORE/reports/synth/
tools/build_r6.sh reports    # re-report the last synthesis after constraint changes
tools/build_r6.sh impl       # synthesize if needed, then place and route; CORE/reports/impl/
tools/build_r6.sh finish     # only the post-route phys_opt_design and reports of the last impl
tools/build_r6.sh impl strong   # the same with place ExtraTimingOpt and a post-route
                                # AggressiveExplore phys_opt pass
tools/build_r6.sh impl incr  # incremental place and route from CORE/reports/ref/
tools/build_r6.sh bit        # the last impl's bitstream and core file, CORE/bitstream/z486-R6.cor
```

`build_r6.sh` regenerates `CORE/CORE-R6.xpr` and the source copies in
`CORE/gen/`, then runs `CORE/build_synth.tcl` or `CORE/build_impl.tcl`.
Implementation stops after the strategy's post-route `phys_opt_design`; `bit`
writes the bitstream from its checkpoint (`CORE/build_bit.tcl`) and makes the
`.cor` with `coretool` from the MEGA65 tools release (`CORETOOL=path`, default
`~/Downloads/m65tools-release-1.00-macos/coretool`). MEGAFLASH shows it as
"z486", version "WIP-" and the commit. `incr` places and routes incrementally
(directive TimingClosure) from the routed checkpoint in `CORE/reports/ref/`:
copy a good build's `CORE/reports/impl/mega65_r6_routed.dcp` there, and the
next small change keeps the rest of its placement and routing. Synthesis takes
about 8 minutes, a full `impl strong` about an hour more. To open the project
in the Vivado GUI, run `python3 tools/gen_xpr.py` first.

Out-of-context builds of the CPU or of `system.sv` alone:

```sh
cd ooc
./run_ooc.sh 1 66                              # CPU with x87 at 66 MHz
OOC_TCL=z486_pc_a7.tcl ./run_ooc.sh 1 66       # system.sv at 66 MHz
OOC_TCL=z486_pc_a7.tcl ./run_ooc.sh 1 66 xc7a200tfbg484-2 resume   # P&R only
```

Toolchain notes (Vivado 2022.2):

- z486 and z486_MiSTer set `` `default_nettype none `` and declare ports
  without a net type, which 2022.2 rejects (Synth 8-6735; the error cannot be
  downgraded). The builds read copies with `` `default_nettype wire `` (only
  the lint check is lost): `CORE/gen/` for the core, `build-*/patched/` for
  the out-of-context runs.
- z486_MiSTer's `.v` files use SystemVerilog: the project reads every z486
  source as SystemVerilog.
- Under Docker emulation, Vivado's WebTalk host-info lookup crashes in libudev
  (`realloc(): invalid pointer`). The scripts turn WebTalk off and run in the
  `m65build` image, whose `LD_PRELOAD` avoids the same crash in the license
  library.
- `Z486_XILINX` selects the Xilinx RAM variants; nothing Intel-only is left.

## Results so far (XC7A200T-2, Vivado 2022.2)

The whole core at **64 MHz** as it boots on the R6 (BIOS loader, SDRAM clock at
292.5 degrees, debug registers; incremental from the previous build, CPU
pblock, `main_clk` over-constrained by 0.3 ns during implementation): **all
timing constraints met** with **+0.327 ns** on the PC's clock, no failing
endpoint out of 97,745, hold +0.012 ns, routing complete. 67.1K LUTs (50%),
33.8K registers, 141.5 block RAM tiles, 86 DSPs.

| Clock | Period | Setup slack | BIOS loader build | Without the over-constraint |
|---|---|---|---|---|
| `main_clk` (the PC) | 15.625 ns | **+0.327 ns** (~65.4 MHz) | +0.303 ns | +0.016 ns |
| `hr_clk` (HyperRAM) | 10.000 ns | +0.179 ns | +0.194 ns | +0.182 ns |
| `hdmi_clk` | 13.468 ns | +2.032 ns | +1.599 ns | +1.854 ns |
| `qnice_clk` | 20.000 ns | +0.635 ns | +1.198 ns | +0.999 ns |
| `pc_audio_clk` | 40.723 ns | +7.496 ns | +8.900 ns | +7.557 ns |

The debug build before it (a full `impl strong` with the phase still at 180
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

## Credits

- z486 and z486_MiSTer by nand2mario. The z486 microcode image comes with the
  z486 submodule and is not covered by its licence; this repository does not
  contain a copy.
- MiSTer2MEGA65 by sy2002 and MJoergen; Megamiga's fork and pc10-iii by Johan
  Smolinski (the framework, the shell's starting point).
- PCXT-EGA-MEGA65 by silent-command, for the approaches to storage, keyboard
  and mouse on the MEGA65.

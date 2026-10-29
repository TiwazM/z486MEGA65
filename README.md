# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

Status: the MEGA65 shell exists, and the whole core synthesizes, places and
routes for the R6 (MiSTer2MEGA65, Megamiga's fork). It misses 66.667 MHz by
1.2 ns (about 61.7 MHz), all inside the CPU. There is no bitstream, and it
cannot boot yet: no boot image loader, no drives, no keyboard.

## Plan

- **Board:** MEGA65 R6 (XC7A200T-2), on MiSTer2MEGA65 in Megamiga's fork
  ([doc/m2m-provenance.md](doc/m2m-provenance.md)).
- **Memory:** the R6's 64 MB SDRAM for system RAM; HyperRAM for the SVGA
  framebuffer (VRAM) and the boot image.
- **Clock:** 66.667 MHz (a DX2-66's).
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
- Clocks (`CORE/vhdl/clk.vhd`): 66.667 MHz for the PC and the video, 24.615 MHz
  for OPL3/SB (MiSTer uses 24.576 MHz; 0.16 % fast).
- The SDRAM clock is the PC clock inverted, through an ODDR; the right phase
  for the R6's traces still has to be found on a board.
- Menu: HDMI mode, help, "Reset the PC". The firmware
  (`CORE/m2m-rom/m2m-rom.asm`) has the fork's callbacks as stubs.

Not wired yet: the IDE/floppy management bus, PS/2 keyboard and mouse,
joysticks, the boot image loader (QNICE loading `boot0.rom`/`boot1.rom` into
HyperRAM at `0x2C0000`).

## Layout

- `CORE/` - the MEGA65 core: `vhdl/`, `sv/`, the firmware (`m2m-rom/`), the
  constraints (`CORE.xdc`), the project (`CORE-R6.xpr`, generated) and
  `build_synth.tcl`
- `M2M/` - the framework (vendored from Megamiga, QNICE as a submodule)
- `z486/` - the CPU (submodule, nand2mario/z486)
- `z486_MiSTer/` - the MiSTer PC core (submodule, nand2mario/z486_MiSTer)
- `ooc/` - out-of-context Vivado builds of the CPU and of `system.sv`
- `tools/` - `build_r6.sh` (the core's synthesis in Docker), `gen_xpr.py` (the
  project), `z486_sources.py` (the source list and the Vivado 2022.2 copies)

Clone with `git clone --recursive`, or run `git submodule update --init` after
cloning (z486_MiSTer's own submodules are not needed).

## Building

Vivado 2022.2 in the vivado-on-mac Docker setup (`m65build` image):

```sh
tools/build_r6.sh            # synthesize the core; reports in CORE/reports/synth/
tools/build_r6.sh reports    # re-report the last synthesis after constraint changes
tools/build_r6.sh impl       # synthesize if needed, then place and route; CORE/reports/impl/
tools/build_r6.sh finish     # only the post-route phys_opt_design and reports of the last impl
```

`build_r6.sh` regenerates `CORE/CORE-R6.xpr` and the source copies in
`CORE/gen/`, then runs `CORE/build_synth.tcl` or `CORE/build_impl.tcl`.
Implementation stops after the strategy's post-route `phys_opt_design`:
nothing here writes a bitstream. To open the project in the Vivado GUI, run
`python3 tools/gen_xpr.py` first.

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

The whole core, placed and routed (CORE-R6.xpr, Performance_ExplorePostRoutePhysOpt):

| | Used | Of the FPGA |
|---|---|---|
| LUTs | 66.4K | 50% |
| Registers | 32.7K | 12% |
| Block RAM | 140.5 tiles | 38% |
| DSPs | 86 | 12% |

| Clock | Period | Setup slack | Est. Fmax |
|---|---|---|---|
| `main_clk` (the PC) | 15.000 ns | **-1.202 ns** (1,848 endpoints) | ~61.7 MHz |
| `hr_clk` (HyperRAM) | 10.000 ns | +0.279 ns | |
| `hdmi_clk` | 13.468 ns | +1.865 ns | |
| `qnice_clk` | 20.000 ns | +0.820 ns | |
| `pc_audio_clk` | 40.625 ns | +7.130 ns | |

Hold is met everywhere (+0.013 ns), routing is complete, every clock crossing
meets. Every failing endpoint is inside the CPU, in three families: the data
unit's write-back into the registers (27-28 levels), the x87 multiplier into its
work register (28 levels), and the data-cache address into the decoder's PLA
ROM (18-19 levels). Routing is 76-82% of the integer paths' delay, about 1 ns
more than in the CPU-alone build: the CPU spreads out next to the framework.

At 60 MHz (16.667 ns) the same placement would have +0.46 ns; 62.5 MHz would
still miss by about 0.2 ns.

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

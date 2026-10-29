# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

Status: feasibility. The CPU and the whole PC (`system.sv`) synthesize and
route for the MEGA65's FPGA at 66 MHz. There is no MEGA65 shell yet and no
bitstream.

## Plan

- **Board:** MEGA65 R6 (XC7A200T-2), on the MiSTer2MEGA65 framework.
- **Memory:** the R6's 64 MB SDRAM for system RAM; HyperRAM for the SVGA
  framebuffer (VRAM). z486's SDRAM controller already supports the 64 MB
  single-chip layout of the R6's IS42S16320F.
- **Clock:** 66 MHz (DX2-66).
- **Disks:** a hardware replacement for MiSTer's ARM-side IDE/floppy handling,
  after `mgmt_bridge.sv` in
  [PCXT-EGA-MEGA65](https://github.com/silent-command/PCXT-EGA-MEGA65)
  (same `ide.v` / `floppy.v`), fed by a hardware SD-card engine as in
  [pc10-iii](https://github.com/johansmolinski/pc10-iii).
- **Keyboard and mouse:** MEGA65 keyboard and joystick-port mouse as PS/2
  devices, after PCXT-EGA-MEGA65's `keyboard.vhd` and `m65_mouse_ps2.vhd`.
- **Later:** a complete x87 FPU; perhaps a Voodoo 1.

## Layout

- `z486/` - the CPU (submodule, nand2mario/z486)
- `z486_MiSTer/` - the MiSTer PC core (submodule, nand2mario/z486_MiSTer)
- `ooc/` - out-of-context Vivado builds for the MEGA65's FPGA
  - `z486_cpu_a7.tcl` - the CPU alone
  - `z486_pc_a7.tcl` - the whole PC (`system.sv`), with `pc_sources.f`
  - `run_ooc.sh` - runs either in Docker (vivado-on-mac, `m65build` image)

Clone with `git clone --recursive`, or run `git submodule update --init` after
cloning (z486_MiSTer's own submodules are not needed).

## Out-of-context builds

```sh
cd ooc
./run_ooc.sh 1 66                              # CPU with x87 at 66 MHz
OOC_TCL=z486_pc_a7.tcl ./run_ooc.sh 1 66       # the whole PC at 66 MHz
OOC_TCL=z486_pc_a7.tcl ./run_ooc.sh 1 66 xc7a200tfbg484-2 resume   # P&R only
```

Arguments: x87 on/off, MHz, part, and `resume` to start from the run's saved
synthesis checkpoint. Results land in `ooc/build-*/` (`summary.txt`, timing and
utilization reports). The scripts stop at the routed checkpoint: they never
write a bitstream.

Toolchain notes (Vivado 2022.2, the M2M toolchain):

- z486 sets `` `default_nettype none `` and declares ports without a net type,
  which 2022.2 rejects (Synth 8-6735). The scripts read a copy with
  `` `default_nettype wire ``; this only drops the lint check.
- Under Docker emulation, Vivado's WebTalk host-info lookup crashes in libudev
  (`realloc(): invalid pointer`) right after routing. The scripts turn WebTalk
  off and run in the `m65build` image, whose `LD_PRELOAD` avoids the same crash
  in the license library.
- `Z486_XILINX` selects the Xilinx RAM variants. Nothing Intel-only is left in
  the PC: `dpram_difclk` has an XPM branch upstream, and `simple_fifo_mlab`
  (Intel `altdpram`) is not instantiated.

## Results so far (XC7A200T-2, Vivado 2022.2, out of context)

| Build | Target | Setup slack | Est. Fmax | LUTs | Block RAM | DSPs |
|---|---|---|---|---|---|---|
| CPU + x87 | 66 MHz | +0.228 ns | ~67 MHz | 39.8K (30%) | 26 tiles | 25 |
| CPU + x87 | 85 MHz | -2.692 ns | ~69 MHz | 41.0K (31%) | 26 tiles | 25 |
| Whole PC | 66 MHz | +0.005 ns | ~66 MHz | 48.8K (36%) | 101 tiles (28%) | 26 |

Whole PC by block: CPU 40.2K LUTs, sound (OPL3/SB) 1.9K, VGA/ET4000 1.2K with
64 RAMB36 for the 256 KB of plane memory, floppy 1.1K; the rest is small.
The audio clock (24.576 MHz) has 29.7 ns of slack. Hold failures in these runs
all start at input ports and exist only out of context.

The worst path at 66 MHz runs from the TLB through the L1 data-cache hit check
and the microcode branch into the segment descriptor cache's enable (20 logic
levels). +0.005 ns is within the build-to-build variation, so the real build
needs margin: shorten that path, over-constrain (e.g. 70 MHz), or both.

With the M2M framework as measured by pc10-iii (~19.3K LUTs, 43.5 tiles,
59 DSPs) the whole core would use about 51% of the LUTs, 40% of the block RAM
and 11% of the DSPs.

## Credits

- z486 and z486_MiSTer by nand2mario. The z486 microcode image comes with the
  z486 submodule and is not covered by its licence; this repository does not
  contain a copy.
- MiSTer2MEGA65 by sy2002 and MJoergen.
- PCXT-EGA-MEGA65 by silent-command and pc10-iii by Johan Smolinski, for the
  approaches to storage, keyboard and mouse on the MEGA65.

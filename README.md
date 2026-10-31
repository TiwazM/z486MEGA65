# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

Status: the MEGA65 shell exists, and the whole core synthesizes, places and
routes for the R6 (MiSTer2MEGA65, Megamiga's fork) and meets timing at 64 MHz
with 0.3 ns to spare (the CPU floorplanned, `impl strong`, the PC's clock
over-constrained in implementation). 66.667 MHz, a DX2-66's clock, misses by
0.25 ns (about 65.6 MHz), all inside the CPU. On an R6 the PC boots its BIOS
from the SD card, typed on the MEGA65 keyboard as the PC's PS/2 keyboard, and
FreeDOS 1.4 installs from its boot floppies (image files on the card, swapped
through the menu) onto the IDE hard disk (a 2 GB image file on the card) and
boots from it.

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
  rest (the boot image at `0x300C0000`) into `0x300000`-`0x3FFFFF`, through
  `avm_fifo` and `avm_decrease` (64 to 16 bits). ascal shows the framebuffer
  from HyperRAM (M2M-UPSTREAM rtg-framebuffer). Below `0x300000` ascal keeps
  three frames of the VGA picture (triple buffering): the PC's 70 Hz text mode
  on 60 Hz HDMI otherwise showed half-old, half-new frames where the screen
  changed (a flickering clock, stray lines, the cursor). The scaler
  interpolates sharp bilinear: the 720x400 text mode scales by 1.2 (480p,
  720x480) or 1.8 (720p), and nearest-neighbour made diagonal strokes uneven.
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
  window z486's boot loader copies from (`0x3C0000`, 256 KB, cleared first).
  The PC stays in reset until they are in (QNICE device `C_DEV_PC_CTL`,
  `mega65.vhd`). A missing or unreadable ROM stops with a message on screen.
  The framework's own ROM auto-loader is not used: it writes one byte per
  HyperRAM word, and z486 reads the ROMs packed.
- Firmware space: the QNICE ROM holds 28,286 of its 32,768 words. The FAT32
  write layer (the Shell's settings file) lives in code banks 0 and 1, 4K-word
  banks behind the window 0x9000-0x9FFF (Megamiga's code-banks, as in MegaMac),
  called through `FAR_CALL` stubs; six banks are free.
- Keyboard: the MEGA65 keyboard is the PC's PS/2 keyboard
  (`CORE/vhdl/pc_keyboard.vhd`, `ps2_device.vhd`): scan code set 2, which the
  PC's 8042 translates to set 1, typematic repeat, and the replies to the
  BIOS's keyboard commands, which MiSTer's ARM side gives there. See
  [Keyboard](#keyboard).
- Mouse: an Amiga mouse on joystick port 1, or a USB mouse behind a mouSTer in
  Amiga mode, is the PC's PS/2 mouse (`CORE/vhdl/pc_mouse.vhd`): its
  quadrature lines as MegaMac decodes them, the left button on pin 6. The
  right button (pin 9) is invisible to the MEGA65's paddle circuit (Megamiga
  measured it), so F13 stands in for it. The mouse answers the BIOS's and the
  drivers' commands (reset, identify, sample rate, status, ...) like a
  standard PS/2 mouse, also when nothing is plugged in: the BIOS's mouse
  functions, which CuteMouse calls, wait for good for a mouse that does not
  answer. `CORE/sim/run_ps2.sh` simulates the keyboard and the mouse against
  z486's 8042 (`ps2.v`).
- Disks (`CORE/vhdl/disk_sd.vhd`, `pc_mgmt.vhd`): MiSTer's ARM side, which
  serves z486's floppy and IDE controllers and fills the CMOS through the
  management bus, is in hardware (`pc_mgmt`): at power-up the CMOS
  (equipment, base memory, checksum, the date and time from the MEGA65's RTC);
  then floppy drives A: and B: (`floppy.v`: insert/eject, the sector
  requests) and the hard disk, the master of the first IDE channel (`ide.v`:
  IDENTIFY, reads and writes, one sector per block), with the CMOS's drive
  types following the images. `disk_sd` reads and writes each sector straight
  in the image file through the SD host controller's engine port (Megamiga's
  sd-host), with the file's extent map from the firmware (fragmented files are
  fine). See [Disks](#disks). `CORE/sim/run_disks.sh` simulates them against
  z486's `floppy.v`, `ide.v` and `rtc.v`.
- Menu: floppy A:, floppy B:, hard disk, HDMI mode, help, "Reset the PC".
- HDMI modes: 720p 60 Hz (the PC's 4:3 picture between bars), 480p, 800x600,
  1024x768 and 1280x1024 at 60 Hz. 1280x1024 is a 5:4 monitor's own
  resolution: the picture is 1280x960 between bars and the monitor scales
  nothing, where 480p or 720p are scaled twice (by the core and by the
  monitor). It uses reduced blanking (the 63.2 kHz / 59.79 Hz of VESA's
  CVT-RB) at 90 MHz: VESA's DMT timing needs 108 MHz, at which the HDMI
  domain misses timing (the menu overlay's blending). The 90 MHz is a new
  entry in the framework's HDMI clock (M2M-UPSTREAM sxga-mode:
  `video_out_clock.vhd`, values from Xilinx's MMCM functions; the HDMI
  domain is timed at it), and the scaler is built without its bicubic and
  polyphase interpolators (`ASCAL_MASK` in `globals.vhd`), whose DSP paths
  were the slowest of that domain.
- L2 cache (`CORE/sv/guest_l2.sv`, after MegaMac's): 256 KB of block RAM
  between the CPU's memory port and the SDRAM, as on a 486 board:
  direct-mapped, 16-byte lines, write-through. A line fill that hits is
  answered from the cache; stores update cached lines; floppy and Sound
  Blaster DMA (the SDRAM's second port) drop their lines before the CPU's
  next lookup. `tools/qmon.py l2` shows the fills from the cache and from the
  SDRAM, `l2 off` / `l2 on` switch it for comparisons. `CORE/sim/run_l2.sh`
  checks it against a memory model with DMA writes and switching. Measured
  (2026-10-31, the same build): Doom's `-timedemo demo3` 35.7 fps without,
  36.9 fps with it (+3.5%), 76% of the line fills from the cache: Doom's hot
  data mostly fits z486's own 8 + 8 KB. Dr. Hardware: average RAM throughput
  24.5 -> 31.4 MB/s (+28%; blocks between the L1's 16 KB and 256 KB), the
  minimum (beyond 256 KB) and maximum (within the L1) unchanged, Hardstones
  26345 -> 27418 (+4%).
- Debug: `C_DEV_PC_CTL` also holds the SDRAM clock's fine phase, a snapshot
  of the PC's state (boot stage, POST code, CS:EIP, VGA frame count, the L2's
  counters) and a 4096-entry log of the BIOS's debug port 0x402, z486's
  stall watchdog, POST code changes and the PS/2 keyboard's bytes both ways;
  `mega65.vhd` has the map. `tools/qmon.py` reads them over the JTAG
  adapter's serial port (115200 baud) while the PC and the menu run: the
  firmware answers serial commands in the Shell's background (`R`/`W` QNICE
  memory, `D`/`P` a device's registers, as MegaMac does), no debug mode
  needed. `qmon.py status` (`disks` the mounted images, the sector counts and
  times; `boot` and `sweep` reset the PC at other SDRAM clock phases).
  `QMON_MONITOR=1` talks to the M2M debug monitor instead (hold Run/Stop +
  Cursor Up, then press Help).

Not wired yet: joysticks, the second IDE channel (a CD-ROM), the MEGA65's own
floppy drive.

## SD card

```
/z486/boot0.rom    the system BIOS
/z486/boot1.rom    the VGA BIOS
/z486/floppy.img   optional: drive A: at start-up (a raw floppy image)
/z486/hdd.img      optional: the hard disk at start-up (a raw disk image)
```

Both come with z486_MiSTer, in
[`z486_MiSTer/verilator/`](https://github.com/nand2mario/z486_MiSTer/tree/main/verilator)
(the same files MiSTer users put in `/media/fat/games/Z486`). `boot0.rom` is
the Bochs BIOS (LGPL), as in ao486; `boot1.rom` is Tseng Labs' ET4000 VGA
BIOS, which matches the core's ET4000 and is Tseng's code: neither is part of
this repository. The firmware takes them from the card the settings file is on;
without one, from the external microSD slot if it has a card, else from the
internal SD card.

## Disks

The menu's "Floppy A:", "Floppy B:" and "Hard disk:" lines mount an image file
from the card, under any name; writes go to the file.

- **Floppies:** raw images of 360K, 720K, 1.2M, 1.44M or 2.88M; the size gives
  the geometry and the drive type in the CMOS. A floppy mounted while the PC
  runs is a disk change, as on a real drive, so disks can be swapped during an
  installation. The PC boots from A: when it holds a floppy, else from the
  hard disk (z486's default boot order, as on MiSTer).
- **Hard disk:** a raw image of any whole number of 512-byte sectors, up to
  4 GB less 512 bytes, the largest file FAT32 holds. The BIOS looks for disks
  only when the PC starts: after mounting one from the menu, "Reset the PC".
  It reads the size from IDENTIFY (LBA) and translates for DOS.
- **Eject:** every folder of the file browser starts with `<No Disk>` (right
  after `<..>`): choosing it empties the drive. A mount lasts until the
  MEGA65 is switched off; only `/z486/floppy.img` and `/z486/hdd.img` come
  back by themselves.

An empty hard disk, on macOS (or `truncate -s 2G hdd.img` on Linux):

```bash
mkfile -n 2g hdd.img
```

Copy it to the card as `/z486/hdd.img`, boot FreeDOS's boot floppy from A:,
and let the installer partition and format C: (it restarts the PC in between)
and install, swapping the floppies through the menu's "Floppy A:" line. To
start from C: afterwards, choose `<No Disk>` for A: and "Reset the PC".

Each sector goes to the card on its own, so writing is slow (DOS without a
disk cache rewrites the FAT for every file). `tools/qmon.py disks` shows the
sector counts and the time per sector (`disks clear` zeroes them, `disks
watch 10` counts sectors per second over 10 seconds).

`tools/floppy-packer.html`, a page that runs in any browser without a server,
packs files into a FAT12 floppy image of any of the five sizes, with DOS's
8.3 file names checked.

## Keyboard

The keys go by their labels: letters and digits as on a PC, the symbols as
printed on the MEGA65's keycaps:

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
| symbol keys and shifted digits | as on their keycaps: `:` (Shift `[`), `;` (Shift `]`), `@`, `*`, `+`, `-`, `=`, Shift+2 `"`, Shift+6 `&`, Shift+7 `'`, Shift+8 `(`, Shift+9 `)`, ... (the PC sees Shift pressed or released as each one needs) |
| PC symbols without a keycap | `£` `\` (Shift `|`), arrow-up `^` (Shift `~`), arrow-left `` ` ``, Shift+`-` `_`, Shift+`@` `{`, Shift+`*` `}` |
| MEGA | the Fn key above, nothing by itself |
| F13 | the mouse's right button (see Mouse above) |
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
  `qmon.py` (the debug registers through the M2M debug monitor),
  `floppy-packer.html` (files into a floppy image, in a browser)

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
tools/build_r6.sh patch      # firmware only (m2m-rom.asm): the last impl's bitstream with the
                             # current firmware, in minutes, no synthesis
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

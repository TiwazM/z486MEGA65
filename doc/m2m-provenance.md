# Provenance of the vendored framework (M2M/)

`M2M/` is the MiSTer2MEGA65 framework as modified by the **Megamiga** project
(johansmolinski/Megamiga), copied unchanged (tracked files only) from its `main`
branch at commit **`85fd76f`** (2026-10-27). The base is M2M V2.0.1 (sy2002 and
MJoergen, GPL-3.0) plus Megamiga's framework exceptions, each tagged
`M2M-UPSTREAM <name>` in the code and listed in Megamiga's `AGENTS.md`. The ones
z486 relies on:

- `sdram-pins`: the R4/R5/R6 SDRAM pins reach the core (`MEGA65_Core`).
- `rtg-framebuffer`: ascal can show a framebuffer in HyperRAM (MiSTer's FB_*
  semantics), used for z486's SVGA modes.
- `sd-host`: the native 4-bit SD host with an engine port for the core (the
  fast disk path pc10-iii uses; not wired yet).
- `core-io-hook`, `cfg-strings`, `code-banks`, `rom-32k`: the firmware
  callbacks and memory layout `CORE/m2m-rom/m2m-rom.asm` follows.

`M2M/QNICE` is a git submodule: johansmolinski/QNICE-FPGA, branch
`fat32-fastseek`, pinned to **`78aeaac`**, the commit Megamiga `main` pins.

`tools/megamiga-CORE-R6.xpr` is Megamiga's `CORE/CORE-R6.xpr` at the same
commit: `tools/gen_xpr.py` takes the framework's file list and settings from it.

The CORE side (`CORE/vhdl/mega65.vhd`'s entity, `config.vhd`, `globals.vhd`,
`clk.vhd`, the firmware build in `CORE/m2m-rom/`, `tools/gen_xpr.py`) started
from pc10-iii (johansmolinski/pc10-iii at `0f363cb`), which uses the same fork
(its R6 board top is identical to this one).

Rules (Megamiga's):

- Leave `M2M/` as it is. A framework change that cannot be avoided gets an
  `M2M-UPSTREAM <name>` tag at every changed place and an entry here:
  - `reset-write` (`M2M/vhdl/av_pipeline/ascal.vhd`): ascal's write request
    resets; a reset in one of its input write bursts left a burst half done,
    and the HyperRAM side waited for its beats for good.
  - `16bpp-eol` (`M2M/vhdl/av_pipeline/ascal.vhd`): in 16-bit mode the end of a
    line's burst count step and the next line's reset came in the same clock,
    so every other line was never written.
  - `scaler-16bpp` (`digital_pipeline.vhd`, `av_pipeline.vhd`, `framework.vhd`,
    `top_mega65-r6.vhd`): the core can ask ascal to keep its picture at 16 bit
    (565) instead of 24; z486 does for pictures wider than 720 pixels, whose
    24-bit write and read exceed the HyperRAM's bandwidth.
  - `typematic-time` (`M2M/rom/sysdef.asm`, `keyboard.asm`,
    `keyboard_vars.asm`): the cursor keys' repeat in the Shell's menus starts
    after 0.4 s and steps 20 times a second, timed with QNICE's cycle counter.
    M2M counted it in keyboard scans, which our menu loop (both SD slots, the
    drives, the serial monitor in `HANDLE_CORE_IO`) makes much slower than the
    0.5 s and 12 per second it was tuned for.
- `.xpr` SFType values: only `VHDL2008`, `SVerilog` or none (anything else
  makes Vivado crash on project open).
- To update: copy Megamiga's `M2M/` again (tracked files only), move the
  submodule to the commit Megamiga pins, copy its `CORE/CORE-R6.xpr` to
  `tools/megamiga-CORE-R6.xpr`, update the hashes above, and rebuild.

Known framework warnings (also in Megamiga's builds): an empty pblock for
upstream's old SD card controller (`MEGA65-R6.xdc`), a false path through
ascal's `reset_na` that synthesis optimizes away (`common.xdc`), and IOB/pblock
notes on the HyperRAM pins.

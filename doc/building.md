# Building

Part of [z486MEGA65](../README.md).

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
  `floppy-packer.html` (files into a floppy image, in a browser), `dos/` (the
  DOS test programs, PIOTEST and VTEST)

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

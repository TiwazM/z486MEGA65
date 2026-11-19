#!/bin/zsh
# Runs CORE/sim/tb_gus.sv (CORE/sv/gus.sv: the Gravis Ultrasound around LPC-GUS's gf1.v, behind
# iobus_adapter.sv with its io_hold, its DMA through system.sv's dma.v) with iverilog
# (Homebrew). Prints each check and PASS or FAILED. The adapter is the patched copy:
# tools/z486_sources.py writes it into CORE/gen first. dma.v declares a few signals after
# their first use, which iverilog rejects: hoist_decls.py makes a copy with them moved up.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build
mkdir -p "$build"
python3 "$root/tools/z486_sources.py" > /dev/null
files=("$root/CORE/sv/gus/gf1.v" "$root/CORE/sv/gus.sv"
       "$root/CORE/gen/z486_MiSTer/src/iobus_adapter.sv" "$build/dma_sim.v" "$root/CORE/sim/tb_gus.sv")
python3 -I "$root/CORE/sim/hoist_decls.py" "$root/z486_MiSTer/src/soc/dma.v" "$build/dma_sim.v" \
    "iverilog -g2012 -o $build/tb_gus ${files[*]}"
defs=()
[[ "$1" == 512 ]] && defs=(-DGUS512)   # run_gus.sh 512: the 512 KB build option
iverilog -g2012 "${defs[@]}" -o "$build/tb_gus" "${files[@]}" 2> /dev/null
vvp "$build/tb_gus" | grep -E "^(ok|FAIL|PASS|FAILED|     )"

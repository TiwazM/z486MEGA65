#!/usr/bin/env bash
# Runs CORE/sim/tb_floppy_err.sv (the floppy.v patch for the internal floppy drive) with Icarus
# Verilog against CORE/gen's patched floppy.v, in CORE/sim/build/iv_floppy_err. Prints each
# check and PASS.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
python3 "$root/tools/z486_sources.py" > /dev/null
build=$root/CORE/sim/build/iv_floppy_err
mkdir -p "$build"
iverilog -g2012 -o "$build/tb" "$root/CORE/sim/tb_floppy_err.sv" \
    "$root/CORE/gen/z486_MiSTer/src/soc/floppy.v" "$root/z486_MiSTer/src/common/simple_fifo.v"
vvp "$build/tb" | grep -E "^(ok|FAIL|PASS|FAILED)"

#!/bin/zsh
# Runs CORE/sim/tb_ne2000.sv (CORE/sv/ne2000_z486.sv: the NE2000 card, ne2000/*.v, with
# ne2k_host.sv as its network side, behind iobus_adapter.sv with its io_hold and io_cpu_be)
# with iverilog (Homebrew). Prints each check and PASS or FAILED. The adapter is the patched
# copy: tools/z486_sources.py writes it into CORE/gen first.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build
mkdir -p "$build"
python3 "$root/tools/z486_sources.py" > /dev/null
files=("$root/CORE/sv/ne2000/ne2000_packet_ram.v" "$root/CORE/sv/ne2000/ne2000_core.v"
       "$root/CORE/sv/ne2000/ne2000_isa.v" "$root/CORE/sv/ne2k_host.sv" "$root/CORE/sv/ne2000_z486.sv"
       "$root/CORE/gen/z486_MiSTer/src/iobus_adapter.sv" "$root/CORE/sim/tb_ne2000.sv")
iverilog -g2012 -o "$build/tb_ne2000" "${files[@]}"
vvp "$build/tb_ne2000" | grep -E "^(ok|FAIL|PASS|FAILED|     )"

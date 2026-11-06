#!/bin/zsh
# Runs CORE/sim/tb_sb_soft.sv (CORE/sv/sb_soft.sv, the Sound Blaster DSP's output stage) with
# iverilog (Homebrew); about 30 s. Prints each check and PASS or FAILED.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build
mkdir -p "$build"
iverilog -g2012 -o "$build/tb_sb_soft" "$root/CORE/sv/sb_soft.sv" "$root/CORE/sim/tb_sb_soft.sv"
vvp "$build/tb_sb_soft" | grep -E "^(ok|FAIL|PASS|FAILED)"

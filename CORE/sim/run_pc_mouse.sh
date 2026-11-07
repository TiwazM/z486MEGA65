#!/bin/zsh
# Runs CORE/sim/tb_pc_mouse_pot.vhd (pc_mouse.vhd: an Amiga mouse's active button lines, the 1351
# detection) with nvc (Homebrew), in CORE/sim/build/nvc_mouse. Prints each check and PASS.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build/nvc_mouse
mkdir -p "$build"
cd "$build"
rm -rf work
nvc --std=2008 -a "$root/CORE/vhdl/pc_mouse.vhd" "$root/CORE/sim/tb_pc_mouse_pot.vhd"
nvc --std=2008 -e tb_pc_mouse_pot -r 2>&1 | grep -E "ok |FAIL|PASS|FAILED" | sed 's/.*Note: [0-9a-z+]*: //'

#!/bin/zsh
# Runs CORE/sim/tb_fdd_sound.vhd (fdd_sound.vhd: the drive sounds, against a model of the
# internal drive) with nvc (Homebrew), in CORE/sim/build/nvc_fdd_sound; GHDL=1 with GHDL
# instead. Prints each check and PASS.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build/nvc_fdd_sound
mkdir -p "$build"
cd "$build"
rm -rf work work-obj08.cf
src=("$root/CORE/vhdl/fdd_sound.vhd" "$root/CORE/sim/tb_fdd_sound.vhd")
if [[ -n "$GHDL" ]]; then
    ghdl -a --std=08 $src
    ghdl -e --std=08 tb_fdd_sound
    ghdl -r --std=08 tb_fdd_sound 2>&1 | grep -E "ok |FAIL|PASS|FAILED" | sed 's/.*(report [a-z]*): //'
else
    nvc --std=2008 -a $src
    nvc --std=2008 -e tb_fdd_sound -r 2>&1 | grep -E "ok |FAIL|PASS|FAILED" | sed 's/.*Note: [0-9a-z+]*: //'
fi

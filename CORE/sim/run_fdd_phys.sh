#!/usr/bin/env bash
# Runs CORE/sim/tb_fdd_phys.vhd (fdd_phys.vhd and fdd_sound.vhd, the internal floppy drive as
# A:, against a model of a drive turning HD and DD disks) with GHDL, in
# CORE/sim/build/ghdl_fdd_phys (NVC=1: nvc instead). Prints each check and PASS; about 25 s
# of simulated time, some minutes. WR=1: the write and FORMAT tests alone (G_WRITES_ONLY).
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
build=$root/CORE/sim/build/ghdl_fdd_phys
mkdir -p "$build"
cd "$build"
rm -rf work *.cf
src=("$root/CORE/vhdl/fdd_sound.vhd" "$root/CORE/vhdl/fdd_mfm_rx.vhd" "$root/CORE/vhdl/fdd_mfm_tx.vhd"
     "$root/CORE/vhdl/fdd_phys.vhd"
     "$root/CORE/sim/tb_fdd_phys.vhd")
if [[ -n "$NVC" ]]; then
    nvc --std=2008 -a "${src[@]}"
    nvc --std=2008 -e tb_fdd_phys ${WR:+-gG_WRITES_ONLY=true} -r 2>&1 | grep -E "ok |FAIL|PASS|FAILED|stat:" | sed 's/.*Note: [0-9a-z+]*: //'
else
    ghdl -a --std=08 "${src[@]}"
    ghdl -e --std=08 tb_fdd_phys
    ghdl -r --std=08 tb_fdd_phys ${WR:+-gG_WRITES_ONLY=true} 2>&1 | grep -E "ok |FAIL|PASS|FAILED|stat:" | sed 's/.*(report [a-z]*): //'
fi

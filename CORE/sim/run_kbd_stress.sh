#!/bin/zsh
# Runs CORE/sim/tb_kbd_stress.vhd (pc_keyboard.vhd: random key presses while the PC reads slowly
# or not at all; afterwards no key held, : and Shift+A right) with nvc (Homebrew), in
# CORE/sim/build/nvc_kbd, for seeds 1..N (default 20). Prints each seed's checks.
#   CORE/sim/run_kbd_stress.sh [N] [steps] [unblock: 1 in this many steps stops/starts the PC]
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build/nvc_kbd
n=${1:-20}
steps=${2:-400}
unblock=${3:-8}
mkdir -p "$build"
cd "$build"
rm -rf work
nvc --std=2008 -a "$root/CORE/vhdl/pc_keyboard.vhd" "$root/CORE/sim/tb_kbd_stress.vhd"
fails=0
for seed in $(seq 1 $n); do
    out=$(nvc --std=2008 -e tb_kbd_stress -gG_SEED=$seed -gG_STEPS=$steps -gG_UNBLOCK=$unblock -r 2>&1 || true)
    echo "$out" | grep -E "ok |FAIL|PASS|FAILED|still sending|holds code" | sed 's/.*\(Note\|Error\|Warning\): [0-9a-z+]*: //'
    echo "$out" | grep -q "PASS:" || fails=$((fails + 1))
done
echo "seeds failed: $fails of $n"

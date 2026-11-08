#!/bin/zsh
# Runs CORE/sim/tb_rtc_master.vhd (M2M/vhdl/i2c/rtc_master.vhd's check of an RTC read, M2M-UPSTREAM
# rtc-verify) with nvc (Homebrew), in CORE/sim/build/nvc_rtc. Prints PASS or the failing check.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build/nvc_rtc
mkdir -p "$build"
cd "$build"
nvc --std=2008 -a "$root/M2M/vhdl/i2c/rtc_master.vhd" "$root/CORE/sim/tb_rtc_master.vhd" \
    -e tb_rtc_master -r 2>&1 | grep -E "after reset|all junk|PASS|FAIL|Failure"

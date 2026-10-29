#!/bin/zsh
# Runs z486_cpu_a7.tcl in the vivado-on-mac container (batch mode, no desktop).
#   ./run_ooc.sh [x87 0|1] [MHz] [part] [resume]   defaults: 1 85 xc7a200tfbg484-2
# "resume" starts from the run's saved synthesis checkpoint.
# OOC_TCL=z486_pc_a7.tcl runs the whole PC instead of the CPU alone.

set -e
ooc_dir=${0:A:h}
work_dir=${ooc_dir:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
# 2022.2 is the M2M toolchain; 2026.1 installs as Xilinx/<ver>/Vivado.
vivado_ver=${VIVADO_VER:-2022.2}
settings=/home/user/Xilinx/$vivado_ver/Vivado/settings64.sh
[[ -f "$vom/Xilinx/$vivado_ver/Vivado/settings64.sh" ]] ||
    settings=/home/user/Xilinx/Vivado/$vivado_ver/settings64.sh

# m65build carries the LD_PRELOAD that keeps Vivado's license library from
# crashing in libudev under emulation; --user (not sudo) keeps that env.
image=${M65_IMAGE:-m65build}
tcl=${OOC_TCL:-z486_cpu_a7.tcl}

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$work_dir",target=/work \
    $image bash -c "
        source $settings &&
        cd /work/ooc &&
        vivado -mode batch -nojournal -log vivado_${tcl:r}_${2:-85}mhz.log \
            -source $tcl -tclargs ${1:-1} ${2:-85} ${3:-xc7a200tfbg484-2} ${4:-}"

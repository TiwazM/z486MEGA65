#!/bin/zsh
# Runs CORE/sim/tb_l2.sv (the L2 cache, CORE/sv/guest_l2.sv, against models of z486's L1, the
# SDRAM and DMA) with Vivado 2022.2's xsim in the vivado-on-mac container. Output in
# CORE/sim/build/.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
mkdir -p "$root/CORE/sim/build"

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build &&
        xvlog -sv /core/CORE/sv/guest_l2.sv /core/CORE/sim/tb_l2.sv &&
        xelab -debug off -timescale 1ns/1ps tb_l2 -s tb_l2_snap &&
        xsim tb_l2_snap -R"

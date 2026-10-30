#!/bin/zsh
# Runs CORE/sim/tb_pc_keyboard.vhd (the MEGA65 keyboard against z486's 8042) with Vivado 2022.2's
# xsim in the vivado-on-mac container. Output in CORE/sim/build/.
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
        xvlog --relax /core/z486_MiSTer/src/common/simple_fifo.v /core/z486_MiSTer/src/soc/ps2.v &&
        xvhdl -2008 /core/CORE/vhdl/ps2_device.vhd /core/CORE/vhdl/pc_keyboard.vhd \
                    /core/CORE/sim/tb_pc_keyboard.vhd &&
        xelab --relax -debug off tb_pc_keyboard -s tb_kbd &&
        xsim tb_kbd -R"

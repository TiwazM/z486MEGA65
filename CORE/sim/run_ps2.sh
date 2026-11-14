#!/bin/zsh
# Runs the PS/2 testbenches with Vivado 2022.2's xsim in the vivado-on-mac container:
#   CORE/sim/tb_pc_keyboard.vhd  the MEGA65 keyboard (pc_keyboard.vhd) against z486's 8042
#   CORE/sim/tb_pc_mouse.vhd     the joystick-port mouse (pc_mouse.vhd) on its mouse port
#                                (z486's 8042 is ps2.v as patched by tools/z486_sources.py)
#   CORE/sim/tb_pic.sv           IRQ1 and IRQ12 high across the BIOS's PIC setup (pic.v, as
#                                patched by tools/z486_sources.py; EXPECT_FAIL=1: upstream's)
#   CORE/sim/tb_i8042_aux.sv     Linux's mouse port probe (i8042_check_aux) against the 8042
# CORE/sim/run_ps2.sh [tb_pc_keyboard|tb_pc_mouse|tb_pic|tb_i8042_aux] runs one; without an
# argument, all four. Output in CORE/sim/build/.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
tbs=${1:-tb_pc_keyboard tb_pc_mouse tb_pic tb_i8042_aux}
mkdir -p "$root/CORE/sim/build"
python3 "$root/tools/z486_sources.py" > /dev/null
pic=/core/CORE/gen/z486_MiSTer/src/soc/pic.v
upstream=
[[ -n "$EXPECT_FAIL" ]] && pic=/core/z486_MiSTer/src/soc/pic.v && upstream="-d UPSTREAM_PIC"

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build &&
        xvlog --relax /core/z486_MiSTer/src/common/simple_fifo.v /core/CORE/gen/z486_MiSTer/src/soc/ps2.v \
              $pic &&
        xvlog --relax -sv $upstream /core/CORE/sim/tb_pic.sv /core/CORE/sim/tb_i8042_aux.sv &&
        xvhdl -2008 /core/CORE/vhdl/ps2_device.vhd /core/CORE/vhdl/pc_keyboard.vhd \
                    /core/CORE/vhdl/pc_mouse.vhd \
                    /core/CORE/sim/tb_pc_keyboard.vhd /core/CORE/sim/tb_pc_mouse.vhd &&
        for tb in $tbs; do
            xelab --relax -debug off \$tb -s \${tb}_snap && xsim \${tb}_snap -R || exit 1
        done"

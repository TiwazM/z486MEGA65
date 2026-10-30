#!/bin/zsh
# Runs CORE/sim/tb_floppy.sv (floppy drive A: from the SD card: floppy.v and rtc.v against
# pc_mgmt.vhd and fdd_sd.vhd) with Vivado 2022.2's xsim in the vivado-on-mac container. Output
# in CORE/sim/build/.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
mkdir -p "$root/CORE/sim/build"

# sdhost.vhd holds the package and the controller: only the package is needed
awk '/^library ieee;/{lib=$0; next} /^package sdhost_pkg is/{print lib; print "use ieee.std_logic_1164.all;"; p=1} p{print} /^end package sdhost_pkg;/{p=0}' \
    "$root/M2M/vhdl/QNICE/sdhost.vhd" > "$root/CORE/sim/build/sdhost_pkg.vhd"

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build &&
        xvlog --relax /core/z486_MiSTer/src/common/simple_fifo.v /core/z486_MiSTer/src/common/simple_ram.v &&
        xvlog --relax -sv /core/z486_MiSTer/src/soc/floppy.v /core/z486_MiSTer/src/soc/rtc.v \
              /core/z486_MiSTer/src/iobus_adapter.sv /core/CORE/sim/tb_floppy.sv &&
        xvhdl -2008 sdhost_pkg.vhd /core/M2M/vhdl/cdc_stable.vhd /core/M2M/vhdl/tdp_ram.vhd \
                    /core/M2M/vhdl/2port2clk_ram.vhd /core/M2M/vhdl/qnice_csr.vhd \
                    /core/CORE/vhdl/pc_mgmt.vhd /core/CORE/vhdl/fdd_sd.vhd &&
        xelab --relax -debug off tb_floppy -s tb_fdd &&
        xsim tb_fdd -R"

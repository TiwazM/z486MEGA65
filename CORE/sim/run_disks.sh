#!/bin/zsh
# Runs the disk testbenches with Vivado 2022.2's xsim in the vivado-on-mac container:
#   CORE/sim/tb_floppy.sv  floppy drives A: and B: (floppy.v, rtc.v) against pc_mgmt.vhd and
#                          disk_sd.vhd
#   CORE/sim/tb_ide.sv     the hard disk (ide.v, rtc.v) against the same
# CORE/sim/run_disks.sh [tb_floppy|tb_ide] runs one; without an argument, both. Output in
# CORE/sim/build/.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
tbs=${1:-tb_floppy tb_ide}
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
        xvlog --relax /core/z486_MiSTer/src/common/simple_fifo.v /core/z486_MiSTer/src/common/simple_ram.v \
              /core/z486_MiSTer/src/common/dpram.v &&
        xvlog --relax -sv /core/z486_MiSTer/src/soc/floppy.v /core/z486_MiSTer/src/soc/rtc.v \
              /core/z486_MiSTer/src/soc/ide.v /core/z486_MiSTer/src/iobus_adapter.sv \
              /core/CORE/sim/tb_floppy.sv /core/CORE/sim/tb_ide.sv &&
        xvhdl -2008 sdhost_pkg.vhd /core/M2M/vhdl/cdc_stable.vhd /core/M2M/vhdl/tdp_ram.vhd \
                    /core/M2M/vhdl/2port2clk_ram.vhd /core/M2M/vhdl/qnice_csr.vhd \
                    /core/CORE/vhdl/pc_mgmt.vhd /core/CORE/vhdl/disk_sd.vhd &&
        for tb in $tbs; do
            xelab --relax -debug off \$tb -s \${tb}_snap && xsim \${tb}_snap -R || exit 1
        done"

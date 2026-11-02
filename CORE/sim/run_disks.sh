#!/bin/zsh
# Runs the disk testbenches with Vivado 2022.2's xsim in the vivado-on-mac container:
#   CORE/sim/tb_floppy.sv  floppy drives A: and B: (floppy.v, rtc.v) against pc_mgmt.vhd and
#                          disk_sd.vhd
#   CORE/sim/tb_ide.sv     the hard disk (ide.v, rtc.v) against the same
#   CORE/sim/tb_cdrom.sv   the CD-ROM drive (ide.v of both channels) against pc_mgmt.vhd with
#                          pc_cdrom.vhd and disk_sd.vhd
# CORE/sim/run_disks.sh [tb_floppy|tb_ide|tb_cdrom] runs one; without an argument, all three.
# E_PER=2 E_CRC=34 run_disks.sh ...: tb_ide's and tb_cdrom's engine model at the real engine's
# pace (a byte every 2 QNICE clocks, the CRC between a block's last byte and its e_blk).
# FAULT=3 run_disks.sh ...: every third answer's first copy out of the ring reads its last
# byte wrong (disk_sd's G_FAULT): pc_mgmt and pc_cdrom must read it again, fresh from the card
# (tb_cdrom needs FAULT=9 or more: a CD block takes four answers, each try must miss one).
# LUTRAM=1 run_disks.sh ...: disk_sd's ring and write buffer in LUT RAM (G_LUTRAM) instead of block RAM.
# disk_sd's ring FIFO is XPM's (xpm_fifo_async): xelab takes -L xpm and glbl.
# Output in CORE/sim/build/.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
tbs=${1:-tb_floppy tb_ide tb_cdrom}
gen=""
[[ -n "$E_PER" ]] && gen="$gen -generic_top E_PER=$E_PER"
[[ -n "$E_CRC" ]] && gen="$gen -generic_top E_CRC=$E_CRC"
fault=""
[[ -n "$FAULT" ]] && fault="-generic_top FAULT=$FAULT"
[[ -n "$LUTRAM" ]] && fault="$fault -generic_top LUTRAM=$LUTRAM"
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
              /core/z486_MiSTer/src/common/dpram.v \$XILINX_VIVADO/data/verilog/src/glbl.v &&
        xvlog --relax -sv /core/z486_MiSTer/src/soc/floppy.v /core/z486_MiSTer/src/soc/rtc.v \
              /core/z486_MiSTer/src/soc/ide.v /core/z486_MiSTer/src/iobus_adapter.sv \
              /core/CORE/sim/tb_floppy.sv /core/CORE/sim/tb_ide.sv /core/CORE/sim/tb_cdrom.sv &&
        xvhdl -2008 sdhost_pkg.vhd /core/M2M/vhdl/cdc_stable.vhd /core/M2M/vhdl/tdp_ram.vhd \
                    /core/M2M/vhdl/2port2clk_ram.vhd /core/M2M/vhdl/qnice_csr.vhd \
                    /core/CORE/vhdl/cd_audio.vhd /core/CORE/vhdl/pc_cdrom.vhd /core/CORE/vhdl/pc_mgmt.vhd /core/CORE/vhdl/disk_sd.vhd &&
        for tb in $tbs; do
            g=\"\"; [ \$tb != tb_floppy ] && g=\"$gen\"
            g=\"\$g $fault\"
            xelab --relax -debug off -L xpm \$tb glbl \$g -s \${tb}_snap && xsim \${tb}_snap -R || exit 1
        done"

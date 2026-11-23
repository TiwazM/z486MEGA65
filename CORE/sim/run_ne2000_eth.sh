#!/bin/zsh
# Runs CORE/sim/tb_ne2000_eth.sv (the NE2000, ne2000_z486.sv + ne2k_host.sv, with the real
# eth_mac.vhd and its RMII pins looped back) in xsim, in the vivado-on-mac container (VHDL and
# SystemVerilog together). Prints each check and PASS or FAILED. The adapter is the patched
# copy: tools/z486_sources.py writes it into CORE/gen first. Also compiles eth_clk.vhd,
# eth_dna.vhd and eth_port.vhd (against unisim) as a syntax check.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
mkdir -p "$root/CORE/sim/build/ne2000_eth"
python3 "$root/tools/z486_sources.py" > /dev/null

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build/ne2000_eth &&
        xvlog --relax -sv /core/CORE/sv/ne2000/ne2000_packet_ram.v /core/CORE/sv/ne2000/ne2000_core.v \
              /core/CORE/sv/ne2000/ne2000_isa.v /core/CORE/sv/ne2k_host.sv /core/CORE/sv/ne2000_z486.sv \
              /core/CORE/gen/z486_MiSTer/src/iobus_adapter.sv /core/CORE/sim/tb_ne2000_eth.sv > xvlog.log &&
        xvhdl -2008 /core/CORE/vhdl/eth_mac.vhd /core/CORE/vhdl/eth_clk.vhd /core/CORE/vhdl/eth_dna.vhd \
              /core/CORE/vhdl/eth_port.vhd > xvhdl.log &&
        xelab --relax -debug off tb_ne2000_eth -s tb_ne2000_eth_snap > xelab.log &&
        xsim tb_ne2000_eth_snap -R" | grep -E "^(ok|FAIL|PASS|FAILED|     |ERROR)"

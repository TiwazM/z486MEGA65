#!/bin/zsh
# Synthesizes the MEGA65 R6 core in the vivado-on-mac container (Vivado 2022.2, batch; the
# bitstream only in "bit" mode): regenerates the project and the Vivado 2022.2 source copies, then
# runs CORE/build_synth.tcl. Reports: CORE/reports/synth/; the run: CORE/CORE-R6.runs/synth_1.
#   tools/build_r6.sh            synthesize
#   tools/build_r6.sh reports    only re-report the last synthesis (after constraint changes)
#   tools/build_r6.sh impl       place and route (CORE/build_impl.tcl; reports in CORE/reports/impl/),
#                                stopping before write_bitstream
#   tools/build_r6.sh finish     only the post-route phys_opt_design and reports of the last impl
#   tools/build_r6.sh impl strong   the same with place ExtraTimingOpt and a post-route
#                                   AggressiveExplore phys_opt pass
#   tools/build_r6.sh bit        the last impl's bitstream (CORE/build_bit.tcl) and its core file,
#                                CORE/bitstream/z486-R6.bit and .cor; the .cor needs coretool from
#                                the MEGA65 tools release (CORETOOL=path)

set -e
root=${0:A:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
vivado_ver=${VIVADO_VER:-2022.2}
image=${M65_IMAGE:-m65build}           # its LD_PRELOAD keeps Vivado's license library alive
coretool=${CORETOOL:-$HOME/Downloads/m65tools-release-1.00-macos/coretool}

[[ "$1" == "reports" || "$1" == "finish" || "$1" == "bit" ]] || python3 "$root/tools/gen_xpr.py"
mkdir -p "$root/CORE/reports"

if [[ "$1" == "bit" ]]; then
    docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
        --mount type=bind,source="$vom",target=/home/user \
        --mount type=bind,source="$root",target=/core \
        $image bash -c "
            source /home/user/Xilinx/Vivado/$vivado_ver/settings64.sh &&
            cd /core &&
            vivado -mode batch -nojournal -log CORE/reports/vivado_bit.log -source CORE/build_bit.tcl"
    # MEGAFLASH shows the name and version: the commit checked out when the .cor is made
    "$coretool" --force -B "$root/CORE/bitstream/z486-R6.cor" --bit "$root/CORE/bitstream/z486-R6.bit" \
        --target mega65r6 --bit-name "z486" \
        --bit-version "WIP-$(git -C "$root" describe --always)"
    exit
fi

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/$vivado_ver/settings64.sh &&
        cd /core &&
        if [ \"${1:-synth}\" = impl ] || [ \"${1:-synth}\" = finish ]; then
            vivado -mode batch -nojournal -log CORE/reports/vivado_impl.log -source CORE/build_impl.tcl \
                -tclargs $*
        else
            vivado -mode batch -nojournal -log CORE/reports/vivado_synth.log \
                -source CORE/build_synth.tcl -tclargs ${1:-synth}
        fi"

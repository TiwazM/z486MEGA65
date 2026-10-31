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
#   tools/build_r6.sh impl [strong] incr   incremental place and route from the routed
#                                   checkpoint in CORE/reports/ref/ (CORE/build_impl.tcl)
#   tools/build_r6.sh bit        the last impl's bitstream (CORE/build_bit.tcl) and its core file,
#                                CORE/bitstream/z486-R6.bit and .cor; the .cor needs coretool from
#                                the MEGA65 tools release (CORETOOL=path)
#   tools/build_r6.sh patch      firmware changes without synthesis (a few minutes): assembles the
#                                current m2m-rom.asm and writes the last impl's bitstream and core
#                                file with it (CORE/patch_firmware.tcl, from MegaMac's): the QNICE
#                                ROM's and the code banks' block RAMs must hold the firmware the
#                                impl was made with (CORE/reports/impl/fw/, kept by impl), or it
#                                stops. Only m2m-rom.asm: the menu (config.vhd) is hardware.

set -e
root=${0:A:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
vivado_ver=${VIVADO_VER:-2022.2}
image=${M65_IMAGE:-m65build}           # its LD_PRELOAD keeps Vivado's license library alive
coretool=${CORETOOL:-$HOME/Downloads/m65tools-release-1.00-macos/coretool}

[[ "$1" == "reports" || "$1" == "finish" || "$1" == "bit" || "$1" == "patch" ]] || \
    python3 "$root/tools/gen_xpr.py"
mkdir -p "$root/CORE/reports"

cor() {
    # MEGAFLASH shows the name and version: the commit checked out when the .cor is made
    "$coretool" --force -B "$root/CORE/bitstream/z486-R6.cor" --bit "$root/CORE/bitstream/z486-R6.bit" \
        --target mega65r6 --bit-name "z486" \
        --bit-version "WIP-$(git -C "$root" describe --always)"
}

if [[ "$1" == "patch" ]]; then
    fw=$root/CORE/reports/impl/fw
    tmp=$root/CORE/reports/patch
    if [[ ! -f $fw/m2m-rom.rom || ! -f $fw/m2m-banks.rom ]]; then
        echo "ERROR: no firmware images of the last impl in $fw (made by impl)"
        exit 1
    fi
    rm -rf "$tmp"
    mkdir -p "$tmp"
    tohex() { python3 -c 'import sys
for l in open(sys.argv[1]):
    l = l.strip()
    if l: print("%04X" % int(l, 2))' "$1" > "$2" }
    docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/tmp \
        --mount type=bind,source="$root",target=/core \
        $image bash -c "cd /core/CORE/m2m-rom && ./make_rom.sh" | tail -2
    tohex "$fw/m2m-rom.rom" "$tmp/rom_ref.hex"
    tohex "$root/CORE/m2m-rom/m2m-rom.rom" "$tmp/rom_new.hex"
    tohex "$fw/m2m-banks.rom" "$tmp/bnk_ref.hex"
    tohex "$root/CORE/m2m-rom/m2m-banks.rom" "$tmp/bnk_new.hex"
    docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
        --mount type=bind,source="$vom",target=/home/user \
        --mount type=bind,source="$root",target=/core \
        $image bash -c "
            source /home/user/Xilinx/Vivado/$vivado_ver/settings64.sh &&
            cd /core &&
            vivado -mode batch -nojournal -log CORE/reports/vivado_patch.log \
                -source CORE/patch_firmware.tcl -tclargs CORE/reports/impl/mega65_r6_routed.dcp \
                CORE/bitstream/z486-R6.bit CORE/reports/patch/rom_ref.hex CORE/reports/patch/rom_new.hex \
                - - CORE/reports/patch/bnk_ref.hex CORE/reports/patch/bnk_new.hex" > /dev/null 2>&1 || true
    grep "^PATCH:\|^ERROR" "$root/CORE/reports/vivado_patch.log" || true
    grep -q "^PATCH: OK" "$root/CORE/reports/vivado_patch.log" || { echo "ERROR: the patch failed"; exit 1; }
    cor
    exit
fi

if [[ "$1" == "bit" ]]; then
    docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
        --mount type=bind,source="$vom",target=/home/user \
        --mount type=bind,source="$root",target=/core \
        $image bash -c "
            source /home/user/Xilinx/Vivado/$vivado_ver/settings64.sh &&
            cd /core &&
            vivado -mode batch -nojournal -log CORE/reports/vivado_bit.log -source CORE/build_bit.tcl"
    cor
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

# After an implementation: the firmware images its netlist was made of (synth_pre.tcl keeps them
# in the run), the reference of a later patch
if [[ "$1" == "impl" ]]; then
    mkdir -p "$root/CORE/reports/impl/fw"
    cp "$root/CORE/CORE-R6.runs/synth_1/m2m-rom.rom" "$root/CORE/CORE-R6.runs/synth_1/m2m-banks.rom" \
        "$root/CORE/reports/impl/fw/"
fi

#!/bin/zsh
# Runs CORE/sim/tb_ascal.vhd (ascal's line fetches, M2M-UPSTREAM late-fetch) with Vivado 2022.2's
# xsim in the vivado-on-mac container: ascal with a fast memory (every fetch fits in its line:
# the reference) and with a slow one (fetches take ~1.3 lines, like 1280x1024 on the HyperRAM),
# then compares the output lines. With CORE/sim/build/ascal_orig.vhd (an ascal without the
# patch, e.g. git show 4096e0e:M2M/vhdl/av_pipeline/ascal.vhd) it runs that one the same way.
# Output in CORE/sim/build/ (ascal_<run>.txt line checksums, ascal_<run>.ppm frame 4).
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
build=$root/CORE/sim/build
mkdir -p "$build"
orig=0
[[ -f "$build/ascal_orig.vhd" ]] && orig=1

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build &&
        chk() { \"\$@\" > ascal_build.log 2>&1 || { grep -E \"ERROR|error\" ascal_build.log; exit 1; }; } &&
        chk xvhdl -2008 -work pat /core/M2M/vhdl/av_pipeline/ascal.vhd /core/CORE/sim/tb_ascal.vhd &&
        chk xelab -debug off pat.tb_ascal -generic_top G_LAT=2  -generic_top G_GAP=1 -generic_top G_RUN=1 -s ascal_s1 &&
        chk xelab -debug off pat.tb_ascal -generic_top G_LAT=16 -generic_top G_GAP=8 -generic_top G_RUN=2 -s ascal_s2 &&
        if [ $orig = 1 ]; then
            chk xvhdl -2008 -work orig ascal_orig.vhd /core/CORE/sim/tb_ascal.vhd &&
            chk xelab -debug off orig.tb_ascal -generic_top G_LAT=2  -generic_top G_GAP=1 -generic_top G_RUN=3 -s ascal_s3 &&
            chk xelab -debug off orig.tb_ascal -generic_top G_LAT=16 -generic_top G_GAP=8 -generic_top G_RUN=4 -s ascal_s4
        fi &&
        for r in 1 2 3 4; do
            [ -d xsim.dir/ascal_s\$r ] && xsim ascal_s\$r -R -log xsim_ascal_\$r.log > /dev/null &
        done; wait"

cd "$build"
cmp_runs() {   # reference, run, name
    local n=$(paste -d' ' ascal_$1.txt ascal_$2.txt | awk '$3 != $6' | wc -l | tr -d ' ')
    local t=$(wc -l < ascal_$2.txt | tr -d ' ')
    print "$3: $n of $t lines differ from run $1"
}
cmp_runs 1 2 "patched, slow memory"
if (( orig )); then
    cmp_runs 1 3 "original, fast memory"
    cmp_runs 1 4 "original, slow memory"
fi

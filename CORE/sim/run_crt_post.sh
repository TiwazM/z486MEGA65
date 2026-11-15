#!/bin/zsh
# Runs CORE/sim/tb_crt_post.vhd (M2M/vhdl/av_pipeline/crt_post.vhd, M2M-UPSTREAM crt-post) with
# nvc: a 320x200 picture as the VGA sends it (640x400) scaled to 960x720 like ascal (the 720p
# mode's 1.8x), through the CRT stage. Every part off must pass the picture through unchanged;
# then medium scanlines alone and everything with each mask, as pictures (crt_post_png.py:
# NAME_out.png, and NAME_zoom.png at 4x) in CORE/sim/build/crt_post/.
set -e
root=${0:A:h:h:h}
build=$root/CORE/sim/build/crt_post
mkdir -p "$build"
cd "$build"
nvc --std=2008 -a "$root/M2M/vhdl/av_pipeline/crt_post.vhd" "$root/CORE/sim/tb_crt_post.vhd"
run() {   # name, scanlines, mask, glow, gamma
    nvc --std=2008 -e tb_crt_post -gG_SL=$2 -gG_MASK=$3 -gG_GLOW=$4 -gG_GAMMA=$5 -gG_NAME=$1 \
        -r --ieee-warnings=off > /dev/null 2>&1
}
run off 0 0 0 0
python3 -I "$root/CORE/sim/crt_post_png.py" off 960 720 --cmp | head -1
for cfg in "sl_medium 2 0 0 0" "grille 2 1 1 1" "slot 2 2 1 1" "c1084 2 3 1 1"; do
    run ${=cfg}
    python3 -I "$root/CORE/sim/crt_post_png.py" ${${=cfg}[1]} 960 720 > /dev/null
done
print "pictures in $build"

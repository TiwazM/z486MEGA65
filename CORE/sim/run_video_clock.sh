#!/bin/zsh
# Runs CORE/sim/tb_video_clock.vhd (every HDMI clock select of video_out_clock.vhd, programmed
# over the DRP into Vivado 2022.2's unisim MMCME2_ADV, its pixel and x5 clocks measured) with
# xsim in the vivado-on-mac container. Output: CORE/sim/build/xsim_video_clock.log.
set -e
root=${0:A:h:h:h}
vom=${VIVADO_ON_MAC:-$HOME/Documents/vivado-on-mac}
image=${M65_IMAGE:-m65build}
build=$root/CORE/sim/build
mkdir -p "$build"

docker run --init --rm --platform linux/amd64 --user 1000:1000 -e HOME=/home/user \
    --mount type=bind,source="$vom",target=/home/user \
    --mount type=bind,source="$root",target=/core \
    $image bash -c "
        source /home/user/Xilinx/Vivado/2022.2/settings64.sh &&
        cd /core/CORE/sim/build &&
        chk() { \"\$@\" > video_clock_build.log 2>&1 || { grep -E \"ERROR|error\" video_clock_build.log; exit 1; }; } &&
        chk xvhdl -2008 -work vclk /core/M2M/vhdl/cdc_stable.vhd \
            /core/M2M/vhdl/controllers/HDMI/video_out_clock.vhd /core/CORE/sim/tb_video_clock.vhd &&
        chk xelab -debug off vclk.tb_video_clock -s video_clock &&
        xsim video_clock -R -log xsim_video_clock.log > /dev/null"

grep -E "^Note: (sel|done)|Error:" "$build/xsim_video_clock.log" | sed 's/^Note: //'

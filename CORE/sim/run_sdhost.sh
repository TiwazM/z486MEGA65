#!/bin/zsh
# Runs tb_sdhost.vhd (the SD host controller, M2M/vhdl/QNICE/sdhost.vhd, against
# sd_card_model.vhd) with nvc, natively (no container): one case per line below, each a
# card behaviour and the mode the init must end in. CORE/sim/run_sdhost.sh [case ...] runs
# those only. Output in CORE/sim/build/sdhost/.
set -e
root=${0:A:h:h:h}
out=$root/CORE/sim/build/sdhost
mkdir -p $out
cd $out
nvc --std=2008 -a $root/M2M/vhdl/QNICE/sdhost.vhd $root/CORE/sim/sd_card_model.vhd $root/CORE/sim/tb_sdhost.vhd
typeset -A cases
cases=(
  native         "-gG_EXPECT_NATIVE=true"
  native_r1b_late "-gG_BUSY_LATE=24 -gG_R1B_LEN=4000 -gG_EXPECT_NATIVE=true"
  native_busy_long "-gG_BUSY_LEN=200000 -gG_EXPECT_NATIVE=true"
  stuck_read     "-gG_STUCK_READ=true -gG_EXPECT_NATIVE=true"
  spi            "-gG_SPI_LOCKED=true -gG_EXPECT_NATIVE=false"
  spi_busy_late  "-gG_SPI_LOCKED=true -gG_BUSY_LATE=2 -gG_EXPECT_NATIVE=false"
  spi_dresp_late "-gG_SPI_LOCKED=true -gG_DRESP_LATE=3 -gG_EXPECT_NATIVE=false"
  spi_preempt    "-gG_SPI_LOCKED=true -gG_PREEMPT_FIRST=true -gG_EXPECT_NATIVE=false"
)
names=(native native_r1b_late native_busy_long stuck_read spi spi_busy_late spi_dresp_late spi_preempt)
(( $# )) && names=($@)
fails=0
for n in $names; do
  nvc --std=2008 -e tb_sdhost -gG_NAME=$n ${=cases[$n]} > /dev/null
  if nvc --std=2008 -r tb_sdhost --stop-time=2000ms > $n.log 2>&1 && grep -q "^\*\* Note.*PASS: all checks" $n.log; then
    echo "PASS  $n"
  else
    echo "FAIL  $n: $(grep -E 'FAIL |sd card:' $n.log | head -3 | sed -E 's/^\*\* [A-Za-z]+: [0-9]+ns\+[0-9]+: //' | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
done
exit $fails

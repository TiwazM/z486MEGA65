# Writes the MEGA65 R6 bitstream from the last implementation (CORE/build_impl.tcl's routed
# checkpoint, CORE/reports/impl/mega65_r6_routed.dcp) to CORE/bitstream/z486-R6.bit.
# tools/build_r6.sh bit runs this, then makes the .cor with coretool.
#
#   vivado -mode batch -source CORE/build_bit.tcl   (from the repository root)

set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root CORE bitstream]
file mkdir $out

# WebTalk's host-info lookup crashes in libudev under Docker emulation
catch {config_webtalk -user off}

open_checkpoint [file join $root CORE reports impl mega65_r6_routed.dcp]

# The flash settings (SPI x4, 66 MHz, compressed) come from M2M/common.xdc with the checkpoint
foreach p {CONFIG_MODE BITSTREAM.CONFIG.SPI_BUSWIDTH BITSTREAM.CONFIG.CONFIGRATE \
           BITSTREAM.CONFIG.SPI_32BIT_ADDR BITSTREAM.GENERAL.COMPRESS} {
    puts "$p = [get_property $p [current_design]]"
}
if {[get_property CONFIG_MODE [current_design]] ne "SPIx4"} {
    error "the checkpoint lacks M2M/common.xdc's configuration settings"
}

write_bitstream -force [file join $out z486-R6.bit]
close_design

# z486 PC (z486_MiSTer's system.sv: CPU, chipset, VGA/ET4000, OPL3/SB, IDE,
# floppy) out of context on the MEGA65's Artix-7. Same flow as
# z486_cpu_a7.tcl; stops at the routed checkpoint: no bitstream.
#
#   vivado -mode batch -source z486_pc_a7.tcl -tclargs <x87 0|1> <MHz> [part] [resume]
#
# Parameters follow z486_mister.sv (8 KB + 8 KB caches, line wrap, no CMS, no
# Voodoo) except ENABLE_SHARED_MAILBOX, which needs MiSTer's HPS. The SDRAM
# controller lives outside system.sv and is not part of this run.

set script_dir [file dirname [file normalize [info script]]]
set cpu_dir [file normalize [file join $script_dir .. z486]]
set pc_dir [file normalize [file join $script_dir .. z486_MiSTer]]
set enable_x87 [expr {[llength $argv] > 0 && [lindex $argv 0] eq "1"}]
set cpu_mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 66}]
set part [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xc7a200tfbg484-2"}]
set resume [expr {[llength $argv] > 3 && [lindex $argv 3] eq "resume"}]

if {![string is integer -strict $cpu_mhz] || $cpu_mhz < 1 || $cpu_mhz > 127} {
    error "CPU frequency must be an integer from 1 through 127 MHz"
}

set_param general.maxThreads 8
# WebTalk's host-info lookup crashes in libudev under Docker emulation
# (realloc(): invalid pointer right after route_design).
catch {config_webtalk -user off}

set suffix [expr {$enable_x87 ? "-x87" : ""}]
set build_dir [file join $script_dir "build-pc-${part}-${cpu_mhz}mhz${suffix}"]
set period_ns [expr {1000.0 / double($cpu_mhz)}]
set synth_dcp [file join $build_dir z486_pc_synth.dcp]

# Vivado 2022.2 rejects ports without an explicit net type under
# `default_nettype none (Synth 8-6735). Read a copy with `default_nettype wire:
# it only drops the lint check.
proc read_patched {src patched_dir} {
    set fh [open $src r]
    set text [read $fh]
    close $fh
    if {[regsub -all {`default_nettype\s+none} $text {`default_nettype wire} text]} {
        set src [file join $patched_dir [file tail $src]]
        set fh [open $src w]
        puts -nonewline $fh $text
        close $fh
    }
    read_verilog -sv $src
}

proc read_manifest {manifest base patched_dir skip} {
    set fh [open $manifest r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match $skip $line]} {
            continue
        }
        read_patched [file join $base $line] $patched_dir
    }
    close $fh
}

if {$resume} {
    cd $build_dir
    open_checkpoint $synth_dcp
} else {
    file mkdir $build_dir
    foreach image [list \
            [file join $cpu_dir ucode.hex] \
            [file join $cpu_dir pla_entry_rom.hex] \
            [file join $cpu_dir pla_group_entry.hex] \
            [file join $cpu_dir x87 x87_ucode.mem]] {
        file copy -force $image [file join $build_dir [file tail $image]]
    }

    set patched_dir [file join $build_dir patched]
    file mkdir $patched_dir
    read_manifest [file join $cpu_dir boards common rtl_sources.f] $cpu_dir \
        $patched_dir "boards/common/*"
    read_manifest [file join $script_dir pc_sources.f] $pc_dir $patched_dir ""

    set constraints_file [file join $build_dir pc_ooc.xdc]
    set constraints [open $constraints_file w]
    puts $constraints [format {create_clock -name cpu_clk -period %.6f [get_ports clk_sys]} \
        $period_ns]
    puts $constraints {create_clock -name clk_audio -period 40.690 [get_ports clk_audio]}
    puts $constraints {set_clock_groups -asynchronous -group cpu_clk -group clk_audio}
    puts $constraints {set_false_path -from [get_ports {reset hps_apply_reset}]}
    puts $constraints {set_input_delay -clock cpu_clk 0.0 [get_ports -filter {DIRECTION == IN && NAME != clk_sys && NAME != clk_audio && NAME != reset && NAME != hps_apply_reset}]}
    puts $constraints {set_output_delay -clock cpu_clk 0.0 [get_ports -filter {DIRECTION == OUT}]}
    close $constraints
    read_xdc $constraints_file

    cd $build_dir
    synth_design -top system -part $part -mode out_of_context \
        -include_dirs [list $cpu_dir [file join $cpu_dir x87] [file join $pc_dir src]] \
        -verilog_define Z486_XILINX=1 \
        -generic "SYS_FREQ=[expr {$cpu_mhz * 1000000}]" \
        -generic DCACHE_SET_BITS=7 -generic DCACHE_LINE_WRAP=1'b1 \
        -generic ICACHE_SET_BITS=7 -generic "ENABLE_X87=$enable_x87" \
        -generic ENABLE_CMS=1'b0 -generic ENABLE_SHARED_MAILBOX=1'b0 \
        -generic ENABLE_VOODOO=1'b0
    write_checkpoint -force $synth_dcp
    report_utilization -file [file join $build_dir utilization_synth.rpt]
    report_timing_summary -file [file join $build_dir timing_synth.rpt]
}

# z486_mister.sdc: reset and boot hand-over registers are asynchronous by design.
foreach pattern {*cpu_reset_n* *reset_sync_r* *boot_done*} {
    set regs [get_cells -quiet -hier -filter "IS_SEQUENTIAL && NAME =~ $pattern"]
    if {[llength $regs]} {
        set_false_path -from $regs
    }
}

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
phys_opt_design -directive Explore
write_checkpoint -force [file join $build_dir z486_pc_routed.dcp]

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $build_dir timing_summary.rpt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 20 -path_type full_clock_expanded \
    -file [file join $build_dir timing_internal.rpt]
report_clock_interaction -file [file join $build_dir clock_interaction.rpt]
report_utilization -file [file join $build_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
    -file [file join $build_dir utilization_hier.rpt]
report_drc -file [file join $build_dir drc.rpt]

# Hold failures that start at an input port only exist out of context: the
# ports have no clock tree delay while the registers they feed do.
set port_hold 0
set internal_hold 0
set fh [open [file join $build_dir hold_failures.txt] w]
foreach p [get_timing_paths -hold -max_paths 1000 -nworst 1 -slack_lesser_than 0] {
    set start [get_property STARTPOINT_PIN $p]
    if {[llength [get_ports -quiet $start]]} { incr port_hold } else { incr internal_hold }
    puts $fh "[format %.3f [get_property SLACK $p]] $start -> [get_property ENDPOINT_PIN $p]"
}
close $fh

set summary [open [file join $build_dir summary.txt] w]
puts $summary [format "z486 PC, part %s, target %d MHz, x87 %d" $part $cpu_mhz $enable_x87]
foreach clk {cpu_clk clk_audio} {
    set p [get_timing_paths -quiet -delay_type max -group $clk]
    if {[llength $p]} {
        set wns [get_property SLACK $p]
        set period [get_property PERIOD [get_clocks $clk]]
        puts $summary [format "%-9s WNS %.3f ns -> estimated Fmax %.1f MHz" \
            $clk $wns [expr {1000.0 / ($period - $wns)}]]
    }
}
puts $summary "hold failures: $internal_hold internal, $port_hold from input ports (out-of-context only)"
close $summary

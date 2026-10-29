# z486 CPU alone, out of context, on the MEGA65's Artix-7.
#
# Adapted from z486/boards/kv260/scripts/build_cpu.tcl: same source manifest,
# same Z486_XILINX define and port constraints; only the part, the build
# directory and the summary reports differ. Stops at the routed checkpoint:
# no bitstream.
#
#   vivado -mode batch -source z486_cpu_a7.tcl -tclargs <x87 0|1> <MHz> [part] [resume]
#
# "resume" skips synthesis and opens the run's z486_cpu_synth.dcp.

set script_dir [file dirname [file normalize [info script]]]
set cpu_dir [file normalize [file join $script_dir .. z486]]
set enable_x87 [expr {[llength $argv] > 0 && [lindex $argv 0] eq "1"}]
set cpu_mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 85}]
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
set build_dir [file join $script_dir "build-${part}-${cpu_mhz}mhz${suffix}"]
set period_ns [expr {1000.0 / double($cpu_mhz)}]
set synth_dcp [file join $build_dir z486_cpu_synth.dcp]

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

    # Vivado 2022.2 (the M2M toolchain) rejects ports without an explicit net
    # type under `default_nettype none (Synth 8-6735); newer releases accept
    # them. Read a copy with `default_nettype wire: it only drops the lint check.
    set patched_dir [file join $build_dir patched]
    file mkdir $patched_dir

    set manifest [file join $cpu_dir boards common rtl_sources.f]
    set manifest_file [open $manifest r]
    while {[gets $manifest_file line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line]} {
            continue
        }
        if {[string match "boards/common/*" $line]} {
            continue
        }
        set src [file join $cpu_dir $line]
        set fh [open $src r]
        set text [read $fh]
        close $fh
        if {[regsub -all {`default_nettype\s+none} $text {`default_nettype wire} text]} {
            set src [file join $patched_dir [file tail $line]]
            set fh [open $src w]
            puts -nonewline $fh $text
            close $fh
        }
        read_verilog -sv $src
    }
    close $manifest_file

    set constraints_file [file join $build_dir cpu_ooc.xdc]
    set constraints [open $constraints_file w]
    puts $constraints [format {create_clock -name cpu_clk -period %.6f [get_ports clk]} \
        $period_ns]
    puts $constraints {set_false_path -from [get_ports reset_n]}
    puts $constraints {set_input_delay -clock cpu_clk 0.0 [get_ports {din[*] ready resp_valid intr nmi snoop_addr[*] snoop_valid a20_enable cpu_speed_sel[*] single_step}]}
    puts $constraints {set_output_delay -clock cpu_clk 0.0 [get_ports {addr[*] be[*] burstcount[*] dout[*] valid write io inta dbg_CS[*] dbg_EIP[*] dbg_CS_base[*] dbg_pe dbg_vm dbg_x87_state[*] triple_fault_reset}]}
    close $constraints
    read_xdc $constraints_file

    cd $build_dir
    synth_design -top z486 -part $part -mode out_of_context \
        -include_dirs [list $cpu_dir [file join $cpu_dir x87]] \
        -verilog_define Z486_XILINX=1 -generic "ENABLE_X87=$enable_x87" \
        -generic "CLOCK_RATE_MHZ=$cpu_mhz"
    write_checkpoint -force $synth_dcp
    report_utilization -file [file join $build_dir utilization_synth.rpt]
    report_timing_summary -file [file join $build_dir timing_synth.rpt]
}

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
phys_opt_design -directive Explore
write_checkpoint -force [file join $build_dir z486_cpu_routed.dcp]

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $build_dir timing_summary.rpt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 20 -path_type full_clock_expanded \
    -file [file join $build_dir timing_internal.rpt]
report_utilization -file [file join $build_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 2 \
    -file [file join $build_dir utilization_hier.rpt]
report_drc -file [file join $build_dir drc.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / ($period_ns - $wns)}]
set summary [open [file join $build_dir summary.txt] w]
puts $summary [format "part %s, target %d MHz, x87 %d" $part $cpu_mhz $enable_x87]
puts $summary [format "WNS %.3f ns -> estimated Fmax %.1f MHz" $wns $fmax]
close $summary

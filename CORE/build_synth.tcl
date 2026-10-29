# Synthesis of the whole core for the MEGA65 R6 (CORE-R6.xpr, synth_1). No implementation and
# no bitstream. Reports go to CORE/reports/synth/.
#
#   vivado -mode batch -source CORE/build_synth.tcl [-tclargs reports]   (from the repository root)
#
# "reports" skips synthesis and only re-reports the last synth_1 run: opening the run applies
# the constraint files as they are now, so constraint changes show without a new synthesis.

set root [file normalize [file join [file dirname [info script]] ..]]
set reports [file join $root CORE reports synth]
file mkdir $reports

# WebTalk's host-info lookup crashes in libudev under Docker emulation
catch {config_webtalk -user off}

open_project [file join $root CORE CORE-R6.xpr]
puts "include dirs: [get_property include_dirs [get_filesets sources_1]]"
puts "defines:      [get_property verilog_define [get_filesets sources_1]]"
puts "top:          [get_property top [get_filesets sources_1]]"

if {!([llength $argv] > 0 && [lindex $argv 0] eq "reports")} {
    set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}

set status [get_property STATUS [get_runs synth_1]]
puts "synth_1: $status"
if {![string match "*Complete*" $status]} {
    error "synthesis failed: see CORE/CORE-R6.runs/synth_1/runme.log"
}

open_run synth_1
report_utilization -file [file join $reports utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $reports utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $reports timing_summary.rpt]
report_clock_interaction -file [file join $reports clock_interaction.rpt]
report_methodology -file [file join $reports methodology.rpt]
close_project

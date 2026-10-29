# Implementation of the whole core for the MEGA65 R6 (CORE-R6.xpr, impl_1), up to the last step
# before write_bitstream: no bitstream. Synthesizes first if synth_1 is not current (e.g. after a
# constraint change). Reports go to CORE/reports/impl/.
#
#   vivado -mode batch -source CORE/build_impl.tcl [-tclargs finish]   (from the repository root)
#
# "finish" skips synthesis and place-and-route and continues from impl_1's routed design: the
# post-route phys_opt_design and the reports.

set root [file normalize [file join [file dirname [info script]] ..]]
set reports [file join $root CORE reports impl]
file mkdir $reports

# WebTalk's host-info lookup crashes in libudev under Docker emulation (the runs themselves rely
# on the m65build image's LD_PRELOAD)
catch {config_webtalk -user off}

open_project [file join $root CORE CORE-R6.xpr]
set finish [expr {[llength $argv] > 0 && [lindex $argv 0] eq "finish"}]

set synth [get_runs synth_1]
if {!$finish && ([get_property NEEDS_REFRESH $synth] || ![string match "*Complete*" [get_property STATUS $synth]])} {
    set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt $synth
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {![string match "*Complete*" [get_property STATUS $synth]]} {
        error "synthesis failed: see CORE/CORE-R6.runs/synth_1/runme.log"
    }
}

# The strategy (Performance_ExplorePostRoutePhysOpt) ends with a phys_opt_design after routing,
# which launch_runs -to_step cannot name in 2022.2: run to route_design, then do that step here
set impl [get_runs impl_1]
if {!$finish} {
    reset_run impl_1
    launch_runs impl_1 -to_step route_design -jobs 8
    wait_on_run impl_1
}

# Stopped at route_design, the run's status is "Not started phys_opt_design (Post-Route)":
# the routed checkpoint is the sign of success
puts "impl_1: [get_property STATUS $impl]"
set routed [file join [get_property DIRECTORY $impl] mega65_r6_routed.dcp]
if {![file exists $routed]} {
    error "implementation failed: see CORE/CORE-R6.runs/impl_1/runme.log"
}
set post_route_phys_opt [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $impl]

# open_run refuses a run another session launched: open the routed checkpoint instead
close_project
open_checkpoint $routed

# CORE.xdc's cut of ascal's reset (a checkpoint keeps the constraints of its run, and this one
# came after the first routed run; setting it twice does no harm)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ i_framework/i_av_pipeline/i_digital_pipeline/i_ascal/*_reset_na_reg/CLR}]

if {$post_route_phys_opt} {
    phys_opt_design -directive Explore
}
write_checkpoint -force [file join $reports mega65_r6_routed.dcp]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $reports timing_summary.rpt]
report_timing -delay_type max -max_paths 50 -nworst 1 -sort_by group \
    -file [file join $reports timing_worst.rpt]
report_clock_interaction -file [file join $reports clock_interaction.rpt]
report_utilization -file [file join $reports utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $reports utilization_hier.rpt]
report_route_status -file [file join $reports route_status.rpt]
report_drc -file [file join $reports drc.rpt]
report_methodology -file [file join $reports methodology.rpt]

# One line per clock: WNS, its estimated Fmax, failing setup endpoints; hold
set summary [open [file join $reports summary.txt] w]
foreach clk [lsort [get_clocks]] {
    set p [get_timing_paths -quiet -delay_type max -group $clk]
    if {![llength $p]} { continue }
    set wns [get_property SLACK $p]
    if {$wns eq ""} { continue }
    set period [get_property PERIOD $clk]
    set fail [llength [get_timing_paths -quiet -delay_type max -group $clk -max_paths 100000 -slack_lesser_than 0]]
    puts $summary [format "%-16s period %7.3f ns  WNS %7.3f ns  est. Fmax %7.2f MHz  failing endpoints %d" \
        $clk $period $wns [expr {1000.0 / ($period - $wns)}] $fail]
}
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts $summary [format "worst hold slack %.3f ns" $whs]
close $summary
close_design

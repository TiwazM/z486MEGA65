## z486 for MEGA65
##
## Implementation-only constraints (gen_xpr.py adds this file to constrs_1 for implementation, not
## synthesis; it comes after CORE.xdc, which creates main_clk)

## Over-constraint of the PC's clock. Vivado stops optimizing a clock once its paths meet
## timing, so a 64 MHz build ends a few ps above zero (+0.016 ns) and the next build's variation
## can push it below. 0.3 ns of extra setup uncertainty makes place, route and phys_opt aim for
## 15.325 ns (65.25 MHz) instead of 15.625 ns. build_impl.tcl takes it out again before the final
## checkpoint and the reports: pass or fail stays at the real 64 MHz, where what the uncertainty
## gained shows as positive slack. Hold is not affected (-setup only).
set_clock_uncertainty -setup 0.300 [get_clocks main_clk]

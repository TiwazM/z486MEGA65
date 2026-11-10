## z486 for MEGA65
##
## Implementation-only constraints (gen_xpr.py adds this file to constrs_1 for implementation, not
## synthesis; it comes after CORE.xdc, which creates main_clk)

## Over-constraint of the PC's clock. Vivado stops optimizing a clock once its paths meet
## timing, so a 64 MHz build ends a few ps above zero (+0.016 ns) and the next build's variation
## can push it below. Extra setup uncertainty makes place, route and phys_opt aim higher:
## 0.6 ns, 15.025 ns (66.6 MHz) instead of 15.625 ns (0.3 ns until the carry-chain ALU, the x87
## product's registered low limb and the dcache's frame-address tag compare, 2026-11-10).
## build_impl.tcl takes it out again before the final checkpoint and the reports: pass or fail
## stays at the real 64 MHz, where what the uncertainty gained shows as positive slack. Hold is
## not affected (-setup only).
set_clock_uncertainty -setup 0.600 [get_clocks main_clk]

## No block RAM on RAMB36_X5Y37 (nor its halves, RAMB18_X5Y74/75). With part of disk_sd's ring
## there, PIOTEST (R6) found by far the most wrong bytes: about 78 per GB with the ring's write
## port on the QNICE clock, about 1550 per GB on main_clk, against 1 to 5 with the ring
## elsewhere. The wrong bytes were not only those of the block RAM on the site, so the site
## alone does not explain them; it stays empty while that is open.
set_property PROHIBIT true [get_sites {RAMB36_X5Y37 RAMB18_X5Y74 RAMB18_X5Y75}]

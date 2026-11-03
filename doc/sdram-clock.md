# SDRAM clock

Part of [z486MEGA65](../README.md).

`sdram.v` (z486_MiSTer) reads its data three clocks after each READ command.
MiSTer runs it at 85 MHz with the SDRAM clock at 180 degrees; at 64 MHz on the
R6 that phase puts the read outside the data window, and the first bitstream
ran garbage from F000:FFF0 on (black screen). With the phase swept at run
time (the MMCM's dynamic phase shift, in 13.95 ps steps), the PC boots for
every phase from 180 degrees + 130 steps to + 570 steps (1.81 to 7.95 ns
later), and fails at +120 and +580. The core uses the middle, +350 steps =
4.88 ns = 292.5 degrees, 3.07 ns from either edge. That window is one board's;
another R6 can be measured the same way.

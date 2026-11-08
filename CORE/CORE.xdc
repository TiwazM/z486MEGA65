## z486 for MEGA65
##
## Core specific constraints (M2M/common.xdc and M2M/MEGA65-R6.xdc hold the framework's)
##
## Based on the M2M template, Megamiga's and pc10-iii's CORE/CORE.xdc; licensed under GPL v3

## The PC's clock, 64 MHz, also M2M's video clock (CORE/vhdl/clk.vhd), and the audio clock
## (24.556 MHz) for OPL3 and the Sound Blaster
create_generated_clock -name main_clk  [get_pins CORE/clk_gen/i_clk_main/CLKOUT1]
create_generated_clock -name pc_audio_clk [get_pins CORE/clk_gen/i_clk_main/CLKOUT0]

## The SDRAM clock: main_clk's frequency at 292.5 degrees plus a fine phase set at run time
## (clk.vhd). It only clocks the ODDR that forwards it to the pin.
create_generated_clock -name sdram_clk [get_pins CORE/clk_gen/i_clk_main/CLKOUT2]

## ascal asynchronous FIFO data crossings (Megamiga CORE.xdc, framework paths): i_dpram is
## written on i_clk (= main_clk) and read on avl_clk (= hr_clk), o_dpram is written on avl_clk
## and read on o_clk (= hdmi_clk). Bound them to one destination period instead of the
## impossible edge-alignment requirement (and its hold-fix detours).
set_max_delay -datapath_only 10.000 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/i_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/avl_dr_reg\[[0-9]+\]}]
set_max_delay -datapath_only 13.400 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/o_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/o_dr_reg\[[0-9]+\]}]

## ascal's reset: common.xdc false-paths it "-through .../i_ascal/reset_na", a pin that synthesis
## optimizes away (CRITICAL WARNING 12-4739). reset_na combines the video reset (main_clk here)
## and the HyperRAM reset and clears ascal's per-domain reset registers asynchronously; without
## the cut their recovery checks fail by up to 6.6 ns. The same cut, by pin names that survive
## synthesis: the CLR pins of i_reset_na_reg (i_clk), o_reset_na_reg (o_clk) and their siblings.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ i_framework/i_av_pipeline/i_digital_pipeline/i_ascal/*_reset_na_reg/CLR}]

## qnice_clk (50 MHz) <-> main_clk: all crossings are synchronizers, cdc_stable or the
## framework's own CDCs; bound them to one qnice period (max_delay, not false_path, so the
## tighter cdc_stable bounds of common.xdc stay in force).
set_max_delay -datapath_only 20.000 -from [get_clocks qnice_clk] -to [get_clocks main_clk]
set_max_delay -datapath_only 20.000 -from [get_clocks main_clk] -to [get_clocks qnice_clk]

## main_clk <-> pc_audio_clk (common.xdc's audio_clk is the framework's HDMI audio clock): one
## MMCM, but no useful common period (64 / 24.556 MHz). The PC crosses with its own
## synchronizers and FIFOs (sound.v, opl3), mega65.vhd with cdc_stable; bound them to one
## main_clk period.
set_max_delay -datapath_only 15.000 -from [get_clocks main_clk]  -to [get_clocks pc_audio_clk]
set_max_delay -datapath_only 15.000 -from [get_clocks pc_audio_clk] -to [get_clocks main_clk]

## M2M-UPSTREAM rtg-framebuffer (Megamiga's rule for its RTG registers): z486's SVGA framebuffer
## descriptor (z486_mega65.sv, main clock) drives ascal's framebuffer-mode inputs, which ascal
## samples in its Avalon (hr_clk) and output (hdmi_clk) domains. The descriptor only changes on
## a mode switch; a torn value lasts one frame at most (MiSTer's sys_top.sdc false-paths FB_*
## too). The palette writes stay timed: ascal's palette RAM is written on fb_pal_clk = main_clk.
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_z486/fb_*}] -to [get_clocks {hr_clk hdmi_clk}]

## M2M-UPSTREAM scaler-16bpp, the same kind of setting: z486's scaler_16bpp (z486_mega65.sv, main
## clock) picks ascal's 16bpp format for pictures wider than 720 pixels (Super VGA 16 colours), an
## <ASYNC> input that ascal samples in its input (i_clk = main_clk, stays timed) and output
## (hdmi_clk) domains. It only changes on a mode switch; a torn value lasts one frame at most.
## Timed as synchronous it needs 0.35 ns (64 vs 90 MHz edges) and failed by 2.3 ns.
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_z486/scaler_16bpp*}] -to [get_clocks hdmi_clk]

## z486_mister.sdc: the reset and boot hand-over registers are asynchronous by design
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_z486/*cpu_reset_n*}]
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ CORE/i_z486/*boot_done*}]

## Floorplan: the CPU in the middle of the chip, clock regions X0Y1..X1Y2 (rows 50..149), next
## to the SDRAM controller (bank 34, X1Y2). Unconstrained, it spread over six clock regions across
## the full width (slice columns 6..163, rows 13..131) and its critical paths were 76-82 %
## routing. Columns 0..5 stay out: pblock_vga (MEGA65-R6.xdc) holds them in rows 75..99. About
## 15.6K slices for the CPU's 42K LUTs (67 %), 180 RAMB36 for its 21 + 10/2, 360 DSPs for 25.
create_pblock pblock_z486_cpu
add_cells_to_pblock pblock_z486_cpu [get_cells CORE/i_z486/core/z486_cpu]
resize_pblock pblock_z486_cpu -add {SLICE_X6Y50:SLICE_X163Y149 RAMB18_X0Y20:RAMB18_X8Y59 RAMB36_X0Y10:RAMB36_X8Y29 DSP48_X0Y20:DSP48_X8Y59}

## SDRAM (R6: IS42S16320F) pin registers in the IOBs (Megamiga's rule). The I/O timing itself
## (the SDRAM clock's phase against the board's traces) is not constrained: the phase is set on
## the board (clk.vhd). Not sdram_cs_n_o: sdram.v only selects between two chips of a 128 MB
## module, so with one 64 MB chip it is a constant 0 without a flip-flop (Place 30-722).
set_property IOB TRUE [get_ports {sdram_a_o[*] sdram_ba_o[*] sdram_ras_n_o sdram_cas_n_o sdram_we_n_o sdram_dqml_o sdram_dqmh_o sdram_dq_io[*]}]

## M2M-UPSTREAM sd-host: the native 4-bit SD bus needs pull-ups on CMD and DAT0..DAT3 of both
## slots. Port names are the SPI ones of the board XDCs: mosi = CMD, miso = DAT0, reset = DAT3.
set_property -dict {PULLUP TRUE} [get_ports {sd_mosi_o sd_miso_i sd_d1_i sd_d2_i sd_reset_o}]
set_property -dict {PULLUP TRUE} [get_ports {sd2_mosi_o sd2_miso_i sd2_d1_i sd2_d2_i sd2_reset_o}]

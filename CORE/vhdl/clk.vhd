----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Clock generator, one MMCM:
--
--    main_clk  = 100 MHz * 33 / 5 / 10     = 66.000 MHz   CLKOUT1   the PC (twice the 33 MHz of
--                                                                   CAPS LOCK's speed)
--    audio_clk = 100 MHz * 33 / 5 / 26.875 = 24.558 MHz   CLKOUT0   OPL3 / Sound Blaster; MiSTer's
--                                                                   CLK_AUDIO is 24.576 MHz, this
--                                                                   is 0.07 % slow (fractional
--                                                                   divide only on CLKOUT0)
--    video_clk = main_clk: system.sv's VGA runs on clk_sys with a pixel clock enable
--    sdram_clk = 100 MHz * 33 / 5 / 10     = 66.000 MHz   CLKOUT2   main_clk at 292.5 degrees plus
--                                                                   sdram_ps_target_i fine steps
--
-- The SDRAM clock's phase was measured on an R6 at 64 MHz: sdram.v reads its data three clocks
-- after each READ command, and the PC booted with CLKOUT2 between 180 degrees + 130 and + 570
-- fine steps (1.81 to 7.95 ns after main_clk's falling edge). 292.5 degrees was the middle
-- (4.88 ns), leaving 3.07 ns either way. At 66 MHz (2026-11-10, qmon.py's sweep) it boots from
-- -116 to +108 fine steps of 27.06 ps around 292.5 degrees: a 6.1 ns window with 292.5 degrees
-- 3 steps from its middle, about 3 ns either way. 180 degrees, MiSTer's phase at 85 MHz, is
-- outside.
-- To measure it again, QNICE sets sdram_ps_target_i (signed, in steps of 1/56 of the VCO period,
-- 13.95 ps at 64 MHz; 1120 steps are one main_clk period) and the MMCM's dynamic phase shift walks CLKOUT2
-- there, one step at a time on sys_clk_i. sdram_ps_pos_o is where it is (27.06 ps steps at the
-- VCO's 660 MHz: 560 steps are one main_clk period). The SDRAM needs a
-- reset after a move (mega65.vhd: C_DEV_PC_CTL).
--
-- VCO 660 MHz (600..1440 MHz for -2; CLKFBOUT_MULT_F goes to 64 only, so not 1320 with /20),
-- PFD 20 MHz. 66.0 MHz since 2026-11-10 (64 MHz before):
-- the CPU's paths now close at about 67.1-67.6 MHz (doc/results.md); 66.0 rather than a DX2-66's
-- 66.667 keeps more of that margin and makes CAPS LOCK's 33 MHz exactly half. Implementation aims
-- 0.3 ns above it (CORE-impl.xdc) against build-to-build variation.
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen) and pc10-iii's clk.vhd
-- (Johan Smolinski); licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      main_clk_o      : out std_logic;   -- 66 MHz
      main_rst_o      : out std_logic;   -- main's reset, synchronized
      video_clk_o     : out std_logic;   -- the same clock
      video_rst_o     : out std_logic;   -- video reset, synchronized
      audio_clk_o     : out std_logic;   -- 24.556 MHz
      sdram_clk_o     : out std_logic;   -- 66 MHz, the SDRAM's (z486_mega65.sv forwards it)

      sdram_ps_target_i : in  std_logic_vector(15 downto 0);  -- any clock: cdc_stable here
      sdram_ps_pos_o    : out std_logic_vector(15 downto 0)   -- sys_clk_i
   );
end entity clk;

architecture rtl of clk is

signal clkfb_mmcm         : std_logic;
signal clkfb              : std_logic;
signal audio_clk_mmcm     : std_logic;
signal main_clk_mmcm      : std_logic;
signal main_clk           : std_logic;
signal main_locked        : std_logic;
signal sdram_clk_mmcm     : std_logic;

signal ps_target          : std_logic_vector(15 downto 0);
signal ps_pos             : signed(15 downto 0) := (others => '0');
signal ps_en              : std_logic := '0';
signal ps_incdec          : std_logic := '0';
signal ps_done            : std_logic;
signal ps_busy            : std_logic := '0';

begin

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,          -- PFD 20 MHz
         CLKFBOUT_MULT_F      => 33.000,     -- VCO 660 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 26.875,     -- 24.558 MHz (audio)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 10,         -- 66 MHz (main = video)
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE,
         CLKOUT2_DIVIDE       => 10,         -- 66 MHz (SDRAM), 292.5 degrees + dynamic shift
         CLKOUT2_PHASE        => 292.500,
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_USE_FINE_PS  => TRUE
      )
      port map (
         CLKFBOUT            => clkfb_mmcm,
         CLKOUT0             => audio_clk_mmcm,
         CLKOUT1             => main_clk_mmcm,
         CLKOUT2             => sdram_clk_mmcm,
         CLKFBIN             => clkfb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         PSCLK               => sys_clk_i,
         PSEN                => ps_en,
         PSINCDEC            => ps_incdec,
         PSDONE              => ps_done,
         LOCKED              => main_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_main

   clkfb_bufg : BUFG
      port map (
         I => clkfb_mmcm,
         O => clkfb
      );

   main_clk_bufg : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk
      );

   audio_clk_bufg : BUFG
      port map (
         I => audio_clk_mmcm,
         O => audio_clk_o
      );

   sdram_clk_bufg : BUFG
      port map (
         I => sdram_clk_mmcm,
         O => sdram_clk_o
      );

   main_clk_o  <= main_clk;
   video_clk_o <= main_clk;

   -- The SDRAM clock's dynamic phase shift: one PSEN pulse per step, the next after PSDONE.
   -- A new lock (power-up) starts at the static 292.5 degrees again.
   i_cdc_ps_target : entity work.cdc_stable
      generic map ( G_DATA_SIZE => 16 )
      port map (
         src_data_i => sdram_ps_target_i,
         dst_clk_i  => sys_clk_i,
         dst_data_o => ps_target
      );

   p_ps : process (sys_clk_i)
   begin
      if rising_edge(sys_clk_i) then
         ps_en <= '0';
         if main_locked = '0' then
            ps_pos  <= (others => '0');
            ps_busy <= '0';
         elsif ps_busy = '1' then
            if ps_done = '1' then
               ps_busy <= '0';
            end if;
         elsif ps_pos /= signed(ps_target) then
            ps_en    <= '1';
            ps_busy  <= '1';
            if ps_pos < signed(ps_target) then
               ps_incdec <= '1';
               ps_pos    <= ps_pos + 1;
            else
               ps_incdec <= '0';
               ps_pos    <= ps_pos - 1;
            end if;
         end if;
      end if;
   end process p_ps;

   sdram_ps_pos_o <= std_logic_vector(ps_pos);

   i_xpm_cdc_async_rst_video : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,
         dest_clk  => main_clk,
         dest_arst => video_rst_o
      );

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,
         dest_clk  => main_clk,
         dest_arst => main_rst_o
      );

end architecture rtl;

----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Clock generator, one MMCM:
--
--    main_clk  = 100 MHz * 64 / 5 / 20     = 64.000 MHz   CLKOUT1   the PC
--    audio_clk = 100 MHz * 64 / 5 / 52.125 = 24.556 MHz   CLKOUT0   OPL3 / Sound Blaster; MiSTer's
--                                                                   CLK_AUDIO is 24.576 MHz, this
--                                                                   is 0.08 % slow (fractional
--                                                                   divide only on CLKOUT0)
--    video_clk = main_clk: system.sv's VGA runs on clk_sys with a pixel clock enable
--
-- VCO 1280 MHz (600..1440 MHz for -2), PFD 20 MHz. 64 MHz, not a DX2-66's 66.667 MHz: with the
-- framework in, the CPU's paths close at about 65.6 MHz (README). Implementation aims 0.3 ns
-- above 64 MHz (CORE-impl.xdc), which keeps that margin against build-to-build variation.
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen) and pc10-iii's clk.vhd
-- (Johan Smolinski); licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      main_clk_o      : out std_logic;   -- 64 MHz
      main_rst_o      : out std_logic;   -- main's reset, synchronized
      video_clk_o     : out std_logic;   -- the same clock
      video_rst_o     : out std_logic;   -- video reset, synchronized
      audio_clk_o     : out std_logic    -- 24.556 MHz
   );
end entity clk;

architecture rtl of clk is

signal clkfb_mmcm         : std_logic;
signal clkfb              : std_logic;
signal audio_clk_mmcm     : std_logic;
signal main_clk_mmcm      : std_logic;
signal main_clk           : std_logic;
signal main_locked        : std_logic;

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
         CLKFBOUT_MULT_F      => 64.000,     -- VCO 1280 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 52.125,     -- 24.556 MHz (audio)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 20,         -- 64 MHz (main = video)
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => clkfb_mmcm,
         CLKOUT0             => audio_clk_mmcm,
         CLKOUT1             => main_clk_mmcm,
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
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
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

   main_clk_o  <= main_clk;
   video_clk_o <= main_clk;

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

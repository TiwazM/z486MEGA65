-- Copied for z486MEGA65 (2026-11-23), unchanged, from Megamiga/MegaMac (Megamac commit e733c5f).
---------------------------------------------------------------------------------------------------------
-- Megamiga (Amiga for MEGA65, fork of AExp)
--
-- eth_clk: the network card's clocks from the 100 MHz board clock: 50 MHz (RMII reference, also
-- driven to the PHY) and 200 MHz (RX latch / TX delay line in eth_mac), phase aligned.
--   VCO = 100 MHz x 10 = 1000 MHz; CLKOUT0 / 20 = 50 MHz; CLKOUT1 / 5 = 200 MHz.
-- rst50_o: held until the MMCM locks, then released synchronously to clk50_o.
--
-- Done in 2026 (Megamiga, fork of AExp) and licensed under GPL v3.
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity eth_clk is
   port (
      sys_clk_i : in  std_logic;    -- 100 MHz
      clk50_o   : out std_logic;
      clk200_o  : out std_logic;
      rst50_o   : out std_logic
   );
end entity eth_clk;

architecture synthesis of eth_clk is
   signal fb_out, fb_in, c50, c200, locked : std_logic;
   signal clk50 : std_logic;
   signal rst_sync : std_logic_vector(3 downto 0) := (others => '1');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of rst_sync : signal is "TRUE";
begin

   i_mmcm : MMCME2_BASE
      generic map (
         BANDWIDTH        => "OPTIMIZED",
         CLKIN1_PERIOD    => 10.0,
         DIVCLK_DIVIDE    => 1,
         CLKFBOUT_MULT_F  => 10.0,
         CLKOUT0_DIVIDE_F => 20.0,
         CLKOUT1_DIVIDE   => 5,
         STARTUP_WAIT     => FALSE
      )
      port map (
         CLKIN1   => sys_clk_i,
         CLKFBIN  => fb_in,
         CLKFBOUT => fb_out,
         CLKOUT0  => c50,
         CLKOUT1  => c200,
         LOCKED   => locked,
         PWRDWN   => '0',
         RST      => '0'
      );

   i_bufg_fb  : BUFG port map (I => fb_out, O => fb_in);
   i_bufg_50  : BUFG port map (I => c50,    O => clk50);
   i_bufg_200 : BUFG port map (I => c200,   O => clk200_o);

   clk50_o <= clk50;

   p_rst : process (clk50, locked)
   begin
      if locked = '0' then
         rst_sync <= (others => '1');
      elsif rising_edge(clk50) then
         rst_sync <= rst_sync(2 downto 0) & '0';
      end if;
   end process p_rst;

   rst50_o <= rst_sync(3);

end architecture synthesis;

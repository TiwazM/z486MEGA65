-- Copied for z486MEGA65 (2026-11-23), unchanged, from Megamiga/MegaMac (Megamac commit e733c5f).
---------------------------------------------------------------------------------------------------------
-- Megamiga (Amiga for MEGA65, fork of AExp)
--
-- eth_dna: a station address for the network card from the FPGA's unique device DNA (57 bits,
-- DNA_PORT). The 57 bits are folded into 40 by XOR and prefixed with $02 (a locally administered,
-- unicast address), so every MEGA65 gets its own, stable MAC without an EEPROM.
--
-- Done in 2026 (Megamiga, fork of AExp) and licensed under GPL v3.
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity eth_dna is
   port (
      clk_i   : in  std_logic;                        -- at most 100 MHz
      mac_o   : out std_logic_vector(47 downto 0);
      valid_o : out std_logic
   );
end entity eth_dna;

architecture synthesis of eth_dna is
   signal dna_read, dna_shift, dna_dout : std_logic := '0';
   signal sh    : std_logic_vector(56 downto 0) := (others => '0');
   signal n     : natural range 0 to 63 := 0;
   signal step  : natural range 0 to 3 := 0;
   signal valid : std_logic := '0';
begin

   i_dna : DNA_PORT
      port map (CLK => clk_i, DIN => '0', READ => dna_read, SHIFT => dna_shift, DOUT => dna_dout);

   p_read : process (clk_i)
   begin
      if rising_edge(clk_i) then
         dna_read <= '0';
         case step is
            when 0 =>                               -- load the DNA into the shift register
               dna_read <= '1';
               step     <= 1;
            when 1 =>
               dna_shift <= '1';
               n         <= 0;
               step      <= 2;
            when 2 =>                               -- 57 bits, MSB first
               sh <= sh(55 downto 0) & dna_dout;
               if n = 56 then
                  dna_shift <= '0';
                  step      <= 3;
               else
                  n <= n + 1;
               end if;
            when others =>
               valid <= '1';
         end case;
      end if;
   end process p_read;

   mac_o   <= x"02" & (sh(39 downto 0) xor ("00000000000000000000000" & sh(56 downto 40)));
   valid_o <= valid;

end architecture synthesis;

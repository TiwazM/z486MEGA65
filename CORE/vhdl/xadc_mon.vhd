----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The FPGA's own temperature and supplies (the XADC). Left in its default mode (all
-- configuration registers 0), the XADC measures the on-chip sensors in turn and keeps each
-- one's minimum and maximum since the configuration. This reads its status registers over the
-- DRP, one after the other, again and again, for QNICE (mega65.vhd, C_DEV_PC_CTL 0x0020..2B):
--   0..3   now:     temperature, VCCINT, VCCAUX, VCCBRAM
--   4..7   maximum: temperature, VCCINT, VCCAUX, VCCBRAM
--   8..11  minimum: temperature, VCCINT, VCCAUX, VCCBRAM
-- Each a 12-bit code in bits 15..4: degrees C = code * 503.975 / 4096 - 273.15, volts =
-- code * 3 / 4096 (UG480).
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity xadc_mon is
   port (
      clk_i  : in  std_logic;                       -- the DRP clock (up to 250 MHz)
      idx_i  : in  std_logic_vector(3 downto 0);
      data_o : out std_logic_vector(15 downto 0)
   );
end entity xadc_mon;

architecture synthesis of xadc_mon is

   type t_addr is array (0 to 11) of std_logic_vector(6 downto 0);
   constant C_ADDR : t_addr := ("0000000", "0000001", "0000010", "0000110",
                                "0100000", "0100001", "0100010", "0100011",
                                "0100100", "0100101", "0100110", "0100111");

   type t_vals is array (0 to 11) of std_logic_vector(15 downto 0);
   signal vals   : t_vals := (others => (others => '0'));
   signal n      : natural range 0 to 11 := 0;
   signal den    : std_logic := '0';
   signal busy   : std_logic := '0';
   signal wait_c : unsigned(15 downto 0) := (others => '1');      -- before the first request
   signal drp_do : std_logic_vector(15 downto 0);
   signal drdy   : std_logic;

begin

   -- The first request waits 65536 clocks after the configuration, and a request that gets
   -- no DRDY within 1024 clocks is made again: the board read nothing but zeros when the
   -- first one went out at once, the reader waiting for good on its answer.
   p_read : process (clk_i)
   begin
      if rising_edge(clk_i) then
         den <= '0';
         if wait_c /= 0 then
            wait_c <= wait_c - 1;
         elsif busy = '0' then
            den    <= '1';
            busy   <= '1';
            wait_c <= to_unsigned(1023, 16);
         end if;
         if busy = '1' and drdy = '1' then
            vals(n) <= drp_do;
            busy    <= '0';
            wait_c  <= (others => '0');
            if n = 11 then
               n <= 0;
            else
               n <= n + 1;
            end if;
         elsif busy = '1' and wait_c = 1 then
            busy <= '0';                                -- no answer: ask again
         end if;
      end if;
   end process p_read;

   data_o <= vals(to_integer(unsigned(idx_i))) when unsigned(idx_i) < 12 else x"0000";

   i_xadc : XADC
      port map (
         DCLK         => clk_i,
         DEN          => den,
         DADDR        => C_ADDR(n),
         DWE          => '0',
         DI           => x"0000",
         DO           => drp_do,
         DRDY         => drdy,
         RESET        => '0',
         CONVST       => '0',
         CONVSTCLK    => '0',
         VP           => '0',
         VN           => '0',
         VAUXP        => x"0000",
         VAUXN        => x"0000",
         ALM          => open,
         OT           => open,
         BUSY         => open,
         CHANNEL      => open,
         EOC          => open,
         EOS          => open,
         JTAGBUSY     => open,
         JTAGLOCKED   => open,
         JTAGMODIFIED => open,
         MUXADDR      => open
      ); -- i_xadc

end architecture synthesis;

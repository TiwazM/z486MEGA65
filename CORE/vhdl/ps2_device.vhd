----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The device end of a PS/2 link: sends bytes to the PC's keyboard controller (ps2.v, an 8042)
-- and receives its commands. A port of MiSTer's ps2_device (sys/hps_io.sv, Till Harbaum and
-- Alexey Melnikov), with one byte at a time (tx_valid_i / tx_ready_o) instead of its FIFO,
-- which overwrote itself when full.
--
-- The lines are wired as MiSTer wires them: ps2_clk_o / ps2_dat_o are what the device drives
-- (the controller's ps2_kbclk / ps2_kbdat), ps2_clk_i / ps2_dat_i what the controller drives
-- (its ps2_kbclk_out / ps2_kbdat_out, '0' = pulled low). The device clocks bits at
-- clk_i / (2 * G_PS2_DIV): 64 MHz / 4000 = 16 kHz, inside PS/2's 10 to 16.7 kHz.
--
-- A command from the controller aborts nothing that is on the wire, but drops a byte that waits
-- (MiSTer clears its FIFO): the keyboard answers the command first. In the clock the command comes
-- out (rx_valid_o) no new byte is taken: its owner drops its queue then, and an old byte taken in
-- that clock went out before the answer (a mouse's packet byte before FA: Windows, quitting, read
-- it as the answer to F4, 2026-11-02).
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_device is
   generic (
      G_PS2_DIV  : natural := 2000             -- clk_i cycles per half PS/2 clock
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      tx_valid_i : in  std_logic;              -- a byte to send
      tx_data_i  : in  std_logic_vector(7 downto 0);
      tx_ready_o : out std_logic;              -- '1': tx_data_i is taken this cycle if valid

      rx_valid_o : out std_logic;              -- one cycle: a byte from the controller
      rx_data_o  : out std_logic_vector(7 downto 0);

      ps2_clk_i  : in  std_logic;              -- the controller's lines
      ps2_dat_i  : in  std_logic;
      ps2_clk_o  : out std_logic;              -- the device's lines
      ps2_dat_o  : out std_logic
   );
end entity ps2_device;

architecture synthesis of ps2_device is

   signal div_cnt   : natural range 0 to G_PS2_DIV - 1 := 0;
   signal tick      : std_logic := '0';        -- the PS/2 clock to be: a square wave
   signal tick_d    : std_logic := '0';

   signal c1, c2, d1 : std_logic := '1';

   signal pend      : std_logic := '0';        -- a byte waits for the wire
   signal pend_data : std_logic_vector(7 downto 0) := (others => '0');

   signal tx_state  : natural range 0 to 11 := 0;
   signal tx_byte   : std_logic_vector(7 downto 0) := (others => '0');
   signal parity    : std_logic := '1';
   signal gap       : unsigned(1 downto 0) := (others => '0');

   signal rx_state  : natural range 0 to 4 := 0;
   signal rx_cnt    : natural range 0 to 9 := 0;
   signal rx_byte   : std_logic_vector(7 downto 0) := (others => '0');

   signal clk_out   : std_logic := '1';
   signal dat_out   : std_logic := '1';

begin

   tx_ready_o <= not pend and not rx_valid_o;
   ps2_clk_o  <= clk_out;
   ps2_dat_o  <= dat_out;
   rx_data_o  <= rx_byte;

   p_device : process (clk_i)
      variable v_rise, v_fall : boolean;
   begin
      if rising_edge(clk_i) then
         rx_valid_o <= '0';

         if div_cnt = G_PS2_DIV - 1 then
            div_cnt <= 0;
            tick    <= not tick;
         else
            div_cnt <= div_cnt + 1;
         end if;
         tick_d <= tick;
         v_rise := tick_d = '0' and tick = '1';
         v_fall := tick_d = '1' and tick = '0';

         if tx_valid_i = '1' and pend = '0' and rx_valid_o = '0' then
            pend      <= '1';
            pend_data <= tx_data_i;
         end if;

         c1 <= ps2_clk_i;
         c2 <= c1;
         d1 <= ps2_dat_i;

         -- The controller asks to send: it releases its clock with the data line low
         if rx_state = 0 and tx_state = 0 and c2 = '0' and c1 = '1' and d1 = '0' then
            rx_state <= 1;
            dat_out  <= '1';
         end if;

         if v_rise then
            if rx_state /= 0 then
               case rx_state is
                  when 1 =>
                     rx_state <= 2;
                     rx_cnt   <= 0;
                  when 2 =>                    -- 8 data bits, LSB first, then parity (unchecked)
                     if rx_cnt <= 7 then
                        rx_byte <= d1 & rx_byte(7 downto 1);
                     else
                        rx_state <= 3;
                     end if;
                     rx_cnt <= rx_cnt + 1;
                  when 3 =>                    -- stop bit: acknowledge
                     if d1 = '1' then
                        rx_state <= 4;
                        dat_out  <= '0';
                     end if;
                  when others =>
                     dat_out    <= '1';
                     rx_valid_o <= '1';
                     rx_state   <= 0;
                     pend       <= '0';
               end case;
            elsif tx_state = 0 then
               -- Idle lines and a byte: after a gap of up to three PS/2 clocks, the start bit
               if c2 = '1' and c1 = '1' and d1 = '1' and pend = '1' then
                  gap <= gap - 1;
                  if gap = 0 then
                     tx_byte  <= pend_data;
                     pend     <= '0';
                     parity   <= '1';
                     tx_state <= 1;
                     dat_out  <= '0';
                  end if;
               end if;
            else
               if tx_state <= 8 then           -- data bits, LSB first
                  dat_out <= tx_byte(0);
                  tx_byte <= '0' & tx_byte(7 downto 1);
                  if tx_byte(0) = '1' then
                     parity <= not parity;
                  end if;
               elsif tx_state = 9 then         -- odd parity
                  dat_out <= parity;
               elsif tx_state = 10 then        -- stop bit
                  dat_out <= '1';
               end if;
               if tx_state < 11 then
                  tx_state <= tx_state + 1;
               else
                  tx_state <= 0;
               end if;
            end if;
            clk_out <= '1';
         end if;

         if v_fall then
            if tx_state = 0 and rx_state < 2 then
               clk_out <= '1';
            else
               clk_out <= '0';
            end if;
         end if;

         if rst_i = '1' then
            pend     <= '0';
            tx_state <= 0;
            rx_state <= 0;
            clk_out  <= '1';
            dat_out  <= '1';
         end if;
      end if;
   end process p_device;

end architecture synthesis;

-- CORE/vhdl/pc_mouse.vhd: an Amiga mouse's active button lines (a mouSTer's activepotlines) and
-- the 1351 detection beside them, on a fast clock (a "millisecond" is 64 clocks):
--   1. lines open from the start (a passive Amiga mouse): no right or middle button
--   2. lines driven (SID 0), then pin 9 open: right held; pin 5 open: middle held
--   3. 0/255 lines for 300 ms: still an Amiga mouse, not a 1351
--   4. both open for 2 s: the buttons let go (unplugged)
--   5. mid-range lines (a 1351) for 150 ms: a 1351; a step on pin 2: an Amiga mouse at once
-- The framework's values are inverted: SID 0 (driven) = x"FF", SID 255 (open) = x"00".
-- Run: CORE/sim/run_pc_mouse.sh

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity tb_pc_mouse_pot is
end entity tb_pc_mouse_pot;

architecture sim of tb_pc_mouse_pot is

   signal clk      : std_logic := '0';
   signal rst      : std_logic := '1';
   signal down_n   : std_logic := '1';
   signal pot_x    : std_logic_vector(7 downto 0) := x"00";
   signal pot_y    : std_logic_vector(7 downto 0) := x"00";
   signal pin9     : std_logic_vector(7 downto 0) := x"00";
   signal pin5     : std_logic_vector(7 downto 0) := x"00";
   signal c1351    : std_logic;
   signal tx_valid : std_logic;
   signal tx_data  : std_logic_vector(7 downto 0);
   signal rx_valid : std_logic := '0';
   signal rx_data  : std_logic_vector(7 downto 0) := x"00";

   signal last_b0  : std_logic_vector(7 downto 0) := x"00";   -- the last packet's first byte
   signal nbytes   : natural := 0;

   constant C_DRIVEN : std_logic_vector(7 downto 0) := x"FF";  -- SID 0
   constant C_OPEN   : std_logic_vector(7 downto 0) := x"00";  -- SID 255
   constant C_MS     : time := 64 * 20 ns;

begin

   clk <= not clk after 10 ns;

   i_dut : entity work.pc_mouse
      generic map (
         G_CLK_HZ    => 64_000,
         G_QUIET_MS  => 5,
         G_DETECT_MS => 100
      )
      port map (
         clk_i => clk, rst_i => rst,
         up_n_i => '1', down_n_i => down_n, left_n_i => '1', right_n_i => '1', fire_n_i => '1',
         pot_x_i => pot_x, pot_y_i => pot_y, flip_i => "00", c1351_o => c1351,
         pin9_i => pin9, pin5_i => pin5,
         key_num_i => 0, key_pressed_n_i => '1',
         tx_valid_o => tx_valid, tx_data_o => tx_data, tx_ready_i => '1',
         rx_valid_i => rx_valid, rx_data_i => rx_data
      );

   -- the bytes the mouse sends: a packet's first byte has bit 3 set (and is not FA)
   p_rx : process (clk)
   begin
      if rising_edge(clk) then
         if tx_valid = '1' then
            nbytes <= nbytes + 1;
            if tx_data(3) = '1' and tx_data /= x"FA" then
               last_b0 <= tx_data;
            end if;
         end if;
      end if;
   end process p_rx;

   p_main : process
      variable v_bad : natural := 0;
      procedure check (ok : boolean; what : string) is
      begin
         if ok then
            report "ok    " & what;
         else
            report "FAIL  " & what severity error;
            v_bad := v_bad + 1;
         end if;
      end procedure check;
   begin
      wait for 200 ns;
      rst <= '0';
      wait for 2 * C_MS;
      -- enable the mouse (F4)
      wait until rising_edge(clk);
      rx_data <= x"F4"; rx_valid <= '1';
      wait until rising_edge(clk);
      rx_valid <= '0';
      wait for 20 * C_MS;

      -- 1. lines open from the start: no buttons
      check(last_b0(2 downto 1) = "00" and c1351 = '0', "1. passive lines: no right or middle button, not a 1351");

      -- 2. driven, then pin 9 open (right), then pin 5 open (middle)
      pin9 <= C_DRIVEN; pin5 <= C_DRIVEN; pot_x <= C_DRIVEN; pot_y <= C_DRIVEN;
      wait for 30 * C_MS;
      check(last_b0(2 downto 1) = "00", "2. lines driven: no buttons");
      pin9 <= C_OPEN; pot_x <= C_OPEN;
      wait for 30 * C_MS;
      check(last_b0(2 downto 1) = "01", "   pin 9 open: right held (byte 0 " & to_hstring(last_b0) & ")");
      pin9 <= C_DRIVEN; pot_x <= C_DRIVEN;
      wait for 30 * C_MS;
      check(last_b0(2 downto 1) = "00", "   pin 9 driven again: right let go");
      pin5 <= C_OPEN; pot_y <= C_OPEN;
      wait for 30 * C_MS;
      check(last_b0(2 downto 1) = "10", "   pin 5 open: middle held (byte 0 " & to_hstring(last_b0) & ")");
      pin5 <= C_DRIVEN; pot_y <= C_DRIVEN;
      wait for 30 * C_MS;

      -- 3. 0/255 lines for 300 ms: not a 1351
      wait for 300 * C_MS;
      check(c1351 = '0', "3. driven 0/255 lines for 300 ms: still an Amiga mouse");

      -- 4. both open for 2 s: let go
      pin9 <= C_OPEN; pin5 <= C_OPEN; pot_x <= C_OPEN; pot_y <= C_OPEN;
      wait for 100 * C_MS;
      check(last_b0(2 downto 1) = "11", "4. both open: both held at first");
      wait for 2100 * C_MS;
      check(last_b0(2 downto 1) = "00", "   after 2 s open: let go (unplugged)");

      -- 5. a 1351: mid-range values; then a step on pin 2
      pot_x <= x"80"; pot_y <= x"7F";
      wait for 150 * C_MS;
      check(c1351 = '1', "5. mid-range lines for 150 ms: a 1351");
      down_n <= '0';
      wait for 5 * C_MS;
      check(c1351 = '0', "   a step on pin 2: an Amiga mouse at once");

      if v_bad = 0 then
         report "PASS: all checks";
      else
         report "FAILED: " & integer'image(v_bad) & " checks";
      end if;
      std.env.finish;
   end process p_main;

end architecture sim;

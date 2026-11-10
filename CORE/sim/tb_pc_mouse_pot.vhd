-- CORE/vhdl/pc_mouse.vhd: an Amiga mouse's active button lines (a mouSTer's activepotlines) and
-- the 1351 detection beside them, on a fast clock (a "millisecond" is 64 clocks):
--   1. lines open from the start (a passive Amiga mouse): no right or middle button
--   2. lines driven (SID 0), then pin 9 open: right held; pin 5 open: middle held
--   3. 0/255 lines for 300 ms: still an Amiga mouse, not a 1351
--   4. both open for 2 s: the buttons let go (unplugged)
--   5. mid-range lines (a 1351) for 150 ms: a 1351
--   6. the 1351 moving 6 counts every 10 ms, the PC at 40 packets a second (as Windows): the
--      packets carry the motion evenly (2.5 readings a packet, 12 or 18 counts unspread), and
--      all of it; then a step on pin 2: an Amiga mouse at once
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
   -- the packets' x motion (6.), and when each came
   type t_ints is array (0 to 63) of integer;
   type t_times is array (0 to 63) of time;
   signal pk_dx    : t_ints := (others => 0);
   signal pk_t     : t_times := (others => 0 ns);
   signal pk_n     : natural := 0;
   signal pk_idx   : natural range 0 to 2 := 0;
   signal pk_b0    : std_logic_vector(7 downto 0) := x"00";
   signal pk_on    : boolean := false;

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

   -- the bytes the mouse sends: a packet's first byte has bit 3 set (and is not FA); its
   -- second the x motion (sign in the first)
   p_rx : process (clk)
   begin
      if rising_edge(clk) then
         if tx_valid = '1' then
            nbytes <= nbytes + 1;
            if pk_idx = 0 then
               if tx_data(3) = '1' and tx_data /= x"FA" then
                  last_b0 <= tx_data;
                  pk_b0   <= tx_data;
                  pk_idx  <= 1;
               end if;
            elsif pk_idx = 1 then
               if pk_on and pk_n < 64 then
                  pk_dx(pk_n) <= to_integer(signed(pk_b0(4) & tx_data));
                  pk_t(pk_n)  <= now;
                  pk_n        <= pk_n + 1;
               end if;
               pk_idx <= 2;
            else
               pk_idx <= 0;
            end if;
         end if;
      end if;
   end process p_rx;

   p_main : process
      variable v_bad : natural := 0;
      variable v_pot : unsigned(7 downto 0);
      variable v_sum, v_min, v_max, v_cnt : integer;
      variable v_t0  : time;
      procedure send (b : std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         rx_data <= b; rx_valid <= '1';
         wait until rising_edge(clk);
         rx_valid <= '0';
         wait for 2 * C_MS;
      end procedure send;
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

      -- 6. 6 counts every 10 ms, 40 packets a second
      send(x"F3"); send(x"28");
      wait for 30 * C_MS;
      pk_on <= true;
      v_pot := x"80";
      v_t0  := now;
      for k in 1 to 20 loop
         v_pot := v_pot - 12;                    -- the SID's value + 12: x + 6
         pot_x <= std_logic_vector(v_pot);
         wait for 10 * C_MS;
      end loop;
      wait for 100 * C_MS;
      pk_on <= false;
      wait for 1 * C_MS;
      v_sum := 0; v_min := 1000; v_max := -1000; v_cnt := 0;
      for k in 0 to pk_n - 1 loop
         v_sum := v_sum + pk_dx(k);
         -- the steady part: packets from 50 ms into the motion to its end
         if pk_t(k) > v_t0 + 50 * C_MS and pk_t(k) <= v_t0 + 200 * C_MS then
            v_cnt := v_cnt + 1;
            if pk_dx(k) < v_min then v_min := pk_dx(k); end if;
            if pk_dx(k) > v_max then v_max := pk_dx(k); end if;
         end if;
      end loop;
      check(v_sum = 120, "6. all the motion: 120 counts in the packets (" & integer'image(v_sum) & ")");
      check(v_cnt >= 5 and v_max - v_min <= 2, "   evenly: " & integer'image(v_cnt) &
            " packets in the steady part, " & integer'image(v_min) & ".." & integer'image(v_max) &
            " counts each");
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

----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Testbench: pc_keyboard.vhd under stress. Random presses and releases of the keys that move the
-- PC's Shift (the shifts, F7 = F8 with Shift, :, ;, *, @, INST/DEL, MEGA, cursor up, A), while
-- the PC takes the bytes at random speeds and stops taking them for long stretches (an 8042
-- whose FIFO is full, a PC that does not read the keyboard). Then every key goes up, the PC
-- reads everything, and the test checks:
--   1. the PC holds no key (a set 2 decoder of the bytes, as the 8042 sees them)
--   2. : alone is Shift+; (12 4C), its release F0 4C F0 12: the translator holds no Shift back
--   3. Shift+A is 12 1C: the PC's Shift works, and the sweep never had a release to send
--   4. a release lost on purpose (the module's copy of the matrix forced while : goes up): the
--      sweep sends it (F0 4C F0 12), once
-- The matrix is scanned as the framework does: every key for G_HOLD clocks in turn.
-- Run: CORE/sim/run_kbd_stress.sh (nvc)
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_kbd_stress is
   generic (
      G_SEED   : positive := 1;
      G_STEPS  : positive := 400;
      G_HOLD   : positive := 4;                  -- clocks per key in the matrix scan
      G_UNBLOCK : positive := 8                  -- 1 in G_UNBLOCK steps stops / restarts the PC
   );
end entity tb_kbd_stress;

architecture sim of tb_kbd_stress is

   constant C_T      : time := 15.625 ns;

   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal done       : boolean := false;

   signal keys       : std_logic_vector(79 downto 0) := (others => '0');   -- '1' = pressed
   signal key_num    : integer range 0 to 79 := 0;
   signal hold_cnt   : natural := 0;
   signal key_pressed_n : std_logic;

   signal tx_valid   : std_logic;
   signal tx_data    : std_logic_vector(7 downto 0);
   signal tx_ready   : std_logic := '0';
   signal dbg        : std_logic_vector(31 downto 0);

   -- the PC: takes a byte every rd_gap clocks unless blocked
   signal blocked    : boolean := false;
   signal rd_gap     : natural := 16;
   signal rd_cnt     : natural := 0;
   signal idle_clks  : natural := 0;            -- clocks since the last byte

   -- what the PC holds: set 2 codes, E0 codes at 256 + code
   type t_held is array (0 to 511) of boolean;
   signal held       : t_held := (others => false);
   signal nbytes     : natural := 0;
   type t_log is array (0 to 15) of std_logic_vector(7 downto 0);
   signal last       : t_log := (others => x"00");   -- the last bytes, newest at 0

   type t_keys is array (natural range <>) of natural;
   constant C_KEYS : t_keys := (15, 52, 3, 45, 50, 49, 46, 0, 61, 73, 10, 4);

   function hex(v : std_logic_vector(7 downto 0)) return string is
      constant C_DIGITS : string(1 to 16) := "0123456789ABCDEF";
   begin
      return C_DIGITS(to_integer(unsigned(v(7 downto 4))) + 1) &
             C_DIGITS(to_integer(unsigned(v(3 downto 0))) + 1);
   end function hex;

begin

   clk <= not clk after C_T / 2 when not done;

   p_matrix : process (clk)
   begin
      if rising_edge(clk) then
         if hold_cnt = G_HOLD - 1 then
            hold_cnt <= 0;
            key_num  <= (key_num + 1) mod 80;
         else
            hold_cnt <= hold_cnt + 1;
         end if;
      end if;
   end process p_matrix;
   key_pressed_n <= not keys(key_num);

   i_dut : entity work.pc_keyboard
      generic map (
         G_CLK_HZ        => 64_000           -- typematic 1000 times faster
      )
      port map (
         clk_i           => clk,
         rst_i           => rst,
         key_num_i       => key_num,
         key_pressed_n_i => key_pressed_n,
         tx_valid_o      => tx_valid,
         tx_data_o       => tx_data,
         tx_ready_i      => tx_ready,
         rx_valid_i      => '0',
         rx_data_i       => x"00",
         dbg_o           => dbg
      );

   -- The PC's end: one byte per rd_gap clocks; a set 2 decoder of what it holds
   p_pc : process (clk)
      variable v_e0, v_f0 : boolean := false;
      variable v_idx      : natural;
   begin
      if rising_edge(clk) then
         tx_ready <= '0';
         if not blocked and rd_cnt >= rd_gap then
            tx_ready <= '1';
         end if;
         if tx_ready = '0' and not blocked and rd_cnt < rd_gap then
            rd_cnt <= rd_cnt + 1;
         end if;
         if tx_valid = '1' and tx_ready = '1' then
            rd_cnt <= 0;
            tx_ready <= '0';
            nbytes <= nbytes + 1;
            last <= tx_data & last(0 to 14);
            idle_clks <= 0;
            if tx_data = x"E0" then
               v_e0 := true;
            elsif tx_data = x"F0" then
               v_f0 := true;
            else
               v_idx := to_integer(unsigned(tx_data));
               if v_e0 then
                  v_idx := v_idx + 256;
               end if;
               held(v_idx) <= not v_f0;
               v_e0 := false;
               v_f0 := false;
            end if;
         elsif idle_clks < 1_000_000 then
            idle_clks <= idle_clks + 1;
         end if;
      end if;
   end process p_pc;

   p_test : process
      alias dut_state is << signal .tb_kbd_stress.i_dut.state : std_logic_vector(79 downto 0) >>;
      variable v_s1, v_s2 : positive;
      variable v_r        : real;
      variable v_bad      : natural := 0;
      variable v_k        : natural;
      variable v_n0       : natural;

      procedure rnd(n : natural; r : out natural) is
      begin
         uniform(v_s1, v_s2, v_r);
         r := integer(floor(v_r * real(n)));
         if r >= n then
            r := n - 1;
         end if;
      end procedure rnd;

      procedure clocks(n : natural) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure clocks;

      -- until the PC has had nothing for 20000 clocks (the typematic, 1000 times faster, repeats
      -- every 92 to 2000 clocks: every key is up by then, so it stays quiet)
      procedure drain is
      begin
         for i in 1 to 2000 loop                 -- 2M clocks at most: a key repeating for good
            clocks(1000);
            exit when idle_clks >= 20_000;
         end loop;
         if idle_clks < 20_000 then
            report "      still sending after 2M clocks: a key repeats for good (the last: " &
                   hex(last(0)) & ")" severity warning;
         end if;
      end procedure drain;

      procedure check(ok : boolean; what : string) is
      begin
         if ok then
            report "ok    " & what;
         else
            report "FAIL  " & what severity error;
            v_bad := v_bad + 1;
         end if;
      end procedure check;

      function lastn(l : t_log; n : natural) return string is
         variable v : string(1 to 3 * n);
      begin
         for i in 0 to n - 1 loop
            v(3 * i + 1 to 3 * i + 3) := hex(l(n - 1 - i)) & " ";
         end loop;
         return v;
      end function lastn;

      variable v_any : boolean;
      variable v_r2  : natural;
   begin
      v_s1 := G_SEED;
      v_s2 := G_SEED * 7 + 3;
      clocks(10);
      rst <= '0';
      clocks(100);

      for step in 1 to G_STEPS loop
         rnd(C_KEYS'length, v_k);
         v_k := C_KEYS(v_k);
         keys(v_k) <= not keys(v_k);
         rnd(G_UNBLOCK, v_r2);
         if v_r2 = 0 then                           -- the PC stops reading for a while
            blocked <= true;
         elsif v_r2 = 1 then
            blocked <= false;
         elsif v_r2 = 2 then
            rnd(400, v_r2);                         -- the PC reads at another speed
            rd_gap <= v_r2 + 4;
         end if;
         rnd(6000, v_r2);
         clocks(v_r2 + 2 * 80 * G_HOLD);           -- at least two scans of the matrix
      end loop;

      -- every key up, the PC reads at full speed
      keys <= (others => '0');
      blocked <= false;
      rd_gap <= 16;
      clocks(4 * 80 * G_HOLD);
      drain;

      v_any := false;
      for i in held'range loop
         if held(i) then
            report "      the PC still holds code " & integer'image(i) severity error;
            v_any := true;
         end if;
      end loop;
      check(not v_any, "1. after " & integer'image(G_STEPS) & " random steps the PC holds no key (" &
            integer'image(nbytes) & " bytes; the last: " & lastn(last, 8) & ")");

      v_n0 := nbytes;
      keys(45) <= '1';
      clocks(4 * 80 * G_HOLD);
      clocks(2000);
      keys(45) <= '0';
      clocks(4 * 80 * G_HOLD);
      drain;
      check(nbytes - v_n0 = 6 and last(5) = x"12" and last(4) = x"4C" and last(3) = x"F0" and
            last(2) = x"4C" and last(1) = x"F0" and last(0) = x"12",
            "2. : alone = 12 4C F0 4C F0 12 (got " & integer'image(nbytes - v_n0) & ": " &
            lastn(last, 6) & ")");

      v_n0 := nbytes;
      keys(15) <= '1';
      clocks(4 * 80 * G_HOLD);
      keys(10) <= '1';
      clocks(4 * 80 * G_HOLD);
      clocks(2000);
      keys(10) <= '0';
      clocks(4 * 80 * G_HOLD);
      keys(15) <= '0';
      clocks(4 * 80 * G_HOLD);
      drain;
      check(nbytes - v_n0 = 6 and last(5) = x"12" and last(4) = x"1C" and last(0) = x"12" and
            last(1) = x"F0",
            "3. Shift+A = 12 1C ... F0 1C F0 12 (got " & integer'image(nbytes - v_n0) & ": " &
            lastn(last, 6) & ")");

      check(dbg(23 downto 16) = x"00", "   the sweep sent no release (" &
            integer'image(to_integer(unsigned(dbg(23 downto 16)))) & ")");

      v_n0 := nbytes;
      keys(45) <= '1';
      clocks(4 * 80 * G_HOLD);
      clocks(2000);
      dut_state <= force (others => '0');
      keys(45) <= '0';
      clocks(4 * 80 * G_HOLD);
      dut_state <= release;
      clocks(4 * 80 * G_HOLD);
      drain;
      check(nbytes - v_n0 = 6 and last(5) = x"12" and last(4) = x"4C" and last(3) = x"F0" and
            last(2) = x"4C" and last(1) = x"F0" and last(0) = x"12" and
            dbg(23 downto 16) = x"01" and dbg(30 downto 24) = "0101101",
            "4. : with its release lost: the sweep sends it (got " & integer'image(nbytes - v_n0) &
            ": " & lastn(last, 6) & "; sweep releases " &
            integer'image(to_integer(unsigned(dbg(23 downto 16)))) & ", the last key " &
            integer'image(to_integer(unsigned(dbg(30 downto 24)))) & ")");
      check(dbg(6 downto 0) = "1010000" and dbg(15) = '1', "   nothing holds the Shift back now");

      if v_bad = 0 then
         report "PASS: all checks (seed " & integer'image(G_SEED) & ")";
      else
         report "FAILED: " & integer'image(v_bad) & " checks (seed " & integer'image(G_SEED) & ")";
      end if;
      done <= true;
      wait;
   end process p_test;

end architecture sim;

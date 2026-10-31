----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Testbench: the MEGA65 keyboard (pc_keyboard.vhd, ps2_device.vhd) against the PC's keyboard
-- controller (z486_MiSTer's ps2.v, an 8042 that translates set 2 to set 1). The test plays the
-- BIOS on ports 0x60/0x64 and a MEGA65 key matrix, and checks the set 1 bytes the PC reads.
-- CORE/sim/run_ps2.sh runs it with Vivado's xsim.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pc_keyboard is
end entity tb_pc_keyboard;

architecture sim of tb_pc_keyboard is

   constant C_T        : time := 15.625 ns;      -- 64 MHz

   signal clk          : std_logic := '0';
   signal rst          : std_logic := '1';
   signal rst_n        : std_logic := '0';
   signal done         : boolean := false;

   signal keys         : std_logic_vector(79 downto 0) := (others => '0');   -- '1' = pressed
   signal key_num      : integer range 0 to 79 := 0;
   signal key_pressed_n : std_logic;

   signal tx_valid     : std_logic;
   signal tx_data      : std_logic_vector(7 downto 0);
   signal tx_ready     : std_logic;
   signal rx_valid     : std_logic;
   signal rx_data      : std_logic_vector(7 downto 0);
   signal dev_clk      : std_logic;
   signal dev_dat      : std_logic;
   signal host_clk     : std_logic;
   signal host_dat     : std_logic;

   signal io_address   : std_logic_vector(3 downto 0) := x"0";
   signal io_read      : std_logic := '0';
   signal io_write     : std_logic := '0';
   signal io_writedata : std_logic_vector(7 downto 0) := x"00";
   signal io_readdata  : std_logic_vector(7 downto 0);

   signal errors       : natural := 0;

   component ps2 is
      port (
         clk               : in  std_logic;
         rst_n             : in  std_logic;
         irq_keyb          : out std_logic;
         irq_mouse         : out std_logic;
         io_address        : in  std_logic_vector(3 downto 0);
         io_read           : in  std_logic;
         io_readdata       : out std_logic_vector(7 downto 0);
         io_write          : in  std_logic;
         io_writedata      : in  std_logic_vector(7 downto 0);
         io_cs             : in  std_logic;
         ctl_cs            : in  std_logic;
         output_a20_enable : out std_logic;
         output_reset_n    : out std_logic;
         a20_enable        : out std_logic;
         ps2_kbclk         : in  std_logic;
         ps2_kbdat         : in  std_logic;
         ps2_kbclk_out     : out std_logic;
         ps2_kbdat_out     : out std_logic;
         ps2_mouseclk      : in  std_logic;
         ps2_mousedat      : in  std_logic;
         ps2_mouseclk_out  : out std_logic;
         ps2_mousedat_out  : out std_logic
      );
   end component ps2;

   function hex(v : std_logic_vector(7 downto 0)) return string is
      constant C_DIGITS : string(1 to 16) := "0123456789ABCDEF";
   begin
      return C_DIGITS(to_integer(unsigned(v(7 downto 4))) + 1) &
             C_DIGITS(to_integer(unsigned(v(3 downto 0))) + 1);
   end function hex;

begin

   clk <= not clk after C_T / 2 when not done;

   -- The MEGA65 matrix as the framework presents it, one key per clock
   p_matrix : process (clk)
   begin
      if rising_edge(clk) then
         key_num <= (key_num + 1) mod 80;
      end if;
   end process p_matrix;
   key_pressed_n <= not keys(key_num);

   i_keyboard : entity work.pc_keyboard
      generic map (
         G_CLK_HZ        => 6_400_000    -- typematic 10 times faster
      )
      port map (
         clk_i           => clk,
         rst_i           => rst,
         key_num_i       => key_num,
         key_pressed_n_i => key_pressed_n,
         tx_valid_o      => tx_valid,
         tx_data_o       => tx_data,
         tx_ready_i      => tx_ready,
         rx_valid_i      => rx_valid,
         rx_data_i       => rx_data
      );

   i_device : entity work.ps2_device
      port map (
         clk_i      => clk,
         rst_i      => rst,
         tx_valid_i => tx_valid,
         tx_data_i  => tx_data,
         tx_ready_o => tx_ready,
         rx_valid_o => rx_valid,
         rx_data_o  => rx_data,
         ps2_clk_i  => host_clk,
         ps2_dat_i  => host_dat,
         ps2_clk_o  => dev_clk,
         ps2_dat_o  => dev_dat
      );

   i_8042 : ps2
      port map (
         clk               => clk,
         rst_n             => rst_n,
         irq_keyb          => open,
         irq_mouse         => open,
         io_address        => io_address,
         io_read           => io_read,
         io_readdata       => io_readdata,
         io_write          => io_write,
         io_writedata      => io_writedata,
         io_cs             => '1',
         ctl_cs            => '0',
         output_a20_enable => open,
         output_reset_n    => open,
         a20_enable        => open,
         ps2_kbclk         => dev_clk,
         ps2_kbdat         => dev_dat,
         ps2_kbclk_out     => host_clk,
         ps2_kbdat_out     => host_dat,
         ps2_mouseclk      => '1',
         ps2_mousedat      => '1',
         ps2_mouseclk_out  => open,
         ps2_mousedat_out  => open
      );

   -- The BIOS
   p_test : process
      procedure io_wr(addr : natural; data : std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         io_address   <= std_logic_vector(to_unsigned(addr, 4));
         io_writedata <= data;
         io_write     <= '1';
         wait until rising_edge(clk);
         io_write     <= '0';
      end procedure io_wr;

      procedure io_rd(addr : natural; data : out std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         io_address <= std_logic_vector(to_unsigned(addr, 4));
         io_read    <= '1';
         wait until rising_edge(clk);
         io_read    <= '0';
         wait until rising_edge(clk);
         data := io_readdata;
      end procedure io_rd;

      -- The next byte from the keyboard (port 0x60 once the status has OBF), or "--" after
      -- about 20 ms without one
      procedure next_byte(data : out std_logic_vector(7 downto 0); got : out boolean) is
         variable v_st : std_logic_vector(7 downto 0);
      begin
         got := false;
         for i in 1 to 10000 loop
            io_rd(4, v_st);
            if v_st(0) = '1' then
               io_rd(0, data);
               got := true;
               return;
            end if;
            for j in 1 to 120 loop
               wait until rising_edge(clk);
            end loop;
         end loop;
      end procedure next_byte;

      procedure expect(what : string; bytes : std_logic_vector) is
         variable v_b   : std_logic_vector(7 downto 0);
         variable v_got : boolean;
         variable v_ok  : boolean := true;
         variable v_txt : string(1 to 3 * (bytes'length / 8)) := (others => ' ');
         variable v_n   : natural := bytes'length / 8;
         variable v_all : std_logic_vector(bytes'length - 1 downto 0) := bytes;
      begin
         for i in 0 to v_n - 1 loop
            next_byte(v_b, v_got);
            if v_got then
               v_txt(3 * i + 1 to 3 * i + 2) := hex(v_b);
               if v_b /= v_all(v_all'left - 8 * i downto v_all'left - 8 * i - 7) then
                  v_ok := false;
               end if;
            else
               v_txt(3 * i + 1 to 3 * i + 2) := "--";
               v_ok := false;
            end if;
         end loop;
         if v_ok then
            report "ok    " & what & ": " & v_txt;
         else
            report "FAIL  " & what & ": " & v_txt severity error;
            errors <= errors + 1;
         end if;
      end procedure expect;

      procedure nothing(what : string) is
         variable v_b   : std_logic_vector(7 downto 0);
         variable v_got : boolean;
      begin
         next_byte(v_b, v_got);
         if v_got then
            report "FAIL  " & what & ": unexpected " & hex(v_b) severity error;
            errors <= errors + 1;
         else
            report "ok    " & what & ": nothing";
         end if;
      end procedure nothing;

      procedure key_down(k : natural) is
      begin
         keys(k) <= '1';
         wait for 20 us;
      end procedure key_down;

      procedure key_up(k : natural) is
      begin
         keys(k) <= '0';
         wait for 20 us;
      end procedure key_up;

   begin
      wait for 1 us;
      rst   <= '0';
      rst_n <= '1';
      wait for 10 us;

      io_wr(0, x"FF");  expect("reset FF", x"FA" & x"AA");
      io_wr(0, x"ED");  expect("LEDs ED", x"FA");
      io_wr(0, x"02");  expect("LEDs 02", x"FA");
      io_wr(0, x"F2");  expect("identify F2 (AB 83 translated)", x"FA" & x"AB" & x"41");
      io_wr(0, x"F4");  expect("enable F4", x"FA");

      key_down(10);   expect("A make", x"1E");
      key_up(10); expect("A break", x"9E");

      key_down(15);   expect("left shift make", x"2A");
      key_down(4);    expect("Shift+F1 = F2: shift break, F2 make", x"AA" & x"3C");
      key_up(4);  expect("F2 break, shift make again", x"BC" & x"2A");
      key_up(15); expect("left shift break", x"AA");

      key_down(73);   expect("cursor up make", x"E0" & x"48");
      key_up(73); expect("cursor up break", x"E0" & x"C8");

      key_down(61);   nothing("MEGA alone");
      key_down(73);   expect("MEGA+cursor up = Page Up", x"E0" & x"49");
      key_up(61); nothing("MEGA released");
      key_up(73); expect("Page Up break", x"E0" & x"C9");

      key_down(72);   expect("Caps Lock latched: a tap", x"3A" & x"BA");
      key_up(72); expect("Caps Lock unlatched: a tap", x"3A" & x"BA");

      -- The symbols by their keycaps: the PC's Shift pressed or released around the key
      key_down(45);   expect(": = Shift+;", x"2A" & x"27");
      key_up(45); expect(": break, Shift break", x"A7" & x"AA");
      key_down(15);   expect("left shift make", x"2A");
      key_down(45);   expect("Shift+: = [: shift break, [ make", x"AA" & x"1A");
      key_up(45); expect("[ break, shift make again", x"9A" & x"2A");
      key_down(59);   expect("Shift+2 = quote (Shift+'), the shift stays", x"28");
      key_up(59); expect("quote break", x"A8");
      key_up(15); expect("left shift break", x"AA");
      key_down(50);   expect("; = ;", x"27");
      key_up(50); expect("; break", x"A7");
      key_down(46);   expect("@ = Shift+2", x"2A" & x"03");
      key_up(46); expect("@ break, Shift break", x"83" & x"AA");
      key_down(53);   expect("= = =", x"0D");
      key_up(53); expect("= break", x"8D");

      key_down(0);    expect("INST/DEL = Backspace", x"0E");
      key_up(0);  expect("Backspace break", x"8E");

      -- Typematic: 500 ms then 92 ms, 10 times faster here
      key_down(10);   expect("A make", x"1E");
      wait for 45 ms;                         -- most of the 50 ms delay
      expect("A repeats after the delay", x"1E" & x"1E" & x"1E");
      key_up(10); expect("A break", x"9E");

      io_wr(0, x"F5");  expect("disable F5", x"FA");
      key_down(10);   nothing("A while disabled");
      key_up(10); nothing("A released while disabled");
      io_wr(0, x"F4");  expect("enable F4", x"FA");
      io_wr(0, x"EE");  expect("echo EE", x"EE");

      if errors = 0 then
         report "PASS: all checks" severity note;
      else
         report "FAILED: " & integer'image(errors) & " checks" severity error;
      end if;
      done <= true;
      wait;
   end process p_test;

end architecture sim;

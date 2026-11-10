----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Testbench: the joystick-port mouse (pc_mouse.vhd, ps2_device.vhd) against the PC's keyboard
-- controller (z486_MiSTer's ps2.v, an 8042) on its mouse port. The test plays the BIOS on ports
-- 0x60/0x64 (D4: the next byte goes to the mouse), an Amiga mouse's quadrature lines and the
-- MEGA65's F13 key, then a 1351 (a mouSTer's C64 mode) on the paddle lines, and checks the
-- bytes the PC reads. CORE/sim/run_ps2.sh runs it with
-- Vivado's xsim.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pc_mouse is
   generic (
      G_QUIET : natural := 50     -- pc_mouse's G_QUIET_MS here; 0: as before it (FAILs)
   );
end entity tb_pc_mouse;

architecture sim of tb_pc_mouse is

   constant C_T        : time := 15.625 ns;      -- 64 MHz

   signal clk          : std_logic := '0';
   signal rst          : std_logic := '1';
   signal rst_n        : std_logic := '0';
   signal done         : boolean := false;

   -- the port's lines (pin 1 up = V, 2 down = H, 3 left = VQ, 4 right = HQ, 6 fire)
   signal j_up, j_down, j_left, j_right, j_fire : std_logic := '1';
   signal keys         : std_logic_vector(79 downto 0) := (others => '0');   -- '1' = pressed
   -- the paddle lines as the framework gives them (inverted: an open line 0), the axis flips
   signal pot_x, pot_y : std_logic_vector(7 downto 0) := x"00";
   signal flip         : std_logic_vector(1 downto 0) := "00";
   signal c1351        : std_logic;
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

   i_mouse : entity work.pc_mouse
      generic map (
         G_CLK_HZ        => 6_400_000,   -- sample periods 10 times shorter
         G_QUIET_MS      => G_QUIET,     -- 5 ms here: the motion checks wait 20 ms
         G_DETECT_MS     => 100          -- 10 ms here
      )
      port map (
         clk_i           => clk,
         rst_i           => rst,
         up_n_i          => j_up,
         down_n_i        => j_down,
         left_n_i        => j_left,
         right_n_i       => j_right,
         fire_n_i        => j_fire,
         pot_x_i         => pot_x,
         pot_y_i         => pot_y,
         flip_i          => flip,
         c1351_o         => c1351,
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
         ps2_kbclk         => '1',
         ps2_kbdat         => '1',
         ps2_kbclk_out     => open,
         ps2_kbdat_out     => open,
         ps2_mouseclk      => dev_clk,
         ps2_mousedat      => dev_dat,
         ps2_mouseclk_out  => host_clk,
         ps2_mousedat_out  => host_dat
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

      -- a byte to the mouse: 8042 command D4, then the byte
      procedure to_mouse(data : std_logic_vector(7 downto 0)) is
      begin
         io_wr(4, x"D4");
         wait for 2 us;
         io_wr(0, data);
      end procedure to_mouse;

      -- The next byte from the mouse (port 0x60 once the status has OBF and AUX), or "--"
      -- after about 20 ms without one
      procedure next_byte(data : out std_logic_vector(7 downto 0); got : out boolean) is
         variable v_st : std_logic_vector(7 downto 0);
      begin
         got := false;
         for i in 1 to 10000 loop
            io_rd(4, v_st);
            if v_st(0) = '1' and v_st(5) = '1' then
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

      -- Packets until their motion adds up to (ex, ey), each with buttons b (middle, right,
      -- left): the first step after a still spell goes out at once, the rest a sample later
      procedure expect_motion(what : string; ex, ey : integer; b : std_logic_vector(2 downto 0)) is
         variable v_p   : std_logic_vector(7 downto 0);
         variable v_x   : std_logic_vector(7 downto 0);
         variable v_y   : std_logic_vector(7 downto 0);
         variable v_got : boolean;
         variable v_sx  : integer := 0;
         variable v_sy  : integer := 0;
         variable v_ok  : boolean := false;
         variable v_txt : string(1 to 8) := "-- -- --";
      begin
         for i in 1 to 8 loop
            next_byte(v_p, v_got);
            exit when not v_got;
            next_byte(v_x, v_got);
            exit when not v_got;
            next_byte(v_y, v_got);
            exit when not v_got;
            v_txt := hex(v_p) & " " & hex(v_x) & " " & hex(v_y);
            exit when v_p(3) /= '1' or v_p(2 downto 0) /= b;
            v_sx := v_sx + to_integer(signed(v_p(4) & v_x));
            v_sy := v_sy + to_integer(signed(v_p(5) & v_y));
            if v_sx = ex and v_sy = ey then
               v_ok := true;
               exit;
            end if;
         end loop;
         if v_ok then
            report "ok    " & what & ": x " & integer'image(v_sx) & ", y " & integer'image(v_sy) &
                   " (last packet " & v_txt & ")";
         else
            report "FAIL  " & what & ": x " & integer'image(v_sx) & ", y " & integer'image(v_sy) &
                   " (last packet " & v_txt & ")" severity error;
            errors <= errors + 1;
         end if;
      end procedure expect_motion;

      -- n quadrature steps on a pair of lines, from where they are: fwd along the Gray code
      -- 11 -> 01 -> 00 -> 10 -> 11 (each a step "down" for pc_mouse's step(): right on the H
      -- pair, down on the V pair), else the other way round
      -- a 1351 at position (x, y): SID values with the position in bits 6..1 and noise in bit
      -- 0, inverted as the framework hands them over
      procedure at1351(x, y : natural; noise : std_logic := '0') is
      begin
         pot_x <= not (std_logic_vector(to_unsigned(x mod 64, 7)) & noise);
         pot_y <= not (std_logic_vector(to_unsigned(y mod 64, 7)) & noise);
         wait for 3 us;
      end procedure at1351;

      procedure mode(what : string; want : std_logic) is
      begin
         if c1351 = want then
            report "ok    " & what;
         else
            report "FAIL  " & what severity error;
            errors <= errors + 1;
         end if;
      end procedure mode;

      procedure steps(signal a, b : inout std_logic; n : natural; fwd : boolean) is
         variable v_s : std_logic_vector(1 downto 0);
      begin
         for i in 1 to n loop
            v_s := a & b;
            if fwd then
               case v_s is
                  when "11"   => v_s := "01";
                  when "01"   => v_s := "00";
                  when "00"   => v_s := "10";
                  when others => v_s := "11";
               end case;
            else
               case v_s is
                  when "11"   => v_s := "10";
                  when "10"   => v_s := "00";
                  when "00"   => v_s := "01";
                  when others => v_s := "11";
               end case;
            end if;
            a <= v_s(1);
            b <= v_s(0);
            wait for 2 us;
         end loop;
      end procedure steps;

   begin
      wait for 1 us;
      rst   <= '0';
      rst_n <= '1';
      wait for 10 us;

      io_wr(4, x"A8");                          -- the 8042: mouse port on
      wait for 10 us;
      to_mouse(x"FF");  expect("reset FF", x"FA" & x"AA" & x"00");
      to_mouse(x"F2");  expect("identify F2", x"FA" & x"00");
      to_mouse(x"F3");  expect("sample rate F3", x"FA");
      to_mouse(x"C8");  expect("rate 200", x"FA");
      to_mouse(x"E8");  expect("resolution E8", x"FA");
      to_mouse(x"03");  expect("resolution 3", x"FA");
      to_mouse(x"E9");  expect("status E9: disabled, rate 200", x"FA" & x"00" & x"03" & x"C8");
      to_mouse(x"F6");  expect("defaults F6", x"FA");
      to_mouse(x"E9");  expect("status E9: defaults", x"FA" & x"00" & x"02" & x"64");
      steps(j_down, j_right, 4, true);
      nothing("motion while disabled");
      to_mouse(x"F4");  expect("enable F4", x"FA");

      steps(j_down, j_right, 4, true);
      expect_motion("4 right", 4, 0, "000");
      steps(j_down, j_right, 3, false);
      expect_motion("3 left", -3, 0, "000");
      steps(j_up, j_left, 4, false);
      expect_motion("4 up", 0, 4, "000");
      steps(j_up, j_left, 2, true);
      expect_motion("2 down", 0, -2, "000");

      j_fire <= '0';    expect_motion("left button", 0, 0, "001");
      j_fire <= '1';    expect_motion("left button up", 0, 0, "000");
      keys(70) <= '1';  expect_motion("F13: right button", 0, 0, "010");
      to_mouse(x"E9");  expect("status E9: enabled, right button", x"FA" & x"21" & x"02" & x"64");
      keys(70) <= '0';  expect_motion("right button up", 0, 0, "000");
      nothing("still");

      to_mouse(x"F0");  expect("remote mode F0", x"FA");
      steps(j_down, j_right, 4, true);
      nothing("motion in remote mode");
      to_mouse(x"EB");  expect("read data EB", x"FA" & x"08" & x"04" & x"00");
      to_mouse(x"EA");  expect("stream mode EA", x"FA");
      to_mouse(x"EE");  expect("wrap mode EE", x"FA");
      to_mouse(x"55");  expect("wrap: echo", x"55");
      to_mouse(x"EC");  expect("wrap off EC", x"FA");
      to_mouse(x"D0");  expect("unknown D0: resend", x"FE");
      -- Motion in the middle of a command (F3, then its byte) is no packet in between: the
      -- BIOS takes the byte after its command as the answer (G_QUIET_MS)
      to_mouse(x"F3");  expect("sample rate F3 while enabled", x"FA");
      steps(j_down, j_right, 4, true);
      wait for 1 ms;
      to_mouse(x"64");  expect("rate 100: FA, no packet first", x"FA");
      expect_motion("4 right after the quiet time", 4, 0, "000");
      to_mouse(x"F5");  expect("disable F5", x"FA");
      steps(j_down, j_right, 4, true);
      nothing("motion after F5");

      -- Windows quitting (I/O trace, 2026-11-02): packets wait unread in the 8042, the command
      -- byte turns IRQ12 and the mouse port off (75h), then D4 F4: the answer is FA, not an old
      -- packet byte (ps2.v as patched: a command to the mouse drops its queued bytes)
      to_mouse(x"F4");  expect("enable F4", x"FA");
      wait for 8 ms;
      steps(j_down, j_right, 6, true);
      wait for 3 ms;
      io_wr(4, x"60");
      wait for 2 us;
      io_wr(0, x"75");
      wait for 10 us;
      to_mouse(x"F4");  expect("command byte 75h, then D4 F4 with packets waiting: FA", x"FA");

      -- A 1351: driven paddle lines for G_DETECT_MS (10 ms here) make it one; its first reading
      -- moves nothing, the next ones by their difference. Its lines idle high: pin 1 is its
      -- right button (the Amiga steps above left it low)
      j_up   <= '1';
      j_left <= '1';
      to_mouse(x"F4");  expect("enable F4", x"FA");
      at1351(20, 40);
      wait for 5 ms;
      mode("1351: not yet after 5 ms", '0');
      wait for 7 ms;
      mode("1351: found after 10 ms", '1');
      nothing("1351: its first reading");
      at1351(25, 40);   expect_motion("1351: 5 right", 5, 0, "000");
      at1351(25, 43);   expect_motion("1351: 3 up", 0, 3, "000");
      at1351(21, 41);   expect_motion("1351: 4 left, 2 down", -4, -2, "000");
      at1351(60, 41);   expect_motion("1351: 25 left (60 = 21 - 25 mod 64)", -25, 0, "000");
      at1351(3, 41);    expect_motion("1351: 7 right across 63 -> 0", 7, 0, "000");
      at1351(3, 41, '1');
      nothing("1351: the noise bit");
      -- (a step on the quadrature lines makes it an Amiga mouse at once: tb_pc_mouse_pot.vhd 5.)
      j_up <= '0';      expect_motion("1351: right button (pin 1)", 0, 0, "010");
      j_up <= '1';      expect_motion("1351: right button up", 0, 0, "000");
      j_fire <= '0';    expect_motion("1351: left button", 0, 0, "001");
      j_fire <= '1';    expect_motion("1351: left button up", 0, 0, "000");
      flip <= "01";
      at1351(8, 41);    expect_motion("1351, x flipped: 5 left", -5, 0, "000");
      flip <= "10";
      at1351(8, 44);    expect_motion("1351, y flipped: 3 down", 0, -3, "000");
      flip <= "00";
      -- unplugged: open lines for five times as long, an Amiga mouse again
      pot_x <= x"00";
      pot_y <= x"00";
      wait for 30 ms;
      mode("1351: still after 30 ms open", '1');
      wait for 25 ms;
      mode("1351: gone after 50 ms open", '0');
      nothing("1351 gone: no motion");
      steps(j_down, j_right, 4, true);
      expect_motion("Amiga again: 4 right", 4, 0, "000");

      if errors = 0 then
         report "PASS: all checks" severity note;
      else
         report "FAILED: " & integer'image(errors) & " checks" severity error;
      end if;
      done <= true;
      wait;
   end process p_test;

end architecture sim;

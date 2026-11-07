----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- A mouse on the MEGA65's joystick port 1 as the PC's PS/2 mouse: a standard two-button PS/2
-- mouse (ID 00) to ps2_device.vhd and the PC's keyboard controller (ps2.v, an 8042). On MiSTer
-- the HPS plays the mouse; without one the BIOS's mouse functions (INT 15h C2xx, which
-- CuteMouse calls) wait for answers for good. So the mouse is always there, still when nothing
-- is plugged in.
--
-- The port: an Amiga mouse, or a USB mouse behind a mouSTer in Amiga mode, puts quadrature
-- pulses on the joystick lines: pin 1 (up) and pin 3 (left) are the vertical pair, pin 2
-- (down) and pin 4 (right) the horizontal one, pin 6 (fire) is the left button (MegaMac's
-- mac_mouse.vhd, with its directions, which were measured on the board). The framework hands
-- the lines over raw (M2M-UPSTREAM raw-joyports). The right button shorts pin 9 to ground,
-- which the MEGA65's paddle circuit cannot see (Megamiga, on an R3), so a held key stands in
-- for it: F13 (G_RMB_KEY), which the PC's keyboard does not use (on the R6 too: the right
-- button reads as an open line on a game port's pin 9, qmon.py joy, 2026-11-02). A mouSTer
-- (firmware 3.23.5313 on) with activepotlines=true drives pin 9 (right) and pin 5 (middle)
-- high while its buttons are up: a SID value of 0, open (255) while one is held (measured
-- 2026-11-07, clean 0 or 255). So a line that has read driven is a button from then on: open
-- = held (pin9_i, pin5_i); a plain Amiga mouse never drives them and has F13 only. Both lines
-- open for 2 s (the mouse unplugged, or a passive one plugged in) drop that until they read
-- driven again.
--
-- Or a Commodore 1351, or a mouSTer in its C64 mode (c1351): its position on the paddle lines
-- (POT X, POT Y; bits 6..1 of the SID's value, its x and y mod 64), the left button on pin 6,
-- the right one on pin 1 (up). The framework samples the paddles as a SID does (mouse_input.vhd)
-- and hands them over inverted, an open line 0. Lines that read mid-range (a SID value of
-- 4..251, as the MEGA65's mouse_input.vhdl takes a 1351's; a mouSTer's active button lines
-- read 0 or 255) for G_DETECT_MS make it a 1351, open for five times as long, or a step on
-- pins 2..4 (which a 1351 never moves), an Amiga mouse again; each new
-- reading (settled after the framework's per-bit crossing) moves it by the difference to the
-- last one, -32..31 an axis. flip_i reverses an axis (qmon.py c1351), should one run backwards.
--
-- The controller's commands: FF reset (FA AA 00), FE resend, F6 defaults, F5 disable, F4
-- enable, F3 sample rate and E8 resolution (a byte follows), F2 identify (FA 00), F0 remote
-- mode, EA stream mode, EB read data (FA and a packet), E9 status (FA and three bytes), E6/E7
-- scaling, EE wrap mode (echoes until EC or FF), EC; anything else asks to resend (FE). A
-- command drops the queued bytes. Enabled in stream mode, the mouse sends a packet at the
-- sample rate (default 100 per second) whenever it moved or a button changed: buttons and
-- signs, then x and y (y counts upwards), at most +/-255 per packet.
--
-- After any byte from the PC the mouse sends no packets for G_QUIET_MS (the motion adds up
-- and goes out after). The Bochs BIOS's mouse functions (INT 15h C2xx) turn the mouse port
-- off, send a command and take the next byte as its answer, and turn the port back on only
-- when that was FA. A packet in between (CuteMouse sends F4, then F3 and its byte, each
-- in its own call, tens of ms apart) made them give up with the port off: the mouse stayed
-- dead (The 7th Guest at its start, seen in the debug log), or a packet was cut short and
-- the rest read one byte off (the pointer jumping from edge to edge).
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_mouse is
   generic (
      G_CLK_HZ        : natural := 64_000_000;
      G_QUIET_MS      : natural := 300;            -- no packets this long after a PC byte
      G_RMB_KEY       : natural := 70;             -- F13 in M2M's key numbering
      G_DETECT_MS     : natural := 100             -- driven paddle lines this long: a 1351
   );
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- joystick port 1, raw
      up_n_i          : in  std_logic;              -- pin 1: V
      down_n_i        : in  std_logic;              -- pin 2: H
      left_n_i        : in  std_logic;              -- pin 3: VQ
      right_n_i       : in  std_logic;              -- pin 4: HQ
      fire_n_i        : in  std_logic;              -- pin 6: the left button

      -- the port's paddle lines as the framework gives them (inverted), a 1351's x and y:
      -- POT X on pin 9, POT Y on pin 5 (mega65.vhd's main_m1351_x, _y)
      pot_x_i         : in  std_logic_vector(7 downto 0) := x"00";
      pot_y_i         : in  std_logic_vector(7 downto 0) := x"00";
      flip_i          : in  std_logic_vector(1 downto 0) := "00";  -- a 1351's y, x reversed
      c1351_o         : out std_logic;              -- a 1351 on the port
      -- pin 9 and pin 5 as the framework gives them (inverted), never swapped: an Amiga mouse's
      -- right and middle buttons where it drives the lines (a mouSTer's activepotlines)
      pin9_i          : in  std_logic_vector(7 downto 0) := x"00";
      pin5_i          : in  std_logic_vector(7 downto 0) := x"00";

      -- the MEGA65 keyboard scan, for the right button's key
      key_num_i       : in  integer range 0 to 79;
      key_pressed_n_i : in  std_logic;

      tx_valid_o      : out std_logic;              -- to ps2_device
      tx_data_o       : out std_logic_vector(7 downto 0);
      tx_ready_i      : in  std_logic;
      rx_valid_i      : in  std_logic;              -- from ps2_device
      rx_data_i       : in  std_logic_vector(7 downto 0)
   );
end entity pc_mouse;

architecture synthesis of pc_mouse is

   -- the port: synchronisers, the last quadrature states, the motion not sent yet
   signal s1, s2     : std_logic_vector(4 downto 0) := (others => '1');
   signal hq, vq     : std_logic_vector(1 downto 0) := "11";
   signal acc_x      : signed(9 downto 0) := (others => '0');      -- right: +
   signal acc_y      : signed(9 downto 0) := (others => '0');      -- up: +
   signal rmb        : std_logic := '0';
   signal btn        : std_logic_vector(2 downto 0);                -- PS/2 order: middle, right, left
   signal btn_sent   : std_logic_vector(2 downto 0) := (others => '0');

   -- the byte queue to ps2_device
   type t_queue is array (0 to 7) of std_logic_vector(7 downto 0);
   signal q          : t_queue := (others => (others => '0'));
   signal q_wr       : unsigned(2 downto 0) := (others => '0');
   signal q_rd       : unsigned(2 downto 0) := (others => '0');
   signal q_cnt      : unsigned(3 downto 0) := (others => '0');
   signal last_tx    : std_logic_vector(7 downto 0) := x"00";

   -- the mouse as the PC set it up
   signal enabled    : std_logic := '0';
   signal remote     : std_logic := '0';
   signal wrap       : std_logic := '0';
   signal scale2     : std_logic := '0';
   signal rate       : std_logic_vector(7 downto 0) := x"64";      -- samples per second
   signal res        : std_logic_vector(1 downto 0) := "10";       -- 4 counts per mm
   signal arg_cmd    : std_logic_vector(7 downto 0) := x"00";      -- F3, E8: waits for its byte

   -- the sample period in ms (1000 / rate), counted in 1 ms ticks
   constant C_MS     : natural := G_CLK_HZ / 1000;
   signal ms_cnt     : natural range 0 to C_MS - 1 := 0;
   signal period     : unsigned(6 downto 0) := to_unsigned(10, 7);
   signal since      : unsigned(6 downto 0) := (others => '0');
   signal quiet      : natural range 0 to G_QUIET_MS := 0;           -- ms left without packets

   -- a 1351 (p_1351): the paddle values, synchronised, settled, the last one taken; whether the
   -- lines read driven and for how long; the motion of each new reading
   signal px1, px2   : std_logic_vector(7 downto 0) := x"00";
   signal py1, py2   : std_logic_vector(7 downto 0) := x"00";
   signal pv_x, pv_y : std_logic_vector(7 downto 0) := x"00";
   signal settle     : natural range 0 to 15 := 0;
   signal driven     : std_logic := '0';
   signal drv_ms     : natural range 0 to G_DETECT_MS := 0;
   signal open_ms    : natural range 0 to 5 * G_DETECT_MS := 0;
   signal c1351      : std_logic := '0';
   signal p_stb      : std_logic := '0';
   signal p_dx, p_dy : signed(5 downto 0) := (others => '0');
   signal amiga_step : std_logic := '0';                           -- pins 2..4 moved

   -- an Amiga mouse's active button lines (p_buttons): pin 9 and 5 synchronised and settled;
   -- whether each has read driven, and held open now; both open how long
   signal b9_1, b9_2 : std_logic_vector(7 downto 0) := x"00";
   signal b5_1, b5_2 : std_logic_vector(7 downto 0) := x"00";
   signal b_settle   : natural range 0 to 15 := 0;
   signal seen9      : std_logic := '0';
   signal seen5      : std_logic := '0';
   signal held9      : std_logic := '0';
   signal held5      : std_logic := '0';
   signal both_ms    : natural range 0 to 2000 := 0;

   type t_bytes is array (0 to 3) of std_logic_vector(7 downto 0);

   -- +1 / -1 / 0 for a Gray-code step from p to n (00 -> 01 -> 11 -> 10 -> 00 counts up)
   function step(p, n : std_logic_vector(1 downto 0)) return integer is
   begin
      if p = n then return 0; end if;
      case std_logic_vector'(p & n) is
         when "0001" | "0111" | "1110" | "1000" => return 1;
         when "0100" | "1101" | "1011" | "0010" => return -1;
         when others => return 0;                           -- both lines changed: lost a step
      end case;
   end function step;

   function clamp(v : signed(9 downto 0)) return signed is
   begin
      if v > 255 then return to_signed(255, 10);
      elsif v < -255 then return to_signed(-255, 10);
      else return v;
      end if;
   end function clamp;

   -- v moved by d, kept within +/-511
   function sat(v : signed(9 downto 0); d : signed(5 downto 0)) return signed is
      variable t : signed(10 downto 0);
   begin
      t := resize(v, 11) + resize(d, 11);
      if t > 511 then return to_signed(511, 10);
      elsif t < -511 then return to_signed(-511, 10);
      else return t(9 downto 0);
      end if;
   end function sat;

   function period_ms(r : std_logic_vector(7 downto 0)) return unsigned is
   begin
      case to_integer(unsigned(r)) is
         when 10     => return to_unsigned(100, 7);
         when 20     => return to_unsigned(50, 7);
         when 40     => return to_unsigned(25, 7);
         when 60     => return to_unsigned(16, 7);
         when 80     => return to_unsigned(12, 7);
         when 200    => return to_unsigned(5, 7);
         when others => return to_unsigned(10, 7);    -- 100, and anything odd
      end case;
   end function period_ms;

begin

   tx_valid_o <= '1' when q_cnt /= 0 else '0';
   tx_data_o  <= q(to_integer(q_rd));

   -- middle: an Amiga mouse's pin 5; right: F13, a 1351's pin 1, or an Amiga mouse's pin 9
   btn     <= (not c1351 and held5) &
              (rmb or (c1351 and not s2(0)) or (not c1351 and held9)) & not s2(4);
   c1351_o <= c1351;

   -- A 1351: the paddle values settle (the framework crosses them bit by bit), a new one moves
   -- the mouse by the difference of bits 6..1 to the last one; the lines decide the mode
   p_1351 : process (clk_i)
      variable v_sx, v_sy : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         p_stb <= '0';
         px1 <= pot_x_i;
         px2 <= px1;
         py1 <= pot_y_i;
         py2 <= py1;
         if px1 /= px2 or py1 /= py2 then
            settle <= 0;
         elsif settle /= 15 then
            settle <= settle + 1;
         end if;

         if settle = 8 and (px2 /= pv_x or py2 /= pv_y) then
            pv_x  <= px2;
            pv_y  <= py2;
            v_sx  := not px2;                    -- the SID's values
            v_sy  := not py2;
            p_dx  <= signed(unsigned(v_sx(6 downto 1)) - unsigned(not pv_x(6 downto 1)));
            p_dy  <= signed(unsigned(v_sy(6 downto 1)) - unsigned(not pv_y(6 downto 1)));
            if flip_i(0) = '1' then
               p_dx <= signed(unsigned(not pv_x(6 downto 1)) - unsigned(v_sx(6 downto 1)));
            end if;
            if flip_i(1) = '1' then
               p_dy <= signed(unsigned(not pv_y(6 downto 1)) - unsigned(v_sy(6 downto 1)));
            end if;
            if (unsigned(v_sx) >= 4 and unsigned(v_sx) <= 251) or
               (unsigned(v_sy) >= 4 and unsigned(v_sy) <= 251) then
               driven <= '1';
               p_stb  <= c1351 and driven;       -- (not from or to open lines: no jump)
            else
               driven <= '0';
            end if;
         end if;

         if ms_cnt = C_MS - 1 then
            if driven = '1' then
               open_ms <= 0;
               if drv_ms /= G_DETECT_MS then
                  drv_ms <= drv_ms + 1;
               else
                  c1351 <= '1';
               end if;
            else
               drv_ms <= 0;
               if open_ms /= 5 * G_DETECT_MS then
                  open_ms <= open_ms + 1;
               else
                  c1351 <= '0';
               end if;
            end if;
         end if;

         if amiga_step = '1' then                 -- pins 2..4 moved: an Amiga mouse
            c1351  <= '0';
            drv_ms <= 0;
         end if;

         if rst_i = '1' then
            c1351  <= '0';
            drv_ms <= 0;
         end if;
      end if;
   end process p_1351;

   -- An Amiga mouse's right and middle buttons on pins 9 and 5 where it drives them (a mouSTer
   -- with activepotlines): SID value 63 or less = driven (up), 192 or more = open (held), once
   -- the line has read driven; both open for 2 s and the lines count as passive again
   p_buttons : process (clk_i)
      variable v_9, v_5 : unsigned(7 downto 0);
   begin
      if rising_edge(clk_i) then
         b9_1 <= pin9_i;
         b9_2 <= b9_1;
         b5_1 <= pin5_i;
         b5_2 <= b5_1;
         if b9_1 /= b9_2 or b5_1 /= b5_2 then
            b_settle <= 0;
         elsif b_settle /= 15 then
            b_settle <= b_settle + 1;
         end if;
         if b_settle = 8 then
            v_9 := unsigned(not b9_2);               -- the SID's values
            v_5 := unsigned(not b5_2);
            if v_9 <= 63 then
               seen9 <= '1';
               held9 <= '0';
            elsif v_9 >= 192 then
               held9 <= seen9;
            end if;
            if v_5 <= 63 then
               seen5 <= '1';
               held5 <= '0';
            elsif v_5 >= 192 then
               held5 <= seen5;
            end if;
         end if;
         if ms_cnt = C_MS - 1 then
            if held9 = '1' and held5 = '1' then
               if both_ms /= 2000 then
                  both_ms <= both_ms + 1;
               else
                  seen9 <= '0';                     -- unplugged, or a passive mouse now
                  seen5 <= '0';
                  held9 <= '0';
                  held5 <= '0';
               end if;
            else
               both_ms <= 0;
            end if;
         end if;
         if rst_i = '1' then
            seen9 <= '0';
            seen5 <= '0';
            held9 <= '0';
            held5 <= '0';
            both_ms <= 0;
         end if;
      end if;
   end process p_buttons;

   p_mouse : process (clk_i)
      variable v_b     : t_bytes;
      variable v_n     : natural range 0 to 4;
      variable v_flush : boolean;
      variable v_pop   : boolean;
      variable v_h     : std_logic_vector(1 downto 0);
      variable v_v     : std_logic_vector(1 downto 0);
      variable v_x     : signed(9 downto 0);
      variable v_y     : signed(9 downto 0);
      variable v_qbase : unsigned(2 downto 0);
      variable v_defaults : boolean;

      procedure add(b : std_logic_vector(7 downto 0)) is
      begin
         v_b(v_n) := b;
         v_n      := v_n + 1;
      end procedure add;

      -- a packet of the motion so far (at most +/-255 an axis; the rest waits for the next)
      procedure packet is
         variable v_px, v_py : signed(9 downto 0);
      begin
         v_px := clamp(v_x);
         v_py := clamp(v_y);
         add("00" & std_logic_vector(v_py(9 downto 9)) & std_logic_vector(v_px(9 downto 9)) &
             '1' & btn);
         add(std_logic_vector(v_px(7 downto 0)));
         add(std_logic_vector(v_py(7 downto 0)));
         v_x := v_x - v_px;
         v_y := v_y - v_py;
         btn_sent <= btn;
      end procedure packet;

   begin
      if rising_edge(clk_i) then
         v_n        := 0;
         v_flush    := false;
         v_pop      := false;
         v_defaults := false;

         -- The port: count the quadrature steps (MegaMac's directions; y turned to count up)
         s1  <= fire_n_i & right_n_i & left_n_i & down_n_i & up_n_i;
         s2  <= s1;
         amiga_step <= '0';
         if s2(3 downto 1) /= s1(3 downto 1) then    -- pins 4, 3, 2 moved: an Amiga mouse
            amiga_step <= '1';
         end if;
         v_h := s2(1) & s2(3);                -- H, HQ
         v_v := s2(0) & s2(2);                -- V, VQ
         v_x := acc_x;
         v_y := acc_y;
         if c1351 = '0' then
            if step(hq, v_h) = 1 and v_x > -511 then v_x := v_x - 1;
            elsif step(hq, v_h) = -1 and v_x < 511 then v_x := v_x + 1; end if;
            if step(vq, v_v) = 1 and v_y < 511 then v_y := v_y + 1;
            elsif step(vq, v_v) = -1 and v_y > -511 then v_y := v_y - 1; end if;
         elsif p_stb = '1' then                  -- a 1351: its reading's motion, up to 511
            v_x := sat(v_x, p_dx);
            v_y := sat(v_y, p_dy);
         end if;
         hq <= v_h;
         vq <= v_v;

         -- The right button's key
         if key_num_i = G_RMB_KEY then
            rmb <= not key_pressed_n_i;
         end if;

         -- 1 ms ticks for the sample period
         if ms_cnt = C_MS - 1 then
            ms_cnt <= 0;
            if since /= 127 then
               since <= since + 1;
            end if;
            if quiet /= 0 then
               quiet <= quiet - 1;
            end if;
         else
            ms_cnt <= ms_cnt + 1;
         end if;

         -- The device took a byte
         if q_cnt /= 0 and tx_ready_i = '1' then
            last_tx <= q(to_integer(q_rd));
            q_rd    <= q_rd + 1;
            v_pop   := true;
         end if;

         if rx_valid_i = '1' then
            -- A command: it drops the queued bytes, and the packets wait
            v_flush := true;
            quiet   <= G_QUIET_MS;
            if wrap = '1' and rx_data_i /= x"EC" and rx_data_i /= x"FF" then
               add(rx_data_i);                   -- wrap mode: the echo
            elsif arg_cmd /= x"00" and unsigned(rx_data_i) < 16#E6# then
               add(x"FA");
               if arg_cmd = x"F3" then
                  rate   <= rx_data_i;
                  period <= period_ms(rx_data_i);
               else
                  res <= rx_data_i(1 downto 0);
               end if;
               arg_cmd <= x"00";
            else
               arg_cmd <= x"00";
               case rx_data_i is
                  when x"FF" =>                  -- reset: self-test passed, ID 00
                     add(x"FA");
                     add(x"AA");
                     add(x"00");
                     v_defaults := true;
                     remote     <= '0';
                     wrap       <= '0';
                  when x"FE" =>                  -- resend
                     add(last_tx);
                  when x"F6" | x"F5" =>          -- defaults; reporting off
                     add(x"FA");
                     v_defaults := true;
                  when x"F4" =>                  -- reporting on
                     add(x"FA");
                     enabled <= '1';
                     v_x := (others => '0');
                     v_y := (others => '0');
                  when x"F3" | x"E8" =>          -- a byte follows
                     add(x"FA");
                     arg_cmd <= rx_data_i;
                  when x"F2" =>                  -- identify: a standard PS/2 mouse
                     add(x"FA");
                     add(x"00");
                  when x"F0" =>                  -- remote mode
                     add(x"FA");
                     remote <= '1';
                  when x"EA" =>                  -- stream mode
                     add(x"FA");
                     remote <= '0';
                  when x"EB" =>                  -- read data
                     add(x"FA");
                     packet;
                  when x"E9" =>                  -- status: mode, reporting, scaling, buttons
                     add(x"FA");
                     add('0' & remote & enabled & scale2 & '0' & btn(0) & btn(2) & btn(1));
                     add("000000" & res);
                     add(rate);
                  when x"E7" =>                  -- scaling 2:1
                     add(x"FA");
                     scale2 <= '1';
                  when x"E6" =>                  -- scaling 1:1
                     add(x"FA");
                     scale2 <= '0';
                  when x"EE" =>                  -- wrap mode
                     add(x"FA");
                     wrap <= '1';
                  when x"EC" =>                  -- wrap mode off
                     add(x"FA");
                     wrap <= '0';
                  when others =>
                     add(x"FE");
               end case;
            end if;
            if v_defaults then
               enabled <= '0';
               scale2  <= '0';
               rate    <= x"64";
               period  <= to_unsigned(10, 7);
               res     <= "10";
               v_x     := (others => '0');
               v_y     := (others => '0');
            end if;

         elsif enabled = '1' and remote = '0' and wrap = '0' and q_cnt = 0 and since >= period and
               quiet = 0 and
               (v_x /= 0 or v_y /= 0 or btn /= btn_sent) then
            -- A packet at the sample rate, when there is news
            packet;
            since <= (others => '0');
         end if;

         acc_x <= v_x;
         acc_y <= v_y;

         -- Into the queue (a command first empties it; a byte the device took this cycle went)
         if v_flush then
            if v_pop then
               v_qbase := q_rd + 1;
            else
               v_qbase := q_rd;
            end if;
            for i in 0 to 3 loop
               if i < v_n then
                  q(to_integer(v_qbase + i)) <= v_b(i);
               end if;
            end loop;
            q_rd  <= v_qbase;
            q_wr  <= v_qbase + v_n;
            q_cnt <= to_unsigned(v_n, 4);
         else
            for i in 0 to 3 loop
               if i < v_n then
                  q(to_integer(q_wr + i)) <= v_b(i);
               end if;
            end loop;
            q_wr <= q_wr + v_n;
            if v_pop then
               q_cnt <= q_cnt + v_n - 1;
            else
               q_cnt <= q_cnt + v_n;
            end if;
         end if;

         if rst_i = '1' then
            q_wr     <= (others => '0');
            q_rd     <= (others => '0');
            q_cnt    <= (others => '0');
            enabled  <= '0';
            remote   <= '0';
            wrap     <= '0';
            arg_cmd  <= x"00";
            acc_x    <= (others => '0');
            acc_y    <= (others => '0');
            btn_sent <= (others => '0');
         end if;
      end if;
   end process p_mouse;

end architecture synthesis;

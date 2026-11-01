----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The MEGA65 keyboard as a PC's PS/2 keyboard: scan code set 2 to ps2_device.vhd, which the
-- PC's keyboard controller (ps2.v, an 8042) translates to set 1 as a real one does. On MiSTer
-- the HPS plays the keyboard; here this module does, answering the controller's commands too.
--
-- The framework scans the 80 MEGA65 keys (key_num_i runs 0..79 at 1 kHz with
-- key_pressed_n_i, M2M's numbering as in Megamac's mac_keyboard.vhd). Every change of a mapped
-- key becomes an event in a 32-entry FIFO: a full FIFO drops a press, never a release (a lost
-- release is a key the PC holds down for good); then the release overwrites the newest entry.
-- Each event becomes its scan codes in a 16-byte queue for ps2_device.
--
-- The keys by their labels: letters and digits as on a PC, the symbols as on the MEGA65's
-- keycaps (: and Shift+: = [, ; and Shift+; = ], @, *, +, -, =, Shift+2 = ", Shift+6 = &,
-- Shift+7 = ', Shift+8 = (, Shift+9 = )): each table entry says whether the PC's Shift must be
-- pressed or released for it (M_DOWN, M_UP), and the PC sees that while the key is down. The
-- PC's symbols without a keycap: GBP = \ (Shift: |), arrow up = ^ (Shift: ~), arrow left = `,
-- Shift+- = _, Shift+@ = {, Shift+* = }.
--   RUN/STOP and ESC = Esc, CTRL = Ctrl, ALT = Alt, NO SCROLL = Scroll Lock, RESTORE = Delete,
--   INST/DEL = Backspace, CLR/HOME = Home, the cursor keys = the arrows.
--   F1 F3 F5 F7 F9 F11 = F1 F3 F5 F7 F9 F11; with Shift F2 F4 F6 F8 F10 F12, as on their
--   keycaps: the PC sees the Shift released while that key is down. The same way Shift+INST/DEL
--   = Insert and Shift+CLR/HOME = End. F13 (the mouse's right button, pc_mouse.vhd) and HELP
--   (the menu) send nothing.
--   MEGA is a Fn key: MEGA+cursor up/down = Page Up/Down, MEGA+cursor left/right = Home/End,
--   MEGA+INST/DEL = Delete, MEGA+TAB = Caps Lock.
--   CAPS LOCK sends nothing: it is the turbo switch (mega65.vhd: down = the CPU at 33 MHz).
--   SHIFT LOCK holds the left Shift, as on the MEGA65.
-- A held key repeats (typematic, default 500 ms then 10.9 per second; command F3 sets it);
-- Shift, Ctrl, Alt, MEGA and CAPS LOCK do not.
--
-- The controller's commands: FF reset (FA AA), FE resend, F6 defaults, F5 disable, F4 enable,
-- F3 typematic, F2 identify (FA AB 83), F0 scan code set (set 2 only), EE echo, ED LEDs (there
-- are none to set); anything else is acknowledged (FA). A command drops the queued scan codes.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_keyboard is
   generic (
      G_CLK_HZ        : natural := 64_000_000
   );
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      key_num_i       : in  integer range 0 to 79;
      key_pressed_n_i : in  std_logic;

      tx_valid_o      : out std_logic;              -- to ps2_device
      tx_data_o       : out std_logic_vector(7 downto 0);
      tx_ready_i      : in  std_logic;
      rx_valid_i      : in  std_logic;              -- from ps2_device
      rx_data_i       : in  std_logic_vector(7 downto 0)
   );
end entity pc_keyboard;

architecture synthesis of pc_keyboard is

   -- A scan code: bits 10..9 = what the PC's Shift must be while the key is down (M_AS: as the
   -- shift keys are, M_DOWN: pressed, M_UP: released), bit 8 = the E0 prefix, 7..0 the code;
   -- all zeros = none
   subtype t_code is std_logic_vector(10 downto 0);
   type t_map is array (0 to 79) of t_code;
   constant M_AS   : std_logic_vector(1 downto 0) := "00";
   constant M_DOWN : std_logic_vector(1 downto 0) := "01";
   constant M_UP   : std_logic_vector(1 downto 0) := "10";
   constant C_NONE : t_code := M_AS & "0" & x"00";

   constant K_LSHIFT : natural := 15;
   constant K_RSHIFT : natural := 52;
   constant K_CTRL   : natural := 58;
   constant K_MEGA   : natural := 61;
   constant K_ALT    : natural := 66;
   constant K_CAPS   : natural := 72;

   constant C_BASE : t_map := (
       0 => M_AS & "0" & x"66",   -- INST/DEL   -> Backspace
       1 => M_AS & "0" & x"5A",   -- RETURN     -> Enter
       2 => M_AS & "1" & x"74",   -- cursor right
       3 => M_AS & "0" & x"83",   -- F7
       4 => M_AS & "0" & x"05",   -- F1
       5 => M_AS & "0" & x"04",   -- F3
       6 => M_AS & "0" & x"03",   -- F5
       7 => M_AS & "1" & x"72",   -- cursor down
       8 => M_AS & "0" & x"26",   -- 3
       9 => M_AS & "0" & x"1D",   -- W
      10 => M_AS & "0" & x"1C",   -- A
      11 => M_AS & "0" & x"25",   -- 4
      12 => M_AS & "0" & x"1A",   -- Z
      13 => M_AS & "0" & x"1B",   -- S
      14 => M_AS & "0" & x"24",   -- E
      15 => M_AS & "0" & x"12",   -- left shift
      16 => M_AS & "0" & x"2E",   -- 5
      17 => M_AS & "0" & x"2D",   -- R
      18 => M_AS & "0" & x"23",   -- D
      19 => M_AS & "0" & x"36",   -- 6
      20 => M_AS & "0" & x"21",   -- C
      21 => M_AS & "0" & x"2B",   -- F
      22 => M_AS & "0" & x"2C",   -- T
      23 => M_AS & "0" & x"22",   -- X
      24 => M_AS & "0" & x"3D",   -- 7
      25 => M_AS & "0" & x"35",   -- Y
      26 => M_AS & "0" & x"34",   -- G
      27 => M_AS & "0" & x"3E",   -- 8
      28 => M_AS & "0" & x"32",   -- B
      29 => M_AS & "0" & x"33",   -- H
      30 => M_AS & "0" & x"3C",   -- U
      31 => M_AS & "0" & x"2A",   -- V
      32 => M_AS & "0" & x"46",   -- 9
      33 => M_AS & "0" & x"43",   -- I
      34 => M_AS & "0" & x"3B",   -- J
      35 => M_AS & "0" & x"45",   -- 0
      36 => M_AS & "0" & x"3A",   -- M
      37 => M_AS & "0" & x"42",   -- K
      38 => M_AS & "0" & x"44",   -- O
      39 => M_AS & "0" & x"31",   -- N
      40 => M_DOWN & "0" & x"55",   -- +          -> Shift+=
      41 => M_AS & "0" & x"4D",   -- P
      42 => M_AS & "0" & x"4B",   -- L
      43 => M_AS   & "0" & x"4E",   -- -
      44 => M_AS & "0" & x"49",   -- .
      45 => M_DOWN & "0" & x"4C",   -- :          -> Shift+;
      46 => M_DOWN & "0" & x"1E",   -- @          -> Shift+2
      47 => M_AS & "0" & x"41",   -- ,
      48 => M_UP   & "0" & x"5D",   -- GBP        -> \
      49 => M_DOWN & "0" & x"3E",   -- *          -> Shift+8
      50 => M_UP   & "0" & x"4C",   -- ;
      51 => M_AS & "1" & x"6C",   -- CLR/HOME   -> Home
      52 => M_AS & "0" & x"59",   -- right shift
      53 => M_UP   & "0" & x"55",   -- =
      54 => M_DOWN & "0" & x"36",   -- arrow up   -> ^ (Shift+6)
      55 => M_AS & "0" & x"4A",   -- /
      56 => M_AS & "0" & x"16",   -- 1
      57 => M_UP   & "0" & x"0E",   -- arrow left -> `
      58 => M_AS & "0" & x"14",   -- CTRL       -> left Ctrl
      59 => M_AS & "0" & x"1E",   -- 2
      60 => M_AS & "0" & x"29",   -- SPACE
      62 => M_AS & "0" & x"15",   -- Q
      63 => M_AS & "0" & x"76",   -- RUN/STOP   -> Esc
      64 => M_AS & "0" & x"7E",   -- NO SCROLL  -> Scroll Lock
      65 => M_AS & "0" & x"0D",   -- TAB
      66 => M_AS & "0" & x"11",   -- ALT        -> left Alt
      68 => M_AS & "0" & x"01",   -- F9
      69 => M_AS & "0" & x"78",   -- F11
      71 => M_AS & "0" & x"76",   -- ESC
      72 => C_NONE,                -- CAPS LOCK: the turbo switch (mega65.vhd)
      73 => M_AS & "1" & x"75",   -- cursor up
      74 => M_AS & "1" & x"6B",   -- cursor left
      75 => M_AS & "1" & x"71",   -- RESTORE    -> Delete
      others => C_NONE);   -- 61 MEGA (Fn), 67 HELP (the menu), 70 F13

   -- With Shift, as on the keycaps (the keys missing here: as the base table, with the PC's
   -- Shift); the symbols a PC has and the MEGA65's keycaps lack are on keys whose shifted
   -- keycap is a graphic: Shift+- _, Shift+@ {, Shift+* }, Shift+GBP |, Shift+arrow up ~
   constant C_SHIFT : t_map := (
       0 => M_UP   & "1" & x"70",   -- INST       -> Insert
       3 => M_UP   & "0" & x"0A",   -- F8
       4 => M_UP   & "0" & x"06",   -- F2
       5 => M_UP   & "0" & x"0C",   -- F4
       6 => M_UP   & "0" & x"0B",   -- F6
      19 => M_DOWN & "0" & x"3D",   -- 6: &       -> Shift+7
      24 => M_UP   & "0" & x"52",   -- 7: '
      27 => M_DOWN & "0" & x"46",   -- 8: (       -> Shift+9
      32 => M_DOWN & "0" & x"45",   -- 9: )       -> Shift+0
      35 => M_UP   & "0" & x"45",   -- 0 (no symbol on its keycap)
      40 => M_DOWN & "0" & x"55",   -- +          -> Shift+=
      43 => M_DOWN & "0" & x"4E",   -- -: _       -> Shift+-
      45 => M_UP   & "0" & x"54",   -- :: [
      46 => M_DOWN & "0" & x"54",   -- @: {       -> Shift+[
      48 => M_DOWN & "0" & x"5D",   -- GBP: |     -> Shift+\
      49 => M_DOWN & "0" & x"5B",   -- *: }       -> Shift+]
      50 => M_UP   & "0" & x"5B",   -- ;: ]
      51 => M_UP   & "1" & x"69",   -- CLR        -> End
      53 => M_UP   & "0" & x"55",   -- =
      54 => M_DOWN & "0" & x"0E",   -- arrow up: ~ -> Shift+`
      57 => M_UP   & "0" & x"0E",   -- arrow left -> `
      59 => M_DOWN & "0" & x"52",   -- 2: "       -> Shift+'
      68 => M_UP   & "0" & x"09",   -- F10
      69 => M_UP   & "0" & x"07",   -- F12
      others => C_NONE);

   -- With MEGA (Fn)
   constant C_FN : t_map := (
       0 => M_AS & "1" & x"71",   -- Delete
       2 => M_AS & "1" & x"69",   -- End
       7 => M_AS & "1" & x"7A",   -- Page Down
      73 => M_AS & "1" & x"7D",   -- Page Up
      65 => M_AS & "0" & x"58",   -- Caps Lock (MEGA+TAB)
      74 => M_AS & "1" & x"6C",   -- Home
      others => C_NONE);

   -- Which table a held key's make came from, so that its break matches
   type t_var is array (0 to 79) of std_logic_vector(1 downto 0);
   constant V_NONE  : std_logic_vector(1 downto 0) := "00";
   constant V_BASE  : std_logic_vector(1 downto 0) := "01";
   constant V_SHIFT : std_logic_vector(1 downto 0) := "10";
   constant V_FN    : std_logic_vector(1 downto 0) := "11";

   function lookup(num : natural; var : std_logic_vector(1 downto 0)) return t_code is
   begin
      case var is
         when V_BASE  => return C_BASE(num);
         when V_SHIFT => return C_SHIFT(num);
         when V_FN    => return C_FN(num);
         when others  => return C_NONE;
      end case;
   end function lookup;

   -- The matrix and its event FIFO: bit 7 = pressed, bits 6..0 = the key
   signal state      : std_logic_vector(79 downto 0) := (others => '0');
   signal num_q      : integer range 0 to 79 := 0;
   signal pressed_q  : std_logic := '0';
   type t_ev_fifo is array (0 to 31) of std_logic_vector(7 downto 0);
   signal ev_fifo    : t_ev_fifo := (others => (others => '0'));
   signal ev_wr      : unsigned(4 downto 0) := (others => '0');
   signal ev_rd      : unsigned(4 downto 0) := (others => '0');
   signal ev_cnt     : unsigned(5 downto 0) := (others => '0');
   signal ev_pop     : std_logic;

   -- The byte queue to ps2_device
   type t_queue is array (0 to 15) of std_logic_vector(7 downto 0);
   signal q          : t_queue := (others => (others => '0'));
   signal q_wr       : unsigned(3 downto 0) := (others => '0');
   signal q_rd       : unsigned(3 downto 0) := (others => '0');
   signal q_cnt      : unsigned(4 downto 0) := (others => '0');
   signal last_tx    : std_logic_vector(7 downto 0) := x"AA";

   -- The keyboard's state as the PC knows it
   signal scan_en    : std_logic := '1';
   signal arg_cmd    : std_logic_vector(7 downto 0) := x"00";   -- ED, F3, F0: waits for its byte
   signal typematic  : std_logic_vector(6 downto 0) := "0101011";  -- 2B: 500 ms, 10.9/s
   signal phys_l     : std_logic := '0';       -- the shifts as the events have them
   signal phys_r     : std_logic := '0';
   signal phys_mega  : std_logic := '0';
   signal sent_l     : std_logic := '0';       -- the shifts as the PC has them
   signal sent_r     : std_logic := '0';
   signal supp       : integer range 0 to 80 := 80;   -- the key that holds the shifts back; 80 none
   signal key_var    : t_var := (others => V_NONE);

   -- Typematic: 240 Hz ticks
   constant C_TICK   : natural := G_CLK_HZ / 240;
   signal tick_cnt   : natural range 0 to C_TICK - 1 := 0;
   signal rep_on     : std_logic := '0';
   signal rep_code   : t_code := C_NONE;
   signal rep_cnt    : unsigned(9 downto 0) := (others => '0');
   signal rep_due    : std_logic := '0';

   type t_bytes is array (0 to 7) of std_logic_vector(7 downto 0);

   -- The typematic delay, 250 ms * (D + 1), in 240 Hz ticks minus one
   function delay_ticks(d : std_logic_vector(1 downto 0)) return unsigned is
   begin
      case d is
         when "00"   => return to_unsigned(59, 10);
         when "01"   => return to_unsigned(119, 10);
         when "10"   => return to_unsigned(179, 10);
         when others => return to_unsigned(239, 10);
      end case;
   end function delay_ticks;

begin

   tx_valid_o <= '1' when q_cnt /= 0 else '0';
   tx_data_o  <= q(to_integer(q_rd));

   ---------------------------------------------------------------------------------------------
   -- The matrix: one event per change of a key that does something
   ---------------------------------------------------------------------------------------------

   p_scan : process (clk_i)
      variable v_push : std_logic;
   begin
      if rising_edge(clk_i) then
         v_push    := '0';
         num_q     <= key_num_i;
         pressed_q <= not key_pressed_n_i;
         if pressed_q /= state(num_q) and (C_BASE(num_q) /= C_NONE or num_q = K_MEGA) then
            if ev_cnt /= 32 then
               ev_fifo(to_integer(ev_wr)) <= pressed_q & std_logic_vector(to_unsigned(num_q, 7));
               v_push := '1';
            elsif pressed_q = '0' then
               ev_fifo(to_integer(ev_wr - 1)) <= '0' & std_logic_vector(to_unsigned(num_q, 7));
            end if;
         end if;
         state(num_q) <= pressed_q;
         if v_push = '1' then
            ev_wr <= ev_wr + 1;
         end if;
         if ev_pop = '1' then
            ev_rd <= ev_rd + 1;
         end if;
         if v_push = '1' and ev_pop = '0' then
            ev_cnt <= ev_cnt + 1;
         elsif v_push = '0' and ev_pop = '1' then
            ev_cnt <= ev_cnt - 1;
         end if;
         if rst_i = '1' then
            ev_wr  <= (others => '0');
            ev_rd  <= (others => '0');
            ev_cnt <= (others => '0');
         end if;
      end if;
   end process p_scan;

   ---------------------------------------------------------------------------------------------
   -- Commands, events and typematic repeats into the byte queue
   ---------------------------------------------------------------------------------------------

   p_keyboard : process (clk_i)
      variable v_b     : t_bytes;
      variable v_n     : natural range 0 to 8;
      variable v_flush : boolean;
      variable v_pop   : boolean;
      variable v_ev    : std_logic_vector(7 downto 0);
      variable v_num   : natural range 0 to 127;
      variable v_var   : std_logic_vector(1 downto 0);
      variable v_code  : t_code;
      variable v_defaults : boolean;
      variable v_qbase : unsigned(3 downto 0);

      procedure add(b : std_logic_vector(7 downto 0)) is
      begin
         v_b(v_n) := b;
         v_n      := v_n + 1;
      end procedure add;

      procedure send_make(c : t_code) is
      begin
         if c(8) = '1' then
            add(x"E0");
         end if;
         add(c(7 downto 0));
      end procedure send_make;

      procedure send_break(c : t_code) is
      begin
         if c(8) = '1' then
            add(x"E0");
         end if;
         add(x"F0");
         add(c(7 downto 0));
      end procedure send_break;

   begin
      if rising_edge(clk_i) then
         v_n        := 0;
         v_flush    := false;
         v_pop      := false;
         v_defaults := false;
         ev_pop     <= '0';

         -- The 240 Hz tick: typematic delay and period
         if tick_cnt = C_TICK - 1 then
            tick_cnt <= 0;
            if rep_on = '1' then
               if rep_cnt = 0 then
                  rep_due <= '1';
                  -- (8 + A) * 2^B ticks of 4.17 ms
                  rep_cnt <= shift_left(resize(unsigned('1' & typematic(2 downto 0)), 10),
                                        to_integer(unsigned(typematic(4 downto 3)))) - 1;
               else
                  rep_cnt <= rep_cnt - 1;
               end if;
            end if;
         else
            tick_cnt <= tick_cnt + 1;
         end if;

         -- The device took a byte
         if q_cnt /= 0 and tx_ready_i = '1' then
            last_tx <= q(to_integer(q_rd));
            q_rd    <= q_rd + 1;
            v_pop   := true;
         end if;

         if rx_valid_i = '1' then
            -- A command: it drops the queued scan codes
            v_flush := true;
            if arg_cmd /= x"00" and unsigned(rx_data_i) < 16#ED# then
               add(x"FA");
               if arg_cmd = x"F3" then
                  typematic <= rx_data_i(6 downto 0);
               elsif arg_cmd = x"F0" and rx_data_i = x"00" then
                  add(x"02");                    -- scan code set 2
               end if;
               arg_cmd <= x"00";
            else
               arg_cmd <= x"00";
               case rx_data_i is
                  when x"FF" =>                  -- reset: self-test passed
                     add(x"FA");
                     add(x"AA");
                     v_defaults := true;
                     scan_en    <= '1';
                  when x"FE" =>                  -- resend
                     add(last_tx);
                  when x"F6" =>                  -- defaults
                     add(x"FA");
                     v_defaults := true;
                  when x"F5" =>                  -- defaults, scanning off
                     add(x"FA");
                     v_defaults := true;
                     scan_en    <= '0';
                  when x"F4" =>                  -- scanning on
                     add(x"FA");
                     scan_en <= '1';
                  when x"F2" =>                  -- identify: an MF2 keyboard
                     add(x"FA");
                     add(x"AB");
                     add(x"83");
                  when x"EE" =>                  -- echo
                     add(x"EE");
                  when x"F3" | x"F0" | x"ED" =>  -- a byte follows
                     add(x"FA");
                     arg_cmd <= rx_data_i;
                  when others =>
                     add(x"FA");
               end case;
            end if;
            if v_defaults then
               typematic <= "0101011";
               sent_l    <= '0';
               sent_r    <= '0';
               supp      <= 80;
               key_var   <= (others => V_NONE);
               rep_on    <= '0';
               rep_due   <= '0';
            end if;

         elsif ev_cnt /= 0 and ev_pop = '0' and q_cnt <= 8 then
            -- A key event (ev_pop = '0': the FIFO's count is a cycle behind a pop)
            v_ev  := ev_fifo(to_integer(ev_rd));
            v_num := to_integer(unsigned(v_ev(6 downto 0)));
            ev_pop <= '1';
            if v_num = K_LSHIFT or v_num = K_RSHIFT then
               if v_num = K_LSHIFT then
                  phys_l <= v_ev(7);
               else
                  phys_r <= v_ev(7);
               end if;
               if v_ev(7) = '1' then
                  rep_on <= '0';
                  if scan_en = '1' and supp = 80 then
                     send_make(C_BASE(v_num));
                     if v_num = K_LSHIFT then sent_l <= '1'; else sent_r <= '1'; end if;
                  end if;
               elsif (v_num = K_LSHIFT and sent_l = '1') or (v_num = K_RSHIFT and sent_r = '1') then
                  send_break(C_BASE(v_num));
                  if v_num = K_LSHIFT then sent_l <= '0'; else sent_r <= '0'; end if;
               end if;
            elsif v_num = K_MEGA then
               phys_mega <= v_ev(7);
            elsif v_num = K_CAPS then
               rep_on <= '0';                    -- the turbo switch: nothing to the PC
            elsif v_ev(7) = '1' then
               -- A press: Fn first, then the keycap's shifted meaning, else the key
               if phys_mega = '1' and C_FN(v_num) /= C_NONE then
                  v_var := V_FN;
               elsif (phys_l = '1' or phys_r = '1') and C_SHIFT(v_num) /= C_NONE then
                  v_var := V_SHIFT;
               else
                  v_var := V_BASE;
               end if;
               v_code := lookup(v_num, v_var);
               key_var(v_num) <= v_var;
               rep_on <= '0';
               rep_due <= '0';
               if scan_en = '1' then
                  -- the PC's Shift as the key wants it, until its release (supp)
                  if v_code(10 downto 9) = M_UP and supp = 80 then
                     if sent_l = '1' then send_break(C_BASE(K_LSHIFT)); end if;
                     if sent_r = '1' then send_break(C_BASE(K_RSHIFT)); end if;
                     sent_l <= '0';
                     sent_r <= '0';
                     supp   <= v_num;
                  elsif v_code(10 downto 9) = M_DOWN and supp = 80 then
                     if sent_l = '0' and sent_r = '0' then
                        send_make(C_BASE(K_LSHIFT));
                        sent_l <= '1';
                     end if;
                     supp <= v_num;
                  end if;
                  send_make(v_code);
                  if v_num /= K_CTRL and v_num /= K_ALT then
                     rep_on   <= '1';
                     rep_code <= v_code;
                     -- the delay: 250 ms * (D + 1) = 60 * (D + 1) ticks
                     rep_cnt  <= delay_ticks(typematic(6 downto 5));
                  end if;
               end if;
            else
               -- A release: the code its press sent
               v_code := lookup(v_num, key_var(v_num));
               key_var(v_num) <= V_NONE;
               if v_code /= C_NONE then
                  if v_code = rep_code then
                     rep_on  <= '0';
                     rep_due <= '0';
                  end if;
                  if scan_en = '1' then
                     send_break(v_code);
                  end if;
               end if;
               if supp = v_num then
                  supp <= 80;
                  if scan_en = '1' then
                     if phys_l = '1' and sent_l = '0' then
                        send_make(C_BASE(K_LSHIFT));
                     elsif phys_l = '0' and sent_l = '1' then
                        send_break(C_BASE(K_LSHIFT));
                     end if;
                     if phys_r = '1' and sent_r = '0' then
                        send_make(C_BASE(K_RSHIFT));
                     elsif phys_r = '0' and sent_r = '1' then
                        send_break(C_BASE(K_RSHIFT));
                     end if;
                     sent_l <= phys_l;
                     sent_r <= phys_r;
                  end if;
               end if;
            end if;

         elsif rep_due = '1' and q_cnt <= 14 then
            rep_due <= '0';
            if scan_en = '1' then
               send_make(rep_code);
            end if;
         end if;

         -- Into the queue (a command first empties it; a byte the device took this cycle went)
         if v_flush then
            if v_pop then
               v_qbase := q_rd + 1;
            else
               v_qbase := q_rd;
            end if;
            for i in 0 to 7 loop
               if i < v_n then
                  q(to_integer(v_qbase + i)) <= v_b(i);
               end if;
            end loop;
            q_rd  <= v_qbase;
            q_wr  <= v_qbase + v_n;
            q_cnt <= to_unsigned(v_n, 5);
         else
            for i in 0 to 7 loop
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
            q_wr      <= (others => '0');
            q_rd      <= (others => '0');
            q_cnt     <= (others => '0');
            scan_en   <= '1';
            arg_cmd   <= x"00";
            typematic <= "0101011";
            sent_l    <= '0';
            sent_r    <= '0';
            supp      <= 80;
            key_var   <= (others => V_NONE);
            rep_on    <= '0';
            rep_due   <= '0';
         end if;
      end if;
   end process p_keyboard;

end architecture synthesis;

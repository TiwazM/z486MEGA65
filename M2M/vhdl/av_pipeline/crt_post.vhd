----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Post-scale CRT emulation (M2M-UPSTREAM crt-post, z486 for MEGA65, 2026-11-15)
--
-- Between ascal and the on-screen menu, one output pixel per clock, each part on its own:
--
--   1. Gamma: a CRT's response (out = in ** C_GAMMA), darker mid-tones.
--   2. Scanlines on the input's own lines at any scale: ascal tells each output line's place
--      between two input lines (vfrac_i: 0 = on the upper one); the line's brightness follows
--      an electron beam's profile across that gap, its width growing with the pixel's
--      brightness (a bright line is thicker, as on a CRT), and the lines are brightened to
--      win back part of what the gaps take (C_SL: light, medium, strong).
--   3. Mask: the phosphor pattern by output pixel, MiSTer's shadowmask.sv way (per pixel and
--      colour a multiplier of 0..1.94: an aperture grille, a slot mask, the Commodore 1084's
--      shadow mask from M2M/video_filters).
--   4. Glow: what is brighter than C_GLOW_T, blurred (7 pixels across, this and two lines up)
--      and half of it added back after the mask: bright areas bleed a little and win back
--      some of the mask's darkening.
--
-- The tables are constants (no loader). Latency C_LAT clocks; syncs and display enable are
-- delayed alike.
--
-- done by the z486MEGA65 project in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity crt_post is
   generic (
      G_XBITS  : natural := 11                         -- the widest output line: 2**G_XBITS
   );
   port (
      clk_i    : in  std_logic;

      -- settings (clk_i's domain)
      sl_i     : in  std_logic_vector(1 downto 0);     -- scanlines: 00 off, 01 light, 10 medium,
                                                       -- 11 strong
      mask_i   : in  std_logic_vector(1 downto 0);     -- 00 off, 01 aperture grille, 10 slot
                                                       -- mask, 11 shadow mask (Commodore 1084)
      glow_i   : in  std_logic;
      gamma_i  : in  std_logic;

      -- ascal's output; vfrac_i is constant over a line
      vfrac_i  : in  unsigned(11 downto 0);
      r_i      : in  unsigned(7 downto 0);
      g_i      : in  unsigned(7 downto 0);
      b_i      : in  unsigned(7 downto 0);
      hs_i     : in  std_logic;
      vs_i     : in  std_logic;
      de_i     : in  std_logic;

      r_o      : out unsigned(7 downto 0);
      g_o      : out unsigned(7 downto 0);
      b_o      : out unsigned(7 downto 0);
      hs_o     : out std_logic;
      vs_o     : out std_logic;
      de_o     : out std_logic
   );
end entity crt_post;

architecture synthesis of crt_post is

   ---------------------------------------------------------------------------------------------
   -- Tables
   ---------------------------------------------------------------------------------------------

   -- Gamma: a CRT's ~2.5 against the 2.2 the picture was made for
   constant C_GAMMA : real := 1.15;
   type t_byte_tab is array (0 to 255) of unsigned(7 downto 0);
   function gamma_tab return t_byte_tab is
      variable t : t_byte_tab;
   begin
      t(0) := (others => '0');
      for i in 1 to 255 loop
         t(i) := to_unsigned(integer(round(255.0 * (real(i) / 255.0) ** C_GAMMA)), 8);
      end loop;
      return t;
   end function gamma_tab;
   constant C_GAMMA_TAB : t_byte_tab := gamma_tab;

   -- Scanlines: the beam's width (a Gaussian's sigma, in input lines) for a black and a white
   -- pixel, how much of the gaps' darkening the line wins back (0..1), and the most it may be
   -- brightened. Weight w (x256, at most 1.99) by setting (2 bits), place in the gap (6 bits),
   -- brightness (4 bits); setting 0 is 1.0 everywhere.
   type t_sl_par is record
      sd, sb, comp, cap : real;
   end record;
   type t_sl_pars is array (1 to 3) of t_sl_par;
   constant C_SL : t_sl_pars := (
      1 => (sd => 0.34, sb => 0.56, comp => 0.5, cap => 1.30),   -- light
      2 => (sd => 0.26, sb => 0.47, comp => 0.6, cap => 1.45),   -- medium
      3 => (sd => 0.20, sb => 0.39, comp => 0.7, cap => 1.60));  -- strong
   type t_sl_tab is array (0 to 4095) of unsigned(8 downto 0);
   function sl_tab return t_sl_tab is
      variable t                   : t_sl_tab;
      variable f, d, l, s, a, g, w : real;
   begin
      for i in 0 to 1023 loop
         t(i) := to_unsigned(256, 9);
      end loop;
      for k in 1 to 3 loop
         for lv in 0 to 15 loop
            l := (real(lv) + 0.5) / 16.0;
            s := C_SL(k).sd + (C_SL(k).sb - C_SL(k).sd) * l;
            a := 0.0;                                -- the line's average over the gap
            for ph in 0 to 63 loop
               f := (real(ph) + 0.5) / 64.0;
               d := f;
               if 1.0 - f < d then
                  d := 1.0 - f;
               end if;
               a := a + exp(-(d * d) / (2.0 * s * s));
            end loop;
            a := a / 64.0;
            g := 1.0 + (1.0 / a - 1.0) * C_SL(k).comp;
            if g > C_SL(k).cap then
               g := C_SL(k).cap;
            end if;
            for ph in 0 to 63 loop
               f := (real(ph) + 0.5) / 64.0;
               d := f;
               if 1.0 - f < d then
                  d := 1.0 - f;
               end if;
               w := g * exp(-(d * d) / (2.0 * s * s));
               if w > 1.99 then
                  w := 1.99;
               end if;
               t(k * 1024 + ph * 16 + lv) := to_unsigned(integer(round(w * 256.0)), 9);
            end loop;
         end loop;
      end loop;
      return t;
   end function sl_tab;
   constant C_SL_TAB : t_sl_tab := sl_tab;

   -- Masks, MiSTer's shadowmask.sv format: per pixel 11 bits, bits 10..8 = red, green, blue use
   -- the high multiplier (1 + bits 7..4 / 16), else the low one (bits 3..0 / 16); index =
   -- row * 16 + column, the pattern hmax + 1 wide and vmax + 1 high
   subtype t_mword is std_logic_vector(10 downto 0);
   type t_mwords is array (natural range <>) of natural;
   type t_mtab is array (0 to 255) of t_mword;
   type t_mask is record
      hmax, vmax : natural range 0 to 15;
      tab        : t_mtab;
   end record;
   type t_masks is array (1 to 3) of t_mask;
   function mk(hmax, vmax : natural; w : t_mwords) return t_mask is
      variable m : t_mask;
   begin
      m.hmax := hmax;
      m.vmax := vmax;
      m.tab  := (others => "11100000000");           -- 1.0 (never used)
      for y in 0 to vmax loop
         for x in 0 to hmax loop
            m.tab(y * 16 + x) := std_logic_vector(to_unsigned(w(y * (hmax + 1) + x), 11));
         end loop;
      end loop;
      return m;
   end function mk;
   constant C_MASKS : t_masks := (
      -- aperture grille: red, green, blue stripes
      1 => mk(2, 0, (16#44A#, 16#24A#, 16#14A#)),
      -- slot mask: triads, every other one with a dark row, staggered
      2 => mk(5, 3, (16#44A#, 16#24A#, 16#14A#,
                     16#44A#, 16#24A#, 16#14A#,
                     16#44A#, 16#24A#, 16#14A#,
                     16#006#, 16#006#, 16#006#,
                     16#44A#, 16#24A#, 16#14A#,
                     16#44A#, 16#24A#, 16#14A#,
                     16#006#, 16#006#, 16#006#,
                     16#44A#, 16#24A#, 16#14A#)),
      -- the Commodore 1084's shadow mask (M2M/video_filters/Commodore_1084_BGR_1987.txt, by
      -- TrashUncle, its base size)
      3 => mk(5, 2, (16#14C#, 16#24C#, 16#44C#,
                     16#11F#, 16#21F#, 16#41F#,
                     16#11F#, 16#21F#, 16#41F#,
                     16#14C#, 16#24C#, 16#44C#,
                     16#14C#, 16#24C#, 16#44C#,
                     16#14C#, 16#24C#, 16#44C#)));

   -- Glow: what is above C_GLOW_T, blurred, half of it added
   constant C_GLOW_T : natural := 128;

   ---------------------------------------------------------------------------------------------
   -- Pipeline
   ---------------------------------------------------------------------------------------------

   type t_rgb is array (0 to 2) of unsigned(7 downto 0);
   type t_sync is record
      hs, vs, de : std_logic;
   end record;
   constant C_SYNC0 : t_sync := ('0', '0', '0');

   -- 1..6: gamma, brightness, scanline weight, scanlines
   signal c1, c2, c3, c4, c6 : t_rgb;
   signal s1, s2, s3, s4, s5, s6 : t_sync := C_SYNC0;
   signal f1, f2, f3       : unsigned(5 downto 0);
   signal lum3             : unsigned(7 downto 0);
   signal w4               : unsigned(8 downto 0);
   type t_prod is array (0 to 2) of unsigned(16 downto 0);
   signal p5               : t_prod;

   -- 7..9: the glow's window across (7 pixels, centre 3 back) and the main picture with it
   type t_win is array (0 to 6) of t_rgb;
   signal win              : t_win;
   type t_cdl is array (0 to 3) of t_rgb;
   signal cdl              : t_cdl;
   type t_sdl is array (0 to 3) of t_sync;
   signal sdl              : t_sdl := (others => C_SYNC0);
   type t_sum is array (0 to 2) of unsigned(9 downto 0);
   signal ha8, hb8, hc8, hd8 : t_sum;
   signal c8, c9, c10      : t_rgb;
   signal s8, s9, s10, s11 : t_sync := C_SYNC0;
   signal h9               : t_rgb;

   -- 9..11: mask, the glow's lines
   signal x9               : unsigned(G_XBITS - 1 downto 0) := (others => '0');
   signal mx9, my9         : natural range 0 to 15 := 0;
   signal vs9_d            : std_logic := '0';
   type t_mul is array (0 to 2) of unsigned(4 downto 0);
   signal m10              : t_mul;
   signal x10              : unsigned(G_XBITS - 1 downto 0);
   signal h10              : t_rgb;
   signal mc11             : t_rgb;
   signal v11              : t_rgb;

   type t_line is array (0 to 2**G_XBITS - 1) of std_logic_vector(23 downto 0);
   signal lb1, lb2         : t_line;
   signal lb1_q, lb2_q     : std_logic_vector(23 downto 0);

   function clamp8(v : unsigned) return unsigned is
   begin
      if v > 255 then
         return to_unsigned(255, 8);
      end if;
      return resize(v, 8);
   end function clamp8;

   function bright(c : unsigned(7 downto 0)) return unsigned is
   begin
      if c > C_GLOW_T then
         return resize(c - C_GLOW_T, 8);
      end if;
      return to_unsigned(0, 8);
   end function bright;

begin

   p_pipe : process (clk_i)
      variable ad   : natural range 0 to 4095;
      variable e    : t_rgb;
      variable mw   : t_mword;
      variable p    : unsigned(12 downto 0);
      variable v    : unsigned(9 downto 0);
      variable hsum : unsigned(10 downto 0);
      variable osum : unsigned(9 downto 0);
   begin
      if rising_edge(clk_i) then
         -- 1: in
         c1 <= (r_i, g_i, b_i);
         f1 <= vfrac_i(11 downto 6);
         s1 <= (hs_i, vs_i, de_i);

         -- 2: gamma
         for i in 0 to 2 loop
            if gamma_i = '1' then
               c2(i) <= C_GAMMA_TAB(to_integer(c1(i)));
            else
               c2(i) <= c1(i);
            end if;
         end loop;
         f2 <= f1;
         s2 <= s1;

         -- 3: brightness (2 R + 5 G + B) / 8
         lum3 <= to_unsigned((2 * to_integer(c2(0)) + 5 * to_integer(c2(1)) + to_integer(c2(2))) / 8, 8);
         c3   <= c2;
         f3   <= f2;
         s3   <= s2;

         -- 4: the scanline weight (block RAM)
         ad := to_integer(unsigned(sl_i)) * 1024 + to_integer(f3) * 16 + to_integer(lum3(7 downto 4));
         w4 <= C_SL_TAB(ad);
         c4 <= c3;
         s4 <= s3;

         -- 5, 6: weighted
         for i in 0 to 2 loop
            p5(i) <= c4(i) * w4;
            c6(i) <= clamp8(p5(i)(16 downto 8));
         end loop;
         s5 <= s4;
         s6 <= s5;

         -- 7: the glow's window across, the picture and syncs to its centre
         for i in 0 to 2 loop
            if s6.de = '1' then
               e(i) := bright(c6(i));
            else
               e(i) := (others => '0');
            end if;
         end loop;
         win(0) <= e;
         for k in 1 to 6 loop
            win(k) <= win(k - 1);
         end loop;
         cdl(0) <= c6;
         sdl(0) <= s6;
         for k in 1 to 3 loop
            cdl(k) <= cdl(k - 1);
            sdl(k) <= sdl(k - 1);
         end loop;

         -- 8: [1 2 3 4 3 2 1] / 16 across, in two steps (win(3) is cdl(3)'s pixel)
         for i in 0 to 2 loop
            ha8(i) <= resize(win(0)(i), 10) + win(6)(i);
            hb8(i) <= resize(win(1)(i), 10) + win(5)(i);
            hc8(i) <= resize(win(2)(i), 10) + win(4)(i);
            hd8(i) <= resize(win(3)(i), 10);
         end loop;
         c8 <= cdl(3);
         s8 <= sdl(3);

         -- 9: the sum; the mask's place; the glow's lines read at this pixel
         for i in 0 to 2 loop
            hsum := resize(ha8(i), 11) + shift_left(resize(hb8(i), 11), 1) + resize(hc8(i) * 3, 11) +
                    shift_left(resize(hd8(i), 11), 2);
            h9(i) <= resize(hsum / 16, 8);
         end loop;
         c9 <= c8;
         s9 <= s8;
         lb1_q <= lb1(to_integer(x9));
         lb2_q <= lb2(to_integer(x9));
         vs9_d <= s9.vs;
         if s9.de = '1' then
            x9 <= x9 + 1;
            if mx9 = C_MASKS(3).hmax and mask_i = "11" then
               mx9 <= 0;
            elsif mx9 = C_MASKS(2).hmax and mask_i = "10" then
               mx9 <= 0;
            elsif mx9 = C_MASKS(1).hmax and mask_i = "01" then
               mx9 <= 0;
            elsif mx9 = 15 then
               mx9 <= 0;
            else
               mx9 <= mx9 + 1;
            end if;
         else
            x9  <= (others => '0');
            mx9 <= 0;
         end if;
         if s9.de = '0' and s10.de = '1' then        -- a line ended
            if (mask_i = "11" and my9 >= C_MASKS(3).vmax) or
               (mask_i = "10" and my9 >= C_MASKS(2).vmax) or
               (mask_i = "01" and my9 >= C_MASKS(1).vmax) or my9 = 15 then
               my9 <= 0;
            else
               my9 <= my9 + 1;
            end if;
         end if;
         if s9.vs = '1' and vs9_d = '0' then
            my9 <= 0;
         end if;

         -- 10: the mask's multipliers; the glow's lines written (this line's into lb1, lb1's
         -- into lb2) and taken
         mw := "11100000000";
         if mask_i /= "00" then
            mw := C_MASKS(to_integer(unsigned(mask_i))).tab(my9 * 16 + mx9);
         end if;
         for i in 0 to 2 loop
            if mw(10 - i) = '1' then
               m10(i) <= '1' & unsigned(mw(7 downto 4));
            else
               m10(i) <= '0' & unsigned(mw(3 downto 0));
            end if;
         end loop;
         c10 <= c9;
         s10 <= s9;
         h10 <= h9;
         x10 <= x9;
         if s10.de = '1' then
            lb1(to_integer(x10)) <= std_logic_vector(h10(0)) & std_logic_vector(h10(1)) &
                                        std_logic_vector(h10(2));
            lb2(to_integer(x10)) <= lb1_q;
         end if;

         -- 11: masked; the glow (2 x this line + the two above) / 4
         for i in 0 to 2 loop
            p := c10(i) * m10(i);
            mc11(i) <= clamp8(p(12 downto 4));
            v := shift_left(resize(h10(i), 10), 1) + unsigned(lb1_q(23 - 8 * i downto 16 - 8 * i)) +
                 unsigned(lb2_q(23 - 8 * i downto 16 - 8 * i));
            v11(i) <= resize(v / 4, 8);
         end loop;
         s11 <= s10;

         -- 12: out
         for i in 0 to 2 loop
            if glow_i = '1' then
               osum := resize(mc11(i), 10) + v11(i) / 2;
            else
               osum := resize(mc11(i), 10);
            end if;
            if s11.de = '1' then
               case i is
                  when 0      => r_o <= clamp8(osum);
                  when 1      => g_o <= clamp8(osum);
                  when others => b_o <= clamp8(osum);
               end case;
            else
               case i is
                  when 0      => r_o <= (others => '0');
                  when 1      => g_o <= (others => '0');
                  when others => b_o <= (others => '0');
               end case;
            end if;
         end loop;
         hs_o <= s11.hs;
         vs_o <= s11.vs;
         de_o <= s11.de;
      end if;
   end process p_pipe;

end architecture synthesis;

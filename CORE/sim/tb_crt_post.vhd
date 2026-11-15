-- Testbench for crt_post.vhd: a 320x200 picture as the VGA sends it (640x400, every line twice),
-- scaled like ascal to G_OW x G_OH (vertically bilinear with ascal's line position vfrac,
-- across nearest), through crt_post; the second frame's input and output go to text files
-- (one "r g b" per pixel) for tb_png.py. With every effect off the output must be the input.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_crt_post is
   generic (
      G_SL    : natural := 2;
      G_MASK  : natural := 1;
      G_GLOW  : natural := 1;
      G_GAMMA : natural := 1;
      G_OW    : natural := 960;
      G_OH    : natural := 720;
      G_NAME  : string  := "run"
   );
end entity tb_crt_post;

architecture sim of tb_crt_post is
   constant C_IW : natural := 640;
   constant C_IH : natural := 400;
   constant C_HB : natural := 60;                  -- blanking clocks a line

   signal clk  : std_logic := '0';
   signal r_i, g_i, b_i, r_o, g_o, b_o : unsigned(7 downto 0) := (others => '0');
   signal hs_i, vs_i, de_i, hs_o, vs_o, de_o : std_logic := '0';
   signal vfrac : unsigned(11 downto 0) := (others => '0');
   signal done : boolean := false;
   signal frame_i : natural := 0;

   type t_px is array (0 to 2) of natural;

   -- the 320x200 picture: colour bars, a grey ramp, white "text" on blue, a white box
   function src(x, y : natural) return t_px is
      variable h : natural;
   begin
      if y < 40 then
         case x / 40 is
            when 0 => return (255, 255, 255);
            when 1 => return (255, 255, 0);
            when 2 => return (0, 255, 255);
            when 3 => return (0, 255, 0);
            when 4 => return (255, 0, 255);
            when 5 => return (255, 0, 0);
            when 6 => return (0, 0, 255);
            when others => return (0, 0, 0);
         end case;
      elsif y < 64 then
         return (x * 255 / 319, x * 255 / 319, x * 255 / 319);
      elsif y >= 150 and y < 190 and x >= 230 and x < 300 then
         if y = 150 or y = 189 or x = 230 or x = 299 or (y > 160 and y < 180 and x > 240 and x < 290) then
            return (255, 255, 255);
         end if;
         return (170, 0, 0);
      elsif y >= 72 and y < 144 and x >= 8 and x < 216 then
         -- 8x8 cells, a pseudo glyph per cell: strokes on rows 1, 4, 6 and columns 1, 5
         h := ((x / 8) * 7 + (y / 8) * 13) mod 11;
         if ((y mod 8 = 1 or y mod 8 = 6) and x mod 8 >= 1 and x mod 8 <= 5 and h mod 2 = 0) or
            ((x mod 8 = 1 or x mod 8 = 5) and y mod 8 >= 1 and y mod 8 <= 6 and h mod 3 /= 0) or
            (y mod 8 = 4 and x mod 8 >= 1 and x mod 8 <= 5 and h > 5) then
            return (255, 255, 255);
         end if;
         return (0, 0, 170);
      end if;
      return (0, 0, 0);
   end function src;

   -- the VGA's 640x400 (every line and pixel twice)
   function vga(x, y : natural) return t_px is
   begin
      return src(x / 2, y / 2);
   end function vga;

begin

   clk <= not clk after 5 ns when not done;

   dut : entity work.crt_post
      port map (
         clk_i   => clk,
         sl_i    => std_logic_vector(to_unsigned(G_SL, 2)),
         mask_i  => std_logic_vector(to_unsigned(G_MASK, 2)),
         glow_i  => to_unsigned(G_GLOW, 1)(0),
         gamma_i => to_unsigned(G_GAMMA, 1)(0),
         vfrac_i => vfrac,
         r_i => r_i, g_i => g_i, b_i => b_i, hs_i => hs_i, vs_i => vs_i, de_i => de_i,
         r_o => r_o, g_o => g_o, b_o => b_o, hs_o => hs_o, vs_o => vs_o, de_o => de_o);

   p_src : process
      file fi : text open write_mode is G_NAME & "_in.txt";
      variable l : line;
      variable pos, f : real;
      variable n, ix : integer;
      variable a, b : t_px;
      variable px : t_px;
   begin
      for frame in 0 to 1 loop
         frame_i <= frame;
         -- vertical sync: two lines
         for k in 0 to 2 * (G_OW + C_HB) - 1 loop
            vs_i <= '1';
            wait until rising_edge(clk);
         end loop;
         vs_i <= '0';
         for y in 0 to G_OH - 1 loop
            -- ascal's place of the output line between two input lines
            pos := (real(y) + 0.5) * real(C_IH) / real(G_OH) - 0.5;
            if pos < 0.0 then
               pos := 0.0;
            end if;
            n := integer(pos - 0.4999999);
            f := pos - real(n);
            vfrac <= to_unsigned(integer(f * 4095.0), 12);
            for x in 0 to G_OW - 1 loop
               ix := x * C_IW / G_OW;
               a := vga(ix, n);
               if n + 1 < C_IH then
                  b := vga(ix, n + 1);
               else
                  b := a;
               end if;
               for i in 0 to 2 loop
                  px(i) := integer(real(a(i)) * (1.0 - f) + real(b(i)) * f);
               end loop;
               r_i <= to_unsigned(px(0), 8);
               g_i <= to_unsigned(px(1), 8);
               b_i <= to_unsigned(px(2), 8);
               de_i <= '1';
               if frame = 1 then
                  write(l, px(0)); write(l, ' '); write(l, px(1)); write(l, ' '); write(l, px(2));
                  writeline(fi, l);
               end if;
               wait until rising_edge(clk);
            end loop;
            de_i <= '0';
            r_i <= (others => '0'); g_i <= (others => '0'); b_i <= (others => '0');
            for k in 0 to C_HB - 1 loop
               hs_i <= '1' when k >= 10 and k < 30 else '0';
               wait until rising_edge(clk);
            end loop;
            hs_i <= '0';
         end loop;
      end loop;
      for k in 0 to 100 loop
         wait until rising_edge(clk);
      end loop;
      done <= true;
      wait;
   end process p_src;

   p_out : process
      file fo : text open write_mode is G_NAME & "_out.txt";
      variable l : line;
      variable frames : natural := 0;
      variable vs_d : std_logic := '0';
   begin
      wait until rising_edge(clk);
      if vs_o = '1' and vs_d = '0' then
         frames := frames + 1;
      end if;
      vs_d := vs_o;
      if frames = 2 and de_o = '1' then
         write(l, to_integer(r_o)); write(l, ' '); write(l, to_integer(g_o)); write(l, ' ');
         write(l, to_integer(b_o));
         writeline(fo, l);
      end if;
      if done then
         wait;
      end if;
   end process p_out;

end architecture sim;

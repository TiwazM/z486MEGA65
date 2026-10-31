----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Testbench for ascal's line fetches (M2M/vhdl/av_pipeline/ascal.vhd, M2M-UPSTREAM late-fetch):
-- a still 320x240 picture scaled 2x into a 640x480 window of a 712x528 output with short
-- blanking, the proportions of 1280x1024 with reduced blanking (a fetch of 8 bursts against
-- 7.9 us lines). The memory is an Avalon slave that does one burst at a time: G_LAT clocks,
-- then a beat every G_GAP clocks, for ascal's input writes and its output reads alike. With
-- G_LAT 2, G_GAP 1 every fetch fits in its line; with G_LAT 16, G_GAP 8 (~80 clocks a burst,
-- the input writes take ~40 % of the memory, like the HyperRAM's) a fetch takes ~1.3 lines.
--
-- Writes one checksum per output line of frames 3 .. G_FRAMES-1 to build/ascal_<G_RUN>.txt,
-- and frame 4 as a P3 picture to build/ascal_<G_RUN>.ppm. run_ascal.sh compares the runs.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ascal is
   generic (
      G_LAT    : natural := 16;      -- memory latency per burst (avl clocks)
      G_GAP    : natural := 8;       -- clocks per beat
      G_FRAMES : natural := 7;
      G_RUN    : natural := 0        -- output file number
   );
end entity tb_ascal;

architecture sim of tb_ascal is

   constant C_DW : natural := 128;
   constant C_AW : natural := 19;
   constant C_MEMW : natural := 65536;   -- 1 MB; addresses wrap

   signal i_clk, o_clk, avl_clk : std_logic := '0';
   signal reset_na : std_logic := '0';

   -- input video: 320x240 of 400x262
   signal i_r, i_g, i_b : unsigned(7 downto 0) := (others => '0');
   signal i_hs, i_vs, i_de : std_logic := '0';

   signal o_r, o_g, o_b : unsigned(7 downto 0);
   signal o_hs, o_vs, o_de : std_logic;

   signal avl_waitrequest   : std_logic := '1';
   signal avl_readdata      : std_logic_vector(C_DW-1 downto 0) := (others => '0');
   signal avl_readdatavalid : std_logic := '0';
   signal avl_burstcount    : std_logic_vector(7 downto 0);
   signal avl_writedata     : std_logic_vector(C_DW-1 downto 0);
   signal avl_address       : std_logic_vector(C_AW-1 downto 0);
   signal avl_write         : std_logic;
   signal avl_read          : std_logic;
   signal avl_byteenable    : std_logic_vector(C_DW/8-1 downto 0);

begin

   i_clk   <= not i_clk   after 20 ns;      -- 25 MHz
   o_clk   <= not o_clk   after 5.5555 ns;  -- 90 MHz
   avl_clk <= not avl_clk after 5 ns;       -- 100 MHz
   reset_na <= '1' after 1 us;

   p_in : process (i_clk)
      variable hc : natural range 0 to 399 := 0;
      variable vc : natural range 0 to 261 := 0;
   begin
      if rising_edge(i_clk) then
         if hc = 399 then
            hc := 0;
            vc := (vc + 1) mod 262;
         else
            hc := hc + 1;
         end if;
         i_de <= '1' when hc < 320 and vc < 240 else '0';
         i_hs <= '1' when hc >= 340 and hc < 370 else '0';
         i_vs <= '1' when vc >= 245 and vc < 247 else '0';
         i_r  <= to_unsigned(hc mod 256, 8);
         i_g  <= to_unsigned(vc, 8);
         i_b  <= to_unsigned((hc * 3 + vc * 5) mod 256, 8);
      end if;
   end process p_in;

   i_ascal : entity work.ascal
      generic map (
         MASK => x"07", RAMBASE => (others => '0'), RAMSIZE => to_unsigned(2**18, 32),
         INTER => true, HEADER => false, DOWNSCALE => false, DOWNSCALE_NN => true,
         BYTESWAP => true, ADAPTIVE => true, PALETTE => true, PALETTE2 => true, FRAC => 6,
         OHRES => 2048, IHRES => 1024, N_DW => C_DW, N_AW => C_AW, N_BURST => 128
      )
      port map (
         i_r => i_r, i_g => i_g, i_b => i_b, i_hs => i_hs, i_vs => i_vs, i_fl => '0',
         i_de => i_de, i_ce => '1', i_clk => i_clk,
         o_r => o_r, o_g => o_g, o_b => o_b, o_hs => o_hs, o_vs => o_vs, o_de => o_de,
         o_vbl => open, o_brd => open, o_ce => '1', o_clk => o_clk,
         o_border => x"000000",
         o_fb_ena => '0', o_fb_hsize => 0, o_fb_vsize => 0, o_fb_format => "000101",
         o_fb_base => x"0000_0000", o_fb_stride => (others => '0'),
         pal1_clk => '0', pal1_dw => (others => '0'), pal1_dr => open, pal1_a => (others => '0'),
         pal1_wr => '0', pal_n => '1',
         pal2_clk => '0', pal2_dw => (others => '0'), pal2_dr => open, pal2_a => (others => '0'),
         pal2_wr => '0',
         o_lltune => open,
         iauto => '1', himin => 0, himax => 0, vimin => 0, vimax => 0,
         i_hdmax => open, i_vdmax => open, i_interlaced => open,
         run => '1', freeze => '0', mode => "01010",   -- triple buffered sharp bilinear
         htotal => 712, hsstart => 660, hsend => 676, hdisp => 640, hmin => 0, hmax => 639,
         vtotal => 528, vsstart => 515, vsend => 519, vdisp => 512, vmin => 16, vmax => 495,
         format => "01",
         poly_clk => '0', poly_dw => (others => '0'), poly_a => (others => '0'), poly_wr => '0',
         avl_clk => avl_clk, avl_waitrequest => avl_waitrequest, avl_readdata => avl_readdata,
         avl_readdatavalid => avl_readdatavalid, avl_burstcount => avl_burstcount,
         avl_writedata => avl_writedata, avl_address => avl_address, avl_write => avl_write,
         avl_read => avl_read, avl_byteenable => avl_byteenable,
         reset_na => reset_na
      );

   -- the memory: one burst at a time; random contents where nothing was written
   p_mem : process (avl_clk)
      type t_mem is array (0 to C_MEMW-1) of std_logic_vector(C_DW-1 downto 0);
      type t_st is (S_IDLE, S_RLAT, S_RDAT, S_WLAT, S_WDAT);
      variable mem    : t_mem;
      variable init   : boolean := false;
      variable st     : t_st := S_IDLE;
      variable adr    : natural range 0 to C_MEMW-1;
      variable left   : natural range 0 to 255;
      variable cnt    : natural;
      variable seed   : unsigned(31 downto 0) := x"12345678";
      variable w      : std_logic_vector(C_DW-1 downto 0);

      procedure store(a : natural; d : std_logic_vector; be : std_logic_vector) is
      begin
         for i in 0 to C_DW/8-1 loop
            if be(i) = '1' then
               mem(a)(8*i+7 downto 8*i) := d(8*i+7 downto 8*i);
            end if;
         end loop;
      end procedure;
   begin
      if rising_edge(avl_clk) then
         if not init then
            for a in 0 to C_MEMW-1 loop
               for k in 0 to C_DW/32-1 loop
                  seed := seed(30 downto 0) & (seed(31) xor seed(21) xor seed(1) xor seed(0));
                  seed := seed(30 downto 0) & (seed(31) xor seed(21) xor seed(1) xor seed(0));
                  mem(a)(32*k+31 downto 32*k) := std_logic_vector(seed);
               end loop;
            end loop;
            init := true;
         end if;
         avl_readdatavalid <= '0';
         avl_waitrequest   <= '1';
         case st is
            when S_IDLE =>
               if avl_waitrequest = '0' and avl_read = '1' then
                  adr  := to_integer(unsigned(avl_address)) mod C_MEMW;
                  left := to_integer(unsigned(avl_burstcount));
                  cnt  := G_LAT;
                  st   := S_RLAT;
               elsif avl_waitrequest = '0' and avl_write = '1' then
                  adr  := to_integer(unsigned(avl_address)) mod C_MEMW;
                  left := to_integer(unsigned(avl_burstcount));
                  store(adr, avl_writedata, avl_byteenable);
                  adr  := (adr + 1) mod C_MEMW;
                  left := left - 1;
                  cnt  := G_LAT;
                  st   := S_WLAT;
               else
                  avl_waitrequest <= '0';
               end if;
            when S_RLAT =>
               if cnt <= 1 then
                  cnt := 0;
                  st  := S_RDAT;
               else
                  cnt := cnt - 1;
               end if;
            when S_RDAT =>
               if cnt = 0 then
                  avl_readdata      <= mem(adr);
                  avl_readdatavalid <= '1';
                  adr  := (adr + 1) mod C_MEMW;
                  left := left - 1;
                  cnt  := G_GAP - 1;
                  if left = 0 then
                     st := S_IDLE;
                     avl_waitrequest <= '0';
                  end if;
               else
                  cnt := cnt - 1;
               end if;
            when S_WLAT =>
               if left = 0 then
                  st := S_IDLE;
                  avl_waitrequest <= '0';
               elsif cnt <= 1 then
                  cnt := 0;
                  st  := S_WDAT;
                  avl_waitrequest <= '0';         -- take the next beat at the next edge
               else
                  cnt := cnt - 1;
               end if;
            when S_WDAT =>
               if avl_waitrequest = '0' and avl_write = '1' then
                  store(adr, avl_writedata, avl_byteenable);
                  adr  := (adr + 1) mod C_MEMW;
                  left := left - 1;
                  cnt  := G_GAP - 1;
               end if;
               if left = 0 then
                  st := S_IDLE;
                  avl_waitrequest <= '0';
               elsif cnt <= 1 then
                  cnt := 0;
                  avl_waitrequest <= '0';
               else
                  cnt := cnt - 1;
               end if;
         end case;
      end if;
   end process p_mem;

   -- per output line a checksum of its pixels; frame 4 as a picture
   p_out : process (o_clk)
      file     f_txt   : text;
      file     f_ppm   : text;
      variable opened  : boolean := false;
      variable l       : line;
      variable frame   : integer := -1;
      variable y       : integer := -1;
      variable x       : integer := 0;
      variable h       : natural := 0;
      variable vs_d    : std_logic := '0';
      variable de_d    : std_logic := '0';
   begin
      if rising_edge(o_clk) then
         if not opened then
            file_open(f_txt, "ascal_" & integer'image(G_RUN) & ".txt", write_mode);
            file_open(f_ppm, "ascal_" & integer'image(G_RUN) & ".ppm", write_mode);
            write(l, string'("P3 640 512 255")); writeline(f_ppm, l);
            opened := true;
         end if;
         if o_vs = '1' and vs_d = '0' then
            frame := frame + 1;
            y := -1;
            if frame = G_FRAMES then
               file_close(f_txt);
               file_close(f_ppm);
               report "tb_ascal: done, run " & integer'image(G_RUN) severity note;
               std.env.finish;
            end if;
         end if;
         if o_de = '1' then
            if de_d = '0' then
               y := y + 1;
               x := 0;
               h := 0;
            end if;
            h := (h * 33 + to_integer(o_r) * 65536 + to_integer(o_g) * 256 + to_integer(o_b))
                 mod 16777213;
            if frame = 4 then
               write(l, integer'image(to_integer(o_r)) & " " & integer'image(to_integer(o_g)) &
                        " " & integer'image(to_integer(o_b)) & " ");
               if x mod 8 = 7 then
                  writeline(f_ppm, l);
               end if;
            end if;
            x := x + 1;
         elsif de_d = '1' and frame >= 3 then
            write(l, integer'image(frame) & " " & integer'image(y) & " " & integer'image(h));
            writeline(f_txt, l);
         end if;
         vs_d := o_vs;
         de_d := o_de;
      end if;
   end process p_out;

end architecture sim;

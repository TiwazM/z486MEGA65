----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The CD-ROM drive's audio player (pc_cdrom.vhd's): Red Book samples (44.1 kHz, 16-bit stereo)
-- from pc_cdrom's streamer into a FIFO, out at 44.1 kHz, through the drive's own volume (MODE
-- SELECT page 0Eh), on the PC's clock. What z486_MiSTer's cdda.v is on MiSTer, plus what the
-- drive needs to say where it is: a pulse per sector heard (588 samples) for READ SUB-CHANNEL.
--
--   * The FIFO: 2**G_DEPTH words of {R, L} (8K: 186 ms of sound), one block RAM. free_o says how
--     many words it can take; a write when it is full is dropped (the streamer asks first).
--   * The reader: a sample every 1/44100 s (a fractional divider on G_CLK_HZ, exact for
--     64 MHz). Paused (pause_i), it holds its place and plays silence. Empty, it plays silence
--     and counts an underrun; neither counts as heard.
--   * flush_i empties the FIFO and starts a new sector count (a new PLAY, STOP, READ).
--   * Port 0 (left out) and port 1 (right out): channel select (0 mute, 1 left, 2 right, 3 both
--     mixed) and volume (0..255, 255 = as recorded), as page 0Eh has them.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cd_audio is
   generic (
      G_CLK_HZ   : natural := 64_000_000;
      G_RATE     : natural := 44_100;           -- (the testbench plays faster)
      G_DEPTH    : natural := 13                -- log2 of the FIFO's words
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      wr_i       : in  std_logic;               -- a sample pair: L 15..0, R 31..16
      data_i     : in  std_logic_vector(31 downto 0);
      flush_i    : in  std_logic;
      pause_i    : in  std_logic;
      free_o     : out unsigned(G_DEPTH downto 0);
      empty_o    : out std_logic;
      heard_o    : out std_logic;               -- a pulse: 588 more samples played
      under_o    : out std_logic;               -- a pulse: a sample the FIFO did not have

      sel0_i     : in  std_logic_vector(3 downto 0);
      vol0_i     : in  std_logic_vector(7 downto 0);
      sel1_i     : in  std_logic_vector(3 downto 0);
      vol1_i     : in  std_logic_vector(7 downto 0);

      l_o        : out std_logic_vector(15 downto 0) := (others => '0');
      r_o        : out std_logic_vector(15 downto 0) := (others => '0');
      stb_o      : out std_logic := '0'         -- a pulse: l_o/r_o are a sample from the FIFO
   );
end entity cd_audio;

architecture synthesis of cd_audio is

   constant C_WORDS : natural := 2 ** G_DEPTH;

   signal wa, ra     : unsigned(G_DEPTH - 1 downto 0) := (others => '0');
   signal fill       : unsigned(G_DEPTH downto 0) := (others => '0');
   signal q          : std_logic_vector(31 downto 0);
   signal acc        : natural range 0 to G_CLK_HZ + G_RATE := 0;
   signal tick       : std_logic := '0';
   signal fill_d     : unsigned(G_DEPTH downto 0) := (others => '0');   -- (a clock ago: the RAM
                                                -- reads ra one clock late)
   signal smp        : natural range 0 to 587 := 0;
   signal s_l, s_r   : signed(15 downto 0) := (others => '0');
   signal m_st       : natural range 0 to 3 := 0;
   signal m_vld      : std_logic := '0';
   signal m_in0      : signed(16 downto 0) := (others => '0');
   signal m_in1      : signed(16 downto 0) := (others => '0');
   signal m_p0, m_p1 : signed(26 downto 0) := (others => '0');

   -- port k's input: the channel(s) it selects (17 bits: both channels added)
   function chan(sel : std_logic_vector(3 downto 0); l, r : signed(15 downto 0)) return signed is
   begin
      case sel(1 downto 0) is
         when "01"   => return resize(l, 17);
         when "10"   => return resize(r, 17);
         when "11"   => return shift_right(resize(l, 17) + resize(r, 17), 1);
         when others => return to_signed(0, 17);
      end case;
   end function chan;

begin

   free_o  <= to_unsigned(C_WORDS, G_DEPTH + 1) - fill;
   empty_o <= '1' when fill = 0 else '0';

   i_fifo : entity work.tdp_ram
      generic map (
         ADDR_WIDTH => G_DEPTH,
         DATA_WIDTH => 32
      )
      port map (
         clock_a   => clk_i,
         address_a => std_logic_vector(wa),
         data_a    => data_i,
         wren_a    => wr_i and not flush_i and (not fill(G_DEPTH)),
         q_a       => open,
         clock_b   => clk_i,
         address_b => std_logic_vector(ra),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => q
      ); -- i_fifo

   p_fifo : process (clk_i)
      variable v_w, v_r : std_logic;
   begin
      if rising_edge(clk_i) then
         heard_o <= '0';
         under_o <= '0';
         stb_o   <= '0';
         fill_d  <= fill;

         -- 44.1 kHz
         tick <= '0';
         if acc + G_RATE >= G_CLK_HZ then
            acc  <= acc + G_RATE - G_CLK_HZ;
            tick <= '1';
         else
            acc <= acc + G_RATE;
         end if;

         v_w := wr_i and not fill(G_DEPTH);
         v_r := '0';
         if tick = '1' and pause_i = '0' then
            if fill_d /= 0 then
               v_r := '1';                       -- (q is the word at ra)
               if smp = 587 then
                  smp     <= 0;
                  heard_o <= '1';
               else
                  smp <= smp + 1;
               end if;
            else
               under_o <= '1';
            end if;
         end if;
         if v_w = '1' then
            wa <= wa + 1;
         end if;
         if v_r = '1' then
            ra <= ra + 1;
         end if;
         if v_w = '1' and v_r = '0' then
            fill <= fill + 1;
         elsif v_w = '0' and v_r = '1' then
            fill <= fill - 1;
         end if;

         -- the sample out (silence when there was none), then the volume
         if tick = '1' then
            if pause_i = '0' and fill_d /= 0 then
               s_l   <= signed(q(15 downto 0));
               s_r   <= signed(q(31 downto 16));
               m_vld <= '1';
            else
               s_l   <= (others => '0');
               s_r   <= (others => '0');
               m_vld <= '0';
            end if;
            m_st <= 1;
         end if;
         case m_st is
            when 1 =>
               m_in0 <= chan(sel0_i, s_l, s_r);
               m_in1 <= chan(sel1_i, s_l, s_r);
               m_st  <= 2;
            when 2 =>
               m_p0 <= resize(m_in0 * signed('0' & resize(unsigned(vol0_i), 9) + 1), 27);
               m_p1 <= resize(m_in1 * signed('0' & resize(unsigned(vol1_i), 9) + 1), 27);
               m_st <= 3;
            when 3 =>
               if vol0_i = x"00" then
                  l_o <= (others => '0');
               else
                  l_o <= std_logic_vector(m_p0(23 downto 8));
               end if;
               if vol1_i = x"00" then
                  r_o <= (others => '0');
               else
                  r_o <= std_logic_vector(m_p1(23 downto 8));
               end if;
               stb_o <= m_vld;
               m_st  <= 0;
            when others =>
               null;
         end case;

         if flush_i = '1' or rst_i = '1' then
            wa     <= (others => '0');
            ra     <= (others => '0');
            fill   <= (others => '0');
            fill_d <= (others => '0');
            smp    <= 0;
         end if;
      end if;
   end process p_fifo;

end architecture synthesis;

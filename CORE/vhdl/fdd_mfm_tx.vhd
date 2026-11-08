----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- fdd_mfm_tx: writes one IBM MFM data field to the internal floppy drive, for fdd_phys: the
-- part a PC's floppy controller writes for a sector after the sector's ID field and gap 2.
--
--   12 x 00, A1 A1 A1 (sync: 0x4489, the clock bit missing), FB, the 512 bytes of the sector
--   (from fdd_phys's write buffer: data_addr_o, data_i a clock later), the CRC-CCITT over
--   A1 A1 A1 FB and the data, then 2 x 4E; WGATE (active low) from the first cell to the end
--   of the last.
--
--   * One channel bit per cell at the nominal rate: 2 us at 250 kbit/s (hd_i = '0'), 1 us at
--     500 kbit/s. A '1' is a WDATA low pulse of a quarter cell, launched at the cell's middle.
--   * Write precompensation (an 82077's default, 125 ns): a '1' whose distance to the '1'
--     before it is shorter than to the '1' after it goes out early, the mirror case late
--     (peak shift pushes such transitions apart on the disk); the first and last few cells
--     unshifted (their neighbours are not all known).
--   * abort_i closes WGATE at once (a lost select, motor or the write protect tab); the
--     field is then broken on the disk, as on a PC whose drive went away mid-write.
--   * Track mode (track_i with start_i, for FORMAT): the bytes come from fdd_phys's track
--     generator instead: s_req_o pulses for the next one, s_byte_i / s_kind_i / s_end_i hold
--     it from the clock after (kind 00 a byte, 01 the A1 sync 4489h, 10 the C2 sync 5224h of
--     the index address mark); s_end_i marks the last byte. The generator computes the CRCs.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fdd_mfm_tx is
generic (
   G_CLK_HZ     : natural := 64_000_000
);
port (
   clk_i        : in  std_logic;
   rst_i        : in  std_logic;
   hd_i         : in  std_logic;                      -- '1': 500 kbit/s, '0': 250 kbit/s
   start_i      : in  std_logic;                      -- pulse: write the field now
   track_i      : in  std_logic := '0';               -- with start_i: a whole track (s_*)
   s_req_o      : out std_logic := '0';               -- pulse: the next byte, please
   s_byte_i     : in  std_logic_vector(7 downto 0) := (others => '0');
   s_kind_i     : in  std_logic_vector(1 downto 0) := "00";
   s_end_i      : in  std_logic := '0';
   abort_i      : in  std_logic;
   data_addr_o  : out std_logic_vector(8 downto 0) := (others => '0');
   data_i       : in  std_logic_vector(7 downto 0);
   busy_o       : out std_logic := '0';
   f_wdata_o    : out std_logic := '1';
   f_wgate_o    : out std_logic := '1'
);
end entity fdd_mfm_tx;

architecture rtl of fdd_mfm_tx is

   constant C_CELL_DD : natural := G_CLK_HZ / 500_000;
   constant C_CELL_HD : natural := G_CLK_HZ / 1_000_000;
   constant C_PRECOMP : natural := G_CLK_HZ / 8_000_000;       -- 125 ns
   constant C_BYTES   : natural := 12 + 3 + 1 + 512 + 2 + 2;   -- 532

   function crc_upd(c : unsigned(15 downto 0); b : std_logic_vector(7 downto 0))
      return unsigned is
      variable v : unsigned(15 downto 0) := c;
      variable x : std_logic;
   begin
      for i in 7 downto 0 loop
         x := v(15) xor b(i);
         v := v(14 downto 0) & '0';
         if x = '1' then
            v := v xor x"1021";
         end if;
      end loop;
      return v;
   end function crc_upd;

   constant C_CRC_A1 : unsigned(15 downto 0) :=
      crc_upd(crc_upd(crc_upd(x"FFFF", x"A1"), x"A1"), x"A1");

   signal active  : std_logic := '0';
   signal cell    : natural range 0 to C_CELL_DD := C_CELL_DD;
   signal cc      : natural range 0 to C_CELL_DD := 0;     -- the clock within the cell
   signal q       : std_logic_vector(31 downto 0) := (others => '0');   -- bits to go, MSB next
   signal qn      : natural range 0 to 32 := 0;
   signal hist    : std_logic_vector(3 downto 0) := (others => '0');    -- the last ones, 0 newest
   signal sent    : natural range 0 to 15 := 0;                         -- cells sent (to 15)
   signal launch  : natural range 0 to C_CELL_DD := 0;
   signal pulse   : std_logic := '0';                       -- this cell has a '1'
   signal pw      : natural range 0 to C_CELL_DD := 0;      -- the pulse's clocks left

   -- the bytes: k counts them; a byte is fetched (data_i a clock after data_addr_o)
   signal k       : natural range 0 to C_BYTES := 0;
   signal fetch   : natural range 0 to 2 := 0;
   signal prev    : std_logic := '0';                       -- the last data bit encoded
   signal crc     : unsigned(15 downto 0) := (others => '0');
   signal trk     : std_logic := '0';                       -- track mode

begin

   busy_o <= active;

   p_tx : process (clk_i)
      variable v_b      : std_logic_vector(7 downto 0);
      variable v_bits   : std_logic_vector(15 downto 0);
      variable v_p      : std_logic;
      variable v_before : natural range 1 to 5;
      variable v_after  : natural range 1 to 5;
      variable v_sync   : boolean;
   begin
      if rising_edge(clk_i) then
         s_req_o <= '0';
         ----------------------------------------------------------------------------------
         -- the next byte into the queue whenever it has room
         ----------------------------------------------------------------------------------
         if active = '1' and qn <= 16 and k < C_BYTES then
            case fetch is
               when 0 =>
                  if trk = '1' then
                     s_req_o <= '1';
                  elsif k >= 16 and k < 528 then
                     data_addr_o <= std_logic_vector(to_unsigned(k - 16, 9));
                  end if;
                  fetch <= 1;
               when 1 =>
                  fetch <= 2;                       -- data_i now
               when others =>
                 -- (not while a cell takes its bit from the queue: one change of q a clock)
                 if cc /= 0 or qn = 0 then
                  fetch  <= 0;
                  v_sync := false;
                  if trk = '1' then
                     v_b := s_byte_i;                -- (k only marks the end here)
                  elsif k < 12 then
                     v_b := x"00";
                  elsif k < 15 then
                     v_sync := true;
                     v_b    := x"A1";
                  elsif k = 15 then
                     v_b := x"FB";
                  elsif k < 528 then
                     v_b := data_i;
                  elsif k = 528 then
                     v_b := std_logic_vector(crc(15 downto 8));
                  elsif k = 529 then
                     v_b := std_logic_vector(crc(7 downto 0));
                  else
                     v_b := x"4E";
                  end if;
                  if k = 15 then
                     crc <= crc_upd(C_CRC_A1, v_b);
                  elsif k > 15 and k < 528 then
                     crc <= crc_upd(crc, v_b);
                  end if;
                  if trk = '1' and s_kind_i = "01" then
                     v_bits := x"4489";              -- A1, the clock between bits 4 and 3 missing
                     prev   <= '1';
                  elsif trk = '1' and s_kind_i = "10" then
                     v_bits := x"5224";              -- C2, the clock between bits 3 and 2 missing
                     prev   <= '0';
                  elsif v_sync and trk = '0' then
                     v_bits := x"4489";
                     prev   <= '1';
                  else
                     v_p := prev;
                     for i in 7 downto 0 loop
                        v_bits(2 * i)     := v_b(i);
                        v_bits(2 * i + 1) := not (v_p or v_b(i));
                        v_p := v_b(i);
                     end loop;
                     prev <= v_p;
                  end if;
                  -- append behind the qn bits queued
                  q  <= std_logic_vector(unsigned(q) or
                        shift_right(unsigned(v_bits & x"0000"), qn));
                  qn <= qn + 16;
                  if trk = '0' then
                     k <= k + 1;
                  elsif s_end_i = '1' then
                     k <= C_BYTES;                   -- the last byte is queued
                  end if;
                 end if;
            end case;
         end if;

         ----------------------------------------------------------------------------------
         -- one cell after the other
         ----------------------------------------------------------------------------------
         if pw /= 0 then
            pw <= pw - 1;
            if pw = 1 then
               f_wdata_o <= '1';
            end if;
         end if;

         if active = '1' then
            if cc = 0 then
               if qn = 0 and k = C_BYTES then
                  -- all out: the gate closes at the end of the last cell
                  active    <= '0';
                  f_wgate_o <= '1';
                  f_wdata_o <= '1';
               elsif qn = 0 then
                  null;                             -- the first byte is on its way
               else
                  -- the cell's bit and where its pulse goes
                  pulse <= q(31);
                  if hist(0) = '1' then v_before := 1;
                  elsif hist(1) = '1' then v_before := 2;
                  elsif hist(2) = '1' then v_before := 3;
                  elsif hist(3) = '1' then v_before := 4;
                  else v_before := 5;
                  end if;
                  if q(30) = '1' then v_after := 1;
                  elsif q(29) = '1' then v_after := 2;
                  elsif q(28) = '1' then v_after := 3;
                  elsif q(27) = '1' then v_after := 4;
                  else v_after := 5;
                  end if;
                  if sent < 8 or qn < 6 or v_before = 5 or v_after = 5 then
                     launch <= cell / 2;
                  elsif v_before < v_after then
                     launch <= cell / 2 - C_PRECOMP;
                  elsif v_before > v_after then
                     launch <= cell / 2 + C_PRECOMP;
                  else
                     launch <= cell / 2;
                  end if;
                  hist <= hist(2 downto 0) & q(31);
                  q    <= q(30 downto 0) & '0';
                  qn   <= qn - 1;
                  if sent /= 15 then
                     sent <= sent + 1;
                  end if;
                  f_wgate_o <= '0';
                  cc <= 1;
               end if;
            else
               if cc = launch and pulse = '1' then
                  f_wdata_o <= '0';
                  pw        <= cell / 4;
               end if;
               if cc = cell - 1 then
                  cc <= 0;
               else
                  cc <= cc + 1;
               end if;
            end if;
         elsif start_i = '1' then
            active <= '1';
            if hd_i = '1' then
               cell <= C_CELL_HD;
            else
               cell <= C_CELL_DD;
            end if;
            cc    <= 0;
            q     <= (others => '0');
            qn    <= 0;
            hist  <= (others => '0');
            sent  <= 0;
            k     <= 0;
            fetch <= 0;
            prev  <= '0';
            trk   <= track_i;
            pw    <= 0;
         end if;

         if abort_i = '1' or rst_i = '1' then
            active    <= '0';
            f_wgate_o <= '1';
            f_wdata_o <= '1';
            pw        <= 0;
         end if;
      end if;
   end process p_tx;

end architecture rtl;

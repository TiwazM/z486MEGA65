----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- fdd_phys: the MEGA65's internal floppy drive as one of the PC's floppy drives. pc_mgmt.vhd
-- hands it floppy.v's sector requests (cylinder, head, sector) instead of disk_sd's image
-- sectors; fdd_sound.vhd positions the head (it follows floppy.v's cylinder of that drive,
-- recalibrates on request, says when the head has settled) and runs the motor with the PC's.
--
-- Read:
--   * fdd_mfm_rx turns RDATA into IBM MFM bytes and A1 syncs. The parser here takes the byte
--     after a sync as an address mark: FE an ID field (C, H, R, N, CRC), FB or F8 a data
--     field (128 << N bytes, CRC), the CRC-CCITT over the three A1s, the mark and the field.
--     A data field belongs to the ID before it if it starts within 60 bytes of that ID's end.
--   * The track buffer: the sectors of the track under the head, a 512-byte slot each by
--     sector number (R mod 32), filled whenever the head is on the track the buffer holds
--     (one revolution reads the whole track: the PC's next sectors come out of it). Only
--     sectors whose CRC is right count (only 512-byte sectors, N = 2, are kept), only into
--     empty slots, so a later bad read never spoils a good copy.
--   * A request: the buffer moves to the request's track (emptied) if it held another; then
--     the head (fdd_sound) on the cylinder and settled, the motor spun up (an index pulse),
--     the side selected 200 us; then until the second index pulse (a whole revolution) for
--     the sector to arrive. The BIOS gives a command about 2 s (its motor-off count).
--     Without any ID field at the rate tried, the other rate (500 / 250 kbit/s) once; ID
--     fields of another cylinder: a recalibration once. Then the error, as an 82077's status
--     bytes ST2:ST1 (err_o): no ID field at all 0001 (MA), the sector's ID but no data field
--     0101 (MA, MD), its data with a CRC error 2020 (DE, DD), the sector not on the track 0004
--     (ND; 1004 with a wrong cylinder seen, WC). The rate that worked is kept for the next
--     track (tried first).
--   * The copy out (pc_mgmt reads the slot through buf_addr_i: first all 512 bytes in a row,
--     then again slowly into floppy.v's FIFO): the bytes as they come out are checked against
--     the CRC of the data as the parser stored it; one that does not match (buf_bad_o) makes
--     pc_mgmt ask again with fresh: the slot is emptied and read from the disk again.
--   * Write (a sector, as a PC's controller writes it): the 512 bytes come into the write buffer
--     first (wbuf_*); the head positioned as for a read; then the sector's ID field (at the rate
--     the disk was found to have, or found as for a read), 22 bytes of gap 2 after it, and
--     fdd_mfm_tx writes the data field over the old one (preamble, sync, FB, the data, CRC, 2
--     bytes of gap). The track buffer's copy of the sector is dropped (the next read comes from
--     the disk). Not found: the errors of a read. The drive's write protect tab (wp_o, for
--     floppy.v, which refuses the PC's write at once) is read while it is selected; a write
--     stops (WGATE closes) when the tab, the select, the motor or the head goes away: the
--     sector is then broken, as on a PC, and the PC gets 0010 (OR).
--   * FORMAT (a whole track, as a PC's controller formats one): floppy.v hands the track's ID
--     fields over one by one (req_fmt_i with a write request: C, H, R, N, as the PC gives them
--     by DMA), each answered at once; the last one (bit 61) writes the track: the head on the
--     cylinder (req_c_i, the PC's present cylinder number) and side (req_h_i), the rate by the
--     sector count (12 or more: 500 kbit/s, 1.44 MB, DMF; fewer: 250, 720 KB; kept for the reads
--     after; not the PC's data rate: the Bochs BIOS never sets one, and floppy.v's stays at its
--     reset value, 250), then from an index pulse the IBM
--     MFM layout an 82077 writes: gap 4a (80 x 4E), 12 x 00, the index address mark (C2 C2 C2
--     with the clock bit missing, FC), gap 1 (50 x 4E), then per sector 12 x 00, A1 A1 A1 FE,
--     the ID field, its CRC, gap 2 (22 x 4E), 12 x 00, A1 A1 A1 FB, 512 filler bytes, the CRC,
--     gap 3 (the command's length), and 4E (gap 4b) until the index comes round again (a track
--     overrunning it ends after its last sector). Gap 3 0 (the Bochs BIOS's FORMAT always sends
--     0) is the standard one, 84 bytes at 500 kbit/s and 80 at 250, made shorter until the
--     track fits a turn with 2 % to spare (DMF's 21 sectors: 8). fdd_mfm_tx writes it in track mode from the
--     generator here (p_gen). The track buffer empties: the next read comes from the disk.
--   * The disk change line for the PC (dskchg_o, floppy.v's DIR bit 7): the drive's DSKCHG,
--     read while the drive is selected (and kept while it is not), as a PC's controller passes
--     it on. It goes active when the disk comes out, and goes inactive with the next step with
--     a disk in (the PC's seek, which fdd_sound follows). The buffer empties when it goes
--     active, and the rate is tried again from the last one.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fdd_phys is
generic (
   G_CLK_HZ     : natural := 64_000_000;
   G_WRITE      : boolean := true                     -- false: read only (always write protected)
);
port (
   clk_i        : in  std_logic;
   rst_i        : in  std_logic;
   enable_i     : in  std_logic;                      -- a PC drive is the internal drive

   -- the drive (34-pin connector, active low; inputs asynchronous)
   f_rdata_i    : in  std_logic;
   f_wprot_i    : in  std_logic;
   f_side1_o    : out std_logic := '1';
   f_wdata_o    : out std_logic := '1';
   f_wgate_o    : out std_logic := '1';

   -- fdd_sound: the head and the motor
   sel_ok_i     : in  std_logic;                      -- selected and settled: lines valid
   sel_fast_i   : in  std_logic;                      -- selected a few us: DSKCHG valid
   idx_n_i      : in  std_logic;                      -- INDEX, synchronized
   chg_n_i      : in  std_logic;                      -- DSKCHG, synchronized
   motor_i      : in  std_logic;                      -- the motor runs
   head_cyl_i   : in  std_logic_vector(6 downto 0);   -- where the head is
   head_ready_i : in  std_logic;                      -- on its target, settled
   recal_o      : out std_logic := '0';               -- pulse: recalibrate

   -- pc_mgmt: the requests (a toggle, the rest stable with it) and the answers (a toggle)
   req_i        : in  std_logic;
   req_wr_i     : in  std_logic;
   req_fresh_i  : in  std_logic;
   req_c_i      : in  std_logic_vector(7 downto 0);
   req_h_i      : in  std_logic;
   req_r_i      : in  std_logic_vector(6 downto 0);
   -- FORMAT (with req_wr_i): 63 a FORMAT ID instead of a sector, 62 the track's first ID, 61
   -- its last, 60..59 the PC's data rate (not used), 47..40 gap 3, 39..32 the
   -- filler byte, 31..0 the ID field (C, H, R, N); req_c_i the head's cylinder, req_h_i the side
   req_fmt_i    : in  std_logic_vector(63 downto 0) := (others => '0');
   done_o       : out std_logic;
   err_o        : out std_logic_vector(15 downto 0) := (others => '0');   -- ST2:ST1, 0 = ok
   buf_addr_i   : in  std_logic_vector(8 downto 0);
   buf_rd_o     : out std_logic_vector(7 downto 0) := (others => '0');
   buf_bad_o    : out std_logic := '0';
   wbuf_we_i    : in  std_logic := '0';               -- the sector to write (milestone 2)
   wbuf_addr_i  : in  std_logic_vector(8 downto 0) := (others => '0');
   wbuf_wd_i    : in  std_logic_vector(7 downto 0) := (others => '0');

   -- floppy.v
   dskchg_o     : out std_logic := '1';               -- DIR bit 7: the disk changed
   wp_o         : out std_logic := '1';               -- write protected

   -- diagnostics (qmon.py fdd)
   stat_o       : out std_logic_vector(255 downto 0)
);
end entity fdd_phys;

architecture rtl of fdd_phys is

   constant C_US       : natural := G_CLK_HZ / 1_000_000;
   constant C_MS       : natural := G_CLK_HZ / 1_000;
   constant C_SIDE     : natural := 200 * C_US;
   constant C_IDX_LOW  : natural := 100 * C_US;      -- INDEX low this long: a pulse
   constant C_SPIN_TO  : natural := 1000 * C_MS;     -- no index pulse: no disk
   constant C_CAP_TO   : natural := 500 * C_MS;      -- two index pulses take 200-400 ms
   constant C_RECAL_W  : natural := 10 * C_MS;

   -- CRC-CCITT (x^16 + x^12 + x^5 + 1), MSB first
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

   -- the track buffer: 32 slots of 512 bytes
   type t_ram is array (0 to 16383) of std_logic_vector(7 downto 0);
   signal ram : t_ram;
   signal ram_we    : std_logic := '0';
   signal ram_wa    : unsigned(13 downto 0) := (others => '0');
   signal ram_wd    : std_logic_vector(7 downto 0) := (others => '0');
   signal ram_ra    : unsigned(13 downto 0);

   type t_crc32 is array (0 to 31) of unsigned(15 downto 0);
   type t_r32 is array (0 to 31) of std_logic_vector(6 downto 0);
   signal slot_ok   : std_logic_vector(31 downto 0) := (others => '0');   -- a good copy
   signal slot_crc  : t_crc32 := (others => (others => '0'));            -- of its 512 bytes
   signal slot_r    : t_r32 := (others => (others => '0'));
   signal seen      : std_logic_vector(31 downto 0) := (others => '0');   -- its ID seen
   signal bad       : std_logic_vector(31 downto 0) := (others => '0');   -- its data CRC wrong

   -- the drive
   signal rx_rst    : std_logic;
   signal hd        : std_logic := '1';           -- the rate tried: 500 kbit/s first
   signal rx_sync   : std_logic;
   signal rx_bv     : std_logic;
   signal rx_byte   : std_logic_vector(7 downto 0);
   signal rx_edge   : std_logic;
   signal rx_cell   : unsigned(12 downto 0);
   signal side      : std_logic := '0';
   signal side_cnt  : natural range 0 to C_SIDE := 0;
   signal idx_cnt   : natural range 0 to C_IDX_LOW := 0;
   signal idx_p     : std_logic := '0';           -- pulse: an index pulse
   signal spin      : natural range 0 to 1 := 0;  -- an index pulse since the motor started
   signal rx_kick   : std_logic := '0';           -- the rate changed: the PLL again
   signal id_ev     : std_logic := '0';           -- pulse: the track's ID field just ended,
   signal id_ev_r   : std_logic_vector(6 downto 0) := (others => '0');   -- for this sector

   -- writing
   type t_wram is array (0 to 511) of std_logic_vector(7 downto 0);
   signal wram      : t_wram;
   signal wram_a    : std_logic_vector(8 downto 0);
   signal wram_q    : std_logic_vector(7 downto 0) := (others => '0');
   signal tx_start  : std_logic := '0';
   signal tx_abort  : std_logic := '0';
   signal tx_busy   : std_logic;
   signal tx_seen   : std_logic := '0';           -- tx_busy was seen high
   signal n_wr      : unsigned(15 downto 0) := (others => '0');
   signal chg       : std_logic := '1';           -- DSKCHG as last read (active high)
   signal wp        : std_logic := '1';

   -- the track the buffer holds
   signal cur_ok    : std_logic := '0';
   signal cur_c     : std_logic_vector(7 downto 0) := (others => '0');
   signal cur_h     : std_logic := '0';
   signal cap_on    : std_logic;

   -- the parser
   type t_pst is (P_HUNT, P_ID, P_DATA);
   signal pst       : t_pst := P_HUNT;
   signal after_sync : std_logic := '0';
   signal pcnt      : natural range 0 to 1023 := 0;
   signal pcrc      : unsigned(15 downto 0) := (others => '0');   -- the field's CRC
   signal dcrc      : unsigned(15 downto 0) := (others => '0');   -- the data's own
   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0) := (others => '0');
   signal id_fresh  : std_logic := '0';           -- the last ID is the track's, N = 2
   signal id_since  : natural range 0 to 63 := 63;
   signal d_slot    : natural range 0 to 31 := 0;
   signal d_store   : std_logic := '0';
   signal d_size    : natural range 0 to 1023 := 511;

   -- per attempt
   signal ids       : unsigned(7 downto 0) := (others => '0');    -- good IDs this attempt
   signal wrong_cyl : std_logic := '0';

   -- FORMAT: the track's ID fields, then the track generator for fdd_mfm_tx's track mode
   constant C_FIDS  : natural := 64;
   type t_fid is array (0 to C_FIDS - 1) of std_logic_vector(31 downto 0);
   signal fid       : t_fid := (others => (others => '0'));
   signal fid_n     : natural range 0 to C_FIDS := 0;
   signal f_cnt     : natural range 0 to C_FIDS := 0;      -- the IDs of the track to write
   signal f_over    : std_logic := '0';                    -- more than C_FIDS
   signal f_gap     : natural range 1 to 255 := 84;        -- gap 3
   signal f_srch    : std_logic := '0';                    -- making gap 3 fit the turn
   signal r_fmt     : std_logic := '0';
   signal r_fv      : std_logic_vector(63 downto 0) := (others => '0');
   type t_gseg is (G_GAP4A, G_SYNC0, G_IAM, G_IAMFC, G_GAP1, G_ISYNC, G_IA1, G_IFE, G_ID,
                   G_ICRC, G_GAP2, G_DSYNC, G_DA1, G_DFB, G_DATA, G_DCRC, G_GAP3, G_GAP4B);
   signal g_seg     : t_gseg := G_GAP4A;
   signal g_n       : natural range 0 to 511 := 0;         -- the byte within the segment
   signal g_sec     : natural range 0 to C_FIDS := 0;
   signal g_crc     : unsigned(15 downto 0) := (others => '0');
   signal g_idx     : std_logic := '0';                    -- the index came round again
   signal g_go      : std_logic := '0';                    -- pulse: from the start
   signal g_byte    : std_logic_vector(7 downto 0) := x"4E";
   signal g_kind    : std_logic_vector(1 downto 0) := "00";
   signal g_end     : std_logic := '0';
   signal s_req     : std_logic;

   -- the request
   type t_st is (S_IDLE, S_SETUP, S_POS, S_CAP, S_EVAL, S_RECAL, S_DONE,
                 S_WFIND, S_WGAP, S_WRITE, S_FPOS, S_FIDX, S_FTRK);
   signal st        : t_st := S_IDLE;
   signal req_s     : std_logic_vector(2 downto 0) := (others => '0');
   signal r_wr      : std_logic := '0';
   signal r_fresh   : std_logic := '0';
   signal r_c       : std_logic_vector(7 downto 0) := (others => '0');
   signal r_h       : std_logic := '0';
   signal r_r       : std_logic_vector(6 downto 0) := (others => '0');
   signal r_slot    : natural range 0 to 31 := 0;
   signal rate_tried : std_logic := '0';
   signal recal_done : std_logic := '0';
   signal revs      : natural range 0 to 1 := 0;
   signal tmr       : natural range 0 to C_SPIN_TO := 0;
   signal err       : std_logic_vector(15 downto 0) := (others => '0');

   -- the copy out's check
   signal out_slot  : natural range 0 to 31 := 0;
   signal ca_d      : unsigned(9 downto 0) := (others => '1');
   signal c_exp     : unsigned(9 downto 0) := (others => '0');
   signal c_crc     : unsigned(15 downto 0) := (others => '1');
   signal c_bad     : std_logic := '0';
   signal c_arm     : std_logic := '0';           -- done_r as last seen: a new slot to check
   signal done_r    : std_logic := '0';
   signal ram_q     : std_logic_vector(7 downto 0) := (others => '0');

   -- diagnostics
   signal n_req, n_err, n_ids, n_data, n_crc, n_sync : unsigned(15 downto 0) := (others => '0');
   signal last_id   : std_logic_vector(31 downto 0) := (others => '0');
   signal idx_per   : unsigned(15 downto 0) := (others => '0');   -- in 100 us
   signal idx_tmr   : unsigned(15 downto 0) := (others => '0');
   signal tick100   : natural range 0 to 100 * C_US - 1 := 0;

   attribute async_reg : string;
   signal wp_m, wp_s : std_logic := '1';
   attribute async_reg of wp_m, wp_s : signal is "true";

begin

   i_rx : entity work.fdd_mfm_rx
      generic map (
         G_CLK_HZ     => G_CLK_HZ
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rx_rst,
         hd_i         => hd,
         rdata_i      => f_rdata_i,
         sync_o       => rx_sync,
         byte_valid_o => rx_bv,
         byte_o       => rx_byte,
         edge_o       => rx_edge,
         cell_o       => rx_cell
      );

   i_tx : entity work.fdd_mfm_tx
      generic map (
         G_CLK_HZ     => G_CLK_HZ
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         hd_i         => hd,
         start_i      => tx_start,
         track_i      => r_fmt,
         s_req_o      => s_req,
         s_byte_i     => g_byte,
         s_kind_i     => g_kind,
         s_end_i      => g_end,
         abort_i      => tx_abort,
         data_addr_o  => wram_a,
         data_i       => wram_q,
         busy_o       => tx_busy,
         f_wdata_o    => f_wdata_o,
         f_wgate_o    => f_wgate_o
      );

   -- the sector to write (pc_mgmt fills it before it asks)
   p_wram : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wbuf_we_i = '1' then
            wram(to_integer(unsigned(wbuf_addr_i))) <= wbuf_wd_i;
         end if;
         wram_q <= wram(to_integer(unsigned(wram_a)));
      end if;
   end process p_wram;

   -- read while the head is on the buffer's track, settled, the side selected (not writing)
   cap_on <= '1' when enable_i = '1' and motor_i = '1' and sel_ok_i = '1' and
                      head_ready_i = '1' and side_cnt = 0 and cur_ok = '1' and
                      head_cyl_i = cur_c(6 downto 0) and side = cur_h and tx_busy = '0' else '0';
   rx_rst <= not cap_on or rx_kick;

   f_side1_o <= not side;
   dskchg_o  <= chg;
   wp_o      <= wp when G_WRITE else '1';

   -- the track buffer
   p_ram_w : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if ram_we = '1' then
            ram(to_integer(ram_wa)) <= ram_wd;
         end if;
      end if;
   end process p_ram_w;

   ram_ra <= to_unsigned(out_slot, 5) & unsigned(buf_addr_i);

   p_ram_r : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ram_q <= ram(to_integer(ram_ra));
      end if;
   end process p_ram_r;

   buf_rd_o  <= ram_q;
   done_o    <= done_r;
   buf_bad_o <= c_bad;

   -- the copy out's check: the bytes read in a row from address 0 (ram_q is the byte of the
   -- address a clock ago), against the slot's CRC when all 512 are through. It starts again
   -- at address 0 after another address, and at the first address 0 after an answer
   p_check : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ca_d <= '0' & unsigned(buf_addr_i);
         if unsigned(buf_addr_i) = 0 and (ca_d /= 0 or c_arm /= done_r) then
            c_arm <= done_r;
            c_exp <= (others => '0');
            c_crc <= x"FFFF";
         elsif ca_d = c_exp and c_exp < 512 then
            c_crc <= crc_upd(c_crc, ram_q);
            c_exp <= c_exp + 1;
            if c_exp = 511 then
               if crc_upd(c_crc, ram_q) /= slot_crc(out_slot) or slot_ok(out_slot) = '0' then
                  c_bad <= '1';
               else
                  c_bad <= '0';
               end if;
            end if;
         end if;
      end if;
   end process p_check;

   p_main : process (clk_i)
      variable v_crc  : unsigned(15 downto 0);
      variable v_slot : natural range 0 to 31;
      variable v_i    : natural range 0 to C_FIDS;
   begin
      if rising_edge(clk_i) then
         ram_we  <= '0';
         g_go    <= '0';
         recal_o <= '0';
         rx_kick <= '0';
         id_ev   <= '0';
         tx_start <= '0';
         tx_abort <= '0';
         idx_p   <= '0';
         req_s   <= req_s(1 downto 0) & req_i;

         wp_m <= f_wprot_i;
         wp_s <= wp_m;
         if sel_ok_i = '1' then
            wp <= not wp_s;
         end if;

         if side_cnt /= 0 then
            side_cnt <= side_cnt - 1;
         end if;

         -- index pulses (INDEX low C_IDX_LOW), their period, the spin-up
         if sel_ok_i = '1' and idx_n_i = '0' then
            if idx_cnt = C_IDX_LOW - 1 then
               idx_p <= '1';
            end if;
            if idx_cnt /= C_IDX_LOW then
               idx_cnt <= idx_cnt + 1;
            end if;
         else
            idx_cnt <= 0;
         end if;
         if tick100 = 100 * C_US - 1 then
            tick100 <= 0;
            if idx_tmr /= x"FFFF" then
               idx_tmr <= idx_tmr + 1;
            end if;
         else
            tick100 <= tick100 + 1;
         end if;
         if idx_p = '1' then
            idx_per <= idx_tmr;
            idx_tmr <= (others => '0');
            spin <= 1;
         end if;
         if motor_i = '0' or sel_ok_i = '0' then
            spin <= 0;
         end if;

         -- the disk change line, read while selected; the buffer empties when it goes active
         if sel_fast_i = '1' then
            chg <= not chg_n_i;
            if chg = '0' and chg_n_i = '0' then
               cur_ok  <= '0';
               slot_ok <= (others => '0');
               seen    <= (others => '0');
               bad     <= (others => '0');
            end if;
         end if;

         if rx_sync = '1' then
            n_sync <= n_sync + 1;
         end if;

         ------------------------------------------------------------------------------------
         -- the parser
         ------------------------------------------------------------------------------------
         if cap_on = '0' then
            pst        <= P_HUNT;
            after_sync <= '0';
            id_fresh   <= '0';
         elsif rx_sync = '1' then
            after_sync <= '1';
            pst        <= P_HUNT;                   -- (a sync inside a field ends it)
         elsif rx_bv = '1' then
            after_sync <= '0';
            case pst is
               when P_HUNT =>
                  if id_since /= 63 then
                     id_since <= id_since + 1;
                  end if;
                  if after_sync = '1' then
                     pcrc <= crc_upd(C_CRC_A1, rx_byte);
                     pcnt <= 0;
                     if rx_byte = x"FE" then
                        pst <= P_ID;
                     elsif (rx_byte = x"FB" or rx_byte = x"F8") and id_fresh = '1' and
                           id_since < 60 then
                        v_slot   := to_integer(unsigned(id_r(4 downto 0)));
                        d_slot   <= v_slot;
                        d_store  <= not slot_ok(v_slot);
                        d_size   <= 511;
                        dcrc     <= x"FFFF";
                        id_fresh <= '0';
                        pst      <= P_DATA;
                     end if;
                  end if;

               when P_ID =>
                  pcrc <= crc_upd(pcrc, rx_byte);
                  pcnt <= pcnt + 1;
                  case pcnt is
                     when 0 => id_c <= rx_byte;
                     when 1 => id_h <= rx_byte;
                     when 2 => id_r <= rx_byte;
                     when 3 => id_n <= rx_byte;
                     when 4 => null;
                     when others =>
                        pst      <= P_HUNT;
                        id_since <= 0;
                        id_fresh <= '0';
                        if crc_upd(pcrc, rx_byte) = 0 then
                           n_ids   <= n_ids + 1;
                           ids     <= ids + 1;
                           last_id <= id_c & id_h & id_r & id_n;
                           if id_c /= cur_c then
                              wrong_cyl <= '1';
                           elsif id_h(0) = cur_h and id_h(7 downto 1) = "0000000" and
                                 id_n = x"02" and id_r(7) = '0' then
                              id_fresh <= '1';
                              id_ev    <= '1';
                              id_ev_r  <= id_r(6 downto 0);
                              v_slot   := to_integer(unsigned(id_r(4 downto 0)));
                              seen(v_slot)   <= '1';
                              slot_r(v_slot) <= id_r(6 downto 0);
                           end if;
                        end if;
                  end case;

               when P_DATA =>
                  pcrc <= crc_upd(pcrc, rx_byte);
                  if pcnt <= d_size then
                     dcrc   <= crc_upd(dcrc, rx_byte);
                     ram_we <= d_store;
                     ram_wa <= to_unsigned(d_slot, 5) & to_unsigned(pcnt, 9);
                     ram_wd <= rx_byte;
                  end if;
                  if pcnt = d_size + 2 then
                     pst <= P_HUNT;
                     if crc_upd(pcrc, rx_byte) = 0 then
                        n_data <= n_data + 1;
                        if d_store = '1' then
                           slot_ok(d_slot)  <= '1';
                           slot_crc(d_slot) <= dcrc;
                           bad(d_slot)      <= '0';
                        end if;
                     else
                        n_crc <= n_crc + 1;
                        if slot_ok(d_slot) = '0' then
                           bad(d_slot) <= '1';
                        end if;
                     end if;
                  else
                     pcnt <= pcnt + 1;
                  end if;
            end case;
         end if;

         ------------------------------------------------------------------------------------
         -- the requests
         ------------------------------------------------------------------------------------
         if tmr /= 0 then
            tmr <= tmr - 1;
         end if;

         case st is
            when S_IDLE =>
               if req_s(2) /= req_s(1) then
                  r_wr    <= req_wr_i;
                  r_fresh <= req_fresh_i;
                  r_c     <= req_c_i;
                  r_h     <= req_h_i;
                  r_r     <= req_r_i;
                  r_fmt   <= req_fmt_i(63) and req_wr_i;
                  r_fv    <= req_fmt_i;
                  r_slot  <= to_integer(unsigned(req_r_i(4 downto 0)));
                  n_req   <= n_req + 1;
                  st      <= S_SETUP;
               end if;

            when S_SETUP =>
               rate_tried <= '0';
               recal_done <= '0';
               if r_wr = '1' and (wp = '1' or not G_WRITE) then
                  err <= x"0002";                   -- NW: the tab
                  st  <= S_DONE;
               elsif r_fmt = '1' then
                  -- a FORMAT ID into the list (answered at once); the last writes the track
                  if r_fv(62) = '1' then
                     v_i    := 0;
                     f_over <= '0';
                  else
                     v_i := fid_n;
                  end if;
                  if v_i < C_FIDS then
                     fid(v_i) <= r_fv(31 downto 0);
                     fid_n    <= v_i + 1;
                     f_cnt    <= v_i + 1;
                  else
                     f_over <= '1';
                  end if;
                  if r_fv(61) = '0' then
                     err <= x"0000";
                     st  <= S_DONE;
                  else
                     cur_ok  <= '0';                -- the track changes
                     slot_ok <= (others => '0');
                     seen    <= (others => '0');
                     bad     <= (others => '0');
                     if side /= r_h then
                        side     <= r_h;
                        side_cnt <= C_SIDE;
                     end if;
                     if v_i >= 11 then             -- (v_i + 1 sectors)
                        hd    <= '1';               -- 500 kbit/s: 1.44 MB, DMF
                        f_gap <= 84;
                     else
                        hd    <= '0';               -- 250: 720 KB
                        f_gap <= 80;
                     end if;
                     f_srch <= '1';
                     if unsigned(r_fv(47 downto 40)) /= 0 then
                        f_gap  <= to_integer(unsigned(r_fv(47 downto 40)));
                        f_srch <= '0';
                     end if;
                     tmr <= C_SPIN_TO;
                     st  <= S_FPOS;
                  end if;
               else
                  if cur_ok = '0' or r_c /= cur_c or r_h /= cur_h then
                     cur_ok  <= '1';
                     cur_c   <= r_c;
                     cur_h   <= r_h;
                     slot_ok <= (others => '0');
                     seen    <= (others => '0');
                     bad     <= (others => '0');
                  elsif r_fresh = '1' then
                     slot_ok(r_slot) <= '0';
                     bad(r_slot)     <= '0';
                  end if;
                  if side /= r_h then
                     side     <= r_h;
                     side_cnt <= C_SIDE;
                  end if;
                  tmr <= C_SPIN_TO;
                  st  <= S_POS;
               end if;

            when S_POS =>
               if motor_i = '1' and sel_ok_i = '1' and spin = 1 and head_ready_i = '1' and
                  head_cyl_i = r_c(6 downto 0) and side_cnt = 0 then
                  revs      <= 0;
                  ids       <= (others => '0');
                  wrong_cyl <= '0';
                  tmr       <= C_CAP_TO;
                  if r_wr = '1' then
                     st <= S_WFIND;
                  else
                     st <= S_CAP;
                  end if;
               elsif tmr = 0 then
                  err <= x"0001";                   -- no disk (no index pulses): MA
                  st  <= S_DONE;
               end if;

            when S_CAP =>
               if slot_ok(r_slot) = '1' and slot_r(r_slot) = r_r then
                  err <= x"0000";
                  st  <= S_DONE;
               elsif idx_p = '1' then
                  if revs = 1 then
                     st <= S_EVAL;
                  else
                     revs <= revs + 1;
                  end if;
               elsif tmr = 0 then
                  st <= S_EVAL;
               end if;

            when S_EVAL =>
               if ids = 0 then
                  if rate_tried = '0' then
                     rate_tried <= '1';
                     hd         <= not hd;          -- the other rate
                     rx_kick    <= '1';
                     tmr        <= C_SPIN_TO;
                     st         <= S_POS;
                  else
                     err <= x"0001";                -- MA
                     st  <= S_DONE;
                  end if;
               elsif wrong_cyl = '1' and recal_done = '0' then
                  recal_done <= '1';
                  recal_o    <= '1';
                  tmr        <= C_RECAL_W;
                  st         <= S_RECAL;
               elsif bad(r_slot) = '1' then
                  err <= x"2020";                   -- DE, DD
                  st  <= S_DONE;
               elsif seen(r_slot) = '1' and slot_r(r_slot) = r_r then
                  err <= x"0101";                   -- MA, MD
                  st  <= S_DONE;
               elsif wrong_cyl = '1' then
                  err <= x"1004";                   -- ND, WC
                  st  <= S_DONE;
               else
                  err <= x"0004";                   -- ND
                  st  <= S_DONE;
               end if;

            -- a write: the sector's ID field, then gap 2 (22 bytes of 16 cells), then the field
            when S_WFIND =>
               if id_ev = '1' and id_ev_r = r_r then
                  if hd = '1' then
                     tmr <= 22 * 16 * C_US;
                  else
                     tmr <= 22 * 32 * C_US;
                  end if;
                  st <= S_WGAP;
               elsif idx_p = '1' then
                  if revs = 1 then
                     st <= S_EVAL;
                  else
                     revs <= revs + 1;
                  end if;
               elsif tmr = 0 then
                  st <= S_EVAL;
               end if;

            when S_WGAP =>
               if tmr = 0 then
                  tx_start <= '1';
                  tx_seen  <= '0';
                  n_wr     <= n_wr + 1;
                  st       <= S_WRITE;
               end if;

            when S_WRITE =>
               if tx_busy = '1' then
                  tx_seen <= '1';
               end if;
               if motor_i = '0' or sel_ok_i = '0' or wp = '1' or head_ready_i = '0' or
                  enable_i = '0' then
                  tx_abort <= '1';
                  err      <= x"0010";              -- OR: the write was cut short
                  st       <= S_DONE;
               elsif tx_seen = '1' and tx_busy = '0' then
                  slot_ok(r_slot) <= '0';           -- the next read from the disk
                  bad(r_slot)     <= '0';
                  err             <= x"0000";
                  st              <= S_DONE;
               end if;

            -- FORMAT: the head on the cylinder, then the track from an index pulse
            when S_FPOS =>
               -- (the standard gap 3 shorter until the track fits: 12500 or 6250 bytes a turn)
               if f_srch = '1' then
                  if f_gap > 1 and ((hd = '1' and f_cnt * (574 + f_gap) + 146 > 12250) or
                                    (hd = '0' and f_cnt * (574 + f_gap) + 146 > 6125)) then
                     f_gap <= f_gap - 1;
                  else
                     f_srch <= '0';
                  end if;
               elsif motor_i = '1' and sel_ok_i = '1' and spin = 1 and head_ready_i = '1' and
                  head_cyl_i = r_c(6 downto 0) and side_cnt = 0 then
                  tmr <= C_CAP_TO;
                  st  <= S_FIDX;
               elsif tmr = 0 then
                  err <= x"0001";                   -- no disk (no index pulses): MA
                  st  <= S_DONE;
               end if;

            when S_FIDX =>
               if idx_p = '1' then
                  g_go     <= '1';
                  tx_start <= '1';
                  tx_seen  <= '0';
                  tmr      <= C_CAP_TO;
                  st       <= S_FTRK;
               elsif tmr = 0 then
                  err <= x"0001";
                  st  <= S_DONE;
               end if;

            when S_FTRK =>
               if tx_busy = '1' then
                  tx_seen <= '1';
               end if;
               if motor_i = '0' or sel_ok_i = '0' or wp = '1' or head_ready_i = '0' or
                  enable_i = '0' or tmr = 0 then
                  tx_abort <= '1';
                  err      <= x"0010";              -- OR: the track was cut short
                  st       <= S_DONE;
               elsif tx_seen = '1' and tx_busy = '0' then
                  n_wr <= n_wr + f_cnt;
                  if f_over = '1' then
                     err <= x"0010";                -- more IDs than it holds
                  else
                     err <= x"0000";
                  end if;
                  st <= S_DONE;
               end if;

            when S_RECAL =>
               if tmr = 0 then
                  tmr <= C_SPIN_TO;
                  st  <= S_POS;
               end if;

            when S_DONE =>
               out_slot <= r_slot;
               err_o    <= err;
               done_r   <= not done_r;
               if err /= x"0000" then
                  n_err <= n_err + 1;
               end if;
               st <= S_IDLE;
         end case;

         if enable_i = '0' or rst_i = '1' then
            cur_ok <= '0';
            if st /= S_IDLE and st /= S_DONE and st /= S_WRITE and st /= S_FTRK then
               err <= x"0001";
               st  <= S_DONE;
            end if;
         end if;
      end if;
   end process p_main;

   -- FORMAT's track for fdd_mfm_tx (track mode): a byte for each s_req, from the clock after
   p_gen : process (clk_i)
      variable v_b    : std_logic_vector(7 downto 0);
      variable v_k    : std_logic_vector(1 downto 0);
      variable v_id   : std_logic_vector(31 downto 0);
      procedure nxt(n : natural; s : t_gseg) is      -- the segment's n bytes done: then s
      begin
         if g_n = n - 1 then
            g_n   <= 0;
            g_seg <= s;
         else
            g_n <= g_n + 1;
         end if;
      end procedure nxt;
   begin
      if rising_edge(clk_i) then
         if g_sec < C_FIDS then
            v_id := fid(g_sec);
         else
            v_id := (others => '0');
         end if;
         if g_go = '1' then
            g_seg <= G_GAP4A;
            g_n   <= 0;
            g_sec <= 0;
            g_idx <= '0';
            g_end <= '0';
         else
            if idx_p = '1' then
               g_idx <= '1';
            end if;
            if s_req = '1' then
               v_b := x"4E";
               v_k := "00";
               case g_seg is
                  when G_GAP4A => nxt(80, G_SYNC0);
                  when G_SYNC0 => v_b := x"00"; nxt(12, G_IAM);
                  when G_IAM   => v_b := x"C2"; v_k := "10"; nxt(3, G_IAMFC);
                  when G_IAMFC => v_b := x"FC"; nxt(1, G_GAP1);
                  when G_GAP1  =>
                     if f_cnt = 0 then
                        nxt(50, G_GAP4B);
                     else
                        nxt(50, G_ISYNC);
                     end if;
                  when G_ISYNC => v_b := x"00"; nxt(12, G_IA1);
                  when G_IA1   => v_b := x"A1"; v_k := "01"; nxt(3, G_IFE);
                  when G_IFE   =>
                     v_b   := x"FE";
                     g_crc <= crc_upd(C_CRC_A1, x"FE");
                     nxt(1, G_ID);
                  when G_ID    =>
                     case g_n is
                        when 0      => v_b := v_id(31 downto 24);
                        when 1      => v_b := v_id(23 downto 16);
                        when 2      => v_b := v_id(15 downto 8);
                        when others => v_b := v_id(7 downto 0);
                     end case;
                     g_crc <= crc_upd(g_crc, v_b);
                     nxt(4, G_ICRC);
                  when G_ICRC  =>
                     if g_n = 0 then
                        v_b := std_logic_vector(g_crc(15 downto 8));
                     else
                        v_b := std_logic_vector(g_crc(7 downto 0));
                     end if;
                     nxt(2, G_GAP2);
                  when G_GAP2  => nxt(22, G_DSYNC);
                  when G_DSYNC => v_b := x"00"; nxt(12, G_DA1);
                  when G_DA1   => v_b := x"A1"; v_k := "01"; nxt(3, G_DFB);
                  when G_DFB   =>
                     v_b   := x"FB";
                     g_crc <= crc_upd(C_CRC_A1, x"FB");
                     nxt(1, G_DATA);
                  when G_DATA  =>
                     v_b   := r_fv(39 downto 32);
                     g_crc <= crc_upd(g_crc, v_b);
                     nxt(512, G_DCRC);
                  when G_DCRC  =>
                     if g_n = 0 then
                        v_b := std_logic_vector(g_crc(15 downto 8));
                     else
                        v_b := std_logic_vector(g_crc(7 downto 0));
                     end if;
                     nxt(2, G_GAP3);
                  when G_GAP3  =>
                     if g_n = f_gap - 1 then
                        g_n <= 0;
                        if g_sec + 1 >= f_cnt then
                           g_seg <= G_GAP4B;
                           g_end <= g_idx;          -- overran the index: ends here
                        else
                           g_sec <= g_sec + 1;
                           g_seg <= G_ISYNC;
                        end if;
                     else
                        g_n <= g_n + 1;
                     end if;
                  when G_GAP4B =>
                     g_end <= g_idx;                -- 4E until the index comes round
               end case;
               g_byte <= v_b;
               g_kind <= v_k;
            end if;
         end if;
      end if;
   end process p_gen;

   -- qmon.py fdd: 16 words, word k in bits 255 - 16k downto 240 - 16k
   stat_o <= std_logic_vector(n_req) &                                      -- 0
             std_logic_vector(n_err) &                                      -- 1
             err &                                                          -- 2
             std_logic_vector(n_ids) &                                      -- 3
             std_logic_vector(n_data) &                                     -- 4
             std_logic_vector(n_crc) &                                      -- 5
             std_logic_vector(n_wr) &                                       -- 6
             last_id(31 downto 16) & last_id(15 downto 0) &                 -- 7, 8
             cur_c & "000" & cur_ok & hd & cur_h & side & wp &              -- 9
             '0' & head_cyl_i & std_logic_vector(to_unsigned(t_st'pos(st), 4)) &
                motor_i & sel_ok_i & head_ready_i & chg &                   -- 10
             "000" & std_logic_vector(rx_cell) &                            -- 11
             std_logic_vector(idx_per) &                                    -- 12
             slot_ok(31 downto 16) & slot_ok(15 downto 0) &                 -- 13, 14
             '0' & r_r & r_c;                                               -- 15

end architecture rtl;

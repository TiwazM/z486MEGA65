----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The CD-ROM drive: an ATAPI device, the master of the PC's second IDE channel (z486_MiSTer's
-- ide.v at management page F1xx, IRQ 15), with an ISO image file on the SD card as its disc
-- (disk_sd.vhd's unit 3). What Main_MiSTer's ide.cpp and ide_cdrom.cpp do for ao486 on the ARM
-- side, in hardware, next to pc_mgmt.vhd's hard disk. pc_mgmt owns the management bus: it grants
-- it to the drive (bus_req_o / bus_gnt_i) and passes the sector requests and the sector buffer
-- through while it does.
--
--   * Always there, with or without a disc (a drive with its tray empty): after a reset the
--     ATAPI signature (sector count 1, sector 1, cylinder EB14h, status 00h); IDENTIFY DEVICE
--     is aborted with it, IDENTIFY PACKET DEVICE (PIO only), DEVICE RESET, EXECUTE DIAGNOSTIC
--     and the power and feature commands work. The slave is never there (as on the first
--     channel: its cylinder reads FFFFh after a reset, its commands are aborted).
--   * PACKET: DRQ for the 12-byte command (interrupt reason CoD, no interrupt), then the
--     command: TEST UNIT READY, REQUEST SENSE, INQUIRY, MODE SENSE (6) and (10) (pages 01h,
--     0Dh, 0Eh, 2Ah and 3Fh), MODE SELECT (its data dropped), START STOP UNIT, PREVENT ALLOW
--     MEDIUM REMOVAL, READ CAPACITY, READ (10) and (12), SEEK, READ TOC (formats 0 and 1, LBA
--     and MSF), READ SUB-CHANNEL (nothing playing), PAUSE/RESUME and STOP PLAY; anything else,
--     CD audio among it (a data disc has none), ends in CHECK CONDITION, ILLEGAL REQUEST.
--   * Data in DRQ blocks of at most 2048 bytes and the byte count limit the PC gave (the
--     cylinder register; 0 counts as FFFEh), each with an interrupt (interrupt reason IO, the
--     block's bytes in the cylinder register); then the end: interrupt reason IO + CoD, DRDY,
--     an interrupt. An error: ERR, the sense key in the error register's high nibble (ABRT
--     with ILLEGAL REQUEST), the sense data for REQUEST SENSE. A new disc: UNIT ATTENTION
--     (6/28h) once; none: NOT READY, MEDIUM NOT PRESENT (2/3Ah).
--   * READ: a 2048-byte sector is four of the image's 512-byte sectors; each READ tells disk_sd
--     the sectors still to come (sd_req_cnt_o), which it reads ahead in one SD transfer.
--
-- ide.v's buffer is filled before the registers that announce a block (pc_mgmt's way, no fast
-- reads), through register F after a write to register 6 (no bits: it changes nothing, but
-- rewinds the buffer pointer, as any other register does). Register 0's low byte 80h, then
-- register 4, set ide.v's block size in words exactly.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_cdrom is
   port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;

      -- the management bus, while pc_mgmt grants it
      bus_req_o         : out std_logic := '0';
      bus_gnt_i         : in  std_logic;
      mgmt_address_o    : out std_logic_vector(15 downto 0) := (others => '0');
      mgmt_read_o       : out std_logic := '0';
      mgmt_write_o      : out std_logic := '0';
      mgmt_writedata_o  : out std_logic_vector(15 downto 0) := (others => '0');
      mgmt_readdata_i   : in  std_logic_vector(15 downto 0);
      ide_request_i     : in  std_logic_vector(2 downto 0);  -- 110 reset, 100 command, 101 block

      -- the disc (disk_sd's unit 3, crossed by pc_mgmt): 39 mounted, 37..6 sectors of 512
      -- bytes, 3..0 the mount generation
      mnt_i             : in  std_logic_vector(39 downto 0);

      -- sector requests to disk_sd's unit 3 (a toggle; lba and cnt stable from one clock before
      -- it) and its answers (QNICE clock: a toggle, err stable with it)
      sd_req_o          : out std_logic := '0';
      sd_req_lba_o      : out std_logic_vector(31 downto 0) := (others => '0');
      sd_req_cnt_o      : out std_logic_vector(8 downto 0) := (others => '0');
      sd_req_fresh_o    : out std_logic := '0';   -- the sector fresh from the card (a new run)
      sd_done_i         : in  std_logic;
      sd_err_i          : in  std_logic;

      -- the sector buffer (disk_sd's ring slot of the answer; read data one clock later)
      buf_addr_o        : out std_logic_vector(8 downto 0);
      buf_rd_i          : in  std_logic_vector(7 downto 0);
      buf_bad_i         : in  std_logic := '0';   -- disk_sd: the last copy did not match

      -- the IDE trace (pc_mgmt.vhd's format): 6 an SD answer (B = 3, the unit), 8 a command
      -- (A command, B drive/head, C features, data the byte count limit & sector), 9 its
      -- registers set (A status, B error, C interrupt reason, data byte count & block words),
      -- 10 a packet (A, B, C its bytes 0, 1, 8, data bytes 2..5), 11 request 101 (A the phase:
      -- 1 packet, 2 data in, 3 data out; data the transfer's position), 12 a reset (A
      -- drive/head)
      trace_we_o        : out std_logic := '0';
      trace_o           : out std_logic_vector(63 downto 0) := (others => '0')
   );
end entity pc_cdrom;

architecture synthesis of pc_cdrom is

   constant C_IDE    : std_logic_vector(7 downto 0) := x"F1";
   constant C_CHUNK  : natural := 2048;            -- bytes per DRQ block at most

   -- register 5's high byte as ide.v takes it (pc_mgmt's w_st): 15..14 BSY, DRDY, 12 DSC, 11 DRQ,
   -- 10 the interrupt, 9 the last block (ide.v then goes ready by itself), 8 ERR
   constant C_ST_PKT  : std_logic_vector(7 downto 0) := x"58";   -- DRQ for the packet
   constant C_ST_DATA : std_logic_vector(7 downto 0) := x"5C";   -- a data block: DRQ, interrupt
   constant C_ST_ATA  : std_logic_vector(7 downto 0) := x"5E";   -- IDENTIFY's block, the last
   constant C_ST_OK   : std_logic_vector(7 downto 0) := x"54";   -- done, interrupt
   constant C_ST_ERR  : std_logic_vector(7 downto 0) := x"45";   -- ERR, interrupt

   -- IDENTIFY PACKET DEVICE (strings: the first character in the high byte)
   constant C_MODEL  : string(1 to 40) := "z486 MEGA65 CD-ROM                      ";
   constant C_SERIAL : string(1 to 20) := "Z486CD0001          ";
   constant C_FW     : string(1 to 8)  := "1.00    ";

   function pair(s : string; i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * i)), 8)) &
             std_logic_vector(to_unsigned(character'pos(s(s'low + 2 * i + 1)), 8));
   end function pair;

   function ident(k : natural) return std_logic_vector is
   begin
      case k is
         when 0        => return x"85C0";      -- ATAPI, CD-ROM, removable, DRQ within 50 us,
                                               -- 12-byte packets
         when 10 to 19 => return pair(C_SERIAL, k - 10);
         when 23 to 26 => return pair(C_FW, k - 23);
         when 27 to 46 => return pair(C_MODEL, k - 27);
         when 49       => return x"0200";      -- LBA, no DMA
         when 51       => return x"0200";      -- PIO timing mode 2
         when 53       => return x"0002";      -- words 64-70 valid
         when 64       => return x"0003";      -- PIO modes 3 and 4
         when 65 to 68 => return x"0078";      -- 120 ns cycles
         when 80       => return x"001E";      -- ATA/ATAPI-1 to -4
         when 82 | 85  => return x"4210";      -- NOP, DEVICE RESET, PACKET
         when 83 | 84 | 86 | 87 => return x"4000";
         when others   => return x"0000";
      end case;
   end function ident;

   -- INQUIRY's vendor, product and revision
   constant C_INQ : string(1 to 28) := "z486    MEGA65 CD-ROM   1.00";

   -- MODE SENSE's pages (0 read error recovery 01h, 1 CD parameters 0Dh, 2 CD audio control
   -- 0Eh, 3 capabilities 2Ah), byte k
   function mode_page(pg : natural; k : natural) return std_logic_vector is
   begin
      case pg is
         when 0 =>
            case k is
               when 0 => return x"01";
               when 1 => return x"06";
               when 3 => return x"05";          -- read retries
               when others => return x"00";
            end case;
         when 1 =>
            case k is
               when 0 => return x"0D";
               when 1 => return x"06";
               when 5 => return x"3C";          -- 60 seconds per minute
               when 7 => return x"4B";          -- 75 frames per second
               when others => return x"00";
            end case;
         when 2 =>
            case k is
               when 0  => return x"0E";
               when 1  => return x"0E";
               when 2  => return x"04";         -- immediate
               when 8  => return x"01";         -- port 0: channel 0, full volume
               when 9  => return x"FF";
               when 10 => return x"02";         -- port 1: channel 1, full volume
               when 11 => return x"FF";
               when others => return x"00";
            end case;
         when others =>
            case k is
               when 0  => return x"2A";
               when 1  => return x"12";
               when 6  => return x"29";         -- lock, eject, a tray
               when 8  => return x"0B";         -- 2816 KB/s at most
               when 10 => return x"01";         -- 256 volume levels
               when 13 => return x"80";         -- a 128 KB buffer
               when 14 => return x"0B";         -- 2816 KB/s now
               when others => return x"00";
            end case;
      end case;
   end function mode_page;

   function nmin(a, b : natural) return natural is
   begin
      if a < b then
         return a;
      end if;
      return b;
   end function nmin;

   function n32(n : natural) return unsigned is
   begin
      return to_unsigned(n, 32);
   end function n32;

   type t_state is (
      S_IDLE, S_GNT, S_REL,
      S_INIT,
      S_RST1, S_RST2,
      S_CMD0, S_CMD1, S_CMD2, S_CMD3, S_CMD,
      S_BLK, S_POP, S_SCSI,
      S_CHUNK, S_STREAM, S_CHK, S_SD_ASK, S_SD_WAIT, S_REGS,
      S_WREGS, S_BUS_W, S_BUS_R
   );
   signal state       : t_state := S_IDLE;
   signal ret         : t_state := S_IDLE;     -- after S_BUS_W / S_BUS_R
   signal w_ret       : t_state := S_IDLE;     -- after S_WREGS

   -- what an interrupt request 101 continues
   type t_phase is (P_NONE, P_PKT, P_IN, P_OUT);
   signal phase       : t_phase := P_NONE;

   -- where a data block's bytes come from
   type t_src is (G_IDENT, G_SENSE, G_INQ, G_CAP, G_MODE, G_TOC, G_SUB, G_DISK);

   -- one bus access: S_BUS_W writes b_data to b_addr, S_BUS_R reads b_addr into b_q
   signal b_addr      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_data      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal b_ph        : natural range 0 to 7 := 0;
   signal idx         : natural range 0 to 15 := 0;
   signal init_pend   : std_logic := '1';

   -- the task file as read (feat = the features register) and as written (S_WREGS)
   signal t_feat      : std_logic_vector(7 downto 0) := (others => '0');
   signal t_sec       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_cnt       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_cyl       : std_logic_vector(15 downto 0) := (others => '0');
   signal t_cmd       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_dh        : std_logic_vector(7 downto 0) := (others => '0');
   signal w_err       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_cnt       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_sec       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_cyl       : std_logic_vector(15 downto 0) := (others => '0');
   signal w_words     : std_logic_vector(15 downto 0) := (others => '0');
   signal w_st        : std_logic_vector(7 downto 0) := (others => '0');
   signal w_dh        : std_logic_vector(7 downto 0) := (others => '0');

   -- the packet
   type t_cdb is array (0 to 11) of std_logic_vector(7 downto 0);
   signal cdb         : t_cdb := (others => (others => '0'));

   -- the transfer: x_total bytes from x_src, x_pos the next one; this block up to x_end
   signal x_src       : t_src := G_SENSE;
   signal x_ata       : std_logic := '0';       -- IDENTIFY PACKET DEVICE (an ATA data block)
   signal x_lim       : unsigned(15 downto 0) := (others => '0');   -- the byte count limit
   signal x_total     : unsigned(31 downto 0) := (others => '0');
   signal x_pos       : unsigned(31 downto 0) := (others => '0');
   signal x_end       : unsigned(31 downto 0) := (others => '0');
   signal x_bytes     : unsigned(15 downto 0) := (others => '0');   -- in this block
   signal x_words     : unsigned(15 downto 0) := (others => '0');
   signal x_w         : unsigned(15 downto 0) := (others => '0');
   signal x_lba       : unsigned(31 downto 0) := (others => '0');   -- the image's 512-byte sector
   signal x_have      : std_logic := '0';       -- the sector at x_pos is in the buffer
   signal x_a         : unsigned(8 downto 0) := (others => '0');    -- the byte in the source
   signal x_start     : unsigned(31 downto 0) := (others => '0');   -- the block's first byte
   signal x_done      : std_logic := '0';       -- the block's last word is out
   signal x_try       : natural range 0 to 2 := 0;   -- the block made again
   signal x_fresh     : std_logic := '0';       -- the next request: fresh from the card
   signal g_lo        : std_logic_vector(7 downto 0) := (others => '0');
   signal g_hi        : std_logic_vector(7 downto 0) := (others => '0');
   signal d_lo        : std_logic_vector(7 downto 0) := (others => '0');
   signal g_byte      : std_logic_vector(7 downto 0);

   -- the sense data (s_*) and the response's parameters (r_*)
   signal s_key       : std_logic_vector(3 downto 0) := (others => '0');
   signal s_asc       : std_logic_vector(7 downto 0) := (others => '0');
   signal s_ascq      : std_logic_vector(7 downto 0) := (others => '0');
   signal ua          : std_logic := '0';       -- a new disc: UNIT ATTENTION once
   signal r_key       : std_logic_vector(3 downto 0) := (others => '0');
   signal r_asc       : std_logic_vector(7 downto 0) := (others => '0');
   signal r_ascq      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_nat       : unsigned(7 downto 0) := (others => '0');    -- the full length
   signal r_m10       : std_logic := '0';       -- MODE SENSE (10)
   signal r_page      : std_logic_vector(5 downto 0) := (others => '0');
   signal r_chg       : std_logic := '0';       -- the changeable values: none
   signal r_msf       : std_logic := '0';
   signal r_toc       : natural range 0 to 2 := 0;   -- 0 track 1 and lead-out, 1 lead-out, 2 session
   signal r_subq      : std_logic := '0';

   -- the disc
   signal m_present   : std_logic := '0';
   signal m_gen       : std_logic_vector(3 downto 0) := (others => '0');
   signal m_cap       : unsigned(31 downto 0) := (others => '0');   -- 2048-byte sectors

   -- the lead-out as minutes, seconds, frames (2 seconds after the capacity)
   signal d_start     : std_logic := '0';
   signal d_st        : natural range 0 to 2 := 0;
   signal d_n         : unsigned(31 downto 0) := (others => '0');
   signal d_m         : unsigned(7 downto 0) := (others => '0');
   signal d_s         : unsigned(7 downto 0) := (others => '0');
   signal lo_m        : std_logic_vector(7 downto 0) := (others => '0');
   signal lo_s        : std_logic_vector(7 downto 0) := (others => '0');
   signal lo_f        : std_logic_vector(7 downto 0) := (others => '0');

   signal req         : std_logic := '0';
   signal done_s      : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of done_s : signal is "true";

begin

   sd_req_o   <= req;
   sd_req_fresh_o <= x_fresh;
   buf_addr_o <= std_logic_vector(x_a);

   ---------------------------------------------------------------------------------------------
   -- The bytes of the responses that are no sectors, by x_a
   ---------------------------------------------------------------------------------------------

   p_gen : process (all)
      variable p    : natural range 0 to 511;
      variable q    : natural range 0 to 511;
      variable hdr  : natural range 0 to 8;
      variable w    : std_logic_vector(15 downto 0);
      variable lead : boolean;
      variable last : unsigned(31 downto 0);
   begin
      p := to_integer(x_a);
      g_byte <= x"00";
      case x_src is
         when G_IDENT =>
            w := ident(p / 2);
            if p mod 2 = 0 then
               g_byte <= w(7 downto 0);
            else
               g_byte <= w(15 downto 8);
            end if;

         when G_SENSE =>                         -- fixed format, current
            case p is
               when 0      => g_byte <= x"70";
               when 2      => g_byte <= x"0" & r_key;
               when 7      => g_byte <= x"0A";
               when 12     => g_byte <= r_asc;
               when 13     => g_byte <= r_ascq;
               when others => null;
            end case;

         when G_INQ =>
            case p is
               when 0      => g_byte <= x"05";   -- a CD-ROM
               when 1      => g_byte <= x"80";   -- removable
               when 3      => g_byte <= x"21";
               when 4      => g_byte <= x"1F";   -- 36 bytes
               when 8 to 35 =>
                  g_byte <= std_logic_vector(to_unsigned(character'pos(C_INQ(p - 7)), 8));
               when others => null;
            end case;

         when G_CAP =>                           -- the last sector, 2048 bytes each
            last := m_cap - 1;
            case p is
               when 0      => g_byte <= std_logic_vector(last(31 downto 24));
               when 1      => g_byte <= std_logic_vector(last(23 downto 16));
               when 2      => g_byte <= std_logic_vector(last(15 downto 8));
               when 3      => g_byte <= std_logic_vector(last(7 downto 0));
               when 6      => g_byte <= x"08";
               when others => null;
            end case;

         when G_TOC =>                           -- one data track; 8-byte descriptors
            if p < 4 then
               case p is
                  when 1      => g_byte <= std_logic_vector(r_nat - 2);
                  when 2 | 3  => g_byte <= x"01";   -- the first and last track (session)
                  when others => null;
               end case;
            else
               q    := (p - 4) mod 8;
               lead := r_toc = 1 or (r_toc = 0 and p >= 12);
               case q is
                  when 1 => g_byte <= x"14";     -- ADR 1, a data track
                  when 2 =>
                     if lead then
                        g_byte <= x"AA";
                     else
                        g_byte <= x"01";
                     end if;
                  when 4 to 7 =>
                     if lead and r_msf = '1' then
                        case q is
                           when 5      => g_byte <= lo_m;
                           when 6      => g_byte <= lo_s;
                           when 7      => g_byte <= lo_f;
                           when others => null;
                        end case;
                     elsif lead then
                        case q is
                           when 4      => g_byte <= std_logic_vector(m_cap(31 downto 24));
                           when 5      => g_byte <= std_logic_vector(m_cap(23 downto 16));
                           when 6      => g_byte <= std_logic_vector(m_cap(15 downto 8));
                           when others => g_byte <= std_logic_vector(m_cap(7 downto 0));
                        end case;
                     elsif r_msf = '1' and q = 6 then
                        g_byte <= x"02";         -- track 1 at 00:02:00 (LBA 0)
                     end if;
                  when others => null;
               end case;
            end if;

         when G_SUB =>                           -- no audio status; the head at track 1
            case p is
               when 1      => g_byte <= x"15";
               when 3      =>
                  if r_subq = '1' then
                     g_byte <= x"0C";
                  end if;
               when 4      => g_byte <= x"01";
               when 5      => g_byte <= x"14";
               when 6 | 7  => g_byte <= x"01";
               when 10     =>
                  if r_msf = '1' then
                     g_byte <= x"02";
                  end if;
               when others => null;
            end case;

         when G_MODE =>                          -- the header, then the pages
            if r_m10 = '1' then
               hdr := 8;
            else
               hdr := 4;
            end if;
            if p < hdr then
               -- the mode data length: the bytes after the length field
               if r_m10 = '1' and p = 1 then
                  g_byte <= std_logic_vector(r_nat - 2);
               elsif r_m10 = '0' and p = 0 then
                  g_byte <= std_logic_vector(r_nat - 1);
               elsif (r_m10 = '1' and p = 2) or (r_m10 = '0' and p = 1) then
                  if m_present = '1' then
                     g_byte <= x"01";            -- 120 mm, data only
                  else
                     g_byte <= x"70";            -- no disc
                  end if;
               end if;
            else
               q := p - hdr;
               if r_page = "111111" then
                  if q < 8 then
                     w(7 downto 0) := mode_page(0, q);
                  elsif q < 16 then
                     w(7 downto 0) := mode_page(1, q - 8);
                     q := q - 8;
                  elsif q < 32 then
                     w(7 downto 0) := mode_page(2, q - 16);
                     q := q - 16;
                  else
                     w(7 downto 0) := mode_page(3, q - 32);
                     q := q - 32;
                  end if;
               else
                  case r_page is
                     when "000001" => w(7 downto 0) := mode_page(0, q);
                     when "001101" => w(7 downto 0) := mode_page(1, q);
                     when "001110" => w(7 downto 0) := mode_page(2, q);
                     when others   => w(7 downto 0) := mode_page(3, q);
                  end case;
               end if;
               if r_chg = '1' and q >= 2 then
                  g_byte <= x"00";               -- nothing can be changed
               else
                  g_byte <= w(7 downto 0);
               end if;
            end if;

         when others =>
            null;
      end case;
   end process p_gen;

   ---------------------------------------------------------------------------------------------
   -- The lead-out's address as minutes, seconds and frames: (capacity + 150) / 75 / 60
   ---------------------------------------------------------------------------------------------

   p_msf : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if d_start = '1' then
            d_n  <= m_cap + 150;
            d_m  <= (others => '0');
            d_s  <= (others => '0');
            d_st <= 1;
         elsif d_st = 1 then
            if d_n >= 4500 then
               d_n <= d_n - 4500;
               if d_m /= x"FF" then
                  d_m <= d_m + 1;
               end if;
            else
               d_st <= 2;
            end if;
         elsif d_st = 2 then
            if d_n >= 75 then
               d_n <= d_n - 75;
               d_s <= d_s + 1;
            else
               lo_m <= std_logic_vector(d_m);
               lo_s <= std_logic_vector(d_s);
               lo_f <= std_logic_vector(d_n(7 downto 0));
               d_st <= 0;
            end if;
         end if;
      end if;
   end process p_msf;

   ---------------------------------------------------------------------------------------------
   -- The drive
   ---------------------------------------------------------------------------------------------

   p_drive : process (clk_i)
      variable v_alloc : natural range 0 to 65535;
      variable v_hdr   : natural range 0 to 8;
      variable v_plen  : natural range 0 to 63;
      variable v_nat   : natural range 0 to 63;
      variable v_fmt   : std_logic_vector(3 downto 0);
      variable v_lba   : unsigned(31 downto 0);
      variable v_cnt   : unsigned(31 downto 0);
      variable v_rem   : unsigned(31 downto 0);
      variable v_c     : unsigned(31 downto 0);
      variable v_left  : unsigned(31 downto 0);
      variable v_word  : std_logic_vector(15 downto 0);

      -- CHECK CONDITION: the sense data, ERR and the sense key, the end
      procedure fail(k : std_logic_vector(3 downto 0); asc, ascq : std_logic_vector(7 downto 0)) is
      begin
         s_key  <= k;
         s_asc  <= asc;
         s_ascq <= ascq;
         if k = x"5" then
            w_err <= k & "0100";                 -- ILLEGAL REQUEST: ABRT too
         else
            w_err <= k & "0000";
         end if;
         w_cnt   <= x"03";                       -- interrupt reason IO + CoD
         w_words <= x"0000";
         w_st    <= C_ST_ERR;
         phase   <= P_NONE;
         idx     <= 0;
         w_ret   <= S_REL;
         state   <= S_WREGS;
      end procedure fail;

      -- the command is done: no sense data
      procedure finish is
      begin
         s_key   <= x"0";
         s_asc   <= x"00";
         s_ascq  <= x"00";
         w_err   <= x"00";
         w_cnt   <= x"03";
         w_words <= x"0000";
         w_st    <= C_ST_OK;
         phase   <= P_NONE;
         idx     <= 0;
         w_ret   <= S_REL;
         state   <= S_WREGS;
      end procedure finish;

      -- n bytes to the PC from src, then the end
      procedure send(src : t_src; n : unsigned(31 downto 0)) is
      begin
         if n = 0 then
            finish;
         else
            x_src   <= src;
            x_ata   <= '0';
            x_total <= n;
            x_pos   <= (others => '0');
            x_have  <= '0';
            phase   <= P_IN;
            state   <= S_CHUNK;
         end if;
      end procedure send;
   begin
      if rising_edge(clk_i) then
         mgmt_read_o  <= '0';
         mgmt_write_o <= '0';
         d_start      <= '0';
         trace_we_o   <= '0';
         done_s       <= done_s(1 downto 0) & sd_done_i;

         case state is

            ----------------------------------------------------------------------------------
            -- one bus access, then back to ret (pc_mgmt's timing)
            ----------------------------------------------------------------------------------
            when S_BUS_W =>
               mgmt_address_o   <= b_addr;
               mgmt_writedata_o <= b_data;
               if b_ph = 1 then
                  mgmt_write_o <= '1';
               end if;
               if b_ph = 3 then
                  b_ph  <= 0;
                  state <= ret;
               else
                  b_ph <= b_ph + 1;
               end if;

            when S_BUS_R =>
               mgmt_address_o <= b_addr;
               if b_ph = 3 then
                  b_q   <= mgmt_readdata_i;
                  b_ph  <= 0;
                  state <= ret;
               else
                  b_ph <= b_ph + 1;
               end if;

            -- the task file: 0 the error and block size 80h (exact, from 4), 1 sector/count,
            -- 2 cylinder, 3 (LBA48) 0, 4 the block size in words, 5 status/drive-head last (it
            -- rewinds ide.v's buffer pointers and clears the request)
            when S_WREGS =>
               if idx = 0 then
                  trace_we_o <= '1';
                  trace_o    <= x"90" & w_st & w_err & w_cnt & w_cyl & w_words;
               end if;
               b_addr <= C_IDE & std_logic_vector(to_unsigned(idx, 8));
               case idx is
                  when 0      => b_data <= w_err & x"80";
                  when 1      => b_data <= w_sec & w_cnt;
                  when 2      => b_data <= w_cyl;
                  when 4      => b_data <= w_words;
                  when 5      => b_data <= w_st & w_dh;
                  when others => b_data <= x"0000";
               end case;
               state <= S_BUS_W;
               if idx = 5 then
                  idx <= 0;
                  ret <= w_ret;
               else
                  idx <= idx + 1;
                  ret <= S_WREGS;
               end if;

            ----------------------------------------------------------------------------------
            -- the bus: asked for while there is work, given back after it
            ----------------------------------------------------------------------------------
            when S_IDLE =>
               if init_pend = '1' or ide_request_i /= "000" then
                  bus_req_o <= '1';
                  state     <= S_GNT;
               end if;

            when S_GNT =>
               if bus_gnt_i = '1' then
                  if init_pend = '1' then
                     idx   <= 0;
                     state <= S_INIT;
                  elsif ide_request_i = "110" then
                     phase  <= P_NONE;
                     b_addr <= C_IDE & x"05";
                     state  <= S_BUS_R;
                     ret    <= S_RST1;
                  elsif ide_request_i = "100" then
                     phase  <= P_NONE;
                     b_addr <= C_IDE & x"00";
                     state  <= S_BUS_R;
                     ret    <= S_CMD0;
                  elsif ide_request_i = "101" then
                     state <= S_BLK;
                  else
                     state <= S_REL;
                  end if;
               end if;

            when S_REL =>
               mgmt_address_o <= x"0000";
               bus_req_o      <= '0';
               if bus_gnt_i = '0' then
                  state <= S_IDLE;
               end if;

            -- ide.v: the master is there (6: bit 3 = its present/LBA48 bits follow), no wait
            -- states (bit 9 = use_wait follows)
            when S_INIT =>
               b_addr <= C_IDE & x"06";
               state  <= S_BUS_W;
               if idx = 0 then
                  b_data <= x"0009";
                  idx    <= 1;
                  ret    <= S_INIT;
               else
                  b_data    <= x"0200";
                  idx       <= 0;
                  init_pend <= '0';
                  ret       <= S_REL;
               end if;

            ----------------------------------------------------------------------------------
            -- reset (request 110): BSY, then the signature (b_q: register 5 = {cmd, drive/head})
            ----------------------------------------------------------------------------------
            when S_RST1 =>
               trace_we_o <= '1';
               trace_o    <= x"C0" & b_q(7 downto 0) & x"0000" & x"00000000";
               w_err   <= x"01";
               w_cnt   <= x"01";
               w_sec   <= x"01";
               w_words <= x"0000";
               w_dh    <= '1' & b_q(6) & '1' & b_q(4) & "0000";
               if b_q(4) = '0' then
                  w_cyl <= x"EB14";                  -- ATAPI
               else
                  w_cyl <= x"FFFF";                  -- the slave is not there
               end if;
               w_st  <= x"80";
               idx   <= 0;
               w_ret <= S_RST2;
               state <= S_WREGS;

            when S_RST2 =>
               if w_dh(4) = '0' then
                  w_st <= x"00";                     -- an ATAPI device is not DRDY after a reset
               else
                  w_st <= x"50";
               end if;
               idx   <= 0;
               w_ret <= S_REL;
               state <= S_WREGS;

            ----------------------------------------------------------------------------------
            -- a command (request 100): the task file, then the command
            ----------------------------------------------------------------------------------
            when S_CMD0 =>
               t_feat <= b_q(15 downto 8);
               b_addr <= C_IDE & x"01";
               state  <= S_BUS_R;
               ret    <= S_CMD1;

            when S_CMD1 =>
               t_sec  <= b_q(15 downto 8);
               t_cnt  <= b_q(7 downto 0);
               b_addr <= C_IDE & x"02";
               state  <= S_BUS_R;
               ret    <= S_CMD2;

            when S_CMD2 =>
               t_cyl  <= b_q;
               b_addr <= C_IDE & x"05";
               state  <= S_BUS_R;
               ret    <= S_CMD3;

            when S_CMD3 =>
               t_cmd <= b_q(15 downto 8);
               t_dh  <= b_q(7 downto 0);
               state <= S_CMD;

            when S_CMD =>
               trace_we_o <= '1';
               trace_o    <= x"80" & t_cmd & t_dh & t_feat & t_cyl & t_sec & x"00";
               -- the registers as read, by default
               w_err   <= x"00";
               w_cnt   <= t_cnt;
               w_sec   <= t_sec;
               w_cyl   <= t_cyl;
               w_dh    <= t_dh;
               w_words <= x"0000";
               idx     <= 0;
               w_ret   <= S_REL;
               state   <= S_WREGS;
               if t_dh(4) = '1' then
                  w_err <= x"04";                    -- the slave: aborted
                  w_st  <= C_ST_ERR;
               else
                  case t_cmd is
                     when x"A0" =>                   -- PACKET (no DMA)
                        if t_feat(0) = '1' then
                           w_err <= x"04";
                           w_st  <= C_ST_ERR;
                        else
                           w_cnt   <= x"01";         -- interrupt reason CoD
                           w_words <= x"0006";
                           w_st    <= C_ST_PKT;
                           phase   <= P_PKT;
                           if t_cyl(15 downto 1) = "000000000000000" then
                              x_lim <= x"FFFE";
                           else
                              x_lim <= unsigned(t_cyl(15 downto 1)) & '0';
                           end if;
                        end if;
                     when x"A1" =>                   -- IDENTIFY PACKET DEVICE
                        x_src   <= G_IDENT;
                        x_ata   <= '1';
                        x_total <= n32(512);
                        x_pos   <= (others => '0');
                        x_lim   <= x"0200";
                        state   <= S_CHUNK;
                     when x"EC" =>                   -- IDENTIFY DEVICE: aborted, the signature
                        w_err <= x"04";
                        w_cnt <= x"01";
                        w_sec <= x"01";
                        w_cyl <= x"EB14";
                        w_st  <= C_ST_ERR;
                     when x"08" =>                   -- DEVICE RESET: the signature
                        w_err <= x"01";
                        w_cnt <= x"01";
                        w_sec <= x"01";
                        w_cyl <= x"EB14";
                        w_st  <= x"00";
                     when x"90" =>                   -- EXECUTE DIAGNOSTIC: passed, the signature
                        w_err <= x"01";
                        w_cnt <= x"01";
                        w_sec <= x"01";
                        w_cyl <= x"EB14";
                        w_st  <= x"04";
                     when x"E5" =>                   -- CHECK POWER MODE: active
                        w_cnt <= x"FF";
                        w_st  <= C_ST_OK;
                     when x"E0" | x"E1" | x"E2" | x"E3" | x"E7" | x"EF" =>
                        w_st  <= C_ST_OK;            -- power, flush, SET FEATURES
                     when others =>
                        w_err <= x"04";              -- aborted
                        w_st  <= C_ST_ERR;
                  end case;
               end if;

            ----------------------------------------------------------------------------------
            -- request 101: the PC has written the packet, read a block or written one
            ----------------------------------------------------------------------------------
            when S_BLK =>
               trace_we_o <= '1';
               trace_o    <= x"B0" & std_logic_vector(to_unsigned(t_phase'pos(phase), 8)) &
                             x"0000" & std_logic_vector(x_pos);
               case phase is
                  when P_PKT =>
                     idx   <= 0;
                     b_ph  <= 0;
                     state <= S_POP;
                  when P_IN | P_OUT =>
                     if x_pos = x_total then
                        finish;
                     else
                        state <= S_CHUNK;
                     end if;
                  when others =>
                     w_err   <= x"04";               -- nothing was going on: aborted
                     w_cnt   <= t_cnt;
                     w_sec   <= t_sec;
                     w_cyl   <= t_cyl;
                     w_dh    <= t_dh;
                     w_words <= x"0000";
                     w_st    <= C_ST_ERR;
                     idx     <= 0;
                     w_ret   <= S_REL;
                     state   <= S_WREGS;
               end case;

            -- the packet's 6 words out of ide.v's buffer (sampled, then the read pulse)
            when S_POP =>
               mgmt_address_o <= C_IDE & x"0F";
               case b_ph is
                  when 0 | 1 | 2 =>
                     b_ph <= b_ph + 1;
                  when 3 =>
                     cdb((2 * idx) mod 12)     <= mgmt_readdata_i(7 downto 0);
                     cdb((2 * idx + 1) mod 12) <= mgmt_readdata_i(15 downto 8);
                     mgmt_read_o      <= '1';
                     b_ph             <= 4;
                  when others =>
                     b_ph <= 0;
                     if idx = 5 then
                        idx   <= 0;
                        state <= S_SCSI;
                     else
                        idx <= idx + 1;
                     end if;
               end case;

            ----------------------------------------------------------------------------------
            -- the packet's command
            ----------------------------------------------------------------------------------
            when S_SCSI =>
               trace_we_o <= '1';
               trace_o    <= x"A0" & cdb(0) & cdb(1) & cdb(8) & cdb(2) & cdb(3) & cdb(4) & cdb(5);
               v_alloc := to_integer(unsigned(cdb(7)) & unsigned(cdb(8)));   -- the 10-byte ones'
               if ua = '1' and cdb(0) /= x"12" and cdb(0) /= x"03" then
                  ua <= '0';
                  fail(x"6", x"28", x"00");          -- UNIT ATTENTION: a new disc
               else
                  case cdb(0) is
                     when x"00" =>                   -- TEST UNIT READY
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           finish;
                        end if;

                     when x"03" =>                   -- REQUEST SENSE (the pending unit
                        if ua = '1' then             -- attention first)
                           r_key  <= x"6";
                           r_asc  <= x"28";
                           r_ascq <= x"00";
                           ua     <= '0';
                        else
                           r_key  <= s_key;
                           r_asc  <= s_asc;
                           r_ascq <= s_ascq;
                        end if;
                        send(G_SENSE, n32(nmin(18, to_integer(unsigned(cdb(4))))));

                     when x"12" =>                   -- INQUIRY (no vital product data)
                        if cdb(1)(0) = '1' then
                           fail(x"5", x"24", x"00");
                        else
                           send(G_INQ, n32(nmin(36, to_integer(unsigned(cdb(4))))));
                        end if;

                     when x"1A" | x"5A" =>           -- MODE SENSE (6), (10)
                        case cdb(2)(5 downto 0) is
                           when "000001" | "001101" => v_plen := 8;
                           when "001110"            => v_plen := 16;
                           when "101010"            => v_plen := 20;
                           when "111111"            => v_plen := 52;
                           when others              => v_plen := 0;
                        end case;
                        if cdb(0) = x"5A" then
                           v_hdr := 8;
                           r_m10 <= '1';
                        else
                           v_hdr   := 4;
                           v_alloc := to_integer(unsigned(cdb(4)));
                           r_m10   <= '0';
                        end if;
                        v_nat  := v_hdr + v_plen;
                        r_nat  <= to_unsigned(v_nat, 8);
                        r_page <= cdb(2)(5 downto 0);
                        if cdb(2)(7 downto 6) = "01" then
                           r_chg <= '1';
                        else
                           r_chg <= '0';
                        end if;
                        if cdb(2)(7 downto 6) = "11" then
                           fail(x"5", x"39", x"00");   -- saved values: not supported
                        elsif v_plen = 0 then
                           fail(x"5", x"24", x"00");
                        else
                           send(G_MODE, n32(nmin(v_nat, v_alloc)));
                        end if;

                     when x"15" | x"55" =>           -- MODE SELECT (6), (10): the data dropped
                        if cdb(0) = x"15" then
                           v_alloc := to_integer(unsigned(cdb(4)));
                        end if;
                        if v_alloc = 0 then
                           finish;
                        else
                           x_ata   <= '0';
                           x_total <= n32(v_alloc);
                           x_pos   <= (others => '0');
                           phase   <= P_OUT;
                           state   <= S_CHUNK;
                        end if;

                     when x"1B" | x"1E" | x"4B" | x"4E" =>
                        finish;                      -- START STOP, PREVENT ALLOW, PAUSE, STOP

                     when x"25" =>                   -- READ CAPACITY
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           send(G_CAP, n32(8));
                        end if;

                     when x"28" | x"A8" =>           -- READ (10), (12)
                        v_lba := unsigned(cdb(2)) & unsigned(cdb(3)) & unsigned(cdb(4)) &
                                 unsigned(cdb(5));
                        if cdb(0) = x"28" then
                           v_cnt := x"0000" & unsigned(cdb(7)) & unsigned(cdb(8));
                        else
                           v_cnt := unsigned(cdb(6)) & unsigned(cdb(7)) & unsigned(cdb(8)) &
                                    unsigned(cdb(9));
                        end if;
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif ('0' & v_lba) + ('0' & v_cnt) > ('0' & m_cap) then
                           fail(x"5", x"21", x"00");   -- beyond the disc
                        elsif v_cnt = 0 then
                           finish;
                        else
                           x_lba <= v_lba(29 downto 0) & "00";
                           send(G_DISK, v_cnt(20 downto 0) & "00000000000");
                        end if;

                     when x"2B" =>                   -- SEEK
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           finish;
                        end if;

                     when x"43" =>                   -- READ TOC (the format: byte 2, or the
                        v_fmt := cdb(2)(3 downto 0); -- old place, byte 9's top bits)
                        if v_fmt = x"0" then
                           v_fmt := "00" & cdb(9)(7 downto 6);
                        end if;
                        r_msf <= cdb(1)(1);
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif v_fmt = x"0" and cdb(6) = x"AA" then
                           r_toc <= 1;               -- the lead-out only
                           r_nat <= to_unsigned(12, 8);
                           send(G_TOC, n32(nmin(12, v_alloc)));
                        elsif v_fmt = x"0" and unsigned(cdb(6)) <= 1 then
                           r_toc <= 0;
                           r_nat <= to_unsigned(20, 8);
                           send(G_TOC, n32(nmin(20, v_alloc)));
                        elsif v_fmt = x"1" then
                           r_toc <= 2;               -- the sessions: one
                           r_nat <= to_unsigned(12, 8);
                           send(G_TOC, n32(nmin(12, v_alloc)));
                        else
                           fail(x"5", x"24", x"00");
                        end if;

                     when x"42" =>                   -- READ SUB-CHANNEL
                        r_msf  <= cdb(1)(1);
                        r_subq <= cdb(2)(6);
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif cdb(2)(6) = '1' then
                           send(G_SUB, n32(nmin(16, v_alloc)));
                        else
                           send(G_SUB, n32(nmin(4, v_alloc)));
                        end if;

                     when x"45" | x"47" | x"48" | x"A5" =>   -- PLAY AUDIO: a data track
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           fail(x"5", x"64", x"00");
                        end if;

                     when others =>
                        fail(x"5", x"20", x"00");    -- invalid command
                  end case;
               end if;

            ----------------------------------------------------------------------------------
            -- a data block: as long as the limits allow; in, it goes into ide.v's buffer first
            ----------------------------------------------------------------------------------
            when S_CHUNK =>
               v_rem := x_total - x_pos;
               v_c   := n32(C_CHUNK);
               if resize(x_lim, 32) < v_c then
                  v_c := resize(x_lim, 32);
               end if;
               if v_rem < v_c then
                  v_c := v_rem;
               end if;
               x_end   <= x_pos + v_c;
               x_start <= x_pos;
               x_try   <= 0;
               x_bytes <= v_c(15 downto 0);
               x_words <= v_c(16 downto 1) + ("000000000000000" & v_c(0));
               x_w     <= (others => '0');
               if phase = P_OUT then
                  state <= S_REGS;                   -- the PC fills it
               else
                  b_addr <= C_IDE & x"06";           -- the buffer pointer back to 0
                  b_data <= x"0000";
                  ret    <= S_STREAM;
                  state  <= S_BUS_W;
               end if;

            -- word by word: the source byte's address, the next one's, the first byte, the word
            when S_STREAM =>
               mgmt_address_o <= C_IDE & x"0F";
               case b_ph is
                  when 0 =>
                     if x_src = G_DISK and x_pos(8 downto 0) = "000000000" and x_have = '0' then
                        -- the image's next 512-byte sector, with those still to come
                        v_left := shift_right(x_total - x_pos, 9);
                        sd_req_lba_o <= std_logic_vector(x_lba + shift_right(x_pos, 9));
                        if v_left >= 256 then
                           sd_req_cnt_o <= '1' & x"00";
                        else
                           sd_req_cnt_o <= std_logic_vector(v_left(8 downto 0));
                        end if;
                        state <= S_SD_ASK;
                     else
                        x_a  <= x_pos(8 downto 0);
                        b_ph <= 1;
                     end if;
                  when 1 =>
                     x_a  <= x_pos(8 downto 1) & '1';
                     g_lo <= g_byte;
                     b_ph <= 2;
                  when 2 =>
                     d_lo <= buf_rd_i;
                     g_hi <= g_byte;
                     b_ph <= 3;
                  when 3 =>
                     if x_src = G_DISK then
                        v_word := buf_rd_i & d_lo;
                     else
                        v_word := g_hi & g_lo;
                     end if;
                     if x_pos + 1 >= x_total then
                        v_word(15 downto 8) := x"00";   -- an odd length's last word
                     end if;
                     mgmt_writedata_o <= v_word;
                     mgmt_write_o     <= '1';
                     b_ph             <= 4;
                  when others =>
                     b_ph  <= 0;
                     x_pos <= x_pos + 2;
                     if x_w + 1 = x_words then
                        x_done <= '1';
                     else
                        x_done <= '0';
                        x_w    <= x_w + 1;
                     end if;
                     if x_pos(8 downto 1) = "11111111" and x_src = G_DISK then
                        x_have <= '0';               -- the sector's last word: its copy
                        state  <= S_CHK;             -- against the ring's checksum
                     elsif x_pos(8 downto 1) = "11111111" then
                        x_have <= '0';
                        if x_w + 1 = x_words then
                           state <= S_REGS;
                        end if;
                     elsif x_w + 1 = x_words then
                        state <= S_REGS;
                     end if;
               end case;

            -- disk_sd's verdict on the image sector just copied (two clocks after its last
            -- byte): for one that did not match the ring's checksum the whole block is made
            -- again, its first sector fresh from the card (a new run, so the others come
            -- fresh too), twice at most: ide.v's buffer pointer only goes back to 0
            when S_CHK =>
               if b_ph < 2 then
                  b_ph <= b_ph + 1;
               else
                  b_ph <= 0;
                  if buf_bad_i = '1' and x_try < 2 and x_start(8 downto 0) = "000000000" then
                     x_try   <= x_try + 1;
                     x_fresh <= '1';
                     x_pos   <= x_start;
                     x_w     <= (others => '0');
                     x_have  <= '0';
                     b_addr  <= C_IDE & x"06";        -- the buffer pointer back to 0
                     b_data  <= x"0000";
                     ret     <= S_STREAM;
                     state   <= S_BUS_W;
                  elsif x_done = '1' then
                     state <= S_REGS;
                  else
                     state <= S_STREAM;
                  end if;
               end if;

            when S_SD_ASK =>
               req   <= not req;                     -- lba and cnt were set a clock ago
               state <= S_SD_WAIT;

            when S_SD_WAIT =>
               if done_s(2) /= done_s(1) then
                  trace_we_o <= '1';
                  trace_o    <= x"60" & "0000000" & sd_err_i & x"03" & sd_req_cnt_o(7 downto 0) &
                                sd_req_lba_o;
                  x_fresh <= '0';
                  if sd_err_i = '1' then
                     fail(x"3", x"11", x"00");       -- MEDIUM ERROR, unrecovered read error
                  else
                     x_have <= '1';
                     state  <= S_STREAM;
                  end if;
               end if;

            -- the block's registers: its bytes, IO (in) or none (out), DRQ and the interrupt
            when S_REGS =>
               x_pos   <= x_end;
               w_err   <= x"00";
               w_words <= std_logic_vector(x_words);
               idx     <= 0;
               w_ret   <= S_REL;
               state   <= S_WREGS;
               if x_ata = '1' then
                  w_st  <= C_ST_ATA;                 -- one block, then ready by itself
                  phase <= P_NONE;
               else
                  w_cyl <= std_logic_vector(x_bytes);
                  if phase = P_OUT then
                     w_cnt <= x"00";
                  else
                     w_cnt <= x"02";
                  end if;
                  w_st <= C_ST_DATA;
               end if;

            when others =>
               state <= S_IDLE;

         end case;

         -- a disc came or went: a new one is a UNIT ATTENTION, and its lead-out's MSF
         if mnt_i(3 downto 0) /= m_gen or mnt_i(39) /= m_present then
            m_gen     <= mnt_i(3 downto 0);
            m_present <= mnt_i(39);
            m_cap     <= "00" & unsigned(mnt_i(37 downto 8));
            d_start   <= '1';
            if mnt_i(39) = '1' then
               ua <= '1';
            end if;
         end if;

         if rst_i = '1' then
            state     <= S_IDLE;
            phase     <= P_NONE;
            bus_req_o <= '0';
            init_pend <= '1';
            b_ph      <= 0;
            idx       <= 0;
         end if;
      end if;
   end process p_drive;

end architecture synthesis;

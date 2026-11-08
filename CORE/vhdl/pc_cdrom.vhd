----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The CD-ROM drive: an ATAPI device, the master of the PC's second IDE channel (z486_MiSTer's
-- ide.v at management page F1xx, IRQ 15), with a disc image on the SD card (disk_sd.vhd's unit
-- 3): an ISO, a raw .bin, or a .cue sheet's files, with CD audio. What Main_MiSTer's ide.cpp
-- and ide_cdrom.cpp do for ao486 on the ARM side, in hardware, next to pc_mgmt.vhd's hard disk.
-- pc_mgmt owns the management bus: it grants it to the drive (bus_req_o / bus_gnt_i) and passes
-- the sector requests and the sector buffer through while it does.
--
--   * Always there, with or without a disc (a drive with its tray empty): after a reset the
--     ATAPI signature (sector count 1, sector 1, cylinder EB14h, status 00h); IDENTIFY DEVICE
--     is aborted with it, IDENTIFY PACKET DEVICE (PIO only), DEVICE RESET, EXECUTE DIAGNOSTIC
--     and the power and feature commands work. The slave is never there (as on the first
--     channel: its cylinder reads FFFFh after a reset, its commands are aborted).
--   * PACKET: DRQ for the 12-byte command (interrupt reason CoD, no interrupt), then the
--     command: TEST UNIT READY, REQUEST SENSE, INQUIRY, MODE SENSE (6) and (10) (pages 01h,
--     0Dh, 0Eh, 2Ah and 3Fh), MODE SELECT (page 0Eh's volumes kept), START STOP UNIT, PREVENT
--     ALLOW MEDIUM REMOVAL, READ CAPACITY, READ (10) and (12), SEEK, READ TOC (formats 0 and 1,
--     LBA and MSF), READ SUB-CHANNEL, PLAY AUDIO (10), (12), MSF and TRACK/INDEX, PAUSE/RESUME
--     and STOP PLAY; anything else ends in CHECK CONDITION, ILLEGAL REQUEST.
--   * Data in DRQ blocks of at most 2048 bytes and the byte count limit the PC gave (the
--     cylinder register; 0 counts as FFFEh), each with an interrupt (interrupt reason IO, the
--     block's bytes in the cylinder register); then the end: interrupt reason IO + CoD, DRDY,
--     an interrupt. Status bit 4 (SERVICE for a packet device) stays 0, except DSC when SEEK
--     is done (Main_MiSTer's choices, made for Windows 9x and VIDE-CDD.SYS). An error: ERR,
--     the sense key in the error register's high nibble (ABRT with ILLEGAL REQUEST), the
--     sense data for REQUEST SENSE. A new disc: UNIT ATTENTION (6/28h) once; none: NOT READY,
--     MEDIUM NOT PRESENT (2/3Ah).
--
-- The disc: the firmware (m2m-rom.asm's cdimage.asm) writes its track table (QNICE device
-- C_DEV_PC_CDTOC, mega65.vhd; read here through tab_addr_o / tab_q_i, the data two clocks after
-- the address) and unit 3's extent map, the disc's files back to back in one "virtual image",
-- before it mounts the unit. The table (16-bit words):
--     0      tracks (1..99)          1      the first track | the last << 8
--     2, 3   the lead-out's LBA      4      01h data, 02h audio, 03h both (MODE SENSE)
--     5, 6   the lead-out's M | S << 8, F
--     100h + 4k, 300h + 4k: READ TOC's descriptor k (k = N: the lead-out) in LBA and in MSF
--            form, 8 bytes (0, control, track, 0, the address), byte 2j in word j's low byte
--     800h + 16k: track k: 0 number | control << 8, 1 the sector size in its file (2048, 2336,
--            2352), 2 the user data's offset in a sector, 3 1 audio, 2 big-endian audio, then
--            32-bit LBAs: 4 its start (INDEX 00), 6 INDEX 01, 8 the first one in its file, 10
--            the end of those, 12 its end (the next track's start); 14 the virtual image's
--            byte of LBA 8's sector. A sector outside 8..10 is in no file (PREGAP, POSTGAP):
--            silence for audio, an error for data.
--
--   * READ: each 2048-byte sector at its byte in the virtual image (+ the user data's offset),
--     the bytes after it (the rest of a raw sector: sync, header, ECC) skipped, every 512-byte
--     card sector read through disk_sd's ring in order (S_WALK, S_SKIP, S_TAIL) so that every
--     copy is checked against the ring's checksum; a block whose copy did not match is made
--     again, fresh from the card. Each READ tells disk_sd the card sectors still to come
--     (sd_req_cnt_o), which it reads ahead in one SD transfer. A READ of an audio track: 5/64h.
--   * Audio: PLAY returns at once; the streamer (S_PL*) then fills cd_audio.vhd's FIFO between
--     the PC's commands: when there is room for 7 sectors it asks for the bus and fills it up,
--     sectors in no file as silence, up to the end the PLAY gave or a data track. READ SUB-
--     CHANNEL reports the sector being heard (cd_audio counts them), or the one a SEEK went
--     to (Media Player seeks to a track, reads where the drive is, then plays from there).
--     READ, SEEK, START STOP UNIT (stop, eject), a new disc and a reset stop it, as on a real
--     drive: games loaded their data first, or stopped the music to read.
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
   generic (
      G_CLK_HZ          : natural := 64_000_000;
      G_RATE            : natural := 44_100       -- the audio's (the testbench plays faster)
   );
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

      -- the track table (mega65.vhd's block RAM: the data two clocks after the address)
      tab_addr_o        : out std_logic_vector(11 downto 0) := (others => '0');
      tab_q_i           : in  std_logic_vector(15 downto 0);

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

      -- CD audio (44.1 kHz, the drive's volume applied) and how it goes: 63..56 the audio
      -- status (11h playing, 12h paused, 13h done, 14h stopped by an error, 15h none), 55..32
      -- the LBA being heard, 31..16 the samples the FIFO did not have, 15..0 the fewest words
      -- it held since the PLAY
      cd_l_o            : out std_logic_vector(15 downto 0);
      cd_r_o            : out std_logic_vector(15 downto 0);
      cd_stb_o          : out std_logic;          -- a pulse: a sample from the FIFO (testbench)
      cd_stat_o         : out std_logic_vector(63 downto 0);

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

   -- the track table (cdimage.asm's CDT_*)
   constant C_T_LBA  : natural := 16#100#;
   constant C_T_MSF  : natural := 16#300#;
   constant C_T_ENT  : natural := 16#800#;

   -- register 5's high byte as ide.v takes it (pc_mgmt's w_st): 15..14 BSY, DRDY, 12 DSC, 11 DRQ,
   -- 10 the interrupt, 9 the last block (ide.v then goes ready by itself), 8 ERR.
   -- For a packet device status bit 4 (12 here) is SERVICE, not DSC: an overlapped command wants
   -- service. It stays 0 (Main_MiSTer #1221/#1224: with it set, Windows 9x's esdi_506.pdr
   -- rejects the CD-ROM's channel), except when SEEK is done (#1239: VIDE-CDD.SYS waits for DSC)
   constant C_ST_PKT  : std_logic_vector(7 downto 0) := x"48";   -- DRQ for the packet
   constant C_ST_DATA : std_logic_vector(7 downto 0) := x"4C";   -- a data block: DRQ, interrupt
   constant C_ST_ATA  : std_logic_vector(7 downto 0) := x"4E";   -- IDENTIFY's block, the last
   constant C_ST_OK   : std_logic_vector(7 downto 0) := x"44";   -- done, interrupt
   constant C_ST_SEEK : std_logic_vector(7 downto 0) := x"54";   -- SEEK done: DSC, interrupt
   constant C_ST_ERR  : std_logic_vector(7 downto 0) := x"45";   -- ERR, interrupt

   -- audio status (READ SUB-CHANNEL)
   constant C_AS_PLAY  : std_logic_vector(7 downto 0) := x"11";
   constant C_AS_PAUSE : std_logic_vector(7 downto 0) := x"12";
   constant C_AS_DONE  : std_logic_vector(7 downto 0) := x"13";
   constant C_AS_ERR   : std_logic_vector(7 downto 0) := x"14";
   constant C_AS_NONE  : std_logic_vector(7 downto 0) := x"15";

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
   -- 0Eh: its ports' bytes 8..11 come from MODE SELECT, 3 capabilities 2Ah), byte k
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
               when others => return x"00";
            end case;
         when others =>
            case k is
               when 0  => return x"2A";
               when 1  => return x"12";
               when 4  => return x"01";         -- audio play
               when 6  => return x"29";         -- lock, eject, a tray
               when 7  => return x"03";         -- separate volumes, separate mutes
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

   -- M:S:F -> LBA (minus the 2 seconds of lead-in)
   function msf_lba(m, s, f : std_logic_vector(7 downto 0)) return unsigned is
      variable um, us, uf : unsigned(31 downto 0);
   begin
      um := resize(unsigned(m), 32);
      us := resize(unsigned(s), 32);
      uf := resize(unsigned(f), 32);
      return shift_left(um, 12) + shift_left(um, 8) + shift_left(um, 7) + shift_left(um, 4) +
             shift_left(um, 2) + shift_left(us, 6) + shift_left(us, 3) + shift_left(us, 1) +
             us + uf - 150;
   end function msf_lba;

   type t_state is (
      S_IDLE, S_GNT, S_REL,
      S_INIT,
      S_RST1, S_RST2,
      S_CMD0, S_CMD1, S_CMD2, S_CMD3, S_CMD,
      S_BLK, S_POP, S_SCSI, S_MSEL,
      S_CHUNK, S_STREAM, S_WALK, S_SKIP, S_TAIL, S_CHK, S_SD_ASK, S_SD_WAIT, S_REGS,
      S_WREGS, S_BUS_W, S_BUS_R,
      S_TR, S_TLD,
      S_LK, S_LK1, S_LK2, S_LKL, S_LKL1,
      S_RD0, S_RD1, S_RD2, S_RD3, S_RD4, S_RD5,
      S_SUB0, S_SUB1, S_SUB2,
      S_PTI0, S_PTI1, S_PTI2, S_PTI3, S_PTI4, S_PLAY0, S_PLAY1,
      S_PL, S_PLN, S_PLN1, S_PLZ, S_PLC0, S_PLC1, S_PLC2, S_PLA, S_PLW, S_PLB
   );
   signal state       : t_state := S_IDLE;
   signal ret         : t_state := S_IDLE;     -- after S_BUS_W / S_BUS_R
   signal w_ret       : t_state := S_IDLE;     -- after S_WREGS
   signal t_ret       : t_state := S_IDLE;     -- after S_TR
   signal lk_ret      : t_state := S_IDLE;     -- after a lookup (S_LK) or an entry's load (S_LKL)
   signal sd_ret      : t_state := S_IDLE;     -- after an SD answer

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
   signal x_have      : std_logic := '0';       -- the card sector rw_card is in the buffer
   signal x_a         : unsigned(8 downto 0) := (others => '0');    -- the byte in the source
   signal x_start     : unsigned(31 downto 0) := (others => '0');   -- the block's first byte
   signal x_done      : std_logic := '0';       -- the block's last word is out
   signal x_try       : natural range 0 to 2 := 0;   -- the block made again
   signal x_fresh     : std_logic := '0';       -- the next request: fresh from the card
   signal g_lo        : std_logic_vector(7 downto 0) := (others => '0');
   signal g_hi        : std_logic_vector(7 downto 0) := (others => '0');
   signal d_lo        : std_logic_vector(7 downto 0) := (others => '0');
   signal g_byte      : std_logic_vector(7 downto 0);

   -- a READ's walk through the virtual image: the card sector, the next byte in it (r_off;
   -- after a block that ended inside it, where the next one goes on), the byte in the raw
   -- sector's period (rw_in: below 2048 user data, from 2048 to r_ss skipped), each as at the
   -- block's start (bs_*, for a block made again); w_a walks a card sector's start in order
   signal rw_card     : unsigned(31 downto 0) := (others => '0');
   signal r_off       : unsigned(9 downto 0) := (others => '0');
   signal rw_in       : unsigned(11 downto 0) := (others => '0');
   signal r_ss        : unsigned(11 downto 0) := (others => '0');
   signal r_next      : std_logic := '0';       -- S_CHK: the card sector is done (not a tail)
   signal bs_card     : unsigned(31 downto 0) := (others => '0');
   signal bs_off      : unsigned(9 downto 0) := (others => '0');
   signal bs_in       : unsigned(11 downto 0) := (others => '0');
   signal w_a         : unsigned(9 downto 0) := (others => '0');
   signal rd_lba      : unsigned(31 downto 0) := (others => '0');
   signal rd_cnt      : unsigned(31 downto 0) := (others => '0');
   signal rd_d        : unsigned(31 downto 0) := (others => '0');
   signal rd_p        : unsigned(31 downto 0) := (others => '0');

   -- the sense data (s_*) and the response's parameters (r_*)
   signal s_key       : std_logic_vector(3 downto 0) := (others => '0');
   signal s_asc       : std_logic_vector(7 downto 0) := (others => '0');
   signal s_ascq      : std_logic_vector(7 downto 0) := (others => '0');
   signal ua          : std_logic := '0';       -- a new disc: UNIT ATTENTION once
   signal r_key       : std_logic_vector(3 downto 0) := (others => '0');
   signal r_asc       : std_logic_vector(7 downto 0) := (others => '0');
   signal r_ascq      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_nat       : unsigned(15 downto 0) := (others => '0');   -- the full length
   signal r_m10       : std_logic := '0';       -- MODE SENSE (10)
   signal r_page      : std_logic_vector(5 downto 0) := (others => '0');
   signal r_chg       : std_logic := '0';       -- the changeable values
   signal r_msf       : std_logic := '0';
   signal r_toc       : natural range 0 to 2 := 0;   -- 0 tracks, 2 sessions
   signal r_tbase     : unsigned(11 downto 0) := (others => '0');   -- its first descriptor
   signal r_subq      : std_logic := '0';
   signal r_sfmt      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_ast       : std_logic_vector(7 downto 0) := (others => '0');
   signal r_sctl      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_strk      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_sidx      : std_logic_vector(7 downto 0) := (others => '0');
   signal r_sabs      : std_logic_vector(31 downto 0) := (others => '0');
   signal r_srel      : std_logic_vector(31 downto 0) := (others => '0');

   -- MODE SELECT's page 0Eh: the ports' channel selects and volumes; its parse
   signal v_sel0      : std_logic_vector(7 downto 0) := x"01";
   signal v_vol0      : std_logic_vector(7 downto 0) := x"FF";
   signal v_sel1      : std_logic_vector(7 downto 0) := x"02";
   signal v_vol1      : std_logic_vector(7 downto 0) := x"FF";
   signal ms_sel      : std_logic := '0';       -- the data out is MODE SELECT's
   signal ms_pos      : unsigned(15 downto 0) := (others => '0');
   signal ms_pg       : unsigned(15 downto 0) := (others => '0');
   signal ms_e        : std_logic := '0';       -- the page at ms_pg is 0Eh
   signal ms_e0       : unsigned(15 downto 0) := (others => '0');
   signal ms_n        : unsigned(15 downto 0) := (others => '0');

   -- the disc (its table's header)
   signal m_present   : std_logic := '0';
   signal m_gen       : std_logic_vector(3 downto 0) := (others => '0');
   signal m_cap       : unsigned(31 downto 0) := (others => '0');   -- the lead-out
   signal m_n         : unsigned(7 downto 0) := (others => '0');
   signal m_first     : std_logic_vector(7 downto 0) := (others => '0');
   signal m_last      : std_logic_vector(7 downto 0) := (others => '0');
   signal m_medium    : std_logic_vector(7 downto 0) := (others => '0');
   signal tl_pend     : std_logic := '0';       -- the table's header to load

   -- the track table: a word (S_TR), a track (S_LK: the one an LBA is in; S_LKL: track lk_i)
   type t_ent is array (0 to 15) of std_logic_vector(15 downto 0);
   signal t_addr      : unsigned(11 downto 0) := (others => '0');
   signal t_ph        : natural range 0 to 2 := 0;
   signal t_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal t_k         : natural range 0 to 15 := 0;
   signal lk_lba      : unsigned(31 downto 0) := (others => '0');
   signal lk_i        : unsigned(7 downto 0) := (others => '0');
   signal lk_ok       : std_logic := '0';
   signal lk_lo       : std_logic_vector(15 downto 0) := (others => '0');
   signal e_w         : t_ent := (others => (others => '0'));

   -- the sub-channel's addresses as M:S:F (p_msf)
   signal d_start     : std_logic := '0';
   signal d_st        : natural range 0 to 2 := 0;
   signal d_in        : unsigned(31 downto 0) := (others => '0');
   signal d_n         : unsigned(31 downto 0) := (others => '0');
   signal d_m         : unsigned(7 downto 0) := (others => '0');
   signal d_s         : unsigned(7 downto 0) := (others => '0');
   signal d_f         : unsigned(7 downto 0) := (others => '0');

   -- the audio: PLAY's range, the streamer's place (pl_lba, its track p_w, its byte), the
   -- sector being heard (h_lba), the status; cd_audio's FIFO
   signal pa_start    : unsigned(31 downto 0) := (others => '0');
   signal pa_end      : unsigned(31 downto 0) := (others => '0');
   signal pl_run      : std_logic := '0';       -- a PLAY is on (playing or paused)
   signal pl_done     : std_logic := '0';       -- its last sector is in the FIFO
   signal pl_pause    : std_logic := '0';
   signal pl_flush    : std_logic := '0';
   signal pl_need     : std_logic := '0';       -- the streamer wants the bus
   signal pl_ast      : std_logic_vector(7 downto 0) := C_AS_NONE;
   signal pl_lba      : unsigned(31 downto 0) := (others => '0');
   signal pl_end      : unsigned(31 downto 0) := (others => '0');
   signal p_w         : t_ent := (others => (others => '0'));
   signal p_idx       : unsigned(7 downto 0) := (others => '0');
   signal pl_bv       : std_logic := '0';       -- pl_byte is pl_lba's
   signal pl_byte     : unsigned(31 downto 0) := (others => '0');
   signal pl_d        : unsigned(31 downto 0) := (others => '0');
   signal pl_have     : std_logic := '0';       -- pl_card is in the buffer
   signal pl_card     : unsigned(31 downto 0) := (others => '0');
   signal pl_off      : unsigned(9 downto 0) := (others => '0');
   signal pl_rem      : unsigned(11 downto 0) := (others => '0');
   signal pl_cnt      : unsigned(9 downto 0) := (others => '0');
   signal pl_half     : std_logic := '0';
   signal pl_wl       : std_logic_vector(15 downto 0) := (others => '0');
   signal pl_wr       : std_logic := '0';
   signal pl_wd       : std_logic_vector(31 downto 0) := (others => '0');
   signal h_lba       : unsigned(31 downto 0) := (others => '0');
   signal cd_free     : unsigned(13 downto 0);
   signal cd_empty    : std_logic;
   signal cd_heard    : std_logic;
   signal cd_under    : std_logic;
   signal st_under    : unsigned(15 downto 0) := (others => '0');
   signal st_low      : unsigned(13 downto 0) := (others => '1');

   signal req         : std_logic := '0';
   signal done_s      : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of done_s : signal is "true";

   -- a table entry's 32-bit field (its low word at k)
   function ew(e : t_ent; k : natural) return unsigned is
   begin
      return unsigned(e(k + 1)) & unsigned(e(k));
   end function ew;

begin

   sd_req_o   <= req;
   sd_req_fresh_o <= x_fresh;
   buf_addr_o <= std_logic_vector(x_a);
   tab_addr_o <= std_logic_vector(t_addr);
   cd_stat_o  <= pl_ast & std_logic_vector(h_lba(23 downto 0)) & std_logic_vector(st_under) &
                 "00" & std_logic_vector(st_low);

   i_audio : entity work.cd_audio
      generic map (
         G_CLK_HZ => G_CLK_HZ,
         G_RATE   => G_RATE,
         G_DEPTH  => 13
      )
      port map (
         clk_i    => clk_i,
         rst_i    => rst_i,
         wr_i     => pl_wr,
         data_i   => pl_wd,
         flush_i  => pl_flush,
         pause_i  => pl_pause,
         free_o   => cd_free,
         empty_o  => cd_empty,
         heard_o  => cd_heard,
         under_o  => cd_under,
         sel0_i   => v_sel0(3 downto 0),
         vol0_i   => v_vol0,
         sel1_i   => v_sel1(3 downto 0),
         vol1_i   => v_vol1,
         l_o      => cd_l_o,
         r_o      => cd_r_o,
         stb_o    => cd_stb_o
      ); -- i_audio

   ---------------------------------------------------------------------------------------------
   -- The bytes of the responses that are no sectors, by x_a (READ TOC's descriptors: S_STREAM
   -- takes them from the table)
   ---------------------------------------------------------------------------------------------

   p_gen : process (all)
      variable p    : natural range 0 to 511;
      variable q    : natural range 0 to 511;
      variable hdr  : natural range 0 to 8;
      variable pg   : natural range 0 to 3;
      variable w    : std_logic_vector(15 downto 0);
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

         when G_TOC =>                           -- the header; the descriptors: the table
            case p is
               when 0      => g_byte <= std_logic_vector(r_nat(15 downto 8));
               when 1      => g_byte <= std_logic_vector(r_nat(7 downto 0));
               when 2 | 3  =>
                  if r_toc = 2 then
                     g_byte <= x"01";            -- the first and last session
                  elsif p = 2 then
                     g_byte <= m_first;
                  else
                     g_byte <= m_last;
                  end if;
               when others => null;
            end case;

         when G_SUB =>                           -- the audio status, then format 1: the place
            case p is
               when 1      => g_byte <= r_ast;
               when 3      =>
                  if r_subq = '1' and r_sfmt = x"01" then
                     g_byte <= x"0C";
                  elsif r_subq = '1' then
                     g_byte <= x"14";
                  end if;
               when 4      => g_byte <= r_sfmt;
               when others =>
                  if r_sfmt = x"01" then
                     case p is
                        when 5      => g_byte <= r_sctl;
                        when 6      => g_byte <= r_strk;
                        when 7      => g_byte <= r_sidx;
                        when 8      => g_byte <= r_sabs(31 downto 24);
                        when 9      => g_byte <= r_sabs(23 downto 16);
                        when 10     => g_byte <= r_sabs(15 downto 8);
                        when 11     => g_byte <= r_sabs(7 downto 0);
                        when 12     => g_byte <= r_srel(31 downto 24);
                        when 13     => g_byte <= r_srel(23 downto 16);
                        when 14     => g_byte <= r_srel(15 downto 8);
                        when 15     => g_byte <= r_srel(7 downto 0);
                        when others => null;
                     end case;
                  end if;
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
                  g_byte <= std_logic_vector(r_nat(7 downto 0) - 2);
               elsif r_m10 = '0' and p = 0 then
                  g_byte <= std_logic_vector(r_nat(7 downto 0) - 1);
               elsif (r_m10 = '1' and p = 2) or (r_m10 = '0' and p = 1) then
                  if m_present = '1' then
                     g_byte <= m_medium;         -- 120 mm: data, audio, both
                  else
                     g_byte <= x"70";            -- no disc
                  end if;
               end if;
            else
               q := p - hdr;
               if r_page = "111111" then
                  if q < 8 then
                     pg := 0;
                  elsif q < 16 then
                     pg := 1;
                     q := q - 8;
                  elsif q < 32 then
                     pg := 2;
                     q := q - 16;
                  else
                     pg := 3;
                     q := q - 32;
                  end if;
               else
                  case r_page is
                     when "000001" => pg := 0;
                     when "001101" => pg := 1;
                     when "001110" => pg := 2;
                     when others   => pg := 3;
                  end case;
               end if;
               w(7 downto 0) := mode_page(pg, q);
               if pg = 2 and q >= 8 and q <= 11 then
                  if r_chg = '1' then            -- channel selects 4 bits, volumes 8
                     if q = 8 or q = 10 then
                        w(7 downto 0) := x"0F";
                     else
                        w(7 downto 0) := x"FF";
                     end if;
                  else
                     case q is
                        when 8      => w(7 downto 0) := v_sel0;
                        when 9      => w(7 downto 0) := v_vol0;
                        when 10     => w(7 downto 0) := v_sel1;
                        when others => w(7 downto 0) := v_vol1;
                     end case;
                  end if;
                  g_byte <= w(7 downto 0);
               elsif r_chg = '1' and q >= 2 then
                  g_byte <= x"00";               -- nothing else can be changed
               else
                  g_byte <= w(7 downto 0);
               end if;
            end if;

         when others =>
            null;
      end case;
   end process p_gen;

   ---------------------------------------------------------------------------------------------
   -- An LBA (or a length) as minutes, seconds and frames
   ---------------------------------------------------------------------------------------------

   p_msf : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if d_start = '1' then
            d_n  <= d_in;
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
               d_f  <= d_n(7 downto 0);
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
      variable v_k     : unsigned(7 downto 0);
      variable v_n     : unsigned(7 downto 0);
      variable v_t     : unsigned(15 downto 0);
      variable v_in    : unsigned(11 downto 0);
      variable v_seek  : boolean;                 -- a SEEK moved h_lba this clock

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

      -- the word at a of the track table, then state t
      procedure tread(a : unsigned(11 downto 0); t : t_state) is
      begin
         t_addr <= a;
         t_ph   <= 0;
         t_ret  <= t;
         state  <= S_TR;
      end procedure tread;

      -- the audio stops (st: the status it leaves)
      procedure stop_play(st : std_logic_vector(7 downto 0)) is
      begin
         if pl_run = '1' then
            pl_ast <= st;
         end if;
         pl_run   <= '0';
         pl_done  <= '0';
         pl_pause <= '0';
         pl_need  <= '0';
         pl_flush <= '1';
      end procedure stop_play;

      -- MODE SELECT's parameter byte v at ms_pos: the header (4 or 8 bytes, with the block
      -- descriptors' length), then pages (code, length): page 0Eh's bytes 8..11
      procedure ms_byte(v : std_logic_vector(7 downto 0)) is
      begin
         if cdb(0) = x"15" and ms_pos = 3 then
            ms_pg <= 4 + resize(unsigned(v), 16);
         elsif cdb(0) = x"55" and ms_pos = 6 then
            ms_pg(15 downto 8) <= unsigned(v);
         elsif cdb(0) = x"55" and ms_pos = 7 then
            ms_pg <= 8 + (ms_pg(15 downto 8) & unsigned(v));
         elsif (cdb(0) = x"15" and ms_pos >= 4) or (cdb(0) = x"55" and ms_pos >= 8) then
            if ms_pos = ms_pg then
               if v(5 downto 0) = "001110" then
                  ms_e  <= '1';
                  ms_e0 <= ms_pg;
               else
                  ms_e <= '0';
               end if;
            elsif ms_pos = ms_pg + 1 then
               ms_pg <= ms_pg + 2 + resize(unsigned(v), 16);
            end if;
            if ms_e = '1' then
               if ms_pos = ms_e0 + 8 then
                  v_sel0 <= v;
               elsif ms_pos = ms_e0 + 9 then
                  v_vol0 <= v;
               elsif ms_pos = ms_e0 + 10 then
                  v_sel1 <= v;
               elsif ms_pos = ms_e0 + 11 then
                  v_vol1 <= v;
               end if;
            end if;
         end if;
      end procedure ms_byte;
   begin
      if rising_edge(clk_i) then
         v_seek       := false;
         mgmt_read_o  <= '0';
         mgmt_write_o <= '0';
         d_start      <= '0';
         trace_we_o   <= '0';
         pl_wr        <= '0';
         pl_flush     <= '0';
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

            -- a word of the track table (the data two clocks after the address)
            when S_TR =>
               if t_ph = 2 then
                  t_q   <= tab_q_i;
                  t_ph  <= 0;
                  state <= t_ret;
               else
                  t_ph <= t_ph + 1;
               end if;

            -- a new disc: its table's header (0 N, 1 the tracks, 2/3 the lead-out, 4 medium)
            when S_TLD =>
               case t_k is
                  when 0 =>
                     t_k <= 1;
                     tread(to_unsigned(0, 12), S_TLD);
                  when 1 =>
                     m_n <= unsigned(t_q(7 downto 0));
                     t_k <= 2;
                     tread(to_unsigned(1, 12), S_TLD);
                  when 2 =>
                     m_first <= t_q(7 downto 0);
                     m_last  <= t_q(15 downto 8);
                     t_k <= 3;
                     tread(to_unsigned(2, 12), S_TLD);
                  when 3 =>
                     m_cap(15 downto 0) <= unsigned(t_q);
                     t_k <= 4;
                     tread(to_unsigned(3, 12), S_TLD);
                  when 4 =>
                     m_cap(31 downto 16) <= unsigned(t_q);
                     t_k <= 5;
                     tread(to_unsigned(4, 12), S_TLD);
                  when others =>
                     m_medium <= t_q(7 downto 0);
                     t_k      <= 0;
                     tl_pend  <= '0';
                     state    <= S_IDLE;
               end case;

            ----------------------------------------------------------------------------------
            -- the track an LBA is in (lk_lba; the tracks follow each other from LBA 0): lk_ok,
            -- its index lk_i and its entry e_w; S_LKL loads track lk_i
            ----------------------------------------------------------------------------------
            when S_LK =>
               lk_i  <= (others => '0');
               lk_ok <= '0';
               if m_n = 0 or lk_lba >= m_cap then
                  state <= lk_ret;
               else
                  tread(to_unsigned(C_T_ENT + 12, 12), S_LK1);
               end if;

            when S_LK1 =>
               lk_lo <= t_q;
               tread(t_addr + 1, S_LK2);

            when S_LK2 =>
               if lk_lba < (unsigned(t_q) & unsigned(lk_lo)) then
                  t_k   <= 0;
                  state <= S_LKL;
               elsif lk_i + 1 = m_n then
                  state <= lk_ret;
               else
                  lk_i <= lk_i + 1;
                  tread(t_addr + 15, S_LK1);
               end if;

            when S_LKL =>
               tread(to_unsigned(C_T_ENT, 12) + shift_left(resize(lk_i, 12), 4) +
                     to_unsigned(t_k, 12), S_LKL1);

            when S_LKL1 =>
               e_w(t_k) <= t_q;
               if t_k = 15 then
                  t_k   <= 0;
                  lk_ok <= '1';
                  state <= lk_ret;
               else
                  t_k   <= t_k + 1;
                  state <= S_LKL;
               end if;

            ----------------------------------------------------------------------------------
            -- the bus: asked for while there is work, given back after it; the table's header
            -- first, the PC before the streamer
            ----------------------------------------------------------------------------------
            when S_IDLE =>
               if tl_pend = '1' then
                  t_k   <= 0;
                  state <= S_TLD;
               elsif init_pend = '1' or ide_request_i /= "000" or pl_need = '1' then
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
                  elsif pl_need = '1' then
                     state <= S_PL;
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
               stop_play(C_AS_NONE);
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
                        stop_play(C_AS_NONE);
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
                  when P_OUT =>
                     if ms_sel = '1' then            -- MODE SELECT's data: its words
                        ms_n  <= x_bytes;
                        b_ph  <= 0;
                        state <= S_MSEL;
                     elsif x_pos = x_total then
                        finish;
                     else
                        state <= S_CHUNK;
                     end if;
                  when P_IN =>
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

            -- MODE SELECT's block out of ide.v's buffer, two bytes a word (ms_n bytes left)
            when S_MSEL =>
               mgmt_address_o <= C_IDE & x"0F";
               case b_ph is
                  when 0 =>
                     if ms_n = 0 then
                        if x_pos = x_total then
                           ms_sel <= '0';
                           finish;
                        else
                           state <= S_CHUNK;
                        end if;
                     else
                        b_ph <= 1;
                     end if;
                  when 1 | 2 =>
                     b_ph <= b_ph + 1;
                  when 3 =>
                     b_q         <= mgmt_readdata_i;
                     mgmt_read_o <= '1';
                     b_ph        <= 4;
                  when 4 =>
                     ms_byte(b_q(7 downto 0));
                     ms_pos <= ms_pos + 1;
                     ms_n   <= ms_n - 1;
                     b_ph   <= 5;
                  when others =>
                     if ms_n /= 0 then
                        ms_byte(b_q(15 downto 8));
                        ms_pos <= ms_pos + 1;
                        ms_n   <= ms_n - 1;
                     end if;
                     b_ph <= 0;
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
                        r_nat  <= to_unsigned(v_nat, 16);
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

                     when x"15" | x"55" =>           -- MODE SELECT (6), (10): page 0Eh kept
                        if cdb(0) = x"15" then
                           v_alloc := to_integer(unsigned(cdb(4)));
                        end if;
                        if v_alloc = 0 then
                           finish;
                        else
                           ms_sel  <= '1';
                           ms_pos  <= (others => '0');
                           ms_pg   <= (others => '1');
                           ms_e    <= '0';
                           x_ata   <= '0';
                           x_total <= n32(v_alloc);
                           x_pos   <= (others => '0');
                           phase   <= P_OUT;
                           state   <= S_CHUNK;
                        end if;

                     when x"1B" =>                   -- START STOP UNIT: stop, eject stop play
                        if cdb(4)(0) = '0' then
                           stop_play(C_AS_NONE);
                        end if;
                        finish;

                     when x"1E" =>                   -- PREVENT ALLOW MEDIUM REMOVAL
                        finish;

                     when x"4B" =>                   -- PAUSE/RESUME
                        if cdb(8)(0) = '0' then
                           if pl_run = '1' and pl_pause = '0' then
                              pl_pause <= '1';
                              pl_ast   <= C_AS_PAUSE;
                           end if;
                           finish;
                        elsif pl_run = '1' and pl_pause = '1' then
                           pl_pause <= '0';
                           pl_ast   <= C_AS_PLAY;
                           finish;
                        else
                           fail(x"5", x"2C", x"00");   -- command sequence error
                        end if;

                     when x"4E" =>                   -- STOP PLAY/SCAN
                        stop_play(C_AS_NONE);
                        finish;

                     when x"25" =>                   -- READ CAPACITY
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           send(G_CAP, n32(8));
                        end if;

                     when x"28" | x"A8" =>           -- READ (10), (12): stops play
                        v_lba := unsigned(cdb(2)) & unsigned(cdb(3)) & unsigned(cdb(4)) &
                                 unsigned(cdb(5));
                        if cdb(0) = x"28" then
                           v_cnt := x"0000" & unsigned(cdb(7)) & unsigned(cdb(8));
                        else
                           v_cnt := unsigned(cdb(6)) & unsigned(cdb(7)) & unsigned(cdb(8)) &
                                    unsigned(cdb(9));
                        end if;
                        stop_play(C_AS_NONE);
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif ('0' & v_lba) + ('0' & v_cnt) > ('0' & m_cap) then
                           fail(x"5", x"21", x"00");   -- beyond the disc
                        elsif v_cnt = 0 then
                           finish;
                        else
                           rd_lba <= v_lba;
                           rd_cnt <= v_cnt;
                           lk_lba <= v_lba;
                           lk_ret <= S_RD0;
                           state  <= S_LK;
                        end if;

                     when x"2B" =>                   -- SEEK: stops play; the head is there
                        stop_play(C_AS_NONE);        -- (READ SUB-CHANNEL's position, PLAY's
                        v_lba := unsigned(cdb(2)) & unsigned(cdb(3)) & unsigned(cdb(4)) &
                                 unsigned(cdb(5));   -- FFh start: Media Player seeks to a
                        if m_present = '0' then      -- track, reads where it is, plays there)
                           fail(x"2", x"3A", x"00");
                        elsif v_lba >= m_cap then
                           fail(x"5", x"21", x"00"); -- past the lead-out
                        else
                           h_lba  <= v_lba;
                           v_seek := true;
                           finish;
                           w_st   <= C_ST_SEEK;
                        end if;

                     when x"43" =>                   -- READ TOC (the format: byte 2, or the
                        v_fmt := cdb(2)(3 downto 0); -- old place, byte 9's top bits)
                        if v_fmt = x"0" then
                           v_fmt := "00" & cdb(9)(7 downto 6);
                        end if;
                        r_msf <= cdb(1)(1);
                        -- v_k: the first descriptor, v_n: how many (the lead-out's too)
                        if cdb(6) = x"AA" then
                           v_k := m_n;
                        elsif unsigned(cdb(6)) <= unsigned(m_first) then
                           v_k := (others => '0');
                        else
                           v_k := unsigned(cdb(6)) - unsigned(m_first);
                        end if;
                        v_n := m_n + 1 - v_k;
                        if cdb(1)(1) = '1' then
                           v_t := to_unsigned(C_T_MSF, 16) + shift_left(resize(v_k, 16), 2);
                        else
                           v_t := to_unsigned(C_T_LBA, 16) + shift_left(resize(v_k, 16), 2);
                        end if;
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif v_fmt = x"0" and cdb(6) /= x"AA" and
                              unsigned(cdb(6)) > unsigned(m_last) then
                           fail(x"5", x"24", x"00");
                        elsif v_fmt = x"0" then
                           r_toc   <= 0;
                           r_tbase <= v_t(11 downto 0);
                           r_nat   <= shift_left(resize(v_n, 16), 3) + 2;
                           send(G_TOC, n32(nmin(to_integer(shift_left(resize(v_n, 16), 3)) + 4,
                                                v_alloc)));
                        elsif v_fmt = x"1" then
                           r_toc   <= 2;             -- the sessions: one, track 1's descriptor
                           if cdb(1)(1) = '1' then
                              r_tbase <= to_unsigned(C_T_MSF, 12);
                           else
                              r_tbase <= to_unsigned(C_T_LBA, 12);
                           end if;
                           r_nat <= to_unsigned(10, 16);
                           send(G_TOC, n32(nmin(12, v_alloc)));
                        else
                           fail(x"5", x"24", x"00");
                        end if;

                     when x"42" =>                   -- READ SUB-CHANNEL
                        r_msf  <= cdb(1)(1);
                        r_subq <= cdb(2)(6);
                        r_sfmt <= cdb(3);
                        r_ast  <= pl_ast;
                        if pl_ast = C_AS_DONE or pl_ast = C_AS_ERR then
                           pl_ast <= C_AS_NONE;      -- reported once
                        end if;
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif cdb(2)(6) = '0' then
                           send(G_SUB, n32(nmin(4, v_alloc)));
                        elsif cdb(3) = x"01" then
                           -- where: the LBA being heard, its track
                           if h_lba >= m_cap and m_cap /= 0 then
                              lk_lba <= m_cap - 1;
                           else
                              lk_lba <= h_lba;
                           end if;
                           lk_ret <= S_SUB0;
                           state  <= S_LK;
                        elsif cdb(3) = x"02" or cdb(3) = x"03" then
                           send(G_SUB, n32(nmin(24, v_alloc)));   -- UPC, ISRC: not valid
                        else
                           fail(x"5", x"24", x"00");
                        end if;

                     when x"45" | x"A5" =>           -- PLAY AUDIO (10), (12)
                        v_lba := unsigned(cdb(2)) & unsigned(cdb(3)) & unsigned(cdb(4)) &
                                 unsigned(cdb(5));
                        if cdb(0) = x"45" then
                           v_cnt := x"0000" & unsigned(cdb(7)) & unsigned(cdb(8));
                        else
                           v_cnt := unsigned(cdb(6)) & unsigned(cdb(7)) & unsigned(cdb(8)) &
                                    unsigned(cdb(9));
                        end if;
                        if v_lba = x"FFFFFFFF" then
                           v_lba := h_lba;           -- from where it is
                        end if;
                        pa_start <= v_lba;
                        pa_end   <= v_lba + v_cnt;
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif v_cnt = 0 then
                           finish;
                        else
                           state <= S_PLAY0;
                        end if;

                     when x"47" =>                   -- PLAY AUDIO MSF
                        if cdb(3) = x"FF" and cdb(4) = x"FF" and cdb(5) = x"FF" then
                           pa_start <= h_lba;
                        else
                           pa_start <= msf_lba(cdb(3), cdb(4), cdb(5));
                        end if;
                        pa_end <= msf_lba(cdb(6), cdb(7), cdb(8));
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        else
                           state <= S_PLAY0;
                        end if;

                     when x"48" =>                   -- PLAY AUDIO TRACK/INDEX
                        if m_present = '0' then
                           fail(x"2", x"3A", x"00");
                        elsif unsigned(cdb(4)) < unsigned(m_first) or
                              unsigned(cdb(4)) > unsigned(m_last) or
                              unsigned(cdb(7)) < unsigned(cdb(4)) then
                           fail(x"5", x"24", x"00");
                        else
                           state <= S_PTI0;
                        end if;

                     when others =>
                        fail(x"5", x"20", x"00");    -- invalid command
                  end case;
               end if;

            ----------------------------------------------------------------------------------
            -- READ, its track found (S_LK): the first byte, cnt sectors of 2048 bytes
            ----------------------------------------------------------------------------------
            when S_RD0 =>
               if lk_ok = '0' then
                  fail(x"5", x"21", x"00");
               elsif e_w(3)(0) = '1' then
                  fail(x"5", x"64", x"00");          -- an audio track: illegal mode
               elsif rd_lba < ew(e_w, 8) or ('0' & rd_lba) + ('0' & rd_cnt) > ('0' & ew(e_w, 10)) then
                  fail(x"5", x"21", x"00");          -- not in its file (a pregap), past it
               else
                  rd_d  <= rd_lba - ew(e_w, 8);
                  r_ss  <= unsigned(e_w(1)(11 downto 0));
                  state <= S_RD1;
               end if;

            when S_RD1 =>                            -- d * sector size: 2048 + 256 + 32 (+ 16)
               if r_ss = 2048 then
                  rd_p <= shift_left(rd_d, 11);
               else
                  rd_p <= shift_left(rd_d, 11) + shift_left(rd_d, 8);
               end if;
               state <= S_RD2;

            when S_RD2 =>
               if r_ss = 2352 then
                  rd_p <= rd_p + shift_left(rd_d, 5) + shift_left(rd_d, 4);
               elsif r_ss = 2336 then
                  rd_p <= rd_p + shift_left(rd_d, 5);
               end if;
               state <= S_RD3;

            when S_RD3 =>
               rd_p  <= rd_p + ew(e_w, 14);
               state <= S_RD4;

            when S_RD4 =>
               rd_p  <= rd_p + resize(unsigned(e_w(2)), 32);
               state <= S_RD5;

            when S_RD5 =>
               rw_card <= "000000000" & rd_p(31 downto 9);
               r_off   <= '0' & rd_p(8 downto 0);
               rw_in   <= (others => '0');
               send(G_DISK, rd_cnt(20 downto 0) & "00000000000");

            ----------------------------------------------------------------------------------
            -- READ SUB-CHANNEL, the track found: index, the addresses (M:S:F by p_msf)
            ----------------------------------------------------------------------------------
            when S_SUB0 =>
               r_sctl <= e_w(0)(15 downto 8);
               r_strk <= e_w(0)(7 downto 0);
               if lk_lba < ew(e_w, 6) then
                  r_sidx <= x"00";                   -- the pregap: counts down
                  r_srel <= std_logic_vector(lk_lba - ew(e_w, 6));
                  d_in   <= ew(e_w, 6) - lk_lba;
               else
                  r_sidx <= x"01";
                  r_srel <= std_logic_vector(lk_lba - ew(e_w, 6));
                  d_in   <= lk_lba - ew(e_w, 6);
               end if;
               if lk_ok = '0' then
                  r_sctl <= x"14";
                  r_strk <= x"01";
                  r_sidx <= x"01";
                  r_srel <= (others => '0');
                  d_in   <= (others => '0');
               end if;
               r_sabs  <= std_logic_vector(lk_lba);
               d_start <= '1';
               state   <= S_SUB1;

            when S_SUB1 =>
               if d_start = '0' and d_st = 0 then
                  if r_msf = '1' then
                     r_srel <= x"00" & std_logic_vector(d_m) & std_logic_vector(d_s) &
                               std_logic_vector(d_f);
                  end if;
                  d_in    <= lk_lba + 150;
                  d_start <= '1';
                  state   <= S_SUB2;
               end if;

            when S_SUB2 =>
               if d_start = '0' and d_st = 0 then
                  if r_msf = '1' then
                     r_sabs <= x"00" & std_logic_vector(d_m) & std_logic_vector(d_s) &
                               std_logic_vector(d_f);
                  end if;
                  send(G_SUB, n32(nmin(16, to_integer(unsigned(cdb(7)) & unsigned(cdb(8))))));
               end if;

            ----------------------------------------------------------------------------------
            -- PLAY AUDIO TRACK/INDEX: the start (INDEX 00 or 01) and end of the tracks
            ----------------------------------------------------------------------------------
            when S_PTI0 =>
               v_k := unsigned(cdb(4)) - unsigned(m_first);
               if cdb(5) = x"00" then
                  tread(to_unsigned(C_T_ENT + 4, 12) + shift_left(resize(v_k, 12), 4), S_PTI1);
               else
                  tread(to_unsigned(C_T_ENT + 6, 12) + shift_left(resize(v_k, 12), 4), S_PTI1);
               end if;

            when S_PTI1 =>
               pa_start(15 downto 0) <= unsigned(t_q);
               tread(t_addr + 1, S_PTI2);

            when S_PTI2 =>
               pa_start(31 downto 16) <= unsigned(t_q);
               if unsigned(cdb(7)) > unsigned(m_last) then
                  v_k := unsigned(m_last) - unsigned(m_first);
               else
                  v_k := unsigned(cdb(7)) - unsigned(m_first);
               end if;
               tread(to_unsigned(C_T_ENT + 12, 12) + shift_left(resize(v_k, 12), 4), S_PTI3);

            when S_PTI3 =>
               pa_end(15 downto 0) <= unsigned(t_q);
               tread(t_addr + 1, S_PTI4);

            when S_PTI4 =>
               pa_end(31 downto 16) <= unsigned(t_q);
               state <= S_PLAY0;

            ----------------------------------------------------------------------------------
            -- PLAY: the range checked, the start's track found, then it plays (the command is
            -- done at once)
            ----------------------------------------------------------------------------------
            when S_PLAY0 =>
               if pa_end > m_cap then
                  fail(x"5", x"21", x"00");
               elsif pa_start = pa_end then
                  finish;
               elsif pa_start > pa_end then
                  fail(x"5", x"24", x"00");
               else
                  lk_lba <= pa_start;
                  lk_ret <= S_PLAY1;
                  state  <= S_LK;
               end if;

            when S_PLAY1 =>
               if lk_ok = '0' then
                  fail(x"5", x"21", x"00");
               elsif e_w(3)(0) = '0' then
                  fail(x"5", x"64", x"00");          -- a data track
               else
                  stop_play(C_AS_NONE);
                  p_w      <= e_w;
                  p_idx    <= lk_i;
                  pl_lba   <= pa_start;
                  pl_end   <= pa_end;
                  h_lba    <= pa_start;
                  pl_bv    <= '0';
                  pl_have  <= '0';
                  pl_half  <= '0';
                  pl_run   <= '1';
                  pl_ast   <= C_AS_PLAY;
                  st_low   <= (others => '1');
                  finish;
               end if;

            ----------------------------------------------------------------------------------
            -- the streamer (the bus granted): sector by sector until the FIFO has no room for
            -- one, or the PLAY's end or a data track
            ----------------------------------------------------------------------------------
            when S_PL =>
               if pl_run = '0' or pl_lba >= pl_end then
                  pl_done <= pl_run;
                  pl_have <= '0';
                  state   <= S_REL;
               elsif cd_free < 588 then
                  pl_have <= '0';                    -- (the ring may change meanwhile)
                  state   <= S_REL;
               elsif pl_lba >= ew(p_w, 12) then
                  state <= S_PLN;                    -- the next track
               elsif pl_lba < ew(p_w, 8) or pl_lba >= ew(p_w, 10) then
                  pl_cnt <= to_unsigned(588, 10);    -- in no file: silence
                  pl_bv  <= '0';
                  state  <= S_PLZ;
               elsif pl_bv = '0' then
                  pl_d  <= pl_lba - ew(p_w, 8);
                  state <= S_PLC0;
               else
                  pl_rem <= to_unsigned(2352, 12);
                  if pl_have = '1' and pl_card = ("000000000" & pl_byte(31 downto 9)) then
                     b_ph  <= 0;
                     state <= S_PLB;
                  else
                     pl_card <= "000000000" & pl_byte(31 downto 9);
                     pl_off  <= '0' & pl_byte(8 downto 0);
                     pl_have <= '0';
                     state   <= S_PLA;
                  end if;
               end if;

            -- the next track: a data track or none ends the PLAY
            when S_PLN =>
               if p_idx + 1 >= m_n then
                  pl_done <= '1';
                  state   <= S_REL;
               else
                  lk_i   <= p_idx + 1;
                  t_k    <= 0;
                  lk_ret <= S_PLN1;
                  state  <= S_LKL;
               end if;

            when S_PLN1 =>
               if e_w(3)(0) = '0' then
                  pl_done <= '1';
                  state   <= S_REL;
               else
                  p_w   <= e_w;
                  p_idx <= lk_i;
                  pl_bv <= '0';
                  state <= S_PL;
               end if;

            when S_PLZ =>
               pl_wr <= '1';
               pl_wd <= (others => '0');
               if pl_cnt = 1 then
                  pl_lba <= pl_lba + 1;
                  state  <= S_PL;
               end if;
               pl_cnt <= pl_cnt - 1;

            -- the sector's byte: its file's + (LBA - first) * 2352
            when S_PLC0 =>
               pl_byte <= shift_left(pl_d, 11) + shift_left(pl_d, 8);
               state   <= S_PLC1;

            when S_PLC1 =>
               pl_byte <= pl_byte + shift_left(pl_d, 5) + shift_left(pl_d, 4);
               state   <= S_PLC2;

            when S_PLC2 =>
               pl_byte <= pl_byte + ew(p_w, 14);
               pl_bv   <= '1';
               state   <= S_PL;

            -- pl_card from the card (all that is left of the track's file in one run)
            when S_PLA =>
               v_left := ew(p_w, 10) - pl_lba;
               sd_req_lba_o <= std_logic_vector(pl_card);
               if v_left >= 52 then
                  sd_req_cnt_o <= '1' & x"00";
               else
                  sd_req_cnt_o <= std_logic_vector(resize(shift_left(v_left, 2) + v_left, 9));
               end if;
               sd_ret <= S_PLW;
               state  <= S_SD_ASK;

            -- its start up to pl_off, in order (disk_sd's checksum), then the words
            when S_PLW =>
               if w_a + 1 >= pl_off then
                  if pl_off /= 0 then
                     x_a <= w_a(8 downto 0);
                  end if;
                  b_ph  <= 0;
                  state <= S_PLB;
               else
                  x_a <= w_a(8 downto 0);
                  w_a <= w_a + 1;
               end if;

            -- a word (a sample's 16 bits; MOTOROLA: big-endian), two make an L/R pair
            when S_PLB =>
               case b_ph is
                  when 0 =>
                     x_a  <= pl_off(8 downto 0);
                     b_ph <= 1;
                  when 1 =>
                     x_a  <= pl_off(8 downto 1) & '1';
                     b_ph <= 2;
                  when 2 =>
                     d_lo <= buf_rd_i;
                     b_ph <= 3;
                  when 3 =>
                     if p_w(3)(1) = '1' then
                        v_word := d_lo & buf_rd_i;
                     else
                        v_word := buf_rd_i & d_lo;
                     end if;
                     if pl_half = '0' then
                        pl_wl <= v_word;
                     else
                        pl_wr <= '1';
                        pl_wd <= v_word & pl_wl;
                     end if;
                     pl_half <= not pl_half;
                     b_ph    <= 4;
                  when others =>
                     b_ph   <= 0;
                     pl_rem <= pl_rem - 2;
                     if pl_off = 510 then            -- the card sector's last word
                        pl_off  <= (others => '0');
                        pl_card <= pl_card + 1;
                        pl_have <= '0';
                     else
                        pl_off <= pl_off + 2;
                     end if;
                     if pl_rem = 2 then              -- the sector is done
                        pl_lba  <= pl_lba + 1;
                        pl_byte <= pl_byte + 2352;
                        state   <= S_PL;
                     elsif pl_off = 510 then
                        state <= S_PLA;              -- (pl_card + 1, from its start)
                     end if;
               end case;

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
               x_done  <= '0';
               x_bytes <= v_c(15 downto 0);
               x_words <= v_c(16 downto 1) + ("000000000000000" & v_c(0));
               x_w     <= (others => '0');
               bs_card <= rw_card;
               bs_off  <= r_off;
               bs_in   <= rw_in;
               if phase = P_OUT then
                  state <= S_REGS;                   -- the PC fills it
               else
                  b_addr <= C_IDE & x"06";           -- the buffer pointer back to 0
                  b_data <= x"0000";
                  ret    <= S_STREAM;
                  state  <= S_BUS_W;
               end if;

            -- word by word: the source byte's address, the next one's, the first byte, the word.
            -- G_DISK: from the card sector in the buffer (asked for first), the bytes after a
            -- raw sector's user data skipped (S_SKIP); G_TOC: its descriptors from the table
            when S_STREAM =>
               mgmt_address_o <= C_IDE & x"0F";
               case b_ph is
                  when 0 =>
                     if x_src = G_DISK and x_have = '0' then
                        -- the card sector, with those the READ still wants
                        v_left := x_total - x_pos;
                        sd_req_lba_o <= std_logic_vector(rw_card);
                        if r_ss = 2048 then
                           v_left := shift_right(v_left, 9);
                        else
                           v_left := shift_right(v_left, 9) + shift_right(v_left, 11) + 1;
                        end if;
                        if v_left >= 256 then
                           sd_req_cnt_o <= '1' & x"00";
                        else
                           sd_req_cnt_o <= std_logic_vector(v_left(8 downto 0));
                        end if;
                        sd_ret <= S_STREAM;
                        state  <= S_SD_ASK;
                     elsif x_src = G_DISK and rw_in(11) = '1' then
                        state <= S_SKIP;
                     else
                        if x_src = G_DISK then
                           x_a <= r_off(8 downto 0);
                        else
                           x_a <= x_pos(8 downto 0);
                        end if;
                        t_addr <= r_tbase + resize(x_pos(11 downto 1), 12) - 2;
                        b_ph   <= 1;
                     end if;
                  when 1 =>
                     if x_src = G_DISK then
                        x_a <= r_off(8 downto 1) & '1';
                     else
                        x_a <= x_pos(8 downto 1) & '1';
                     end if;
                     g_lo <= g_byte;
                     b_ph <= 2;
                  when 2 =>
                     d_lo <= buf_rd_i;
                     g_hi <= g_byte;
                     if x_src = G_TOC and x_pos >= 4 then
                        g_lo <= tab_q_i(7 downto 0);
                        g_hi <= tab_q_i(15 downto 8);
                     end if;
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
                     if x_src = G_DISK then
                        r_off <= r_off + 2;
                        v_in  := rw_in + 2;
                        if v_in = r_ss then
                           v_in := (others => '0');
                        end if;
                        rw_in <= v_in;
                        if r_off = 510 then          -- the card sector's last word: its copy
                           x_have <= '0';            -- against the ring's checksum
                           r_next <= '1';
                           state  <= S_CHK;
                        elsif x_w + 1 = x_words then -- the block ends inside the card sector:
                           w_a   <= r_off + 2;       -- its rest, for the checksum
                           state <= S_TAIL;
                        end if;
                     elsif x_w + 1 = x_words then
                        state <= S_REGS;
                     end if;
               end case;

            -- a raw sector's bytes after its user data: read in order, not sent
            when S_SKIP =>
               x_a   <= r_off(8 downto 0);
               r_off <= r_off + 1;
               v_in  := rw_in + 1;
               if v_in = r_ss then
                  v_in := (others => '0');
               end if;
               rw_in <= v_in;
               if r_off = 511 then
                  x_have <= '0';
                  r_next <= '1';
                  b_ph   <= 0;
                  state  <= S_CHK;
               elsif v_in = 0 then
                  b_ph  <= 0;
                  state <= S_STREAM;
               end if;

            -- the rest of a card sector after a block's last word (it goes on there)
            when S_TAIL =>
               x_a <= w_a(8 downto 0);
               if w_a = 511 then
                  x_have <= '0';
                  r_next <= '0';
                  b_ph   <= 0;
                  state  <= S_CHK;
               else
                  w_a <= w_a + 1;
               end if;

            -- a card sector's start up to r_off, in order, after its answer
            when S_WALK =>
               if w_a + 1 >= r_off then
                  if r_off /= 0 then
                     x_a <= w_a(8 downto 0);
                  end if;
                  b_ph  <= 0;
                  state <= S_STREAM;
               else
                  x_a <= w_a(8 downto 0);
                  w_a <= w_a + 1;
               end if;

            -- disk_sd's verdict on the card sector just copied (four clocks after its last
            -- byte): for one that did not match the ring's checksum the whole block is made
            -- again, its first card sector fresh from the card (a new run, so the others come
            -- fresh too), twice at most: ide.v's buffer pointer only goes back to 0
            when S_CHK =>
               if b_ph < 4 then
                  b_ph <= b_ph + 1;
               else
                  b_ph <= 0;
                  if buf_bad_i = '1' and x_try < 2 then
                     x_try   <= x_try + 1;
                     x_fresh <= '1';
                     x_pos   <= x_start;
                     x_w     <= (others => '0');
                     x_done  <= '0';
                     x_have  <= '0';
                     rw_card <= bs_card;
                     r_off   <= bs_off;
                     rw_in   <= bs_in;
                     b_addr  <= C_IDE & x"06";       -- the buffer pointer back to 0
                     b_data  <= x"0000";
                     ret     <= S_STREAM;
                     state   <= S_BUS_W;
                  elsif r_next = '1' then
                     rw_card <= rw_card + 1;
                     r_off   <= (others => '0');
                     if x_done = '1' then
                        state <= S_REGS;
                     else
                        state <= S_STREAM;
                     end if;
                  else
                     state <= S_REGS;                -- (a tail: the next block goes on at r_off)
                  end if;
               end if;

            when S_SD_ASK =>
               req   <= not req;                     -- lba and cnt were set a clock ago
               x_a   <= (others => '1');             -- (so that the copy's start at 0 counts)
               state <= S_SD_WAIT;

            when S_SD_WAIT =>
               if done_s(2) /= done_s(1) then
                  trace_we_o <= '1';
                  trace_o    <= x"60" & "0000000" & sd_err_i & x"03" & sd_req_cnt_o(7 downto 0) &
                                sd_req_lba_o;
                  x_fresh <= '0';
                  w_a     <= (others => '0');
                  if sd_ret = S_PLW then             -- the streamer's
                     if sd_err_i = '1' then
                        stop_play(C_AS_ERR);
                        state <= S_REL;
                     else
                        pl_have <= '1';
                        state   <= S_PLW;
                     end if;
                  elsif sd_err_i = '1' then
                     fail(x"3", x"11", x"00");       -- MEDIUM ERROR, unrecovered read error
                  else
                     x_have <= '1';
                     state  <= S_WALK;
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

         -- the audio: the sector heard, the end, the FIFO's lowest, when the streamer goes
         if pl_run = '1' and cd_heard = '1' and not v_seek then
            h_lba <= h_lba + 1;
         end if;
         if pl_run = '1' and pl_done = '1' and cd_empty = '1' then
            pl_run <= '0';
            pl_done <= '0';
            pl_ast <= C_AS_DONE;
         end if;
         if cd_under = '1' and pl_run = '1' and pl_pause = '0' and st_under /= x"FFFF" then
            st_under <= st_under + 1;
         end if;
         if pl_run = '1' and pl_done = '0' and to_unsigned(8192, 14) - cd_free < st_low then
            st_low <= to_unsigned(8192, 14) - cd_free;
         end if;
         if pl_run = '1' and pl_done = '0' and cd_free >= 4096 then
            pl_need <= '1';
         else
            pl_need <= '0';
         end if;

         -- a disc came or went: a new one is a UNIT ATTENTION, its table's header, no play
         if mnt_i(3 downto 0) /= m_gen or mnt_i(39) /= m_present then
            m_gen     <= mnt_i(3 downto 0);
            m_present <= mnt_i(39);
            m_cap     <= (others => '0');
            m_n       <= (others => '0');
            h_lba     <= (others => '0');
            stop_play(C_AS_NONE);
            pl_ast    <= C_AS_NONE;
            if mnt_i(39) = '1' then
               ua      <= '1';
               tl_pend <= '1';
            end if;
         end if;

         if rst_i = '1' then
            state     <= S_IDLE;
            phase     <= P_NONE;
            bus_req_o <= '0';
            init_pend <= '1';
            b_ph      <= 0;
            idx       <= 0;
            pl_run    <= '0';
            pl_done   <= '0';
            pl_pause  <= '0';
            pl_ast    <= C_AS_NONE;
            ms_sel    <= '0';
         end if;
      end if;
   end process p_drive;

end architecture synthesis;

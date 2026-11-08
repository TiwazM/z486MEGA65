----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The PC's management bus: what MiSTer's ARM side (Main_MiSTer, support/x86/x86.cpp and
-- ide.cpp) does through hps_ext, in hardware. z486_MiSTer's system.sv decodes the bus by page:
-- F0xx the first IDE channel (ide.v), F2xx the floppy controller (floppy.v), F4xx the RTC's
-- CMOS (rtc.v).
--
--   * At power-up, while the PC is still held in reset: the CMOS configuration (x86_init:
--     equipment, 640 KB base memory, century, LBA translation), the date and time from the
--     MEGA65's RTC (again once, when the RTC has been read: rtc_i(64) toggles; and again
--     whenever the PC restarts, rtc_sync_i: its CMOS clock was the RTC on a PC), both floppy
--     drives empty with 1.44 MB geometry (fdd_set), no hard disk. The CMOS's drive types (10h
--     the floppies, by their images' sizes, 12h/19h the hard disk: F0h/2Fh, type 47) and the
--     checksum of 10h-2Dh are written again whenever a disk comes or goes (rtc.v corrects
--     2Eh/2Fh for the bytes it fills in itself). The BIOS reads them when the PC starts.
--   * Drives A: and B: as disk_sd.vhd mounted them: every change ejects first (register 0 = 0,
--     then 100 ms: the change line the PC reads at 3F7h), then the geometry and the media.
--   * The floppy's sector requests (fdd_request_i, a level): read register 0 (bit 15 drive,
--     14..0 LBA); a read gets the sector from disk_sd and pushes its 512 bytes into register F,
--     a write or a format pops 512 bytes from register F and hands them to disk_sd. A sector of a
--     drive without an image, or one that cannot be read, is 512 zeros, as on MiSTer.
--   * The hard disk (ide.v, master of the first channel; Main_MiSTer's ide.cpp for a raw image,
--     one sector per data block as PCXT-EGA-MEGA65's mgmt_bridge does it): geometry 16 heads x
--     256 sectors (ide_set_geometry(0, 0)), LBA28; the BIOS translates by the capacity and reads
--     and writes by LBA. Request 110 (reset): the task file with BSY, then ready (the slave,
--     never there, reads cylinder FFFFh: the BIOS's probe takes it as absent). Request 100 (a
--     command): EC IDENTIFY, 20/21/C4 reads, 30/31/C5 writes one sector per block (IDENTIFY
--     says one sector per multiple block, C6 accepts 0 and 1), the no-data commands, anything
--     else aborted (error 04h). Request 101: the CPU has the block, the next one follows. Data
--     goes into ide.v's buffer before the registers that announce it (no RDP: ide.v never
--     stalls the CPU).
--   * The CD-ROM drive (pc_cdrom.vhd, the second channel's ide.v at F1xx): it asks for the bus
--     when it has work, and gets it in S_IDLE when nothing else is waiting (S_CD): then its bus
--     accesses, its sector requests (unit 3) and its sector buffer reads go out instead of
--     these. Its requests toggle sd_req_o as well (the two toggles are XORed: only the one
--     with the bus ever toggles).
--
-- Bus timing (floppy.v and ide.v): mgmt_read_o / mgmt_write_o are one-clock pulses, the address
-- stays one clock after each pulse (ide.v moves its buffer pointer on the pulse's trailing edge,
-- by the address then), read data is sampled three clocks after the address is set, at least
-- four after a register F read pulse. Register F's read data is sampled first, then popped.
-- Register reads here never pulse: only the writes move ide.v's buffer pointer (back to 0, so
-- every block starts at the buffer's start).
--
-- The disk_sd.vhd side runs on the QNICE clock: its mount data crosses with cdc_stable (a
-- unit's changes only with its mount generation, which comes last), the sector requests as a
-- toggle with a payload that is stable while it crosses, the answers likewise (CORE.xdc bounds
-- qnice <-> main).
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_mgmt is
   generic (
      G_CLK_HZ          : natural := 64_000_000
   );
   port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;

      -- z486's management bus (z486_mega65.sv)
      mgmt_address_o    : out std_logic_vector(15 downto 0) := (others => '0');
      mgmt_read_o       : out std_logic := '0';
      mgmt_write_o      : out std_logic := '0';
      mgmt_writedata_o  : out std_logic_vector(15 downto 0) := (others => '0');
      mgmt_readdata_i   : in  std_logic_vector(15 downto 0);
      fdd_request_i     : in  std_logic_vector(1 downto 0);  -- bit 0 read, bit 1 write/format
      ide_request_i     : in  std_logic_vector(2 downto 0);  -- 110 reset, 100 command, 101 block
      ide1_request_i    : in  std_logic_vector(2 downto 0);  -- the second channel's (the CD-ROM)

      rtc_i             : in  std_logic_vector(64 downto 0); -- the framework's (BCD)
      rtc_sync_i        : in  std_logic := '0';  -- pulse: the PC restarts, copy the time again

      -- the units as disk_sd mounted them (QNICE clock; disk_sd.vhd's mnt_o)
      mnt_i             : in  std_logic_vector(159 downto 0);

      -- sector requests to disk_sd (a toggle; unit, wr and lba stable from one clock before it)
      -- and its answers (QNICE clock: a toggle, err stable with it)
      sd_req_o          : out std_logic;
      sd_req_wr_o       : out std_logic := '0';
      sd_req_unit_o     : out std_logic_vector(1 downto 0) := (others => '0');
      sd_req_lba_o      : out std_logic_vector(31 downto 0) := (others => '0');
      -- the sectors a hard disk read command still wants from this one on (1..256), which
      -- disk_sd reads ahead in one SD transfer; 0 = not known (the floppies)
      sd_req_cnt_o      : out std_logic_vector(8 downto 0) := (others => '0');
      -- the sector again, fresh from the card (disk_sd starts a new run): its copy out of the
      -- ring did not match (buf_bad_i)
      sd_req_fresh_o    : out std_logic := '0';
      sd_done_i         : in  std_logic;
      sd_err_i          : in  std_logic;

      -- the sector buffer (disk_sd's block RAM, its clk_i port; read data one clock later)
      buf_addr_o        : out std_logic_vector(8 downto 0) := (others => '0');
      buf_we_o          : out std_logic := '0';
      buf_wd_o          : out std_logic_vector(7 downto 0) := (others => '0');
      buf_rd_i          : in  std_logic_vector(7 downto 0);
      -- disk_sd: the last copy out of the ring did not match its checksum (a hard disk, CD-ROM
      -- or floppy read then asks for the sector again, fresh from the card, twice at most)
      buf_bad_i         : in  std_logic := '0';

      -- the CD-ROM drive's track table (mega65.vhd's block RAM: the data two clocks after the
      -- address), its audio (44.1 kHz) and how that goes (pc_cdrom.vhd's cd_stat_o)
      cd_tab_addr_o     : out std_logic_vector(11 downto 0);
      cd_tab_q_i        : in  std_logic_vector(15 downto 0) := (others => '0');
      cd_l_o            : out std_logic_vector(15 downto 0);
      cd_r_o            : out std_logic_vector(15 downto 0);
      cd_stb_o          : out std_logic;          -- a pulse: a sample from the FIFO (testbench)
      cd_stat_o         : out std_logic_vector(63 downto 0);

      -- the IDE trace (mega65.vhd keeps it): one event per clock at most, bits 63..60 the
      -- event, 59..56 0, then three bytes A, B, C and 32 bits of data (CD-ROM events from
      -- pc_cdrom.vhd too)
      --   1 a command, first channel: A command, B drive/head, C count, data cylinder & sector
      --   2 its registers set: A pc_mgmt's status (w_st), B error, C count, data cylinder & sector
      --   3 request 101 (a block done): A bit 1 write, bit 0 a transfer going on, C sectors
      --     left, data the LBA
      --   4 a reset (request 110): A drive/head
      --   5 a floppy request: A bit 0 write, data drive (bit 15) and LBA
      --   6 an SD answer: A bit 1 write, bit 0 failed, B the unit, C count (7..0), data the LBA
      --   8-12 the CD-ROM drive (pc_cdrom.vhd)
      trace_we_o        : out std_logic;
      trace_o           : out std_logic_vector(63 downto 0)
   );
end entity pc_mgmt;

architecture synthesis of pc_mgmt is

   -- The CMOS at power-up (x86_init): 10h-2Dh; 10h, 12h and 19h follow the disks (S_CMOS_DYN),
   -- 2Eh/2Fh are the 16-bit sum of 10h-2Dh
   type t_cmos is array (16#10# to 16#2D#) of natural range 0 to 255;
   constant C_CMOS : t_cmos := (
      16#14# => 16#4D#,             -- equipment: two floppy drives, VGA, keyboard (rtc.v adds the FPU)
      16#15# => 16#80#,             -- 640 KB base memory
      16#16# => 16#02#,
      16#18# => 16#3C#,             -- extended memory (rtc.v replaces it and corrects the sum)
      others => 0);

   function cmos_sum return natural is
      variable s : natural := 0;
   begin
      for i in C_CMOS'range loop
         s := s + C_CMOS(i);
      end loop;
      return s;
   end function cmos_sum;

   -- The other bytes after the block: address, data
   type t_pair is record
      a : natural range 0 to 127;
      d : natural range 0 to 255;
   end record;
   type t_pairs is array (natural range <>) of t_pair;
   constant C_CMOS_MORE : t_pairs := (
      (16#32#, 16#20#),             -- century (BCD)
      (16#37#, 16#20#),             -- century (PS/2)
      (16#39#, 16#55#));            -- LBA translation for the hard disks

   -- The floppy registers, drive d at F2xx + d * 80h: 0 media, 1 write protect, 2 cylinders,
   -- 3 sectors per track, 4 sectors, 5 heads, F the FIFO. ide.v: 0-5 the task file, 6 the
   -- drives, F the buffer.
   constant C_IDE     : std_logic_vector(7 downto 0) := x"F0";
   constant C_FDD     : std_logic_vector(7 downto 0) := x"F2";
   constant C_CMOS_PG : std_logic_vector(7 downto 0) := x"F4";

   constant C_EJECT_WAIT : natural := G_CLK_HZ / 10;          -- 100 ms

   -- The CMOS type of a floppy image by its sectors (unmounted: 1.44 MB, as MiSTer)
   function fdd_type(mounted : std_logic; total : std_logic_vector(15 downto 0)) return natural is
   begin
      if mounted = '1' then
         case to_integer(unsigned(total)) is
            when 720    => return 1;           -- 360 KB
            when 2400   => return 2;           -- 1.2 MB
            when 1440   => return 3;           -- 720 KB
            when 5760   => return 5;           -- 2.88 MB
            when others => return 4;
         end case;
      end if;
      return 4;
   end function fdd_type;

   -- IDENTIFY DEVICE (ide.cpp's, for a raw image of t sectors, 16 heads x 256 sectors)
   constant C_MODEL : string(1 to 40) := "z486 MEGA65 hard disk                   ";
   function ident(k : natural; t : unsigned(31 downto 0)) return std_logic_vector is
      variable c : unsigned(15 downto 0);
   begin
      if t(31 downto 28) /= 0 then
         c := x"FFFF";
      else
         c := t(27 downto 12);
      end if;
      case k is
         when 0      => return x"0040";
         when 1 | 54 => return std_logic_vector(c);
         when 3 | 55 => return x"0010";
         when 5      => return x"0200";
         when 6 | 56 => return x"0100";
         when 10     => return x"414F";                -- serial "AOHD00000"
         when 11     => return x"4844";
         when 12     => return x"3030";
         when 13     => return x"3030";
         when 14     => return x"3020";
         when 15 to 19 => return x"2020";
         when 20     => return x"0003";
         when 21     => return x"0200";
         when 22     => return x"0004";
         when 27 to 46 =>                               -- the model, first character high
            return std_logic_vector(to_unsigned(character'pos(C_MODEL(2 * (k - 27) + 1)), 8)) &
                   std_logic_vector(to_unsigned(character'pos(C_MODEL(2 * (k - 27) + 2)), 8));
         when 47     => return x"8001";                -- one sector per multiple block
         when 48     => return x"0001";                -- 32-bit I/O
         when 49     => return x"0200";                -- LBA
         when 50     => return x"4001";
         when 51 | 52 => return x"0200";
         when 53     => return x"0007";
         when 57 | 60 | 100 => return std_logic_vector(t(15 downto 0));
         when 58 | 61 | 101 => return std_logic_vector(t(31 downto 16));
         when 59     => return x"0101";                -- multiple: 1
         when 65 to 68 => return x"0078";
         when 80     => return x"007E";
         when 82 | 85 => return x"4200";
         when 83 | 86 => return x"7000";
         when 84 | 87 => return x"4000";
         when 93     => return x"630B";
         when others => return x"0000";
      end case;
   end function ident;

   type t_state is (
      S_START,
      S_CMOS, S_CMOS_MORE, S_TIME, S_FD_INIT, S_IDE_INIT,
      S_CMOS_DYN,
      S_IDLE,
      S_MNT_EJECTED, S_MNT_WAIT, S_MNT_GEO,
      S_REQ_GOT,
      S_SD_ASK, S_SD_WAIT,
      S_PUSH, S_POP, S_POP_GOT, S_POP_DONE,
      S_REQ_END,
      S_HDD_MNT,
      S_IDE_RST1, S_IDE_RST2,
      S_IDE_CMD1, S_IDE_CMD2, S_IDE_CMD3, S_IDE_CMD,
      S_IDE_IDENT,
      S_HR_SD, S_HR_STREAM, S_HR_CHK, S_HR_REGS, S_FD_CHK,
      S_HW_BLOCK, S_HW_POP, S_HW_SD, S_HW_DONE,
      S_IDE_BLK,
      S_WREGS,
      S_CD,
      S_BUS_W, S_BUS_R
   );
   signal state       : t_state := S_START;
   signal ret         : t_state := S_START;      -- after S_BUS_W / S_BUS_R
   signal time_ret    : t_state := S_FD_INIT;    -- after S_TIME
   signal sd_next     : t_state := S_IDLE;       -- after the SD answer
   signal w_ret       : t_state := S_IDLE;       -- after S_WREGS

   -- one bus access: S_BUS_W writes b_data to b_addr, S_BUS_R reads b_addr into b_q
   signal b_addr      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_data      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal b_ph        : natural range 0 to 7 := 0;

   signal idx         : natural range 0 to 511 := 0;
   signal cnt         : natural range 0 to C_EJECT_WAIT := 0;

   -- this side's bus accesses, sector requests and buffer reads (the CD-ROM's go out instead
   -- in S_CD)
   signal pm_address  : std_logic_vector(15 downto 0) := (others => '0');
   signal pm_read     : std_logic := '0';
   signal pm_write    : std_logic := '0';
   signal pm_wdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal pm_req_wr   : std_logic := '0';
   signal pm_req_unit : std_logic_vector(1 downto 0) := (others => '0');
   signal pm_req_lba  : std_logic_vector(31 downto 0) := (others => '0');
   signal pm_req_cnt  : std_logic_vector(8 downto 0) := (others => '0');
   signal pm_req_fresh : std_logic := '0';
   signal pm_buf_addr : std_logic_vector(8 downto 0) := (others => '0');

   -- the CD-ROM drive
   signal cd_bus_req  : std_logic;
   signal cd_gnt      : std_logic;
   signal cd_address  : std_logic_vector(15 downto 0);
   signal cd_read     : std_logic;
   signal cd_write    : std_logic;
   signal cd_wdata    : std_logic_vector(15 downto 0);
   signal cd_req      : std_logic;
   signal cd_req_lba  : std_logic_vector(31 downto 0);
   signal cd_req_cnt  : std_logic_vector(8 downto 0);
   signal cd_req_fresh : std_logic;
   signal cd_buf_addr : std_logic_vector(8 downto 0);
   signal cd_tr_we    : std_logic;
   signal cd_tr       : std_logic_vector(63 downto 0);

   -- this side's trace events
   signal tr_we       : std_logic := '0';
   signal tr          : std_logic_vector(63 downto 0) := (others => '0');

   -- the units as disk_sd has them (crossed) and as the PC's controllers have them
   signal m_dst       : std_logic_vector(159 downto 0);
   type t_b4  is array (0 to 1) of std_logic_vector(3 downto 0);
   type t_b16 is array (0 to 1) of std_logic_vector(15 downto 0);
   signal a_mounted   : std_logic_vector(1 downto 0) := "00";
   signal a_gen       : t_b4 := (others => (others => '0'));
   signal a_total     : t_b16 := (others => (others => '0'));
   signal m_drv       : natural range 0 to 1 := 0;    -- the floppy being mounted
   signal m_cur       : std_logic_vector(39 downto 0);   -- its data
   signal h_try       : natural range 0 to 2 := 0;  -- the sector's copies made again
   signal h_present   : std_logic := '0';
   signal h_gen       : std_logic_vector(3 downto 0) := (others => '0');
   signal h_total     : unsigned(31 downto 0) := (others => '0');

   -- the time again once the RTC has been read, and whenever the PC restarts
   signal rtc_tgl     : std_logic := '0';
   signal rtc_again   : std_logic := '1';
   signal rtc_now     : std_logic := '0';

   -- the floppy request being served
   signal r_wr        : std_logic := '0';
   signal r_serve     : std_logic := '0';       -- '1': a drive with an image
   signal r_ok        : std_logic := '0';       -- '1': the sector came from the card

   signal req         : std_logic := '0';
   signal done_s      : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of done_s : signal is "true";

   -- the IDE task file as read (cmd, dh = the drive/head register) and as written (S_WREGS)
   signal t_sec       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_cnt       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_cyl       : std_logic_vector(15 downto 0) := (others => '0');
   signal t_cmd       : std_logic_vector(7 downto 0) := (others => '0');
   signal t_dh        : std_logic_vector(7 downto 0) := (others => '0');
   signal w_err       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_blk       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_sec       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_cnt       : std_logic_vector(7 downto 0) := (others => '0');
   signal w_cyl       : std_logic_vector(15 downto 0) := (others => '0');
   signal w_st        : std_logic_vector(7 downto 0) := (others => '0');
   signal w_dh        : std_logic_vector(7 downto 0) := (others => '0');

   -- the IDE transfer: i_act = a block is with the CPU (request 101 continues it)
   signal i_act       : std_logic := '0';
   signal i_wr        : std_logic := '0';
   signal i_lbam      : std_logic := '0';       -- LBA addressing (else CHS 16 x 256)
   signal i_lba       : unsigned(27 downto 0) := (others => '0');
   signal i_cnt       : unsigned(7 downto 0) := (others => '0');   -- sectors left; 0 = 256
   signal i_lo        : std_logic_vector(7 downto 0) := (others => '0');

   function bcd_dow(dow : std_logic_vector(7 downto 0)) return std_logic_vector is
      -- the MEGA65's 0 = Monday .. 6 = Sunday to the CMOS's 1 = Sunday .. 7 = Saturday
      variable v : natural range 0 to 255;
   begin
      v := to_integer(unsigned(dow));
      if v >= 6 then
         return x"01";
      else
         return std_logic_vector(to_unsigned(v + 2, 8));
      end if;
   end function bcd_dow;

begin

   i_cdc_mount : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 160
      )
      port map (
         src_data_i => mnt_i,
         dst_clk_i  => clk_i,
         dst_data_o => m_dst
      ); -- i_cdc_mount

   -- the floppy being mounted: 39 mounted, 38 write protected, 37..30 cylinders, 29..22 sectors
   -- per track, 21..6 sectors, 5..4 heads, 3..0 generation. The hard disk: 119 mounted, 118
   -- write protected, 117..86 sectors, 83..80 generation.
   m_cur <= m_dst(40 * m_drv + 39 downto 40 * m_drv);

   -- this side's outputs, or the CD-ROM's while it has the bus
   cd_gnt           <= '1' when state = S_CD else '0';
   mgmt_address_o   <= cd_address when cd_gnt = '1' else pm_address;
   mgmt_read_o      <= cd_read    when cd_gnt = '1' else pm_read;
   mgmt_write_o     <= cd_write   when cd_gnt = '1' else pm_write;
   mgmt_writedata_o <= cd_wdata   when cd_gnt = '1' else pm_wdata;
   sd_req_o         <= req xor cd_req;
   sd_req_wr_o      <= '0'        when cd_gnt = '1' else pm_req_wr;
   sd_req_unit_o    <= "11"       when cd_gnt = '1' else pm_req_unit;
   sd_req_lba_o     <= cd_req_lba when cd_gnt = '1' else pm_req_lba;
   sd_req_cnt_o     <= cd_req_cnt when cd_gnt = '1' else pm_req_cnt;
   sd_req_fresh_o   <= cd_req_fresh when cd_gnt = '1' else pm_req_fresh;
   buf_addr_o       <= cd_buf_addr when cd_gnt = '1' else pm_buf_addr;
   trace_we_o       <= tr_we or cd_tr_we;
   trace_o          <= cd_tr when cd_tr_we = '1' else tr;

   i_cdrom : entity work.pc_cdrom
      generic map (
         G_CLK_HZ         => G_CLK_HZ
      )
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         bus_req_o        => cd_bus_req,
         bus_gnt_i        => cd_gnt,
         mgmt_address_o   => cd_address,
         mgmt_read_o      => cd_read,
         mgmt_write_o     => cd_write,
         mgmt_writedata_o => cd_wdata,
         mgmt_readdata_i  => mgmt_readdata_i,
         ide_request_i    => ide1_request_i,
         mnt_i            => m_dst(159 downto 120),
         tab_addr_o       => cd_tab_addr_o,
         tab_q_i          => cd_tab_q_i,
         sd_req_o         => cd_req,
         sd_req_lba_o     => cd_req_lba,
         sd_req_cnt_o     => cd_req_cnt,
         sd_req_fresh_o   => cd_req_fresh,
         sd_done_i        => sd_done_i,
         sd_err_i         => sd_err_i,
         buf_addr_o       => cd_buf_addr,
         buf_rd_i         => buf_rd_i,
         buf_bad_i        => buf_bad_i,
         cd_l_o           => cd_l_o,
         cd_r_o           => cd_r_o,
         cd_stb_o         => cd_stb_o,
         cd_stat_o        => cd_stat_o,
         trace_we_o       => cd_tr_we,
         trace_o          => cd_tr
      ); -- i_cdrom

   p_mgmt : process (clk_i)
      variable v_byte : std_logic_vector(7 downto 0);
      variable v_l    : unsigned(27 downto 0);
      variable v_left : unsigned(7 downto 0);
      variable v_sum  : natural range 0 to 65535;
   begin
      if rising_edge(clk_i) then
         pm_read  <= '0';
         pm_write <= '0';
         buf_we_o     <= '0';
         tr_we        <= '0';
         done_s       <= done_s(1 downto 0) & sd_done_i;

         case state is

            ----------------------------------------------------------------------------------
            -- one bus access, then back to ret
            ----------------------------------------------------------------------------------
            when S_BUS_W =>
               -- 0: address and data out, 1: the write pulse, 2/3: the address stays
               pm_address   <= b_addr;
               pm_wdata <= b_data;
               if b_ph = 1 then
                  pm_write <= '1';
               end if;
               if b_ph = 3 then
                  b_ph  <= 0;
                  state <= ret;
               else
                  b_ph <= b_ph + 1;
               end if;

            when S_BUS_R =>
               -- 0: address out, 3: the data has settled
               pm_address <= b_addr;
               if b_ph = 3 then
                  b_q   <= mgmt_readdata_i;
                  b_ph  <= 0;
                  state <= ret;
               else
                  b_ph <= b_ph + 1;
               end if;

            -- the IDE task file: 0 error/block, 1 sector/count, 2 cylinder, 3, 4 (LBA48) 0, 5
            -- status/drive-head last (it rewinds ide.v's buffer pointer and clears the request)
            when S_WREGS =>
               if idx = 0 then
                  tr_we <= '1';
                  tr    <= x"20" & w_st & w_err & w_cnt & x"00" & w_cyl & w_sec;
               end if;
               b_addr <= C_IDE & std_logic_vector(to_unsigned(idx, 8));
               case idx is
                  when 0      => b_data <= w_err & w_blk;
                  when 1      => b_data <= w_sec & w_cnt;
                  when 2      => b_data <= w_cyl;
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
            -- power-up: CMOS, time, both floppy drives empty, no hard disk
            ----------------------------------------------------------------------------------
            when S_START =>
               idx   <= 16#10#;
               state <= S_CMOS;

            when S_CMOS =>
               b_addr <= C_CMOS_PG & std_logic_vector(to_unsigned(idx, 8));
               b_data <= x"00" & std_logic_vector(to_unsigned(C_CMOS(idx), 8));
               state  <= S_BUS_W;
               if idx = 16#2D# then
                  idx <= 0;
                  ret <= S_CMOS_MORE;
               else
                  idx <= idx + 1;
                  ret <= S_CMOS;
               end if;

            when S_CMOS_MORE =>
               b_addr <= C_CMOS_PG & std_logic_vector(to_unsigned(C_CMOS_MORE(idx).a, 8));
               b_data <= x"00" & std_logic_vector(to_unsigned(C_CMOS_MORE(idx).d, 8));
               state  <= S_BUS_W;
               if idx = C_CMOS_MORE'high then
                  idx      <= 0;
                  time_ret <= S_FD_INIT;
                  ret      <= S_TIME;
               else
                  idx <= idx + 1;
                  ret <= S_CMOS_MORE;
               end if;

            -- 00h seconds, 02h minutes, 04h hours, 06h day of week, 07h day, 08h month, 09h year
            when S_TIME =>
               b_data(15 downto 8) <= x"00";
               case idx is
                  when 0 => b_addr <= C_CMOS_PG & x"00"; b_data(7 downto 0) <= rtc_i(7 downto 0);
                            rtc_tgl <= rtc_i(64);
                  when 1 => b_addr <= C_CMOS_PG & x"02"; b_data(7 downto 0) <= rtc_i(15 downto 8);
                  when 2 => b_addr <= C_CMOS_PG & x"04"; b_data(7 downto 0) <= rtc_i(23 downto 16);
                  when 3 => b_addr <= C_CMOS_PG & x"07"; b_data(7 downto 0) <= rtc_i(31 downto 24);
                  when 4 => b_addr <= C_CMOS_PG & x"08"; b_data(7 downto 0) <= rtc_i(39 downto 32);
                  when 5 => b_addr <= C_CMOS_PG & x"09"; b_data(7 downto 0) <= rtc_i(47 downto 40);
                  when others =>
                     b_addr <= C_CMOS_PG & x"06"; b_data(7 downto 0) <= bcd_dow(rtc_i(55 downto 48));
               end case;
               state <= S_BUS_W;
               if idx = 6 then
                  idx <= 0;
                  ret <= time_ret;
               else
                  idx <= idx + 1;
                  ret <= S_TIME;
               end if;

            -- both drives: no media, write protected, 80 cylinders, 18 sectors, 2880 sectors,
            -- 2 heads (idx: bit 3 = the drive, bits 2..0 = the register)
            when S_FD_INIT =>
               state  <= S_BUS_W;
               ret    <= S_FD_INIT;
               b_addr <= C_FDD & std_logic_vector(to_unsigned((idx / 8) * 128 + idx mod 8, 8));
               case idx mod 8 is
                  when 0      => b_data <= x"0000";
                  when 1      => b_data <= x"0001";
                  when 2      => b_data <= x"0050";
                  when 3      => b_data <= x"0012";
                  when 4      => b_data <= x"0B40";
                  when others => b_data <= x"0002";
               end case;
               if idx = 13 then
                  idx <= 0;
                  ret <= S_IDE_INIT;
               elsif idx mod 8 = 5 then
                  idx <= idx + 3;
               else
                  idx <= idx + 1;
               end if;

            -- ide.v: no drives (6: bit 3 = the master's present/hob bits follow), use_wait 0
            when S_IDE_INIT =>
               b_addr <= C_IDE & x"06";
               state  <= S_BUS_W;
               if idx = 0 then
                  b_data <= x"0008";
                  idx    <= 1;
                  ret    <= S_IDE_INIT;
               else
                  b_data <= x"0200";
                  idx    <= 0;
                  ret    <= S_CMOS_DYN;
               end if;

            -- the CMOS's drive types and the checksum: 10h, 12h, 19h, 2Eh, 2Fh
            when S_CMOS_DYN =>
               v_sum := cmos_sum + fdd_type(a_mounted(0), a_total(0)) * 16 +
                        fdd_type(a_mounted(1), a_total(1));
               if h_present = '1' then
                  v_sum := v_sum + 16#F0# + 16#2F#;
               end if;
               b_data(15 downto 8) <= x"00";
               case idx is
                  when 0 =>
                     b_addr <= C_CMOS_PG & x"10";
                     b_data(7 downto 0) <= std_logic_vector(to_unsigned(fdd_type(a_mounted(0), a_total(0)), 4)) &
                                           std_logic_vector(to_unsigned(fdd_type(a_mounted(1), a_total(1)), 4));
                  when 1 =>
                     b_addr <= C_CMOS_PG & x"12";
                     b_data(7 downto 0) <= (others => h_present);
                     b_data(3 downto 0) <= "0000";
                  when 2 =>
                     b_addr <= C_CMOS_PG & x"19";
                     if h_present = '1' then b_data(7 downto 0) <= x"2F"; else b_data(7 downto 0) <= x"00"; end if;
                  when 3 =>
                     b_addr <= C_CMOS_PG & x"2E";
                     b_data(7 downto 0) <= std_logic_vector(to_unsigned(v_sum / 256, 8));
                  when others =>
                     b_addr <= C_CMOS_PG & x"2F";
                     b_data(7 downto 0) <= std_logic_vector(to_unsigned(v_sum mod 256, 8));
               end case;
               state <= S_BUS_W;
               if idx = 4 then
                  idx <= 0;
                  ret <= S_IDLE;
               else
                  idx <= idx + 1;
                  ret <= S_CMOS_DYN;
               end if;

            ----------------------------------------------------------------------------------
            -- idle: a disk change, a hard disk request, a floppy request, the RTC
            ----------------------------------------------------------------------------------
            when S_IDLE =>
               pm_address <= x"0000";
               if m_dst(3 downto 0) /= a_gen(0) or m_dst(39) /= a_mounted(0) or
                  m_dst(43 downto 40) /= a_gen(1) or m_dst(79) /= a_mounted(1) then
                  -- a floppy changed: the first one that did
                  if m_dst(3 downto 0) /= a_gen(0) or m_dst(39) /= a_mounted(0) then
                     m_drv        <= 0;
                     a_gen(0)     <= m_dst(3 downto 0);
                     a_mounted(0) <= m_dst(39);
                     a_total(0)   <= m_dst(21 downto 6);
                     b_addr       <= C_FDD & x"00";   -- out first
                  else
                     m_drv        <= 1;
                     a_gen(1)     <= m_dst(43 downto 40);
                     a_mounted(1) <= m_dst(79);
                     a_total(1)   <= m_dst(61 downto 46);
                     b_addr       <= C_FDD & x"80";
                  end if;
                  b_data <= x"0000";
                  state  <= S_BUS_W;
                  ret    <= S_MNT_EJECTED;
               elsif m_dst(83 downto 80) /= h_gen or m_dst(119) /= h_present then
                  -- the hard disk changed (the PC sees it at its next start)
                  h_gen     <= m_dst(83 downto 80);
                  h_present <= m_dst(119);
                  h_total   <= unsigned(m_dst(117 downto 86));
                  i_act     <= '0';
                  state     <= S_HDD_MNT;
               elsif ide_request_i = "110" then
                  i_act  <= '0';
                  b_addr <= C_IDE & x"05";
                  state  <= S_BUS_R;
                  ret    <= S_IDE_RST1;
               elsif ide_request_i = "100" then
                  i_act  <= '0';
                  b_addr <= C_IDE & x"01";
                  state  <= S_BUS_R;
                  ret    <= S_IDE_CMD1;
               elsif ide_request_i = "101" then
                  state <= S_IDE_BLK;
               elsif fdd_request_i /= "00" then
                  r_wr   <= fdd_request_i(1);
                  b_addr <= C_FDD & x"00";
                  state  <= S_BUS_R;
                  ret    <= S_REQ_GOT;
               elsif rtc_now = '1' or (rtc_again = '1' and rtc_i(64) /= rtc_tgl) then
                  if rtc_i(64) /= rtc_tgl then
                     rtc_again <= '0';                -- the RTC's first read is in: done
                  end if;
                  rtc_now   <= '0';
                  idx       <= 0;
                  time_ret  <= S_IDLE;
                  state     <= S_TIME;
               elsif cd_bus_req = '1' then
                  state <= S_CD;                     -- the CD-ROM drive has the bus
               end if;

            -- until the CD-ROM drive gives the bus back
            when S_CD =>
               if cd_bus_req = '0' then
                  state <= S_IDLE;
               end if;

            ----------------------------------------------------------------------------------
            -- a floppy gets its image: 100 ms without media, then the geometry and the media
            ----------------------------------------------------------------------------------
            when S_MNT_EJECTED =>
               cnt <= 0;
               if m_cur(39) = '1' then
                  state <= S_MNT_WAIT;
               else
                  state <= S_CMOS_DYN;
               end if;

            when S_MNT_WAIT =>
               if cnt = C_EJECT_WAIT then
                  idx   <= 1;
                  state <= S_MNT_GEO;
               else
                  cnt <= cnt + 1;
               end if;

            when S_MNT_GEO =>
               b_addr <= C_FDD & std_logic_vector(to_unsigned(m_drv * 128 + idx, 8));
               case idx is
                  when 1      => b_data <= x"000" & "000" & m_cur(38);
                  when 2      => b_data <= x"00" & m_cur(37 downto 30);
                  when 3      => b_data <= x"00" & m_cur(29 downto 22);
                  when 4      => b_data <= m_cur(21 downto 6);
                  when 5      => b_data <= x"000" & "00" & m_cur(5 downto 4);
                  when others => b_data <= x"0001";      -- 0: media present, last
               end case;
               state <= S_BUS_W;
               if idx = 0 then
                  ret <= S_CMOS_DYN;
               elsif idx = 5 then
                  idx <= 0;
                  ret <= S_MNT_GEO;
               else
                  idx <= idx + 1;
                  ret <= S_MNT_GEO;
               end if;

            -- the hard disk: the master present (6 = 0009h) or not (0008h), then the CMOS
            when S_HDD_MNT =>
               b_addr <= C_IDE & x"06";
               b_data <= x"000" & '1' & "00" & h_present;
               state  <= S_BUS_W;
               idx    <= 0;
               ret    <= S_CMOS_DYN;

            ----------------------------------------------------------------------------------
            -- a floppy sector
            ----------------------------------------------------------------------------------
            when S_REQ_GOT =>
               tr_we <= '1';
               tr    <= x"50" & "0000000" & r_wr & x"0000" & x"0000" & b_q;
               -- b_q: bit 15 = drive B:, 14..0 = the LBA
               pm_req_unit <= '0' & b_q(15);
               pm_req_lba  <= x"0000" & '0' & b_q(14 downto 0);
               pm_req_cnt  <= (others => '0');
               pm_req_wr   <= r_wr;
               r_ok          <= '0';
               idx           <= 0;
               r_serve       <= a_mounted(to_integer(unsigned(b_q(15 downto 15))));
               if r_wr = '1' then
                  state <= S_POP;                    -- the PC's bytes first
               elsif a_mounted(to_integer(unsigned(b_q(15 downto 15)))) = '1' then
                  h_try   <= 0;
                  sd_next <= S_FD_CHK;
                  state   <= S_SD_ASK;
               else
                  state <= S_PUSH;                   -- zeros
               end if;

            when S_SD_ASK =>
               req   <= not req;                     -- unit, wr and lba were set a clock ago
               pm_buf_addr <= (others => '1');       -- (so that the copy's start at 0 counts:
                                                     -- disk_sd checks a copy that moves to 0)
               state <= S_SD_WAIT;

            when S_SD_WAIT =>
               if done_s(2) /= done_s(1) then
                  tr_we <= '1';
                  tr    <= x"60" & "000000" & pm_req_wr & sd_err_i & "000000" & pm_req_unit &
                           pm_req_cnt(7 downto 0) & pm_req_lba;
                  r_ok  <= not sd_err_i;
                  pm_req_fresh <= '0';
                  idx   <= 0;
                  state <= sd_next;
               end if;

            -- floppy.v's FIFO cannot take a sector back, so first a copy of the slot only for
            -- disk_sd's checksum (a byte a clock, its verdict two clocks after the last); one
            -- that does not match comes again fresh from the card, twice at most (the ring's
            -- wrong bits are stored ones: a fresh sector reads right), then S_PUSH
            when S_FD_CHK =>
               case b_ph is
                  when 0 =>
                     pm_buf_addr <= std_logic_vector(to_unsigned(idx, 9));
                     if idx = 511 then
                        idx  <= 0;
                        b_ph <= 1;
                     else
                        idx <= idx + 1;
                     end if;
                  when 1 | 2 | 3 | 4 =>
                     b_ph <= b_ph + 1;
                  when others =>
                     b_ph <= 0;
                     if buf_bad_i = '1' and r_ok = '1' and h_try < 2 then
                        h_try        <= h_try + 1;
                        pm_req_fresh <= '1';
                        sd_next      <= S_FD_CHK;
                        state        <= S_SD_ASK;
                     else
                        h_try <= 0;
                        state <= S_PUSH;
                     end if;
               end case;

            -- 512 bytes into the FIFO: buffer address, a clock for the RAM, then the write
            when S_PUSH =>
               pm_buf_addr <= std_logic_vector(to_unsigned(idx, 9));
               pm_address <= C_FDD & x"0F";
               case b_ph is
                  when 0 | 1 =>
                     b_ph <= b_ph + 1;
                  when 2 =>
                     if r_ok = '1' then
                        pm_wdata <= x"00" & buf_rd_i;
                     else
                        pm_wdata <= x"0000";
                     end if;
                     pm_write <= '1';
                     b_ph <= 3;
                  when others =>
                     b_ph <= 0;
                     if idx = 511 then
                        idx   <= 0;
                        state <= S_REQ_END;
                     else
                        idx <= idx + 1;
                     end if;
               end case;

            -- 512 bytes out of the FIFO: the head (registered) settles, is sampled, then popped
            when S_POP =>
               pm_address <= C_FDD & x"0F";
               if b_ph = 3 then
                  b_ph  <= 0;
                  state <= S_POP_GOT;
               else
                  b_ph <= b_ph + 1;
               end if;

            when S_POP_GOT =>
               v_byte      := mgmt_readdata_i(7 downto 0);
               pm_buf_addr  <= std_logic_vector(to_unsigned(idx, 9));
               buf_wd_o    <= v_byte;
               buf_we_o    <= '1';
               pm_read <= '1';                  -- pop it
               if idx = 511 then
                  state <= S_POP_DONE;
               else
                  idx   <= idx + 1;
                  state <= S_POP;
               end if;

            when S_POP_DONE =>
               idx <= 0;
               if r_serve = '1' then
                  sd_next <= S_REQ_END;
                  state   <= S_SD_ASK;
               else
                  state <= S_REQ_END;               -- no image: dropped
               end if;

            -- floppy.v drops the request once the FIFO is full (read) or empty (write); then
            -- the next one may come (after its 4000-clock gap at least)
            when S_REQ_END =>
               pm_address <= x"0000";
               if fdd_request_i = "00" then
                  state <= S_IDLE;
               elsif cnt = 4095 then
                  state <= S_IDLE;                   -- (it never stays: a safety net)
               else
                  cnt <= cnt + 1;
               end if;

            ----------------------------------------------------------------------------------
            -- the hard disk: reset (request 110)
            ----------------------------------------------------------------------------------
            when S_IDE_RST1 =>
               tr_we <= '1';
               tr    <= x"40" & b_q(7 downto 0) & x"0000" & x"00000000";
               -- b_q: reg 5 = {cmd, drive/head}: answer for the drive selected (the slave, never
               -- there, reads cylinder FFFFh)
               w_err <= x"00";
               w_blk <= x"00";
               w_sec <= x"01";
               w_cnt <= x"01";
               if b_q(4) = '0' and h_present = '1' then
                  w_cyl <= x"0000";
               else
                  w_cyl <= x"FFFF";
               end if;
               w_dh  <= '1' & b_q(6) & '1' & b_q(4) & "0000";
               w_st  <= x"80";                       -- BSY
               idx   <= 0;
               w_ret <= S_IDE_RST2;
               state <= S_WREGS;

            when S_IDE_RST2 =>
               w_st  <= x"50";                       -- DRDY, DSC: ready
               idx   <= 0;
               w_ret <= S_IDLE;
               state <= S_WREGS;

            ----------------------------------------------------------------------------------
            -- the hard disk: a command (request 100): the task file, then the command
            ----------------------------------------------------------------------------------
            when S_IDE_CMD1 =>
               t_sec  <= b_q(15 downto 8);
               t_cnt  <= b_q(7 downto 0);
               b_addr <= C_IDE & x"02";
               state  <= S_BUS_R;
               ret    <= S_IDE_CMD2;

            when S_IDE_CMD2 =>
               t_cyl  <= b_q;
               b_addr <= C_IDE & x"05";
               state  <= S_BUS_R;
               ret    <= S_IDE_CMD3;

            when S_IDE_CMD3 =>
               t_cmd <= b_q(15 downto 8);
               t_dh  <= b_q(7 downto 0);
               state <= S_IDE_CMD;

            when S_IDE_CMD =>
               tr_we <= '1';
               tr    <= x"10" & t_cmd & t_dh & t_cnt & x"00" & t_cyl & t_sec;
               -- the registers as read, by default
               w_err <= x"00";
               w_blk <= x"00";
               w_sec <= t_sec;
               w_cnt <= t_cnt;
               w_cyl <= t_cyl;
               w_dh  <= t_dh;
               idx   <= 0;
               w_ret <= S_IDLE;
               state <= S_WREGS;
               i_lbam <= t_dh(6);
               if t_dh(6) = '1' then
                  i_lba <= unsigned(std_logic_vector'(t_dh(3 downto 0) & t_cyl & t_sec));
               else
                  i_lba <= unsigned(std_logic_vector'(t_cyl & t_dh(3 downto 0) &
                                                      std_logic_vector(unsigned(t_sec) - 1)));
               end if;
               i_cnt <= unsigned(t_cnt);
               if t_dh(4) = '1' or h_present = '0' then
                  w_err <= x"04";                    -- the slave, or no disk: aborted
                  w_st  <= x"45";
               else
                  case t_cmd is
                     when x"EC" =>                   -- IDENTIFY DEVICE
                        idx   <= 0;
                        b_ph  <= 0;
                        state <= S_IDE_IDENT;
                     when x"20" | x"21" | x"C4" =>   -- READ SECTORS (MULTIPLE)
                        i_wr  <= '0';
                        state <= S_HR_SD;
                     when x"30" | x"31" | x"C5" =>   -- WRITE SECTORS (MULTIPLE): the first block
                        i_wr  <= '1';
                        i_act <= '1';
                        w_blk <= x"01";
                        w_st  <= x"58";              -- DRQ, no interrupt
                     when x"C6" =>                   -- SET MULTIPLE MODE: 0 or 1 sector
                        if unsigned(t_cnt) <= 1 then
                           w_st <= x"54";
                        else
                           w_err <= x"04";
                           w_st  <= x"45";
                        end if;
                     when x"10" | x"11" | x"12" | x"13" | x"14" | x"15" | x"16" | x"17" |
                          x"18" | x"19" | x"1A" | x"1B" | x"1C" | x"1D" | x"1E" | x"1F" =>
                        w_cyl <= x"0000";            -- RECALIBRATE
                        w_st  <= x"54";
                     when x"90" =>                   -- EXECUTE DIAGNOSTIC: passed
                        w_err <= x"01";
                        w_st  <= x"54";
                     when x"E5" =>                   -- CHECK POWER MODE: active
                        w_cnt <= x"FF";
                        w_st  <= x"54";
                     when x"40" | x"41" | x"70" | x"91" | x"E0" | x"E1" | x"E2" | x"E3" |
                          x"E7" | x"EA" | x"EF" =>
                        w_st  <= x"54";              -- verify, seek, parameters, power, cache, features
                     when others =>
                        w_err <= x"04";              -- aborted
                        w_st  <= x"45";
                  end case;
               end if;

            -- IDENTIFY: 256 words into the buffer, then the registers (END: the block is the last)
            when S_IDE_IDENT =>
               pm_address <= C_IDE & x"0F";
               case b_ph is
                  when 0 =>
                     pm_wdata <= ident(idx, h_total);
                     b_ph <= 1;
                  when 1 =>
                     pm_write <= '1';
                     b_ph <= 2;
                  when others =>
                     b_ph <= 0;
                     if idx = 255 then
                        idx   <= 0;
                        w_err <= x"00";
                        w_blk <= x"01";
                        w_sec <= x"00";
                        w_cnt <= x"00";
                        w_cyl <= x"0000";
                        w_dh  <= t_dh(7) & '0' & t_dh(5 downto 4) & "0000";
                        w_st  <= x"5E";
                        w_ret <= S_IDLE;
                        state <= S_WREGS;
                     else
                        idx <= idx + 1;
                     end if;
               end case;

            ----------------------------------------------------------------------------------
            -- the hard disk: reading, one sector per block
            ----------------------------------------------------------------------------------
            when S_HR_SD =>
               pm_req_unit <= "10";
               pm_req_lba  <= "0000" & std_logic_vector(i_lba);
               if i_cnt = 0 then
                  pm_req_cnt <= '1' & x"00";      -- 256
               else
                  pm_req_cnt <= '0' & std_logic_vector(i_cnt);
               end if;
               pm_req_wr   <= '0';
               sd_next       <= S_HR_STREAM;
               b_ph          <= 0;
               state         <= S_SD_ASK;

            -- 256 words: the low byte, the high byte, then the write (zeros if the card failed)
            when S_HR_STREAM =>
               pm_address <= C_IDE & x"0F";
               case b_ph is
                  when 0 =>
                     pm_buf_addr <= std_logic_vector(to_unsigned(2 * idx, 9));
                     b_ph <= 1;
                  when 1 =>
                     pm_buf_addr <= std_logic_vector(to_unsigned(2 * idx + 1, 9));
                     b_ph <= 2;
                  when 2 =>
                     i_lo <= buf_rd_i;
                     b_ph <= 3;
                  when 3 =>
                     if r_ok = '1' then
                        pm_wdata <= buf_rd_i & i_lo;
                     else
                        pm_wdata <= x"0000";
                     end if;
                     pm_write <= '1';
                     b_ph <= 4;
                  when others =>
                     b_ph <= 0;
                     if idx = 255 then
                        idx   <= 0;
                        state <= S_HR_CHK;
                     else
                        idx <= idx + 1;
                     end if;
               end case;

            -- disk_sd's verdict on the copy (two clocks after its last byte): for one that did
            -- not match the ring's checksum the sector comes again, fresh from the card (the
            -- ring's copy of it stays wrong), twice at most; a read pulse at register 0 rewinds
            -- ide.v's buffer pointer for the new copy (the address stays two clocks after it)
            when S_HR_CHK =>
               pm_address <= C_IDE & x"00";
               case b_ph is
                  when 0 | 1 =>
                     b_ph <= b_ph + 1;
                  when 2 =>
                     if buf_bad_i = '1' and r_ok = '1' and h_try < 2 then
                        h_try        <= h_try + 1;
                        pm_req_fresh <= '1';
                        pm_read      <= '1';
                        b_ph         <= 3;
                     else
                        h_try <= 0;
                        b_ph  <= 0;
                        state <= S_HR_REGS;
                     end if;
                  when 3 =>
                     b_ph <= 4;
                  when others =>
                     b_ph    <= 0;
                     sd_next <= S_HR_STREAM;
                     state   <= S_SD_ASK;
               end case;

            -- the registers: the sector just moved, the count left; DRQ + interrupt (+ END)
            when S_HR_REGS =>
               v_l    := i_lba;
               v_left := i_cnt - 1;
               i_lba  <= i_lba + 1;
               i_cnt  <= v_left;
               w_err  <= x"00";
               w_blk  <= x"01";
               w_cnt  <= std_logic_vector(v_left);
               if i_lbam = '1' then
                  w_sec <= std_logic_vector(v_l(7 downto 0));
                  w_cyl <= std_logic_vector(v_l(23 downto 8));
                  w_dh  <= t_dh(7) & '1' & t_dh(5 downto 4) & std_logic_vector(v_l(27 downto 24));
               else
                  w_sec <= std_logic_vector(v_l(7 downto 0) + 1);
                  w_cyl <= std_logic_vector(v_l(27 downto 12));
                  w_dh  <= t_dh(7) & '0' & t_dh(5 downto 4) & std_logic_vector(v_l(11 downto 8));
               end if;
               if v_left = 0 then
                  w_st  <= x"5E";                    -- the last block: ide.v ends with 40h
                  i_act <= '0';
               else
                  w_st  <= x"5C";
                  i_act <= '1';
               end if;
               idx   <= 0;
               w_ret <= S_IDLE;
               state <= S_WREGS;

            ----------------------------------------------------------------------------------
            -- the hard disk: request 101, the CPU has a block: the next read, or this write
            ----------------------------------------------------------------------------------
            when S_IDE_BLK =>
               tr_we <= '1';
               tr    <= x"30" & "000000" & i_wr & i_act & x"00" & std_logic_vector(i_cnt) &
                        "0000" & std_logic_vector(i_lba);
               if i_act = '0' then
                  w_err <= x"04";                    -- nothing was going on: aborted
                  w_blk <= x"00";
                  w_sec <= t_sec;
                  w_cnt <= t_cnt;
                  w_cyl <= t_cyl;
                  w_dh  <= t_dh;
                  w_st  <= x"45";
                  idx   <= 0;
                  w_ret <= S_IDLE;
                  state <= S_WREGS;
               elsif i_wr = '0' then
                  state <= S_HR_SD;
               else
                  idx   <= 0;
                  b_ph  <= 0;
                  state <= S_HW_POP;
               end if;

            -- 256 words out of ide.v's buffer (sampled, then the read pulse), into the sector
            when S_HW_POP =>
               pm_address <= C_IDE & x"0F";
               case b_ph is
                  when 0 | 1 | 2 =>
                     b_ph <= b_ph + 1;
                  when 3 =>
                     i_lo        <= mgmt_readdata_i(15 downto 8);
                     pm_buf_addr  <= std_logic_vector(to_unsigned(2 * idx, 9));
                     buf_wd_o    <= mgmt_readdata_i(7 downto 0);
                     buf_we_o    <= '1';
                     pm_read <= '1';
                     b_ph <= 4;
                  when others =>
                     pm_buf_addr <= std_logic_vector(to_unsigned(2 * idx + 1, 9));
                     buf_wd_o   <= i_lo;
                     buf_we_o   <= '1';
                     b_ph <= 0;
                     if idx = 255 then
                        idx   <= 0;
                        state <= S_HW_SD;
                     else
                        idx <= idx + 1;
                     end if;
               end case;

            -- the sectors this command still writes, this one included (disk_sd's write run)
            when S_HW_SD =>
               pm_address <= C_IDE & x"0F";
               pm_req_unit  <= "10";
               pm_req_lba   <= "0000" & std_logic_vector(i_lba);
               if i_cnt = 0 then
                  pm_req_cnt <= '1' & x"00";      -- 256
               else
                  pm_req_cnt <= '0' & std_logic_vector(i_cnt);
               end if;
               pm_req_wr    <= '1';
               sd_next        <= S_HW_DONE;
               state          <= S_SD_ASK;

            -- written: the sector just stored, the count left; the next block or done
            when S_HW_DONE =>
               v_l    := i_lba;
               v_left := i_cnt - 1;
               i_lba  <= i_lba + 1;
               i_cnt  <= v_left;
               w_err  <= x"00";
               w_blk  <= x"01";
               w_cnt  <= std_logic_vector(v_left);
               if i_lbam = '1' then
                  w_sec <= std_logic_vector(v_l(7 downto 0));
                  w_cyl <= std_logic_vector(v_l(23 downto 8));
                  w_dh  <= t_dh(7) & '1' & t_dh(5 downto 4) & std_logic_vector(v_l(27 downto 24));
               else
                  w_sec <= std_logic_vector(v_l(7 downto 0) + 1);
                  w_cyl <= std_logic_vector(v_l(27 downto 12));
                  w_dh  <= t_dh(7) & '0' & t_dh(5 downto 4) & std_logic_vector(v_l(11 downto 8));
               end if;
               if v_left = 0 then
                  w_st  <= x"54";                    -- done, interrupt
                  i_act <= '0';
               else
                  w_st  <= x"5C";                    -- the next block: DRQ, interrupt
                  i_act <= '1';
               end if;
               idx   <= 0;
               w_ret <= S_IDLE;
               state <= S_WREGS;

            when others =>
               state <= S_IDLE;

         end case;

         if state = S_IDLE then
            cnt <= 0;
         end if;

         if rtc_sync_i = '1' then
            rtc_now <= '1';
         end if;

         if rst_i = '1' then
            state     <= S_START;
            b_ph      <= 0;
            idx       <= 0;
            a_mounted <= "00";
            a_gen     <= (others => (others => '0'));
            h_present <= '0';
            h_gen     <= (others => '0');
            i_act     <= '0';
            rtc_again <= '1';
         end if;
      end if;
   end process p_mgmt;

end architecture synthesis;

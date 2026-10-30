----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The PC's management bus: what MiSTer's ARM side (Main_MiSTer, support/x86/x86.cpp) does
-- through hps_ext, in hardware. z486_MiSTer's system.sv decodes the bus by page: F2xx the floppy
-- controller (floppy.v), F4xx the RTC's CMOS (rtc.v), F0xx/F1xx the IDE channels (not yet).
--
--   * At power-up, while the PC is still held in reset: the CMOS configuration (x86_init:
--     floppy types 1.44 MB, equipment, 640 KB base memory, century, LBA translation and the
--     checksum of 10h-2Dh; rtc.v corrects 2Eh/2Fh for the bytes it fills in itself), the date and
--     time from the MEGA65's RTC (again once the RTC has been read, rtc_i(64) toggles), and both
--     floppy drives empty with 1.44 MB geometry (fdd_set).
--   * Drive A: as fdd_sd.vhd mounted it: every change ejects first (register 0 = 0, then
--     100 ms: the change line the PC reads at 3F7h), then the geometry and the media.
--   * The floppy's sector requests (fdd_request_i, a level): read register 0 (bit 15 drive,
--     14..0 LBA); a read gets the sector from fdd_sd and pushes its 512 bytes into register F, a
--     write or a format pops 512 bytes from register F and hands them to fdd_sd. A sector of
--     drive B:, of a drive without an image, or one that cannot be read is 512 zeros, as on
--     MiSTer: floppy.v waits for exactly 512 bytes either way.
--
-- Bus timing (floppy.v and ide.v): mgmt_read_o / mgmt_write_o are one-clock pulses (floppy.v
-- pushes or pops one byte per clock they are high), the address stays one clock after each
-- pulse, read data is sampled three clocks after the address is set. Register F's read data is
-- the FIFO's head, registered: sampled first, then popped.
--
-- The fdd_sd.vhd side runs on the QNICE clock: its mount data crosses with cdc_stable (it
-- changes only with fdd_mnt_gen_i, which comes last), the sector requests as a toggle with a
-- payload that is stable while it crosses, the answers likewise (CORE.xdc bounds qnice <-> main).
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

      rtc_i             : in  std_logic_vector(64 downto 0); -- the framework's (BCD)

      -- drive A: as fdd_sd mounted it (QNICE clock)
      fdd_mounted_i     : in  std_logic;
      fdd_wp_i          : in  std_logic;
      fdd_cyl_i         : in  std_logic_vector(7 downto 0);
      fdd_spt_i         : in  std_logic_vector(7 downto 0);
      fdd_total_i       : in  std_logic_vector(15 downto 0);
      fdd_heads_i       : in  std_logic_vector(1 downto 0);
      fdd_gen_i         : in  std_logic_vector(3 downto 0);  -- moves with every mount change

      -- sector requests to fdd_sd (a toggle; wr and lba stable from one clock before it) and
      -- its answers (QNICE clock: a toggle, err stable with it)
      sd_req_o          : out std_logic;
      sd_req_wr_o       : out std_logic := '0';
      sd_req_lba_o      : out std_logic_vector(15 downto 0) := (others => '0');
      sd_done_i         : in  std_logic;
      sd_err_i          : in  std_logic;

      -- the sector buffer (fdd_sd's block RAM, its clk_i port; read data one clock later)
      buf_addr_o        : out std_logic_vector(8 downto 0) := (others => '0');
      buf_we_o          : out std_logic := '0';
      buf_wd_o          : out std_logic_vector(7 downto 0) := (others => '0');
      buf_rd_i          : in  std_logic_vector(7 downto 0)
   );
end entity pc_mgmt;

architecture synthesis of pc_mgmt is

   -- The CMOS at power-up (x86_init): 10h-2Dh, then 2Eh/2Fh = their 16-bit sum
   type t_cmos is array (16#10# to 16#2D#) of natural range 0 to 255;
   constant C_CMOS : t_cmos := (
      16#10# => 16#44#,             -- drives A: and B: 1.44 MB
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
      (16#2E#, cmos_sum / 256), (16#2F#, cmos_sum mod 256),
      (16#32#, 16#20#),             -- century (BCD)
      (16#37#, 16#20#),             -- century (PS/2)
      (16#39#, 16#55#));            -- LBA translation for the hard disks

   -- The floppy registers, drive d at F2xx + d * 80h: 0 media, 1 write protect, 2 cylinders,
   -- 3 sectors per track, 4 sectors, 5 heads, F the FIFO
   constant C_FDD     : std_logic_vector(7 downto 0) := x"F2";
   constant C_CMOS_PG : std_logic_vector(7 downto 0) := x"F4";

   constant C_EJECT_WAIT : natural := G_CLK_HZ / 10;          -- 100 ms

   type t_state is (
      S_START,
      S_CMOS, S_CMOS_MORE, S_TIME, S_FD_INIT,
      S_IDLE,
      S_MNT_EJECT, S_MNT_WAIT, S_MNT_GEO,
      S_REQ, S_REQ_GOT,
      S_SD_ASK, S_SD_WAIT,
      S_PUSH, S_POP, S_POP_GOT, S_POP_DONE,
      S_REQ_END,
      S_BUS_W, S_BUS_R
   );
   signal state       : t_state := S_START;
   signal ret         : t_state := S_START;      -- after S_BUS_W / S_BUS_R

   -- one bus access: S_BUS_W writes b_data to b_addr, S_BUS_R reads b_addr into b_q
   signal b_addr      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_data      : std_logic_vector(15 downto 0) := (others => '0');
   signal b_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal b_ph        : natural range 0 to 3 := 0;

   signal idx         : natural range 0 to 511 := 0;
   signal cnt         : natural range 0 to C_EJECT_WAIT := 0;

   -- drive A: as fdd_sd has it (crossed) and as floppy.v has it
   signal m_src       : std_logic_vector(39 downto 0);
   signal m_dst       : std_logic_vector(39 downto 0);
   signal m_mounted   : std_logic;
   signal m_wp        : std_logic;
   signal m_cyl       : std_logic_vector(7 downto 0);
   signal m_spt       : std_logic_vector(7 downto 0);
   signal m_total     : std_logic_vector(15 downto 0);
   signal m_heads     : std_logic_vector(1 downto 0);
   signal m_gen       : std_logic_vector(3 downto 0);
   signal a_mounted   : std_logic := '0';
   signal a_gen       : std_logic_vector(3 downto 0) := (others => '0');

   -- the time again once the RTC has been read
   signal rtc_tgl     : std_logic := '0';
   signal rtc_again   : std_logic := '1';

   -- the request being served
   signal r_wr        : std_logic := '0';
   signal r_serve     : std_logic := '0';       -- '1': drive A: with an image
   signal r_ok        : std_logic := '0';       -- '1': the sector came from the card

   signal req         : std_logic := '0';
   signal done_s      : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of done_s : signal is "true";

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

   m_src <= fdd_mounted_i & fdd_wp_i & fdd_cyl_i & fdd_spt_i & fdd_total_i & fdd_heads_i &
            fdd_gen_i;

   i_cdc_mount : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 40
      )
      port map (
         src_data_i => m_src,
         dst_clk_i  => clk_i,
         dst_data_o => m_dst
      ); -- i_cdc_mount

   m_mounted <= m_dst(39);
   m_wp      <= m_dst(38);
   m_cyl     <= m_dst(37 downto 30);
   m_spt     <= m_dst(29 downto 22);
   m_total   <= m_dst(21 downto 6);
   m_heads   <= m_dst(5 downto 4);
   m_gen     <= m_dst(3 downto 0);

   sd_req_o <= req;

   p_mgmt : process (clk_i)
      variable v_byte : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         mgmt_read_o  <= '0';
         mgmt_write_o <= '0';
         buf_we_o     <= '0';
         done_s       <= done_s(1 downto 0) & sd_done_i;

         case state is

            ----------------------------------------------------------------------------------
            -- one bus access, then back to ret
            ----------------------------------------------------------------------------------
            when S_BUS_W =>
               -- 0: address and data out, 1: the write pulse, 2/3: the address stays
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
               -- 0: address out, 3: the data has settled
               mgmt_address_o <= b_addr;
               if b_ph = 3 then
                  b_q   <= mgmt_readdata_i;
                  b_ph  <= 0;
                  state <= ret;
               else
                  b_ph <= b_ph + 1;
               end if;

            ----------------------------------------------------------------------------------
            -- power-up: CMOS, time, both drives empty
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
                  idx <= 0;
                  ret <= S_TIME;
               else
                  idx <= idx + 1;
                  ret <= S_CMOS_MORE;
               end if;

            -- 00h seconds, 02h minutes, 04h hours, 06h day of week, 07h day, 08h month, 09h year
            when S_TIME =>
               b_data(15 downto 8) <= x"00";
               case idx is
                  when 0 => b_addr <= C_CMOS_PG & x"00"; b_data(7 downto 0) <= rtc_i(7 downto 0);
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
                  ret <= S_FD_INIT;
               else
                  idx <= idx + 1;
                  ret <= S_TIME;
               end if;

            -- both drives: no media, writable, 80 cylinders, 18 sectors, 2880 sectors, 2 heads
            -- (idx: bit 3 = the drive, bits 2..0 = the register)
            when S_FD_INIT =>
               state <= S_BUS_W;
               ret   <= S_FD_INIT;
               b_addr <= C_FDD & std_logic_vector(to_unsigned((idx / 8) * 128 + idx mod 8, 8));
               case idx mod 8 is
                  when 0      => b_data <= x"0000";
                  when 1      => b_data <= x"0001";      -- write protected: no image
                  when 2      => b_data <= x"0050";
                  when 3      => b_data <= x"0012";
                  when 4      => b_data <= x"0B40";
                  when others => b_data <= x"0002";
               end case;
               if idx = 13 then
                  idx <= 0;
                  ret <= S_IDLE;
               elsif idx mod 8 = 5 then
                  idx <= idx + 3;
               else
                  idx <= idx + 1;
               end if;

            ----------------------------------------------------------------------------------
            -- idle: a mount change, the RTC, a sector request
            ----------------------------------------------------------------------------------
            when S_IDLE =>
               mgmt_address_o <= x"0000";
               if m_gen /= a_gen or m_mounted /= a_mounted then
                  a_gen     <= m_gen;
                  a_mounted <= m_mounted;
                  b_addr    <= C_FDD & x"00";      -- out first
                  b_data    <= x"0000";
                  state     <= S_BUS_W;
                  if m_mounted = '1' then
                     cnt <= 0;
                     ret <= S_MNT_WAIT;
                  else
                     ret <= S_IDLE;
                  end if;
               elsif rtc_again = '1' and rtc_i(64) /= rtc_tgl then
                  rtc_again <= '0';
                  idx       <= 0;
                  ret       <= S_IDLE;
                  state     <= S_TIME;
               elsif fdd_request_i /= "00" then
                  r_wr   <= fdd_request_i(1);
                  b_addr <= C_FDD & x"00";
                  state  <= S_BUS_R;
                  ret    <= S_REQ_GOT;
               end if;

            ----------------------------------------------------------------------------------
            -- drive A: gets its image: 100 ms without media, then the geometry and the media
            ----------------------------------------------------------------------------------
            when S_MNT_WAIT =>
               if cnt = C_EJECT_WAIT then
                  idx   <= 1;
                  state <= S_MNT_GEO;
               else
                  cnt <= cnt + 1;
               end if;

            when S_MNT_GEO =>
               b_addr <= C_FDD & std_logic_vector(to_unsigned(idx, 8));
               case idx is
                  when 1      => b_data <= x"000" & "000" & m_wp;
                  when 2      => b_data <= x"00" & m_cyl;
                  when 3      => b_data <= x"00" & m_spt;
                  when 4      => b_data <= m_total;
                  when 5      => b_data <= x"000" & "00" & m_heads;
                  when others => b_data <= x"0001";      -- 0: media present, last
               end case;
               state <= S_BUS_W;
               if idx = 0 then
                  ret <= S_IDLE;
               elsif idx = 5 then
                  idx <= 0;
                  ret <= S_MNT_GEO;
               else
                  idx <= idx + 1;
                  ret <= S_MNT_GEO;
               end if;

            ----------------------------------------------------------------------------------
            -- a sector request
            ----------------------------------------------------------------------------------
            when S_REQ_GOT =>
               -- b_q: bit 15 = drive B:, 14..0 = the LBA
               sd_req_lba_o <= '0' & b_q(14 downto 0);
               sd_req_wr_o  <= r_wr;
               r_ok         <= '0';
               idx          <= 0;
               if b_q(15) = '0' and a_mounted = '1' then
                  r_serve <= '1';
               else
                  r_serve <= '0';
               end if;
               if r_wr = '1' then
                  state <= S_POP;                    -- the PC's bytes first
               elsif b_q(15) = '0' and a_mounted = '1' then
                  state <= S_SD_ASK;
               else
                  state <= S_PUSH;                   -- zeros
               end if;

            when S_SD_ASK =>
               req   <= not req;                     -- wr and lba were set a clock ago
               state <= S_SD_WAIT;

            when S_SD_WAIT =>
               if done_s(2) /= done_s(1) then
                  r_ok <= not sd_err_i;
                  idx  <= 0;
                  if r_wr = '1' then
                     state <= S_REQ_END;
                  else
                     state <= S_PUSH;
                  end if;
               end if;

            -- 512 bytes into the FIFO: buffer address, a clock for the RAM, then the write
            when S_PUSH =>
               buf_addr_o <= std_logic_vector(to_unsigned(idx, 9));
               mgmt_address_o <= C_FDD & x"0F";
               case b_ph is
                  when 0 | 1 =>
                     b_ph <= b_ph + 1;
                  when 2 =>
                     if r_ok = '1' then
                        mgmt_writedata_o <= x"00" & buf_rd_i;
                     else
                        mgmt_writedata_o <= x"0000";
                     end if;
                     mgmt_write_o <= '1';
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
               mgmt_address_o <= C_FDD & x"0F";
               if b_ph = 3 then
                  b_ph  <= 0;
                  state <= S_POP_GOT;
               else
                  b_ph <= b_ph + 1;
               end if;

            when S_POP_GOT =>
               v_byte     := mgmt_readdata_i(7 downto 0);
               buf_addr_o <= std_logic_vector(to_unsigned(idx, 9));
               buf_wd_o   <= v_byte;
               buf_we_o   <= '1';
               mgmt_read_o <= '1';                  -- pop it
               if idx = 511 then
                  state <= S_POP_DONE;
               else
                  idx   <= idx + 1;
                  state <= S_POP;
               end if;

            when S_POP_DONE =>
               idx <= 0;
               if r_serve = '1' then
                  state <= S_SD_ASK;
               else
                  state <= S_REQ_END;               -- drive B: or no image: dropped
               end if;

            -- floppy.v drops the request once the FIFO is full (read) or empty (write); then
            -- the next one may come (after its 4000-clock gap at least)
            when S_REQ_END =>
               mgmt_address_o <= x"0000";
               if fdd_request_i = "00" then
                  state <= S_IDLE;
               elsif cnt = 4095 then
                  state <= S_IDLE;                   -- (it never stays: a safety net)
               else
                  cnt <= cnt + 1;
               end if;

            when others =>
               state <= S_IDLE;

         end case;

         if state = S_IDLE then
            cnt <= 0;
         end if;
         if state = S_TIME and idx = 0 then
            rtc_tgl <= rtc_i(64);
         end if;

         if rst_i = '1' then
            state     <= S_START;
            b_ph      <= 0;
            idx       <= 0;
            a_mounted <= '0';
            a_gen     <= (others => '0');
            rtc_again <= '1';
         end if;
      end if;
   end process p_mgmt;

end architecture synthesis;

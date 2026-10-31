----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The PC's disks straight from image files on the SD card: floppy drives A: and B: (units 0
-- and 1) and the hard disk (unit 2), one 512-byte sector at a time through the SD host
-- controller's engine port, for pc_mgmt.vhd, which serves floppy.v and ide.v. After Megamiga's
-- adf_sd.vhd and Megamac's ide_engine.vhd (the same extent map and lookup), without their track
-- buffer: the PC's controllers ask for one sector and wait for it anyway.
--
--   * The firmware (m2m-rom.asm, DISK_PREP) writes a file's extent map (FAT32$FILE_MAP format:
--     word 0 = extents, then per extent first cluster lo/hi, clusters lo/hi; up to 511) into
--     window 1, then the drive's registers below, MODE last.
--   * A request from pc_mgmt (a toggle; unit, wr and lba stable while it crosses) is looked up
--     in the unit's map: cluster index = lba >> SHIFT, SD block = BASE + (cluster << SHIFT) +
--     the rest.
--     The block moves between the card and the sector buffer (a true dual-port block RAM, one
--     port per clock domain), then the answer goes back (a toggle, err stable with it).
--   * A failed transfer is tried again twice, 1 ms apart; a controller that is not ready
--     counts as a failure. A transfer that QNICE's own SD access ended early (no block moved)
--     starts again. A sector that cannot be read (no image, outside the file, SD error) comes
--     back with err set: pc_mgmt then gives the PC zeros. A write to a write-protected image
--     is dropped (floppy.v already refused it: the write protect is in its register 1).
--
-- QNICE registers (device C_DEV_PC_DISK, window 0; written on the falling edge), unit u at
-- 0x20 * u (A: 0x00, B: 0x20, the hard disk 0x40):
--   0x00 MODE    bit 0 = an image is mounted, bit 1 = it is on the card in slot 1, bit 2 =
--                write protected. Every write counts the drive's mount generation, which
--                pc_mgmt watches.
--   0x01/0x02    SECTS  sectors of the file (lo, hi)
--   0x03/0x04    BASE   SD block of cluster 0 = DEV_CLUSTER - (2 << SHIFT) (lo, hi)
--   0x05 SHIFT   log2(sectors per cluster)
--   0x06 CYL     cylinders, 0x07 SPT sectors per track, 0x08 HEADS (floppies only, for floppy.v)
--   0x10..0x15   (read, all units) sectors read, sectors written, failed requests, the last
--                request (bit 15 = write, 14..13 = unit), its LBA (lo, hi)
--   0x16..0x1E   (read) the requests' times in microseconds, from the request's arrival to its
--                answer: reads' sum (lo, hi), the slowest read, writes' sum (lo, hi), the
--                slowest write, the last request's; then the transfers tried again after an
--                error and the ones that QNICE's own SD access interrupted
--   0x10         (write) clears 0x10..0x1E (any value)
-- Windows 1 and 2: the extent maps, unit u at map word 2048 * u (A: window 1 from 0, B: window
-- 1 from 2048, the hard disk: window 2 from 0). Window 0xFFFF: M2M's CSR (qnice_csr.vhd), one per
-- unit (qnice_unit_i: the device the Shell selected), which the Shell's manual load talks to and
-- reads back to tell whether the unit's menu line is loaded: it answers READY at once (the Shell
-- streams nothing: DISK_PREP moved the file handle to its end). The other windows are the same
-- for every unit.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;
use work.qnice_csr_pkg.all;

entity disk_sd is
   generic (
      G_QNICE_HZ   : natural := 50_000_000
   );
   port (
      qnice_clk_i  : in  std_logic;
      qnice_rst_i  : in  std_logic;
      qnice_addr_i : in  std_logic_vector(27 downto 0);
      qnice_data_i : in  std_logic_vector(15 downto 0);
      qnice_ce_i   : in  std_logic;               -- this device is selected
      qnice_unit_i : in  std_logic_vector(1 downto 0);  -- through which unit's device (the CSR)
      qnice_we_i   : in  std_logic;
      qnice_data_o : out std_logic_vector(15 downto 0);
      qnice_wait_o : out std_logic;

      -- the SD host controller's engine port (QNICE clock)
      sd_q2c_i     : in  t_sd_q2c;
      sd_c2q_o     : out t_sd_c2q;

      -- the units for pc_mgmt (QNICE clock), unit u at bits 40 * u + 39 .. 40 * u: floppies:
      -- mounted, write protected, cylinders (8), sectors per track (8), sectors (16), heads (2),
      -- the mount generation (4), which moves last; the hard disk: mounted, write protected,
      -- sectors (32), 00, the mount generation (4)
      mnt_o         : out std_logic_vector(119 downto 0);

      -- sector requests from pc_mgmt (main clock) and the answers (QNICE clock)
      req_i        : in  std_logic;                -- a toggle
      req_wr_i     : in  std_logic;
      req_unit_i   : in  std_logic_vector(1 downto 0);
      req_lba_i    : in  std_logic_vector(31 downto 0);
      done_o       : out std_logic;                -- a toggle
      done_err_o   : out std_logic;

      -- the sector buffer's other port (pc_mgmt's clock; read data one clock later)
      main_clk_i   : in  std_logic;
      buf_addr_i   : in  std_logic_vector(8 downto 0);
      buf_we_i     : in  std_logic;
      buf_wd_i     : in  std_logic_vector(7 downto 0);
      buf_rd_o     : out std_logic_vector(7 downto 0)
   );
end entity disk_sd;

architecture synthesis of disk_sd is

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (others => "OK                   ");
   constant C_RETRY_WAIT    : natural := G_QNICE_HZ / 1000;     -- 1 ms
   constant C_TRIES         : natural := 3;

   -- registers, one set per unit
   constant C_UNITS : natural := 3;
   type t_mode  is array (0 to C_UNITS - 1) of std_logic_vector(2 downto 0);
   type t_u32   is array (0 to C_UNITS - 1) of unsigned(31 downto 0);
   type t_shift is array (0 to C_UNITS - 1) of natural range 0 to 15;
   type t_b8    is array (0 to C_UNITS - 1) of std_logic_vector(7 downto 0);
   type t_b2    is array (0 to C_UNITS - 1) of std_logic_vector(1 downto 0);
   type t_gen   is array (0 to C_UNITS - 1) of unsigned(3 downto 0);
   signal mode      : t_mode  := (others => (others => '0'));
   signal sects     : t_u32   := (others => (others => '0'));
   signal base      : t_u32   := (others => (others => '0'));
   signal shift     : t_shift := (others => 0);
   signal cyl       : t_b8    := (others => x"50");
   signal spt       : t_b8    := (others => x"12");
   signal heads     : t_b2    := (others => "10");
   signal gen       : t_gen   := (others => (others => '0'));
   signal st_rd     : unsigned(15 downto 0) := (others => '0');
   signal st_wr     : unsigned(15 downto 0) := (others => '0');
   signal st_err    : unsigned(15 downto 0) := (others => '0');
   signal st_last   : std_logic_vector(15 downto 0) := (others => '0');
   signal st_lba    : std_logic_vector(31 downto 0) := (others => '0');
   signal st_rd_t   : unsigned(31 downto 0) := (others => '0');   -- microseconds
   signal st_rd_max : unsigned(15 downto 0) := (others => '0');
   signal st_wr_t   : unsigned(31 downto 0) := (others => '0');
   signal st_wr_max : unsigned(15 downto 0) := (others => '0');
   signal st_t      : unsigned(15 downto 0) := (others => '0');   -- the last request's
   signal st_retry  : unsigned(15 downto 0) := (others => '0');
   signal st_again  : unsigned(15 downto 0) := (others => '0');
   signal st_clr_f  : std_logic := '0';                           -- a toggle (falling edge)
   signal st_clr_r  : std_logic := '0';
   constant C_US    : natural := G_QNICE_HZ / 1_000_000;
   signal us_div    : natural range 0 to C_US - 1 := 0;
   signal x_t       : unsigned(15 downto 0) := (others => '0');   -- this request's, saturating

   -- the extent map: written on the falling edge, into the RAM on the next rising edge
   type t_map is array (0 to 8191) of std_logic_vector(15 downto 0);
   signal map_ram   : t_map := (others => (others => '0'));
   signal map_we_f  : std_logic := '0';
   signal map_wa_f  : std_logic_vector(12 downto 0) := (others => '0');
   signal map_wd_f  : std_logic_vector(15 downto 0) := (others => '0');
   signal maddr     : unsigned(10 downto 0) := (others => '0');   -- within the drive's map
   signal map_q     : std_logic_vector(15 downto 0) := (others => '0');

   -- the CSRs (window 0xFFFF), one per unit
   type t_csr16 is array (0 to C_UNITS - 1) of std_logic_vector(15 downto 0);
   type t_csr4  is array (0 to C_UNITS - 1) of std_logic_vector(3 downto 0);
   signal csr_ce     : std_logic_vector(C_UNITS - 1 downto 0);
   signal csr_data_u : t_csr16;
   signal csr_wait_u : std_logic_vector(C_UNITS - 1 downto 0);
   signal csr_sel_u  : std_logic_vector(C_UNITS - 1 downto 0);
   signal req_status : t_csr4;
   signal resp_status : t_csr4;
   signal csr_data   : std_logic_vector(15 downto 0);
   signal csr_wait   : std_logic;
   signal csr_sel    : std_logic;
   signal q_win0     : std_logic;
   signal q_map      : std_logic;

   -- the request
   type t_state is (F_IDLE, F_CHECK, F_LOOK_N, F_LOOK_EXT, F_LOOK_CMP, F_CALC, F_START, F_RUN,
                    F_RETRY, F_FAIL, F_DONE);
   signal st        : t_state := F_IDLE;
   signal req_s     : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of req_s : signal is "true";
   signal x_wr      : std_logic := '0';
   signal x_drv     : natural range 0 to C_UNITS - 1 := 0;
   signal x_shift   : natural range 0 to 15 := 0;
   signal x_lba     : unsigned(31 downto 0) := (others => '0');
   signal ph        : natural range 0 to 7 := 0;
   signal ci        : unsigned(31 downto 0) := (others => '0');
   signal cum       : unsigned(31 downto 0) := (others => '0');
   signal ext_i     : unsigned(9 downto 0) := (others => '0');
   signal ext_n     : unsigned(15 downto 0) := (others => '0');
   signal e_first   : unsigned(31 downto 0) := (others => '0');
   signal e_len     : unsigned(31 downto 0) := (others => '0');
   signal p_clus    : unsigned(31 downto 0) := (others => '0');
   signal run_blk   : unsigned(31 downto 0) := (others => '0');
   signal moved     : std_logic := '0';
   signal tries     : natural range 0 to C_TRIES := 0;
   signal wait_cnt  : natural range 0 to C_RETRY_WAIT := 0;
   signal done      : std_logic := '0';
   signal done_err  : std_logic := '0';

   -- the engine port
   signal sd_start  : std_logic := '0';
   signal sd_ready  : std_logic;
   signal sd_busy   : std_logic;
   signal sd_done   : std_logic;
   signal sd_error  : std_logic;
   signal sd_blk    : std_logic;
   signal sd_rdwe   : std_logic;

   -- the sector buffer, QNICE side
   signal buf_a_addr : std_logic_vector(8 downto 0);
   signal buf_a_we   : std_logic;
   signal buf_a_q    : std_logic_vector(7 downto 0);

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE: registers, map, CSR
   ---------------------------------------------------------------------------------------------

   q_win0 <= '1' when qnice_addr_i(27 downto 12) = x"0000" else '0';
   q_map  <= '1' when qnice_addr_i(27 downto 12) = x"0001" or qnice_addr_i(27 downto 12) = x"0002" else '0';

   p_qnice_write : process (qnice_clk_i)
      variable v_d : natural range 0 to 3;
   begin
      if falling_edge(qnice_clk_i) then
         map_we_f <= '0';
         v_d := to_integer(unsigned(qnice_addr_i(6 downto 5)));
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if q_map = '1' then
               map_we_f <= '1';
               map_wa_f <= qnice_addr_i(13) & qnice_addr_i(11 downto 0);   -- window 1: 0.., 2: 4096..
               map_wd_f <= qnice_data_i;
            elsif q_win0 = '1' and qnice_addr_i(11 downto 0) = x"010" then
               st_clr_f <= not st_clr_f;
            elsif q_win0 = '1' and qnice_addr_i(7) = '0' and qnice_addr_i(4) = '0' and v_d < C_UNITS then
               case to_integer(unsigned(qnice_addr_i(3 downto 0))) is
                  when 16#0# =>
                     mode(v_d) <= qnice_data_i(2 downto 0);
                     gen(v_d)  <= gen(v_d) + 1;
                  when 16#1# => sects(v_d)(15 downto 0)  <= unsigned(qnice_data_i);
                  when 16#2# => sects(v_d)(31 downto 16) <= unsigned(qnice_data_i);
                  when 16#3# => base(v_d)(15 downto 0)   <= unsigned(qnice_data_i);
                  when 16#4# => base(v_d)(31 downto 16)  <= unsigned(qnice_data_i);
                  when 16#5# => shift(v_d) <= to_integer(unsigned(qnice_data_i(3 downto 0)));
                  when 16#6# => cyl(v_d)   <= qnice_data_i(7 downto 0);
                  when 16#7# => spt(v_d)   <= qnice_data_i(7 downto 0);
                  when 16#8# => heads(v_d) <= qnice_data_i(1 downto 0);
                  when others => null;
               end case;
            end if;
         end if;
         if qnice_rst_i = '1' then
            for d in 0 to C_UNITS - 1 loop
               mode(d) <= (others => '0');
               gen(d)  <= gen(d) + 1;
            end loop;
         end if;
      end if;
   end process p_qnice_write;

   p_qnice_read : process (all)
      variable v_d : natural range 0 to 3;
   begin
      v_d := to_integer(unsigned(qnice_addr_i(6 downto 5)));
      qnice_data_o <= x"0000";
      if csr_sel = '1' then
         qnice_data_o <= csr_data;
      elsif q_win0 = '1' and qnice_addr_i(27 downto 7) = "000000000000000000000" then
         if qnice_addr_i(4) = '1' then
            case to_integer(unsigned(qnice_addr_i(3 downto 0))) is
               when 0      => qnice_data_o <= std_logic_vector(st_rd);
               when 1      => qnice_data_o <= std_logic_vector(st_wr);
               when 2      => qnice_data_o <= std_logic_vector(st_err);
               when 3      => qnice_data_o <= st_last;
               when 4      => qnice_data_o <= st_lba(15 downto 0);
               when 5      => qnice_data_o <= st_lba(31 downto 16);
               when 6      => qnice_data_o <= std_logic_vector(st_rd_t(15 downto 0));
               when 7      => qnice_data_o <= std_logic_vector(st_rd_t(31 downto 16));
               when 8      => qnice_data_o <= std_logic_vector(st_rd_max);
               when 9      => qnice_data_o <= std_logic_vector(st_wr_t(15 downto 0));
               when 10     => qnice_data_o <= std_logic_vector(st_wr_t(31 downto 16));
               when 11     => qnice_data_o <= std_logic_vector(st_wr_max);
               when 12     => qnice_data_o <= std_logic_vector(st_t);
               when 13     => qnice_data_o <= std_logic_vector(st_retry);
               when 14     => qnice_data_o <= std_logic_vector(st_again);
               when others => null;
            end case;
         elsif v_d < C_UNITS then
            case to_integer(unsigned(qnice_addr_i(3 downto 0))) is
               when 0      => qnice_data_o <= "0000000000000" & mode(v_d);
               when 1      => qnice_data_o <= std_logic_vector(sects(v_d)(15 downto 0));
               when 2      => qnice_data_o <= std_logic_vector(sects(v_d)(31 downto 16));
               when 3      => qnice_data_o <= std_logic_vector(base(v_d)(15 downto 0));
               when 4      => qnice_data_o <= std_logic_vector(base(v_d)(31 downto 16));
               when 5      => qnice_data_o <= std_logic_vector(to_unsigned(shift(v_d), 16));
               when 6      => qnice_data_o <= x"00" & cyl(v_d);
               when 7      => qnice_data_o <= x"00" & spt(v_d);
               when 8      => qnice_data_o <= "00000000000000" & heads(v_d);
               when others => null;
            end case;
         end if;
      end if;
   end process p_qnice_read;

   qnice_wait_o <= csr_wait when csr_sel = '1' else '0';

   g_csr : for u in 0 to C_UNITS - 1 generate
      csr_ce(u) <= qnice_ce_i when to_integer(unsigned(qnice_unit_i)) = u else '0';

      i_qnice_csr : entity work.qnice_csr
         generic map (
            G_ERROR_STRINGS => C_ERROR_STRINGS
         )
         port map (
            qnice_clk_i          => qnice_clk_i,
            qnice_rst_i          => qnice_rst_i,
            qnice_addr_i         => qnice_addr_i,
            qnice_data_i         => qnice_data_i,
            qnice_ce_i           => csr_ce(u),
            qnice_we_i           => qnice_we_i,
            qnice_data_o         => csr_data_u(u),
            qnice_wait_o         => csr_wait_u(u),
            qnice_csr_o          => csr_sel_u(u),
            qnice_req_status_o   => req_status(u),
            qnice_req_length_o   => open,
            qnice_resp_status_i  => resp_status(u),
            qnice_resp_error_i   => x"0",
            qnice_resp_address_i => (others => '0')
         ); -- i_qnice_csr

      resp_status(u) <= C_CSR_RESP_READY when req_status(u) = C_CSR_REQ_OK else C_CSR_RESP_IDLE;
   end generate g_csr;

   csr_sel  <= csr_sel_u(to_integer(unsigned(qnice_unit_i))) when unsigned(qnice_unit_i) < C_UNITS else '0';
   csr_data <= csr_data_u(to_integer(unsigned(qnice_unit_i))) when unsigned(qnice_unit_i) < C_UNITS else x"0000";
   csr_wait <= csr_wait_u(to_integer(unsigned(qnice_unit_i))) when unsigned(qnice_unit_i) < C_UNITS else '0';

   g_mnt : for d in 0 to 1 generate
      mnt_o(40 * d + 39 downto 40 * d) <= mode(d)(0) & mode(d)(2) & cyl(d) & spt(d) &
                                          std_logic_vector(sects(d)(15 downto 0)) & heads(d) &
                                          std_logic_vector(gen(d));
   end generate g_mnt;
   mnt_o(119 downto 80) <= mode(2)(0) & mode(2)(2) & std_logic_vector(sects(2)) & "00" &
                           std_logic_vector(gen(2));

   p_map : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if map_we_f = '1' then
            map_ram(to_integer(unsigned(map_wa_f))) <= map_wd_f;
         end if;
         map_q <= map_ram(x_drv * 2048 + to_integer(maddr));
      end if;
   end process p_map;

   ---------------------------------------------------------------------------------------------
   -- The engine port
   ---------------------------------------------------------------------------------------------

   sd_ready <= sd_q2c_i(Q2C_READY);
   sd_busy  <= sd_q2c_i(Q2C_BUSY);
   sd_done  <= sd_q2c_i(Q2C_DONE);
   sd_error <= sd_q2c_i(Q2C_ERROR);
   sd_blk   <= sd_q2c_i(Q2C_BLK);
   sd_rdwe  <= sd_q2c_i(Q2C_RDWE);

   p_c2q : process (all)
   begin
      sd_c2q_o              <= (others => '0');
      sd_c2q_o(C2Q_START)   <= sd_start;
      sd_c2q_o(C2Q_WRITE)   <= x_wr;
      sd_c2q_o(C2Q_ADDR)    <= std_logic_vector(run_blk);
      sd_c2q_o(C2Q_COUNT)   <= x"0001";
      sd_c2q_o(C2Q_LIMIT)   <= x"FFFF";
      sd_c2q_o(C2Q_WRDATA)  <= buf_a_q;
      sd_c2q_o(C2Q_SLOT)    <= mode(x_drv)(1);
   end process p_c2q;

   -- the buffer's QNICE port: the controller's read bytes in, its write bytes out (the byte
   -- one clock after it named it)
   buf_a_we   <= sd_rdwe when st = F_RUN and x_wr = '0' and sd_q2c_i(Q2C_RDBLK) = x"0000" else '0';
   buf_a_addr <= sd_q2c_i(Q2C_RDIDX) when x_wr = '0' else sd_q2c_i(Q2C_WRIDX);

   -- (tdp_ram itself, not M2M's dualport_2clk_ram wrapper: that one passes the clock through an
   -- expression and the address through a process, a delta cycle each, which in simulation makes
   -- the RAM see a new write enable with the previous address)
   i_buf : entity work.tdp_ram
      generic map (
         ADDR_WIDTH => 9,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => qnice_clk_i,
         address_a => buf_a_addr,
         data_a    => sd_q2c_i(Q2C_RDDATA),
         wren_a    => buf_a_we,
         q_a       => buf_a_q,
         clock_b   => main_clk_i,
         address_b => buf_addr_i,
         data_b    => buf_wd_i,
         wren_b    => buf_we_i,
         q_b       => buf_rd_o
      ); -- i_buf

   ---------------------------------------------------------------------------------------------
   -- A request: look up, move one block, answer
   ---------------------------------------------------------------------------------------------

   done_o     <= done;
   done_err_o <= done_err;

   p_engine : process (qnice_clk_i)
      variable v_end : unsigned(31 downto 0);
      variable v_w   : unsigned(10 downto 0);
   begin
      if rising_edge(qnice_clk_i) then
         sd_start <= '0';
         req_s    <= req_s(1 downto 0) & req_i;

         -- the request's time: microseconds since it arrived
         if us_div = C_US - 1 then
            us_div <= 0;
            if x_t /= x"FFFF" then
               x_t <= x_t + 1;
            end if;
         else
            us_div <= us_div + 1;
         end if;

         case st is
            when F_IDLE =>
               if req_s(2) /= req_s(1) then
                  x_wr    <= req_wr_i;
                  if unsigned(req_unit_i) < C_UNITS then
                     x_drv <= to_integer(unsigned(req_unit_i));
                  else
                     x_drv <= 0;
                  end if;
                  x_lba   <= unsigned(req_lba_i);
                  st_last <= req_wr_i & req_unit_i & req_lba_i(12 downto 0);
                  st_lba  <= req_lba_i;
                  us_div  <= 0;
                  x_t     <= (others => '0');
                  tries   <= 0;
                  st      <= F_CHECK;
               end if;

            when F_CHECK =>
               x_shift <= shift(x_drv);
               if mode(x_drv)(0) = '0' or x_lba >= sects(x_drv) or
                  (x_wr = '1' and mode(x_drv)(2) = '1') then
                  st <= F_FAIL;
               else
                  ci    <= shift_right(x_lba, shift(x_drv));
                  cum   <= (others => '0');
                  ext_i <= (others => '0');
                  maddr <= (others => '0');
                  ph    <= 0;
                  st    <= F_LOOK_N;
               end if;

            -- word 0: the number of extents (the RAM answers two clocks after the address)
            when F_LOOK_N =>
               if ph = 2 then
                  ext_n <= unsigned(map_q);
                  ph    <= 0;
                  st    <= F_LOOK_EXT;
               else
                  ph <= ph + 1;
               end if;

            -- the extent's four words: first cluster lo/hi, clusters lo/hi
            when F_LOOK_EXT =>
               if resize(ext_i, 16) >= ext_n then
                  st <= F_FAIL;                      -- not in the map
               else
                  v_w := resize(ext_i(8 downto 0) & "00", 11) + 1;
                  case ph is
                     when 0 => maddr <= v_w;
                     when 1 => maddr <= v_w + 1;
                     when 2 => maddr <= v_w + 2;  e_first(15 downto 0)  <= unsigned(map_q);
                     when 3 => maddr <= v_w + 3;  e_first(31 downto 16) <= unsigned(map_q);
                     when 4 =>                     e_len(15 downto 0)    <= unsigned(map_q);
                     when others =>                e_len(31 downto 16)   <= unsigned(map_q);
                  end case;
                  if ph = 5 then
                     ph <= 0;
                     st <= F_LOOK_CMP;
                  else
                     ph <= ph + 1;
                  end if;
               end if;

            when F_LOOK_CMP =>
               v_end := cum + e_len;
               if ci < v_end then
                  p_clus <= e_first + (ci - cum);
                  st     <= F_CALC;
               else
                  cum   <= v_end;
                  ext_i <= ext_i + 1;
                  st    <= F_LOOK_EXT;
               end if;

            when F_CALC =>
               run_blk <= base(x_drv) + shift_left(p_clus, x_shift) + (x_lba - shift_left(ci, x_shift));
               st      <= F_START;

            when F_START =>
               if sd_ready = '0' then
                  st <= F_RETRY;                     -- no card, or not initialised (yet)
               elsif sd_busy = '0' then
                  moved    <= '0';
                  sd_start <= '1';
                  st       <= F_RUN;
               end if;

            when F_RUN =>
               if sd_blk = '1' then
                  moved <= '1';
               end if;
               if sd_done = '1' then
                  if sd_error = '1' then
                     st_retry <= st_retry + 1;
                     st <= F_RETRY;
                  elsif moved = '0' and sd_blk = '0' then
                     st_again <= st_again + 1;
                     st <= F_START;                  -- QNICE came first: once more
                  else
                     st <= F_DONE;
                  end if;
               end if;

            when F_RETRY =>
               if tries = C_TRIES - 1 then
                  st <= F_FAIL;
               elsif wait_cnt = C_RETRY_WAIT then
                  wait_cnt <= 0;
                  tries    <= tries + 1;
                  st       <= F_START;
               else
                  wait_cnt <= wait_cnt + 1;
               end if;

            when F_FAIL =>
               st_err   <= st_err + 1;
               st_t     <= x_t;
               done_err <= '1';
               done     <= not done;
               st       <= F_IDLE;

            when F_DONE =>
               if x_wr = '1' then
                  st_wr   <= st_wr + 1;
                  st_wr_t <= st_wr_t + x_t;
                  if x_t > st_wr_max then
                     st_wr_max <= x_t;
                  end if;
               else
                  st_rd   <= st_rd + 1;
                  st_rd_t <= st_rd_t + x_t;
                  if x_t > st_rd_max then
                     st_rd_max <= x_t;
                  end if;
               end if;
               st_t     <= x_t;
               done_err <= '0';
               done     <= not done;
               st       <= F_IDLE;
         end case;

         -- QNICE cleared the statistics
         st_clr_r <= st_clr_f;
         if st_clr_r /= st_clr_f then
            st_rd     <= (others => '0');
            st_wr     <= (others => '0');
            st_err    <= (others => '0');
            st_rd_t   <= (others => '0');
            st_rd_max <= (others => '0');
            st_wr_t   <= (others => '0');
            st_wr_max <= (others => '0');
            st_retry  <= (others => '0');
            st_again  <= (others => '0');
         end if;
      end if;
   end process p_engine;

end architecture synthesis;

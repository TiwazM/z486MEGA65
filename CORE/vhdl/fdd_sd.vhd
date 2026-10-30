----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- The PC's floppy drive A: straight from an image file on the SD card: one 512-byte sector at
-- a time through the SD host controller's engine port, for pc_mgmt.vhd, which serves floppy.v.
-- After Megamiga's adf_sd.vhd and Megamac's ide_engine.vhd (the same extent map and lookup),
-- without their track buffer: floppy.v asks for one sector and waits for it anyway.
--
--   * The firmware (m2m-rom.asm, FDD_PREP) writes the file's extent map (FAT32$FILE_MAP format:
--     word 0 = extents, then per extent first cluster lo/hi, clusters lo/hi; up to 511) into
--     window 1, then the registers below, MODE last.
--   * A request from pc_mgmt (a toggle; wr and lba stable while it crosses) is looked up in
--     the map: cluster index = lba >> SHIFT, SD block = BASE + (cluster << SHIFT) + the rest.
--     The block moves between the card and the sector buffer (a true dual-port block RAM, one
--     port per clock domain), then the answer goes back (a toggle, err stable with it).
--   * A failed transfer is tried again twice, 1 ms apart; a controller that is not ready
--     counts as a failure. A transfer that QNICE's own SD access ended early (no block moved)
--     starts again. A sector that cannot be read (no image, outside the file, SD error) comes
--     back with err set: pc_mgmt then gives the PC zeros. A write to a write-protected image
--     is dropped (floppy.v already refused it: the write protect is in its register 1).
--
-- QNICE registers (device C_DEV_PC_FDD, window 0; written on the falling edge):
--   0x00 MODE    bit 0 = an image is mounted, bit 1 = it is on the card in slot 1, bit 2 =
--                write protected. Every write counts the mount generation pc_mgmt watches.
--   0x01/0x02    SECTS  sectors of the file (lo, hi)
--   0x03/0x04    BASE   SD block of cluster 0 = DEV_CLUSTER - (2 << SHIFT) (lo, hi)
--   0x05 SHIFT   log2(sectors per cluster)
--   0x06 CYL     cylinders, 0x07 SPT sectors per track, 0x08 HEADS (for floppy.v)
--   0x10..0x13   (read) sectors read, sectors written, failed requests, the last request
--                (bit 15 = write, 14..0 = LBA)
-- Window 1: the extent map (2048 words). Window 0xFFFF: M2M's CSR (qnice_csr.vhd), which the
-- Shell's manual load talks to: it answers READY at once (the Shell streams nothing: FDD_PREP
-- moved the file handle to its end).
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;
use work.qnice_csr_pkg.all;

entity fdd_sd is
   generic (
      G_QNICE_HZ   : natural := 50_000_000
   );
   port (
      qnice_clk_i  : in  std_logic;
      qnice_rst_i  : in  std_logic;
      qnice_addr_i : in  std_logic_vector(27 downto 0);
      qnice_data_i : in  std_logic_vector(15 downto 0);
      qnice_ce_i   : in  std_logic;               -- this device is selected
      qnice_we_i   : in  std_logic;
      qnice_data_o : out std_logic_vector(15 downto 0);
      qnice_wait_o : out std_logic;

      -- the SD host controller's engine port (QNICE clock)
      sd_q2c_i     : in  t_sd_q2c;
      sd_c2q_o     : out t_sd_c2q;

      -- drive A: for pc_mgmt (QNICE clock; mnt_gen_o moves last)
      mnt_mounted_o : out std_logic;
      mnt_wp_o      : out std_logic;
      mnt_cyl_o     : out std_logic_vector(7 downto 0);
      mnt_spt_o     : out std_logic_vector(7 downto 0);
      mnt_total_o   : out std_logic_vector(15 downto 0);
      mnt_heads_o   : out std_logic_vector(1 downto 0);
      mnt_gen_o     : out std_logic_vector(3 downto 0);

      -- sector requests from pc_mgmt (main clock) and the answers (QNICE clock)
      req_i        : in  std_logic;                -- a toggle
      req_wr_i     : in  std_logic;
      req_lba_i    : in  std_logic_vector(15 downto 0);
      done_o       : out std_logic;                -- a toggle
      done_err_o   : out std_logic;

      -- the sector buffer's other port (pc_mgmt's clock; read data one clock later)
      main_clk_i   : in  std_logic;
      buf_addr_i   : in  std_logic_vector(8 downto 0);
      buf_we_i     : in  std_logic;
      buf_wd_i     : in  std_logic_vector(7 downto 0);
      buf_rd_o     : out std_logic_vector(7 downto 0)
   );
end entity fdd_sd;

architecture synthesis of fdd_sd is

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (others => "OK                   ");
   constant C_RETRY_WAIT    : natural := G_QNICE_HZ / 1000;     -- 1 ms
   constant C_TRIES         : natural := 3;

   -- registers
   signal mode      : std_logic_vector(2 downto 0) := (others => '0');
   signal sects     : unsigned(31 downto 0) := (others => '0');
   signal base      : unsigned(31 downto 0) := (others => '0');
   signal shift     : natural range 0 to 15 := 0;
   signal cyl       : std_logic_vector(7 downto 0) := x"50";
   signal spt       : std_logic_vector(7 downto 0) := x"12";
   signal heads     : std_logic_vector(1 downto 0) := "10";
   signal gen       : unsigned(3 downto 0) := (others => '0');
   signal st_rd     : unsigned(15 downto 0) := (others => '0');
   signal st_wr     : unsigned(15 downto 0) := (others => '0');
   signal st_err    : unsigned(15 downto 0) := (others => '0');
   signal st_last   : std_logic_vector(15 downto 0) := (others => '0');

   -- the extent map: written on the falling edge, into the RAM on the next rising edge
   type t_map is array (0 to 2047) of std_logic_vector(15 downto 0);
   signal map_ram   : t_map := (others => (others => '0'));
   signal map_we_f  : std_logic := '0';
   signal map_wa_f  : std_logic_vector(10 downto 0) := (others => '0');
   signal map_wd_f  : std_logic_vector(15 downto 0) := (others => '0');
   signal maddr     : unsigned(10 downto 0) := (others => '0');
   signal map_q     : std_logic_vector(15 downto 0) := (others => '0');

   -- the CSR (window 0xFFFF)
   signal csr_data   : std_logic_vector(15 downto 0);
   signal csr_wait   : std_logic;
   signal csr_sel    : std_logic;
   signal req_status : std_logic_vector(3 downto 0);
   signal resp_status : std_logic_vector(3 downto 0);
   signal q_win0     : std_logic;
   signal q_win1     : std_logic;

   -- the request
   type t_state is (F_IDLE, F_CHECK, F_LOOK_N, F_LOOK_EXT, F_LOOK_CMP, F_CALC, F_START, F_RUN,
                    F_RETRY, F_FAIL, F_DONE);
   signal st        : t_state := F_IDLE;
   signal req_s     : std_logic_vector(2 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of req_s : signal is "true";
   signal x_wr      : std_logic := '0';
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
   q_win1 <= '1' when qnice_addr_i(27 downto 12) = x"0001" else '0';

   p_qnice_write : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         map_we_f <= '0';
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if q_win1 = '1' then
               map_we_f <= '1';
               map_wa_f <= qnice_addr_i(10 downto 0);
               map_wd_f <= qnice_data_i;
            elsif q_win0 = '1' then
               case to_integer(unsigned(qnice_addr_i(7 downto 0))) is
                  when 16#00# =>
                     mode <= qnice_data_i(2 downto 0);
                     gen  <= gen + 1;
                  when 16#01# => sects(15 downto 0)  <= unsigned(qnice_data_i);
                  when 16#02# => sects(31 downto 16) <= unsigned(qnice_data_i);
                  when 16#03# => base(15 downto 0)   <= unsigned(qnice_data_i);
                  when 16#04# => base(31 downto 16)  <= unsigned(qnice_data_i);
                  when 16#05# => shift <= to_integer(unsigned(qnice_data_i(3 downto 0)));
                  when 16#06# => cyl   <= qnice_data_i(7 downto 0);
                  when 16#07# => spt   <= qnice_data_i(7 downto 0);
                  when 16#08# => heads <= qnice_data_i(1 downto 0);
                  when others => null;
               end case;
            end if;
         end if;
         if qnice_rst_i = '1' then
            mode <= (others => '0');
            gen  <= gen + 1;
         end if;
      end if;
   end process p_qnice_write;

   p_qnice_read : process (all)
   begin
      qnice_data_o <= x"0000";
      if csr_sel = '1' then
         qnice_data_o <= csr_data;
      elsif q_win0 = '1' then
         case to_integer(unsigned(qnice_addr_i(7 downto 0))) is
            when 16#00# => qnice_data_o <= "0000000000000" & mode;
            when 16#01# => qnice_data_o <= std_logic_vector(sects(15 downto 0));
            when 16#02# => qnice_data_o <= std_logic_vector(sects(31 downto 16));
            when 16#03# => qnice_data_o <= std_logic_vector(base(15 downto 0));
            when 16#04# => qnice_data_o <= std_logic_vector(base(31 downto 16));
            when 16#05# => qnice_data_o <= std_logic_vector(to_unsigned(shift, 16));
            when 16#06# => qnice_data_o <= x"00" & cyl;
            when 16#07# => qnice_data_o <= x"00" & spt;
            when 16#08# => qnice_data_o <= "00000000000000" & heads;
            when 16#10# => qnice_data_o <= std_logic_vector(st_rd);
            when 16#11# => qnice_data_o <= std_logic_vector(st_wr);
            when 16#12# => qnice_data_o <= std_logic_vector(st_err);
            when 16#13# => qnice_data_o <= st_last;
            when others => null;
         end case;
      end if;
   end process p_qnice_read;

   qnice_wait_o <= csr_wait when csr_sel = '1' else '0';

   i_qnice_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_addr_i,
         qnice_data_i         => qnice_data_i,
         qnice_ce_i           => qnice_ce_i,
         qnice_we_i           => qnice_we_i,
         qnice_data_o         => csr_data,
         qnice_wait_o         => csr_wait,
         qnice_csr_o          => csr_sel,
         qnice_req_status_o   => req_status,
         qnice_req_length_o   => open,
         qnice_resp_status_i  => resp_status,
         qnice_resp_error_i   => x"0",
         qnice_resp_address_i => (others => '0')
      ); -- i_qnice_csr

   resp_status <= C_CSR_RESP_READY when req_status = C_CSR_REQ_OK else C_CSR_RESP_IDLE;

   mnt_mounted_o <= mode(0);
   mnt_wp_o      <= mode(2);
   mnt_cyl_o     <= cyl;
   mnt_spt_o     <= spt;
   mnt_total_o   <= std_logic_vector(sects(15 downto 0));
   mnt_heads_o   <= heads;
   mnt_gen_o     <= std_logic_vector(gen);

   p_map : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if map_we_f = '1' then
            map_ram(to_integer(unsigned(map_wa_f))) <= map_wd_f;
         end if;
         map_q <= map_ram(to_integer(maddr));
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
      sd_c2q_o(C2Q_SLOT)    <= mode(1);
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

         case st is
            when F_IDLE =>
               if req_s(2) /= req_s(1) then
                  x_wr    <= req_wr_i;
                  x_lba   <= resize(unsigned(req_lba_i), 32);
                  st_last <= req_wr_i & req_lba_i(14 downto 0);
                  tries   <= 0;
                  st      <= F_CHECK;
               end if;

            when F_CHECK =>
               if mode(0) = '0' or x_lba >= sects or (x_wr = '1' and mode(2) = '1') then
                  st <= F_FAIL;
               else
                  ci    <= shift_right(x_lba, shift);
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
               run_blk <= base + shift_left(p_clus, shift) + (x_lba - shift_left(ci, shift));
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
                     st <= F_RETRY;
                  elsif moved = '0' and sd_blk = '0' then
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
               done_err <= '1';
               done     <= not done;
               st       <= F_IDLE;

            when F_DONE =>
               if x_wr = '1' then
                  st_wr <= st_wr + 1;
               else
                  st_rd <= st_rd + 1;
               end if;
               done_err <= '0';
               done     <= not done;
               st       <= F_IDLE;
         end case;
      end if;
   end process p_engine;

end architecture synthesis;

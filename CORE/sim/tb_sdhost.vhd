----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Testbench: the SD host controller (M2M/vhdl/QNICE/sdhost.vhd) against sd_card_model.vhd.
-- After the card's init (the controller's own, at reset), the mode it ended in is checked;
-- then the engine port reads 4 blocks, writes 4 and 1, reads those back and reads one
-- more, as disk_sd does: every byte checked, no transfer may fail, the card must see no
-- protocol error. G_PREEMPT_FIRST: the first multi-block write after the init ends before
-- its first block may move (LIMIT 0, then ABORT), as when QNICE comes first.
--
-- Scaled time: G_MS = 1000 clk2x_i clocks per "ms" (timeouts 100 times shorter than on the
-- board); the init clock is 3.1 MHz instead of 400 kHz. No high speed (G_HS false).
-- CORE/sim/run_sdhost.sh runs the cases (nvc).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sd_card_pkg.all;

entity tb_sdhost is
   generic (
      G_SPI_LOCKED    : boolean := false;
      G_STUCK_READ    : boolean := false;
      G_BUSY_LATE     : natural := 0;
      G_BUSY_LEN      : natural := 40;
      G_R1B_LEN       : natural := 40;
      G_DRESP_LATE    : natural := 0;
      G_EXPECT_NATIVE : boolean := true;
      G_PREEMPT_FIRST : boolean := false;
      G_NAME          : string  := "case";
      G_DEBUG         : boolean := false
   );
end entity tb_sdhost;

architecture sim of tb_sdhost is
   signal clk, clk2x : std_logic := '0';
   signal reset      : std_logic := '1';
   signal en, we     : std_logic := '0';
   signal reg        : std_logic_vector(2 downto 0) := "000";
   signal qd_i, qd_o : std_logic_vector(15 downto 0) := (others => '0');

   signal e_ready, e_start, e_write, e_abort : std_logic := '0';
   signal e_addr     : std_logic_vector(31 downto 0) := (others => '0');
   signal e_count    : std_logic_vector(15 downto 0) := (others => '0');
   signal e_limit    : std_logic_vector(15 downto 0) := x"FFFF";
   signal e_busy, e_done, e_error, e_blk, e_rd_we : std_logic;
   signal e_rd_blk, e_wr_blk : std_logic_vector(15 downto 0);
   signal e_rd_idx, e_wr_idx : std_logic_vector(8 downto 0);
   signal e_rd_data, e_wr_data : std_logic_vector(7 downto 0) := (others => '0');

   signal sd_clk, h_cmd, h_cmd_oe, c_cmd, c_cmd_oe, cmd_line : std_logic;
   signal h_dat, h_dat_oe, c_dat, c_dat_oe, dat_line : std_logic_vector(3 downto 0);
   signal card_errors, card_writes : natural;
   signal card_spi : boolean;

   -- the transfer the engine port runs, for the data processes
   signal cur_addr   : natural := 0;
   signal cur_write  : std_logic := '0';
   signal rd_bad     : natural := 0;
   signal rd_bytes   : natural := 0;
   signal rd_reset   : std_logic := '0';

   -- what the test writes: byte i of block b
   function pat_b(b : natural; i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((b * 11 + i * 3 + 16#33#) mod 256, 8));
   end function;
   -- what block b holds at the time of the read-back (blocks 8..11 and 20 written)
   function expect(b : natural; i : natural; after_wr : boolean) return std_logic_vector is
   begin
      if after_wr and ((b >= 8 and b <= 11) or b = 20) then
         return pat_b(b, i);
      end if;
      return sd_init_byte(b, i);
   end function;
   signal after_wr : boolean := false;
begin

   -- clk_i 50 MHz and clk2x_i 100 MHz, rising together (the same delta)
   p_clk : process
   begin
      clk2x <= '1'; clk <= '1'; wait for 5 ns;
      clk2x <= '0';             wait for 5 ns;
      clk2x <= '1'; clk <= '0'; wait for 5 ns;
      clk2x <= '0';             wait for 5 ns;
   end process p_clk;

   i_dut : entity work.sdhost
      generic map (
         G_HS        => false,
         G_HALF_INIT => 16,
         G_MS        => 1000
      )
      port map (
         clk_i => clk, clk2x_i => clk2x, reset_i => reset,
         en_i => en, we_i => we, reg_i => reg, data_i => qd_i, data_o => qd_o,
         e_ready_o => e_ready, e_start_i => e_start, e_write_i => e_write,
         e_addr_i => e_addr, e_count_i => e_count, e_limit_i => e_limit, e_abort_i => e_abort,
         e_busy_o => e_busy, e_done_o => e_done, e_error_o => e_error, e_blk_o => e_blk,
         e_rd_we_o => e_rd_we, e_rd_blk_o => e_rd_blk, e_rd_idx_o => e_rd_idx,
         e_rd_data_o => e_rd_data,
         e_wr_blk_o => e_wr_blk, e_wr_idx_o => e_wr_idx, e_wr_data_i => e_wr_data,
         sd_clk_o => sd_clk, cmd_o => h_cmd, cmd_oe_o => h_cmd_oe, cmd_i => cmd_line,
         dat_o => h_dat, dat_oe_o => h_dat_oe, dat_i => dat_line
      );

   -- the lines: the host drives over the card, else the card, else the pull-ups
   cmd_line <= h_cmd when h_cmd_oe = '1' else c_cmd when c_cmd_oe = '1' else '1';
   g_dat : for l in 0 to 3 generate
      dat_line(l) <= h_dat(l) when h_dat_oe(l) = '1' else c_dat(l) when c_dat_oe(l) = '1' else '1';
   end generate;

   i_card : entity work.sd_card_model
      generic map (
         G_SPI_LOCKED => G_SPI_LOCKED, G_STUCK_READ => G_STUCK_READ,
         G_BUSY_LATE => G_BUSY_LATE, G_BUSY_LEN => G_BUSY_LEN, G_DRESP_LATE => G_DRESP_LATE,
         G_R1B_LEN => G_R1B_LEN,
         G_DEBUG => G_DEBUG
      )
      port map (
         clk_i => sd_clk, cmd_i => cmd_line, dat_i => dat_line,
         cmd_o => c_cmd, cmd_oe_o => c_cmd_oe, dat_o => c_dat, dat_oe_o => c_dat_oe,
         errors_o => card_errors, spi_o => card_spi, writes_o => card_writes
      );

   -- the engine's write data: the byte at (blk, idx), one clk_i clock after the address
   p_wdata : process (clk)
   begin
      if rising_edge(clk) then
         e_wr_data <= pat_b(cur_addr + to_integer(unsigned(e_wr_blk)), to_integer(unsigned(e_wr_idx)));
      end if;
   end process p_wdata;

   -- the read data, checked
   p_rdata : process (clk)
      variable b : natural;
   begin
      if rising_edge(clk) then
         if rd_reset = '1' then
            rd_bad <= 0; rd_bytes <= 0;
         elsif e_rd_we = '1' then
            b := cur_addr + to_integer(unsigned(e_rd_blk));
            rd_bytes <= rd_bytes + 1;
            if e_rd_data /= expect(b, to_integer(unsigned(e_rd_idx)), after_wr) then
               rd_bad <= rd_bad + 1;
            end if;
         end if;
      end if;
   end process p_rdata;

   p_test : process
      variable errors : natural := 0;
      variable v      : std_logic_vector(15 downto 0);
      variable k      : natural;
      variable got_err : std_logic;

      procedure check(ok : boolean; what : string) is
      begin
         if ok then
            report "ok    " & what;
         else
            report "FAIL  " & what severity error;
            errors := errors + 1;
         end if;
      end procedure;

      procedure qread(r : natural; d : out std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk);
         en <= '1'; we <= '0'; reg <= std_logic_vector(to_unsigned(r, 3));
         wait until rising_edge(clk);
         d := qd_o;
         en <= '0';
      end procedure;

      -- an engine transfer; returns its error bit (a timeout counts as an error)
      procedure xfer(wr : std_logic; addr : natural; cnt : natural; err : out std_logic;
                     tmo_us : natural := 200000) is
         variable n : natural := 0;
      begin
         wait until rising_edge(clk);
         cur_addr <= addr; cur_write <= wr;
         rd_reset <= '1';
         wait until rising_edge(clk);
         rd_reset <= '0';
         e_write <= wr;
         e_addr  <= std_logic_vector(to_unsigned(addr, 32));
         e_count <= std_logic_vector(to_unsigned(cnt, 16));
         e_start <= '1';
         wait until rising_edge(clk);
         e_start <= '0';
         err := '1';
         for t in 0 to tmo_us * 50 loop
            wait until rising_edge(clk);
            if e_done = '1' then
               err := e_error;
               exit;
            end if;
         end loop;
      end procedure;
   begin
      reset <= '1';
      wait for 200 ns;
      wait until rising_edge(clk);
      reset <= '0';

      -- the init (the controller starts it after its reset)
      for t in 0 to 60_000_000 / 20 loop
         wait until rising_edge(clk);
         exit when e_ready = '1';
      end loop;
      qread(6, v);
      check(e_ready = '1' and (v(0) = '1') = G_EXPECT_NATIVE,
            G_NAME & ": init: ready " & std_logic'image(e_ready) & ", mode " & to_hstring(v) &
            " (bit 0 native, 1 SPI 12.5 MHz), card " & boolean'image(card_spi) & " SPI, expected " &
            boolean'image(G_EXPECT_NATIVE) & " native, at " & time'image(now));
      if e_ready /= '1' then
         qread(4, v);
         report "  error code " & to_hstring(v);
         qread(5, v);
         report "  CSR " & to_hstring(v);
         report "FAILED: " & integer'image(errors) & " checks (" & G_NAME & ")" severity error;
         std.env.finish;
      end if;

      -- the first multi-block write after the init, ended before its first block
      if G_PREEMPT_FIRST then
         wait until rising_edge(clk);
         e_limit <= x"0000";
         cur_addr <= 30; cur_write <= '1';
         e_write <= '1'; e_addr <= std_logic_vector(to_unsigned(30, 32));
         e_count <= std_logic_vector(to_unsigned(4, 16));
         e_start <= '1';
         wait until rising_edge(clk);
         e_start <= '0';
         wait for 30 us;
         e_abort <= '1';
         got_err := '1';
         for t in 0 to 1_000_000 loop
            wait until rising_edge(clk);
            if e_done = '1' then got_err := e_error; exit; end if;
         end loop;
         e_abort <= '0';
         e_limit <= x"FFFF";
         check(got_err = '0', G_NAME & ": a multi-block write ended before its first block");
      end if;

      xfer('0', 0, 4, got_err);
      check(got_err = '0' and rd_bad = 0 and rd_bytes = 2048,
            G_NAME & ": read 0-3: error " & std_logic'image(got_err) & ", " & integer'image(rd_bytes) &
            " bytes, " & integer'image(rd_bad) & " wrong");
      xfer('1', 8, 4, got_err);
      check(got_err = '0', G_NAME & ": write 8-11: error " & std_logic'image(got_err));
      xfer('1', 20, 1, got_err);
      check(got_err = '0', G_NAME & ": write 20: error " & std_logic'image(got_err));
      after_wr <= true;
      xfer('0', 8, 4, got_err);
      check(got_err = '0' and rd_bad = 0 and rd_bytes = 2048,
            G_NAME & ": read back 8-11: error " & std_logic'image(got_err) & ", " & integer'image(rd_bytes) &
            " bytes, " & integer'image(rd_bad) & " wrong");
      xfer('0', 20, 1, got_err);
      check(got_err = '0' and rd_bad = 0 and rd_bytes = 512,
            G_NAME & ": read back 20: error " & std_logic'image(got_err) & ", " & integer'image(rd_bad) & " wrong");
      xfer('0', 5, 1, got_err);
      check(got_err = '0' and rd_bad = 0 and rd_bytes = 512,
            G_NAME & ": read 5: error " & std_logic'image(got_err) & ", " & integer'image(rd_bad) & " wrong");
      qread(6, v);
      check(card_errors = 0 and card_writes = 5 and (v(0) = '1') = G_EXPECT_NATIVE,
            G_NAME & ": the card saw " & integer'image(card_errors) & " protocol errors, " &
            integer'image(card_writes) & " blocks written; mode " & to_hstring(v));

      if errors = 0 then
         report "PASS: all checks (" & G_NAME & ")";
      else
         report "FAILED: " & integer'image(errors) & " checks (" & G_NAME & ")" severity error;
      end if;
      std.env.finish;
   end process p_test;

end architecture sim;

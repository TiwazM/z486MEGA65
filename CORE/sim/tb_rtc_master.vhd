-- Runs M2M/vhdl/i2c/rtc_master.vhd (MEGA65_R6) against a stand-in for the I2C controller: the
-- first read returns what an R6 gave straight after power-on (2026-11-06: time 00:00:00, day
-- 00, month 06, year B1), the second a real time, which must be the one kept (M2M-UPSTREAM
-- rtc-verify: every field checked). Then every read is junk: after C_RETRIES retries the master
-- gives 2000-01-01 00:00:00 and goes idle. Run with nvc (CORE/sim/run_rtc_master.sh).

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity tb_rtc_master is
end entity tb_rtc_master;

architecture sim of tb_rtc_master is

   signal clk      : std_logic := '0';
   signal rst      : std_logic := '1';
   signal busy     : std_logic;
   signal rd       : std_logic := '0';
   signal rd_data  : std_logic_vector(63 downto 0);
   signal m_ce     : std_logic;
   signal m_we     : std_logic;
   signal m_addr   : std_logic_vector( 7 downto 0);
   signal m_wdata  : std_logic_vector(15 downto 0);
   signal m_rdata  : std_logic_vector(15 downto 0);

   signal accepted : std_logic := '0';  -- the command register was written: F1 reads 0 once
   signal reads    : natural   := 0;    -- RTC reads the master started (writes to F0)
   signal all_junk : boolean   := false;

   type words_t is array (0 to 3) of std_logic_vector(15 downto 0);
   -- word k = byte 2k (high) & byte 2k+1 (low); bytes as the RV-3032 sends them from register
   -- 1: hundredths, seconds, minutes, hours, day of week, day, month, year
   constant C_JUNK : words_t := (x"0000", x"0000", x"0000", x"06B1");
   constant C_GOOD : words_t := (x"9655", x"1721", x"0406", x"1126");   -- Fri 2026-11-06 21:17:55.96
   -- after post_read: day of week, year, month, day, hours, minutes, seconds, hundredths
   constant C_GOOD_RTC  : std_logic_vector(63 downto 0) := x"04_26_11_06_21_17_55_96";
   constant C_EMPTY_RTC : std_logic_vector(63 downto 0) := x"05_00_01_01_00_00_00_00";

begin

   clk <= not clk after 10 ns;

   i_dut : entity work.rtc_master
      generic map (
         G_BOARD => "MEGA65_R6"
      )
      port map (
         clk_i           => clk,
         rst_i           => rst,
         rtc_busy_o      => busy,
         rtc_read_i      => rd,
         rtc_write_i     => '0',
         rtc_wr_data_i   => (others => '0'),
         rtc_rd_data_o   => rd_data,
         cpu_m_wait_i    => '0',
         cpu_m_ce_o      => m_ce,
         cpu_m_we_o      => m_we,
         cpu_m_addr_o    => m_addr,
         cpu_m_wr_data_o => m_wdata,
         cpu_m_rd_data_i => m_rdata
      );

   -- the I2C controller: F1 = status (0 once after a command, else 1 = idle), 00..03 = the
   -- received bytes
   m_rdata <= x"0000"                     when m_addr = x"F1" and accepted = '1' else
              x"0001"                     when m_addr = x"F1" else
              C_JUNK(to_integer(unsigned(m_addr(1 downto 0)))) when all_junk or reads = 1 else
              C_GOOD(to_integer(unsigned(m_addr(1 downto 0))));

   p_ctl : process (clk)
   begin
      if rising_edge(clk) then
         if m_ce = '1' and m_we = '1' and m_addr = x"F0" then
            accepted <= '1';
            if m_wdata(7 downto 0) = x"A3" then           -- receive: a read of the time
               reads <= reads + 1;
            end if;
         elsif m_ce = '1' and m_we = '0' and m_addr = x"F1" then
            accepted <= '0';
         end if;
      end if;
   end process p_ctl;

   p_main : process
      variable v_reads : natural;
   begin
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      -- the read after reset: junk first, then the real time
      wait until rising_edge(clk) and busy = '0' for 10 ms;
      assert busy = '0' report "FAIL: still busy after the first read" severity failure;
      report "after reset: " & integer'image(reads) & " reads, rtc " & to_hstring(rd_data);
      assert reads = 2 and rd_data = C_GOOD_RTC
         report "FAIL: expected 2 reads and the good time" severity failure;

      -- every read junk: the master gives up after C_RETRIES retries
      all_junk <= true;
      v_reads  := reads;
      wait until rising_edge(clk);
      rd <= '1';
      wait until rising_edge(clk);
      rd <= '0';
      wait until rising_edge(clk) and busy = '0' for 1000 ms;
      assert busy = '0' report "FAIL: still busy after junk reads" severity failure;
      report "all junk: " & integer'image(reads - v_reads) & " reads, rtc " & to_hstring(rd_data);
      assert reads - v_reads = 101 and rd_data = C_EMPTY_RTC
         report "FAIL: expected 101 reads and 2000-01-01" severity failure;
      report "PASS";
      std.env.finish;
   end process p_main;

end architecture sim;

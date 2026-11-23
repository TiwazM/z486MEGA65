-- Copied for z486MEGA65 (2026-11-23), unchanged, from Megamiga/MegaMac (Megamac commit e733c5f).
---------------------------------------------------------------------------------------------------------
-- Megamiga (Amiga for MEGA65, fork of AExp)
--
-- eth_mac: a 100 Mbit/s RMII Ethernet MAC for the MEGA65's KSZ8081 PHY.
--
-- Clocks: clk50_i is the RMII reference clock (the parent drives the same net to the PHY), clk200_i
-- comes from the same MMCM, phase aligned. As in the MEGA65 core (ethernet.vhdl), RX data is
-- latched at 200 MHz at one of four phases and TX data leaves through a 200 MHz delay line, so the
-- sampling point can be tuned per board (rx_phase_i / tx_phase_i; the MEGA65's network loader uses
-- 1 / 1). Everything else runs on clk50_i: at 100 Mbit/s RMII carries one dibit per clock.
--
-- RX: CRS_DV starts a frame; preamble dibits 01, the SFD ends with 11, then bytes LSB first. On
-- some PHYs CRS_DV toggles near the end of a frame while data is still valid, so the frame ends
-- only after three low samples in a row (as in the MEGA65 core); a partial byte at the end is
-- dropped. rx_byte_o/rx_valid_o deliver every byte including the FCS; rx_end_o pulses at the end
-- with rx_ok_o = the CRC residue was right and the frame had a whole number of bytes.
--
-- TX: tx_start_i (one clock) with tx_len_i (1..2047 bytes, without FCS) starts a frame; the MAC
-- reads the bytes through tx_addr_o / tx_data_i (a synchronous RAM: data one clock after the
-- address), pads to 60 bytes, appends the FCS and keeps 12 byte times of inter-frame gap.
-- tx_busy_o is high from the start to the end of the gap.
--
-- Done in 2026 (Megamiga, fork of AExp) and licensed under GPL v3. The RMII sampling scheme follows
-- the MEGA65 core's ethernet.vhdl (Paul Gardner-Stephen, LGPL).
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_mac is
   port (
      clk50_i     : in  std_logic;
      clk200_i    : in  std_logic;
      rst_i       : in  std_logic;                       -- clk50_i domain

      -- PHY (RMII)
      phy_rxd_i   : in  std_logic_vector(1 downto 0);
      phy_crsdv_i : in  std_logic;
      phy_txd_o   : out std_logic_vector(1 downto 0);
      phy_txen_o  : out std_logic;

      rx_phase_i  : in  std_logic_vector(1 downto 0);    -- quasi-static
      tx_phase_i  : in  std_logic_vector(1 downto 0);

      -- RX stream (clk50_i)
      rx_start_o  : out std_logic;                       -- the SFD was seen: a frame begins
      rx_valid_o  : out std_logic;                       -- rx_byte_o is the next byte
      rx_byte_o   : out std_logic_vector(7 downto 0);
      rx_end_o    : out std_logic;                       -- the frame is over
      rx_ok_o     : out std_logic;                       -- with rx_end_o: FCS right

      -- TX (clk50_i)
      tx_start_i  : in  std_logic;
      tx_len_i    : in  unsigned(10 downto 0);
      tx_addr_o   : out unsigned(10 downto 0);
      tx_data_i   : in  std_logic_vector(7 downto 0);
      tx_busy_o   : out std_logic
   );
end entity eth_mac;

architecture synthesis of eth_mac is

   -- Ethernet CRC-32, reflected (polynomial $EDB88320), one byte LSB first
   function crc_byte(c : std_logic_vector(31 downto 0); d : std_logic_vector(7 downto 0))
      return std_logic_vector is
      variable r : std_logic_vector(31 downto 0) := c;
   begin
      for i in 0 to 7 loop
         if (r(0) xor d(i)) = '1' then
            r := ('0' & r(31 downto 1)) xor x"EDB88320";
         else
            r := '0' & r(31 downto 1);
         end if;
      end loop;
      return r;
   end function;

   constant C_RESIDUE : std_logic_vector(31 downto 0) := x"DEBB20E3";

   -- 200 MHz side
   signal ph_cnt      : unsigned(1 downto 0) := "00";
   signal rxd_l       : std_logic_vector(1 downto 0) := "00";
   signal crsdv_l     : std_logic := '0';
   signal txd_dl      : std_logic_vector(7 downto 0) := (others => '0');
   signal txen_dl     : std_logic_vector(3 downto 0) := (others => '0');
   signal txd_st      : std_logic_vector(1 downto 0) := "00";
   signal txen_st     : std_logic := '0';
   signal rx_ph200    : std_logic_vector(1 downto 0) := "01";
   signal tx_ph200    : std_logic_vector(1 downto 0) := "01";

   attribute IOB : string;

   -- RX (50 MHz)
   type t_rx is (R_IDLE, R_PRE, R_DATA, R_SKIP);
   signal rs          : t_rx := R_IDLE;
   signal rxd         : std_logic_vector(1 downto 0) := "00";
   signal crsdv       : std_logic := '0';
   signal crsdv_1     : std_logic := '0';
   signal crsdv_2     : std_logic := '0';
   signal rx_sh       : std_logic_vector(5 downto 0) := (others => '0');
   signal rx_n        : unsigned(1 downto 0) := "00";     -- dibits of the current byte so far
   signal rx_crc      : std_logic_vector(31 downto 0) := (others => '1');

   -- TX (50 MHz)
   type t_tx is (T_IDLE, T_PRE, T_DATA, T_FCS, T_GAP);
   signal ts          : t_tx := T_IDLE;
   signal txd         : std_logic_vector(1 downto 0) := "00";
   signal txen        : std_logic := '0';
   signal tx_sh       : std_logic_vector(7 downto 0) := (others => '0');
   signal tx_d        : unsigned(1 downto 0) := "00";     -- dibit of the current byte
   signal tx_i        : unsigned(10 downto 0) := (others => '0');  -- byte index
   signal tx_len      : unsigned(10 downto 0) := (others => '0');   -- with padding
   signal tx_dlen     : unsigned(10 downto 0) := (others => '0');   -- bytes from the buffer
   signal tx_crc      : std_logic_vector(31 downto 0) := (others => '1');
   signal tx_fcs      : std_logic_vector(31 downto 0) := (others => '0');   -- shifts out, LSB first
   signal tx_ra       : unsigned(10 downto 0) := (others => '0');

begin

   ---------------------------------------------------------------------------------------------
   -- 200 MHz: RX latch at the selected phase, TX delay line (MEGA65 core scheme)
   ---------------------------------------------------------------------------------------------

   p_200 : process (clk200_i)
   begin
      if rising_edge(clk200_i) then
         rx_ph200 <= rx_phase_i;
         tx_ph200 <= tx_phase_i;
         ph_cnt   <= ph_cnt + 1;

         if ph_cnt = unsigned(rx_ph200) then
            rxd_l   <= phy_rxd_i;
            crsdv_l <= phy_crsdv_i;
         end if;

         txd_st     <= txd_dl(7 downto 6);
         txen_st    <= txen_dl(3);
         phy_txd_o  <= txd_st;
         phy_txen_o <= txen_st;

         txd_dl(7 downto 2)  <= txd_dl(5 downto 0);
         txen_dl(3 downto 1) <= txen_dl(2 downto 0);
         case tx_ph200 is
            when "00"   => txd_dl(7 downto 6) <= txd; txen_dl(3) <= txen;
            when "01"   => txd_dl(5 downto 4) <= txd; txen_dl(2) <= txen;
            when "10"   => txd_dl(3 downto 2) <= txd; txen_dl(1) <= txen;
            when others => txd_dl(1 downto 0) <= txd; txen_dl(0) <= txen;
         end case;
      end if;
   end process p_200;

   ---------------------------------------------------------------------------------------------
   -- RX
   ---------------------------------------------------------------------------------------------

   p_rx : process (clk50_i)
      variable v_b : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk50_i) then
         rxd     <= rxd_l;
         crsdv   <= crsdv_l;
         crsdv_1 <= crsdv;
         crsdv_2 <= crsdv_1;

         rx_start_o <= '0';
         rx_valid_o <= '0';
         rx_end_o   <= '0';

         case rs is
            when R_IDLE =>
               if crsdv = '1' and rxd = "01" then
                  rs <= R_PRE;
               end if;

            when R_PRE =>
               if crsdv = '0' then
                  rs <= R_IDLE;
               elsif rxd = "11" then                     -- the end of the SFD
                  rs         <= R_DATA;
                  rx_n       <= "00";
                  rx_crc     <= (others => '1');
                  rx_start_o <= '1';
               elsif rxd /= "01" then
                  rs <= R_SKIP;
               end if;

            when R_DATA =>
               if crsdv = '0' and crsdv_1 = '0' and crsdv_2 = '0' then
                  rs       <= R_IDLE;
                  rx_end_o <= '1';
                  -- the two low samples before took two dibits that were no data: a frame
                  -- that ended on a byte boundary leaves exactly those two behind
                  if rx_n = "10" and rx_crc = C_RESIDUE then
                     rx_ok_o <= '1';
                  else
                     rx_ok_o <= '0';
                  end if;
               else
                  rx_n <= rx_n + 1;
                  if rx_n = "11" then
                     v_b        := rxd & rx_sh;
                     rx_byte_o  <= v_b;
                     rx_valid_o <= '1';
                     rx_crc     <= crc_byte(rx_crc, v_b);
                  else
                     rx_sh <= rxd & rx_sh(5 downto 2);
                  end if;
               end if;

            when R_SKIP =>                               -- junk in the preamble: wait it out
               if crsdv = '0' and crsdv_1 = '0' then
                  rs <= R_IDLE;
               end if;
         end case;

         if rst_i = '1' then
            rs <= R_IDLE;
         end if;
      end if;
   end process p_rx;

   ---------------------------------------------------------------------------------------------
   -- TX
   ---------------------------------------------------------------------------------------------

   tx_addr_o <= tx_ra;
   tx_busy_o <= '0' when ts = T_IDLE else '1';

   p_tx : process (clk50_i)
      variable v_b   : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk50_i) then
         case ts is
            when T_IDLE =>
               txen <= '0';
               txd  <= "00";
               if tx_start_i = '1' then
                  tx_len  <= tx_len_i;
                  tx_dlen <= tx_len_i;
                  if tx_len_i < 60 then
                     tx_len <= to_unsigned(60, 11);
                  end if;
                  tx_i   <= (others => '0');
                  tx_d   <= "00";
                  tx_ra  <= (others => '0');                -- byte 0 is there when the SFD ends
                  ts     <= T_PRE;
               end if;

            when T_PRE =>                                -- 7 x $55, $D5: 31 x 01, then 11
               txen <= '1';
               tx_d <= tx_d + 1;
               if tx_d = "11" then
                  tx_i <= tx_i + 1;
               end if;
               if tx_i = 7 and tx_d = "11" then
                  txd    <= "11";
                  tx_i   <= (others => '0');
                  tx_crc <= (others => '1');
                  ts     <= T_DATA;
               else
                  txd <= "01";
               end if;

            when T_DATA =>
               tx_d <= tx_d + 1;
               if tx_d = "00" then                       -- a new byte (padding past the data)
                  if tx_i < tx_dlen then
                     v_b := tx_data_i;
                  else
                     v_b := x"00";
                  end if;
                  tx_sh  <= "00" & v_b(7 downto 2);
                  txd    <= v_b(1 downto 0);
                  tx_crc <= crc_byte(tx_crc, v_b);
                  tx_ra  <= tx_i + 1;                    -- prefetch the next byte
               else
                  txd   <= tx_sh(1 downto 0);
                  tx_sh <= "00" & tx_sh(7 downto 2);
                  if tx_d = "11" then
                     tx_i <= tx_i + 1;
                     if tx_i = tx_len - 1 then
                        tx_i   <= (others => '0');
                        tx_fcs <= not tx_crc;            -- the CRC over every byte, the last too
                        ts     <= T_FCS;
                     end if;
                  end if;
               end if;

            when T_FCS =>                                -- 4 bytes of not crc, LSB first: 16 dibits
               txd    <= tx_fcs(1 downto 0);
               tx_fcs <= "00" & tx_fcs(31 downto 2);
               tx_i   <= tx_i + 1;
               if tx_i = 15 then
                  tx_i <= (others => '0');
                  ts   <= T_GAP;
               end if;

            when T_GAP =>                                -- 12 byte times = 48 clocks
               txen <= '0';
               txd  <= "00";
               tx_i <= tx_i + 1;
               if tx_i = 47 then
                  ts <= T_IDLE;
               end if;
         end case;

         if rst_i = '1' then
            ts   <= T_IDLE;
            txen <= '0';
         end if;
      end if;
   end process p_tx;

end architecture synthesis;

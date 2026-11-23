----------------------------------------------------------------------------------
-- z486 for MEGA65: the Ethernet port behind the NE2000 (ne2000_z486.sv, ne2k_host.sv)
--
-- MegaMac's mac_eth.vhd (Megamac commit e733c5f), changed for z486MEGA65 (2026-11-23):
-- Megamiga's RMII MAC (eth_mac.vhd), its clocks (eth_clk.vhd: 50 MHz for RMII and the
-- PHY, 200 MHz for the sampling phases) and the station address from the FPGA's DNA
-- (eth_dna.vhd), with the PHY management of Megamiga's eth_card.vhd: the KSZ8081 is
-- held in reset for 10 ms, then told to advertise 100BASE-TX and autonegotiate, and its
-- link is polled every 100 ms. The byte streams are eth_mac's, on clk50_o.
-- Changes: the address is eth_dna's own (02:xx:xx:xx:xx:xx, locally administered: the
-- NE2000 model takes only such an address from its host, ne2k_host.sv); and the PHY setup
-- runs again when enable_i comes on (the menu's network card starts off, so the PHY was in
-- reset when it ran at power-on); and the 100 MHz reaches eth_clk's MMCM through a BUFG: in
-- z486 the board clock's pin already feeds three MMCMs and the QNICE PLL, as many as its
-- dedicated route reaches (the clock regions beside the pin), and a fourth there stopped the
-- placer (Place 30-575).
--
-- Done in 2026 (Megamiga, MegaMac, z486MEGA65) and licensed under GPL v3.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity eth_port is
   generic (
      G_RESET_CYCLES : natural := 500_000;      -- 10 ms at 50 MHz: the PHY's reset
      G_POLL_CYCLES  : natural := 5_000_000;    -- 100 ms between link polls
      G_MDC_DIV      : natural := 16            -- MDC = 50 MHz / 2 / 16 = 1.56 MHz
   );
   port (
      sys_clk_i   : in  std_logic;              -- 100 MHz (the MMCM's input)
      clk50_o     : out std_logic;
      rst50_o     : out std_logic;

      -- PHY (RMII)
      phy_rxd_i   : in  std_logic_vector(1 downto 0);
      phy_crsdv_i : in  std_logic;
      phy_txd_o   : out std_logic_vector(1 downto 0);
      phy_txen_o  : out std_logic;
      phy_mdc_o   : out std_logic;
      phy_mdio_i  : in  std_logic;
      phy_mdio_o  : out std_logic;
      phy_mdio_oe_o : out std_logic;
      phy_reset_n_o : out std_logic;

      phase_i     : in  std_logic_vector(3 downto 0) := "0101";   -- RX sample phase (1:0), TX delay phase (3:2)
      enable_i    : in  std_logic := '1';       -- the menu's Ethernet toggle (sys clock, quasi-static): 0 = the PHY
                                                -- held in reset, no link, no frames in or out
      mac_o       : out std_logic_vector(47 downto 0);
      mac_valid_o : out std_logic;
      link_o      : out std_logic_vector(2 downto 0);              -- link up, 100M, full duplex (clk50)

      -- the streams (clk50_o), eth_mac's
      rx_start_o  : out std_logic;
      rx_valid_o  : out std_logic;
      rx_byte_o   : out std_logic_vector(7 downto 0);
      rx_end_o    : out std_logic;
      rx_ok_o     : out std_logic;
      tx_start_i  : in  std_logic;
      tx_len_i    : in  unsigned(10 downto 0);
      tx_addr_o   : out unsigned(10 downto 0);
      tx_data_i   : in  std_logic_vector(7 downto 0);
      tx_busy_o   : out std_logic
   );
end entity eth_port;

architecture synthesis of eth_port is
   signal clk50, clk200, rst50 : std_logic;
   signal sys_clk_g  : std_logic;                -- the 100 MHz on the global clock network
   signal dna_mac    : std_logic_vector(47 downto 0);
   signal dna_valid  : std_logic;

   -- PHY management
   signal rst_cnt    : natural range 0 to G_RESET_CYCLES := 0;
   signal phy_up     : std_logic := '0';
   type t_mi is (M_WAIT, M_START, M_SHIFT, M_NEXT);
   signal ms         : t_mi := M_WAIT;
   signal m_step     : natural range 0 to 3 := 0;     -- 0: reg 4, 1: reg 0, 2: reg 1, 3: reg $1E
   signal m_div      : natural range 0 to G_MDC_DIV - 1 := 0;
   signal m_mdc      : std_logic := '0';
   signal m_bit      : natural range 0 to 64 := 0;
   signal m_sh       : std_logic_vector(63 downto 0) := (others => '1');
   signal m_rd       : std_logic := '0';
   signal m_in       : std_logic_vector(15 downto 0) := (others => '0');
   signal m_dly      : natural range 0 to G_POLL_CYCLES := 0;
   signal m_mdio_o   : std_logic := '1';
   signal m_mdio_oe  : std_logic := '0';
   signal m_mdio_i   : std_logic := '1';
   signal m_link     : std_logic := '0';
   signal e_link     : std_logic_vector(2 downto 0) := "000";
   signal en_s       : std_logic_vector(1 downto 0) := "00";     -- enable_i into clk50
   signal en_d       : std_logic := '0';
   signal redo       : std_logic := '0';                         -- enable_i came on: set the PHY up again
   signal mac_rx_start, mac_rx_valid, mac_rx_end, mac_rx_ok : std_logic;
begin

   i_bufg_in : BUFG port map (I => sys_clk_i, O => sys_clk_g);

   i_clk : entity work.eth_clk
      port map (
         sys_clk_i => sys_clk_g,
         clk50_o   => clk50,
         clk200_o  => clk200,
         rst50_o   => rst50
      ); -- i_clk
   clk50_o <= clk50;
   rst50_o <= rst50;

   i_dna : entity work.eth_dna
      port map (
         clk_i   => clk50,
         mac_o   => dna_mac,
         valid_o => dna_valid
      ); -- i_dna
   mac_o       <= dna_mac;
   mac_valid_o <= dna_valid;

   i_mac : entity work.eth_mac
      port map (
         clk50_i     => clk50,
         clk200_i    => clk200,
         rst_i       => rst50,
         phy_rxd_i   => phy_rxd_i,
         phy_crsdv_i => phy_crsdv_i,
         phy_txd_o   => phy_txd_o,
         phy_txen_o  => phy_txen_o,
         rx_phase_i  => phase_i(1 downto 0),
         tx_phase_i  => phase_i(3 downto 2),
         rx_start_o  => mac_rx_start,
         rx_valid_o  => mac_rx_valid,
         rx_byte_o   => rx_byte_o,
         rx_end_o    => mac_rx_end,
         rx_ok_o     => mac_rx_ok,
         tx_start_i  => tx_start_i,
         tx_len_i    => tx_len_i,
         tx_addr_o   => tx_addr_o,
         tx_data_i   => tx_data_i,
         tx_busy_o   => tx_busy_o
      ); -- i_mac

   ---------------------------------------------------------------------------------------------
   -- PHY reset and management (MDC/MDIO), as eth_card.vhd
   ---------------------------------------------------------------------------------------------
   phy_reset_n_o <= phy_up and en_s(1);
   phy_mdc_o     <= m_mdc;
   phy_mdio_o    <= m_mdio_o;
   phy_mdio_oe_o <= m_mdio_oe;
   link_o        <= e_link when en_s(1) = '1' else "000";
   rx_start_o    <= mac_rx_start and en_s(1);                -- off: no frames reach the card
   rx_valid_o    <= mac_rx_valid and en_s(1);
   rx_end_o      <= mac_rx_end and en_s(1);
   rx_ok_o       <= mac_rx_ok and en_s(1);

   p_mii : process (clk50)
      variable v_reg  : std_logic_vector(4 downto 0);
      variable v_wr   : std_logic;
      variable v_val  : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk50) then
         m_mdio_i <= phy_mdio_i;
         en_s     <= en_s(0) & enable_i;

         if rst_cnt /= G_RESET_CYCLES then
            rst_cnt <= rst_cnt + 1;
         else
            phy_up <= '1';
         end if;

         case ms is
            when M_WAIT =>                               -- after reset, between polls
               m_mdc <= '0';
               if redo = '1' then                       -- the PHY just left reset: 100 ms,
                  redo   <= '0';                        -- then the two writes again
                  m_step <= 0;
                  m_dly  <= 0;
               elsif phy_up = '1' then
                  if m_dly = G_POLL_CYCLES then
                     m_dly <= 0;
                     ms     <= M_START;
                  else
                     m_dly <= m_dly + 1;
                  end if;
               end if;

            when M_START =>
               case m_step is
                  when 0      => v_reg := "00100"; v_wr := '1'; v_val := x"0181";  -- advertise 100 only
                  when 1      => v_reg := "00000"; v_wr := '1'; v_val := x"3300";  -- AN on, restart
                  when 2      => v_reg := "00001"; v_wr := '0'; v_val := x"FFFF";  -- status
                  when others => v_reg := "11110"; v_wr := '0'; v_val := x"FFFF";  -- PHY control 1
               end case;
               -- 32 x 1, start 01, op (01 write, 10 read), PHY 0, register, TA (10 or Z), data
               m_sh  <= x"FFFFFFFF" & "01" & (not v_wr) & v_wr & "00000" & v_reg & "10" & v_val;
               m_rd  <= not v_wr;
               m_bit <= 64;
               m_div <= 0;
               ms    <= M_SHIFT;

            when M_SHIFT =>                              -- MDIO changes after the falling MDC edge
               if m_div = G_MDC_DIV - 1 then
                  m_div <= 0;
                  m_mdc <= not m_mdc;
                  if m_mdc = '1' then                    -- falling edge: next bit out
                     if m_bit = 0 then
                        m_mdio_oe <= '0';
                        ms        <= M_NEXT;
                     else
                        m_bit     <= m_bit - 1;
                        m_mdio_o  <= m_sh(63);
                        m_sh      <= m_sh(62 downto 0) & '1';
                        -- reads: release MDIO for the turnaround and the data (the last 18 bits)
                        if m_rd = '1' and m_bit <= 18 then
                           m_mdio_oe <= '0';
                        else
                           m_mdio_oe <= '1';
                        end if;
                     end if;
                  else                                   -- rising edge: the PHY drives read data
                     if m_bit < 16 then
                        m_in <= m_in(14 downto 0) & m_mdio_i;
                     end if;
                  end if;
               else
                  m_div <= m_div + 1;
               end if;

            when M_NEXT =>
               ms <= M_WAIT;
               case m_step is
                  when 0 =>
                     m_step <= 1;
                     m_dly <= G_POLL_CYCLES;           -- no pause between the two writes
                  when 1 =>
                     m_step <= 2;
                  when 2 =>
                     m_link <= m_in(2);                 -- link status (latched low: a fall is
                     m_step <= 3;                       -- seen once, then the next poll is fresh)
                     m_dly <= G_POLL_CYCLES;
                  when others =>
                     -- $1E bits 2:0: 001 10 HD, 010 100 HD, 101 10 FD, 110 100 FD
                     e_link(0) <= m_link;
                     e_link(1) <= m_in(1);
                     e_link(2) <= m_in(2);
                     m_step    <= 2;
               end case;
         end case;

         en_d <= en_s(1);
         if en_s(1) = '1' and en_d = '0' then
            redo <= '1';
         end if;
      end if;
   end process p_mii;

end architecture synthesis;

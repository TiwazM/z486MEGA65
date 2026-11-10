----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- fdd_mfm_rx: the internal floppy drive's read data (RDATA) to IBM MFM bytes, for fdd_phys.
--
--   * RDATA (active low, asynchronous): two flip-flops, then its falling edge is a flux
--     transition. An edge closer than C_RUNT to the one before is an electrical glitch and is
--     dropped.
--   * A digital PLL data separator (AExp's physical_fdd_bits, sy2002, GPLv3; there it replaced
--     a gap classifier on old media): a phase counter in sixteenths of a clock wraps once per
--     channel cell and emits one channel bit, '1' if an edge fell into the cell. Every edge
--     pulls the phase half way toward the cell's middle and nudges the cell length by 1/64 of
--     the error, within +/-10 % of nominal. A wild edge costs one bit, never a slip.
--     The cell: 2 us at 250 kbit/s (DD, hd_i = '0'), 1 us at 500 kbit/s (HD); 128 or 64
--     clocks at 64 MHz.
--   * Framing: the channel bits shift into 16 bits; 0x4489 (an A1 data byte with a missing
--     clock bit, which ordinary data never has) is a sync (sync_o) and starts the byte
--     framing; from there every 16 channel bits are a byte (byte_o, byte_valid_o), its data
--     bits the second of each clock/data pair.
--
-- rst_i (a rate or head change, or nothing to read) re-seeds the PLL and drops the framing.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fdd_mfm_rx is
generic (
   G_CLK_HZ     : natural := 64_000_000
);
port (
   clk_i        : in  std_logic;
   rst_i        : in  std_logic;
   hd_i         : in  std_logic;                      -- '1': 500 kbit/s, '0': 250 kbit/s
   rdata_i      : in  std_logic;                      -- the pin (active low, asynchronous)

   sync_o       : out std_logic := '0';               -- pulse: an A1 sync (0x4489)
   byte_valid_o : out std_logic := '0';               -- pulse: byte_o is the next byte
   byte_o       : out std_logic_vector(7 downto 0) := (others => '0');
   edge_o       : out std_logic := '0';               -- pulse: a flux transition (diagnostics)
   cell_o       : out unsigned(12 downto 0)           -- the tracked cell, sixteenths of a clock
);
end entity fdd_mfm_rx;

architecture rtl of fdd_mfm_rx is

   constant C_CELL_DD : natural := G_CLK_HZ / 500_000 * 16;     -- 2 us, Q4
   constant C_CELL_HD : natural := G_CLK_HZ / 1_000_000 * 16;   -- 1 us, Q4
   constant C_RUNT    : natural := G_CLK_HZ / 3_000_000;        -- 333 ns
   constant C_PGAIN   : natural := 1;                           -- phase: err / 2 per edge
   constant C_FGAIN   : natural := 6;                           -- period: err / 64 per edge

   signal rd_m, rd_s, rd_d : std_logic := '1';
   signal runt   : natural range 0 to C_RUNT := 0;

   signal nom    : unsigned(12 downto 0);
   signal cmin   : unsigned(12 downto 0);
   signal cmax   : unsigned(12 downto 0);
   signal phase  : unsigned(13 downto 0) := (others => '0');
   signal cell   : unsigned(12 downto 0) := to_unsigned(C_CELL_DD, 13);
   signal pend   : std_logic := '0';                 -- an edge fell into the current cell

   signal sr     : std_logic_vector(15 downto 0) := (others => '0');
   signal framed : std_logic := '0';                 -- a sync has set the byte framing
   signal bitc   : natural range 0 to 15 := 0;

   attribute async_reg : string;
   attribute async_reg of rd_m, rd_s : signal is "true";

begin

   nom  <= to_unsigned(C_CELL_HD, 13) when hd_i = '1' else to_unsigned(C_CELL_DD, 13);
   cmin <= to_unsigned(C_CELL_HD - C_CELL_HD / 10, 13) when hd_i = '1' else
           to_unsigned(C_CELL_DD - C_CELL_DD / 10, 13);
   cmax <= to_unsigned(C_CELL_HD + C_CELL_HD / 10, 13) when hd_i = '1' else
           to_unsigned(C_CELL_DD + C_CELL_DD / 10, 13);
   cell_o <= cell;

   p_rx : process (clk_i)
      variable v_edge  : boolean;
      variable v_phase : signed(15 downto 0);
      variable v_err   : signed(15 downto 0);
      variable v_cell  : signed(15 downto 0);
      variable v_pend  : std_logic;
      variable v_sr    : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk_i) then
         rd_m <= rdata_i;
         rd_s <= rd_m;
         rd_d <= rd_s;
         sync_o       <= '0';
         byte_valid_o <= '0';
         edge_o       <= '0';

         -- a flux transition: RDATA's falling edge, not a runt
         v_edge := false;
         if runt /= 0 then
            runt <= runt - 1;
         end if;
         if rd_d = '1' and rd_s = '0' and runt = 0 then
            v_edge := true;
            runt   <= C_RUNT;
            edge_o <= '1';
         end if;

         if rst_i = '1' then
            phase  <= (others => '0');
            cell   <= nom;
            pend   <= '0';
            framed <= '0';
            bitc   <= 0;
            sr     <= (others => '0');
         else
            -- the PLL
            v_phase := signed(resize(phase, 16)) + 16;
            v_pend  := pend;
            if v_edge then
               v_pend  := '1';
               v_err   := v_phase - signed(resize(cell(12 downto 1), 16));
               v_phase := v_phase - shift_right(v_err, C_PGAIN);
               v_cell  := signed(resize(cell, 16)) + shift_right(v_err, C_FGAIN);
               if v_cell < signed(resize(cmin, 16)) then
                  cell <= cmin;
               elsif v_cell > signed(resize(cmax, 16)) then
                  cell <= cmax;
               else
                  cell <= unsigned(v_cell(12 downto 0));
               end if;
            end if;
            if v_phase >= signed(resize(cell, 16)) then
               v_phase := v_phase - signed(resize(cell, 16));
               -- one channel bit
               v_sr := sr(14 downto 0) & v_pend;
               sr   <= v_sr;
               v_pend := '0';
               if v_sr = x"4489" then
                  sync_o <= '1';
                  framed <= '1';
                  bitc   <= 0;
               elsif bitc = 15 then
                  bitc <= 0;
                  if framed = '1' then
                     byte_o       <= v_sr(14) & v_sr(12) & v_sr(10) & v_sr(8) &
                                     v_sr(6) & v_sr(4) & v_sr(2) & v_sr(0);
                     byte_valid_o <= '1';
                  end if;
               else
                  bitc <= bitc + 1;
               end if;
            end if;
            if v_phase < 0 then
               v_phase := (others => '0');
            end if;
            phase <= unsigned(v_phase(13 downto 0));
            pend  <= v_pend;
         end if;
      end if;
   end process p_rx;

end architecture rtl;

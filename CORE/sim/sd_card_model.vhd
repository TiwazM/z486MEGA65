----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Simulation only: an SDHC card for tb_sdhost.vhd, in its native mode (1 or 4 data lines,
-- default speed) and in SPI mode, with the behaviour that hardware showed (MEGA65's
-- mega65-core branch 890-sdcard-native, docs/sdcard-native/architecture.md) as knobs:
--
--   G_SPI_LOCKED   the card was put into SPI mode before (an SPI-only controller, a boot
--                  ROM): it does not answer in SD mode until it loses power
--   G_STUCK_READ   the card is in a multi-block read from before (a reset, an FPGA
--                  configuration): it sends blocks whenever clocked and takes only CMD12
--   G_BUSY_LATE    SPI: FF bytes after a write's data response (and after the stop token)
--                  before the busy (00) starts; native: clocks after an R1b response before
--                  DAT0 goes low (the card has 31)
--   G_BUSY_LEN     a write's busy: SPI bytes of 00 / native clocks of DAT0 low
--   G_R1B_LEN      the same after an R1b command (CMD7, CMD12)
--   G_DRESP_LATE   SPI: 1 bits before the data response token (some cards send it a few
--                  bits late)
--
-- A busy card takes no command (it holds DO / DAT0 low; a command sent then is lost). The
-- card counts protocol errors (a bad CRC from the host, a command or a data block it had
-- to drop, a multi-block write left without its stop token) in errors_o.
--
-- Bit timing: the card samples CMD and DAT on the rising edge of the clock and changes its
-- outputs on the falling edge (SPI: mode 0; MISO = DAT0, MOSI = CMD, CS = DAT3).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sd_card_pkg is
   -- the card's contents at power-up: byte i of block b
   function sd_init_byte(b : natural; i : natural) return std_logic_vector;
   function crc7_bit(crc : std_logic_vector(6 downto 0); d : std_logic) return std_logic_vector;
   function crc16_bit(crc : std_logic_vector(15 downto 0); d : std_logic) return std_logic_vector;
end package sd_card_pkg;

package body sd_card_pkg is
   function sd_init_byte(b : natural; i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((b * 7 + i * 13 + 16#5A# + (i / 256) * 3) mod 256, 8));
   end function;

   function crc7_bit(crc : std_logic_vector(6 downto 0); d : std_logic) return std_logic_vector is
      variable c : std_logic_vector(6 downto 0) := crc;
      variable f : std_logic;
   begin
      f := d xor c(6);
      c := c(5 downto 0) & '0';
      if f = '1' then
         c := c xor "0001001";
      end if;
      return c;
   end function;

   function crc16_bit(crc : std_logic_vector(15 downto 0); d : std_logic) return std_logic_vector is
      variable c : std_logic_vector(15 downto 0) := crc;
      variable f : std_logic;
   begin
      f := d xor c(15);
      c := c(14 downto 0) & '0';
      if f = '1' then
         c := c xor x"1021";
      end if;
      return c;
   end function;
end package body sd_card_pkg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sd_card_pkg.all;

entity sd_card_model is
   generic (
      G_SPI_LOCKED  : boolean := false;
      G_STUCK_READ  : boolean := false;
      G_ACMD41_BUSY : natural := 2;      -- ACMD41s answered "still powering up"
      G_NCR         : natural := 1;      -- SPI: FF bytes before a response (1..8)
      G_NAC         : natural := 3;      -- FF bytes (SPI) / clocks (native) before a read block
      G_BUSY_LATE   : natural := 0;
      G_BUSY_LEN    : natural := 40;     -- a write's busy
      G_R1B_LEN     : natural := 40;     -- an R1b command's busy (CMD7, CMD12)
      G_DRESP_LATE  : natural := 0;
      G_BLOCKS      : natural := 64;
      G_DEBUG       : boolean := false   -- report every command
   );
   port (
      clk_i    : in  std_logic;
      cmd_i    : in  std_logic;                       -- the line as it is
      dat_i    : in  std_logic_vector(3 downto 0);
      cmd_o    : out std_logic := '1';
      cmd_oe_o : out std_logic := '0';
      dat_o    : out std_logic_vector(3 downto 0) := "1111";
      dat_oe_o : out std_logic_vector(3 downto 0) := "0000";
      errors_o : out natural := 0;
      spi_o    : out boolean := false;                -- the card is in SPI mode
      writes_o : out natural := 0                     -- blocks written
   );
end entity sd_card_model;

architecture sim of sd_card_model is
begin

   p_card : process
      type t_mem is array (0 to G_BLOCKS * 512 - 1) of std_logic_vector(7 downto 0);
      variable mem : t_mem;

      -- output queues: native CMD (oe & value), native DAT (oe(3:0) & value(3:0)), SPI MISO bits
      constant C_QN : natural := 16384;
      type t_q2 is array (0 to C_QN - 1) of std_logic_vector(1 downto 0);
      type t_q8 is array (0 to C_QN - 1) of std_logic_vector(7 downto 0);
      type t_q1 is array (0 to 65535) of std_logic;
      variable cq : t_q2; variable cq_h, cq_t : natural := 0;
      variable dq : t_q8; variable dq_h, dq_t : natural := 0;
      variable sq : t_q1; variable sq_h, sq_t : natural := 0;
      -- a busy, after what is queued: so many idle clocks (bits), then so many low ones
      variable nb_late, nb_len : natural := 0;          -- native: DAT0
      variable sb_late, sb_len : natural := 0;          -- SPI: MISO bits
      variable cur_oe : std_logic_vector(3 downto 0) := "0000";   -- what the card drives now

      -- card state
      type t_state is (ST_IDLE, ST_READY, ST_IDENT, ST_STBY, ST_TRAN, ST_DATA, ST_RCV);
      variable state    : t_state := ST_IDLE;
      variable spi      : boolean := G_SPI_LOCKED;
      variable stuck    : boolean := G_STUCK_READ;
      variable app      : boolean := false;
      variable acmd41_n : natural := 0;
      variable powered  : boolean := false;
      variable wide     : boolean := false;
      variable errs     : natural := 0;
      variable nwr      : natural := 0;

      -- native command receiver
      variable rx_on    : boolean := false;
      variable rx_n     : natural := 0;
      variable rx_sr    : std_logic_vector(47 downto 0);
      -- multi-block read
      variable rd_multi : boolean := false;
      variable rd_blk   : natural := 0;
      variable rd_on    : boolean := false;
      -- native write receiver
      variable wr_wait  : boolean := false;     -- waiting for a block's start bit
      variable wr_on    : boolean := false;
      variable wr_multi : boolean := false;
      variable wr_blk   : natural := 0;
      variable wr_n     : natural := 0;          -- nibbles / bits received
      type t_blk is array (0 to 511) of std_logic_vector(7 downto 0);
      variable wbuf     : t_blk;
      type t_crc4 is array (0 to 3) of std_logic_vector(15 downto 0);
      variable wcrc     : t_crc4;
      variable rcrc     : t_crc4;

      -- SPI
      variable cs_q     : std_logic := '1';
      variable sbit     : natural := 0;          -- bits since CS went low, mod 8
      variable sbyte    : std_logic_vector(7 downto 0);
      type t_sst is (SP_IDLE, SP_CMD, SP_TOKEN, SP_DATA, SP_STREAM);
      variable sst      : t_sst := SP_IDLE;
      type t_bytes is array (0 to 5) of std_logic_vector(7 downto 0);
      variable scmd     : t_bytes;
      variable sn       : natural := 0;
      variable s_multi  : boolean := false;
      variable s_blk    : natural := 0;
      variable s_crc    : std_logic_vector(15 downto 0);

      variable v_idx    : natural;
      variable v_arg    : std_logic_vector(31 downto 0);
      variable v_crc7   : std_logic_vector(6 downto 0);
      variable v_crc16  : std_logic_vector(15 downto 0);
      variable v_b      : std_logic_vector(7 downto 0);
      variable v_e      : std_logic_vector(7 downto 0);

      -- queues --------------------------------------------------------------------------
      procedure cq_push(oe : std_logic; v : std_logic) is
      begin
         cq(cq_t) := oe & v;
         cq_t := (cq_t + 1) mod C_QN;
      end procedure;
      impure function cq_len return natural is
      begin
         return (cq_t + C_QN - cq_h) mod C_QN;
      end function;
      procedure dq_push(oe : std_logic_vector(3 downto 0); v : std_logic_vector(3 downto 0)) is
      begin
         dq(dq_t) := oe & v;
         dq_t := (dq_t + 1) mod C_QN;
      end procedure;
      impure function dq_len return natural is
      begin
         return (dq_t + C_QN - dq_h) mod C_QN;
      end function;
      procedure sq_push_bit(v : std_logic) is
      begin
         sq(sq_t) := v;
         sq_t := (sq_t + 1) mod 65536;
      end procedure;
      procedure sq_push(b : std_logic_vector(7 downto 0)) is
      begin
         for k in 7 downto 0 loop
            sq_push_bit(b(k));
         end loop;
      end procedure;
      impure function sq_len return natural is
      begin
         return (sq_t + 65536 - sq_h) mod 65536;
      end function;

      -- native responses ---------------------------------------------------------------
      -- 48 bits: 0, 0, index (6), 32 bits, CRC7 (or 1111111 for R3), 1; after Ncr = 2 clocks
      procedure resp48(idx : natural; arg : std_logic_vector(31 downto 0); r3 : boolean) is
         variable f : std_logic_vector(39 downto 0);
         variable c : std_logic_vector(6 downto 0) := (others => '0');
      begin
         if r3 then
            f := "00" & "111111" & arg;
         else
            f := "00" & std_logic_vector(to_unsigned(idx, 6)) & arg;
         end if;
         for k in 1 to 2 loop cq_push('0', '1'); end loop;
         for k in 39 downto 0 loop
            cq_push('1', f(k));
            c := crc7_bit(c, f(k));
         end loop;
         if r3 then
            c := "1111111";
         end if;
         for k in 6 downto 0 loop cq_push('1', c(k)); end loop;
         cq_push('1', '1');
      end procedure;
      -- R2: 0, 0, 111111, 120 bits of CID/CSD and its CRC7, 1
      procedure resp136 is
      begin
         for k in 1 to 2 loop cq_push('0', '1'); end loop;
         cq_push('1', '0'); cq_push('1', '0');
         for k in 1 to 6 loop cq_push('1', '1'); end loop;
         for k in 1 to 127 loop cq_push('1', std_logic(to_unsigned(k * 5 mod 7, 3)(0))); end loop;
         cq_push('1', '1');
      end procedure;
      -- a busy on DAT0 after an R1b: idle until the response is out, G_BUSY_LATE clocks, then
      -- G_BUSY_LEN clocks low
      procedure busy_native(n_after : natural) is
      begin
         for k in 1 to n_after loop
            dq_push("0000", "1111");
         end loop;
         nb_late := G_BUSY_LATE;
         nb_len  := G_R1B_LEN;
      end procedure;
      constant C_STAT : std_logic_vector(31 downto 0) := x"00000900";   -- tran, ready for data

      -- a read block (native): G_NAC clocks idle, start bit, 1024 nibbles (or 4096 bits on
      -- DAT0), the CRC16 of each line, end bit
      procedure push_block_native(b : natural) is
         variable c   : t_crc4 := (others => (others => '0'));
         variable nib : std_logic_vector(3 downto 0);
         variable oe  : std_logic_vector(3 downto 0);
         variable byt : std_logic_vector(7 downto 0);
      begin
         if wide then oe := "1111"; else oe := "0001"; end if;
         for k in 1 to G_NAC loop dq_push("0000", "1111"); end loop;
         dq_push(oe, "0000");
         for i in 0 to 511 loop
            byt := mem((b mod G_BLOCKS) * 512 + i);
            if wide then
               for h in 1 downto 0 loop
                  nib := byt(4 * h + 3 downto 4 * h);
                  dq_push(oe, nib);
                  for l in 0 to 3 loop c(l) := crc16_bit(c(l), nib(l)); end loop;
               end loop;
            else
               for k in 7 downto 0 loop
                  dq_push(oe, "111" & byt(k));
                  c(0) := crc16_bit(c(0), byt(k));
               end loop;
            end if;
         end loop;
         for k in 15 downto 0 loop
            dq_push(oe, c(3)(k) & c(2)(k) & c(1)(k) & c(0)(k));
         end loop;
         dq_push(oe, "1111");
      end procedure;

      -- an SPI read block: G_NAC FF bytes, FE, 512 bytes, CRC16
      procedure push_block_spi(b : natural) is
         variable c : std_logic_vector(15 downto 0) := (others => '0');
      begin
         for k in 1 to G_NAC loop sq_push(x"FF"); end loop;
         sq_push(x"FE");
         for i in 0 to 511 loop
            sq_push(mem((b mod G_BLOCKS) * 512 + i));
            for k in 7 downto 0 loop c := crc16_bit(c, mem((b mod G_BLOCKS) * 512 + i)(k)); end loop;
         end loop;
         sq_push(c(15 downto 8));
         sq_push(c(7 downto 0));
      end procedure;
      -- an SPI response: G_NCR FF bytes, then the bytes
      procedure spi_r1(r1 : std_logic_vector(7 downto 0)) is
      begin
         for k in 1 to G_NCR loop sq_push(x"FF"); end loop;
         sq_push(r1);
      end procedure;
      -- an SPI busy: G_BUSY_LATE FF bytes, then G_BUSY_LEN bytes of 00
      procedure busy_spi(len : natural) is
      begin
         sb_late := 8 * G_BUSY_LATE;
         sb_len  := 8 * len;
      end procedure;

      procedure err(msg : string) is
      begin
         errs := errs + 1;
         report "sd card: " & msg severity warning;
      end procedure;

      -- a native command ------------------------------------------------------------------
      procedure native_cmd(sr : std_logic_vector(47 downto 0)) is
         variable c   : std_logic_vector(6 downto 0) := (others => '0');
         variable idx : natural;
         variable arg : std_logic_vector(31 downto 0);
         variable was_app : boolean;
      begin
         for k in 47 downto 8 loop c := crc7_bit(c, sr(k)); end loop;
         idx := to_integer(unsigned(sr(45 downto 40)));
         arg := sr(39 downto 8);
         if G_DEBUG then
            report "sd card: native CMD" & integer'image(idx) & " " & to_hstring(arg) & " stuck " & boolean'image(stuck);
         end if;
         if c /= sr(7 downto 1) or sr(0) /= '1' then
            err("native CMD" & integer'image(idx) & ": bad CRC7 or end bit");
            return;
         end if;
         if stuck then
            if idx = 12 then
               stuck := false;
               rd_on := false;
               dq_h := dq_t;                     -- the transfer stops
               state := ST_TRAN;
               resp48(12, C_STAT, false);
               busy_native(50);
            end if;
            return;
         end if;
         if nb_late + nb_len > 0 then
            err("native CMD" & integer'image(idx) & " while busy: lost");
            return;
         end if;
         was_app := app;
         app := false;
         if was_app and idx = 41 then
            acmd41_n := acmd41_n + 1;
            if acmd41_n > G_ACMD41_BUSY then
               powered := true;
               state := ST_READY;
               resp48(41, x"C0FF8000", true);        -- powered up, CCS (SDHC)
            else
               resp48(41, x"40FF8000", true);
            end if;
            return;
         end if;
         if was_app and idx = 6 then
            wide := arg(1 downto 0) = "10";
            resp48(6, C_STAT, false);
            return;
         end if;
         case idx is
            when 0 =>
               state := ST_IDLE; powered := false; acmd41_n := 0; wide := false;
               rd_on := false; wr_wait := false; wr_on := false;
               dq_h := dq_t;
               if dat_i(3) = '0' then
                  spi := true;                    -- CS low: SPI mode until power is lost
                  sst := SP_IDLE;
                  spi_r1(x"01");
               end if;
            when 8 =>
               resp48(8, x"00000" & "0001" & arg(7 downto 0), false);
            when 55 =>
               app := true;
               resp48(55, C_STAT or x"00000020", false);
            when 2 =>
               state := ST_IDENT; resp136;
            when 3 =>
               state := ST_STBY; resp48(3, x"1234" & x"0500", false);
            when 9 =>
               resp136;
            when 7 =>
               state := ST_TRAN;
               resp48(7, C_STAT, false);
               busy_native(50);
            when 13 =>
               resp48(13, C_STAT, false);
            when 16 =>
               resp48(16, C_STAT, false);
            when 12 =>
               if rd_on then
                  rd_on := false;
                  dq_h := dq_t;                   -- the transfer stops
               end if;
               wr_wait := false;
               state := ST_TRAN;
               resp48(12, C_STAT, false);
               busy_native(50);
            when 17 | 18 =>
               resp48(idx, C_STAT, false);
               rd_multi := idx = 18;
               rd_blk := to_integer(unsigned(arg));
               rd_on := true;
               for k in 1 to 50 loop dq_push("0000", "1111"); end loop;   -- after the response
               push_block_native(rd_blk);
               rd_blk := rd_blk + 1;
               if not rd_multi then rd_on := false; end if;
            when 24 | 25 =>
               resp48(idx, C_STAT, false);
               wr_multi := idx = 25;
               wr_blk := to_integer(unsigned(arg));
               wr_wait := true;
            when 6 =>
               err("CMD6 (switch) not modelled");
            when others =>
               err("native CMD" & integer'image(idx) & " not modelled");
         end case;
      end procedure;

      -- an SPI command --------------------------------------------------------------------
      procedure spi_cmd is
         variable idx : natural;
         variable arg : std_logic_vector(31 downto 0);
         variable c   : std_logic_vector(6 downto 0) := (others => '0');
         variable r1  : std_logic_vector(7 downto 0);
         variable was_app : boolean;
      begin
         idx := to_integer(unsigned(scmd(0)(5 downto 0)));
         arg := scmd(1) & scmd(2) & scmd(3) & scmd(4);
         if G_DEBUG then
            report "sd card: SPI CMD" & integer'image(idx) & " " & to_hstring(arg) & " crc " & to_hstring(scmd(5));
         end if;
         for b in 0 to 4 loop
            for k in 7 downto 0 loop c := crc7_bit(c, scmd(b)(k)); end loop;
         end loop;
         if c /= scmd(5)(7 downto 1) or scmd(5)(0) /= '1' then
            err("SPI CMD" & integer'image(idx) & ": bad CRC7");
            spi_r1(x"09");
            return;
         end if;
         if powered then r1 := x"00"; else r1 := x"01"; end if;
         was_app := app;
         app := false;
         if was_app and idx = 41 then
            acmd41_n := acmd41_n + 1;
            if acmd41_n > G_ACMD41_BUSY then
               powered := true;
               spi_r1(x"00");
            else
               spi_r1(x"01");
            end if;
            return;
         end if;
         case idx is
            when 0 =>
               powered := false; acmd41_n := 0;
               spi_r1(x"01");
            when 8 =>
               spi_r1(r1); sq_push(x"00"); sq_push(x"00"); sq_push(x"01"); sq_push(arg(7 downto 0));
            when 55 =>
               app := true; spi_r1(r1);
            when 58 =>
               spi_r1(r1); sq_push(x"C0"); sq_push(x"FF"); sq_push(x"80"); sq_push(x"00");
            when 59 | 16 =>
               spi_r1(r1);
            when 13 =>
               spi_r1(r1); sq_push(x"00");
            when 17 | 18 =>
               spi_r1(x"00");
               s_multi := idx = 18;
               s_blk := to_integer(unsigned(arg));
               push_block_spi(s_blk);
               s_blk := s_blk + 1;
               if s_multi then sst := SP_STREAM; end if;
            when 24 | 25 =>
               spi_r1(x"00");
               s_multi := idx = 25;
               s_blk := to_integer(unsigned(arg));
               sst := SP_TOKEN;
            when 12 =>
               spi_r1(x"00");
               busy_spi(G_R1B_LEN);
            when others =>
               err("SPI CMD" & integer'image(idx) & " not modelled");
               spi_r1(x"04");
         end case;
      end procedure;

      -- an SPI byte from the host (sampled while CS is low)
      procedure spi_byte(b : std_logic_vector(7 downto 0)) is
      begin
         if sb_late + sb_len > 0 then
            if sst = SP_IDLE and b(7 downto 6) = "01" then
               err("SPI CMD" & integer'image(to_integer(unsigned(b(5 downto 0)))) & " while busy: lost");
            elsif sst = SP_TOKEN and b /= x"FF" then
               err("SPI token " & to_hstring(b) & " while busy: lost");
            end if;
            return;
         end if;
         case sst is
            when SP_IDLE =>
               if b(7 downto 6) = "01" then
                  scmd(0) := b; sn := 1; sst := SP_CMD;
               end if;
            when SP_STREAM =>
               if b(7 downto 6) = "01" then
                  scmd(0) := b; sn := 1; sst := SP_CMD;
               end if;
            when SP_CMD =>
               scmd(sn) := b;
               sn := sn + 1;
               if sn = 6 then
                  if s_multi and to_integer(unsigned(scmd(0)(5 downto 0))) = 12 then
                     -- CMD12 during a multi-block read: the stream stops (a stuff byte)
                     sq_h := sq_t;
                     sq_push(x"FF");
                     s_multi := false;
                  end if;
                  sst := SP_IDLE;
                  spi_cmd;
               end if;
            when SP_TOKEN =>
               if b = x"FE" and not s_multi then
                  sst := SP_DATA; sn := 0; s_crc := (others => '0');
               elsif b = x"FC" and s_multi then
                  sst := SP_DATA; sn := 0; s_crc := (others => '0');
               elsif b = x"FD" and s_multi then
                  sq_push(x"FF");                  -- the byte after the stop token
                  busy_spi(G_BUSY_LEN);
                  s_multi := false;
                  sst := SP_IDLE;
               elsif b /= x"FF" then
                  err("SPI write: token " & to_hstring(b));
               end if;
            when SP_DATA =>
               if sn < 512 then
                  wbuf(sn) := b;
                  for k in 7 downto 0 loop s_crc := crc16_bit(s_crc, b(k)); end loop;
               elsif sn = 512 then
                  v_e := b;
               else
                  if s_crc /= v_e & b then
                     err("SPI write: bad CRC16");
                     for k in 1 to G_DRESP_LATE loop sq_push_bit('1'); end loop;
                     sq_push(x"EB");                 -- xxx0 101 1: CRC error
                  else
                     for i in 0 to 511 loop mem((s_blk mod G_BLOCKS) * 512 + i) := wbuf(i); end loop;
                     nwr := nwr + 1;
                     for k in 1 to G_DRESP_LATE loop sq_push_bit('1'); end loop;
                     sq_push(x"E5");                 -- xxx0 010 1: accepted
                  end if;
                  busy_spi(G_BUSY_LEN);
                  s_blk := s_blk + 1;
                  if s_multi then sst := SP_TOKEN; else sst := SP_IDLE; end if;
               end if;
               sn := sn + 1;
            when others => null;
         end case;
      end procedure;

   begin
      for b in 0 to G_BLOCKS - 1 loop
         for i in 0 to 511 loop mem(b * 512 + i) := sd_init_byte(b, i); end loop;
      end loop;
      if G_STUCK_READ then
         rd_on := true; rd_multi := true; rd_blk := 40; wide := true;
      end if;

      loop
         wait on clk_i, dat_i(3);
         spi_o <= spi;

         ------------------------------------------------------------------------------------
         -- SPI
         ------------------------------------------------------------------------------------
         if spi then
            if dat_i(3) /= cs_q then
               if dat_i(3) = '0' then
                  sbit := 0;
                  dat_o(0) <= '1';
                  dat_oe_o <= "0001";
               else
                  if sst = SP_DATA or (sst = SP_TOKEN and s_multi) then
                     err("SPI: CS high in the middle of a write (no stop token)");
                     sst := SP_IDLE; s_multi := false;
                  end if;
                  dat_oe_o <= "0000";
               end if;
               cs_q := dat_i(3);
            end if;
            if dat_i(3) = '0' and clk_i'event and clk_i = '1' then
               sbyte := sbyte(6 downto 0) & cmd_i;
               sbit := sbit + 1;
               if sbit = 8 then
                  sbit := 0;
                  spi_byte(sbyte);
               end if;
            elsif dat_i(3) = '0' and clk_i'event and clk_i = '0' then
               -- the next bit out (for the host's next sample), taken off the queue
               if sst = SP_STREAM and sq_len < 64 then
                  push_block_spi(s_blk);
                  s_blk := s_blk + 1;
               end if;
               if sq_len > 0 then
                  dat_o(0) <= sq(sq_h);
                  sq_h := (sq_h + 1) mod 65536;
               elsif sb_late > 0 then
                  dat_o(0) <= '1';
                  sb_late := sb_late - 1;
               elsif sb_len > 0 then
                  dat_o(0) <= '0';
                  sb_len := sb_len - 1;
               else
                  dat_o(0) <= '1';
               end if;
            end if;

         ------------------------------------------------------------------------------------
         -- native
         ------------------------------------------------------------------------------------
         elsif clk_i'event and clk_i = '1' then
            -- a write block coming in
            if wr_on then
               if wide then
                  if wr_n < 1024 then
                     v_b := wbuf(wr_n / 2);
                     if wr_n mod 2 = 0 then v_b(7 downto 4) := dat_i; else v_b(3 downto 0) := dat_i; end if;
                     wbuf(wr_n / 2) := v_b;
                     for l in 0 to 3 loop wcrc(l) := crc16_bit(wcrc(l), dat_i(l)); end loop;
                  elsif wr_n < 1040 then
                     for l in 0 to 3 loop rcrc(l) := rcrc(l)(14 downto 0) & dat_i(l); end loop;
                  end if;
                  wr_n := wr_n + 1;
                  if wr_n = 1041 then
                     wr_on := false;
                     if wcrc /= rcrc or dat_i /= "1111" then
                        err("native write: bad CRC16 or end bit");
                        for k in 1 to 2 loop dq_push("0000", "1111"); end loop;
                        dq_push("0001", "0000"); dq_push("0001", "0101"); dq_push("0001", "0000");
                        dq_push("0001", "0001"); dq_push("0001", "0001");   -- 0 101 1: CRC error
                     else
                        for i in 0 to 511 loop mem((wr_blk mod G_BLOCKS) * 512 + i) := wbuf(i); end loop;
                        nwr := nwr + 1;
                        for k in 1 to 2 loop dq_push("0000", "1111"); end loop;
                        dq_push("0001", "0000");
                        dq_push("0001", "0000"); dq_push("0001", "0001"); dq_push("0001", "0000");
                        dq_push("0001", "0001");                             -- 0 010 1: accepted
                     end if;
                     nb_late := 0;
                     nb_len  := G_BUSY_LEN;
                     wr_blk := wr_blk + 1;
                     wr_wait := wr_multi;
                  end if;
               else
                  err("native write on one data line: not modelled");
                  wr_on := false;
               end if;
            elsif wr_wait and dq_len = 0 and nb_late + nb_len = 0 and cur_oe = "0000" and
                  ((wide and dat_i = "0000") or (not wide and dat_i(0) = '0')) then
               wr_on := true; wr_wait := false; wr_n := 0;
               wcrc := (others => (others => '0'));
               rcrc := (others => (others => '0'));
            elsif wr_wait and dq_len = 0 and nb_late + nb_len = 0 and cur_oe = "0000" and wide and dat_i(0) = '0' then
               err("native write: DAT0 low alone (not a block start)");
            end if;

            -- the CMD line: a command from the host (not while the card answers)
            if cq_len = 0 then
               if rx_on then
                  rx_sr := rx_sr(46 downto 0) & cmd_i;
                  rx_n := rx_n + 1;
                  if rx_n = 48 then
                     rx_on := false;
                     if not spi and not G_SPI_LOCKED then
                        native_cmd(rx_sr);
                     end if;
                  end if;
               elsif cmd_i = '0' then
                  rx_on := true; rx_n := 1;
                  rx_sr := (others => '0');
               end if;
            end if;

         elsif clk_i'event and clk_i = '0' then
            -- outputs: the CMD line
            if cq_len > 0 then
               cmd_oe_o <= cq(cq_h)(1);
               cmd_o    <= cq(cq_h)(0);
               cq_h := (cq_h + 1) mod C_QN;
            else
               cmd_oe_o <= '0';
               cmd_o    <= '1';
            end if;
            -- the data lines (a multi-block read goes on while clocked)
            if rd_on and rd_multi and dq_len < 8 then
               for k in 1 to 2 loop dq_push("0000", "1111"); end loop;
               push_block_native(rd_blk);
               rd_blk := rd_blk + 1;
            end if;
            if dq_len > 0 then
               v_e := dq(dq_h);
               cur_oe := v_e(7 downto 4);
               dat_oe_o <= v_e(7 downto 4);
               dat_o    <= v_e(3 downto 0);
               dq_h := (dq_h + 1) mod C_QN;
            elsif nb_late > 0 then
               nb_late := nb_late - 1;
               cur_oe := "0000";
               dat_oe_o <= "0000";
               dat_o    <= "1111";
            elsif nb_len > 0 then
               nb_len := nb_len - 1;
               cur_oe := "0001";
               dat_oe_o <= "0001";
               dat_o    <= "1110";
            else
               cur_oe := "0000";
               dat_oe_o <= "0000";
               dat_o    <= "1111";
            end if;
         end if;

         errors_o <= errs;
         writes_o <= nwr;
      end loop;
   end process p_card;

end architecture sim;

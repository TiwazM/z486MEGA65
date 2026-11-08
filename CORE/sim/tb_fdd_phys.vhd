----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- tb_fdd_phys: fdd_phys.vhd and fdd_sound.vhd (the internal drive as the PC's A:) against a
-- model of a 3.5" drive with a disk: the head steps on STEP while selected (TRACK0 at
-- cylinder 0), the disk turns at 300 rpm while the motor runs (an index pulse each turn),
-- and each turn the track under the head comes out of RDATA as IBM MFM: gap 4a, IAM, gap 1,
-- then the sectors (ID field, gap 2, data field, gap 3), the rest 4E. Each flux transition
-- is a 200 ns low pulse at the middle of its cell, moved by a pseudo-random jitter of up to
-- jit percent of a cell, the whole disk turning spd percent fast or slow. The data of
-- cylinder c, head h, sector r, byte i is (7c + 13h + 17r + i) mod 256.
--
-- The PC side does what pc_mgmt and floppy.v do: A:'s motor on, floppy.v's cylinder the
-- request's, the request, the answer, then the slot read out in a row (checked byte for
-- byte, and buf_bad after it).
--
-- Writes: while WGATE is low the model notes each WDATA pulse's cell (from the gate's opening,
-- at the nominal rate), then decodes the field (3 syncs, FB, 512 bytes, the CRC), checks that
-- it began in the sector's gap 2 (22 bytes after its ID field, +/-4), and from the next turn
-- that sector holds the written bytes (a broken field: a data CRC error). The data written is
-- the read pattern xor A5.
--
-- FORMAT: a write of more than 30000 cells is a whole track: the model decodes it (the index
-- address mark, every ID field and data field with their CRCs, the filler), checks that it
-- began within 40 bytes after the index and ended within 40 bytes after the next one, and from
-- then on the track is the one written (its IDs, gap 3 and filler; a sector written later over
-- it as above). The PC side hands the IDs over as pc_mgmt does (req_fmt).
--
-- The clock is 32 MHz (G_CLK_HZ): the cells are 32 (HD) and 64 (DD) clocks.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fdd_phys is
generic (
   G_WRITES_ONLY : boolean := false               -- the write tests alone (quicker)
);
end entity tb_fdd_phys;

architecture sim of tb_fdd_phys is

   constant C_HZ   : natural := 32_000_000;
   constant C_CLK  : time := 1 sec / C_HZ;

   signal clk      : std_logic := '0';
   signal rst      : std_logic := '1';
   signal done_sim : boolean := false;

   -- the PC side
   signal pc_motor : std_logic_vector(1 downto 0) := "00";
   signal pc_cyl0  : std_logic_vector(7 downto 0) := x"00";
   signal req      : std_logic := '0';
   signal req_wr   : std_logic := '0';
   signal req_fresh : std_logic := '0';
   signal req_c    : std_logic_vector(7 downto 0) := x"00";
   signal req_h    : std_logic := '0';
   signal req_r    : std_logic_vector(6 downto 0) := "0000001";
   signal req_fmt  : std_logic_vector(63 downto 0) := (others => '0');
   signal done     : std_logic;
   signal err      : std_logic_vector(15 downto 0);
   signal buf_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal buf_rd   : std_logic_vector(7 downto 0);
   signal buf_bad  : std_logic;
   signal dskchg   : std_logic;
   signal wp       : std_logic;
   signal stat     : std_logic_vector(255 downto 0);

   -- the pins
   signal sel_n, motor_n, step_n, dir, side1_n, wdata_n, wgate_n : std_logic;
   signal trk0_n, index_n, chg_n, rdata_n : std_logic := '1';
   signal wprot_n  : std_logic := '0';          -- the tab: write protected
   signal wbuf_we  : std_logic := '0';
   signal wbuf_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal wbuf_wd  : std_logic_vector(7 downto 0) := (others => '0');

   -- fdd_sound <-> fdd_phys
   signal s_sel_ok, s_sel_fast, s_idx_n, s_chg_n, s_motor, s_ready, s_recal : std_logic;
   signal s_cyl    : std_logic_vector(6 downto 0);

   -- the drive
   signal head      : integer := 20;
   signal head_jump : integer := -1;
   signal disk_in   : boolean := true;
   signal disk_hd   : boolean := true;          -- 500 kbit/s, 18 sectors; else 250, 9
   signal bad_crc   : boolean := true;          -- cylinder 5, head 1, sector 3: data CRC wrong
   signal chg_latch : boolean := true;
   signal spd       : integer := 0;             -- percent
   signal jit       : integer := 10;            -- percent of a cell, peak
   signal ejected   : boolean := false;
   signal idx_now   : std_logic := '1';
   signal rd_now    : std_logic := '1';

   signal errors   : natural := 0;
   signal wr_errors : natural := 0;              -- p_wcap's

   type t_bytes is array (natural range <>) of natural range 0 to 255;

   -- what the model was written: the sector and its bytes (ok: the field decoded right)
   type t_ovr is record
      valid : boolean;
      ok    : boolean;
      c, h, r : natural;
      d     : t_bytes(0 to 511);
   end record;
   type t_ovrs is array (0 to 7) of t_ovr;
   signal ovr      : t_ovrs := (others => (false, false, 0, 0, 0, (others => 0)));
   signal pos_k    : natural := 0;               -- the byte of the track under the head

   -- formatted tracks (FORMAT): their IDs (C, H as the first ID's), filler, gap 3
   type t_ftr is record
      valid : boolean;
      c, h  : natural;                           -- the track (the head's cylinder, side)
      idc, idh : natural;
      n     : natural;
      r     : t_bytes(0 to 39);
      fill  : natural;
      gap3  : natural;
   end record;
   type t_ftrs is array (0 to 3) of t_ftr;
   signal ftr      : t_ftrs := (others => (false, 0, 0, 0, 0, 0, (others => 0), 0, 0));
   signal ftr_gen  : natural := 0;               -- changes when a track is formatted
   signal fmt_errors : natural := 0;             -- p_wcap's for tracks
   signal pos_c, pos_h : natural := 0;

   function crc_upd(c : unsigned(15 downto 0); b : natural) return unsigned is
      variable v : unsigned(15 downto 0) := c;
      variable d : unsigned(7 downto 0) := to_unsigned(b, 8);
      variable x : std_logic;
   begin
      for i in 7 downto 0 loop
         x := v(15) xor d(i);
         v := v(14 downto 0) & '0';
         if x = '1' then
            v := v xor x"1021";
         end if;
      end loop;
      return v;
   end function crc_upd;

   function pat(c, h, r, i : natural) return natural is
   begin
      return (7 * c + 13 * h + 17 * r + i) mod 256;
   end function pat;

   function pat2(c, h, r, i : natural) return natural is       -- what the tests write
   begin
      return to_integer(to_unsigned(pat(c, h, r, i), 8) xor x"A5");
   end function pat2;

begin

   clk <= not clk after C_CLK / 2 when not done_sim;

   i_snd : entity work.fdd_sound
      generic map (
         G_CLK_HZ    => C_HZ
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         enable_i    => '1',
         phys_i      => '1',
         phys_drv_i  => '0',
         recal_i     => s_recal,
         pc_motor_i  => pc_motor,
         pc_sel_i    => '0',
         pc_cyl0_i   => pc_cyl0,
         pc_cyl1_i   => x"00",
         f_selecta_o => sel_n,
         f_motora_o  => motor_n,
         f_step_o    => step_n,
         f_stepdir_o => dir,
         f_track0_i  => trk0_n,
         f_index_i   => index_n,
         f_diskchg_i => chg_n,
         sel_ok_o    => s_sel_ok,
         sel_fast_o  => s_sel_fast,
         idx_n_o     => s_idx_n,
         chg_n_o     => s_chg_n,
         motor_o     => s_motor,
         ready_o     => s_ready,
         cyl_o       => s_cyl,
         disk_o      => open,
         idx_off_o   => open,
         fault_o     => open
      );

   i_phys : entity work.fdd_phys
      generic map (
         G_CLK_HZ     => C_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         enable_i     => '1',
         f_rdata_i    => rdata_n,
         f_wprot_i    => wprot_n,
         f_side1_o    => side1_n,
         f_wdata_o    => wdata_n,
         f_wgate_o    => wgate_n,
         sel_ok_i     => s_sel_ok,
         sel_fast_i   => s_sel_fast,
         idx_n_i      => s_idx_n,
         chg_n_i      => s_chg_n,
         motor_i      => s_motor,
         head_cyl_i   => s_cyl,
         head_ready_i => s_ready,
         recal_o      => s_recal,
         req_i        => req,
         req_wr_i     => req_wr,
         req_fresh_i  => req_fresh,
         req_c_i      => req_c,
         req_h_i      => req_h,
         req_r_i      => req_r,
         req_fmt_i    => req_fmt,
         done_o       => done,
         err_o        => err,
         buf_addr_i   => buf_addr,
         buf_rd_o     => buf_rd,
         buf_bad_o    => buf_bad,
         wbuf_we_i    => wbuf_we,
         wbuf_addr_i  => wbuf_addr,
         wbuf_wd_i    => wbuf_wd,
         dskchg_o     => dskchg,
         wp_o         => wp,
         stat_o       => stat
      );

   -- the drive's outputs: open collector, while selected
   trk0_n  <= '0' when sel_n = '0' and head = 0 else '1';
   chg_n   <= '0' when sel_n = '0' and chg_latch else '1';
   index_n <= idx_now when sel_n = '0' else '1';
   rdata_n <= rd_now when sel_n = '0' else '1';

   p_head : process (step_n, head_jump, ejected)
   begin
      if head_jump'event and head_jump >= 0 then
         head <= head_jump;
      end if;
      if ejected'event and ejected then
         chg_latch <= true;
      end if;
      if falling_edge(step_n) and sel_n = '0' then
         if dir = '1' then
            if head > 0 then
               head <= head - 1;
            end if;
         elsif head < 83 then
            head <= head + 1;
         end if;
         if disk_in then
            chg_latch <= false;
         end if;
      end if;
   end process p_head;

   -- the disk turning: a track per turn, from the index
   p_disk : process
      variable v_trk  : t_bytes(0 to 12499);
      variable v_n    : natural;
      variable v_c, v_h, v_spt, v_gap3, v_len : natural;
      variable v_crc  : unsigned(15 downto 0);
      variable v_cell : time;
      variable v_rev  : time;
      variable v_t0   : time;
      variable v_prev : std_logic;
      variable v_bits : std_logic_vector(15 downto 0);
      variable v_d    : unsigned(7 downto 0);
      variable v_rng  : unsigned(31 downto 0) := x"12345678";
      variable v_j    : integer;
      variable v_sync : t_bytes(0 to 12499);     -- 1 = A1 sync, 2 = C2 sync
      variable v_o    : integer;
      variable v_gen  : natural := 0;

      procedure put(b : natural; k : natural := 0) is
      begin
         v_trk(v_n)  := b;
         v_sync(v_n) := k;
         v_n := v_n + 1;
      end procedure put;
      -- the track under the head now (v_c, v_h): its bytes and syncs
      procedure build is
         variable v_f : integer;
         variable v_r : natural;
      begin
               v_c := head;
               v_h := 0;
               if side1_n = '0' then
                  v_h := 1;
               end if;
               if disk_hd then
                  v_spt := 18; v_gap3 := 84; v_len := 12500; v_cell := 1 us;
               else
                  v_spt := 9;  v_gap3 := 80; v_len := 6250;  v_cell := 2 us;
               end if;
               v_cell := v_cell * 100 / (100 + spd);
               v_gen := ftr_gen;
               v_f := -1;
               for j in ftr'range loop
                  if ftr(j).valid and ftr(j).c = v_c and ftr(j).h = v_h then
                     v_f := j;
                  end if;
               end loop;
               v_n := 0;
               for i in 1 to 80 loop put(16#4E#); end loop;
               for i in 1 to 12 loop put(0); end loop;
               for i in 1 to 3 loop put(16#C2#, 2); end loop;
               put(16#FC#);
               for i in 1 to 50 loop put(16#4E#); end loop;
               if v_f >= 0 then
                  v_spt := ftr(v_f).n;
                  v_gap3 := ftr(v_f).gap3;
               end if;
               for k in 1 to v_spt loop
                  v_r := k;
                  if v_f >= 0 then
                     v_r := ftr(v_f).r(k - 1);
                  end if;
                  for i in 1 to 12 loop put(0); end loop;
                  for i in 1 to 3 loop put(16#A1#, 1); end loop;
                  v_crc := x"CDB4";
                  put(16#FE#); v_crc := crc_upd(v_crc, 16#FE#);
                  put(v_c);    v_crc := crc_upd(v_crc, v_c);
                  put(v_h);    v_crc := crc_upd(v_crc, v_h);
                  put(v_r);    v_crc := crc_upd(v_crc, v_r);
                  put(2);      v_crc := crc_upd(v_crc, 2);
                  put(to_integer(v_crc(15 downto 8)));
                  put(to_integer(v_crc(7 downto 0)));
                  for i in 1 to 22 loop put(16#4E#); end loop;
                  for i in 1 to 12 loop put(0); end loop;
                  for i in 1 to 3 loop put(16#A1#, 1); end loop;
                  v_crc := x"CDB4";
                  put(16#FB#); v_crc := crc_upd(v_crc, 16#FB#);
                  v_o := -1;
                  for j in ovr'range loop
                     if ovr(j).valid and ovr(j).c = v_c and ovr(j).h = v_h and ovr(j).r = v_r then
                        v_o := j;
                     end if;
                  end loop;
                  for i in 0 to 511 loop
                     if v_o >= 0 then
                        put(ovr(v_o).d(i));
                        v_crc := crc_upd(v_crc, ovr(v_o).d(i));
                     elsif v_f >= 0 then
                        put(ftr(v_f).fill);
                        v_crc := crc_upd(v_crc, ftr(v_f).fill);
                     else
                        put(pat(v_c, v_h, v_r, i));
                        v_crc := crc_upd(v_crc, pat(v_c, v_h, v_r, i));
                     end if;
                  end loop;
                  if (bad_crc and v_f < 0 and v_c = 5 and v_h = 1 and v_r = 3) or
                     (v_o >= 0 and not ovr(v_o).ok) then
                     v_crc := v_crc xor x"0001";
                  end if;
                  put(to_integer(v_crc(15 downto 8)));
                  put(to_integer(v_crc(7 downto 0)));
                  for i in 1 to v_gap3 loop put(16#4E#); end loop;
               end loop;
               while v_n < v_len loop put(16#4E#); end loop;
      end procedure build;
   begin
      rd_now  <= '1';
      idx_now <= '1';
      wait for 1 us;
      loop
         exit when done_sim;
         if motor_n /= '0' or not disk_in then
            rd_now  <= '1';
            idx_now <= '1';
            wait for 1 ms;
         else
            build;
            -- out, MSB first, with the index pulse at the start
            v_t0 := now;
            idx_now <= '0', '1' after 2 ms;
            v_prev := '0';
            for k in 0 to v_len - 1 loop
               pos_k <= k;
               pos_c <= v_c;
               pos_h <= v_h;
               if v_sync(k) = 1 then
                  v_bits := x"4489"; v_prev := '1';
               elsif v_sync(k) = 2 then
                  v_bits := x"5224"; v_prev := '0';
               else
                  v_d := to_unsigned(v_trk(k), 8);
                  for i in 7 downto 0 loop
                     v_bits(2 * i)     := v_d(i);
                     v_bits(2 * i + 1) := not (v_prev or v_d(i));
                     v_prev := v_d(i);
                  end loop;
               end if;
               for i in 15 downto 0 loop
                  if v_bits(i) = '1' then
                     v_rng := resize(v_rng * to_unsigned(1103515245, 32) + 12345, 32);
                     v_j   := (to_integer(v_rng(23 downto 16)) - 128) * jit / 128;  -- -jit..jit %
                     wait for v_cell / 2 + v_cell * v_j / 200;
                     rd_now <= '0', '1' after 200 ns;
                     wait for v_cell / 2 - v_cell * v_j / 200;
                  else
                     wait for v_cell;
                  end if;
               end loop;
               exit when motor_n /= '0' or not disk_in;
               if head /= v_c or (side1_n = '0') /= (v_h = 1) or disk_hd /= (v_cell < 1500 ns) or
                  ftr_gen /= v_gen then
                  build;                         -- the head moved: the new track from here
               end if;
            end loop;
         end if;
      end loop;
      wait;
   end process p_disk;

   -- writes: the cells of WDATA's pulses while WGATE is low, then the field decoded
   p_wcap : process
      variable v_t0   : time;
      variable v_cell : time;
      variable v_k0, v_c, v_h : natural;
      variable v_bits : std_logic_vector(0 to 220000);
      variable v_n    : natural;
      variable v_sr   : std_logic_vector(15 downto 0);
      variable v_pos  : integer;
      variable v_syncs : natural;
      variable v_b    : unsigned(7 downto 0);
      variable v_crc  : unsigned(15 downto 0);
      variable v_d    : t_bytes(0 to 511);
      variable v_mark : natural;
      variable v_stride, v_s, v_off, v_slot : natural;
      -- a track
      variable v_k1   : natural;
      variable v_i, v_last, v_c2, v_nid, v_ndat, v_bad, v_fill : integer;
      variable v_iam  : boolean;
      variable v_ip0, v_ip1 : integer;
      variable v_rs   : t_bytes(0 to 39);
      variable v_idc, v_idh : natural;
      impure function byte_at(p0 : integer) return natural is
         variable b : unsigned(7 downto 0);
      begin
         for j in 0 to 7 loop
            b(7 - j) := v_bits(p0 + 2 * j + 1);
         end loop;
         return to_integer(b);
      end function byte_at;
   begin
      wait until wgate_n = '0' or done_sim;
      if done_sim then
         wait;
      end if;
      v_t0 := now;
      v_k0 := pos_k; v_c := pos_c; v_h := pos_h;
      if disk_hd then v_cell := 1 us; v_stride := 658; else v_cell := 2 us; v_stride := 654; end if;
      v_bits := (others => '0');
      v_n := 0;
      loop
         wait until falling_edge(wdata_n) or rising_edge(wgate_n);
         exit when wgate_n = '1';
         v_bits((now - v_t0) / v_cell) := '1';
         v_n := (now - v_t0) / v_cell + 1;
      end loop;
      v_k1 := pos_k;
      if v_n > 30000 then
         -- a whole track (FORMAT): the index address mark, the ID and data fields
         v_iam := false; v_nid := 0; v_ndat := 0; v_bad := 0; v_fill := -1;
         v_ip0 := 0; v_ip1 := 0; v_idc := 0; v_idh := 0;
         v_i := 0; v_last := -100; v_c2 := 0; v_syncs := 0;
         v_sr := (others => '0');
         while v_i < v_n - 16 * 520 loop
            v_sr := v_sr(14 downto 0) & v_bits(v_i);
            if v_sr = x"5224" then
               if v_i - v_last = 16 then v_c2 := v_c2 + 1; else v_c2 := 1; end if;
               v_last := v_i;
               if v_c2 = 3 and byte_at(v_i + 1) = 16#FC# then
                  v_iam := true;
               end if;
               v_i := v_i + 1;
            elsif v_sr = x"4489" then
               if v_i - v_last = 16 then v_syncs := v_syncs + 1; else v_syncs := 1; end if;
               v_last := v_i;
               if v_syncs = 3 then
                  v_syncs := 0;
                  v_mark  := byte_at(v_i + 1);
                  v_crc   := crc_upd(x"CDB4", v_mark);
                  if v_mark = 16#FE# then
                     for j in 1 to 6 loop
                        v_crc := crc_upd(v_crc, byte_at(v_i + 1 + 16 * j));
                     end loop;
                     if v_crc /= 0 then
                        v_bad := v_bad + 1;
                     end if;
                     if v_nid = 0 then
                        v_ip0 := v_i;
                        v_idc := byte_at(v_i + 17);
                        v_idh := byte_at(v_i + 33);
                     elsif v_nid = 1 then
                        v_ip1 := v_i;
                     end if;
                     if v_nid < 40 then
                        v_rs(v_nid) := byte_at(v_i + 49);
                     end if;
                     v_nid := v_nid + 1;
                     v_i   := v_i + 1 + 16 * 7;
                  elsif v_mark = 16#FB# then
                     for j in 1 to 514 loop
                        v_crc := crc_upd(v_crc, byte_at(v_i + 1 + 16 * j));
                        if j <= 512 then
                           if v_fill < 0 then
                              v_fill := byte_at(v_i + 1 + 16 * j);
                           elsif byte_at(v_i + 1 + 16 * j) /= v_fill then
                              v_bad := v_bad + 1;
                           end if;
                        end if;
                     end loop;
                     if v_crc /= 0 then
                        v_bad := v_bad + 1;
                     end if;
                     v_ndat := v_ndat + 1;
                     v_i    := v_i + 1 + 16 * 515;
                  else
                     v_i := v_i + 1;
                  end if;
                  v_sr := (others => '0');
               else
                  v_i := v_i + 1;
               end if;
            else
               v_i := v_i + 1;
            end if;
         end loop;
         if not v_iam or v_nid = 0 or v_nid /= v_ndat or v_bad /= 0 or v_k0 > 40 or v_k1 > 40 then
            report "FAIL track at C " & integer'image(v_c) & " H " & integer'image(v_h) &
                   ": IAM " & boolean'image(v_iam) & ", " & integer'image(v_nid) & " IDs, " &
                   integer'image(v_ndat) & " data fields, " & integer'image(v_bad) & " bad, began at byte " &
                   integer'image(v_k0) & ", ended at byte " & integer'image(v_k1) &
                   " of the next turn" severity error;
            fmt_errors <= fmt_errors + 1;
         else
            report "ok   track decoded: C " & integer'image(v_c) & " H " & integer'image(v_h) &
                   ": " & integer'image(v_nid) & " sectors (IDs C " & integer'image(v_idc) &
                   " H " & integer'image(v_idh) & "), filler " & integer'image(v_fill) & ", gap 3 " &
                   integer'image((v_ip1 - v_ip0) / 16 - 574) & ", from byte " & integer'image(v_k0) &
                   " after the index to byte " & integer'image(v_k1) & " after the next";
            v_slot := 0;
            for j in ftr'range loop
               if not ftr(j).valid or (ftr(j).c = v_c and ftr(j).h = v_h) then
                  v_slot := j;
                  exit;
               end if;
            end loop;
            ftr(v_slot) <= (true, v_c, v_h, v_idc, v_idh, v_nid, v_rs, v_fill,
                            (v_ip1 - v_ip0) / 16 - 574);
            ftr_gen <= ftr_gen + 1;
         end if;
      else
      -- three syncs, then the bytes (the data bit the second of each pair)
      v_sr := (others => '0');
      v_pos := -1;
      v_syncs := 0;
      for i in 0 to v_n - 1 loop
         v_sr := v_sr(14 downto 0) & v_bits(i);
         if v_sr = x"4489" then
            v_syncs := v_syncs + 1;
            if v_syncs = 3 then
               v_pos := i + 1;
               exit;
            end if;
         end if;
      end loop;
      v_crc := x"CDB4";
      v_mark := 0;
      if v_pos >= 0 then
         for j in 0 to 514 loop
            for b in 0 to 7 loop
               v_b(7 - b) := v_bits(v_pos + 16 * j + 2 * b + 1);
            end loop;
            v_crc := crc_upd(v_crc, to_integer(v_b));
            if j = 0 then
               v_mark := to_integer(v_b);
            elsif j <= 512 then
               v_d(j - 1) := to_integer(v_b);
            end if;
         end loop;
      end if;
      -- where it began: the sector's gap 2 (the data field's preamble 44 bytes into the sector)
      v_s   := (v_k0 - 146) / v_stride;
      v_off := (v_k0 - 146) mod v_stride;
      if v_pos < 0 or v_mark /= 16#FB# or v_crc /= 0 or v_off < 40 or v_off > 48 then
         report "FAIL write at C " & integer'image(v_c) & " H " & integer'image(v_h) &
                " sector " & integer'image(v_s + 1) & " byte " & integer'image(v_off) &
                ": syncs " & integer'image(v_syncs) & ", mark " & integer'image(v_mark) &
                ", CRC " & to_hstring(v_crc) severity error;
         wr_errors <= wr_errors + 1;
      else
         report "ok   write decoded: C " & integer'image(v_c) & " H " & integer'image(v_h) &
                " sector " & integer'image(v_s + 1) & ", began at byte " & integer'image(v_off) &
                " of the sector (gap 2: 44)";
      end if;
      v_slot := 0;
      for j in ovr'range loop
         if not ovr(j).valid then
            v_slot := j;
            exit;
         end if;
      end loop;
      ovr(v_slot) <= (true, v_pos >= 0 and v_mark = 16#FB# and v_crc = 0, v_c, v_h, v_s + 1, v_d);
      end if;
   end process p_wcap;

   p_main : process
      procedure check(ok : boolean; what : string) is
      begin
         if ok then
            report "ok   " & what;
         else
            report "FAIL " & what severity error;
            errors <= errors + 1;
         end if;
      end procedure check;

      -- a request as pc_mgmt asks it (floppy.v's cylinder set first, as its implied seek does);
      -- then the slot out in a row, its bytes and buf_bad checked
      procedure ask(c, h, r : natural; want : std_logic_vector(15 downto 0); what : string;
                    fresh : std_logic := '0'; maxt : time := 3 sec; alt : boolean := false;
                    fillv : integer := -1) is
         variable v_t   : time;
         variable v_bad : natural := 0;
      begin
         pc_cyl0   <= std_logic_vector(to_unsigned(c, 8));
         req_c     <= std_logic_vector(to_unsigned(c, 8));
         req_h     <= '1' when h = 1 else '0';
         req_r     <= std_logic_vector(to_unsigned(r, 7));
         req_fresh <= fresh;
         wait until rising_edge(clk);
         req <= not req;
         v_t := now;
         wait until done'event for maxt;
         if not done'event and now - v_t >= maxt then
            check(false, what & ": no answer");
            return;
         end if;
         wait until rising_edge(clk);
         check(err = want, what & ": status " & to_hstring(err) & " in " &
               integer'image((now - v_t) / 1 ms) & " ms");
         if want = x"0000" and err = x"0000" then
            for i in 0 to 512 loop
               if i <= 511 then
                  buf_addr <= std_logic_vector(to_unsigned(i, 9));
               end if;
               wait until rising_edge(clk);
               if i > 0 and fillv >= 0 then
                  if to_integer(unsigned(buf_rd)) /= fillv then
                     v_bad := v_bad + 1;
                  end if;
               elsif i > 0 and not alt and to_integer(unsigned(buf_rd)) /= pat(c, h, r, i - 1) then
                  v_bad := v_bad + 1;
               end if;
               if i > 0 and alt and to_integer(unsigned(buf_rd)) /= pat2(c, h, r, i - 1) then
                  v_bad := v_bad + 1;
               end if;
            end loop;
            for i in 1 to 6 loop
               wait until rising_edge(clk);
            end loop;
            check(v_bad = 0 and buf_bad = '0', what & ": data (" & integer'image(v_bad) &
                  " wrong, buf_bad " & std_logic'image(buf_bad) & ")");
            buf_addr <= (others => '0');
            wait until rising_edge(clk);
         end if;
      end procedure ask;

      -- a write as pc_mgmt asks it: the bytes into the write buffer, then the request
      procedure wr(c, h, r : natural; want : std_logic_vector(15 downto 0); what : string) is
         variable v_t : time;
      begin
         for i in 0 to 511 loop
            wbuf_addr <= std_logic_vector(to_unsigned(i, 9));
            wbuf_wd   <= std_logic_vector(to_unsigned(pat2(c, h, r, i), 8));
            wbuf_we   <= '1';
            wait until rising_edge(clk);
         end loop;
         wbuf_we   <= '0';
         pc_cyl0   <= std_logic_vector(to_unsigned(c, 8));
         req_c     <= std_logic_vector(to_unsigned(c, 8));
         req_h     <= '1' when h = 1 else '0';
         req_r     <= std_logic_vector(to_unsigned(r, 7));
         req_wr    <= '1';
         req_fresh <= '0';
         wait until rising_edge(clk);
         req <= not req;
         v_t := now;
         wait until done'event for 3 sec;
         wait until rising_edge(clk);
         req_wr <= '0';
         check(err = want, what & ": status " & to_hstring(err) & " in " &
               integer'image((now - v_t) / 1 ms) & " ms");
      end procedure wr;

      -- a FORMAT as pc_mgmt hands it over: the IDs C H 1..sc 2, the last one writes the track
      procedure fmt(c, h, sc, gpl, fill : natural; hd : boolean; want : std_logic_vector(15 downto 0);
                    what : string) is
         variable v_t : time;
         variable v_e : std_logic_vector(15 downto 0) := x"FFFF";
         variable v_f : std_logic_vector(3 downto 0);
      begin
         pc_cyl0   <= std_logic_vector(to_unsigned(c, 8));
         req_c     <= std_logic_vector(to_unsigned(c, 8));
         req_h     <= '1' when h = 1 else '0';
         req_wr    <= '1';
         req_fresh <= '0';
         v_t := now;
         for k in 1 to sc loop
            v_f := "0000";                       -- 2 first, 1 last, 0 DD
            if k = 1 then v_f(2) := '1'; end if;
            if k = sc then v_f(1) := '1'; end if;
            v_f(0) := '0' when hd else '1';
            req_fmt <= '1' & v_f(2 downto 1) & v_f(0) & '0' & "000" & std_logic_vector(to_unsigned(sc, 8)) &
                       std_logic_vector(to_unsigned(gpl, 8)) & std_logic_vector(to_unsigned(fill, 8)) &
                       std_logic_vector(to_unsigned(c, 8)) & std_logic_vector(to_unsigned(h, 8)) &
                       std_logic_vector(to_unsigned(k, 8)) & x"02";
            req_r <= std_logic_vector(to_unsigned(k, 7));
            wait until rising_edge(clk);
            req <= not req;
            wait until done'event for 3 sec;
            wait until rising_edge(clk);
            v_e := err;
            exit when err /= x"0000";
         end loop;
         req_wr  <= '0';
         req_fmt <= (others => '0');
         check(v_e = want, what & ": status " & to_hstring(v_e) & " in " &
               integer'image((now - v_t) / 1 ms) & " ms");
      end procedure fmt;

      variable v_t : time;
   begin
      wait for 1 us;
      rst <= '0';
      wait for 400 ms;                           -- fdd_sound's start: out to TRACK0
      check(head = 0, "start: head on cylinder 0");
      check(wp = '1', "write protected (the tab, as the model starts)");

      pc_motor <= "01";
      if not G_WRITES_ONLY then
      -- HD, 18 sectors
      ask(0, 0, 1, x"0000", "HD 0/0/1");
      v_t := now;
      for r in 2 to 18 loop
         ask(0, 0, r, x"0000", "HD 0/0/" & integer'image(r), maxt => 300 ms);
      end loop;
      check(now - v_t < 250 ms, "HD 0/0/2-18 within a turn: " &
            integer'image((now - v_t) / 1 ms) & " ms");
      ask(5, 1, 7, x"0000", "HD 5/1/7 (seek, side 1)");
      ask(5, 1, 19, x"0004", "HD 5/1/19: not on the track (ND)");
      ask(5, 1, 3, x"2020", "HD 5/1/3: data CRC (DE, DD)");
      ask(5, 1, 4, x"0000", "HD 5/1/4", fresh => '1');
      ask(79, 0, 18, x"0000", "HD 79/0/18");
      check(dskchg = '0', "DSKCHG inactive with the disk in");

      -- a lost step: the head two cylinders off; the IDs say so, a recalibration
      head_jump <= 77;
      wait for 1 us;
      ask(79, 1, 1, x"0000", "lost steps: 79/1/1 after a recalibration");
      check(head = 79, "lost steps: head on 79 (" & integer'image(head) & ")");

      -- the disk out: DSKCHG; another in (DD, 9 sectors), a little fast, more jitter
      ejected <= true;
      disk_in <= false;
      wait for 50 ms;
      check(dskchg = '1', "disk out: DSKCHG active for the PC");
      ask(2, 0, 1, x"0001", "no disk: MA", maxt => 3 sec);
      disk_hd <= false;
      spd     <= 2;
      jit     <= 20;
      disk_in <= true;
      ejected <= false;
      wait for 10 ms;
      pc_cyl0 <= x"01";                          -- the PC's seek: a step clears DSKCHG
      wait for 100 ms;
      check(dskchg = '0', "DD disk in, a step: DSKCHG inactive");
      ask(1, 0, 1, x"0000", "DD 1/0/1 (the rate found)");
      for r in 2 to 9 loop
         ask(1, 0, r, x"0000", "DD 1/0/" & integer'image(r), maxt => 450 ms);
      end loop;
      ask(40, 1, 9, x"0000", "DD 40/1/9 (2 % fast, jitter 20 %)");
      ask(40, 1, 10, x"0004", "DD 40/1/10: not on the track (ND)");

      -- back to HD: the rate from the last one, then the other
      disk_hd <= true;
      spd     <= -2;
      jit     <= 10;
      ask(41, 0, 17, x"0000", "HD again (2 % slow): 41/0/17");
      end if;

      -- writes (HD, 2 % slow): the tab, then a sector, read back with its neighbours
      wr(3, 0, 5, x"0002", "write with the tab set: NW");
      wprot_n <= '1';
      wait for 20 ms;
      check(wp = '0', "the tab off: writable");
      wr(3, 0, 5, x"0000", "write HD 3/0/5");
      ask(3, 0, 5, x"0000", "read back HD 3/0/5", alt => true);
      ask(3, 0, 4, x"0000", "HD 3/0/4 untouched");
      ask(3, 0, 6, x"0000", "HD 3/0/6 untouched");
      wr(3, 0, 20, x"0004", "write HD 3/0/20: not on the track (ND)");
      wr(3, 1, 18, x"0000", "write HD 3/1/18 (the track's last)");
      ask(3, 1, 18, x"0000", "read back HD 3/1/18", alt => true);
      -- DD: the rate found for the write
      disk_hd <= false;
      spd     <= 1;
      wr(2, 1, 9, x"0000", "write DD 2/1/9 (the rate found)");
      ask(2, 1, 9, x"0000", "read back DD 2/1/9", alt => true);
      ask(2, 1, 8, x"0000", "DD 2/1/8 untouched");
      ask(2, 1, 1, x"0000", "DD 2/1/1 untouched");
      check(wr_errors = 0, "every write decoded in its gap (" & integer'image(wr_errors) & " bad)");

      -- FORMAT: an HD track (1 % slow), read back, a sector written into it; a DD track; the tab
      disk_hd <= true;
      spd     <= -1;
      fmt(7, 1, 18, 0, 16#F6#, true, x"0000", "format HD 7/1 (18 sectors, gap 3 0 as the BIOS's, F6)");
      wait for 1 ms;
      for j in ftr'range loop
         if ftr(j).valid and ftr(j).c = 7 and ftr(j).h = 1 then
            check(ftr(j).n = 18 and ftr(j).gap3 = 84 and ftr(j).idc = 7 and ftr(j).idh = 1,
                  "format HD 7/1: 18 sectors, the standard gap 3 (" & integer'image(ftr(j).gap3) & ")");
         end if;
      end loop;
      ask(7, 1, 1, x"0000", "formatted HD 7/1/1", fillv => 16#F6#);
      ask(7, 1, 18, x"0000", "formatted HD 7/1/18", fillv => 16#F6#);
      wr(7, 1, 9, x"0000", "write HD 7/1/9 into the formatted track");
      ask(7, 1, 9, x"0000", "read back HD 7/1/9", alt => true);
      ask(7, 1, 10, x"0000", "formatted HD 7/1/10", fillv => 16#F6#);
      ask(7, 1, 19, x"0004", "formatted HD 7/1/19: not on the track (ND)");
      disk_hd <= false;
      spd     <= 1;
      fmt(4, 0, 9, 16#50#, 16#E5#, false, x"0000", "format DD 4/0 (9 sectors, gap 3 50h, E5)");
      fmt(5, 1, 10, 0, 16#E5#, false, x"0000", "format DD 5/1 (10 sectors, gap 3 0: made to fit)");
      wait for 1 ms;
      for j in ftr'range loop
         if ftr(j).valid and ftr(j).c = 5 and ftr(j).h = 1 then
            check(ftr(j).n = 10 and ftr(j).gap3 < 80,
                  "format DD 5/1: 10 sectors, gap 3 shortened (" & integer'image(ftr(j).gap3) & ")");
         end if;
      end loop;
      ask(5, 1, 10, x"0000", "formatted DD 5/1/10", fillv => 16#E5#);
      ask(4, 0, 5, x"0000", "formatted DD 4/0/5", fillv => 16#E5#);
      ask(4, 0, 9, x"0000", "formatted DD 4/0/9", fillv => 16#E5#);
      wprot_n <= '0';
      wait for 20 ms;
      fmt(6, 0, 9, 16#50#, 16#E5#, false, x"0002", "format with the tab set: NW");
      check(fmt_errors = 0, "every formatted track decoded (" & integer'image(fmt_errors) & " bad)");

      pc_motor <= "00";
      wait for 10 ms;
      report "stat: requests " & integer'image(to_integer(unsigned(stat(255 downto 240)))) &
             ", errors " & integer'image(to_integer(unsigned(stat(239 downto 224)))) &
             ", IDs " & integer'image(to_integer(unsigned(stat(207 downto 192)))) &
             ", data " & integer'image(to_integer(unsigned(stat(191 downto 176)))) &
             ", CRC errors " & integer'image(to_integer(unsigned(stat(175 downto 160))));
      if errors = 0 then
         report "PASS";
      else
         report "FAILED: " & integer'image(errors) severity failure;
      end if;
      done_sim <= true;
      wait;
   end process p_main;

end architecture sim;

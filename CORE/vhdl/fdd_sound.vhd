----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Drive sounds: the MEGA65's internal floppy drive follows the PC's floppy drives (images on
-- the SD card), so it hums and clicks as a 486's drive does. floppy.v (z486_sources.py's patch)
-- says which drive is selected, whose motor is on and which cylinder each one's head is on;
-- this block turns the internal drive's motor on with the PC's and steps its head after the
-- selected drive's cylinder. It never writes: WGATE and WDATA stay high (mega65.vhd), and so
-- do SIDE1 and DENSITY.
--
--   * Select: while the PC has a floppy motor on and while the head moves. The drive's own LED
--     lights while it is selected, as a PC drive's does while its motor runs. TRACK0, INDEX and
--     DSKCHG are only valid while the drive is selected (and settled): they are only read then.
--   * Steps: one every G_STEP_US (4 ms: a 3.5" drive takes 3 ms), a G_PULSE_US low pulse with
--     the direction set G_DIR_US before. The head goes to the selected drive's cylinder, at most
--     C_MAX_CYL. On the way out to cylinder 0 it steps until TRACK0 shows, at most C_EXTRA steps
--     past where it thinks cylinder 0 is (a lost step), and TRACK0 seen anywhere sets the head
--     to 0. At the start (power-up, the menu's "On") one step in and then out until TRACK0
--     (at most C_RECAL steps; a drive that never shows TRACK0 is left alone, fault_o).
--   * A disk in the drive: the motor stays off (steps only), so a real disk does not spin
--     under its heads for nothing. DSKCHG (active low) latches when a disk comes out and
--     clears on a step with a disk in, as on a PC: every step's end reads it (inactive = a
--     disk). A disk put in while the head stands still: DSKCHG stays latched until the next
--     step, so INDEX tells it: two index pulses while the motor runs stop the motor at once,
--     and a step away and back (the "probe") asks DSKCHG. If DSKCHG then says no disk, the
--     mechanism sends INDEX without one, and INDEX is not used again (idx_off_o) until the
--     block restarts. DSKCHG going from inactive to active while selected: the disk came out.
--     Until the first step's answer the block assumes a disk (motor off).
--
-- All in clk_i (the PC's clock); the drive's lines are asynchronous, synchronized here.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fdd_sound is
generic (
   G_CLK_HZ     : natural := 64_000_000;
   G_STEP_US    : natural := 4000;     -- step period
   G_PULSE_US   : natural := 4;        -- STEP low
   G_DIR_US     : natural := 10;       -- DIR before STEP
   G_SEL_US     : natural := 100;      -- select before the lines are read or the head steps
   G_IDX_MIN_US : natural := 100_000   -- two index pulses closer than this count as one
);
port (
   clk_i         : in  std_logic;
   rst_i         : in  std_logic;      -- the core's reset: start again
   enable_i      : in  std_logic;      -- the menu's "Internal drive": Sounds, Drive A: or B:
   phys_i        : in  std_logic := '0';   -- the drive is the PC's drive phys_drv_i (fdd_phys)
   phys_drv_i    : in  std_logic := '0';
   recal_i       : in  std_logic := '0';   -- pulse: out to TRACK0 and back (a lost step)

   -- floppy.v (clk_i)
   pc_motor_i    : in  std_logic_vector(1 downto 0);    -- the DOR's motor bits, A: and B:
   pc_sel_i      : in  std_logic;                       -- the selected drive
   pc_cyl0_i     : in  std_logic_vector(7 downto 0);    -- A:'s head
   pc_cyl1_i     : in  std_logic_vector(7 downto 0);    -- B:'s head

   -- the internal drive (34-pin connector, all active low, asynchronous inputs)
   f_selecta_o   : out std_logic;
   f_motora_o    : out std_logic;
   f_step_o      : out std_logic;
   f_stepdir_o   : out std_logic;      -- '1': out, toward cylinder 0
   f_track0_i    : in  std_logic;
   f_index_i     : in  std_logic;
   f_diskchg_i   : in  std_logic;

   -- for fdd_phys: the lines (synchronized, valid while selected), the head on its target
   sel_ok_o      : out std_logic;                       -- selected 100 us
   sel_fast_o    : out std_logic;                       -- selected 4 us (DSKCHG valid)
   idx_n_o       : out std_logic;
   chg_n_o       : out std_logic;
   motor_o       : out std_logic;
   ready_o       : out std_logic;                       -- on target, settled 18 ms

   -- status
   cyl_o         : out std_logic_vector(6 downto 0);    -- where the head is
   disk_o        : out std_logic;                       -- a disk is in (motor held off)
   idx_off_o     : out std_logic;                       -- INDEX comes without a disk: unused
   fault_o       : out std_logic                        -- no TRACK0: the drive is left alone
);
end entity fdd_sound;

architecture rtl of fdd_sound is

   constant C_MAX_CYL : natural := 79;
   constant C_RECAL   : natural := 90;      -- steps out at the start before giving up
   constant C_EXTRA   : natural := 10;      -- steps past cylinder 0 looking for TRACK0

   constant C_US      : natural := G_CLK_HZ / 1_000_000;
   constant C_STEP    : natural := G_STEP_US * C_US;
   constant C_PULSE   : natural := G_PULSE_US * C_US;
   constant C_DIR     : natural := G_DIR_US * C_US;
   constant C_SEL     : natural := G_SEL_US * C_US;
   constant C_IDX_MIN : natural := G_IDX_MIN_US * C_US;
   constant C_FAST    : natural := 4 * C_US;
   constant C_SETTLE  : natural := 18_000 * C_US;     -- head settle after the last step

   type t_state is (S_OFF, S_IDLE, S_SEL, S_DIR, S_PULSE, S_GAP);
   signal state      : t_state := S_OFF;
   signal timer      : natural range 0 to C_STEP := 0;

   -- the drive's lines, synchronized (active low)
   signal trk0_m, trk0_n  : std_logic := '1';
   signal idx_m, idx_n    : std_logic := '1';
   signal idx_d           : std_logic := '1';
   signal chg_m, chg_n    : std_logic := '1';

   signal sel        : std_logic := '0';     -- select asserted
   signal sel_ok     : std_logic := '0';     -- ... for C_SEL: the lines are valid
   signal sel_cnt    : natural range 0 to C_SEL := 0;
   signal motor      : std_logic := '0';
   signal sel_fast   : std_logic := '0';
   signal settle     : natural range 0 to C_SETTLE := 0;
   signal ready      : std_logic := '0';
   signal step_n     : std_logic := '1';
   signal dir        : std_logic := '1';

   signal cyl        : natural range 0 to C_MAX_CYL := 0;      -- the head, as far as known
   signal tgt_drv    : std_logic := '0';                       -- the PC drive followed
   signal dir_out    : std_logic := '1';                       -- the step in progress: out
   signal recal      : std_logic := '0';     -- out until TRACK0 (the start)
   signal recal_cnt  : natural range 0 to C_RECAL := 0;
   signal extra      : natural range 0 to C_EXTRA := 0;        -- steps out past 0 for TRACK0
   signal force_in   : std_logic := '0';     -- one step in, whatever the target (start, probe)
   signal force_out  : std_logic := '0';     -- one step out (the probe at C_MAX_CYL)

   signal disk       : std_logic := '1';     -- a disk is in: no motor
   signal chg_last   : std_logic := '0';     -- DSKCHG as last seen while selected
   signal idx_off    : std_logic := '0';
   signal idx_probe  : std_logic := '0';     -- the probe in progress came from INDEX
   signal idx_cnt    : natural range 0 to 2 := 0;
   signal idx_gap    : natural range 0 to C_IDX_MIN := 0;
   signal fault      : std_logic := '0';

   function clamp(c : std_logic_vector(7 downto 0)) return natural is
   begin
      if unsigned(c) > C_MAX_CYL then
         return C_MAX_CYL;
      end if;
      return to_integer(unsigned(c));
   end function clamp;

begin

   p_main : process (clk_i)
      variable v_target : natural range 0 to C_MAX_CYL;
      variable v_pc_on  : boolean;
      variable v_out    : boolean;
      variable v_in     : boolean;
   begin
      if rising_edge(clk_i) then
         trk0_m <= f_track0_i;  trk0_n <= trk0_m;
         idx_m  <= f_index_i;   idx_n  <= idx_m;   idx_d <= idx_n;
         chg_m  <= f_diskchg_i; chg_n  <= chg_m;

         -- the PC drive followed: the selected one if its motor runs, else one whose motor runs;
         -- the internal drive's own as a PC drive
         if phys_i = '1' then
            tgt_drv <= phys_drv_i;
         elsif pc_motor_i(0) = '1' and (pc_sel_i = '0' or pc_motor_i(1) = '0') then
            tgt_drv <= '0';
         elsif pc_motor_i(1) = '1' then
            tgt_drv <= '1';
         end if;
         if tgt_drv = '0' then
            v_target := clamp(pc_cyl0_i);
         else
            v_target := clamp(pc_cyl1_i);
         end if;
         if phys_i = '1' then
            v_pc_on := pc_motor_i(to_integer(unsigned'('0' & phys_drv_i))) = '1';
         else
            v_pc_on := pc_motor_i /= "00";
         end if;

         -- select settles before its lines count
         if sel = '0' then
            sel_cnt  <= 0;
            sel_ok   <= '0';
            sel_fast <= '0';
         elsif sel_cnt /= C_SEL then
            sel_cnt <= sel_cnt + 1;
            if sel_cnt = C_FAST then
               sel_fast <= '1';
            end if;
         else
            sel_ok  <= '1';
         end if;

         if settle /= 0 then
            settle <= settle - 1;
         end if;
         ready <= '0';
         if recal_i = '1' and state /= S_OFF then
            recal     <= '1';
            recal_cnt <= 0;
         end if;

         if timer /= 0 then
            timer <= timer - 1;
         end if;

         -- a disk taken out: DSKCHG from inactive to active while selected (not mid-step: a step
         -- with a disk in clears it, which the step's end reads)
         if sel_ok = '1' and (state = S_IDLE or state = S_SEL) then
            chg_last <= chg_n;
            if chg_last = '1' and chg_n = '0' then
               disk <= '0';
            end if;
         end if;

         -- a disk put in: two index pulses while the motor runs; the motor stops at once and
         -- a probe asks DSKCHG
         if motor = '1' and sel_ok = '1' and idx_off = '0' and phys_i = '0' then
            if idx_gap /= 0 then
               idx_gap <= idx_gap - 1;
            end if;
            if idx_d = '1' and idx_n = '0' and idx_gap = 0 then
               idx_gap <= C_IDX_MIN;
               if idx_cnt = 1 then
                  idx_cnt <= 0;
                  disk    <= '1';
                  if cyl = C_MAX_CYL then
                     force_out <= '1';
                  else
                     force_in  <= '1';
                  end if;
                  idx_probe <= '1';
               else
                  idx_cnt <= idx_cnt + 1;
               end if;
            end if;
         else
            idx_cnt <= 0;
            idx_gap <= 0;
         end if;

         case state is
            when S_OFF =>
               sel       <= '0';
               motor     <= '0';
               step_n    <= '1';
               disk      <= '1';
               idx_off   <= '0';
               idx_probe <= '0';
               fault     <= '0';
               extra     <= 0;
               chg_last  <= '0';
               if enable_i = '1' then
                  force_in  <= '1';     -- one step in (DSKCHG's answer), then out to TRACK0
                  force_out <= '0';
                  recal     <= '1';
                  recal_cnt <= 0;
                  cyl       <= 0;
                  state     <= S_IDLE;
               end if;

            when S_IDLE =>
               step_n   <= '1';
               if sel_ok = '1' and trk0_n = '0' then
                  cyl   <= 0;
                  extra <= 0;
               end if;
               v_out := false;
               v_in  := false;
               if fault = '0' then
                  if force_in = '1' then
                     v_in  := true;
                  elsif force_out = '1' then
                     v_out := true;
                  elsif recal = '1' then
                     if sel_ok = '1' and trk0_n = '0' then
                        recal <= '0';
                     elsif sel_ok = '1' and recal_cnt = C_RECAL then
                        recal <= '0';
                        fault <= '1';                 -- no TRACK0: leave the drive alone
                     else
                        v_out := true;
                     end if;
                  elsif cyl > v_target then
                     v_out := true;
                  elsif cyl < v_target then
                     v_in  := true;
                  elsif v_target = 0 and sel_ok = '1' and trk0_n = '1' and extra /= C_EXTRA then
                     v_out := true;                   -- cylinder 0 without TRACK0: lost a step
                  end if;
               end if;
               if not (v_out or v_in) and settle = 0 and fault = '0' and recal_i = '0' then
                  ready <= '1';                       -- on target, settled
               end if;
               if v_out or v_in then
                  sel <= '1';
                  if v_out then
                     dir_out <= '1';
                  else
                     dir_out <= '0';
                  end if;
                  state <= S_SEL;
               else
                  sel <= '1' when v_pc_on else '0';
               end if;
               if enable_i = '0' or rst_i = '1' then
                  state <= S_OFF;
               end if;

            when S_SEL =>
               -- the select line settled; then TRACK0 may already say the head is out
               if sel_ok = '1' then
                  if dir_out = '1' and trk0_n = '0' and force_out = '0' then
                     cyl   <= 0;
                     extra <= 0;
                     recal <= '0';
                     state <= S_IDLE;
                  else
                     dir         <= dir_out;
                     timer       <= C_DIR;
                     state       <= S_DIR;
                  end if;
               end if;

            when S_DIR =>
               if timer = 0 then
                  step_n   <= '0';
                  timer    <= C_PULSE;
                  state    <= S_PULSE;
               end if;

            when S_PULSE =>
               if timer = 0 then
                  step_n   <= '1';
                  settle   <= C_SETTLE;
                  timer    <= C_STEP - C_PULSE - C_DIR;
                  state    <= S_GAP;
                  if dir_out = '1' then
                     if cyl /= 0 then
                        cyl <= cyl - 1;
                     elsif force_out = '0' and recal = '0' then
                        extra <= extra + 1;
                     end if;
                     if recal = '1' and force_out = '0' then
                        recal_cnt <= recal_cnt + 1;
                     end if;
                     force_out <= '0';
                  else
                     if cyl /= C_MAX_CYL then
                        cyl <= cyl + 1;
                     end if;
                     force_in <= '0';
                  end if;
               end if;

            when S_GAP =>
               if timer = 0 then
                  -- DSKCHG after a step: inactive = a disk is in
                  disk     <= chg_n;
                  chg_last <= chg_n;
                  if idx_probe = '1' and chg_n = '0' then
                     idx_off <= '1';        -- INDEX without a disk: not used again
                  end if;
                  if force_in = '0' and force_out = '0' then
                     idx_probe <= '0';
                  end if;
                  state <= S_IDLE;
               end if;
         end case;

         -- the motor: with the PC's, unless a disk is in (sounds); as a PC drive, with the PC's
         if state /= S_OFF then
            motor <= '1' when v_pc_on and (disk = '0' or phys_i = '1') and fault = '0' else '0';
         end if;

         if rst_i = '1' then
            state     <= S_OFF;
            sel       <= '0';
            motor     <= '0';
            step_n    <= '1';
            timer     <= 0;
         end if;
      end if;
   end process p_main;

   f_selecta_o <= not sel;
   f_motora_o  <= not motor;
   f_step_o    <= step_n;
   f_stepdir_o <= dir;

   sel_ok_o   <= sel_ok;
   sel_fast_o <= sel_fast;
   idx_n_o    <= idx_n;
   chg_n_o    <= chg_n;
   motor_o    <= motor;
   ready_o    <= ready;

   cyl_o     <= std_logic_vector(to_unsigned(cyl, 7));
   disk_o    <= disk;
   idx_off_o <= idx_off;
   fault_o   <= fault;

end architecture rtl;

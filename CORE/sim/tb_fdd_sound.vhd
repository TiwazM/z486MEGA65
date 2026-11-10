----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- tb_fdd_sound: fdd_sound.vhd (drive sounds) against a model of the internal drive: a head
-- on cylinders 0 to 83 that steps on STEP's falling edge while selected, TRACK0, DSKCHG
-- (latched at power-up and when the disk comes out, cleared by a step with a disk in) and
-- INDEX (every 200 ms while selected and spinning with a disk in; with idx_nodisk without one
-- too). The PC side sets floppy.v's motor bits and cylinders. A watcher checks every step
-- pulse: selected, DIR steady from 10 us before it, 4 ms from the one before, never past the
-- stops; and how long the motor spins a disk.
--
-- The clock is 1 MHz (fdd_sound's G_CLK_HZ): 1 us a clock.
--
-- Licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fdd_sound is
end entity tb_fdd_sound;

architecture sim of tb_fdd_sound is

   constant C_CLK  : time := 1 us;

   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal enable     : std_logic := '0';
   signal pc_motor   : std_logic_vector(1 downto 0) := "00";
   signal pc_sel     : std_logic := '0';
   signal pc_cyl0    : std_logic_vector(7 downto 0) := x"00";
   signal pc_cyl1    : std_logic_vector(7 downto 0) := x"00";

   signal sel_n, motor_n, step_n, dir : std_logic;
   signal trk0_n, index_n, chg_n      : std_logic := '1';

   signal cyl_o      : std_logic_vector(6 downto 0);
   signal disk_o, idx_off_o, fault_o : std_logic;

   -- the drive
   signal head       : integer := 37;
   signal disk_in    : boolean := false;
   signal chg_latch  : boolean := true;          -- power-up: latched
   signal idx_nodisk : boolean := false;         -- INDEX without a disk too
   signal no_trk0    : boolean := false;         -- TRACK0 never shows
   signal steps      : natural := 0;
   signal spin_disk  : natural := 0;             -- us the motor ran with a disk in, this time
   signal spin_max   : natural := 0;             -- the longest of those
   signal spin_clr   : boolean := false;         -- toggled: spin_max from 0
   signal head_jump  : integer := -1;            -- the testbench moves the head (a lost step)

   signal done       : boolean := false;
   signal errors     : natural := 0;
   signal watch_err  : natural := 0;             -- p_watch's

begin

   clk <= not clk after C_CLK / 2 when not done;

   dut : entity work.fdd_sound
      generic map (
         G_CLK_HZ     => 1_000_000
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         enable_i    => enable,
         pc_motor_i  => pc_motor,
         pc_sel_i    => pc_sel,
         pc_cyl0_i   => pc_cyl0,
         pc_cyl1_i   => pc_cyl1,
         f_selecta_o => sel_n,
         f_motora_o  => motor_n,
         f_step_o    => step_n,
         f_stepdir_o => dir,
         f_track0_i  => trk0_n,
         f_index_i   => index_n,
         f_diskchg_i => chg_n,
         cyl_o       => cyl_o,
         disk_o      => disk_o,
         idx_off_o   => idx_off_o,
         fault_o     => fault_o
      );

   -- the drive's outputs: open collector, gated by select (pulled up otherwise)
   trk0_n <= '0' when sel_n = '0' and head = 0 and not no_trk0 else '1';
   chg_n  <= '0' when sel_n = '0' and chg_latch else '1';

   p_head : process (step_n, head_jump, disk_in)
   begin
      if head_jump'event and head_jump >= 0 then
         head <= head_jump;
      end if;
      if disk_in'event and not disk_in then
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
         steps <= steps + 1;
      end if;
   end process p_head;

   p_index : process
   begin
      index_n <= '1';
      wait for 1 ms;
      loop
         if sel_n = '0' and motor_n = '0' and (disk_in or idx_nodisk) then
            index_n <= '0';
            wait for 2 ms;
            index_n <= '1';
            wait for 198 ms;
         else
            wait for 1 ms;
         end if;
         exit when done;
      end loop;
      wait;
   end process p_index;

   -- every step pulse: selected, DIR steady 10 us before, 4 ms apart
   p_watch : process
      variable v_last : time := -1 sec;
      variable v_dir  : time := 0 ns;
   begin
      wait until falling_edge(step_n) or dir'event or done;
      if done then
         wait;
      end if;
      if dir'event then
         v_dir := now;
      else
         if sel_n /= '0' then
            report "FAIL: step while not selected" severity error;
            watch_err <= watch_err + 1;
         end if;
         if now - v_dir < 10 us then
            report "FAIL: DIR changed " & time'image(now - v_dir) & " before the step" severity error;
            watch_err <= watch_err + 1;
         end if;
         if now - v_last < 4 ms then
            report "FAIL: steps " & time'image(now - v_last) & " apart" severity error;
            watch_err <= watch_err + 1;
         end if;
         v_last := now;
      end if;
   end process p_watch;

   p_spin : process (clk)
      variable v_clr : boolean := false;
   begin
      if rising_edge(clk) then
         if spin_clr /= v_clr then
            v_clr    := spin_clr;
            spin_max <= 0;
         elsif motor_n = '0' and disk_in then
            spin_disk <= spin_disk + 1;
            if spin_disk + 1 > spin_max then
               spin_max <= spin_disk + 1;
            end if;
         else
            spin_disk <= 0;
         end if;
      end if;
   end process p_spin;

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

      procedure settle(t : time) is
      begin
         wait for t;
      end procedure settle;

      procedure insert is
      begin
         disk_in  <= true;
         spin_clr <= not spin_clr;
      end procedure insert;

      procedure eject is
      begin
         disk_in   <= false;
      end procedure eject;

      variable v_steps : natural;
   begin
      wait for 10 us;
      rst <= '0';
      wait for 1 ms;
      check(sel_n = '1' and motor_n = '1' and step_n = '1', "off: the drive idle");

      -- 1. start without a disk, head on 37: one step in, out to TRACK0
      enable <= '1';
      settle(400 ms);
      check(head = 0 and unsigned(cyl_o) = 0, "start: head on cylinder 0 (" & integer'image(head) & ")");
      check(disk_o = '0', "start: no disk");
      check(fault_o = '0', "start: TRACK0 found");
      check(sel_n = '1' and motor_n = '1', "start: idle, deselected");

      -- 2. the PC's A: motor on, a seek to 40
      pc_motor <= "01";
      pc_cyl0  <= x"28";
      settle(250 ms);
      check(head = 40 and unsigned(cyl_o) = 40, "A: seek to 40 (" & integer'image(head) & ")");
      check(motor_n = '0' and sel_n = '0', "A: motor on, selected");

      -- 3. back to 0
      pc_cyl0 <= x"00";
      settle(250 ms);
      check(head = 0, "A: seek to 0 (" & integer'image(head) & ")");

      -- 4. a lost step: the head two out of place; going for cylinder 0 finds TRACK0
      pc_cyl0 <= x"05";
      settle(100 ms);
      head_jump <= 7;
      wait for 1 us;
      pc_cyl0 <= x"00";
      settle(150 ms);
      check(head = 0 and unsigned(cyl_o) = 0, "lost steps: TRACK0 found (" & integer'image(head) & ")");

      -- 5. B: and A: : the selected drive's cylinder
      pc_cyl0  <= x"0A";
      pc_cyl1  <= x"14";
      pc_motor <= "10";
      pc_sel   <= '1';
      settle(150 ms);
      check(head = 20, "B: followed (" & integer'image(head) & ")");
      pc_motor <= "11";
      pc_sel   <= '0';
      settle(100 ms);
      check(head = 10, "A: and B: on, A: selected (" & integer'image(head) & ")");
      pc_motor <= "01";

      -- 6. a disk put in while the head stands: INDEX stops the motor, the probe confirms
      insert;
      settle(800 ms);
      check(disk_o = '1', "disk in: seen");
      check(motor_n = '1', "disk in: motor off");
      check(spin_max < 450_000, "disk in: spun " & integer'image(spin_max / 1000) & " ms");
      check(head = 10, "disk in: the probe went back (" & integer'image(head) & ")");
      check(idx_off_o = '0', "disk in: INDEX still used");

      -- 7. with the disk in: steps only
      spin_clr <= not spin_clr;
      pc_cyl0 <= x"1E";
      settle(150 ms);
      check(head = 30, "disk in: seek to 30 (" & integer'image(head) & ")");
      check(spin_max = 0, "disk in: the motor never ran");

      -- 8. the disk out while selected: the motor runs again
      eject;
      settle(5 ms);
      check(disk_o = '0' and motor_n = '0', "disk out: motor on");

      -- 9. the PC's motor off: deselected; a disk in while deselected; the PC's motor on:
      --    it spins until INDEX, then stops
      pc_motor <= "00";
      settle(10 ms);
      check(sel_n = '1' and motor_n = '1', "PC motor off: deselected");
      insert;
      settle(100 ms);
      pc_motor <= "01";
      settle(800 ms);
      check(disk_o = '1' and motor_n = '1', "disk in while off: motor stopped");
      check(spin_max < 450_000, "disk in while off: spun " & integer'image(spin_max / 1000) & " ms");

      -- 10. out while deselected: seen at the next select
      pc_motor <= "00";
      settle(10 ms);
      eject;
      settle(10 ms);
      pc_motor <= "01";
      settle(5 ms);
      check(disk_o = '0' and motor_n = '0', "disk out while off: motor on");

      -- 11. a drive that sends INDEX without a disk: one probe, then INDEX is not used
      idx_nodisk <= true;
      v_steps := steps;
      settle(1500 ms);
      check(idx_off_o = '1', "INDEX without a disk: INDEX off");
      check(disk_o = '0' and motor_n = '0', "INDEX without a disk: motor on");
      check(steps - v_steps = 2, "INDEX without a disk: one probe (" & integer'image(steps - v_steps) & " steps)");
      idx_nodisk <= false;

      -- 12. off from the menu: idle; on again: starts over
      enable <= '0';
      settle(10 ms);
      check(sel_n = '1' and motor_n = '1' and step_n = '1', "menu off: the drive idle");
      v_steps := steps;
      pc_cyl0 <= x"32";
      settle(300 ms);
      check(steps = v_steps, "menu off: no steps");
      enable <= '1';
      settle(700 ms);
      check(head = 50 and idx_off_o = '0', "menu on: started over, on 50 (" & integer'image(head) & ")");

      -- 13. a drive without TRACK0: at most 90 steps out, then left alone
      enable   <= '0';
      pc_motor <= "00";
      settle(10 ms);
      no_trk0 <= true;
      v_steps := steps;
      enable  <= '1';
      settle(600 ms);
      check(fault_o = '1', "no TRACK0: fault");
      check(steps - v_steps <= 92, "no TRACK0: " & integer'image(steps - v_steps) & " steps");
      v_steps := steps;
      pc_motor <= "01";
      pc_cyl0  <= x"14";
      settle(200 ms);
      check(steps = v_steps and motor_n = '1', "no TRACK0: left alone");

      check(watch_err = 0, "every step pulse: selected, DIR 10 us before, 4 ms apart (" &
                           integer'image(watch_err) & " bad)");
      wait for 1 us;
      if errors = 0 then
         report "PASS";
      else
         report "FAILED: " & integer'image(errors) severity failure;
      end if;
      done <= true;
      wait;
   end process p_main;

end architecture sim;

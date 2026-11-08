-- Runs M2M/vhdl/controllers/HDMI/video_out_clock.vhd with Vivado's unisim MMCME2_ADV: for every
-- clock select (000..111) it reprograms the MMCM over the DRP from its table, waits for lock,
-- then measures the pixel clock (clko) and the serialiser clock (clko_x5), which must be five
-- times the pixel clock. One line per select; FAIL when a clock is more than 0.1 % off the
-- table's frequency or the two are not 1:5. Run by CORE/sim/run_video_clock.sh.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity tb_video_clock is
end entity tb_video_clock;

architecture sim of tb_video_clock is

   signal clki    : std_logic := '0';
   signal rsti    : std_logic := '1';
   signal sel     : std_logic_vector(2 downto 0) := "000";
   signal rsto    : std_logic;
   signal clko    : std_logic;
   signal clko_x5 : std_logic;

   type freqs_t is array (0 to 7) of real;
   -- what each entry's comment says it makes (MHz)
   constant C_EXPECT : freqs_t := (25.200, 27.000, 74.250, 65.000, 25.179, 28.333, 90.000, 40.000);

begin

   clki <= not clki after 5 ns;                       -- 100 MHz

   i_dut : entity work.video_out_clock
      generic map (
         fref => 100.0
      )
      port map (
         rsti    => rsti,
         clki    => clki,
         sel     => sel,
         rsto    => rsto,
         clko    => clko,
         clko_x5 => clko_x5
      );

   p_main : process
      variable v_f   : real;
      variable v_f5  : real;
      variable v_ok  : boolean;
      variable v_bad : natural := 0;

      -- frequency (MHz) of c over n rising edges
      procedure measure (signal c : in std_logic; n : natural; f : out real) is
         variable t_a : time;
      begin
         wait until rising_edge(c);
         t_a := now;
         for i in 1 to n loop
            wait until rising_edge(c);
         end loop;
         f := real(n) * 1.0e6 / real((now - t_a) / 1 ps);
      end procedure measure;

   begin
      wait for 200 ns;
      rsti <= '0';
      for s in 0 to 7 loop
         sel <= std_logic_vector(to_unsigned(s, 3));
         if s > 0 then
            wait until rsto = '1' for 20 us;          -- the change seen, the MMCM in reset
         end if;
         wait until rsto = '0' for 1 ms;              -- locked again, the mux on the MMCM
         if rsto /= '0' then
            report "sel " & integer'image(s) & ": no lock" severity error;
            v_bad := v_bad + 1;
         else
            wait for 20 us;
            measure(clko, 2000, v_f);
            measure(clko_x5, 10000, v_f5);
            v_ok := abs (v_f - C_EXPECT(s)) < C_EXPECT(s) * 0.001 and
                    abs (v_f5 - 5.0 * v_f) < v_f * 0.001;
            if not v_ok then
               v_bad := v_bad + 1;
            end if;
            if v_ok then
               report "sel " & integer'image(s) & ": pixel " & real'image(v_f) & " MHz, x5 " &
                      real'image(v_f5) & " MHz, expected " & real'image(C_EXPECT(s)) & " ok";
            else
               report "sel " & integer'image(s) & ": pixel " & real'image(v_f) & " MHz, x5 " &
                      real'image(v_f5) & " MHz, expected " & real'image(C_EXPECT(s)) & " FAIL";
            end if;
         end if;
      end loop;
      report "done, " & integer'image(v_bad) & " failing";
      std.env.finish;
   end process p_main;

end architecture sim;

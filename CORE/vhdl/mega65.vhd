----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- MEGA65 main file that contains the whole machine
--
-- * clk.vhd: the PC's 64 MHz clock (also the video clock) and the 24.556 MHz audio clock
-- * CORE/sv/z486_mega65.sv: z486_MiSTer's system.sv and SDRAM backend: CPU, chipset,
--   VGA/ET4000, OPL3/SB, IDE, floppy; system RAM in the R6's 64 MB SDRAM
-- * z486's MiSTer DDR3 port (the boot image and the SVGA framebuffer) in HyperRAM: an address
--   map, a clock crossing (avm_fifo) and a 64 -> 16 bit width reduction (avm_decrease)
-- * the SVGA framebuffer shown by ascal from HyperRAM (M2M-UPSTREAM rtg-framebuffer)
-- * the MEGA65 keyboard as a PS/2 keyboard (pc_keyboard.vhd, ps2_device.vhd)
--
-- Not wired yet: the IDE/floppy management bus (no drives), the PS/2 mouse, joysticks.
--
-- The entity is the Megamiga fork's MEGA65_Core (M2M-UPSTREAM exceptions: floppy, SDRAM,
-- PMOD, Ethernet pins and the SD engine port are routed into the core), as in pc10-iii.
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen, 2022), Megamiga's and pc10-iii's
-- mega65.vhd (Johan Smolinski); licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;
   video_fl_o              : out std_logic;  -- interlace field flag for ascal weave deinterlacing

   -- M2M-UPSTREAM rtg-framebuffer (Megamiga 2026-10-09): the RTG graphics card - ascal shows
   -- the framebuffer in HyperRAM instead of the Amiga picture while fb_ena_o = '1' (HDMI only:
   -- the analog output keeps the Amiga picture). Core clock domain, slowly changing.
   fb_ena_o                : out std_logic;
   fb_hsize_o              : out std_logic_vector(11 downto 0);
   fb_vsize_o              : out std_logic_vector(11 downto 0);
   fb_format_o             : out std_logic_vector( 5 downto 0);
   fb_base_o               : out std_logic_vector(31 downto 0);  -- HyperRAM byte address
   fb_stride_o             : out std_logic_vector(13 downto 0);
   fb_pal_clk_o            : out std_logic;
   fb_pal_a_o              : out std_logic_vector( 7 downto 0);
   fb_pal_dw_o             : out std_logic_vector(23 downto 0);
   fb_pal_wr_o             : out std_logic;
   fb_pal_dr_i             : in  std_logic_vector(23 downto 0) := (others => '0');

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- the PC's 28.63636 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_kb_key_raw_n_i     : in  std_logic;              -- the same, also while the OSM is open (M2M osm-hotkey)
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- OSM-open key selection (issue #8): the core decodes the "OSM: %s" radio and
   -- tells the framework's m2m_keyb which key(s) drive the menu-open bit
   -- (qnice_keys bit 7). Threaded core->framework->m2m_keyb, exactly like video_fl_o.
   osm_key_a_o             : out integer range 0 to 79;
   osm_key_b_o             : out integer range 0 to 79;
   osm_combo_o             : out std_logic;
   -- Megamiga (M2M-UPSTREAM osm-hotkey): '1' = the menu key must not open the menu now
   -- (CTRL+MEGA are held: CTRL+MEGA+HELP is the cartridge's freeze button)
   osm_block_o             : out std_logic;

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- MEGA65 internal floppy drive (Hardware Floppy feature): the 34-pin
   -- connector, threaded as plain wires from the board tops (M2M-UPSTREAM
   -- floppy-pins; the C64MEGA65 issue-#90 pattern). All active low. Drive B
   -- (f_motorb/f_selectb) stays tied '1' at the top level; the WRITE pins
   -- f_wdata/f_wgate are driven by physical_fdd_writer since WIP-V2-A9.
   f_wdata_o               : out std_logic;
   f_wgate_o               : out std_logic;
   f_motora_o              : out std_logic;
   f_selecta_o             : out std_logic;
   f_side1_o               : out std_logic;
   f_stepdir_o             : out std_logic;
   f_step_o                : out std_logic;
   f_density_o             : out std_logic;
   f_index_i               : in  std_logic;
   f_track0_i              : in  std_logic;
   f_writeprotect_i        : in  std_logic;
   f_rdata_i               : in  std_logic;
   f_diskchanged_i         : in  std_logic;

   -- SDRAM (R4/R5/R6 only: IS42S16320F, 32M x 16): the 8 MB Zorro II Fast RAM,
   -- threaded as plain wires from the board tops (M2M-UPSTREAM sdram-pins, the
   -- floppy-pins pattern). The R3 top has no SDRAM and leaves these unconnected;
   -- the R3 build then also ignores the Fast RAM menu bit (see C_HAS_SDRAM).
   sdram_clk_o             : out   std_logic;
   sdram_cke_o             : out   std_logic;
   sdram_ras_n_o           : out   std_logic;
   sdram_cas_n_o           : out   std_logic;
   sdram_we_n_o            : out   std_logic;
   sdram_cs_n_o            : out   std_logic;
   sdram_ba_o              : out   std_logic_vector(1 downto 0);
   sdram_a_o               : out   std_logic_vector(12 downto 0);
   sdram_dqml_o            : out   std_logic;
   sdram_dqmh_o            : out   std_logic;
   sdram_dq_io             : inout std_logic_vector(15 downto 0);

   -- PMOD headers (R4/R5/R6 only): the Amiga serial port on PMOD1, threaded as
   -- plain wires from the board tops (M2M-UPSTREAM pmod-pins, the floppy-pins
   -- pattern). All pins stay high-Z and both headers unpowered unless the
   -- "Serial port on PMOD" menu item is on. The R3 top leaves these unconnected.
   p1lo_io                 : inout std_logic_vector(3 downto 0);
   p1hi_io                 : inout std_logic_vector(3 downto 0);
   p2lo_io                 : inout std_logic_vector(3 downto 0);
   p2hi_io                 : inout std_logic_vector(3 downto 0);
   pmod1_en_o              : out   std_logic;
   pmod2_en_o              : out   std_logic;

   -- Ethernet PHY KSZ8081 (R4/R5/R6 only): the network card (eth_card.vhd), threaded as plain
   -- wires from the board tops (M2M-UPSTREAM eth-pins, the floppy-pins pattern). The R3 top
   -- leaves these unconnected.
   eth_clock_o             : out   std_logic;
   eth_led2_o              : out   std_logic;
   eth_mdc_o               : out   std_logic;
   eth_mdio_io             : inout std_logic;
   eth_reset_o             : out   std_logic;
   eth_rxd_i               : in    std_logic_vector(1 downto 0) := "00";
   eth_rxdv_i              : in    std_logic := '0';
   eth_rxer_i              : in    std_logic := '0';
   eth_txd_o               : out   std_logic_vector(1 downto 0);
   eth_txen_o              : out   std_logic;

   -- The engine port of the SD host controller (M2M-UPSTREAM sd-host, sdhost_pkg; QNICE
   -- clock domain): the IDE board's sector engine streams HDF sectors through it
   sd_eng_i                : in    std_logic_vector(63 downto 0) := (others => '0');
   sd_eng_o                : out   std_logic_vector(75 downto 0);

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- OSM menu bits (= line numbers of OPTM_ITEMS in config.vhd; keep single-line, make_rom.sh
-- scrapes them into osm_const.asm as PC_OSM_*)
---------------------------------------------------------------------------------------------

constant C_MENU_HDMI_720P     : natural := 5;
constant C_MENU_HDMI_480P     : natural := 6;
constant C_MENU_RESET         : natural := 11;  -- momentary: m2m-rom.asm resets through the CSR

-- The R6's SDRAM (IS42S16320F, 32M x 16): z486's 64 MB size code
constant C_RAM_SIZE           : std_logic_vector(1 downto 0) := "10";

---------------------------------------------------------------------------------------------
-- Clocks and resets
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;
signal main_rst               : std_logic;
signal video_clk              : std_logic;
signal video_rst              : std_logic;
signal audio_clk              : std_logic;
signal main_pc_reset          : std_logic;
signal main_pc_roms_ok        : std_logic_vector(0 downto 0);
signal qnice_pc_roms_ok       : std_logic_vector(0 downto 0) := "0";

-- The SDRAM clock (clk.vhd) and its phase, set from QNICE (C_DEV_PC_CTL, address 1)
signal main_sdram_clk         : std_logic;
signal qnice_sdram_ps_target  : std_logic_vector(15 downto 0) := (others => '0');
signal sdram_ps_pos           : std_logic_vector(15 downto 0);  -- clk_i
signal qnice_sdram_ps_pos     : std_logic_vector(15 downto 0);

---------------------------------------------------------------------------------------------
-- Debug (C_DEV_PC_CTL): the PC's boot and POST state, CS:EIP, and a log of its debug port
---------------------------------------------------------------------------------------------

signal main_dbg_boot_stage    : std_logic_vector(2 downto 0);
signal main_dbg_bios_loaded   : std_logic;
signal main_dbg_vga_checked   : std_logic;
signal main_dbg_vga_bad       : std_logic;
signal main_dbg_first_instr   : std_logic;
signal main_dbg_post_code     : std_logic_vector(7 downto 0);
signal main_dbg_post_write    : std_logic;
signal main_dbg_cpu_pe        : std_logic;
signal main_dbg_cpu_cs        : std_logic_vector(15 downto 0);
signal main_dbg_cpu_eip       : std_logic_vector(31 downto 0);
signal main_dbg_log_byte      : std_logic_vector(7 downto 0);
signal main_dbg_log_we        : std_logic;
signal main_dbg_mem_busy      : std_logic;

signal main_dbg_tick          : unsigned(19 downto 0) := (others => '0');
signal main_dbg_post_cnt      : unsigned(7 downto 0) := (others => '0');
signal main_dbg_log_cnt       : unsigned(15 downto 0) := (others => '0');
signal main_dbg_vs_cnt        : unsigned(15 downto 0) := (others => '0');
signal main_dbg_snap_cnt      : unsigned(15 downto 0) := (others => '0');
signal main_dbg_vs_d          : std_logic := '0';
signal main_dbg_post_last     : std_logic_vector(7 downto 0) := x"00";
signal main_dbg_post_new      : std_logic;
signal main_dbg_snap          : std_logic_vector(127 downto 0) := (others => '0');
signal qnice_dbg_snap         : std_logic_vector(127 downto 0);
signal main_dbg_log_wr        : std_logic;
signal main_dbg_log_entry     : std_logic_vector(9 downto 0);
signal qnice_dbg_log_q        : std_logic_vector(9 downto 0);

---------------------------------------------------------------------------------------------
-- The MEGA65 keyboard as a PS/2 keyboard (main clock)
---------------------------------------------------------------------------------------------

signal main_kbd_tx_valid      : std_logic;
signal main_kbd_tx_data       : std_logic_vector(7 downto 0);
signal main_kbd_tx_ready      : std_logic;
signal main_kbd_rx_valid      : std_logic;
signal main_kbd_rx_data       : std_logic_vector(7 downto 0);
signal main_kbd_dev_clk       : std_logic;     -- the keyboard's lines
signal main_kbd_dev_dat       : std_logic;
signal main_kbd_host_clk      : std_logic;     -- the 8042's lines
signal main_kbd_host_dat      : std_logic;

---------------------------------------------------------------------------------------------
-- z486's MiSTer DDR3 port (main clock) and its way into HyperRAM (hr clock)
---------------------------------------------------------------------------------------------

signal main_ddram_busy        : std_logic;
signal main_ddram_burstcnt    : std_logic_vector(7 downto 0);
signal main_ddram_addr        : std_logic_vector(28 downto 0);  -- DDR3, 64-bit words
signal main_ddram_dout        : std_logic_vector(63 downto 0);
signal main_ddram_dout_ready  : std_logic;
signal main_ddram_rd          : std_logic;
signal main_ddram_din         : std_logic_vector(63 downto 0);
signal main_ddram_be          : std_logic_vector(7 downto 0);
signal main_ddram_we          : std_logic;
signal main_hr_addr           : std_logic_vector(19 downto 0);  -- HyperRAM, 64-bit words

signal hr_wide_write          : std_logic;
signal hr_wide_read           : std_logic;
signal hr_wide_address        : std_logic_vector(19 downto 0);
signal hr_wide_writedata      : std_logic_vector(63 downto 0);
signal hr_wide_byteenable     : std_logic_vector(7 downto 0);
signal hr_wide_burstcount     : std_logic_vector(7 downto 0);
signal hr_wide_readdata       : std_logic_vector(63 downto 0);
signal hr_wide_readdatavalid  : std_logic;
signal hr_wide_waitrequest    : std_logic;
signal hr_core_address        : std_logic_vector(21 downto 0);  -- HyperRAM, 16-bit words

---------------------------------------------------------------------------------------------
-- The SVGA framebuffer descriptor (main clock) and the audio (audio clock)
---------------------------------------------------------------------------------------------

signal main_fb_en             : std_logic;
signal main_fb_format         : std_logic_vector(4 downto 0);
signal main_fb_base           : std_logic_vector(31 downto 0);  -- DDR3 byte address

signal audio_l                : std_logic_vector(15 downto 0);
signal audio_r                : std_logic_vector(15 downto 0);
signal main_audio             : std_logic_vector(31 downto 0);

---------------------------------------------------------------------------------------------
-- Drives (no bridge to the SD card yet: ide.v and floppy.v see an idle management bus)
---------------------------------------------------------------------------------------------

signal main_fdd_request       : std_logic_vector(1 downto 0);
signal main_ide0_request      : std_logic_vector(2 downto 0);
signal main_ide1_request      : std_logic_vector(2 downto 0);
signal main_mgmt_readdata     : std_logic_vector(15 downto 0);

component z486_mega65 is
   generic (
      CLK_HZ             : integer := 64_000_000
   );
   port (
      clk_sys            : in    std_logic;
      clk_audio          : in    std_logic;
      clk_sdram          : in    std_logic;
      reset              : in    std_logic;
      video_ce           : out   std_logic;
      video_r            : out   std_logic_vector(7 downto 0);
      video_g            : out   std_logic_vector(7 downto 0);
      video_b            : out   std_logic_vector(7 downto 0);
      video_hs           : out   std_logic;
      video_vs           : out   std_logic;
      video_hblank       : out   std_logic;
      video_vblank       : out   std_logic;
      fb_en              : out   std_logic;
      fb_width           : out   std_logic_vector(11 downto 0);
      fb_height          : out   std_logic_vector(11 downto 0);
      fb_format          : out   std_logic_vector(4 downto 0);
      fb_base            : out   std_logic_vector(31 downto 0);
      fb_stride          : out   std_logic_vector(13 downto 0);
      fb_pal_a           : out   std_logic_vector(7 downto 0);
      fb_pal_d           : out   std_logic_vector(23 downto 0);
      fb_pal_wr          : out   std_logic;
      ddram_busy         : in    std_logic;
      ddram_burstcnt     : out   std_logic_vector(7 downto 0);
      ddram_addr         : out   std_logic_vector(28 downto 0);
      ddram_dout         : in    std_logic_vector(63 downto 0);
      ddram_dout_ready   : in    std_logic;
      ddram_rd           : out   std_logic;
      ddram_din          : out   std_logic_vector(63 downto 0);
      ddram_be           : out   std_logic_vector(7 downto 0);
      ddram_we           : out   std_logic;
      sdram_clk          : out   std_logic;
      sdram_cke          : out   std_logic;
      sdram_a            : out   std_logic_vector(12 downto 0);
      sdram_ba           : out   std_logic_vector(1 downto 0);
      sdram_dq           : inout std_logic_vector(15 downto 0);
      sdram_dqml         : out   std_logic;
      sdram_dqmh         : out   std_logic;
      sdram_ncs          : out   std_logic;
      sdram_ncas         : out   std_logic;
      sdram_nras         : out   std_logic;
      sdram_nwe          : out   std_logic;
      audio_l            : out   std_logic_vector(15 downto 0);
      audio_r            : out   std_logic_vector(15 downto 0);
      mgmt_address       : in    std_logic_vector(15 downto 0);
      mgmt_read          : in    std_logic;
      mgmt_readdata      : out   std_logic_vector(15 downto 0);
      mgmt_write         : in    std_logic;
      mgmt_writedata     : in    std_logic_vector(15 downto 0);
      fdd_request        : out   std_logic_vector(1 downto 0);
      ide0_request       : out   std_logic_vector(2 downto 0);
      ide1_request       : out   std_logic_vector(2 downto 0);
      ps2_kbd_clk_in     : in    std_logic;
      ps2_kbd_data_in    : in    std_logic;
      ps2_kbd_clk_out    : out   std_logic;
      ps2_kbd_data_out   : out   std_logic;
      ps2_mouse_clk_in   : in    std_logic;
      ps2_mouse_data_in  : in    std_logic;
      ps2_mouse_clk_out  : out   std_logic;
      ps2_mouse_data_out : out   std_logic;
      ram_size           : in    std_logic_vector(1 downto 0);
      dbg_boot_stage     : out   std_logic_vector(2 downto 0);
      dbg_bios_loaded    : out   std_logic;
      dbg_vga_sig_checked : out  std_logic;
      dbg_vga_sig_bad    : out   std_logic;
      dbg_first_instr    : out   std_logic;
      dbg_post_code      : out   std_logic_vector(7 downto 0);
      dbg_post_write     : out   std_logic;
      dbg_cpu_pe         : out   std_logic;
      dbg_cpu_cs         : out   std_logic_vector(15 downto 0);
      dbg_cpu_eip        : out   std_logic_vector(31 downto 0);
      dbg_log_byte       : out   std_logic_vector(7 downto 0);
      dbg_log_we         : out   std_logic;
      dbg_mem_busy       : out   std_logic
   );
end component z486_mega65;

begin

   ---------------------------------------------------------------------------------------------
   -- Tie-offs: everything the PC does not use (yet)
   ---------------------------------------------------------------------------------------------

   -- M2M-UPSTREAM interlace: progressive
   video_fl_o           <= '0';

   -- M2M-UPSTREAM osm-hotkey: the classic Help key opens the menu
   osm_key_a_o          <= 67;
   osm_key_b_o          <= 67;
   osm_combo_o          <= '0';
   osm_block_o          <= '0';

   -- IEC port: idle
   iec_reset_n_o        <= '1';
   iec_atn_n_o          <= '1';
   iec_clk_en_o         <= '0';
   iec_clk_n_o          <= '1';
   iec_data_en_o        <= '0';
   iec_data_n_o         <= '1';
   iec_srq_en_o         <= '0';
   iec_srq_n_o          <= '1';

   -- M2M-UPSTREAM floppy-pins: the internal drive idle
   f_motora_o           <= '1';
   f_selecta_o          <= '1';
   f_stepdir_o          <= '1';
   f_step_o             <= '1';
   f_side1_o            <= '1';
   f_wdata_o            <= '1';
   f_wgate_o            <= '1';
   f_density_o          <= '1';

   -- M2M-UPSTREAM pmod-pins: headers unpowered, all pins high-Z
   p1lo_io              <= (others => 'Z');
   p1hi_io              <= (others => 'Z');
   p2lo_io              <= (others => 'Z');
   p2hi_io              <= (others => 'Z');
   pmod1_en_o           <= '0';
   pmod2_en_o           <= '0';

   -- M2M-UPSTREAM eth-pins: PHY held idle
   eth_clock_o          <= '0';
   eth_led2_o           <= '0';
   eth_mdc_o            <= '0';
   eth_mdio_io          <= 'Z';
   eth_reset_o          <= '1';
   eth_txd_o            <= (others => '0');
   eth_txen_o           <= '0';

   -- M2M-UPSTREAM sd-host: no engine requests (the framework's default)
   sd_eng_o             <= (others => '0');

   -- Expansion port: tristate everything; enabled because of the R5/R6 joystick port 2 bug
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';
   cart_en_o            <= '1';
   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';

   ---------------------------------------------------------------------------------------------
   -- Clocks
   ---------------------------------------------------------------------------------------------

   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- 64 MHz
         main_rst_o        => main_rst,
         video_clk_o       => video_clk,       -- the same clock
         video_rst_o       => video_rst,
         audio_clk_o       => audio_clk,       -- 24.556 MHz
         sdram_clk_o       => main_sdram_clk,  -- 64 MHz, 292.5 degrees + the fine phase
         sdram_ps_target_i => qnice_sdram_ps_target,
         sdram_ps_pos_o    => sdram_ps_pos
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= video_clk;
   video_rst_o <= video_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk
   ---------------------------------------------------------------------------------------------

   -- The PC is reset with the machine, by the Shell (cores start in reset until the firmware
   -- releases them) and by "Reset the PC" (m2m-rom.asm, through the CSR). It also stays in
   -- reset until its BIOS ROMs are in HyperRAM: z486's boot loader copies them from there the
   -- moment it leaves reset, and the Shell releases the core before PREP_START loads them.
   main_pc_reset <= main_rst or main_reset_m2m_i or main_reset_core_i or not main_pc_roms_ok(0);

   -- Power LED: green; blue while the reset button is held long. Drive LED: off (no drives yet).
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";
   main_drive_led_o     <= '0';
   main_drive_led_col_o <= x"00FF00";

   i_z486 : z486_mega65
      generic map (
         CLK_HZ             => CORE_CLK_SPEED
      )
      port map (
         clk_sys            => main_clk,
         clk_audio          => audio_clk,
         clk_sdram          => main_sdram_clk,
         reset              => main_pc_reset,

         video_ce           => video_ce_o,
         video_r            => video_red_o,
         video_g            => video_green_o,
         video_b            => video_blue_o,
         video_hs           => video_hs_o,
         video_vs           => video_vs_o,
         video_hblank       => video_hblank_o,
         video_vblank       => video_vblank_o,

         fb_en              => main_fb_en,
         fb_width           => fb_hsize_o,
         fb_height          => fb_vsize_o,
         fb_format          => main_fb_format,
         fb_base            => main_fb_base,
         fb_stride          => fb_stride_o,
         fb_pal_a           => fb_pal_a_o,
         fb_pal_d           => fb_pal_dw_o,
         fb_pal_wr          => fb_pal_wr_o,

         ddram_busy         => main_ddram_busy,
         ddram_burstcnt     => main_ddram_burstcnt,
         ddram_addr         => main_ddram_addr,
         ddram_dout         => main_ddram_dout,
         ddram_dout_ready   => main_ddram_dout_ready,
         ddram_rd           => main_ddram_rd,
         ddram_din          => main_ddram_din,
         ddram_be           => main_ddram_be,
         ddram_we           => main_ddram_we,

         sdram_clk          => sdram_clk_o,
         sdram_cke          => sdram_cke_o,
         sdram_a            => sdram_a_o,
         sdram_ba           => sdram_ba_o,
         sdram_dq           => sdram_dq_io,
         sdram_dqml         => sdram_dqml_o,
         sdram_dqmh         => sdram_dqmh_o,
         sdram_ncs          => sdram_cs_n_o,
         sdram_ncas         => sdram_cas_n_o,
         sdram_nras         => sdram_ras_n_o,
         sdram_nwe          => sdram_we_n_o,

         audio_l            => audio_l,
         audio_r            => audio_r,

         mgmt_address       => (others => '0'),
         mgmt_read          => '0',
         mgmt_readdata      => main_mgmt_readdata,
         mgmt_write         => '0',
         mgmt_writedata     => (others => '0'),
         fdd_request        => main_fdd_request,
         ide0_request       => main_ide0_request,
         ide1_request       => main_ide1_request,

         ps2_kbd_clk_in     => main_kbd_dev_clk,
         ps2_kbd_data_in    => main_kbd_dev_dat,
         ps2_kbd_clk_out    => main_kbd_host_clk,
         ps2_kbd_data_out   => main_kbd_host_dat,
         ps2_mouse_clk_in   => '1',            -- no mouse yet: idle lines
         ps2_mouse_data_in  => '1',
         ps2_mouse_clk_out  => open,
         ps2_mouse_data_out => open,

         ram_size           => C_RAM_SIZE,

         dbg_boot_stage     => main_dbg_boot_stage,
         dbg_bios_loaded    => main_dbg_bios_loaded,
         dbg_vga_sig_checked => main_dbg_vga_checked,
         dbg_vga_sig_bad    => main_dbg_vga_bad,
         dbg_first_instr    => main_dbg_first_instr,
         dbg_post_code      => main_dbg_post_code,
         dbg_post_write     => main_dbg_post_write,
         dbg_cpu_pe         => main_dbg_cpu_pe,
         dbg_cpu_cs         => main_dbg_cpu_cs,
         dbg_cpu_eip        => main_dbg_cpu_eip,
         dbg_log_byte       => main_dbg_log_byte,
         dbg_log_we         => main_dbg_log_we,
         dbg_mem_busy       => main_dbg_mem_busy
      ); -- i_z486

   -- The MEGA65 keyboard as the PC's PS/2 keyboard. Not reset with the PC, as a real one
   -- is not: the BIOS resets it with command FF.
   i_pc_keyboard : entity work.pc_keyboard
      generic map (
         G_CLK_HZ        => CORE_CLK_SPEED
      )
      port map (
         clk_i           => main_clk,
         rst_i           => main_rst,
         key_num_i       => main_kb_key_num_i,
         key_pressed_n_i => main_kb_key_pressed_n_i,
         tx_valid_o      => main_kbd_tx_valid,
         tx_data_o       => main_kbd_tx_data,
         tx_ready_i      => main_kbd_tx_ready,
         rx_valid_i      => main_kbd_rx_valid,
         rx_data_i       => main_kbd_rx_data
      ); -- i_pc_keyboard

   i_ps2_keyboard : entity work.ps2_device
      generic map (
         G_PS2_DIV  => CORE_CLK_SPEED / 32_000  -- 16 kHz
      )
      port map (
         clk_i      => main_clk,
         rst_i      => main_rst,
         tx_valid_i => main_kbd_tx_valid,
         tx_data_i  => main_kbd_tx_data,
         tx_ready_o => main_kbd_tx_ready,
         rx_valid_o => main_kbd_rx_valid,
         rx_data_o  => main_kbd_rx_data,
         ps2_clk_i  => main_kbd_host_clk,
         ps2_dat_i  => main_kbd_host_dat,
         ps2_clk_o  => main_kbd_dev_clk,
         ps2_dat_o  => main_kbd_dev_dat
      ); -- i_ps2_keyboard

   -- Debug: every 2^20 clocks (16 ms) a snapshot of the PC's state, still for long enough to
   -- cross to QNICE whole (cdc_stable). The log keeps the last 4096 entries: bits 9..8 say
   -- what bits 7..0 are, 00 a byte of the PC's debug port (the BIOS's port 0x402, the
   -- watchdog's stall messages), 01 a POST code, only when it changes (the Bochs BIOS writes
   -- port 0x80 as an I/O delay, thousands of zeros), 10 a byte from the 8042 to the keyboard,
   -- 11 one from the keyboard. Each PC reset starts the counters and the log afresh.
   p_main_dbg : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_dbg_tick <= main_dbg_tick + 1;
         main_dbg_vs_d <= video_vs_o;
         if video_vs_o = '1' and main_dbg_vs_d = '0' then
            main_dbg_vs_cnt <= main_dbg_vs_cnt + 1;
         end if;
         if main_dbg_post_write = '1' then
            main_dbg_post_cnt <= main_dbg_post_cnt + 1;
         end if;
         if main_dbg_log_wr = '1' then
            main_dbg_log_cnt <= main_dbg_log_cnt + 1;
         end if;
         if main_dbg_tick = 0 then
            main_dbg_snap_cnt <= main_dbg_snap_cnt + 1;
            main_dbg_snap <= std_logic_vector(main_dbg_snap_cnt) &
                             std_logic_vector(main_dbg_vs_cnt) &
                             std_logic_vector(main_dbg_log_cnt) &
                             main_dbg_cpu_eip &
                             main_dbg_cpu_cs &
                             std_logic_vector(main_dbg_post_cnt) & main_dbg_post_code &
                             "000000" & main_pc_reset & main_dbg_mem_busy & main_dbg_cpu_pe &
                             main_dbg_first_instr & main_dbg_vga_bad & main_dbg_vga_checked &
                             main_dbg_bios_loaded & main_dbg_boot_stage;
         end if;
         if main_dbg_post_write = '1' then
            main_dbg_post_last <= main_dbg_post_code;
         end if;
         if main_pc_reset = '1' then
            main_dbg_post_last <= x"00";
            main_dbg_post_cnt <= (others => '0');
            main_dbg_log_cnt  <= (others => '0');
            main_dbg_vs_cnt   <= (others => '0');
         end if;
      end if;
   end process p_main_dbg;

   main_dbg_post_new  <= '1' when main_dbg_post_write = '1' and main_dbg_post_code /= main_dbg_post_last
                    else '0';
   main_dbg_log_wr    <= main_dbg_post_new or main_dbg_log_we or main_kbd_rx_valid or
                         (main_kbd_tx_valid and main_kbd_tx_ready);
   main_dbg_log_entry <= "01" & main_dbg_post_code when main_dbg_post_new = '1' else
                         "00" & main_dbg_log_byte  when main_dbg_log_we = '1' else
                         "10" & main_kbd_rx_data   when main_kbd_rx_valid = '1' else
                         "11" & main_kbd_tx_data;

   i_dbg_log : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 12,
         DATA_WIDTH => 10,
         FALLING_B  => true                    -- QNICE's device convention
      )
      port map (
         clock_a    => main_clk,
         address_a  => std_logic_vector(main_dbg_log_cnt(11 downto 0)),
         data_a     => main_dbg_log_entry,
         wren_a     => main_dbg_log_wr,
         q_a        => open,
         clock_b    => qnice_clk_i,
         address_b  => qnice_dev_addr_i(11 downto 0),
         q_b        => qnice_dbg_log_q
      ); -- i_dbg_log

   i_cdc_dbg_snap : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 128
      )
      port map (
         src_data_i => main_dbg_snap,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_dbg_snap
      ); -- i_cdc_dbg_snap

   -- One pixel clock enable for the picture and the OSM: the OSM canvas is the VGA's 640 wide
   video_ce_ovl_o <= video_ce_o;

   -- M2M-UPSTREAM rtg-framebuffer: ascal shows the SVGA framebuffer from HyperRAM while
   -- fb_ena_o = '1' (HDMI only). z486's DDR3 window 0x3F800000 is HyperRAM 0x400000 (below).
   fb_ena_o     <= main_fb_en;
   fb_format_o  <= '0' & main_fb_format;
   fb_base_o    <= x"00" & "01" & main_fb_base(21 downto 0);
   fb_pal_clk_o <= main_clk;

   ---------------------------------------------------------------------------------------------
   -- z486's DDR3 port in HyperRAM. DDR3 byte 0x3F800000.. (the SVGA framebuffer, 4 MB) is
   -- HyperRAM 0x400000..0x7FFFFF; everything else (the boot image at 0x300C0000) folds into
   -- HyperRAM 0x200000..0x3FFFFF. The framework's ascal buffer stays below 0x200000.
   ---------------------------------------------------------------------------------------------

   main_hr_addr <= "1"  & main_ddram_addr(18 downto 0) when main_ddram_addr(28 downto 19) = "0011111110" else
                   "01" & main_ddram_addr(17 downto 0);

   i_avm_fifo_ddram : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 20,
         G_DATA_SIZE    => 64
      )
      port map (
         s_clk_i               => main_clk,
         s_rst_i               => main_rst,
         s_avm_waitrequest_o   => main_ddram_busy,
         s_avm_write_i         => main_ddram_we,
         s_avm_read_i          => main_ddram_rd,
         s_avm_address_i       => main_hr_addr,
         s_avm_writedata_i     => main_ddram_din,
         s_avm_byteenable_i    => main_ddram_be,
         s_avm_burstcount_i    => main_ddram_burstcnt,
         s_avm_readdata_o      => main_ddram_dout,
         s_avm_readdatavalid_o => main_ddram_dout_ready,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => hr_wide_waitrequest,
         m_avm_write_o         => hr_wide_write,
         m_avm_read_o          => hr_wide_read,
         m_avm_address_o       => hr_wide_address,
         m_avm_writedata_o     => hr_wide_writedata,
         m_avm_byteenable_o    => hr_wide_byteenable,
         m_avm_burstcount_o    => hr_wide_burstcount,
         m_avm_readdata_i      => hr_wide_readdata,
         m_avm_readdatavalid_i => hr_wide_readdatavalid
      ); -- i_avm_fifo_ddram

   i_avm_decrease_ddram : entity work.avm_decrease
      generic map (
         G_SLAVE_ADDRESS_SIZE  => 20,
         G_SLAVE_DATA_SIZE     => 64,
         G_MASTER_ADDRESS_SIZE => 22,
         G_MASTER_DATA_SIZE    => 16
      )
      port map (
         clk_i                 => hr_clk_i,
         rst_i                 => hr_rst_i,
         s_avm_write_i         => hr_wide_write,
         s_avm_read_i          => hr_wide_read,
         s_avm_address_i       => hr_wide_address,
         s_avm_writedata_i     => hr_wide_writedata,
         s_avm_byteenable_i    => hr_wide_byteenable,
         s_avm_burstcount_i    => hr_wide_burstcount,
         s_avm_readdata_o      => hr_wide_readdata,
         s_avm_readdatavalid_o => hr_wide_readdatavalid,
         s_avm_waitrequest_o   => hr_wide_waitrequest,
         m_avm_write_o         => hr_core_write_o,
         m_avm_read_o          => hr_core_read_o,
         m_avm_address_o       => hr_core_address,
         m_avm_writedata_o     => hr_core_writedata_o,
         m_avm_byteenable_o    => hr_core_byteenable_o,
         m_avm_burstcount_o    => hr_core_burstcount_o,
         m_avm_readdata_i      => hr_core_readdata_i,
         m_avm_readdatavalid_i => hr_core_readdatavalid_i,
         m_avm_waitrequest_i   => hr_core_waitrequest_i
      ); -- i_avm_decrease_ddram

   hr_core_address_o <= "0000000000" & hr_core_address;

   ---------------------------------------------------------------------------------------------
   -- Audio: the samples change at the sample rate, hundreds of clocks apart (cdc_stable)
   ---------------------------------------------------------------------------------------------

   i_cdc_audio : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 32,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i  => audio_clk,
         src_data_i => audio_l & audio_r,
         dst_clk_i  => main_clk,
         dst_data_o => main_audio
      ); -- i_cdc_audio

   main_audio_left_o  <= signed(main_audio(31 downto 16));
   main_audio_right_o <= signed(main_audio(15 downto 0));

   ---------------------------------------------------------------------------------------------
   -- QNICE clock domain: video and audio settings, core devices (none yet)
   ---------------------------------------------------------------------------------------------

   qnice_video_mode_o <= C_VIDEO_HDMI_720_5994 when qnice_osm_control_i(C_MENU_HDMI_480P) = '1' else
                         C_VIDEO_HDMI_16_9_60;

   qnice_dvi_o                <= '0';         -- HDMI with sound
   qnice_scandoubler_o        <= '0';         -- the PC's VGA is 31 kHz already
   qnice_retro15kHz_o         <= '0';
   qnice_csync_o              <= '0';
   qnice_audio_mute_o         <= '0';
   qnice_audio_filter_o       <= '0';
   qnice_zoom_crop_o          <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');
   qnice_ascal_mode_o         <= "00";
   qnice_ascal_polyphase_o    <= '0';
   qnice_ascal_triplebuf_o    <= '0';
   qnice_flip_joyports_o      <= '0';

   -- C_DEV_PC_CTL (globals.vhd):
   --    0x0000      bit 0 = the PC's BIOS ROMs are in HyperRAM. Written by m2m-rom.asm
   --                (PREP_START); cleared with QNICE, whose firmware then loads them again.
   --                Clearing and setting it resets the PC.
   --    0x0001      the SDRAM clock's phase, signed fine steps from 292.5 degrees (clk.vhd)
   --    0x0002      read: where the phase shift is
   --    0x0010..17  read: the debug snapshot (p_main_dbg): status (bits 2..0 boot stage, 3 BIOS
   --                copied, 4/5 VGA BIOS signature checked/bad, 6 first instruction, 7 CPU PE,
   --                8 SDRAM busy, 9 PC in reset), POST count:code, CS, EIP low, EIP high,
   --                log count, VGA vsync count, snapshot count
   --    0x1000..1FFF read: the log (p_main_dbg), entry n at 0x1000 + n mod 4096
   p_qnice_pc_ctl : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and qnice_dev_id_i = C_DEV_PC_CTL then
            if qnice_dev_addr_i = x"0000000" then
               qnice_pc_roms_ok(0) <= qnice_dev_data_i(0);
            elsif qnice_dev_addr_i = x"0000001" then
               qnice_sdram_ps_target <= qnice_dev_data_i;
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_pc_roms_ok(0) <= '0';
         end if;
      end if;
   end process p_qnice_pc_ctl;

   p_qnice_dev_data : process (all)
      variable v_word : natural range 0 to 7;
   begin
      v_word := to_integer(unsigned(qnice_dev_addr_i(2 downto 0)));
      qnice_dev_data_o <= x"EEEE";
      if qnice_dev_id_i = C_DEV_PC_CTL then
         if qnice_dev_addr_i = x"0000000" then
            qnice_dev_data_o <= x"000" & "000" & qnice_pc_roms_ok(0);
         elsif qnice_dev_addr_i = x"0000001" then
            qnice_dev_data_o <= qnice_sdram_ps_target;
         elsif qnice_dev_addr_i = x"0000002" then
            qnice_dev_data_o <= qnice_sdram_ps_pos;
         elsif qnice_dev_addr_i(27 downto 3) = "0000000000000000000000010" then
            qnice_dev_data_o <= qnice_dbg_snap(16 * v_word + 15 downto 16 * v_word);
         elsif qnice_dev_addr_i(27 downto 12) = x"0001" then
            qnice_dev_data_o <= "000000" & qnice_dbg_log_q;
         end if;
      end if;
   end process p_qnice_dev_data;
   qnice_dev_wait_o <= '0';

   i_cdc_sdram_ps_pos : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         src_data_i => sdram_ps_pos,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_sdram_ps_pos
      ); -- i_cdc_sdram_ps_pos

   -- A level that changes once per boot
   i_cdc_pc_roms_ok : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1
      )
      port map (
         src_data_i => qnice_pc_roms_ok,
         dst_clk_i  => main_clk,
         dst_data_o => main_pc_roms_ok
      ); -- i_cdc_pc_roms_ok

end architecture synthesis;

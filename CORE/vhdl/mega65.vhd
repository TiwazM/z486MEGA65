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
-- * a mouse on joystick port 1 (an Amiga mouse, or a mouSTer in Amiga mode, F13 the right
--   button; or a 1351, or a mouSTer in C64 mode, with both buttons) as a PS/2 mouse
--   (pc_mouse.vhd, ps2_device.vhd)
-- * the management bus in hardware (pc_mgmt.vhd: CMOS, floppy, hard disk; pc_cdrom.vhd: the
--   CD-ROM drive) and the disks from image files on the SD card (disk_sd.vhd, through the SD
--   host controller's engine port): floppy drives A: and B:, the hard disk on the first IDE
--   channel, the CD-ROM drive (an ISO image) on the second
--
-- Not wired yet: joysticks.
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

library xpm;
use xpm.vcomponents.all;

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
   qnice_scanlines_o       : out std_logic_vector(1 downto 0);  -- 00 off, 01 25 %, 10 50 %
   -- M2M-UPSTREAM native: bit 24 = the picture unscaled in a 23..12 x 11..0 window
   qnice_native_o          : out std_logic_vector(24 downto 0);
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
   -- M2M-UPSTREAM vga-polarity: the VGA connector's sync polarity as the PC's VGA sets it
   -- (bit 0 HSYNC, bit 1 VSYNC; 1 = negative). video_hs_o/video_vs_o stay active-high.
   video_vga_pol_o         : out std_logic_vector(1 downto 0);

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

constant C_MENU_FDD_A          : natural := 2;   -- manual load 0 (m2m-rom.asm DISK_PREP)
constant C_MENU_FDD_B          : natural := 3;   -- manual load 1
constant C_MENU_HDD            : natural := 4;   -- manual load 2
constant C_MENU_CD            : natural := 5;   -- manual load 3
constant C_MENU_HDMI_720P     : natural := 10;
constant C_MENU_HDMI_480P     : natural := 11;
constant C_MENU_HDMI_800      : natural := 12;
constant C_MENU_HDMI_1024     : natural := 13;
constant C_MENU_HDMI_1280     : natural := 14;  -- M2M-UPSTREAM sxga-mode
constant C_MENU_HDMI_NATIVE   : natural := 15;  -- M2M-UPSTREAM native: the PC's own resolution
constant C_MENU_FLT_SMOOTH    : natural := 22;  -- (21: Sharp, the default)
constant C_MENU_FLT_PIXELS    : natural := 23;
constant C_MENU_SL_25         : natural := 30;  -- (29: Off, the default)
constant C_MENU_SL_50         : natural := 31;
constant C_MENU_RF_ORIG       : natural := 38;  -- the VGA's own refresh (37: 60 Hz, the default)
constant C_MENU_JOY_P5        : natural := 45;  -- the game port's fire 2 on pin 5 (44: pin 9)
constant C_MENU_JOY_OFF       : natural := 46;  -- no joystick on the game port (201h reads FFh)
constant C_MENU_RESET         : natural := 51;  -- momentary: m2m-rom.asm resets through the CSR

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
signal main_hr_rst            : std_logic;
signal main_cpu_slow          : std_logic := '0';
signal main_joy_dig           : std_logic_vector(7 downto 0);    -- the game port's joystick
signal main_joy_b2            : std_logic := '0';
signal main_joy_b3            : std_logic := '0';
signal main_ddram_rst         : std_logic;
signal main_pc_roms_ok        : std_logic_vector(0 downto 0);
signal qnice_pc_roms_ok       : std_logic_vector(0 downto 0) := "0";

-- The SDRAM clock (clk.vhd) and its phase, set from QNICE (C_DEV_PC_CTL, address 1)
signal main_sdram_clk         : std_logic;
signal qnice_sdram_ps_target  : std_logic_vector(15 downto 0) := (others => '0');
signal qnice_l2_on            : std_logic_vector(1 downto 0) := "11";  -- 0: the L2 (guest_l2.sv), 1: z486's L1
signal main_l2_on             : std_logic_vector(1 downto 0);
signal main_l2_hits           : std_logic_vector(31 downto 0);
signal main_l2_misses         : std_logic_vector(31 downto 0);
signal sdram_ps_pos           : std_logic_vector(15 downto 0);  -- clk_i
signal qnice_sdram_ps_pos     : std_logic_vector(15 downto 0);
signal qnice_xadc             : std_logic_vector(15 downto 0);   -- xadc_mon.vhd's value

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
signal main_dbg_io_rd         : std_logic_vector(23 downto 0);   -- the last I/O read: port, byte
signal main_dbg_io_wr         : std_logic_vector(23 downto 0);   -- the last I/O write
signal main_vga_pol           : std_logic_vector(1 downto 0) := "00";  -- VSYNC, HSYNC negative
signal main_dbg_sb_req        : std_logic_vector(1 downto 0);    -- the SB's DMA requests
signal main_dbg_sb_irq        : std_logic;
signal main_dbg_io_rd_stb     : std_logic;                       -- main_dbg_io_rd/wr are new
signal main_dbg_io_wr_stb     : std_logic;
signal main_dbg_sb_cmd_wait   : std_logic;                       -- a DSP DMA command held back
signal main_dbg_sb_smp_stb    : std_logic;                       -- a DSP DMA output sample:
signal main_dbg_sb_smp_dif    : std_logic_vector(15 downto 0);   -- its jump from the last one
signal main_dbg_sb_smp_pos    : std_logic_vector(15 downto 0);   -- its index in the block
signal main_dbg_pic           : std_logic_vector(47 downto 0);   -- the PICs' IRR, ISR, IMR
signal main_dbg_irq           : std_logic_vector(15 downto 0);   -- the IRQ lines into them
signal main_dbg_ps2           : std_logic_vector(15 downto 0);   -- the 8042's state
signal main_dbg_ps2_fifo      : std_logic_vector(15 downto 0);   -- its FIFOs' bytes
signal main_dbg_inta_bad      : std_logic_vector(15 downto 0);   -- INTAs acknowledged otherwise
signal main_dbg_inta_last     : std_logic_vector(15 downto 0);   -- the last: CPU's, PIC's vector

-- The DMA and Sound Blaster I/O trace (p_main_iot)
signal main_iot_div           : unsigned(5 downto 0) := (others => '0');
signal main_iot_tick          : std_logic := '0';                -- a microsecond
signal main_iot_us            : unsigned(31 downto 0) := (others => '0');
signal main_iot_cnt           : unsigned(15 downto 0) := (others => '0');  -- entries written
signal main_iot_full          : std_logic := '0';                -- 1024 or more
signal main_iot_run           : std_logic := '1';
signal main_iot_we            : std_logic := '0';
signal main_iot_entry         : std_logic_vector(63 downto 0) := (others => '0');
signal main_iot_last_rd       : std_logic_vector(23 downto 0) := (others => '1');
signal main_iot_irq_d         : std_logic := '0';
signal main_iot_irq_p         : std_logic := '0';
signal main_iot_req_d         : std_logic_vector(1 downto 0) := "00";
signal main_iot_wait          : unsigned(15 downto 0) := (others => '0');  -- us the request is up
signal main_iot_stall         : unsigned(15 downto 0) := (others => '0');
signal main_iot_stall_req     : std_logic_vector(1 downto 0) := "00";
signal main_iot_stall_p       : std_logic := '0';
signal main_iot_freeze_p      : std_logic := '0';
signal main_iot_imr           : std_logic_vector(7 downto 0) := x"FF";  -- the last write to 21
signal main_iot_cwait         : unsigned(15 downto 0) := (others => '0');  -- us a command waits
signal main_iot_cdef          : unsigned(15 downto 0) := (others => '0');
signal main_iot_cdef_p        : std_logic := '0';
signal main_iot_clong_p       : std_logic := '0';
signal main_iot_jump_p        : std_logic := '0';
signal main_iot_jump          : std_logic_vector(7 downto 0) := (others => '0');
signal main_iot_jpos          : std_logic_vector(15 downto 0) := (others => '0');
-- 7..0 changed: start again, 8: stop at a 1 ms wait, 9: stop now, 10: the Sound Blaster's
-- stalled-transfer fix off (sound_dsp.v's dma_take_starved), 11: stop when full, 19..12: the
-- smallest sample jump logged, in 256ths (default 0x40, a quarter of the full range), 20: the
-- PIC's vector hold from the first INTA off (pic_inta_bridge.sv's vector_hold), 22..21: a 1351
-- mouse's y and x reversed (pc_mouse.vhd's flip_i), 23: its x and y swapped (main_m1351_x)
signal main_iot_arm           : std_logic_vector(23 downto 0);
signal main_iot_arm_d         : std_logic_vector(23 downto 0) := (others => '0');
signal main_iot_stat          : std_logic_vector(17 downto 0);
signal qnice_iot_arm          : std_logic_vector(23 downto 0) := x"040000";
signal qnice_iot_stat         : std_logic_vector(17 downto 0);
signal qnice_iot_q            : std_logic_vector(63 downto 0);

signal main_dbg_tick          : unsigned(19 downto 0) := (others => '0');
signal main_dbg_post_cnt      : unsigned(7 downto 0) := (others => '0');
signal main_dbg_log_cnt       : unsigned(15 downto 0) := (others => '0');
signal main_dbg_vs_cnt        : unsigned(15 downto 0) := (others => '0');
signal main_dbg_snap_cnt      : unsigned(15 downto 0) := (others => '0');
signal main_dbg_vs_d          : std_logic := '0';
signal main_dbg_post_last     : std_logic_vector(7 downto 0) := x"00";
signal main_dbg_post_new      : std_logic;
signal main_dbg_snap          : std_logic_vector(255 downto 0) := (others => '0');
signal qnice_dbg_snap         : std_logic_vector(255 downto 0);
signal main_dbg_snap2         : std_logic_vector(255 downto 0) := (others => '0');  -- PICs, 8042
signal qnice_dbg_snap2        : std_logic_vector(255 downto 0);
signal main_dbg_log_wr        : std_logic;
signal main_dbg_log_entry     : std_logic_vector(11 downto 0);
signal qnice_dbg_log_q        : std_logic_vector(11 downto 0);
-- the CD-ROM drive (pc_cdrom.vhd): its track table (C_DEV_PC_CDTOC), its audio and status
signal main_cd_tab_addr       : std_logic_vector(11 downto 0);
signal main_cd_tab_q          : std_logic_vector(15 downto 0);
signal main_cd_l              : std_logic_vector(15 downto 0);
signal main_cd_r              : std_logic_vector(15 downto 0);
signal main_cd_stat           : std_logic_vector(63 downto 0);
signal qnice_cd_stat          : std_logic_vector(63 downto 0);
signal qnice_cdtoc_q          : std_logic_vector(15 downto 0);
signal qnice_cdtoc_we         : std_logic;
-- the IDE trace (pc_mgmt.vhd, pc_cdrom.vhd): sequence number, milliseconds, the event
signal main_tr_we             : std_logic;
signal main_tr_d              : std_logic_vector(63 downto 0);
signal main_tr_seq            : unsigned(15 downto 0) := (others => '0');
signal main_tr_div            : unsigned(15 downto 0) := (others => '0');
signal main_tr_ms             : unsigned(15 downto 0) := (others => '0');
signal main_tr_entry          : std_logic_vector(95 downto 0);
signal qnice_tr_q             : std_logic_vector(95 downto 0);
-- Native: the PC's picture size (main clock: the frame being measured, the last frame, the one
-- that held for eight frames; QNICE: the HDMI mode and window for it)
signal main_nat_de_d          : std_logic := '0';
signal main_nat_vb_d          : std_logic := '0';
signal main_nat_cnt           : unsigned(11 downto 0) := (others => '0');
signal main_nat_wmax          : unsigned(11 downto 0) := (others => '0');
signal main_nat_lines         : unsigned(11 downto 0) := (others => '0');
signal main_nat_w             : unsigned(11 downto 0) := (others => '0');
signal main_nat_h             : unsigned(11 downto 0) := (others => '0');
signal main_nat_same          : natural range 0 to 7 := 0;
signal main_nat_size          : std_logic_vector(24 downto 0) := (others => '0');  -- 70 Hz, w, h
signal main_nat_per           : unsigned(20 downto 0) := (others => '0');          -- clocks this frame
signal main_nat_slow          : std_logic := '0';     -- this frame is longer than 1/65 s
signal main_nat_f             : std_logic := '0';     -- the last frame was shorter
signal qnice_nat_size         : std_logic_vector(24 downto 0);
signal qnice_nat_mode         : video_mode_type := C_VIDEO_HDMI_640_60;
signal qnice_nat_on           : std_logic := '0';
signal qnice_nat_w            : natural range 0 to 4095 := 640;
signal qnice_nat_h            : natural range 0 to 4095 := 480;

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
signal main_c1351             : std_logic;                       -- a 1351 on port 1
-- the paddle lines as a 1351's x and y (port 1) and the game port's fire 2 and 3 (port 2)
signal main_m1351_x           : std_logic_vector(7 downto 0);
signal main_m1351_y           : std_logic_vector(7 downto 0);
signal main_fire2_pot         : std_logic_vector(7 downto 0);
signal main_fire3_pot         : std_logic_vector(7 downto 0);
signal main_mouse_tx_valid    : std_logic;
signal main_mouse_tx_data     : std_logic_vector(7 downto 0);
signal main_mouse_tx_ready    : std_logic;
signal main_mouse_rx_valid    : std_logic;
signal main_mouse_rx_data     : std_logic_vector(7 downto 0);
signal main_mouse_dev_clk     : std_logic;
signal main_mouse_dev_dat     : std_logic;
signal main_mouse_host_clk    : std_logic;
signal main_mouse_host_dat    : std_logic;

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
-- Drives: the management bus (pc_mgmt.vhd) and the disks from the SD card (disk_sd.vhd)
---------------------------------------------------------------------------------------------

signal main_fdd_request       : std_logic_vector(1 downto 0);
signal main_ide0_request      : std_logic_vector(2 downto 0);
signal main_ide1_request      : std_logic_vector(2 downto 0);
signal main_mgmt_address      : std_logic_vector(15 downto 0);
signal main_mgmt_read         : std_logic;
signal main_mgmt_write        : std_logic;
signal main_mgmt_writedata    : std_logic_vector(15 downto 0);
signal main_mgmt_readdata     : std_logic_vector(15 downto 0);

signal main_disk_req          : std_logic;
signal main_disk_req_wr       : std_logic;
signal main_disk_req_unit     : std_logic_vector(1 downto 0);
signal main_disk_req_lba      : std_logic_vector(31 downto 0);
signal main_disk_req_cnt      : std_logic_vector(8 downto 0);
signal main_disk_req_fresh    : std_logic;
signal main_disk_buf_addr     : std_logic_vector(8 downto 0);
signal main_disk_buf_we       : std_logic;
signal main_disk_buf_wd       : std_logic_vector(7 downto 0);
signal main_disk_buf_rd       : std_logic_vector(7 downto 0);
signal main_disk_buf_bad      : std_logic;

signal qnice_disk_done        : std_logic;
signal qnice_disk_done_err    : std_logic;
signal qnice_disk_mnt         : std_logic_vector(159 downto 0);
signal qnice_disk_ce          : std_logic;
signal qnice_disk_data        : std_logic_vector(15 downto 0);
signal qnice_disk_wait        : std_logic;
signal qnice_disk_sel         : std_logic;
signal qnice_disk_unit        : std_logic_vector(1 downto 0);

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
      joy_dig            : in    std_logic_vector(7 downto 0);
      joy_off            : in    std_logic;
      cpu_slow           : in    std_logic;
      video_f60          : in    std_logic;
      ram_size           : in    std_logic_vector(1 downto 0);
      l2_enable          : in    std_logic;
      cache_off          : in    std_logic;
      sb_take_starved    : in    std_logic;
      l2_hits            : out   std_logic_vector(31 downto 0);
      l2_misses          : out   std_logic_vector(31 downto 0);
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
      dbg_mem_busy       : out   std_logic;
      dbg_io_rd          : out   std_logic_vector(23 downto 0);
      dbg_io_wr          : out   std_logic_vector(23 downto 0);
      dbg_sb_req         : out   std_logic_vector(1 downto 0);
      dbg_sb_irq         : out   std_logic;
      dbg_io_rd_stb      : out   std_logic;
      dbg_io_wr_stb      : out   std_logic;
      dbg_sb_cmd_wait    : out   std_logic;
      dbg_sb_smp_stb     : out   std_logic;
      dbg_sb_smp_dif     : out   std_logic_vector(15 downto 0);
      dbg_sb_smp_pos     : out   std_logic_vector(15 downto 0);
      inta_hold          : in    std_logic;
      dbg_pic            : out   std_logic_vector(47 downto 0);
      dbg_irq            : out   std_logic_vector(15 downto 0);
      dbg_ps2            : out   std_logic_vector(15 downto 0);
      dbg_ps2_fifo       : out   std_logic_vector(15 downto 0);
      dbg_inta_bad       : out   std_logic_vector(15 downto 0);
      dbg_inta_last      : out   std_logic_vector(15 downto 0);
      cd_l               : in    std_logic_vector(15 downto 0);
      cd_r               : in    std_logic_vector(15 downto 0)
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

   -- M2M-UPSTREAM sd-host: the engine port belongs to the disks (disk_sd.vhd, below)

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
   -- And while the HyperRAM side is in reset (main_hr_rst, below): the reset button resets
   -- HyperRAM with the core, and a boot read sent before it is back was lost (stage 2 for good).
   main_pc_reset <= main_rst or main_hr_rst or main_reset_m2m_i or main_reset_core_i or
                    not main_pc_roms_ok(0);

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

         mgmt_address       => main_mgmt_address,
         mgmt_read          => main_mgmt_read,
         mgmt_readdata      => main_mgmt_readdata,
         mgmt_write         => main_mgmt_write,
         mgmt_writedata     => main_mgmt_writedata,
         fdd_request        => main_fdd_request,
         ide0_request       => main_ide0_request,
         ide1_request       => main_ide1_request,

         ps2_kbd_clk_in     => main_kbd_dev_clk,
         ps2_kbd_data_in    => main_kbd_dev_dat,
         ps2_kbd_clk_out    => main_kbd_host_clk,
         ps2_kbd_data_out   => main_kbd_host_dat,
         ps2_mouse_clk_in   => main_mouse_dev_clk,
         ps2_mouse_data_in  => main_mouse_dev_dat,
         joy_dig            => main_joy_dig,
         -- "Joystick: Off": the game port without a stick, as a PC with none plugged in (the
         -- MEGA65 can't tell a released digital stick from an empty port, and DOS Quake, finding
         -- one, stops to calibrate it with its prompts off screen)
         joy_off            => main_osm_control_i(C_MENU_JOY_OFF),
         cpu_slow           => main_cpu_slow,
         -- the menu's "Refresh": 60 Hz (the default) or the VGA's own timing, which analog
         -- VGA monitors recognise (DOS text 720x400 at 70 Hz, 31.5 kHz; 60 Hz text has
         -- 26.9 kHz lines)
         video_f60          => not main_osm_control_i(C_MENU_RF_ORIG),
         ps2_mouse_clk_out  => main_mouse_host_clk,
         ps2_mouse_data_out => main_mouse_host_dat,

         ram_size           => C_RAM_SIZE,
         l2_enable          => main_l2_on(0),
         cache_off          => not main_l2_on(1),
         sb_take_starved    => not main_iot_arm(10),
         l2_hits            => main_l2_hits,
         l2_misses          => main_l2_misses,

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
         dbg_mem_busy       => main_dbg_mem_busy,
         dbg_io_rd          => main_dbg_io_rd,
         dbg_io_wr          => main_dbg_io_wr,
         dbg_sb_req         => main_dbg_sb_req,
         dbg_sb_irq         => main_dbg_sb_irq,
         dbg_io_rd_stb      => main_dbg_io_rd_stb,
         dbg_io_wr_stb      => main_dbg_io_wr_stb,
         dbg_sb_cmd_wait    => main_dbg_sb_cmd_wait,
         dbg_sb_smp_stb     => main_dbg_sb_smp_stb,
         dbg_sb_smp_dif     => main_dbg_sb_smp_dif,
         dbg_sb_smp_pos     => main_dbg_sb_smp_pos,
         inta_hold          => not main_iot_arm(20),
         dbg_pic            => main_dbg_pic,
         dbg_irq            => main_dbg_irq,
         dbg_ps2            => main_dbg_ps2,
         dbg_ps2_fifo       => main_dbg_ps2_fifo,
         dbg_inta_bad       => main_dbg_inta_bad,
         dbg_inta_last      => main_dbg_inta_last,
         cd_l               => main_cd_l,
         cd_r               => main_cd_r
      ); -- i_z486

   -- The management bus: MiSTer's ARM side in hardware (CMOS, floppy, hard disk). Not reset
   -- with the PC: it configures the CMOS while the PC still waits for its ROMs.
   i_pc_mgmt : entity work.pc_mgmt
      generic map (
         G_CLK_HZ          => CORE_CLK_SPEED
      )
      port map (
         clk_i             => main_clk,
         rst_i             => main_rst,
         mgmt_address_o    => main_mgmt_address,
         mgmt_read_o       => main_mgmt_read,
         mgmt_write_o      => main_mgmt_write,
         mgmt_writedata_o  => main_mgmt_writedata,
         mgmt_readdata_i   => main_mgmt_readdata,
         fdd_request_i     => main_fdd_request,
         ide_request_i     => main_ide0_request,
         ide1_request_i    => main_ide1_request,
         rtc_i             => main_rtc_i,
         mnt_i             => qnice_disk_mnt,
         sd_req_o          => main_disk_req,
         sd_req_wr_o       => main_disk_req_wr,
         sd_req_unit_o     => main_disk_req_unit,
         sd_req_lba_o      => main_disk_req_lba,
         sd_req_cnt_o      => main_disk_req_cnt,
         sd_req_fresh_o    => main_disk_req_fresh,
         sd_done_i         => qnice_disk_done,
         sd_err_i          => qnice_disk_done_err,
         buf_addr_o        => main_disk_buf_addr,
         buf_we_o          => main_disk_buf_we,
         buf_wd_o          => main_disk_buf_wd,
         buf_rd_i          => main_disk_buf_rd,
         buf_bad_i         => main_disk_buf_bad,
         cd_tab_addr_o     => main_cd_tab_addr,
         cd_tab_q_i        => main_cd_tab_q,
         cd_l_o            => main_cd_l,
         cd_r_o            => main_cd_r,
         cd_stb_o          => open,
         cd_stat_o         => main_cd_stat,
         trace_we_o        => main_tr_we,
         trace_o           => main_tr_d
      ); -- i_pc_mgmt

   -- The CD-ROM's track table (pc_cdrom.vhd has the layout): QNICE writes it (C_DEV_PC_CDTOC,
   -- window 0; windows 1 to 3 are the firmware's scratch: a cue sheet's text and the extent
   -- map's staging copy, as disk_sd's map is write-only for QNICE), the drive reads window 0
   -- on the PC's clock (the data two clocks after the address)
   qnice_cdtoc_we <= qnice_dev_ce_i and qnice_dev_we_i when qnice_dev_id_i = C_DEV_PC_CDTOC and
                                                            qnice_dev_addr_i(27 downto 14) = "00000000000000"
                     else '0';

   i_cd_toc : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 14,
         DATA_WIDTH => 16,
         FALLING_B  => true                    -- QNICE's device convention
      )
      port map (
         clock_a    => main_clk,
         address_a  => "00" & main_cd_tab_addr,
         q_a        => main_cd_tab_q,
         clock_b    => qnice_clk_i,
         address_b  => qnice_dev_addr_i(13 downto 0),
         data_b     => qnice_dev_data_i,
         wren_b     => qnice_cdtoc_we,
         q_b        => qnice_cdtoc_q
      ); -- i_cd_toc

   i_cdc_cd_stat : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 64,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i  => main_clk,
         src_data_i => main_cd_stat,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_cd_stat
      ); -- i_cdc_cd_stat

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

   -- The turbo switch: CAPS LOCK (it latches) down = the CPU at 33 MHz, up = full speed
   -- (z486's throttle, cpu_slow; the keyboard sends the PC nothing for it)
   p_main_turbo : process (main_clk)
   begin
      if rising_edge(main_clk) then
         if main_kb_key_num_i = 72 then             -- CAPS LOCK
            main_cpu_slow <= not main_kb_key_pressed_n_i;
         end if;
      end if;
   end process p_main_turbo;

   -- The paddle lines. The framework names them as the C64 does: POT X is pin 9, a 1351's x
   -- (a mouSTer in C64 mode came out the right way round so, 2026-11-02); main_iot_arm(23)
   -- (qmon.py c1351 swap) swaps them. The game port's second fire button is on pin 9, POT X,
   -- as the C64GS's, or on pin 5 when the menu says so (C_MENU_JOY_P5: a two-button stick that
   -- has it there, qmon.py joy, 2026-11-02); the third on the other line.
   main_m1351_x   <= main_pot1_y_i when main_iot_arm(23) = '1' else main_pot1_x_i;
   main_m1351_y   <= main_pot1_x_i when main_iot_arm(23) = '1' else main_pot1_y_i;
   main_fire2_pot <= main_pot2_y_i when main_osm_control_i(C_MENU_JOY_P5) = '1' else main_pot2_x_i;
   main_fire3_pot <= main_pot2_x_i when main_osm_control_i(C_MENU_JOY_P5) = '1' else main_pot2_y_i;

   -- A joystick on port 2 as the PC's game port joystick (201h). Fire is button 1; a second
   -- and third fire button on the paddle lines (main_fire2_pot, main_fire3_pot: the C64 two-
   -- and three-button joysticks connect them to +5 V) are buttons 2 and 3. A pressed one reads near 255 here
   -- (M2M inverts the paddle values), an open line near 0. The directions and fire come
   -- debounced, on main_clk, from M2M (the paddle values too).
   p_main_joy : process (main_clk)
   begin
      if rising_edge(main_clk) then
         if unsigned(main_fire2_pot) >= 192 then
            main_joy_b2 <= '1';
         elsif unsigned(main_fire2_pot) < 64 then
            main_joy_b2 <= '0';
         end if;
         if unsigned(main_fire3_pot) >= 192 then
            main_joy_b3 <= '1';
         elsif unsigned(main_fire3_pot) < 64 then
            main_joy_b3 <= '0';
         end if;
      end if;
   end process p_main_joy;

   main_joy_dig <= '0' & main_joy_b3 & main_joy_b2 & not main_joy_2_fire_n_i &
                   not main_joy_2_up_n_i & not main_joy_2_down_n_i &
                   not main_joy_2_left_n_i & not main_joy_2_right_n_i;

   -- A mouse on joystick port 1 as the PC's PS/2 mouse, always there (the BIOS waits for good
   -- for a mouse that does not answer). Not reset with the PC either.
   i_pc_mouse : entity work.pc_mouse
      generic map (
         G_CLK_HZ        => CORE_CLK_SPEED
      )
      port map (
         clk_i           => main_clk,
         rst_i           => main_rst,
         up_n_i          => main_joy_1_up_n_i,
         down_n_i        => main_joy_1_down_n_i,
         left_n_i        => main_joy_1_left_n_i,
         right_n_i       => main_joy_1_right_n_i,
         fire_n_i        => main_joy_1_fire_n_i,
         pot_x_i         => main_m1351_x,
         pot_y_i         => main_m1351_y,
         flip_i          => main_iot_arm(22 downto 21),
         c1351_o         => main_c1351,
         key_num_i       => main_kb_key_num_i,
         key_pressed_n_i => main_kb_key_pressed_n_i,
         tx_valid_o      => main_mouse_tx_valid,
         tx_data_o       => main_mouse_tx_data,
         tx_ready_i      => main_mouse_tx_ready,
         rx_valid_i      => main_mouse_rx_valid,
         rx_data_i       => main_mouse_rx_data
      ); -- i_pc_mouse

   i_ps2_mouse : entity work.ps2_device
      generic map (
         G_PS2_DIV  => CORE_CLK_SPEED / 32_000  -- 16 kHz
      )
      port map (
         clk_i      => main_clk,
         rst_i      => main_rst,
         tx_valid_i => main_mouse_tx_valid,
         tx_data_i  => main_mouse_tx_data,
         tx_ready_o => main_mouse_tx_ready,
         rx_valid_o => main_mouse_rx_valid,
         rx_data_o  => main_mouse_rx_data,
         ps2_clk_i  => main_mouse_host_clk,
         ps2_dat_i  => main_mouse_host_dat,
         ps2_clk_o  => main_mouse_dev_clk,
         ps2_dat_o  => main_mouse_dev_dat
      ); -- i_ps2_mouse

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
            main_dbg_snap <= main_dbg_io_wr & main_dbg_io_rd & "0000" & main_dbg_sb_req & main_joy_dig &
                             main_l2_on &
                             main_l2_misses & main_l2_hits &
                             std_logic_vector(main_dbg_snap_cnt) &
                             std_logic_vector(main_dbg_vs_cnt) &
                             std_logic_vector(main_dbg_log_cnt) &
                             main_dbg_cpu_eip &
                             main_dbg_cpu_cs &
                             std_logic_vector(main_dbg_post_cnt) & main_dbg_post_code &
                             "000000" & main_pc_reset & main_dbg_mem_busy & main_dbg_cpu_pe &
                             main_dbg_first_instr & main_dbg_vga_bad & main_dbg_vga_checked &
                             main_dbg_bios_loaded & main_dbg_boot_stage;
            -- the PICs and the 8042 (z486_sources.py): master ISR:IRR, slave ISR:IRR, slave
            -- IMR:master IMR, the IRQ lines, the 8042's state and FIFOs, the INTAs the PIC
            -- acknowledged with another vector than the CPU took, the last one's two vectors;
            -- the paddle values of port 1 (Y:X) and port 2, a 1351 on port 1 (pc_mouse.vhd)
            main_dbg_snap2 <= x"0000" & x"0000" & x"0000" & x"0000" & x"0000" &
                              x"000" & "000" & main_c1351 &
                              main_pot2_y_i & main_pot2_x_i & main_pot1_y_i & main_pot1_x_i &
                              main_dbg_inta_last & main_dbg_inta_bad &
                              main_dbg_ps2_fifo & main_dbg_ps2 & main_dbg_irq &
                              main_dbg_pic(7 downto 0) & main_dbg_pic(31 downto 24) &
                              main_dbg_pic(15 downto 8) & main_dbg_pic(23 downto 16) &
                              main_dbg_pic(39 downto 32) & main_dbg_pic(47 downto 40);
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
   -- the log: bits 9..8 the kind (00 a character, 01 a POST code, 10 to the device, 11 from it),
   -- bit 10 the mouse (else the keyboard)
   main_dbg_log_wr    <= main_dbg_post_new or main_dbg_log_we or main_kbd_rx_valid or
                         (main_kbd_tx_valid and main_kbd_tx_ready) or main_mouse_rx_valid or
                         (main_mouse_tx_valid and main_mouse_tx_ready);
   main_dbg_log_entry <= "0001" & main_dbg_post_code when main_dbg_post_new = '1' else
                         "0000" & main_dbg_log_byte  when main_dbg_log_we = '1' else
                         "0010" & main_kbd_rx_data   when main_kbd_rx_valid = '1' else
                         "0011" & main_kbd_tx_data   when (main_kbd_tx_valid and main_kbd_tx_ready) = '1' else
                         "0110" & main_mouse_rx_data when main_mouse_rx_valid = '1' else
                         "0111" & main_mouse_tx_data;

   i_dbg_log : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 12,
         DATA_WIDTH => 12,
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

   -- The IDE trace: the last 512 events of the disks' controllers (pc_mgmt.vhd has the list),
   -- each with its sequence number and the time in 1.024 ms steps (65536 clocks). Not cleared
   -- by a PC reset: what led up to one stays readable.
   p_main_trace : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_tr_div <= main_tr_div + 1;
         if main_tr_div = x"FFFF" then
            main_tr_ms <= main_tr_ms + 1;
         end if;
         if main_tr_we = '1' then
            main_tr_seq <= main_tr_seq + 1;
         end if;
      end if;
   end process p_main_trace;
   main_tr_entry <= std_logic_vector(main_tr_seq) & std_logic_vector(main_tr_ms) & main_tr_d;

   i_ide_trace : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 9,
         DATA_WIDTH => 96,
         FALLING_B  => true                    -- QNICE's device convention
      )
      port map (
         clock_a    => main_clk,
         address_a  => std_logic_vector(main_tr_seq(8 downto 0)),
         data_a     => main_tr_entry,
         wren_a     => main_tr_we,
         q_a        => open,
         clock_b    => qnice_clk_i,
         address_b  => qnice_dev_addr_i(11 downto 3),
         q_b        => qnice_tr_q
      ); -- i_ide_trace

   -- The DMA and Sound Blaster I/O trace: the last 1024 of these, each with the time in
   -- microseconds (qmon.py iotrace):
   --   kind 0  a write to the DMA controllers (00-0F, C0-DF), their page registers (81-8F),
   --           the PICs (20/A0 but a plain end of interrupt and OCW3, which interrupt handlers
   --           and the CD-ROM driver's polling write all the time; 21 when it changes the
   --           mask), the 8042 (60, 64) or the Sound Blaster (224-22F, not its FM ports)
   --   kind 1  a read of the DSP (22A, 22E, 22F), the mixer (225), the DMA status (08, D0)
   --           or the 8042 (60, 64); a read that returns what the last one logged did is
   --           left out (polling)
   --   kind 2  the Sound Blaster's IRQ rises
   --   kind 3  its DMA request waited 64 us or more before the DMA controller answered (bits
   --           31..16 the microseconds, 7..0 which request: 1 8-bit, 2 16-bit)
   --   kind 4  a request has waited 1 ms (the card has nothing to play); the trace stops
   --           there when QNICE started it so, until QNICE starts it again
   --   kind 5  a new DMA command the DSP held back for 64 us or more has started (bits 31..16
   --           the microseconds; sound_dsp.v waits for the block in progress to end)
   --   kind 6  a new DMA command has been held back for 1 ms
   --   kind 7  a DMA output sample jumped from the one before (left channel) by the threshold
   --           or more (main_iot_arm(19..12), in 256ths; bits 7..0 the jump in 256ths, 31..16
   --           its index in the DSP's block: a late buffer half jumps at index 0)
   -- QNICE can also stop it (main_iot_arm(9)), or start it to stop when full (main_iot_arm(11):
   -- the first 1024 entries instead of the last).
   -- Bits 63..32 the time, 31..16 the port, 15..13 the kind, 7..0 the byte.
   p_main_iot : process (main_clk)
      function wr_ok (p : std_logic_vector(15 downto 0)) return boolean is
      begin
         return p(15 downto 4) = x"000" or p(15 downto 5) = "00000000110" or
                (p(15 downto 4) = x"008" and p /= x"0080") or
                p = x"0060" or p = x"0064" or
                (p(15 downto 4) = x"022" and p(3 downto 2) /= "00" and p(3 downto 1) /= "100");
      end function wr_ok;
      function pic_ok (p : std_logic_vector(15 downto 0); v, imr : std_logic_vector(7 downto 0))
         return boolean is
      begin
         return ((p = x"0020" or p = x"00A0") and v /= x"20" and v(4 downto 3) /= "01") or
                (p = x"0021" and v /= imr);
      end function pic_ok;
      function rd_ok (p : std_logic_vector(15 downto 0)) return boolean is
      begin
         return p = x"022A" or p = x"022E" or p = x"022F" or p = x"0225" or p = x"0008" or
                p = x"00D0" or p = x"0060" or p = x"0064";
      end function rd_ok;
   begin
      if rising_edge(main_clk) then
         main_iot_tick <= '0';
         main_iot_div  <= main_iot_div + 1;
         if main_iot_div = 63 then                -- 64 MHz
            main_iot_tick <= '1';
            main_iot_us   <= main_iot_us + 1;
         end if;

         main_iot_irq_d <= main_dbg_sb_irq;
         if main_dbg_sb_irq = '1' and main_iot_irq_d = '0' then
            main_iot_irq_p <= '1';
         end if;
         main_iot_req_d <= main_dbg_sb_req;
         if main_dbg_sb_req = "00" then
            if main_iot_wait >= 64 then
               main_iot_stall_p   <= '1';
               main_iot_stall     <= main_iot_wait;
               main_iot_stall_req <= main_iot_req_d;
            end if;
            main_iot_wait <= (others => '0');
         elsif main_iot_tick = '1' and main_iot_wait /= x"FFFF" then
            main_iot_wait <= main_iot_wait + 1;
            if main_iot_wait = 999 then
               main_iot_freeze_p <= '1';
            end if;
         end if;
         if main_dbg_sb_cmd_wait = '0' then
            if main_iot_cwait >= 64 then
               main_iot_cdef_p <= '1';
               main_iot_cdef   <= main_iot_cwait;
            end if;
            main_iot_cwait <= (others => '0');
         elsif main_iot_tick = '1' and main_iot_cwait /= x"FFFF" then
            main_iot_cwait <= main_iot_cwait + 1;
            if main_iot_cwait = 999 then
               main_iot_clong_p <= '1';
            end if;
         end if;
         if main_dbg_io_wr_stb = '1' and main_dbg_io_wr(23 downto 8) = x"0021" then
            main_iot_imr <= main_dbg_io_wr(7 downto 0);
         end if;
         if main_dbg_sb_smp_stb = '1' and
            unsigned(main_dbg_sb_smp_dif(15 downto 8)) >= unsigned(main_iot_arm(19 downto 12)) then
            main_iot_jump_p <= '1';
            main_iot_jump   <= main_dbg_sb_smp_dif(15 downto 8);
            main_iot_jpos   <= main_dbg_sb_smp_pos;
         end if;

         main_iot_we <= '0';
         -- stopping when full: the 1024th entry may be on its way (main_iot_we)
         if main_iot_run = '1' and (main_iot_arm(11) = '0' or main_iot_cnt < 1023 or
                                    (main_iot_cnt = 1023 and main_iot_we = '0')) then
            if main_dbg_io_wr_stb = '1' and (wr_ok(main_dbg_io_wr(23 downto 8)) or
               pic_ok(main_dbg_io_wr(23 downto 8), main_dbg_io_wr(7 downto 0), main_iot_imr)) then
               main_iot_entry <= std_logic_vector(main_iot_us) & main_dbg_io_wr(23 downto 8) &
                                 "000" & "00000" & main_dbg_io_wr(7 downto 0);
               main_iot_we    <= '1';
            elsif main_dbg_io_rd_stb = '1' and rd_ok(main_dbg_io_rd(23 downto 8)) and
                  main_dbg_io_rd /= main_iot_last_rd then
               main_iot_entry  <= std_logic_vector(main_iot_us) & main_dbg_io_rd(23 downto 8) &
                                  "001" & "00000" & main_dbg_io_rd(7 downto 0);
               main_iot_we     <= '1';
               main_iot_last_rd <= main_dbg_io_rd;
            elsif main_iot_irq_p = '1' then
               main_iot_entry <= std_logic_vector(main_iot_us) & x"0000" & "010" & "00000" & x"00";
               main_iot_we    <= '1';
               main_iot_irq_p <= '0';
            elsif main_iot_stall_p = '1' then
               main_iot_entry   <= std_logic_vector(main_iot_us) & std_logic_vector(main_iot_stall) &
                                   "011" & "00000" & "000000" & main_iot_stall_req;
               main_iot_we      <= '1';
               main_iot_stall_p <= '0';
            elsif main_iot_freeze_p = '1' then
               main_iot_entry    <= std_logic_vector(main_iot_us) & x"0000" & "100" & "00000" &
                                    "000000" & main_dbg_sb_req;
               main_iot_we       <= '1';
               main_iot_freeze_p <= '0';
               main_iot_run      <= not main_iot_arm(8);
            elsif main_iot_cdef_p = '1' then
               main_iot_entry  <= std_logic_vector(main_iot_us) & std_logic_vector(main_iot_cdef) &
                                  "101" & "00000" & x"00";
               main_iot_we     <= '1';
               main_iot_cdef_p <= '0';
            elsif main_iot_clong_p = '1' then
               main_iot_entry   <= std_logic_vector(main_iot_us) & x"0000" & "110" & "00000" & x"00";
               main_iot_we      <= '1';
               main_iot_clong_p <= '0';
            elsif main_iot_jump_p = '1' then
               main_iot_entry  <= std_logic_vector(main_iot_us) & main_iot_jpos & "111" & "00000" &
                                  main_iot_jump;
               main_iot_we     <= '1';
               main_iot_jump_p <= '0';
            end if;
         end if;
         if main_iot_we = '1' then
            main_iot_cnt <= main_iot_cnt + 1;
            if main_iot_cnt = 1023 then
               main_iot_full <= '1';
            end if;
         end if;
         if main_iot_arm(11) = '1' and main_iot_cnt >= 1024 then
            main_iot_run <= '0';
         end if;

         -- QNICE (re)starts it: empty, running
         main_iot_arm_d <= main_iot_arm;
         if main_iot_arm(7 downto 0) /= main_iot_arm_d(7 downto 0) then
            main_iot_run      <= '1';
            main_iot_cnt      <= (others => '0');
            main_iot_full     <= '0';
            main_iot_we       <= '0';
            main_iot_irq_p    <= '0';
            main_iot_stall_p  <= '0';
            main_iot_freeze_p <= '0';
            main_iot_cdef_p   <= '0';
            main_iot_clong_p  <= '0';
            main_iot_jump_p   <= '0';
            main_iot_last_rd  <= (others => '1');
         end if;
         if main_iot_arm(9) = '1' then
            main_iot_run <= '0';
         end if;
      end if;
   end process p_main_iot;

   main_iot_stat <= main_iot_run & main_iot_full & std_logic_vector(main_iot_cnt);

   i_io_trace : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 10,
         DATA_WIDTH => 64,
         FALLING_B  => true                    -- QNICE's device convention
      )
      port map (
         clock_a    => main_clk,
         address_a  => std_logic_vector(main_iot_cnt(9 downto 0)),
         data_a     => main_iot_entry,
         wren_a     => main_iot_we,
         q_a        => open,
         clock_b    => qnice_clk_i,
         address_b  => qnice_dev_addr_i(11 downto 2),
         q_b        => qnice_iot_q
      ); -- i_io_trace

   i_cdc_iot_arm : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 24,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i  => qnice_clk_i,
         src_data_i => qnice_iot_arm,
         dst_clk_i  => main_clk,
         dst_data_o => main_iot_arm
      ); -- i_cdc_iot_arm

   i_cdc_iot_stat : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 18,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i  => main_clk,
         src_data_i => main_iot_stat,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_iot_stat
      ); -- i_cdc_iot_stat

   -- M2M-UPSTREAM vga-polarity: a VGA card tells an analog monitor how many lines its mode has by
   -- the sync polarity, from the misc output register (port 3C2h: bit 6 HSYNC, bit 7 VSYNC, 1 =
   -- negative): +/- 350 lines (EGA modes), -/+ 400 (DOS text, 320x200), -/- 480. z486's vga.v
   -- keeps those bits (general_hsync/general_vsync) but makes active-high syncs, and MiSTer's
   -- video_cleaner makes them active-high in any case, which the scaler wants; so on the VGA
   -- connector every mode had +/+ and a monitor had to guess: a Dell took DOS text for 640x350,
   -- sampled the 720-pixel lines with the wrong clock (uneven strokes, shimmer, edges cut off)
   -- and its auto adjust could not fix it. The bits come from the PC's writes to 3C2h (as
   -- vga.v takes them: no reset), the analog pipeline turns the connector's syncs to match.
   p_main_vga_pol : process (main_clk)
   begin
      if rising_edge(main_clk) then
         if main_dbg_io_wr_stb = '1' and main_dbg_io_wr(23 downto 8) = x"03C2" then
            main_vga_pol <= main_dbg_io_wr(7) & main_dbg_io_wr(6);
         end if;
      end if;
   end process p_main_vga_pol;

   video_vga_pol_o <= main_vga_pol;

   -- Native (M2M-UPSTREAM native): the PC's picture size as ascal sees it: the pixels (ce) of
   -- the widest line's display enable, the lines of a frame; the SVGA framebuffer's size while
   -- ascal shows it. A size counts once it held for eight frames (mode changes pass through
   -- odd frames). Bit 24: the frames are shorter than 1/65 s (main_clk's clocks from one
   -- vblank to the next), as a VGA's 400- and 350-line modes at 70 Hz with "Refresh: Original
   -- (VGA)"; with "60 Hz (HDMI)" (video_f60) every mode runs at 60 Hz. Held for the same eight
   -- frames as the size.
   p_main_native : process (main_clk)
      constant C_PER_65HZ : natural := 984615;   -- 64 MHz / 65 Hz
      variable v_de : std_logic;
      variable v_w  : unsigned(11 downto 0);
      variable v_l  : unsigned(11 downto 0);
      variable v_f  : std_logic;
   begin
      if rising_edge(main_clk) then
         if main_nat_per /= (main_nat_per'range => '1') then
            main_nat_per <= main_nat_per + 1;
         end if;
         if main_nat_per = C_PER_65HZ then
            main_nat_slow <= '1';
         end if;
         if video_ce_o = '1' then
            v_de := not (video_hblank_o or video_vblank_o);
            v_w  := main_nat_wmax;
            v_l  := main_nat_lines;
            main_nat_de_d <= v_de;
            main_nat_vb_d <= video_vblank_o;
            if v_de = '1' then
               main_nat_cnt <= main_nat_cnt + 1;
            elsif main_nat_de_d = '1' then             -- a line ended
               if main_nat_cnt > v_w then
                  v_w := main_nat_cnt;
               end if;
               v_l := v_l + 1;
               main_nat_cnt <= (others => '0');
            end if;
            if video_vblank_o = '1' and main_nat_vb_d = '0' then   -- a frame ended
               v_f := not main_nat_slow;
               if v_w = main_nat_w and v_l = main_nat_h and v_f = main_nat_f then
                  if main_nat_same = 7 then
                     main_nat_size <= v_f & std_logic_vector(v_w & v_l);
                  else
                     main_nat_same <= main_nat_same + 1;
                  end if;
               else
                  main_nat_same <= 0;
               end if;
               main_nat_w    <= v_w;
               main_nat_h    <= v_l;
               main_nat_f    <= v_f;
               main_nat_per  <= (others => '0');
               main_nat_slow <= '0';
               v_w := (others => '0');
               v_l := (others => '0');
            end if;
            main_nat_wmax  <= v_w;
            main_nat_lines <= v_l;
         end if;
         if main_fb_en = '1' then
            main_nat_size <= '0' & fb_hsize_o & fb_vsize_o;
         end if;
      end if;
   end process p_main_native;

   i_cdc_native : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 25
      )
      port map (
         src_data_i => main_nat_size,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_nat_size
      ); -- i_cdc_native

   -- The caches' switches into the PC's clock: the L2, z486's L1 (off: every access uncached)
   i_cdc_l2_on : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 2
      )
      port map (
         src_data_i => qnice_l2_on,
         dst_clk_i  => main_clk,
         dst_data_o => main_l2_on
      ); -- i_cdc_l2_on

   i_cdc_dbg_snap : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 256
      )
      port map (
         src_data_i => main_dbg_snap,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_dbg_snap
      ); -- i_cdc_dbg_snap

   i_cdc_dbg_snap2 : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 256
      )
      port map (
         src_data_i => main_dbg_snap2,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_dbg_snap2
      ); -- i_cdc_dbg_snap2

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
   -- HyperRAM 0x400000..0x7FFFFF; everything else (the boot image at 0x300C0000, all z486 reads
   -- there) folds into HyperRAM 0x300000..0x3FFFFF. The framework's ascal buffer has the 3 MB
   -- below 0x300000: three frames of 1 MB, triple buffered.
   ---------------------------------------------------------------------------------------------

   main_hr_addr <= "1"   & main_ddram_addr(18 downto 0) when main_ddram_addr(28 downto 19) = "0011111110" else
                   "011" & main_ddram_addr(16 downto 0);

   -- HyperRAM's reset in main_clk: a core reset (the reset button) resets HyperRAM, its arbiter
   -- and the HyperRAM side of the bridge (clk_m2m's hr_rst), so the main side's request FIFO
   -- resets with them, and the PC waits for them (main_pc_reset)
   i_cdc_hr_rst : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 4
      )
      port map (
         src_arst  => hr_rst_i,
         dest_clk  => main_clk,
         dest_arst => main_hr_rst
      ); -- i_cdc_hr_rst

   main_ddram_rst <= main_rst or main_hr_rst;

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
         s_rst_i               => main_ddram_rst,
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

   -- Native: the smallest HDMI mode the PC's picture fits into at its own size: 640x480 at
   -- 60 Hz for 640x480 and 640x400, 720x480 for 720x400 text, 800x600 and 1024x768 for SVGA.
   -- A 400- or 350-line picture at 70 Hz ("Refresh: Original (VGA)") gets a VGA card's own
   -- 640x400 or 720x400 at 70 Hz (M2M-UPSTREAM vga70), so that HDMI, and VGA, which shows the
   -- HDMI picture, keep its rate; the scaler repeats or drops a frame about once a minute (the
   -- PC's 70.09 Hz and the HDMI clock's 70.09/70.11 Hz come from different clocks).
   -- The core gives 320/360-pixel lines without the VGA's pixel doubling and 200-line modes
   -- without line doubling: those come doubled (320x200 as 640x400). The scaler copies pixels
   -- into a window of that size in the middle; the monitor scales. Nothing sensible yet (the
   -- BIOS before the VGA BIOS) or larger than 1024x768: 640x480 or 1280x1024, scaled.
   p_qnice_native : process (qnice_clk_i)
      variable v_w  : natural range 0 to 4095;
      variable v_h  : natural range 0 to 4095;
      variable v_tw : natural range 0 to 8191;
      variable v_th : natural range 0 to 8191;
   begin
      if rising_edge(qnice_clk_i) then
         v_w := to_integer(unsigned(qnice_nat_size(23 downto 12)));
         v_h := to_integer(unsigned(qnice_nat_size(11 downto 0)));
         if v_w <= 400 then
            v_tw := 2 * v_w;
         else
            v_tw := v_w;
         end if;
         if v_h <= 300 then
            v_th := 2 * v_h;
         else
            v_th := v_h;
         end if;
         qnice_nat_on <= '1';
         if v_w < 256 or v_h < 160 then
            qnice_nat_mode <= C_VIDEO_HDMI_640_60;
            qnice_nat_on   <= '0';
         elsif v_tw <= 640 and v_th <= 400 and qnice_nat_size(24) = '1' then
            qnice_nat_mode <= C_VIDEO_VGA_640_70;
         elsif v_tw <= 720 and v_th <= 400 and qnice_nat_size(24) = '1' then
            qnice_nat_mode <= C_VIDEO_VGA_720_70;
         elsif v_tw <= 640 and v_th <= 480 then
            qnice_nat_mode <= C_VIDEO_HDMI_640_60;
         elsif v_tw <= 720 and v_th <= 480 then
            qnice_nat_mode <= C_VIDEO_HDMI_720_5994;
         elsif v_tw <= 800 and v_th <= 600 then
            qnice_nat_mode <= C_VIDEO_SVGA_800_60;
         elsif v_tw <= 1024 and v_th <= 768 then
            qnice_nat_mode <= C_VIDEO_SVGA_1024_60;
         else
            qnice_nat_mode <= C_VIDEO_SVGA_1280_60;
            qnice_nat_on   <= '0';
         end if;
         if v_tw <= 4095 and v_th <= 4095 then
            qnice_nat_w <= v_tw;
            qnice_nat_h <= v_th;
         end if;
      end if;
   end process p_qnice_native;

   qnice_native_o     <= qnice_nat_on & std_logic_vector(to_unsigned(qnice_nat_w, 12)) &
                         std_logic_vector(to_unsigned(qnice_nat_h, 12))
                            when qnice_osm_control_i(C_MENU_HDMI_NATIVE) = '1' else
                         (others => '0');

   qnice_video_mode_o <= qnice_nat_mode        when qnice_osm_control_i(C_MENU_HDMI_NATIVE) = '1' else
                         C_VIDEO_SVGA_1280_60  when qnice_osm_control_i(C_MENU_HDMI_1280) = '1' else
                         C_VIDEO_SVGA_1024_60  when qnice_osm_control_i(C_MENU_HDMI_1024) = '1' else
                         C_VIDEO_SVGA_800_60   when qnice_osm_control_i(C_MENU_HDMI_800)  = '1' else
                         C_VIDEO_HDMI_720_5994 when qnice_osm_control_i(C_MENU_HDMI_480P) = '1' else
                         C_VIDEO_HDMI_16_9_60;

   qnice_dvi_o                <= '0';         -- HDMI with sound
   qnice_scandoubler_o        <= '0';         -- the PC's VGA is 31 kHz already
   qnice_retro15kHz_o         <= '0';
   qnice_csync_o              <= '0';
   qnice_audio_mute_o         <= '0';
   qnice_audio_filter_o       <= '0';
   qnice_zoom_crop_o          <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');
   -- the Filter menu: sharp bilinear (the default: 720x400 text at x1.2 (480p) or x1.8 (720p)
   -- without uneven strokes, still crisp), bilinear, nearest neighbour (ascal's MODE[1:0])
   qnice_ascal_mode_o         <= "00" when qnice_osm_control_i(C_MENU_HDMI_NATIVE) = '1' else
                                 "01" when qnice_osm_control_i(C_MENU_FLT_SMOOTH) = '1' else
                                 "00" when qnice_osm_control_i(C_MENU_FLT_PIXELS) = '1' else
                                 "10";
   -- the Scanlines menu, in every HDMI mode: lined up in 1280x1024 only, where a 480-line mode
   -- is exactly doubled (in the others a line is 1.25 to 1.92 output lines, the dark lines beat)
   qnice_scanlines_o          <= "00" when qnice_osm_control_i(C_MENU_HDMI_NATIVE) = '1' else
                                 "01" when qnice_osm_control_i(C_MENU_SL_25) = '1' else
                                 "10" when qnice_osm_control_i(C_MENU_SL_50) = '1' else
                                 "00";
   qnice_ascal_polyphase_o    <= '0';
   qnice_ascal_triplebuf_o    <= '1';         -- whole frames: the PC's 70 Hz text mode on 60 Hz
                                              -- HDMI tore while the screen changed
   qnice_flip_joyports_o      <= '0';

   -- C_DEV_PC_CTL (globals.vhd):
   --    0x0000      bit 0 = the PC's BIOS ROMs are in HyperRAM. Written by m2m-rom.asm
   --                (PREP_START); cleared with QNICE, whose firmware then loads them again.
   --                Clearing and setting it resets the PC.
   --    0x0001      the SDRAM clock's phase, signed fine steps from 292.5 degrees (clk.vhd)
   --    0x0002      read: where the phase shift is
   --    0x0003      bit 0 = the L2 cache is on (guest_l2.sv; default on, switching it on
   --                empties it first), bit 1 = z486's L1 caches are on (default on; off, every
   --                access goes uncached; back on, reset the PC: lines may be stale)
   --    0x0004      read: the I/O trace's entries written (p_main_iot); write: start it again
   --                (empty, running; bit 0 = stop at the Sound Blaster's first 1 ms DMA wait,
   --                bit 1 = stop when full)
   --    0x0005      read: bit 1 = it is running, bit 0 = it has wrapped (1024 or more);
   --                write: stop it
   --    0x0006      bit 0 = the Sound Blaster takes a new DMA command over a stalled transfer
   --                at once (sound_dsp.v's dma_take_starved, z486_sources.py; default on)
   --    0x0007      bits 7..0 = the smallest jump between two Sound Blaster samples the I/O
   --                trace logs, in 256ths (default 0x40; 0 logs every sample)
   --    0x0008..0B  read: the CD-ROM's audio (pc_cdrom.vhd's cd_stat_o), the high word first:
   --                the audio status | the LBA heard (23..16), its low word, the samples the
   --                FIFO did not have, the fewest words it held since the PLAY
   --    0x000C      bit 0 = the PIC holds its vector from the CPU's first INTA to its
   --                acknowledge (pic_inta_bridge.sv's vector_hold, z486_sources.py; default on)
   --    0x000D      bit 0 = a 1351 mouse's x reversed, bit 1 its y (pc_mouse.vhd's flip_i);
   --                bit 2 = its x and y swapped (main_m1351_x)
   --    0x0010..17  read: the debug snapshot (p_main_dbg): status (bits 2..0 boot stage, 3 BIOS
   --                copied, 4/5 VGA BIOS signature checked/bad, 6 first instruction, 7 CPU PE,
   --                8 SDRAM busy, 9 PC in reset), POST count:code, CS, EIP low, EIP high,
   --                log count, VGA vsync count, snapshot count; 0x0018..1C the L2's line
   --                fills from the cache (lo, hi) and from the SDRAM (lo, hi), whether it is on
   --                (0x001C bits 1..0), the game port's joystick (bits 9..2, main_joy_dig) and
   --                the Sound Blaster's DMA requests (bit 10 8-bit, bit 11 16-bit);
   --                0x001D..1F the last I/O read (port, byte) and write (port, byte), 48 bits
   --                from bit 0 of 0x001D: read byte, read port, write byte, write port
   --    0x0020..2B  read: the FPGA's temperature, VCCINT, VCCAUX and VCCBRAM now, their maxima,
   --                their minima since the configuration (xadc_mon.vhd)
   --    0x0030..37  read: the second debug snapshot (p_main_dbg, the same moment): the master
   --                PIC's ISR:IRR, the slave's ISR:IRR, the slave's IMR:the master's IMR, the
   --                IRQ lines 15..0, the 8042's state and its FIFOs' bytes (ps2.v's dbg_state
   --                and dbg_fifo, z486_sources.py), the INTAs the PIC acknowledged with another
   --                vector than the CPU took since the PC's reset, the last one's (CPU:PIC);
   --    0x0038..3A  the paddle values (as the framework gives them: inverted) of port 1, Y:X,
   --                and port 2; bit 0 of 0x003A = a 1351 on port 1 (pc_mouse.vhd)
   --    0x1000..1FFF read: the log (p_main_dbg), entry n at 0x1000 + n mod 4096
   --    0x2000..2FFF read: the IDE trace (p_main_trace), event n at 0x2000 + 8 * (n mod 512):
   --                its sequence number, milliseconds, then the event (pc_mgmt.vhd) in four
   --                words, the high one first
   --    0x3000..3FFF read: the I/O trace (p_main_iot), entry n at 0x3000 + 4 * (n mod 1024),
   --                its 64 bits the high word first
   p_qnice_pc_ctl : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and qnice_dev_id_i = C_DEV_PC_CTL then
            if qnice_dev_addr_i = x"0000000" then
               qnice_pc_roms_ok(0) <= qnice_dev_data_i(0);
            elsif qnice_dev_addr_i = x"0000001" then
               qnice_sdram_ps_target <= qnice_dev_data_i;
            elsif qnice_dev_addr_i = x"0000003" then
               qnice_l2_on <= qnice_dev_data_i(1 downto 0);
            elsif qnice_dev_addr_i = x"0000004" then
               qnice_iot_arm(9 downto 0) <= '0' & qnice_dev_data_i(0) &
                                            std_logic_vector(unsigned(qnice_iot_arm(7 downto 0)) + 1);
               qnice_iot_arm(11) <= qnice_dev_data_i(1);
            elsif qnice_dev_addr_i = x"0000005" then
               qnice_iot_arm(9) <= '1';
            elsif qnice_dev_addr_i = x"0000006" then
               qnice_iot_arm(10) <= not qnice_dev_data_i(0);
            elsif qnice_dev_addr_i = x"0000007" then
               qnice_iot_arm(19 downto 12) <= qnice_dev_data_i(7 downto 0);
            elsif qnice_dev_addr_i = x"000000C" then
               qnice_iot_arm(20) <= not qnice_dev_data_i(0);
            elsif qnice_dev_addr_i = x"000000D" then
               qnice_iot_arm(23 downto 21) <= qnice_dev_data_i(2 downto 0);
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_pc_roms_ok(0) <= '0';
            qnice_l2_on         <= "11";
         end if;
      end if;
   end process p_qnice_pc_ctl;

   -- QNICE's reads: a select per source from the device and the address alone (the sources
   -- never overlap), then each source's data through an AND and one OR tree; EEEE where
   -- nothing is selected. The block RAMs among them are read on the falling edge, half a QNICE
   -- clock to the CPU: as an if-elsif chain (nested priority logic) this was the QNICE clock's
   -- slowest path; alone, from the RAM data to the result, 3 logic levels instead of 5.
   p_qnice_dev_data : process (all)
      variable v_ctl, v_blk0, v_any : boolean;
      variable v_word : natural range 0 to 7;
      variable v_low  : natural range 0 to 63;
      variable v_q    : natural range 0 to 3;
      variable v_d    : std_logic_vector(15 downto 0);

      procedure put(sel : boolean; d : std_logic_vector(15 downto 0)) is
      begin
         if sel then
            v_d   := v_d or d;
            v_any := true;
         end if;
      end procedure put;
   begin
      v_word := to_integer(unsigned(qnice_dev_addr_i(2 downto 0)));
      v_low  := to_integer(unsigned(qnice_dev_addr_i(5 downto 0)));
      v_q    := to_integer(unsigned(qnice_dev_addr_i(1 downto 0)));
      v_ctl  := qnice_dev_id_i = C_DEV_PC_CTL;
      v_blk0 := v_ctl and qnice_dev_addr_i(27 downto 6) = "0000000000000000000000";
      v_d    := (others => '0');
      v_any  := false;

      put(qnice_disk_sel = '1', qnice_disk_data);
      put(qnice_dev_id_i = C_DEV_PC_CDTOC, qnice_cdtoc_q);
      put(v_blk0 and v_low = 0, x"000" & "000" & qnice_pc_roms_ok(0));
      put(v_blk0 and v_low = 1, qnice_sdram_ps_target);
      put(v_blk0 and v_low = 2, qnice_sdram_ps_pos);
      put(v_blk0 and v_low = 3, x"000" & "00" & qnice_l2_on);
      put(v_blk0 and v_low = 4, qnice_iot_stat(15 downto 0));
      put(v_blk0 and v_low = 5, x"000" & "00" & qnice_iot_stat(17 downto 16));
      put(v_blk0 and v_low = 6, x"000" & "000" & not qnice_iot_arm(10));
      put(v_blk0 and v_low = 7, x"00" & qnice_iot_arm(19 downto 12));
      for k in 0 to 3 loop                     -- the CD-ROM's audio (pc_cdrom's cd_stat_o)
         put(v_blk0 and v_low = 8 + k, qnice_cd_stat(63 - 16 * k downto 48 - 16 * k));
      end loop;
      put(v_blk0 and v_low = 12, x"000" & "000" & not qnice_iot_arm(20));
      put(v_blk0 and v_low = 13, x"000" & "0" & qnice_iot_arm(23 downto 21));
      for k in 0 to 7 loop
         put(v_blk0 and v_low = 16 + k, qnice_dbg_snap(16 * k + 15 downto 16 * k));
         put(v_blk0 and v_low = 24 + k, qnice_dbg_snap(16 * k + 143 downto 16 * k + 128));
         put(v_blk0 and v_low = 48 + k, qnice_dbg_snap2(16 * k + 15 downto 16 * k));
         put(v_blk0 and v_low = 56 + k, qnice_dbg_snap2(16 * k + 143 downto 16 * k + 128));
      end loop;
      put(v_blk0 and v_low >= 32 and v_low <= 47, qnice_xadc);
      put(v_ctl and qnice_dev_addr_i(27 downto 12) = x"0001", "0000" & qnice_dbg_log_q);
      for k in 0 to 5 loop
         put(v_ctl and qnice_dev_addr_i(27 downto 12) = x"0002" and v_word = k,
             qnice_tr_q(95 - 16 * k downto 80 - 16 * k));
      end loop;
      for k in 0 to 3 loop
         put(v_ctl and qnice_dev_addr_i(27 downto 12) = x"0003" and v_q = k,
             qnice_iot_q(63 - 16 * k downto 48 - 16 * k));
      end loop;
      if not v_any then
         v_d := x"EEEE";
      end if;
      qnice_dev_data_o <= v_d;
   end process p_qnice_dev_data;
   qnice_dev_wait_o <= qnice_disk_wait when qnice_disk_sel = '1' else '0';

   i_xadc_mon : entity work.xadc_mon
      port map (
         clk_i  => qnice_clk_i,
         idx_i  => qnice_dev_addr_i(3 downto 0),
         data_o => qnice_xadc
      ); -- i_xadc_mon

   -- The disks from image files on the SD card: floppy drives A: and B:, the hard disk, the
   -- CD-ROM (C_DEV_PC_DISK, _B, _HD, _CD: one CSR each; the firmware mounts them)
   qnice_disk_sel  <= '1' when qnice_dev_id_i = C_DEV_PC_DISK or qnice_dev_id_i = C_DEV_PC_DISK_B or
                               qnice_dev_id_i = C_DEV_PC_DISK_HD or
                               qnice_dev_id_i = C_DEV_PC_DISK_CD else '0';
   qnice_disk_unit <= "01" when qnice_dev_id_i = C_DEV_PC_DISK_B else
                      "10" when qnice_dev_id_i = C_DEV_PC_DISK_HD else
                      "11" when qnice_dev_id_i = C_DEV_PC_DISK_CD else "00";
   qnice_disk_ce   <= qnice_dev_ce_i and qnice_disk_sel;

   i_disk_sd : entity work.disk_sd
      generic map (
         G_QNICE_HZ    => QNICE_CLK_SPEED,
         G_LUTRAM      => 1               -- the ring and the write buffer in LUT RAM (disk_sd.vhd)
      )
      port map (
         qnice_clk_i   => qnice_clk_i,
         qnice_rst_i   => qnice_rst_i,
         qnice_addr_i  => qnice_dev_addr_i,
         qnice_data_i  => qnice_dev_data_i,
         qnice_ce_i    => qnice_disk_ce,
         qnice_unit_i  => qnice_disk_unit,
         qnice_we_i    => qnice_dev_we_i,
         qnice_data_o  => qnice_disk_data,
         qnice_wait_o  => qnice_disk_wait,
         sd_q2c_i      => sd_eng_i,
         sd_c2q_o      => sd_eng_o,
         mnt_o         => qnice_disk_mnt,
         req_i         => main_disk_req,
         req_wr_i      => main_disk_req_wr,
         req_unit_i    => main_disk_req_unit,
         req_lba_i     => main_disk_req_lba,
         req_cnt_i     => main_disk_req_cnt,
         req_fresh_i   => main_disk_req_fresh,
         done_o        => qnice_disk_done,
         done_err_o    => qnice_disk_done_err,
         main_clk_i    => main_clk,
         buf_addr_i    => main_disk_buf_addr,
         buf_we_i      => main_disk_buf_we,
         buf_wd_i      => main_disk_buf_wd,
         buf_rd_o      => main_disk_buf_rd,
         buf_bad_o     => main_disk_buf_bad
      ); -- i_disk_sd

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

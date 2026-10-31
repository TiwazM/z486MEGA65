----------------------------------------------------------------------------------
-- z486 for MEGA65
--
-- Global constants
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen, 2022) in the Megamiga fork and
-- pc10-iii's globals.vhd (Johan Smolinski); licensed under GPL v3
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.qnice_tools.all;
use work.video_modes_pkg.all;

package globals is

----------------------------------------------------------------------------------------------------------
-- QNICE Firmware
----------------------------------------------------------------------------------------------------------

constant QNICE_FIRMWARE_MONITOR   : string  := "../../../M2M/QNICE/monitor/monitor.rom";    -- debug/development
constant QNICE_FIRMWARE_M2M       : string  := "../../../CORE/m2m-rom/m2m-rom.rom";         -- release

-- Select firmware here
constant QNICE_FIRMWARE           : string  := QNICE_FIRMWARE_M2M;

-- Megamiga fork (M2M-UPSTREAM code-banks): the code bank ROM behind the window 0x9000-0x9FFF
-- (m2m-rom.asm: the FAT32 write layer, banks 0 and 1; make_rom.sh writes the image)
constant QNICE_CODE_BANKS         : string  := "../../../CORE/m2m-rom/m2m-banks.rom";

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
----------------------------------------------------------------------------------------------------------

-- The PC's clock, 100 MHz * 64 / 5 / 20 (clk.vhd). The framework derives the MEGA65 keyboard link
-- (m2m_keyb) from it: a wrong value runs the link at the wrong speed and the keyboard drops it.
constant CORE_CLK_SPEED       : natural := 64_000_000;

-- System clock speed (crystal that is driving the FPGA) and QNICE clock speed
-- !!! Do not touch !!!
constant BOARD_CLK_SPEED      : natural := 100_000_000;
constant QNICE_CLK_SPEED      : natural := 50_000_000;   -- a change here has dependencies in qnice_globals.vhd

----------------------------------------------------------------------------------------------------------
-- Video Mode
----------------------------------------------------------------------------------------------------------

-- The On-Screen-Menu canvas: 640 x 480 = 40 x 30 characters, the VGA picture.
constant VGA_DX               : natural := 640;
constant VGA_DY               : natural := 480;

-- The PC's VGA is 31 kHz already: the scandoubler stays off (mega65.vhd); this only matters
-- for the analog 15 kHz path (M2M-UPSTREAM line-doubler).
constant VGA_LINEDOUBLER      : boolean := true;

-- The scaler's interpolators that are built (M2M-UPSTREAM ascal-mask; bit 0 nearest, 1 bilinear,
-- 2 sharp bilinear, 3 bicubic, 4 polyphase): z486 uses sharp bilinear (mega65.vhd), and bicubic's
-- DSP paths were the HDMI clock's slowest, too slow for the 90 MHz of 1280x1024
constant ASCAL_MASK           : std_logic_vector(7 downto 0) := x"07";

--    FONT_*  size of one OSM character (the 8x8 strike, rendered as 16x16 cells)
constant FONT_FILE            : string  := "../font/Anikki-8x8-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of 4kW)
--
-- Byte addresses: 0x000000-0x2FFFFF the framework (ascal's buffer: three 1 MB frames, triple
-- buffered), 0x300000-0x3FFFFF z486's DDR3 window (boot image at 0x3C0000), 0x400000-0x7FFFFF
-- z486's SVGA framebuffer (mega65.vhd maps the DDR3 port)
----------------------------------------------------------------------------------------------------------

constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework

----------------------------------------------------------------------------------------------------------
-- QNICE devices of the core (ids >= 0x0100)
----------------------------------------------------------------------------------------------------------

-- The PC's control and debug registers (mega65.vhd has the map). Address 0, bit 0: the BIOS
-- ROMs are in HyperRAM (m2m-rom.asm, PREP_START); until QNICE sets it, the PC stays in reset.
constant C_DEV_PC_CTL         : std_logic_vector(15 downto 0) := x"0100";

-- The disks, floppy drives A: and B:, the hard disk and the CD-ROM (disk_sd.vhd has the register
-- map): the image files' extent maps and sizes, written by m2m-rom.asm (DISK_PREP). One device
-- per drive for the Shell's manual loads: each has its own CSR in window 0xFFFF (the Shell takes
-- a line as loaded while its device's CSR says so); the other windows are the same for all four.
constant C_DEV_PC_DISK        : std_logic_vector(15 downto 0) := x"0101";   -- A:
constant C_DEV_PC_DISK_B      : std_logic_vector(15 downto 0) := x"0102";
constant C_DEV_PC_DISK_HD     : std_logic_vector(15 downto 0) := x"0103";
constant C_DEV_PC_DISK_CD     : std_logic_vector(15 downto 0) := x"0104";

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System: not used
----------------------------------------------------------------------------------------------------------

type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders. The framework's auto-loader writes
-- one byte per HyperRAM word; z486 reads its BIOS ROMs packed, so m2m-rom.asm loads them itself
-- (PREP_START). Manual loads 0 to 3 are the menu's "Floppy A:", "Floppy B:", "Hard disk:" and
-- "CD-ROM:" lines (one device each, so that the Shell tells them apart): the file browser, then
-- DISK_PREP mounts the image (the Shell streams nothing into the device).
----------------------------------------------------------------------------------------------------------

type crtrom_buf_array is array(natural range<>) of std_logic_vector;
constant ENDSTR : character := character'val(0);

-- Cartridges and ROMs can be stored into QNICE devices, HyperRAM and SDRAM
constant C_CRTROMTYPE_DEVICE     : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMTYPE_HYPERRAM   : std_logic_vector(15 downto 0) := x"0001";
constant C_CRTROMTYPE_SDRAM      : std_logic_vector(15 downto 0) := x"0002";

-- Types of automatically loaded ROMs:
-- If a mandatory file is missing, then the core outputs the missing file and goes fatal
constant C_CRTROMTYPE_MANDATORY  : std_logic_vector(15 downto 0) := x"0003";
constant C_CRTROMTYPE_OPTIONAL   : std_logic_vector(15 downto 0) := x"0004";

constant C_CRTROMS_MAN_NUM       : natural := 4;
constant C_CRTROMS_MAN           : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_PC_DISK,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_PC_DISK_B,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_PC_DISK_HD,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_PC_DISK_CD,
                                                         x"EEEE");

constant C_CRTROMS_AUTO_NUM      : natural := 0;
constant C_CRTROMS_AUTO_NAMES    : string  := "" & ENDSTR;
constant C_CRTROMS_AUTO          : crtrom_buf_array := ( x"EEEE", x"EEEE", x"EEEE", x"EEEE",
                                                         x"EEEE");

----------------------------------------------------------------------------------------------------------
-- Audio filters (the framework's optional low-pass; values of the C64 template, unused while
-- qnice_audio_filter_o = '0')
----------------------------------------------------------------------------------------------------------

constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(2, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00"; -- 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

end package globals;

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

-- Megamiga fork (M2M-UPSTREAM code-banks): no code banks yet
constant QNICE_CODE_BANKS         : string  := "";

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
----------------------------------------------------------------------------------------------------------

-- The PC's clock, 100 MHz * 10 / 15 (clk.vhd). The framework derives the MEGA65 keyboard link
-- (m2m_keyb) from it: a wrong value runs the link at the wrong speed and the keyboard drops it.
constant CORE_CLK_SPEED       : natural := 66_666_667;

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
-- Byte addresses: 0x000000-0x1FFFFF the framework (ascal's buffer), 0x200000-0x3FFFFF z486's
-- DDR3 window (boot image at 0x2C0000), 0x400000-0x7FFFFF z486's SVGA framebuffer
-- (mega65.vhd maps the DDR3 port)
----------------------------------------------------------------------------------------------------------

constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework

----------------------------------------------------------------------------------------------------------
-- QNICE devices of the core (ids >= 0x0100): none yet
----------------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System: not used
----------------------------------------------------------------------------------------------------------

type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders: none yet (the boot image will be an
-- auto-loaded ROM into HyperRAM)
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

constant C_CRTROMS_MAN_NUM       : natural := 0;
constant C_CRTROMS_MAN           : crtrom_buf_array := ( x"EEEE", x"EEEE",
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

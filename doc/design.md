# Design notes

Part of [z486MEGA65](../README.md). How the core is put together: the plan, then what each part of the shell does and why.

## Plan

- **Board:** MEGA65 R6 (XC7A200T-2), on MiSTer2MEGA65 in Megamiga's fork
  ([m2m-provenance.md](m2m-provenance.md)).
- **Memory:** the R6's 64 MB SDRAM for system RAM; HyperRAM for the SVGA
  framebuffer (VRAM) and the boot image.
- **Clock:** 64 MHz. A DX2-66 runs at 66.667 MHz, which the CPU's paths miss by
  0.25 ns with the framework in; 64 MHz meets timing with room for
  build-to-build variation.
- **Disks:** a hardware replacement for MiSTer's ARM-side IDE/floppy handling,
  after `mgmt_bridge.sv` in
  [PCXT-EGA-MEGA65](https://github.com/silent-command/PCXT-EGA-MEGA65)
  (same `ide.v` / `floppy.v`), fed by the fork's hardware SD engine as in
  [pc10-iii](https://github.com/johansmolinski/pc10-iii).
- **Keyboard and mouse:** MEGA65 keyboard and joystick-port mouse as PS/2
  devices, after PCXT-EGA-MEGA65's `keyboard.vhd` and `m65_mouse_ps2.vhd`.
- **Later:** a complete x87 FPU; perhaps a Voodoo 1.

## What the shell does now

- `CORE/sv/z486_mega65.sv` wires z486_MiSTer's `system.sv` (CPU, chipset,
  VGA/ET4000, OPL3/SB, IDE, floppy) and its SDRAM backend (64 MB on the R6's
  IS42S16320F, with DQM) as `z486_mister.sv` does on MiSTer, plus the SVGA
  framebuffer descriptor, the SB Pro mix, and a video stream for M2M
  (positive syncs, separate blanks).
- `CORE/vhdl/mega65.vhd` maps z486's MiSTer DDR3 port into HyperRAM:
  DDR3 `0x3F800000` (the SVGA framebuffer, 4 MB) to HyperRAM `0x400000`, the
  rest (the boot image at `0x300C0000`) into `0x300000`-`0x3FFFFF`, through
  `avm_fifo` and `avm_decrease` (64 to 16 bits). The reset button resets
  HyperRAM with the core (M2M's `hr_rst`), and ascal with it. ascal's write
  request had no reset (`--avl_write_i<='0'` in M2M's ascal.vhd): a reset
  during one of its input write bursts left it high, the HyperRAM side took
  it for a new burst and waited for its beats for good. HyperRAM stopped (0
  transactions a second), the screen repeated one line, z486's boot loader
  waited for its first read (stage 2), and a long press did not help: the
  next reset caught ascal writing again. It resets now (M2M-UPSTREAM
  reset-write; `tb_ascal.vhd`'s G_RST replays it, the old ascal fails). The
  bridge's z486 side resets with HyperRAM too, and the PC waits for it.
  ascal shows the framebuffer
  from HyperRAM (M2M-UPSTREAM rtg-framebuffer). Below `0x300000` ascal keeps
  three frames of the VGA picture (triple buffering): the PC's 70 Hz text mode
  on 60 Hz HDMI otherwise showed half-old, half-new frames where the screen
  changed (a flickering clock, stray lines, the cursor). The scaler
  interpolates sharp bilinear by default: the 720x400 text mode scales by 1.2
  (480p, 720x480) or 1.8 (720p), and nearest-neighbour made diagonal strokes
  uneven. The menu's "Filter" switches it (Sharp, Smooth = bilinear, Pixels =
  nearest neighbour), and "Scanlines" darkens every second output line by
  25 % or 50 % (a register stage behind ascal, M2M-UPSTREAM scanlines,
  `digital_pipeline.vhd`). They line up with the PC's lines only in 1280x1024,
  where a 480-line mode is exactly two lines each; in the other modes a PC
  line is 1.25 to 1.92 output lines and the dark lines beat into bands.
  ascal's bilinear path (Smooth, Sharp) left one clock before the nearest one
  and wrote every pixel one output pixel to the left: the picture moved left,
  at 800x600 the PC's first column was gone, and thin strokes broke (the top
  of a "6"). It now runs one stage later (M2M-UPSTREAM filter-align); Smooth
  matches a centre-aligned bilinear exactly, Sharp's edges sit where Pixels'
  do (`CORE/sim/tb_ascal.vhd` with `G_PAT=1`: "68" text at 720x400 into
  1280x960 and 800x600).
- Clocks (`CORE/vhdl/clk.vhd`): 64 MHz for the PC and the video, 24.556 MHz
  for OPL3/SB (MiSTer uses 24.576 MHz; 0.08 % slow, about 1.4 cents), one
  MMCM at VCO 1280 MHz.
- The SDRAM clock is a third output of that MMCM at 292.5 degrees, through an
  ODDR (see [SDRAM clock](sdram-clock.md)). `sdram.v`'s shortcut below 75 MHz
  (one cycle for tRCD and tRP, 15.6 ns at 64 MHz, under the chip's 18 ns) is
  patched out in the build copy (`tools/z486_sources.py`): two cycles each.
- BIOS: at startup the firmware (`CORE/m2m-rom/m2m-rom.asm`, `PREP_START`)
  loads `boot1.rom` (VGA BIOS, to `0xC0000`) and `boot0.rom` (system BIOS, to
  `0xF0000`, or `0xE0000` if above 64 KB) from the SD card into the HyperRAM
  window z486's boot loader copies from (`0x3C0000`, 256 KB, cleared first).
  The PC stays in reset until they are in (QNICE device `C_DEV_PC_CTL`,
  `mega65.vhd`). A missing or unreadable ROM stops with a message on screen.
  The framework's own ROM auto-loader is not used: it writes one byte per
  HyperRAM word, and z486 reads the ROMs packed.
- Firmware space: the QNICE ROM holds 28,286 of its 32,768 words. The FAT32
  write layer (the Shell's settings file) lives in code banks 0 and 1, 4K-word
  banks behind the window 0x9000-0x9FFF (Megamiga's code-banks, as in MegaMac),
  called through `FAR_CALL` stubs; six banks are free.
- Keyboard: the MEGA65 keyboard is the PC's PS/2 keyboard
  (`CORE/vhdl/pc_keyboard.vhd`, `ps2_device.vhd`): scan code set 2, which the
  PC's 8042 translates to set 1, typematic repeat, and the replies to the
  BIOS's keyboard commands, which MiSTer's ARM side gives there. See
  [Keyboard](../README.md#keyboard).
- Mouse: an Amiga mouse on joystick port 1, or a USB mouse behind a mouSTer in
  Amiga mode, is the PC's PS/2 mouse (`CORE/vhdl/pc_mouse.vhd`): its
  quadrature lines as MegaMac decodes them, the left button on pin 6. The
  right button (pin 9) is invisible to the MEGA65's paddle circuit (Megamiga
  measured it, and the R6 is no different), so F13 stands in for it. For a
  real right button, use a Commodore 1351 or a mouSTer in its C64 mode
  (`c1351`, `mode=mouse` in its INI): its position on the paddle lines, the
  right button on pin 1. The core finds a 1351 by itself (its paddle lines
  read driven for 0.1 s) and goes back to Amiga mode half a second after
  they read open. Its x is on POT X (pin 9), its y on POT Y (pin 5), as on a
  C64; `qmon.py c1351` shows the mode and reverses or swaps axes that run the
  wrong way. The mouse answers the BIOS's and the
  drivers' commands (reset, identify, sample rate, status, ...) like a
  standard PS/2 mouse, also when nothing is plugged in: the BIOS's mouse
  functions, which CuteMouse calls, wait for good for a mouse that does not
  answer. After any byte from the PC it sends no packets for 300 ms (the
  motion waits): the Bochs BIOS's mouse functions take the byte after their
  command as its answer and leave the mouse port off when it was no FA, so
  a packet in the middle of CuteMouse's set-up (F4, then F3 and its byte)
  left the mouse dead, or its packets read a byte off (the pointer jumping
  from edge to edge). The 7th Guest hit it at its start, in native mode
  nearly every time; the debug log showed it. `CORE/sim/run_ps2.sh`
  simulates the keyboard and the mouse against z486's 8042 (`ps2.v`;
  `tb_pc_mouse` has a packet in the middle of F3, which fails without the
  quiet time), and the PIC patch below (`tb_pic.sv`).
- Joystick: a joystick on port 2 is the PC's game port joystick at 201h
  (z486_MiSTer's `joystick.v`, as a 4-button joystick; the second joystick
  absent). The directions put the axes at their ends, fire is button 1. A
  second and third fire button on the paddle lines (the C64 two- and
  three-button joysticks, which connect them to +5 V) are buttons 2 and 3:
  the second on pin 9 (POT X, as the C64GS's), or on pin 5 for sticks that
  have it there ("Joystick fire 2" in the menu); the third on the other one.
  A button that grounds pin 9 (Amiga style) is invisible, like the Amiga
  mouse's right button. `qmon.py status` shows what is held, `qmon.py joy`
  every change.
- Disks (`CORE/vhdl/disk_sd.vhd`, `pc_mgmt.vhd`): MiSTer's ARM side, which
  serves z486's floppy and IDE controllers and fills the CMOS through the
  management bus, is in hardware (`pc_mgmt`): at power-up the CMOS
  (equipment, base memory, checksum, the date and time from the MEGA65's RTC);
  then floppy drives A: and B: (`floppy.v`: insert/eject, the sector
  requests) and the hard disk, the master of the first IDE channel (`ide.v`:
  IDENTIFY, reads and writes, one sector per block), with the CMOS's drive
  types following the images; the CD-ROM drive, an ATAPI device on the second
  channel (`pc_cdrom.vhd`, what Main_MiSTer's `ide_cdrom.cpp` does, with
  `cd_audio.vhd` for CD audio and the firmware's `cdimage.asm` for cue sheets),
  which `pc_mgmt` lets onto the management bus when it is idle. `disk_sd` reads and writes straight in the
  image file through the SD host controller's engine port (Megamiga's
  sd-host), with the file's extent map from the firmware (fragmented files are
  fine); reads come in runs of one SD command each through a 32-sector ring
  in LUT RAM, every copy out of it checked against the checksum of what went
  in (a sector that does not match comes again, fresh from the card); the
  write buffer is LUT RAM too. See [Disks](disks.md). `CORE/sim/run_disks.sh` simulates them against z486's
  `floppy.v`, `ide.v` and `rtc.v` (`tb_cdrom.sv`: both IDE channels, the
  packets a DOS CD-ROM driver sends, an ISO and a disc with data and audio
  tracks: raw reads, the TOC, PLAY sample by sample); `CORE/m2m-rom/test/run.sh`
  runs `cdimage.asm` in the QNICE emulator on FAT32 images (mtools) with ISO,
  BIN and cue sheets, checked against its own layout of the disc.
- Menu: floppy A:, floppy B:, hard disk, CD-ROM, HDMI mode, filter,
  scanlines, the joystick's fire 2 (pin 9 or pin 5), help, "Reset the PC". An image mounted at start-up
  (`/z486/hdd.img`, `/z486/cdrom.cue` or `.iso`, `/z486/floppy.img`) shows its name
  once the menu opens (`DAN_FLUSH`): the
  menu has no memory before that, and the line read "Hard disk:  Hard
  dis..." (the line's own text taken for the name).
- HDMI modes: 720p 60 Hz (the PC's 4:3 picture between bars), 480p, 800x600,
  1024x768 and 1280x1024 at 60 Hz, and "Native resolution": the HDMI output
  follows the PC's own picture size and the monitor does the only scaling
  (M2M-UPSTREAM native, `digital_pipeline.vhd`: ascal's window is the
  picture's size in the middle of the output). `mega65.vhd` measures the
  picture as ascal sees it (the widest line's pixels, the lines of a frame;
  a size counts once it held for eight frames) and picks the smallest mode it
  fits into: 720x400 text in 720x480 (40 lines of bars), 640x480 and 640x400
  in 640x480, SVGA 800x600 and 1024x768 in their own modes; 320- and
  360-pixel lines and 200-line modes come doubled (the core gives them
  without the VGA's doubling), so 320x200 is 640x400. Native uses nearest
  neighbour and no scanlines, and the monitor resyncs when the PC changes
  mode, as a real VGA monitor does. On an R6 with a 1280x1024 monitor the DOS
  prompt came out as 720x480 and The 7th Guest's VESA screens as 640x480,
  switching by themselves. The HDMI modes all exist already; the
  PC's 70 Hz text mode goes out at 60 Hz (ascal's triple buffering). 1280x1024 is a 5:4 monitor's own
  resolution: the picture is 1280x960 between bars and the monitor scales
  nothing, where 480p or 720p are scaled twice (by the core and by the
  monitor). It uses reduced blanking (the 63.2 kHz / 59.79 Hz of VESA's
  CVT-RB) at 90 MHz: VESA's DMT timing needs 108 MHz, at which the HDMI
  domain misses timing (the menu overlay's blending). The 90 MHz is a new
  entry in the framework's HDMI clock (M2M-UPSTREAM sxga-mode:
  `video_out_clock.vhd`, values from Xilinx's MMCM functions; the HDMI
  domain is timed at it), and the scaler is built without its bicubic and
  polyphase interpolators (`ASCAL_MASK` in `globals.vhd`), whose DSP paths
  were the slowest of that domain. Its 15.8 µs lines are shorter than the
  scaler's fetch of a 640-pixel line from the HyperRAM (15 bursts, ~13-20
  µs with the input's writes in between); ascal's line accounting waited for
  each fetch, fell behind, missed the start of the frame and showed noise.
  The fetches now run on their own from a queue (M2M-UPSTREAM late-fetch,
  `ascal.vhd`), so the accounting keeps the display's time;
  `CORE/sim/run_ascal.sh` compares ascal with a slow memory against a fast
  one. On a 5:4 monitor 1280x1024 is the sharpest mode by far: 800x600 is
  1.25x (every fourth pixel doubled, then smoothed) and the monitor scales
  it again.
- L2 cache (`CORE/sv/guest_l2.sv`, after MegaMac's): 256 KB of block RAM
  between the CPU's memory port and the SDRAM, as on a 486 board:
  direct-mapped, 16-byte lines, write-through. A line fill that hits is
  answered from the cache; stores update cached lines; floppy and Sound
  Blaster DMA (the SDRAM's second port) drop their lines before the CPU's
  next lookup. `tools/qmon.py l2` shows the fills from the cache and from the
  SDRAM, `l2 off` / `l2 on` switch it for comparisons (`l1 off` / `l1 on`
  z486's own L1 caches: off, every access goes uncached; after on, reset the
  PC). `CORE/sim/run_l2.sh`
  checks it against a memory model with DMA writes and switching. Measured
  (2026-10-31, the same build): Doom's `-timedemo demo3` 35.7 fps without,
  36.9 fps with it (+3.5%), 76% of the line fills from the cache: Doom's hot
  data mostly fits z486's own 8 + 8 KB. Dr. Hardware: average RAM throughput
  24.5 -> 31.4 MB/s (+28%; blocks between the L1's 16 KB and 256 KB), the
  minimum (beyond 256 KB) and maximum (within the L1) unchanged, Hardstones
  26345 -> 27418 (+4%).
- Debug: `C_DEV_PC_CTL` also holds the SDRAM clock's fine phase, a snapshot
  of the PC's state (boot stage, POST code, CS:EIP, VGA frame count, the L2's
  counters) and a 4096-entry log of the BIOS's debug port 0x402, z486's
  stall watchdog, POST code changes and the PS/2 keyboard's and mouse's bytes
  both ways (`qmon.py status`: `>kbd`/`>mou` to the device, `<` from it);
  `mega65.vhd` has the map. `tools/qmon.py` reads them over the JTAG
  adapter's serial port (115200 baud) while the PC and the menu run: the
  firmware answers serial commands in the Shell's background (`R`/`W` QNICE
  memory, `D`/`P` a device's registers, as MegaMac does), no debug mode
  needed. `qmon.py status` (`disks` the mounted images, the sector counts and
  times, the ring's checksums; `boot` and `sweep` reset the PC at other SDRAM
  clock phases; `xadc` the FPGA's temperature, VCCINT, VCCAUX and VCCBRAM,
  now and their lowest and highest since the core was loaded,
  `xadc_mon.vhd`).
  `qmon.py ide [N]` prints the last N of 512 events of the IDE trace
  (`pc_mgmt.vhd`, `pc_cdrom.vhd`; window 2 of `C_DEV_PC_CTL`): every command
  of both channels with its task file, every status the controllers set,
  every block done, reset, floppy request and SD answer, with milliseconds
  before the newest. It is not cleared by a PC reset, so it shows what led up
  to a hang.
  `QMON_MONITOR=1` talks to the M2M debug monitor instead (hold Run/Stop +
  Cursor Up, then press Help).

Not wired yet: the MEGA65's own floppy drive.

## Keyboard after a warm reset

After Ctrl+Alt+Del, or Enter at a "restart" prompt, the keyboard could stay
dead until a full reset. The Bochs BIOS sets up the keyboard (POST 77) before
the interrupt controllers; a key released in between raises IRQ1, ICW1 then
clears the request, and an 8259 waits for a new rising edge, which never
comes while nobody reads port 60h. `tools/z486_sources.py` patches `pic.v`:
after ICW1 an input that is already high counts as a new edge, so it is
served once (the same for the mouse's IRQ12). `tb_pic.sv` replays the race;
upstream's `pic.v` fails it.

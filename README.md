# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

It runs at 66 MHz, boots DOS, Windows 3.11 to 98, OS/2 Warp 4 and Linux, and
plays games from the CD era. The current version is **v0.3** (see
[Releases](https://github.com/TiwazM/z486MEGA65/releases)).

## Features

**PC**
- z486 486DX2-class CPU at 66 MHz, with 16 KB + 16 KB L1 caches (instructions
  and data) and an x87 FPU. There is no L2 cache (its block RAM holds the
  Gravis Ultrasound's samples): the larger L1 is faster than the 8 KB + 8 KB
  with a 256 KB L2 of earlier versions (Dr. Hardware: Hardstones +2 %, memory
  throughput up to +29 %; Quake 8.0 fps against 7.9)
- 64 MB RAM (the R6's SDRAM)
- Turbo switch: CAPS LOCK slows the CPU to 33 MHz for games that run too fast

**Video**
- Tseng ET4000 SVGA, up to 1024x768 in 256 colours (Windows 3.11 included);
  High Color (32K and 64K colours) up to 1024x768 and True Color up to 800x600,
  through a HiColor DAC as Tseng's BIOS expects it, so the VESA modes report
  correctly
- HDMI out at 720p, 480p, 800x600, 1024x768, 1280x960 (4:3), 1280x1024 (5:4),
  or the PC's own native resolution (with "Refresh: Original (VGA)", DOS text and 320x200 at 70 Hz,
  as a VGA card sends them)
- Scaling filters (Sharp, Smooth, Pixels)
- CRT emulation after the scaler, at any HDMI resolution: "VGA monitor"
  (scanlines on the PC's own lines, wider on bright pixels, a soft beam, the
  Commodore 1084's shadow mask, a little glow), "TV (200 lines)" (one scanline
  per game row in 320x200 and 320x240 games) and "Trinitron" (crisp, an
  aperture grille, for Windows and SVGA)
- No tearing on HDMI (the scaler keeps three frames)
- VGA out: the HDMI picture, menu included, on the same steady clock, so LCDs
  sample it cleanly. For an analog monitor or a CRT, set HDMI to "Native" and
  "Refresh" to "Original (VGA)": DOS text then comes as 720x400 and 320x200 as
  640x400 at 70 Hz, SVGA at 60 Hz, as from a VGA card. "60 Hz (HDMI)", the
  default, retimes every mode to 60 Hz, which suits HDMI

**Sound**
- Sound Blaster 16 with OPL3 FM music
- CD audio, played in hardware and mixed through the Sound Blaster's CD volume
- Gravis Ultrasound with 512 KB at 240h, DMA 3, IRQ 11 (see
  [Gravis Ultrasound](#gravis-ultrasound))

**Disks**
- IDE hard disk from an image file on the SD card
- Floppy drives A: and B: from image files, swapped from the menu
- ATAPI CD-ROM drive:
  - ISO images, raw BIN images, and BIN/CUE discs, including multiple files,
    WAVE audio, pregaps and mixed sector sizes
  - Up to 99 tracks, with CD audio
  - Works with DOS CD-ROM drivers and MSCDEX, Windows 3.11's Media Player, and
    Windows 95's own CD-ROM driver (AutoRun, CD Player, video from the CD)
- Disc and disk images mount automatically at start-up, or from the menu at any
  time

**Input**
- The MEGA65 keyboard as a PC keyboard, with symbols as on the keycaps. MEGA works
  as an Fn key for Page Up/Down, Home/End and Delete.
- PS/2 mouse on joystick port 1:
  - Commodore 1351, or a mouSTer in C64 mode: both buttons, detected
    automatically
  - mouSTer in Amiga mode with `activepotlines=true` (firmware 3.23.5313 or
    newer): all three buttons
  - Amiga mouse (or a mouSTer in Amiga mode without that): F13 is the right
    button
- Game port joystick on port 2 with up to three buttons. The second fire button
  can be on pin 9 (C64GS style) or pin 5, set in the menu.

**Core**
- Menu on HELP: floppies, internal drive, hard disk, CD-ROM, real floppy
  speed, boot order, HDMI mode, filter, CRT, refresh (HDMI or VGA),
  joystick, reset; settings are saved to the SD card, the hard disk mounted
  last too
- `<SD card info>` in the file browser, under each card on the list of the
  cards: each card's bus (native 4-bit, or the slower SPI mode) and its errors
- Boot order: floppy then hard disk (the default), CD-ROM then hard disk (a
  bootable CD, El Torito), or the hard disk only; it counts from the next reset
- Real floppy speed (off by default): the floppy images run at a real drive's
  speed. Each sector waits for its place on a disk turning at 300 rpm (360 rpm
  for a 1.2 MB disk), and a read or write that moves the head waits for its
  steps. Off, images load as fast as the SD card allows. The internal drive as
  A: or B: is a real drive either way.
- The reset button and Ctrl+Alt+Del restart the PC cleanly, and set its clock
  from the MEGA65's again
- The drive LED shows the PC's disk accesses: amber for the hard disk and the
  CD-ROM, green for the floppies
- The MEGA65's own floppy drive ("Internal drive" in the menu):
  - Off (the default): the drive stays idle
  - Sounds: it hums and clicks with the PC's floppy drives
    (their images on the SD card). Its motor runs while the PC's does and its
    head steps to the cylinder the PC's is on. With a disk in it, only the head
    moves: the motor stays off, so the disk doesn't spin for nothing. It never
    writes. Only with "Real floppy speed": without it, Sounds is greyed out
    (and a Sounds setting becomes Off).
  - Drive A: or Drive B:: it is that PC drive, and reads and writes real PC
    disks: 720 KB and 1.44 MB (and other 512-byte-sector formats, such as
    Microsoft's 1.68 MB DMF). The drive finds the disk's rate and reads its
    write protect tab and disk change line by itself. The image mounted as that
    drive waits until the menu gives the drive back.

## Tested

On an R6: MS-DOS, FreeDOS, Windows 3.11 (SVGA up to 1024x768 in 256 colours
and 800x600 in 16, Media Player CD audio), Windows 95 (High Color, its own
CD-ROM driver: AutoRun, CD Player, AVIs from the CD), Windows 98 SE (installed
from its CD), OS/2 Warp 4 (installed from its CD, its desktop at 640x480),
Linux (TinyCore with CorePlus, Damn Small Linux installed onto the hard disk),
DOOM, SimCity 2000, Wing Commander III, King's Quest VI, Phantasmagoria, The
7th Guest, Ultima Underworld 1 and 2, Day of the Tentacle (CD talkie), The
Secret of Monkey Island (CD, with its CD music), Gabriel Knight (CD), Jazz
Jackrabbit, TIE Fighter, and Quake (slowly: 8.0 fps in
`timedemo demo1` and `demo2`, its CD music playing from a BIN/CUE while it
loads from the hard disk; 486Quake, a build tuned for 486s, 8.5 fps at 64 MHz).
On the Gravis Ultrasound: Second Reality, DOOM, Wing Commander III, Gabriel
Knight (music and speech), TIE Fighter, XTC-Play and Open Cubic Player in DOS,
MOD4WIN in Windows 95.
Benchmarks: Chris's 3D Benchmark 43.3 (25.9 fps), SpeedSys 4.78 (CPU 23.19,
hard drive 1902), PC Player Benchmark 13.7 fps, Superscape 49.5 fps.

Ultima Underworld 2 wants its Sound Blaster Pro option with a Pro in
`BLASTER` (`SET BLASTER=A220 I5 D1 T4` before it starts): with its Sound
Blaster option it hangs. Wing Commander III runs best without EMM386
(`HIMEM.SYS` only): with it, a video can hang the game on a black screen.
For music on the Gravis Ultrasound, start its install and the game with
`WC3GRAV.BAT` from the first CD (`WC3GRAV -I` for the install): it loads the
game's instruments into the card first (`WC3GPATS`, from `ULTRADIR`'s patches),
and without them the install says it "could not startup your music sound
card".
King's Quest VI's intro movie tears (the lower part of the picture an older
frame) and judders in the boat scene with the game's own VGA driver: the VGA
driver from a later Sierra game (the Gabriel Knight demo's), a known fix for
KQ6, cures both.
Gabriel Knight on the Gravis Ultrasound, with Gravis' Sierra patch installed:
its `RESOURCE.CFG` names the Gravis drivers, `soundDrv = GUSMIDI.DRV` and
`audioDrv = GUSDAC.DRV` (for a CD installation with the game folder's full
path, such as `C:\SIERRA\GKCD\GUSMIDI.DRV`), and `LOADPATS -IGK1.INI` runs in
the game folder before every start: it loads the music's instruments into the
card, and they're gone after a reset. A few speech lines end with a click.
DOS Quake (and 486Quake) calibrates the joystick on port 2 as it starts,
after "Playing registered version.", with its prompts on a console that isn't
on screen yet, so it seems to hang. Set "Joystick: Off" in the menu (HELP)
and Quake starts straight away: no `-nojoy` needed.
Windows 3.11 runs at up to 1024x768 in 256 colours with Microsoft's generic
"Super VGA 256 colors" driver (`SVGA.EXE` from the Windows Driver Library,
through the ET4000 BIOS's VESA calls); pick the mode in Windows Setup
(Options, Change System Settings, Display). Its own drivers stop at 800x600 in
16 colours.
TinyCore and its CorePlus image: add `rootfstype=ramfs` to the boot line. Its
default root filesystem may use only half of the 64 MB, and CorePlus's
extensions run out of memory in it.
Damn Small Linux installed onto the hard disk: pick the plain "DSL" entry in its
boot menu. Its "fb" entries need a linear framebuffer (see Known limits). Its X
(Xvesa) offers the VESA modes, up to 800x600 in True Color.

## Getting started

1. Flash `z486-R6-<version>.cor` from [Releases](https://github.com/TiwazM/z486MEGA65/releases)
   with MEGAFLASH. The `.bit` is the same core, for loading over JTAG.
2. Put the BIOS files, and any disk images, on the SD card:

```
/z486/boot0.rom    the system BIOS
/z486/boot1.rom    the VGA BIOS
/z486/floppy.img   optional: drive A: at start-up (a raw floppy image)
/z486/hdd.img      optional: the hard disk at start-up (a raw disk image), until
                   the menu mounts another one: the core remembers that one
/z486/cdrom.cue    optional: the CD-ROM's disc at start-up (a cue sheet, its files in /z486)
/z486/cdrom.iso    optional: the same as an ISO image (when there is no cdrom.cue)
```

Both come with z486_MiSTer, in
[`z486_MiSTer/verilator/`](https://github.com/nand2mario/z486_MiSTer/tree/main/verilator)
(the same files MiSTer users put in `/media/fat/games/Z486`). `boot0.rom` is
the Bochs BIOS (LGPL), as in ao486; `boot1.rom` is Tseng Labs' ET4000 VGA
BIOS, which matches the core's ET4000 and is Tseng's code: neither is part of
this repository. The firmware takes them from the card the settings file is on;
without one, from the external microSD slot if it has a card, else from the
internal SD card.

For an empty hard disk, make a 2 GB file of zeros and copy it to the card as
`/z486/hdd.img`. On Windows, in PowerShell:

```powershell
$f = [System.IO.File]::Create("$PWD\hdd.img"); $f.SetLength(2GB); $f.Close()
```

or in a Command Prompt (`fsutil` may need "Run as administrator"):

```bat
fsutil file createnew hdd.img 2147483648
```

On macOS:

```bash
mkfile -n 2g hdd.img
```

On Linux:

```bash
truncate -s 2G hdd.img
```

Then boot a DOS install floppy from A: (FreeDOS's, for example) and let it
partition and format C:. A FAT32 card can't hold a file of 4 GB or more, so
keep the image below that. More in [Disks](doc/disks.md).

Mounting an image walks its cluster chain on the card, so it takes longer the
smaller the card's clusters are: a 2 GB `hdd.img` mounts in about 20 seconds
on a card with 4 KB clusters and about 5 seconds with 16 KB. Format the card
with 16 or 32 KB clusters (`qmon.py disks` shows the card's as "shift", the
log2 of its sectors per cluster: 5 for 16 KB, 6 for 32 KB).

3. Press HELP for the menu, to mount images and pick the HDMI mode.

## Keyboard

The keys go by their labels: letters and digits as on a PC, the symbols as
printed on the MEGA65's keycaps:

| MEGA65 | PC |
|---|---|
| RUN/STOP, ESC | Esc |
| INST/DEL | Backspace; with Shift Insert, with MEGA Delete |
| CLR/HOME | Home; with Shift End |
| RESTORE | Delete |
| F1 F3 F5 F7 F9 F11 | the same; with Shift F2 F4 F6 F8 F10 F12, as on the keycaps (the PC sees no Shift while the key is down) |
| cursor keys | arrows; with MEGA, up/down = Page Up/Down, left/right = Home/End |
| CTRL, ALT, TAB, both shifts | Ctrl, Alt, Tab, Shift |
| CAPS LOCK | the turbo switch: down (it latches) = the CPU at 33 MHz, up = full speed (66 MHz); z486's throttle, memory and devices keep full speed. The PC's Caps Lock is MEGA+TAB (SHIFT LOCK holds Shift: the MEGA65 wires it to the left Shift) |
| NO SCROLL | Scroll Lock |
| symbol keys and shifted digits | as on their keycaps: `:` (Shift `[`), `;` (Shift `]`), `@`, `*`, `+`, `-`, `=`, Shift+2 `"`, Shift+6 `&`, Shift+7 `'`, Shift+8 `(`, Shift+9 `)`, ... (the PC sees Shift pressed or released as each one needs) |
| PC symbols without a keycap | `£` `\` (Shift `|`), arrow-up `^` (Shift `~`), arrow-left `` ` ``, Shift+`-` `_`, Shift+`@` `{`, Shift+`*` `}` |
| MEGA | the Fn key above, nothing by itself |
| F13 | the mouse's right button (see [Mouse and joystick](#mouse-and-joystick)) |
| HELP | the menu |

## Mouse and joystick

- **Mouse on port 1.** A Commodore 1351, or a USB mouse behind a mouSTer set to
  C64 mode (`c1351` and `mode=mouse` in its INI), has both buttons. A mouSTer in
  Amiga mode with firmware 3.23.5313 or newer and `activepotlines=true` in its
  INI has all three (right and middle): it drives the button lines, which the
  MEGA65 can read. A plain Amiga mouse works too, but the MEGA65 can't read its
  right button (pin 9): F13 stands in for it. The core tells them all apart by
  itself. (Edit the INI the mouSTer writes, not one copied over with a new
  firmware: the update writes its defaults.) Load a PS/2 mouse driver (CuteMouse, or Windows' "Microsoft or IBM
  PS/2"). There is no scroll wheel.
- **Joystick on port 2** is the PC's game port joystick. Fire is button 1. A C64
  two- or three-button stick's extra buttons are buttons 2 and 3: the second on
  pin 9 (POT X, as the C64GS), or on pin 5 if your stick has it there ("Joystick
  fire 2" in the menu). The Joystick menu's "Timing" chooses how the stick's
  position is measured: "Timed" (the default) answers as a real stick does, by
  time; "Count" answers by the number of reads, for games that count them in a
  loop and on this fast PC run out before the stick answers. Jazz Jackrabbit
  needs "Count" (set it before starting the game, then calibrate in Jazz's
  options): with "Timed" its calibration doesn't follow the stick. TIE
  Fighter finds the stick with "Count" too.
  A calibration made with "Timed" leaves Jazz reading the centred stick as
  pushed, so its menus ignore the keys: set the Joystick menu to "Off", answer
  Jazz's questions with the keys, set it back, and calibrate again with "Count".

## Gravis Ultrasound

The core has a classic Gravis Ultrasound with 512 KB of sample memory, beside
the Sound Blaster. Its GF1 chip is nukeykt's model from LPC-GUS, built from a
die shot. Set it up in `AUTOEXEC.BAT`:

```
SET ULTRASND=240,3,3,11,11
```

That is port 240h, DMA 3 (DMA 1 is the Sound Blaster's), IRQ 11. Most games
and players set the card up themselves from that line. The card starts as if
Gravis' ULTRINIT had run with these settings, so ULTRINIT isn't needed; if you
run it (it comes on the Gravis install disks, not with the core), give it the
same settings. Only DMA 3 is wired; the IRQ follows what the software sets.
DMA works both ways (into the card and back to the PC). Recording records
silence, since the core has no audio input. There is no MIDI port. The card has its own level: the Sound Blaster's mixer
doesn't change it. Gravis' INSTALL (4.11) finds the card the way a classic
one is found, through the AdLib port 388h. In Windows 95, set the Gravis
driver's resources by hand to 240h, IRQ 11 and DMA 3, and set `ULTRADIR` to
the folder INSTALL made. In Gravis' Setup choose Custom Setup with 240h,
IRQ 11 for both lines and DMA 3 for playback and recording: its tests pass
there (DMA 6 and 7 fail, since only DMA 3 is wired). Its final "NMI test"
fails: the card has no NMI, which only Gravis' Sound Blaster emulation
(SBOS, MEGA-EM) uses; choose Ignore. The core's own SB16 does that job.
Gravis' installation can also leave a `BLASTER` line in `AUTOEXEC.BAT` that
points at the Ultrasound (such as `A240 I11 D1 T1`, for that emulation):
games that read it then look for a Sound Blaster on the Ultrasound's port
and fail to find their sound card or crash. Set it back to the SB16's,
`SET BLASTER=A220 I5 D1 H5 T6`.

The menu's "Sound" chooses the cards in the PC: "SB16", "GUS" or
"SB16 + GUS" (the default). With "GUS" alone nothing answers at 220h, so
software finds no Sound Blaster and uses the Ultrasound; AdLib's FM at 388h
and the CD audio stay. With "SB16" alone there is no card at 240h. Reset the
PC after a change, as after taking a card out.

Below it, "GUS volume" sets the Ultrasound's level in the output: "Full",
"-6 dB" (the default) or "-12 dB". A real card has its own line out; here
both cards share one, and the Ultrasound at full scale is much louder than
the Sound Blaster, whose mixer starts at -14 dB. If the GUS sounds harsh or
too loud even with the speakers turned down, lower it here. The change is
heard at once.

## Known limits

- A 486 at 66 MHz with a microcoded FPU: Pentium-era 3D games are slow.
- Some games don't detect the joystick with the default "Timing: Timed": set
  the Joystick menu's Timing to "Count" for them. TIE Fighter finds the stick
  with "Count"; with "Timed" only when the stick is held to the upper left
  while it starts (as on ao486 on MiSTer).
- The core fixes z486_MiSTer's `boot0.rom` as it loads it, so the mouse can't
  get stuck out of step. With another system BIOS, the pointer can start
  jumping between the screen edges when a program starts or quits while the
  mouse is moving: load the mouse driver again (`ctmouse`).
- The internal drive only reads and formats 512-byte sectors (no
  copy-protected disks).
- The ET4000 has no linear framebuffer (the W32's linear window). Games that
  bring SciTech's UniVBE engine take it for an ET4000/W32 and can show a black
  screen while they run (The Eleventh Hour, with sound), and Linux's VESA
  framebuffer (`vga=791` and the like) stops with "undefined mode number".
- OS/2's SVGA support finds 256 KB of video memory, so OS/2's desktop stays at
  640x480 in 16 colours.
- Windows draws the mouse pointer itself (the ET4000AX has no hardware
  cursor), so it can flicker when the picture under it changes.
- The Gravis Ultrasound has 512 KB of sample memory (a classic card takes up
  to 1 MB). Module players fit a song's samples into it: on the biggest songs
  they store some samples at lower quality (XTC-Play and Open Cubic Player mark
  those with ½), so those songs can sound duller than on a card with 1 MB.
- Quake's sound through the Gravis Ultrasound crackles: Quake's buffer holds
  53 ms, and at 8 fps it refills it in time only just. Clear `ULTRASND`
  (`SET ULTRASND=`) before starting Quake and it uses the Sound Blaster.
- The MPU-401 at 330h (UART mode, from z486_MiSTer) has no MIDI port to send
  to on the MEGA65: Windows 95 finds it as "MPU-401 Compatible", and music
  sent there is silent. Choose the Gravis or the Sound Blaster's FM synth for
  MIDI instead (in Windows 95: Control Panel, Multimedia, MIDI).
- In native HDMI mode the picture is measured one line short: the top line
  can be missing.
- The MEGA65's own software can leave the SD cards in SPI mode before the core
  starts: the back card when the internal slot is empty, both cards after
  MEGAFLASH has read them. A card stays in SPI mode until it loses power, and
  the PC's disks then run about 40 % slower. `<SD card info>` shows it ("SPI
  25 MHz", "re-insert for native"). Take the card out and put it back in: it
  comes back native at once, also at a DOS prompt with the PC running from it
  (not while it writes).

## Documentation

- [Design notes](doc/design.md): how the core is put together, part by part
- [Disks](doc/disks.md): the floppy, IDE and CD-ROM drives and the SD card path
- [SDRAM clock](doc/sdram-clock.md): how the SDRAM clock's phase was measured
- [x87](doc/x87.md): the FPU's clocks per instruction and its accuracy gaps
- [CPU](doc/cpu.md): where the integer core is slower than a 486, and what changed
- [Building](doc/building.md): the repository's layout and how to build the core
- [Results](doc/results.md): build and timing results
- [M2M provenance](doc/m2m-provenance.md): the framework's origin

## Credits

- z486 and z486_MiSTer by nand2mario. The z486 microcode image comes with the
  z486 submodule and is not covered by its licence; this repository does not
  contain a copy.
- MiSTer2MEGA65 by sy2002 and MJoergen; Megamiga's fork and pc10-iii by Johan
  Smolinski (the framework, the shell's starting point).
- PCXT-EGA-MEGA65 by silent-command, for the approaches to storage, keyboard
  and mouse on the MEGA65.
- The Gravis Ultrasound's GF1: LPC-GUS by nukeykt (`CORE/sv/gus/gf1.v`), a
  model of the chip built from John McMaster's die shot.

## Licence

z486MEGA65 is licensed under the GNU General Public License version 3, like
the MiSTer2MEGA65 framework it is built on: see [LICENSE](LICENSE). The
submodules keep their own licences:

- z486: the Apache License 2.0 for its SystemVerilog, Python and Markdown
  files (its `LICENSE-SCOPE.md`); its microcode image is not covered.
- QNICE-FPGA: BSD-3-Clause.
- z486_MiSTer: the notices in its files (the MiSTer framework's files are GPL
  version 2 or later).
- `CORE/sv/gus/gf1.v` (LPC-GUS): GPL version 2 or later.

The core built from this repository (the `.bit` and `.cor` files) contains
z486's microcode image, which none of these licences cover. The BIOS images
the core loads from the SD card are not part of it.

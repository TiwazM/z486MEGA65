# z486MEGA65

A port of [z486_MiSTer](https://github.com/nand2mario/z486_MiSTer), nand2mario's
486DX2-class PC built around the [z486](https://github.com/nand2mario/z486) CPU,
to the MEGA65 R6.

It runs at 64 MHz, boots DOS and Windows 3.11, and plays games from the CD era.
The current version is **v0.1-preview** (see
[Releases](https://github.com/TiwazM/z486MEGA65/releases)).

## Features

**PC**
- z486 486DX2-class CPU at 64 MHz, with L1 caches and an x87 FPU
- 256 KB L2 cache in block RAM, as on a 486 board
- 64 MB RAM (the R6's SDRAM)
- Turbo switch: CAPS LOCK slows the CPU to 33 MHz for games that run too fast

**Video**
- Tseng ET4000 SVGA, up to 1024x768 in 256 colours (Windows 3.11 included)
- HDMI out at 720p, 480p, 800x600, 1024x768, 1280x1024, or the PC's own native
  resolution
- Scaling filters (Sharp, Smooth, Pixels) and optional scanlines (25 % or 50 %)
- No tearing when the PC's 70 Hz text mode goes out at 60 Hz

**Sound**
- Sound Blaster 16 with OPL3 FM music
- CD audio, played in hardware and mixed through the Sound Blaster's CD volume

**Disks**
- IDE hard disk from an image file on the SD card
- Floppy drives A: and B: from image files, swapped from the menu
- ATAPI CD-ROM drive:
  - ISO images, raw BIN images, and BIN/CUE discs, including multiple files,
    WAVE audio, pregaps and mixed sector sizes
  - Up to 99 tracks, with CD audio
  - Works with DOS CD-ROM drivers and MSCDEX, and Windows' Media Player
- Disc and disk images mount automatically at start-up, or from the menu at any
  time

**Input**
- The MEGA65 keyboard as a PC keyboard, with symbols as on the keycaps. MEGA works
  as an Fn key for Page Up/Down, Home/End and Delete.
- PS/2 mouse on joystick port 1:
  - Commodore 1351, or a mouSTer in C64 mode: both buttons, detected
    automatically
  - Amiga mouse, or a mouSTer in Amiga mode: F13 is the right button
- Game port joystick on port 2 with up to three buttons. The second fire button
  can be on pin 9 (C64GS style) or pin 5, set in the menu.

**Core**
- Menu on HELP: disks, HDMI mode, filter, scanlines, joystick, reset; settings
  are saved to the SD card
- The reset button and Ctrl+Alt+Del restart the PC cleanly

## Tested

On an R6: MS-DOS, FreeDOS, Windows 3.11 (SVGA, Media Player CD audio), DOOM,
SimCity 2000, Wing Commander III, King's Quest VI, Phantasmagoria, The 7th
Guest, Ultima Underworld 1 and 2, Day of the Tentacle (CD talkie), The Secret
of Monkey Island (CD, with its CD music), and Quake (slowly: about 6 fps in
`timedemo demo1`).

Ultima Underworld 2 wants its Sound Blaster Pro option with a Pro in
`BLASTER` (`SET BLASTER=A220 I5 D1 T4` before it starts): with its Sound
Blaster option it hangs. Wing Commander III runs best without EMM386
(`HIMEM.SYS` only): with it, a video can hang the game on a black screen.

## Getting started

1. Flash `z486-R6-<version>.cor` from [Releases](https://github.com/TiwazM/z486MEGA65/releases)
   with MEGAFLASH. The `.bit` is the same core, for loading over JTAG.
2. Put the BIOS files, and any disk images, on the SD card:

```
/z486/boot0.rom    the system BIOS
/z486/boot1.rom    the VGA BIOS
/z486/floppy.img   optional: drive A: at start-up (a raw floppy image)
/z486/hdd.img      optional: the hard disk at start-up (a raw disk image)
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
| CAPS LOCK | the turbo switch: down (it latches) = the CPU at 33 MHz, up = full speed (64 MHz); z486's throttle, memory and devices keep full speed. The PC's Caps Lock is MEGA+TAB (SHIFT LOCK holds Shift: the MEGA65 wires it to the left Shift) |
| NO SCROLL | Scroll Lock |
| symbol keys and shifted digits | as on their keycaps: `:` (Shift `[`), `;` (Shift `]`), `@`, `*`, `+`, `-`, `=`, Shift+2 `"`, Shift+6 `&`, Shift+7 `'`, Shift+8 `(`, Shift+9 `)`, ... (the PC sees Shift pressed or released as each one needs) |
| PC symbols without a keycap | `£` `\` (Shift `|`), arrow-up `^` (Shift `~`), arrow-left `` ` ``, Shift+`-` `_`, Shift+`@` `{`, Shift+`*` `}` |
| MEGA | the Fn key above, nothing by itself |
| F13 | the mouse's right button (see [Mouse and joystick](#mouse-and-joystick)) |
| HELP | the menu |

## Mouse and joystick

- **Mouse on port 1.** A Commodore 1351, or a USB mouse behind a mouSTer set to
  C64 mode (`c1351` and `mode=mouse` in its INI), has both buttons. An Amiga
  mouse, or a mouSTer in Amiga mode, works too, but the MEGA65 can't read its
  right button (pin 9): F13 stands in for it. The core tells them apart by
  itself. Load a PS/2 mouse driver (CuteMouse, or Windows' "Microsoft or IBM
  PS/2"). There is no scroll wheel.
- **Joystick on port 2** is the PC's game port joystick. Fire is button 1. A C64
  two- or three-button stick's extra buttons are buttons 2 and 3: the second on
  pin 9 (POT X, as the C64GS), or on pin 5 if your stick has it there ("Joystick
  fire 2" in the menu).

## Known limits

- A 486 at 64 MHz with a microcoded FPU: Pentium-era 3D games are slow.
- Some games don't detect the joystick. TIE Fighter does when the stick is
  held to the upper left while it starts (as on ao486 on MiSTer).
- The core fixes z486_MiSTer's `boot0.rom` as it loads it, so the mouse can't
  get stuck out of step. With another system BIOS, the pointer can start
  jumping between the screen edges when a program starts or quits while the
  mouse is moving: load the mouse driver again (`ctmouse`).
- The MEGA65's own floppy drive isn't used.
- CD music while a game loads from the hard disk hasn't been tried on the board
  yet.

## Documentation

- [Design notes](doc/design.md): how the core is put together, part by part
- [Disks](doc/disks.md): the floppy, IDE and CD-ROM drives and the SD card path
- [SDRAM clock](doc/sdram-clock.md): how the SDRAM clock's phase was measured
- [x87](doc/x87.md): the FPU's clocks per instruction and its accuracy gaps
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

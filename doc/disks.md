# Disks

Part of [z486MEGA65](../README.md). The floppy, IDE and CD-ROM drives in hardware, and the SD card path behind them.

The menu's "Floppy A:", "Floppy B:", "Hard disk:" and "CD-ROM:" lines mount an
image file from the card, under any name; writes go to the file.

- **Floppies:** raw images of 360K, 720K, 1.2M, 1.44M or 2.88M; the size gives
  the geometry and the drive type in the CMOS. A floppy mounted while the PC
  runs is a disk change, as on a real drive, so disks can be swapped during an
  installation. The PC boots from A: when it holds a floppy, else from the
  hard disk (z486's default boot order, as on MiSTer).
- **Hard disk:** a raw image of any whole number of 512-byte sectors, up to
  4 GB less 512 bytes, the largest file FAT32 holds. The BIOS looks for disks
  only when the PC starts: after mounting one from the menu, "Reset the PC".
  It reads the size from IDENTIFY (LBA) and translates for DOS.
- **CD-ROM:** a disc image, any time: the drive is always there, the master
  of the second IDE channel (ports 170h/376h, IRQ 15), with or without a
  disc, and a new disc is a media change for the driver. The BIOS lists it
  ("IDE1 master: CD-ROM z486 MEGA65 CD-ROM"); MS-DOS 6.22 reads it with
  `DEVICE=OAKCDROM.SYS /D:MSCD001` and `MSCDEX /D:MSCD001` (tested on the
  board; OAKCDROM.SYS comes with Windows 98's boot disk). The image can be
  - an ISO (whole 2048-byte sectors, one data track);
  - a raw `.bin` (whole 2352-byte sectors, one data track, MODE1 or MODE2);
  - a `.cue` sheet with its files in the same folder: data and CD audio
    tracks, one file for all or one per track (`FILE ... BINARY`, `MOTOROLA`
    for big-endian audio, `WAVE`: PCM, 16-bit stereo, 44.1 kHz; MP3 and other
    compressed audio are refused: convert those tracks to WAVE or BIN),
    `TRACK` (`AUDIO`, `MODE1/2048`, `MODE1/2352`, `MODE2/2352`, `MODE2/2336`),
    `INDEX 00/01`, `PREGAP`, `POSTGAP`; at most 99 tracks, one session, 16K
    characters of cue text and 511 fragments for all its files together.
  Mount the `.cue` (the firmware, `cdimage.asm`, reads it and maps its files).
  **CD audio**: PLAY AUDIO (10, 12, MSF, TRACK/INDEX), PAUSE/RESUME, STOP and
  READ SUB-CHANNEL, as MSCDEX and games use them; the music goes through the
  Sound Blaster mixer's CD volume (and its CD output switches) and the drive's
  own volume (MODE SELECT page 0Eh, what a game's music slider sets through
  MSCDEX). As on a real drive, a READ (or SEEK) stops the music: games load
  their data first, or stop the music to load. A track's pregap that is in no
  file (`PREGAP`) plays as silence. `qmon.py cd` shows the disc's tracks and
  how the music goes.
- **Eject:** every folder of the file browser starts with `<No Disk>` (right
  after `<..>`): choosing it empties the drive. A mount lasts until the
  MEGA65 is switched off; only `/z486/floppy.img`, `/z486/hdd.img` and
  `/z486/cdrom.cue` (or `/z486/cdrom.iso`) come back by themselves.

An empty hard disk, on macOS (or `truncate -s 2G hdd.img` on Linux):

```bash
mkfile -n 2g hdd.img
```

On Windows, in PowerShell (or `fsutil file createnew hdd.img 2147483648` in a
Command Prompt, which may need "Run as administrator"):

```powershell
$f = [System.IO.File]::Create("$PWD\hdd.img"); $f.SetLength(2GB); $f.Close()
```

Copy it to the card as `/z486/hdd.img`, boot FreeDOS's boot floppy from A:,
and let the installer partition and format C: (it restarts the PC in between)
and install, swapping the floppies through the menu's "Floppy A:" line. To
start from C: afterwards, choose `<No Disk>` for A: and "Reset the PC".

Reads come in runs: one multi-block SD read (CMD18) for the sectors the PC
will read next (what an IDE command still wants, a track on a floppy), within
the image's extent, into a ring of 32 sectors. The PC's sector is answered as
soon as it is in, and the next ones come out of the ring; the card waits (its
clock stopped) while the ring is full, so a 64-sector DOS cluster is one SD
command. A read elsewhere ends the run. Before, every sector was an SD
command of its own, about 440 µs: Dr. Hardware measured 997 KB/s with 64 KB
blocks; with the runs 2989 KB/s (10 KB blocks: 1036 -> 2624 KB/s), the
average sector 456 -> 146 µs. Its access time stayed 6.1-6.2 ms. A CD-ROM
READ is one run too: its 2048-byte sectors are four of the image's.

Writes come in runs as well (2026-11-07). Before, every sector was an SD
write of its own (CMD24), and the card programmed each one before taking the
next: about 6 ms a sector on the board, 83 KB/s, over ten minutes for a 50 MB
game install. Now an IDE write command is one multi-block SD write (CMD25) of
its sectors, within the image's extent: `pc_mgmt` says how many sectors the
command still writes, the write buffer has four slots, a sector is answered
as soon as the next one has a free slot, and the card waits between blocks
(its clock stopped) until the PC has the next one. The command's last sector
is answered only once the whole run is on the card, so the command ends with
its data written. Any other request first lets the run write every sector it
has. A floppy still writes one sector at a time. `tb_ide.sv` checks runs of
1 to 64 sectors with a slow and a fast card, across two extents, with QNICE
taking the card and with an SD error in the middle, and a write the PC
abandons after 3 of 8 sectors: every block reaches the card once. On the
board a write is answered in about 50 us on average instead of 6.1 ms, and
copies compare equal with `fc /b`.

`tools/qmon.py disks` shows the sector counts, the time per sector and the SD
transfers (`disks clear` zeroes them, `disks watch 10` counts sectors per
second over 10 seconds).

Checked on the board with MS-DOS 6.22 (`fc /b` of a file against itself and
against fresh copies, 25,151 sectors read and 2,325 written): no wrong data,
no failed or repeated transfers.

The ring lost bits in block RAM. The 7th Guest's videos broke up, it hung
now and then, and DOS said "Invalid COMMAND.COM" on its exit: now and then a
bit of a sector read came out wrong, near the end of the sector, in the
data's lower bits, a 1 more often than a 0. PIOTEST (below) found 1 to 1500
wrong sectors per GB, by where Vivado had put the ring's block RAMs (much the
most with one on RAMB36_X5Y37, which `CORE-impl.xdc` now leaves empty); the
ring's write port on the QNICE clock or on the PC's, its slots split over
two block RAMs by parity, did not help. A checksum per sector, as the engine
writes it into the ring and as `pc_mgmt` or `pc_cdrom` copies it out, caught
every one: the bits were stored wrong (copying the slot again never helped),
and a sector read again from the card came out right (1,390 of 1,390 in
2 GB). With the ring in LUT RAM, none in 1.7 GB, at the same supply and
temperature (the XADC: VCCINT and VCCBRAM within 0.01 V of 1.0 V, 52-59
degrees C). So the ring and the write buffer are LUT RAM (`disk_sd`'s
`G_LUTRAM`), and the checksums stay: a copy that does not match is read again
fresh from the card, twice at most, for the hard disk, the CD-ROM (its
2048-byte block again, as `ide.v`'s buffer only rewinds to its start) and
the floppies (checked before `floppy.v`'s FIFO gets the sector).
`qmon.py disks` counts them: copies that matched, copies that did not,
sectors read again fresh and how many of those came right.

An SD card that a core has used in SPI mode (MegaMac does) stays in SPI mode
until it loses power, and loading z486 over JTAG does not power it: the SD
host's native 4-bit bus then fails and it falls back to SPI at 25 MHz, which
works but makes the disks about 8x slower (PIOTEST 1,940 instead of 3,000+
KB/s). `qmon.py disks` shows each slot's bus (native 4-bit at 50 MHz, or SPI);
take the card out and put it back in once (or switch off) to bring it back to
the native bus.

`tools/dos/` has the test programs, on `tools/dos/build/z486test.iso` for
the CD-ROM drive (`tools/dos/build.sh`, GNU as in the build image):
- `PIOTEST.COM`: from C:, reads `PIOPAT.BIN` (4 MB, it writes it when it is
  missing) straight from the IDE ports, past the BIOS and DOS, with REP
  INSW, single INs, REP INSD and INs compared in registers (nothing stored),
  pass after pass until a key. Each sector's bytes are its own: a wrong byte
  says whether it belongs to another sector (and which) or has bits flipped.
- `VTEST.COM`: the SVGA video memory through VESA's bank window, conventional
  RAM, XMS and reads through DOS (`CDPAT.BIN` on the CD; `VTEST W` writes it),
  with the timer at 10 kHz and Sound Blaster DMA running, as during a game.
- `CPUSPEED.COM [MHz] [F]`: the CPU's clocks per instruction in real mode (about
  30 integer kinds and 41 of the FPU, the PIT's counter 2 as the clock), beside a
  486's, and the MHz a speed test that times each one would report (64 unless
  given). A row well under 64 is an instruction z486 takes longer for than a
  486. `F` shows only the FPU's rows; all of them are more than a screen
  (`CPUSPEED > SPEED.TXT`).

`tools/floppy-packer.html`, a page that runs in any browser without a server,
packs files into a FAT12 floppy image of any of the five sizes, with DOS's
8.3 file names checked.

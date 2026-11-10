#!/usr/bin/env python3
# Reads z486's debug registers (C_DEV_PC_CTL, CORE/vhdl/mega65.vhd) and the disks' (C_DEV_PC_DISK,
# disk_sd.vhd) over the MEGA65 JTAG adapter's UART, 115200 8N1, while the Shell and the PC run:
# through the firmware's serial commands (m2m-rom.asm, HANDLE_CORE_IO: R/W QNICE memory, D/P a
# device's registers), no debug mode needed. QMON_MONITOR=1 talks to the QNICE monitor of the M2M
# debug mode instead (hold Run/Stop + Cursor Up, then press Help). QMON_PORT overrides the serial
# port.
#
#   qmon.py CMD...            each CMD is sent as is (a firmware command such as "R80008",
#                             or a monitor command in debug mode); the replies are printed
#   qmon.py status            z486's debug snapshot (C_DEV_PC_CTL 0x10..0x17) and the log
#   qmon.py boot PHASE [SECS] reset the PC with the SDRAM clock at PHASE fine steps (13.95 ps)
#                             from 292.5 degrees, wait SECS (default 3), print the status
#   qmon.py sweep FROM TO STEP [SECS]   boot at each phase, one summary line each
#   qmon.py disks             the disks (disk_sd.vhd, C_DEV_PC_DISK): mounts, statistics, times
#   qmon.py l2 [on|off]       the L2 cache: line fills from it and from the SDRAM (rates over
#                             2 s); on/off switches it (on empties it first)
#   qmon.py l1 on|off         z486's L1 caches (every access uncached while off; after on,
#                             reset the PC: their lines may be stale)
#   qmon.py disks clear       zero the disks' statistics
#   qmon.py disks watch [s]   sectors per second over s seconds (default 10)
#   qmon.py xadc              the FPGA's temperature, VCCINT, VCCAUX, VCCBRAM: now, and the
#                             lowest and highest since the core was loaded (xadc_mon.vhd)
#   qmon.py iotrace           the I/O trace (mega65.vhd p_main_iot): the last 1024 accesses to
#                             the DMA controllers, PICs, 8042 and Sound Blaster, its IRQs, its
#                             DMA requests' long waits and the DMA commands its DSP held back,
#                             with microseconds, and its samples' big jumps; stops it first
#                             ("peek": reads it running)
#   qmon.py iotrace start [freeze] [once] [quiet] [timer]
#                             start it again (empty); "freeze": stop at the card's first 1 ms
#                             wait; "once": stop when full (the first 1024 entries); "quiet":
#                             leave out DMA flip-flop clears and status reads (a driver polling
#                             its position fills the trace with them in a tenth of a second);
#                             "timer": the PIT (40-43h) and port 61h too, writes and reads that
#                             change (what a program waits on there)
#   qmon.py iotrace jump [N]  the smallest sample jump it logs, N/256 of the full range
#                             (default 64)
#   qmon.py sbfix [on|off]    the Sound Blaster's stalled-transfer fix (sound_dsp.v's
#                             dma_take_starved, z486_sources.py; on after the core loads)
#   qmon.py sbsoft [on|off]   the Sound Blaster DSP's output stage (z486_mega65.sv's sb_soft:
#                             its output glides to 0 when it stops or mutes; on after the
#                             core loads), for listening both ways
#   qmon.py joy [secs]        port 2's joystick (the game port) over secs seconds (default
#                             30): every change of its directions and buttons; fire 2 and 3
#                             are its paddle lines (pins 9 and 5, or as the menu says)
#   qmon.py intahold [on|off] the PIC holds its vector from the CPU's first INTA to its
#                             acknowledge (pic_inta_bridge.sv's vector_hold, z486_sources.py;
#                             on after the core loads; off, an IRQ that rises in between can be
#                             acknowledged in place of the one the CPU took, and is lost)
#   qmon.py pic               the PICs' IRR, ISR and masks, the IRQ lines, the 8042's state, the
#                             INTAs acknowledged with another vector, the mouse (also in status)
#   qmon.py bios              whether the system BIOS's copy has the mouse handler's sync check
#                             (m2m-rom.asm's bios_patch.asm: z486_MiSTer's boot0.rom only)
#   qmon.py c1351 [normal|flipx|flipy|flipxy] [swap|noswap]
#                             the mouse on port 1: an Amiga mouse or a 1351 (pc_mouse.vhd), the
#                             paddle values, and a 1351's axes reversed or swapped (default
#                             normal, noswap: x on POT X, pin 9)
#   qmon.py cd                the CD-ROM's disc (its track table, C_DEV_PC_CDTOC, written by
#                             m2m-rom.asm's cdimage.asm) and its audio (pc_cdrom.vhd): the
#                             status, the LBA heard, the FIFO's underruns and lowest fill
#   qmon.py fdd               the internal floppy drive as a PC drive (fdd_phys.vhd): requests,
#                             errors, ID and data fields read, sectors written, the track buffer, the head, the
#                             data separator's cell and the disk's speed
#   qmon.py ide [N]           the IDE trace (mega65.vhd, pc_mgmt.vhd): the last N events
#                             (default 40, at most 512) of both IDE channels and the floppies,
#                             with milliseconds before the newest
import os, re, sys, termios, time

PORT = os.environ.get("QMON_PORT", "/dev/cu.usbserial-101")

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0                                   # iflag
a[1] = 0                                   # oflag
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[3] = 0                                   # lflag
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIOFLUSH)


def read_for(secs, until=b"QMON> "):
    buf = b""
    end = time.time() + secs
    while time.time() < end:
        try:
            d = os.read(fd, 4096)
            if d:
                buf += d
                if until and buf.endswith(until):
                    break
                continue
        except BlockingIOError:
            pass
        time.sleep(0.005)
    return buf.replace(b"\r", b"").decode("latin-1")


MONITOR = os.environ.get("QMON_MONITOR") == "1"
cur_dev, cur_win = 0, 0                    # the device window the next D/P command selects


def cmd(c, secs=5.0):
    if MONITOR:                            # the monitor reads keys one at a time
        for ch in c.encode():
            os.write(fd, bytes([ch]))
            time.sleep(0.004)
    else:                                  # the firmware's UART has a 32-byte FIFO
        os.write(fd, c.encode())
    return read_for(secs)


def poke(addr, val):
    global cur_dev, cur_win
    if MONITOR:
        cmd("MC%04X%04X" % (addr, val & 0xFFFF))
    elif addr == 0xFFF4:                   # M2M$RAMROM_DEV / _4KWIN: for the next D/P
        cur_dev = val
    elif addr == 0xFFF5:
        cur_win = val
    elif 0x8000 <= addr <= 0x8FFF:
        cmd("P%04X%04X%04X%04X" % (cur_dev, cur_win, addr, val & 0xFFFF))
    else:
        cmd("W%04X%04X" % (addr, val & 0xFFFF))


def dump(start, end):
    n = end - start + 1
    if MONITOR:
        out = cmd("MD%04X%04X" % (start, end))
    elif 0x8000 <= start <= 0x8FFF:
        out = cmd("D%04X%04X%04X%04X" % (cur_dev, cur_win, start, n), 5.0 + n / 1500)
    else:
        out = cmd("R%04X%04X" % (start, n), 5.0 + n / 1500)
    words = {}
    for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", out, re.M):
        base = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            words[base + i] = int(w, 16)
    return [words.get(a) for a in range(start, end + 1)]


def pc_dev():
    poke(0xFFF4, 0x0100)                   # M2M$RAMROM_DEV = C_DEV_PC_CTL
    poke(0xFFF5, 0x0000)                   # window 0


def status():
    pc_dev()
    w = dump(0x8010, 0x8017)
    ps = dump(0x8001, 0x8002)
    st = w[0]
    s = {
        "stage": st & 7, "copied": st >> 3 & 1, "vga_chk": st >> 4 & 1, "vga_bad": st >> 5 & 1,
        "first": st >> 6 & 1, "pe": st >> 7 & 1, "sdram_busy": st >> 8 & 1, "reset": st >> 9 & 1,
        "post": w[1] & 0xFF, "posts": w[1] >> 8, "cs": w[2], "eip": w[4] << 16 | w[3],
        "logs": w[5], "vsyncs": w[6], "snap": w[7], "ps_target": ps[0], "ps_pos": ps[1],
    }
    joy = dump(0x801C, 0x801C)[0]          # bits 9..2: the game port's joystick
    if joy is not None:
        s["joy"] = joy >> 2 & 0xFF
        s["sb_req"] = joy >> 10 & 3        # the Sound Blaster's DMA requests: 8-bit, 16-bit
    io = dump(0x801D, 0x801F)              # the last I/O read and write, 48 bits
    if None not in io:
        v = io[2] << 32 | io[1] << 16 | io[0]
        s["io_rd"], s["io_wr"] = v & 0xFFFFFF, v >> 24
    return s


def log(n):
    if n == 0:
        return ""
    pc_dev()
    poke(0xFFF5, 0x0001)                   # the log: device addresses 0x1000.., window 1
    if n <= 4096:
        ent = dump(0x8000, 0x8000 + n - 1)
    else:                                  # wrapped: the oldest entry is at n mod 4096
        ent = dump(0x8000, 0x8FFF)
        ent = ent[n % 4096:] + ent[:n % 4096]
    out = ""
    for e in ent:
        if e is None:
            continue
        kind, c = e >> 8 & 3, e & 0xFF
        dev = "mou" if e & 0x400 else "kbd"   # bit 10: the mouse
        if kind == 1:
            out += "[POST %02X]" % c
        elif kind == 2:
            out += "[>%s %02X]" % (dev, c)    # the 8042 to the device
        elif kind == 3:
            out += "[<%s %02X]" % (dev, c)    # the device to the 8042
        else:
            out += chr(c) if (c >= 32 and c < 127) or c == 10 else "\\x%02X" % c
    return out


def boot(phase, secs):
    pc_dev()
    poke(0x8000, 0)                        # PC (and its SDRAM controller) into reset
    poke(0x8001, phase)                    # SDRAM clock phase
    time.sleep(0.05)
    poke(0x8000, 1)                        # ROMs are still in HyperRAM: boot again
    time.sleep(secs)
    return status()


def line(s):
    return ("phase %5d (pos %5d)  stage %d copied %d first %d pe %d  POST %02X x%-3d  "
            "CS:EIP %04X:%08X  log %4d  vsyncs %5d" %
            (s["ps_target"] - (0x10000 if s["ps_target"] & 0x8000 else 0),
             s["ps_pos"] - (0x10000 if s["ps_pos"] & 0x8000 else 0),
             s["stage"], s["copied"], s["first"], s["pe"], s["post"], s["posts"],
             s["cs"], s["eip"], s["logs"], s["vsyncs"]))


def sd_modes():
    # each slot's SD host (sdhost.vhd: 0xFF25 the CSR, 0xFF26 the bus mode) through
    # M2M$SD_SLOT (0xFF27), put back afterwards. A card that an SPI-only controller has used
    # (MegaMac) stays in SPI mode until it loses power: the native bus fails, ~8x slower.
    old = dump(0xFF27, 0xFF27)[0]
    for slot, where in ((0, "bottom"), (1, "back")):
        poke(0xFF27, slot)
        csr, mode = dump(0xFF25, 0xFF26)
        ctype = ["no card / unknown", "SD V1", "SD V2", "SDHC"][csr >> 12 & 3]
        if not mode & 4:
            bus = "not ready"
        elif mode & 1:
            bus = "native 4-bit, " + ("50 MHz (high speed)" if mode & 0x10 else "25 MHz")
        else:
            bus = "SPI, %s MHz%s" % ("12.5" if mode & 2 else "25",
                                     " (SPI only)" if mode & 8 else " (the native bus failed)")
        print("SD slot %d (%s): %s, %s, %d transfers retried" % (slot, where, ctype, bus, mode >> 8))
    poke(0xFF27, old)


def disks():
    sd_modes()
    poke(0xFFF4, 0x0101)                   # M2M$RAMROM_DEV = C_DEV_PC_DISK
    poke(0xFFF5, 0x0000)
    for u, name in enumerate(["A:", "B:", "hard disk", "CD-ROM"]):
        r = dump(0x8000 + 0x20 * u, 0x8008 + 0x20 * u)
        geo = "  geometry %d/%d/%d" % (r[6], r[8], r[7]) if u < 2 else ""
        print("%-9s mode %d (%s%s%s)  sectors %d  base %d  shift %d%s" %
              (name, r[0], "mounted" if r[0] & 1 else "empty", ", slot 1" if r[0] & 2 else "",
               ", write protected" if r[0] & 4 else "", r[2] << 16 | r[1], r[4] << 16 | r[3], r[5], geo))
    st = dump(0x8010, 0x801F)
    print("sectors read %d  written %d  failed %d  last request: %s %s LBA %d, %d us" %
          (st[0], st[1], st[2], "write" if st[3] & 0x8000 else "read",
           ["A:", "B:", "hard disk", "CD-ROM"][st[3] >> 13 & 3], st[5] << 16 | st[4], st[12]))
    rd_t, wr_t = st[7] << 16 | st[6], st[10] << 16 | st[9]
    print("read  average %s us, slowest %d us" % ("%d" % (rd_t // st[0]) if st[0] else "-", st[8]))
    print("write average %s us, slowest %d us" % ("%d" % (wr_t // st[1]) if st[1] else "-", st[11]))
    print("tried again after an error %d, after QNICE's own SD access %d" % (st[13], st[14]))
    print("SD transfers started %d (runs of sectors read ahead, and writes): %s sectors per transfer"
          % (st[15], "%.1f" % ((st[0] + st[1]) / st[15]) if st[15] else "-"))
    ck = dump(0x8009, 0x800F)
    print("ring checksums (since the core started, 16 bits): %d copies matched, %d did not, "
          "%d sectors read fresh from the card, %d of them right then" % (ck[0], ck[1], ck[6], ck[2]))
    if ck[1]:
        print("  the last that did not: slot %d, checksum %04X wanted, %04X read" % (ck[3], ck[4], ck[5]))


def cd():
    pc_dev()
    st = dump(0x8008, 0x800B)
    if None in st:
        print("no answer")
        return
    ast = st[0] >> 8
    print("audio: %s, LBA heard %d, samples the FIFO did not have %d, fewest words in it %s" %
          ({0x11: "playing", 0x12: "paused", 0x13: "done", 0x14: "stopped by an error",
            0x15: "none"}.get(ast, "%02X" % ast), (st[0] & 0xFF) << 16 | st[1], st[2],
           "-" if st[3] == 0x3FFF else "%d of 8192" % st[3]))
    poke(0xFFF4, 0x0105)                   # M2M$RAMROM_DEV = C_DEV_PC_CDTOC
    poke(0xFFF5, 0x0000)
    h = dump(0x8000, 0x8006)
    n = h[0]
    if not n or n > 99:
        print("no disc (%s tracks in the table)" % n)
        return
    msf = lambda l: "%02d:%02d:%02d" % ((l + 150) // 4500, (l + 150) // 75 % 60, (l + 150) % 75)
    print("%d tracks (%d..%d), %s, lead-out at LBA %d (%s)" %
          (n, h[1] & 0xFF, h[1] >> 8, {1: "data", 2: "audio", 3: "data and audio"}.get(h[4], "?"),
           h[3] << 16 | h[2], msf(h[3] << 16 | h[2])))
    print("track  type          INDEX 00  INDEX 01 (MSF)     in its file  end    sector  byte in the image")
    e = dump(0x8800, 0x8800 + 16 * n - 1)
    for k in range(n):
        w = e[16 * k:16 * k + 16]
        l32 = lambda i: w[i + 1] << 16 | w[i]
        kind = "audio" if w[3] & 1 else "data"
        if w[3] & 2:
            kind += " (BE)"
        print("%5d  %-12s %9d %9d (%s) %6d-%-6d %6d  %4d+%-2d %d" %
              (w[0] & 0xFF, kind, l32(4), l32(6), msf(l32(6)), l32(8), l32(10) - 1, l32(12),
               w[1], w[2], l32(14)))


def bios():
    import bios_patch
    want = bios_patch.asm_values(bios_patch.ASM)[1]
    poke(0xFFF4, 0x0004)                   # M2M$HYPERRAM: the ROM window (0xF0000 = 0x01F8)
    got = []
    for win in sorted({w for w, _, _ in want}):
        offs = [o for w, o, _ in want if w == win]
        poke(0xFFF5, win)
        got += dump(0x8000 + min(offs), 0x8000 + max(offs))
    pc_dev()
    new = sum(g == w for g, (_, _, w) in zip(got, want))
    if None in got:
        print("no answer")
    elif new == len(want):
        print("system BIOS: the mouse handler's sync check is in (F000:5209 -> F000:E000)")
    elif new == 0:
        print("system BIOS: as loaded, no sync check (not z486_MiSTer's boot0.rom?)")
    else:
        print("system BIOS: %d of %d patched words as expected" % (new, len(want)))


def xadc():
    pc_dev()
    v = dump(0x8020, 0x802B)
    deg = lambda c: (c >> 4) * 503.975 / 4096 - 273.15
    volt = lambda c: (c >> 4) * 3.0 / 4096
    print("              now      lowest   highest")
    print("temperature  %5.1f C  %5.1f C  %5.1f C" % (deg(v[0]), deg(v[8]), deg(v[4])))
    for i, name in ((1, "VCCINT "), (2, "VCCAUX "), (3, "VCCBRAM")):
        print("%s      %5.3f V  %5.3f V  %5.3f V" % (name, volt(v[i]), volt(v[i + 8]), volt(v[i + 4])))


def caches_set(bit, on):
    pc_dev()
    v = dump(0x8003, 0x8003)[0] & 3                 # bit 0 the L2, bit 1 the L1
    poke(0x8003, (v | bit) if on else (v & ~bit & 3))
    time.sleep(0.1)
    return dump(0x8003, 0x8003)[0] & 3


def l2(arg):
    pc_dev()
    if arg in ("on", "off"):
        caches_set(1, arg == "on")
    a, t0 = dump(0x8018, 0x801C), time.time()
    time.sleep(2)
    b, t1 = dump(0x8018, 0x801C), time.time()
    h0, m0 = a[1] << 16 | a[0], a[3] << 16 | a[2]
    h1, m1 = b[1] << 16 | b[0], b[3] << 16 | b[2]
    dt = t1 - t0
    dh, dm = (h1 - h0) & 0xFFFFFFFF, (m1 - m0) & 0xFFFFFFFF
    print("L2 cache %s; line fills since the PC's reset: %d from the cache, %d from the SDRAM" %
          ("on" if b[4] & 1 else "off", h1, m1))
    print("over %.1f s: %.0f fills/s from the cache, %.0f/s from the SDRAM (%s hits)" %
          (dt, dh / dt, dm / dt, "%.1f%%" % (100.0 * dh / (dh + dm)) if dh + dm else "-"))


def disks_clear():
    poke(0xFFF4, 0x0101)
    poke(0xFFF5, 0x0000)
    poke(0x8010, 0)


def disks_watch(secs):
    poke(0xFFF4, 0x0101)
    poke(0xFFF5, 0x0000)
    a, t0 = dump(0x8010, 0x8011), time.time()
    time.sleep(secs)
    b, t1 = dump(0x8010, 0x8011), time.time()
    dt = t1 - t0
    rd, wr = (b[0] - a[0]) & 0xFFFF, (b[1] - a[1]) & 0xFFFF
    print("in %.1f s: %d sectors read (%.0f/s, %.0f KB/s), %d written (%.0f/s, %.0f KB/s)" %
          (dt, rd, rd / dt, rd / dt / 2, wr, wr / dt, wr / dt / 2))


ST_BITS = [(0x80, "BSY"), (0x40, "DRDY"), (0x10, "DSC"), (0x08, "DRQ"), (0x04, "IRQ"),
           (0x02, "LAST"), (0x01, "ERR")]


def st_text(st):
    return "+".join(n for b, n in ST_BITS if st & b) or "0"


FDD_ERR = {0x0000: "done", 0x0001: "no ID field (MA)", 0x0101: "ID but no data field (MA, MD)",
           0x2020: "data CRC error (DE, DD)", 0x0004: "sector not found (ND)",
           0x1004: "sector not found, wrong cylinder (ND, WC)", 0x0002: "write protected (NW)"}


def fdd_err(e):
    return FDD_ERR.get(e, "ST2:ST1 %04X" % e)


def fdd():
    """The internal floppy drive as a PC drive (fdd_phys.vhd's stat_o, C_DEV_PC_CTL 0x40..4F)"""
    pc_dev()
    w = dump(0x8040, 0x804F)
    if None in w:
        sys.exit("no answer")
    st = ["idle", "setup", "positioning", "reading", "deciding", "recalibrating", "done",
          "write: finding the ID", "write: gap 2", "writing", "format: positioning",
          "format: waiting for the index", "formatting the track"]
    w9, w10 = w[9], w[10]
    print("requests %d  errors %d  last status: %s" % (w[0], w[1], fdd_err(w[2])))
    print("ID fields %d  data fields %d  CRC errors %d  sectors written (formatted too) %d" % (w[3], w[4], w[5], w[6]))
    print("last ID: C %d H %d R %d N %d" % (w[7] >> 8, w[7] & 0xFF, w[8] >> 8, w[8] & 0xFF))
    print("track buffer: %s C %d H %d, rate %s, side %d, write protected %d" % (
        "holds" if w9 & 0x10 else "empty,", w9 >> 8, w9 >> 2 & 1,
        "500 kbit/s (HD)" if w9 & 0x08 else "250 kbit/s (DD)", w9 >> 1 & 1, w9 & 1))
    slots = w[13] << 16 | w[14]
    print("  sectors in it: %s" % (" ".join(str(i) for i in range(32) if slots >> i & 1) or "none"))
    print("head on cylinder %d, %s; motor %s, selected %s, head ready %s, disk change line %s" % (
        w10 >> 8 & 0x7F, st[w10 >> 4 & 0xF] if (w10 >> 4 & 0xF) < len(st) else "?",
        "on" if w10 & 8 else "off", "yes" if w10 & 4 else "no", "yes" if w10 & 2 else "no",
        "active" if w10 & 1 else "inactive"))
    print("PLL cell %.2f clocks (%.3f us)  index period %.1f ms (%d rpm)" % (
        w[11] / 16.0, w[11] / 16.0 / 64, w[12] / 10.0, 600000 // w[12] if w[12] else 0))
    print("last request: C %d R %d" % (w[15] & 0xFF, w[15] >> 8 & 0x7F))


def ide_event(t, a, b, c, d):
    unit = ["A:", "B:", "HDD", "CD"]
    if t == 1:
        lba = (b & 0xF) << 24 | d
        where = "LBA %d" % lba if b & 0x40 else "CHS cyl %d sec %d" % (d >> 8, d & 0xFF)
        return "IDE0 command %02X  %s  count %d%s" % (a, where, c or 256, "  (slave)" if b & 0x10 else "")
    if t == 2:
        return "IDE0 status %s  error %02X  count %d  cyl/sec %06X" % (st_text(a), b, c, d)
    if t == 3:
        return "IDE0 block done  %s%s  left %d  LBA %d" % ("write" if a & 2 else "read",
                                                         "" if a & 1 else " (none going on)", c, d)
    if t == 4:
        return "IDE0 reset  drive/head %02X" % a
    if t == 5:
        return "floppy %s %s LBA %d" % ("write" if a & 1 else "read", "B:" if d & 0x8000 else "A:",
                                        d & 0x7FFF)
    if t == 6:
        return "SD %s %s LBA %d  ahead %d%s" % (unit[b & 3], "write" if a & 2 else "read", d, c,
                                                "  FAILED" if a & 1 else "")
    if t == 7:
        return "internal drive %s %s C %d H %d R %d: %s" % (
            "write" if a & 1 else "read", "B:" if d & 0x80000000 else "A:", d >> 16 & 0xFF,
            d >> 8 & 1, d & 0x7F, fdd_err(b << 8 | c))
    if t == 8:
        return "IDE1 command %02X  drive/head %02X  features %02X  limit %d" % (a, b, c, d >> 16)
    if t == 9:
        return "IDE1 status %s  error %02X  reason %02X  bytes %d  words %d" % (
            st_text(a), b, c, d >> 16, d & 0xFFFF)
    if t == 10:
        return "IDE1 packet %02X %02X  LBA %d  byte 8 %02X" % (a, b, d, c)
    if t == 11:
        return "IDE1 block done  phase %s  position %d" % (
            ["none", "packet", "data in", "data out"][a & 3], d)
    if t == 12:
        return "IDE1 reset  drive/head %02X" % a
    return "? %X %02X %02X %02X %08X" % (t, a, b, c, d)


# The I/O trace (mega65.vhd p_main_iot): DMA, PIC, 8042 and Sound Blaster accesses
IOT_DMA = ["ch%d address", "ch%d count"] * 4
IOT_DMA_REG = {8: "command", 9: "request", 10: "single mask", 11: "mode", 12: "clear flip-flop",
               13: "master clear", 14: "clear masks", 15: "write masks"}
IOT_PAGE = {0x87: 0, 0x83: 1, 0x81: 2, 0x82: 3, 0x8F: 4, 0x8B: 5, 0x89: 6, 0x8A: 7}
IOT_PORT = {0x20: "PIC1 command", 0x21: "PIC1 mask", 0xA0: "PIC2 command", 0xA1: "PIC2 mask",
            0x60: "8042 data", 0x64: "8042 status/command", 0x224: "mixer index",
            0x225: "mixer data", 0x226: "DSP reset", 0x22A: "DSP read data",
            0x22C: "DSP write", 0x22E: "DSP status (8-bit IRQ ack)", 0x22F: "16-bit IRQ ack",
            0x3F2: "FDC DOR", 0x3F4: "FDC DSR", 0x3F5: "FDC FIFO", 0x3F7: "FDC CCR/DIR"}
# DSP commands: name, parameter bytes
DSP_CMD = {0x10: ("direct 8-bit sample", 1), 0x14: ("8-bit single-cycle DMA", 2),
           0x1C: ("8-bit auto-init DMA", 0), 0x40: ("time constant", 1),
           0x41: ("output rate", 2), 0x42: ("input rate", 2), 0x48: ("block size", 2),
           0x80: ("pause DAC (silence)", 2), 0x90: ("high-speed 8-bit auto-init", 0),
           0x91: ("high-speed 8-bit single", 0), 0xD0: ("pause 8-bit DMA", 0),
           0xD1: ("speaker on", 0), 0xD3: ("speaker off", 0), 0xD4: ("continue 8-bit DMA", 0),
           0xD5: ("pause 16-bit DMA", 0), 0xD6: ("continue 16-bit DMA", 0),
           0xD8: ("speaker status", 0), 0xD9: ("exit 16-bit auto-init", 0),
           0xDA: ("exit 8-bit auto-init", 0), 0xE1: ("version", 0), 0xE0: ("invert", 1),
           0xE2: ("DMA identification", 1), 0xE4: ("write test", 1), 0xE8: ("read test", 0),
           0xF2: ("IRQ 8-bit", 0), 0xF3: ("IRQ 16-bit", 0)}


def iot_port(port, val, wr, dsp):
    """A name for the port, and for the byte where it says more."""
    if port < 0x10 or 0xC0 <= port <= 0xDF:
        hi = port >= 0xC0
        reg = (port - 0xC0) >> 1 if hi else port
        base = 4 if hi else 0
        if reg < 8:
            return "DMA%d %s" % (2 if hi else 1, IOT_DMA[reg] % (base + reg // 2))
        name = "DMA%d %s" % (2 if hi else 1, IOT_DMA_REG[reg])
        if wr and reg == 10:
            name += ": ch%d %s" % (base + (val & 3), "masked" if val & 4 else "unmasked")
        elif wr and reg == 11:
            name += ": ch%d %s%s%s" % (base + (val & 3),
                                      {0: "verify", 1: "write (to memory)", 2: "read (from memory)",
                                       3: "?"}[val >> 2 & 3], ", auto-init" if val & 0x10 else "",
                                      {0: ", demand", 1: ", single", 2: ", block",
                                       3: ", cascade"}[val >> 6])
        elif wr and reg == 15:
            name += ": %s" % ", ".join("ch%d %s" % (base + i, "m" if val >> i & 1 else "u")
                                       for i in range(4))
        elif not wr and reg == 8:
            tc = [base + i for i in range(4) if val >> i & 1]
            rq = [base + i for i in range(4) if val >> (4 + i) & 1]
            name += ": terminal count %s, request %s" % (tc or "-", rq or "-")
        return name
    if port in IOT_PAGE:
        return "DMA page ch%d" % IOT_PAGE[port]
    if port == 0x61:
        if wr:
            return "port 61h: speaker %s, timer 2 gate %s" % ("on" if val & 2 else "off",
                                                              "on" if val & 1 else "off")
        return "port 61h: timer 2 output %d, refresh %d, speaker %s, gate %s" % (
            val >> 5 & 1, val >> 4 & 1, "on" if val & 2 else "off", "on" if val & 1 else "off")
    if 0x40 <= port <= 0x43:
        if port == 0x43 and wr:
            if val >> 6 == 3:
                return "PIT read-back: %s%s, counters %s" % (
                    "" if val & 0x20 else "count ", "" if val & 0x10 else "status",
                    ",".join(str(i) for i in range(3) if val >> (1 + i) & 1))
            if val >> 4 & 3 == 0:
                return "PIT counter %d latched" % (val >> 6)
            return "PIT counter %d: mode %d, %s%s" % (
                val >> 6, (val >> 1) & 7, {1: "LSB", 2: "MSB", 3: "LSB+MSB"}[val >> 4 & 3],
                ", BCD" if val & 1 else "")
        return "PIT counter %d %s" % (port - 0x40, "<-" if wr else "->")
    name = IOT_PORT.get(port, "port %03X" % port)
    if wr and port == 0x22C:
        if dsp["left"]:
            dsp["left"] -= 1
            name += "  (%s parameter)" % dsp["cmd"]
        elif 0xB0 <= val <= 0xCF:
            dsp["cmd"], dsp["left"] = "%d-bit %s %s DMA" % (
                16 if val < 0xC0 else 8, "input" if val & 8 else "output",
                "auto-init" if val & 4 else "single-cycle"), 3
            name += "  %s (mode, length lo, hi follow)" % dsp["cmd"]
        elif val in DSP_CMD:
            dsp["cmd"], dsp["left"] = DSP_CMD[val]
            name += "  " + dsp["cmd"]
    elif wr and port == 0x226:
        dsp["left"] = 0
    elif port in (0x21, 0xA1):
        base = 0 if port == 0x21 else 8
        name += ": " + ("masked %s" % [base + i for i in range(8) if val >> i & 1])
    return name


def iotrace(opts):
    pc_dev()
    if opts[:1] == ["jump"]:
        if len(opts) > 1:
            poke(0x8007, int(opts[1], 0) & 0xFF)
        v = dump(0x8007, 0x8007)[0]
        print("I/O trace: logs sample jumps of %s/256 of the full range or more" %
              ("?" if v is None else v & 0xFF))
        return
    if opts[:1] in (["start"], ["freeze"]):
        freeze, once, quiet = "freeze" in opts, "once" in opts, "quiet" in opts
        timer = "timer" in opts
        poke(0x8004, (1 if freeze else 0) | (2 if once else 0) | (4 if quiet else 0) |
             (8 if timer else 0))
        print("I/O trace started%s%s%s%s" % (
            ", stops at the Sound Blaster's first 1 ms DMA wait" if freeze else "",
            ", stops when full" if once else "",
            ", without DMA polling" if quiet else "",
            ", with the timer and port 61h" if timer else ""))
        return
    if opts[:1] != ["peek"]:
        poke(0x8005, 0)                    # stop it: a running trace changes while it is read
        time.sleep(0.05)
    st = dump(0x8004, 0x8005)
    if None in st:
        print("no answer")
        return
    n, run, full = st[0], st[1] >> 1 & 1, st[1] & 1
    poke(0xFFF5, 0x0003)                   # the trace: device addresses 0x3000.., window 3
    raw = dump(0x8000, 0x8FFF)
    pc_dev()
    first = n % 1024 if full else 0
    count = 1024 if full else n % 1024 if n else 0
    print("I/O trace: %d entries%s, %s" % (n, " (the last 1024 shown)" if full else "",
                                          "running" if run else "stopped"))
    dsp = {"cmd": "", "left": 0}
    t0 = tp = None
    for i in range(count):
        j = (first + i) % 1024
        w = raw[4 * j:4 * j + 4]
        if None in w:
            continue
        t = w[0] << 16 | w[1]
        t0 = t if t0 is None else t0
        dt = 0 if tp is None else (t - tp) & 0xFFFFFFFF
        tp = t
        kind, val, port = w[3] >> 13, w[3] & 0xFF, w[2]
        head = "%10.3f ms %+9d us  " % (((t - t0) & 0xFFFFFFFF) / 1000.0, dt)
        if kind == 0:
            print(head + "W %03X <- %02X  %s" % (port, val, iot_port(port, val, True, dsp)))
        elif kind == 1:
            print(head + "R %03X -> %02X  %s" % (port, val, iot_port(port, val, False, dsp)))
        elif kind == 2:
            print(head + "--- Sound Blaster IRQ")
        elif kind == 3:
            print(head + "--- the %s DMA request waited %d us" %
                  ({1: "8-bit", 2: "16-bit"}.get(val, "?"), port))
        elif kind == 4:
            print(head + "--- the DMA request has waited 1 ms: the card has nothing to play")
        elif kind == 5:
            print(head + "--- the DSP started a new DMA command it held back for %d us" % port)
        elif kind == 6:
            print(head + "--- the DSP has held a new DMA command back for 1 ms")
        elif kind == 7 and w[3] >> 12 & 1:
            print(head + "--- DSP output jump of %3d/256: %s" %
                  (val, ("a DMA sample", "held at 0 (speaker off in SB Pro mode, or 80h)",
                         "a direct output or ADPCM", "?")[w[3] >> 8 & 3]))
        elif kind == 7:
            print(head + "--- sample jump of %3d/256 at sample %d of the block" % (val, port))


def sbsoft(arg):
    pc_dev()
    if arg in ("on", "off"):
        poke(0x800E, 1 if arg == "on" else 0)
    v = dump(0x800E, 0x800E)[0]
    print("Sound Blaster DSP output stage: %s" % ("?" if v is None else "on" if v & 1 else "off"))


def sbfix(arg):
    pc_dev()
    if arg in ("on", "off"):
        poke(0x8006, 1 if arg == "on" else 0)
    v = dump(0x8006, 0x8006)[0]
    print("Sound Blaster stalled-transfer fix: %s" % ("?" if v is None else "on" if v & 1 else "off"))


# the game port's joystick (main_joy_dig, snapshot word 0x001C bits 9..2)
JOY_NAMES = ("right", "left", "down", "up", "fire", "fire 2", "fire 3", "button 4")


def joy_watch(secs):
    # every change of port 2 over secs seconds: fire 2 and 3 are its paddle lines, pin 9 and
    # pin 5 unless the menu says pin 5 for fire 2 (mega65.vhd p_main_joy)
    pc_dev()
    last, t0 = None, time.time()
    while time.time() - t0 < secs:
        v = dump(0x801C, 0x801C)[0]
        if v is None:
            continue
        j = v >> 2 & 0xFF
        if j != last:
            held = [n for i, n in enumerate(JOY_NAMES) if j >> i & 1]
            print("%6.1f s  %s" % (time.time() - t0, ", ".join(held) or "centred, no button"),
                  flush=True)
            last = j


# the MEGA65's keys by M2M's numbers (pc_keyboard.vhd), for kbd_line
KEY_NAMES = {0: "INST/DEL", 1: "RETURN", 2: "cursor right", 3: "F7", 4: "F1", 5: "F3", 6: "F5",
             7: "cursor down", 15: "left Shift", 40: "+", 43: "-", 45: ":", 46: "@", 48: "GBP",
             49: "*", 50: ";", 51: "CLR/HOME", 52: "right Shift", 53: "=", 54: "arrow up",
             57: "arrow left", 58: "CTRL", 60: "SPACE", 61: "MEGA", 63: "RUN/STOP",
             64: "NO SCROLL", 65: "TAB", 66: "ALT", 67: "HELP", 68: "F9", 69: "F11", 70: "F13",
             71: "ESC", 72: "CAPS LOCK", 73: "cursor up", 74: "cursor left", 75: "RESTORE"}


def key_name(n):
    return KEY_NAMES.get(n, "key %d" % n)


def native_mode(w, h, f70):
    # mega65.vhd p_qnice_native: the HDMI mode native picks for an accepted size
    tw = 2 * w if w <= 400 else w
    th = 2 * h if h <= 300 else h
    if w < 256 or h < 160:
        return "640x480 60 Hz, the picture scaled (nothing sensible measured)"
    for cond, name in ((tw <= 640 and th <= 400 and f70, "640x400 70 Hz"),
                       (tw <= 720 and th <= 400 and f70, "720x400 70 Hz"),
                       (tw <= 640 and th <= 480, "640x480 60 Hz"),
                       (tw <= 720 and th <= 480, "720x480 59.94 Hz"),
                       (tw <= 800 and th <= 600, "800x600 60 Hz"),
                       (tw <= 1024 and th <= 768, "1024x768 60 Hz")):
        if cond:
            return "%s, a %dx%d window 1:1" % (name, tw, th)
    return "1280x1024 60 Hz, the picture scaled (larger than 1024x768)"


def native_line():
    # native's measurement (mega65.vhd p_main_native, snapshot words 0x803F..0x803D, 0x803A):
    # the size it accepted (eight frames alike), the last frame's, the framebuffer
    w = dump(0x803A, 0x803A) + dump(0x803D, 0x803F)
    if None in w:
        return "native: ?"
    acc_h, (acc_w16, last_h16, last_w16) = w[0] >> 4, w[1:]
    if (acc_w16 | last_h16 | last_w16) == 0 and acc_h == 0:
        return "native: this core has no readout"
    acc_w, acc_70 = acc_w16 >> 4, acc_w16 >> 3 & 1
    last_h, alike = last_h16 >> 4, last_h16 >> 1 & 7
    last_w, last_70, fb = last_w16 >> 4, last_w16 >> 3 & 1, last_w16 >> 2 & 1
    return ("native: accepted %dx%d%s -> %s; last frame %dx%d%s, %d frames alike%s" %
            (acc_w, acc_h, " (70 Hz)" if acc_70 else "", native_mode(acc_w, acc_h, acc_70),
             last_w, last_h, " (70 Hz)" if last_70 else "", alike,
             "; the SVGA framebuffer is shown (its size counts)" if fb else ""))


def kbd_line():
    # the keyboard translator (pc_keyboard.vhd dbg_o, snapshot words 0x803C:0x803B): the key that
    # holds the PC's Shift back (a key whose release went missing held it for good, 2026-11-07),
    # and the releases its sweep had to send itself
    w = dump(0x803B, 0x803C)
    if None in w:
        return "keyboard: ?"
    lo, hi = w
    if not lo & 0x8000:
        return "keyboard: this core has no translator readout"
    supp = lo & 0x7F
    held = ("Shift held back while %s is down (%s)" %
            (key_name(supp), "the keyboard has it down" if lo & 0x80 else
             "the keyboard has it UP: stuck") if supp != 80 else "no Shift held back")
    shifts = "Shift: keys %s%s, the PC has %s%s" % (
        "L" if lo & 0x100 else "-", "R" if lo & 0x200 else "-",
        "L" if lo & 0x400 else "-", "R" if lo & 0x800 else "-")
    heals = hi & 0xFF
    return ("keyboard: %s; %s%s%s%s; releases the sweep sent: %d%s" %
            (held, shifts, ", MEGA down" if lo & 0x1000 else "",
             "" if lo & 0x2000 else ", scanning off (F5)", ", events waiting" if lo & 0x4000 else "",
             heals, " (the last: %s)" % key_name(hi >> 8 & 0x7F) if heals else ""))


def mouse_line():
    # port 1's mouse (pc_mouse.vhd): Amiga or 1351, and both ports' paddle lines as SID values
    # (the framework hands them over inverted: an open line reads 255 here). POT X is pin 9: a
    # 1351's x, the game port's fire 2 (unless the menu says pin 5)
    w = dump(0x8038, 0x803A)
    f = dump(0x800D, 0x800D)[0]
    if None in w or f is None:
        return "mouse: ?"
    if f == 0xEEEE:                        # nothing there: a core from before the 1351
        return "mouse: this core has no 1351 readout"
    p1x, p1y, p2x, p2y = (255 - (w[0] & 0xFF), 255 - (w[0] >> 8), 255 - (w[1] & 0xFF),
                          255 - (w[1] >> 8))
    flips = [a for a, b in (("x", 1), ("y", 2)) if f & b]
    return ("mouse (port 1): %s; 1351 axes reversed: %s%s\n"
            "paddles (SID values): port 1 POT X (pin 9) %3d (position %2d), POT Y (pin 5) %3d "
            "(position %2d); port 2 POT X %3d, POT Y %3d" %
            ("a 1351 (both buttons)" if w[2] & 1 else "Amiga (F13 = right button)",
             ", ".join(flips) or "none", "; x and y swapped" if f & 4 else "",
             p1x, p1x >> 1 & 63, p1y, p1y >> 1 & 63, p2x, p2y))


def c1351(args):
    # a 1351's axes: normal, flipx, flipy, flipxy reverse them; swap, noswap
    pc_dev()
    flips = {"normal": 0, "flipx": 1, "flipy": 2, "flipxy": 3}
    f = dump(0x800D, 0x800D)[0]
    if f is not None and f != 0xEEEE and args:
        v = f & 7
        for a in args:
            if a in flips:
                v = (v & 4) | flips[a]
            elif a in ("swap", "noswap"):
                v = (v & 3) | (4 if a == "swap" else 0)
        poke(0x800D, v)
    print(mouse_line())


def intahold(arg):
    pc_dev()
    if arg in ("on", "off"):
        poke(0x800C, 1 if arg == "on" else 0)
    v = dump(0x800C, 0x800C)[0]
    print("PIC vector held from the first INTA: %s" % ("?" if v is None else "on" if v & 1 else "off"))


def irqs(mask, base=0):
    return ",".join(str(base + i) for i in range(8) if mask >> i & 1) or "-"


def pic_8042():
    # the second snapshot (mega65.vhd p_main_dbg, 0x0030..37): the PICs, the IRQ lines, the 8042
    w = dump(0x8030, 0x8037)
    if None in w:
        return "PICs: ?"
    m_irr, m_isr, s_irr, s_isr = w[0] & 0xFF, w[0] >> 8, w[1] & 0xFF, w[1] >> 8
    m_imr, s_imr, lines = w[2] & 0xFF, w[2] >> 8, w[3]
    k, f = w[4], w[5]
    out = ["PIC master: IRR %s  ISR %s  masked %s   slave: IRR %s  ISR %s  masked %s" %
           (irqs(m_irr), irqs(m_isr), irqs(m_imr), irqs(s_irr, 8), irqs(s_isr, 8), irqs(s_imr, 8)),
           "IRQ lines up: %s" % (",".join(str(i) for i in range(16) if lines >> i & 1) or "-")]
    buf = "empty" if not k & 4 else "a mouse byte" if k & 8 else "a key"
    out.append("8042: output buffer %s, IRQ1 %d IRQ12 %d; keyboard %s (IRQ %s), mouse %s (IRQ %s); "
               "FIFOs: keyboard %d, mouse %d bytes; line states kbd %d mouse %d" %
               (buf, k & 1, k >> 1 & 1, "off" if k & 16 else "on", "on" if k & 64 else "off",
                "off" if k & 32 else "on", "on" if k & 128 else "off", f & 0x7F, f >> 8 & 0x7F,
                k >> 8 & 15, k >> 12 & 15))
    for irq, pic_irr, pic_isr, bit in ((1, m_irr, m_isr, 1), (12, s_irr, s_isr, 4)):
        if lines >> irq & 1 and not pic_irr >> bit & 1 and not pic_isr >> bit & 1:
            out.append("  IRQ%d is up but neither requested nor in service: its edge is gone" % irq)
    out.append("INTAs the PIC acknowledged with another vector than the CPU took: %d%s" %
               (w[6], "  (the last: CPU %02Xh, PIC %02Xh)" % (w[7] >> 8, w[7] & 0xFF) if w[6] else ""))
    out.append(mouse_line())
    out.append(kbd_line())
    out.append(native_line())
    return "\n".join(out)


def ide(n):
    pc_dev()
    poke(0xFFF5, 0x0002)                   # the IDE trace: device addresses 0x2000.., window 2
    raw = dump(0x8000, 0x8FFF)
    ev = []
    for i in range(512):
        w = raw[8 * i:8 * i + 6]
        if None in w or w[2] >> 12 == 0:
            continue
        ev.append(w)
    if not ev:
        print("no IDE events yet")
        return
    # the ring holds the last 512 sequence numbers: the newest is the one without a successor
    # (the numbers wrap at 65536)
    seqs = {w[0] for w in ev}
    ends = [q for q in seqs if (q + 1) & 0xFFFF not in seqs]
    newest = ends[0] if len(ends) == 1 else max(seqs)
    ev = [w for w in ev if (newest - w[0]) & 0xFFFF < 512]
    ev.sort(key=lambda w: (newest - w[0]) & 0xFFFF, reverse=True)
    t_new = ev[-1][1]
    for w in ev[-n:]:
        t, a = w[2] >> 12, w[2] & 0xFF
        b, c = w[3] >> 8, w[3] & 0xFF
        d = w[4] << 16 | w[5]
        print("%5d  -%6d ms  %s" % (w[0], (t_new - w[1]) & 0xFFFF, ide_event(t, a, b, c, d)))


args = sys.argv[1:]
if args and args[0] == "l2":
    l2(args[1] if len(args) > 1 else "")
elif args and args[0] == "l1" and len(args) > 1 and args[1] in ("on", "off"):
    v = caches_set(2, args[1] == "on")
    print("L1 caches %s, L2 cache %s" % ("on" if v & 2 else "off", "on" if v & 1 else "off"))
elif args[:2] == ["disks", "clear"]:
    disks_clear()
elif args[:2] == ["disks", "watch"]:
    disks_watch(float(args[2]) if len(args) > 2 else 10)
elif args and args[0] == "disks":
    disks()
elif args and args[0] == "fdd":
    fdd()
elif args and args[0] == "xadc":
    xadc()
elif args and args[0] == "bios":
    bios()
elif args and args[0] == "iotrace":
    iotrace(args[1:])
elif args and args[0] == "sbfix":
    sbfix(args[1] if len(args) > 1 else "")
elif args and args[0] == "sbsoft":
    sbsoft(args[1] if len(args) > 1 else "")
elif args and args[0] == "joy":
    joy_watch(float(args[1]) if len(args) > 1 else 30)
elif args and args[0] == "c1351":
    c1351(args[1:])
elif args and args[0] == "intahold":
    intahold(args[1] if len(args) > 1 else "")
elif args and args[0] == "pic":
    pc_dev()
    print(pic_8042())
elif args and args[0] == "cd":
    cd()
elif args and args[0] == "ide":
    ide(int(args[1]) if len(args) > 1 else 40)
elif args and args[0] == "status":
    s = status()
    print(line(s), " vga_chk %d vga_bad %d sdram_busy %d reset %d snap %d" %
          (s["vga_chk"], s["vga_bad"], s["sdram_busy"], s["reset"], s["snap"]))
    if "io_rd" in s:
        print("last I/O read: port %04X -> %02X   last I/O write: port %04X <- %02X" %
              (s["io_rd"] >> 8, s["io_rd"] & 0xFF, s["io_wr"] >> 8, s["io_wr"] & 0xFF))
    if "joy" in s:
        held = [n for i, n in enumerate(JOY_NAMES) if s["joy"] >> i & 1]
        print("joystick (port 2): %s   Sound Blaster DMA request: %s" %
              (", ".join(held) or "centred, no button",
               {0: "none", 1: "8-bit up", 2: "16-bit up", 3: "both up"}[s["sb_req"]]))
    print(pic_8042())
    print(log(s["logs"]))
elif args and args[0] == "boot":
    s = boot(int(args[1], 0), float(args[2]) if len(args) > 2 else 3.0)
    print(line(s))
    print(log(s["logs"]))
elif args and args[0] == "sweep":
    lo, hi, step = int(args[1], 0), int(args[2], 0), int(args[3], 0)
    secs = float(args[4]) if len(args) > 4 else 3.0
    for ph in range(lo, hi + 1, step):
        print(line(boot(ph, secs)), flush=True)
else:
    for c in args:
        sys.stdout.write(cmd(c))
os.close(fd)

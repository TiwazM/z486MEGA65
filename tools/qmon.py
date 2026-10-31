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
#   qmon.py disks clear       zero the disks' statistics
#   qmon.py disks watch [s]   sectors per second over s seconds (default 10)
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
        if kind == 1:
            out += "[POST %02X]" % c
        elif kind == 2:
            out += "[>kbd %02X]" % c          # the 8042 to the keyboard
        elif kind == 3:
            out += "[<kbd %02X]" % c          # the keyboard to the 8042
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


def disks():
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


def l2(arg):
    pc_dev()
    if arg in ("on", "off"):
        poke(0x8003, 1 if arg == "on" else 0)
        time.sleep(0.1)
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
elif args[:2] == ["disks", "clear"]:
    disks_clear()
elif args[:2] == ["disks", "watch"]:
    disks_watch(float(args[2]) if len(args) > 2 else 10)
elif args and args[0] == "disks":
    disks()
elif args and args[0] == "ide":
    ide(int(args[1]) if len(args) > 1 else 40)
elif args and args[0] == "status":
    s = status()
    print(line(s), " vga_chk %d vga_bad %d sdram_busy %d reset %d snap %d" %
          (s["vga_chk"], s["vga_bad"], s["sdram_busy"], s["reset"], s["snap"]))
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

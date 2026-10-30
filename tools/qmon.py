#!/usr/bin/env python3
# Drives the QNICE monitor (M2M debug mode: hold Run/Stop + Cursor Up, then press Help) over the
# MEGA65 JTAG adapter's UART, 115200 8N1, and reads z486's debug registers (C_DEV_PC_CTL,
# CORE/vhdl/mega65.vhd). QMON_PORT overrides the serial port.
#
#   qmon.py CMD...            each CMD is one monitor command typed as is, e.g. "MCFFF40100",
#                             "MD80008007", "ME8000"; the replies are printed
#   qmon.py status            z486's debug snapshot (C_DEV_PC_CTL 0x10..0x17) and the log
#   qmon.py boot PHASE [SECS] reset the PC with the SDRAM clock at PHASE fine steps (13.95 ps)
#                             from 292.5 degrees, wait SECS (default 3), print the status
#   qmon.py sweep FROM TO STEP [SECS]   boot at each phase, one summary line each
#   qmon.py fdd               floppy A: (fdd_sd.vhd, C_DEV_PC_FDD): mount registers, statistics
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


def cmd(c):
    for ch in c.encode():
        os.write(fd, bytes([ch]))
        time.sleep(0.004)
    return read_for(5.0)


def poke(addr, val):
    cmd("MC%04X%04X" % (addr, val & 0xFFFF))


def dump(start, end):
    out = cmd("MD%04X%04X" % (start, end))
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


def fdd():
    poke(0xFFF4, 0x0101)                   # M2M$RAMROM_DEV = C_DEV_PC_FDD
    poke(0xFFF5, 0x0000)
    r = dump(0x8000, 0x8008)
    st = dump(0x8010, 0x8013)
    print("A: mode %d (%s%s%s)  sectors %d  base %d  shift %d  geometry %d/%d/%d" %
          (r[0], "mounted" if r[0] & 1 else "empty", ", slot 1" if r[0] & 2 else "",
           ", write protected" if r[0] & 4 else "", r[2] << 16 | r[1], r[4] << 16 | r[3], r[5],
           r[6], r[8], r[7]))
    print("   read %d  written %d  failed %d  last request: %s LBA %d" %
          (st[0], st[1], st[2], "write" if st[3] & 0x8000 else "read", st[3] & 0x7FFF))


os.write(fd, b"\r")
read_for(1.0)
args = sys.argv[1:]
if args and args[0] == "fdd":
    fdd()
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

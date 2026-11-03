#!/usr/bin/env python3
"""z486 for MEGA65: bios_patch.asm's test (bios_run.sh).

  bios_test.py gen <outdir>              <outdir>/sd.img (MBR + FAT32 by mtools) with
                                          /Z486/BOOT0.ROM (z486_MiSTer's), OTHER.ROM (one byte
                                          changed), SHORT.ROM (its first 32 KB), LONG.ROM (two
                                          bytes more)
  bios_test.py check <outdir> <emu.log>  BOOT0.ROM: the writes make tools/bios_patch.py's
                                          image; the others: no writes
"""
import os
import struct
import subprocess
import sys

H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(H, "..", "..", "..", "tools")))
import bios_patch  # noqa: E402

PART_LBA = 2048


def files():
    rom = open(bios_patch.ROM, "rb").read()
    other = bytearray(rom)
    other[0x1234] ^= 0x01
    return {"BOOT0.ROM": rom, "OTHER.ROM": bytes(other), "SHORT.ROM": rom[:0x8000],
            "LONG.ROM": rom + b"\x12\x34"}


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def gen(out):
    os.makedirs(out, exist_ok=True)
    img = os.path.join(out, "sd.img")
    total = 80 * 1024 * 1024
    with open(img, "wb") as f:
        f.truncate(total)
        mbr = bytearray(512)
        sectors = total // 512 - PART_LBA
        mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0C, b"\0\0\0", PART_LBA, sectors)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
    mi = "%s@@%d" % (img, PART_LBA * 512)
    run("mformat", "-i", mi, "-F", "-c", "1", "-T", str(sectors), "-h", "64", "-s", "32",
        "-H", str(PART_LBA), "::")
    run("mmd", "-i", mi, "::Z486")
    for name, data in files().items():
        p = os.path.join(out, name)
        open(p, "wb").write(data)
        run("mcopy", "-o", "-i", mi, p, "::Z486/" + name)


def parse(log):
    cases, cur = {}, None
    for line in open(log, errors="replace"):
        f = line.split()
        if not f:
            continue
        if f[0] == "CASE":
            cur = cases.setdefault(f[1].split("/")[-1], {"P": []})
        elif cur is not None and f[0] == "P":
            cur["P"].append(tuple(int(x, 16) for x in f[1:4]))
        elif cur is not None and f[0] in ("S", "R"):
            cur[f[0]] = tuple(int(x, 16) for x in f[1:])
        elif f[0] in ("OPEN", "MOUNT") and cur is not None:
            cur["err"] = line.strip()
    return cases


def check(log):
    cases, fs, ok = parse(log), files(), True
    for name, data in fs.items():
        c = cases.get(name)
        if c is None or "err" in c or "S" not in c or "R" not in c:
            print("%s: no result (%s)" % (name, c and c.get("err")))
            ok = False
            continue
        s1 = s2 = 0
        for (w,) in struct.iter_unpack("<H", data + b"\0" * (len(data) & 1)):
            s1 = (s1 + w) & 0xFFFF
            s2 = (s2 + s1) & 0xFFFF
        good = c["S"] == (s1, s2) and c["R"][1:] == (0x5A5A, 0xA5A5)
        if name == "BOOT0.ROM":
            img = bytearray(data)
            for win, off, w in c["P"]:
                a = ((win - bios_patch.PC_BIOS_WIN) << 13) + 2 * off
                img[a:a + 2] = struct.pack("<H", w)
            good = good and c["R"][0] == 1 and bytes(img) == bios_patch.patched(data)
        else:
            good = good and c["R"][0] == 0 and not c["P"]
        print("%-10s %s  (%d writes, result %d, sums %04X %04X)" % (
            name, "ok" if good else "FAIL", len(c["P"]), c["R"][0], c["S"][0], c["S"][1]))
        ok = ok and good
    return 0 if ok else 1


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(sys.argv[2])
    else:
        sys.exit(check(sys.argv[3]))

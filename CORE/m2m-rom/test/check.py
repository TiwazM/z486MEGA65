#!/usr/bin/env python3
"""z486 for MEGA65: compares the emulator's output of cdimage.asm's test with
gen.py's expected.json, and reads the virtual image through the extent map it
printed from sd.img: every file must be at its place.

usage: check.py <outdir> <emulator log>
"""
import json, struct, sys

PART_LBA = 2048


def words(line):
    return [int(x, 16) for x in line.split()[1:]]


def main():
    out, logf = sys.argv[1], sys.argv[2]
    exp = json.load(open(out + "/expected.json"))
    cb = exp["cb"]
    log = [l.strip() for l in open(logf, errors="replace") if l.strip()]
    img = open(out + "/sd.img", "rb")
    img.seek(PART_LBA * 512)
    bs = img.read(512)
    bps, spc = struct.unpack_from("<HB", bs, 11)
    rsvd = struct.unpack_from("<H", bs, 14)[0]
    nfats = bs[16]
    fatsz = struct.unpack_from("<I", bs, 36)[0]
    data_off = (PART_LBA + rsvd + nfats * fatsz) * bps

    # the log, case by case
    blocks, cur = [], None
    for l in log:
        if l.startswith("CASE "):
            cur = [l]
            blocks.append(cur)
        elif l == "END":
            cur = None
        elif cur is not None:
            cur.append(l)
    fails = 0
    if len(blocks) != len(exp["cases"]) or "END" not in log:
        print("FAIL: %d cases in the log, %d expected, last line %r" %
              (len(blocks), len(exp["cases"]), log[-1] if log else None))
        fails += 1
    for e, b in zip(exp["cases"], blocks):
        name = "%s/%s" % (e["dir"], e["file"])
        bad = []
        r = [l for l in b if l.startswith("R ")]
        if not r:
            bad.append("no result: %s" % b[1:])
        else:
            code, slo, shi, r11, r12 = words(r[0])
            if code != e["code"]:
                bad.append("code %04X, expected %04X" % (code, e["code"]))
            if (r11, r12) != (0x5A5A, 0xA5A5):
                bad.append("R11/R12 not kept: %04X %04X" % (r11, r12))
            if code == 0 and e["code"] == 0:
                if slo | shi << 16 != e["sects"]:
                    bad.append("SECTS %d, expected %d" % (slo | shi << 16, e["sects"]))
                get = lambda p: [words(l) for l in b if l.startswith(p + " ")]
                h = get("H")[0]
                if h != e["header"]:
                    bad.append("header %s, expected %s" % (h, e["header"]))
                for k, (a, x) in enumerate(zip(get("E"), e["entries"])):
                    if a != x:
                        bad.append("track %d: %s, expected %s" % (k + 1, a, x))
                if len(get("E")) != len(e["entries"]):
                    bad.append("%d tracks, expected %d" % (len(get("E")), len(e["entries"])))
                if get("L") != e["lba"]:
                    bad.append("TOC LBA %s, expected %s" % (get("L"), e["lba"]))
                if get("M") != e["msf"]:
                    bad.append("TOC MSF %s, expected %s" % (get("M"), e["msf"]))
                # the virtual image through the map
                ext = get("X")
                n = words([l for l in b if l.startswith("XN ")][0])[0]
                if n != len(ext):
                    bad.append("map count %d, %d extents printed" % (n, len(ext)))
                virt = bytearray()
                for f0, f1, n0, n1 in ext:
                    first, count = f0 | f1 << 16, n0 | n1 << 16
                    img.seek(data_off + (first - 2) * cb)
                    virt += img.read(count * cb)
                for fname, vbase in e["vfiles"]:
                    want = bytes.fromhex(e["data"][fname])
                    got = bytes(virt[vbase:vbase + len(want)])
                    if got != want:
                        bad.append("%s not at virtual byte %d (map)" % (fname, vbase))
        if bad:
            fails += 1
            print("FAIL %s:\n  %s" % (name, "\n  ".join(bad)))
        else:
            extra = ""
            if e["code"] == 0:
                extra = " (%d tracks, %d extents)" % (len(e["entries"]),
                                                       len([l for l in b if l.startswith("X ")]))
            print("ok   %s%s" % (name, extra))
    print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL"))
    sys.exit(1 if fails else 0)


main()

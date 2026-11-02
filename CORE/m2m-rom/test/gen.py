#!/usr/bin/env python3
"""z486 for MEGA65: the SD image and the expected results for cdimage.asm's
emulator test (run.sh).

usage: gen.py <outdir> <sectors per cluster>

Writes <outdir>/sd.img (MBR + FAT32 by mtools), <outdir>/cases.inc (the
harness's list of folders and files) and <outdir>/expected.json: per case
the expected CD_PREP code and, for a disc, the track table (header, entries,
READ TOC descriptors), SECTS and the files in virtual-image order (to check
the extent map against the image). The layout here is written independently
of cdimage.asm, from the cue sheet rules: LBA 0 = track 1's INDEX 01; INDEX
00..01 is file data; PREGAP / POSTGAP are in no file and move later tracks;
track 1's INDEX 00 and PREGAP are dropped.
"""
import json, os, re, struct, subprocess, sys

PART_LBA = 2048
OK, E_SIZE, E_FRAG, E_CUE, E_FILE, E_FAT, E_LONG, E_WAVE, E_TYPE = (
    0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8)


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def pattern(seed, n):
    """n bytes, different for every file and position"""
    out = bytearray(n)
    x = (seed * 2654435761) & 0xFFFFFFFF
    for i in range(n):
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF
        out[i] = (x >> 16) & 0xFF
    return bytes(out)


def raw_data_sectors(seed, n, mode):
    """n raw 2352-byte sectors: sync, header (mode at byte 15), data"""
    out = bytearray()
    body = pattern(seed, n * 2352)
    for i in range(n):
        s = bytearray(body[i * 2352:(i + 1) * 2352])
        s[0:12] = b"\x00" + b"\xff" * 10 + b"\x00"
        s[15] = mode
        out += s
    return bytes(out)


def wav(seed, frames, extra_chunk=True, channels=2, rate=44100, bits=16, tail=0):
    data = pattern(seed, frames * 2352 + tail)
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * channels * bits // 8,
                      channels * bits // 8, bits)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    if extra_chunk:
        lst = b"INFOISFT\x05\x00\x00\x00test\x00"          # odd length: a pad byte
        chunks += b"LIST" + struct.pack("<I", len(lst)) + lst + b"\x00"
    body = b"WAVE" + chunks + b"data" + struct.pack("<I", len(data)) + data
    off = 12 + len(chunks) + 8
    return b"RIFF" + struct.pack("<I", len(body)) + body, off, len(data)


def fsinfo_rewind(img):
    """FSInfo's next free cluster hint back to 2: mtools then fills the holes"""
    with open(img, "r+b") as f:
        f.seek(PART_LBA * 512)
        bs = f.read(512)
        fsi = struct.unpack_from("<H", bs, 48)[0]
        f.seek((PART_LBA + fsi) * 512 + 492)
        f.write(struct.pack("<I", 2))


def msf(f):
    return "%02d:%02d:%02d" % (f // 4500, f // 75 % 60, f % 75)


# ----------------------------------------------------------------------------
# the cases: folder, the file to mount, the files of the folder, the expected
# code, and for a disc its tracks: (file, mode, idx0 or None, idx1, pregap,
# postgap, big-endian)
# ----------------------------------------------------------------------------

def cases():
    cs = []

    iso = pattern(1, 10 * 2048)
    cs.append(dict(dir="/ISO", file="game.iso", files={"game.iso": iso}, code=OK,
                   single=("game.iso", "MODE1/2048")))

    raw = raw_data_sectors(2, 5, 1)
    cs.append(dict(dir="/RAW", file="game.bin", files={"game.bin": raw}, code=OK,
                   single=("game.bin", "MODE1/2352")))

    raw2 = raw_data_sectors(3, 3, 2)
    cs.append(dict(dir="/RAW2", file="mode2.bin", files={"mode2.bin": raw2}, code=OK,
                   single=("mode2.bin", "MODE2/2352")))

    # three files, long names, CRLF, REM; track 2 fragmented (frag=True)
    t1, t2, t3 = "Game (Track 1).bin", "Game (Track 2).bin", "Game (Track 3).bin"
    cue = ("REM GENRE Game\r\nREM COMMENT \"x\"\r\n"
           'FILE "%s" BINARY\r\n  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\n'
           'FILE "%s" BINARY\r\n  TRACK 02 AUDIO\r\n    FLAGS DCP\r\n'
           "    INDEX 00 00:00:00\r\n    INDEX 01 00:00:02\r\n"
           'FILE "%s" BINARY\r\n  TRACK 03 AUDIO\r\n    PREGAP 00:00:03\r\n'
           "    INDEX 01 00:00:00\r\n    POSTGAP 00:00:01\r\n") % (t1, t2, t3)
    cs.append(dict(dir="/MULTI", file="game.cue", frag=t2,
                   files={"game.cue": cue.encode(), t1: raw_data_sectors(4, 4, 1),
                          t2: pattern(5, 6 * 2352), t3: pattern(6, 5 * 2352)},
                   code=OK, tracks=[(t1, "MODE1/2352", None, 0, 0, 0, False),
                                    (t2, "AUDIO", 0, 2, 0, 0, False),
                                    (t3, "AUDIO", None, 0, 3, 1, False)]))

    # one file, three tracks; BOM, lower case, a bare name, tabs, LF only;
    # track 1's INDEX 00 (dropped), track 3 with INDEX 00
    cue = ("﻿rem single\n"
           "file single.bin binary\n"
           "\ttrack 1 mode1/2352\n\t\tindex 00 00:00:00\n\t\tindex 01 00:00:00\n"
           "\ttrack 2 audio\n\t\tindex 01 00:00:04\n"
           "\ttrack 3 audio\n\t\tindex 00 00:00:09\n\t\tindex 01 00:00:11\n")
    cs.append(dict(dir="/SINGLE", file="Single.cue",
                   files={"Single.cue": cue.encode("utf-8"),
                          "single.bin": raw_data_sectors(7, 4, 1) + pattern(8, 12 * 2352)},
                   code=OK, tracks=[("single.bin", "MODE1/2352", 0, 0, 0, 0, False),
                                    ("single.bin", "AUDIO", None, 4, 0, 0, False),
                                    ("single.bin", "AUDIO", 9, 11, 0, 0, False)]))

    # the longest cue (16K characters, both scratch windows full): REM lines,
    # then three files, the first fragmented, whose FILE lines are the text's
    # last words
    t1, t2, t3 = "Long (Track 1).bin", "Long (Track 2).bin", "Long (Track 3).bin"
    tail = ('FILE "%s" BINARY\r\n  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\n'
            'FILE "%s" BINARY\r\n  TRACK 02 AUDIO\r\n    INDEX 01 00:00:00\r\n'
            'FILE "%s" BINARY\r\n  TRACK 03 AUDIO\r\n    INDEX 01 00:00:00\r\n') % (t1, t2, t3)
    pad = 16384 - len(tail)
    rem = "".join("REM COMMENT %s\r\n" % ("%04d" % i * 12) for i in range(pad // 64))
    rem += "REM " + "x" * (pad - len(rem) - 6) + "\r\n"
    cue = rem + tail
    assert len(cue) == 16384
    files = {t1: raw_data_sectors(16, 4, 1), t2: pattern(17, 6 * 2352), t3: pattern(18, 5 * 2352)}
    trk = [(t1, "MODE1/2352", None, 0, 0, 0, False), (t2, "AUDIO", None, 0, 0, 0, False),
           (t3, "AUDIO", None, 0, 0, 0, False)]
    cs.append(dict(dir="/LONG", file="long.cue", frag=t1,
                   files=dict(files, **{"long.cue": cue.encode()}), code=OK, tracks=trk))
    # one character more: too long
    cs.append(dict(dir="/ERR8", file="long.cue",
                   files=dict(files, **{"long.cue": ("REM " + cue).encode()[:16385]}),
                   code=E_LONG))

    # an ISO data track and a WAVE audio track (a LIST chunk before the data,
    # a partial sector at its end)
    w, woff, wlen = wav(9, 4, tail=1000)
    cue = ('FILE "data.iso" BINARY\n TRACK 01 MODE1/2048\n  INDEX 01 00:00:00\n'
           'FILE "music.wav" WAVE\n TRACK 02 AUDIO\n  INDEX 00 00:00:00\n  INDEX 01 00:00:01\n')
    cs.append(dict(dir="/WAVE", file="wave.cue",
                   files={"wave.cue": cue.encode(), "data.iso": pattern(10, 3 * 2048),
                          "music.wav": w},
                   wave={"music.wav": (woff, wlen)},
                   code=OK, tracks=[("data.iso", "MODE1/2048", None, 0, 0, 0, False),
                                    ("music.wav", "AUDIO", 0, 1, 0, 0, False)]))

    # big-endian audio
    cue = 'FILE "moto.bin" MOTOROLA\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n'
    cs.append(dict(dir="/MOTO", file="moto.cue",
                   files={"moto.cue": cue.encode(), "moto.bin": pattern(11, 3 * 2352)},
                   code=OK, tracks=[("moto.bin", "AUDIO", None, 0, 0, 0, True)]))

    # errors
    cs.append(dict(dir="/ERR1", file="missing.cue",
                   files={"missing.cue": b'FILE "gone.bin" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n'},
                   code=E_FILE))
    cs.append(dict(dir="/ERR2", file="mp3.cue",
                   files={"mp3.cue": b'FILE "a.mp3" MP3\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n',
                          "a.mp3": b"ID3"}, code=E_TYPE))
    mono, _, _ = wav(12, 2, extra_chunk=False, channels=1)
    cs.append(dict(dir="/ERR3", file="mono.cue",
                   files={"mono.cue": b'FILE "m.wav" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n',
                          "m.wav": mono}, code=E_WAVE))
    cs.append(dict(dir="/ERR4", file="bad.bin",
                   files={"bad.bin": raw_data_sectors(13, 2, 1) + b"\x00" * 100}, code=E_SIZE))
    cs.append(dict(dir="/ERR5", file="notrack.cue",
                   files={"notrack.cue": b'FILE "x.bin" BINARY\n', "x.bin": pattern(14, 2352)},
                   code=E_CUE))
    cs.append(dict(dir="/ERR6", file="noidx.cue",
                   files={"noidx.cue": b'FILE "x.bin" BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:00\n',
                          "x.bin": pattern(15, 2352)}, code=E_CUE))
    cs.append(dict(dir="/ERR7", file="badiso.iso", files={"badiso.iso": b"\x00" * 3000},
                   code=E_SIZE))
    return cs


# ----------------------------------------------------------------------------
# the reference layout
# ----------------------------------------------------------------------------

MODES = {"AUDIO": (2352, 0, 0x10), "MODE1/2048": (2048, 0, 0x14),
         "MODE1/2352": (2352, 16, 0x14), "MODE2/2352": (2352, 24, 0x14),
         "MODE2/2336": (2336, 8, 0x14)}


def swap(x):
    return ((x & 0xFF) << 8) | (x >> 8)


def tomsf(lba):
    v = lba + 150
    return v // 4500, v // 75 % 60, v % 75


def layout(c, cb):
    """-> dict(header, entries, lba, msf, sects, vfiles)"""
    if "single" in c:
        name, mode = c["single"]
        tracks = [(name, mode, None, 0, 0, 0, False)]
        if mode == "MODE2/2352":
            pass
    else:
        tracks = c["tracks"]
    wave = c.get("wave", {})
    # the files in FILE order, their virtual bases
    order = []
    for t in tracks:
        if t[0] not in order:
            order.append(t[0])
    vclus, vfiles, fbase, fsect = 0, [], {}, {}
    for name in order:
        size = len(c["files"][name])
        woff, dlen = wave.get(name, (0, size))
        ssize = MODES[next(t[1] for t in tracks if t[0] == name)][0]
        fbase[name] = vclus * cb + woff
        fsect[name] = dlen // ssize
        vfiles.append((name, vclus * cb))
        vclus += (size + cb - 1) // cb
    # frames
    fstart, acc = {}, 0
    for name in order:
        fstart[name] = acc
        acc += fsect[name]
    S, org, rows = 0, None, []
    for k, (name, mode, i0, i1, pre, post, be) in enumerate(tracks):
        ssize, off, ctl = MODES[mode]
        P = pre if k else 0
        fbf = i1 if (k == 0 or i0 is None) else i0
        base = fstart[name] + S + P
        start = fstart[name] + S + fbf
        fb = start + P
        idx1 = base + i1
        nxt = tracks[k + 1] if k + 1 < len(tracks) else None
        if nxt and nxt[0] == name:
            fe_file = nxt[3] if nxt[2] is None else nxt[2]
        else:
            fe_file = fsect[name]
        fe = max(base + fe_file, fb)
        end = fe + post
        byte = fbase[name] + fbf * ssize
        if k == 0:
            org = idx1
        flags = (1 if mode == "AUDIO" else 0) | (2 if be else 0)
        rows.append(dict(num=k + 1, ctl=ctl, ssize=ssize, off=off, flags=flags,
                         v=[start - org, idx1 - org, fb - org, fe - org, end - org], byte=byte))
        S += P + post
    ents, lbad, msfd = [], [], []
    for r in rows:
        w = [r["num"] | r["ctl"] << 8, r["ssize"], r["off"], r["flags"]]
        for x in r["v"] + [r["byte"]]:
            w += [x & 0xFFFF, x >> 16]
        ents.append(w)
    def desc(num, ctl, lba):
        m, s, f = tomsf(lba)
        return ([ctl << 8, num, swap(lba >> 16), swap(lba & 0xFFFF)],
                [ctl << 8, num, m << 8, s | f << 8])
    for r in rows:
        a, b = desc(r["num"], r["ctl"], r["v"][1])
        lbad.append(a)
        msfd.append(b)
    lead = rows[-1]["v"][4]
    a, b = desc(0xAA, rows[-1]["ctl"], lead)
    lbad.append(a)
    msfd.append(b)
    media = 0
    for r in rows:
        media |= 2 if r["flags"] & 1 else 1
    m, s, f = tomsf(lead)
    header = [len(rows), rows[0]["num"] | rows[-1]["num"] << 8, lead & 0xFFFF, lead >> 16,
              media, m | s << 8, f]
    return dict(header=header, entries=ents, lba=lbad, msf=msfd,
                sects=vclus * (cb // 512), vfiles=vfiles)


# ----------------------------------------------------------------------------

def main():
    out, spc = sys.argv[1], int(sys.argv[2])
    cb = spc * 512
    os.makedirs(out, exist_ok=True)
    img = os.path.join(out, "sd.img")
    total = (80 if spc == 1 else 300) * 1024 * 1024
    with open(img, "wb") as f:
        f.truncate(total)
        mbr = bytearray(512)
        sectors = total // 512 - PART_LBA
        mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\0\0\0", 0x0C, b"\0\0\0", PART_LBA, sectors)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
    mi = "%s@@%d" % (img, PART_LBA * 512)
    run("mformat", "-i", mi, "-F", "-c", str(spc), "-T", str(sectors), "-h", "64", "-s", "32",
        "-H", str(PART_LBA), "::")
    tmp = os.path.join(out, "files")
    os.makedirs(tmp, exist_ok=True)
    cs = cases()
    exp = []
    for n, c in enumerate(cs):
        run("mmd", "-i", mi, "::" + c["dir"])
        for name, data in c["files"].items():
            if name == c.get("frag"):
                # fragmented: small files first, every other one deleted
                for i in range(12):
                    p = os.path.join(tmp, "g%d" % i)
                    open(p, "wb").write(b"g" * cb)
                    run("mcopy", "-o", "-i", mi, p, "::%s/G%d.TMP" % (c["dir"], i))
                for i in range(0, 12, 2):
                    run("mdel", "-i", mi, "::%s/G%d.TMP" % (c["dir"], i))
                fsinfo_rewind(img)
            p = os.path.join(tmp, "f")
            open(p, "wb").write(data)
            run("mcopy", "-o", "-i", mi, p, "::%s/%s" % (c["dir"], name))
        e = dict(dir=c["dir"], file=c["file"], code=c["code"])
        if c["code"] == OK:
            e.update(layout(c, cb))
            e["data"] = {name: data.hex() for name, data in c["files"].items()
                         if name in dict(e["vfiles"])}
        exp.append(e)
    with open(os.path.join(out, "expected.json"), "w") as f:
        json.dump(dict(cb=cb, cases=exp), f)
    with open(os.path.join(out, "cases.inc"), "w") as f:
        f.write("T_CASES")
        for n, c in enumerate(cs):
            f.write("         .DW     T_D%d, T_F%d\n" % (n, n))
        f.write("                .DW     0\n")
        for n, c in enumerate(cs):
            f.write('T_D%d .ASCII_W "%s"\nT_F%d .ASCII_W "%s"\n' % (n, c["dir"], n, c["file"]))


main()

# crt_post_png.py NAME W H [--cmp]: NAME_in.txt / NAME_out.txt ("r g b" a pixel) -> NAME_out.png, NAME_zoom.png
# (a 240x135 crop of the output around the text, 4x nearest) and, with --cmp, checks out == in
import sys, zlib, struct
name, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def load(fn):
    px = [tuple(int(v) for v in l.split()) for l in open(fn) if l.strip()]
    assert len(px) == w * h, (fn, len(px), w * h)
    return px
def png(fn, px, pw, ph):
    raw = b"".join(b"\0" + bytes(c for p in px[y * pw:(y + 1) * pw] for c in p) for y in range(ph))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(fn, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", pw, ph, 8, 2, 0, 0, 0))
                         + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
out = load(name + "_out.txt")
if "--cmp" in sys.argv:
    inp = load(name + "_in.txt")
    bad = sum(1 for a, b in zip(inp, out) if a != b)
    print(name, "differs from the input in", bad, "pixels")
png(name + "_out.png", out, w, h)
x0, y0, cw, ch, z = int(w * 0.02), int(h * 0.30), 240, 135, 4
crop = []
for y in range(ch * z):
    for x in range(cw * z):
        crop.append(out[(y0 + y // z) * w + x0 + x // z])
png(name + "_zoom.png", crop, cw * z, ch * z)
print("wrote", name + "_out.png", name + "_zoom.png")

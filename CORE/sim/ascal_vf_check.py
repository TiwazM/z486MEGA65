# ascal_vf_check.py FILE FIRST LAST: per output line "y frac pixel" (tb_ascal G_PAT 2, bilinear): the
# pixel must be 255 x (1 - f) after a white input line or 255 x f after a black one, and the
# lines must alternate as the position wraps
import sys
rows = [tuple(int(v) for v in l.split()) for l in open(sys.argv[1]) if l.strip()]
first, last = int(sys.argv[2]), int(sys.argv[3])
bad = 0; n = 0; prev_f = None; colour = None; flips = 0
for y, fr, px in rows:
    if y < first or y > last:
        continue
    f = fr / 4096.0
    a, b = 255 * (1 - f), 255 * f           # after white, after black
    ew, eb = abs(px - a), abs(px - b)
    c = "w" if ew <= eb else "b"
    if min(ew, eb) > 6:
        bad += 1
        if bad <= 5: print("line", y, "frac", fr, "pixel", px, "expected", round(a), "or", round(b))
    if prev_f is not None and fr < prev_f and c == colour:
        flips += 1                           # the position wrapped but the colour did not change
    if prev_f is not None and fr >= prev_f and c != colour:
        flips += 1                           # the colour changed but the position did not wrap
    prev_f, colour = fr, c; n += 1
print("%d lines, %d off by more than 6, %d out of step" % (n, bad, flips))

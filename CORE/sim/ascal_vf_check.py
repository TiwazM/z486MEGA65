# ascal_vf_check.py FILE FIRST LAST: per output line "y frac pixel" (tb_ascal G_PAT 2, bilinear): the
# pixel must be 255 x (1 - f) after a white input line or 255 x f after a black one, and the
# lines must alternate as the position wraps
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
# a 4th column (o_vline_odd, '0'/'1'): it must be the upper input line's parity
odd_bad = 0
rows4 = []
for r in rows:
    y, fr, px = int(r[0]), int(r[1]), int(r[2])
    rows4.append((y, fr, px, r[3].strip("'") if len(r) > 3 else None))
rows = rows4
first, last = int(sys.argv[2]), int(sys.argv[3])
bad = 0; n = 0; prev_f = None; colour = None; flips = 0
for y, fr, px, odd in rows:
    if y < first or y > last:
        continue
    f = fr / 4096.0
    a, b = 255 * (1 - f), 255 * f           # after white, after black
    ew, eb = abs(px - a), abs(px - b)
    c = "w" if ew <= eb else "b"
    if odd is not None and odd != ("0" if c == "w" else "1"):
        odd_bad += 1                         # white lines are the even ones
    if min(ew, eb) > 6:
        bad += 1
        if bad <= 5: print("line", y, "frac", fr, "pixel", px, "expected", round(a), "or", round(b))
    if prev_f is not None and fr < prev_f and c == colour:
        flips += 1                           # the position wrapped but the colour did not change
    if prev_f is not None and fr >= prev_f and c != colour:
        flips += 1                           # the colour changed but the position did not wrap
    prev_f, colour = fr, c; n += 1
print("%d lines, %d off by more than 6, %d out of step, %d with the wrong pair bit" % (n, bad, flips, odd_bad))

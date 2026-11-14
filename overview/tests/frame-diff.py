#!/usr/bin/env python3
"""Whether two sets of frames from the overlay suite differ by more than noise.

    TEST_OUT=<before> tests/run.sh overlay    # on the old code
    TEST_OUT=<after> tests/run.sh overlay     # on the new
    tests/frame-diff.py <before> <after>

Every PNG in <before> is compared to its namesake. No window content here: nothing
is captured off a real compositor, so this says nothing about ScreencopyView.
"""
import os, struct, sys, zlib


def load(path):
    data = open(path, "rb").read()
    pos, idat = 8, b""
    while pos < len(data):
        n, t = struct.unpack(">I4s", data[pos:pos + 8])
        c = data[pos + 8:pos + 8 + n]
        if t == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", c[:10])
        if t == b"IDAT":
            idat += c
        pos += 12 + n
    bpp = {2: 3, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    p = 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + (a + prev[i]) // 2) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


a, b = sys.argv[1:3]
bad = 0
for f in sorted(os.listdir(a)):
    w, h, bpp, x = load(os.path.join(a, f))
    w2, h2, bpp2, y = load(os.path.join(b, f))
    n = big = mx = 0
    x0, y0, x1, y1 = w, h, -1, -1
    for j in range(min(h, h2)):
        if x[j] == y[j]:
            continue
        for i in range(w):
            d = max(abs(x[j][i * bpp + k] - y[j][i * bpp + k]) for k in range(bpp))
            if d:
                n += 1
                big += d > 8
                mx = max(mx, d)
                x0, x1, y0, y1 = min(x0, i), max(x1, i), min(y0, j), max(y1, j)
    # Two runs of the same code differ by a dozen pixels, by a level or two.
    bad += big > 0 or n > 50
    print(f"{f}: {w}x{h} differing={n} over8={big} max={mx} bbox=({x0},{y0})-({x1},{y1})")
sys.exit(1 if bad else 0)

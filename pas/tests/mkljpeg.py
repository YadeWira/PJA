#!/usr/bin/env python3
# Lossless JPEGs (SOF3) of kinds no common encoder writes, for tests/jpg.
# usage: mkljpeg.py out.jpg kind seed
#   wrap      16 bits, predictor 6, as an encoder that halves Ra - Rc
#             wrapped to 16 bits writes it (pjajpeg TScan.wrapPred):
#             signed samples around 0, two's complement, where H.1.2.1's
#             predictor and that encoder's part ways (a DICOM file has it)
#   sub       8 bits, three components sampled 2x2, 1x1 and 1x2, one
#             interleaved scan (MCUs of 7 samples, past the image's edge
#             too), predictor 4, a restart every 2 rows of MCUs
#   subscans  the same image, a scan per component (each over its own
#             size), predictors 1, 7 and 5
import sys, math, random, struct
out, kind, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
rnd = random.Random(seed)

def wrap16(d):
    d &= 0xFFFF
    return d - 0x10000 if d >= 0x8000 else d

def predict(img, w, x, y, y0, psv, prec, wrap):
    if y == y0:
        return 1 << (prec - 1) if x == 0 else img[y][x - 1]
    if x == 0:
        return img[y - 1][0]
    ra, rb, rc = img[y][x - 1], img[y - 1][x], img[y - 1][x - 1]
    if psv == 1: return ra
    if psv == 2: return rb
    if psv == 3: return rc
    if psv == 4: return ra + rb - rc
    if psv == 5: return ra + ((wrap16(rb - rc) if wrap else rb - rc) >> 1)
    if psv == 6: return rb + ((wrap16(ra - rc) if wrap else ra - rc) >> 1)
    return (ra + rb) >> 1

# one table for categories 0 to 16, no code all ones
BITS = [0, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0]
VALS = [2, 3, 1, 4, 0, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
TAB = {}; code = 0; k = 0
for l in range(1, 17):
    for _ in range(BITS[l - 1]):
        TAB[VALS[k]] = (code, l); code += 1; k += 1
    code <<= 1

buf = bytearray(); acc = 0; nacc = 0
def put(v, l):
    global acc, nacc
    acc = (acc << l) | (v & ((1 << l) - 1)); nacc += l
    while nacc >= 8:
        nacc -= 8; b = (acc >> nacc) & 0xFF; buf.append(b)
        if b == 0xFF: buf.append(0)
def align():
    global nacc
    if nacc: put((1 << (8 - nacc)) - 1, 8 - nacc)
def diff(d):
    d &= 0xFFFF
    # jclhuff.c: the magnitude modulo 2^16, 32768 alone in category 16
    if d & 0x8000:
        mag = (-d) & 0x7FFF
        if mag == 0: mag, extra = 0x8000, 0
        else: extra = ~mag
    else:
        mag = d & 0x7FFF; extra = mag
    t = mag.bit_length()
    c, l = TAB[t]; put(c, l)
    if 0 < t < 16: put(extra, t)
def seg(m, body): return bytes([0xFF, m]) + struct.pack('>H', len(body) + 2) + body
def dht(): return seg(0xC4, bytes([0x00]) + bytes(BITS) + bytes(VALS))

f = bytearray(b'\xff\xd8')
if kind == 'wrap':
    W, H = 64, 48
    img = [[(round(900 * math.sin(x / 7 + y / 11) + 700 * math.cos(y / 5) + rnd.randint(-40, 40))) & 0xFFFF
            for x in range(W)] for y in range(H)]
    for y in range(H):
        for x in range(W):
            diff(img[y][x] - predict(img, W, x, y, 0, 6, 16, True))
    align()
    f += seg(0xC3, struct.pack('>BHHB', 16, H, W, 1) + bytes([1, 0x11, 0]))
    f += dht()
    f += seg(0xDA, bytes([1, 1, 0x00, 6, 0, 0])) + buf
else:
    W, H = 37, 29                       # not a multiple of the MCU: 2x2
    samp = [(2, 2), (1, 1), (1, 2)]
    hmax, vmax = 2, 2
    mx, my = (W + hmax - 1) // hmax, (H + vmax - 1) // vmax
    real = [((W * h + hmax - 1) // hmax, (H * v + vmax - 1) // vmax) for h, v in samp]
    full = [(mx * h, my * v) for h, v in samp]
    def plane(ci, w, h):
        return [[(int(128 + 90 * math.sin((x + 3 * ci) / (4 + ci)) * math.cos(y / 6)) + rnd.randint(-3, 3)) & 0xFF
                 for x in range(w)] for y in range(h)]
    f += seg(0xC3, struct.pack('>BHHB', 8, H, W, 3) +
             b''.join(bytes([i + 1, (h << 4) | v, 0]) for i, (h, v) in enumerate(samp)))
    f += dht()
    if kind == 'sub':
        imgs = [plane(i, *full[i]) for i in range(3)]
        rows = 2                        # MCU rows a restart interval
        f += seg(0xDD, struct.pack('>H', rows * mx))
        rst = 0; y0 = 0
        for j in range(my):
            if j and j % rows == 0:
                align(); buf += bytes([0xFF, 0xD0 + (rst & 7)]); rst += 1; y0 = j
            for i in range(mx):
                for ci, (h, v) in enumerate(samp):
                    for r in range(v):
                        for q in range(h):
                            y, x = j * v + r, i * h + q
                            diff(imgs[ci][y][x] - predict(imgs[ci], full[ci][0], x, y, y0 * v, 4, 8, False))
        align()
        f += seg(0xDA, bytes([3, 1, 0, 2, 0, 3, 0, 4, 0, 0])) + buf
    else:
        for ci, psv in enumerate([1, 7, 5]):
            w, h = real[ci]
            img = plane(ci, w, h)
            buf.clear()
            for y in range(h):
                for x in range(w):
                    diff(img[y][x] - predict(img, w, x, y, 0, psv, 8, False))
            align()
            f += seg(0xDA, bytes([1, ci + 1, 0, psv, 0, 0])) + buf
f += b'\xff\xd9'
open(out, 'wb').write(f)

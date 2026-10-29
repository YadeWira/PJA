#!/usr/bin/env python3
# A baseline JPEG with any sampling factors and random coefficients, for the
# codec suite (pas/run_codec_tests.sh): big enough for several bands, which
# tests/jpg's files are not.
# usage: mkjpg_sampling.py out.jpg mcusx mcusy "h0v0,h1v1,h2v2" seed
import sys, random, struct
out, mx, my, samp, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
rnd = random.Random(seed)
comps = [(int(s[0]), int(s[1])) for s in samp.split(',')]
hmax = max(h for h, v in comps); vmax = max(v for h, v in comps)
W, H = mx * 8 * hmax, my * 8 * vmax
# standard tables (K.3)
dc_bits = [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]; dc_vals = list(range(12))
ac_bits = [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d]
ac_vals = [0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa]
def codes(bits, vals):
    t = {}; code = 0; k = 0
    for l in range(1, 17):
        for _ in range(bits[l-1]):
            t[vals[k]] = (code, l); code += 1; k += 1
        code <<= 1
    return t
DC = codes(dc_bits, dc_vals); AC = codes(ac_bits, ac_vals)
buf = bytearray(); acc = 0; n = 0
def put(v, l):
    global acc, n
    acc = (acc << l) | (v & ((1 << l) - 1)); n += l
    while n >= 8:
        n -= 8; b = (acc >> n) & 0xFF; buf.append(b)
        if b == 0xFF: buf.append(0)
    acc &= (1 << n) - 1
def cat(v):
    return 0 if v == 0 else abs(v).bit_length()
def bitsof(v, s):
    return v if v >= 0 else v + (1 << s) - 1
pred = [0] * len(comps)
for my_ in range(my):
    for mx_ in range(mx):
        for ci, (h, v) in enumerate(comps):
            for _ in range(h * v):
                d = rnd.randint(-40, 40); s = cat(d)
                c, l = DC[s]; put(c, l)
                if s: put(bitsof(d, s), s)
                pred[ci] += d
                run = 0
                for k in range(1, 64):
                    p = 0.45 if k < 6 else 0.12 if k < 20 else 0.0
                    a = rnd.randint(-12, 12) if rnd.random() < p else 0
                    if a == 0:
                        run += 1; continue
                    while run > 15:
                        c, l = AC[0xF0]; put(c, l); run -= 16
                    s = cat(a); c, l = AC[(run << 4) | s]; put(c, l); put(bitsof(a, s), s); run = 0
                if run: c, l = AC[0x00]; put(c, l)
if n: put((1 << (8 - n)) - 1, 8 - n)
o = bytearray(b'\xff\xd8')
q = bytes([0] + [2] * 64)
o += b'\xff\xdb' + struct.pack('>H', 2 + 65) + q
o += b'\xff\xc0' + struct.pack('>HBHHB', 8 + 3 * len(comps), 8, H, W, len(comps))
for i, (h, v) in enumerate(comps): o += bytes([i + 1, (h << 4) | v, 0])
def dht(cls, bits, vals): return b'\xff\xc4' + struct.pack('>H', 2 + 1 + 16 + len(vals)) + bytes([cls] + bits + vals)
o += dht(0x00, dc_bits, dc_vals) + dht(0x10, ac_bits, ac_vals)
o += b'\xff\xda' + struct.pack('>HB', 6 + 2 * len(comps), len(comps))
for i in range(len(comps)): o += bytes([i + 1, 0x00])
o += bytes([0, 63, 0])
o += buf + b'\xff\xd9'
open(out, 'wb').write(o)
print(out, W, H, len(o))

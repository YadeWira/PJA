#!/usr/bin/env python3
"""Small codestreams that ask a lot of work of the analysis (doc/CODEC.md,
"JPEG 2000, stage C"): they must be refused or taken in a time that grows
with their bytes, not faster.

    mkj2k_limits.py tileparts OUT.j2k TILES PARTS
        1 component of TILES x 1 samples in tiles of 1 x 1, 0 levels, 1
        layer: each tile has PARTS tile-parts, its one packet (empty) in the
        first. Each tile used to look through all the tile-parts.
    mkj2k_limits.py codeblocks OUT.j2k
        111 bytes: 5792 x 5792 samples, one tile, 0 levels, code-blocks of
        4 x 4 (about 2 million in one precinct), 15 layers of packets with
        nothing in them. Each packet header goes through all the code-blocks.
    mkj2k_limits.py blank OUT.j2k W H [PAD [DEPTH [TILES]]]
        a blank image of W x H (DEPTH bits, 8 by default), TILES tiles (1 by
        default) one above the other, 0
        levels, code-blocks of 64 x 64, one empty packet: a few bytes that
        declare many samples (stage D: mode 2 takes it only within its width
        and its samples per byte); PAD bytes of COM segments make it longer
        (mode 2's memory at its bounds).
"""
import struct
import sys


def seg(m, body):
    return struct.pack('>HH', m, len(body) + 2) + body


def siz(w, h, tw, th, depth=8):
    return seg(0xFF51, struct.pack('>HIIIIIIIIH', 0, w, h, 0, 0, tw, th, 0, 0, 1) + bytes([depth - 1, 1, 1]))


def cod(layers, cb=0):
    # Scod 0, LRCP, layers, no MCT; 0 levels, code-blocks 4 x 4 (cb 0) or
    # 2^(cb + 2), style 0, 5/3
    return seg(0xFF52, struct.pack('>BBHB', 0, 0, layers, 0) + bytes([0, cb, cb, 0, 1]))


def tileparts(tiles, parts):
    b = bytearray(b'\xff\x4f') + siz(tiles, 1, 1, 1) + cod(1) + seg(0xFF5C, bytes([0x40, 0x40]))
    for t in range(tiles):
        for j in range(parts):
            body = b'\x00' if j == 0 else b''
            b += seg(0xFF90, struct.pack('>HIBB', t, 14 + len(body), j, parts)) + b'\xff\x93' + body
    return bytes(b + b'\xff\xd9')


def codeblocks():
    pk = b'\x80\x00' * 15
    b = bytearray(b'\xff\x4f') + siz(5792, 5792, 5792, 5792) + cod(15) + seg(0xFF5C, bytes([0x40, 0x40]))
    b += seg(0xFF90, struct.pack('>HIBB', 0, 14 + len(pk), 0, 1)) + b'\xff\x93' + pk
    return bytes(b + b'\xff\xd9')


def blank(w, h, pad=0, depth=8, tiles=1):
    pk = b'\x00'
    th = (h + tiles - 1) // tiles
    b = bytearray(b'\xff\x4f') + siz(w, h, w, th, depth) + cod(1, 4) + seg(0xFF5C, bytes([0x40, 0x40]))
    while pad > 0:
        n = min(pad, 60000)
        b += seg(0xFF64, b'\x00\x01' + bytes((i * 7) & 0x7F for i in range(n)))
        pad -= n
    for t in range((h + th - 1) // th):
        b += seg(0xFF90, struct.pack('>HIBB', t, 14 + len(pk), 0, 1)) + b'\xff\x93' + pk
    return bytes(b + b'\xff\xd9')


def main():
    a = sys.argv
    if len(a) == 5 and a[1] == 'tileparts':
        d = tileparts(int(a[3]), int(a[4]))
    elif len(a) == 3 and a[1] == 'codeblocks':
        d = codeblocks()
    elif 5 <= len(a) <= 8 and a[1] == 'blank':
        d = blank(int(a[3]), int(a[4]), *[int(v) for v in a[5:]])
    else:
        sys.exit(__doc__)
    with open(a[2], 'wb') as f:
        f.write(d)


main()

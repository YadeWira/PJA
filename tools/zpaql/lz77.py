#!/usr/bin/env python3
"""A test encoder for the z codecs' blocks (pjaz, pjalsz, pjaxz, pjallz,
pjalsxz): each segment as zpaq's level 1 LZ77 (libzpaq's LZBuffer, the -m1
method, rb = 0), matches reaching back into the block's earlier segments
within 2^wbits, as pas/plugin/zpaql/lz.zl expands them. Greedy, a hash of
8 bytes, min match 8: zpaq-std has its own; this one is for the tests.

    lz77.py <wbits> <segment>...    writes <segment>.lz"""
import sys

MIN = 8


class Bits:
    def __init__(self):
        self.out = bytearray(); self.bits = 0; self.nb = 0

    def put(self, x, k):
        self.bits |= (x & ((1 << k) - 1)) << self.nb; self.nb += k
        while self.nb >= 8:
            self.out.append(self.bits & 255); self.bits >>= 8; self.nb -= 8

    def gamma(self, n):
        """n >= 1 in interleaved Elias gamma, its leading 1 implied"""
        for i in range(n.bit_length() - 2, -1, -1):
            self.put(1, 1); self.put((n >> i) & 1, 1)
        self.put(0, 1)

    def done(self):
        if self.nb:
            self.out.append(self.bits & 255)
        return bytes(self.out)


def literals(b, data):
    for i in range(0, len(data), 1 << 23):
        run = data[i:i + (1 << 23)]
        b.put(0, 2); b.gamma(len(run))
        for c in run:
            b.put(c, 8)


def match(b, length, off):
    lo = off.bit_length() - 1
    b.put((lo + 8) >> 3, 2); b.put(lo & 7, 3)
    b.gamma(length >> 2); b.put(length & 3, 2); b.put(off, lo)


def encode(segments, wbits):
    """the segments of one block, each as its LZ77 codes"""
    data = b''.join(segments)
    win = 1 << wbits
    heads = {}
    outs, start = [], 0
    for seg in segments:
        end = start + len(seg)
        if len(seg) > win:
            raise ValueError('a segment larger than the window')
        b, i, lit = Bits(), start, start
        while i < end:
            best, boff = 0, 0
            if i + MIN <= end:
                key = data[i:i + MIN]
                for p in reversed(heads.get(key, [])[-16:]):
                    off = i - p
                    # the whole segment must stay within the window, and rb = 0
                    if off >= win - len(seg) or off >= 1 << 24:
                        break
                    m = 0
                    while i + m < end and data[p + m] == data[i + m] and m < 1 << 20:
                        m += 1
                    if m > best:
                        best, boff = m, off
            if best >= MIN:
                literals(b, data[lit:i])
                match(b, best, boff)
                for q in range(i, i + best):
                    if q + MIN <= end:
                        heads.setdefault(data[q:q + MIN], []).append(q)
                i += best; lit = i
            else:
                if i + MIN <= end:
                    heads.setdefault(data[i:i + MIN], []).append(i)
                i += 1
        literals(b, data[lit:end])
        outs.append(b.done())
        start = end
    return outs


if __name__ == '__main__':
    wb, names = int(sys.argv[1]), sys.argv[2:]
    for name, z in zip(names, encode([open(n, 'rb').read() for n in names], wb)):
        open(name + '.lz', 'wb').write(z)

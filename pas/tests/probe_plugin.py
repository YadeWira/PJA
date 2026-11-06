#!/usr/bin/env python3
"""The zpaq-std plugin as zpaq-std sees it (its C ABI, through ctypes): the
codecs it lists, which files the JPEG 2000 codec takes, and that codec's
compress, query, data and decompress on those files.

    probe_plugin.py <pja.so> <dir or file> ...

Checks: 31 codecs (0 to 30) and nothing past them; the JPEG 2000 codec at
30, named as pjazsj2k.pas's PJK_NAME, its ZPAQL given only with $3..$5
(comp 0 0 $3 $4 0); detect takes each JPEG 2000 file whose codestreams it
can (all of tests/j2k) and no JPEG or JPEG-LS file, and no other codec takes
a JPEG 2000 file; each JPEG 2000 file of 64 KB or less compressed, its query
within the ZPAQL's limits (H 2^26 words, M 2^28 bytes), decompressed back
byte for byte. Exit code 1 on any failure."""
import ctypes as C, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, '..', 'plugin', 'pjazsj2k.pas')).read()
PJK = re.search(r"PJK_NAME = '(\w+)';", src).group(1)

BOUND = C.CFUNCTYPE(C.c_size_t, C.c_size_t, C.c_int)
COMP = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t, C.c_int)
QUERY = C.CFUNCTYPE(C.c_longlong, C.c_int, C.c_void_p, C.c_size_t)
DATA = C.CFUNCTYPE(C.c_void_p, C.c_int, C.POINTER(C.c_size_t))


class Codec(C.Structure):
    _fields_ = [('abi', C.c_int), ('name', C.c_char_p), ('library', C.c_char_p), ('min_level', C.c_int),
                ('max_level', C.c_int), ('bound', BOUND), ('compress', COMP), ('decompress', COMP),
                ('query', QUERY), ('data', DATA)]


lib = C.CDLL(os.path.abspath(sys.argv[1]))
lib.zpaqstd_codecs_v1.restype = C.POINTER(Codec)
lib.zpaqstd_codecs_v1.argtypes = [C.c_int]
lib.zpaqstd_detect_v1.restype = C.c_int
lib.zpaqstd_detect_v1.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t]
fails = 0


def fail(msg):
    global fails
    fails += 1
    print('FAIL: ' + msg)


codecs = []
i = 0
while True:
    p = lib.zpaqstd_codecs_v1(i)
    if not p:
        break
    codecs.append(p.contents)
    i += 1
names = [c.name.decode() for c in codecs]
if len(codecs) != 31:
    fail('%d codecs listed, not 31' % len(codecs))
if len(set(names)) != len(names):
    fail('names repeated')
if names[30:31] != [PJK]:
    fail('codec 30 is %s, not %s' % (names[30:31], PJK))
pjk = codecs[30]
if pjk.abi != 1 or pjk.min_level != 2 or pjk.max_level != 2:
    fail('%s: abi or levels' % PJK)
size = C.c_size_t(0)
if pjk.data(2, C.byref(size)):
    fail('%s gives its ZPAQL without $3..$5' % PJK)
z = pjk.data(4, C.byref(size))
cfg = C.string_at(z, size.value).decode() if z else ''
if not cfg.startswith('comp 0 0 $3 $4 0'):
    fail('%s: its ZPAQL config: %r' % (PJK, cfg[:40]))
card = pjk.data(3, C.byref(size))
card = C.string_at(card, size.value).decode() if card else ''
if 'name=%s\n' % PJK not in card:
    fail('%s: its card' % PJK)
if pjk.query(3, b'', 0) != 1:
    fail('%s: segments' % PJK)

files = []
for a in sys.argv[2:]:
    if os.path.isdir(a):
        files += sorted(os.path.join(a, f) for f in os.listdir(a) if os.path.isfile(os.path.join(a, f)))
    else:
        files.append(a)
taken = rt = 0
for f in files:
    d = open(f, 'rb').read()
    j2k = d[:4] == b'\xff\x4f\xff\x51' or d[:12] == b'\x00\x00\x00\x0cjP  \r\n\x87\n'
    det = lib.zpaqstd_detect_v1(PJK.encode(), d, len(d))
    if det != int(j2k):
        fail('%s: detect %s says %d' % (os.path.basename(f), PJK, det))
    if j2k:
        for n in names[:30]:
            if lib.zpaqstd_detect_v1(n.encode(), d, len(d)):
                fail('%s: %s takes it' % (os.path.basename(f), n))
    if not det:
        continue
    taken += 1
    if len(d) > 65536:
        continue
    cap = pjk.bound(len(d), 2)
    out = C.create_string_buffer(cap)
    n = pjk.compress(d, len(d), out, cap, 2)
    if n < 0:
        fail('%s: compress %d' % (os.path.basename(f), n))
        continue
    s = out.raw[:n]
    a = pjk.query(2, s, n)
    if a < 0 or (a & 255) > 26 or (a >> 8) > 28:
        fail('%s: query %d' % (os.path.basename(f), a))
    back = C.create_string_buffer(len(d) + 1)
    m = pjk.decompress(s, n, back, len(d), 0)
    if m != len(d) or back.raw[:m] != d:
        fail('%s: decompress %d' % (os.path.basename(f), m))
    else:
        rt += 1
print('plugin: %d codecs, %s at 30 (ZPAQL %d bytes of text); %d files, %s took %d, %d back through compress, '
      'query and decompress; %d failures' % (len(codecs), PJK, len(cfg), len(files), PJK, taken, rt, fails))
sys.exit(1 if fails else 0)

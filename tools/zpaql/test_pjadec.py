#!/usr/bin/env python3
"""The plugin's ZPAQL decoders (pas/plugin/pjazpaql.inc, and for JPEG-LS
files pjalszpaql.inc) run on segments: each must give back its file byte
for byte; and, per decoder, its two smallest files as segments of one
block, as zpaq-std groups them.

    test_pjadec.py <segment dir> <jpeg> ...
    test_pjadec.py --pjax <segment dir> <jpeg> ...   pjax's (pjaxzpaql.inc)
    test_pjadec.py --pjall <segment dir> <jpeg> ...  pjall's (pjallzpaql.inc)
    test_pjadec.py --pjalsx <segment dir> <jls> ...  pjalsx's (pjalsxzpaql.inc)
    test_pjadec.py --pja7 <segment dir> <jpeg> ...   pja7's (v7zpaql.inc), stream version 7
    test_pjadec.py --pjax7 <segment dir> <jpeg> ...  pjax7's (v7zpaql.inc)
    test_pjadec.py --o [--lz] [--pjall|--pjalsx] <segment dir> <file> ...
        the o codecs' (ozpaql.inc): pjalso's for JPEG-LS files (or pjallo's,
        pjalsxo's), and with --lz their z (pjalszo, ...); JPEGs, pja's as before
    test_pjadec.py --v8 [--lz] [--pja7|--pjax7|--pjall|--pjalsx] <segment dir> <file> ...
        the 8 codecs' (v8zpaql.inc): pja78's, pjax78's, pjals8's, pjall8's,
        pjalsx8's, and with --lz their z; without a codec flag, JPEG-LS files
        through pjals8 (JPEGs, pja's as before)
    test_pjadec.py --pja2k <segment dir> <file> ...
        the JPEG 2000 codec's (j2kzpaql.inc: stream version 8, modes 0 and
        1), each file alone with the H and M of its query ($3 | $4 << 8 in
        its .args), then the two smallest as segments of one block
    test_pjadec.py --lz [--pjax|...] <segment dir> <file> ...
        the z codec's instead (lzzpaql.inc; v7zpaql.inc's for --pja7 and
        --pjax7), per decoder on ONE block: its
        two smallest files and the first of them again, through lz77.py
        (the third all matches into the first), the window the smallest
        that holds the block

The segments come from pas/tests/zpaql_segments, with the $3 the plugin's
query gives for each: the decoder runs with exactly that H (it measures its
H and stops if it is short). Slow (the interpreter is
Python): the suite gives it a few small samples; zpaq-std -sat, with
libzpaq's JIT, checks every block of real files."""
import math, os, re, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zpaqlvm, lz77

REPO = os.path.dirname(os.path.dirname(HERE))


args = sys.argv[1:]


def pjk_test(segdir, files):
    """the JPEG 2000 codec's decoder: each file, then two in one block"""
    cfg = zconfig('PJK', 'j2kzpaql.inc')
    fails = 0

    def load(f):
        n = os.path.join(segdir, os.path.splitext(os.path.basename(f))[0])
        a = int(open(n + '.args').read())
        if a < 0:
            raise RuntimeError('the query refused it')
        return open(n + '.seg', 'rb').read(), open(f, 'rb').read(), a & 255, a >> 8
    for f in files:
        t = time.time()
        try:
            seg, want, ph, pm = load(f)
            out, steps, size = zpaqlvm.run_config(cfg, seg, [math.ceil(math.log2(len(seg))),
                                                             math.ceil(math.log2(len(want))), ph, pm])
            ok = out == want
        except Exception as e:
            ok = False
            ph = pm = '?'
            print('  %s: %s' % (os.path.basename(f), e))
        if not ok:
            fails += 1
        print('  %-24s %s (%d bytes, H 2^%s words, M 2^%s bytes, %.0f s)' % (
            os.path.basename(f), 'the original' if ok else 'DIFFERS', os.path.getsize(f), ph, pm, time.time() - t))
    group = sorted(files, key=os.path.getsize)[:2][::-1]
    if len(group) == 2:
        t = time.time()
        try:
            loaded = [load(f) for f in group]
            segs = [x[0] for x in loaded]
            outs, steps, size = zpaqlvm.run_segments(cfg, segs, [math.ceil(math.log2(max(map(len, segs)))),
                                                                 math.ceil(math.log2(max(len(x[1]) for x in loaded))),
                                                                 max(x[2] for x in loaded), max(x[3] for x in loaded)])
            ok = outs == [x[1] for x in loaded]
        except Exception as e:
            ok = False
            print('  block: %s' % e)
        if not ok:
            fails += 1
        print('  one block: %s %s (%.0f s)' % (' + '.join(os.path.basename(f) for f in group),
                                               'each the original' if ok else 'DIFFERS', time.time() - t))
    print('%d JPEG 2000 files through the pja2k decoder, %d failures' % (len(files), fails))
    sys.exit(1 if fails else 0)


# --lz: the z codec's decoder, on the segments as LZ77
# --o: the o codecs' decoders (the same programs, compiled with opt=2)
ozp = '--o' in args[:3]
if ozp:
    args.remove('--o')
# --v8: the 8 codecs' decoders (opt=3)
v8 = '--v8' in args[:3]
if v8:
    args.remove('--v8')
lz = '--lz' in args[:2]
if lz:
    args.remove('--lz')
# --pjax: the segments are the pjax codec's, every file through its decoder
pjax = args[:1] == ['--pjax']
# --pjall: lossless JPEGs, through the pjall codec's decoder
pjall = args[:1] == ['--pjall']
# --pjalsx: subsampled JPEG-LS, through the pjalsx codec's decoder
pjalsx = args[:1] == ['--pjalsx']
# --pja7, --pjax7: the version 7 codecs, pja's and pjax's
pja7 = args[:1] == ['--pja7']
pjax7 = args[:1] == ['--pjax7']
if pjax or pjall or pjalsx or pja7 or pjax7:
    args = args[1:]
segdir, jpegs = args[0], args[1:]


def config(name):
    inc = open(os.path.join(REPO, 'pas', 'plugin', name)).read()
    return '\n'.join(m.replace("''", "'") for m in re.findall(r"^\s+'(.*)'#10", inc, re.M)) + '\n'


cfgs = {False: config('pjazpaql.inc'), True: config('pjalszpaql.inc')}
if pjax:
    cfgs = {False: config('pjaxzpaql.inc'), True: config('pjaxzpaql.inc')}
if pjall:
    cfgs = {False: config('pjallzpaql.inc'), True: config('pjallzpaql.inc')}
if pjalsx:
    cfgs = {False: config('pjalsxzpaql.inc'), True: config('pjalsxzpaql.inc')}


def zconfig(name, incname='lzzpaql.inc'):
    inc = open(os.path.join(REPO, 'pas', 'plugin', incname)).read()
    part = inc[inc.index('  %s_ZPAQL: AnsiString =' % name):]
    part = part[:part.index(';\n')]
    return '\n'.join(m.replace("''", "'") for m in re.findall(r"^\s+'(.*)'#10", part, re.M)) + '\n'


if args[:1] == ['--pja2k']:
    pjk_test(args[1], args[2:])


if ozp:
    o = 'PJALLO' if pjall else 'PJALSXO' if pjalsx else 'PJALSO'
    cfgs = {False: cfgs[False], True: zconfig(o, 'ozpaql.inc')}
    if pjall or pjalsx:
        cfgs = {False: cfgs[True], True: cfgs[True]}


if pja7 or pjax7:
    v7 = zconfig('PJAX7' if pjax7 else 'PJA7', 'v7zpaql.inc')
    cfgs = {False: v7, True: v7}


if v8 and not lz:
    n8 = 'PJAX78' if pjax7 else 'PJA78' if pja7 else 'PJALL8' if pjall else 'PJALSX8' if pjalsx else 'PJALS8'
    c8 = zconfig(n8, 'v8zpaql.inc')
    cfgs = {False: c8 if (pja7 or pjax7 or pjall or pjalsx) else cfgs[False], True: c8}


if lz:
    z = 'PJAXZ' if pjax else 'PJALLZ' if pjall else 'PJALSXZ' if pjalsx else None
    cfgs = {False: zconfig(z or 'PJAZ'), True: zconfig(z or 'PJALSZ')}
    if ozp:
        zo = (z or 'PJALSZ') + 'O'
        cfgs = {False: cfgs[False], True: zconfig(zo, 'ozpaql.inc')}
        if pjall or pjalsx:
            cfgs = {False: cfgs[True], True: cfgs[True]}
    if pja7 or pjax7:
        z7 = zconfig('PJAX7Z' if pjax7 else 'PJA7Z', 'v7zpaql.inc')
        cfgs = {False: z7, True: z7}
    if v8:
        n8 = 'PJAX7Z8' if pjax7 else 'PJA7Z8' if pja7 else 'PJALLZ8' if pjall else 'PJALSXZ8' if pjalsx else 'PJALSZ8'
        c8 = zconfig(n8, 'v8zpaql.inc')
        cfgs = {False: c8 if (pja7 or pjax7 or pjall or pjalsx) else cfgs[False], True: c8}
    fails = 0
    for ls in (False, True):
        group = sorted((j for j in jpegs if j.lower().endswith('.jls') == ls), key=os.path.getsize)[:2][::-1]
        if not group:
            continue
        names = [os.path.join(segdir, os.path.splitext(os.path.basename(j))[0]) for j in group]
        segs = [open(n + '.seg', 'rb').read() for n in names]
        wants = [open(j, 'rb').read() for j in group]
        ph = max(int(open(n + '.args').read()) for n in names)
        wb = max(10, math.ceil(math.log2(2 * sum(map(len, segs)) + 1)))
        for ks, what in [(list(range(len(group))) + [0], 'one block')]:
            t = time.time()
            zs = lz77.encode([segs[k] for k in ks], wb)
            try:
                outs, steps, size = zpaqlvm.run_segments(cfgs[ls], zs, [wb, 0, ph])
                ok = outs == [wants[k] for k in ks]
            except Exception as e:
                ok = False
                print('  %s' % e)
            if not ok:
                fails += 1
            print('  %s: %s %s (LZ77 %d -> %d bytes, window 2^%d, %.0f s)' % (
                what, ' + '.join(os.path.basename(group[k]) for k in ks), 'back' if ok else 'DIFFERS',
                sum(len(segs[k]) for k in ks), sum(map(len, zs)), wb, time.time() - t))
    print('%d files through the z decoders, %d failures' % (len(jpegs), fails))
    sys.exit(1 if fails else 0)
fails = 0
for j in jpegs:
    want = open(j, 'rb').read()
    seg = open(os.path.join(segdir, os.path.splitext(os.path.basename(j))[0] + '.seg'), 'rb').read()
    t = time.time()
    try:
        ph = int(open(os.path.join(segdir, os.path.splitext(os.path.basename(j))[0] + '.args')).read())
        if ph < 0:
            raise RuntimeError('the query refused it')
        out, steps, size = zpaqlvm.run_config(cfgs[j.lower().endswith('.jls')], seg, [math.ceil(math.log2(len(seg))), math.ceil(math.log2(len(want))), ph])
        ok = out == want
    except Exception as e:
        ok = False; out = b''
        print('  %s: %s' % (os.path.basename(j), e))
    if not ok:
        fails += 1
    print('  %-20s %s (%d bytes, H of 2^%s words, %.0f s)' % (os.path.basename(j), 'the original' if ok else 'DIFFERS', len(want), ph if ok else '?', time.time() - t))

# several files in ONE block, a segment each, as zpaq-std puts them: the
# decoder starts afresh after each. Per decoder, its two smallest files,
# the larger first, H the larger of their two sizes
blocks = 0
for ls in (False, True):
    group = sorted((j for j in jpegs if j.lower().endswith('.jls') == ls), key=os.path.getsize)[:2][::-1]
    if len(group) < 2:
        continue
    blocks += 1
    t = time.time()
    names = [os.path.join(segdir, os.path.splitext(os.path.basename(j))[0]) for j in group]
    segs = [open(n + '.seg', 'rb').read() for n in names]
    wants = [open(j, 'rb').read() for j in group]
    ph = max(int(open(n + '.args').read()) for n in names)
    try:
        outs, steps, size = zpaqlvm.run_segments(cfgs[ls], segs, [math.ceil(math.log2(max(map(len, segs)))),
                                                                   math.ceil(math.log2(max(map(len, wants)))), ph])
        ok = outs == wants
    except Exception as e:
        ok = False
        print('  block: %s' % e)
    if not ok:
        fails += 1
    print('  one block: %s %s (%.0f s)' % (' + '.join(os.path.basename(j) for j in group), 'each the original' if ok else 'DIFFERS', time.time() - t))
print('%d files, %d blocks of two, %d failures' % (len(jpegs), blocks, fails))
sys.exit(1 if fails else 0)

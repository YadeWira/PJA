#!/usr/bin/env python3
"""The plugin's ZPAQL decoders (pas/plugin/pjazpaql.inc, and for JPEG-LS
files pjalszpaql.inc) run on segments: each must give back its file byte
for byte; and, per decoder, its two smallest files as segments of one
block, as zpaq-std groups them.

    test_pjadec.py <segment dir> <jpeg> ...
    test_pjadec.py --pjax <segment dir> <jpeg> ...   pjax's (pjaxzpaql.inc)
    test_pjadec.py --pjall <segment dir> <jpeg> ...  pjall's (pjallzpaql.inc)
    test_pjadec.py --pjalsx <segment dir> <jls> ...  pjalsx's (pjalsxzpaql.inc)

The segments come from pas/tests/zpaql_segments, with the $3 the plugin's
query gives for each: the decoder runs with exactly that H (it measures its
H and stops if it is short). Slow (the interpreter is
Python): the suite gives it a few small samples; zpaq-std -sat, with
libzpaq's JIT, checks every block of real files."""
import math, os, re, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zpaqlvm

REPO = os.path.dirname(os.path.dirname(HERE))


args = sys.argv[1:]
# --pjax: the segments are the pjax codec's, every file through its decoder
pjax = args[:1] == ['--pjax']
# --pjall: lossless JPEGs, through the pjall codec's decoder
pjall = args[:1] == ['--pjall']
# --pjalsx: subsampled JPEG-LS, through the pjalsx codec's decoder
pjalsx = args[:1] == ['--pjalsx']
if pjax or pjall or pjalsx:
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

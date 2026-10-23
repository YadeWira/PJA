#!/usr/bin/env python3
"""The plugin's ZPAQL decoder (pas/plugin/pjazpaql.inc) run on segments:
it must give back each JPEG byte for byte.

    test_pjadec.py <segment dir> <jpeg> ...

The segments come from pas/tests/zpaql_segments. Slow (the interpreter is
Python): the suite gives it two small samples; zpaq-std -sat, with
libzpaq's JIT, checks every block of real files."""
import math, os, re, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zpaqlvm

REPO = os.path.dirname(os.path.dirname(HERE))
inc = open(os.path.join(REPO, 'pas', 'plugin', 'pjazpaql.inc')).read()
cfg = '\n'.join(m.replace("''", "'") for m in re.findall(r"^\s+'(.*)'#10", inc, re.M)) + '\n'
segdir, jpegs = sys.argv[1], sys.argv[2:]
fails = 0
for j in jpegs:
    want = open(j, 'rb').read()
    seg = open(os.path.join(segdir, os.path.splitext(os.path.basename(j))[0] + '.seg'), 'rb').read()
    t = time.time()
    try:
        out, steps, size = zpaqlvm.run_config(cfg, seg, [math.ceil(math.log2(len(seg))), math.ceil(math.log2(len(want)))], max_ph=23)
        ok = out == want
    except Exception as e:
        ok = False; out = b''
        print('  %s: %s' % (os.path.basename(j), e))
    if not ok:
        fails += 1
    print('  %-20s %s (%d bytes, %.0f s)' % (os.path.basename(j), 'the original' if ok else 'DIFFERS', len(want), time.time() - t))
print('%d files, %d failures' % (len(jpegs), fails))
sys.exit(1 if fails else 0)

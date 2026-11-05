#!/usr/bin/env python3
"""Writes pas/pjaselftest.inc: the samples `pja selftest` carries inside the
binary, and the .pja each one has to give (doc/CLI.md, selftest).

Four small files of tests/ (a baseline JPEG in 4:2:0, a progressive one, an
arithmetic-coded one with restarts, a near-lossless JPEG-LS), about 5.7 KB,
and the .pja the given pja command makes of each. The formats are frozen
(doc/STABILITY.md): those bytes never change, on any platform or SIMD path.

    tools/gen_selftest.py <pja binary>            write the include
    tools/gen_selftest.py --check <pja binary>    exit 1 if it is not current
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pas', 'pjaselftest.inc')
SAMPLES = ['jpg/baseline_color.jpg', 'jpg/prog_huffman.jpg', 'jpg/arith_restart.jpg',
           'jls/plasma17x13_sample_near1.jls']


def pas_bytes(name, b):
    out = [f'  {name}: array[0..{len(b) - 1}] of Byte = (']
    for i in range(0, len(b), 20):
        out.append('    ' + ', '.join(f'${x:02X}' for x in b[i:i + 20]) + (',' if i + 20 < len(b) else ''))
    out.append('  );')
    return out


def generate(pja):
    lines = ['{ Written by tools/gen_selftest.py: do not edit. The samples of `pja selftest`',
             '  (tests/README.md says how each was made) and the .pja of each. }', 'const']
    table = []
    with tempfile.TemporaryDirectory() as tmp:
        for k, rel in enumerate(SAMPLES):
            src = os.path.join(ROOT, 'tests', rel)
            data = open(src, 'rb').read()
            out = os.path.join(tmp, f's{k}.pja')
            subprocess.run([pja, 'a', '-q', '-f', '-th', '1', src, '-o', out], check=True)
            packed = open(out, 'rb').read()
            lines += pas_bytes(f'SELFTEST_IN_{k}', data)
            lines += pas_bytes(f'SELFTEST_PJA_{k}', packed)
            table.append((os.path.basename(rel), os.path.splitext(rel)[1][1:], k))
    lines.append(f'  SELFTEST_COUNT = {len(table)};')
    lines.append('  SELFTEST_NAMES: array[0..SELFTEST_COUNT - 1] of string = (' +
                 ', '.join(f"'{t[0]}'" for t in table) + ');')
    lines.append('  SELFTEST_EXTS: array[0..SELFTEST_COUNT - 1] of string = (' +
                 ', '.join(f"'{t[1]}'" for t in table) + ');')
    lines.append('')
    lines.append('procedure SelftestSample(k: Integer; out data, expect: TBytes);')
    lines.append('begin')
    lines.append('  data := nil; expect := nil;')
    lines.append('  case k of')
    for (_, _, k) in table:
        lines.append(f'    {k}: begin')
        lines.append(f'      SetLength(data, Length(SELFTEST_IN_{k})); Move(SELFTEST_IN_{k}[0], data[0], Length(data));')
        lines.append(f'      SetLength(expect, Length(SELFTEST_PJA_{k})); Move(SELFTEST_PJA_{k}[0], expect[0], Length(expect));')
        lines.append('    end;')
    lines.append('  end;')
    lines.append('end;')
    return '\n'.join(lines) + '\n'


def main():
    args = sys.argv[1:]
    check = args and args[0] == '--check'
    if check:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    text = generate(args[0])
    if check:
        old = open(OUT).read() if os.path.exists(OUT) else ''
        if old != text:
            print('pas/pjaselftest.inc is not current: run tools/gen_selftest.py <pja>')
            sys.exit(1)
        print('pas/pjaselftest.inc is current')
        return
    open(OUT, 'w').write(text)
    print(f'wrote {OUT}')


main()

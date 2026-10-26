#!/usr/bin/env python3
"""Builds the ZPAQL decoder the zpaq-std plugin carries (pas/plugin/).

    gen_pjadec.py [--check]

1. pas/plugin/zpaql/consts.zl from the Pascal sources: the model's
   constants, the size of every table of the full model (TCoefModel.Init's
   NewBits calls, the fast model's left out) and its mixers (their Init
   calls), the zigzag order, BASIS, K_BUCKET_OF, the partition networks of
   Split16 and Split8, the bucket tables, and squash's upper half (the
   same formula as pjamodel.InitTables; it agrees with it on all 4096
   values, the nearest one 0.00017 away from a rounding tie).
2. pjadec.zl, consts.zl, model.zl and huff.zl compiled with zpaqlc into
   pas/plugin/pjazpaql.inc: the config as a Pascal string, and the words
   of H the decoder takes besides what each file needs (for the plugin's
   query and detection).
4. pjadec.zl, consts.zl, model.zl, huff.zl and pjax.zl, the pjax codec's
   decoder (stream versions 5 and 6, Huffman only), into
   pas/plugin/pjaxzpaql.inc. Every program is compiled with its PJAX
   constant: 1 for this one, 0 for the frozen pja and pjals, whose
   programs the branches on it leave as they were.
5. pjadec.zl, consts.zl, model.zl, jls.zl and ljpeg.zl, the pjall codec's
   decoder (lossless JPEG, stream version 5), into pas/plugin/pjallzpaql.inc,
   compiled with PJALL = 1 (0 for the others).
3. pjadec.zl, consts.zl, model.zl and jls.zl, the JPEG-LS decoder of the
   pjals codec, into pas/plugin/pjalszpaql.inc, with the words of its
   models (jls.zl's constants checked against pjamodel.pas and
   pjajls.pas). The compiler leaves out what a decoder does not reach.

With --check nothing is written: it fails if any of the files is not what
the sources make now (the suite runs this)."""
import math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PAS = os.path.join(REPO, 'pas')
ZL = os.path.join(PAS, 'plugin', 'zpaql')
sys.path.insert(0, HERE)
import zpaqlc

PH = '$3'               # H: what the plugin's query says this block needs
NAME = 'pja5'
LS_NAME = 'pjals5'
X_NAME = 'pjax6'
LL_NAME = 'pjall5'


def pascal_consts(src):
    """NAME = <integer expression>; from const sections, in order."""
    out = {}
    for m in re.finditer(r'^\s+([A-Z][A-Z0-9_]*)\s*=\s*([^;{]+);', src, re.M):
        name, expr = m.group(1), m.group(2).strip()
        try:
            out[name] = int(eval(expr.replace(' shl ', ' << ').replace(' div ', ' // '), {}, dict(out)))
        except Exception:
            pass
    return out


def make_consts():
    model = open(os.path.join(PAS, 'pjamodel.pas')).read()
    jpeg = open(os.path.join(PAS, 'pjajpeg.pas')).read()
    k = pascal_consts(model)
    names = ['NZ_BUCKETS', 'REM_BUCKETS', 'MAG_BUCKETS', 'K_BUCKETS', 'RATIO_BUCKETS', 'MAX_EXP_AC',
             'MAX_EXP_DC', 'ACT_BUCKETS', 'NO_NEIGHBOUR', 'PRED_BUCKETS', 'NO_PRED', 'EDGE_POS',
             'COUNTER_LIMIT', 'MAX_WEIGHT', 'O2_BITS', 'BAND_BLOCKS', 'MAX_BANDS']
    for n in names:
        if n not in k:
            raise SystemExit('gen_pjadec: %s not found in pjamodel.pas' % n)
    i = model.index('procedure TCoefModel.Init(isFast, isChroma: Boolean);')
    body = model[i:model.index('\nend;', i)]
    fast_from = body.index('if fast then begin')
    fast_to = body.index('Exit;', fast_from)
    full = body[:fast_from] + body[fast_to:]
    tables = []
    for m in re.finditer(r'NewBits\((\w+),\s*([^;]+)\);', full):
        tables.append((m.group(1).upper(), int(eval(m.group(2).replace(' div ', ' // '), {}, dict(k)))))
    mixers = []
    for m in re.finditer(r'(mx\w+)\.Init\(([^,]+),\s*([^)]+)\);', full):
        mixers.append((m.group(1)[2:].upper(), int(eval(m.group(2), {}, dict(k))), int(eval(m.group(3), {}, dict(k)))))

    def pairs(name):
        a = model.index('procedure %s(var e: TEstimates);' % name)
        b = model.index('end;', a)
        return [(int(x), int(y)) for x, y in re.findall(r'CompareSwap\(e\[(\d+)\], e\[(\d+)\]\)', model[a:b])]

    def int_list(src, start):
        a = src.index(start) + len(start)
        return [int(x) for x in re.findall(r'-?\d+', src[a:src.index(');', a)])]

    qa = jpeg.index('QE_TABLE: array[0..113] of LongInt = (')
    qe = [int(x, 16) for x in re.findall(r'\$([0-9a-fA-F]+)', jpeg[qa:jpeg.index(');', qa)])]
    assert len(qe) == 114
    basis = int_list(model, 'BASIS: array[0..7, 0..7] of Integer = (')
    kbucket = int_list(model, 'K_BUCKET_OF: array[0..63] of Byte = (')
    zigzag = int_list(jpeg, 'ZIGZAG: array[0..63] of Byte = (')
    assert len(basis) == 64 and len(kbucket) == 64 and len(zigzag) == 64

    def nzb(n):   # pjamodel.NzBucketOf
        return n if n <= 4 else 5 if n <= 6 else 6 if n <= 8 else 7 if n <= 12 else 8 if n <= 18 else 9 if n <= 27 else 10

    def remb(n):  # pjamodel.RemBucketOf
        return n - 1 if 1 <= n <= 4 else 4 if n <= 6 and n >= 5 else 5 if 7 <= n <= 9 else 6 if 10 <= n <= 14 else 7 if 15 <= n <= 22 else 8

    sq = [min(4095, max(1, round(4096 / (1 + math.exp(-(i - 2048) / 256))))) for i in range(4096)]
    assert sq[2048] == 2048 and sq[0] == 1 and all(sq[i] + sq[4096 - i] == 4096 for i in range(1, 4096))
    deltas = [sq[2048 + i + 1] - sq[2048 + i] for i in range(2047)]
    assert max(deltas) <= 7
    sqpack = []
    for a in range(0, 2047, 10):
        w = 0
        for j, d in enumerate(deltas[a:a + 10]):
            w |= d << (3 * j)
        sqpack.append(w)

    def tab(name, vals):
        return '%s = table([%s])\n' % (name, ', '.join(str(v & 0xFFFFFFFF) for v in vals))

    out = ['"""Generated by tools/zpaql/gen_pjadec.py from pas/pjamodel.pas and pas/pjajpeg.pas: do not edit."""\n']
    for n in names:
        out.append('%s = %d\n' % (n, k[n]))
    out.append('# the full model in H: its mixers\' addresses, then its tables\n')
    for idx, (n, _, _) in enumerate(mixers):
        out.append('MX_%s = %d\n' % (n, idx))
    off = len(mixers)
    for n, size in tables:
        out.append('T_%s = %d\n' % (n, off))
        off += size
    out.append('MODEL_WORDS = %d\n' % off)
    mixer_words = sum(12 + sets * 8 for _, _, sets in mixers)
    out.append('MIXER_WORDS = %d\n' % mixer_words)
    out.append(tab('zigzag', zigzag) + tab('basis', basis) + tab('kbucket', kbucket))
    out.append(tab('nzbucket', [nzb(n) for n in range(64)]) + tab('rembucket', [remb(n) for n in range(64)]))
    out.append(tab('split16', [a * 16 + b for a, b in pairs('Split16')]))
    out.append(tab('split8', [a * 16 + b for a, b in pairs('Split8')]))
    out.append(tab('qetable', qe))
    out.append('SQPACK_WORDS = %d\n' % len(sqpack))
    out.append(tab('sqpack', sqpack))
    out.append('\ndef newmodel():\n    m = alloc(MODEL_WORDS)\n')
    for n, inputs, sets in mixers:
        out.append('    H[m + MX_%s] = mxnew(%d, %d)\n' % (n, inputs, sets))
    out.append('    return m\n')
    return ''.join(out), off + mixer_words


def zl_consts(src):
    """NAME = <integer> at the top level of a .zl source"""
    return {m.group(1): int(m.group(2)) for m in re.finditer(r'^([A-Z][A-Z0-9_]*) = (-?\d+)\s*(?:#.*)?$', src, re.M)}


def jls_words(jls):
    """the words of H pjals takes besides each file's own: the symbols
    model, and each band of the samples model (jls.zl's allocs)"""
    model = pascal_consts(open(os.path.join(PAS, 'pjamodel.pas')).read())
    jlsp = open(os.path.join(PAS, 'pjajls.pas')).read()
    k = zl_consts(jls)
    for n in ('JLS_CTX', 'JLS_ACT', 'JLS_NB', 'JLS_FIRST', 'JLS_MAX_EXP', 'JLS_BAND_SAMPLES',
              'SYM_K', 'SYM_CTX', 'SYM_NB', 'SYM_X', 'SYM_E', 'SYM_ACT', 'SYM_TEX'):
        if k.get(n) != model.get(n):
            raise SystemExit('gen_pjadec: jls.zl has %s = %s, pjamodel.pas %s' % (n, k.get(n), model.get(n)))
    if k.get('MAX_K') != pascal_consts(jlsp).get('MAX_K'):
        raise SystemExit('gen_pjadec: jls.zl\'s MAX_K is not pjajls.pas\'s')
    a = jlsp.index('RUN_J: array[0..31] of Integer = (') + len('RUN_J: array[0..31] of Integer = (')
    runj = re.search(r'RUN_J = table\(\[([^\]]*)\]\)', jls).group(1)
    if [int(x) for x in re.findall(r'\d+', jlsp[a:jlsp.index(');', a)])] != [int(x) for x in runj.split(',')]:
        raise SystemExit('gen_pjadec: jls.zl\'s RUN_J is not pjajls.pas\'s')
    K, CTX, NB, X, E, ACT, TEX = (k['SYM_' + n] for n in ('K', 'CTX', 'NB', 'X', 'E', 'ACT', 'TEX'))
    sym = (3 * K * E + CTX * E + 3 * NB * E + X * K * E + 16 * K * E + ACT * K * E + TEX * E +
           (E + 1) * 16 * K + (E + 1) * 16 * E + 3 * 15 * (E + 1) * 3 + 2 * 32 * 8 + 32 * 80 +
           12 + 3 * K * E * 8 + 2 * TEX)
    C, A, N, F, M = (k['JLS_' + n] for n in ('CTX', 'ACT', 'NB', 'FIRST', 'MAX_EXP'))
    band = (2 * C * 4 + 2 * A + 2 * C + 2 * N * 4 + F * A + 2 * A * M + 2 * C * M + 2 * N * M + F * M +
            (M + 1) * A + (M + 1) * M + 2 * A * 9 + 12 + 2 * A * 8 + 12 + 2 * M * 8)
    return sym, band


def chunked(cfg):
    lines = [l.strip() for l in cfg.split('\n') if l.strip()]
    chunks, cur = [], ''
    for l in lines:
        if len(cur) + len(l) + 1 > 200:
            chunks.append(cur); cur = l
        else:
            cur = cur + ' ' + l if cur else l
    if cur:
        chunks.append(cur)
    return ' +\n'.join("    '" + ch.replace("'", "''") + "'#10" for ch in chunks) + ';'


def build(check):
    consts, model_words = make_consts()
    cpath = os.path.join(ZL, 'consts.zl')

    def source(files, pjax=0, pjall=0):
        # PJAX, PJALL: the constants the shared sources test for what pjax or
        # pjall has and the frozen programs have not (zpaqlc compiles only
        # the branch taken)
        return 'PJAX = %d\nPJALL = %d\n' % (pjax, pjall) + ''.join(open(os.path.join(ZL, f)).read() + '\n' if f != 'consts.zl' else consts + '\n'
                                               for f in files)

    cfg, size, c = zpaqlc.compile_source(source(('pjadec.zl', 'consts.zl', 'model.zl', 'huff.zl')), NAME, PH, '$1+1')
    inc = ['{ Generated by tools/zpaql/gen_pjadec.py from pas/plugin/zpaql/*.zl: do not edit.',
           '  %d bytes of PCOMP. }' % size,
           'const',
           '  { the words of H the decoder takes for its variables and tables; and',
           '    for each band, two models with their mixers. Its config sizes H with',
           '    $3, which the plugin\'s query gives for each block }',
           '  ZPAQL_STATIC_WORDS = %d;' % c.hwords,
           '  ZPAQL_MODEL_WORDS = %d;' % model_words,
           '  PJA_ZPAQL: AnsiString =', chunked(cfg)]
    inc = '\n'.join(inc) + '\n'
    ipath = os.path.join(PAS, 'plugin', 'pjazpaql.inc')

    jsrc = source(('pjadec.zl', 'consts.zl', 'model.zl', 'jls.zl'))
    sym, band = jls_words(open(os.path.join(ZL, 'jls.zl')).read())
    lcfg, lsize, lc = zpaqlc.compile_source(jsrc, LS_NAME, PH, '$1+1')
    linc = ['{ Generated by tools/zpaql/gen_pjadec.py from pas/plugin/zpaql/*.zl: do not edit.',
            '  %d bytes of PCOMP. }' % lsize,
            'const',
            '  { the words of H the JPEG-LS decoder takes for its variables and',
            '    tables, for the symbols model, and for each band of the samples',
            '    model besides its rows of residuals (pjazpaqlargs.ZpaqlJlsWords) }',
            '  ZPAQL_LS_STATIC_WORDS = %d;' % lc.hwords,
            '  ZPAQL_LS_SYM_WORDS = %d;' % sym,
            '  ZPAQL_LS_BAND_WORDS = %d;' % band,
            '  PJALS_ZPAQL: AnsiString =', chunked(lcfg)]
    linc = '\n'.join(linc) + '\n'
    lpath = os.path.join(PAS, 'plugin', 'pjalszpaql.inc')

    xcfg, xsize, xc = zpaqlc.compile_source(source(('pjadec.zl', 'consts.zl', 'model.zl', 'huff.zl', 'pjax.zl'), 1),
                                            X_NAME, PH, '$1+1')
    xinc = ['{ Generated by tools/zpaql/gen_pjadec.py from pas/plugin/zpaql/*.zl: do not edit.',
            '  %d bytes of PCOMP. }' % xsize,
            'const',
            '  { the words of H the pjax decoder takes for its variables and tables;',
            '    each JPEG it decodes takes what pja\'s would besides',
            '    (pjazpaqlargs.ZpaqlPjaxWords) }',
            '  ZPAQL_X_STATIC_WORDS = %d;' % xc.hwords,
            '  PJAX_ZPAQL: AnsiString =', chunked(xcfg)]
    xinc = '\n'.join(xinc) + '\n'
    xpath = os.path.join(PAS, 'plugin', 'pjaxzpaql.inc')

    llcfg, llsize, llc = zpaqlc.compile_source(source(('pjadec.zl', 'consts.zl', 'model.zl', 'jls.zl', 'ljpeg.zl'), 0, 1),
                                               LL_NAME, PH, '$1+1')
    llinc = ['{ Generated by tools/zpaql/gen_pjadec.py from pas/plugin/zpaql/*.zl: do not edit.',
             '  %d bytes of PCOMP. }' % llsize,
             'const',
             '  { the words of H the pjall decoder takes for its variables and tables;',
             '    each band of its samples model takes ZPAQL_LS_BAND_WORDS besides',
             '    its rows of residuals (pjazpaqlargs.ZpaqlLjpegWords) }',
             '  ZPAQL_LL_STATIC_WORDS = %d;' % llc.hwords,
             '  PJALL_ZPAQL: AnsiString =', chunked(llcfg)]
    llinc = '\n'.join(llinc) + '\n'
    llpath = os.path.join(PAS, 'plugin', 'pjallzpaql.inc')

    outs = ((cpath, consts), (ipath, inc), (lpath, linc), (xpath, xinc), (llpath, llinc))
    if check:
        stale = [p for p, t in outs if not os.path.exists(p) or open(p).read() != t]
        if stale:
            print('gen_pjadec: not up to date: ' + ', '.join(os.path.relpath(p, REPO) for p in stale))
            sys.exit(1)
        print('ZPAQL decoders up to date: %d, %d, %d and %d bytes of PCOMP' % (size, lsize, xsize, llsize))
        return
    for p, t in outs:
        open(p, 'w').write(t)
    print('%s: %d bytes of PCOMP, %d static words of H, %d words per model' % (os.path.relpath(ipath, REPO), size, c.hwords, model_words))
    print('%s: %d bytes of PCOMP, %d static words of H' % (os.path.relpath(lpath, REPO), lsize, lc.hwords))
    print('%s: %d bytes of PCOMP, %d static words of H' % (os.path.relpath(xpath, REPO), xsize, xc.hwords))
    print('%s: %d bytes of PCOMP, %d static words of H' % (os.path.relpath(llpath, REPO), llsize, llc.hwords))


if __name__ == '__main__':
    build('--check' in sys.argv[1:])

#!/usr/bin/env python3
"""zpaqlc against exact 32-bit arithmetic: random expressions, and
hand-written programs for control flow, calls, arrays and signed helpers.
Each program runs in zpaqlvm."""
import random, sys
import zpaqlc, zpaqlvm

M32 = 0xFFFFFFFF
fails = 0
cells = 0


def run(src, segment=b''):
    cfg, size, _ = zpaqlc.compile_source(src, 'test', '16', '16')
    out, steps, _ = zpaqlvm.run_config(cfg, segment, [])
    return out


def word_bytes(vals):
    return b''.join(v.to_bytes(4, 'little') for v in vals)


def check(what, got, want):
    global fails, cells
    cells += 1
    if got != want:
        fails += 1
        print('FAIL', what)
        print('  got ', got[:64])
        print('  want', want[:64])


# --- random expressions -------------------------------------------------

OPS = ['+', '-', '*', '//', '%', '&', '|', '^', '<<', '>>']
CMPS = ['==', '!=', '<', '<=', '>', '>=']


def rnd_const(r):
    k = r.choice([0, 1, 2, 7, 255, 256, 1000, 65535, 0x7FFFFFFF, 0x80000000, M32,
                  r.randrange(0, 256), r.randrange(0, 1 << 32)])
    return k


def gen(r, depth, vars_):
    if depth == 0 or r.random() < 0.25:
        if r.random() < 0.5:
            k = rnd_const(r)
            return str(k), k
        v = r.choice(list(vars_))
        return v, vars_[v]
    kind = r.random()
    if kind < 0.7:
        op = r.choice(OPS)
        ls, lv = gen(r, depth - 1, vars_)
        rs, rv = gen(r, depth - 1, vars_)
        if op == '+': v = lv + rv
        elif op == '-': v = lv - rv
        elif op == '*': v = lv * rv
        elif op == '//': v = lv // rv if rv else 0
        elif op == '%': v = lv % rv if rv else 0
        elif op == '&': v = lv & rv
        elif op == '|': v = lv | rv
        elif op == '^': v = lv ^ rv
        elif op == '<<': v = lv << (rv & 31)
        else: v = lv >> (rv & 31)
        return '(%s %s %s)' % (ls, op, rs), v & M32
    if kind < 0.8:
        s, v = gen(r, depth - 1, vars_)
        if r.random() < 0.5:
            return '(~%s)' % s, (~v) & M32
        return '(-%s)' % s, (-v) & M32
    if kind < 0.9:
        op = r.choice(CMPS)
        ls, lv = gen(r, depth - 1, vars_)
        rs, rv = gen(r, depth - 1, vars_)
        v = {'==': lv == rv, '!=': lv != rv, '<': lv < rv, '<=': lv <= rv,
             '>': lv > rv, '>=': lv >= rv}[op]
        return '(1 if %s %s %s else 0)' % (ls, op, rs), int(v)
    # signed comparison
    op = r.choice(['slt', 'sle', 'sgt', 'sge'])
    ls, lv = gen(r, depth - 1, vars_)
    rs, rv = gen(r, depth - 1, vars_)
    sl = lv - (1 << 32) if lv >> 31 else lv
    sr = rv - (1 << 32) if rv >> 31 else rv
    v = {'slt': sl < sr, 'sle': sl <= sr, 'sgt': sl > sr, 'sge': sl >= sr}[op]
    return '(1 if %s(%s, %s) else 0)' % (op, ls, rs), int(v)


def put32(name):
    return ('    out(%s)\n    out(%s >> 8)\n    out(%s >> 16)\n    out(%s >> 24)\n' % (name, name, name, name))


r = random.Random(1)
for prog in range(60):
    vars_ = {'x%d' % i: rnd_const(r) for i in range(4)}
    lines = ['def main():']
    for k, v in vars_.items():
        lines.append('    %s = %d' % (k, v))
    want = []
    for e in range(12):
        s, v = gen(r, r.randrange(1, 6), vars_)
        lines.append('    t = %s' % s)
        lines.append(put32('t').rstrip('\n'))
        want.append(v)
    src = '\n'.join(lines) + '\n'
    check('random expressions %d' % prog, run(src), word_bytes(want))

# --- control flow, calls, arrays, signed ---------------------------------

src = '''
N = 300
buf = array(N)
def sq(x):
    return x * x
def fib(n):
    a = 0
    b = 1
    for i in range(n):
        t = a + b
        a = b
        b = t
    return a
def sabs(x):
    if slt(x, 0):
        return -x
    return x
def sdiv(a, b):
    q = sabs(a) // sabs(b)
    if slt(a ^ b, 0):
        return -q
    return q
def main():
    for i in range(N):
        buf[i] = sq(i) + fib(i % 40)
    s = 0
    i = 0
    while True:
        if i >= N:
            break
        if i % 3 == 0:
            i += 1
            continue
        s = s + buf[i]
        i += 1
    out(s)
    out(s >> 8)
    out(s >> 16)
    out(s >> 24)
    out(sdiv(-17, 5))
    out(sdiv(17, -5))
    out(sdiv(-17, -5))
    out(sar(-16, 2))
    out(sar(16, 2))
    out(sar(0x80000000, 31))
    k = inlen()
    out(k)
    for j in range(k):
        out(M[j] + 1)
'''
def fibp(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
buf = [(i * i + fibp(i % 40)) & M32 for i in range(300)]
s = sum(buf[i] for i in range(300) if i % 3 != 0) & M32
seg = bytes([5, 6, 7, 250])
want = word_bytes([s]) + bytes([(-3) & 255, (-3) & 255, 3, (-4) & 255, 4, 255, 4, 6, 7, 8, 251])
check('control flow, calls, arrays, signed', run(src, seg), want)

# a program big enough for long jumps and many temps
lines = ['def main():', '    s = 0']
want_s = 0
for i in range(400):
    lines.append('    if s %% 7 == %d:' % (i % 7))
    lines.append('        s = s * 3 + %d' % i)
    lines.append('    else:')
    lines.append('        s = s + %d' % (i * 1000))
    if want_s % 7 == i % 7:
        want_s = (want_s * 3 + i) & M32
    else:
        want_s = (want_s + i * 1000) & M32
lines.append(put32('s').rstrip('\n'))
check('long program, long jumps', run('\n'.join(lines) + '\n'), word_bytes([want_s]))

# more variables than R holds: spills to H
lines = ['def main():']
names = ['v%d' % i for i in range(300)]
for i, n in enumerate(names):
    lines.append('    %s = %d' % (n, i * 7 + 1))
lines.append('    s = 0')
for n in names:
    lines.append('    s = s + %s * 3' % n)
lines.append(put32('s').rstrip('\n'))
want_s = sum((i * 7 + 1) * 3 for i in range(300)) & M32
check('variables spilled to H', run('\n'.join(lines) + '\n'), word_bytes([want_s]))

# constants above 255 as right operands and as stored values
src = '''
BIG = 70000
OFF = 300
buf = array(400)
def main():
    x = 5
    y = x + BIG
    buf[x + OFF] = BIG
    z = buf[x + OFF] + OFF
    out(y)
    out(y >> 8)
    out(y >> 16)
    out(z)
    out(z >> 8)
    out(z >> 16)
'''
check('big constants as operands', run(src), bytes([(70005) & 255, (70005 >> 8) & 255, 70005 >> 16, 70300 & 255, (70300 >> 8) & 255, 70300 >> 16]))

# temporaries spilled to H once R is full, with arrays in use: they must
# not overlap
lines = ['buf = array(64)', 'def main():', '    for i in range(64):', '        buf[i] = i * 3']
for i in range(260):
    lines.append('    v%d = %d' % (i, i))
lines.append('    s = 0')
for i in range(260):
    lines.append('    s = s + ((v%d + (v%d * 3 + (buf[%d] + 1))) ^ v%d)' % (i, i, i % 64, (i + 1) % 260))
lines.append('    for i in range(64):')
lines.append('        s = s + buf[i]')
lines.append(put32('s').rstrip('\n'))
want_s = 0
for i in range(260):
    want_s = (want_s + ((i + (i * 3 + ((i % 64) * 3 + 1))) ^ ((i + 1) % 260))) & M32
want_s = (want_s + sum(i * 3 for i in range(64))) & M32
check('temporaries in H next to arrays', run('\n'.join(lines) + '\n'), word_bytes([want_s]))

# heap() goes after every array, even ones declared after it
src = '''
first = array(10)
HEAPA = heap()
later = array(10)
def main():
    for i in range(10):
        later[i] = 7
    H[base(HEAPA)] = 99
    s = 0
    for i in range(10):
        s = s + later[i]
    out(s)
    out(H[base(HEAPA)])
    out(1 if base(HEAPA) >= base(later) + 10 else 0)
'''
check('heap after every array', run(src), bytes([70, 99, 1]))

# tables: words set at the start
src = '''
t = table([1, 300, 70000, 4294967295, 0, 255])
u = table([9, 8])
def main():
    for i in range(6):
        v = t[i]
        out(v)
        out(v >> 8)
        out(v >> 16)
        out(v >> 24)
    out(u[0] + u[1])
    H[base(u) + 1] = 30
    out(u[1])
'''
check('tables', run(src), word_bytes([1, 300, 70000, 4294967295, 0, 255]) + bytes([17, 30]))

print('%d cells, %d failures' % (cells, fails))
sys.exit(1 if fails else 0)

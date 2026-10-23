#!/usr/bin/env python3
"""A ZPAQL interpreter for testing PCOMP programs: libzpaq's semantics
(ZPAQL::execute in zpaq-std.cpp), one instruction at a time.

    zpaqlvm.py <config> <segment> <output> [arg1 arg2 ...]

Runs the config's PCOMP section on every byte of <segment>, then once more
with 2^32-1 (the end), and writes what OUT produced. $1..$9 in the config
take the given numbers (zpaq-std passes log2 of the segment and of the
original size, rounded up). Also usable as a module (assemble, run)."""
import sys

OPCODES = [
"error","a++",  "a--",  "a!",   "a=0",  "",     "",     "a=r",
"b<>a", "b++",  "b--",  "b!",   "b=0",  "",     "",     "b=r",
"c<>a", "c++",  "c--",  "c!",   "c=0",  "",     "",     "c=r",
"d<>a", "d++",  "d--",  "d!",   "d=0",  "",     "",     "d=r",
"*b<>a","*b++", "*b--", "*b!",  "*b=0", "",     "",     "jt",
"*c<>a","*c++", "*c--", "*c!",  "*c=0", "",     "",     "jf",
"*d<>a","*d++", "*d--", "*d!",  "*d=0", "",     "",     "r=a",
"halt", "out",  "",     "hash", "hashd","",     "",     "jmp",
"a=a",  "a=b",  "a=c",  "a=d",  "a=*b", "a=*c", "a=*d", "a=",
"b=a",  "b=b",  "b=c",  "b=d",  "b=*b", "b=*c", "b=*d", "b=",
"c=a",  "c=b",  "c=c",  "c=d",  "c=*b", "c=*c", "c=*d", "c=",
"d=a",  "d=b",  "d=c",  "d=d",  "d=*b", "d=*c", "d=*d", "d=",
"*b=a", "*b=b", "*b=c", "*b=d", "*b=*b","*b=*c","*b=*d","*b=",
"*c=a", "*c=b", "*c=c", "*c=d", "*c=*b","*c=*c","*c=*d","*c=",
"*d=a", "*d=b", "*d=c", "*d=d", "*d=*b","*d=*c","*d=*d","*d=",
"",     "",     "",     "",     "",     "",     "",     "",
"a+=a", "a+=b", "a+=c", "a+=d", "a+=*b","a+=*c","a+=*d","a+=",
"a-=a", "a-=b", "a-=c", "a-=d", "a-=*b","a-=*c","a-=*d","a-=",
"a*=a", "a*=b", "a*=c", "a*=d", "a*=*b","a*=*c","a*=*d","a*=",
"a/=a", "a/=b", "a/=c", "a/=d", "a/=*b","a/=*c","a/=*d","a/=",
"a%=a", "a%=b", "a%=c", "a%=d", "a%=*b","a%=*c","a%=*d","a%=",
"a&=a", "a&=b", "a&=c", "a&=d", "a&=*b","a&=*c","a&=*d","a&=",
"a&~a", "a&~b", "a&~c", "a&~d", "a&~*b","a&~*c","a&~*d","a&~",
"a|=a", "a|=b", "a|=c", "a|=d", "a|=*b","a|=*c","a|=*d","a|=",
"a^=a", "a^=b", "a^=c", "a^=d", "a^=*b","a^=*c","a^=*d","a^=",
"a<<=a","a<<=b","a<<=c","a<<=d","a<<=*b","a<<=*c","a<<=*d","a<<=",
"a>>=a","a>>=b","a>>=c","a>>=d","a>>=*b","a>>=*c","a>>=*d","a>>=",
"a==a", "a==b", "a==c", "a==d", "a==*b","a==*c","a==*d","a==",
"a<a",  "a<b",  "a<c",  "a<d",  "a<*b", "a<*c", "a<*d", "a<",
"a>a",  "a>b",  "a>c",  "a>d",  "a>*b", "a>*c", "a>*d", "a>",
"",     "",     "",     "",     "",     "",     "",     "",
"",     "",     "",     "",     "",     "",     "",     "lj"]
OP = {name: i for i, name in enumerate(OPCODES) if name}
M32 = 0xFFFFFFFF


class ConfigError(Exception):
    pass


def tokens(text):
    """Whitespace-separated tokens, (nested comments) skipped."""
    out, depth, cur = [], 0, ''
    for ch in text:
        if ch == '(':
            depth += 1
            if cur:
                out.append(cur); cur = ''
        elif ch == ')' and depth > 0:
            depth -= 1
        elif depth > 0:
            continue
        elif ch <= ' ':
            if cur:
                out.append(cur); cur = ''
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def subst(tok, args):
    """$n and $n+k with args; anything else as is."""
    if tok.startswith('$') and len(tok) >= 2 and tok[1].isdigit():
        n = int(tok[1]); rest = tok[2:]
        v = args[n - 1] if n - 1 < len(args) else 0
        if rest.startswith('+'):
            v += int(rest[1:])
        return str(v)
    return tok


def assemble(code_tokens):
    """PCOMP/HCOMP tokens (after the section keyword) to bytecode, with
    libzpaq's if/else/endif/do/while/until/forever macros and their long
    forms."""
    hdr = []
    if_stack, do_stack = [], []
    i = 0
    toks = code_tokens
    while i < len(toks):
        t = toks[i].lower(); i += 1
        if t in ('end', 'post', 'pcomp'):
            break
        operand = operand2 = None
        if t == 'if':
            op = OP['jf']; operand = 0; if_stack.append(len(hdr) + 1)
        elif t == 'ifnot':
            op = OP['jt']; operand = 0; if_stack.append(len(hdr) + 1)
        elif t in ('ifl', 'ifnotl'):
            hdr += [OP['jt'] if t == 'ifl' else OP['jf'], 3]
            op = OP['lj']; operand = operand2 = 0; if_stack.append(len(hdr) + 1)
        elif t in ('else', 'elsel'):
            if t == 'else':
                op = OP['jmp']; operand = 0
            else:
                op = OP['lj']; operand = operand2 = 0
            a = if_stack.pop()
            if hdr[a - 1] != OP['lj']:
                j = (len(hdr) - a) + 1 + (op == OP['lj'])
                if j > 127:
                    raise ConfigError('IF too big')
                hdr[a] = j
            else:
                j = len(hdr) + 2 + (op == OP['lj'])
                hdr[a] = j & 255; hdr[a + 1] = j >> 8
            if_stack.append(len(hdr) + 1)
        elif t == 'endif':
            a = if_stack.pop()
            j = len(hdr) - a - 1
            if hdr[a - 1] != OP['lj']:
                if j > 127:
                    raise ConfigError('IF too big')
                hdr[a] = j
            else:
                j = len(hdr)
                hdr[a] = j & 255; hdr[a + 1] = j >> 8
            continue
        elif t == 'do':
            do_stack.append(len(hdr)); continue
        elif t in ('while', 'until', 'forever'):
            a = do_stack.pop()
            j = a - len(hdr) - 2
            if j >= -127:
                op = {'while': OP['jt'], 'until': OP['jf'], 'forever': OP['jmp']}[t]
                operand = j & 255
            else:
                if t == 'while':
                    hdr += [OP['jf'], 3]
                if t == 'until':
                    hdr += [OP['jt'], 3]
                op = OP['lj']; operand = a & 255; operand2 = a >> 8
        else:
            if t not in OP:
                raise ConfigError('unknown instruction ' + t)
            op = OP[t]
            if op & 7 == 7:
                n = int(toks[i]); i += 1
                if op == OP['lj']:
                    if not 0 <= n <= 65535:
                        raise ConfigError('lj out of range')
                    operand, operand2 = n & 255, n >> 8
                elif op in (OP['jt'], OP['jf'], OP['jmp']):
                    if not -128 <= n <= 127:
                        raise ConfigError('jump out of range')
                    operand = n & 255
                else:
                    if not 0 <= n <= 255:
                        raise ConfigError('operand out of range')
                    operand = n
        hdr.append(op)
        if operand is not None:
            hdr.append(operand)
        if operand2 is not None:
            hdr.append(operand2)
    if len(hdr) > 65535:
        raise ConfigError('program too big: %d bytes' % len(hdr))
    return hdr


def parse_config(text, args):
    """(ph, pm, pcomp bytecode) of a config."""
    toks = [subst(t, args) for t in tokens(text)]
    if toks[0].lower() != 'comp':
        raise ConfigError('expected comp')
    hh, hm, ph, pm, n = (int(x) for x in toks[1:6])
    i = 6
    # skip n component lines: we only run PCOMP; find 'pcomp'
    low = [t.lower() for t in toks]
    if 'pcomp' not in low:
        raise ConfigError('no pcomp')
    p = low.index('pcomp')
    # pcomp <command...> ; code end
    j = low.index(';', p)
    code = assemble(toks[j + 1:])
    return ph, pm, code


class VM:
    def __init__(self, code, ph, pm):
        self.code = code
        self.h = [0] * (1 << ph); self.hmask = (1 << ph) - 1
        self.m = bytearray(1 << pm); self.mmask = (1 << pm) - 1
        self.r = [0] * 256
        self.a = self.b = self.c = self.d = 0
        self.f = 0
        self.out = bytearray()
        self.steps = 0

    def run(self, inp):
        code = self.code; h = self.h; m = self.m; r = self.r
        hm = self.hmask; mm = self.mmask
        a, b, c, d, f = inp & M32, self.b, self.c, self.d, self.f
        pc = 0; steps = 0
        out = self.out
        while True:
            op = code[pc]; pc += 1; steps += 1
            if op < 64:
                if op == 0: raise RuntimeError('ZPAQL error instruction at %d' % (pc - 1))
                elif op == 1: a = (a + 1) & M32
                elif op == 2: a = (a - 1) & M32
                elif op == 3: a = (~a) & M32
                elif op == 4: a = 0
                elif op == 7: a = r[code[pc]]; pc += 1
                elif op == 8: a, b = b, a
                elif op == 9: b = (b + 1) & M32
                elif op == 10: b = (b - 1) & M32
                elif op == 11: b = (~b) & M32
                elif op == 12: b = 0
                elif op == 15: b = r[code[pc]]; pc += 1
                elif op == 16: a, c = c, a
                elif op == 17: c = (c + 1) & M32
                elif op == 18: c = (c - 1) & M32
                elif op == 19: c = (~c) & M32
                elif op == 20: c = 0
                elif op == 23: c = r[code[pc]]; pc += 1
                elif op == 24: a, d = d, a
                elif op == 25: d = (d + 1) & M32
                elif op == 26: d = (d - 1) & M32
                elif op == 27: d = (~d) & M32
                elif op == 28: d = 0
                elif op == 31: d = r[code[pc]]; pc += 1
                elif op == 32: a = self._swapm(a, b, mm)
                elif op == 33: m[b & mm] = (m[b & mm] + 1) & 255
                elif op == 34: m[b & mm] = (m[b & mm] - 1) & 255
                elif op == 35: m[b & mm] = (~m[b & mm]) & 255
                elif op == 36: m[b & mm] = 0
                elif op == 39:
                    if f: pc += ((code[pc] + 128) & 255) - 127
                    else: pc += 1
                elif op == 40: a = self._swapm(a, c, mm)
                elif op == 41: m[c & mm] = (m[c & mm] + 1) & 255
                elif op == 42: m[c & mm] = (m[c & mm] - 1) & 255
                elif op == 43: m[c & mm] = (~m[c & mm]) & 255
                elif op == 44: m[c & mm] = 0
                elif op == 47:
                    if not f: pc += ((code[pc] + 128) & 255) - 127
                    else: pc += 1
                elif op == 48: a, h[d & hm] = h[d & hm], a
                elif op == 49: h[d & hm] = (h[d & hm] + 1) & M32
                elif op == 50: h[d & hm] = (h[d & hm] - 1) & M32
                elif op == 51: h[d & hm] = (~h[d & hm]) & M32
                elif op == 52: h[d & hm] = 0
                elif op == 55: r[code[pc]] = a; pc += 1
                elif op == 56: break
                elif op == 57: out.append(a & 255)
                elif op == 59: a = ((a + m[b & mm] + 512) * 773) & M32
                elif op == 60: h[d & hm] = ((h[d & hm] + a + 512) * 773) & M32
                elif op == 63: pc += ((code[pc] + 128) & 255) - 127
                else: raise RuntimeError('bad opcode %d' % op)
                continue
            if op < 128:
                # moves: dst = op>>3 & 7 (8 a,9 b,10 c,11 d,12 *b,13 *c,14 *d), src = op & 7
                src = op & 7
                if src == 0: v = a
                elif src == 1: v = b
                elif src == 2: v = c
                elif src == 3: v = d
                elif src == 4: v = m[b & mm]
                elif src == 5: v = m[c & mm]
                elif src == 6: v = h[d & hm]
                else: v = code[pc]; pc += 1
                dst = op >> 3
                if dst == 8: a = v
                elif dst == 9: b = v
                elif dst == 10: c = v
                elif dst == 11: d = v
                elif dst == 12: m[b & mm] = v & 255
                elif dst == 13: m[c & mm] = v & 255
                elif dst == 14: h[d & hm] = v
                else: raise RuntimeError('bad opcode %d' % op)
                continue
            if op == 255:
                pc = code[pc] + 256 * code[pc + 1]
                if pc >= len(code): raise RuntimeError('lj out of program')
                continue
            src = op & 7
            if src == 0: v = a
            elif src == 1: v = b
            elif src == 2: v = c
            elif src == 3: v = d
            elif src == 4: v = m[b & mm]
            elif src == 5: v = m[c & mm]
            elif src == 6: v = h[d & hm]
            else: v = code[pc]; pc += 1
            g = op >> 3
            if g == 16: a = (a + v) & M32
            elif g == 17: a = (a - v) & M32
            elif g == 18: a = (a * v) & M32
            elif g == 19: a = a // v if v else 0
            elif g == 20: a = a % v if v else 0
            elif g == 21: a &= v
            elif g == 22: a &= ~v & M32
            elif g == 23: a |= v
            elif g == 24: a ^= v
            elif g == 25: a = (a << (v & 31)) & M32
            elif g == 26: a >>= (v & 31)
            elif g == 27: f = int(a == v)
            elif g == 28: f = int(a < v)
            elif g == 29: f = int(a > v)
            else: raise RuntimeError('bad opcode %d' % op)
        self.a, self.b, self.c, self.d, self.f = a, b, c, d, f
        self.steps += steps

    @staticmethod
    def _swapm(a, x, mm):
        raise NotImplementedError


def _swapm_factory(vm):
    def swapm(a, x, mm):
        t = vm.m[x & mm]
        vm.m[x & mm] = a & 255
        return (a & ~255 & M32) | t
    return swapm


def run_config(text, segment, args, max_ph=None):
    """max_ph caps H for tests: a program that never reaches past 2^max_ph
    words runs the same in less memory."""
    ph, pm, code = parse_config(text, args)
    if max_ph is not None:
        ph = min(ph, max_ph)
    vm = VM(code, ph, pm)
    vm._swapm = _swapm_factory(vm)
    for byte in segment:
        vm.run(byte)
    vm.run(M32)
    return bytes(vm.out), vm.steps, len(code)


if __name__ == '__main__':
    cfg, seg, outp = sys.argv[1:4]
    args = [int(x) for x in sys.argv[4:]]
    out, steps, size = run_config(open(cfg).read(), open(seg, 'rb').read(), args)
    open(outp, 'wb').write(out)
    print('%d bytes out, %d instructions run, program %d bytes' % (len(out), steps, size))

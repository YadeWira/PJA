#!/usr/bin/env python3
"""zpaqlc: a small language compiled to a ZPAQL PCOMP program.

    zpaqlc.py <source.zl> <out.cfg> [--name NAME] [--ph PH] [--pm PM]

The source is a subset of Python, read with the ast module:

  - every value is a 32-bit unsigned integer; + - * // % & | ^ << >> ~ and
    the comparisons are ZPAQL's (unsigned, wrapping, x // 0 = x % 0 = 0,
    shifts by n & 31). -x is 0 - x.
  - signed helpers: slt sle sgt sge (comparisons), sar (arithmetic shift);
    anything else signed is written in the language itself (a prelude).
  - top level: NAME = <constant expression> (ALL_CAPS: a constant),
    name = <constant> (a global), name = array(N) (N words of H),
    name = table([...]) (words of H set to those constants at the start),
    name = heap() (the rest of H, after every array, wherever declared),
    def f(...): ... (no recursion), and def main(): (run at the end).
  - statements: assignment, augmented assignment, if/elif/else, while,
    for i in range(...), break, continue, return, pass, a call.
  - H[i] and M[i]: the machine's arrays; arr[i] is H[base(arr) + i].
    M[0 ..] holds the segment as it came; inlen() is its length.
    base(arr) is arr's first word in H, for code that takes addresses.
    out(x) writes the byte x; error() stops with a ZPAQL error.
    reset(n) ends the segment so that the next one starts as the first
    did: H[0 .. n) and every R register in use back to zero (n is past
    the last word the program used: its heap pointer), then halt. libzpaq
    keeps H, M and R from one segment of a block to the next.

Variables live in R, or in H when R is full: each function has its own
fixed places (no recursion, so nothing needs a stack). A call stores a
call-site number, long-jumps to the function and comes back through a
comparison chain on that number."""
import ast, sys

M32 = 0xFFFFFFFF


class CompileError(Exception):
    pass


def err(node, msg):
    raise CompileError('line %s: %s' % (getattr(node, 'lineno', '?'), msg))


# ---------------------------------------------------------------- emitter

class Asm:
    """Instructions with symbolic jumps; relaxed to short or long forms."""
    def __init__(self):
        self.items = []       # ('i', text, size) | ('label', name) | ('j', kind, label)
        self.nlabel = 0

    def label(self):
        self.nlabel += 1
        return 'L%d' % self.nlabel

    def put(self, name):
        self.items.append(('label', name))

    def op(self, text):
        t = text.split()
        size = 2 if len(t) == 2 else 1
        self.items.append(('i', text, size))

    def jmp(self, kind, label):     # kind: 'jt' 'jf' 'jmp'
        self.items.append(('j', kind, label))

    def assemble(self):
        # sizes: short jump 2, long: jmp -> lj (3), jt/jf -> inverse 2 + lj 3
        long_ = {}
        while True:
            addr, pos = 0, {}
            for k, it in enumerate(self.items):
                if it[0] == 'label':
                    pos[it[1]] = addr
                elif it[0] == 'i':
                    addr += it[2]
                else:
                    addr += (3 if it[1] == 'jmp' else 5) if long_.get(k) else 2
            changed = False
            addr = 0
            for k, it in enumerate(self.items):
                if it[0] == 'label':
                    continue
                if it[0] == 'i':
                    addr += it[2]; continue
                size = (3 if it[1] == 'jmp' else 5) if long_.get(k) else 2
                if not long_.get(k):
                    off = pos[it[2]] - (addr + 2)
                    if not -128 <= off <= 127:
                        long_[k] = True; changed = True
                addr += size
            if not changed:
                break
        out, addr = [], 0
        for k, it in enumerate(self.items):
            if it[0] == 'label':
                continue
            if it[0] == 'i':
                out.append(it[1]); addr += it[2]; continue
            kind, lab = it[1], it[2]
            if long_.get(k):
                if kind == 'jmp':
                    out.append('lj %d' % pos[lab]); addr += 3
                else:
                    out.append(('jf 3' if kind == 'jt' else 'jt 3'))
                    out.append('lj %d' % pos[lab]); addr += 5
            else:
                out.append('%s %d' % (kind, pos[lab] - (addr + 2))); addr += 2
        if addr > 65535:
            raise CompileError('program too big: %d bytes (ZPAQL allows 65535)' % addr)
        self.positions = pos
        return out, addr


# ---------------------------------------------------------------- storage

class Slot:
    def __init__(self, kind, n):
        self.kind, self.n = kind, n      # 'r' register n, 'h' word n of H

    def __repr__(self):
        return '%s%d' % self.kind, self.n


class Alloc:
    """R first (from RFIRST), then H words 0 .. HVARS - 1. The arrays
    start at HVARS: temporaries are given out while the functions are
    compiled, after the arrays have their places, so the variables need a
    region of their own."""
    RFIRST = 8          # R0: input length, R1..R7: the compiler's scratch
    HVARS = 8192
    def __init__(self):
        self.r = self.RFIRST
        self.h = 0

    def new(self):
        if self.r < 256:
            s = Slot('r', self.r); self.r += 1; return s
        if self.h >= self.HVARS:
            raise CompileError('more than %d variables in H' % self.HVARS)
        s = Slot('h', self.h); self.h += 1; return s


R_INLEN = 0
R_T1, R_T2, R_T3 = 1, 2, 3     # scratch the code generator uses between two instructions


class Func:
    def __init__(self, node):
        self.node = node
        self.name = node.name
        self.params = [a.arg for a in node.args.args]
        self.vars = {}        # name -> Slot
        self.temps = []       # Slots, reused by depth
        self.ret = None       # Slot: call-site number
        self.rv = None        # Slot: return value
        self.entry = None
        self.exit = None
        self.sites = []       # labels to come back to
        self.globals_decl = set()


class Compiler:
    def __init__(self, tree):
        self.asm = Asm()
        self.alloc = Alloc()
        self.consts = {}
        self.globals = {}     # name -> Slot
        self.ginit = {}       # name -> initial value
        self.arrays = {}      # name -> (base slot, size)
        self.hnext = 0        # H words given to arrays (after the variables)
        self.arr_order = []
        self.tables = {}      # name -> its initial words (table([...]))
        self.heap = None      # the array placed after all the others (heap())
        self.funcs = {}
        self.lreset = None    # where reset() goes, once something calls it
        self.loops = []
        self.cur = None
        self.collect(tree)

    # ----------------------------------------------------------- module

    def const_eval(self, node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value & M32 if node.value >= 0 else node.value & M32
        if isinstance(node, ast.Name) and node.id in self.consts:
            return self.consts[node.id]
        if isinstance(node, ast.UnaryOp):
            v = self.const_eval(node.operand)
            if isinstance(node.op, ast.USub): return (-v) & M32
            if isinstance(node.op, ast.Invert): return (~v) & M32
        if isinstance(node, ast.BinOp):
            a, b = self.const_eval(node.left), self.const_eval(node.right)
            ops = {ast.Add: lambda: a + b, ast.Sub: lambda: a - b, ast.Mult: lambda: a * b,
                   ast.FloorDiv: lambda: a // b if b else 0, ast.Mod: lambda: a % b if b else 0,
                   ast.BitAnd: lambda: a & b, ast.BitOr: lambda: a | b, ast.BitXor: lambda: a ^ b,
                   ast.LShift: lambda: a << (b & 31), ast.RShift: lambda: a >> (b & 31)}
            f = ops.get(type(node.op))
            if f:
                return f() & M32
        err(node, 'not a constant expression')

    def collect(self, tree):
        # the constants first, in any order: arrays and tables may use ones
        # defined further down (or in a file concatenated after)
        pending = [n for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1
                   and isinstance(n.targets[0], ast.Name) and n.targets[0].id.isupper()
                   and not (isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Name)
                            and n.value.func.id in ('array', 'table', 'heap'))]
        while pending:
            left = []
            for n in pending:
                try:
                    self.consts[n.targets[0].id] = self.const_eval(n.value)
                except CompileError:
                    left.append(n)
            if len(left) == len(pending):
                err(left[0], 'not a constant expression')
            pending = left
        for node in tree.body:
            if isinstance(node, ast.FunctionDef):
                if node.name in self.funcs:
                    err(node, 'function defined twice')
                self.funcs[node.name] = Func(node)
            elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                name = node.targets[0].id
                v = node.value
                if isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id == 'array':
                    self.arrays[name] = [None, self.const_eval(v.args[0])]
                    self.arr_order.append(name)
                elif isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id == 'heap':
                    if self.heap:
                        err(v, 'one heap() only')
                    self.heap = name
                    self.arrays[name] = [None, 0]
                elif isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id == 'table':
                    if not isinstance(v.args[0], (ast.List, ast.Tuple)):
                        err(v, 'table([...]) takes a list of constants')
                    vals = [self.const_eval(e) for e in v.args[0].elts]
                    self.arrays[name] = [None, len(vals)]
                    self.arr_order.append(name)
                    self.tables[name] = vals
                elif name.isupper():
                    pass       # already in self.consts
                else:
                    self.globals[name] = None
                    self.ginit[name] = self.const_eval(v)
            elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                pass   # a docstring
            else:
                err(node, 'only constants, globals, arrays and functions at top level')
        if 'main' not in self.funcs:
            raise CompileError('no main()')
        if self.heap:
            self.arr_order.append(self.heap)    # last, wherever it was declared
        for name in self.globals:
            self.globals[name] = self.alloc.new()
        for name in self.arr_order:
            self.arrays[name][0] = self.alloc.new()

    # ----------------------------------------------------------- frames

    def frame(self, f):
        """Places for a function's parameters, locals, return slots."""
        for fn in ast.walk(f.node):
            if isinstance(fn, ast.Global):
                f.globals_decl.update(fn.names)
        names = list(f.params)
        for fn in ast.walk(f.node):
            targets = []
            if isinstance(fn, ast.Assign):
                targets = fn.targets
            elif isinstance(fn, (ast.AugAssign,)):
                targets = [fn.target]
            elif isinstance(fn, ast.For):
                targets = [fn.target]
            for t in targets:
                if isinstance(t, ast.Name) and t.id not in f.globals_decl and t.id not in names:
                    if t.id in self.consts or t.id in self.arrays:
                        err(fn, 'assigning to a constant or an array: ' + t.id)
                    names.append(t.id)
        for n in names:
            f.vars[n] = self.alloc.new()
        f.ret = self.alloc.new()
        f.rv = self.alloc.new()
        f.entry = self.asm.label()
        f.exit = self.asm.label()

    def temp(self, depth):
        f = self.cur
        while len(f.temps) <= depth:
            f.temps.append(self.alloc.new())
        return f.temps[depth]

    # ----------------------------------------------------------- moves

    def const_a(self, k):
        k &= M32
        a = self.asm
        if k < 256:
            a.op('a= %d' % k); return
        if k == M32:
            a.op('a=0'); a.op('a!'); return
        bs = [(k >> s) & 255 for s in (24, 16, 8, 0)]
        i = 0
        while bs[i] == 0:
            i += 1
        a.op('a= %d' % bs[i])
        shift = 0
        for b in bs[i + 1:]:
            shift += 8
            if b:
                a.op('a<<= %d' % shift); a.op('a|= %d' % b); shift = 0
        if shift:
            a.op('a<<= %d' % shift)

    def d_to(self, n):
        """D := word n of H (clobbers A when n > 255)."""
        if n < 256:
            self.asm.op('d= %d' % n)
        else:
            self.const_a(n); self.asm.op('d=a')

    def hvar_base(self):
        return 0

    def load_a(self, s):
        if s.kind == 'r':
            self.asm.op('a=r %d' % s.n)
        else:
            self.d_to(s.n); self.asm.op('a=*d')

    def store_a(self, s):
        if s.kind == 'r':
            self.asm.op('r=a %d' % s.n)
        else:
            if s.n < 256:
                self.asm.op('d= %d' % s.n)
            else:
                self.asm.op('r=a %d' % R_T1); self.const_a(s.n); self.asm.op('d=a'); self.asm.op('a=r %d' % R_T1)
            self.asm.op('*d=a')

    def load_b(self, s):
        """B := slot (clobbers A when the slot is in H)."""
        if s.kind == 'r':
            self.asm.op('b=r %d' % s.n)
        else:
            self.d_to(s.n); self.asm.op('b=*d')

    # ----------------------------------------------------------- names

    def lookup(self, node, name):
        f = self.cur
        if f and name in f.vars and name not in f.globals_decl:
            return f.vars[name]
        if name in self.globals:
            return self.globals[name]
        err(node, 'unknown name ' + name)

    # ----------------------------------------------------------- expressions

    BINOPS = {ast.Add: 'a+=', ast.Sub: 'a-=', ast.Mult: 'a*=', ast.FloorDiv: 'a/=',
              ast.Mod: 'a%=', ast.BitAnd: 'a&=', ast.BitOr: 'a|=', ast.BitXor: 'a^=',
              ast.LShift: 'a<<=', ast.RShift: 'a>>='}

    def simple(self, node):
        """A value that can be loaded without touching other temps."""
        if isinstance(node, ast.Constant):
            return True
        if isinstance(node, ast.Name):
            return True
        return False

    def is_small_const(self, node):
        try:
            v = self.const_eval(node)
        except CompileError:
            return None
        return v if v < 256 else None

    def expr(self, node, depth=0):
        """Value of node into A."""
        a = self.asm
        try:
            v = self.const_eval(node)
            self.const_a(v)
            return
        except CompileError:
            pass
        if isinstance(node, ast.Name):
            self.load_a(self.lookup(node, node.id)); return
        if isinstance(node, ast.BinOp):
            op = self.BINOPS.get(type(node.op))
            if not op:
                err(node, 'operator not supported')
            k = self.is_small_const(node.right)
            if k is not None:
                self.expr(node.left, depth); a.op('%s %d' % (op, k)); return
            if isinstance(node.right, ast.Name) and node.right.id not in self.consts \
                    and self.lookup(node.right, node.right.id).kind == 'r' \
                    and not self.has_call(node.left):
                self.expr(node.left, depth)
                a.op('b=r %d' % self.lookup(node.right, node.right.id).n)
                a.op(op + 'b'); return
            t = self.temp(depth)
            self.expr(node.right, depth + 1); self.store_a(t)
            self.expr(node.left, depth + 1)
            if t.kind == 'r':
                a.op('b=r %d' % t.n)
            else:
                a.op('r=a %d' % R_T2); self.load_b(t); a.op('a=r %d' % R_T2)
            a.op(op + 'b'); return
        if isinstance(node, ast.UnaryOp):
            if isinstance(node.op, ast.Invert):
                self.expr(node.operand, depth); a.op('a!'); return
            if isinstance(node.op, ast.USub):
                self.expr(node.operand, depth); a.op('a!'); a.op('a++'); return
            if isinstance(node.op, ast.Not):
                self.bool_value(node, depth); return
            err(node, 'unary operator not supported')
        if isinstance(node, (ast.Compare, ast.BoolOp)):
            self.bool_value(node, depth); return
        if isinstance(node, ast.IfExp):
            lf, le = a.label(), a.label()
            self.branch_false(node.test, lf, depth)
            self.expr(node.body, depth); a.jmp('jmp', le)
            a.put(lf); self.expr(node.orelse, depth); a.put(le); return
        if isinstance(node, ast.Subscript):
            self.address(node, depth)          # D := address, or C for M
            if self.subscript_space(node) == 'M':
                a.op('a=*c')
            else:
                a.op('a=*d')
            return
        if isinstance(node, ast.Call):
            self.call(node, depth, want=True); return
        err(node, 'expression not supported: ' + type(node).__name__)

    def has_call(self, node):
        return any(isinstance(n, ast.Call) and not (isinstance(n.func, ast.Name) and n.func.id in ('slt', 'sle', 'sgt', 'sge'))
                   for n in ast.walk(node))

    def subscript_space(self, node):
        v = node.value
        if isinstance(v, ast.Name) and v.id in ('H', 'M'):
            return v.id
        if isinstance(v, ast.Name) and v.id in self.arrays:
            return 'A'
        err(node, 'not an array: ' + ast.dump(v))

    def address(self, node, depth):
        """D := the H address of node (C for M). Clobbers A and B."""
        a = self.asm
        space = self.subscript_space(node)
        idx = node.slice
        if space == 'A':
            base = self.arrays[node.value.id][0]
            self.expr(idx, depth)
            if base.kind == 'r':
                a.op('b=r %d' % base.n)
            else:
                a.op('r=a %d' % R_T2); self.load_b(base); a.op('a=r %d' % R_T2)
            a.op('a+=b'); a.op('d=a')
        elif space == 'H':
            self.expr(idx, depth); a.op('d=a')
        else:
            self.expr(idx, depth); a.op('c=a')

    def bool_value(self, node, depth):
        a = self.asm
        lf, le = a.label(), a.label()
        self.branch_false(node, lf, depth)
        a.op('a= 1'); a.jmp('jmp', le)
        a.put(lf); a.op('a=0'); a.put(le)

    # comparisons: F and its sense (True: F set means the condition holds)
    CMP = {ast.Eq: ('a==', True), ast.NotEq: ('a==', False), ast.Lt: ('a<', True),
           ast.Gt: ('a>', True), ast.LtE: ('a>', False), ast.GtE: ('a<', False)}
    SCMP = {'slt': ('a<', True), 'sgt': ('a>', True), 'sle': ('a>', False), 'sge': ('a<', False)}

    def flip_sign(self):
        """A ^= 2^31 (to compare signed values as unsigned ones)."""
        a = self.asm
        a.op('r=a %d' % R_T3); a.op('a= 128'); a.op('a<<= 24'); a.op('b=a'); a.op('a=r %d' % R_T3); a.op('a^=b')

    def cond(self, node, depth):
        """Sets F; returns its sense."""
        a = self.asm
        if isinstance(node, ast.Compare):
            if len(node.ops) != 1:
                err(node, 'chained comparisons not supported')
            op, sense = self.CMP[type(node.ops[0])]
            left, right = node.left, node.comparators[0]
            k = self.is_small_const(right)
            if k is not None:
                self.expr(left, depth); a.op('%s %d' % (op, k)); return sense
            t = self.temp(depth)
            self.expr(right, depth + 1); self.store_a(t)
            self.expr(left, depth + 1)
            if t.kind == 'r':
                a.op('b=r %d' % t.n)
            else:
                a.op('r=a %d' % R_T2); self.load_b(t); a.op('a=r %d' % R_T2)
            a.op(op + 'b'); return sense
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in self.SCMP:
            op, sense = self.SCMP[node.func.id]
            l, r = node.args
            t = self.temp(depth)
            self.expr(r, depth + 1); self.flip_sign(); self.store_a(t)
            self.expr(l, depth + 1); self.flip_sign()
            if t.kind == 'r':
                a.op('b=r %d' % t.n)
            else:
                a.op('r=a %d' % R_T2); self.load_b(t); a.op('a=r %d' % R_T2)
            a.op(op + 'b'); return sense
        self.expr(node, depth); a.op('a== 0'); return False

    def branch_false(self, node, lfalse, depth=0):
        """Falls through when node holds, jumps to lfalse otherwise."""
        a = self.asm
        if isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.And):
                for v in node.values:
                    self.branch_false(v, lfalse, depth)
            else:
                ltrue = a.label()
                for v in node.values[:-1]:
                    self.branch_true(v, ltrue, depth)
                self.branch_false(node.values[-1], lfalse, depth)
                a.put(ltrue)
            return
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            ltrue = a.label()
            self.branch_true(node.operand, lfalse, depth)
            return
        if isinstance(node, ast.Constant):
            if not node.value:
                a.jmp('jmp', lfalse)
            return
        sense = self.cond(node, depth)
        a.jmp('jf' if sense else 'jt', lfalse)

    def branch_true(self, node, ltrue, depth=0):
        a = self.asm
        if isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.Or):
                for v in node.values:
                    self.branch_true(v, ltrue, depth)
            else:
                lf = a.label()
                for v in node.values[:-1]:
                    self.branch_false(v, lf, depth)
                self.branch_true(node.values[-1], ltrue, depth)
                a.put(lf)
            return
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            self.branch_false(node.operand, ltrue, depth)
            return
        if isinstance(node, ast.Constant):
            if node.value:
                a.jmp('jmp', ltrue)
            return
        sense = self.cond(node, depth)
        a.jmp('jt' if sense else 'jf', ltrue)

    # ----------------------------------------------------------- calls

    def call(self, node, depth, want):
        a = self.asm
        if not isinstance(node.func, ast.Name):
            err(node, 'only plain calls')
        name = node.func.id
        args = node.args
        if name == 'out':
            self.expr(args[0], depth); a.op('out'); return
        if name == 'error':
            a.op('error'); return
        if name == 'inlen':
            a.op('a=r %d' % R_INLEN); return
        if name == 'reset':
            if len(args) != 1:
                err(node, 'reset() takes the end of the H in use')
            if self.lreset is None:
                self.lreset = a.label()
            self.expr(args[0], depth); a.op('d=a'); a.jmp('jmp', self.lreset); return
        if name == 'base':
            if len(args) != 1 or not isinstance(args[0], ast.Name) or args[0].id not in self.arrays:
                err(node, 'base() takes an array')
            self.load_a(self.arrays[args[0].id][0]); return
        if name == 'sar':
            t = self.temp(depth)
            self.expr(args[1], depth + 1); self.store_a(t)
            self.expr(args[0], depth + 1)
            lneg, lend = a.label(), a.label()
            a.op('r=a %d' % R_T1); a.op('a>>= 31'); a.op('a== 0')
            a.jmp('jf', lneg)
            a.op('a=r %d' % R_T1); self.load_b_keep(t); a.op('a>>=b'); a.jmp('jmp', lend)
            a.put(lneg)
            a.op('a=r %d' % R_T1); a.op('a!'); self.load_b_keep(t); a.op('a>>=b'); a.op('a!')
            a.put(lend); return
        if name in self.SCMP:
            self.bool_value(node, depth); return
        if name not in self.funcs:
            err(node, 'unknown function ' + name)
        f = self.funcs[name]
        if len(args) != len(f.params):
            err(node, '%s takes %d arguments' % (name, len(f.params)))
        if f is self.cur:
            err(node, 'recursion is not supported')
        if any(self.has_call(x) for x in args):
            ts = []
            for i, x in enumerate(args):
                t = self.temp(depth + i)
                self.expr(x, depth + len(args)); self.store_a(t); ts.append(t)
            for t, p in zip(ts, f.params):
                self.load_a(t); self.store_a(f.vars[p])
        else:
            for x, p in zip(args, f.params):
                self.expr(x, depth); self.store_a(f.vars[p])
        site = len(f.sites) + 1
        if site > 255:
            err(node, 'more than 255 calls to ' + name)
        back = a.label()
        f.sites.append(back)
        a.op('a= %d' % site); self.store_a(f.ret)
        a.jmp('jmp', f.entry)
        a.put(back)
        if want:
            self.load_a(f.rv)

    def load_b_keep(self, s):
        """B := slot, keeping A."""
        if s.kind == 'r':
            self.asm.op('b=r %d' % s.n)
        else:
            self.asm.op('r=a %d' % R_T2); self.load_b(s); self.asm.op('a=r %d' % R_T2)

    # ----------------------------------------------------------- statements

    def stmts(self, body):
        for s in body:
            self.stmt(s)

    def assign(self, target, value):
        a = self.asm
        if isinstance(target, ast.Name):
            if target.id in self.consts:
                err(target, 'assigning to a constant')
            self.expr(value); self.store_a(self.lookup(target, target.id)); return
        if isinstance(target, ast.Subscript):
            space = self.subscript_space(target)
            if self.simple(value) and not self.has_call(target.slice):
                self.address(target, 0)
                if space == 'M':
                    self.expr(value); a.op('*c=a')     # C holds the address
                else:
                    # D holds the address; loading a value from H would move D
                    if isinstance(value, ast.Name) and value.id not in self.consts \
                            and self.lookup(value, value.id).kind == 'h':
                        a.op('a=d'); a.op('r=a %d' % R_T1); self.expr(value)
                        a.op('r=a %d' % R_T2); a.op('a=r %d' % R_T1); a.op('d=a'); a.op('a=r %d' % R_T2)
                    else:
                        self.expr(value)
                    a.op('*d=a')
                return
            t = self.temp(0)
            self.expr(value, 1); self.store_a(t)
            self.address(target, 1)
            if space == 'M':
                self.load_a_keep_cd(t); a.op('*c=a')
            else:
                if t.kind == 'r':
                    a.op('a=r %d' % t.n)
                else:
                    a.op('a=d'); a.op('r=a %d' % R_T1); self.load_a(t); a.op('r=a %d' % R_T2)
                    a.op('a=r %d' % R_T1); a.op('d=a'); a.op('a=r %d' % R_T2)
                a.op('*d=a')
            return
        err(target, 'cannot assign to this')

    def load_a_keep_cd(self, s):
        if s.kind == 'r':
            self.asm.op('a=r %d' % s.n)
        else:
            self.asm.op('a=d'); self.asm.op('r=a %d' % R_T1)
            self.load_a(s); self.asm.op('r=a %d' % R_T2)
            self.asm.op('a=r %d' % R_T1); self.asm.op('d=a'); self.asm.op('a=r %d' % R_T2)

    def stmt(self, s):
        a = self.asm
        self.nline = getattr(self, 'nline', 0) + 1
        a.put('@%d:%d:%s' % (self.nline, s.lineno, self.cur.name if self.cur else ''))
        if isinstance(s, ast.Assign):
            if len(s.targets) != 1:
                err(s, 'one target per assignment')
            self.assign(s.targets[0], s.value); return
        if isinstance(s, ast.AugAssign):
            t = s.target
            if isinstance(t, ast.Subscript) and self.has_call(t.slice):
                err(s, 'a call inside an augmented index')
            self.assign(t, ast.BinOp(left=t, op=s.op, right=s.value, lineno=s.lineno)); return
        if isinstance(s, ast.If):
            lelse, lend = a.label(), a.label()
            self.branch_false(s.test, lelse)
            self.stmts(s.body)
            if s.orelse:
                a.jmp('jmp', lend)
                a.put(lelse); self.stmts(s.orelse); a.put(lend)
            else:
                a.put(lelse)
            return
        if isinstance(s, ast.While):
            ltop, lend = a.label(), a.label()
            a.put(ltop)
            self.branch_false(s.test, lend)
            self.loops.append((ltop, lend))
            self.stmts(s.body)
            self.loops.pop()
            a.jmp('jmp', ltop); a.put(lend); return
        if isinstance(s, ast.For):
            it = s.iter
            if not (isinstance(it, ast.Call) and isinstance(it.func, ast.Name) and it.func.id == 'range'):
                err(s, 'only for ... in range(...)')
            ar = it.args
            start, stop, step = (ast.Constant(0), ar[0], ast.Constant(1)) if len(ar) == 1 else \
                (ar[0], ar[1], ast.Constant(1)) if len(ar) == 2 else (ar[0], ar[1], ar[2])
            if self.const_eval(step) != 1:
                err(s, 'only step 1')
            var = s.target
            self.assign(var, start)
            ltop, lnext, lend = a.label(), a.label(), a.label()
            a.put(ltop)
            self.branch_false(ast.Compare(left=var, ops=[ast.Lt()], comparators=[stop], lineno=s.lineno), lend)
            self.loops.append((lnext, lend))
            self.stmts(s.body)
            self.loops.pop()
            a.put(lnext)
            self.assign(var, ast.BinOp(left=var, op=ast.Add(), right=ast.Constant(1), lineno=s.lineno))
            a.jmp('jmp', ltop); a.put(lend); return
        if isinstance(s, ast.Break):
            a.jmp('jmp', self.loops[-1][1]); return
        if isinstance(s, ast.Continue):
            a.jmp('jmp', self.loops[-1][0]); return
        if isinstance(s, ast.Return):
            f = self.cur
            if s.value is not None:
                self.expr(s.value); self.store_a(f.rv)
            a.jmp('jmp', f.exit); return
        if isinstance(s, ast.Expr):
            if isinstance(s.value, ast.Call):
                self.call(s.value, 0, want=False); return
            if isinstance(s.value, ast.Constant):
                return
        if isinstance(s, (ast.Pass, ast.Global)):
            return
        err(s, 'statement not supported: ' + type(s).__name__)

    # ----------------------------------------------------------- program

    def function(self, f):
        a = self.asm
        self.cur = f
        a.put(f.entry)
        self.stmts(f.node.body)
        a.jmp('jmp', f.exit)
        self.cur = None

    def exit_block(self, f):
        """Back to the call site whose number the caller left in f.ret;
        emitted after every body, when all the sites are known."""
        a = self.asm
        a.put(f.exit)
        if f.name == 'main':
            a.op('halt'); return
        self.load_a(f.ret)
        for i, site in enumerate(f.sites, 1):
            a.op('a== %d' % i)
            a.jmp('jt', site)
        a.op('error')     # an unknown call site

    def reachable(self):
        """The functions main() can call, and every name their bodies use:
        nothing else is compiled, placed in H or initialized, so one source
        can hold what several programs share."""
        reach, todo, names = {'main'}, ['main'], set()
        while todo:
            f = self.funcs[todo.pop()]
            for n in ast.walk(f.node):
                if isinstance(n, ast.Name):
                    names.add(n.id)
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in self.funcs \
                        and n.func.id not in reach:
                    reach.add(n.func.id); todo.append(n.func.id)
        return reach, names

    def program(self):
        a = self.asm
        reach, used = self.reachable()
        self.funcs = {n: f for n, f in self.funcs.items() if n in reach}
        for f in self.funcs.values():
            self.frame(f)
        # every byte: into M; the end (A > 255): set up and run main
        leos = a.label()
        a.op('a> 255'); a.jmp('jt', leos)
        a.op('c=r %d' % R_INLEN); a.op('*c=a'); a.op('a=c'); a.op('a++'); a.op('r=a %d' % R_INLEN)
        a.op('halt')
        a.put(leos)
        for name, v in self.ginit.items():
            if v:
                self.const_a(v); self.store_a(self.globals[name])
        base = Alloc.HVARS           # arrays after the variables' region
        for name in self.arr_order:
            if name not in used and name != self.heap:
                continue
            slot, size = self.arrays[name]
            self.const_a(base); self.store_a(slot)
            base += size
        self.hwords = base
        for name, vals in self.tables.items():
            if name not in used:
                continue
            self.load_a(self.arrays[name][0]); a.op('d=a')
            for v in vals:
                self.const_a(v); a.op('*d=a'); a.op('d++')
        a.jmp('jmp', self.funcs['main'].entry)
        # main first, then the rest, in the order written
        order = ['main'] + [n for n in self.funcs if n != 'main']
        for n in order:
            self.function(self.funcs[n])
        for n in order:
            self.exit_block(self.funcs[n])
        if self.lreset is not None:
            # H[0 .. D) to zero from the top, then the registers, the input
            # counter among them; only A and D, which hold nothing between runs
            lloop, ldone = a.label(), a.label()
            a.put(self.lreset)
            a.put(lloop)
            a.op('a=d'); a.op('a== 0'); a.jmp('jt', ldone)
            a.op('d--'); a.op('a=0'); a.op('*d=a'); a.jmp('jmp', lloop)
            a.put(ldone)
            a.op('a=0')
            for r in range(min(self.alloc.r, 256)):
                a.op('r=a %d' % r)
            a.op('halt')
        return a.assemble()


def compile_source(src, name='zl', ph='24', pm='$1+1'):
    tree = ast.parse(src)
    c2 = Compiler(tree)
    lines, size = c2.program()
    text = ['comp 0 0 %s %s 0' % (ph, pm), 'hcomp', '  halt', 'pcomp %s ;' % name]
    text += ['  ' + l for l in lines]
    text.append('end')
    return '\n'.join(text) + '\n', size, c2


if __name__ == '__main__':
    args = sys.argv[1:]
    src, outp = args[0], args[1]
    opts = dict(zip(args[2::2], args[3::2]))
    cfg, size, c = compile_source(open(src).read(), opts.get('--name', 'zl'),
                                  opts.get('--ph', '24'), opts.get('--pm', '$1+1'))
    open(outp, 'w').write(cfg)
    # where each source line starts in the program: for a run-time error's address
    marks = sorted((v, k.split(':')[1], k.split(':')[2]) for k, v in c.asm.positions.items() if k.startswith('@'))
    with open(outp + '.map', 'w') as mf:
        for addr, line, fn in marks:
            mf.write('%d %s %s\n' % (addr, line, fn))
    print('%s: %d bytes of PCOMP, %d R registers, %d H words of variables and arrays'
          % (outp, size, min(c.alloc.r, 256), c.hwords))

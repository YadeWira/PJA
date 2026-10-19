#!/usr/bin/env python3
"""Looks for identifiers that clash case-insensitively.

Pascal is case-insensitive: a variable `version` shadows a constant VERSION
and the compiler does not warn. It really happened when porting indice.rs
(Rust IS case-sensitive, and its convention guarantees FOO / foo pairs): the
comparison became `version > version` and no future version was rejected.

Heuristic on purpose: it gathers the names of constants, types, functions and
procedures of every unit and compares them against each declared variable and
parameter. Exits != 0 if there is a clash.

Functions were added on 12/10/2026: a variable `plano` shadowed the function
`Plano` in pjaformato and this said "0 clashes" (the compiler caught it because
the types did not match; with compatible types it would have compiled).
Against a function the SAME name clashes too, not only with other casing: in
Pascal a local variable with a function's name shadows it in the whole body."""
import re, sys, glob, os
d = sys.argv[1] if len(sys.argv) > 1 else '.'
sources = glob.glob(os.path.join(d, '*.pas')) + glob.glob(os.path.join(d, '*/*.pas'))
globals_ = {}
for f in sources:
    s = re.sub(r'\{[^}]*\}|\(\*.*?\*\)|//[^\n]*', '', open(f, encoding='utf-8', errors='replace').read(), flags=re.S)
    for m in re.finditer(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[^=;]+)?=\s*[^=]', s, re.M):
        n = m.group(1)
        if n.lower() in ('result',): continue
        globals_.setdefault(n.lower(), set()).add((n, os.path.basename(f), False))
routines = {}   # file -> [(name, visible from other units)]
for f in sources:
    s = re.sub(r'\{[^}]*\}|\(\*.*?\*\)|//[^\n]*', '', open(f, encoding='utf-8', errors='replace').read(), flags=re.S)
    impl = re.search(r'^implementation\b', s, re.M | re.I)
    is_unit = re.search(r'^\s*unit\b', s, re.M | re.I) is not None
    # At column 0: record methods are indented, and no variable `ok` shadows
    # `r.Ok`.
    for m in re.finditer(r'^(?:function|procedure)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(:;]', s, re.M | re.I):
        visible = is_unit and impl is not None and m.start() < impl.start()
        routines.setdefault(f, []).append((m.group(1), visible))
clashes = 0
for f in sources:
    s = re.sub(r'\{[^}]*\}|\(\*.*?\*\)|//[^\n]*', '', open(f, encoding='utf-8', errors='replace').read(), flags=re.S)
    # "a, b: Type" declarations in var and parameter lists
    # the routines visible from this file: its own and the interface ones of the others
    seen = {}
    for g, rs in routines.items():
        for (n, visible) in rs:
            if g == f or visible:
                seen.setdefault(n.lower(), set()).add((n, os.path.basename(g), True))
    for m in re.finditer(r'(?:^|[;(]|\bvar\b|\bconst\b|\bout\b)\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*:\s*[A-Za-z]', s, re.M):
        for n in re.split(r'\s*,\s*', m.group(1)):
            for (g, gf, is_routine) in globals_.get(n.lower(), set()) | seen.get(n.lower(), set()):
                # same name with other casing: the SAME identifier in Pascal;
                # against a routine, equal too
                if g != n or is_routine:
                    print(f"  {os.path.basename(f)}: '{n}' clashes with '{g}' ({gf})"); clashes += 1
print(f"{clashes} clashes")
sys.exit(1 if clashes else 0)

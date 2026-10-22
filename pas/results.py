#!/usr/bin/env python3
"""Stops the build if a function never names `Result` outside an Exit(...).

FPC does not warn "function result does not seem to be set" if SOME path does
Exit(value), even if another path reaches `end` without setting it. It
happened in pjafs.Parent (2026-10-09): it returned whatever was left in the
register, and the differential showed it as an intermittent failure, 1 run in
~10.

The rule is about style and not flow: it is enough for the body to use
`Result` (assigned, or passed to something that fills it, like WriteStr or an
out parameter). A pure `assembler` function is the exception: it returns
in the register its calling convention names.
Usage: results.py <pas_dir>"""
import re, sys, glob, os

def review(f):
    s = open(f, encoding='utf-8', errors='replace').read()
    # the keyword at the start of a line, not the word in a comment
    k = re.search(r'^implementation\b', s, re.M | re.I)
    unit_body = s[k.start():] if k else s
    bad = []
    for m in re.finditer(r'\nfunction\s+([\w.]+)\s*(\([^)]*\))?\s*:\s*[\w.<>]+\s*;', unit_body):
        start = m.end()
        nxt = re.search(r'\n(function|procedure|constructor|destructor)\s', unit_body[start:])
        body = unit_body[start: start + (nxt.start() if nxt else len(unit_body))]
        if re.match(r'\s*(stdcall|cdecl)?\s*;?\s*external\b', body) or re.search(r'\bexternal\b', body.split('\n', 1)[0]):
            continue
        # a pure assembler function returns in a register, by its convention;
        # a forward declaration has its body further down
        if re.search(r'\b(assembler|forward)\b', body.split('\n', 1)[0], re.I):
            continue
        without_exit = re.sub(r'\bExit\s*\([^)]*\)', '', body, flags=re.I)
        if not re.search(r'\bResult\b', without_exit, re.I):
            bad.append(m.group(1))
    return bad

d = sys.argv[1]
total = 0
for f in sorted(glob.glob(f'{d}/*.pas') + glob.glob(f'{d}/*/*.pas')):
    for n in review(f):
        print(f'  {os.path.relpath(f, d)}: {n} never names Result outside Exit(...)'); total += 1
print(f'{total} functions without Result')
sys.exit(1 if total else 0)

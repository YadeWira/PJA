# zpaqlc

For the ZPAQL decoder that zpaq-std's archives carry with PJA's blocks
(`pas/plugin/`): ZPAQL is a small virtual machine with 32-bit registers,
no calls and at most 65535 bytes of program, and PJA's decoder is far too
big to write in it by hand. These tools are written in Python and run at
build time only; nothing of them goes into PJA itself.

| | |
|---|---|
| `zpaqlc.py` | compiles a small language (a subset of Python: 32-bit unsigned values, arrays in ZPAQL's H, functions without recursion, signed comparisons and shifts) to a ZPAQL PCOMP program |
| `zpaqlvm.py` | runs a PCOMP program as libzpaq does, one instruction at a time, to test and debug it |
| `test_zpaqlc.py` | random expressions against exact 32-bit arithmetic, and programs for control flow, calls, arrays, signed helpers, long jumps and variables spilled to H |
| `gen_pjadec.py` | builds the plugin's decoders: `pas/plugin/zpaql/consts.zl` from the Pascal sources (the model's constants, tables and mixers, so the two cannot drift apart), then `pas/plugin/zpaql/` compiled into `pas/plugin/pjazpaql.inc` (JPEG, with `huff.zl`) `pas/plugin/pjalszpaql.inc` (JPEG-LS, with `jls.zl`, whose constants it checks against the Pascal ones) `pas/plugin/pjaxzpaql.inc` (pjax, with `huff.zl` and `pjax.zl`) and `pas/plugin/pjallzpaql.inc` (pjall, lossless JPEG, with `jls.zl` and `ljpeg.zl`) and `pas/plugin/pjalsxzpaql.inc` (pjalsx, subsampled JPEG-LS, with `jls.zl` and `jlsx.zl`), and the z codecs' five decoders (each its codec's with `lz.zl` in front, compiled with `opt`) into `pas/plugin/lzzpaql.inc`, and the version 7 codecs' four (pja7, pjax7 and their z: `model7.zl` in place of `model.zl`'s component, `opt=2`) into `pas/plugin/v7zpaql.inc`, and the o codecs' six (pjals, pjall and pjalsx and their z, the same programs with `opt=2`) into `pas/plugin/ozpaql.inc`, and the 8 codecs' ten (pja7's, pjax7's and the o codecs' programs and their z, with `opt=3`) into `pas/plugin/v8zpaql.inc`, and the JPEG 2000 codec's (stream version 8, modes 0 and 1: `j2k.zl`, `j2kcs.zl`, `j2kmodel.zl`, `j2kt1.zl` with `pjadec.zl`'s coder and raw bytes' model, `opt=3`; its model's tables packed from `pas/pjaj2km_tab.h`) into `pas/plugin/j2kzpaql.inc`; `--check` only verifies all of them are current |
| `test_pjadec.py` | those decoders run on segments (`pas/tests/zpaql_segments`), each with the H the plugin's query gives it: each JPEG or JPEG-LS file back byte for byte (`--o`: the o codecs'; `--v8`: the 8 codecs'; `--pja2k`: the JPEG 2000 codec's, with the H and M of its query, `$3 \| $4 << 8`) |
| `lz77.py` | a test encoder for the z codecs' blocks: zpaq's level 1 LZ77 (`rb` = 0), matches reaching back into the segments before; `test_pjadec.py --lz` runs each z decoder on its output |

```sh
python3 tools/zpaql/gen_pjadec.py        # after changing pas/plugin/zpaql/ or the model
python3 tools/zpaql/zpaqlc.py decoder.zl decoder.cfg --name pja --ph 24 --pm '$1+1'
python3 tools/zpaql/zpaqlvm.py decoder.cfg segment.bin out.bin 20 22
```

`zpaqlc` also writes `decoder.cfg.map`: where each source line starts in
the program, to find the line of a run-time error's address.

Only what `main()` reaches is compiled: functions it never calls, and
arrays and tables nothing reads, are left out, so the two decoders share
their sources (the head stream, the coder, the mixers) and each pays only
for what it uses.

An `if` on a constant compiles only the branch taken (its test, too, is
gone): the shared sources say `if PJAX:`, `if PJALL:` or `if PJALSX:` for
what only one program has, and the frozen programs, compiled with them 0,
come out as they were, byte for byte. One thing to keep that way: a
function's locals get their places in the order `ast.walk` meets their
first assignment, level by level, so moving an assignment into such an
`if` can swap two locals' places and change a frozen program. Leave the
assignment where it was and let the branch overwrite it after. `fresh(A, B, ...)` puts every global back to its first
value and every array but the tables, the heap and the ones named back to
zeros, and goes on: pjax decodes several JPEGs in one segment with it.

`reset(n)` ends a segment so that the next segment of the same block
starts as the first did: libzpaq keeps H, M and the registers between
them, so H below `n` and every register in use go back to zero.
`zpaqlvm.run_segments` runs several segments on one machine.

`def onbyte(c)` makes an unpacker: each byte of a segment goes to it
instead of into M, and it writes M itself (`setinlen(n)` says how long the
segment came out). M[i] is then M[mbase() + i], and `reset()` moves
`mbase()` past the segment instead of starting M over, so the segments of
a block follow one another in M (a ring) and each can refer to the ones
before: `pas/plugin/zpaql/lz.zl`, the z codecs' LZ77 expander.

`compile_source(..., opt=True)`, the z codecs' (frozen in 0.4.0): each
constant as the shortest sequence of instructions found (`a= 255 a+= 5`
for 260, `a= 255 a+=a a++` for 511), checked by running it, and in the
start-up code a constant near the one before built from it, kept in A or
B; and the variables placed by use: compiled twice more, each time with
the variables the code named most in R8 .. R255, then in H[0 .. 255]
(`d= N`, one instruction, where a higher address takes a constant first),
the smallest of the three kept. Without it the output is what it always
was.

`opt=2`, the version 7 codecs' (frozen in 0.6.0):
the same, with the functions' variables overlaid. A function's frame (its
variables, return places and temporaries) starts past the frames of all
the functions that may call it, so functions never on one chain of calls
share places, and far more of them fit in R; then the places by use, as
`opt`. And three of kaitz's patterns (zpaq-std's issue #4): `a=r N` right
after `r=a N` goes, a `b=a` whose B is written again before anything reads
it goes, and the start-up code steps over a table's zeros (H is zero then).
The version 7 decoder: 71,052 bytes with `opt`, 35,104 with `opt=2`.

`opt=3`, the 8 codecs' (frozen in 0.8.0): `opt=2` and three things more.
Functions inlined: one called from one place always, others when their
copies take fewer bytes than their calls (a call costs about 7 bytes, its
return chain about 7 more); the program is also compiled with none
inlined, and the smaller kept. The right side of an operation through B
with no temporary when the left one is a constant or a variable (`b=a`
and the left loaded, 4 bytes where a temporary took 7). A function's
value back in B instead of a place of its own (the return chain uses A
and F only). And a `jmp` to the instruction right after it goes. pja7's
decoder: 35,104 bytes with `opt=2`, 32,954 with `opt=3`.

How a program looks inside: variables live in R (in H once R is full), each
function in fixed places of its own; a call stores a call-site number and
long-jumps, and the function comes back through a chain of comparisons on
that number. The segment's bytes arrive one per run and go to M; the run
with the end marker starts `main()`.

Checked against libzpaq itself (zpaq-std 1.4.0): a test codec whose
decoder was compiled from this language was decoded by zpaq-std's ZPAQL,
with and without the plugin, byte for byte.

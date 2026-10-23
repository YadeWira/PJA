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
| `gen_pjadec.py` | builds the plugin's two decoders: `pas/plugin/zpaql/consts.zl` from the Pascal sources (the model's constants, tables and mixers, so the two cannot drift apart), then `pas/plugin/zpaql/` compiled into `pas/plugin/pjazpaql.inc` (JPEG, with `huff.zl`) and `pas/plugin/pjalszpaql.inc` (JPEG-LS, with `jls.zl`, whose constants it checks against the Pascal ones); `--check` only verifies all three are current |
| `test_pjadec.py` | those decoders run on segments (`pas/tests/zpaql_segments`), each with the H the plugin's query gives it: each JPEG or JPEG-LS file back byte for byte |

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

`reset(n)` ends a segment so that the next segment of the same block
starts as the first did: libzpaq keeps H, M and the registers between
them, so H below `n` and every register in use go back to zero.
`zpaqlvm.run_segments` runs several segments on one machine.

How a program looks inside: variables live in R (in H once R is full), each
function in fixed places of its own; a call stores a call-site number and
long-jumps, and the function comes back through a chain of comparisons on
that number. The segment's bytes arrive one per run and go to M; the run
with the end marker starts `main()`.

Checked against libzpaq itself (zpaq-std 1.4.0): a test codec whose
decoder was compiled from this language was decoded by zpaq-std's ZPAQL,
with and without the plugin, byte for byte.

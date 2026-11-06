# The PJA codec

Its streams (versions 5, 6 and 7) are stable since 0.9.0, version 8 (the
JPEG 2000 family) since 0.9.5: `doc/STABILITY.md`.

Its own format, written from scratch in FreePascal. It is **not** compatible
with packJPG's `.pjg`: packJPG is kept only as a yardstick for compression
ratio. No encryption.

## The one guarantee

JPEG → compressed → JPEG gives **the same file, byte for byte**. The
compressor checks this before handing anything out: it rebuilds in memory and
compares. A JPEG that does not come back identical is not compressed: it is
rejected with its reason.

Since there is no reference format to compare against, that round trip, run
over a large corpus, is the oracle for the whole project.

## Layers, bottom up

| layer | unit | what it does | status |
|---|---|---|---|
| 1 | `pjajpeg` | JPEG ↔ DCT coefficients + what is needed to rebuild the exact bits | done: 8 and 12 bits, Huffman and arithmetic, sequential and progressive; lossless JPEG ↔ samples |
| 1 | `pjajls` | JPEG-LS ↔ samples, the same way | done: 2-16 bits, NEAR, every interleave mode |
| 2 | `pjaarith` | binary arithmetic coder and adaptive bit counters | done |
| 3 | `pjamodel` | context modelling of the coefficients, the JPEG-LS samples or symbols, and the raw bytes | first version |
| 4 | `pjacodec` | the compressed stream: raw bytes + padding bits + coefficients, verified at compress time | done |
| 5 | `pjapack`, `pjacli` | the `.pja` file (`FORMAT.md`) and the `pja` command (`CLI.md`) | done |

Each layer has its test in `pas/tests/`, and nothing moves up to the next
layer with a red test. `pas/run_codec_tests.sh` runs them all.

## asm

x86-64 only, and only where a measurement justifies it (bit reading, the
arithmetic coder, coefficient prediction). The Pascal version is the
reference, builds on every architecture, and every asm routine is tested
against it on the same input.

## Layer 1: what it takes to give back the same bits

The JPEG is split into what is NOT entropy-coded data (markers, tables, SOS,
garbage after EOI) and the entropy-coded data of each scan. The former is kept
verbatim; the latter is decoded to coefficients and encoded again with the
same tables. What an encoder may have chosen differently from the standard,
and therefore has to be recorded:

- the padding bit at the end of each segment (almost always 1);
- the RST sequence;
- (progressive) the length of EOB runs and how many correction bits are
  buffered: libjpeg's choices are reproduced (up to 937 bits), and a run
  goes as far as the AC table can code it, `(2 shl r) - 1` for its largest
  EOBr symbol: 32767 with a full table as libjpeg, shorter for an encoder
  whose table stops earlier;
- RST markers after the last restart interval, which some encoders write:
  outside a scan an RST has no length, and it stays in the raw part.

Both are checked by `tests/test_tolerances.pas`, which builds such files
from `tests/jpg` (one and two extra RSTs after every file; a progressive
scan without its largest EOBr symbol, re-encoded so that its runs are cut);
`djpeg` decodes the cut ones to the same pixels as the original.

What is not modelled yet is detected anyway, because the rebuild is compared
against the original: it cannot pass as good.

Measured on 2026-10-18:

| corpus | files | identical | the rest |
|---|---|---|---|
| `tests/jpg` | 5 | 5 | — |
| real files from the shared corpus | 78 | 65 | 9 JPEG-LS, 2 of 12 bits, 2 malformed (packJPG rejects them too) |
| generated: cjpeg, jpegtran, ImageMagick, ffmpeg; progressive, RST, 4:1:1, CMYK, 1×1 | 640 | 604 | 36 arithmetic-coded |
| bit flips over the first 2 KB + every truncation | 72,543 | 35,829 | the rest, a named error; **0 exceptions** |

## Layer 1, arithmetic coding (19/10/2026)

SOF9 and SOF10 (sequential and progressive), with the DAC conditioning
tables: the QM coder of T.81 Annex D, decoded and re-encoded exactly as
libjpeg does it (jdarith.c / jcarith.c), its flush included, which is what
has to come out again. The Qe table is generated from libjpeg-turbo's, not
typed. Each restart interval is decoded from its own bytes, cut at the next
marker. A decoded magnitude of 2^15 stops the decoder, as in libjpeg: without
that bound garbage would walk the statistics index out of its table.

Round trip alone would not prove the decoder right: a symmetric mistake in
the contexts would decode wrong coefficients and still rebuild the file. So
the coefficients were compared with libjpeg's, through `jpegtran`, which
turns an arithmetic JPEG into a Huffman one without touching them.

| | files | result |
|---|---|---|
| cjpeg/jpegtran arithmetic: sequential, progressive, restart, 4:2:0, 4:2:2, 4:4:4, gray, CMYK | 244 | **244 identical**; coefficients equal to libjpeg's in all 244 |
| bit flips over the first 2 KB + every truncation of 5 of them | 54,397 | **0 exceptions** |
| the 244 through the whole codec | 244 | PJA saves **23.66%**, packJPG v5.0f 21.48% |

`tests/jpg` carries four small synthetic ones (`arith_*.jpg`, made from a
seeded plasma) so that every suite run covers it.

## Layer 3: the model (first version, 18/10/2026)

One routine encodes and decodes (`TCoder`): every value goes by `var`, is coded
when encoding and filled when decoding, so the two sides cannot drift apart.

Per block, component by component, blocks in raster order:

1. **How many of the 49 interior coefficients (7x7, u and v >= 1) are
   nonzero**, as a 6-bit tree, mixing the neighbours' counts (above and left)
   and, for chroma, the count of the luma block at the same spot.
2. **The interior in zigzag order** until that count runs out: zero or not,
   bit length in unary, mantissa, sign. Each zero and bit-length decision
   mixes four or five counters in the logistic domain: the same position in
   the blocks around (above and left weigh 2, above-left and above-right 1),
   the already coded neighbours inside the block, how many nonzeros are left,
   the ratio left / positions left, and for chroma the luma's activity. The
   zero decision is then refined by an APM.
3. **Row 0 and column 0**, each coefficient *predicted* from the neighbour
   across its edge: the boundary, extrapolated with its gradient from both
   sides, has to meet, which in 1D DCT terms fixes the one unknown term (the
   idea comes from Lepton and Lakhani). The prediction correlates 0.75 with
   the value but overshoots (best linear factor 0.61-0.65), so 5/8 of it is
   what goes into the contexts, with the adjacent interior coefficient.
   Coding the residual from the prediction instead of the value was tried
   and is worse (76.08% against 74.72%): it loses that the value is nonzero.
4. **The DC**, estimated pixel by pixel along both edges: each of up to 16
   boundary pixels, extrapolated from the neighbour and from this block, says
   what the DC must be; the mean of the middle half is the prediction, and
   the spread of the estimates the context, mixed with the neighbours' DC
   residuals.

The basis is an **integer** table: a prediction computed in floating point
could round differently on another CPU and the file would not come back.

The raw bytes (headers, tables, EXIF, garbage after EOI) go through orders
0-2 mixed.

Measured (`pas/tests/test_codec.pas`, 18/10/2026), every file verified byte
for byte:

| corpus | files | PJA saves | packJPG saves |
|---|---|---|---|
| `packJPG/jpg-files`, real photos, 78 MB | 151 | **25.00%** | 23.38% |
| shared corpus, real files | 65 | 26.27% | — |
| generated variants | 604 | 24.95% | — |

Corrupt streams (`test_codec_corrupt`, every bit of each stream and every
truncation): 49,985 variants, **0 exceptions**; a damaged stream that still
decodes gives another JPEG, which the container's size and hash reject.

Where the bits go (30 photos, `pas/tests/bench_costs.pas`): interior zero
flags 14%, bit lengths 15%, mantissas 9%, signs 12%; edge zero flags 9%, bit
lengths 12%, mantissas 10%, signs 7%; DC 7%; interior counts 5%; raw 1%.

Tried and dropped: counters at two speeds (no gain, the data is stationary),
the prediction's bits as context for the edge mantissa (no gain).

## Speed (19/10/2026)

Two builds of the same source:

- **reference**: range and overflow checks on (`$R+`/`$Q+`), Pascal only;
- **fast** (`-dPJA_FAST`): no checks in the model (`pjamodel`, `pjaarith`)
  and in the Huffman *encoder* (data already validated); the Huffman
  *decoder*, which reads untrusted input, keeps its checks. The mixer's dot
  product and weight update go through SSE4.1 when the CPU has it (`cpuid`;
  `PJA_NOASM=1` forces Pascal). The mixer arithmetic is 32-bit (weights
  clamped to +-2.0) so that both paths give the same numbers.

`pas/run_codec_tests.sh` compresses the same files with the reference, the
fast build, the fast build without asm and the fast build with 4 threads,
and demands identical streams.

Coefficients go in **horizontal bands** (one per 65,536 blocks, at most 16),
each its own arithmetic stream with its own models, coded and decoded in
parallel. The count depends only on the image, so the file is the same on
every machine and with any number of threads. Cost: 0.02 points on 30 photos
(32,768 blocks per band cost 0.23).

Measured, compress without verify / decompress, fast build:

| | 1 thread | 8 threads |
|---|---|---|
| 6 photos of 1.7-2.3 MB (2 bands each) | 1.15 / 1.23 MB/s | 1.50 / 1.66 MB/s |
| one 24 MP JPEG, 4 MB (8 bands) | 0.98 / 1.08 MB/s | **3.58 / 4.35 MB/s** |

A lesson paid for: the first threaded version scaled 1.7x on 8 threads,
because the cost accounting wrote a global variable several times per
coefficient from every band thread; one cache line bouncing between cores
made each band three times slower. The accounting now only exists in a
build with `-dPJA_COSTS` (`tests/bench_costs`).

From the first version: the edge and DC predictions now walk only the
nonzero coefficients and cache each finished block's edges (byte-identical
streams, 65 s -> 45 s on 30 photos); without checks 3x more; with asm, the
counter inlined and the encoder unchecked, 18 s. The APM was dropped: it
gave 0.02 points for 3% of the time.

The Huffman layer (`pjajpeg`) decodes through a 64-bit accumulator and a
9-bit table per Huffman table, built by running the bit-by-bit decoder on
every 9-bit pattern, so it answers the same for any table, broken ones
included. The reader runs ahead, so it remembers how many input bytes each
loaded byte took (1, or 2 for FF 00) and gives them back when aligning.
Checked against the bit-by-bit version: the same verdict for each of the
72,543 damaged variants (one hash over all of them) and the same result for
each of the 876 corpus files, in both builds. The encoder writes through a
64-bit accumulator. On the 24 MP file: decode 519 -> 274 ms, re-encode
273 -> 186 ms.

## JPEG-LS (19/10/2026)

`pjajls` is layer 1 for JPEG-LS (T.87, LOCO-I), in Pascal, with no library:
contexts, run mode, Golomb codes, the bit stuffing after FF and the padding
at the end of a scan, done as CharLS 2.4.2 does them, since that padding is
what has to come out again. Supported: 2 to 16 bits, 1 to 4 components,
NEAR (near-lossless), interleave modes 0, 1 and 2, custom thresholds and
RESET, LSE type 1 (mapping tables, kept as indices), restart markers. Not
supported (a named error): subsampled components, the point transform, LSE
type 4.

Near-lossless needs one thing recorded: the encoder decides where a run ends
by comparing the *original* samples, which the decoder never sees. The run
lengths read from the file are kept, and the re-encoder follows them.

Samples were checked against CharLS's, not only the round trip:

| | files | result |
|---|---|---|
| generated with CharLS: 2-16 bits, gray and colour, NEAR 0-3, the three interleave modes | 65 | **65 identical**, samples equal to CharLS's |
| real files (ISO and HP test images) | 9 | **8 identical** (packJPG: 2); the ninth uses subsampling |
| bit flips + every truncation | 189,176 | **0 exceptions** |

`tests/jls` carries eight small synthetic ones made from a seeded plasma.

Two models, and the compressor keeps whichever gives the smaller stream
(one bit in the header stream says which):

- **samples**: the samples themselves, predicted from their neighbours and,
  in colour, from the components already coded; in bands, so in parallel.
  Near-lossless files need their run lengths stored beside it.
- **symbols**: JPEG-LS's own state machine, run over every scan, with each
  of its symbols (mapped errors, run bits) coded arithmetically instead of
  with Golomb codes. The model also keeps the reconstructed samples and
  makes a second prediction (CALIC's GAP with its error feedback), which
  tells it what error to expect. It carries the run lengths by itself. One
  stream per image, so not in parallel.

Size of the stream against the JPEG-LS file (the frame and headers aside):

| | files | samples | symbols | kept |
|---|---|---|---|---|
| photos (8 gray, 8 colour), converted with CharLS | 16 | 89.63% | 84.35% | **84.35%** |
| ISO and HP test images | 8 | 97.16% | 92.03% | **91.73%** |
| generated: 2-16 bits, NEAR 0-3, the three interleave modes | 65 | 113.85% | 92.65% | **92.38%** |

The first version had only the samples model, and near-lossless files grew
(NEAR=3, 12 bits: 139.7%), because the samples model codes values that
JPEG-LS had already quantised to a much smaller alphabet; the symbols model
codes that alphabet, and the same file shrinks (93.5%).

Tried and dropped: coding the difference from the second prediction's
error instead of the error with it as context (better on gray photos,
much worse on the test images: 96.8%), choosing per context how much to
trust it, and a second mixer.

## Speed, second pass (19/10/2026)

Without changing a bit of any stream (checked on 415 files: the samples,
244 arithmetic JPEGs, 74 JPEG-LS and 78 real JPEGs, every `.pja` identical
to the previous build's):

- the counters are set up with one fill instead of one by one: the raw-byte
  model alone has 4M per file, so a small file decodes in half the time;
- `FineLog`, `BitLen` and `DivRound` are inlined again: FPC does not inline
  a call nested as the argument of another inline call, nor one that
  assigns to a parameter;
- each block keeps a mask of its nonzero coefficients, and the
  dequantization, the edge sums and the DC estimates visit only those;
- two divisions per coefficient became a table and a division by a
  constant; the 8 or 16 DC estimates are sorted by a sorting network
  without branches.

On 151 photos (76 MB), one thread: compress 164 → 141 s, decompress
79 → 69 s. packJPG 5.0f, the same files: 68 s with `--verify` (37 s
without), 36 s. Measured with `perf`: 52.8 million binary decisions for
4.2 MB of stream, about 300 cycles each, and neither cache misses (almost
none reach the last level) nor branch misses (2.3%) dominate: the cost is
the work per decision. Inlining the arithmetic coder and the mixer into
their callers gave nothing.

`pja -th N` now gives its threads to files first. On the same photos with
8 threads: compress 20.6 s, decompress **10.0 s** (packJPG 5.0f: 10.4 s
both ways).

Smaller bands would let one photo decode on several threads, but every band
starts its models from nothing:

| blocks per band | the 151 photos | cost |
|---|---|---|
| 65536 (as it is) | 58,848,042 | — |
| 16384 | 59,304,600 | +0.78% |
| 8192 | 59,801,969 | +1.62% |
| 4096 | 60,302,146 | +2.47% |

A typical photo needs about 6,000 blocks per band for 8 threads: close to
2%, most of PJA's lead over packJPG. Not done.

## Verifying while encoding (19/10/2026)

With two threads or more, a JPEG is verified while it is being compressed:
each band's encoder writes into a `TLiveStream` (`pjaarith`), and a second
thread decodes it a few bytes behind, into a second copy of the
coefficients built from the header stream exactly as `Decompress` builds
it. Then the stream's framing is read back with `Decompress`'s own
`BandRanges`, and the copy is rebuilt into a JPEG that has to be the input:
the same checks as before, in about the time of one pass. The bytes go in
64 KB blocks that never move, so the reader never sees a reallocation; past
the end of a finished stream it reads zeros, as the decoder does on a band's
own slice. An encoder that fails still closes its stream, so its reader is
never left waiting. Two mutants were caught on every sample: a decoder off
by one bit, and an encoder that fails mid-band (no hang).

One photo at a time, the 151 photos: 146.5 → 108.5 s, the same `.pja`
files. The ideal would be about 40% less: the phases outside the bands
(the JPEG's own round trip, the header stream, the rebuild) stay in series,
and with two cores busy each one runs at a lower clock (measured: the same
instructions, 3.2 → 2.7 GHz). A reader that spins while it waits makes that
worse, so it sleeps 50 µs when it catches up. The two threads must not land
on the two hardware threads of one core: there it took 823 ms against
650 ms on two cores.

## The fast model (19/10/2026)

`pja a --fast` (stream byte 1 = 1): a JPEG's coefficients with no mixer. Each
decision is coded with one counter in a joint context, averaged in the
logistic domain with one of the full model's counters for the biggest
decisions (interior zero flags and bit lengths, edge zero flags and bit
lengths); the DC, the nonzero counts, the mantissas and the signs use one
counter. The predictions (edges, DC) are the full model's: they are where the
ratio is.

How the contexts were chosen: the full model's decisions were logged with
the cells that took part, and for each kind of decision the code length of a
static model over one cell or a pair of cells was estimated with the KT
estimator, per image. The best pairs became the joint contexts; on 12 photos
they predicted +1.8% for one counter, and gave +2.04% (one counter) and
+1.67% (two averaged).

On the 151 photos, against the full model:

| | full | fast |
|---|---|---|
| size | 58,848,193 | 59,827,219 (+1.66%) |
| compress, 1 thread | 144.8 s | 95.9 s |
| decompress, 1 thread | 72.5 s | 47.1 s |
| decompress, 8 threads | 10.1 s | 6.9 s |

Still smaller than packJPG 5.0f's 60,084,653, and faster to extract with 8
threads (packJPG: 10.4 s).

Measured and not done: with smaller bands, so one photo decodes on several
threads, the fast model loses more than the full one (8192 blocks per band:
+4.4% on top), since one counter needs more samples to learn than a mixture
of five. Starting each band from per-image tables would cost their
transmission, about as much again: a static design that parallelises inside
a photo costs more than the 2% this mode allows.

## Speed, last round (20/10/2026)

All without changing a bit of any stream (830 streams, 415 files in both
models, compared with the previous build each time): the DC estimates split
by pruned partition networks; FillCaches and the DC estimates as
precomputed per-position kernels, added with SSE4.1 `pmuldq` (a Pascal path
gives the same numbers); a counter update without clamps or branches; the
raw model's 16 MB of counters and each band's models kept per thread and
refilled, not reallocated; one call per Huffman code and its extra bits.

The 151 photos, measured in one session:

| | packJPG 5.0f | PJA `--fast` | PJA full |
|---|---|---|---|
| size | 60,084,653 | 59,827,219 (-0.4%) | 58,848,193 (-2.1%) |
| compress, 1 thread | 70.8 s (`--verify`) | 86.3 s | 133.2 s |
| compress one file at a time, 2 threads | | 82.0 s | 107.3 s |
| decompress, 1 thread | 34.4 s | 40.2 s | 67.6 s |

Tried and dropped, each measured: inlining the arithmetic coder into its
callers (nothing), decoding the bit without a branch (+3.5%: the model
branches on it right after), building for AVX2 (nothing), multi-symbol
models in the AV1 way for the zero-or-length decisions (ratio +0.4% to
+3.1% depending on the region, and no faster). With the predictions off
altogether the fast model would decode 22% faster for 5.6% more: they are
where both the time and the ratio are. What is left of the gap to packJPG on
one thread is spread over the whole coefficient loop, about 200 cycles per
binary decision; closing it would take that loop in assembly, which was
judged not worth it.

## Speed, one thread against packJPG (21/10/2026)

The fast model's goal: packJPG's ratio and speed on one thread. Profiled
with `perf`, and again without changing a bit of any stream (the suite, and
both models and the no-assembly path compared with the previous build):

- **the edge predictions' divisions**: two 64-bit `idiv` per edge
  coefficient (40 to 90 cycles each on the Broadwell measured), by a divisor
  that depends only on the quantizer. Its reciprocal is computed once per
  component; a multiplication in double and one integer comparison each way
  give exactly `DivRound`'s quotient while the numerator is below 2^50, and
  the division itself does the rest. The same for the DC's two. About -4%
  both ways.
- **BLAKE3** at 28 cycles a byte: a loop that permuted the message in an
  array. Unrolled, the schedule written out and every word a local, 9.5. The
  official vectors still pass.
- **the kernel sums** of FillCaches and the DC estimates: one routine per
  block that keeps the accumulators in registers, instead of one call per
  coefficient that read and wrote 16 Int64 in memory. About -4% compressing.
- **the interior's nonzeros** counted and visited through the block's
  nonzero mask (SSE2) instead of 49 compared one by one.
- **the JPEG's Huffman decoding**: with 26 bits waiting no code and its
  extra bits can run out, so the table's answer is used directly; the block
  checked against its component once and written through a pointer. The bit
  reader takes up to 7 bytes at once and the writer puts 4 when none is FF.
- smaller: the squash and stretch tables in 16 bits (16 KB together, not
  32), the bucket functions as tables, the mantissa bits through the fused
  coder, a frame-less `NonzeroMask`, 32-bit division for an MCU's position.

The 151 photos, 1 thread, `--fast --no-verify` against packJPG's default
(which does not verify either), alternating runs, cycles in user space
(the machine was shared, about 15 to 20 of load):

| | packJPG 5.0f | PJA `--fast` |
|---|---|---|
| size | 60,084,653 | 59,827,219 (-0.43%) |
| compress | 125.5 to 126.6 Gcycles | 128.6 to 130.5 (+2.8%) |
| decompress | 117.4 to 119.8 Gcycles | 115.0 to 115.2 (-3%) |

Decompression is now faster than packJPG's and the stream smaller;
compression is within 3%. On 30 of the photos this round took the fast
model from about 27 to about 23 Gcycles compressing (-15%) and from about 24 to 21
decompressing (-13%).

Then compression's own part, the same way (no stream changes): the raw
model's tables read through locals (each use of a threadvar was a call),
the rebuilt JPEG allocated once at the size expected (capped by the
coefficients' memory, so a damaged `.pja` cannot make it allocate what it
claims) and handed back without a copy, the round trip compared with one
`CompareMem`, the nonzero mask computed once per block when encoding, and
the scan's units walked by position instead of divided out. Compressing
the 151 photos, three alternating rounds: 121.6, 121.5 and 126.9 Gcycles
against packJPG's 124.5, 125.5 and 124.9, so about 2% faster (median);
decompressing 112.9 to 123.8 against 115.3 to 133.9. Both ways now at or
below packJPG, with a stream 0.43% smaller.

Tried and left out: turning the overflow and range checks off in the JPEG
decoder's block routine gave about 1%, not enough to give up the rule that
the decoders stay checked in every build.

Then the branches. Decoding mispredicted about 178 million of them on 30
photos, some 15% of the cycles, and much of it on data the code compared
in order to choose between two values: the sign of a neighbour (`Sgn3`),
the extremes of the DC estimates, the sign of an edge prediction before its
division. Those became comparisons and masks; the extremes are taken from
the ends the partition network already leaves them at; the edge's nonzero
coefficients and the in-block neighbour come from the nonzero mask and
from tables per position. About -6% decompressing, -3% compressing. The
151 photos, three alternating rounds:

| | packJPG 5.0f | PJA `--fast` |
|---|---|---|
| compress | 130.4, 133.4, 131.9 Gcycles | 120.4, 122.5, 130.2 (median -7.7%) |
| decompress | 126.2, 122.9, 121.4 | 111.7, 109.5, 106.6 (-11.5%) |

Tried and dropped, each measured: the arithmetic encoder's interval update
without a branch (+3%: the predictor already gets it right from the
model's own branches on the same bit), `FineLog` without a branch (more
instructions, slower), the position kernels in 32 bits (half the cache,
no faster), NeighbourMag's weights and divisor set up once per block (no
faster: the routine has no registers to spare).

## The fast model, closed (22/10/2026)

The fast model is closed: no more work on it (its stream moved to version 5
with the full model's, below, at no cost in size). The
151 photos, one thread, in one quiet session (load about 5), two rounds
each, cycles in user space:

| | packJPG 5.0f | PJA `--fast` | PJA full |
|---|---|---|---|
| size | 60,084,653 | 59,827,219 (-0.43%) | 58,848,193 (-2.06%) |
| compress | 123.5, 125.1 Gcycles | 112.0, 113.2 (-9.4%) | 195.9, 195.0 (+57%) |
| decompress | 115.2, 117.2 | 104.7, 105.3 (-9.6%) | 186.6, 186.4 (+61%) |

Two more ideas measured and left out: counters in 2 bytes instead of 4
(probability in 11 bits, count in 5) cost +0.37% for about 1% of speed:
the counters' memory is not the lever it looked like; precision is what
matters (in 12 bits alone, +0.44%). And a count limit of 63 instead of 255
would make the fast model 0.08% smaller at no cost in time, but it changes
the frozen stream.

## A heavier model, explored (22/10/2026)

How much more a JPEG can give, measured with the author's archived TCIJ, a
JPEG compressor built on paq8px v216's JPEG model (GPL: used as a yardstick
only; nothing of its code is in PJA). On 30 photos it is 8.9% smaller than
PJA's full model, about 30 times slower; on 10 baseline photos, 5.7%. Two
kinds of files stand out: one with repeated content where its match model
takes 55% off, and the progressive ones, where PJA is 20% smaller (paq8px
does not model progressive scans). Taking its parts out one at a time, on
the 10 baseline photos:

| TCIJ | against PJA full |
|---|---|
| everything | -5.7% |
| without its 14 APM stages | -5.2% |
| without the general and match models | -4.3% |
| its JPEG model only, 49 contexts, no APM | -3.8% |
| the same with 20 contexts | -2.4% |
| with 10 contexts | +0.75% |
| with 5 contexts | +2.8% |

PJA's full model is worth about 10 to 12 of those contexts, at a fraction of
the cost. The rest of the distance is not in any one part: many contexts
combining several predictions, counters with a bit history that know how
much to trust themselves, two inputs per context, mixing in two layers,
APM stages with rich contexts. Tried in PJA one piece at a time, each gave
next to nothing: an APM after each mixer selected by the mixer's own
selector, -0.03% to -0.09%; eight hashed contexts more for the interior
zero flag, -0.01%. A `--max` model would have to be designed as a whole,
every decision at once; the estimate, 2% to 4% under the full model at 3
to 6 times its time, with no guarantee. Not done.

## Stream version 5: the predictions in 32 bits (22/10/2026)

For zpaq-std, PJA's stream has to be decodable by a ZPAQL program, and
ZPAQL has only 32-bit registers. The edge predictions and the DC estimates
were the only 64-bit arithmetic in the models: a dequantized coefficient
(up to 2^22) times the kernels (up to 2^27). Version 5 rescales them so
that every product fits in 31 bits and every value the predictions use
fits in 32:

- a dequantized coefficient is clamped to 2^15 (a real 8-bit JPEG's DCT
  coefficients stay below 2^14);
- the edge weights (3 B0 - B1) are divided by 8, so the edge prediction
  divides by 724 q instead of 2 B00 q;
- the DC kernels are divided by B00 (rounded), so the DC estimate divides
  by B00 q0 instead of B00^2 q0.

The arithmetic is defined as a 32-bit machine's, wrapping: sums and
products are kept in Int64, which gives the same value modulo 2^32
wherever it is cut, and `W32` cuts them to 32 bits right before anything
else (a division, a comparison, the partition network's differences, a
logarithm, a sign). On real files nothing wraps: 0 of 611 million values
checked on 151 photos and the 73-file corpus. A hostile file wraps the
same way in Pascal and in ZPAQL.

What it costs: nothing. The 151 photos, full model, 58,848,193 -> 58,848,272
bytes (+0.0001%); the corpus -0.0001%; the fast model on 30 photos +5
bytes in 10.6 MB. Streams of version 4 are no longer read.

## The decoder in ZPAQL, for zpaq-std (22/10/2026)

zpaq-std's archives carry, with each block a plugin compressed, a decoder
written in ZPAQL, ZPAQ's virtual machine, so that any zpaq reads them
without the plugin. ZPAQL has 32-bit registers, no calls and at most 65535
bytes of program: PJA's decoder is written in a small language (a subset
of Python, `pas/plugin/zpaql/`) that `tools/zpaql/zpaqlc.py` compiles.

Stage 1 covers what the plugin takes for now: the full model and
sequential Huffman JPEG (the head stream and its raw bytes, the headers,
every band with the full model, and the JPEG rebuilt). It is a line by line
port: the same integers as Pascal, which version 5 of the stream made
possible (the predictions in 32 bits). Two tables Pascal computes with
floating point are not computed in ZPAQL: squash travels in the program
(symmetric, its upper half as deltas of 3 bits), and the reciprocals of
the counters come from an integer formula that gives the same 256 values.

40,547 bytes of program. Its memory, H, is sized for each block: the
config says `comp 0 0 $3 $1+1 0`, and zpaq-std asks the plugin for $3
(query `ZS_QUERY_ZPAQL_ARGS`) when it compresses the block; the block keeps
the number, so any zpaq reads it. `pjazpaqlargs` follows the decoder's
allocations one by one to give it. The decoder's own part is 90,000 words:
the raw model's order-2 counters, a table of 4 million in Pascal, are a
hash map sized by the raw bytes (each touches at most 8), and the
coefficients go two to a word. A small JPEG asks for 2 MB, a photo of
200 KB for 16 MB; the plugin takes nothing that would need more than 256
MB. The decoder measures its H when it starts and stops with an error if
it is short, instead of writing over itself. Such a ZPAQL is handed out
only as `ZS_DATA_ZPAQL_ARGS`: a zpaq-std that does not ask the query sees
none, so it never writes a block with an H of one word. With libzpaq's JIT it decodes about 10 times slower than the plugin
(2.1 s against 0.23 s for a photo of 211 KB). With a fixed H of 2^26
words it was checked with zpaq-std 1.4.0 on every block of the 151 photos
and of the corpus (190 blocks, 0 wrong), and on Windows 10 in 64 and 32
bits; extracting without the plugin gave every file back. The decoder with
its order-2 map and packed coefficients, given a fixed H, again on every
block of both sets: 193 blocks, 0 wrong (3 more files taken, now that the
plugin counts the memory exactly instead of estimating it). Then with H sized per block, on zpaq-std's
test build with the query (its commit 6c8ea90): the same 193 blocks, 0
wrong, the memory it reports going from 25 GB to 1.7 GB for the 151
photos; extraction without the plugin, 151 of 151 photos back, and plain
zpaq 7.15, which knows nothing of plugins, gave back all 78 files of the
corpus; on Windows 10, 64 and 32 bits, every block and every file. The suite runs the decoder on two samples in a Python
interpreter of ZPAQL, and checks that the generated program is current.

Stage 2, the same day: progressive Huffman JPEG. The model was already the
same (PJA codes the final coefficients whatever the scans); what the
decoder adds is the progressive rebuild of pjajpeg, ported the same way:
DC first scans, DC refinement bits, AC first scans with their EOB runs,
AC refinement with its correction bits held until the next run, each
scan's longest EOB run from its table, the runs flushed at every restart.
46,307 bytes of ZPAQL. On zpaq-std's test build: all 151 photos taken (17
of them progressive) and 64 files of the corpus, every block ZPAQL OK;
plain zpaq 7.15 gave back all 151 photos and all 78 files of the corpus.
Windows 10, 64 and 32 bits, with progressive files among them: every block
ZPAQL OK, every file back without the plugin.

Stage 3: arithmetic-coded JPEG. The decoder reads SOF9 and SOF10 and the
DAC conditioning in force at each scan, and rebuilds the scans with
pjajpeg's QM encoder (libjpeg's jcarith.c, bit for bit, its flush
included), its statistics reset at each restart. The QM coder fits in 32
bits (its C register stays below 2^28). 61,764 bytes of ZPAQL, close to the
65,535 a program may take: JPEG-LS, with a model of its own, will be a
second codec in the same plugin, with a ZPAQL decoder of its own. On
zpaq-std's test build: of 244 arithmetic JPEGs (sequential, progressive,
restarts, 4:2:0, 4:2:2, 4:4:4, gray, CMYK) and 640 generated ones of every
kind, every block given to the plugin was decoded by the ZPAQL as by the
plugin, 0 wrong; plain zpaq 7.15 gave back all 244 and all 652 files.

Stage 4 (23/10/2026): JPEG-LS, as a second codec in the same plugin,
`pjals`, with a decoder of its own (`jls.zl`, 55,459 bytes of ZPAQL),
since `pja`'s had no room left. It shares the head stream, the coder and
the mixers with `pja`'s; the compiler now leaves out of each program what
its `main()` does not reach. Ported line by line: the JPEG-LS headers
(presets, restart intervals of 2 to 4 bytes), both models (the samples
with their bands and the near-lossless run lengths, and the symbols with
CALIC's GAP and its texture contexts), and pjajls's state machine twice
over: driving the symbols model to decode, and writing a scan's bits from
the samples, CharLS's bit stuffing and padding included. Its memory comes
from a query of its own: the samples, the line buffers and either model,
and for the symbols model on a near-lossless scan room for one run length
a line and component, since the stream does not say how many. The
plugin's detection asks that the file fit with either model, as compress()
keeps whichever is smaller. With libzpaq (the engine of zpaq 7.15), every
file of four sets came back byte for byte: the 8 suite samples, 65
CharLS files of every bit depth, interleave and NEAR from 1x1 to 333x7,
16 photos and 8 real test images, and, from 33 lossless ones, variants
with restarts every 1 and every 5 lines, each with both models forced
(282 decodes, 0 wrong). On zpaq-std's test build, with JPEGs and JPEG-LS
files in one archive (`-sat:pja:pja+2:pjals+2`), every block given to
`pjals` was ZPAQL OK, and plain zpaq 7.15 gave back all 104 files. The
ZPAQL decodes about 6 times slower than the plugin (16.7 s against 2.7 s
for a photo of 1.4 MB).

Several files in one block (23/10/2026). Every block carries its decoder,
about 60 KB, which eats the whole gain of a small photo. zpaq-std can put
consecutive files of one codec in one block, a segment each, so that the
decoder is paid once: zpaq 7.15, zpaqfranz and zpaq-std extract such a
block (zpaq-std checked it with the PCOMP in the first segment only).
libzpaq keeps H, M and the registers from one segment to the next, so both
decoders end each segment with zpaqlc's `reset(hp)`: the part of H they
used and every register back to zero, the input counter among them, and
the next segment starts as the first did. 530 bytes more of each program
(62,294 and 55,989). The plugin says so with `query(ZS_QUERY_SEGMENTS)` =
1; zpaq-std then sizes the block for its largest file. With libzpaq,
blocks of 3 to 20 files of every kind (photos, arithmetic, generated
variants, JPEG-LS files of every interleave and NEAR), large and small in
any order: every file back byte for byte. The suite decodes two blocks of
two files.

## JPEGs inside a JPEG: stream version 6 (23/10/2026)

Many JPEGs carry others: the EXIF thumbnail in an APP1 (some cameras write
it twice, in two segments), the further images of an MPO after the first
one's EOI, an Ultra HDR gain map after it too. Until now they went with
the raw bytes, which the order-2 model codes, while their coefficients
could be modelled as any JPEG's. Measured over the test sets: at least
11.7% of the bytes of the 78-file corpus are such JPEGs, 0.56% of the 151
photos', and close to half of an MPO.

Version 6 is a frame around version 5 streams: a table of the parts
(where each is in the file, its length, its stream's length, its mode),
the parts' streams, and the host, the file without them, as a version 5
stream. A part inside one of the host's segments is replaced by zeros
there, so that the host's markers still add up; one after the host's EOI
is cut out. A part identical to an earlier one (the second copy of a
thumbnail) is a reference to it, with no stream. Each part goes through
Compress itself, so the second image of an MPO has its own thumbnail
taken out as well (two levels).

Compress looks for FF D8 FF from the third byte on (none can be inside
entropy-coded data, where FF is followed by 00 or a restart marker); a
candidate becomes a part if PJA takes it as a JPEG and its stream is
smaller than its bytes. The bands of the host and of the whole file are
the same, so whether the parts pay is known exactly by coding only the
file's raw bytes, not by compressing it twice: the parts go only when the
version 6 stream is smaller than version 5 would be. For a file of 1 MB
or more whose parts are a quarter of it (an MPO's images) that check is
skipped, since it would code megabytes of raw bytes to confirm what the
model's gain on a whole image makes certain. Version 5 is written
whenever no part pays, and also if anything about the parts fails (the
host not taken, the round trip not identical): a file never fails for
its parts. The zpaq-std plugin asks for version 5 only, the stream its
ZPAQL reads.

| set | files | v5 | v6 | | smaller | larger | time |
|---|---|---|---|---|---|---|---|
| MPO of the corpus | 6 | 35,002,145 | 30,406,303 | **-13.13%** | 5 | 0 | 16.6 s -> 16.1 s |
| corpus | 78 | 24,348,466 | 23,654,057 | **-2.85%** | 24 | 0 | 10.6 s -> 12.2 s |
| 151 photos | 151 | 58,848,272 | 58,786,809 | -0.10% | 48 | 0 | 16.7 s -> 17.6 s |
| 30 photos | 30 | 10,411,481 | 10,401,771 | -0.09% | 6 | 0 | 4.1 s -> 4.2 s |
| arithmetic and generated JPEGs | 884 | 18,926,330 | 18,926,330 | 0 | 0 | 0 | 6.6 s -> 7.0 s |

8 threads, every file extracted and compared: all identical. The first
version took every part that was smaller than its bytes, and 6 of the 30
photos came out larger: their cameras write the thumbnail twice, and the
raw model had coded the second copy almost for free; the references to
an earlier part and the exact check fixed both.

## 12-bit JPEG (23/10/2026)

Extended, progressive and arithmetic JPEG may have 12 bits a sample
(SOF1, SOF2, SOF9, SOF10). Nothing in PJA was 8-bit but the gate and the
Huffman categories: a DC difference has up to precision + 3 bits and an
AC coefficient up to precision + 2 (T.81 F.1.2), 15 and 14 at 12 bits.
The coefficients were already 16-bit and range-checked, the DQT already
read 16-bit tables, the QM coder's magnitudes already reached 2^15, and
the model's predictions take the dequantized values capped at
MAX_DEQUANT, so they stay in 32 bits at any precision: the same stream,
the same model. The checked build (range and overflow checks on) gives
the same streams.

Samples from libjpeg-turbo 3.0.4 (`cjpeg -precision 12`; the system's
libjpeg cannot write them) of every kind, sequential, optimized,
progressive, arithmetic sequential and progressive, restarts, gray,
quality 100, and the 2 of the 78-file corpus: all back, those 2 to 73.0%
and 77.7% (xz -9e: 97%). The 30 photos re-encoded at 8 and at 12 bits
with the same qualities: 70.7% and 80.7%. The 12-bit files are 2.6 times
larger, their extra bits mostly the DCT's rounding, which nothing
predicts; how much of the difference the model could still take (its
buckets were tuned on 8-bit magnitudes) is left for when there are real
12-bit files to tune on. Windows 10, 64 and 32 bits: the same streams as
on Linux.

The zpaq-std plugin keeps to 8 bits: its ZPAQL is frozen as v0.0.1 left
it, with the 8-bit categories, so detect, compress and the query refuse
a 12-bit JPEG.

## Lossless JPEG (23/10/2026)

Lossless JPEG (SOF3, T.81 Annex H) codes samples, not coefficients: each
one predicted from its neighbours by one of seven predictors, and the
difference, modulo 2^16, Huffman-coded by its bit length as a DC
difference is (up to 16, where 16 is 32768 alone with no bits after it).
It lives on in medical imaging (DICOM) and in some raw formats; libjpeg
-turbo 3 writes it again. pjajpeg decodes a scan to the samples and writes
it back bit for bit, as libjpeg-turbo does (jdlossls.c, jclhuff.c): the
first line of a scan or of a restart interval predicted from 2^(P-Pt-1)
and then from the left, every other line's first sample from above, the
shifts of predictors 5 and 6 arithmetic. The padding bits and the
restarts are a DCT scan's.

The samples go to JPEG-LS's samples model (pjamodel.CodeJlsBand, its
bands and threads): pjacodec gives it a TJls whose sample arrays are the
TJpeg's own, so what it decodes is where Recompose reads. The stream is
version 5's: the raw bytes say it is a lossless JPEG, as they say a file
is JPEG-LS. What the model needs: no component subsampled, and one point
transform for the whole image (one range of samples); a restart interval
of whole lines, which libjpeg demands too. A sample beyond the point
transform's range, which no encoder writes, is refused. SOF11 (lossless
with arithmetic coding) is refused.

36 samples from libjpeg-turbo 3.0.4 (every predictor at 8, 12 and 16
bits, gray and colour, point transforms, restarts, RGB): all back, the
checked build and the fast one with the same streams. The 30 photos,
decoded and written as lossless JPEG: 86.0 MB with predictor 1 to 53.5 MB
(62.2%), 81.9 MB with predictor 6 to the same 53.5 MB (65.3%): the model
sees the samples, whichever predictor coded them. As JPEG-LS (CharLS) the
same images are 61.6 MB, and PJA makes them 50.6 MB, its symbols model
taking a little more where the JPEG-LS file is the input.

The zpaq-std plugin refuses lossless JPEG: its ZPAQL is frozen as v0.0.1
left it.

## DNL and subsampled JPEG-LS (23/10/2026)

**DNL.** A frame may say its height is 0 and give it in a DNL segment
right after the first scan (T.81 B.2.5), as some scanners and fax
software did. pjajpeg finds the DNL ahead when it reads such a frame (no
FF DC can be inside entropy-coded data) and sizes the image by it; the
SOF's 0 and the DNL stay in the raw bytes as they were, and a DNL
anywhere else, or saying another height, is refused. libjpeg reads none
("DNL not supported"); PJA takes them, Huffman, progressive and lossless.

**Subsampled JPEG-LS.** T.87 lets a frame's components have sampling
factors (A.2): each component is ceil(X·H/Hmax) by ceil(Y·V/Vmax), and in
line interleave the scan goes by groups, V lines of each component in
turn, its contexts shared and its run index its own. CharLS has none (not
even its development version), so this follows the standard, with the
conformance image T8SSE0 (2x4, 2x1, 1x2, in the real JPEG-LS test files)
as the check: decoded by these rules, its first component is the
conformance set's non-subsampled image's, all 65,536 samples. Both models
take it: the samples model goes component by component with their own
sizes (the first component's residual is a context only where the sizes
match), the symbols model takes each component's width. Without
subsampling nothing changed: 134 JPEG-LS and lossless JPEG streams of
before, the same bytes. T8SSE0 now comes back (8% smaller, the model
picked by size as always); sample interleave with subsampling, which T.87
does not allow, and restarts in a subsampled line-interleaved scan stay
refused.

The point transform of JPEG-LS stays refused: no encoder at hand writes
it (CharLS refuses it) and no file in the test sets has it.

The zpaq-std plugin refuses both, its ZPAQL frozen as v0.0.1 left it.

## Encoder quirks, and the rest as bytes (23/10/2026)

The two files of the 78-file corpus PJA still refused had the same
quirk: a DRI segment (an interval of 60 and of 34 MCUs) and not one
restart marker in the scan. Their encoder wrote the DRI and coded as if
there were none; libjpeg reads the first interval and throws the rest
away ("extraneous bytes before marker 0xd9"). A patch of differences, as
first planned, cannot hold this: coding the scan with its restarts shifts
every bit after the first, and the patch would be the file. So the quirk
is said instead. pjajpeg reads a sequential Huffman or lossless scan that
fails with its DRI once more without it, from cleared coefficients, and
marks it (TScan.ignoreRi); the raw bytes keep the DRI. Stream version 6
carries the list of such scans (QUIRKS), which the decoder applies to the
host before rebuilding it; version 5 has no room for it, so the zpaq-std
plugin, which writes version 5 only, refuses these files. The two files:
77.3% and 80.0%, and the corpus is taken whole, 78 of 78.

Anything else that starts like a JPEG (FF D8) and that PJA does not take
goes through the raw bytes' model (version 6, BYTES), with the reason
kept and shown: `a` prints `(as bytes: Truncated@9000)` for a JPEG cut
short, which comes out at 98.97% where xz -9e makes it larger. A file the
model does not shrink either is stored as it is, as before. A file that
does not start like a JPEG is still refused.

With parts, the host's stream is now the host's header stream and the
file's bands, coded once (a host with quirks cannot go through
CompressOne, which writes version 5): the same streams as before. 614
streams of every set compared with the previous build: the same bytes,
and two new, the corpus' two files.

## The pjax codec, for zpaq-std (25/10/2026)

zpaq-std asked for what 0.0.2 added, as new codecs beside the frozen pja
and pjals: one plugin file, each codec with its own ZPAQL (65,535 bytes of
bytecode at most), tried in an order the family fixes. pjax comes first:
the Huffman JPEGs that need stream version 6, with JPEGs inside them
(EXIF thumbnails, MPO, Ultra HDR), 12 bits, a DNL or a DRI with no
restarts; pja keeps every other JPEG, pjals JPEG-LS; lossless JPEG and
subsampled JPEG-LS are for later codecs.

Its decoder shares pja's sources. zpaqlc now compiles an `if` on a
constant as the branch taken alone, and the shared sources test `PJAX`
for what only pjax has: the frozen programs, compiled with `PJAX = 0`,
are the same bytes. pjax reads version 5 as pja does, or version 6: its
parts table and quirk list, each part (a version 5 stream of its own)
decoded first into H, then the host, whose bytes go out with each part put
back where it was, in place of the host's zeros (inside a segment) or
between its bytes (after its EOI). Between two JPEGs, zpaqlc's `fresh()`
puts the decoder's globals and arrays back as they start. The arithmetic
coder is left out (pja keeps those files), which is what makes room:
57,709 bytes. CompressPjax writes only what that decoder reads: Huffman
hosts and parts, parts of one level, no bytes mode; the query sizes H as
the sum of what each JPEG's decoding takes and the parts' bytes.

Checked with libzpaq (zpaq 7.15's engine): every file of the MPO set (6,
5 as version 6) and of the 78-file corpus pjax takes (69, 26 as version
6) back byte for byte; blocks of 4 to 6 files of every kind, version 5
and 6 mixed, back; 300 damaged segments: 299 errors and one the same,
none hanging or crashing. On zpaq-std 1.7.0 with -sat in the family's
order, 116 files: pjax took 36, pja 54, pjals 18, every block ZPAQL OK,
zpaq 7.15 gave every file back, and the archive came out 1.84% smaller
than without pjax. Windows 10, 64 and 32 bits: every block OK, every file
back.

### Which files pjax takes (0.0.4)

zpaq-std measured 0.0.3 on its 79 files and got a larger archive with
pjax than without it (+0.40%): pjax took 15 common photos for their EXIF
thumbnail, and since zpaq-std puts only consecutive files of one codec in
a block, they split pja's blocks into small ones that did not pay their
ZPAQL. Per file, a thumbnail gains 54 bytes to 7.7 KB over pja; the JPEGs
after the EOI (a camera's MPO) 200 KB to 1.15 MB, about a fifth of their
size. pjax's detect now takes 12 bits, a DNL, a DRI with no restarts
(none of which pja takes), or 256 KiB or more of JPEGs after the EOI; the
format and the ZPAQL do not change. zpaq-std -sat in the family's order,
plain zpaq 7.15 giving every file back:

| files | without pjax | pjax 0.0.3 | pjax 0.0.4 |
|---|---|---|---|
| zpaq-std's 79 | 19,451,097 | 19,529,480 (+0.40%) | 19,451,097 (the same) |
| our 116 | 33,355,687 | 32,742,655 (-1.84%) | 32,047,857 (-3.92%) |

On zpaq-std's files pjax takes only the three pja cannot (two 12-bit, one
DRI with no restarts), which go as -m says, as they did without it.

## The pjall codec, for zpaq-std (25/10/2026)

The family's next codec: lossless JPEG (SOF3, Huffman), 2 to 16 bits,
every predictor, a point transform, restarts, a DNL; stream version 5 as
pja writes it for such a file. No other codec takes these files (pja's
and pjax's ZPAQL have no lossless scans), so pjall takes every one its
ZPAQL fits; a block that does not pay goes as -m says, as it would have.

Its decoder adds little to what was there: pja's header parser (pjadec.zl,
whose `if PJALL:` hands an SOF3 to ljpeg.zl), JPEG-LS's samples model
(jls.zl's samplesband, on the samples as LosslessView shows them), and
ljpeg.zl, which writes the scans again as pjajpeg.EncodeScanLossless does.
30,508 bytes of ZPAQL; the other three programs, compiled with PJALL = 0,
are byte for byte as before.

Checked with libzpaq (zpaq 7.15's engine): the 36 synthetic lossless
JPEGs (8, 12 and 16 bits, gray and colour, predictors 1 to 7, point
transforms, restarts) and 60 photos as lossless JPEG (predictors 1 and 6)
back byte for byte; blocks of 6 and 4 segments back; 300 damaged
segments: 299 errors and one the same, none hanging or crashing. zpaq-std
-sat in the family's order on those 96 files with zpaq-std's 79: 151,373,263
bytes with 0.0.4, 128,835,877 with pjall (-14.9%; its photos at 29 to 74%
of their size), every block ZPAQL OK, zpaq 7.15 giving every file back.
Windows 10, 64 and 32 bits: the same archive, every file back without
the plugin.

## The pjalsx codec, for zpaq-std (28/10/2026)

The family's last codec: JPEG-LS whose components are subsampled (T.87's
sampling factors, each component ceil(X h / hmax) by ceil(Y v / vmax)),
which pjals' frozen ZPAQL has not. Stream version 5 as for any JPEG-LS
file, the smaller of the two models. No other codec takes these files.

Its decoder is pjals' with `if PJALSX:` where the frame's size was every
component's, and jlsx.zl: each component's own size, the samples model's
rows in CodeJlsBand's order (subsampled: each component's rows of the
band one component after the other, no context from the first), the
groups of lines of a subsampled line-interleaved scan (CodeLines,
ScanRows), and the symbols model's context of the first component, taken
only from one of the same size. 60,776 bytes of ZPAQL; the other four
programs are byte for byte as before. On the way, a trap in zpaqlc: a
local's place follows the order in which `ast.walk` meets its first
assignment, so moving `total = ...` into an `if PJALSX:` swapped two
locals of pjals; the shared sources now leave the assignment in place and
let the branch overwrite it (tools/zpaql/README.md).

Samples: CharLS (lossless; no interleave and line interleave) subsampled
by PJA's own encoder with factors 2x4/2x1/1x2 (T8SSE0's), 4:2:0, 4:2:2 and
4:1:1, on plasmas of odd sizes and 5 photos, some with restarts (none in
a subsampled line-interleaved scan, which PJA does not take), and T.87's
conformance images T8SSE0 and T8SSE3 (NEAR 3): 67 files.

Checked with libzpaq (zpaq 7.15's engine): the 67 files back byte for
byte, and each with either model forced (136 of 136); blocks of 6 and 4
segments back; 300 damaged segments: 299 errors and one decoded to other
bytes of the same size (the stream has no check of its own; zpaq's
SHA-1 of each fragment catches it), none hanging or crashing. zpaq-std
-sat in the family's order on them with zpaq-std's 79 files: 49,953,561
bytes with 0.0.5, 49,375,481 with pjalsx (-1.16%), every block ZPAQL OK,
zpaq 7.15 giving every file back; zpaq-std's own 001.jls (T8SSE0) is one
of them, which 0.0.5 kept as -m. On the "photos" (JPEGs decoded and
written as JPEG-LS, their 8x8 blocks still in them) zpaq's own -m often
does better than JPEG-LS's models, and zpaq-std keeps -m for those: one
group of 12 went to pjalsx (85.8%). Windows 10, 64 and 32 bits: that
group through the ZPAQL, the same archive, every file back without the
plugin. The suite runs pjalsx's ZPAQL in the Python interpreter on two
small samples.

## Photoshop's EOB runs: a second encoder quirk (29/10/2026)

To look for more quirks, the JPEGs inside the corpus' documents and
archives were taken out (epub, docx, odt, zip, PDF DCTDecode streams):
286 different ones, from as many encoders as the documents had. PJA took
285; the other went as bytes (`NoRoundTrip`): a progressive JPEG from
Photoshop. Its scans decode, but the rebuild differed in the last one, an
AC refinement: Photoshop ends an EOB run once it holds a bit over 256
correction bits, where libjpeg goes on to 937 (jcphuff.c's MAX_CORR_BITS
- 64 + 1). The coefficients are the same; only where the runs are cut
differs, so this too is a quirk to say, not a patch.

pjajpeg's decoder now watches each refinement scan's runs: the correction
bits a run held and went on (the limit is at least that), and those of a
run that ended for no other reason than its bits, when the next block
starts with an EOB of its own and the run was shorter than the table
allows (the limit is less). If libjpeg's 937 fits, the scan is libjpeg's;
if not, the smallest limit that fits (TScan.maxBe) rebuilds it: for the
Photoshop file, 252. Stream version 6 carries the scans with another limit
and the limit (CORRECTION, flag bit 2); version 5 has no room for it, so
CompressOne refuses these files as before, and the zpaq-std plugin's
detects say no to them (pja and pjax), as with the DRI quirk.

The file: 77.45% as bytes, 61.46% now. The streams of every other file
are the same bytes as 0.0.7's: tests' 37 (the CI's hash unchanged), the
78 and 93 corpus JPEGs, the 151 photos, the 244 arithmetic ones and the
other 285 of the 286. New sample `prog_correction_limit.jpg` (a blurred
plasma, progressive, its refinement scans re-encoded ending runs at 2
bits; djpeg gives the same pixels as libjpeg's own); test_tolerances
re-encodes refinement scans with limits of 1 and 4 bits and checks that
layer 1 finds a limit that rebuilds them, that version 6 holds it and
that version 5 refuses it.

## A faster mode with rANS, explored (29/10/2026)

Aqueous (`aqr`, measured in the README) is 7% larger than PJA on the 151
photos but 6 to 13 times faster. Its JPEG model is static: two passes,
each image's frequency tables stored, a few symbols per block (the count
of nonzero ACs; each AC's bit length by position, nonzeros left and
neighbours' counts; the DC from its neighbours' edges) through rANS, and
the mantissas and signs as raw bits. No predictions of the edges.

Could a rANS mode of PJA's sit in between? Measured on 30 of the photos,
the coefficients only, with a probe (`rprobe`: the ideal cost of each
design with adaptive multi-symbol tables) and then a coder (`rcoef`, in C
with SSE2: adaptive tables of 16 symbols in the AV1 way, of a fixed total
so that two can be averaged, rANS, raw bits apart), every image back:

| design | coefficients against `--fast`'s |
|---|---|
| Aqueous's contexts, tables adaptive | +5.3% |
| + the first mantissa bit and the sign modeled | +4.2% |
| + PJA's neighbour magnitude, nonzero count by the luma for chroma | +3.6% |
| + a second table by the neighbours in the block, averaged | +3.3% (ideal) |
| the same as a coder, AV1-style adaptation | +7.4% |
| the coder without the average | +8.2% |

Speed, 30 photos, one thread: `--fast` decodes them in 5.1 s (the whole
`pja x`); the coder decodes their coefficients in 3.1 s in plain C, 1.7 s
with SSE2, 1.5 s without the average. About 2.5 times `--fast`, Huffman
re-encoding included, for 7% more: larger than packJPG and than Aqueous.

Where the gap is: not the edges (+1.7% without PJA's edge predictions);
it is the adaptation. A multi-symbol table that adapts by a shift learns
less than PJA's counters with their counts, and adapting by counts needs a
division per symbol, which is the cost rANS was meant to save. Static
tables, as Aqueous's, are what make it fast, and they land where Aqueous
does: about 80%, 5% more than `--fast`.

Not done: a mode between packJPG and Aqueous in size is no use to anyone,
and one as fast as Aqueous would be Aqueous's ratio. PJA's place is the
ratio; for speed it has threads (8 threads: the 151 photos in 9.9 s
`--fast`). The probe and the coder are in the author's lab
(`/mnt/IA_LAB/agentes/pja/rans/`).

## Stream version 7: the full model's size at the fast model's speed (29/10/2026)

The full model was 1.7% smaller than the fast one and took 1.8 times its
time. Version 7 is the full model (its contexts, mixers, counters and
predictions) with fewer decisions, its coefficient loop in C
(`pas/pjav7c.c`, `pas/pjav7c_loop.h`, through `pas/pjav7.pas`). `pja a`
writes it; versions 5 and 6 are still read, and the zpaq-std plugin, which
does not use pjav7, has no C in it and writes what it wrote.

Where the time went (callgrind, `pja x` of 3 photos; perf is not allowed on
the machine): the mixed decisions, about 380 instructions each, 41% of the
instructions and 70% of the L1 misses, the loop around them 33%, the
arithmetic decoder 9%, the edge and DC predictions only 6.5%. On 30 photos
the full model took 122 million binary decisions for the coefficients.

Fewer decisions (30 photos, every file back):

| change | decisions | cost |
|---|---|---|
| each edge's count of nonzeros first (3-bit trees, mixed), then its flags while some are left | edge flags 30.2 M -> 18.7 M | +2.8 KB |
| the interior's signs as direct bits (0.998 bits each modeled) | -8.5 M modeled | +1.7 KB |
| the interior count as its bit length in unary (mixed) and the bits below (two counters) | 12.9 M -> 6.75 M | +0.1 KB |
| (not kept) the mantissa below its first bit as direct bits | | +16 KB (0.18%) |

Then the loop in C, a copy of `pjacoef.inc`'s arithmetic, one text compiled
once per direction. A first step, only the mixed decision's kernel in C
called from the Pascal loop, gave 6%: the cost was not the arithmetic but
the counters' cache misses and the calls. The whole loop in C, with the
arithmetic coder without branches both ways, the prediction kernels in 32
bits (half the cache) and an SSE2 nonzero mask, was bit for bit what the
Pascal version of the same model wrote (Pascal encoding and C decoding, and
the other way round). It is compiled with -O3 and once more for SSE4.1,
chosen by pjamodel's cpuid check (`PJA_NOASM=1` turns it off): 4.62 against
5.73 G instructions with -O2.

The 30 photos, one thread, three alternating rounds (compress without
verify / decompress, `pja`):

| | size | compress | decompress |
|---|---|---|---|
| full model (version 5) | 9,029,356 | 11.15 s | 9.22 s |
| fast model (version 5) | 9,187,750 (+1.75%) | 6.74 s | 5.29 s |
| version 7 | 9,033,933 (+0.05%) | 6.80 s | 5.40 s |

Every set, 8 threads, against the full model, every file back: photos
+0.13%, the corpus of 78 +0.20%, MPOs +0.24%, arithmetic-coded +0.10%,
generated +0.11%. `--fast` still parses and changes nothing.

The C part takes no memory and calls no library (pjamodel hands it the
tables, the counters and the scratch; two callbacks carry the encoder's
bytes out and a live stream's bytes in), so it links with FreePascal alone
on every platform: `pas/build_c.sh` builds the object without a stack
protector, without loops turned into memset and, on 32-bit x86, without
PIC and without libgcc's 64-bit division. The suite checks version 7's
streams in the reference, fast, no-asm and 4-thread builds and with the C
part built without SSE2, and damages them as the other streams (166,465
variants, no failure); CI compares their hash across the six platforms.

### Version 7's contexts (29/10/2026)

What paq8px has that PJA did not, one context at a time, measured on the 30
photos (`pja a`, 8 threads, every file back) with a cost per decision kind
first: an encoder build that adds up -log2(p) of every bit by kind
(interior zero flag 1.30 MB, interior exponent 1.26 MB, interior sign 1.03
MB, edge exponent 0.99 MB, edge mantissa 0.86 MB, interior mantissa 0.78
MB, edge sign 0.59 MB, edge counts 0.56 MB of which 0.21 MB chroma, the
DCs 0.68 MB). The time is callgrind's estimate on 3 photos, one thread
(instructions + 15 x mispredicted branches + 10 x L1 read misses), enc and
dec. A mixer input costs about 1.5% of that in the interior's decisions,
so one stays only where it pays at least what the full model paid over
the fast one, about 1.5 KB per 1% of time.

Kept, in the order they went in (photos30, cumulative):

| change | photos30 |
|---|---|
| version 7 as it was | 9,033,933 |
| chroma: the luma block's coefficient at the same position (finelog), an input of the interior zero flag and exponent, the edge zero flag and exponent | -58.4 KB |
| chroma: the interior sign by the luma's and (Cr) the Cb's sign there; luma's stays a direct bit | -20.7 KB |
| Cr: the Cb block's coefficient at the same position, in the same four decisions; the edge signs by the luma's and the Cb's | -63.0 KB |
| the edge counts by the luma's and the Cb's counts on the same edge | -18.2 KB |
| the first mantissa bit with a second counter by the neighbourhood; the interior count by the blocks above left and above right and the Cb's count | -14.8 KB |
| the expo by the nonzeros so far on the coefficient's row and column of the block | -6.5 KB |
| luma: in the interior inputs that are the luma's or the Cb's for chroma (constant for luma), the sum of the magnitudes coded so far in the block, and how far back the last nonzero was | -15.7 KB |
| the mantissa's bits below the first by the position's bucket (edge: the position), the bit length and the bit | -4.6 KB |
| out: interior zero inputs (k, lz, rem) and (k, rem, neighbours); edge zero inputs but the remaining-count one, the neighbours' and the luma's; the edge count's input repeated with the row count; the count's first counter | -1.2 KB, 9 inputs fewer |
| the interior exponent's (bucket, in-block neighbour) input replaced by (position, neighbourhood) | -9.1 KB |
| luma: the edge count by the interior's nonzeros on the row (column) next to the edge and the count's bucket; Cb the same in the Cb's slot | -5.7 KB |
| the edge mantissa's bits by where the edge's prediction falls against the two halves left (five cases, the fifth without a prediction) | -13.2 KB |
| luma: the edge sign by the neighbours' signs along and across the edge | -1.5 KB |
| the DC zero flag and exponent by the Cb's (Cr) or the luma's (Cb) DC residual size, the sign by its sign | -4.2 KB |
| out: the interior exponent's (bucket, neighbours) and (neighbourhood) inputs, 7 -> 5 | +4.4 KB, time -2.8% / -3.5% |
| out: the interior zero flag's ratio input, 5 -> 4 | +2.3 KB, time -3.0% / -3.5% |
| the interior's first mantissa bit's second counter also by the component context (16) | -2.1 KB |
| luma: the edge zero and exponent by the interior's sum, and by the neighbour across the edge | -4.4 KB |

Measured and not kept (photos30, against the state they were tried on):
the luma's magnitude summed over the 2x2 luma blocks of a 4:2:0 chroma
block -0.2 KB, its count averaged -0.7 KB; the luma's sign with its
magnitude -0.3 KB worse; luma's interior sign by the above and left
blocks' signs at the same position -0.8 KB; the interior's zero flag by
its row and column counts, worse once the inputs were full; the mixers'
weight sets also by the remaining count (+2.8 KB), the neighbourhood
(+0.6 KB), the exponent's by the neighbourhood (+2.0 KB); the mantissa
bits below the first with the value's two bits above (-1.9 KB) or with a
second counter (-7.2 KB, a counter more per bit); for the luma's spare
slots: row and column counts -2.1 KB, the above and left blocks' sizes
-0.6 KB, the last nonzero's size -4.2 KB (all instead of the sum, -13.2
KB); for the interior zero flag, once the two weak inputs were out, the
sum with the neighbourhood -0.2 KB, (position, two neighbourhoods) +0.6
KB, the count so far -0.4 KB, the last nonzero's distance and size -0.8
KB; in place of the zero flag's two remaining neighbourhood inputs one
joint context, (position, both neighbourhoods) +3.3 KB, (position,
neighbourhood, remaining) +6.3 KB; the edge mantissa's prediction counter
next to the old one -2.2 KB more for a counter per bit; luma's DC sign by
the neighbours' residual signs +1.3 KB, the DC by the block above right's
residual size 0; the luma's interior exponent by the sum and the
neighbourhood or the remaining count, worse; luma's edge count by the
interior count of the same row +0.75 KB worse, by the neighbour along the
edge +1.5 KB worse; the count's luma slot by the DC residuals around +0.2
KB, by the block two to the left -0.5 KB (not worth the code); the first
mantissa bits with one counter, interior +5.8 KB, edge +1.5 KB.

The tables these take are named in `TCoefModel` (`InitV7`) and sized to
their contexts, about 450 KB a model. They see the components coded before
them in the band: pjamodel hands the C the luma's coefficients and DC
residuals and the previous component's when it has the same size (Cr after
Cb). The DC residuals keep their sign above their size.

The luma's coefficients go to a chroma component only when its vertical
sampling divides the luma's (`CodeBand`): with luma 1x3 and chroma 1x2, both
legal, a chroma row maps to luma rows of the band before, which a decoder of
this band need not have yet (bands decode in parallel). The first version
read them anyway: the encoder has every row, so it round-tripped by luck of
the timing and failed when the bands were decoded last first. The suite now
decodes generated multi-band JPEGs (1x3/1x2 and 4:2:0) last band first
(`PJA_BANDS_REVERSE=1`, one thread), which fails on any band reading what
an earlier band decodes. The fix moves no byte on the sets measured here.


## Version 7's counters and mixers (29/10/2026)

Measured on the 30 photos (sizes; time as callgrind's estimate, `pja a`
and `pja x` of 3 photos, one thread). The mixers were the lever, not the
counters, and mostly by taking away.

Kept, in the order they went in (30 photos, from 9,033,933):

| change | 30 photos |
|---|---|
| the constant input at 384 instead of stretch(0.625), about 131 | -5,935 |
| the edge zero flag's weights by position, nonzeros left and positions left (896 sets) | -2,456 |
| four inputs out: zero1 (interior zero flag), ezero1 (edge zero flag), dcZero (DC), ec1 at cb (edge count) | -1,118, 4.5% fewer instructions |
| learning rate per decision: 4 for both zero flags, 10 for the edge exponent, 6 the rest | -1,528 |
| weights start at 4/3 of an equal share, the constant's at zero | -2,784 |
| the edge exponent's weights also by how many nonzeros are left after this one (0..3+) | -13,125 |
| the interior exponent's also by the ratio of nonzeros left to positions left (in eighths), the edge count's by the interior count's | -8,870 |

Together 8,998,117 (-0.40%, now 0.35% under the full model of version 5),
the corpus of 78 23,753,540 (-0.26%), the 244 arithmetic-coded 5,092,954
(-0.49%), every file back. Time -4.5% compressing, -5.6% decompressing
(callgrind's estimate: the four inputs and the constant that is no longer a table read; the
bigger weight tables take back a little in cache misses).

Measured and left out:

- Mixing in two weight sets chosen by different contexts, their outputs
  averaged in the logistic domain (paq's several selectors): -8,518 at the
  four biggest decisions, but +20% of time (+11% once `restrict` let the
  compiler vectorize the two updates); at the interior zero flag alone
  -2,700 for +4%. A learned final mixer instead of the mean: the same.
- An APM after both exponents (33 interpolated counters by exponent and
  neighbour magnitude, the nearer one learning, a quarter mix): -1,507
  more for +5% of instructions.
- The counters in more precision: 24-bit probability -419; 22-bit with
  a 10-bit count, limit 255/511/1023: -423/-1,541/-99 (every `learn`
  costs more). Only for the counters coded alone: +50 to +3,089; a limit
  of 127 for them +1,248. Version 5's limit of 255 stays.
- A count-based confidence (the stretch scaled down for young counters):
  +273 to +8,109. The squash in 16 bits (interpolated): -8. A learning
  rate that starts high and decays (per weight set, counted in an unused
  lane): -946 at best, not worth a division. The weight clamp at 2^18 and
  more: never reached.
- Other selectors: the interior zero flag by remaining count (+2,615, or
  +211 in three classes) or by neighbour magnitude (+606); the edge zero
  flag by prediction (+3,110); the nonzero count by the neighbours' (+1,127);
  the DC's (-6, -62, +39); the edge exponent's by prediction class or by
  the count instead of what is left (+1,899, -10,960 against -13,125);
  the interior exponent's by the remaining count's bucket (-1,269; the
  ratio instead, 6,581 less again), by the ratio in sixteenths, sixths or
  quarters or without the coefficient's class (all 750-1,800 behind).
- Dropping any other input: from +432 (the nonzero count's first) to
  +55,528. And what is left on the edge as a counter context of the edge
  exponent instead of the mixer's: +4,983.

The ratio selector is defined as 16 (its ninth weight set) when every
position left is nonzero: RATIO_OF has no column for that case, and the
first version read one byte past the table there, for a block with all 49
interior coefficients nonzero (the integration, below).


## Stream version 7: the predictions, a second pass (29/10/2026)

Version 7 is not released, so its stream could change. Where the bits went
(30 photos, the ideal cost of each kind of decision, a debugging build of
`pjav7c.c` with `PJA_V7_STATS`, which calls the C library; left out of the
merged source): interior zero flags 1311 KB, bit lengths 1285 KB, signs 1060 KB
(direct bits), mantissas 788 KB, counts 442 KB; edge bit lengths 1019 KB,
mantissas 861 KB, signs 632 KB (0.86 bits each), counts 583 KB, zero flags
321 KB; DC 678 KB, its sign 0.99 bits.

Each change measured alone, in order, on the 30 photos (`v7bench.sh`, every
file back), kept when smaller:

| change | photos30 |
|---|---|
| version 7 as released to the branch | 9,033,933 |
| the edge sign also by the coded magnitude against the prediction's (`rel`, 9 steps) | -20,118 |
| the edge prediction also in quarters of a quantum (`pbq`) for the edge zero flag, bit length and first mantissa bit; both roundings from one truncated division in eighths, exact | -1,079 |
| the DC prediction in eighths: the eighths left over (`frac`) as a context of the DC sign | -2,855 |
| ... and of the DC zero flag | -803 |
| the DC from the middle ten of the 16 estimates (the middle eight before; six of 8 on one side) | -322 |
| the DC sign averaged with a second counter by the above and left residuals' signs | -1,793 |
| the edge sign averaged with a second counter by the position, the prediction and whether this edge's last sign agreed with its prediction | -5,855 |
| the first sign counter on `pbq` | -906 |
| the second also by the same coefficient's sign in the block along the edge, and in the block across it | -3,732 |
| the 14 edge predictions first (they need the interior and the block across only): how many are big (1.5 quanta) plus how many very big (10) as a context of each edge's count | -6,890 |
| the DC spread between the 4th smallest and the 4th largest estimate (both already at hand) instead of the whole range | -8,234 |
| that spread in quarters of a quantum | -679 |
| `pbq` from 4/8 of the prediction instead of 5/8 (where the half-octave buckets fall) | -1,670 |
| the second sign counter on 3 steps of the prediction (22 before), the first on 13 (26) | -4,731 |
| the DC sign's first counter on half the spread's steps | -61 |
| the edge mantissa's bits below the first by where 5/8 of the prediction falls in the interval still open (below, lower half, upper half, above) | -717 |

Tried and dropped: the sign's `rel` over 13 steps (+822); the sign from
the quarter prediction's sign (+48); the DC exponent by `frac` (+150);
each side's trimmed mean weighted by the other side's spread (+8,740) or
not weighted (+5,310): the trim over all 16 is better; trimming 2, 5 or 6
of 16 at each end instead of 3 or 4 (+550 to +2,800); the middle four
counted twice (+520); the neighbours' residual signs inside the DC sign's
context (+7,650: nine times the contexts) instead of a second counter; the
DC sign mixed from three counters (-550 more, for a mixed decision per
nonzero residual: not worth its time); the agreement inside the edge
sign's context (+2,312) instead of a second counter; the edge bit length's
mixer selected by the prediction's bit length against the one being coded
(+2,500); the number of big predictions left on the edge in place of the
positions left (redundant with the position) (+311); the edge count with
five inputs (+251); no integer prediction, everything from the quarter one
(+1,975); the sign's `rel` centered elsewhere (+30, +340); the previous
edge coefficient's sign in the second sign counter (+2,163); the first
sign counter per position (+2,301); the spread between the 2nd, 4th or 5th
smallest and largest (+800 to +4,800).

The time: the edge sign is now two counters, and the 14 predictions are
computed for every block (before, only up to the last nonzero of each edge).
Their interior sums are one pass over the interior's nonzeros, and "big" is
an integer comparison of the numerator with a threshold per component
(exact: 2|n| >= (2 PTH - 1) 181 q), the division done only where a
coefficient is coded. Every set, the C part built plainly
(`PJA_V7_PLAIN`), with `PJA_NOASM=1` and with one thread give the same
bytes.

All of it (`v7bench.sh`, 8 threads, every file back; callgrind on 3
photos, one thread, est = Ir + 15 mispredictions + 10 L1 read misses):

| | photos30 | corpus (78) | arithmetic (244) | encode est | decode est |
|---|---|---|---|---|---|
| version 7 before | 9,033,933 | 23,815,570 | 5,118,141 | 5.949 G | 5.285 G |
| version 7 now | 8,973,488 | 23,706,569 | 5,076,390 | 6.203 G | 5.481 G |
| | -0.67% | -0.46% | -0.82% | +4.3% | +3.7% |

0.6% smaller than the full model of version 5 on the photos (9,029,356),
for about 4% more time than version 7 had: some 0.16% of size per 1% of
time, seven times the rate at which the full model bought its size over the
fast one.


## Version 7: signs, mantissas and the component before (29/10/2026)

Signs and mantissas were about 35% of version 7's output, coded at 0.86 to
1.0 bits per decision. Shadow models first (a counter per candidate
context, run beside the coder without touching the stream, its ideal cost
added up; 30 photos, one thread), then each change in the coder, measured
with the deterministic harness (sizes of `pja a` on the 30 photos; est =
callgrind's instructions + 15 x mispredictions + 10 x L1 misses on 3 of
them, one thread). Before: 9,033,933 bytes, est 5.949 G to compress and
5.285 G to decompress.

What the shadows said, on the 30 photos:

- the interior's signs (1,060 KB as direct bits): the neighbours' signs at
  the same place, the signs above and left in the block, and votes from the
  block's rank-1 structure (F(u,v) F(u',v') ~ F(u,v') F(u',v), each known
  (u',v') voting sgn F(u,v') F(u',v) F(u',v')) give at best 0.7 to 1.0%
  (7 to 10 KB);
- an edge's sign: how its magnitude compares with the prediction's (half
  octaves of |v| minus the prediction's bucket) takes 20 KB of 632; finer
  buckets, the edge position, the rank-1 vote in the same context dilute;
- the DC residual's sign (147 KB): on which side of the prediction the DCs
  left and above are takes 13.6 KB (finer sides, the sides against |res|,
  a diagonal: no better);
- the first mantissa bit: the interior with the neighbours' magnitude sum
  (mbS) 4.4 KB, the edges with their position 7 KB; the second bit with the
  frequency bucket 2.8 KB (interior) and the prediction and first bit 3 KB
  (edges); the bits below: nothing;
- the component before: in a band Y, Cb and Cr are coded in turn, so when
  Cr is coded the Cb of the same rows is known both ways (Cb's own partner
  is Y in 4:4:4). The sign of the partner's coefficient at the same place
  takes a third of the chroma signs: interior 109 -> 72 KB, edges 114 ->
  76 KB, DC 54 -> 48.5 KB (the partner's DC moving up or down from its
  left and above neighbours).

In the coder, 30 photos (bytes; est against the step before):

| change | photos30 | compress est | decompress est | kept |
|---|---|---|---|---|
| edge sign + magnitude against prediction (esign2) | -20,118 | +0.46% | +0.21% | yes |
| edge 1st mantissa bit + edge position (emant1b) | -7,342 | 0 | 0 | yes |
| interior 2nd mantissa bit, own counters by frequency bucket (mant2i) | -3,215 | +0.19% | +0.25% | yes |
| edge 2nd mantissa bit by prediction and 1st bit (mant2e) | -3,170 | -0.03% | -0.20% | yes |
| interior 1st mantissa bit by mbS (mant1s) | -4,703 | +0.21% | +0.08% | yes |
| the same, averaged with a second counter by mbI | -6,360 | +0.93% | +0.72% | no |
| interior signs with a counter by the rank-1 vote (bit masks, popcounts) | -7,374 | +2.9% | +3.0% | no |
| edge signs mixing esign2 with the rank-1 vote | -13,938 | +3.0% | +3.3% | no |
| DC sign by the sides of the DCs left and above (dcSign2) | -14,090 | +0.21% | +0.22% | yes |
| chroma signs by the partner's (isignp, esignp, dcSign2) | -81,876 | +0.41% | +0.54% | yes |
| chroma 1st mantissa bit by the partner's magnitude | -3,148 | +0.50% | +0.45% | no |
| chroma zero flag and exponent (interior) with the partner's magnitude in one input | -26,363 | +0.17% | +0.42% | yes |
| the same on the edges | -27,281 | +0.48% | +0.61% | yes |
| chroma interior count with the partner's in place of the luma's | -2,419 | +0.74% | -0.07% | no |
| chroma edge counts with the partner's | -14,845 | +0.62% | 0 | yes |
| chroma DC zero and exponent with how much the partner's DC moves | -1,220 | +0.08% | +0.10% | no |

The partner is the component just before when it has the same sampling
and grid (`CodeBand`; `TV7Work.partner`, `partKind` 0 for the luma, 1 for
a chroma); its tables have a bucket for "no partner", so the luma and a
4:2:0 Cb index the same tables without a branch. Small changes of the big
C loop move gcc's register allocation and layout: the cost of several rows
above is that, not their work (the edge partner tables chosen by a branch
cost 0.3% more than the same model without it).

All of it together, 8 threads, every file back: photos 9,033,933 ->
8,830,930 (-2.25%), the corpus of 78 23,815,570 -> 23,583,298 (-0.98%),
arithmetic-coded 5,118,141 -> 5,085,560 (-0.64%); est to compress 5.949 ->
6.102 G (+2.6%), to decompress 5.285 -> 5.405 G (+2.3%).


## Stream version 7: the C core, faster (29/10/2026)

The same streams, byte for byte (30 photos 9,033,933 bytes before and
after; every stream compared with the old one's), in less work. Measured
with callgrind (`pja a --no-verify` and `pja x` of 3 photos, one thread),
as est = instructions + 15 x mispredicted branches + 10 x L1 read misses;
each line on the one before it (some on a state that still had a dropped
change: the numbers are each run's own).

| change | encode est | decode est | kept |
|---|---|---|---|
| (start) | 5.949 G | 5.285 G | |
| a counter's step as an unsigned 32-bit product toward its target (65535 - p or p - 1, times rc[n] < 2^32), not a signed 64-bit one truncated | -4.8% | -5.9% | yes |
| the coder without its clamp (p is always in [1, 65535] here), the interval by selects | -3.0% | -2.6% | yes |
| the mixer in SSE4.1 intrinsics (4-lane dot product and update; the lanes past n are 0 and stay 0) | -4.9% | -4.4% | yes |
| the four prediction kernels in one pass, in uint32 lanes (pjamodel only uses their sums modulo 2^32), the edge caches in 32 bits | -7.3% | -8.7% | yes |
| the counter's update with masks, no select | +4.9% | +4.7% | no: 207 M more instructions |
| NeighbourMag set up once a block (a block of zeros for a missing neighbour, the division as an exact multiply) | -0.9% | -0.5% | yes |
| the 16 DC estimates sorted as a bitonic network in four lanes (only min, max and the middle 8's sum: their order inside a set is not needed) | -3.0% | -3.7% | yes |
| the interval with xor masks, no branch | +0.3% | +0.5% | no: 1.5 M fewer mispredictions, 43 M more instructions |
| the counter as one 32-bit word (one load, one store) | +2.8% | +4.5% | no: 178 M more instructions |
| stretch, squash and reciprocals copied into static C arrays | +0.8% | +0.9% | no: position-independent code needs an address for each |
| ladders and mantissas in rows of 16 counters (a cache line), every table on a line | -0.6% | -0.4% | yes (the L1 misses did not move: they are capacity misses) |
| the encoder's bytes in a 4 KB buffer, out by the block | -1.0% | 0 | yes |
| the weights of each mixer selector on one cache line | -0.7% | -1.0% | yes (mostly the static arrays' revert; this alone about -0.1%) |
| the counters learned in two loops, the bit a constant in each | -0.4% | -0.6% | yes |
| a third copy of the loop for AVX2 (cpuid, OSXSAVE and XCR0; `PJA_NOAVX2=1` turns it off): the mixer's 8 lanes and the kernels' 32 in 256-bit vectors | -3.7% | -4.1% | yes |
| (end) | 4.39 G (-26%) | 3.84 G (-27%) | |

What did not help says where the time is: in this one big function the
compiler's register allocation decides more than the instruction count
of a helper, so a change that looks shorter can be longer (the word-sized
counter, the static tables), and a branch it makes of a select is cheaper
than the masks that avoid it. The L1 misses (about 41 M on the 3 photos)
are mostly the counters, scattered over tables much larger than L1, with
stretch, squash and the kernels (24 KB) taking most of it: aligning the
rows did not lower them. Software prefetch was not tried: callgrind does
not model it, so this measure could not see it.

The suite also checks the SSE4.1 copy where the AVX2 one would run
(`PJA_NOAVX2=1`), against the reference without asm and the C without
SSE2.


## Around the model, in C (29/10/2026)

With version 7's loop in C, what is not the model was a fifth of
compressing: the JPEG's own Huffman decoding and re-encoding (the round
trip that allows storing it), BLAKE3, the search for embedded JPEGs. None
of it changes a byte of any stream (the suite: every stream of every
model the same in every build, and the JPEG layer's verdicts on 538,351
damaged variants the same with the C and with the Pascal).

`pas/pjasysc.c`, built by `pas/build_c.sh` beside `pjav7c.c` and taken by
`pjav7.pas`, which installs it at start-up in units that stay Pascal
(`pjablake3.Blake3Chunks`, `pjajpeg.HuffEncodeScan` and
`HuffDecodeScan`): the zpaq-std plugin, which does not use pjav7, has no
C in it and runs the Pascal; so does `PJA_NOASM=1` for the Huffman scans,
which the suite compares with the C (`test_jpeg`, and a sum of the
verdicts of `test_jpeg_corrupt`). Like `pjav7c.c` it takes no memory and
calls no library.

- **The Huffman scans both ways**, sequential and progressive. The writer
  gives the same bytes whatever its drain policy; on a symbol a table
  lacks it answers "not written" and `EncodeScan` writes the scan itself,
  for its own error and position. The reader takes the path a well-formed
  scan takes, with every check the Pascal makes (data that runs out, a
  code the table lacks, a coefficient out of range, the padding, the
  restart markers); on anything else it hands back the state at the start
  of that unit (the reader, the predictions, the EOB runs and the bounds
  of the correction bits) and `DecodeScan` goes on from there in Pascal.
  What the C wrote of that unit is written again the same way (values put
  where they were, bits or-ed in again); an AC refinement block, whose new
  coefficients would change how it is read, is only written once read.
  Every block is checked inside its component before the C runs, and
  `THuff` is taken as it is (its layout checked at start-up). The AC
  reader has a second 9-bit table that gives the coefficient itself when
  its code and its extra bits fit; the writer one word per symbol, code
  and length.
- **BLAKE3**: every whole chunk but the input's last, four at a time in
  SSE2 lanes (one chunk per lane); the plain path one at a time.
  `test_blake3` checks both against the official vectors.
- **The host of embedded JPEGs** (a camera photo's EXIF thumbnail, zeroed
  in the host to see whether storing it apart pays) was decoded and
  re-encoded whole a second time. `VerifyRoundTripFrom` takes each scan
  from the file's own round trip when its header, its tables, its place
  and its bytes through the marker that stops the reader are the same,
  and the frame too: then decoding it would give the same coefficients
  and the same padding, and the rebuild would be the host itself, since
  `VerifyRoundTrip` saw each scan's bytes come out exactly where they were
  (`TScan.dataStart`, `dataEnd`, `TJpeg.scansExact`). All the scans or
  none: otherwise the whole work, as before.
- Small: the search for embedded JPEGs jumps from FF to FF (`IndexByte`)
  instead of comparing every byte; version 7's encoder puts its bytes
  without a range-check call each.

Callgrind as the bench measures it (Ir + 15 mispredictions + 10 L1 read
misses), one thread, 3 photos (`pja a --no-verify` / `pja x`):

| step | compress | decompress |
|---|---|---|
| version 7 as it was | 5,949 M | 5,285 M |
| embedded-JPEG search by FF | 5,893 M (-0.95%) | = |
| BLAKE3 four chunks at once | 5,831 M (-1.0%) | 5,238 M (-0.9%) |
| sequential scans written in C | 5,653 M (-3.1%) | 5,063 M (-3.3%) |
| sequential scans read in C | 5,285 M (-6.5%) | = |
| the v7 encoder's bytes without range checks | 5,259 M (-0.5%) | = |
| one word per symbol (writer) | 5,258 M | 5,057 M |
| the coefficient from the AC table (reader) | 5,230 M (-0.5%) | = |
| progressive in C, state handed back per unit | 5,234 M (+0.08%) | 5,055 M |
| the C's tables in the caller's record | **5,217 M (-12.3%)** | **5,044 M (-4.6%)** |

The same sizes everywhere (30 photos 9,033,933, the corpus of 78
23,815,570, the 244 arithmetic-coded 5,118,141), every file back.

On files the 3 photos do not have (the same measure): three photos with
an EXIF thumbnail, one of them progressive, compress in 7,491 M against
9,153 M (-18%: the host's scans taken from the file); three progressive
photos compress in 3,253 M against 3,948 M (-18%) and decompress in
2,804 M against 3,206 M (-13%).

Tried and dropped: version 7's encoder writing its bytes into the
encoder's array from C, calling Pascal only when full (+10 M
instructions: the check inlined into every coded bit costs more than the
1.08 M calls it saves); in the reader, keeping only the reader's four
words and, sequential, not the EOB state at the start of each unit (+2.7 M,
the copy of the whole state is cheaper as the compiler lays it out). The C
keeps its tables (8 KB a scan each way) in the caller's record, not on its
stack: a frame over a page calls a stack probe on Windows, which is
libgcc's.

## Version 7, the six lenses together (29/10/2026)

The six sections above were measured each alone on 089218b. Then each was
applied on top of the others, best value first (size, then speed), the
verifiers' fixes with them, and measured again with `v7bench.sh quick`
(photos30, callgrind on 3 photos), so that a gain counted twice would show:

| step | photos30 | enc.est | dec.est |
|---|---|---|---|
| 089218b | 9,033,933 | 5.949 G | 5.285 G |
| + contexts, with the fractional-sampling fix | 8,797,262 (-2.62%) | 6.528 G | 5.850 G |
| + predictions | 8,753,598 (-43,664) | 6.742 G | 6.075 G |
| + signs and mantissas: the DC sign by the DCs around against the prediction | 8,746,266 (-7,332) | 6.748 G | 6.070 G |
| + counters and mixers | 8,724,840 (-21,426) | 6.794 G | 6.100 G |
| the ratio selector at 16 when every position left is nonzero | 8,724,800 (-40) | 6.793 G | 6.103 G |
| + the C core, faster (no table layout) | 8,724,800 | 5.164 G | 4.528 G |
| + its table layout, redone for the merged tables | 8,724,800 | 5.136 G | 4.495 G |
| + around the model, in C | 8,724,800 | 4.429 G | 4.270 G |

Against 089218b: 3.42% smaller on the photos, and 25.5% less estimated
time to compress, 19.2% less to decompress. The full harness on the
result, every file back: photos30 8,724,800, the corpus of 78 23,209,553
(-2.55%), the 244 arithmetic-coded 4,985,273 (-2.60%), enc.est 4.429 G,
dec.est 4.270 G. Version 7's streams are the same byte for byte with the C
built without SSE2, the SSE4.1 copy (`PJA_NOAVX2=1`), no asm, the -O2
reference build and 8 threads, on all three sets. The version 5 full model writes
9,029,356: version 7 is now 3.37% smaller than it.

How the lenses met:

- **Contexts and signs-and-mantissas overlap.** Both read the component
  coded before (contexts: the luma block over a chroma block and the Cb
  block at Cr's place; signs and mantissas: the "partner", the previous
  component when it has the same sampling, which in 4:4:4 is also the luma).
  Its partner signs, partner magnitudes in the zero flags and exponents,
  partner edge counts, interior first mantissa bit by mbS and second edge
  mantissa bit all have a contexts counterpart (`iSign`, `eSgn`, `zLum`,
  `zCb`, `xLum`, `xCb`, `ecX`, `mFirst`, `eMant`), so they were not
  merged. Of what has none, the DC sign's first counter by which side of
  the prediction the DCs left and above are (E7) stacked (-7,332, 1,134
  counters); the edge first mantissa counter by position (E2) did not
  (+1,391, dropped). Its first-sign context d is the predictions' rel.
- **Predictions on top of contexts.** The edge sign became one average of
  two counters: predictions' first (`esr`: the prediction's sign and
  quarter-size against the size coded, rel) and a second (`eSgn`) by
  position, agreement of the last sign with its prediction, the
  prediction's sign and size, and the two signs contexts chose (luma: the
  same coefficient left and above, as predictions' ns/ns2; chroma: the luma
  and the Cb sign here). The edge count got pcn as a fifth input next to
  contexts' `ecX`. The DC sign is the average of `dsf` (spread, eighths of
  the prediction, and E7's sides) and `dsX` (the neighbours' residual
  signs, the eighths, the other component's residual sign); contexts'
  `dzX` and `dxX` follow the finer spread (`ACT2_BUCKETS`). The DC residual
  bytes keep predictions' sign coding (bits 4-5: 0 zero, 1 positive, 2
  negative), which contexts reads as is. The edge mantissa stayed contexts'
  (13.2 KB against predictions' 0.7 KB), its first counter on the quarter
  prediction; predictions' `emq` was not merged. 72% of predictions' gain
  survived (-43,664 of -60,445) for +3.3% / +3.8% est.
- **Counters and mixers on top.** Its constant input of 384, rates by
  decision, starting weights and selectors carried over to the larger
  mixers (now 3 to 7 inputs); its dropped inputs had already been dropped
  or replaced by contexts. 60% of its gain survived (-21,466).
- **The C core's mixer, generalized.** Its SSE4.1 and AVX2 mixer took 3 to
  5 inputs with the constant in a fixed lane; the merged one takes 3 to 7
  (lanes 0..n-1 the counters, n the constant 384, the rest 0) and the rate
  as an argument. Its bitonic DC network returns what predictions' middle
  ten needs (the fourth smallest and the fourth largest, not the extremes);
  its table layout was redone for the merged tables (every table version 7
  reads starts on a cache line, every exponent ladder and the DC's
  mantissas in rows of 16). Bytes identical at each step.
- **Around the model** went in unchanged but for `pjav7.Put`, where the C
  core's buffered encoder already writes a block with one `Move`.

The verifiers' fixes, all in: the ratio selector reads RATIO_OF only when
positions left exceed the nonzeros left (it read one byte past the table
for a block with 49 nonzero interior coefficients, a value that depends on
the linker; 16, the selector's otherwise unused ninth set, now); the
luma's coefficients only when the vertical sampling divides (above); PTH
and PTH2 are enum constants, not build flags; the per-coefficient
reciprocals `rq[]` and `divround` that predictions left unused are gone,
and the `PJA_V7_STATS` debugging block (C library calls) was not merged.

## The z codecs: LZ77 across a block's files, for zpaq-std (30/10/2026)

Inside a zpaq-std block the files are coded one by one, and what one shares
with another is lost: the same image saved progressive and baseline, or
with and without restarts, gives the same coefficients and much the same
PJA stream. 7-Zip with PJA gets that back with LZMA2 after the filter (and,
since 0.3.0, the filter's own dedup); zpaq-std now does it with zpaq's
level 1 LZ77 (the `-m1` method, `rb` = 0) across the block's segments, and
five new codecs carry a decoder that undoes it: pjaz, pjalsz, pjaxz,
pjallz and pjalsxz, each its codec without the z (the same files, the same
streams, the same detect, compress, decompress and query) with another
ZPAQL.

That ZPAQL is its codec's decoder with `pas/plugin/zpaql/lz.zl` in front.
Each byte of a segment goes to zpaqlc's `onbyte(c)` instead of into M: a
state machine over the codes (literal runs and matches, Elias gamma lengths,
LSB first) that writes the segment out into M, where the decoder then reads
it as it always did. Each segment's codes start afresh, padded to a byte
at its end, but a match may reach back into the segments before it: M is a
ring of 2^$1 bytes that `reset()` no longer starts over, but moves past the
segment (zpaqlc's `mbase()`). The config is `comp 0 0 $3 $1 0`: $3 is H as
the codec's query gives it (the largest of the block), $1 the window's bits
(zpaq-std uses 16 to 24); no distance may reach 2^$1, and no segment come out
larger than it. The ZPAQL stops with an error on a match before the block's
first byte or with more than 23 bits of distance, and on whatever its codec's
decoder already refuses. H is its codec's to the word (gen_pjadec checks
it), so the codec's query serves for both.

The expander costs about 1.6 KB of program, and pjaz had 1.6 KB left
under ZPAQL's 65,535. zpaq-std's issue #4 (kaitz) pointed at two wastes
in zpaqlc's output, and for programs not yet frozen zpaqlc now has `opt`:
each constant as the shortest sequence of instructions it finds instead
of a byte at a time (`a= 255 a+= 5` for 260), checked by running it, and
in the start-up code a constant near the one before built from it, kept in
A or B. Then Wira saw that a third of pjaz's program built addresses of H
above 255 before a `d=a` (3,078 times): variables that did not fit in R
went to H in the order they were declared. With `opt` the program is now
compiled twice more, the variables placed by how often the code named
them: the most named in R, the next 256 in H[0 .. 255], which `d= N`
reaches in one instruction, the rest above. The frozen programs are
compiled without `opt` and do not change.

| codec | its codec (frozen) | with lz.zl | shortest constants | and places by use |
|---|---|---|---|---|
| pjaz | 62,294 | 63,925 | 56,635 | **39,458** |
| pjalsz | 55,989 | 57,678 | 51,290 | **32,984** |
| pjaxz | 57,709 | 59,398 | 52,547 | **37,476** |
| pjallz | 30,508 | 32,117 | 28,051 | **18,003** |
| pjalsxz | 60,776 | 62,329 | 55,061 | **36,110** |

With libzpaq (zpaq 7.15's), each set as one block of its codec's segments
through a test LZ77 encoder (`tools/zpaql/lz77.py`, and the same in C):
every file back byte for byte, with a window of 2^24 and with the smallest
that holds the largest segment (M wraps several times); 150 damaged segments
per codec (a bit changed or the segment cut) never hung: 144 to 150 errors,
the rest the same file or another without an error, as without the LZ77
(zpaq's SHA-1 of each segment catches those).

| codec | set | its streams | in one block, after the LZ77 |
|---|---|---|---|
| pjaz | 244 arithmetic-coded JPEGs | 76.36% | **17.70%** |
| pjaz | 640 generated variants | 75.49% | **16.77%** |
| pjalsz | 73 JPEG-LS files | 92.21% | 79.24% |
| pjaxz | 66 JPEGs and 6 MPO | 73.09% | 71.73% |
| pjallz | 36 lossless JPEGs | 95.75% | **19.84%** |
| pjalsxz | 76 subsampled JPEG-LS files | 88.42% | 69.96% |

zpaq-std's own build (`-sat`, a z codec only where it wins, decoded and
compared before writing; with the decoders of the shortest constants, each
block now carries some 17 KB less): arithmetic 4,763,128 -> 1,259,556 bytes, generated
13,217,825 -> 3,268,732; the MPO, the corpus and the photos a little smaller,
none larger. The suite runs each z decoder on a block of two files and the
first again, the third all matches into the first.

## JPEGs without their tables, in libpja (30/10/2026)

Stage E of the JPEG family plan was a generic patch for JPEGs with
encoder quirks. To find what real files need, the JPEGs stored inside
the sample corpus' other files were cut out (cover art, video, PDF, TIFF,
FlashPix, resources, thumbnails): 19,054 different ones, 556 MB. PJA
took half of them; of the 9,329 it took as bytes, 9,303 were
`MissingTable`: "abbreviated" JPEGs without DQT and DHT, the tiles of
FlashPix (`.fpx`), Picture It's and PhotoDraw's `.mix` and TIFF, whose
tables the container keeps once, as a JPEG of tables only. The quirks a
patch would cover were 26 files, about 2 MB: a 00 byte before the EOI
(Xara, 9), restarts numbered wrong (4), scans that end early.

So the tiles come first, in the filter (doc/LIBRARY.md): it gives a tile
the tables of the last JPEG of tables (or of the first one ahead: FlashPix
writes them after its tiles), and PJA codes the tile as the JPEG it would
be with them after its SOI. Coding those tables in each tile's raw bytes
cost more than a 2 KB tile gains, so CodeRaw learnt "given tables"
(pjamodel.SetGivenTables, set by libpja's pool for that job only): one
direct bit, 1 when the raw bytes have them right after the SOI, and then
the raw bytes are coded without them and put back when decoding. Without
given tables nothing changes: no bit, the same streams (the zpaq-std
plugin and the command never set them). 34 containers in one 7-Zip
archive: 71.92% -> 59.55% (FlashPix 12 to 17% smaller, the .mix 15 to 63%,
a TIFF 46%); photos, corpus and arithmetic sets give the same archives as
0.4.0, byte for byte.

The quirks came next, as repairs rather than a byte-by-byte patch: a
file PJA refuses for a restart numbered wrong (`BadRst` at an RST: the
scan's RSTs from there numbered again, D0 to D7 in turn) or for bytes
between a scan and the next marker (`DataAfterScan`: taken out) is
repaired, one slip at a time as the parser meets them, compressed as any
JPEG, and its repairs kept: stream version 6, PATCH (flag bit 3, alone,
at the top): the edits (where in the repaired file, how many bytes go,
which take their place) and the repaired file's stream. Decoding applies
them back; Compress verifies the whole, as always. Only `Compress` with
parts (the command, libpja) repairs; version 5 and the zpaq-std plugin
do not. `pja a` shows `(repaired: BadRst@19896)`.

Of the 26 quirky JPEGs cut from the corpus, 14 are repaired: Second
Nature's slide shows (RSTs numbered from RST4: 98.5% as bytes, 92.2% now)
and Xara's (a 00 before the EOI: 98.6% -> 67 to 83%); every one back. The
other 12 (scans that end early, bad codes, an SOS that does not add up)
look damaged or cut wrong, and still go as bytes. New samples
`restarts_misnumbered.jpg` and `byte_before_eoi.jpg`.


## The zpaq-std plugin: MPO and speed (30/10/2026)

zpaq-std + PJA was still behind on MPO (80.53% against Aqueous' 78.94%)
and slower than 7-Zip + PJA. Two of the four camera MPO, DSCF0039 and
DSCF0075, did not go to pjax: its detection put their decoder at 2^27
words of H, over the 2^26 the plugin allows, where their streams ask for
2^25. The estimate counted the second image twice: in the host's raw
bytes (TJpeg.raw keeps everything after the EOI) and as a part. The host
now counts its raw bytes without the parts after its EOI, which its
stream cuts out; pjax takes all four, 85.5% and 84.8% -> 75.0% and 73.1%.
Only the detection changed: no stream and no ZPAQL.

Measured through the plugin as zpaq-std calls it, one thread, the 151
photos: detecting pjax 7.8 s, pja 7.4 s, compressing 59.3 s,
decompressing 55.6 s. Each detection verified the whole JPEG again, and
compress did it a third time. The detections now keep what they found (64
entries, by the bytes' size and a 64-bit hash) and pja's compress takes
the JPEG apart only (pjacodec.CompressVerified): pja's detection 7.4 s ->
0, the same streams. And a call gave a file's bands one thread, whatever
zpaq-std ran, so four MPO of 10 MB kept half the machine idle: an optional
export, zpaqstd_threads_v1(n), tells the plugin how many threads zpaq-std
runs, and each call takes n / (the calls running) for its bands. The four
MPO through pjax, one call at a time: 27.2 -> 12.6 s to compress, 23.9 ->
9.3 s to decompress with n = 8; the same streams.

Later the same day, a third slip: a scan that ends before its last block,
at a marker (three of the corpus' 26: an encoder that did not flush its
last bits) or at the end of the file (a download cut short). PJA reads on
with zero bits, as libjpeg does: a filler after the scan, zero bytes
until the scan has all its blocks, with the RSTs its DRI asks for (each
found as the parser misses it) and their padding bits set to 1, and what
the scan does not read taken out; then the file is decoded and rebuilt,
and the repair is "these bytes go". The filler may be large (a photo cut
at 60% has 40% of its blocks made up), so PATCH holds it to 4 times the
file and 64 KB (MaxFiller), and the repaired stream is kept only when it
is smaller than the file as bytes. Three of the corpus' four are taken
now (98% -> 76 to 80%); 30 photos cut at random points: 10 repaired (a
photo cut at 99%: 85.9% as bytes, 61.1% now), 20 smaller as bytes, every
one back. Compress's own check now decodes with the original's size as
the cap, as every caller does: before, a large filler passed the check
and failed when extracted. New samples `scan_ends_early.jpg` and
`cut_short.jpg`.

And the tiles whose container keeps no tables at all (Konica's Q-Photo
`.kqp` and `.pic`, 10 of the corpus' files): libpja's filter now gives a
JPEG without tables, when it finds none in its container within 16 MiB,
the standard ones, T.81's example tables (STD_TABLES in pjafilter.c, as
cjpeg -quality 50 writes them). Konica's are those: the 10 files go from
raw to 52 to 78%, every one back.

In a solid block the filter gives a JPEG without tables the last ones it
saw, which may be another file's: a Konica file after a FlashPix whose
tables are the standard ones was taken, after a JPEG of optimized tables
it was left raw. When those tables do not fit, the filter now tries the
standard ones too (once, when the file is written out): test_lib puts
baseline_444.jpg without tables after a JPEG of color_plasma.jpg's
tables, which 0.5.2 left raw.


## Stream version 7 for zpaq-std: pja7, pjax7 and their z (31/10/2026)

zpaq-std's plugin wrote stream version 5, the one its frozen ZPAQL
decoders read, while the command had moved to version 7: 3% smaller and
about 1.6 times as fast. Wira approved a prototype of version 7 for
zpaq-std, as new codecs (a frozen ZPAQL never changes): pja7 (pja's
files), pjax7 (pjax's), and their z, pja7z and pjax7z.

The decoder: `pas/plugin/zpaql/model7.zl`, pjav7c_loop.h's plain path
line by line in zpaqlc's language over model.zl's tables and helpers.
What C does in 64 bits is 32 bits there: the sums it only uses modulo 2^32
are those, and each division of a number that may reach 2^33 (the edge
prediction, the DC's eighths, its spread) is split into a quotient and a
remainder's that stay below 2^32. Its 64-bit masks are counts (nonzeros
per row and column of the block so far) and loops. The models' tables and
mixers come from TCoefModel.InitV7 (gen_pjadec.make_consts7): 210,731
words a model, two a band. The plugin links the C of version 7 (pjav7),
so it writes the streams the command writes.

Compiled as zpaqlc compiled the z codecs, the decoder was 71,052 bytes,
over ZPAQL's 65,535: every function's variables had places of their own,
and with this many functions most were in H, where each use builds an
address first (a line of 150 to 450 bytes). zpaqlc's opt=2 overlays them:
a function's frame starts past those of all the functions that may call
it, so functions never on one chain of calls share places, and the most
used fit in R. With kaitz's three patterns from zpaq-std's issue #4 too:

| codec | PCOMP |
|---|---|
| pja7 | 35,104 |
| pja7z | 35,829 |
| pjax7 | 35,211 |
| pjax7z | 35,987 |

The plugin, one thread, against the version 5 codecs (every file back):

| set | v5 | v7 | compress | decompress |
|---|---|---|---|---|
| 151 photos (pja / pja7) | 75.03% | **72.68%** | 52.7 -> 33.5 s | 53.5 -> 35.9 s |
| corpus, the 65 pja takes | 73.85% | **72.22%** | 25.6 -> 19.6 s | 20.4 -> 15.2 s |
| 244 arithmetic-coded | 76.35% | **74.44%** | 6.2 -> 5.0 s | 5.9 -> 4.8 s |
| 640 generated | 75.47% | **73.58%** | 12.5 -> 9.4 s | 12.9 -> 10.1 s |
| MPO, the 4 pjax takes (pjax / pjax7) | 73.93% | **73.18%** | 23.5 -> 16.8 s | 22.1 -> 16.0 s |

The ZPAQL is faster as well: libzpaq extracts 30 photos in 46.4 s with
pja7's, 108.6 s with pja's. Each set in one block through a test LZ77
(the z): arithmetic-coded 17.70% (pjaz) -> 17.18% (pja7z), generated
16.77% -> 16.34%, libzpaq 41 -> 28 s and 108 -> 70 s. Every file back,
with $3 the plugin's query gives (its count, ZpaqlWords7, follows
model7.zl's allocs); with a window of 4 KB too; damaged segments, 150 a
codec: no hang. x86 and x64 write the same bytes. The suite decodes pja7
and pjax7 segments, and their z, in zpaqlc's interpreter.

zpaq-std measured the prototype (commit 9c3e61a) through its whole
path (`-sa -t8`, pja7 and pjax7 in place of pja and pjax, their z where
the LZ77 wins), against its 2.0.3:

| set | 2.0.3 | with version 7 | |
|---|---|---|---|
| photos | 59,009,713 | 57,151,702 | -3.1% |
| corpus | 23,290,117 | 22,739,830 | -2.4% |
| MPO | 30,570,193 | 30,254,230 | -1.0% |
| arithmetic-coded | 1,251,109 | 1,212,377 | -3.1% |
| generated | 3,183,477 | 3,099,865 | -2.6% |

Writing 1.3 to 1.6 times as fast, extracting natively 1.2 to 1.6 times,
zpaq 7.15 with the ZPAQL 1.5 to 1.6 times (photos 191 -> 121 s). Every
file back, natively and with zpaq 7.15; with the smallest valid window
forced in each group as well (2^16 to 2^24). Its CI built the plugin, C
included, on its six platforms, the same archive on every one.

Frozen in 0.6.0, for zpaq-std 2.1.0: pja7, pjax7, pja7z and pjax7z,
their streams and their ZPAQL never change under these names, as
codecs 0 to 9's.

## clang for the model's C (01/11/2026)

Profiled (callgrind, one photo, one thread), 92% of compressing is
version 7's coefficient loop, encoding and then decoding to verify; the
rest is Huffman, BLAKE3 and the stream's framing. Misses past the cache
are rare: the cost is the work per bit (5 to 7 counters, the mixer, the
coder). Packing a counter's update into one 32-bit load and store changed
nothing measurable. The compiler did: clang 19 against gcc 14, the same C
and flags, 20 photos, one thread, best of 3, three rounds alternated:

| | gcc | clang |
|---|---|---|
| compress | 8.86 to 8.97 s | **8.18 to 8.33 s** |
| extract | 4.35 to 4.42 s | **4.01 to 4.07 s** |

The same streams from both, on every path (AVX2, SSE4.1, plain), in 64
and 32 bits. clang turns a zeroed array or a struct copy into memset or
memcpy, which a DLL with no C runtime cannot resolve: it gets
-fno-builtin (build_c.sh, pas/lib/build.sh), and pjav7c.c zeroes and
copies through clang's inline builtins. Since 0.6.1 the releases build
the C with clang on Linux (x86-64, x86, arm64) and Windows x64, as macOS
did; Windows x86 and the two suites keep gcc, so both stay checked.

## Fuzzing the command and the 7-Zip plugin (01/11/2026)

Random mutations anywhere in a file (bytes and bits changed, cuts, chunks
copied or taken out), 30 minutes on 24 workers, the C built with UBSan's
traps: 212,168 damaged `.pja` through `pja x` and 25,854 damaged `.7z`
(PJA and PJA1, `7z t` with the plugin) gave nothing: no crash, no trap, no
hang, every damage refused. 21,143 damaged JPEGs and JPEG-LS through
`pja a` gave two bugs, both in what PJA does with a file it refuses at
first, and neither losing data (every stream is verified before it is
written):

- **The repair could take minutes.** RepairJpeg's filler for a scan cut
  short decodes the whole file at each try. Some damage made the parser
  answer "data after the scan" at one length and "scan cut short" at the
  next, and the filler went back and forth between them until its 4096
  tries were spent (104 s for a 91 KB file); a filler cut to the length it
  was last cut to, with nothing else changed, now gives the repair up.
  And a cut progressive scan with a restart every few blocks cost one
  decode per padding bit and per RST: once two intervals in a row are the
  same length, the filler after them gets them all at once. Their lengths
  can vary by a byte (not every interval is the same bits), so a filler
  about to be given up after a copy goes back to how it was before it and
  on one interval at a time: what is repaired is what 0.6.2 repaired
  (1,207 files of every set, the same streams), in seconds at worst
  instead of minutes (`prog_restarts_cut.jpg` has the case where the
  copy does not fit).
- **A JPEG-LS without its EOI was taken and then not given back.**
  DecomposeJls stopped at the end of the file after the last scan; the
  headers alone, decompressing, looked for a marker there. The
  verification caught it (`NoRoundTrip`, nothing written); it is now
  refused when parsed (`Truncated`) and goes as bytes. The plugin's pjals
  and pjalsx share the parser: zpaq-std's detect refuses it too.

An audit of the C that reads damaged or hostile input (`pjafilter.c`,
`pja7z.c`, `pjasysc.c`; 600,000 damaged filter streams through the
decoder with ASan and UBSan) found no memory error. It found the filter's
encoder going quadratic: a JPEG cut short in a solid block, followed by
bytes with no FF (text), was read again from its start at every read
7-Zip made (32 MB: 22.8 s), and held up to 512 MB. `jpeg_extent` now goes
on from where it got to (32 MB: 0.17 s), and 16 MB without an FF inside a
scan ends the candidate (a JPEG's entropy-coded data has one every 256
bytes or so): 32 MB of buffer at most. The library's thread count is now
1 to 64 in every export (a count past 2^28 overflowed the filter's job
arrays), and a pool that fails half-built stops the threads it started.

The Windows libraries' heap (`pas/pjaheap.pas`, 0.6.2) now refuses a size
that would overflow its 16-byte header. With no memory it answers nil, as
it did: raising runtime error 203 from inside the memory manager instead
was tried and measured on Windows x86 (a test that takes the address space
and leaves 2 to 24 MB): the exception needs memory of its own, fails again
and ends the host, where nil gives PJA_E_MEMORY at every level, as
FreePascal's own heap (0.6.1) does.

The 32-bit x86 builds now pass `-march=i686` to the C compiler: MSYS2's
mingw32 gcc assumes SSE2 by default, and pjav7c.c took its SSE2 path when
it did, so PJA's x86 builds needed a Pentium 4 (pointed out by PMPA). The
plain path writes the same streams (the suite checks it); the SSE4.1 and
AVX2 copies still go by cpuid.

## An audit of the codec's limits (04/11/2026)

- **A cut photo whose filler outgrew the file was refused when read.**
  ReadPatch held each edit's place and length to the original's size,
  while RepairJpeg lets a cut scan's filler grow to MaxFiller (4 times the
  file and 64 KB): the first 70% of a corpus photo was repaired, failed its
  check and went as bytes (2871.5 KB instead of 2758.2 KB), and with
  `--no-verify` the `.pja` written could not be extracted. ReadPatch now
  takes what RepairJpeg writes (places and lengths up to the original and
  its MaxFiller, the repaired file's size from the edits), and a PATCH
  stream is always decompressed before it is kept, with or without
  verify: the repairs are guesses. Every stream that was read is read the
  same, and every file gives the same bytes.
- **Verification decoded with a cap of 256 MiB**, while compressing took a
  raw part of any size: a JPEG with more than 256 MiB after its EOI failed
  as `NoRoundTrip`, and nothing was written. It decodes now with the
  original's size, as `pja x`, libpja and the plugin do.
- **A thread the system would not give** (a host at its limit) left the
  bands' threads already started running on the job arrays the exception
  freed. The bands with no thread now run on the caller's thread, after
  the others were started, and those are waited for: the same stream and
  the same JPEG (`tests/test_threads.pas` refuses threads to check it).

## The o codecs: half the ZPAQL for JPEG-LS and lossless JPEG (04/11/2026)

zpaq-std groups a format's files in blocks and every block carries its
codec's whole ZPAQL; split in blocks of 1 to 4 MB for zpaq 7.15 to
extract them in parallel, the decoder came to 0.6 to 1.9% of the archive.
zpaqII proposed emulating subroutines to shrink it: zpaqlc has always
done that (a call stores a call-site number and long-jumps, the function
returns through a chain of comparisons), so nothing was inlined. The
weight came from the optimizations: pjals, pjall and pjalsx were frozen
compiled without any, and their z with opt; only version 7's decoders had
opt=2. zpaq-std's `-sa` uses those three and their z.

The same programs compiled with opt=2 (the sources and every other
decoder unchanged, byte for byte), PCOMP bytes:

| codec | frozen | o (opt=2) |
|---|---|---|
| pjals / pjalso | 55,989 | **24,076** |
| pjalsz / pjalszo | 32,984 | **24,724** |
| pjall / pjallo | 30,508 | **15,058** |
| pjallz / pjallzo | 18,003 | **15,693** |
| pjalsx / pjalsxo | 60,776 | **25,623** |
| pjalsxz / pjalsxzo | 36,110 | **26,278** |

Their H is their codec's to the word (gen_pjadec checks it), so the
codec's query sizes them, and they read the same streams: the o codecs
are their codec with another ZPAQL, codecs 14 to 19 of
`zpaqstd_codecs_v1`. The smaller program is faster too: libzpaq (zpaq
7.15's engine, JIT) on the same segments, the frozen decoder against the
o one, every file back with both:

| set | files | frozen | o |
|---|---|---|---|
| JPEG-LS (pjals) | 24 | 78.5 s | **36.2 s** |
| lossless JPEG (pjall) | 36 | 2.8 s | **1.2 s** |
| subsampled JPEG-LS (pjalsx) | 67 | 410.9 s | **178.6 s** |

The same compile of pja and pjax gave 29,237 and 28,541 bytes (from
62,294 and 57,709), but zpaq-std no longer writes them: pja7 and pjax7
are its codecs for those files. The suite runs the six o decoders on
segments, alone, two in a block and through the LZ77.

Frozen in 0.7.0, for zpaq-std: pjalso, pjallo, pjalsxo, pjalszo, pjallzo
and pjalsxzo, their streams and their ZPAQL never change under these
names.

## The 8 codecs: zpaqlc's opt=3 (05/11/2026)

What the decoders' bytes go to, in pja7z (opt=2, 35,829 bytes): places in
R loaded and stored, 42%; calls and returns, about 6 KB (a call stores its
call-site number and long-jumps, 7 bytes; its return chain compares and
long-jumps back, 7 more); the tables written at start-up, 4.5 KB. ZPAQL has
no indirect jump, so calls cannot be made much cheaper; three things in
the code around them can, as zpaqlc's opt=3:

- **Inlining.** A function called from one place, or one whose copies
  take fewer bytes than its calls, is compiled where it is called: its
  returns go to the end of the copy. Each program is also compiled with
  nothing inlined and the smaller is kept (pjalsx's grows with inlining).
  A search, function by function, found 184 bytes more on pja7: the
  estimate is close enough.
- **The right operand through B.** With a constant or a variable on the
  left, `b=a` and the left loaded (4 bytes) in place of a temporary stored
  and read back (7).
- **Return values in B.** The return chain uses A and F only, so a
  function's value stays in B: `b=a` and `a=b`, a byte each, where a place
  of its own took two.

PCOMP bytes, the same streams and H as their codecs:

| codec | frozen | opt=3 |
|---|---|---|
| pja7 / pja78 | 35,104 | **32,954** |
| pja7z / pja7z8 | 35,829 | **33,603** |
| pjax7 / pjax78 | 35,211 | **33,197** |
| pjax7z / pjax7z8 | 35,987 | **33,949** |
| pjalso / pjals8 | 24,076 | **22,430** |
| pjalszo / pjalsz8 | 24,724 | **23,046** |
| pjallo / pjall8 | 15,058 | **13,901** |
| pjallzo / pjallz8 | 15,693 | **14,517** |
| pjalsxo / pjalsx8 | 25,623 | **24,611** |
| pjalsxzo / pjalsxz8 | 26,278 | **25,244** |

libzpaq (zpaq 7.15's engine, JIT) on the same segments, every file back
with both: 30 photos 69.3 -> 68.0 s, 18 MPO and 12-bit JPEGs (pjax7)
216.4 -> 206.2 s, 24 JPEG-LS 33.1 -> 32.4 s, 36 lossless JPEGs 1.33 ->
1.25 s, 67 subsampled JPEG-LS 180.8 -> 170.4 s: 2 to 6% faster. On Windows
XP, zpaq 7.15 (32-bit, no plugin) extracts byte for byte archives that
zpaq-std 2.2.2 wrote with pja78, pjax78, pjals8, pjall8 and pjalsx8 (87
files), and the x86 plugin round-trips each set with each of the ten. The
suite runs the ten on segments, two in a block and through the LZ77
(test_pjadec --v8).

Frozen in 0.8.0, codecs 20 to 29: pja78, pjax78, pja7z8, pjax7z8, pjals8,
pjall8, pjalsx8, pjalsz8, pjallz8 and pjalsxz8, their streams and their
ZPAQL never change under these names.

## Before the formats are fixed: 0.9.0 (05/11/2026)

A last round of checks on what 0.9.0 fixes (`doc/STABILITY.md`):

- **The 8 codecs' decoders on damaged data.** 150 damaged segments for
  each of the ten (bits flipped, bytes inserted, deleted or cut), through
  libzpaq: 1,497 refused with libzpaq's error, 3 decoded without one
  (zpaq-std's hash rejects them), no hang, no crash.
- **Past 256 MiB.** A JPEG with 270 MB of random bytes after it: taken,
  verified and given back byte for byte (6.4 min to compress, 3.5 to
  extract, the raw model's speed).
- **Threads the system refuses, for real.** Under systemd's TasksMax (a
  cgroup's limit of threads), `pja a -th 16` died with "EThread: Failed to
  create new thread" when it made its pool of file workers: the codec's
  bands had been fixed (0.6.4), the command's pool not. The 7-Zip plugin
  answered "Can't allocate required memory" for the same reason in the
  filter's pool. Both now go on with the threads they get: with TasksMax 1
  (no thread but the main one) to 8 the command writes the same `.pja`
  files and extracts them; 7-Zip with PJA compresses and extracts at
  TasksMax 4 and 5, where 0.8.0's plugin failed (at 3, 7-Zip's own threads
  fail first).
- **FAT and exFAT.** A new output takes its name through link(), which
  never replaces a file; FAT has no hard links, so on a camera card the
  output was written in place, and a run cut short left it truncated. On
  Linux, renameat2 with RENAME_NOREPLACE does the same and FAT takes it:
  checked on a vfat mount.
- **The filter's tables record** stays out of the decision to keep a file
  compressed, as designed: it is written once for every file after it with
  the same tables, so a small file is not charged for all of it. (The
  audit had asked for it to count; libpja's test of the standard tables,
  a 2 KB JPEG that the record alone would outweigh, showed why not.)
- **PATCH's bounds** saturate instead of overflowing for a declared size
  past 2^61 (the `.pja` ratio check already kept the command from it).
- **Fuzzing**, 20 minutes on 12 workers with these builds: `pja x` on
  135,730 damaged `.pja` (every one refused cleanly: a hash that does not
  verify or a stream that does not rebuild), `pja a` on 18,348 damaged
  JPEG and JPEG-LS files, `7z t` on 15,994 damaged archives: no crash, no
  hang, nothing taken that did not come back.

## The largest files first (05/11/2026)

`pja -th N` took its files in the order of the arguments, one per worker.
With sizes ten times apart, the last big file often started when the other
workers had nothing left, and they waited for it: simulated on 30 of the
b151 photos in name order, the run took 1.31 times the ideal. Now, with more
than one worker, the workers take the largest first (the input's size: the
JPEG for `a`, the `.pja` for `x` and `list`; a file that cannot be read
counts as 0), which brings it to 1.04. The lines still come out in the order
of the inputs, `a` still takes its outputs in that order before the workers
start, and with one worker nothing changes. Every `.pja` and every extracted
file is the same, and so is what the command prints.

Wall time, `-th 4` on 4 cores, A (0.9.0) and B alternated, best of the
rounds (the machine was loaded):

| set | compress A → B | extract A → B |
|---|---|---|
| 30 b151 photos, name order (5 rounds) | 4.780 → 4.466 s (−6.6%) | 2.482 → 2.330 s (−6.1%) |
| corpus-jpg, 78 files (4 rounds) | 21.335 → 17.215 s (−19%) | 9.296 → 7.553 s (−19%) |
| jlsphoto, 16 JPEG-LS (3 rounds) | 23.301 → 15.649 s (−33%) | 9.231 → 6.210 s (−33%) |
| arith, 244 small files (4 rounds) | 5.502 → 5.423 s | 2.323 → 2.378 s (noise) |
| all 151 b151 photos (3 rounds) | 33.736 → 33.818 s | 16.801 → 16.794 s |

The gain is the tail: it grows with the spread of sizes and shrinks as the
files outnumber the threads (on 151 photos and 4 threads there is none to
take). A single large file that holds back the others (the corpus's 4.7 MB
0056, the jlsphoto's 1.4 MB photo7, both last by name) gains the most.

## JPEG-LS's symbols model without managed locals (05/11/2026)

TJlsSymModel.Mapped, the hottest routine of a JPEG-LS file (its symbols
model is tried on every file when compressing, and decodes it when
extracting), took its four rows as local `array of Integer`, and Sample
rotated the three lines through a fourth: each call cost FPC's reference
counts and an implicit try/finally (fpc_dynarray_assign, fpc_finalize,
fpc_pushexceptaddr, about 9% of compressing photo6.jls). In the fast
build the rows are now bare pointers (TJlsLine), and the lines are
rotated as bare references (a pure swap: every count stays as it was);
the reference build keeps the dynamic arrays and their range checks. The
same arithmetic, the same streams.

Callgrind, photo3.jls (136 KB), one thread: compress 5.87 G to 4.98 G
instructions (-15%), extract 1.85 G to 1.41 G (-24%). Wall time, one
thread, four rounds alternated, best:

| | before | after |
|---|---|---|
| photo6.jls (786 KB), compress | 3.18 s | **2.89 s** |
| photo6.jls, extract | 1.28 s | **1.13 s** |
| photo7.jls (1.4 MB), compress | 6.54 s | **5.84 s** |
| photo7.jls, extract | 2.61 s | **2.21 s** |
| gray7.jls (460 KB), compress | 2.60 s | **2.29 s** |
| gray7.jls, extract | 1.01 s | **0.87 s** |

JPEG photos do not go through this code (20 photos: the same within the
noise). What is left of the managed overhead in JPEG-LS is
fpc_dynarray_rangecheck from pjajls, whose $R+ is mandatory.

## The raw model's reset, for large raw parts (05/11/2026)

After each use the raw model puts back as new only the counters its bytes
touched (`RawReset`), walking the bytes again: three stores per bit, those
of the order-2 table at random in its 16 MB. For a few KB that is nothing;
for an ICC profile of 600 KB it is 14 million stores, mostly cache misses,
on every one of the raw model's passes (encode, the trial without the
parts, the verify's decode). From 64 KB of raw bytes on, the three tables
are now refilled whole with the initial counter instead: the same state,
so the same streams (checked on corpus-jpg's 78 files, 10 photos, 10
arithmetic files and 4 JPEG-LS files, and by the suites).

Walk against refill alone, one thread: 16 KB of raw bytes 1.2-1.5 ms
against 0.9-1.5 ms (the break-even), 64 KB 7.1-7.4 ms against 0.9-1.5 ms,
600 KB 61-75 ms against about 1 ms. The threshold sits at 64 KB rather
than at the break-even: below it the gain is a few ms a file, too little
to see, and a refill writes 16 MB, through a cache other threads share,
that a short walk leaves alone. The command, `-th 1`, best of 4 or 5 alternated runs:

| file (raw bytes) | compress before | after | extract before | after |
|---|---|---|---|---|
| 0046 (593 KB) | 3.01 s | 2.75 s (-8.5%) | 1.26 s | 1.11 s (-11.7%) |
| 0047 (1.16 MB) | 7.48 s | 6.82 s (-8.7%) | 2.96 s | 2.80 s (-5.4%) |
| 0049 (571 KB) | 2.10 s | 1.74 s (-16.8%) | 0.71 s | 0.58 s (-17.9%) |
| 0056 (1.55 MB) | 10.17 s | 8.77 s (-13.8%) | 4.07 s | 3.93 s (-3.3%) |

Photos (20 of the 151) and JPEG-LS do not change: their raw parts are
small.

## The raw bytes' model in C (05/11/2026)

The bytes PJA keeps as they are (APP segments, ICC profiles, what follows
the EOI) go through orders 0, 1 and 2 mixed by a 4-input mixer. In Pascal
that cost about 350 instructions a bit (four Add calls, Mix calling the
SSE4.1 dot product, CodeP calling Encode, Update calling its SSE4.1 copy,
three counter updates), as much as one of version 7's mixed decisions,
and it is serial: on a camera or Photoshop JPEG with a large profile it
was half of compressing (corpus 0046: 52%) and the bound of `-th 8`.

`pjav7c.c` now has the loop (`pjav7_raw_d`, `pjav7_raw_e`), the same
arithmetic step by step: the dot product in 32 bits, TruncShr(dot, 16),
the squash clamped, pr shl 4 into the version-5 coder (dbit and ebit are
pjaarith's Decode and Encode; the encoder's bytes go out through the 4 KB
buffer), err = ((bit shl 12) - pr) * MIX_LR and each weight's step
clamped to ±2^17, the counters by learn() (TAdaptiveBit.Update at limit
255). The lanes 4..7 of the Pascal mixer hold zeros and never move, so
they are left out. RawReset's walk is folded in at the end (below 64 KB
of raw bytes; from there on the caller refills the tables whole, as the
section before says). `pjav7.pas` installs
it at start-up (`pjamodel.RawCode`); `PJA_NOASM=1`, the zpaq-std plugin
and a `PJA_COSTS` run keep the Pascal. It is compiled a second time for
SSE4.1 (the four weights in pmulld), taken by cpuid like the coefficient
loop. The cache lines of the order-1 and order-2 counters are prefetched:
encoding, the next byte's whole path through the tree (the byte is
known); decoding, the first four lines of the byte's 256 counters, and the
line of nodes 64..255 two bits before it is read. The suite compresses
the samples with the C and with the Pascal, and extracts each one's
`.pja` with the other (`tests/cli.sh`); the fast build without asm is the
Pascal against the reference in `run_codec_tests.sh`, and the C without
SSE2 is there for version 7.

And one exact saving around it: when a file's parts lose, CompressAt has
already coded the file's own header stream (HeadBytes, to weigh them)
and now hands it to CompressJpeg instead of coding it again.

Every stream the same: corpus-jpg (78), b151 (151), the arithmetic set
(244), the MPO set and jlsphoto, each compressed with 0.9.0, with this and
with this under `PJA_NOASM=1`, and each one's extracted by the others;
`.github/test.sh` still gives 3387e58d... The C objects build for
`clang -m32`, `gcc -m32`, both MinGW-w64 and aarch64 with no undefined
symbol, and the win64 `pja.exe` links.

Instructions (callgrind, one thread): 0046 compress 10.10 G -> 7.23 G
(-28%), extract 4.01 G -> 3.08 G (-23%); the raw model is now about 160
instructions a bit, with RawReset. 3 b151 photos: 8.54 G -> 8.36 G
(-2.1%) and 4.02 G -> 3.96 G (-1.5%). Wall, cores 20-23 of a shared
machine, A (0.9.0) and B alternated, best of 4 (3 for the sets):

| file | 0.9.0 a / x | C raw a / x |
|---|---|---|
| 0046, -th 1 | 3.21 / 1.27 s | 2.55 / 1.12 s (-21% / -12%) |
| 0056, -th 1 | 11.73 / 4.35 s | 8.54 / 3.59 s (-27% / -17%) |
| 0047, -th 1 | 7.07 / 2.50 s | 5.30 / 2.14 s (-25% / -15%) |
| 0056, -th 8 (4 cores) | 12.46 / 4.20 s | 8.56 / 3.09 s (-31% / -27%) |
| corpus-jpg (78), -th 1 | 68.4 / 31.9 s | 57.7 / 26.8 s (-16% / -16%) |
| 20 b151 photos, -th 1 | 15.14 / 6.99 s | 15.22 / 7.06 s (noise) |
| 20 b151 photos, -th 8 (4 cores) | 3.75 / 1.95 s | 3.67 / 1.58 s |

What did not help: the coder's interval and the decoder's position kept
in locals for the whole call (+2.4% instructions encoding, +2.5%
decoding: the register pressure spills more than the memory state cost),
and the counter as one 32-bit word on top of that (+6%), as in version
7's loop.

## JPEG-LS: both models at once, the symbols checked as they are written (05/11/2026)

A single JPEG-LS file gave nothing to threads: `pja a` coded the samples
model, then the symbol model (one stream), then decompressed the winner to
verify it, all in series. photo6.jls took the same 4.4 s at `-th 1`, 2 and
8. Now (`AssembleJls`, no stream changes):

- with verify and two threads or more, the symbol stream is decoded while
  it is written (a `TLiveStream`, as `CompressLive` does a JPEG's bands),
  into a second copy of the samples built from its header stream as
  `Decompress` builds it; the framing is read back with `BandRanges` and
  the samples are rebuilt into a file that has to be the input. When the
  symbols win and that check passed, the stream is not decompressed again;
  when the samples win (or the check fails), `VerifyStream` runs as before;
- the samples model's bands run on a thread of their own next to the symbol
  stream when one is left (three threads or more, or two without verify),
  else after it on all of them. The two header streams are still coded on
  the caller's thread (the raw tables and a library host's tables are
  threadvars). The selection is the same: the samples model on a tie.

The symbols won on all 16 photos (8 gray, 8 colour); the samples only on
small synthetic files. At two threads the live check is worth more than
running the two models side by side: photo6, 3.58 / 3.66 / 3.60 s against
4.36 / 4.30 / 4.41 s.

Compress with verify, best of three alternated runs (4 cores, a shared
machine):

| | `-th 1` | `-th 2` | `-th 3` | `-th 8` |
|---|---|---|---|---|
| photo6.jls (786 KB), before | 4.71 s | 4.75 s | 4.32 s | 4.44 s |
| after | 4.64 s | **3.26 s** (-31%) | **2.72 s** (-37%) | **2.72 s** (-39%) |
| photo7.jls (1.39 MB), before | 9.42 s | 9.21 s | 8.72 s | 8.85 s |
| after | 9.45 s | **6.33 s** (-31%) | **5.36 s** (-38%) | **5.35 s** (-40%) |

One thread, and many files on few threads (the 16 photos at `-th 4`:
17.90 against 17.97 s), are unchanged: there the threads go to files.
Extracting is untouched. A mutant that changes one symbol in the symbol
model's encoder is caught by the live check (and then by `VerifyStream`)
at every thread count; with threads refused (test_threads' scarce
BeginThread) the same streams come out.

## A large file's header streams on threads (05/11/2026)

With one file and threads to spare, the raw model's passes ran one after
the other on the caller while the threads waited. A camera file with large
APP segments and a thumbnail (corpus 0056.jpg, 4.7 MB, 1.55 MB raw) coded
its raw bytes three times in series: the host's header stream
(`HeadBytes(hj)`), the file's own (`HeadBytes(j)`, only to see whether the
parts pay) and the verify's `DecodeHead`. Now, with two threads or more:

- **`CompressAt`**: once the parts are found, the file's own header stream
  is coded on a thread of its own (`StartHead`) while the caller builds the
  host, rebuilds it and codes the host's. Only when it is needed (the
  same `whole * 4 < size or size < 1 MB` rule) and only for 64 KB of raw
  bytes or more (a thread and its fresh 16 MB of raw tables cost a few
  milliseconds). The thread takes the caller's `GivenTables` (libpja's
  tables-less JPEGs) and releases its models at the end; with one thread,
  or none to be had, it runs on the caller as before.
- When the parts do not pay after all, `CompressJpeg` is given that header
  stream instead of coding the same bytes a second time.
- **`CompressLive`**: the first round's band encoders start before the
  header stream is coded and decoded (they need only `j`); the readers
  start after `DecodeHead`. If it fails, the encoders run to their end (a
  live stream keeps all it is given), are waited for, and the file fails
  as before. `HeadBytes` copies the scans before `CodeScanBits` writes their
  pad bits back, so the encoders read a `j` nobody writes.

Every stream is the same: the codec suite (4-thread builds against the
reference), `.github/test.sh`'s list (3387e58d...), the `.pja` of the
repository's samples and of 14 raw-heavy corpus files at -th 1, 2 and 4,
also with the helper forced on every file (`HELPER_RAW = 0`, whose codec
suite passes too), and under TasksMax 1, 2, 3 and 5. The mutants (a
reader off by one bit, an encoder that raises mid-band, and a
`DecodeHead` that fails while the encoders run) are caught on every file
that reaches `CompressLive`, without a hang and without a wrong `.pja`.

Wall time, cores 28-31, A (0.9.0) and B alternated, best of 3 or 4 (the
host's load went from 10 to 90 during the runs, so compare within a row):

| file | -th | compress A | compress B | |
|---|---|---|---|---|
| 0056.jpg | 2 | 5.32 s | 4.77 s | -10% |
| 0056.jpg | 4 | 6.35 s | 4.82 s | -24% |
| 0047.jpg (1.16 MB raw) | 2 | 3.97 s | 3.30 s | -17% |
| 0047.jpg | 4 | 4.22 s | 3.34 s | -21% |
| 0046.jpg (593 KB raw) | 2 | 1.88 s | 1.63 s | -13% |
| 0046.jpg | 4 | 2.65 s | 2.22 s | -16% |
| 0049.jpg (571 KB raw) | 2 | 2.56 s | 1.80 s | -30% |
| 0043.jpg (126 KB raw) | 2 | 2.41 s | 2.44 s | same |
| Image40.jpg (24 MP, no raw) | 2 | 1.22 s | 1.22 s | same |

Extract does not change (no code of it did). Ten b151 photos one at a
time at -th 4: 5.93 / 5.73 s, extract 3.23 / 3.21 s; the same ten as one
run (one thread per file, no helper): 2.09 / 2.07 s; eight arithmetic
files: 0.947 / 0.949 s. The `CompressLive` overlap alone (`StartHead`
off) gives nothing measurable: a photo with an ICC profile of 557 KB and
no thumbnail, 2.14 / 2.33 s at -th 2 and 1.71 / 1.68 s at -th 4, inside
the noise. Only the first round's encoders overlap the header stream's
two passes, and they finish first. It stays because it costs nothing
and the mutants still catch every failure. Every raw-heavy file of the
corpus carries a thumbnail, so the parts' path is where the gain is.

Not done: the host's bands could also be encoded while the two header
streams are coded (they are the same bands with or without the parts),
and the verify's `DecodeHead` (`SameAfter`, a whole `Decompress`) is
still serial, 15.7% of 0056's instructions.

## Speed for 0.9.5 (05/11/2026)

The six changes above, together on one branch, every stream the same as
0.9.0's. What each one is, in short:

- **The largest files first**: `-th N` workers take the inputs by size,
  largest first; the output and what is printed keep the inputs' order.
- **JPEG-LS's symbols model without managed locals**: no reference counts
  and no implicit try/finally per sample in the fast build.
- **The raw model's reset**: from 64 KB of raw bytes on, the raw tables
  are refilled whole instead of walked back.
- **The raw bytes' model in C**: `pjav7_raw_d` / `pjav7_raw_e`, bit for
  bit the Pascal loop (kept for `PJA_NOASM=1`, the zpaq-std plugin and
  `PJA_COSTS`).
- **JPEG-LS, both models at once**: the symbol stream is checked as it is
  written, and the samples model codes on a thread of its own.
- **A large file's header streams on threads**: the file's own header
  stream next to the host's when a JPEG carries parts.

One thing had to be joined by hand: the C loop walked its counters back
at the end of every call, so with it installed the whole refill never
ran. The C now walks them only below `RAW_RESET_WHOLE` and
`CodeRawBytes` refills the tables after it from there on. On 0056.jpg
(1.55 MB raw), `-th 1`, best of 3 alternated: compress 4.37 -> 3.82 s
(-12.7%), extract 1.94 -> 1.77 s (-8.4%) against the same branch without
that join.

Checked on the combined tree: `pas/run_tests.sh` (with `gen_pjadec.py
--check`: the ZPAQL decoders are as they were), `pas/run_codec_tests.sh`
with corpus-jpg (reference = fast = fast without asm = 4 threads),
`.github/test.sh` native and 32-bit (FPC i386, `gcc -m32`), both giving
"74 streams, SHA-256 of their list: 3387e58d...". Every timing run below
compared the `.pja` of both sides (the same, file for file) and the
extracted files with the inputs (the same).

Wall time, cores 0-7 of a shared machine, the shipped build (`-O3
-dPJA_FAST`, clang for the C) of main (A, 0.9.0 plus docs) and of this
(B), A and B alternated with the first side swapped each round, compress
with verify (`pja a`) then extract (`pja x`) of what it made. Best of 3;
`-th 1` pinned to one core, `-th 8` to the eight. The load was 3 to 14:

| set | `-th` | compress A -> B | extract A -> B |
|---|---|---|---|
| 24 b151 photos | 8 | 1.570 -> 1.291 s (-18%) | 0.870 -> 0.652 s (-25%) |
| corpus-jpg, 78 files | 8 | 7.908 -> 4.206 s (-47%) | 3.562 -> 1.970 s (-45%) |
| arith, 244 files | 8 | 1.630 -> 1.643 s (same) | 0.771 -> 0.773 s (same) |
| jlsphoto, 16 JPEG-LS | 8 | 7.892 -> 5.614 s (-29%) | 3.067 -> 2.177 s (-29%) |
| 0056.jpg alone | 8 | 3.631 -> 1.670 s (-54%) | 1.319 -> 0.786 s (-40%) |
| photo7.jls alone | 8 | 5.860 -> 3.284 s (-44%) | 2.384 -> 2.051 s (-14%) |
| 24 b151 photos | 1 | 9.340 -> 9.034 s (noise) | 6.084 -> 4.513 s (noise) |
| corpus-jpg, 78 files | 1 | 32.374 -> 28.919 s (-11%) | 14.667 -> 13.548 s (-8%) |
| arith, 244 files | 1 | 11.417 -> 11.567 s (same) | 4.858 -> 4.929 s (same) |
| jlsphoto, 16 JPEG-LS | 1 | 28.527 -> 24.534 s (-14%) | 10.663 -> 9.213 s (-14%) |
| 0056.jpg alone | 1 | 5.509 -> 3.894 s (-29%) | 2.274 -> 1.828 s (-20%) |
| photo7.jls alone | 1 | 6.222 -> 5.504 s (-12%) | 2.392 -> 2.099 s (-12%) |

All runs, compress / extract in seconds, A then B:

- photos `-th 8`: A 1.714/0.870, 1.642/0.918, 1.570/0.935; B 1.331/0.652,
  1.291/0.680, 1.318/0.688. An earlier series at load 20: A 1.708/0.930,
  1.632/0.870, 1.675/0.898; B 1.542/0.781, 1.465/0.898, 1.564/0.785.
- corpus `-th 8`: A 8.323/3.663, 8.046/3.581, 7.908/3.562; B 4.213/1.987,
  4.206/1.970, 4.275/2.058. Earlier: A 8.714/3.773, 8.067/3.857,
  8.187/3.609; B 5.450/2.562, 5.458/2.583, 5.463/2.116.
- arith `-th 8`: A 1.630/0.771, 1.640/0.777, 1.662/0.775; B 1.648/0.778,
  1.652/0.773, 1.643/0.774.
- jlsphoto `-th 8`: A 8.133/3.280, 8.138/3.222, 7.892/3.067; B 5.696/2.177,
  5.614/2.267, 5.770/2.240. Earlier: A 11.532/4.543, 11.105/4.500,
  11.402/4.618; B 7.824/2.951, 8.004/3.042, 8.029/3.012.
- 0056 `-th 8`: A 3.933/1.319, 3.631/1.413, 3.669/1.339; B 1.841/0.792,
  1.737/0.906, 1.670/0.786.
- photo7 `-th 8`: A 5.860/2.400, 5.909/2.488, 6.007/2.384; B 3.357/2.100,
  3.284/2.079, 3.334/2.051.
- photos `-th 1`: A 9.340/6.650, 14.093/6.084, 12.578/6.295; B
  13.665/6.669, 13.592/6.748, 9.034/4.513 (the core was shared with
  something else: these swing by half, and none of the changes is on a
  photo's path beyond about 2% of instructions).
- corpus `-th 1`: A 40.267/17.439, 32.809/14.667, 32.374/15.373; B
  30.180/13.548, 28.946/13.722, 28.919/13.613.
- arith `-th 1`: A 11.417/4.858, 11.900/4.973, 11.765/4.915; B
  11.567/5.051, 11.732/5.017, 11.730/4.929.
- jlsphoto `-th 1`: A 28.527/10.663, 41.525/17.502, 50.134/20.336; B
  25.146/9.213, 24.534/9.303, 29.051/9.941. Another series: A
  37.997/14.485, 35.315/10.083, 26.849/10.152; B 23.950/8.681,
  23.374/8.566, 23.436/8.598.
- 0056 `-th 1`: A 5.509/2.274, 6.115/2.613, 6.195/2.597; B 3.894/1.828,
  4.017/1.894, 4.168/1.912.
- photo7 `-th 1`: A 6.464/2.430, 6.561/2.744, 6.222/2.392; B 5.504/2.180,
  5.673/2.099, 6.046/2.136.

Where it comes from: on a set at `-th 8`, the largest-first order (the
tail no longer waits for one big file) and, inside each big file, the
raw model in C and its refill; on one file, the header streams on
threads (JPEG) or the two JPEG-LS models at once. Photos and the
arithmetic set do not change at `-th 1` and gain only from the order at
`-th 8`: their raw parts are small and their bands were already spread.

What was tried and did not help (all measured, see the sections above):

- **The C raw loop with the coder's state in locals** for the whole call:
  +2.4% instructions encoding, +2.5% decoding (more spills than the
  memory state cost); and **the counter as one 32-bit word** on top of
  that, about +6%, as version 7's loop had found.
- **The raw reset's threshold at its break-even, 16 KB**: between 16 and
  64 KB the gain is a few ms a file, which a 20-file mid-raw set (13-53
  KB raw) could not show above the noise; 64 KB stays, which also keeps a
  short walk from writing 16 MB through a shared cache.
- **The two JPEG-LS models side by side at two threads** without the live
  check: photo6 4.36 / 4.30 / 4.41 s against 3.58 / 3.66 / 3.60 s with
  it, so two threads check live and code the samples afterwards.
- **`CompressLive`'s encoders started before the header stream**: no gain
  on a 557 KB-ICC photo without a thumbnail (2.14 / 2.33 s at `-th 2`,
  1.71 / 1.68 s at `-th 4`, noise); it stays because it is free and the
  mutants still catch every failure.
- **The largest-first order** gives nothing when the files far outnumber
  the threads (151 photos at `-th 4`: 33.74 / 33.82 s) or are all small
  (the arithmetic set).

Left open: JPEG-LS's `fpc_dynarray_rangecheck` in `pjajls` ($R+ is kept
there on purpose; 4% of compressing photo3, 6% of extracting it); the
host's bands could be encoded while the two header streams are coded;
the verify's `DecodeHead` (`SameAfter`) is still serial, 15.7% of
0056's instructions.

## The main thread's waits: 100 ms each (05/11/2026)

`pja a -th 2` on color_plasma.jpg (15 KB, one band) took about 110 ms
against 33 ms at `-th 1`, and `--stats` put all of it in `encode`, while
the process used about 42 ms of processor. The time was not work but a
wait: FreePascal's `TThread.WaitFor`, on Unix and called from the main
thread, loops on `CheckSynchronize(100)` until the thread is finished,
and a thread that simply ends wakes nothing, so each wait returned up to
100 ms after the thread had. The command codes on the main thread (a
single file, and one file of every run with several) and waits there for
the threads of `CompressLive`, `RunBands`, the header stream and the
JPEG-LS models, and for its own workers at the end. (Windows' `WaitFor`
waits on the thread's handle and was not hit.)

`pjathread.TJoinThread` sets an event in `DoTerminate`, which the RTL
calls after it marks the thread finished; `Join` waits for that event
and then calls `WaitFor`, which joins at once. Every thread of the codec
and the command's workers use it. Only the waiting changes: every output
below was compared, the same bytes.

Wall time, best of 5, before and after alternated, `taskset -c 0-7`, the
shipped build:

| file | command | before | after |
|---|---|---|---|
| color_plasma.jpg, 15 KB, 1 band | `a -th 2` | 113.7 ms | 30.6 ms |
| color_plasma.jpg | `a -th 8` | 116.9 ms | 29.7 ms |
| corpus-jpg 0065.jpg, 42 KB, 1 band | `a -th 2` | 213.7 ms | 127.8 ms |
| corpus-jpg 0030.jpg, 397 KB, 1 band | `a -th 2` | 238.3 ms | 205.7 ms |
| corpus-jpg 0043.jpg, 1.9 MB, 4 bands | `a -th 2` | 1346.5 ms | 1170.2 ms |
| corpus-jpg 0043.jpg | `a -th 8` | 826.8 ms | 724.5 ms |
| corpus-jpg 0043.pja | `x -th 2` | 743.3 ms | 563.8 ms |
| corpus-jpg 0043.pja | `x -th 8` | 451.8 ms | 349.1 ms |
| gray2.jls, 219 B | `a -th 2` | 116.8 ms | 16.8 ms |
| tests/jpg, 30 files in one run | `a -th 8` | 87.0 ms | 82.6 ms |

`-th 1` starts no thread and does not change (within 5%, both ways).
Sequential verification for one-band files, the first idea, would have
been wrong: once the wait is gone `-th 2` is as fast as `-th 1` or
faster on every one-band file measured (color_plasma 35 -> 31 ms,
0065.jpg 156 -> 128 ms), and it already was from about 100 KB up
(0030.jpg: 328 ms at `-th 1`, 206 ms at `-th 2`).

## JPEG 2000, stage A: stream version 8 (05/11/2026)

The first stage of JPEG 2000 for 0.9.5: the container, not yet the model.
A file of the JPEG 2000 family is taken as a stream of its own version,
8, whose layout leaves room for the stages after it; in this stage its
bytes go through the raw bytes' model (CodeRaw), as stream version 6's
BYTES does for a JPEG PJA cannot take, and PJA saves what that model
saves on them: a fraction of a percent on real files (below). The
research behind it (a model of the code-blocks' decisions, about 8% on
real codestreams) is for the later stages.

**What is taken** (`pjaj2k.pas`): a raw codestream (`.j2k`, `.j2c`,
`.jpc`: SOC and SIZ, `FF 4F FF 51`, first) and a file of boxes that
starts with the JPEG 2000 signature box (`00 00 00 0C 6A 50 20 20 0D 0A
87 0A`): JP2, JPX (`.jpx`, `.jpf`), JPM, Motion JPEG 2000, JPH (HTJ2K in
a JP2-like file). Recognised by its first bytes, not by its extension.
The box tree is walked: each box's length (LBox, XLBox when it is 1, to
the end of the box that holds it when it is 0), into the superboxes of
JP2, JPX and JPM (jp2h, res, uinf, asoc, jpch, jplh, cgrp, comp, drep,
page, pcol, lobj, objc) and those of the ISO base media file format that
Motion JPEG 2000 is built on (moov, trak, mdia, minf, stbl, dinf, edts,
udta, mvex, moof, traf, and mdat, which holds an MJ2's frames as jp2c
boxes). A codestream is the contents of a jp2c box that start with SOC
and SIZ; a raw codestream runs from 0 to its EOC, found by walking its
main header's segments and its tile-parts (Psot), or to the end of the
file when they do not add up. Bounded: 16 levels of superboxes, 2^20
boxes, 16,384 codestreams kept (any more stay among the other bytes); a
box that does not fit where it is ends the walk at its level, and what
follows it is plain bytes. A file cut short is taken as it is, with the
codestreams that are whole.

**The stream:**

```
byte 0          8
byte 1          flags: none yet, 0
4 bytes (LE)    K, the codestreams: 0 to 16,384
K x 13 bytes    each codestream, in the order of the file and apart:
                where it is in the file (u32), its length (u32, 1 or more),
                its stream's length (u32), its mode (byte)
the K streams   of the codestreams that have one, in order
the rest        the host through the raw bytes' model (CodeRaw): the file
                without the codestreams that have a stream of their own
```

Mode 0, raw, is the only one in this stage: the codestream's bytes stay in
the host where they are, and its stream's length is 0; the table only
says where it is. So a version 8 stream today is the file through the raw
model and 6 + 13 x K bytes. The modes of the later stages cut their
codestream out of the host and give it a stream after the table: stage B
the packets' headers regenerated (tag trees, progressions, side
information), stage C the code-blocks' coding passes decoded and coded
again with PJA's model, each code-block that does not come back the same
kept as bytes. A reader that does not know a mode, or a flag, refuses the
stream as `FutureVersion` before it decodes anything, and never reads the
stream as something else; a reader of a mode it knows checks each
codestream's place (in order, apart, within the file). Files up to 4 GiB
- 2 (the places are 32 bits); a larger one is refused as before. Version
8 is a whole file, as BYTES is: never a part of a version 6 stream, nor
the repaired file's stream inside a PATCH stream (`BadStream` in both).

**Dispatch** (`pjacodec.Compress`): a file that starts like either kind
goes to version 8, and nothing else is tried on it (it does not start like
a JPEG). Verified like every stream: decompressed and compared before it
is handed out. `Pack` stores the file as it is when the stream is not
smaller, as for any file. The JPEG and JPEG-LS paths are untouched: the
same streams byte for byte (the suite's streams and their hash). Only with
`parts` (the command, `pja_compress`): the zpaq-std plugin's codecs, which
ask for version 5, refuse a JPEG 2000 file as before, and the 7-Zip
filter does not look for one (pjafilter.c finds files by `FF D8 FF`; a
filter record of version 8 is never written, though a reader would decode
one).

**The command and the library.** `pja a` takes the files (any extension:
`.jp2`, `.j2k`, `.j2c`, `.jpc`, `.jpx`, `.jpf`, `.jpm`, `.mj2`, `.jph`,
`.jhc` are what they are usually called) and keeps the extension in the
`.pja` as for any file, and says `(JPEG 2000: as bytes for now)`; `pja
list` says `JPEG 2000`; `pja x` of a `.pja` with no extension kept names
the file by its content (`.j2k`, or `.jp2`, `.jpx`, `.jpm`, `.mj2`, `.jph`
by the brand of its ftyp box). `pja_compress` and `pja_decompress` take
them as well.

**Tests.** `tests/j2k`: five files made with opj_compress from the
repository's own JPEGs (a raw codestream, a JP2, three quality layers,
lossless 5/3, 12 bits), and two put together from such codestreams by
`pas/tests/mkj2k_boxes.py` (a JPX with two codestreams, one in an XLBox
and one in a last box of length 0, an asoc superbox; an MJ2 whose mdat
holds two frames). `test_j2k` checks the codestreams the walk finds in
each of them (K, each one's place and length) and in the version 8
stream's table, and in files of boxes it builds (a jp2c at the top, in an
XLBox, of length 0, in an mdat, in a box that is not a superbox, of other
bytes, after a box that does not fit, superboxes 16 deep and 17): a round
trip alone would not show a lost codestream, since mode 0 keeps every byte
in the host. The codec's round trip (`test_codec`, the same stream
with 1 and 4 threads and from every build), its damage test (every bit
of the first 128 bytes of each stream and every truncation: 19,959
variants, no exception), `cli.sh` (a and x of each, the extension by the
content, a file cut in half, one bit flipped, a mode of a later release),
`test_corruption` (the `.pja` end to end), libpja's test and 7-Zip with
the plugin (the files in a solid block, left as they are).

**The research corpus** (`/mnt/IA_LAB/agentes/pja/j2k2/corpus`: JPEG 2000
files of the sample corpus, codestreams extracted from DICOM and PDF
files, and downloads from OpenJPEG's, jpylyzer's, GDAL's and other test
sets, the Library of Congress, Helioviewer, Sentinel-2), through `pja a`
and `pja x`, every file compared:

| set | files | of the family | taken | back byte for byte | size | `.pja` | saved |
|---|---|---|---|---|---|---|---|
| sample corpus (`samples/local`) | 18 | 15 | 15 (4 stored) | 15 | 18,138,400 | 18,040,859 | 0.54% |
| codestreams from DICOM and PDF (`samples/extracted`) | 1,455 | 1,455 | 1,455 (93 stored) | 1,455 | 32,501,920 | 32,469,737 | 0.10% |
| 400 downloads of 8 MB or less, drawn at random | 400 | 400 | 400 (54 stored) | 400 | 163,104,267 | 157,411,019 | 3.49% |
| all | 1,873 | 1,870 | 1,870 | **1,870** | 213,744,587 | 207,921,615 | 2.72% |

Every file of the family was taken and came back byte for byte; the three
others (an `.icns`, a QuickTime image and a `.mov` with JPEG 2000 inside)
are refused as before. The downloads' 3.49% is the test sets': fuzzing and
conformance files whose codestreams are mostly padding or repeated
packets (one of 579 KB comes out at 33 KB, an OpenJPH test stream of
3.3 MB with 4x4 code-blocks at 2.7 MB). Real files save what a general
compressor saves on them: the Internet Archive's book pages 0.27%,
Helioviewer's solar images 1.08%, OSGeo's 0.92%, the sample corpus 0.54%,
the extracted codestreams 0.10% (many are a few KB, where the `.pja`'s
37 bytes and its extension weigh more than the model saves; 93 are stored,
their stream no smaller than they are). The raw bytes'
model is slow for this: about 0.45 MB/s a thread on this machine (a
1.3 MB JP2: 3.2 s to compress without verifying, 6.1 s with, 2.9 s to
extract); the files of a run go to several threads at once, a file's
bytes to one.

## Pre-1.0: what a later release writes (05/11/2026)

The rule that lets a new kind of file come as a new stream (JPEG 2000
above) is now tested and has an error code of its own:

- **A codec stream of a later version.** A first byte past the last
  version this release knows (9 to 255 now) is `FutureVersion`, at the top,
  inside a PATCH stream (its repaired file's stream), inside a part of a
  version 6 stream and inside a `.pja` (`Unpack` gives
  `Codec(FutureVersion)`); so are a version 8 flag or codestream mode this
  release does not know (1 to 255 now). 0 to 4 are `BadStream`, and so is
  version 8 where it never goes (a part, a PATCH's repaired file).
  `pas/tests/test_versions.pas` sweeps the first byte of every stream of
  the samples (versions 5, 6, 7 and 8, PATCH among them), of the first
  part of each version 6 stream with parts, and of each PATCH's repaired
  file over 0 to 255, version 8's flags and modes too, and hand-made ones
  (that byte alone, with a zero, with 999 bytes after it): no exception.
- **`PJA_E_VERSION`** (7) in `pja.h`: `pja_decompress` returns it for a
  `.pja` of a later version or whose codec stream is; the filter's
  decoders for a filter version past theirs (`PJAF` 03, `PJAB` 02), a
  record tag from 04 to FE (left for later records) and a file record
  whose codec stream is of a later version. Until 0.9.0 all of these were
  `PJA_E_DATA`; other damage still is. Damage cannot be told apart from a
  newer release in those very bytes: a damaged byte that lands on a codec
  stream's first byte (and makes it 9 to 255), on version 8's flags or on
  one of its K mode bytes (making it other than 0), on a filter version or
  on a record tag (making it 04 to FE) is reported as `PJA_E_VERSION` too
  (in a `.pja` the stream is decoded before the hash, which covers the
  original, is checked). Version 8 adds one such byte per codestream. So
  `PJA_E_VERSION` says "not this release's to read": a newer PJA wrote it,
  or one of those bytes is damaged. The 7-Zip plugin maps it to
  `E_NOTIMPL`, which 7-Zip 25.01 reports as "Unsupported Method" for the
  files of the block, and damaged data to "Data Error", as before
  (checked on archives with the filter's version, a record tag and a
  codec stream's version changed, and with a byte of a stream flipped).

## JPEG 2000, stage B: each codestream taken apart and put back together (05/11/2026)

Stage B rebuilds a JPEG 2000 Part 1 codestream byte for byte from its
headers, some side information and the decisions of its code-blocks. PJA
parses and decodes the codestream itself; the research prototype
(`rb.c`) read logs from an instrumented OpenJPEG instead. Stage C (below)
codes the result with a model as stream version 8's mode 1; there the blob
is version 2, without the `dec` stream and with a slice table after the
streams, and it is fixed with mode 1. The blob of version 1 described here
is only the test's (`test_j2kcs`).

**Where.** `pas/pjaj2kcs.pas` (Pascal, `$R+ $Q+`) parses the main header
and the tile-part headers. It builds tiles, resolutions, bands, precincts
and code-blocks, walks the five progressions and the POCs, decodes and
writes packet headers (tag trees, inclusion, zero bit-planes, passes,
Lblock, lengths) and holds the rules. `pas/pjaj2kt1.c` (C in the
`pjav7c.c` style: no memory taken, no library called, every buffer's size
passed and checked) holds tier-1:
- the coding passes decoded from a code-block's segments, with the MQ and
  raw (BYPASS) decoders and every code-block style (BYPASS, RESET,
  RESTART, CAUSAL, ERTERM, SEGMARK);
- the same passes replayed from the decisions' bits alone, which gives
  each decision its context back (compiled twice, once for each mode);
- the MQ encoder with both terminations, FLUSH and ERTERM;
- the lengths those terminations would give at each pass end;
- the prefix checks;
- BYPASS packing.

Each decision is one byte, `ctx << 1 | bit`: contexts 0-8 zero coding,
9-13 sign, 14-16 refinement, 17 run length, 18 uniform, 19 a raw bit. The
bit is the one the coder codes; for a sign, that is before the prediction's
xor. The decoder follows OpenJPEG 2's conventions: past a segment's end
its bytes are FF, and an FF followed by a byte above 8F ends the data. It
was checked decision by decision against an instrumented OpenJPEG. HL
(x0b = 1) takes the vertical neighbours first in table D.1. OpenJPEG's
table swaps at band 2, but in its transposed flag layout, so it agrees.

**The blob.** A version byte (1), the lengths of ten streams as
varints, then the streams:

| stream | what |
|---|---|
| `hdr` | the main header's and the tile-parts' marker segments as they are, except a TLM or a PLT that follows from the rest (kept as its Z, its style and its count); per tile-part Isot, TPsot, TNsot and Psot (its real length, 0, or the number when the codestream is cut short); what follows the last tile-part |
| `layout` | per tile its packets; per tile-part how many are in it and the bytes after them that are not a packet (padding, a cut, DICOM fragment headers) |
| `t2` | per packet, empty or not, SOP, EPH, Nsop against the count; per code-block of a packet, whether it is in, and its new passes against those left (3 Mb - 2 by the QCD) |
| `zbp` | zero bit-planes on first inclusion, against the band's last |
| `tree` | the tag-tree nodes whose value the decoder learnt differently from the canonical one (a node is the least of its leaves, a leaf the layer of first inclusion or the zero bit-planes, never included: no value) |
| `lblock` | per inclusion, Lblock over the least the lengths need |
| `t1rule` | per code-block whether it is kept as bytes; per segment how it ends; per layer boundary inside a segment its rule |
| `t1x` | explicit data: kept bytes, literal tails, explicit lengths |
| `hdrx` | per packet, whether its header is the canonical one, and if not, its bytes |
| `dec` | the decisions, a bit each, in the order tile, component, resolution, band, code-block (raster in the band) |

How a segment ends (MQ):
- empty;
- FLUSH;
- ERTERM;
- the shortest valid prefix of FLUSH's bytes, or of ERTERM's: the length
  goes down a byte at a time, at most 32, while the shorter prefix still
  decodes every decision with FF after it;
- a literal tail: the bytes committed when the last decision is coded,
  then how far the bits go along with FLUSH's or ERTERM's, the next bit
  the other way, then the rest as they are;
- raw bytes.

A BYPASS segment is its bits with a 0101.., 0 or 1 padding, or raw
bytes. Where a layer cuts a segment:
- OpenJPEG's rule, the bytes committed + 3 with a last FF dropped (for a
  BYPASS segment, the bytes that hold its bits, at most the segment's: a
  damaged codestream's raw decoder can go on past its data);
- Kakadu's, the shortest prefix within K - 3 to K + 8 that decodes the
  passes so far;
- what the decoder has read after those passes: its byte pointer + 1,
  and one more when its bit counter has at most one bit left. Found here,
  in Adobe's Photoshop plugin and in other LuraTech-like files;
- the length against OpenJPEG's.

The analysis tries the cheap rules first, and the rebuild works out only
the one it is told.

**Refused**: the codestream stays in mode 0, and the reason is counted.
- HTJ2K: the CAP's Part 15 bit, or code-block style 0x40;
- Part 2's decomposition styles (DFS, ADS) and coding styles;
- a header that does not parse;
- what passes the limits: 65,535 tiles, 16,384 components, 2^21
  code-blocks and 2^22 precincts a tile, 2^26 progression steps, 2^25
  code-block entries a tile, and more entries in the codestream (a slice
  of it, stage C) than its side information may hold (`J2kSideBound`,
  stage C: each entry takes a byte of it at least).

Not refused:
- a packet that does not fit its tile-part (the rest of that tile-part
  is kept as it is);
- a code-block of more than 120 passes (kept as bytes);
- PPM and PPT: read in the order of Zppm/Zppt and kept as they are.

A code-block one of whose segments ends as raw bytes (rule raw, or a
BYPASS segment's raw bytes) is kept as bytes whole: its decisions would
be paid for a second time (stage C).

The work grows with the codestream's bytes: each tile's tile-parts come
from a list made once (it was a pass over all the tile-parts for each
tile: 65,535 tiles of 4 tile-parts, 3.6 MB, took 274 s in `pja a`), and
the lists of marker segments and tile-parts grow by doubling.

`J2kAnalyze` rebuilds the blob before it says yes, and anything that does
not come back is refused as `verify` (that never happened on the corpus).
`J2kRebuild` checks every number it reads against what it has built. A
damaged blob gives a refusal or other bytes, never an exception. In
fuzzing, damaged blobs came back as a codestream 9% to 23% of the time:
there is no hash in the blob, and stage C's stream has one.

**Two things the parser had to learn.**
- Conformance file g3_colr has its PPM marker segments in decreasing
  Zppm. The data goes in the order of the index, not of the file.
- p0_02 has an FF30 in its main header. FF30 to FF3F are markers with no
  segment, which a decoder skips.

**Tests.** `pas/tests/test_j2kcs.pas`:
- analyses each codestream of the files given;
- rebuilds it from a copy of the blob, after the analysis is gone, and
  compares;
- with `-fuzz N`, damages copies of each codestream (bits flipped
  anywhere or in the first 512 bytes, bytes set to FF/00, cut short) and
  of each blob;
- prints a digest of all the blobs, the same on every platform (x86-64
  and i386 gave the same digest on tests/j2k and on the 30 rebuild
  files).

`tests/j2k` gets five codestreams that cover what the others lack
(tests/README.md): every code-block style, BYPASS cut by layers,
RPCL with precincts and SOP/EPH, PCRL with tiles and tile-parts and
PLT/TLM, and CPRL with a tile POC. `run_codec_tests.sh` and
`.github/test.sh` run it. The streams' hash is unchanged (3387e58d…).

**Results** (05/11/2026). "Side" means the side information, without
the decisions:

| set | codestreams | rebuilt byte for byte | refused | side, xz -9e | decisions per byte |
|---|---|---|---|---|---|
| tests/j2k | 14 | 14 | 0 | 2,884 B of 29,728 | 7.0 |
| 30 rebuild files (7 encoder families, 26.1 MB) | 30 | 30 | 0 | 128,268 B, 0.49% | 12.8 |
| gap1 real-world (113, 150.1 MB) | 113 | 113 | 0 | 415,620 B, 0.28% | 10.8 |
| sample corpus, local and extracted from DICOM/PDF (1,669) | 1,669 | 1,663 | 6: 2 HTJ2K, 2 tiles, 1 Part 2, 1 cut header | | |
| downloads (705 codestreams in 515 files) | 705 | 552 | 153: 87 HTJ2K, the rest broken or fuzz files | | |

No codestream failed, nothing crashed and nothing timed out, here or
under fuzzing:
- 5,640 damaged codestreams and 4,400 damaged blobs from the downloads;
- 2,094 and 1,602 more from the conformance, jpylyzer, rebuild and
  tests sets;
- 2,700 and 2,700 from tests/j2k.

On gap1:
- 0 header exceptions, 65 tree overrides;
- tails 4.5 bits each on 61,147 segments;
- segments: 180k FLUSH, 307k ERTERM, 12k shortest prefix, 61k tails;
- layer boundaries: 8,308 OpenJPEG, 22,933 shortest prefix, 744 decoder
  reach, 2 explicit.

The extracted DICOM codestreams whose fragments were not joined keep the
fragment headers and everything after them as layout bytes.

**Speed** (one thread, this machine, decode plus rebuild): the analysis
with its check runs at 0.65 to 1.0 MB/s of codestream, the rebuild alone
at 1.6 to 2.8 MB/s. Tier-1 takes about 75% of the time; the replay is
dearer than the decode, because it reads its decisions bit by bit.

## JPEG 2000, stage C: the decisions through a model, mode 1 (05/11/2026)

Stage C gives stream version 8 its second codestream mode. A codestream
is taken apart as stage B does (`pjaj2kcs.pas`), its side information
goes through the raw bytes' model, and its code-blocks' decisions through
a context-mixing model in C (`pas/pjaj2kmc.c`). The stream is decoded
and compared before it is kept; it is kept when it is smaller than the
codestream, and the codestream goes in mode 0 otherwise. Mode 1 is fixed
from 0.9.5 on (doc/STABILITY.md).

**Mode 1's stream** (`pas/pjaj2km.pas`), in the version 8 stream's place
for the codestream, whose bytes are cut out of the host:

```
byte 0          layout: 0 (another value: a later release's, FutureVersion)
4 bytes (LE)    a check: the first 4 bytes of the codestream's BLAKE3
4 bytes (LE)    S, the slices: 1 to 64
S x 4 bytes     each slice's decisions' length
4 bytes (LE)    L, the side information's length
L bytes         the side information through the raw bytes' model (CodeRaw)
the S slices    their decisions, each its own arithmetic stream
```

The side information is stage B's blob as version 2: the version byte
(2), the ten lengths (`dec`'s is 0), the nine streams, then the slice
table: S, and for each slice after the first its first tile (its place
among the tiles that have tile-parts), its tables' size (hb, 10 to 20:
2^hb counters at most a table) and where each of streams 1 to 8 (layout
to hdrx) starts; the first slice's are 0. It is at most
`J2kSideBound(n)` = n + n / 4 + 65,536 bytes for a codestream of n bytes:
the encoder keeps a codestream whose would be more in mode 0, and the
decoder refuses a stream whose side information says it is longer as
soon as it reads that length, before decoding it. A small damaged or
crafted stream then costs at most about what mode 0 costs for a
codestream of that length (the raw bytes' model, about 1.2 MB/s); with
the bound at 4n + 65,536, a 4 KB .pja took 14 minutes and 1.3 GiB to be
refused. Measured (stage C's runs): the side information is at most
1.00 times the codestream on the codestreams of 64 KiB or more, and at
most 20 KB more than the codestream below that (a 2,050-byte codestream,
22,325 bytes of side information). A 32-bit program for which the bound
passes its addresses gives `TooLarge`. A decoder checks every number
against what it has built, the slices' streams to the byte where the
next slice starts, and the check against the codestream it rebuilt: a
damaged stream is `BadStream`, never another codestream.

**Slices.** The tiles go in S slices of consecutive tiles, one per 4 MiB
of codestream (1 MiB from 0.9.6: "JPEG 2000 faster", below), at most one a tile and 64; a slice has its own model and
arithmetic stream, so that slices are coded and decoded on several
threads (one TJ2k per slice, `RunSlices`), and the stream is the same
for any number of threads. A codestream of one tile is one slice. Cutting
the Sentinel-2 bands (121 tiles, 46 MB) in 10 slices costs nothing: 0.05%
smaller than one slice, the model adapting to each part.

**Layout 1, kept for files of many codestreams.** Each codestream starts
with a model that knows nothing and has its own side information. On an
MJ2 of 200 frames (Speedway.mj2, 3.0 MB) mode 1 saves 5.97%, of which the
side information costs 2.26% (about 343 bytes a frame, mostly headers
repeated); the decisions coded with the model kept from the frame before
(the coder started again, the tables kept; measured with a harness on
the `-dumpcb` dumps) come out 174 KB smaller, 5.8% of the codestream.
That would be layout 1, a codestream coded on from the previous one of
the file; it is left to a later release. Until one defines it, a layout
other than 0 is `FutureVersion`, and layout 0's streams do not change.

**The decisions.** `pjaj2kmc.c` walks a code-block's coding passes as
`pjaj2kt1.c` does (encoding, it takes the decisions the analysis decoded
and checks each one's context; decoding, it writes them for the rebuild,
which codes them again with the MQ coder) and codes each decision as what
it means for the coefficient, an event of one of five kinds:
- significance in a significance propagation pass, and in a cleanup pass;
- a sign (the coefficient's, not the MQ coder's bit: the sign
  prediction's xor is put back);
- a magnitude refinement bit;
- a run: in a cleanup pass's run mode, whether any of the column's four
  coefficients becomes significant (one event in place of the run
  decision); when one does, the significance of the rows up to it (rows
  0 to 2, the last implied), in place of the two uniform decisions.
  Coding the four rows one by one instead cost 2 to 4 events a run and
  was slower and 0.05% larger;
- SEGMARK's four decisions, by their place.
BYPASS's raw decisions are events of the same kinds. The model knows the
coefficients' values so far: in the code-block, each one's value as the
decoder reconstructs it (1.5 x 2^B when it becomes significant at plane B,
the midpoint after each refinement); around it, the code-blocks already
coded of the band; the band one resolution coarser of the same
orientation (the parent; the LL band for the first resolution) and the
first two components' band of the same resolution and orientation, at
the position scaled by the bands' sizes. Those come from the maps: one
byte a coefficient, floor(2 log2 |v|) + 1 and the sign, kept for the
tile's components 0 and 1 and for the component being coded. Plane B
counts from the band's Mb: the code-block's first pass is at Mb minus its
zero bit-planes.

The features (each clamped):
- the neighbours' magnitude, 2 (left, right, up, down) + the diagonals,
  as 2 log2 against the plane (20 values), the ones two away (14), how
  many of the eight are significant;
- the parent's, 2 x itself + its four neighbours, against the plane and
  the bands' Mb (18), and its sign; the other components' (18) and sign;
- the depth (Mb - B), the orientation and the decomposition level, the
  component (0 to 3), the standard context (the MQ one);
- for a sign, the signs of the six neighbours left, up, right, down, up
  left and up right; for a refinement, the planes since significance, the
  coefficient's next three bits and its magnitude against its neighbours';
- for a run, the magnitude in the 5 x 8 window around the column, the
  parent's and the other components' largest over the four rows, how many
  runs before it in the stripe came to nothing (8 buckets), and whether
  the column is at the code-block's edge.

Eight contexts mix these by kind (`event`, `event_run`); a context whose
values fit 2^hb counters is a table indexed directly, a larger one is
hashed (one multiplication, the top hb bits) into 2^hb. Each context has
two counters: one whose rate slows to 1/256.5 (pjaarith's), and one at
1/8. The 16 stretched probabilities go to three sets of weights, chosen
by kind, neighbours and depth (A), kind, standard context and parent (B),
and kind, orientation and level, component (C); the three dot products
are averaged; then three adaptive probability maps of 33 bins (by kind
and neighbours, by kind, parent and other component, by kind, standard
context and depth), and the final probability is (mixer + the three
maps) / 4, coded by pjaarith's binary arithmetic coder (the same
arithmetic as version 7's, carried out in C). Integer arithmetic only;
the stretch and squash tables are constants (`pas/pjaj2km_tab.h`, made by
`pas/pjaj2km_tab.py`); the C takes no memory, calls no library, and
divides 64-bit numbers by hand on 32-bit targets (no undefined symbol
with gcc, clang, gcc -m32, both MinGW-w64 and aarch64 gcc).

What the tuning on gap1 and the 30 rebuild files (the dumps of
`test_j2kcs -dumpcb`, run through `pjaj2kmc.c` by a harness) kept and
dropped, in % of the decisions' bytes:
- the run as one event: -0.05% and a third fewer events;
- the fast counters: -0.4%; at 1/8 rather than 1/16: -0.04%;
- the second set of weights -0.18%, the third -0.1%; the maps -0.09%,
  the third map -0.05%;
- tables 4 times larger (hb from the slice's bytes / 2 rather than / 8):
  -0.02%; the mixer's rate halved: -0.01%;
- dropped: two of the research model's ten contexts (each 0.00% to
  +0.01% without it), the mixer's constant input (+0.02%, but 16 inputs
  in place of 17), a third counter at 1/64 (-0.04% for 18% more time), a
  learned second layer over the three sets (-0.01%).

**Memory, the worst case.** The planes, 2 bytes a sample: 256 MiB at
2^27 samples. Per worker (a thread rebuilding a slice): a tile's
coefficients, 4 bytes a sample, at most 256 MiB (2^26), and the workers
fewer when the tiles are large (their coefficients 256 MiB at most in
all, one worker at least). The models: the 1-bit one 2 x 2^22 + 3 x 2^20
counters of 6 bytes (66 MiB) at hb 22, the multi-bit one 4.6 MiB and its
rows, 18 int32 a column of the widest plane of 2 bits or more (72 MiB at
the 2^20 samples it may be wide; nothing when every plane is 1-bit). Both
sides refuse, from the SIZ alone and before a plane is made, planes past
2^27 samples, a plane of 2 bits or more (after the colour transform, which
makes a 1-bit RGB 2-bit: the encoder then leaves the colour byte 0) past
2^20 samples wide, and planes of more than max(2^20, 1,024 x the
codestream's bytes) samples: time and memory follow the codestream's
bytes, as stage C's bounds do for mode 1, and not what a few of them
declare (a 139-byte OpenJPEG test file declaring 2^24 samples took 20 s
and 1.3 GiB to be refused before; now none). The widest reversible
multi-bit codestream seen in 5,119 is 49,198 samples (an OpenJPEG test
file; the widest real image, Sentinel-2's, 10,980), and the most samples
a byte of a codestream that mode 2 keeps 318 (a nearly blank book page).
What the bounds leave, measured (blank codestreams of 140 KB, made
`pas/tests/mkj2k_limits.py blank` with COM bytes; the whole test program,
one thread and eight): 11,585 x 11,585 at 8 bits or 1 bit in three tiles
(2^27 samples) encodes (with its check) in 617 MiB and 28 to 39 s and
decodes in 446 MiB and 14 to 19 s; 2^20 x 128 at 8 or 16 bits in four
tiles, 487 MiB and 48 to 62 s, and 411 MiB and 28 to 34 s. The same with an
i386 build (gcc -m32, fpc i386): the same streams, the same memory.

**Tests.** `test_j2kcs -mode1` codes each codestream in mode 1, decodes it
and compares, and prints a digest of the streams; `run_codec_tests.sh`
runs it on `tests/j2k`, again with slices forced to 1,500 bytes
(`PJA_J2K_SLICE`, read only by the tests' programs through
`J2kTestSlicesFromEnv`: the command and libpja never read it, and
`cli.sh` checks that it does not change what `pja a` writes) on 1 and 4
threads (the same digest),
and damages the version 8 streams of `tests/j2k` both ways
(`test_codec_corrupt`: every bit of the first 128 bytes and every
truncation, no exception). `test_j2kcs -mode1` also decodes its first
stream for lengths it is not, up to 5 GB (an error, never the codestream
nor an exception: on 32-bit, 4 x len + 65,536 used to fail a range check
past 512 MiB). `pas/tests/mkj2k_limits.py` makes two codestreams that ask
much work for their bytes: 65,535 tiles of 2 tile-parts (taken) and 111
bytes declaring 2 million code-blocks in 15 layers (refused at the
entries' bound, in under 2 s where it took 30 s and 1.5 GiB);
`run_codec_tests.sh` runs both and fails past 90 s. `tests/j2k` is in
the builds' comparison (reference, fast, fast without asm, 4 threads,
and in slices).
`test_versions` sweeps the mode byte (2 to 255: `FutureVersion`), mode 1's
layout byte (1 to 255) and reads mode 1 without the hooks
(`FutureVersion`). `cli.sh`: a JP2 modelled, and a mode of a later
release. `.github/test.sh` adds a second line to `hash.txt`, the SHA-256
of the version 8 streams of `tests/j2k` (whole, and in slices on 4
threads), so the first line, the JPEG and JPEG-LS streams', is unchanged
(3387e58d…); the CI's last job compares the files. On x86-64 (clang)
and i386 (gcc -m32) here, `hash.txt` is the same, its second line
`j2k da21961d…`, and so are the mode 1 streams' digest (FC23950B095EA60B)
and stage B's blobs' (A8FBC05E4A8B3D47). Both suites
(`run_codec_tests.sh`, `run_tests.sh`) pass.

**Results** (06/11/2026; "saves" is net, side information and check
included, and counts each codestream as `CompressJ2k` keeps it: its mode
1 stream, or the codestream in mode 0 when that is not smaller):

| set | codestreams | in mode 1, back byte for byte | bytes | saves | of which side information |
|---|---|---|---|---|---|
| gap1 real-world (7 sources) | 113 | 113 | 150,122,046 | **7.77%** | 0.30% |
| gap1, tuned on (2 of 3 by name) | 76 | 76 | 118,090,768 | 7.12% | 0.22% |
| gap1, held out (every third) | 37 | 37 | 32,031,278 | 10.18% | 0.59% |
| 30 rebuild files (7 encoder families) | 30 | 30 | 26,058,518 | 10.33% | 0.50% |
| 30 rebuild files, held out | 10 | 10 | 13,432,971 | 9.41% | 0.24% |
| sample corpus, local and from DICOM/PDF | 1,671 | 1,665 (6 refused) | 49,950,421 | 8.83% | 14.9% |
| downloads (705 codestreams, 2,051 files) | 705 | 552 (153 refused, as stage B) | 246,703,261 | 8.76% | 2.29% |
| tests/j2k | 14 | 14 | 29,728 | 15.28% | 13.6% |

The sample corpus has two more codestreams than first counted (two
files whose names have spaces, which the first runs' harness split).
Keeping a code-block whose segment ends as raw bytes as bytes whole
(stage B) changed nothing on gap1, the rebuild files and `tests/j2k`
(no such segment: the same streams); on the sample corpus and the
downloads it made 32 codestreams' mode 1 streams smaller and one 16
bytes larger (p1_05.j2k), and 19 of those codestreams now go in mode 1
where they stayed in mode 0: kodak_2layers_lrcp.j2c 3,508,838 bytes to
3,240,277 (the codestream: 3,363,991), US1_J2KR from DICOM 255,004 to
148,076 (152,291), and 7 more DICOM files; issue432.jp2 went from 163,329
to 26,092 (22,955: still mode 0). The two sets went from 8.79% and 8.65%
to 8.83% and 8.76% (from 7.59% and 8.38% counting mode 1 alone).

The research's ideal for gap1 was 7.48%; the held-out parts were never
seen by the tuning (the split is by the files' names, so the large
Sentinel-2 bands, 62% of gap1's bytes, fell in the tuned part: the parts
weigh differently, not better). gap1 by source:

| source | codestreams | bytes | saves |
|---|---|---|---|
| Internet Archive book pages (Kakadu 5.1 to 7.9, LuraTech) | 44 | 15,503,437 | 13.29% |
| Library of Congress (Aware, Kakadu, one unknown) | 3 | 24,834,867 | 9.39% |
| OSGeo (Kakadu) | 6 | 321,779 | 9.77% |
| Internet Archive PDFs' images | 26 | 951,809 | 7.95% |
| Helioviewer (Kakadu 6.4, 8 layers) | 10 | 7,416,666 | 6.92% |
| Sentinel-2 (Kakadu) | 7 | 93,728,590 | 6.69% |
| DICOM (Kakadu, OpenJPEG, JasPer) | 17 | 7,364,898 | 5.16% |

The sample corpus's codestreams from DICOM files keep their fragments'
headers as layout bytes (stage B), which is most of their side
information. Nothing failed, crashed or ran out of time in any set; the
codestreams stage B refuses (HTJ2K, Part 2 styles, broken headers) stay in
mode 0. Damaged streams (`test_codec_corrupt`, every bit of the first
256 bytes and every truncation of four real files' streams: 19,136
variants) gave `BadStream` or the original, never an exception.

**Speed** (this machine, a Xeon E5-2697A v4, one thread, per MB of
codestream; encoding includes the analysis, the model and the decoding
that checks it):

| codestream | encoding | decoding |
|---|---|---|
| a book page, 1.3 MB, one tile | 0.11 MB/s | 0.22 MB/s |
| solar image, 1.1 MB, 8 layers | 0.13 MB/s | 0.26 MB/s |
| DICOM lossless, 4.3 MB | 0.24 MB/s | 0.51 MB/s |
| Sentinel-2 B04, 46 MB, 121 tiles (10 slices) | 0.21 MB/s | 0.47 MB/s |
| the same on 8 threads | 0.95 MB/s | 1.98 MB/s |

The model alone codes 0.33 to 0.6 MB/s (as the research's C path,
0.5 to 0.6); it costs about 2,000 instructions an event, spread over its
8 table lookups, the three dot products of 16 and their updates, the maps
and the counters. Slices give threads only to codestreams of 8 MB or
more with several tiles; a file's codestreams go one after the other.

**Open.** The side information goes through the generic raw bytes' model
(0.30% of gap1, 0.50% of the rebuild files, where xz -9e on each stream
gave 0.28% and 0.49%): a model of its streams (zero bit-planes against the
code-block above, the rules against the last ones) is a later mode 1
layout. Speed: SSE4.1 or AVX2 copies of the mixer (10% measured) and
codestreams of a file in parallel. A single-tile codestream is one slice,
one thread.

## JPEG 2000 and the 0.9.5 command together (06/11/2026)

The JPEG 2000 work (stream version 8, stages A to C) and the 0.9.5 speed,
durability and command branches merged into one. Nothing in a stream
changed: the stream hashes of `.github/test.sh` (JPEG's and JPEG 2000's
lines) and `test_j2kcs -mode1`'s digest are the ones each branch had.

- **The stage timers** (`--stats`, `bench`; `pjastage`) count JPEG 2000
  too: `parse` is the walk of the box tree (`J2kCodestreams`), `encode`
  each codestream taken apart with its decisions through the model, and
  `verify` both mode 1's own check of each codestream's stream (`pjaj2km`
  decodes it before it gives it) and the whole stream read back. A
  codestream's slices count as its bands (`pjainfopja.StreamBands`).
- **Scheduling**: the largest files first and the threads shared out
  between files and within each (bands, slices) apply to JPEG 2000 files
  as they are: the order goes by the file's size, and the threads a file
  gets go to its codestreams' slices.
- **`pja selftest`** carries a JPEG 2000 codestream (tests/j2k's
  `rpcl_sop_eph.j2k`, RPCL with SOP and EPH, 2318 B -> 554 B in mode 1),
  whose `.pja` has to be the same bytes on every SIMD path.
- **`pja info` and `report`** describe JPEG 2000 files (`pjainfoj2k`):
  the box tree, each codestream's SIZ, COD, CAP and tiles, its markers,
  and what PJA does with it: mode 1 with the bytes its stream takes, or
  mode 0 with the analysis's reason. 400 damaged copies of tests/j2k's
  files: no exception, and each file's mode 1 bytes the same as `a`'s.

Speed, alternating A/B, best of 3, 8 threads (`taskset -c 0-7`), `a` and
`x` of the whole set: 10 photos of the corpus (7.6 MB), the merged binary
against rel-095 before the merge, 4.46 / 2.21 s against 4.51 / 2.13 s,
then 4.54 / 2.15 against 4.57 / 2.15 and 4.60 / 2.14 against 4.71 / 2.25
(the same within the noise, the same bytes); three real JPEG 2000 files
(1.3 MB), against the j2k branch alone, 4.57 / 2.25 s against 4.65 /
2.28 s, the same bytes.

## JPEG 2000, stage D: mode 2, the pixels (06/11/2026)

Stage D gives stream version 8 its third codestream mode. A reversible
codestream (the 5/3 wavelet, every code-block's passes there, as lossless
encoders write them) is kept as its pixels and what it takes to make the
codestream again from them: the pixels go through a pixel model, the side
information is mode 1's, and the decisions are not stored at all, since
the coefficients give them back. A bitonal page (the Internet Archive's
books: 1 bit, Kakadu) comes out at under a third of its codestream (70.6%
saved), where mode 1 saves 17%.

**Mode 2's stream** (`pas/pjaj2kpx.pas`), in the version 8 stream's place
for the codestream, whose bytes are cut out of the host as mode 1's:

```
byte 0          layout: 0 (another value: a later release's, FutureVersion)
4 bytes (LE)    a check: the first 4 bytes of the codestream's BLAKE3
4 bytes (LE)    L, the side information's length
L bytes         the side information through the raw bytes' model (CodeRaw):
                stage C's blob (version 2, with its slice table), at most
                J2kSideBound(n) bytes for a codestream of n, as mode 1's
byte            hb: the bitonal model's two large tables have 2^hb counters
                and its three far ones 2^(hb - 2), hb 12 to 22 (the
                encoder: the 1-bit samples, rounded up)
byte            the colour: 0, or 1 when planes 0 to 2 go to the model as the
                reversible colour transform makes them (below)
the rest        the planes, one after the other, through the pixel models
                (pas/pjaj2kpm.c) with one arithmetic stream
```

**The planes.** One a component: the image area of the SIZ on that
component's grid, ceil(Xsiz / XRsiz) - ceil(XOsiz / XRsiz) samples wide
and the same down, so the decoder knows them from the side information's
SIZ (`J2kBlobSiz`) before it decodes a pixel. A sample is v + 2^(depth -
1) for the value v a decoder's inverse transforms give before it adds the
level shift (for an unsigned component that is the sample itself, for a
signed one the same offset), 0 to 2^depth - 1, kept in 16 bits.

**From the codestream to the pixels** (the analysis, `kmPixEncode`):
stage B takes the codestream apart as for mode 1 (`pjaj2kcs.pas`, the same
side information); each code-block's decisions as decoded become its
coefficients (`pjaj2kp_cb_coef`, walking the passes as `pjaj2kt1.c` does:
a decision of pass k is at plane Mb - zero bit-planes - 1 - (k + 2) / 3; a
coefficient is its sign and the bits its passes coded, nothing added for
the planes left out), and the coefficients give the same decisions back
(`pjaj2kp_cb_sym`, checked code-block by code-block). When a tile's
code-blocks are done: the inverse 5/3 wavelet of each tile-component
(F.3: rows then columns at each level, the signals' first sample at the
parity of the resolution's place on the grid, symmetric extension, a lone
odd sample halved), the inverse reversible colour transform when the
tile's COD has it (G.2), the level shift, and the samples into the
planes. Then the planes go through the model.

**Back** (the rebuild, `kmPixDecode`): the planes from the model; for each
tile, its samples, the forward colour transform when its COD has it, the
forward 5/3 (F.4: columns then rows), and each code-block's decisions from
its coefficients, with the passes and zero bit-planes the side information
gives; from there on the rebuild is mode 1's (the MQ coder and the rules
of how segments end, the packet headers, the tile-parts). The integer 5/3
and the colour transform are exact both ways (each lifting step is undone
by the other, and the decoder never clips): the coefficients that come
back are the ones the codestream had, bit for bit. The one inverse the
forward cannot undo, a lone sample at an odd place whose coefficient is
odd, is refused when it is met.

**Taken** (`TPx.Tile` and the C side; anything else: the codestream goes
to mode 1, or 0):
- every tile-component reversible: the 5/3 wavelet, no quantization (QCD
  or QCC style 0), an exponent for each band; no RGN;
- 1 to 16 bits a component (signed too), the planes 2^27 samples at most
  in all and at most max(2^20, 1,024 x the codestream's bytes), a plane of
  2 bits or more (as the model takes it) at most 2^20 samples wide, a
  tile's coefficients 2^26 (32-bit, all its components): see "Memory";
- the colour transform only on components 0 to 2 of the same size;
- every code-block decodes (no code-block kept as bytes for not decoding;
  one kept as bytes for its ending rule is fine), its passes within its
  bit-planes, its coefficients within 30 bits, and each one gives its
  decisions back;
- every code-block with all its passes: 3 P - 2 for P bit-planes (Mb
  less its zero bit-planes), less the trailing passes that change nothing
  (make no coefficient significant, refine none), which Kakadu leaves out
  (`pjaj2kp_cb_full`, from the coefficients). A code-block with fewer lost
  passes to the encoder's rate control: the codestream is lossy and its
  pixels are not the image's, so mode 2 does not take it ("rate-truncated":
  `tests/j2k`'s eleven made with `opj_compress -r`, which writes the
  reversible 5/3 and cuts it by rate). The integer 5/3 would still bring
  them back byte for byte, but a pixel model cannot beat mode 1 on them;
- every sample within its range;
- and the stream decoded and compared with the codestream, as always.

**Choice** (`pjacodec.CompressJ2k`): mode 2 first (a stream that is not
shorter than the codestream is not decoded to be checked: it would not be
kept), then mode 1 unless mode 2's stream is no longer than the least mode
1's could be: the side information (the same in both, as coded) and half
the codestream's bytes that the side information does not keep (mode 1
saves a fifth of those on the codestreams it does best), so that a
bitonal page is not coded twice; the smaller of the two, when it is
smaller than the codestream, and mode 0 otherwise. A large COM or other
bytes kept in the side information do not count as what mode 2 saved
(`tests/j2k/lossless_com.j2k`: mode 2 takes it to 23% of its bytes and
mode 1 is still smaller; the earlier rule, mode 1 only above half the
codestream, kept mode 2). The hooks are set by `pjaj2kpx`, which the command, libpja and
the tests use; without it (the zpaq-std plugin) mode 2 is
`FutureVersion`.

**The 1-bit model.** Each row of a 1-bit plane with seven templates, kept
in sliding windows. Four of the rows y - 2 to y: 10 pixels (JBIG's
three-line template), 16, 22 and 30 (the 16-pixel one in a table indexed
directly, the 22- and 30-pixel ones in tables of 2^hb counters, directly
when they fit, by a hash otherwise). Three reach farther, each hashed
(64-bit multiplicative) into a table of 2^(hb - 2) counters: rows y - 4
(x - 4 to x + 4) and y - 3 (x - 8 to x + 8) with the 22-pixel template;
row y - 1 from x - 16 to x + 16 with row y from x - 16 and five pixels of
row y - 2; and the 10-pixel template with sparse pixels at x - 4, x and x
+ 4 of rows y - 6, y - 8 and y - 12 (a text line's height away), at x ±
12 and x ± 20 of row y - 1 and at x - 12 and x - 20 of row y. Each
context has the two counters of mode 1's model (one slowing to 1/256.5,
one at 1/16); the 14 stretched probabilities go to a set of weights
chosen by 8 nearby pixels (learning at 1.5 times the multi-bit mixers'
rate), and an adaptive probability map of 33 bins chosen by the 10-pixel
template; (mixer + map) / 2 goes to PJA's binary arithmetic coder. The
three far templates took 8.8% off the book pages' pixel bytes (359,071 to
327,628 on the 11 pages' planes) for 1.7 times the model's time.

**The 2 to 16-bit model.** Each sample is predicted by eight predictors
(MED; a + b - c; b + (d - c) / 2; a + (d - b) / 2; MED plus the previous
component's error under MED when that component has the same size, else
(a + d) / 2; b; a; and a sign-sign LMS over seven neighbours), weighted
by their errors at the neighbours above and to the left (each half
octave of error halves a weight). The residual, aligned by the sign of
LOCO's gradient context and reduced modulo the range, is coded as zero or
not, its bit length (whether it is more than k, k = 1, 2..), its two top
mantissa bits and its sign; each of those decisions mixes five contexts
(LOCO's mean residual of the gradient context, the context itself, the
neighbours' residuals, the previous component's error, the predictors'
least error and their spread), with sets of weights and a map as above;
the other mantissa bits have a counter each. With the colour byte, planes
0 to 2 go through the reversible colour transform first (Y, then Db and
Dr + 2^depth, of depth + 1 bits; 15 bits at most): the encoder sets it
when every tile of the codestream has the transform, what the
codestream's own encoder found best. Tuned on the planes of 12 lossless
codestreams (OpenJPEG, Kakadu and JasPer: photos, DICOM, Sentinel-2;
dumped by a build with -dPJA_PX_DUMP): the predictors, their weighting
and the contexts on their errors took 2.4% off MED with LOCO's bias
alone, and the colour transform 13% off an RGB photo (87,012 bytes where
its RGB planes gave 98,365; its codestream 90,563).

**Memory, the worst case.** The planes, 2 bytes a sample: 256 MiB at
2^27 samples. Per worker (a thread rebuilding a slice): a tile's
coefficients, 4 bytes a sample, at most 256 MiB (2^26), and the workers
fewer when the tiles are large (their coefficients 256 MiB at most in
all, one worker at least). The models: the 1-bit one 2 x 2^22 counters of 6 bytes (48 MiB) at
hb 22, the multi-bit one 4.6 MiB. A stream that says more is refused
before the planes are decoded. The most a few bytes can ask is planes at
the bounds: blank codestreams of 646 bytes (11,585 x 11,585 at 8 bits, two
tiles: 2^27 samples) and 252 bytes (8,192 x 8,192 at 1 bit, one tile:
2^26) decode in 24 s and 7 s on one thread here, in 539 MiB at most (the whole test program).

**Tests.** `tests/j2k` gets `bitonal.j2k` (a 1-bit plasma, 320 x 240,
lossless) and `rgb_tiles53.j2k` (a lossless RGB with the colour transform,
four tiles on an image offset by (5, 3), so that signals start at odd
places), both made with `opj_compress` from the repository's images
(tests/README.md); mode 2 takes and keeps both. `lossless_com.j2k`
(`lossless53.j2k` with a COM of 9,939 bytes) is one that mode 2 takes to
under half its bytes while mode 1 is smaller still: the choice must try
mode 1 too. `test_j2kcs -mode2` codes
each codestream in mode 2 when it is taken, decodes it and compares, prints
a digest of the streams and why the others are not taken, and with
`-mode1` what the choice gives each; `-m2fuzz N` decodes N damaged copies
of each mode 2 stream and takes N / 4 damaged copies of its codestream as
mode 2 (refused, or a stream that gives them back: never an exception nor
a stream that does not come back); and each stream it takes again with
its side information's SIZ set past the bounds (2^21 samples wide;
1,024 x max(2^17, n + 1) samples), which must be refused at once.
`run_codec_tests.sh` runs them on `tests/j2k` (five codestreams taken,
the twelve rate-truncated ones refused; 1,500 damaged streams, 375
damaged codestreams, 10 streams past the bounds), with the choice fixed
(15 codestreams in mode 1, 2 in mode 2, `lossless_com.j2k` in mode 1),
the same digest on 1 and 4 threads in slices of 1,500 bytes, and two
blank codestreams of 82 bytes (`mkj2k_limits.py blank`: 2^21 x 1 and
4,096 x 4,096) refused as too wide and as too many samples for their
bytes. `test_versions` sweeps the
mode byte (3 to 255: `FutureVersion`), mode 2's layout byte (1 to 255) and
reads mode 2 without the hooks (`FutureVersion`). `cli.sh`: `bitonal.j2k`
in mode 2 (the mode byte in the `.pja`, under 60% of the file, back byte
for byte), `rgb_tiles53.j2k` back byte for byte, one bit of a mode 2
stream's pixels damaged (rc 1, nothing written).

**Results** (06/11/2026; "saves" is net and counts each codestream as
`CompressJ2k` keeps it: mode 2, mode 1 or the codestream; "mode 2 took"
means the codestream was taken and its stream decoded and compared, byte
for byte, whether or not it was smaller; no codestream failed anywhere):

| set | codestreams | mode 2 took | chose mode 2 | bytes | saves | stage C (mode 1 alone) |
|---|---|---|---|---|---|---|
| gap1 real-world (7 sources) | 113 | 29 | 19 | 150,122,046 | **8.47%** | 7.77% |
| 30 rebuild files (7 encoder families) | 30 | 9 | 7 | 26,058,518 | 11.75% | 10.33% |
| sample corpus, local and from DICOM/PDF | 1,663 | 84 | 67 | 48,603,647 | 10.26% | 8.77% |
| downloads (by unique name) | 550 | 97 | 59 | 246,684,904 | 9.28% | 8.76% |
| tests/j2k | 17 | 5 | 2 | 51,634 | 32.81% | 31.57% |

gap1 by source: the Internet Archive's book pages (44 codestreams)
17.22% (13.29% in mode 1 alone; their 10 bitonal pages in mode 2),
DICOM 6.24% (5.16%), Sentinel-2 7.07% (6.69%: B8A, TCI and one B01 in
mode 2), the others unchanged. By encoder family (the COM marker
segment), what mode 2 took and chose:

| set | Kakadu | OpenJPEG | JasPer | no COM | other |
|---|---|---|---|---|---|
| gap1 | 23 of 92, 15 | 4 of 6, 2 | 1 of 1, 1 | 1 of 2, 1 | 0 of 12 |
| rebuild files | 4 of 12, 2 | 2 of 8, 2 | 3 of 4, 3 | 0 of 1 | 0 of 5 (Aware, ECW, LuraTech) |
| sample corpus | 27 of 819, 26 | 35 of 646, 20 | 5 of 6, 4 | 16 of 33, 16 | 1 of 159, 1 |
| downloads | 53 of 159, 33 | 7 of 229, 4 | 0 of 7 | 22 of 78, 12 | 15 of 74, 10 |

What mode 2 did not take: not reversible (the 9/7 wavelet or quantized:
73 of gap1's, 17 of the rebuild files', 640 of the sample corpus's, 184
of the downloads'); rate-truncated (2 in gap1, 3 rebuild files, 612 in
the sample corpus, 224 in the downloads: `opj_compress -r`, lossy DICOM,
Motion JPEG 2000 frames); planes past the bounds (7 + 2 in gap1, 325 in
the sample corpus, 11 in the downloads: maps, nearly blank pages, PDF
images and OpenJPEG's test files, none of which mode 2 would keep); and
a few out of range, with a colour transform on unequal components, RGN,
or more than 16 bits. The all-passes rule costs one codestream mode 2
used to win: OpenJPEG's `Bretagne2.j2k` (5.4 MB, 1.2.0, three layers
whose last is cut by rate: an LL code-block of 9 passes where 12 change
something) went in mode 2 at 4,543,834 bytes and goes in mode 1 at
4,931,037 (the downloads saved 9.42% with it). In exchange the encoder no
longer spends mode 2's time on lossy codestreams (200 Motion JPEG 2000
frames of 15 KB, each tried and lost at 37 KB, are refused at their first
truncated code-block).

**The bitonal pages** (the Internet Archive's, Kakadu 5.1 to 7.9, 1 bit,
5.5 to 14.4 megapixels; the research's JBIG1 for comparison):

| page | codestream | mode 1 | kept | saves | JBIG1 |
|---|---|---|---|---|---|
| 0932890343_0005 | 73,272 | 61,490 | 24,010 | 67.2% | 61.7% |
| 0932890343_0021 | 120,366 | 100,682 | 37,114 | 69.2% | 63.9% |
| waq43664_0005 | 65,135 | 52,007 | 16,798 | 74.2% | 70.1% |
| waq43664_0021 | 116,595 | 93,977 | 28,234 | 75.8% | 69.4% |
| y2010_waq10932 (nearly blank) | 539 | 425 | 425 (mode 1) | 21.2% | 70.5% |
| y2011_waq104752 | 73,753 | 59,474 | 20,195 | 72.6% | 68.6% |
| y2011_waq64169 | 62,770 | 50,065 | 14,519 | 76.9% | 70.4% |
| y2013_WAQ123451 | 16,641 | 13,168 | 5,444 | 67.3% | 67.6% |
| y2014_WAQ144815 | 62,111 | 51,391 | 15,086 | 75.7% | 68.2% |
| GreekBiologyAndMedicine_0005 | 249,321 | 205,315 | 64,087 | 74.3% | 67.4% |
| GreekBiologyAndMedicine_0021 | 299,303 | 256,307 | 109,457 | 63.4% | 57.9% |
| all 11 | 1,139,806 | 944,301 | 335,369 | **70.58%** | 64.6% |

(With the four-template model of the first stage D build: 366,771 bytes,
67.82%.) The side information is 0.72% of the codestreams (8,183 bytes,
as mode 1's), 2.4% of what mode 2 keeps. The nearly blank page (JBIG1:
159 bytes) is past the bounds now (5.5 million samples in 539 bytes) and
mode 1 keeps it, as before.

**Damage and fuzzing.** `test_j2kcs -mode2 -m2fuzz` as before, and the
review's tool (`m2tool fuzz`: damaged streams, damaged side information
coded again, damaged hb and colour bytes, damaged pixels, and damaged
codestreams through the encoder) for 130 s each on six codestreams mode 2
takes (`bitonal.j2k`, `rgb_tiles53.j2k`, `lossless_com.j2k`, a book page,
a DICOM, JasPer's `input.j2k`): 48,358 variants, no exception, no wrong
codestream, none slow (more than four times its codestream's own
decoding and 2 s). The 129 slow cases of the review (fuzzed SIZ heights and
widths) now take at most 0.03 s to decode (refused for their bytes) and
the encodings at most 19 s (a 105 KB codestream that declares 67 million
samples: within the bounds; `pja a` takes 11 s on it with mode 1, since
the encoder no longer decodes to check a mode 2 stream that is not
smaller). Every stream mode 2 took in gap1 and the
corpus (219 codestreams) set past the bounds by its SIZ: 438 refused at
once. `run_codec_tests.sh` adds 1,500 damaged streams and 375 damaged
codestreams, `test_codec_corrupt`
damages the version 8 streams with mode 2 in them (every bit of the first
128 bytes, every truncation).

**Speed** (this machine; encoding with the decoding that checks it): a
book page of 14.4 megapixels (299 KB of codestream) takes 4.0 s in mode 2
and decodes in 1.9 s on one thread (mode 1: 3.1 s and 1.5 s); the 1-bit
model codes about 7 megapixels a second, 1.7 times the time of the first
build's four templates. The 2 to 16-bit model codes about 2.8 million
samples a second. Whole sets, with the choice (8 threads): gap1 0.32
MB/s encoding and 0.70 MB/s decoding in mode 2.

**The streams are the same everywhere.** x86-64 (gcc; clang's
objects give the same `tests/j2k` streams) and i386 (gcc -m32): `hash.txt`
the same, its JPEG line unchanged (3387e58d…), its
j2k line now `59a5774e…` (the bitonal model, the new sample); mode 2's
digest on `tests/j2k` 4EAA3FD936B1C654 on both. Mode 1's streams of the
14 earlier codestreams (FC23950B095EA60B) are unchanged.

**Open.** Mode 2's side information is mode 1's, with the zero
bit-planes and how each segment ends that the coefficients could predict
(2.4% of a bitonal page's mode 2 stream; the zero bit-planes alone,
about 2.3 KB of the 11 pages' 8.2 KB, would take about 0.5% off them: a
new layout byte if it comes); a page of two values kept at 8 bits
(`opj_compress` from a PBM) goes through the multi-bit model, three times
what the 1-bit one makes of it; the pixel models run on one thread; a
codestream within the bounds whose tiles are mostly missing (a damaged
SIZ) still costs the planes its SIZ declares (a tighter bound would count
only the tiles that have tile-parts).

## Mode 2 in the 0.9.5 command (06/11/2026)

Stage D merged into the 0.9.5 branch. Nothing in a stream changed; what
the command says of mode 2:

- **`--stats` and `bench`**: mode 2's `encode` is the codestream taken
  apart and its pixels through the pixel models; its own check (the
  stream decoded and compared before it is kept, as mode 1's) is
  `verify`, with the whole stream read back. A codestream of mode 2 is
  one band (its planes are one arithmetic stream); mode 1's slices are
  bands as before.
- **`pja info`** on a JPEG 2000 file no longer codes it by default (the
  modes' work took minutes on a large MJ2): each codestream gets a
  verdict from its headers alone, mode 2 eligible or why not (`not
  reversible: the 9/7 wavelet`, `not reversible: quantized`, `RGN`,
  `HTJ2K`, `Part 2`, the SIZ's caps: `more than 16 bits`, `too wide`,
  `too many samples`, `too many samples for its bytes`, from
  `pjaj2kpx.J2kMode2SizWhy`, the encoder's own check), mode 1 analysable
  or why not, and whether the codestream is complete. Whether every
  code-block has all its passes (rate truncation) only the coding tells.
  `info --estimate` codes each codestream as `CompressJ2k` does (mode 2,
  then mode 1 unless mode 2 is below mode 1's floor) and shows the chosen
  mode with its saving and the other mode's size or reason; `pja: takes
  it ...` then splits the bytes into `modelled (mode 1)` and `as pixels
  (mode 2)` (`j2k_pixels_bytes`, from the codec's new
  `TCodecResult.j2kPixels`). On gap1's 113 real codestreams the
  headers say 82 not eligible (62 the 9/7 wavelet, 11 quantized, 9 the
  caps) and 31 eligible, of which `--estimate` keeps 19 in mode 2; never
  "not eligible" where the coding takes mode 2. The largest (45.8 MB)
  takes 0.04 s by default, minutes with `--estimate`.
  `pja report` does the dry run, as it must, up to 64 MB; above, a note.
- **Stored as is**: a JPEG 2000 file goes in the stream when the stream
  is smaller than the file, and stored as is otherwise, exactly as a JPEG
  (`pjapack.Pack`: the payload against the original, the 40-byte header
  being the same either way). `tests/j2k/cprl_poc.j2k`'s .pja (1206 B ->
  1230 B) holds a 1190 B stream: stored it would be 1246 B. A file whose
  stream is no smaller (`plasma_cs.j2k`, 612 B) is stored (652 B).
- **`pja selftest`** carries a mode 2 sample too, `tests/j2k/bitonal.j2k`
  (1448 B -> 783 B), whose `.pja` has to be the same bytes on every SIMD
  path and word size.

## JPEG 2000 faster (06/11/2026)

For 0.9.6, without a change to any format: every stream version 8 stream
is byte for byte 0.9.5's for the same file and settings, but for the
slicing of large tiled codestreams, which is the encoder's choice and is
written in the stream (below). Checked: the `.pja` of gap1's 113 real
codestreams and the 30 rebuild files, against 0.9.5's, all 143 the same
bytes with 4 MiB slices and the same but for nine tiled codestreams of 2
MiB or more with 1 MiB slices; `tests/j2k`'s digests (stage B's blobs,
mode 1 4A8994DE27F6BB08, in slices D106D2C0344B1AC2, mode 2
4EAA3FD936B1C654, in slices 3E68FE182353F288, the choice), and
`hash.txt` native and 32-bit (FPC i386, `clang -m32`): `3387e58d…` and
`j2k 59a5774e…`, main's. No C object references `__divdi3`,
`__moddi3`, `__udivdi3` or `__umoddi3` (`nm -u`, both word sizes).

**Where the time went** (callgrind, 0.9.5, one thread). A book page
(`056_1970-01_202503_0005`, 324 KB, Kakadu, 9/7, one tile) took 15.7 G
instructions to compress: 92% in mode 1's model (`pjaj2km_cb`, coding and
then decoding the decisions for the check), 3.5% tier-1's decoding, 1.7%
the MQ coder's endings; extracting, 7.5 G, the same model. About 8.6
million events each way, 850 instructions an event. Builds that change
the stream, made only to see where the time goes (the check's decoding,
900 ms): the model's probability a constant, 262 ms; with its contexts
still computed, 407 ms; two of the three sets of weights left out, -10%;
the three maps left out, -3%; every table 2^10 counters (the counters'
cache misses), -5%. So no single part: the mixing about half, the
contexts about a sixth, the passes, the code-blocks' setup and the
rebuild the rest. Cutting the mixers' instructions by AVX2 took 21% of the
decoding's instructions but only 4% of its time: an event waits on the
one before (its bit, its counters, its weights), the processor is not
short of instructions to run.

A bitonal page (`047_GreekBiologyAndMedicine_0021`, 299 KB, 14.4
megapixels, mode 2) took 34.7 G instructions: 76% the pixel model (coding
and decoding), 6% the 5/3 lifting (most of it the symmetric extension of
every sample), 4% zeroing its tables a byte at a time.

**What changed**, the streams the same:

- **SIMD copies of the models.** `pjaj2kmc.c`'s passes (mode 1) and
  `pjaj2kpm.c`'s two pixel models (mode 2) compiled again with
  `target("sse4.1")` and `target("avx2")`, as `pjav7c.c`'s loop, and
  taken by pjamodel's cpuid (`UseSse41`, `UseAvx2`; `PJA_NOASM=1` and
  `PJA_NOAVX2=1` turn them off, `PJA_V7_PLAIN` leaves them out, `--cpu`
  and `selftest` follow). The same C: the mixers' 16 lanes in `pmulld`,
  `pminsd` and `pmaxsd` instead of SSE2's `pmuludq` and compare-and-blend,
  the same 32-bit wrapping arithmetic. `run_codec_tests.sh` already
  compares the reference build (`PJA_NOASM=1`) with the fast one, the fast
  one without asm and on 4 threads for `tests/j2k` whole and in slices.
- **Fewer branches.** The arithmetic coder's interval without a branch on
  the bit (decoding, about one guess missed an event); `q2log` with one
  bit scan and no test (64-bit targets: `__builtin_clzll`, still two
  32-bit scans on 32-bit ones), the contexts' logarithms (`ln`, `ln2`,
  the run's window, the refinement's `rel`), `sgn3`, the maps' bytes and
  the run's bucket as selects.
- **A code-block's setup.** The values around a code-block from the maps:
  the array zeroed, then only its border of two read (it tested every
  entry); the parent's values, each parent coefficient once for the
  coefficients it maps to (about four), rows and columns that map where
  the one before did copied.
- **The bitonal model.** Where every pixel the windows take in (up to x +
  25) is inside the row, without the bounds tests (a row above the plane
  reads row y, masked to 0); its tables and the model zeroed 8 bytes at a
  time; the 5/3 lifting without the symmetric extension inside the line,
  and its 30-bit check without an early exit (it vectorizes).
- **One check per codestream.** `CompressJ2k` coded mode 2, checked it by
  decoding it, coded mode 1 and checked it too, then kept the smaller.
  Now both are coded first and only the stream kept is decoded and
  compared (`J2kChoose`); if it does not come back, the other is checked,
  and mode 1 coded then if it had not been: the same choice as before in
  every case. A lossless codestream that both modes take loses one
  decoding of the two (a Sentinel-2 B01, 1.47 MB: the checks 4.5 s -> 1.8 s).
- **The two modes side by side.** With threads to spare, mode 1 is coded
  on a thread of its own while mode 2 codes: for a reversible (5/3)
  codestream of more than one bit, up to 64 MB, where both are nearly
  always coded. Mode 1 gets as many threads as it may have slices (one a
  MiB of codestream), mode 2 the rest, one at least (its pixels are one
  arithmetic stream; the others go to its tiles' wavelets). A bitonal
  page's mode 2 is nearly always below the least mode 1's could be, and
  mode 2 refuses the 9/7 at once (mode 1 then gets every thread), so
  neither is coded beside. A mode 1 stream coded beside a mode 2 one below
  its floor is not looked at (the same choice).
- **A file's codestreams side by side.** A file of several codestreams of
  at most 4 MB each and 2^22 samples (image area times components) each
  (Motion JPEG 2000's frames, JPX layers) codes them on the threads, and
  `ReadJ2k` decodes them side by side before putting them in place.
  Decoding, the decoders refuse a SIZ past 2^22 samples there
  (`pjaj2k.J2kSamplesCap`, before they allocate: eight small codestreams
  that each declare the bounds' planes would take eight times the memory),
  and a codestream refused side by side is decoded again on its own, which
  gives the error where the sequential loop met it. Speedway.mj2 (200
  frames of 15 KB, 3.0 MB), `-th 8`, best of 3: 17.55 -> 2.32 s
  compressing, 8.49 -> 1.07 s extracting.
- **No 100 ms naps.** `RunSlices` waited for its threads with FreePascal's
  `TThread.WaitFor`, which from the main thread naps 100 ms at a time
  ("The main thread's waits", above); it joins them through
  `pjathread.TJoinThread` now.
- **The command's threads by the files' sizes** (`pjacli`). `-th N` went
  to files first and what was left to each file's bands: N divided by the
  files at once, one each as soon as there are more files than threads.
  On gap1 at `-th 8` that left its 46 MB Sentinel-2 band (a third of the
  set's bytes) on one thread at the end, its slices one after the other:
  the set took as long as that one file. The N threads are tokens now: a
  worker holds one while it runs a file, and a file takes, of those free
  when it starts, as many as its share of the bytes not yet started is of
  N (the largest go first, and the last ones take what the others left).
  With one worker a file takes every thread, as before. JPEG files gain
  the same way (their bands).
- **Slices of 1 MiB.** Below.

**Instructions** (callgrind, one thread, `a` with its check and `x`;
0.9.5 -> this):

| codestream | `a` | `x` |
|---|---|---|
| book page, 324 KB, mode 1 | 15.74 G -> 12.11 G (-23%) | 7.51 G -> 5.72 G (-24%) |
| bitonal page, 299 KB, mode 2 | 34.74 G -> 29.73 G (-14%) | 16.05 G -> 13.62 G (-15%) |
| DICOM MR, 587 KB, lossless (both modes coded, mode 2 kept) | 30.26 G -> 20.84 G (-31%) | 9.15 G -> 7.00 G (-23%) |
| Motion JPEG 2000 frame, 15 KB, mode 1 | 0.77 G -> 0.60 G (-22%) | 0.37 G -> 0.28 G (-23%) |

**Slices.** The slicing of mode 1 (and of mode 2's side information and
rebuild) is the encoder's choice, written in the stream, which every
release from 0.9.5 reads: one slice a `J2K_SLICE_BYTES` of codestream,
at most one a tile and 64. A slice is coded and decoded on a thread of its
own; with 4 MiB, a tiled codestream of 13.6 MB had 3 slices for 8 threads,
one of 2.5 MB and 25 tiles a single one. A codestream of one tile is one
slice whatever the size: the slice table counts tiles, so a single-tile
codestream (a book page, a DICOM) cannot be cut without a new layout; its
parallelism is the two modes side by side. What smaller slices cost, on
the 13 codestreams of the two sets with several tiles and 500 KB or more
(each slice starts a model that knows nothing; savings of the whole set,
`pja a` as the command writes it):

| slice | gap1 (113, 150.1 MB) | rebuild files (30, 26.1 MB) | worst codestream |
|---|---|---|---|
| 4 MiB (0.9.5) | 8.463% | 11.747% | |
| 2 MiB | 8.446% | 11.733% | +0.08 points |
| **1 MiB** | **8.422%** | **11.706%** | +0.19 points |
| 512 KiB | 8.395% | 11.673% | +0.35 points |
| 256 KiB | 8.367% | 11.655% | +0.51 points |

The worst is the same codestream every time: a Library of Congress map
of 8.6 MB, 3 components and 56 tiles (2 slices at 4 MiB, 8 at 1 MiB, 32
at 256 KiB). The Sentinel-2 bands lose 0.02 points at 1 MiB (46 MB: 10
-> 43 slices), the 3-component maps 0.1 to 0.2 points (their tiles of
1024 x 1024 x 3 hold about 140 KB each, and a model needs a few of them to
learn). 1 MiB keeps the sets within 0.05 points of 0.9.5 and gives a tiled
codestream of a few MB its threads: the 13.6 MB map of 96 tiles alone at
`-th 8`, best of 2, 31.31 s compressing and 14.85 s extracting with 4 MiB
slices (3), 11.55 s and 5.55 s with 1 MiB (13). 512 KiB would cost 0.07
points for little more on these sets. At one thread the slicing costs
nothing measurable (five rebuild files, `-th 1`: the same time with 1 and
4 MiB, within 0.5%).

**Speed** (wall time, this machine, a shared Xeon E5-2697A v4 under a load
of 10 to 40 from other work: `-th 8` on cores 0-7, `-th 1` on core 10;
0.9.5 (A) and this (B) alternated, the first side swapped each round,
best of 3; `pja a` of the whole list then `pja x` of what it wrote; every
`.pja` compared (the same, but the tiled codestreams of 2 MiB or more,
sliced by 1 MiB), every file back byte for byte). B is this branch; the
`-th 1` sets ran before its last three commits (the samples' cap, the
bitonal model's SSE4.1 copy, the command's threads: the first and the
last change nothing for one codestream on one thread, the second takes
about 5% off a bitonal page's extraction), as did B' below:

| set | `-th` | compress A -> B | extract A -> B |
|---|---|---|---|
| gap1, 113 codestreams, 150.1 MB | 8 | 302.95 -> 135.72 s (-55%) | 83.00 -> 51.08 s (-38%) |
| the same, without the command's threads by size | 8 | 302.95 -> 235.10 s (-22%) | 83.00 -> 73.88 s (-11%) |
| gap1 up to 4.2 MB, 108 codestreams, 40.3 MB | 1 | 316.99 -> 267.71 s (-16%) | 132.30 -> 116.34 s (-12%) |
| rebuild files, 30, 26.1 MB | 8 | 41.00 -> 28.30 s (-31%) | 19.63 -> 13.92 s (-29%) |
| rebuild files | 1 | 191.06 -> 177.15 s (-7%) | 81.35 -> 69.74 s (-14%) |
| Speedway.mj2, 200 frames, 3.0 MB | 8 | 17.55 -> 2.32 s (-87%) | 8.49 -> 1.07 s (-87%) |
| a DICOM, 4.3 MB lossless, one tile (both modes coded) | 8 | 21.84 -> 12.91 s (-41%) | 6.63 -> 5.99 s (-10%) |
| the same | 1 | 22.03 -> 17.92 s (-19%) | 6.58 -> 6.01 s (-9%) |

All runs, compress / extract in seconds (A, B, and B without the
command's threads, B'):
- gap1 `-th 8`: A 320.94/87.52, 308.57/83.00, 302.95/83.66; B
  136.79/51.80, 135.89/51.08, 135.72/51.12; B' 239.43/74.15,
  235.10/74.49, 235.76/73.88. An earlier series (load 10 to 25): A
  322.02/91.14, 320.59/89.80, 326.17/90.41; B' 242.38/75.86,
  268.63/84.47, 257.73/79.48.
- gap1 up to 4.2 MB `-th 1`: A 398.90/162.29, 316.99/144.32,
  327.38/132.30; B 268.21/165.17, 277.35/116.34, 267.71/116.40.
- rebuild files `-th 8`: A 41.60/19.63, 41.00/19.98, 41.34/19.82; B
  28.38/13.92, 28.30/13.97, 28.30/13.97. Earlier, B': A 69.37/21.78,
  44.15/21.27, 52.47/21.39; B' 43.58/21.49, 46.50/19.87, 38.21/18.13.
- rebuild files `-th 1`: A 254.05/84.37, 191.06/81.80, 191.81/81.35; B
  215.99/123.41, 208.53/70.56, 177.15/69.74 (the 123.41: another job on
  the core's sibling; extracting file by file, one at a time on another
  core, B was faster on 25 of the 30 and within 2% on the other 5).
- Speedway.mj2 `-th 8`: A 17.55/8.62, 17.86/8.49, 17.69/8.58; B
  2.36/1.08, 2.32/1.07, 2.34/1.09.
- the DICOM `-th 8`: A 22.52/7.99, 21.84/6.63, 22.23/7.52; B
  12.91/5.99, 13.06/6.16, 13.27/6.12; `-th 1`: A 22.82/6.58,
  22.03/6.60, 22.17/6.80; B 18.01/6.11, 17.92/6.01.

One thread, by kind, through the SIMD paths (`--cpu`, extracting,
best of 3): the book page 1,002 ms in 0.9.5, 1,006 plain, 880 SSE4.1,
873 AVX2; the bitonal page 1,985, 1,906, 1,841, and 1,884 on the AVX2
path (its SSE4.1 copy, 1,975 with the AVX2 one); the DICOM MR (lossless,
mode 2) 1,226, 1,208, 1,050, 1,037.
So in time the SIMD copies give 10 to 15%, the rest of the instructions
taken out a few percent: the model waits more than it computes.

**Dead ends and what was left.**
- The bitonal mixer's 14 inputs padded to 16 lanes (two whole AVX2
  vectors, the extra weights at 0 adding 0): 0.4% more instructions.
- Cutting the model's per-event latency would need a different model (or
  a pipeline): the decoder cannot look ahead, each event's contexts wait
  on the bit before. The encoder knows every bit, so its counters and its
  mixers could run on two threads, but the check's decoding would stay as
  it is.
- Checking a mode 1 stream while it is written (a decoder following the
  encoder on another thread, as JPEG's live check does): the side
  information is complete only at the end of the analysis, and the
  decisions the rebuild needs would have to be kept (about 10 bytes a
  byte of codestream) or decoded again; not done.
- `pja info --estimate` still codes and checks both modes, one after the
  other.
- Mode 2's pixel models run on one thread (one arithmetic stream for all
  the planes).

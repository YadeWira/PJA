# The PJA codec

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


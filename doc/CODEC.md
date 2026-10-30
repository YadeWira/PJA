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

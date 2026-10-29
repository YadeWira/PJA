# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal with
some x86-64 assembly, and nothing else: no C, no C++, no libraries.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pja a photo.jpg          # -> photo.pja, about 25% smaller
pja x photo.pja          # -> photo.jpg, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pja`.

Against packJPG 5.0g, measured on 23/10/2026, the files both take (each
verifying its output):

| | files | packJPG takes | PJA takes | packJPG | PJA | |
|---|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 151 | 151 | 76.62% | **74.96%** | -2.16% |
| corpus of JPEGs of every kind | 78 | 65 | 75 | 76.83% | **71.76%** | -6.59% |
| MPO (stereo pairs) | 6 | 6 | 6 | 86.54% | **74.13%** | -14.34% |
| arithmetic-coded JPEG | 244 | 244 | 244 | 78.52% | **76.50%** | -2.58% |
| generated JPEGs | 640 | 640 | 640 | 77.48% | **75.61%** | -2.42% |
| 12-bit JPEG | 10 | 0 | 10 | — | | |
| lossless JPEG | 36 | 0 | 36 | — | | |
| JPEG-LS photos (19/10) | 16 | — | 16 | — | 84.4% | |

And how fast, on the 151 photos with one thread and without verifying
(packJPG's default), back to back on a machine with other work running:

| | packJPG 5.0g | PJA `--fast` | PJA (full model) |
|---|---|---|---|
| compressed | 60,084,653 | **59,776,460** (-0.51%) | **58,788,017** (-2.16%) |
| compress | **38.3 s** | 42.5 s | 71.4 s |
| decompress | 39.6 s | **36.4 s** (-8%) | 64.6 s |

`--fast` is smaller than packJPG and decompresses faster; it compresses
about 10% slower since the predictions went to 32 bits (stream version 5,
for the ZPAQL decoder) and since it looks for JPEGs inside each JPEG. The
full model is 2% smaller still, at 1.8 times the time. PJA uses the
processors packJPG does not: with 8 threads, `--fast` compresses the 151
photos verifying in 10.0 s and decompresses them in 4.7 s, the full model
in 17.9 s and 8.2 s.

What it handles: baseline, extended and progressive JPEG with Huffman or
arithmetic coding, 8 and 12 bits, any subsampling, restart markers, and the
oddities real encoders leave (extra restart markers, EOB runs cut by the
table, data after the end, a DRI with no restart markers); the JPEGs inside a JPEG (thumbnails, the
further images of an MPO, Ultra HDR gain maps), each compressed as a JPEG
of its own; lossless JPEG (SOF3) from 2 to 16 bits, every predictor, point
transforms and restarts; the height given by a DNL segment; JPEG-LS from
2 to 16 bits, lossless and near-lossless, every interleave mode, and
subsampled components (no interleave, or line interleave without
restarts). Anything else that starts like a JPEG
goes through the raw bytes' model, and `a` says why (`as bytes: ...`). As
JPEGs it does not take: hierarchical JPEG, lossless
JPEG with arithmetic coding (SOF11) or subsampled components, and JPEG-LS
with a point transform or with subsampled components in sample
interleave.

## Platforms

| OS | Architectures | State |
|---|---|---|
| Linux | x86-64 | built and tested in CI, the two full suites included; developed here |
| Linux | AArch64 | built and tested in CI; streams byte-identical to x86-64 |
| Linux | x86 (32-bit) | built and tested in CI; streams byte-identical to x86-64 |
| macOS | arm64 (Apple silicon) | built and tested in CI; streams byte-identical to x86-64 |
| Windows (7 and later) | x86-64 | built and tested in CI; also validated in Windows 10 and Windows 7 VMs |
| Windows (XP and later) | x86 | built and tested in CI; also validated in Windows 10, Windows 7 and Windows XP SP3 VMs |

On every platform CI builds the command and the zpaq-std plugin, takes
every sample of the repository through `pja a` and `pja x`, and compares
the SHA-256 of the codec's streams across all six (`.github/test.sh`): a
`.pja` made on one decodes on any other. The x86-64 builds use PJA's
assembly routines, the others their Pascal versions, which the suite holds
to the same streams.

Every [release][relLink] carries, for each of the six, the command
(`pja-VERSION-PLATFORM`) and the plugin (`pja-VERSION-zpaqstd-plugin-PLATFORM`),
built and checked by CI on that platform (`.github/workflows/release.yml`),
with `SHA256SUMS`. The Linux builds need glibc 2.34 or later. The macOS
ones are not signed: after unpacking, `xattr -d com.apple.quarantine pja`
lets Gatekeeper run it.

## Building

FreePascal 3.2:

```sh
cd pas
fpc -O3 -dPJA_FAST pjacli.pas -opja       # the command
cd .. && ./run_tests.sh                    # every test
```

`-dPJA_FAST` turns off range and overflow checks in the models and the
encoders, where they cost 2.3x. The checked build is the reference: the codec
suite compresses the same files with both, with and without assembly and with
several threads, and demands identical streams. The JPEG and JPEG-LS
decoders stay checked in every build.

**Windows (64 and 32 bits)**: cross-compiled from Linux, `x86_64-win64`
with the units FreePascal ships (`fpc -Twin64 -Px86_64`), `i386-win32` with
a cross compiler built from FreePascal's sources (the 32-bit build has no
assembly: the Pascal path, which the suite holds to the same streams).
`pas/tests/windows_pkg.sh DIR` builds `pja.exe`, a checked `pja_ref.exe`
(and, with `PPC386` and `RTL386` set, `pja32.exe` and `pja32_ref.exe`), the
samples and the `.pja` files Linux makes of them; `windows.ps1`, run on
Windows, demands the very same `.pja` files (full and fast model, with and
without assembly, 1 to 4 threads), every original back from the Linux ones,
the CLI's refusals, and names outside the ANSI code page. Checked on
Windows 10 on 21/10/2026, 64-bit and 32-bit builds: 24 cells each, 0
failures. The arguments are read in UTF-16 there and the program runs in
UTF-8: through the ANSI code page a name like `写真.jpg` could not be opened
at all. The 32-bit build's speed is not measured yet.

**As a library: the zpaq-std plugin.** `pas/plugin/pja_zpaqstd.pas` is PJA
as a codec for [zpaq-std](https://github.com/YadeWira/zpaq-std)'s `-sat`
(codecs for specific formats), on its plugin ABI 1: `pas/plugin/build.sh
DIR` builds `pja.so`, `pja.dll` and, with `PPC386` and `RTL386`, the 32-bit
`pja.dll`, to go in zpaq-std's `codecs/` folder. The file holds five
codecs, tried in this order: `pjax` for the JPEGs that need stream
version 6 (12 bits; a DNL; a DRI with no restarts; 256 KiB or more of
JPEGs after the EOI, as an MPO or an Ultra HDR file has them), `pja` for
every other JPEG, EXIF thumbnails included, `pjall` for lossless JPEG,
`pjals` for JPEG-LS, and `pjalsx` for JPEG-LS with subsampled components. Each detects its files by their bytes and leaves
verification to zpaq-std, which decodes every block before writing it.
Every block also carries the codec's decoder in ZPAQL, so that any zpaq
reads the archive without the plugin, and several files may share a
block. The decoders are compiled from `pas/plugin/zpaql/` with
`tools/zpaql/`: `pja`'s (62,294 bytes of ZPAQL) covers every JPEG PJA
handles, Huffman or arithmetic, sequential or progressive; `pjals`'s
(55,989 bytes) every JPEG-LS file, with either of its two models; `pjax`'s
(57,709 bytes) the Huffman JPEGs of version 6; `pjall`'s (30,508 bytes)
lossless JPEG, 2 to 16 bits, through JPEG-LS's samples model; `pjalsx`'s
(60,776 bytes) JPEG-LS whose components are of other sizes than the
frame. `pja` and `pjals` are frozen as v0.0.1 left them, `pjax` as v0.0.3
did, `pjall` as v0.0.5 did.
Its memory is sized for each block: the plugin tells zpaq-std how much
the decoder will need for that file (2 MB for a small one, 16 MB for a
photo of 200 KB, at most 256 MB).
Checked with zpaq-std's test build on Linux and on Windows 10 (64 and 32
bits): every block decoded by the ZPAQL as by the plugin, and every file
back without the plugin, plain zpaq 7.15 included (doc/CODEC.md has the
sets).

## Layout

| | |
|---|---|
| `pas/pjajpeg.pas` | JPEG ↔ DCT coefficients, plus what is needed to rebuild the exact bits |
| `pas/pjajls.pas` | JPEG-LS ↔ samples, the same way |
| `pas/pjaarith.pas` | the binary arithmetic coder |
| `pas/pjamodel.pas` | the context models (SSE4.1 assembly for the mixer, chosen at run time) |
| `pas/pjacodec.pas` | the compressed stream, verified when compressing; bands in threads |
| `pas/pjablake3.pas` | BLAKE3, checked against the official implementation |
| `pas/pjaformat.pas`, `pas/pjalimits.pas` | the `.pja` file: header, size, hash |
| `pas/pjapack.pas` | codec and format together, in the order that makes it safe |
| `pas/pjafs.pas` | writing the output: no links followed, no half-written files, nothing unverified under its name |
| `pas/pjacli.pas` | the `pja` command |
| `pas/plugin/` | PJA as a zpaq-std codec plugin |
| `pas/plugin/zpaql/` | the plugin's decoder in the language zpaqlc compiles to ZPAQL |
| `tools/zpaql/` | a compiler to ZPAQL, a ZPAQL interpreter and the generator of the plugin's decoder (Python, build time only) |
| `doc/` | `CODEC.md` (how the codec works, what was measured and tried), `FORMAT.md`, `POLICY.md`, `CLI.md` |

## Testing

`./run_tests.sh` runs both suites:

- `pas/run_codec_tests.sh`: each codec layer, round trips, every bit flip and
  truncation of the first bytes of every sample and stream (no exception
  allowed), and the reference, fast, no-assembly and threaded builds giving
  identical streams. `JPEG_CORPUS=dir1:dir2` adds round trips over more files.
- `pas/run_tests.sh`: BLAKE3 against its vectors, the format's every error,
  more than a million damaged `.pja` variants, writing the output (links,
  overwriting, `.corrupt`), and the command (`tests/cli.sh`).

Each test demands its own minimum cell count: one that runs zero cells is not
green. Two source guards stop the build first: `collisions.py`
(identifiers that clash case-insensitively) and `results.py` (functions that
never set `Result`).

## FreePascal rules, all measured and none obvious

The first two are in `pas/pja.inc`.

- **`{$R+}` does not check pointer accesses.** `p[10]` with `p: PByte` reads
  out of range without any error. Validation works only on arrays.
- **With `{$Q+}`, `for i := 0 to n - 1` with unsigned `n` and `n = 0` raises
  `EIntOverflow`.** Lengths and indices are signed, and loops use `High()`.
- **On i386, `Int64` is not ordinal**: it cannot be a `for` variable, and the
  error only shows up when compiling for 32 bits. Counters in `SizeInt`, and
  byte positions in `Int64`.
- **`for s in ['short', 'much_longer']` truncates the literals** to the length
  of the first one, and with numbers it builds a **set** of bytes. Iterate over
  a declared constant array instead.
- **On Unix, `TFileStream.Create(f, fmOpenRead)` takes an exclusive `flock`.**
  A second open of the same file, even in the same process, fails with
  `EAGAIN`. For reading: `fmOpenRead or fmShareDenyNone`.
- **FPC does not warn about an unset `Result` if some path does `Exit(value)`.**
  `pjafs.Parent` returned whatever was left in the register, and it showed up
  as an **intermittent** failure (1 run in ~10). `pas/results.py` stops the build.
- **Pascal is case-insensitive.** A variable `version` shadowed the constant
  `VERSION` and no future version was rejected; a variable `plain` shadowed the
  function `Plain`. The compiler does not warn in either case (the second was
  caught only because the types did not match).
  `pas/collisions.py` stops the build.
- **On 64 bits, FPC multiplies two `Cardinal`s in 64 bits.** A hash meant to
  wrap at 32 bits kept its high bits until the product was wrapped in
  `Cardinal()`.
- **A global written from several threads costs more than it seems.** The
  cost accounting wrote one per coefficient from every band thread; the cache
  line bouncing between cores made each band three times slower.

## License

MIT, see `LICENSE`. The arithmetic-coded JPEG support is based in part on the
work of the Independent JPEG Group; see `NOTICE` for that and other credits.

[ciBadge]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PJA "Latest release"
[relLink]: https://github.com/YadeWira/PJA/releases/latest

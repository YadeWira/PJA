# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal with
some x86-64 assembly, and nothing else: no C, no C++, no libraries.

```sh
pja a photo.jpg          # -> photo.pja, about 25% smaller
pja x photo.pja          # -> photo.jpg, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pja`.

Measured on 19/10/2026 (`doc/CODEC.md`):

| | files | PJA saves | packJPG 5.0f saves |
|---|---|---|---|
| photos (Huffman JPEG) | 151 | **24.97%** | 23.38% |
| arithmetic-coded JPEG | 244 | **23.66%** | 21.48% |
| JPEG-LS photos | 16 | **15.6%** | — (it rebuilds 2 of 9 real JPEG-LS test files; PJA 8) |

And how fast, on the 151 photos with one thread, measured on 22/10/2026
against packJPG's default (which does not verify either, so PJA with
`--no-verify`):

| | packJPG 5.0f | PJA `--fast` | PJA (full model) |
|---|---|---|---|
| compressed | 60,084,653 | **59,827,219** (-0.43%) | **58,848,193** (-2.06%) |
| compress | 38.7 s | **34.6 s** (-9%) | 58.5 s |
| decompress | 34.1 s | **31.7 s** (-10%) | 57.7 s |

`--fast` is smaller and faster than packJPG both ways; the full model is 2%
smaller still, at 1.7 times the time. With several threads the full model
splits each photo into bands.

What it handles: baseline, extended and progressive JPEG with Huffman or
arithmetic coding, 8 bits, any subsampling, restart markers, and the oddities
real encoders leave (extra restart markers, EOB runs cut by the table, data
after the end); JPEG-LS from 2 to 16 bits, lossless and near-lossless, every
interleave mode. What it refuses, with the reason: 12-bit JPEG, lossless
JPEG (SOF3), hierarchical JPEG, and JPEG-LS with subsampled components or a
point transform.

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
`pja.dll`, to go in zpaq-std's `codecs/` folder. It detects JPEG and JPEG-LS
files by their bytes, writes the full-model stream (`pja stream v4 full`),
and leaves verification to zpaq-std, which decodes every block before
writing it. No ZPAQL decoder yet, so only `-sat`. Checked on 21/10/2026 on
Linux and on Windows 10 (64 and 32 bits): 44 files, the same streams on all
three, and every file back, including archives made on another system.

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

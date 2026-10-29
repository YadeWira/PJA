# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal,
with the coefficient model's core in C and some x86-64 assembly; no
libraries.

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

Against [packJPG](https://github.com/YadeWira/packJPG) 5.0g and
[Aqueous](https://github.com/lifthrasiir/aqueous) (`aqr`, commit
`3d37dae`, its default level), measured on 29/10/2026 ([how][wComp]): each set's whole
output against its input, every file decompressed and compared with the
original, a file a tool does not take counted at its own size:

| set | files | size | packJPG | Aqueous | PJA 0.0.8 |
|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 78.4 MB | 76.62% | 80.46% | **74.96%** |
| corpus of JPEGs of every kind | 78 | 33.0 MB | 77.23% (takes 65) | **72.01%** | 72.08% |
| MPO (stereo pairs) | 6 | 41.0 MB | 86.54% | 78.95% | **74.13%** |
| arithmetic-coded JPEG | 244 | 6.7 MB | 78.52% | 85.73% | **76.50%** |
| generated JPEGs | 640 | 18.3 MB | 77.48% | **33.96%**¹ | 75.61% |
| 12-bit JPEG | 10 | 83 KB | does not take them | 92.55% | **88.34%** |
| lossless JPEG | 36 | 390 KB | does not take them | 96.54% | **96.04%** |

¹ Aqueous is an archiver: it codes a set as one archive and its files
against each other, and these 640 are variants of 12 images. packJPG and
PJA code each file on its own. Each Aqueous archive also carries its
decoders, about 42 KB.

And how fast, on the 151 photos, every tool verifying what it writes (two
Xeon E5-2697A v4, 64 threads, with other work running):

| | packJPG 5.0g | Aqueous | PJA `--fast` | PJA (full model) |
|---|---|---|---|---|
| compressed | 60,084,653 | 63,098,952 | 59,776,460 | **58,788,017** |
| compress, 1 thread | 69.6 s | **12.5 s** | 77.4 s | 118.6 s |
| decompress, 1 thread | 34.7 s | **4.4 s** | 31.2 s | 57.3 s |
| compress, 8 threads | — | **2.3 s** | 9.9 s | 17.0 s |
| decompress, 8 threads | — | **0.7 s** | 4.6 s | 8.1 s |

PJA is the smallest on photos, MPOs, arithmetic-coded, 12-bit and lossless
JPEG; Aqueous is many times faster, at 7% larger than PJA on photos (and takes
far more than JPEG); packJPG uses one thread.

It handles baseline, extended and progressive JPEG (Huffman or arithmetic,
8 and 12 bits), the JPEGs inside a JPEG (thumbnails, MPO, Ultra HDR),
lossless JPEG, and JPEG-LS, along with the oddities real encoders leave.
Anything else goes through as bytes, and `pja a` says why
([details][wHandles]).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64), macOS (Apple silicon) or Windows (x64, and x86
from XP on). Each build is tested by CI on its own platform, and a `.pja`
made on one opens on any other ([installing][wInstall], [platforms][wPlat]).

```sh
pja a *.jpg --output-dir=packed   # compress many
pja x packed/*.pja -o restored/   # and back
pja list packed/*.pja             # sizes and hashes
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## More

The [wiki][wiki] has the rest: [benchmarks][wComp], the
[zpaq-std plugin][wPlugin] (PJA as codecs for zpaq archives),
[building and testing][wBuild], [how it works][wHow], the [source
layout][wLayout], [FreePascal pitfalls][wFpc] and the [release
history][wRel]. The codec's full notes are in [doc/CODEC.md](doc/CODEC.md),
the file format in [doc/FORMAT.md](doc/FORMAT.md).

## Building

FreePascal 3.2 and a C compiler (gcc or clang):

```sh
cd pas
./build_c.sh build/c                               # the C part
fpc -O3 -dPJA_FAST -Fobuild/c pjacli.pas -opja     # the command
cd .. && ./run_tests.sh                            # every test
```

## License

MIT, see `LICENSE`. The arithmetic-coded JPEG support is based in part on the
work of the Independent JPEG Group; see `NOTICE` for that and other credits.

[ciBadge]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PJA "Latest release"
[relLink]: https://github.com/YadeWira/PJA/releases/latest
[wiki]: https://github.com/YadeWira/PJA/wiki
[wComp]: https://github.com/YadeWira/PJA/wiki/Benchmarks
[wHandles]: https://github.com/YadeWira/PJA/wiki/What-PJA-handles
[wInstall]: https://github.com/YadeWira/PJA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PJA/wiki/Platforms
[wPlugin]: https://github.com/YadeWira/PJA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PJA/wiki/Building
[wHow]: https://github.com/YadeWira/PJA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PJA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PJA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PJA/wiki/Releases

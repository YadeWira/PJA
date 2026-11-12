# PJA

**packJPG Algorithm**: lossless recompression of **JPEG**, **JPEG-LS** and **JPEG 2000** files, in FreePascal,
with the coefficient model's core in C and some x86-64 assembly; no
libraries. The successor of [packJPG](https://github.com/YadeWira/packJPG):
a new codec and format of its own (it does not read `.pjg` files), smaller
and verified before anything is written.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pja a photo.jpg          # -> photo.pja, about 27% smaller
pja x photo.pja          # -> photo.jpg, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pja`.

The formats are stable since 0.9.0: a `.pja`, a 7-Zip archive with PJA or
a zpaq-std block written today opens in every later release
([doc/STABILITY.md](doc/STABILITY.md)).

PJA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [POA](https://github.com/YadeWira/POA) | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |
| [PDA](https://github.com/YadeWira/PDA) | documents (PDF, Office, OpenDocument, EPUB, CHM, ...) | (new) |
| **PJA** | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |

## What it handles

- **JPEG**: baseline, extended and progressive, Huffman or arithmetic, 8
  and 12 bits, lossless JPEG, the JPEGs inside a JPEG (thumbnails, MPO,
  Ultra HDR), and the oddities real encoders leave.
- **JPEG-LS**: 2 to 16 bits, lossless and near-lossless.
- **JPEG 2000** (since 0.9.5): JP2, JPX, JPM, Motion JPEG 2000 and raw
  codestreams, HTJ2K since 0.9.6; each codestream rebuilt byte for byte.

Anything else goes through as bytes, and `pja a` says why
([details][wHandles]).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64; glibc 2.34 or later: Debian 12, Ubuntu 22.04,
RHEL 9 and newer), macOS (Apple silicon) or Windows (x64, and x86 from XP
on). Each build is tested by CI on its own platform, and a `.pja`
made on one opens on any other ([installing][wInstall], [platforms][wPlat]).

```sh
pja a *.jpg --output-dir=packed   # compress many
pja x packed/*.pja -o restored/   # and back
pja list packed/*.pja             # sizes and hashes
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## Against other compressors

One file at a time, against the other recompressors that give a JPEG back
byte for byte: [packJPG](https://github.com/YadeWira/packJPG) 5.0g, JPEG
XL's lossless transcoding (0.11.2), Lepton and brunsli. Each set's whole
output against its input; a file a tool does not take counts at its own
size ([how, and the details][wComp]).

| set | files | size | packJPG 5.0g | JPEG XL | Lepton | brunsli | PJA 0.9.6 |
|---|---|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 78.4 MB | 76.62% | 79.80% | 79.42% (takes 136) | 77.98% | **72.60%** |
| corpus of JPEGs of every kind | 78 | 33.0 MB | 77.23% (takes 65) | 86.03% (takes 56) | 85.11% (takes 55) | 75.36% (takes 64) | **70.39%** |
| MPO (stereo pairs) | 6 | 41.0 MB | 86.54% | takes none | 87.65% | 87.71% | **73.38%** |
| arithmetic-coded JPEG | 244 | 6.7 MB | 78.52% | takes none | takes none | takes none | **74.59%** |
| generated JPEGs | 640 | 18.3 MB | 77.48% | 85.35% (takes 528) | 83.95% (takes 511) | 79.69% (takes 604) | **73.72%** |
| 12-bit JPEG, small | 10 | 83 KB | takes none | takes none | takes none | takes none | **88.14%** |
| 12-bit JPEG from camera RAWs | 12 | 27.7 MB | takes none | takes none | takes none | takes none | **84.80%** |
| lossless JPEG | 36 | 390 KB | takes none | takes none | takes none | takes none | **96.04%** |

Speed on the 151 photos (two Xeon E5-2697A v4; "8 at once": `pja -th 8`,
the others 8 processes):

| | packJPG 5.0g | JPEG XL | Lepton | brunsli | PJA 0.9.6 |
|---|---|---|---|---|---|
| compress, 1 thread | 68.1 s | 26.7 s | 40.8 s | **13.3 s** | 68.3 s |
| decompress, 1 thread | 34.9 s | 10.7 s | 15.3 s | **9.0 s** | 37.0 s |
| compress, 8 at once | 10.3 s | 4.1 s | 5.8 s | **1.9 s** | 9.0 s |
| decompress, 8 at once | 5.2 s | 1.5 s | 2.2 s | **1.4 s** | 5.1 s |

PJA is the smallest on every set and the only one that takes every file;
none of the others takes 12-bit or lossless JPEG, and only packJPG takes
arithmetic-coded ones. brunsli, JPEG XL and Lepton are faster, and neither
of the first two verifies what it writes.

### JPEG 2000

No other recompressor takes JPEG 2000. Against general-purpose compressors,
on 113 real JPEG 2000 codestreams (150 MB: Internet Archive, Library of
Congress, OSGeo, Helioviewer, Sentinel-2 and DICOM), every one given back
byte for byte:

| | size | saved |
|---|---|---|
| bzip2 -9 | 100.18% | it grows |
| bzip3 | 100.05% | it grows |
| zip -9 | 99.81% | 0.19% |
| xz -9e | 99.78% | 0.22% |
| 7-Zip -mx=9 (LZMA2) | 99.76% | 0.24% |
| zstd --ultra -22 | 99.72% | 0.28% |
| brotli -q 11 | 99.67% | 0.33% |
| zpaq -m5 | 99.56% | 0.44% (18 min) |
| **PJA 0.9.6** | **91.58%** | **8.42%** |

Scanned 1-bit book pages come out about 70% smaller, other scans 9 to 17%,
satellite and medical images 6 to 7%. HTJ2K (since 0.9.6): 11.2% smaller
on 716 real codestreams, 27% on photos. Slower than JPEG: about 0.1-0.25
MB/s per thread to compress.

## Safe by design

PJA's first rule is that the original comes back byte for byte, or nothing
is written. Measured against the other JPEG recompressors on the same 20
photos and the same damage ([how][wSafe]):

| | PJA | packJPG | Lepton | brunsli | JPEG XL |
|---|---|---|---|---|---|
| 4,000 single-bit flips in the compressed file: a wrong JPEG given back without an error | **0** | 4 | 3,712 | 195 | 361 |
| stores a hash of the original | **yes** (BLAKE3) | no | no | no | no |
| checks its output before writing it, by default | **yes** | no | yes | no | no |
| fuzzed inputs taken that do not come back | **0** | 199 | 0 | 0 | 17 |
| disk full: a truncated file under the output's name | **no** (an old file is kept) | no | yes (and exit 0) | yes | yes |
| writes through a symbolic link at the output's name | **no** | yes | yes | yes | yes |
| killed while writing: a partial file under the output's name | **no** | yes | yes | yes | yes |
| written promise that its files keep opening | **yes** ([STABILITY](doc/STABILITY.md)) | no | archived | no | ISO standard |

It is design, not luck: a stored hash and size, a decode-and-compare before
writing, a temporary that takes the output's name only when it is complete
and on the disk (and is deleted on Ctrl-C), and a clean refusal of anything
it does not understand. What it does not do: repair a damaged `.pja` (keep
backups, or use an archiver with recovery records) or authenticate it (the
hash catches accidents, not tampering).

## Against archivers

One archive per set, 8 threads; every file extracted and compared. Size,
then the time to write / extract. 7-Zip + PJA: 7-Zip 25.01 with PJA
0.9.8's plugin, `-m0=PJA -m1=LZMA2`; zpaq-std + PJA: zpaq-std 2.7.2 with
the plugin it ships (PJA 0.9.8), `-sa -m5`; [Aqueous](https://github.com/lifthrasiir/aqueous)
`-l high`; 7-Zip and zpaq-std `-m5` without PJA for reference. The mixed
folder is 40 of the photos among 57 files of other kinds.

| set | 7-Zip + PJA | zpaq-std + PJA | Aqueous | 7-Zip | zpaq-std |
|---|---|---|---|---|---|
| photos (151) | **72.57%**, 9.6 / 4.7 s | 72.82%, 32.4 / 5.8 s | 80.46%, 2.5 / 0.8 s | 97.04%, 9.8 / 1.2 s | 94.58%, 320 / 316 s |
| corpus (78) | **66.86%**, 6.3 / 3.1 s | 68.36%, 14.4 / 2.8 s | 71.98%, 1.5 / 0.3 s | 82.24%, 2.9 / 0.5 s | 80.07%, 140 / 134 s |
| MPO (6) | **73.39%**, 4.8 / 2.2 s | 73.66%, 17.1 / 4.4 s | 78.94%, 1.3 / 0.4 s | 99.57%, 3.8 / 0.9 s | 95.23%, 196 / 251 s |
| arithmetic-coded (244) | **17.25%**, 1.8 / 0.8 s | 18.10%, 5.6 / 0.9 s | 85.73%, 0.2 / 0.0 s | 74.49%, 0.5 / 0.1 s | 73.13%, 24.8 / 25.4 s |
| generated (640) | **16.40%**, 2.8 / 1.4 s | 16.94%, 6.0 / 1.7 s | 33.97%, 0.7 / 0.3 s | 62.85%, 1.3 / 0.4 s | 62.65%, 80.2 / 74.6 s |
| 12-bit, small (10) | **58.28%**, 0.2 / 0.2 s | 93.16%, 0.6 / 0.3 s | 92.62%, 0.0 / 0.0 s | 90.38%, 0.0 / 0.0 s | 92.42%, 0.4 / 0.3 s |
| 12-bit from RAWs (12) | **84.80%**, 3.7 / 2.1 s | 84.98%, 11.6 / 3.0 s | 100.00%, 0.2 / 0.0 s | 100.00%, 2.2 / 0.1 s | 98.61%, 128 / 128 s |
| lossless JPEG (36) | 27.37%, 0.2 / 0.2 s | **25.08%**, 0.3 / 0.2 s | 96.59%, 0.0 / 0.0 s | 95.64%, 0.1 / 0.0 s | 95.93%, 1.4 / 1.4 s |
| JPEG 2000 (113 codestreams, 150 MB) | 99.82%, 13.0 / 0.7 s | **92.44%**, 130 / 99 s | 100.00%, 1.3 / 0.1 s | 99.82%, 12.3 / 0.5 s | 99.62%, 221 / 222 s |
| mixed (97, 38 MB) | 64.83%, 5.7 / 2.1 s | **63.22%**, 41.1 / 41.8 s | 69.98%, 1.9 / 0.4 s | 76.31%, 4.1 / 0.7 s | 73.54%, 155 / 146 s |

7-Zip + PJA is the smallest on every JPEG set but the lossless one.
zpaq-std + PJA is 0.2 to 1.5 points behind it on JPEG and slower, but any
zpaq can extract its archives without the plugin; it is the only one here
that takes JPEG 2000, and the smallest on the mixed folder, where `-m5`
packs the files PJA does not take tighter than LZMA2 (at 41 s against
5.7 s). With `-sa -m1` every JPEG and JPEG 2000 set but the small 12-bit one
stays within 0.1 points, and the mixed folder goes to 71.15% in 7.2 /
1.9 s. On 10 small 12-bit files the ZPAQL
decoder each block carries costs more than PJA saves, so zpaq-std stores
them its usual way. Both methods, and why each number is what it is:
[the benchmarks page][wComp].

## In 7-Zip and zpaq-std

**7-Zip** and [7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd): put
`libpja`'s `pja.dll` (or `pja.so`; in each release, x64 for 64-bit 7-Zip,
x86 for 32-bit) in the `Codecs` folder next to 7-Zip, and

```sh
7z a -m0=PJA -m1=LZMA2 photos.7z photos/      # 7-Zip-zstd: -m1=zstd
```

(in 7-Zip's window: **Parameters** `0=PJA 1=LZMA2`). PJA goes first in the
chain as a filter: it recompresses the JPEG and JPEG-LS files of the solid
block, keeps once what repeats between them, and passes every other byte
on. Extracting needs the plugin too; JPEG 2000 files go through as they
are, for now ([details][wLib]).

**[zpaq-std](https://github.com/YadeWira/zpaq-std)** ships PJA as codecs
and uses them with `-sa`, JPEG 2000 included:

```sh
zpaq-std a photos.zpaq photos/ -sa
```

Each block carries a ZPAQL decoder, so any zpaq extracts it, even without
the plugin ([details][wPlugin]).

## Reporting a bug

```sh
pja report photo.jpg -o report.txt   # what happened, on which machine
```

It writes a plain-text report (PJA's build, the system, the command line,
and the file's size, hash and structure, but no pixels, no metadata
contents and no folder names) and prints a link that opens a [new
issue][issues] with it filled in. `--with-file` puts a copy of the file
beside it, to attach if you choose to ([details][wBugs],
[doc/CLI.md](doc/CLI.md#checking-and-reporting)).

## More

The [wiki][wiki] has the rest: [benchmarks][wComp], the
[zpaq-std plugin][wPlugin] (PJA as codecs for zpaq archives), [the library
and 7-Zip plugin][wLib],
[building and testing][wBuild], [how it works][wHow], the [source
layout][wLayout], [FreePascal pitfalls][wFpc] and the [release
history][wRel]. The codec's full notes are in [doc/CODEC.md](doc/CODEC.md),
the file format in [doc/FORMAT.md](doc/FORMAT.md), what does not change in
[doc/STABILITY.md](doc/STABILITY.md).

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
[wSafe]: https://github.com/YadeWira/PJA/wiki/Safety-and-robustness
[wHandles]: https://github.com/YadeWira/PJA/wiki/What-PJA-handles
[wInstall]: https://github.com/YadeWira/PJA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PJA/wiki/Platforms
[wLib]: https://github.com/YadeWira/PJA/wiki/Library-and-7-Zip
[wPlugin]: https://github.com/YadeWira/PJA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PJA/wiki/Building
[wHow]: https://github.com/YadeWira/PJA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PJA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PJA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PJA/wiki/Releases
[wBugs]: https://github.com/YadeWira/PJA/wiki/Reporting-bugs
[issues]: https://github.com/YadeWira/PJA/issues

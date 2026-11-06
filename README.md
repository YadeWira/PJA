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
| **PJA** | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |

## Against other compressors

One file at a time: [packJPG](https://github.com/YadeWira/packJPG) 5.0g and
JPEG XL's lossless transcoding of a JPEG (`cjxl`/`djxl` 0.11.2), which both
give the JPEG back byte for byte too, against `pja` 0.6.2. Measured on
05/11/2026 ([how][wComp]): each set's whole output against its input, every
file decompressed and compared with the original; a file a tool does not
take, or that does not come back the same, counts at its own size.

| set | files | size | packJPG 5.0g | JPEG XL | Lepton | brunsli | PJA 0.7.0 |
|---|---|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 78.4 MB | 76.62% | 79.80% | 79.42% (takes 136) | 77.98% | **72.60%** |
| corpus of JPEGs of every kind | 78 | 33.0 MB | 77.23% (takes 65) | 86.03% (takes 56) | 85.11% (takes 55) | 75.36% (takes 64) | **70.39%** |
| MPO (stereo pairs) | 6 | 41.0 MB | 86.54% | takes none | 87.65% | 87.71% | **73.38%** |
| arithmetic-coded JPEG | 244 | 6.7 MB | 78.52% | takes none | takes none | takes none | **74.59%** |
| generated JPEGs | 640 | 18.3 MB | 77.48% | 85.35% (takes 528) | 83.95% (takes 511) | 79.69% (takes 604) | **73.72%** |
| 12-bit JPEG, small | 10 | 83 KB | takes none | takes none | takes none | takes none | **88.14%** |
| 12-bit JPEG from camera RAWs | 12 | 27.7 MB | takes none | takes none | takes none | takes none | **84.80%** |
| lossless JPEG | 36 | 390 KB | takes none | takes none | takes none | takes none | **96.04%** |

And how fast, on the 151 photos (two Xeon E5-2697A v4, 64 threads, with
other work running). "8 at once": `pja -th 8`; the others, 8 processes of
one file each, best of three runs for one thread. PJA, packJPG and Lepton
verify what they write; `cjxl` and `cbrunsli` do not. Lepton (Dropbox,
commit `f34c7f4`, `-singlethread -allowprogressive`) and brunsli (Google,
commit `c18b962`) were built from their repositories.

| | packJPG 5.0g | JPEG XL | Lepton | brunsli | PJA 0.7.0 |
|---|---|---|---|---|---|
| compress, 1 thread | 72.2 s | 27.0 s | 40.8 s | **13.3 s** | 66.2 s |
| decompress, 1 thread | 37.3 s | 10.9 s | 15.3 s | **9.0 s** | 32.5 s |
| compress, 8 at once | 10.3 s | 4.2 s | 5.8 s | **1.9 s** | 9.4 s |
| decompress, 8 at once | 5.3 s | 1.5 s | 2.2 s | **1.4 s** | 4.7 s |

PJA is the smallest on every set and the only one that takes every file.
On photos it is 5.5% smaller than packJPG and 9 to 15% faster; 7.4% smaller
than brunsli, the fastest (3.4 to 5 times PJA's speed); 9.4% smaller than
Lepton (1.6 to 2.1 times as fast, and it leaves 15 of the 151 photos as
they are); 9.9% smaller than JPEG XL (2.2 to 3.1 times as fast). None of
the four takes 12-bit or lossless JPEG, and only packJPG takes
arithmetic-coded ones.

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
| **PJA 0.9.5** | **91.53%** | **8.47%** |

By kind: scanned 1-bit book pages about 70% smaller (the pixels through a
bitonal model, better than JBIG1); book and map scans 9 to 17%; solar,
Sentinel-2 and medical images 6 to 7%. It is slower than on JPEG (about
0.1-0.25 MB/s per thread to compress).

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

One archive per set, 8 threads, on 05/11/2026; every file extracted and
compared, and every one came back. Times are to write the archive / to
extract it.

- **7-Zip + PJA**: 7-Zip 25.01 with PJA 0.7.0's plugin, `7z a -mmt=8
  -m0=PJA -m1=LZMA2` ([below](#in-7-zip-and-7-zip-zstd)).
- **zpaq-std + PJA**: [zpaq-std](https://github.com/YadeWira/zpaq-std)
  2.3.0 with the PJA 0.6.4 plugin it ships, `zpaq-std a set.zpaq FILES
  -sa -t8` (stream version 7, the command's model); it keeps the files a
  codec takes in one block, and its z codecs put the PJA streams of a
  block's files through an LZ77 that reaches back into the files before.
- **Aqueous**: [Aqueous](https://github.com/lifthrasiir/aqueous) (`aqr`,
  commit `30f9a4e`), `aqr -c -T 8 -l high`.
- For reference, 7-Zip (`7z a -mmt=8`, LZMA2) and zpaq-std (`-t8`, its
  default method) without PJA.

| set | 7-Zip + PJA | zpaq-std + PJA | Aqueous | 7-Zip | zpaq-std |
|---|---|---|---|---|---|
| photos (151) | **72.57%**, 9.6 / 4.7 s | 72.88%, 16.0 / 5.4 s | 80.46%, 2.8 / 0.7 s | 97.04%, 6.8 / 1.0 s | 97.84%, 0.6 / 0.4 s |
| corpus (78) | **66.86%**, 8.0 / 3.5 s | 68.41%, 16.3 / 3.0 s | 71.98%, 1.5 / 0.3 s | 82.24%, 2.8 / 0.4 s | 85.28%, 0.4 / 0.3 s |
| MPO (6) | **73.39%**, 4.6 / 2.2 s | 73.76%, 13.9 / 4.0 s | 78.94%, 1.3 / 0.4 s | 99.57%, 3.7 / 0.9 s | 100.04%, 0.3 / 0.2 s |
| arithmetic-coded (244) | **17.25%**, 1.7 / 0.8 s | 18.14%, 5.0 / 0.9 s | 85.73%, 0.2 / 0.0 s | 74.49%, 0.5 / 0.1 s | 75.43%, 0.1 / 0.1 s |
| generated (640) | **16.40%**, 2.8 / 1.4 s | 16.96%, 5.8 / 1.6 s | 33.98%, 0.7 / 0.3 s | 62.85%, 1.2 / 0.4 s | 67.22%, 0.4 / 0.3 s |
| 12-bit, small (10) | **58.28%**, 0.2 / 0.2 s | 95.81%, 0.3 / 0.0 s | 92.63%, 0.0 / 0.0 s | 90.38%, 0.0 / 0.0 s | 95.55%, 0.0 / 0.0 s |
| 12-bit from RAWs (12) | **84.80%**, 3.7 / 2.1 s | 84.99%, 11.7 / 3.1 s | 100.00%, 0.2 / 0.0 s | 100.00%, 2.4 / 0.1 s | 100.07%, 0.3 / 0.2 s |
| lossless JPEG (36) | 27.37%, 0.2 / 0.2 s | **25.98%**, 0.4 / 0.2 s | 96.63%, 0.0 / 0.0 s | 95.64%, 0.0 / 0.0 s | 97.82%, 0.0 / 0.0 s |

7-Zip + PJA is smaller than Aqueous on every set, and the smallest of all
on every set but the lossless one; zpaq-std + PJA is smaller than Aqueous
on all but the small 12-bit one. That set is 10 small files (8 made with
cjpeg, 2 from the sample corpus), 83 KB in all: each zpaq-std block
carries pjax7's ZPAQL decoder (35 KB), more than PJA saves on so few
bytes, so zpaq-std rightly stores them its usual way (and two are
arithmetic-coded 12-bit, which no plugin codec takes). 12-bit files of
real size pay the decoder back: on 12 made from camera RAWs (NEF and DNG
from the sample corpus, developed to 16 bits, about 2 to 5 megapixels,
cjpeg 3.0.4 `-precision 12 -quality 90`, baseline, optimized and
progressive), 350 KB to 4 MB each, zpaq-std + PJA is 0.19 points behind
7-Zip + PJA, and nothing else takes them. On the arithmetic-coded and
generated sets,
whose files are variants of a few images, both keep each image about
once: 16 to 18% of the input, where Aqueous writes 34 to 86%. zpaq-std +
PJA writes stream version 7, as the command does, and since 2.3.0 keeps a
codec's files in one block: it is 0.3 to 1.6 points behind 7-Zip + PJA,
1.7 to 3 times slower to write and up to 1.8 times slower to extract; what it spends
buys an archive any zpaq can extract without the plugin, through the
ZPAQL decoder each block carries. Aqueous is 3 to 25 times faster than
either to write.

## In 7-Zip and 7-Zip-zstd

`libpja` (in each release) is a C library and, in the same file, a codec
for [7-Zip](https://7-zip.org) and
[7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd): put `pja.dll` (or
`pja.so`) in the `Codecs` folder next to 7-Zip (the x64 build for 64-bit
7-Zip, the x86 one for 32-bit), and

```sh
7z a -m0=PJA -m1=LZMA2 photos.7z photos/      # 7-Zip-zstd: -m1=zstd
```

In 7-Zip's window (Add to archive, 7z format), the same goes in
**Parameters**: `0=PJA 1=LZMA2` (7-Zip-zstd: `0=PJA 1=zstd`). `0=PJA`
alone also works, but then nothing follows PJA in the chain and every
byte that is not a JPEG (other files, EXIF) goes into the archive as it is.
Extracting needs nothing but the plugin.

PJA goes first in the chain as a filter: it recompresses the JPEG and
JPEG-LS files it finds in the solid block and passes every other byte on
to LZMA2 or zstd, which match what PJA leaves (EXIF, other files); its
own data goes into the archive by a second stream, with what repeats
between files taken out (one image saved several times, progressive or
not, with or without restarts, gives the same coefficients). Extracting
needs the plugin too ([doc/LIBRARY.md](doc/LIBRARY.md)); its sizes and
times are in [the table above](#against-archivers).

Since 0.5.0 the filter also takes the JPEGs that FlashPix, Picture It's
and PhotoDraw's `.mix` and TIFF keep as tiles without their tables: 34
such files of the sample corpus in one archive, 71.92% with 0.4.0 (no
better than plain LZMA2), 59.55% now ([doc/LIBRARY.md](doc/LIBRARY.md)).
Since 0.5.2 it gives the standard tables to those whose container keeps
none (Konica's Q-Photo files: 27% smaller in an archive of their own),
and the command and the filter repair a scan that ends early, a download
cut short included (a photo cut at 99%: 85.9% as bytes, 61.1% now).

It handles baseline, extended and progressive JPEG (Huffman or arithmetic,
8 and 12 bits), the JPEGs inside a JPEG (thumbnails, MPO, Ultra HDR),
lossless JPEG, and JPEG-LS, along with the oddities real encoders leave.
Anything else goes through as bytes, and `pja a` says why
([details][wHandles]).

**JPEG 2000** (JP2, JPX, JPM, Motion JPEG 2000, JPH and raw codestreams:
`.jp2`, `.j2k`, `.j2c`, `.jpx`, `.mj2`...) is recompressed too since 0.9.5:
each Part 1 codestream is taken apart, its code-blocks' decisions coded
again with a context-mixing model, and put back together byte for byte,
checked before anything is written. A lossless codestream may instead be
kept as its pixels, through a pixel model, when that is smaller: bitonal
(1-bit) book pages come out **more than two thirds smaller** (70.6% on the
Internet Archive's). On 113 real-world codestreams (book
pages, maps, solar and satellite images, DICOM; 150 MB) the codestreams come out
**8.5% smaller**, 17% on the book pages; on 30 files from seven encoders,
11.8%. It is slower than for JPEG (about 0.1 to 0.25 MB/s to compress and
0.2 to 0.5 MB/s to extract on one thread; a large tiled codestream uses
several). HTJ2K and Part 2 codestreams are kept as bytes. The 7-Zip
plugin and the zpaq-std codecs leave JPEG 2000 files as they are, for now
([details](doc/CODEC.md)).

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

## Reporting a bug

```sh
pja report photo.jpg -o report.txt   # what happened, on which machine
```

It writes a plain-text report and prints a link that opens a [new
issue][issues] with it filled in: add what you ran and what you expected.
The report has PJA's version and build, the system, the processor and its
SIMD path, the command line, and for the file its size, hash, structure
(markers, frame, scans; for JPEG 2000 the boxes, each codestream's SIZ, COD
and tiles, and its mode) and what PJA does with it. It does **not** have the
image (no pixels), the contents of its metadata (EXIF, XMP, ICC, comments,
JPEG 2000's XML and UUID boxes: only their sizes), or folder names. The file itself is attached only if you
choose to: `--with-file` puts a copy beside the report. `pja info FILE`
shows the same structure, `pja selftest` checks the binary on every SIMD
path, and a run that hits a bug says so and exits with 3
([details][wBugs], [doc/CLI.md](doc/CLI.md#checking-and-reporting)).

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

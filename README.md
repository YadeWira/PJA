# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal,
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

## Against other compressors

One file at a time: [packJPG](https://github.com/YadeWira/packJPG) 5.0g and
JPEG XL's lossless transcoding of a JPEG (`cjxl`/`djxl` 0.11.2), which both
give the JPEG back byte for byte too, against `pja` 0.6.2. Measured on
01/11/2026 ([how][wComp]): each set's whole output against its input, every
file decompressed and compared with the original; a file a tool does not
take, or that does not come back the same, counts at its own size.

| set | files | size | packJPG 5.0g | JPEG XL | PJA 0.6.2 |
|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 78.4 MB | 76.62% | 79.80% | **72.60%** |
| corpus of JPEGs of every kind | 78 | 33.0 MB | 77.23% (takes 65) | 86.03% (takes 56) | **70.39%** |
| MPO (stereo pairs) | 6 | 41.0 MB | 86.54% | takes none | **73.38%** |
| arithmetic-coded JPEG | 244 | 6.7 MB | 78.52% | takes none | **74.59%** |
| generated JPEGs | 640 | 18.3 MB | 77.48% | 85.35% (takes 528) | **73.72%** |
| 12-bit JPEG, small | 10 | 83 KB | takes none | takes none | **88.14%** |
| 12-bit JPEG from camera RAWs | 12 | 27.7 MB | takes none | takes none | **84.80%** |
| lossless JPEG | 36 | 390 KB | takes none | takes none | **96.04%** |

And how fast, on the 151 photos (two Xeon E5-2697A v4, 64 threads, with
other work running). "8 at once": `pja -th 8`; the others, 8 processes of
one file each, best of three runs for one thread. PJA and packJPG verify
what they write; `cjxl` does not.

| | packJPG 5.0g | JPEG XL | PJA 0.6.2 |
|---|---|---|---|
| compress, 1 thread | 77.1 s | **28.0 s** | 69.6 s |
| decompress, 1 thread | 39.8 s | **11.1 s** | 34.6 s |
| compress, 8 at once | 10.9 s | **4.5 s** | 9.7 s |
| decompress, 8 at once | 5.6 s | **1.5 s** | 4.7 s |

PJA is the smallest on every set and the only one that takes every file:
5.5% smaller than packJPG on photos and 10 to 19% faster, and 9.9% smaller
than JPEG XL, which is 2.2 to 3.1 times faster but takes no arithmetic,
12-bit or lossless JPEG nor MPO.

## Against archivers

One archive per set, 8 threads, on 01/11/2026; every file extracted and
compared, and every one came back. Times are to write the archive / to
extract it.

- **7-Zip + PJA**: 7-Zip 25.01 with PJA 0.6.2's plugin, `7z a -mmt=8
  -m0=PJA -m1=LZMA2` ([below](#in-7-zip-and-7-zip-zstd)).
- **zpaq-std + PJA**: [zpaq-std](https://github.com/YadeWira/zpaq-std)
  2.1.0 with the PJA 0.6.0 plugin it ships, `zpaq-std a set.zpaq FILES
  -sa -t8` (stream version 7, the command's model); its z codecs put the PJA streams of a block's files through an
  LZ77 that reaches back into the files before.
- **Aqueous**: [Aqueous](https://github.com/lifthrasiir/aqueous) (`aqr`,
  commit `30f9a4e`), `aqr -c -T 8 -l high`.
- For reference, 7-Zip (`7z a -mmt=8`, LZMA2) and zpaq-std (`-t8`, its
  default method) without PJA.

| set | 7-Zip + PJA | zpaq-std + PJA | Aqueous | 7-Zip | zpaq-std |
|---|---|---|---|---|---|
| photos (151) | **72.57%**, 9.6 / 4.8 s | 72.88%, 17.4 / 5.6 s | 80.46%, 2.3 / 0.8 s | 97.04%, 7.5 / 1.1 s | 97.84%, 0.6 / 0.4 s |
| corpus (78) | **66.86%**, 8.7 / 3.8 s | 68.96%, 13.0 / 3.3 s | 71.98%, 1.4 / 0.3 s | 82.24%, 3.0 / 0.5 s | 85.28%, 0.4 / 0.3 s |
| MPO (6) | **73.39%**, 4.8 / 2.3 s | 73.76%, 16.1 / 4.6 s | 78.94%, 1.2 / 0.4 s | 99.57%, 4.0 / 1.0 s | 100.04%, 0.3 / 0.2 s |
| arithmetic-coded (244) | **17.25%**, 1.8 / 0.8 s | 18.14%, 5.6 / 0.9 s | 85.73%, 0.2 / 0.0 s | 74.49%, 0.5 / 0.1 s | 75.43%, 0.2 / 0.1 s |
| generated (640) | **16.40%**, 2.9 / 1.5 s | 16.96%, 6.6 / 1.7 s | 33.98%, 0.7 / 0.3 s | 62.85%, 1.3 / 0.4 s | 67.22%, 0.3 / 0.3 s |
| 12-bit, small (10) | **58.28%**, 0.2 / 0.2 s | 96.05%, 0.2 / 0.0 s | 92.63%, 0.0 / 0.0 s | 90.38%, 0.0 / 0.0 s | 95.55%, 0.0 / 0.0 s |
| 12-bit from RAWs (12) | **84.80%**, 3.7 / 2.1 s | 84.99%, 12.5 / 2.9 s | 100.00%, 0.2 / 0.0 s | 100.00%, 2.3 / 0.1 s | 100.07%, 0.3 / 0.2 s |
| lossless JPEG (36) | 27.52%, 0.3 / 0.2 s | **25.98%**, 0.4 / 0.2 s | 96.59%, 0.0 / 0.0 s | 95.64%, 0.1 / 0.0 s | 97.82%, 0.0 / 0.0 s |

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
once: 16 to 18% of the input, where Aqueous writes 34 to 86%. With 2.1.0
zpaq-std + PJA writes stream version 7 too, as the command does: it is now
0.3 to 2.1 points behind 7-Zip + PJA (1 to 4 with 2.0.1), 1.5 to 3.4 times
slower to write and up to 2 times slower to extract; what it spends
buys an archive any zpaq can extract without the plugin, through the
ZPAQL decoder each block carries. Aqueous is 4 to 13 times faster than
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
[zpaq-std plugin][wPlugin] (PJA as codecs for zpaq archives), [the library
and 7-Zip plugin][wLib],
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
[wLib]: https://github.com/YadeWira/PJA/wiki/Library-and-7-Zip
[wPlugin]: https://github.com/YadeWira/PJA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PJA/wiki/Building
[wHow]: https://github.com/YadeWira/PJA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PJA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PJA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PJA/wiki/Releases

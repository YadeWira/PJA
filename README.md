# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal,
with the coefficient model's core in C and some x86-64 assembly; no
libraries.

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
give the JPEG back byte for byte too, against `pja` 0.5.1. Measured on
30/10/2026 ([how][wComp]): each set's whole output against its input, every
file decompressed and compared with the original; a file a tool does not
take, or that does not come back the same, counts at its own size.

| set | files | size | packJPG 5.0g | JPEG XL | PJA 0.5.1 |
|---|---|---|---|---|---|
| photos (Huffman JPEG) | 151 | 78.4 MB | 76.62% | 79.80% | **72.60%** |
| corpus of JPEGs of every kind | 78 | 33.0 MB | 77.23% (takes 65) | 86.03% (takes 56) | **70.39%** |
| MPO (stereo pairs) | 6 | 41.0 MB | 86.54% | takes none | **73.38%** |
| arithmetic-coded JPEG | 244 | 6.7 MB | 78.52% | takes none | **74.59%** |
| generated JPEGs | 640 | 18.3 MB | 77.48% | 85.35% (takes 528) | **73.72%** |
| 12-bit JPEG | 10 | 83 KB | takes none | takes none | **88.14%** |
| lossless JPEG | 36 | 390 KB | takes none | takes none | **96.04%** |

And how fast, on the 151 photos (two Xeon E5-2697A v4, 64 threads, with
other work running). "8 at once": `pja -th 8`; the others, 8 processes of
one file each. PJA and packJPG verify what they write; `cjxl` does not.

| | packJPG 5.0g | JPEG XL | PJA 0.5.1 |
|---|---|---|---|
| compress, 1 thread | 73.7 s | **28.7 s** | 76.8 s |
| decompress, 1 thread | 38.6 s | **11.2 s** | 38.0 s |
| compress, 8 at once | 11.3 s | **4.1 s** | 10.0 s |
| decompress, 8 at once | 5.3 s | **1.5 s** | 5.1 s |

PJA is the smallest on every set and the only one that takes every file:
5.5% smaller than packJPG on photos, at the same speed, and 9.9% smaller
than JPEG XL, which is 2.5 to 3.5 times faster but takes no arithmetic,
12-bit or lossless JPEG nor MPO.

## Against archivers

One archive per set, 8 threads, on 30/10/2026; every file extracted and
compared, and every one came back. Times are to write the archive / to
extract it.

- **7-Zip + PJA**: 7-Zip 25.01 with PJA 0.5.1's plugin, `7z a -mmt=8
  -m0=PJA -m1=LZMA2` ([below](#in-7-zip-and-7-zip-zstd)).
- **zpaq-std + PJA**: [zpaq-std](https://github.com/YadeWira/zpaq-std)
  2.0.0 with the PJA 0.5.1 plugin it ships, `zpaq-std a set.zpaq FILES
  -sa -t8`; its z codecs put the PJA streams of a block's files through an
  LZ77 that reaches back into the files before.
- **Aqueous**: [Aqueous](https://github.com/lifthrasiir/aqueous) (`aqr`,
  commit `30f9a4e`), `aqr -c -T 8 -l high`.
- For reference, 7-Zip (`7z a -mmt=8`, LZMA2) and zpaq-std (`-t8`, its
  default method) without PJA.

| set | 7-Zip + PJA | zpaq-std + PJA | Aqueous | 7-Zip | zpaq-std |
|---|---|---|---|---|---|
| photos (151) | **72.57%**, 10.4 / 5.2 s | 75.25%, 23.8 / 8.3 s | 80.46%, 2.2 / 0.7 s | 97.04%, 7.4 / 1.1 s | 97.84%, 0.7 / 0.4 s |
| corpus (78) | **66.86%**, 8.6 / 3.9 s | 70.79%, 11.8 / 6.1 s | 71.98%, 1.5 / 0.3 s | 82.24%, 2.8 / 0.4 s | 85.28%, 0.4 / 0.3 s |
| MPO (6) | **73.39%**, 5.0 / 2.5 s | 74.53%, 19.3 / 6.0 s | 78.95%, 1.1 / 0.4 s | 99.57%, 3.8 / 0.9 s | 100.07%, 0.3 / 0.2 s |
| arithmetic-coded (244) | **17.25%**, 1.8 / 0.8 s | 18.72%, 5.6 / 1.0 s | 85.73%, 0.2 / 0.0 s | 74.49%, 0.5 / 0.1 s | 75.43%, 0.1 / 0.1 s |
| generated (640) | **16.40%**, 3.0 / 1.5 s | 17.41%, 9.3 / 2.2 s | 33.99%, 0.6 / 0.3 s | 62.85%, 1.2 / 0.4 s | 67.22%, 0.4 / 0.3 s |
| 12-bit (10) | **58.28%**, 0.2 / 0.2 s | 113.85%¹, 0.3 / 0.0 s | 92.62%, 0.0 / 0.0 s | 90.38%, 0.0 / 0.0 s | 99.88%, 0.0 / 0.0 s |
| lossless JPEG (36) | 27.37%, 0.2 / 0.2 s | **25.98%**, 0.4 / 0.2 s | 96.62%, 0.0 / 0.0 s | 95.64%, 0.0 / 0.0 s | 98.69%, 0.0 / 0.0 s |

¹ zpaq-std 2.0.0 puts the 57 KB decoder of the pjax codec into a block of
83 KB of small files; it has been told.

7-Zip + PJA is smaller than Aqueous on every set, and the smallest of all
on every set but the lossless one; zpaq-std + PJA is smaller than Aqueous
on all but the 12-bit one. On the arithmetic-coded and generated sets,
whose files are variants of a few images, both keep each image about
once: 16 to 19% of the input, where Aqueous writes 34 to 86%. zpaq-std +
PJA is 1 to 4 points behind 7-Zip + PJA, 1.4 to 4 times slower to write
and 1.3 to 2.4 times to extract: its plugin writes the stream PJA's ZPAQL
decoder reads (version 5, about 1.6 times slower than the command's), so
that any zpaq can extract the archive without the plugin. Aqueous is 4 to
10 times faster than either.

## In 7-Zip and 7-Zip-zstd

`libpja` (in each release) is a C library and, in the same file, a codec
for [7-Zip](https://7-zip.org) and
[7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd): put `pja.dll` (or
`pja.so`) in the `Codecs` folder next to 7-Zip, and

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

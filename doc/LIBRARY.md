# libpja: PJA as a library and a 7-Zip plugin

`libpja` is one shared object (`pja.so`, `pja.dll`, `pja.dylib`) that does
two jobs:

- a **C library** (`pas/lib/pja.h`) for any program: one file in memory to
  a `.pja` and back, and a **filter** over a stream of any bytes;
- a **codec plugin for 7-Zip and 7-Zip-zstd**, the method `PJA`, which is
  that filter.

It is built from `pas/lib/`: `pjalib.pas` (the library, its exports and
PJA's codec), `pjafilter.c` (the filter), `pja7z.c` (7-Zip's interfaces),
plus PJA's C part (`pas/build_c.sh`).

```sh
pas/lib/build.sh build/lib                                   # Linux: pja.so
CC=x86_64-w64-mingw32-gcc FPC="fpc -Twin64 -Px86_64" pas/lib/build.sh build/w64   # pja.dll
```

## The filter

An archiver that puts many files into one stream (7-Zip's solid blocks)
cannot hand PJA one file at a time. The filter takes the stream as it is,
finds the JPEG and JPEG-LS files inside it, recompresses each one with
PJA's codec (stream version 7, verified: it must come back byte for byte),
and passes **every other byte through untouched**, so that the archiver's
own compressor (LZMA2, zstd) still sees them:

```
solid block ──► PJA filter ──► [ raw bytes | JPEG as PJA | raw bytes | ... ] ──► LZMA2 ──► archive
```

The two help each other:

- PJA does what no general compressor can: the JPEGs' coefficients.
- The compressor after it does what PJA alone cannot: matches across
  files. EXIF blocks and thumbnails of one camera, other files, and — the
  big one — **one image saved several times**: the same coefficients
  written progressive or not, with or without restarts, with other Huffman
  tables come out of PJA as the same coefficient stream, so LZMA2 finds it
  again. On 640 JPEGs that are
  variants of 12 images, PJA + xz writes 16% of the input, where PJA alone
  writes 74% and Aqueous 34%.

### How it finds a file

A file starts with `FF D8 FF`. The filter walks its markers: segment
lengths, and after each SOS the entropy-coded bytes up to the next marker
(JPEG: `FF 00` and the RSTs are data; JPEG-LS, after an SOF55: `FF` then a
byte under `80`), until the EOI. A candidate whose markers do not add up,
that PJA does not take, that does not come back byte for byte or that does
not get smaller stays raw; so does any file over 256 MiB. The JPEGs inside
a JPEG (EXIF thumbnails) are inside its segments, so they go with it; an
MPO's images, one after another, are found one by one.

### The stream

```
"PJAF" 01                    magic and version
records, each a tag byte:
  00 n bytes                 n raw bytes (n a LEB128 number, 1 to 262,144)
  01 size n stream           a file of `size` bytes as PJA's codec stream of
                             n bytes (doc/CODEC.md), n < size
  FF                         the end
```

Raw bytes are cut into records of 262,144 bytes counted from the end of the
last file, so the stream depends only on the input: not on how it was read,
not on the number of threads.

Files are compressed in batches, several at once (up to eight per thread,
or 64 MiB), and decompressed the same way; with fewer files than threads,
each file's bands share the rest.

## The C interface

`pas/lib/pja.h`. Every function can be called from several threads at once,
and no exception or signal leaves the library: errors are return codes.

| function | does |
|---|---|
| `pja_version()` | `"pja 0.2.0"` |
| `pja_compress(in, size, &out, &out_size, threads)` | a JPEG or JPEG-LS file → a `.pja` (the command's format: size and BLAKE3 hash inside); `PJA_E_NOT_TAKEN` for a file PJA does not take |
| `pja_decompress(in, size, &out, &out_size, max_size, threads)` | a `.pja` → the original, checked against its size and hash |
| `pja_filter_encode(read, ctx, write, ctx, threads)` | the filter: every byte read → its stream, written |
| `pja_filter_decode(read, ctx, write, ctx, threads)` | its stream → the bytes |
| `pja_free(p)` | frees what the library returned |

`pas/lib/test_lib.c` is the test, and an example: each file through
`pja_compress`/`pja_decompress`, all of them in one stream with bytes
between them through the filter, read 1 byte to 1 MiB at a time (the same
stream every time), and damaged and cut filter streams.

## The 7-Zip plugin

Put the library in the `Codecs` folder next to 7-Zip: `7z.exe` on Windows
(7-Zip or 7-Zip-zstd), `7z` and `7z.so` on Linux. `7z i` lists it:

```
 1  ED     37F01 PJA
```

```sh
7z a -m0=PJA -m1=LZMA2 photos.7z photos/        # 7-Zip
7z a -m0=PJA -m1=zstd  photos.7z photos/        # 7-Zip-zstd
7z x photos.7z
```

`-mmt` sets the filter's threads when compressing; extracting, 7-Zip
gives its thread count only to the first coder of the chain that takes one
(LZMA2), so PJA uses the processors (up to 8), as the `pja` command does.
**The archive needs the plugin to be extracted**, in every 7-Zip that
opens it. It works with 7-Zip on Windows and with 7-Zip 23 or later on
Linux and macOS; p7zip (the old port, `7z` 16.02) builds its interfaces
differently and does not load it.

Measured on 29/10/2026 with 7-Zip 25.01 on Linux (`-mmt=8`, one archive per
set, every file extracted and compared): the input's size, the archive
against it, and the times to write it and to extract it.

| set | files | 7-Zip + PJA + LZMA2 | 7-Zip-zstd + PJA + zstd | Aqueous | `pja` alone |
|---|---|---|---|---|---|
| photos | 151 | **72.60%**, 20.9 / 7.8 s | 72.60%, 15.5 / 7.7 s | 80.46%, 2.3 / 0.7 s | 72.61% |
| corpus of JPEGs of every kind | 78 | **66.90%**, 15.3 / 6.2 s | 69.99%, 12.9 / 6.2 s | 71.91% | 70.39% |
| MPO | 6 | **73.40%** | | 78.94% | 73.38% |
| arithmetic-coded JPEG | 244 | **17.37%** | | 85.71% | 74.59% |
| generated JPEGs | 640 | **16.52%**, 4.7 / 2.7 s | 16.58%, 4.3 / 2.5 s | 33.96% | 73.73% |

On the photos the archive is as small as the `pja` command's files: there
is little for LZMA2 to add. Where files repeat an image's coefficients (the
arithmetic-coded and generated sets hold the same images in several
encodings), the
pair is four times smaller than PJA alone and half the size of Aqueous.
LZMA2 is the slower half of the chain: PJA's output does not compress
further, and LZMA2 goes through it on one or two threads; zstd is faster.

Tested on Windows 10 with 7-Zip 26.05 and 7-Zip-zstd 26.02, 64 and 32
bits: the plugin listed, archives written, tested and extracted byte for
byte, and an archive written on Linux extracted.

The method ID, `03 7F 01`, is the one 7-Zip's `DOC/Methods.txt` keeps for
an experimental method; PJA will move to an ID of its own once 7-Zip
assigns one, and stay able to read `03 7F 01`.

How it is made: 7-Zip's interfaces are C++ classes with only virtual
methods, which is a table of function pointers at the start of the object,
so `pja7z.c` builds them in plain C (`__stdcall` on 32-bit Windows). The
library exports `GetNumberOfMethods`, `GetMethodProperty`,
`CreateDecoder`, `CreateEncoder`, `CreateObject` and `GetModuleProp`
(which tells 7-Zip on Linux, since version 23, that `IUnknown` has no
virtual destructor). Strings handed to 7-Zip are BSTRs of `wchar_t`: OLE's
on Windows, 7-Zip's own layout from `malloc` elsewhere.

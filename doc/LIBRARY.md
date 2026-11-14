# libpja: PJA as a library and a 7-Zip plugin

The filter's streams and the C interface are stable since 0.9.0:
`doc/STABILITY.md`.

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

### JPEGs without their tables (0.5.0)

Some formats keep an image as many small JPEGs that share their tables:
FlashPix (`.fpx`), Picture It's and PhotoDraw's `.mix` (built on it), and
TIFF's JPEG compression. The tables (DQT, DHT) are written once, as a JPEG
of tables only (`FF D8`, the segments, `FF D9`; TIFF's JPEGTables), and
each tile is an "abbreviated" JPEG without them, which no decoder, PJA
included, reads alone. The filter gives such a JPEG the last JPEG of tables
it saw, or, before the first one, the first ahead of it (up to 16 MiB on:
FlashPix writes them after the tiles); PJA codes it as if the tables were
after its SOI, and leaves them out of its stream (pjamodel.SetGivenTables),
so a tile of 2 KB still gains. The JPEGs of tables themselves stay raw.

34 such files of the sample corpus (FlashPix, Picture It, PhotoDraw, TIFF;
25.3 MB) in one 7-Zip archive, `-m0=PJA -m1=LZMA2`: 71.92% of their size
with 0.4.0, which did not take the tiles (plain LZMA2: 71.92% too),
**59.55%** now; every file back. Konica's `.kqp` and `.pic` have no tables
anywhere: their software assumes them. Since 0.5.2, a JPEG without
tables whose container has none within 16 MiB is given the standard ones,
T.81's example tables as libjpeg writes them when it does not optimize
(K.1's quantization at quality 50, K.3's Huffman): Konica's files are
coded with them, 10 files 30.4 KB -> 22.5 KB on average, every one back.
A JPEG they are not right for does not come back and stays raw. Since
0.5.3 they are also tried when the last tables seen were another file's
and did not fit (in a solid block, a Konica file after a JPEG of tables
of some other program): 0.5.2 left such a file raw.

### The stream

```
"PJAF" 01                    magic and version
records, each a tag byte:
  00 n bytes                 n raw bytes (n a LEB128 number, 1 to 262,144)
  01 size n stream           a file of `size` bytes as PJA's codec stream of
                             n bytes (doc/CODEC.md), n < size
  02 n segments              tables (0.5.0): n bytes of DQT, DHT, DRI or COM
                             segments, for the 03 records after it; nothing
                             is written
  03 size n stream           a file of `size` bytes without tables of its own
                             (0.5.0): its codec stream is that of the file
                             with the last 02's tables after its SOI, which
                             the stream leaves out (one bit says so)
  FF                         the end
```

A 02 record comes just before the first 03 record that needs other tables
than the decoder has. A decoder of 0.4.0 or before stops at 02 or 03 with
a data error.

**Tags 04 to FE are reserved** for records of later releases. A decoder
that meets one stops there: with `PJA_E_VERSION` since 0.9.5 (a newer PJA
wrote the stream), with a data error (`PJA_E_DATA`) before; it never skips
the record nor reads it as something else, and what came before it may
have been written already. The same holds for a `PJAF` version past 2, a
`PJAB` version past 1, and a file record whose codec stream is of a
version the decoder does not know (`doc/STABILITY.md`).

The filter does not look for JPEG 2000 files yet (0.9.5 and later take them in
`pja_compress` and the command only): they stay among the raw bytes, for
the compressor after it.

Raw bytes are cut into records of 262,144 bytes counted from the end of the
last file, so the stream depends only on the input: not on how it was read,
not on the number of threads.

### Version 2: two streams, PJA's data deduplicated

For an archiver that can store several streams apart (7-Zip's method `PJA`
below), version 2 splits the output:

```
A: "PJAF" 02, the same records, but a file's record is only 01 size n:
   its codec stream goes to B
B: "PJAB" 01, then each file's n bytes, in A's order, as
   L, L literal bytes, [M, D, L, L literal bytes]...
   (L, M, D LEB128 numbers; a match copies M >= 32 bytes from D bytes back
   in the streams written so far; it ends when the n bytes are there)
```

A holds the raw bytes and goes on to the archiver's compressor; B holds
PJA's data, which no compressor makes smaller, and skips it. What a
compressor would still have found in B — the same coefficients in several
files — is taken out by the filter itself: each file's stream is coded
against the ones before it (up to 128 MiB of them, then the history starts
again on both sides), its matches found through a hash of 32 bytes at
every position against the history's positions every 8 bytes. LZMA2 found
those repeats too, but had to read all of PJA's data to do it, and that
was most of 7-Zip's time.

### Threads

Files go to a pool of threads as the filter finds them, up to eight per
thread (or 64 MiB) ahead of the oldest, which is written as soon as it is
done; so reading, compressing and writing overlap, and extracting works the
same way. A file alone gets the threads for its bands. None of this
changes the stream.

## The C interface

`pas/lib/pja.h`. Every function can be called from several threads at once,
and no exception or signal leaves the library: errors are return codes.

| function | does |
|---|---|
| `pja_version()` | `"pja 0.9.12"` |
| `pja_compress(in, size, &out, &out_size, threads)` | a JPEG, JPEG-LS or (0.9.5: stream version 8, its codestreams modelled or as their pixels; 0.9.6: HTJ2K too) JPEG 2000 file → a `.pja` (the command's format: size and BLAKE3 hash inside); `PJA_E_NOT_TAKEN` for a file PJA does not take |
| `pja_decompress(in, size, &out, &out_size, max_size, threads)` | a `.pja` → the original, checked against its size and hash; `PJA_E_VERSION` for one a newer PJA wrote |
| `pja_filter_encode(read, ctx, write, ctx, threads)` | the filter: every byte read → its stream, written |
| `pja_filter_decode(read, ctx, write, ctx, threads)` | its stream → the bytes |
| `pja_filter2_encode(read, ctx, write_a, ctx, write_b, ctx, threads)` | version 2: two streams, A for the archiver's compressor and B (PJA's data, deduplicated) to store as it is |
| `pja_filter2_decode(read_a, ctx, read_b, ctx, write, ctx, threads)` | both streams → the bytes |
| `pja_free(p)` | frees what the library returned |

Return codes: `PJA_OK` (0), `PJA_E_NOT_TAKEN` (1), `PJA_E_DATA` (2:
damaged, or not PJA's), `PJA_E_MEMORY` (3: out of memory or over a size
limit), `PJA_E_READ` (4) and `PJA_E_WRITE` (5: the filter's callbacks),
`PJA_E_ARG` (6), and since 0.9.5 `PJA_E_VERSION` (7): the input was
written by a newer PJA, a `.pja` or codec stream version, a version 8
codestream mode or flag, a filter version or record this release does not
know, where 0.9.0 said `PJA_E_DATA`. Those bytes can also be damaged, and
nothing tells the two apart there (a `.pja`'s hash covers the original,
checked after its stream is decoded): a damaged byte that makes a codec
stream's first byte 9 to 255, a version 8 flag or mode byte other than 0,
or a filter record tag 04 to FE gives `PJA_E_VERSION` as well; damage
anywhere else gives `PJA_E_DATA`. More codes may come; a caller treats one
it does not know as an error.

`pas/lib/test_lib.c` is the test, and an example: each file through
`pja_compress`/`pja_decompress`, all of them in one stream with bytes
between them through the filter, read 1 byte to 1 MiB at a time (the same
stream every time), the stream twice over through version 2 (the second
copy deduplicated), damaged and cut filter streams, and what a newer PJA
would write (a `.pja` of version 5, codec streams of versions 9 to 255,
`PJAF` 03, `PJAB` 02, records 04 to FE, a file record of a later codec
stream): `PJA_E_VERSION` every time.

## The 7-Zip plugin

Put the library in the `Codecs` folder next to 7-Zip: `7z.exe` on Windows
(7-Zip or 7-Zip-zstd), `7z` and `7z.so` on Linux. The library's build must
be 7-Zip's: the x64 `pja.dll` for 64-bit 7-Zip, the x86 one for 32-bit
7-Zip (on 64-bit Windows, the other one gives "Codec Load Error: ... is not
a valid Win32 application"). `7z i` lists two methods:

```
 1 2ED     37F02 PJA
 1  ED     37F01 PJA1
```

```sh
7z a -m0=PJA -m1=LZMA2 photos.7z photos/        # 7-Zip
7z a -m0=PJA -m1=zstd  photos.7z photos/        # 7-Zip-zstd
7z x photos.7z
```

`PJA` is the filter's version 2: its first stream (the records and the raw
bytes) goes to the next coder, its second (PJA's data) straight into the
archive; 7-Zip binds them that way by itself. `PJA1` is version 1, one
stream, what 0.2.0 wrote as `PJA`: it is there so that those archives
open.

A stream a newer PJA wrote (`PJA_E_VERSION`) comes out of the plugin as
`E_NOTIMPL`, which 7-Zip reports as "Unsupported Method" for the block's
files, and damaged data as "Data Error", as before (7-Zip 25.01, 0.9.5);
damage on one of the version bytes above shows as "Unsupported Method".

`-mmt` sets the filter's threads when compressing. Extracting, 7-Zip
gives its thread count only to the first coder of the chain that takes one
(LZMA2: `CDecoder::Decode` in 7zDecode.cpp, the coders listed backwards
from `-m0`), never to PJA; so since 0.9.10 the plugin reads `-mmt` from
the process's command line (Linux `/proc/self/cmdline`, macOS
`_NSGetArgv`, Windows `GetCommandLineW`), parsed as 7-Zip's console does:
`-mmt=N`, `-mmtN`, `-mmt=on`/`off`, `-mmt+`/`-`, `-mmt=pN` (a percentage
of the processors), the last one counting, none after `--`. Without
`-mmt`, and in another host (7zFM, 7zG), PJA uses the processors (up to
8), as the `pja` command does; a 32-bit 7-Zip no more than that. The
archive's bytes do not depend on the threads. Measured (20 photos, 8 MB,
7-Zip 25.01 on Linux): extracting with `-mmt=1` 4.3 s on one core, `-mmt=2`
2.3 s, `-mmt=8` 0.86 s, `-mmt=16` 0.77 s; before, 0.8 s on about 5.5 cores
whatever `-mmt` said. (The same fix as PPA's, 13ccd32.)
**The archive needs the plugin to be extracted**, in every 7-Zip that
opens it. It works with 7-Zip on Windows and with 7-Zip 23 or later on
Linux and macOS; p7zip (the old port, `7z` 16.02) builds its interfaces
differently and does not load it.

Measured on 29/10/2026 with 7-Zip 25.01 on Linux (`-m0=PJA -m1=LZMA2
-mmt=8`, one archive per set, every file extracted and compared, on a busy
machine): the archive against the input, and the times to write it and to
extract it. zstd (7-Zip-zstd 26.02) gives the same sizes within 0.1%.

| set | files | 7-Zip + PJA | Aqueous | `pja` alone |
|---|---|---|---|---|
| photos | 151 | **72.57%**, 10.9 / 5.6 s | 80.46%, 2.3 / 0.7 s | 72.61%, 10.8 / 5.3 s |
| corpus of JPEGs of every kind | 78 | **66.86%**, 11.7 / 5.1 s | 71.91%, 1.6 / 0.3 s | 70.39% |
| MPO | 6 | **73.39%**, 5.1 / 2.5 s | 78.94%, 1.2 / 0.4 s | 73.38% |
| arithmetic-coded JPEG | 244 | **17.25%**, 1.9 / 0.9 s | 85.71%, 0.2 / 0.0 s | 74.59% |
| generated JPEGs | 640 | **16.40%**, 3.2 / 1.6 s | 33.96%, 0.6 / 0.2 s | 73.73% |

7-Zip with PJA takes as long as the `pja` command on its own. On the photos
the archive is as small as the command's files. Where files repeat an
image's coefficients (the arithmetic-coded and generated sets hold the same
images in several encodings) it is four times smaller than PJA alone and
half the size of Aqueous. Aqueous stays several times faster.

With 0.2.0's one stream (now `PJA1`), LZMA2 had to go through all of PJA's
data: 20.9 / 7.8 s on the photos, for 72.60%.

Tested on Windows 10 with 7-Zip 26.05 and 7-Zip-zstd 26.02, 64 and 32
bits: the plugin listed, archives written, tested and extracted byte for
byte, and an archive written on Linux extracted.

On Windows the library takes its memory from the process heap
(`pas/pjaheap.pas`), not FreePascal's own. FreePascal 3.2.2's heap, in a
DLL, deletes its lock when the thread that loaded the DLL ends; 7-Zip's
file manager loads its codecs from such a short-lived thread, and up to
0.6.1 testing or extracting from inside an archive in 7zFM crashed in
PJA's threads (7z.exe and 7zG, which load codecs from their main thread,
did not). Checked on Windows 10 with 7-Zip 25.01, 64 and 32 bits: 7zFM
tests PJA and PJA1 archives without errors.

`pja_compress` and `pja_decompress` code on the caller's thread, and the
codec keeps its models (about 18 MB) in threadvars, which FreePascal does
not free when a thread of the host ends: up to 0.6.3 every thread that
called them kept one set for good. They now give the set back before
returning, and the library keeps up to four for the next calls on any
thread (no cost measured on repeated calls from one thread).

The method IDs, `03 7F 02` and `03 7F 01`, are in the slot 7-Zip's
`DOC/Methods.txt` keeps for an experimental method; PJA will move to IDs
of its own once 7-Zip assigns them, and stay able to read these.

How it is made: 7-Zip's interfaces are C++ classes with only virtual
methods, which is a table of function pointers at the start of the object,
so `pja7z.c` builds them in plain C (`__stdcall` on 32-bit Windows). The
library exports `GetNumberOfMethods`, `GetMethodProperty`,
`CreateDecoder`, `CreateEncoder`, `CreateObject` and `GetModuleProp`
(which tells 7-Zip on Linux, since version 23, that `IUnknown` has no
virtual destructor). Strings handed to 7-Zip are BSTRs of `wchar_t`: OLE's
on Windows, 7-Zip's own layout from `malloc` elsewhere.

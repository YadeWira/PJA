# What does not change

From 0.9.0, every format PJA writes is fixed: a file written by 0.9.0, or
by any earlier release, is read by every release after it, and none of
these formats changes again. 1.0.0 adds 7-Zip method IDs of PJA's own
(below).

What may still change: speed, the encoder's choices, and the files PJA
takes (more, never fewer). For a JPEG or JPEG-LS file a later release can
write other bytes (a better repair of a damaged JPEG, a different choice of
streams), in these same formats, which every release from 0.9.0 on reads.
A new kind of file comes as a new codec stream version beside these (and,
later, its own zpaq-std codecs): the releases before it refuse such a
stream cleanly ("a newer version": `FutureVersion`, `PJA_E_VERSION` in
the library since 0.9.5, `PJA_E_DATA` before), and read everything else as
before. The JPEG 2000 family came that way, as stream version 8, in 0.9.5
(below).

## The `.pja` file

`doc/FORMAT.md`. Magic `PJA\x01`, version 4 (written since 0.0.2), version
3 read; the stored flag; the descriptor with the original's size, BLAKE3-128
and extension.

## The codec stream

`doc/CODEC.md`. What the `.pja` carries, and what the library and both
plugins carry for each file:

| version | written by | for |
|---|---|---|
| 5 | the zpaq-std codecs pja, pjals, pjall, pjalsx and their z and o and 8 | a JPEG or JPEG-LS file; model byte 0 (full) and 1 (fast, read only) |
| 6 | pjax, pjax7 and their z and 8 | a JPEG with JPEGs inside it (MPO, Ultra HDR), 12-bit JPEG, DNL |
| 7 | the command and the library since 0.1.0; pja7, pjax7 and their z and 8 | the coefficients through version 7's model |
| 8 | the command and `pja_compress` since 0.9.5 | a file of the JPEG 2000 family: its codestreams' places, each with a mode (0 raw, 1 modelled), and the other bytes through the raw bytes' model |

With them, the parts stream, the PATCH stream (a repaired JPEG) and the
bytes stream (a file stored as it is), as `doc/CODEC.md` describes them.
Versions 0 to 4 are never written; 9 and up are left for later kinds of
file, and a release refuses one it does not know as `FutureVersion`
(`pas/tests/test_versions.pas`).

Stream version 8 is fixed as 0.9.5 writes it: its layout (flags, the
table of codestreams, their streams, the host), flag value 0 and
codestream mode 0 (raw: the codestream's bytes stay in the host, coded
with the other bytes) keep their meaning forever, and every release from
0.9.5 on reads what 0.9.5 writes. It is a whole file, as BYTES is: never
a part of a version 6 stream nor the repaired file inside a PATCH stream
(a reader refuses it there as `BadStream`). Codestream mode 1 (the
codestream taken apart and its code-blocks' decisions through a
context-mixing model, `doc/CODEC.md`, "JPEG 2000, stage C") joins what is
fixed when 0.9.5 ships: its stream's layout (layout byte 0, the check, the
slices, the side information through the raw bytes' model and at most
n + n / 4 + 65,536 bytes for a codestream of n, each slice's
decisions), the side information's blob (version 2, its ten streams and
its slice table), the rules that rebuild a codestream from it, and the
model's contexts, counters, mixer, maps and constants, bit for bit. Later
stages (a bitonal pixel mode, HTJ2K, DICOM fragments) come only as new
codestream mode values, a new layout byte of mode 1 (1 is meant for a
codestream coded on from the file's previous one: MJ2 frames), or new flags, in this
same layout; nothing a release has written changes meaning. A program
without mode 1's model (the zpaq-std plugin) reads mode 1 as
`FutureVersion`; the encoder may change which codestreams it models,
which code-blocks it keeps as bytes, its
slices and its tables' sizes (all written in the stream). A release that does not know a mode
or a flag refuses the stream as `FutureVersion` (`PJA_E_VERSION`) before
decoding it, never reads it as something else: a `.pja` of a JPEG 2000
file written by a later release with such a mode needs that release, or a
later one, to be extracted. For the same file a later release may write
other modes (smaller), which is the same rule as for a JPEG's streams
above.

## The library and 7-Zip

`doc/LIBRARY.md`. The filter's streams: `PJAF` version 1 (one stream:
records 00 raw, 01 file, 02 tables, 03 file without tables, FF end), and
`PJAF` version 2 with `PJAB` version 1 (two streams, PJA's data
deduplicated). Record tags 04 to FE are left for later records: a decoder
that meets one stops with an error (`PJA_E_VERSION` since 0.9.5,
`PJA_E_DATA` before), as it does at a `PJAF` or `PJAB` version past its
own. The filter does not take JPEG 2000 files yet: it leaves them as raw
records, as before. The C interface in `pja.h` keeps its functions and
their meaning; new functions may come, and new error codes (0.9.5 added
`PJA_E_VERSION`, 7, where `PJA_E_DATA` was returned for the same
streams): a caller treats a code it does not know as an error.

7-Zip methods: `PJA1` (one stream) and `PJA` (two streams), today under
7-Zip's experimental IDs `03 7F 01` and `03 7F 02`. 1.0.0 brings IDs of
PJA's own; archives written with the experimental ones keep opening in
every release.

## The zpaq-std codecs

`zpaqstd_codecs_v1(i)` and the codec names: each name keeps its index, its
stream, what it takes and its ZPAQL decoder byte for byte, forever (any
zpaq extracts a block through the decoder it carries). A smaller or faster
decoder, even for the same stream, is a new codec.

| index | codec | stream | ZPAQL | since |
|---|---|---|---|---|
| 0 | `pja` | 5 | 62,294 | 0.0.1 |
| 1 | `pjals` | 5 | 55,989 | 0.0.1 |
| 2 | `pjax` | 6 | 57,709 | 0.0.3 |
| 3 | `pjall` | 5 | 30,508 | 0.0.5 |
| 4 | `pjalsx` | 5 | 60,776 | 0.0.6 |
| 5 to 9 | `pjaz`, `pjalsz`, `pjaxz`, `pjallz`, `pjalsxz` | as 0 to 4, through an LZ77 | 39,458, 32,984, 37,476, 18,003, 36,110 | 0.4.0 |
| 10, 11 | `pja7`, `pjax7` | 7, 6 with 7 | 35,104, 35,211 | 0.6.0 |
| 12, 13 | `pja7z`, `pjax7z` | as 10, 11, through an LZ77 | 35,829, 35,987 | 0.6.0 |
| 14 to 16 | `pjalso`, `pjallo`, `pjalsxo` | as 1, 3, 4 | 24,076, 15,058, 25,623 | 0.7.0 |
| 17 to 19 | `pjalszo`, `pjallzo`, `pjalsxzo` | as 6, 8, 9 | 24,724, 15,693, 26,278 | 0.7.0 |
| 20 to 23 | `pja78`, `pjax78`, `pja7z8`, `pjax7z8` | as 10 to 13 | 32,954, 33,197, 33,603, 33,949 | 0.8.0 |
| 24 to 29 | `pjals8`, `pjall8`, `pjalsx8`, `pjalsz8`, `pjallz8`, `pjalsxz8` | as 14 to 19 | 22,430, 13,901, 24,611, 23,046, 14,517, 25,244 | 0.8.0 |

ZPAQL in bytes of PCOMP. zpaq-std's `-sa` uses the newest of each family;
the others stay to read older archives. No codec takes JPEG 2000 yet: one
would come at index 30 or after.

## Left as they are

Three kinds of valid but unusual files would need a change to the streams
to be taken, and are stored as bytes instead (no loss, no compression):
0xFF fill bytes before a restart marker, a JPEG-LS scan whose MAXVAL is a
power of two (T.87's bpp, which CharLS does not follow either), and
Huffman categories past the 8-bit ranges of T.81 that libjpeg decodes.

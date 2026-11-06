# The `pja` command

```
pja a [options] FILE...     compress:  photo.jpg -> photo.pja, scan.jls -> scan.pja, map.jp2 -> map.pja
pja x [options] FILE...     extract:   photo.pja -> photo.jpg (the original's extension)
pja list FILE...            what each .pja holds: original size, stored size, hash
pja t FILE...               test each .pja: extract and verify in memory, write nothing
pja info FILE...            the structure of each file, and what PJA does with it
pja report [FILE]           a bug report (no pixels, no metadata) and a link to open an issue
pja bench FILE...           how fast this machine runs a, a --no-verify and x on them
pja selftest                the samples inside the binary, on every SIMD path here
pja --version, pja -V       the build, the compilers, the system and the SIMD path
```

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, and what is left to each file's bands (a photo is usually one band). Each file's lines still come out in the order of the inputs |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` (`pja.corrupt` beside it if that name would be too long) |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. About twice as fast; a codec bug would then only show when extracting, where the hash catches it. The JPEG's own round trip still runs, so does the check of a repaired JPEG, and the `.pja` is the same byte for byte |
| `--fast` | `a`: accepted for older scripts, and changes nothing: since 0.1.0 the model `a` uses (stream version 7) is as fast as the fast model was and as small as the full one (`CODEC.md`). `x` reads every version |
| `--no-sync` | `a`, `x`, `report`, `bench`: do not wait for each output to reach the disk before it takes its name. A few percent faster on a real disk (none on tmpfs), but after a power cut an output may be empty or missing ([below](#interrupted-runs)). `bench` then measures its write without the flush |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only PJA's (`.pja-tmp-PID-N`, and the `.pja-tmpN` of 0.9.0 and earlier), only regular files, only older than an hour, and never one whose process is still running ([below](#interrupted-runs)) |
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, or (`x`) a `.pja` whose size or hash does not match, fails as it would for real |
| `-q`, `--quiet` | only errors (`--stats` lines still come out, each under its file's name: they were asked for) |
| `--stats` | `a`, `x`, `t`: after each file, where its time went (below), its threads and its bands; then a line for the run: files, bytes in and out, time, MB/s of the originals |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}`; errors still go to stderr as well |
| `--cpu=PATH` | the models' SIMD path: `plain`, `sse41` or `avx2`, before or after the command (`--cpu avx2`, with a space, is refused naming `--cpu=avx2`). A path this processor or this build lacks is refused (exit 2) naming those it has. Every path writes and reads the same bytes: only the speed changes (`selftest` proves it; `selftest --cpu=PATH` checks that path alone) |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one) |
| `--with-file` | `report`: also copy the file beside the report as `pja-report-NAME`, to attach if you choose to (without FILE it is refused: exit 2) |
| `-r N` | `bench`: runs of each measure, the best one counts (3 by default) |
| `--` | everything after it is a file, even if it starts with a dash |

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.pja` verified; `selftest`: every check passed) |
| 1 | a file failed: it is not what the command takes, it is damaged, it could not be read or written (each with its line on stderr); the command's own output could not be written (a full disk, `pja: could not write the output: ...`); `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command, `--cpu` with a path not here |
| 3 | a bug in PJA: an exception that is not about the file or the system (a range check, an access violation, an assertion; not a read or a write the system refused, nor memory it did not give). The run ends with `This is a bug in PJA. Please run: pja report FILE and open an issue at https://github.com/YadeWira/PJA/issues` |
| 130, 143, 129, 141 | ended by SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing ([below](#interrupted-runs)); `STATUS_CONTROL_C_EXIT` on Windows |

A run time error the run time library does not turn into an exception (none
is known) would end with its own number, which is 200 or more.

## Checking and reporting

These are for helping: telling what happened, on which machine, in a form
that can be pasted into an issue, and checking a build before trusting it.

### `pja t FILE...`

What `x` does, without writing: the format, the declared size against
`--max-output`, decoding, then the size and the BLAKE3-128. A line
`NAME: OK` for each one that verifies, `pja: NAME: FAILED: why` on stderr for
each that does not (exit 1). Takes `-th`, `-q`, `--max-output`, `--stats`
and `--json`; `-o`, `-f`, `-n` and `--keep-corrupt` are refused (exit 2).

### `pja info FILE...`

Any file: what it is and what PJA does with it. Each format has a provider
(`pas/pjainfo.pas`; a new format is one more unit):

- **JPEG, MPO, JPEG-LS** (`pas/pjainfojpeg.pas`), from the markers alone:
  every segment with its place and length (DQT's tables, DHT's, DRI's
  interval, DNL's height, the known APP identifiers); the frame (SOF type,
  coding, precision, size, each component's sampling and table); each
  scan's components, band and bits (JPEG-LS: NEAR and the interleave), its
  entropy-coded bytes and restarts; progressive, arithmetic, lossless,
  hierarchical (a JPEG-LS file with NEAR above 0 is `near_lossless`, not
  `lossless`); what follows the EOI; the JPEGs inside APP segments and
  after the EOI (a thumbnail, an MPO's images, a gain map), each with its
  frame; the MPF index (each image's place in the file, `offset`, and as
  the index counts it, from its own header, `mpf_offset`); anything that
  does not fit (`problems`). Past 300 segments and 100 problems they are
  counted, not listed (`segments_not_listed`, `problems_not_listed`).
- **JPEG 2000** (`pas/pjainfoj2k.pas`: raw codestreams, JP2, JPX, JPM,
  Motion JPEG 2000, JPH), from the boxes and the markers alone: the box
  tree (each box's type, place, length and depth; ftyp's brands, ihdr's
  size, components and bits, colr's method and enumerated colour space);
  then each codestream PJA finds (the very list stream version 8 keeps):
  its main header's markers with place and length; SIZ (size, offsets,
  tiles and their grid, each component's bits, sign and subsampling); COD
  (levels, layers, progression, code-block size and style, the wavelet:
  5/3 reversible or 9/7 irreversible, MCT, precincts, SOP, EPH); QCD's
  quantization; CAP and `ht` (HTJ2K: CAP's Part 15 bit or the HT
  code-block style); its tile-parts (tile, part, place, length, header);
  every marker met with how many; what is after the EOC; and what PJA does
  with it: `mode 1 (modelled): 612 B -> 586 B, 4.25% less`, or `mode 0 (as
  bytes): HTJ2K` with the analysis's reason (HTJ2K, Part 2, a limit, a
  marker that does not parse...) or that its stream would not be smaller.
  That is mode 1's own work (as `a` does it, on `-th`'s threads), so a
  large JPEG 2000 file takes `info` about what it takes `a`. Past 300
  boxes and main-header markers, 100 problems, 64 tile-parts and 64
  components a codestream, and 32 codestreams, they are counted, not
  listed (nor analysed). The XML, UUID, label, URL and IPR boxes, an ICC
  profile and a COM marker's text are only measured: `metadata_bytes: XML
  31 B, UUID 0 B, ICC 0 B, labels 15 B, URLs 0 B, IPR 0 B, 2 COM (66 B);
  contents not shown`.
- **.pja** (`pas/pjainfopja.pas`): the container (version, flags, the
  original's size, BLAKE3-128 and extension, stored or not) and the stream:
  its version and model; for versions 5 and 7, the image its header stream
  describes and the number of bands (only the raw bytes' model is decoded,
  never the bands); for version 6, as bytes, PATCH (the edits, then the
  repaired file's stream) or parts (each JPEG inside, then the host's).
  For version 8 (JPEG 2000), each codestream's place, mode and stream (mode
  1: its slices, which count as its bands), and the host's stream.
  A `.pja` that declares an original larger than `--max-output` is not
  decoded (`not_decoded`), as `x` refuses it.

Then `pja: ...`: for a `.pja`, whether it extracts and verifies; for
anything else, what `a --no-verify` would do: `takes it: stream version 7,
1748 B -> 1431 B (81.86%)`, `takes it ..., as bytes: BadRst@1670` (PJA did
not take it as a JPEG and why: the reason and the byte where it was found),
`..., repaired: BadRst@...`, for JPEG 2000 `takes it: stream version 8
(JPEG 2000), 3230 B -> 3084 B (95.48%), 3025 B of codestreams modelled
(mode 1)` (`j2k_modelled_bytes` in `--json`), or `refuses it:
Codec(Jpeg(NotJpeg@0))`.
Exit 1 only for a file that cannot be read. `--json` gives the same tree.

Metadata is never printed, only its size: `metadata_bytes: Exif 1818 B,
XMP 0 B, ICC 0 B, other APP 16 B, 1 COM (19 B); contents not shown`.

### `pja report [FILE] [-o REPORT.txt] [--with-file]`

A plain-text bug report, to stdout or to `-o`'s file:

- PJA: version, commit, build date, FPC's version, the C compiler, the
  target; the system, the processor's name and features, the SIMD path in
  use and those it could take, the processors, the threads;
- the command line, each path cut to its name (an option's value too:
  `--output-dir=NAME`; a path after `--` that starts with a dash as well);
- for FILE: its size, BLAKE3-128, what PJA does with it and its structure,
  as `info` gives them (with `a`'s verification).

**What is not in it**: no pixel and no coefficient, no metadata contents
(EXIF, XMP, ICC, comments, JPEG 2000's XML, UUID and label boxes: only how many bytes), no folder names. A
report on a file that hits a bug says so (`internal_error`) instead of
ending.

Then a link that opens a new issue on GitHub with the report in it
(`https://github.com/YadeWira/PJA/issues/new?template=bug_report.yml&title=...&body=...`):
a report too long for a link (about 6000 characters) keeps its start (PJA,
the system, the command) and its end (the frame, the problems, the
metadata sizes, what PJA does), with a line in their place saying how many
lines were cut and to paste the whole report; the line before the link
says so too. `--with-file` copies FILE beside the
report as `pja-report-NAME` (never over an existing file): it goes nowhere
unless you attach it, which shows the very bytes; GitHub takes a `.jpg`,
anything else (`.jls`, `.mpo`, `.pja`) zipped. Without FILE, the system
part alone, for a problem with no file.

### `pja bench FILE... [-r N] [-th N]`

Prints the system part of the report, then for each file the best of N
runs (3 by default) of `a`, `a --no-verify` and `x`, in milliseconds and
MB/s (2^20 bytes) of the original, with where `a`'s and `x`'s time went,
and the write of the `.pja` alone; then the totals. Everything is in
memory but that write, which goes to a folder of its own in the system's
temporary folder and is deleted: nothing is written beside the inputs. A
`.pja` given is only extracted.

### `pja selftest`

The binary carries six small samples (a baseline JPEG in 4:2:0, a
progressive one, an arithmetic-coded one with restarts, a near-lossless
JPEG-LS, a JPEG 2000 codestream (RPCL, SOP and EPH) that goes as stream version 8's mode 1,
and the baseline one again as stream version 5, the model of the
`.pja` made before 0.1.0 and of the zpaq-std plugin's frozen codecs, with
SSE4.1 code of its own: `pas/pjaselftest.inc`, written by
`tools/gen_selftest.py` from `tests/` and `pas/tests/selftest_v5.pja`),
and the `.pja` each one has to give. On every SIMD path the processor
has, with one thread and with two (two decode the bands while they are
encoded), each is compressed, compared byte for byte with its expected
`.pja` (whose BLAKE3-128 it prints), and extracted back. `--cpu=PATH`
checks that path alone. Exit 0 only if every check passed. CI runs it on
every platform.

### `pja --version`

```
pja 0.9.0
commit: 1482334
built: 2026/11/05
fpc: 3.2.2
c_compiler: gcc 14.2.0
target: x86_64-linux
system: Linux 6.12.115 x86_64
cpu: Intel(R) Xeon(R) CPU E5-2697A v4 @ 2.60GHz
cpu_features: sse2 sse4.1 avx2
cpu_path: avx2
cpu_paths_supported: plain sse41 avx2
c_simd_copies: sse41 avx2
processors: 64
default_threads: 8
```

The commit comes from `PJA_COMMIT` at build time, as the zpaq-std plugin's
(`pas/plugin/build.sh`): `.github/test.sh` and `pas/run_tests.sh` set it
from git when it is not set, `release.yml` from the tag's commit; a build
without it says `commit:` and nothing.

### `--cpu=PATH`

The coefficient models' loops exist as plain code and, on x86-64, as
copies for SSE4.1 (both models) and AVX2 (version 7's, `pas/pjav7c.c`).
The path is chosen at start from cpuid (`PJA_NOASM=1` and `PJA_NOAVX2=1`
turn the copies off); `--cpu` chooses it instead, to compare speeds or to
rule a path out when chasing a bug. 32-bit builds have the plain path only.
A path is there when the processor has it: the Pascal model's SSE4.1 code
is in every x86-64 build. Version 7's C copies may not be (a C part built
with `PJA_V7_PLAIN`, or by a compiler without them): `c_simd_copies` says
which this build has, and the C model runs plain where it has none.

### `--stats`

```
photo.jpg -> photo.pja  15.3 KB -> 12.2 KB  79.97%
  stats: read 0.05 ms, parse 1.03 ms, encode 22.16 ms, verify 11.47 ms, hash 0.07 ms, write 0.12 ms; total 34.90 ms; 1 thread(s), 1 band(s)
```

The stages: `read` the input; `parse` taking the JPEG apart and checking
that it comes back (`a`); `encode` the model; `verify` decoding the stream
to compare it with the input (with two threads or more, a JPEG's bands,
and a JPEG-LS's symbol stream, are decoded while they are encoded, and that
time is `encode`'s); `decode` (`x`, `t`); `hash` BLAKE3; `write` the
output, verified, flushed to the disk (unless `--no-sync`) and renamed;
`other` what falls between. `threads` are the file's own (what `-th`
leaves each file), `bands` the stream's. For a JPEG 2000 file, `parse` is
the walk of its boxes, `encode` each codestream taken apart and its
decisions through the model (stream version 8's mode 1), `verify` both
mode 1's own check of each codestream's stream and the whole stream read
back; its `bands` are the slices of its codestreams of mode 1 (each with
its own model, decoded on a thread of its own). The largest files go first
and the threads are shared out the same way as for JPEG files.

### `--json`

One object a line, so that `python3 -c 'import json'` or `jq` read it
line by line:

```
{"file":"photo.jpg","output":"photo.pja","original_size":15679,"pja_size":12538,"ratio_percent":79.97,"stored":false,"ok":true}
{"summary":{"command":"a","files":1,"failed":0,"bugs":0,"bytes_in":15679,"bytes_out":12538,"seconds":0.035,"threads":8}}
```

The same thing has the same name in every command: `original_size` is
the original's bytes (the JPEG, the JPEG-LS), `pja_size` the `.pja`'s.

| command | fields of each file (after `"file"`) |
|---|---|
| every one | `ok` (`true`: it went through; for `info`, it was read and described); `error` (what failed, as on stderr) when it did not; `internal_error` when it met a bug |
| `a` | `output`, `original_size`, `pja_size`, `ratio_percent`, `stored`; `as_bytes` or `repaired` (the reason and the byte, `BadRst@1670`) when it applies |
| `x` | `output`, `original_size`, `pja_size` |
| `t` | `original_size`, `pja_size` |
| `list` | `original_size`, `pja_size`, `ratio_percent`, `stored`, `extension`, `blake3_128` |
| `info` | the tree the text shows: `format`, `size`, and the format's own (JPEG: `segments`, `frame`, `scans`, `problems`, `metadata_bytes`...; `.pja`: `container`, `stream` with `version` a number); then `pja`: `command` (`a` or `x`), `ok`, `summary` (the line of the text), and for `a`: `takes`, `stream` (in words), `stream_version` (a number; 0 for stored as is), `pja_size`, `ratio_percent`, `as_bytes` or `repaired`, or `error`; for `x`: `original_size` or `error` |
| `--stats` (`a`, `x`, `t`) | `stats`: each stage's `NAME_ms`, `total_ms`, `threads`, `bands` |

The summary: `command`, `files`, `failed`, `bugs`, `bytes_in`, `bytes_out`,
`seconds`, `threads`.

## Nothing written that did not verify

- `a` writes the `.pja` only after the codec has decompressed its own stream
  and compared it with the input (unless `--no-verify` is asked for: a
  program that checks on its own, such as an archiver, need not pay for it
  twice).
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.pja-tmp-PID-N`) that takes the output's name
  only once it is complete **and on the disk** (`fsync`; `FlushFileBuffers`
  on Windows), and on Unix the directory is flushed after the name is
  given: after a power cut the output is either whole or not there, never
  empty or partial under its name. (Windows has no call to flush a
  directory: the name is left to the file system's journal, so a power
  cut just after a run may lose a name, never give it a partial file.) If
  only that last flush fails, the run fails (rc 1) with `written, but its
  directory could not be flushed to the disk`: the output is in place and
  whole, and a rerun needs `-f`. A run
  cut short (Ctrl-C, a kill, a full disk) never leaves a truncated file
  under the output's name. Without `-f` the name is only taken if it is
  still free; with `-f` the temporary is renamed on top: what was there is
  only replaced by something that verified. Nothing that fails deletes a
  file this run did not write. (On a file system without hard links, such
  as FAT, it is written in place when there is no `-f`.)

## Interrupted runs

- **Ctrl-C, `kill`, a closed terminal, a closed pipe**: SIGINT, SIGTERM,
  SIGHUP and SIGPIPE (`pja x ... | head`; on Windows Ctrl-C, Ctrl-Break
  and closing the console) delete the temporaries the run is still
  writing, and it ends as the signal would have ended it (exit status 130
  for SIGINT, 143 for SIGTERM, 129 for SIGHUP, 141 for SIGPIPE;
  `STATUS_CONTROL_C_EXIT` on Windows). Outputs already written stay:
  each one verified. A signal ignored by whoever started `pja` (`nohup`, a
  background job of a script) stays ignored.
- **`kill -9`, a crash, a power cut**: nothing can run then, so a
  `.pja-tmp-PID-N` may stay. The next run that writes in that directory
  names them on stderr (`found 2 leftover temporaries of an interrupted
  run: ...; --clean-temps deletes them`), once per directory, and deletes
  nothing unless `--clean-temps` is given. Either way only names of PJA's
  own pattern count, only regular files (a link or a directory with that
  name is left alone), only older than an hour, and never one whose process
  (the PID in its name) is still running. With `-n` they are only named.
  The notice is a warning on stderr, shown even with `-q`. The PID is
  checked in this machine's process table (`kill(pid, 0)`; `OpenProcess`
  on Windows): in a directory shared with another machine or container
  (NFS, a bind mount) another run's temporary cannot be told alive, and
  the hour of age is the only guard, so do not use `--clean-temps` there
  while another machine may be writing.
- **What flushing costs**: on 151 photos (76 MB) with `-th 8`, writing to
  a SATA SSD took 3.7 to 4.8% longer for `a` and 4.4 to 7.1% longer for
  `x` than 0.9.0, which did not flush (medians of two series of 5 runs);
  on tmpfs, under 1%. It is on by default; `--no-sync` turns it off (within
  1% of 0.9.0) for a run whose outputs can be made again: a power cut may
  then leave an output empty or missing. The temporary and the handlers
  above work the same either way.

## Choices, and why

These follow the switches agreed for packJPG's rework, where they were
measured against the old spelling.

- **An existing output is refused without `-f`.** Otherwise
  `pja a -o a.pja b.jpg` silently replaces `a.pja`.
- **`-o` behaves like the destination of `cp`**: an existing directory or a
  path ending in `/` is a directory, anything else a name. **With more than
  one input, a destination that is not a directory is an error**: without
  that guard, `pja a *.jpg -o one.pja` would write every input over the same
  file and the last one would win.
- **Two inputs with the same output in one run: the second fails**, with or
  without `-f` (`a.jpg` and `a.jpeg`, `d1/p.jpg` and `d2/p.jpg` with
  `--output-dir`, the same file twice), naming the input that took it; so
  does an output that is another input of the run. For `a` it is always the
  later input; for `x`, whose names come from inside the `.pja`, whichever
  finishes second.
- **On Unix a backslash is part of the name**, not a separator:
  `a\x.jpg` gives `a\x.pja`.
- **Values with `=` or a space, never glued**: `-th 4` or `--threads=4`. The
  old glued `-th4` is refused naming the right spelling.
- **There is no bare `-t`.** `-th` is two letters; with no `-t`, it can never
  be read as `-t -h`.
- **`a` and `x` are filters**: `a` refuses a `.pja`, `x` anything that is not
  one. There is no mode that does both; shell globs separate them.
- **The output keeps the original's extension**, as it was written:
  `photo.JPEG` comes back as `photo.JPEG`, `scan.jls` as `scan.jls` (the
  `.pja` keeps it, with a check). The name is the `.pja`'s own. When there
  is none to keep (a `.pja` of version 3, or an extension the format does
  not take: more than 15 characters, or anything but letters, digits, `_`
  and `-`), the content decides: a JPEG-LS file comes back as `.jls`, an
  MPO (a stereo pair, a panorama: its MPF index lists a Multi-Frame image)
  as `.mpo`, any other JPEG as `.jpg`. A JPEG with a gain map or a depth
  map hung off it (Ultra HDR) has an MPF index too, without that class: it
  is a `.jpg`. A file of the JPEG 2000 family: a raw codestream as `.j2k`,
  a file of boxes as `.jp2`, or `.jpx`, `.jpm`, `.mj2`, `.jph` by the brand
  of its ftyp box.
- **JPEG 2000 is recompressed** (0.9.5): `a` takes each codestream apart
  and codes it with a model (stream version 8's mode 1), each one checked;
  a codestream it cannot take (HTJ2K, Part 2) and the other bytes go
  through the raw bytes' model. It says `(JPEG 2000)`, or `(JPEG 2000: as
  bytes)` when no codestream was modelled; `list` says `JPEG 2000`. A
  large codestream of several tiles is coded on several threads (`-th`).
- **Never larger than the original by more than 52 bytes** (37 and the
  extension): a file the codec does not make smaller is stored as it is,
  and `a` and `list` say so.
- **On Windows, `pja` expands `*` and `?` itself**, because neither `cmd`
  nor PowerShell does it for a program: `pja a photos\*.jpg` takes every
  file that matches, in order of name, folders left out. Only the name part
  is a pattern (`photos\*.jpg`, not `*\x.jpg`). A pattern that matches
  nothing fails as `no file matches`, and the other inputs still go through.
  Elsewhere the shell expands them, as always.
- **A write the system refuses is reported in its own words**, with the
  error number: `could not write it: Not a directory (Io(20))`.

Tested by `pas/tests/cli.sh` (191 cells with `tests/j2k`: round trips, JPEG 2000, existing outputs, links,
damage, `--keep-corrupt`, `--max-output`, threads, outputs shared by two
inputs, a write cut short, every usage error; `t`, `info` (JPEG 2000 too), `report` and its
privacy (XML and COM text too), `bench`, `selftest`, `--cpu` on every path here, `--stats`,
`--json`, and the end of a run that meets a bug), and
on Windows by `pas/tests/windows.ps1` (28 cells, the wildcards among them).

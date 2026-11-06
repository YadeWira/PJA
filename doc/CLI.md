# The `pja` command

```
pja a [options] FILE...     compress:  photo.jpg -> photo.pja, scan.jls -> scan.pja, map.jp2 -> map.pja
pja x [options] FILE...     extract:   photo.pja -> photo.jpg (the original's extension)
pja list FILE...            what each .pja holds: original size, stored size, hash
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
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, fails as it would for real |
| `-q`, `--quiet` | only errors |
| `--` | everything after it is a file, even if it starts with a dash |

Exit status: 0 when every file went through, 1 when any failed (each with
its line on stderr), 2 for a usage error. All warnings and errors go to
stderr.

## Nothing written that did not verify

- `a` writes the `.pja` only after the codec has decompressed its own stream
  and compared it with the input (unless `--no-verify` is asked for: a
  program that checks on its own, such as an archiver, need not pay for it
  twice).
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.pja-tmpN`) that takes the output's name only once
  it is complete: a run cut short (Ctrl-C, a kill, a full disk) can leave a
  `.pja-tmpN` behind, never a truncated file under the output's name.
  Without `-f` the name is only taken if it is still free; with `-f` the
  temporary is renamed on top: what was there is only replaced by something
  that verified. Nothing that fails deletes a file this run did not write.
  (On a file system without hard links, such as FAT, it is written in place
  when there is no `-f`.)

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

Tested by `pas/tests/cli.sh` (74 cells: round trips, JPEG 2000, existing outputs, links,
damage, `--keep-corrupt`, `--max-output`, threads, outputs shared by two
inputs, a write cut short, every usage error), and
on Windows by `pas/tests/windows.ps1` (28 cells, the wildcards among them).

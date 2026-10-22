# The `pja` command

```
pja a [options] FILE...     compress:  photo.jpg -> photo.pja, scan.jls -> scan.pja
pja x [options] FILE...     extract:   photo.pja -> photo.jpg (or .jls, by content)
pja list FILE...            what each .pja holds: original size, stored size, hash
```

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, and what is left to each file's bands (a photo is usually one band). Each file's lines still come out in the order of the inputs |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. About twice as fast; a codec bug would then only show when extracting, where the hash catches it. The JPEG's own round trip still runs, and the `.pja` is the same byte for byte |
| `--fast` | `a`: a JPEG goes with the fast model: about 1.75 times as fast both ways, 1.7% larger than the full model, and on one thread smaller and about 9% faster than packJPG 5.0f (`CODEC.md`). `x` needs no switch |
| `-n`, `--dry-run` | do everything but write |
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
- Writing creates the file without following links. With `-f`, it goes to a
  temporary file and is renamed on top: what was there is only replaced by
  something that verified. Nothing that fails deletes a file this run did not
  write.

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
- **Values with `=` or a space, never glued**: `-th 4` or `--threads=4`. The
  old glued `-th4` is refused naming the right spelling.
- **There is no bare `-t`.** `-th` is two letters; with no `-t`, it can never
  be read as `-t -h`.
- **`a` and `x` are filters**: `a` refuses a `.pja`, `x` anything that is not
  one. There is no mode that does both; shell globs separate them.
- **The output's type comes from its content**: a JPEG-LS file comes back as
  `.jls`, a JPEG as `.jpg`, whatever the `.pja` is called.
- **Never larger than the original by more than 32 bytes**: a file the codec
  does not make smaller is stored as it is, and `a` and `list` say so.
- **A write the system refuses is reported in its own words**, with the
  error number: `could not write it: Not a directory (Io(20))`.

Tested by `pas/tests/cli.sh` (48 cells: round trips, existing outputs, links,
damage, `--keep-corrupt`, `--max-output`, threads, every usage error).

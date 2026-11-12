# PJA format

Stable since 0.9.0: `doc/STABILITY.md`.

**A `.pja` is ONE compressed file**: a JPEG, a JPEG-LS file or, since
0.9.5, a file of the JPEG 2000 family, as the codec stream
(`doc/CODEC.md`), together with the size, hash and extension of the
original. The extension is `.pja`; dispatch is by magic, not by extension.

The files PJA takes are usually called (the extension each keeps, as it
was written):

| family | extensions | codec stream |
|---|---|---|
| JPEG | `jpg`, `jpeg`, `jpe`, `jfif`, `mpo`... | 5, 6, 7 |
| JPEG-LS | `jls` | 5 |
| JPEG 2000 (0.9.5) | `jp2`, `j2k`, `j2c`, `jpc`, `jpx`, `jpf`, `jpm`, `mj2`, `jph`, `jhc` | 8 |

Any other name works too: the content decides, and a `.pja` without an
extension kept is extracted as `.jpg`, `.jls`, `.mpo`, or for JPEG 2000
`.j2k` (a raw codestream) or `.jp2`, `.jpx`, `.jpm`, `.mj2`, `.jph` (by the
brand of its ftyp box).

What the `.pja` adds over the bare codec stream, and why each thing:

| | why |
|---|---|
| **BLAKE3-128 hash of the original** | A damaged stream can decode to **another valid file** without any error. The hash gives it away. |
| **declared original size** | Allows rejecting a bomb **before decoding**. It is also the decoder's cap: the output cannot exceed it. |
| **the original's extension** (version 4) | So that `photo.JPEG` comes back as `photo.JPEG`, not as whatever its content suggests. Only the extension: the name is the `.pja`'s own. With a check of its own, since the hash covers the content only. |

The codec verifies its own stream when compressing (it decompresses it and
compares), so what the hash protects against is damage **after** writing:
the disk, the network, a hand.

No encryption. An earlier version of the format (2) wrapped packJPG's `.pjg`
and could encrypt it, with C libraries; both went away with the move to a
codec of our own and to Pascal only. Encrypting is left to the tools made for
it.

---

## 1. Layout

```
HEADER - 8 B
  magic        4 B   "PJA\x01"
  version      1 B   4        (3 is still read: no extension field; 1 was a multi-file
                              container, 2 the encrypted .pjg wrapper)
  flags        1 B   bit 0: stored (the payload is the original itself); the rest 0
  reserved     2 B   0

DESCRIPTOR - 24 B, and in version 4 the extension field (5 to 20 B)
  orig_size    u64 LE   the original's length
  hash         16 B     BLAKE3-128 of the original
  ext_len      1 B      0 to 15                                      (version 4)
  ext          ext_len  the original's extension, without the dot, as it was
                        written: letters, digits, '_' and '-' only    (version 4)
  ext_check    4 B      the first 4 bytes of BLAKE3 of ext_len and ext (version 4)

PAYLOAD - the rest: the codec stream, or with the stored flag the original

A file the codec does not make smaller (a JPEG-LS file of noise, for
instance) is stored as it is: 37 bytes more than the original, and the
extension's length (at most 52 bytes in all). Its descriptor is
stricter: `orig_size` has to be the payload's length exactly.
```

The hash is BLAKE3 truncated to 128 bits, in Pascal (`pas/pjablake3.pas`),
checked against the official implementation: its vectors (`pas/tests/kat.txt`)
and, before the C copy was removed, every size from 0 to 5,000 bytes and 66
more up to 33 MiB, all equal.

---

## 2. Order of operations

**On extract** (`pjapack.Unpack`), and it is the order that provides the
safety:

1. validate the header: magic, version, flags known, reserved bytes zero
2. validate the descriptor: `orig_size` between 1 and 65,536 x the payload
   length (`ValidateDescriptor`), and a payload of at least 6 B (the
   smallest codec stream); in version 4, the extension's length, its
   characters and its check (`ValidExtension`, `ExtensionCheck`)
3. reject if `orig_size` exceeds the user's cap (`--max-output`)
4. decode, with `orig_size` as the cap of the raw part
5. check that the result is `orig_size` bytes long and has the declared hash
6. only then, write it under its name (`pjafs.WriteVerified`)

**On compress** (`pjapack.Pack`): the codec compresses and verifies; the
original is hashed; the writer validates the descriptor with the same
function the reader uses. What is written can be opened, and what is
rejected on open cannot be written. This is the rule an earlier container
broke: it wrote files its own reader rejected.

---

## 3. Hostile cases

Each row is a case with its expected result, and it is in the tests.

### 3.1 Header (`test_format`)

| case | expected |
|---|---|
| 0 to 7 bytes; a header with less than a whole descriptor | `ShortFile` |
| wrong magic, garbage, zeros | `NotPja` |
| version 5 or higher | `FutureVersion(n)` |
| (the codec stream's own version, 9 or higher; `test_versions`) | `Codec(FutureVersion)` |
| versions 0, 1 and 2 | `OldVersion(n)` |
| any flag but bit 0 | `UnknownFlag` |
| the stored flag on a codec stream (its length is not `orig_size`) | `BadOrigSize` |
| a reserved byte other than 0 | `ReservedNotZero` |

### 3.2 Descriptor (in the writer **and** in the reader, with the same verdict)

| case | expected |
|---|---|
| `orig_size` = 0 | `BadOrigSize` |
| `orig_size` > 2^63 - 1 | `BadOrigSize` |
| `orig_size` = 65,536 x payload | accepted |
| `orig_size` = 65,536 x payload + 1 | `RatioExceeded`, without multiplying (by dividing: no overflow) |
| 5 B payload | `PayloadOutOfRange` |
| stored: `orig_size` other than the payload's length | `BadOrigSize` |
| stored: an empty payload | `PayloadOutOfRange` |

### 3.2b Extension (version 4; `test_format`)

| case | expected |
|---|---|
| `JPEG`, kept as written | opens with `JPEG`; `Unpack` gives it |
| any bit of its characters or of its check | `BadExtension` |
| its length one short (the check gives it away), or above 15 | `BadExtension` |
| no extension field, or its check cut short | `ShortFile` |
| `a.b`, `a/b`, `a b`, a byte above 127, 16 characters: the writer and the reader | `BadExtension`, both |
| `Pack` given `../x` or 16 characters | leaves it out: the file is named by its content |
| version 3, no field | opens, no extension |

### 3.3 Corruption (`test_corruption`)

- **The format alone:** every bit of the 27 sample files packed with their
  extensions, every value of the header and descriptor bytes (the
  extension field included), every truncation and appended data:
  1,810,944 variants. None **reads the same** as the original: every byte
  means something, the extension's too (56,808 of them `BadExtension`).
  Those the format cannot reject (a bit in the payload) read a different
  payload, and step 5 gives them away.
- **End to end, with the codec:** 8,085 variants of the 14 smaller files
  (every header and descriptor bit, bits spread over the payload,
  truncations). **None ends in a different file delivered as good**, and no
  exception: a format rejection, a codec rejection, a size or hash mismatch,
  or (a bit the codec does not use) the original itself. The codec's own
  damage tests flip every bit of the first 128 bytes of its streams (64 for
  JPEG-LS) and try every truncation (`run_codec_tests.sh`).

### 3.4 Writing the output (`test_pjafs`, `tests/cli.sh`)

| case | expected |
|---|---|
| link (symbolic or hard) with the output's name | without overwrite: the name is taken (a dangling link takes it too); with overwrite, the entry is replaced and **it is never written through** |
| any write | to a new temporary file with a short name of its own (`.pja-tmp-PID-N`) in the same directory, which takes the output's name only once complete: **cut short, it leaves no truncated file under that name** |
| a power cut | the temporary's data is flushed to the disk (`fsync`, `FlushFileBuffers`) before it takes the name, and the directory after (Unix; Windows has no such call and leaves the name to the file system's journal): **the output is whole or absent, never empty under its name** (unless the run asked for `--no-sync`). A failed flush of the directory fails the run (`NotSynced`) with the output already in place |
| SIGINT, SIGTERM, SIGHUP, SIGPIPE (Ctrl-C, closing the console) | the temporaries being written are deleted, from a fixed table and without allocating, and the process ends by the same signal (130 for SIGINT); one ignored at start stays ignored |
| a temporary left by a SIGKILL or a crash | the next run that writes in that directory names it; `--clean-temps` deletes it: only PJA's name pattern, a regular file, older than an hour, of a process that is gone (pid 1 included in the ones asked about; another machine's processes cannot be seen) |
| the output already exists | rejected, unless overwrite is requested; the name is given without replacing anything (link, or MoveFileEx without REPLACE_EXISTING), so one taken meanwhile is rejected too |
| with overwrite | the temporary is renamed on top: **what was there is only replaced by something that verified** |
| the output is a directory | rejected, even if overwrite is requested |
| hash does not match | **nothing is written** under that name |
| the same, with `--keep-corrupt` | written as `<name>.corrupt`; if it already exists, `.corrupt.1`, `.corrupt.2`...; if that name is too long, `pja.corrupt[.N]` in the same directory |
| the same, and there is no free `.corrupt` name | error, without writing anything |
| the size the descriptor declares is not what the stream gives (a damaged `orig_size`) | as a hash that does not match: nothing under that name; with `--keep-corrupt`, what was decoded (up to `--max-output`) is written as `<name>.corrupt`, even when it matches the stored hash, because the descriptor itself is damaged |
| the write fails halfway | what was written is deleted before returning the error |
| the file could not be created | **nothing is deleted**: whatever is there was not written by us |

> **A file that remains on disk under its own name passed verification.**

A file with a good name and bad content is worse than no file at all.
`--keep-corrupt` exists because a partial JPEG usually displays and is
sometimes worth rescuing, but it rescues it under **another name**.

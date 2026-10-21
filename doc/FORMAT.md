# PJA format

**A `.pja` is ONE compressed file**: a JPEG or a JPEG-LS file, as the codec
stream (`doc/CODEC.md`), together with the size and hash of the original. The
extension is `.pja`; dispatch is by magic, not by extension.

What the `.pja` adds over the bare codec stream, and why each thing:

| | why |
|---|---|
| **BLAKE3-128 hash of the original** | A damaged stream can decode to **another valid file** without any error. The hash gives it away. |
| **declared original size** | Allows rejecting a bomb **before decoding**. It is also the decoder's cap: the output cannot exceed it. |

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
  version      1 B   3        (1 was a multi-file container, 2 the encrypted .pjg wrapper)
  flags        1 B   bit 0: stored (the payload is the original itself); the rest 0
  reserved     2 B   0

DESCRIPTOR - 24 B
  orig_size    u64 LE   the original's length
  hash         16 B     BLAKE3-128 of the original

PAYLOAD - the rest: the codec stream, or with the stored flag the original

A file the codec does not make smaller (a JPEG-LS file of noise, for
instance) is stored as it is: 32 bytes more than the original, never
more. Its descriptor is stricter: `orig_size` has to be the payload's
length exactly.
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
   smallest codec stream)
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
| version 4 or higher | `FutureVersion(n)` |
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

### 3.3 Corruption (`test_corruption`)

- **The format alone:** every bit of the 19 sample files packed, every value
  of the header and descriptor bytes, every truncation and appended data:
  1,029,301 variants. None **reads the same** as the original: every byte
  means something. Those the format cannot reject (a bit in the payload)
  read a different payload, and step 5 gives them away.
- **End to end, with the codec:** 6,157 variants of the 12 smaller files
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
| the output already exists | rejected, unless overwrite is requested |
| with overwrite | written to a new temporary file in the same directory and renamed on top: **what was there is only replaced by something that verified** |
| the output is a directory | rejected, even if overwrite is requested |
| hash does not match | **nothing is written** under that name |
| the same, with `--keep-corrupt` | written as `<name>.corrupt`; if it already exists, `.corrupt.1`, `.corrupt.2`... |
| the same, and there is no free `.corrupt` name | error, without writing anything |
| the write fails halfway | what was written is deleted before returning the error |
| the file could not be created | **nothing is deleted**: whatever is there was not written by us |

> **A file that remains on disk under its own name passed verification.**

A file with a good name and bad content is worse than no file at all.
`--keep-corrupt` exists because a partial JPEG usually displays and is
sometimes worth rescuing, but it rescues it under **another name**.

# PJA format limits policy

The format's numbers and where each one comes from. The layout is in
`FORMAT.md`; the numbers live in `pas/pjalimits.pas`.

With a single file per `.pja`, the output name is chosen by the user, not by
the file, and the only possible bomb is the usual one: a small file that
claims a huge output.

| rule | value | why |
|---|---|---|
| payload >= 5 B | the codec stream's version byte and header length | no empty or impossible payload |
| `orig_size` >= 1 | | an empty file does not exist |
| `orig_size` <= 2^63 - 1 | | no stream size can hold more |
| `orig_size` <= 65,536 x payload | see below | rejects before decoding |
| `orig_size` <= `--max-output` | 256 MB by default; `0` = no limit | the user's ceiling; applied before decoding |

**The 65,536x is a last-resort cap, not a tight bound.** Measured on
19/10/2026: photos expand 1.3x from their `.pja`; a 24 MP solid-colour JPEG
160x; a JPEG with 4 MB of zeros after its end 2,038x, because the raw bytes
compress to almost nothing. packJPG used 500x, which the second and third
cases would break: the writer would refuse its own output. What matters is
not the number but *when* it is applied: before anything is decoded.

**The declared size is also the decoder's cap.** The raw part of the stream
cannot claim more than `orig_size` bytes, and the result has to be exactly
`orig_size` bytes long: a lying `orig_size` buys nothing.

**The writer applies the same rules as the reader, with the same function**
(`ValidateDescriptor`).

## What this policy does not cover

**What happens inside the codec.** The hash guarantees that what is delivered
is the original. It does not make decoding a hostile stream safe: that is the
codec's job, with range and overflow checks on in every build that decides
anything, its own limits on image size, and its damage tests (`CODEC.md`).

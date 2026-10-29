# PJA

Lossless recompression of **JPEG** and **JPEG-LS** files, in FreePascal with
some x86-64 assembly, and nothing else: no C, no C++, no libraries.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pja a photo.jpg          # -> photo.pja, about 25% smaller
pja x photo.pja          # -> photo.jpg, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pja`.

Against packJPG 5.0g, on the files both take: 2.2% smaller on photos,
6.6% on a corpus of JPEGs of every kind, 14.3% on MPOs; `--fast` is still
smaller than packJPG and decompresses faster, and PJA uses several processors.
It also takes 12-bit and lossless JPEG, which packJPG does not
([the numbers][wComp]).

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

The [wiki][wiki] has the rest: [comparison with packJPG][wComp], the
[zpaq-std plugin][wPlugin] (PJA as codecs for zpaq archives),
[building and testing][wBuild], [how it works][wHow], the [source
layout][wLayout], [FreePascal pitfalls][wFpc] and the [release
history][wRel]. The codec's full notes are in [doc/CODEC.md](doc/CODEC.md),
the file format in [doc/FORMAT.md](doc/FORMAT.md).

## Building

FreePascal 3.2:

```sh
cd pas
fpc -O3 -dPJA_FAST pjacli.pas -opja       # the command
cd .. && ./run_tests.sh                    # every test
```

## License

MIT, see `LICENSE`. The arithmetic-coded JPEG support is based in part on the
work of the Independent JPEG Group; see `NOTICE` for that and other credits.

[ciBadge]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PJA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PJA "Latest release"
[relLink]: https://github.com/YadeWira/PJA/releases/latest
[wiki]: https://github.com/YadeWira/PJA/wiki
[wComp]: https://github.com/YadeWira/PJA/wiki/Compared-with-packJPG
[wHandles]: https://github.com/YadeWira/PJA/wiki/What-PJA-handles
[wInstall]: https://github.com/YadeWira/PJA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PJA/wiki/Platforms
[wPlugin]: https://github.com/YadeWira/PJA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PJA/wiki/Building
[wHow]: https://github.com/YadeWira/PJA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PJA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PJA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PJA/wiki/Releases

# Test samples

Every file here is synthetic: a fractal plasma from ImageMagick with a fixed
seed, encoded with libjpeg's `cjpeg` or, for JPEG-LS, with CharLS. None comes
from a photo or from another project. They are small on purpose: the suites
flip every bit of them.

## `jpg/`

| file | made with |
|---|---|
| `baseline_444.jpg` | `convert -seed 21 -size 64x64 plasma:fractal` → `cjpeg -quality 85 -sample 1x1` |
| `baseline_color.jpg` | the same image → `cjpeg -quality 85` (4:2:0) |
| `color_plasma.jpg` | `convert -seed 22 -size 320x240 plasma:fractal` → `cjpeg -quality 85 -optimize` |
| `grayscale.jpg` | `convert -seed 23 -size 64x64 plasma:fractal -colorspace gray` → `cjpeg -quality 75 -grayscale` |
| `solid_color.jpg` | `convert -size 32x32 xc:'#3a7bd5'` → `cjpeg -quality 90` |
| `prog_huffman.jpg`, `restart_huffman.jpg` | a 120x80 plasma → `cjpeg -progressive -optimize`, and `cjpeg -quality 60 -restart 1` |
| `arith_*.jpg` | 96x64 and 40x24 plasmas → `cjpeg -arithmetic`: sequential, progressive, with restarts, gray progressive |

## `jls/`

A 64x48 plasma (`-seed` fixed), gray and colour, encoded with CharLS: gray
at 16, 12 and 2 bits, colour at 16 bits (ImageMagick wrote the
intermediate files at 16 bits, so `gray8*.jls` are 16-bit too), lossless
and NEAR 1 to 3, the three interleave modes, and one with custom
thresholds.

`plasma17x13_*.jls`: a 17x13 colour plasma (ImageMagick, `-seed 7`, 8
bits) encoded with CharLS 2.4: NEAR 1 with sample interleave, and lossless
with line interleave given a restart interval of 4 lines (CharLS 2.4
writes none: PJA's own JPEG-LS encoder, pjajls.RecomposeJls, rebuilt it
with a DRI segment, and checked it decodes back). Small enough for the
ZPAQL decoder's test in the Python interpreter.

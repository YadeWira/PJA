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
| `twelve_bit.jpg`, `twelve_bit_arith_prog.jpg` | a 96x64 plasma (`-seed 41`, 16-bit PPM) → libjpeg-turbo 3.0.4's `cjpeg -precision 12 -quality 85 -optimize`, and `-precision 12 -arithmetic -progressive` (the system's libjpeg cannot write 12-bit JPEG) |
| `stereo.mpo` | an MPO as a stereo camera writes it: a 256x192 plasma (`-seed 51`, `cjpeg -quality 85`) and the same shifted 6 pixels, the first with an APP2 MPF index of two Multi-Frame Disparity images (0x020002) and their sizes and offsets |
| `gain_map.jpg` | the same left image with a 128x96 gray plasma (`-seed 52`) after it, its MPF index saying Baseline MP Primary (0x030000) and Undefined (0x000000), as an Ultra HDR JPEG hangs its gain map: it has to come back as a `.jpg` |
| `lossless_p6.jpg` | lossless JPEG (SOF3): a 96x64 plasma (`-seed 61`) → libjpeg-turbo 3.0.4's `cjpeg -lossless 6` |
| `lossless16_p7_pt5.jpg` | an 80x48 gray plasma (`-seed 62`, 16-bit PGM) → `cjpeg -precision 16 -lossless 7,5`: 16 bits, predictor 7, point transform 5 |
| `lossless_restart.jpg` | the same at 8 bits → `cjpeg -lossless 4 -restart 3 -grayscale`: a restart every 3 lines |
| `dnl_baseline.jpg`, `dnl_progressive.jpg`, `dnl_lossless.jpg` | `baseline_color.jpg`, `prog_huffman.jpg` and `lossless_restart.jpg` with the frame's height set to 0 and a DNL segment giving it right after the first scan (B.2.5), which no common encoder writes (libjpeg reads none either) |
| `dri_no_restarts.jpg` | `color_plasma.jpg` with a DRI segment (an interval of 5 MCUs) and no restart marker in its scan, as some cameras' encoders wrote them (two such files in the corpus): the scan is coded as if there were none |
| `thumbs_twice.jpg` | a 320x240 plasma (`-seed 31`, `cjpeg -quality 85`) with the same image at 96x72 (`cjpeg -quality 75`) as a thumbnail twice, in an APP1 and in an APP2, as some cameras write it |
| `two_images.jpg` | the same with the thumbnail once, and a second image after its EOI, a 240x160 plasma (`-seed 32`, `cjpeg -quality 80`), as an MPO has it |
| `image_after_eoi.jpg` | `solid_color.jpg` with `baseline_444.jpg` after its EOI (`cat`): a small file of stream version 6, for the pjax ZPAQL in the Python interpreter |
| `restarts_misnumbered.jpg` | `restart_huffman.jpg` with its restart markers numbered from RST4 on instead of RST0, as Second Nature's slide shows have them (libjpeg: "found marker 0xd4 instead of RST0"): PJA renumbers them and keeps the original numbers (stream version 6, PATCH) |
| `byte_before_eoi.jpg` | `baseline_color.jpg` with a 00 byte between its scan and its EOI, as Xara writes its JPEGs (libjpeg says nothing): PJA takes it out and puts it back (PATCH) |
| `scan_ends_early.jpg` | `color_plasma.jpg` with its scan's last 40 bytes taken out and its EOI kept, as some encoders end a scan before its last blocks (libjpeg: "premature end of data segment"): PJA reads it on with zero bits, as libjpeg does, and keeps what it added to take out again (PATCH) |
| `cut_short.jpg` | `restart_huffman.jpg` cut at 93%, without its EOI, as a download cut short leaves a file: the same, with the RSTs its DRI asks for in what PJA adds |
| `prog_restarts_cut.jpg` | `convert -seed 25 -size 120x80 plasma:fractal` → `cjpeg -progressive -restart 3B -quality 75`, cut at 70% without its EOI: a restart every 3 blocks in the scan PJA fills, whose intervals are not all the same length (a byte or so), so the filler cannot simply repeat one: it has to come back repaired, as 0.6.2 repaired it |
| `prog_correction_limit.jpg` | `convert -seed 71 -size 192x128 plasma:fractal -blur 0x4` → `cjpeg -progressive -quality 90`, its AC refinement scans re-encoded by PJA's own encoder ending each EOB run once it holds more than 2 correction bits (libjpeg: 937; Photoshop: about 256): it needs stream version 6, and `djpeg` decodes it to the same pixels |

## `jls/`

A 64x48 plasma (`-seed` fixed), gray and colour, encoded with CharLS: gray
at 16, 12 and 2 bits, colour at 16 bits (ImageMagick wrote the
intermediate files at 16 bits, so `gray8*.jls` are 16-bit too), lossless
and NEAR 1 to 3, the three interleave modes, and one with custom
thresholds.

`color_line_subsampled.jls`: `color_line.jls`'s components subsampled
as the T.87 conformance image T8SSE0 has them (2x4, 2x1, 1x2: the first
kept, the second every 4th line, the third every 2nd line and column) and
written by PJA's own JPEG-LS encoder, its frame's sampling factors
changed (CharLS has no subsampled JPEG-LS). The same rules decode
T8SSE0's first component as the conformance set's non-subsampled image
has it, sample for sample.

`plasma33x17_none_sub.jls`: a 33x17 colour plasma (ImageMagick, `-seed
73`, 8 bits) encoded with CharLS without interleave, its components then
subsampled 2x2, 1x1, 1x1 (the first kept, the others every 2nd line and
column) and written by PJA's own JPEG-LS encoder, as
`color_line_subsampled.jls` was. Small enough for the pjalsx ZPAQL
decoder's test in the Python interpreter.

`plasma17x13_*.jls`: a 17x13 colour plasma (ImageMagick, `-seed 7`, 8
bits) encoded with CharLS 2.4: NEAR 1 with sample interleave, and lossless
with line interleave given a restart interval of 4 lines (CharLS 2.4
writes none: PJA's own JPEG-LS encoder, pjajls.RecomposeJls, rebuilt it
with a DRI segment, and checked it decodes back). Small enough for the
ZPAQL decoder's test in the Python interpreter.

## `j2k/`

The JPEG 2000 family (stream version 8). Each image is one of `jpg/`'s,
decoded with libjpeg's `djpeg -pnm` and encoded with OpenJPEG 2.5's
`opj_compress` (the system's, Debian 13); none comes from elsewhere.

| file | made with |
|---|---|
| `plasma_cs.j2k` | `baseline_color.jpg` (64x64) → `opj_compress -r 20`: a raw codestream |
| `plasma.jp2` | `color_plasma.jpg` (320x240) → `opj_compress -r 60`: a JP2 |
| `layers.jp2` | `prog_huffman.jpg` (120x80) → `opj_compress -r 80,40,20`: three quality layers |
| `lossless53.j2k` | `grayscale.jpg` (64x64) → `opj_compress` (its default: lossless, the 5/3 wavelet) |
| `gray_12bit.jp2` | `grayscale.jpg` scaled to 12 bits (ImageMagick, `convert -depth 12`, a PGM of maxval 4095) → `opj_compress -r 10`: 12 bits a sample |
| `two_codestreams.jpx` | `pas/tests/mkj2k_boxes.py jpx`, around `plasma_cs.j2k` and `lossless53.j2k`: a JPX with two codestreams, the first in a box with a 64-bit length (XLBox), the second in a last box of length 0 (to the end of the file), with an asoc superbox and a codestream header box |
| `two_frames.mj2` | `pas/tests/mkj2k_boxes.py mj2`, around `plasma_cs.j2k` and `baseline_444.jpg` → `opj_compress -r 20`: the boxes of a Motion JPEG 2000 file (signature, ftyp `mjp2`, an mdat with two jp2c frames), without the moov box a player needs |

No tool at hand writes JPX or Motion JPEG 2000, hence the last two, put
together box by box. Their names are apart from `jpg/`'s and `jls/`'s
(`gray_12bit.jp2`, not `gray12.jp2`): the suites put every sample in one
folder, and two inputs with the same name give the same `.pja`.

For stage B (`pas/tests/test_j2kcs.pas`: each codestream taken apart and
put back together), five raw codestreams with what the others lack, each
`color_plasma.jpg` decoded with `djpeg -pnm` and cut to its top-left 96x80
(a PPM; `opj_compress` has no option to crop):

| file | made with `opj_compress` and |
|---|---|
| `cblk_styles.j2k` | `-M 63 -r 40,20,10 -n 4 -b 16,16`: every code-block style (BYPASS, RESET, RESTART, CAUSAL, ERTERM, SEGMARK), three layers |
| `bypass_layers.j2k` | `-M 1 -r 24,12,6,3 -n 3 -b 16,16`: BYPASS alone, its raw segments cut by four layers |
| `rpcl_sop_eph.j2k` | `-p RPCL -c [32,32],[16,16] -n 4 -SOP -EPH -r 30,10 -b 8,8`: RPCL, precincts, SOP and EPH markers |
| `pcrl_tiles_plt_tlm.j2k` | `-p PCRL -t 48,40 -TP R -PLT -TLM -n 3 -r 20,8 -b 16,16`: PCRL, four tiles, a tile-part per resolution, PLT and TLM |
| `cprl_poc.j2k` | `-p CPRL -POC T1=0,0,1,3,2,CPRL/T1=0,0,2,4,3,LRCP -n 4 -M 8 -r 12,4,1 -b 16,16`: CPRL, a POC in the tile's header, CAUSAL, three layers (the last at rate 1, which still leaves passes out: not lossless, every pixel differs) |

For stage D (stream version 8's mode 2: a reversible codestream kept as
its pixels), two lossless ones that mode 2 takes and keeps (its stream
is smaller than mode 1's):

| file | made with |
|---|---|
| `bitonal.j2k` | `color_plasma.jpg` decoded with `djpeg -pnm`, to gray and thresholded at 50% (ImageMagick, `convert -colorspace Gray -threshold 50%`), one byte 0 or 1 a pixel (a `.raw`) → `opj_compress -F 320,240,1,1,u`: a 1-bit codestream (Ssiz 0), lossless (the PBM and PGM readers of `opj_compress` make 8-bit ones) |
| `rgb_tiles53.j2k` | `baseline_color.jpg` (64x64, `djpeg -pnm`) → `opj_compress -b 8,8 -t 40,36 -d 5,3 -n 3`: lossless RGB with the reversible colour transform, four tiles on an image offset by (5, 3), so that the wavelet's signals start at odd places |

And one where mode 2 takes the codestream to under half its bytes and
mode 1 is still smaller (a large COM, the same in both, makes the
codestream large and its coded bytes few): the choice must try mode 1
too.

| file | made with |
|---|---|
| `lossless_com.j2k` | `grayscale.jpg` (64x64, `djpeg -pnm`) → `opj_compress -C "<text>"`: `lossless53.j2k` with a COM of 9,939 bytes of text, the text `PJA test comment line N: a long compressible COM marker segment.` for N = 0 to 149, joined by spaces |

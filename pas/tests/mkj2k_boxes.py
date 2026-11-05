#!/usr/bin/env python3
"""Builds tests/j2k's files with more than one codestream, around raw
codestreams made with opj_compress (tests/README.md): no tool at hand
writes JPX or Motion JPEG 2000.

    mkj2k_boxes.py jpx OUT.jpx COLOR.j2k GRAY.j2k
    mkj2k_boxes.py mj2 OUT.mj2 FRAME1.j2k FRAME2.j2k

jpx: the signature, ftyp (jpx, compatible with jp2), jp2h for the first
codestream (a 64x64 colour image), an asoc superbox with a label and an XML
box inside, a codestream header box (jpch) for the second (a 64x64 gray
image), the first codestream in a jp2c box with a 64-bit length (XLBox),
the second in the last box, whose length is 0 (to the end of the file).

mj2: the signature, ftyp (mjp2) and an mdat box holding two jp2c boxes, one
per frame, as Motion JPEG 2000 keeps its samples. There is no moov box: the
box structure the codec walks, not a movie a player opens."""
import struct
import sys


def box(kind, payload):
    return struct.pack('>I', 8 + len(payload)) + kind + payload


def xlbox(kind, payload):
    return struct.pack('>I', 1) + kind + struct.pack('>Q', 16 + len(payload)) + payload


SIGNATURE = box(b'jP  ', b'\r\n\x87\n')


def ihdr(h, w, nc, bpc):
    # height, width, components, bits per component - 1, compression 7, unknown colourspace 0, no IPR
    return box(b'ihdr', struct.pack('>IIHBBBB', h, w, nc, bpc - 1, 7, 0, 0))


def colr(enum):
    return box(b'colr', struct.pack('>BBBI', 1, 0, 0, enum))


def main():
    kind, out, a, b = sys.argv[1:5]
    cs1 = open(a, 'rb').read()
    cs2 = open(b, 'rb').read()
    if kind == 'jpx':
        data = (SIGNATURE +
                box(b'ftyp', b'jpx ' + struct.pack('>I', 0) + b'jpx jp2 ') +
                box(b'jp2h', ihdr(64, 64, 3, 8) + colr(16)) +
                box(b'asoc', box(b'lbl ', b'two codestreams') +
                    box(b'xml ', b'<note>a test file of PJA</note>')) +
                box(b'jpch', ihdr(64, 64, 1, 8)) +
                xlbox(b'jp2c', cs1) +
                struct.pack('>I', 0) + b'jp2c' + cs2)
    elif kind == 'mj2':
        data = (SIGNATURE +
                box(b'ftyp', b'mjp2' + struct.pack('>I', 0) + b'mjp2') +
                box(b'mdat', box(b'jp2c', cs1) + box(b'jp2c', cs2)))
    else:
        sys.exit('jpx or mj2')
    with open(out, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    main()

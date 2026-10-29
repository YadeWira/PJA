{ Codec layer 1: a JPEG split into what is stored verbatim (markers, tables,
  scan headers, garbage after EOI) and its DCT coefficients, and back to the
  SAME file, byte for byte.

  What an encoder may choose differently from the standard, and therefore has
  to be recorded: the padding bit of each entropy-coded segment and the RST
  sequence. What is not recorded yet (an extra ZRL, an unneeded EOB, stray
  bytes between the scan and the next marker) cannot pass as good:
  VerifyRoundTrip rebuilds and compares against the original.

  For now: 8 bits, Huffman or arithmetic (QM coder), sequential or
  progressive (SOF0, SOF1, SOF2, SOF9, SOF10). Lossless, hierarchical,
  JPEG-LS and 12-bit give Unsupported.

  In progressive mode the encoder chooses how long an EOB run gets and how
  many correction bits it buffers before flushing. This reproduces libjpeg
  (jcphuff.c): runs up to $7FFF and up to 937 buffered bits.

  This is the Pascal reference version, no asm: it reads Huffman codes one bit
  at a time. The fast version is measured against this one. }
unit pjajpeg;

{$I pja.inc}
{$ifopt R-}{$fatal pjajpeg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjajpeg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { Cap on 8x8 blocks over all components: 4M blocks are 512 MB of
    coefficients. A 100 MP photo in 4:2:0 is ~2.3M. }
  MAX_BLOCKS = 1 shl 22;
  { From the standard (B.2.3): the sum of H*V in an interleaved scan. }
  MAX_MCU_BLOCKS = 10;
  { Lossless JPEG: cap on samples over all components, as for JPEG-LS }
  MAX_LOSSLESS_SAMPLES = 1 shl 27;

  { ZIGZAG[k] = natural position (row*8+col) of the k-th coefficient in a scan. }
  ZIGZAG: array[0..63] of Byte = (
     0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

const
  { jcphuff.c: MAX_CORR_BITS - DCTSIZE2 + 1 }
  LIBJPEG_MAX_BE = 1000 - 64 + 1;
  { the most correction bits a run may hold, here: TProgState.bebuf }
  MAX_BE_LIMIT = 4096 - 64;

type
  TJpegError = (
    jeNone,
    jeNotJpeg, jeTruncated, jeBadSegment, jeUnexpectedMarker,
    jeBadDqt, jeBadDht, jeBadSof, jeRepeatedSof, jeBadSos,
    jeMissingTable, jeBadDri, jeTooLarge, jeBadDac, jeBadLse,
    { the JPEG may be valid, but this layer does not handle it yet }
    jeUnsupported,
    { in the entropy-coded data }
    jeBadCode, jeCoefOutOfRange, jeBadRst, jeInconsistentPadding,
    jeDataAfterScan,
    { decoded completely, but does not give back the same bytes }
    jeNoRoundTrip);

  TJpegResult = record
    err: TJpegError;
    pos: Int64;      { byte of the original where it was detected }
    value: Integer;  { the marker, with jeUnsupported and jeUnexpectedMarker }
    function Ok: Boolean;
    { "BadCode@1234", "Unsupported(C9)@2" }
    function Text: string;
  end;

  THuff = record
    counts: array[1..16] of Byte;
    values: array[0..255] of Byte;
    nvalues: Integer;
    { decoding (F.2.2.3): maxcode[l] = -1 when there are no codes of length l }
    mincode, maxcode, valptr: array[1..16] of Integer;
    { encoding: len 0 = the symbol is not in the table }
    code: array[0..255] of Word;
    len: array[0..255] of Byte;
    { decoding fast path: for the next 9 bits, (length shl 8) or symbol of
      the code they start with, 0 if that code is longer than 9 bits }
    lut: array[0..511] of Word;
  end;

  TComponent = record
    id, h, v, tq: Byte;
    { grid padded to whole MCUs, which is how it is stored }
    bw, bh: SizeInt;
    { the one a single-component scan walks (A.2.2) }
    bwReal, bhReal: SizeInt;
    { bw*bh*64, each block in zigzag order }
    coef: array of SmallInt;
    { lossless JPEG: the samples instead, width*height, row by row (the
      point transform's, as the scan codes them) }
    samples: array of Word;
  end;

  TScan = record
    ncomp: Integer;
    comp: array[0..3] of Integer;   { indices into TJpeg.comp }
    dc, ac: array[0..3] of THuff;   { the tables in force when the scan starts }
    { arithmetic coding: the statistics table of each component (Td, Ta) and
      the conditioning in force (DAC): DC bounds L and U, AC threshold Kx }
    td, ta: array[0..3] of Integer;
    dcL, dcU, acK: array[0..3] of Integer;
    ss, se, ah, al: Integer;
    ri: Integer;                     { restart interval in force, 0 = no RST }
    { progressive Huffman: the longest EOB run the AC table can code,
      (2 shl r) - 1 for its largest EOBr symbol; 32767 with a full table }
    maxEob: Integer;
    padbit: Integer;
    { progressive Huffman, AC refinement: how many correction bits an EOB
      run may hold before the encoder ends it, the run going on while they
      are no more than this. libjpeg's is LIBJPEG_MAX_BE; Photoshop ends
      its runs sooner. Decompose finds it from the scan, ParseHeaders
      leaves libjpeg's, and the caller sets another }
    maxBe: Integer;
    { a DRI in force, but the scan has no restart markers: an encoder that
      wrote the DRI and then coded as if there were none (ri is 0 then).
      ParseHeaders cannot tell it from the raw bytes: the caller says it }
    ignoreRi: Boolean;
    cut: SizeInt;                    { where in TJpeg.raw its data goes }
    { Decompose only: its entropy-coded bytes in the file, [dataStart, dataEnd) }
    dataStart, dataEnd: SizeInt;
  end;

  TJpeg = record
    width, height: Integer;
    precision: Integer;              { bits per sample: 8 or 12; lossless 2 to 16 }
    { lossless JPEG (SOF3, Annex H): samples, not coefficients; each scan's
      ss is its predictor and al its point transform, the same in all }
    lossless: Boolean;
    { the frame's height is 0, and a DNL segment after the first scan
      gives it }
    dnl: Boolean;
    progressive: Boolean;
    arithmetic: Boolean;
    comp: array of TComponent;
    hmax, vmax, mcusx, mcusy: Integer;
    qt: array[0..3, 0..63] of Word;  { in zigzag order, as in the DQT }
    qpresent: array[0..3] of Boolean;
    scans: array of TScan;
    { the file without its entropy-coded data }
    raw: TBytes;
    { Decompose only: where in the file the image ends, just past its EOI
      (the file's length when it has none); what follows is kept in raw }
    eoi: SizeInt;
    { VerifyRoundTrip only: Recompose wrote each scan's entropy-coded bytes
      exactly where they were, [dataStart, dataEnd) (for VerifyRoundTripFrom) }
    scansExact: Boolean;
  end;

  { A sequential Huffman scan for HuffEncodeScan (pjasysc.c's hencscan_t,
    field for field): each component of the scan (slot) with its grid and
    tables, the writer's output, and the state kept between calls }
  THuffEncSlot = record
    coef: PSmallInt;
    bw, h, v: SizeInt;
    dcCode, acCode: PWord;
    dcLen, acLen: PByte;
    predIdx: SizeInt;
  end;
  THuffEncScan = record
    acc: QWord;
    slot: array[0..3] of THuffEncSlot;
    nslot, unitsX, total, ri, padbit: SizeInt;
    outp: PByte;
    n, cap: SizeInt;
    u, ux, uy, rst: SizeInt;
    pred: array[0..3] of SizeInt;
    nacc: SizeInt;
    { a progressive scan: its band and bits, then TProgState's EOB run and
      correction bits }
    progressive, ss, se, ah, al, maxEob, maxBe: SizeInt;
    eobrun, be: SizeInt;
    bebuf: array[0..MAX_BE_LIMIT + 63] of Byte;
    { scratch for the C side (its tables: not on its own stack) }
    encTab: array[0..3, 0..1, 0..255] of LongWord;
  end;
  { 0: written; 1: not (a symbol the table lacks: EncodeScan writes it
    again itself); 2: out needs more room, call again }
  THuffEncodeScanFn = function(var hs: THuffEncScan): SizeInt; cdecl;

  { The same for HuffDecodeScan (pjasysc.c's hdecscan_t): the tables as
    they are (THuff), the data, and padbit and last back }
  THuffDecSlot = record
    coef: PSmallInt;
    bw, h, v: SizeInt;
    dcHuff, acHuff: ^THuff;
    predIdx: SizeInt;
  end;
  THuffDecScan = record
    acc: QWord;
    d: PByte;
    len, first: SizeInt;
    slot: array[0..3] of THuffDecSlot;
    nslot, unitsX, total, ri, precision: SizeInt;
    progressive, ss, se, ah, al, maxEob: SizeInt;
    padbit, last: SizeInt;
    { not read to the end: where DecodeScan goes on, the start of unit u
      (the reader: acc, pos, nbits, stopped) }
    u, ux, uy, rst: SizeInt;
    pred: array[0..3] of SizeInt;
    pos, nbits, stopped: SizeInt;
    { TProgState's decoder part; beLow and beHigh also when read }
    eobrun, runBe, runLen, prevEnded, prevBe, prevLen, beLow, beHigh: SizeInt;
    { scratch for the C side }
    fastAc: array[0..3, 0..511] of LongInt;
  end;
  { 0: read, padbit, last, beLow and beHigh set; 1: not to the end, the
    state where DecodeScan goes on set }
  THuffDecodeScanFn = function(var hs: THuffDecScan): SizeInt; cdecl;

var
  { set by pjav7 (pjasysc.c); nil: EncodeScan and DecodeScan in Pascal.
    The same bytes, the same coefficients }
  HuffEncodeScan: THuffEncodeScanFn = nil;
  HuffDecodeScan: THuffDecodeScanFn = nil;

{ Parses and decodes. On error, j is half filled and useless. }
function Decompose(const data: TBytes; out j: TJpeg): TJpegResult;
{ The other way in: `raw` is TJpeg.raw as Decompose left it (the file without
  its entropy-coded data). Parses the headers again -- frame, tables, scans
  and their cuts -- and leaves the coefficients allocated at zero, for the
  model to fill. The padding bits are not in raw: the caller sets them. }
function ParseHeaders(const raw: TBytes; out j: TJpeg): TJpegResult;
{ Encodes the scans again with their tables and interleaves them into raw.
  expected: the size the caller expects (the original's, when there is
  one), to allocate the output once; 0 if unknown. }
function Recompose(const j: TJpeg; out data: TBytes; expected: SizeInt = 0): TJpegResult;
{ Decompose + Recompose + compare with the original. The only thing that
  allows a JPEG to be stored as coefficients. }
function VerifyRoundTrip(const data: TBytes; out j: TJpeg): TJpegResult;
{ The same answer and the same j for data, a copy of refData with some bytes
  changed, when ref is what VerifyRoundTrip made of refData: the scans whose
  bytes did not change are taken from ref instead of being decoded and
  encoded again (all of them, or the whole work is done) }
function VerifyRoundTripFrom(const data: TBytes; const ref: TJpeg; const refData: TBytes;
                             out j: TJpeg): TJpegResult;
{ An MPO (CIPA DC-007, Multi-Picture Format): its first image's APP2 "MPF"
  index lists an image of the Multi-Frame class (a panorama, a stereo pair,
  several angles). Ultra HDR and depth maps hang a second image off a JPEG
  with the same index but no such class: those stay JPEGs. }
function IsMpo(const data: TBytes): Boolean;
{ Some scan with a DRI in force and no restarts (TScan.ignoreRi) }
function HasIgnoredRestarts(const j: TJpeg): Boolean;
{ Some scan whose EOB runs end at another number of correction bits than
  libjpeg's (TScan.maxBe) }
function HasCorrectionLimits(const j: TJpeg): Boolean;
{ A bit per coefficient of a block of 64 (zigzag order), set where it is
  not zero. }
function NonzeroMask(cf: PSmallInt): QWord;

implementation

uses Math;

const
  ERROR_NAMES: array[TJpegError] of string = (
    'None',
    'NotJpeg', 'Truncated', 'BadSegment', 'UnexpectedMarker',
    'BadDqt', 'BadDht', 'BadSof', 'RepeatedSof', 'BadSos',
    'MissingTable', 'BadDri', 'TooLarge', 'BadDac', 'BadLse',
    'Unsupported',
    'BadCode', 'CoefOutOfRange', 'BadRst', 'InconsistentPadding',
    'DataAfterScan',
    'NoRoundTrip');

function TJpegResult.Ok: Boolean;
begin Result := err = jeNone; end;

function TJpegResult.Text: string;
begin
  Result := ERROR_NAMES[err];
  if err in [jeUnsupported, jeUnexpectedMarker] then Result := Result + '(' + IntToHex(value, 2) + ')';
  if err <> jeNone then Result := Result + '@' + IntToStr(pos);
end;

function Fail(e: TJpegError; p: Int64; v: Integer = 0): TJpegResult;
begin
  Result := Default(TJpegResult);
  Result.err := e; Result.pos := p; Result.value := v;
end;

function Success: TJpegResult;
begin Result := Fail(jeNone, 0); end;

{ ---------- bits ---------- }

const
  LUT_BITS = 9;

type
  { Reads entropy-coded data through a 64-bit accumulator, a byte at a time,
    unstuffing FF 00 and stopping at a marker. Being ahead, it remembers how
    many input bytes each loaded byte took (1, or 2 for FF 00): aligning puts
    p back exactly at the first byte past the segment. }
  TBitReader = record
    d: TBytes;
    p: SizeInt;
    buf: QWord;
    nbits: Integer;         { valid bits in buf, the oldest ones on top }
    stopped: Boolean;       { hit a marker or the end }
    nload: Integer;
    sizes: array[0..15] of Byte;
    procedure Fill;
    { False when the data ran out: a marker or the end of the file }
    function Bit(out b: Integer): Boolean; inline;
    function Bits(n: Integer; out v: Integer): Boolean; inline;
    { the next n <= 16 bits, zeros past the end of the data }
    function Peek(n: Integer): Integer; inline;
    { Drops the padding bits; padbit = -1 if there were none }
    function Align(out padbit: Integer): Boolean;
  end;

  { Bits go into a 64-bit accumulator and come out as whole bytes (with the
    FF 00 stuffing) once 32 are waiting, and all of them at Align. Bytes put
    directly (markers) and CopyFrom only after an Align. }
  TBitWriter = record
    d: TBytes;
    n: SizeInt;
    acc: QWord;
    nacc: Integer;
    procedure PutByte(b: Byte);
    procedure Bits(v, count: Integer); inline;
    procedure Drain;
    procedure Align(padbit: Integer);
    procedure CopyFrom(const src: TBytes; first, last: SizeInt);
  end;

{ Whether a byte of w is FF: where the same byte of not w is zero. The
  subtraction wraps on purpose. }
{$push}{$Q-}{$R-}
function HasFF(w: QWord): Boolean; inline;
begin
  Result := (((not w) - QWord($0101010101010101)) and w and QWord($8080808080808080)) <> 0;
end;
{$pop}

procedure TBitReader.Fill;
var c: Byte; w: QWord; k, i: Integer;
begin
  { several bytes at once while none of the next 8 is FF (no stuffing, no
    marker): the same bits as one at a time }
  while (nbits <= 48) and not stopped and (p <= Length(d) - 8) do begin
    w := BEtoN(PQWord(@d[p])^);
    if HasFF(w) then Break;
    k := (64 - nbits) shr 3;
    if k > 7 then k := 7;
    buf := (buf shl (8 * k)) or (w shr (64 - 8 * k));
    for i := 0 to k - 1 do sizes[(nload + i) and 15] := 1;
    Inc(nload, k); Inc(p, k); Inc(nbits, 8 * k);
  end;
  while (nbits <= 56) and not stopped do begin
    if p >= Length(d) then begin stopped := True; Exit; end;
    c := d[p];
    if c = $FF then begin
      if (p + 1 >= Length(d)) or (d[p + 1] <> 0) then begin stopped := True; Exit; end;
      Inc(p, 2); sizes[nload and 15] := 2;
    end else begin
      Inc(p); sizes[nload and 15] := 1;
    end;
    Inc(nload);
    buf := (buf shl 8) or c;
    Inc(nbits, 8);
  end;
end;

function TBitReader.Peek(n: Integer): Integer;
begin
  if nbits < n then Fill;
  if nbits >= n then Result := Integer((buf shr (nbits - n)) and ((QWord(1) shl n) - 1))
  else Result := Integer((buf shl (n - nbits)) and ((QWord(1) shl n) - 1));
end;

function TBitReader.Bits(n: Integer; out v: Integer): Boolean;
begin
  v := 0;
  if n = 0 then Exit(True);
  if nbits < n then Fill;
  if nbits < n then Exit(False);
  Dec(nbits, n);
  v := Integer((buf shr nbits) and ((QWord(1) shl n) - 1));
  Result := True;
end;

function TBitReader.Bit(out b: Integer): Boolean;
begin
  Result := Bits(1, b);
end;

function TBitReader.Align(out padbit: Integer): Boolean;
var m, pr, wb, i: Integer;
begin
  padbit := -1;
  Result := True;
  { the bits left of the byte being read are padding; the whole bytes after
    it were read ahead and go back to the input }
  pr := nbits and 7;
  wb := nbits shr 3;
  if pr > 0 then begin
    m := (1 shl pr) - 1;
    if Integer((buf shr (nbits - pr)) and m) = m then padbit := 1
    else if Integer((buf shr (nbits - pr)) and m) = 0 then padbit := 0
    else Result := False;
  end;
  for i := 1 to wb do Dec(p, sizes[(nload - i) and 15]);
  buf := 0; nbits := 0; stopped := False; nload := 0;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
procedure TBitWriter.PutByte(b: Byte);
begin
  if n >= Length(d) then SetLength(d, 2 * Length(d) + 4096);
  d[n] := b; Inc(n);
end;

procedure TBitWriter.Drain;
var b: Byte; w: DWord;
begin
  { at most 6 whole bytes wait, each one twice with its stuffing }
  if n + 16 > Length(d) then SetLength(d, 2 * Length(d) + 4096);
  { the 4 oldest bytes at once when none is FF (Bits drains at 32) }
  if nacc >= 32 then begin
    w := DWord(acc shr (nacc - 32));
    if not HasFF(w) then begin
      PDWord(@d[n])^ := NtoBE(w);
      Inc(n, 4); Dec(nacc, 32);
    end;
  end;
  while nacc >= 8 do begin
    Dec(nacc, 8);
    b := Byte((acc shr nacc) and $FF);
    d[n] := b; Inc(n);
    if b = $FF then begin d[n] := 0; Inc(n); end;
  end;
  acc := acc and ((QWord(1) shl nacc) - 1);
end;

procedure TBitWriter.Bits(v, count: Integer);
begin
  { at most 31 bits wait before adding, and count <= 32 }
  acc := (acc shl count) or (QWord(v) and ((QWord(1) shl count) - 1));
  Inc(nacc, count);
  if nacc >= 32 then Drain;
end;

procedure TBitWriter.Align(padbit: Integer);
begin
  if nacc and 7 > 0 then
    if padbit = 0 then Bits(0, 8 - nacc and 7) else Bits($FF, 8 - nacc and 7);
  Drain;
end;

{$ifdef PJA_FAST}{$pop}{$endif}
procedure TBitWriter.CopyFrom(const src: TBytes; first, last: SizeInt);
var k: SizeInt;
begin
  if last <= first then Exit;
  while n + (last - first) > Length(d) do SetLength(d, 2 * Length(d) + 4096);
  for k := first to last - 1 do begin d[n] := src[k]; Inc(n); end;
end;

{ ---------- Huffman ---------- }

{ Builds a table from the 16 counts and their values (C.2, F.2.2.3). False if
  the codes do not fit in their lengths. }
function BuildHuff(var h: THuff): Boolean;
var l, k, i, cd: Integer;
begin
  FillChar(h.code, SizeOf(h.code), 0);
  FillChar(h.len, SizeOf(h.len), 0);
  cd := 0; k := 0;
  for l := 1 to 16 do begin
    h.valptr[l] := k;
    h.mincode[l] := cd;
    if h.counts[l] = 0 then h.maxcode[l] := -1
    else begin
      for i := 1 to h.counts[l] do begin
        if cd >= (1 shl l) then Exit(False);
        { a repeated value is encoded with the first code; if the original
          used the other one, VerifyRoundTrip sees it }
        if h.len[h.values[k]] = 0 then begin
          h.code[h.values[k]] := cd;
          h.len[h.values[k]] := l;
        end;
        Inc(cd); Inc(k);
      end;
      h.maxcode[l] := cd - 1;
    end;
    cd := cd shl 1;
  end;
  { the fast path, built by running the bit-by-bit decoder on every 9-bit
    pattern: it gives the same answer as that decoder for every table }
  for i := 0 to (1 shl LUT_BITS) - 1 do begin
    h.lut[i] := 0;
    cd := 0;
    for l := 1 to LUT_BITS do begin
      cd := (cd shl 1) or ((i shr (LUT_BITS - l)) and 1);
      if cd <= h.maxcode[l] then begin
        h.lut[i] := (l shl 8) or h.values[h.valptr[l] + cd - h.mincode[l]];
        Break;
      end;
    end;
  end;
  Result := True;
end;

function DecodeSymbol(var rd: TBitReader; const h: THuff; out sym: Integer): TJpegError;
var l, cd, e: Integer;
begin
  sym := 0;
  if rd.nbits < 16 then rd.Fill;
  e := h.lut[rd.Peek(LUT_BITS)];
  if e <> 0 then begin
    { a code of l <= 9 bits; past the real data it is a truncation, as for
      the bit-by-bit decoder }
    l := e shr 8;
    if l > rd.nbits then Exit(jeTruncated);
    Dec(rd.nbits, l);
    sym := e and 255;
    Exit(jeNone);
  end;
  { longer than 9 bits: the first 9 matched nothing. If they were not all
    real data, the bit-by-bit decoder ran out before finding a code. }
  if rd.nbits < LUT_BITS then Exit(jeTruncated);
  cd := rd.Peek(LUT_BITS);
  for l := LUT_BITS + 1 to 16 do begin
    if l > rd.nbits then Exit(jeTruncated);
    cd := (cd shl 1) or Integer((rd.buf shr (rd.nbits - l)) and 1);
    if cd <= h.maxcode[l] then begin
      sym := h.values[h.valptr[l] + cd - h.mincode[l]];
      Dec(rd.nbits, l);
      Exit(jeNone);
    end;
  end;
  Result := jeBadCode;
end;

function Extend(v, s: Integer): Integer;
begin
  if (s > 0) and (v < (1 shl (s - 1))) then Result := v - (1 shl s) + 1 else Result := v;
end;

function Category(v: Integer): Integer; inline;
var a: Integer;
begin
  { not assigning to v: that would keep it from being inlined }
  if v < 0 then a := -v else a := v;
  if a = 0 then Result := 0 else Result := BsrDWord(DWord(a)) + 1;
end;

{ ---------- block traversal ---------- }

type
  TBlockRef = record c: Integer; idx: SizeInt; end;
  TUnit = array[0..MAX_MCU_BLOCKS - 1] of TBlockRef;

function UnitCount(const j: TJpeg; const s: TScan): SizeInt;
begin
  if s.ncomp = 1 then Result := j.comp[s.comp[0]].bwReal * j.comp[s.comp[0]].bhReal
  else Result := SizeInt(j.mcusx) * j.mcusy;
end;

{ The blocks of the unit at column ux, row uy of the scan, in stream order
  (A.2): a block of the component's grid for a single-component scan, an
  MCU otherwise. }
procedure BlocksAt(const j: TJpeg; const s: TScan; ux, uy: SizeInt; out un: TUnit; out n: Integer);
var i, x, y: Integer;
begin
  n := 0;
  if s.ncomp = 1 then begin
    un[0].c := s.comp[0];
    un[0].idx := uy * j.comp[s.comp[0]].bw + ux;
    n := 1;
    Exit;
  end;
  for i := 0 to s.ncomp - 1 do
    with j.comp[s.comp[i]] do
      for y := 0 to v - 1 do
        for x := 0 to h - 1 do begin
          un[n].c := s.comp[i];
          un[n].idx := (uy * v + y) * bw + ux * h + x;
          Inc(n);
        end;
end;

{ How many units a row of the scan has. }
function UnitsPerRow(const j: TJpeg; const s: TScan): SizeInt;
begin
  if s.ncomp = 1 then Result := j.comp[s.comp[0]].bwReal else Result := j.mcusx;
end;

{ The blocks of unit u of the scan. }
procedure BlocksOf(const j: TJpeg; const s: TScan; u: SizeInt; out un: TUnit; out n: Integer);
var w: SizeInt;
begin
  w := UnitsPerRow(j, s);
  BlocksAt(j, s, u mod w, u div w, un, n);
end;

{ ---------- sequential scan ---------- }

function DecodeBlock(var rd: TBitReader; var j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                     var pred: Integer): TJpegError;
var e: TJpegError; t, v, k, rs, r, lu: Integer; base: SizeInt; cf: PSmallInt; ac: ^THuff;
begin
  base := b.idx * 64;
  { the block's bounds checked once; then it is written through a pointer }
  if (base < 0) or (base + 63 >= Length(j.comp[b.c].coef)) then
    raise ERangeError.Create('DecodeBlock: block outside its component');
  cf := @j.comp[b.c].coef[base];
  ac := @s.ac[i];
  e := DecodeSymbol(rd, s.dc[i], t);
  if e <> jeNone then Exit(e);
  if t > j.precision + 3 then Exit(jeBadCode);
  if not rd.Bits(t, v) then Exit(jeTruncated);
  pred := pred + Extend(v, t);
  if (pred < -32767) or (pred > 32767) then Exit(jeCoefOutOfRange);
  cf[0] := pred;
  k := 1;
  while k <= 63 do begin
    { with 26 bits waiting no code (16) and its extra bits (10) can run
      out: the table's answer is all there is to it. Otherwise, and for
      codes longer than the table, DecodeSymbol, with every error it knows }
    if rd.nbits < 26 then rd.Fill;
    lu := 0;
    if rd.nbits >= 26 then lu := ac^.lut[Integer(rd.buf shr (rd.nbits - LUT_BITS)) and ((1 shl LUT_BITS) - 1)];
    if lu <> 0 then begin
      Dec(rd.nbits, lu shr 8);
      rs := lu and 255;
    end else begin
      e := DecodeSymbol(rd, ac^, rs);
      if e <> jeNone then Exit(e);
    end;
    r := rs shr 4; t := rs and 15;
    if t = 0 then begin
      if r <> 15 then Break;   { EOB }
      Inc(k, 16);              { ZRL }
      Continue;
    end;
    if t > j.precision + 2 then Exit(jeBadCode);
    Inc(k, r);
    if k > 63 then Exit(jeBadCode);
    { Bits, without its refill when the bits are already there }
    if rd.nbits >= t then begin
      Dec(rd.nbits, t);
      v := Integer((rd.buf shr rd.nbits) and ((QWord(1) shl t) - 1));
    end else if not rd.Bits(t, v) then Exit(jeTruncated);
    if v < (1 shl (t - 1)) then v := v - (1 shl t) + 1;
    cf[k] := v;
    Inc(k);
  end;
  Result := jeNone;
end;

{ The block as a standard encoder writes it (F.1.2): ZRL only before a nonzero
  coefficient, EOB if zeros are left at the end. }
{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
{ A bit per coefficient of a block (zigzag order), set where it is not zero:
  the encoder then visits only those, instead of asking each of the 63. }
{$ifdef CPUX86_64}
{$asmmode intel}
{ SSE2, part of x86-64: compare 8 coefficients with 0 at a time, pack the
  word masks to bytes, take their top bits. No frame; the argument in the
  first register of the platform's convention; only registers no caller
  keeps anything in (xmm6 and up are the caller's on Win64). }
function NonzeroMask(cf: PSmallInt): QWord; assembler; nostackframe;
asm
  {$ifdef WIN64}
  mov r9, rcx
  {$else}
  mov r9, rdi
  {$endif}
  pxor xmm1, xmm1
  xor rax, rax
  mov rcx, 56
@loop:
  movdqu xmm0, [r9 + rcx * 2]
  pcmpeqw xmm0, xmm1
  packsswb xmm0, xmm0
  pmovmskb r8d, xmm0
  and r8d, 255
  shl rax, 8
  or rax, r8
  sub rcx, 8
  jns @loop
  not rax
end;
{$else}
function NonzeroMask(cf: PSmallInt): QWord;
var k: Integer;
begin
  Result := 0;
  for k := 0 to 63 do
    if cf[k] <> 0 then Result := Result or (QWord(1) shl k);
end;
{$endif}

function EncodeBlock(var wr: TBitWriter; const j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                     var pred: Integer): Boolean;
var k, r, v, t, diff, sym, last: Integer; cf: PSmallInt; dc, ac: ^THuff; nz: QWord;
begin
  { the block and the tables through pointers: the encoder reads data that
    Decompose (or the model) already validated, and BlocksOf keeps base + 63
    inside the component }
  cf := @j.comp[b.c].coef[b.idx * 64];
  dc := @s.dc[i]; ac := @s.ac[i];
  v := cf[0];
  diff := v - pred; pred := v;
  t := Category(diff);
  if dc^.len[t] = 0 then Exit(False);
  { the code and its extra bits in one go: at most 16 + 16 bits }
  wr.Bits((dc^.code[t] shl t) or ((diff - Ord(diff < 0)) and ((1 shl t) - 1)), dc^.len[t] + t);
  { only the nonzero AC coefficients: the run of zeros before each one is
    the gap from the last one }
  nz := NonzeroMask(cf) and not QWord(1);
  last := 0;
  while nz <> 0 do begin
    k := BsfQWord(nz);
    nz := nz and (nz - 1);
    r := k - last - 1;
    last := k;
    v := cf[k];
    while r > 15 do begin
      if ac^.len[$F0] = 0 then Exit(False);
      wr.Bits(ac^.code[$F0], ac^.len[$F0]);
      Dec(r, 16);
    end;
    t := Category(v);
    sym := (r shl 4) or t;
    if ac^.len[sym] = 0 then Exit(False);
    wr.Bits((ac^.code[sym] shl t) or ((v - Ord(v < 0)) and ((1 shl t) - 1)), ac^.len[sym] + t);
  end;
  { zeros after the last nonzero one: an end of block }
  r := 63 - last;
  if r > 0 then begin
    if ac^.len[0] = 0 then Exit(False);
    wr.Bits(ac^.code[0], ac^.len[0]);
  end;
  Result := True;
end;

{$ifdef PJA_FAST}{$pop}{$endif}
{ ---------- progressive scan (G.1.2) ----------

  AC is kept in sign-magnitude, the way libjpeg's encoder treats it:
  refinement adds a bit to the MAGNITUDE. DC is kept in two's complement, the
  way that same encoder shifts and refines it. }

type
  TProgState = record
    eobrun: Integer;
    { pending correction bits, in the encoder (BE in jcphuff.c) }
    be: Integer;
    bebuf: array[0..MAX_BE_LIMIT + 63] of Byte;
    { the decoder, AC refinement: the correction bits of the run it is in
      and its length; the run that ended with the last block, if one did
      (not at a restart); and the bounds of the encoder's TScan.maxBe the
      runs so far allow: the bits a run held and went on, and one less
      than the bits of a run that ended for no other reason }
    runBe, runLen: Integer;
    prevEnded: Boolean;
    prevBe, prevLen: Integer;
    beLow, beHigh: Integer;
  end;

function DecodeDcFirst(var rd: TBitReader; var j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                       var pred: Integer): TJpegError;
var e: TJpegError; t, v: Integer; x: Int64;
begin
  e := DecodeSymbol(rd, s.dc[i], t);
  if e <> jeNone then Exit(e);
  if t > j.precision + 3 then Exit(jeBadCode);
  if not rd.Bits(t, v) then Exit(jeTruncated);
  pred := pred + Extend(v, t);
  x := Int64(pred) * (Int64(1) shl s.al);
  if (pred < -32767) or (pred > 32767) or (x < -32767) or (x > 32767) then Exit(jeCoefOutOfRange);
  j.comp[b.c].coef[b.idx * 64] := x;
  Result := jeNone;
end;

function DecodeDcRefine(var rd: TBitReader; var j: TJpeg; const s: TScan; const b: TBlockRef): TJpegError;
var v: Integer;
begin
  if not rd.Bit(v) then Exit(jeTruncated);
  if v = 1 then j.comp[b.c].coef[b.idx * 64] := j.comp[b.c].coef[b.idx * 64] or SmallInt(1 shl s.al);
  Result := jeNone;
end;

function DecodeAcFirst(var rd: TBitReader; var j: TJpeg; const s: TScan; const b: TBlockRef;
                       var st: TProgState): TJpegError;
var e: TJpegError; k, rs, r, t, v, base: Integer; x: Int64;
begin
  if st.eobrun > 0 then begin Dec(st.eobrun); Exit(jeNone); end;
  base := b.idx * 64;
  k := s.ss;
  while k <= s.se do begin
    e := DecodeSymbol(rd, s.ac[0], rs);
    if e <> jeNone then Exit(e);
    r := rs shr 4; t := rs and 15;
    if t = 0 then begin
      if r = 15 then begin Inc(k, 16); Continue; end;
      st.eobrun := 1 shl r;
      if r > 0 then begin
        if not rd.Bits(r, v) then Exit(jeTruncated);
        Inc(st.eobrun, v);
      end;
      Dec(st.eobrun);
      Break;
    end;
    if t > j.precision + 2 then Exit(jeBadCode);
    Inc(k, r);
    if k > s.se then Exit(jeBadCode);
    if not rd.Bits(t, v) then Exit(jeTruncated);
    x := Int64(Extend(v, t)) * (Int64(1) shl s.al);
    if (x < -32767) or (x > 32767) then Exit(jeCoefOutOfRange);
    j.comp[b.c].coef[base + k] := x;
    Inc(k);
  end;
  Result := jeNone;
end;

{ Adds bit p1 to the magnitude of an already nonzero coefficient. }
function Refine(c, p1: Integer): Integer;
begin
  if c > 0 then Result := c or p1 else Result := -((-c) or p1);
end;

function DecodeAcRefine(var rd: TBitReader; var j: TJpeg; const s: TScan; const b: TBlockRef;
                        var st: TProgState): TJpegError;
var e: TJpegError; k, rs, r, t, v, base, p1, c, bits: Integer; first: Boolean;
begin
  base := b.idx * 64;
  p1 := 1 shl s.al;
  if p1 > 16383 then Exit(jeCoefOutOfRange);
  k := s.ss;
  first := True;
  if st.eobrun = 0 then
    while k <= s.se do begin
      e := DecodeSymbol(rd, s.ac[0], rs);
      if e <> jeNone then Exit(e);
      r := rs shr 4; t := rs and 15;
      if t <> 0 then begin
        if t <> 1 then Exit(jeBadCode);
        if not rd.Bit(v) then Exit(jeTruncated);
        if v = 1 then t := p1 else t := -p1;
      end else if r <> 15 then begin
        st.eobrun := 1 shl r;
        if r > 0 then begin
          if not rd.Bits(r, v) then Exit(jeTruncated);
          Inc(st.eobrun, v);
        end;
        { a run that starts with the block, right after another: that one
          was ended by its correction bits, unless by its length }
        if first and st.prevEnded and (st.prevLen < s.maxEob) and (st.prevBe - 1 < st.beHigh) then
          st.beHigh := st.prevBe - 1;
        st.runBe := 0; st.runLen := st.eobrun;
        Break;
      end;
      first := False;
      { skip r zeros, refining the ones that were already nonzero }
      repeat
        c := j.comp[b.c].coef[base + k];
        if c <> 0 then begin
          if not rd.Bit(v) then Exit(jeTruncated);
          if v = 1 then j.comp[b.c].coef[base + k] := Refine(c, p1);
        end else begin
          Dec(r);
          if r < 0 then Break;
        end;
        Inc(k);
      until k > s.se;
      if t <> 0 then begin
        if k > s.se then Exit(jeBadCode);
        j.comp[b.c].coef[base + k] := t;
      end;
      Inc(k);
    end;
  if st.eobrun > 0 then begin
    bits := 0;
    while k <= s.se do begin
      c := j.comp[b.c].coef[base + k];
      if c <> 0 then begin
        if not rd.Bit(v) then Exit(jeTruncated);
        if v = 1 then j.comp[b.c].coef[base + k] := Refine(c, p1);
        Inc(bits);
      end;
      Inc(k);
    end;
    Dec(st.eobrun);
    Inc(st.runBe, bits);
    if st.eobrun > 0 then begin
      if st.runBe > st.beLow then st.beLow := st.runBe;
    end else begin
      st.prevEnded := True; st.prevBe := st.runBe; st.prevLen := st.runLen;
    end;
  end else st.prevEnded := False;
  Result := jeNone;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
procedure FlushBe(var wr: TBitWriter; var st: TProgState);
var k: Integer;
begin
  for k := 0 to st.be - 1 do wr.Bits(st.bebuf[k], 1);
  st.be := 0;
end;

function FlushEobrun(var wr: TBitWriter; const s: TScan; var st: TProgState): Boolean;
var nb: Integer;
begin
  Result := True;
  if st.eobrun = 0 then Exit;
  nb := Category(st.eobrun) - 1;
  if (nb > 14) or (s.ac[0].len[nb shl 4] = 0) then Exit(False);
  wr.Bits(s.ac[0].code[nb shl 4], s.ac[0].len[nb shl 4]);
  if nb > 0 then wr.Bits(st.eobrun, nb);
  st.eobrun := 0;
  FlushBe(wr, st);
end;

function EmitSymbol(var wr: TBitWriter; const h: THuff; sym: Integer): Boolean;
begin
  if h.len[sym] = 0 then Exit(False);
  wr.Bits(h.code[sym], h.len[sym]);
  Result := True;
end;

function EncodeDcFirst(var wr: TBitWriter; const j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                       var pred: Integer): Boolean;
var v, diff, t: Integer;
begin
  v := SarLongint(j.comp[b.c].coef[b.idx * 64], s.al);
  diff := v - pred; pred := v;
  t := Category(diff);
  if not EmitSymbol(wr, s.dc[i], t) then Exit(False);
  if t > 0 then wr.Bits(diff - Ord(diff < 0), t);
  Result := True;
end;

function EncodeAcFirst(var wr: TBitWriter; const j: TJpeg; const s: TScan; const b: TBlockRef;
                       var st: TProgState): Boolean;
var base, k, r, v, t: Integer; neg: Boolean;
begin
  base := b.idx * 64;
  r := 0;
  for k := s.ss to s.se do begin
    v := j.comp[b.c].coef[base + k];
    neg := v < 0;
    v := Abs(v) shr s.al;
    if v = 0 then begin Inc(r); Continue; end;
    if not FlushEobrun(wr, s, st) then Exit(False);
    while r > 15 do begin
      if not EmitSymbol(wr, s.ac[0], $F0) then Exit(False);
      Dec(r, 16);
    end;
    t := Category(v);
    if not EmitSymbol(wr, s.ac[0], (r shl 4) or t) then Exit(False);
    if neg then wr.Bits(-v - 1, t) else wr.Bits(v, t);
    r := 0;
  end;
  if r > 0 then begin
    Inc(st.eobrun);
    if st.eobrun = s.maxEob then if not FlushEobrun(wr, s, st) then Exit(False);
  end;
  Result := True;
end;

function EncodeAcRefine(var wr: TBitWriter; const j: TJpeg; const s: TScan; const b: TBlockRef;
                        var st: TProgState): Boolean;
var base, k, r, v, eob, br, ibr: Integer; absv: array[0..63] of Integer;
    brbuf: array[0..63] of Byte;
begin
  base := b.idx * 64;
  eob := 0;
  for k := s.ss to s.se do begin
    absv[k] := Abs(Integer(j.comp[b.c].coef[base + k])) shr s.al;
    if absv[k] = 1 then eob := k;
  end;
  r := 0; br := 0;
  FillChar(brbuf, SizeOf(brbuf), 0);
  for k := s.ss to s.se do begin
    v := absv[k];
    if v = 0 then begin Inc(r); Continue; end;
    while (r > 15) and (k <= eob) do begin
      if not FlushEobrun(wr, s, st) then Exit(False);
      if not EmitSymbol(wr, s.ac[0], $F0) then Exit(False);
      Dec(r, 16);
      for ibr := 0 to br - 1 do wr.Bits(brbuf[ibr], 1);
      br := 0;
    end;
    if v > 1 then begin
      { already nonzero: its correction bit waits for the next symbol }
      brbuf[br] := v and 1; Inc(br);
      Continue;
    end;
    if not FlushEobrun(wr, s, st) then Exit(False);
    if not EmitSymbol(wr, s.ac[0], (r shl 4) or 1) then Exit(False);
    wr.Bits(Ord(j.comp[b.c].coef[base + k] > 0), 1);
    for ibr := 0 to br - 1 do wr.Bits(brbuf[ibr], 1);
    br := 0; r := 0;
  end;
  if (r > 0) or (br > 0) then begin
    Inc(st.eobrun);
    for ibr := 0 to br - 1 do begin st.bebuf[st.be] := brbuf[ibr]; Inc(st.be); end;
    if (st.eobrun = s.maxEob) or (st.be > s.maxBe) then
      if not FlushEobrun(wr, s, st) then Exit(False);
  end;
  Result := True;
end;

{$ifdef PJA_FAST}{$pop}{$endif}
{ The position within the scan of a block's component. }
function IndexInScan(const s: TScan; c: Integer): Integer;
var i: Integer;
begin
  for i := 0 to s.ncomp - 1 do if s.comp[i] = c then Exit(i);
  Result := -1;
end;

{ ---------- arithmetic coding (QM coder, T.81 Annex D, F.1.4, G.1.3) ----------

  What libjpeg does, bit for bit: the decoder (jdarith.c) and the encoder with
  its flush (jcarith.c), which is what has to come out again. This section is
  based in part on the work of the Independent JPEG Group (see NOTICE).
  Statistics are one byte per bin: the state in the low 7 bits, the more
  probable symbol in bit 7. }

const
  { Table D.3: Qe << 16 | next state if MPS << 8 | switch << 7 | next state if
    LPS. Generated from the table in libjpeg-turbo's jaricom.c, not typed. }
  QE_TABLE: array[0..113] of LongInt = (
    $5a1d0181, $2586020e, $11140310, $080b0412, $03d80514, $01da0617, $00e50719, $006f081c,
    $0036091e, $001a0a21, $000d0b23, $00060c09, $00030d0a, $00010d0c, $5a7f0f8f, $3f251024,
    $2cf21126, $207c1227, $17b91328, $1182142a, $0cef152b, $09a1162d, $072f172e, $055c1830,
    $04061931, $03031a33, $02401b34, $01b11c36, $01441d38, $00f51e39, $00b71f3b, $008a203c,
    $0068213e, $004e223f, $003b2320, $002c0921, $5ae125a5, $484c2640, $3a0d2741, $2ef12843,
    $261f2944, $1f332a45, $19a82b46, $15182c48, $11772d49, $0e742e4a, $0bfb2f4b, $09f8304d,
    $0861314e, $0706324f, $05cd3330, $04de3432, $040f3532, $03633633, $02d43734, $025c3835,
    $01f83936, $01a43a37, $01603b38, $01253c39, $00f63d3a, $00cb3e3b, $00ab3f3d, $008f203d,
    $5b1241c1, $4d044250, $412c4351, $37d84452, $2fe84553, $293c4654, $23794756, $1edf4857,
    $1aa94957, $174e4a48, $14244b48, $119c4c4a, $0f6b4d4a, $0d514e4b, $0bb64f4d, $0a40304d,
    $583251d0, $4d1c5258, $438e5359, $3bdd545a, $34ee555b, $2eae565c, $299a575d, $25164756,
    $557059d8, $4ca95a5f, $44d95b60, $3e225c61, $38245d63, $32b45e63, $2e17565d, $56a860df,
    $4f466165, $47e56266, $41cf6367, $3c3d6468, $375e5d63, $52316669, $4c0f676a, $4639686b,
    $415e6367, $56276ae9, $50e76b6c, $4b85676d, $55976d6e, $504f6b6f, $5a106fee, $55226d70,
    $59eb6ff0, $5a1d7171);

type
  TArithStats = record
    dc: array[0..3, 0..63] of Byte;
    ac: array[0..3, 0..255] of Byte;
    { the fixed bin of probability 1/2: state 113 loops on itself }
    fixed: Byte;
    dcContext: array[0..3] of Integer;
    lastDc: array[0..3] of Integer;
  end;

  { Reads one restart interval: its bytes and then, as libjpeg past a marker,
    zeros. }
  TQmDecoder = record
    d: TBytes;
    p, last: SizeInt;
    c, a: Int64;
    ct: Integer;
    unread: Boolean;
    procedure Init(const data: TBytes; first, stop: SizeInt);
    function NextByte: Integer; inline;
    function Decode(var st: Byte): Integer;
  end;

  TQmEncoder = record
    c, a: Int64;
    ct, buffer, sc, zc: Integer;
    procedure Init;
    procedure Emit(var wr: TBitWriter; v: Integer); inline;
    procedure Encode(var wr: TBitWriter; var st: Byte; val: Integer);
    procedure Finish(var wr: TBitWriter);
  end;

procedure TQmDecoder.Init(const data: TBytes; first, stop: SizeInt);
begin
  d := data; p := first; last := stop;
  c := 0; a := 0; ct := -16; unread := False;
end;

function TQmDecoder.NextByte: Integer;
begin
  if p < last then begin Result := d[p]; Inc(p); end else Result := 0;
end;

function TQmDecoder.Decode(var st: Byte): Integer;
var sv, data: Integer; qe, temp: Int64; nl, nm: Integer;
begin
  while a < $8000 do begin
    Dec(ct);
    if ct < 0 then begin
      if unread then data := 0
      else begin
        data := NextByte;
        if data = $FF then begin
          repeat data := NextByte; until data <> $FF;
          if data = 0 then data := $FF
          else begin unread := True; data := 0; end;
        end;
      end;
      c := (c shl 8) or data;
      Inc(ct, 8);
      if ct < 0 then begin
        Inc(ct);
        if ct = 0 then a := $8000;
      end;
    end;
    a := a shl 1;
  end;
  sv := st;
  qe := QE_TABLE[sv and $7F];
  nl := qe and $FF; qe := qe shr 8;
  nm := qe and $FF; qe := qe shr 8;
  temp := a - qe;
  a := temp;
  temp := temp shl ct;
  if c >= temp then begin
    c := c - temp;
    if a < qe then begin a := qe; st := (sv and $80) xor nm; end
    else begin a := qe; st := (sv and $80) xor nl; sv := sv xor $80; end;
  end else if a < $8000 then begin
    if a < qe then begin st := (sv and $80) xor nl; sv := sv xor $80; end
    else st := (sv and $80) xor nm;
  end;
  Result := sv shr 7;
end;

procedure TQmEncoder.Init;
begin
  c := 0; a := $10000; ct := 11; buffer := -1; sc := 0; zc := 0;
end;

procedure TQmEncoder.Emit(var wr: TBitWriter; v: Integer);
begin
  wr.PutByte(Byte(v));
end;

procedure TQmEncoder.Encode(var wr: TBitWriter; var st: Byte; val: Integer);
var sv, nl, nm, temp: Integer; qe: Int64;
begin
  sv := st;
  qe := QE_TABLE[sv and $7F];
  nl := qe and $FF; qe := qe shr 8;
  nm := qe and $FF; qe := qe shr 8;
  a := a - qe;
  if val <> (sv shr 7) then begin
    if a >= qe then begin c := c + a; a := qe; end;
    st := (sv and $80) xor nl;
  end else begin
    if a >= $8000 then Exit;
    if a < qe then begin c := c + a; a := qe; end;
    st := (sv and $80) xor nm;
  end;
  repeat
    a := a shl 1; c := c shl 1;
    Dec(ct);
    if ct = 0 then begin
      temp := Integer(c shr 19);
      if temp > $FF then begin
        if buffer >= 0 then begin
          while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
          Emit(wr, buffer + 1);
          if buffer + 1 = $FF then Emit(wr, 0);
        end;
        Inc(zc, sc); sc := 0;
        buffer := temp and $FF;
      end else if temp = $FF then
        Inc(sc)
      else begin
        if buffer = 0 then Inc(zc)
        else if buffer >= 0 then begin
          while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
          Emit(wr, buffer);
        end;
        if sc > 0 then begin
          while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
          repeat Emit(wr, $FF); Emit(wr, 0); Dec(sc); until sc = 0;
        end;
        buffer := temp and $FF;
      end;
      c := c and $7FFFF;
      Inc(ct, 8);
    end;
  until a >= $8000;
end;

{ jcarith.c finish_pass: the shortest tail that still decodes, and trailing
  zero bytes are never written }
procedure TQmEncoder.Finish(var wr: TBitWriter);
var temp: Int64;
begin
  temp := (a - 1 + c) and Int64($FFFF0000);
  if temp < c then c := temp + $8000 else c := temp;
  c := c shl ct;
  if (c and Int64($F8000000)) <> 0 then begin
    if buffer >= 0 then begin
      while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
      Emit(wr, buffer + 1);
      if buffer + 1 = $FF then Emit(wr, 0);
    end;
    Inc(zc, sc); sc := 0;
  end else begin
    if buffer = 0 then Inc(zc)
    else if buffer >= 0 then begin
      while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
      Emit(wr, buffer);
    end;
    if sc > 0 then begin
      while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
      repeat Emit(wr, $FF); Emit(wr, 0); Dec(sc); until sc = 0;
    end;
  end;
  if (c and $7FFF800) <> 0 then begin
    while zc > 0 do begin Emit(wr, 0); Dec(zc); end;
    Emit(wr, Integer((c shr 19) and $FF));
    if ((c shr 19) and $FF) = $FF then Emit(wr, 0);
    if (c and $7F800) <> 0 then begin
      Emit(wr, Integer((c shr 11) and $FF));
      if ((c shr 11) and $FF) = $FF then Emit(wr, 0);
    end;
  end;
end;

{ At the start of a scan and of every restart interval (start_pass and
  process_restart): the bins of the tables this scan uses go back to zero. }
procedure ResetStats(var st: TArithStats; const j: TJpeg; const s: TScan);
var i: Integer;
begin
  for i := 0 to s.ncomp - 1 do begin
    if not j.progressive or ((s.ss = 0) and (s.ah = 0)) then begin
      FillChar(st.dc[s.td[i]], 64, 0);
      st.lastDc[i] := 0; st.dcContext[i] := 0;
    end;
    if not j.progressive or (s.se > 0) then FillChar(st.ac[s.ta[i]], 256, 0);
  end;
  st.fixed := 113;
end;

{ A DC difference (F.1.4.1 / F.2.4.1), shared by sequential and DC-first. }
function ArithDecodeDcDiff(var qd: TQmDecoder; var st: TArithStats; const s: TScan; i: Integer;
                           out v: Integer): TJpegError;
var t, sign, m, x: Integer;
begin
  v := 0;
  t := s.td[i];
  x := st.dcContext[i];
  if qd.Decode(st.dc[t, x]) = 0 then begin st.dcContext[i] := 0; Exit(jeNone); end;
  sign := qd.Decode(st.dc[t, x + 1]);
  x := x + 2 + sign;
  m := qd.Decode(st.dc[t, x]);
  if m <> 0 then begin
    x := 20;
    while qd.Decode(st.dc[t, x]) <> 0 do begin
      m := m shl 1;
      { a magnitude of 2^15 does not exist: only garbage gets here }
      if m = $8000 then Exit(jeBadCode);
      Inc(x);
    end;
  end;
  if m < ((1 shl s.dcL[i]) shr 1) then st.dcContext[i] := 0
  else if m > ((1 shl s.dcU[i]) shr 1) then st.dcContext[i] := 12 + sign * 4
  else st.dcContext[i] := 4 + sign * 4;
  v := m;
  x := x + 14;
  m := m shr 1;
  while m > 0 do begin
    if qd.Decode(st.dc[t, x]) <> 0 then v := v or m;
    m := m shr 1;
  end;
  v := v + 1;
  if sign <> 0 then v := -v;
  Result := jeNone;
end;

procedure ArithEncodeDcDiff(var wr: TBitWriter; var qe: TQmEncoder; var st: TArithStats; const s: TScan;
                            i, v: Integer);
var t, x, m, v2: Integer;
begin
  t := s.td[i];
  x := st.dcContext[i];
  if v = 0 then begin qe.Encode(wr, st.dc[t, x], 0); st.dcContext[i] := 0; Exit; end;
  qe.Encode(wr, st.dc[t, x], 1);
  if v > 0 then begin qe.Encode(wr, st.dc[t, x + 1], 0); x := x + 2; st.dcContext[i] := 4; end
  else begin v := -v; qe.Encode(wr, st.dc[t, x + 1], 1); x := x + 3; st.dcContext[i] := 8; end;
  m := 0;
  v := v - 1;
  if v <> 0 then begin
    qe.Encode(wr, st.dc[t, x], 1);
    m := 1; v2 := v; x := 20;
    v2 := v2 shr 1;
    while v2 <> 0 do begin qe.Encode(wr, st.dc[t, x], 1); m := m shl 1; Inc(x); v2 := v2 shr 1; end;
  end;
  qe.Encode(wr, st.dc[t, x], 0);
  if m < ((1 shl s.dcL[i]) shr 1) then st.dcContext[i] := 0
  else if m > ((1 shl s.dcU[i]) shr 1) then st.dcContext[i] := st.dcContext[i] + 8;
  x := x + 14;
  m := m shr 1;
  while m <> 0 do begin
    qe.Encode(wr, st.dc[t, x], Ord((m and v) <> 0));
    m := m shr 1;
  end;
end;

{ An AC magnitude after its sign (F.1.4.4.1.2-3), from bin x of table t. }
function ArithDecodeAcMag(var qd: TQmDecoder; var st: TArithStats; t, k, kx: Integer; x: Integer;
                          out v: Integer): TJpegError;
var m: Integer;
begin
  v := 0;
  m := qd.Decode(st.ac[t, x]);
  if m <> 0 then
    if qd.Decode(st.ac[t, x]) <> 0 then begin
      m := m shl 1;
      if k <= kx then x := 189 else x := 217;
      while qd.Decode(st.ac[t, x]) <> 0 do begin
        m := m shl 1;
        if m = $8000 then Exit(jeBadCode);
        Inc(x);
      end;
    end;
  v := m;
  x := x + 14;
  m := m shr 1;
  while m > 0 do begin
    if qd.Decode(st.ac[t, x]) <> 0 then v := v or m;
    m := m shr 1;
  end;
  v := v + 1;
  Result := jeNone;
end;

procedure ArithEncodeAcMag(var wr: TBitWriter; var qe: TQmEncoder; var st: TArithStats; t, k, kx, x, v: Integer);
var m, v2: Integer;
begin
  m := 0;
  v := v - 1;
  if v <> 0 then begin
    qe.Encode(wr, st.ac[t, x], 1);
    m := 1; v2 := v shr 1;
    if v2 <> 0 then begin
      qe.Encode(wr, st.ac[t, x], 1);
      m := m shl 1;
      if k <= kx then x := 189 else x := 217;
      v2 := v2 shr 1;
      while v2 <> 0 do begin qe.Encode(wr, st.ac[t, x], 1); m := m shl 1; Inc(x); v2 := v2 shr 1; end;
    end;
  end;
  qe.Encode(wr, st.ac[t, x], 0);
  x := x + 14;
  m := m shr 1;
  while m <> 0 do begin
    qe.Encode(wr, st.ac[t, x], Ord((m and v) <> 0));
    m := m shr 1;
  end;
end;

{ The DC kept by libjpeg is 16 bits, wrapping: back to a signed value. }
function Wrap16(v: Integer): Integer; inline;
begin
  v := v and $FFFF;
  if v >= $8000 then Result := v - $10000 else Result := v;
end;

function ArithDecodeBlock(var qd: TQmDecoder; var st: TArithStats; var j: TJpeg; const s: TScan;
                          const b: TBlockRef): TJpegError;
var i, t, k, x, sign, v, p1, kex, c, base, ss, se: Integer; e: TJpegError; q: Int64;
begin
  i := IndexInScan(s, b.c);
  base := b.idx * 64;
  if not j.progressive or ((s.ss = 0) and (s.ah = 0)) then begin
    e := ArithDecodeDcDiff(qd, st, s, i, v);
    if e <> jeNone then Exit(e);
    st.lastDc[i] := Wrap16(st.lastDc[i] + v);
    q := Int64(st.lastDc[i]) * (Int64(1) shl s.al);
    if (q < -32767) or (q > 32767) then Exit(jeCoefOutOfRange);
    j.comp[b.c].coef[base] := q;
    if j.progressive then Exit(jeNone);
  end else if s.ss = 0 then begin
    { DC refinement }
    if qd.Decode(st.fixed) <> 0 then
      j.comp[b.c].coef[base] := j.comp[b.c].coef[base] or SmallInt(1 shl s.al);
    Exit(jeNone);
  end;
  if j.progressive then begin ss := s.ss; se := s.se; end else begin ss := 1; se := 63; end;
  t := s.ta[i];
  if not j.progressive or (s.ah = 0) then begin
    { sequential AC, or progressive AC first }
    k := ss;
    while k <= se do begin
      x := 3 * (k - 1);
      if qd.Decode(st.ac[t, x]) <> 0 then Break;                { EOB }
      while qd.Decode(st.ac[t, x + 1]) = 0 do begin
        Inc(k);
        if k > se then Exit(jeBadCode);
        x := x + 3;
      end;
      sign := qd.Decode(st.fixed);
      e := ArithDecodeAcMag(qd, st, t, k, s.acK[i], x + 2, v);
      if e <> jeNone then Exit(e);
      if sign <> 0 then v := -v;
      q := Int64(v) * (Int64(1) shl s.al);
      if (q < -32767) or (q > 32767) then Exit(jeCoefOutOfRange);
      j.comp[b.c].coef[base + k] := q;
      Inc(k);
    end;
    Exit(jeNone);
  end;
  { progressive AC refinement }
  p1 := 1 shl s.al;
  kex := se;
  while (kex > 0) and (j.comp[b.c].coef[base + kex] = 0) do Dec(kex);
  k := ss;
  while k <= se do begin
    x := 3 * (k - 1);
    if k > kex then
      if qd.Decode(st.ac[t, x]) <> 0 then Break;                { EOB }
    while True do begin
      c := j.comp[b.c].coef[base + k];
      if c <> 0 then begin
        if qd.Decode(st.ac[t, x + 2]) <> 0 then begin
          if c < 0 then c := c - p1 else c := c + p1;
          if (c < -32767) or (c > 32767) then Exit(jeCoefOutOfRange);
          j.comp[b.c].coef[base + k] := c;
        end;
        Break;
      end;
      if qd.Decode(st.ac[t, x + 1]) <> 0 then begin
        if qd.Decode(st.fixed) <> 0 then j.comp[b.c].coef[base + k] := -p1
        else j.comp[b.c].coef[base + k] := p1;
        Break;
      end;
      x := x + 3;
      Inc(k);
      if k > se then Exit(jeBadCode);
    end;
    Inc(k);
  end;
  Result := jeNone;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
{ The magnitude of a coefficient >> al, and its sign. }
function ShiftedAbs(v, al: Integer; out neg: Boolean): Integer; inline;
begin
  neg := v < 0;
  if neg then v := -v;
  Result := v shr al;
end;

function ArithEncodeBlock(var wr: TBitWriter; var qe: TQmEncoder; var st: TArithStats; const j: TJpeg;
                          const s: TScan; const b: TBlockRef): Boolean;
var i, t, k, ke, kex, x, v, ss, se, al: Integer; neg: Boolean; cf: PSmallInt;
begin
  i := IndexInScan(s, b.c);
  cf := @j.comp[b.c].coef[b.idx * 64];
  if not j.progressive or ((s.ss = 0) and (s.ah = 0)) then begin
    v := SarLongint(cf[0], s.al);
    ArithEncodeDcDiff(wr, qe, st, s, i, v - st.lastDc[i]);
    st.lastDc[i] := v;
    if j.progressive then Exit(True);
  end else if s.ss = 0 then begin
    qe.Encode(wr, st.fixed, SarLongint(cf[0], s.al) and 1);
    Exit(True);
  end;
  if j.progressive then begin ss := s.ss; se := s.se; al := s.al; end
  else begin ss := 1; se := 63; al := 0; end;
  t := s.ta[i];
  { the last coefficient that is nonzero in this pass }
  ke := se;
  while (ke > 0) and (ShiftedAbs(cf[ke], al, neg) = 0) do Dec(ke);
  if not j.progressive or (s.ah = 0) then begin
    k := ss;
    while k <= ke do begin
      x := 3 * (k - 1);
      qe.Encode(wr, st.ac[t, x], 0);
      while True do begin
        v := ShiftedAbs(cf[k], al, neg);
        if v <> 0 then begin
          qe.Encode(wr, st.ac[t, x + 1], 1);
          qe.Encode(wr, st.fixed, Ord(neg));
          Break;
        end;
        qe.Encode(wr, st.ac[t, x + 1], 0);
        x := x + 3; Inc(k);
      end;
      ArithEncodeAcMag(wr, qe, st, t, k, s.acK[i], x + 2, v);
      Inc(k);
    end;
  end else begin
    { refinement: up to kex the coefficient was already nonzero (bit above al) }
    kex := ke;
    while (kex > 0) and (ShiftedAbs(cf[kex], s.ah, neg) = 0) do Dec(kex);
    k := ss;
    while k <= ke do begin
      x := 3 * (k - 1);
      if k > kex then qe.Encode(wr, st.ac[t, x], 0);
      while True do begin
        v := ShiftedAbs(cf[k], al, neg);
        if v <> 0 then begin
          if v shr 1 <> 0 then qe.Encode(wr, st.ac[t, x + 2], v and 1)
          else begin
            qe.Encode(wr, st.ac[t, x + 1], 1);
            qe.Encode(wr, st.fixed, Ord(neg));
          end;
          Break;
        end;
        qe.Encode(wr, st.ac[t, x + 1], 0);
        x := x + 3; Inc(k);
      end;
      Inc(k);
    end;
  end;
  if k <= se then qe.Encode(wr, st.ac[t, 3 * (k - 1)], 1);   { EOB }
  Result := True;
end;
{$ifdef PJA_FAST}{$pop}{$endif}

{ ---------- scan ---------- }

function IsRst(m: Byte): Boolean;
begin Result := (m >= $D0) and (m <= $D7); end;

function DecodeUnitBlock(var rd: TBitReader; var j: TJpeg; const s: TScan; const b: TBlockRef;
                         var pred: array of Integer; var st: TProgState): TJpegError;
var i: Integer;
begin
  i := IndexInScan(s, b.c);
  if not j.progressive then Result := DecodeBlock(rd, j, s, i, b, pred[i])
  else if s.ss = 0 then begin
    if s.ah = 0 then Result := DecodeDcFirst(rd, j, s, i, b, pred[i])
    else Result := DecodeDcRefine(rd, j, s, b);
  end
  else if s.ah = 0 then Result := DecodeAcFirst(rd, j, s, b, st)
  else Result := DecodeAcRefine(rd, j, s, b, st);
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function EncodeUnitBlock(var wr: TBitWriter; const j: TJpeg; const s: TScan; const b: TBlockRef;
                         var pred: array of Integer; var st: TProgState): Boolean;
var i: Integer;
begin
  i := IndexInScan(s, b.c);
  if not j.progressive then Result := EncodeBlock(wr, j, s, i, b, pred[i])
  else if s.ss = 0 then begin
    if s.ah = 0 then Result := EncodeDcFirst(wr, j, s, i, b, pred[i])
    else begin
      wr.Bits(SarLongint(j.comp[b.c].coef[b.idx * 64], s.al) and 1, 1);
      Result := True;
    end;
  end
  else if s.ah = 0 then Result := EncodeAcFirst(wr, j, s, b, st)
  else Result := EncodeAcRefine(wr, j, s, b, st);
end;

{$ifdef PJA_FAST}{$pop}{$endif}
{ An arithmetic scan: each restart interval is decoded from its own bytes,
  which end at the next marker. }
function DecodeScanArith(const data: TBytes; first: SizeInt; var j: TJpeg; var s: TScan;
                         out last: SizeInt): TJpegResult;
var qd: TQmDecoder; st: TArithStats; total, u, u0, p, stop: SizeInt; un: TUnit; n, i, rst: Integer;
    e: TJpegError;

  { the end of the entropy-coded bytes from p on: the first FF that is not
    FF 00 (fill bytes FF FF ... included in the marker) }
  function SegmentEnd(from: SizeInt): SizeInt;
  var q, r: SizeInt;
  begin
    q := from;
    while q < Length(data) do begin
      if data[q] = $FF then begin
        r := q + 1;
        while (r < Length(data)) and (data[r] = $FF) do Inc(r);
        if (r < Length(data)) and (data[r] = 0) then begin q := r + 1; Continue; end;
        Exit(q);
      end;
      Inc(q);
    end;
    Result := Length(data);
  end;

begin
  last := first;
  s.padbit := 1;
  st := Default(TArithStats);
  total := UnitCount(j, s);
  p := first; rst := 0; u0 := 0;
  while u0 < total do begin
    stop := SegmentEnd(p);
    qd.Init(data, p, stop);
    ResetStats(st, j, s);
    u := u0;
    while (u < total) and ((s.ri = 0) or (u < u0 + s.ri)) do begin
      BlocksOf(j, s, u, un, n);
      for i := 0 to n - 1 do begin
        e := ArithDecodeBlock(qd, st, j, s, un[i]);
        if e <> jeNone then Exit(Fail(e, qd.p));
      end;
      Inc(u);
    end;
    if u < total then begin
      if (stop + 1 >= Length(data)) or (data[stop] <> $FF) or (data[stop + 1] <> $D0 + (rst and 7)) then
        Exit(Fail(jeBadRst, stop));
      p := stop + 2; Inc(rst);
    end else p := stop;
    u0 := u;
  end;
  { what follows must be a marker, or the end; extra RSTs stay in raw }
  if p < Length(data) then
    if p + 1 >= Length(data) then Exit(Fail(jeDataAfterScan, p));
  last := p;
  Result := Success;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function EncodeScanArith(var wr: TBitWriter; const j: TJpeg; const s: TScan): Boolean;
var qe: TQmEncoder; st: TArithStats; total, u: SizeInt; un: TUnit; n, i, rst: Integer;
begin
  st := Default(TArithStats);
  total := UnitCount(j, s);
  rst := 0;
  qe.Init; ResetStats(st, j, s);
  for u := 0 to total - 1 do begin
    if (s.ri > 0) and (u > 0) and (u mod s.ri = 0) then begin
      qe.Finish(wr);
      wr.PutByte($FF); wr.PutByte($D0 + (rst and 7));
      Inc(rst);
      qe.Init; ResetStats(st, j, s);
    end;
    BlocksOf(j, s, u, un, n);
    for i := 0 to n - 1 do
      if not ArithEncodeBlock(wr, qe, st, j, s, un[i]) then Exit(False);
  end;
  qe.Finish(wr);
  Result := True;
end;
{$ifdef PJA_FAST}{$pop}{$endif}

{ Decodes from data[first]; last ends at the first byte past the
  entropy-coded data. }
{ The blocks a sequential scan walks, for HuffEncodeScan and
  HuffDecodeScan: False if one of them would fall outside its component }
function ScanSlots(const j: TJpeg; const s: TScan; progressive: Boolean; out unitsX, total, nslot: SizeInt;
                   out bws, hs, vs, preds: array of SizeInt; out coefs: array of PSmallInt): Boolean;
var i, ci: Integer; unitsY, last: SizeInt;
begin
  Result := False;
  nslot := s.ncomp;
  total := UnitCount(j, s);
  unitsX := UnitsPerRow(j, s);
  if (j.progressive and not progressive) or (nslot < 1) or (nslot > 4) or (total <= 0) or (unitsX <= 0) then Exit;
  { a progressive scan's band and bits, inside what the C side takes }
  if j.progressive and ((s.al < 0) or (s.al > 15) or (s.ah < 0) or
                        ((s.ss > 0) and ((s.se < s.ss) or (s.se > 63))) or (s.ss < 0)) then Exit;
  unitsY := (total + unitsX - 1) div unitsX;
  for i := 0 to nslot - 1 do begin
    ci := s.comp[i];
    if (ci < 0) or (ci > High(j.comp)) then Exit;
    bws[i] := j.comp[ci].bw;
    if nslot = 1 then begin hs[i] := 1; vs[i] := 1; end
    else begin hs[i] := j.comp[ci].h; vs[i] := j.comp[ci].v; end;
    if (hs[i] < 1) or (vs[i] < 1) or (bws[i] < 1) or (unitsX * hs[i] > bws[i]) then Exit;
    { the last block the scan touches, inside the component }
    last := (unitsY * vs[i] - 1) * bws[i] + unitsX * hs[i] - 1;
    if (last + 1) * 64 > Length(j.comp[ci].coef) then Exit;
    coefs[i] := @j.comp[ci].coef[0];
    preds[i] := IndexInScan(s, ci);
    if preds[i] < 0 then Exit;
  end;
  Result := True;
end;

{ A sequential scan through HuffDecodeScan: False if it is not there, if
  some block would fall outside its component, or if the scan is not one
  it reads to the end (then DecodeScan reads it, from its start) }
function DecodeScanC(const data: TBytes; first: SizeInt; var j: TJpeg; const s: TScan;
                     out hs: THuffDecScan): Integer;
{ 0: read to the end; 1: hs says where to go on; 2: not taken }
var i: Integer; bws, hh, vv, preds: array[0..3] of SizeInt; coefs: array[0..3] of PSmallInt;
begin
  Result := 2;
  hs := Default(THuffDecScan);
  if not Assigned(HuffDecodeScan) or (first < 0) or (first > Length(data)) then Exit;
  if not ScanSlots(j, s, True, hs.unitsX, hs.total, hs.nslot, bws, hh, vv, preds, coefs) then Exit;
  for i := 0 to hs.nslot - 1 do
    with hs.slot[i] do begin
      coef := coefs[i]; bw := bws[i]; h := hh[i]; v := vv[i]; predIdx := preds[i];
      { the tables of the scan's first entry for the component, as
        DecodeUnitBlock takes them (IndexInScan) }
      dcHuff := @s.dc[preds[i]]; acHuff := @s.ac[preds[i]];
    end;
  if Length(data) > 0 then hs.d := @data[0];
  hs.len := Length(data); hs.first := first;
  hs.ri := s.ri; hs.precision := j.precision;
  hs.progressive := Ord(j.progressive);
  hs.ss := s.ss; hs.se := s.se; hs.ah := s.ah; hs.al := s.al; hs.maxEob := s.maxEob;
  Result := HuffDecodeScan(hs);
end;

function DecodeScan(const data: TBytes; first: SizeInt; var j: TJpeg; var s: TScan;
                    out last: SizeInt): TJpegResult;
var rd: TBitReader; total, u, u0, w, ux, uy: SizeInt; un: TUnit; n, i, pb, rst: Integer;
    pred: array[0..3] of Integer; e: TJpegError; st: TProgState; hs: THuffDecScan;

  { AC refinement: libjpeg's limit if the runs allow it, else the smallest
    that does (Photoshop's, about 256). Runs no limit explains stay with
    libjpeg's, and the rebuild will tell }
  procedure TakeBe(beLow, beHigh: Integer);
  begin
    if j.progressive and (s.ah > 0) and (s.ss > 0) and
       ((beLow > LIBJPEG_MAX_BE) or (beHigh < LIBJPEG_MAX_BE)) and
       (beLow <= beHigh) and (beLow <= MAX_BE_LIMIT) then
      s.maxBe := beLow;
  end;

  function Padding: Boolean;
  begin
    if not rd.Align(pb) then Exit(False);
    if pb >= 0 then begin
      if s.padbit < 0 then s.padbit := pb
      else if s.padbit <> pb then Exit(False);
    end;
    Result := True;
  end;

begin
  last := first;
  rd := Default(TBitReader);
  rd.d := data; rd.p := first;
  s.padbit := -1;
  FillChar(pred, SizeOf(pred), 0);
  st := Default(TProgState);
  st.beHigh := High(Integer);
  total := UnitCount(j, s);
  w := UnitsPerRow(j, s); ux := 0; uy := 0;
  rst := 0; u0 := 0;
  case DecodeScanC(data, first, j, s, hs) of
    0: begin
         s.padbit := hs.padbit;
         TakeBe(hs.beLow, hs.beHigh);
         last := hs.last;
         Exit(Success);
       end;
    1: begin
         { from the start of the unit pjasysc.c did not read to the end }
         u0 := hs.u; ux := hs.ux; uy := hs.uy; rst := hs.rst; s.padbit := hs.padbit;
         for i := 0 to 3 do pred[i] := hs.pred[i];
         rd.p := hs.pos; rd.buf := hs.acc; rd.nbits := hs.nbits; rd.stopped := hs.stopped <> 0;
         { the whole bytes waiting, for Align to give back: 2 input bytes for FF (FF 00) }
         rd.nload := 16;
         for i := 1 to rd.nbits shr 3 do
           if (hs.acc shr (8 * (i - 1))) and $FF = $FF then rd.sizes[16 - i] := 2 else rd.sizes[16 - i] := 1;
         st.eobrun := hs.eobrun; st.runBe := hs.runBe; st.runLen := hs.runLen; st.prevEnded := hs.prevEnded <> 0;
         st.prevBe := hs.prevBe; st.prevLen := hs.prevLen; st.beLow := hs.beLow; st.beHigh := hs.beHigh;
       end;
  end;
  for u := u0 to total - 1 do begin
    if (s.ri > 0) and (u > 0) and (u mod s.ri = 0) then begin
      if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
      if (rd.p + 1 >= Length(data)) or (data[rd.p] <> $FF) or (data[rd.p + 1] <> $D0 + (rst and 7)) then
        Exit(Fail(jeBadRst, rd.p));
      Inc(rd.p, 2); Inc(rst);
      FillChar(pred, SizeOf(pred), 0);
      st.eobrun := 0;
      st.prevEnded := False;
    end;
    { the unit's position kept as it goes, not divided out of u }
    BlocksAt(j, s, ux, uy, un, n);
    Inc(ux); if ux = w then begin ux := 0; Inc(uy); end;
    for i := 0 to n - 1 do begin
      e := DecodeUnitBlock(rd, j, s, un[i], pred, st);
      if e <> jeNone then Exit(Fail(e, rd.p));
    end;
  end;
  if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
  if s.padbit < 0 then s.padbit := 1;
  TakeBe(st.beLow, st.beHigh);
  { what follows must be a marker, or the end. An RST here is one too many:
    some encoders write them, and they stay in raw (see Parse) }
  if rd.p < Length(data) then
    if (data[rd.p] <> $FF) or (rd.p + 1 >= Length(data)) or (data[rd.p + 1] = 0) then
      Exit(Fail(jeDataAfterScan, rd.p));
  last := rd.p;
  Result := Success;
end;

{ A Huffman scan through HuffEncodeScan: False if it is not there, if
  some block would fall outside its component, or if it did not write the
  scan (then nothing of wr has changed but bytes past wr.n) }
function EncodeScanC(var wr: TBitWriter; const j: TJpeg; const s: TScan): Boolean;
const HE_ROOM = 2; UNIT_ROOM = 6144;
var hs: THuffEncScan; i: Integer; r: SizeInt; bws, hh, vv, preds: array[0..3] of SizeInt;
    coefs: array[0..3] of PSmallInt;
begin
  Result := False;
  if not Assigned(HuffEncodeScan) then Exit;
  hs := Default(THuffEncScan);
  if not ScanSlots(j, s, True, hs.unitsX, hs.total, hs.nslot, bws, hh, vv, preds, coefs) then Exit;
  for i := 0 to hs.nslot - 1 do
    with hs.slot[i] do begin
      coef := coefs[i]; bw := bws[i]; h := hh[i]; v := vv[i]; predIdx := preds[i];
      dcCode := @s.dc[preds[i]].code[0]; dcLen := @s.dc[preds[i]].len[0];
      acCode := @s.ac[preds[i]].code[0]; acLen := @s.ac[preds[i]].len[0];
    end;
  hs.ri := s.ri; hs.padbit := s.padbit;
  hs.progressive := Ord(j.progressive);
  hs.ss := s.ss; hs.se := s.se; hs.ah := s.ah; hs.al := s.al; hs.maxEob := s.maxEob; hs.maxBe := s.maxBe;
  hs.acc := wr.acc; hs.nacc := wr.nacc;
  hs.n := wr.n;
  repeat
    if Length(wr.d) < hs.n + UNIT_ROOM then SetLength(wr.d, 2 * Length(wr.d) + UNIT_ROOM);
    hs.outp := @wr.d[0]; hs.cap := Length(wr.d);
    r := HuffEncodeScan(hs);
  until r <> HE_ROOM;
  if r <> 0 then Exit;
  wr.n := hs.n; wr.acc := 0; wr.nacc := 0;
  Result := True;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function EncodeScan(var wr: TBitWriter; const j: TJpeg; const s: TScan): Boolean;
var total, u, w, ux, uy: SizeInt; un: TUnit; n, i, rst: Integer; pred: array[0..3] of Integer;
    st: TProgState;
begin
  if EncodeScanC(wr, j, s) then Exit(True);
  FillChar(pred, SizeOf(pred), 0);
  st := Default(TProgState);
  total := UnitCount(j, s);
  w := UnitsPerRow(j, s); ux := 0; uy := 0;
  rst := 0;
  for u := 0 to total - 1 do begin
    if (s.ri > 0) and (u > 0) and (u mod s.ri = 0) then begin
      if not FlushEobrun(wr, s, st) then Exit(False);
      wr.Align(s.padbit);
      wr.PutByte($FF); wr.PutByte($D0 + (rst and 7));
      Inc(rst);
      FillChar(pred, SizeOf(pred), 0);
    end;
    { the unit's position kept as it goes, not divided out of u }
    BlocksAt(j, s, ux, uy, un, n);
    Inc(ux); if ux = w then begin ux := 0; Inc(uy); end;
    for i := 0 to n - 1 do
      if not EncodeUnitBlock(wr, j, s, un[i], pred, st) then Exit(False);
  end;
  if not FlushEobrun(wr, s, st) then Exit(False);
  wr.Align(s.padbit);
  Result := True;
end;

{$ifdef PJA_FAST}{$pop}{$endif}
{ ---------- segments ---------- }

function U16(const d: TBytes; i: SizeInt): Integer;
begin Result := (d[i] shl 8) or d[i + 1]; end;

function ReadDqt(const d: TBytes; p, last: SizeInt; var j: TJpeg): Boolean;
var pq, tq, k: Integer;
begin
  while p < last do begin
    pq := d[p] shr 4; tq := d[p] and 15; Inc(p);
    if (pq > 1) or (tq > 3) then Exit(False);
    if p + 64 * (pq + 1) > last then Exit(False);
    for k := 0 to 63 do
      if pq = 0 then begin j.qt[tq, k] := d[p]; Inc(p); end
      else begin j.qt[tq, k] := U16(d, p); Inc(p, 2); end;
    j.qpresent[tq] := True;
  end;
  Result := True;
end;

type
  THuffState = record
    present: array[0..1, 0..3] of Boolean;
    t: array[0..1, 0..3] of THuff;
  end;

  { DAC: arithmetic conditioning, per table index }
  TArithCond = record
    L, U, K: array[0..3] of Integer;
  end;

function ReadDac(const d: TBytes; p, last: SizeInt; var ac: TArithCond): Boolean;
var tc, tb, cs: Integer;
begin
  if (last - p) mod 2 <> 0 then Exit(False);
  while p < last do begin
    tc := d[p] shr 4; tb := d[p] and 15; cs := d[p + 1]; Inc(p, 2);
    if (tc > 1) or (tb > 3) then Exit(False);
    if tc = 0 then begin
      ac.L[tb] := cs and 15; ac.U[tb] := cs shr 4;
      if ac.L[tb] > ac.U[tb] then Exit(False);
    end else begin
      if (cs < 1) or (cs > 63) then Exit(False);
      ac.K[tb] := cs;
    end;
  end;
  Result := True;
end;

function ReadDht(const d: TBytes; p, last: SizeInt; var hs: THuffState): Boolean;
var tc, th, l, k, total: Integer;
begin
  while p < last do begin
    if p + 17 > last then Exit(False);
    tc := d[p] shr 4; th := d[p] and 15; Inc(p);
    if (tc > 1) or (th > 3) then Exit(False);
    total := 0;
    for l := 1 to 16 do begin hs.t[tc, th].counts[l] := d[p]; Inc(total, d[p]); Inc(p); end;
    if (total > 256) or (p + total > last) then Exit(False);
    for k := 0 to total - 1 do begin hs.t[tc, th].values[k] := d[p]; Inc(p); end;
    hs.t[tc, th].nvalues := total;
    if not BuildHuff(hs.t[tc, th]) then Exit(False);
    hs.present[tc, th] := True;
  end;
  Result := True;
end;

function ReadSof(const d: TBytes; p, last: SizeInt; var j: TJpeg): TJpegError;
var nf, i, k: Integer; blocks: Int64; q: SizeInt;
begin
  if last - p < 6 then Exit(jeBadSof);
  if j.lossless then begin
    if (d[p] < 2) or (d[p] > 16) then Exit(jeBadSof);
  end else
    if (d[p] <> 8) and (d[p] <> 12) then Exit(jeUnsupported);
  j.precision := d[p];
  j.height := U16(d, p + 1); j.width := U16(d, p + 3); nf := d[p + 5];
  if j.height = 0 then begin
    { the height comes in a DNL after the first scan (B.2.5): found ahead,
      since no FF D C can be inside entropy-coded data, where FF is followed
      by 00 or a restart marker }
    q := last;
    while (q + 6 <= Length(d)) and not ((d[q] = $FF) and (d[q + 1] = $DC) and (U16(d, q + 2) = 4)) do Inc(q);
    if q + 6 > Length(d) then Exit(jeBadSof);
    j.height := U16(d, q + 4);
    if j.height = 0 then Exit(jeBadSof);
    j.dnl := True;
  end;
  if (j.width = 0) or (nf < 1) or (nf > 4) or (last - p <> 6 + 3 * nf) then Exit(jeBadSof);
  SetLength(j.comp, nf);
  j.hmax := 1; j.vmax := 1;
  for i := 0 to nf - 1 do
    with j.comp[i] do begin
      id := d[p + 6 + 3 * i]; h := d[p + 7 + 3 * i] shr 4; v := d[p + 7 + 3 * i] and 15; tq := d[p + 8 + 3 * i];
      if (h < 1) or (h > 4) or (v < 1) or (v > 4) or (tq > 3) then Exit(jeBadSof);
      for k := 0 to i - 1 do if j.comp[k].id = id then Exit(jeBadSof);
      if h > j.hmax then j.hmax := h;
      if v > j.vmax then j.vmax := v;
    end;
  if j.lossless then begin
    { the samples of each component, none subsampled }
    if (j.hmax <> 1) or (j.vmax <> 1) then Exit(jeUnsupported);
    if Int64(j.width) * j.height * nf > MAX_LOSSLESS_SAMPLES then Exit(jeTooLarge);
    for i := 0 to nf - 1 do
      with j.comp[i] do begin
        SetLength(samples, SizeInt(j.width) * j.height);
        if Length(samples) > 0 then FillChar(samples[0], Length(samples) * SizeOf(Word), 0);
      end;
    Exit(jeNone);
  end;
  j.mcusx := (j.width + 8 * j.hmax - 1) div (8 * j.hmax);
  j.mcusy := (j.height + 8 * j.vmax - 1) div (8 * j.vmax);
  blocks := 0;
  for i := 0 to nf - 1 do
    with j.comp[i] do begin
      bw := SizeInt(j.mcusx) * h; bh := SizeInt(j.mcusy) * v;
      bwReal := ((Int64(j.width) * h + j.hmax - 1) div j.hmax + 7) div 8;
      bhReal := ((Int64(j.height) * v + j.vmax - 1) div j.vmax + 7) div 8;
      Inc(blocks, Int64(bw) * bh);
    end;
  if blocks > MAX_BLOCKS then Exit(jeTooLarge);
  for i := 0 to nf - 1 do
    with j.comp[i] do begin
      SetLength(coef, bw * bh * 64);
      if Length(coef) > 0 then FillChar(coef[0], Length(coef) * SizeOf(SmallInt), 0);
    end;
  Result := jeNone;
end;

function ReadSos(const d: TBytes; p, last: SizeInt; const j: TJpeg; const hs: THuffState;
                 const ac: TArithCond; ri: Integer; out s: TScan): TJpegError;
var i, k, c, td, ta, sum, prev: Integer; q: SizeInt; tds, tas: array[0..3] of Integer;
begin
  s := Default(TScan);
  s.maxBe := LIBJPEG_MAX_BE;
  if last - p < 1 then Exit(jeBadSos);
  s.ncomp := d[p];
  if (s.ncomp < 1) or (s.ncomp > 4) or (last - p <> 4 + 2 * s.ncomp) then Exit(jeBadSos);
  sum := 0; prev := -1;
  for i := 0 to s.ncomp - 1 do begin
    c := -1;
    for k := 0 to High(j.comp) do if j.comp[k].id = d[p + 1 + 2 * i] then c := k;
    { each component once, and in frame order (B.2.3) }
    if c <= prev then Exit(jeBadSos);
    prev := c;
    s.comp[i] := c;
    Inc(sum, j.comp[c].h * j.comp[c].v);
    td := d[p + 2 + 2 * i] shr 4; ta := d[p + 2 + 2 * i] and 15;
    if (td > 3) or (ta > 3) then Exit(jeBadSos);
    tds[i] := td; tas[i] := ta;
  end;
  if (s.ncomp > 1) and (sum > MAX_MCU_BLOCKS) then Exit(jeBadSos);
  q := p + 1 + 2 * s.ncomp;
  s.ss := d[q]; s.se := d[q + 1]; s.ah := d[q + 2] shr 4; s.al := d[q + 2] and 15;
  if j.lossless then begin
    { H.1.2: a predictor 1 to 7, Se and Ah zero, a point transform below the
      precision; restarts at the start of a line, as libjpeg has them }
    if (s.ss < 1) or (s.ss > 7) or (s.se <> 0) or (s.ah <> 0) or (s.al >= j.precision) then Exit(jeBadSos);
    if (ri > 0) and (ri mod j.width <> 0) then Exit(jeUnsupported);
    for i := 0 to s.ncomp - 1 do begin
      if not hs.present[0, tds[i]] then Exit(jeMissingTable);
      s.dc[i] := hs.t[0, tds[i]];
    end;
    s.ri := ri;
    Exit(jeNone);
  end;
  if not j.progressive then begin
    if (s.ss <> 0) or (s.se <> 63) or (s.ah <> 0) or (s.al <> 0) then Exit(jeBadSos);
  end else begin
    { G.1.1.1: DC alone, or AC of a single component; each refinement drops one bit }
    if (s.ss = 0) and (s.se <> 0) then Exit(jeBadSos);
    if (s.ss > 0) and ((s.se < s.ss) or (s.se > 63) or (s.ncomp <> 1)) then Exit(jeBadSos);
    if (s.ah <> 0) and (s.al <> s.ah - 1) then Exit(jeBadSos);
    if s.al > 13 then Exit(jeBadSos);
  end;
  if j.arithmetic then begin
    { no Huffman tables: statistics bins, and the conditioning in force }
    for i := 0 to s.ncomp - 1 do begin
      s.td[i] := tds[i]; s.ta[i] := tas[i];
      s.dcL[i] := ac.L[tds[i]]; s.dcU[i] := ac.U[tds[i]]; s.acK[i] := ac.K[tas[i]];
    end;
    s.ri := ri;
    Exit(jeNone);
  end;
  { only the tables the scan uses: DC refinement uses none }
  for i := 0 to s.ncomp - 1 do begin
    if (s.ss = 0) and (s.ah = 0) then begin
      if not hs.present[0, tds[i]] then Exit(jeMissingTable);
      s.dc[i] := hs.t[0, tds[i]];
    end;
    if s.se > 0 then begin
      if not hs.present[1, tas[i]] then Exit(jeMissingTable);
      s.ac[i] := hs.t[1, tas[i]];
    end;
  end;
  { an encoder that runs EOBs only as far as its table allows: libjpeg goes
    to 32767, and with the tables it builds itself the largest EOBr symbol
    present is never shorter than its longest run, so this is the same }
  s.maxEob := 1;
  if j.progressive and (s.se > 0) then
    for k := 14 downto 0 do
      if s.ac[0].len[k shl 4] > 0 then begin s.maxEob := (2 shl k) - 1; Break; end;
  s.ri := ri;
  Result := jeNone;
end;

{ ---------- lossless JPEG (Annex H) ---------- }

{ H.1.2.1, as libjpeg computes it: Ra the sample to the left, Rb the one
  above, Rc above and to the left; the shifts arithmetic }
function LosslessPredict(psv, ra, rb, rc: Integer): Integer; inline;
begin
  case psv of
    1: Result := ra;
    2: Result := rb;
    3: Result := rc;
    4: Result := ra + rb - rc;
    5: Result := ra + SarLongint(rb - rc, 1);
    6: Result := rb + SarLongint(ra - rc, 1);
  else Result := (ra + rb) shr 1;
  end;
end;

{ The prediction of the sample at (x, y) of a component; y0 the first line
  of its restart interval (the scan's first line without restarts) }
function LosslessPrediction(const j: TJpeg; const s: TScan; const sm: array of Word; x, y, y0: SizeInt): Integer;
var w: SizeInt;
begin
  w := j.width;
  if y = y0 then begin
    if x = 0 then Result := 1 shl (j.precision - s.al - 1)
    else Result := sm[y * w + x - 1];
  end else if x = 0 then Result := sm[(y - 1) * w]
  else Result := LosslessPredict(s.ss, sm[y * w + x - 1], sm[(y - 1) * w + x], sm[(y - 1) * w + x - 1]);
end;

function DecodeScanLossless(const data: TBytes; first: SizeInt; var j: TJpeg; var s: TScan;
                            out last: SizeInt): TJpegResult;
var rd: TBitReader; x, y, y0, rows, w: SizeInt; i, c, t, v, pb, rst, diff, top: Integer; e: TJpegError;

  function Padding: Boolean;
  begin
    if not rd.Align(pb) then Exit(False);
    if pb >= 0 then begin
      if s.padbit < 0 then s.padbit := pb
      else if s.padbit <> pb then Exit(False);
    end;
    Result := True;
  end;

begin
  last := first;
  rd := Default(TBitReader);
  rd.d := data; rd.p := first;
  s.padbit := -1;
  w := j.width;
  rows := 0;
  if s.ri > 0 then rows := s.ri div w;
  { the samples a P - Pt bit range holds: anything above, no encoder writes }
  top := (1 shl (j.precision - s.al)) - 1;
  rst := 0; y0 := 0;
  for y := 0 to j.height - 1 do begin
    if (rows > 0) and (y > 0) and (y mod rows = 0) then begin
      if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
      if (rd.p + 1 >= Length(data)) or (data[rd.p] <> $FF) or (data[rd.p + 1] <> $D0 + (rst and 7)) then
        Exit(Fail(jeBadRst, rd.p));
      Inc(rd.p, 2); Inc(rst);
      y0 := y;
    end;
    for x := 0 to w - 1 do
      for i := 0 to s.ncomp - 1 do begin
        e := DecodeSymbol(rd, s.dc[i], t);
        if e <> jeNone then Exit(Fail(e, rd.p));
        { a difference of 16 bits: 32768 itself, with no bits after it }
        if t > 16 then Exit(Fail(jeBadCode, rd.p));
        if t = 16 then diff := 32768
        else begin
          if not rd.Bits(t, v) then Exit(Fail(jeTruncated, rd.p));
          diff := Extend(v, t);
        end;
        { no `with` here: TComponent has fields h and v }
        c := s.comp[i];
        v := (diff + LosslessPrediction(j, s, j.comp[c].samples, x, y, y0)) and $FFFF;
        if v > top then Exit(Fail(jeCoefOutOfRange, rd.p));
        j.comp[c].samples[y * w + x] := v;
      end;
  end;
  if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
  if s.padbit < 0 then s.padbit := 1;
  if rd.p < Length(data) then
    if (data[rd.p] <> $FF) or (rd.p + 1 >= Length(data)) or (data[rd.p + 1] = 0) then
      Exit(Fail(jeDataAfterScan, rd.p));
  last := rd.p;
  Result := Success;
end;

function EncodeScanLossless(var wr: TBitWriter; const j: TJpeg; const s: TScan): Boolean;
var x, y, y0, rows, w: SizeInt; i, c, d, mag, bits, nbits, rst: Integer;
begin
  w := j.width;
  rows := 0;
  if s.ri > 0 then rows := s.ri div w;
  rst := 0; y0 := 0;
  for y := 0 to j.height - 1 do begin
    if (rows > 0) and (y > 0) and (y mod rows = 0) then begin
      wr.Align(s.padbit);
      wr.PutByte($FF); wr.PutByte($D0 + (rst and 7));
      Inc(rst);
      y0 := y;
    end;
    for x := 0 to w - 1 do
      for i := 0 to s.ncomp - 1 do begin
        c := s.comp[i];
        d := (j.comp[c].samples[y * w + x] - LosslessPrediction(j, s, j.comp[c].samples, x, y, y0)) and $FFFF;
        { jclhuff.c: the magnitude modulo 2^16, 32768 alone in category 16 }
        if d and $8000 <> 0 then begin
          mag := (-d) and $7FFF;
          if mag = 0 then begin mag := $8000; bits := 0; end
          else bits := not mag;
        end else begin
          mag := d and $7FFF;
          bits := mag;
        end;
        nbits := 0;
        while mag <> 0 do begin Inc(nbits); mag := mag shr 1; end;
        if not EmitSymbol(wr, s.dc[i], nbits) then Exit(False);
        if (nbits > 0) and (nbits < 16) then wr.Bits(bits and ((1 shl nbits) - 1), nbits);
      end;
  end;
  wr.Align(s.padbit);
  Result := True;
end;

{ ---------- top ---------- }

{ Whether a scan of data, just read from its header (s, starting at first)
  as the scan of the same number in ref, decodes as that one did: the same
  frame, the same header and tables, the same place, and the same bytes
  through the two after its end (the marker that stops the reader) }
function SameScanAs(const data: TBytes; first: SizeInt; const j: TJpeg; const s: TScan;
                    const ref: TJpeg; const refData: TBytes): Boolean;
var i: Integer; rs: TScan; e: SizeInt;
begin
  Result := False;
  i := Length(j.scans);
  if (i > High(ref.scans)) or ref.dnl or j.dnl or ref.arithmetic or ref.lossless then Exit;
  rs := ref.scans[i];
  if rs.ignoreRi or (rs.dataStart <> first) or (rs.cut <> s.cut) or (rs.dataEnd < first) then Exit;
  { the frame }
  if (j.width <> ref.width) or (j.height <> ref.height) or (j.precision <> ref.precision) or
     (j.lossless <> ref.lossless) or (j.progressive <> ref.progressive) or (j.arithmetic <> ref.arithmetic) or
     (j.hmax <> ref.hmax) or (j.vmax <> ref.vmax) or (j.mcusx <> ref.mcusx) or (j.mcusy <> ref.mcusy) or
     (Length(j.comp) <> Length(ref.comp)) then Exit;
  for i := 0 to High(j.comp) do
    if (j.comp[i].id <> ref.comp[i].id) or (j.comp[i].h <> ref.comp[i].h) or (j.comp[i].v <> ref.comp[i].v) or
       (j.comp[i].tq <> ref.comp[i].tq) or (j.comp[i].bw <> ref.comp[i].bw) or (j.comp[i].bh <> ref.comp[i].bh) or
       (j.comp[i].bwReal <> ref.comp[i].bwReal) or (j.comp[i].bhReal <> ref.comp[i].bhReal) or
       (Length(j.comp[i].coef) <> Length(ref.comp[i].coef)) then Exit;
  { the scan's header, as the decoder reads it }
  if (s.ncomp <> rs.ncomp) or (s.ncomp < 0) or (s.ncomp > 4) or (s.ss <> rs.ss) or (s.se <> rs.se) or
     (s.ah <> rs.ah) or (s.al <> rs.al) or (s.ri <> rs.ri) or (s.maxEob <> rs.maxEob) then Exit;
  for i := 0 to s.ncomp - 1 do
    if (s.comp[i] <> rs.comp[i]) or (s.td[i] <> rs.td[i]) or (s.ta[i] <> rs.ta[i]) or
       (s.dcL[i] <> rs.dcL[i]) or (s.dcU[i] <> rs.dcU[i]) or (s.acK[i] <> rs.acK[i]) or
       not CompareMem(@s.dc[i], @rs.dc[i], SizeOf(THuff)) or not CompareMem(@s.ac[i], @rs.ac[i], SizeOf(THuff)) then
      Exit;
  { its bytes, and the two the reader stops at (or the end of both) }
  e := rs.dataEnd + 2;
  if e > Length(refData) then begin
    if Length(data) <> Length(refData) then Exit;
    e := Length(refData);
  end;
  if (e > Length(data)) or (rs.dataEnd > Length(refData)) then Exit;
  if (e > first) and not CompareMem(@data[first], @refData[first], e - first) then Exit;
  Result := True;
end;

type PJpegRef = ^TJpeg;

function ParseWith(const data: TBytes; decode: Boolean; out j: TJpeg; ref: PJpegRef; const refData: TBytes;
                   out refFailed: Boolean): TJpegResult;
var p, first, last, copied, seglen: SizeInt; m: Byte; hs: THuffState; ri, i: Integer;
    haveFrame: Boolean; e: TJpegError; s, s2: TScan; rawOut: TBitWriter; ac: TArithCond; r2: TJpegResult;

  procedure CopyUpTo(upto: SizeInt);
  begin rawOut.CopyFrom(data, copied, upto); copied := upto; end;

begin
  refFailed := False;
  j := Default(TJpeg);
  hs := Default(THuffState);
  rawOut := Default(TBitWriter);
  if (Length(data) < 4) or (data[0] <> $FF) or (data[1] <> $D8) then Exit(Fail(jeNotJpeg, 0));
  p := 2; copied := 0; ri := 0; haveFrame := False;
  for i := 0 to 3 do begin ac.L[i] := 0; ac.U[i] := 1; ac.K[i] := 5; end;   { T.81 F.1.4.4.1.4 defaults }
  while True do begin
    if p >= Length(data) then Exit(Fail(jeTruncated, p));
    if data[p] <> $FF then Exit(Fail(jeUnexpectedMarker, p, data[p]));
    { $FF fill bytes before the marker (B.1.1.2) }
    while (p < Length(data)) and (data[p] = $FF) do Inc(p);
    if p >= Length(data) then Exit(Fail(jeTruncated, p));
    m := data[p]; Inc(p);
    if m = $D9 then begin  { EOI: whatever follows, garbage included, goes into raw }
      j.eoi := p;
      Break;
    end;
    if (m = 0) or (m = $D8) or (m = $01) then Exit(Fail(jeUnexpectedMarker, p - 1, m));
    { an RST outside a scan (one too many after the last restart interval,
      written by some encoders) has no length: it is kept as it is }
    if IsRst(m) then Continue;
    if p + 2 > Length(data) then Exit(Fail(jeTruncated, p));
    seglen := U16(data, p);
    if seglen < 2 then Exit(Fail(jeBadSegment, p));
    if p + seglen > Length(data) then Exit(Fail(jeTruncated, p));
    first := p + 2; last := p + seglen;
    case m of
      $DB: if not ReadDqt(data, first, last, j) then Exit(Fail(jeBadDqt, first));
      $C4: if not ReadDht(data, first, last, hs) then Exit(Fail(jeBadDht, first));
      $DD: begin
             if seglen <> 4 then Exit(Fail(jeBadDri, first));
             ri := U16(data, first);
           end;
      $DC: begin
             { DNL: only where the frame left its height to it, after the
               first scan, and saying the height read ahead }
             if not j.dnl or (Length(j.scans) <> 1) or (seglen <> 4) or (U16(data, first) <> j.height) then
               Exit(Fail(jeUnexpectedMarker, p - 1, m));
           end;
      $C0, $C1, $C2, $C9, $CA, $C3: begin
             if haveFrame then Exit(Fail(jeRepeatedSof, p - 1));
             j.lossless := m = $C3;
             e := ReadSof(data, first, last, j);
             if e <> jeNone then Exit(Fail(e, first, m));
             j.progressive := (m = $C2) or (m = $CA);
             j.arithmetic := m >= $C9;
             haveFrame := True;
           end;
      $CC: if not ReadDac(data, first, last, ac) then Exit(Fail(jeBadDac, first));
      { JPEG-LS is $F7; $CB lossless with arithmetic coding }
      $C5..$C7, $CB, $CD..$CF, $DE, $DF, $F7:
           Exit(Fail(jeUnsupported, p - 1, m));
      $DA: begin
             if not haveFrame then Exit(Fail(jeUnexpectedMarker, p - 1, m));
             e := ReadSos(data, first, last, j, hs, ac, ri, s);
             if e <> jeNone then Exit(Fail(e, first));
             { lossless: one point transform for the whole image (the model
               takes its samples in one range) }
             if j.lossless and (Length(j.scans) > 0) and (s.al <> j.scans[0].al) then
               Exit(Fail(jeUnsupported, first, m));
             CopyUpTo(last);
             s.cut := rawOut.n;
             if decode and (ref <> nil) then begin
               { the scan of ref, bytes and all: what decoding would give }
               if not SameScanAs(data, last, j, s, ref^, refData) then begin
                 refFailed := True;
                 Exit(Fail(jeUnsupported, last));
               end;
               s := ref^.scans[Length(j.scans)];
               copied := s.dataEnd;
             end else if decode then begin
               if j.lossless then Result := DecodeScanLossless(data, last, j, s, copied)
               else if j.arithmetic then Result := DecodeScanArith(data, last, j, s, copied)
               else Result := DecodeScan(data, last, j, s, copied);
               { an encoder that wrote a DRI and no RST: a sequential
                 Huffman or lossless scan read again as if without
                 restarts, from cleared coefficients (the first try wrote
                 some). Progressive and arithmetic scans are not tried }
               if not Result.Ok and (s.ri > 0) and not j.progressive and not j.arithmetic then begin
                 for i := 0 to s.ncomp - 1 do
                   with j.comp[s.comp[i]] do begin
                     if Length(coef) > 0 then FillChar(coef[0], Length(coef) * SizeOf(SmallInt), 0);
                     if Length(samples) > 0 then FillChar(samples[0], Length(samples) * SizeOf(Word), 0);
                   end;
                 s2 := s; s2.ri := 0;
                 if j.lossless then r2 := DecodeScanLossless(data, last, j, s2, copied)
                 else r2 := DecodeScan(data, last, j, s2, copied);
                 if r2.Ok then begin s := s2; s.ignoreRi := True; Result := r2; end;
               end;
               if not Result.Ok then Exit;
               s.dataStart := last; s.dataEnd := copied;
             end;
             SetLength(j.scans, Length(j.scans) + 1);
             j.scans[High(j.scans)] := s;
             p := copied;
             if p >= Length(data) then begin j.eoi := Length(data); Break; end;  { no EOI }
             Continue;
           end;
    end;
    p := last;
  end;
  if Length(j.scans) = 0 then Exit(Fail(jeUnexpectedMarker, p, $D9));
  CopyUpTo(Length(data));
  j.raw := Copy(rawOut.d, 0, rawOut.n);
  Result := Success;
end;

function Parse(const data: TBytes; decode: Boolean; out j: TJpeg): TJpegResult;
var refFailed: Boolean;
begin
  Result := ParseWith(data, decode, j, nil, nil, refFailed);
end;

function Decompose(const data: TBytes; out j: TJpeg): TJpegResult;
begin
  Result := Parse(data, True, j);
end;

function ParseHeaders(const raw: TBytes; out j: TJpeg): TJpegResult;
begin
  Result := Parse(raw, False, j);
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
{ Recompose; ends, if not nil: where each scan's entropy-coded bytes begin
  and end in data (2 per scan) }
function RecomposeAt(const j: TJpeg; out data: TBytes; expected: SizeInt; ends: PSizeInt): TJpegResult;
var wr: TBitWriter; i: Integer; from, room: SizeInt;
begin
  data := nil;
  wr := Default(TBitWriter);
  { the writers keep 16 bytes of room ahead. What a damaged stream claims
  is not allocated beyond the coefficients' own memory, already taken; the
  buffer grows past that as the output does }
  if expected > 0 then begin
    room := Length(j.raw);
    for i := 0 to High(j.comp) do room := room + 2 * Length(j.comp[i].coef) + 4 * Length(j.comp[i].samples);
    SetLength(wr.d, Min(expected, room) + 64);
  end else SetLength(wr.d, Length(j.raw) * 4 + 4096);
  from := 0;
  for i := 0 to High(j.scans) do begin
    wr.CopyFrom(j.raw, from, j.scans[i].cut);
    from := j.scans[i].cut;
    wr.acc := 0; wr.nacc := 0;
    if ends <> nil then ends[2 * i] := wr.n;
    if j.lossless then begin
      if not EncodeScanLossless(wr, j, j.scans[i]) then Exit(Fail(jeNoRoundTrip, wr.n));
    end else if j.arithmetic then begin
      if not EncodeScanArith(wr, j, j.scans[i]) then Exit(Fail(jeNoRoundTrip, wr.n));
    end else
      if not EncodeScan(wr, j, j.scans[i]) then Exit(Fail(jeNoRoundTrip, wr.n));
    if ends <> nil then ends[2 * i + 1] := wr.n;
  end;
  wr.CopyFrom(j.raw, from, Length(j.raw));
  { the buffer itself, cut to its length: no copy }
  SetLength(wr.d, wr.n);
  data := wr.d;
  Result := Success;
end;

function Recompose(const j: TJpeg; out data: TBytes; expected: SizeInt): TJpegResult;
begin
  Result := RecomposeAt(j, data, expected, nil);
end;

{$ifdef PJA_FAST}{$pop}{$endif}
function HasIgnoredRestarts(const j: TJpeg): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(j.scans) do if j.scans[i].ignoreRi then Exit(True);
end;

function HasCorrectionLimits(const j: TJpeg): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(j.scans) do if j.scans[i].maxBe <> LIBJPEG_MAX_BE then Exit(True);
end;

function IsMpo(const data: TBytes): Boolean;
var p, t, ifd, e, n, k, i, off, cnt, images: SizeInt; le: Boolean; m: Byte;

  function Get16(q: SizeInt): Integer;
  begin
    if le then Result := data[q] or (data[q + 1] shl 8) else Result := (data[q] shl 8) or data[q + 1];
  end;

  function Get32(q: SizeInt): Int64;
  begin
    if le then Result := Int64(Get16(q)) or (Int64(Get16(q + 2)) shl 16)
    else Result := (Int64(Get16(q)) shl 16) or Get16(q + 2);
  end;

begin
  Result := False;
  if (Length(data) < 4) or (data[0] <> $FF) or (data[1] <> $D8) then Exit;
  p := 2;
  while p + 4 <= Length(data) do begin
    if data[p] <> $FF then Exit;
    m := data[p + 1];
    if (m = $DA) or (m = $D9) then Exit;
    n := U16(data, p + 2);
    if (n < 2) or (p + 2 + n > Length(data)) then Exit;
    { APP2 "MPF\0", then a TIFF header and its first IFD }
    if (m = $E2) and (n >= 16) and (data[p + 4] = Ord('M')) and (data[p + 5] = Ord('P')) and
       (data[p + 6] = Ord('F')) and (data[p + 7] = 0) then begin
      t := p + 8;
      if (data[t] = Ord('I')) and (data[t + 1] = Ord('I')) then le := True
      else if (data[t] = Ord('M')) and (data[t + 1] = Ord('M')) then le := False
      else Exit;
      ifd := t + Get32(t + 4);
      if (ifd < t) or (ifd + 2 > p + 2 + n) then Exit;
      cnt := Get16(ifd);
      for k := 0 to cnt - 1 do begin
        e := ifd + 2 + 12 * k;
        if e + 12 > p + 2 + n then Exit;
        { MPEntry: 16 bytes an image, its attribute first; the type code
          is the low 24 bits, Multi-Frame 0x02xxxx }
        if Get16(e) = $B002 then begin
          off := t + Get32(e + 8);
          images := Get32(e + 4) div 16;
          for i := 0 to images - 1 do begin
            if (off < t) or (off + 16 * (i + 1) > Length(data)) then Exit;
            if (Get32(off + 16 * i) shr 16) and $FF = $02 then Exit(True);
          end;
          Exit;
        end;
      end;
      Exit;
    end;
    p := p + 2 + n;
  end;
end;

function VerifyRoundTrip(const data: TBytes; out j: TJpeg): TJpegResult;
var other: TBytes; k: SizeInt; ends: array of SizeInt; i: Integer;
begin
  Result := Decompose(data, j);
  if not Result.Ok then Exit;
  ends := nil; SetLength(ends, 2 * Length(j.scans) + 1);
  Result := RecomposeAt(j, other, Length(data), @ends[0]);
  if not Result.Ok then Exit;
  { the same bytes and length: the common case in one comparison; the
    first difference is only looked for when there is one }
  if (Length(other) = Length(data)) and
     ((Length(data) = 0) or CompareMem(@other[0], @data[0], Length(data))) then begin
    j.scansExact := True;
    for i := 0 to High(j.scans) do
      if (ends[2 * i] <> j.scans[i].dataStart) or (ends[2 * i + 1] <> j.scans[i].dataEnd) then
        j.scansExact := False;
    Exit(Success);
  end;
  for k := 0 to Min(High(other), High(data)) do
    if other[k] <> data[k] then Exit(Fail(jeNoRoundTrip, k));
  if Length(other) <> Length(data) then Exit(Fail(jeNoRoundTrip, Min(Length(other), Length(data))));
  Result := Success;
end;

function VerifyRoundTripFrom(const data: TBytes; const ref: TJpeg; const refData: TBytes;
                             out j: TJpeg): TJpegResult;
var refFailed: Boolean; c: Integer;
begin
  { each scan as ref's: its bytes as Recompose writes them, there, so that
    the rebuild is data itself (RecomposeAt in VerifyRoundTrip saw it) }
  if ref.scansExact and (Length(ref.scans) > 0) then begin
    Result := ParseWith(data, True, j, @ref, refData, refFailed);
    if not refFailed then begin
      if not Result.Ok then Exit;
      if Length(j.scans) = Length(ref.scans) then begin
        for c := 0 to High(j.comp) do begin
          j.comp[c].coef := ref.comp[c].coef;
          j.comp[c].samples := ref.comp[c].samples;
        end;
        j.scansExact := True;
        Exit(Success);
      end;
    end;
  end;
  Result := VerifyRoundTrip(data, j);
end;

end.

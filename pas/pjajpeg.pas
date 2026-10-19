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

  { ZIGZAG[k] = natural position (row*8+col) of the k-th coefficient in a scan. }
  ZIGZAG: array[0..63] of Byte = (
     0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

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
    cut: SizeInt;                    { where in TJpeg.raw its data goes }
  end;

  TJpeg = record
    width, height: Integer;
    progressive: Boolean;
    arithmetic: Boolean;
    comp: array of TComponent;
    hmax, vmax, mcusx, mcusy: Integer;
    qt: array[0..3, 0..63] of Word;  { in zigzag order, as in the DQT }
    qpresent: array[0..3] of Boolean;
    scans: array of TScan;
    { the file without its entropy-coded data }
    raw: TBytes;
  end;

{ Parses and decodes. On error, j is half filled and useless. }
function Decompose(const data: TBytes; out j: TJpeg): TJpegResult;
{ The other way in: `raw` is TJpeg.raw as Decompose left it (the file without
  its entropy-coded data). Parses the headers again -- frame, tables, scans
  and their cuts -- and leaves the coefficients allocated at zero, for the
  model to fill. The padding bits are not in raw: the caller sets them. }
function ParseHeaders(const raw: TBytes; out j: TJpeg): TJpegResult;
{ Encodes the scans again with their tables and interleaves them into raw. }
function Recompose(const j: TJpeg; out data: TBytes): TJpegResult;
{ Decompose + Recompose + compare with the original. The only thing that
  allows a JPEG to be stored as coefficients. }
function VerifyRoundTrip(const data: TBytes; out j: TJpeg): TJpegResult;

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

procedure TBitReader.Fill;
var c: Byte;
begin
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
var b: Byte;
begin
  { at most 6 whole bytes wait, each one twice with its stuffing }
  if n + 16 > Length(d) then SetLength(d, 2 * Length(d) + 4096);
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
  { at most 31 bits wait before adding, and count <= 16 }
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
begin
  if v < 0 then v := -v;
  if v = 0 then Result := 0 else Result := BsrDWord(DWord(v)) + 1;
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

{ The blocks of unit u of the scan, in stream order (A.2). }
procedure BlocksOf(const j: TJpeg; const s: TScan; u: SizeInt; out un: TUnit; out n: Integer);
var i, x, y: Integer; mx, my: SizeInt;
begin
  n := 0;
  if s.ncomp = 1 then begin
    with j.comp[s.comp[0]] do begin
      un[0].c := s.comp[0];
      un[0].idx := (u div bwReal) * bw + (u mod bwReal);
    end;
    n := 1;
    Exit;
  end;
  mx := u mod j.mcusx; my := u div j.mcusx;
  for i := 0 to s.ncomp - 1 do
    with j.comp[s.comp[i]] do
      for y := 0 to v - 1 do
        for x := 0 to h - 1 do begin
          un[n].c := s.comp[i];
          un[n].idx := (my * v + y) * bw + mx * h + x;
          Inc(n);
        end;
end;

{ ---------- sequential scan ---------- }

function DecodeBlock(var rd: TBitReader; var j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                     var pred: Integer): TJpegError;
var e: TJpegError; t, v, k, rs, r, base: Integer;
begin
  base := b.idx * 64;
  e := DecodeSymbol(rd, s.dc[i], t);
  if e <> jeNone then Exit(e);
  if t > 11 then Exit(jeBadCode);
  if not rd.Bits(t, v) then Exit(jeTruncated);
  pred := pred + Extend(v, t);
  if (pred < -32767) or (pred > 32767) then Exit(jeCoefOutOfRange);
  j.comp[b.c].coef[base] := pred;
  k := 1;
  while k <= 63 do begin
    e := DecodeSymbol(rd, s.ac[i], rs);
    if e <> jeNone then Exit(e);
    r := rs shr 4; t := rs and 15;
    if t = 0 then begin
      if r <> 15 then Break;   { EOB }
      Inc(k, 16);              { ZRL }
      Continue;
    end;
    if t > 10 then Exit(jeBadCode);
    Inc(k, r);
    if k > 63 then Exit(jeBadCode);
    if not rd.Bits(t, v) then Exit(jeTruncated);
    j.comp[b.c].coef[base + k] := Extend(v, t);
    Inc(k);
  end;
  Result := jeNone;
end;

{ The block as a standard encoder writes it (F.1.2): ZRL only before a nonzero
  coefficient, EOB if zeros are left at the end. }
{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function EncodeBlock(var wr: TBitWriter; const j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                     var pred: Integer): Boolean;
var k, r, v, t, diff, sym: Integer; cf: PSmallInt; dc, ac: ^THuff;
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
  wr.Bits(dc^.code[t], dc^.len[t]);
  if t > 0 then wr.Bits(diff - Ord(diff < 0), t);
  r := 0;
  for k := 1 to 63 do begin
    v := cf[k];
    if v = 0 then begin Inc(r); Continue; end;
    while r > 15 do begin
      if ac^.len[$F0] = 0 then Exit(False);
      wr.Bits(ac^.code[$F0], ac^.len[$F0]);
      Dec(r, 16);
    end;
    t := Category(v);
    sym := (r shl 4) or t;
    if ac^.len[sym] = 0 then Exit(False);
    wr.Bits(ac^.code[sym], ac^.len[sym]);
    wr.Bits(v - Ord(v < 0), t);
    r := 0;
  end;
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
    bebuf: array[0..999] of Byte;
  end;

const
  { jcphuff.c: MAX_CORR_BITS - DCTSIZE2 + 1 }
  MAX_BE = 1000 - 64 + 1;

function DecodeDcFirst(var rd: TBitReader; var j: TJpeg; const s: TScan; i: Integer; const b: TBlockRef;
                       var pred: Integer): TJpegError;
var e: TJpegError; t, v: Integer; x: Int64;
begin
  e := DecodeSymbol(rd, s.dc[i], t);
  if e <> jeNone then Exit(e);
  if t > 11 then Exit(jeBadCode);
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
    if t > 10 then Exit(jeBadCode);
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
var e: TJpegError; k, rs, r, t, v, base, p1, c: Integer;
begin
  base := b.idx * 64;
  p1 := 1 shl s.al;
  if p1 > 16383 then Exit(jeCoefOutOfRange);
  k := s.ss;
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
        Break;
      end;
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
    while k <= s.se do begin
      c := j.comp[b.c].coef[base + k];
      if c <> 0 then begin
        if not rd.Bit(v) then Exit(jeTruncated);
        if v = 1 then j.comp[b.c].coef[base + k] := Refine(c, p1);
      end;
      Inc(k);
    end;
    Dec(st.eobrun);
  end;
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
    if (st.eobrun = s.maxEob) or (st.be > MAX_BE) then
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
function DecodeScan(const data: TBytes; first: SizeInt; var j: TJpeg; var s: TScan;
                    out last: SizeInt): TJpegResult;
var rd: TBitReader; total, u: SizeInt; un: TUnit; n, i, pb, rst: Integer;
    pred: array[0..3] of Integer; e: TJpegError; st: TProgState;

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
  total := UnitCount(j, s);
  rst := 0;
  for u := 0 to total - 1 do begin
    if (s.ri > 0) and (u > 0) and (u mod s.ri = 0) then begin
      if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
      if (rd.p + 1 >= Length(data)) or (data[rd.p] <> $FF) or (data[rd.p + 1] <> $D0 + (rst and 7)) then
        Exit(Fail(jeBadRst, rd.p));
      Inc(rd.p, 2); Inc(rst);
      FillChar(pred, SizeOf(pred), 0);
      st.eobrun := 0;
    end;
    BlocksOf(j, s, u, un, n);
    for i := 0 to n - 1 do begin
      e := DecodeUnitBlock(rd, j, s, un[i], pred, st);
      if e <> jeNone then Exit(Fail(e, rd.p));
    end;
  end;
  if not Padding then Exit(Fail(jeInconsistentPadding, rd.p));
  if s.padbit < 0 then s.padbit := 1;
  { what follows must be a marker, or the end. An RST here is one too many:
    some encoders write them, and they stay in raw (see Parse) }
  if rd.p < Length(data) then
    if (data[rd.p] <> $FF) or (rd.p + 1 >= Length(data)) or (data[rd.p + 1] = 0) then
      Exit(Fail(jeDataAfterScan, rd.p));
  last := rd.p;
  Result := Success;
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function EncodeScan(var wr: TBitWriter; const j: TJpeg; const s: TScan): Boolean;
var total, u: SizeInt; un: TUnit; n, i, rst: Integer; pred: array[0..3] of Integer;
    st: TProgState;
begin
  FillChar(pred, SizeOf(pred), 0);
  st := Default(TProgState);
  total := UnitCount(j, s);
  rst := 0;
  for u := 0 to total - 1 do begin
    if (s.ri > 0) and (u > 0) and (u mod s.ri = 0) then begin
      if not FlushEobrun(wr, s, st) then Exit(False);
      wr.Align(s.padbit);
      wr.PutByte($FF); wr.PutByte($D0 + (rst and 7));
      Inc(rst);
      FillChar(pred, SizeOf(pred), 0);
    end;
    BlocksOf(j, s, u, un, n);
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
var nf, i, k: Integer; blocks: Int64;
begin
  if last - p < 6 then Exit(jeBadSof);
  if d[p] <> 8 then Exit(jeUnsupported);      { 12-bit }
  j.height := U16(d, p + 1); j.width := U16(d, p + 3); nf := d[p + 5];
  if j.height = 0 then Exit(jeUnsupported);   { height in a DNL }
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

{ ---------- top ---------- }

function Parse(const data: TBytes; decode: Boolean; out j: TJpeg): TJpegResult;
var p, first, last, copied, seglen: SizeInt; m: Byte; hs: THuffState; ri, i: Integer;
    haveFrame: Boolean; e: TJpegError; s: TScan; rawOut: TBitWriter; ac: TArithCond;

  procedure CopyUpTo(upto: SizeInt);
  begin rawOut.CopyFrom(data, copied, upto); copied := upto; end;

begin
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
    if m = $D9 then Break;  { EOI: whatever follows, garbage included, goes into raw }
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
      $C0, $C1, $C2, $C9, $CA: begin
             if haveFrame then Exit(Fail(jeRepeatedSof, p - 1));
             e := ReadSof(data, first, last, j);
             if e <> jeNone then Exit(Fail(e, first, m));
             j.progressive := (m = $C2) or (m = $CA);
             j.arithmetic := m >= $C9;
             haveFrame := True;
           end;
      $CC: if not ReadDac(data, first, last, ac) then Exit(Fail(jeBadDac, first));
      { JPEG-LS is $F7 }
      $C3, $C5..$C7, $CB, $CD..$CF, $DC, $DE, $DF, $F7:
           Exit(Fail(jeUnsupported, p - 1, m));
      $DA: begin
             if not haveFrame then Exit(Fail(jeUnexpectedMarker, p - 1, m));
             e := ReadSos(data, first, last, j, hs, ac, ri, s);
             if e <> jeNone then Exit(Fail(e, first));
             CopyUpTo(last);
             s.cut := rawOut.n;
             if decode then begin
               if j.arithmetic then Result := DecodeScanArith(data, last, j, s, copied)
               else Result := DecodeScan(data, last, j, s, copied);
               if not Result.Ok then Exit;
             end;
             SetLength(j.scans, Length(j.scans) + 1);
             j.scans[High(j.scans)] := s;
             p := copied;
             if p >= Length(data) then Break;  { no EOI }
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

function Decompose(const data: TBytes; out j: TJpeg): TJpegResult;
begin
  Result := Parse(data, True, j);
end;

function ParseHeaders(const raw: TBytes; out j: TJpeg): TJpegResult;
begin
  Result := Parse(raw, False, j);
end;

{$ifdef PJA_FAST}{$push}{$R-}{$Q-}{$endif}
function Recompose(const j: TJpeg; out data: TBytes): TJpegResult;
var wr: TBitWriter; i: Integer; from: SizeInt;
begin
  data := nil;
  wr := Default(TBitWriter);
  SetLength(wr.d, Length(j.raw) * 4 + 4096);
  from := 0;
  for i := 0 to High(j.scans) do begin
    wr.CopyFrom(j.raw, from, j.scans[i].cut);
    from := j.scans[i].cut;
    wr.acc := 0; wr.nacc := 0;
    if j.arithmetic then begin
      if not EncodeScanArith(wr, j, j.scans[i]) then Exit(Fail(jeNoRoundTrip, wr.n));
    end else
      if not EncodeScan(wr, j, j.scans[i]) then Exit(Fail(jeNoRoundTrip, wr.n));
  end;
  wr.CopyFrom(j.raw, from, Length(j.raw));
  data := Copy(wr.d, 0, wr.n);
  Result := Success;
end;

{$ifdef PJA_FAST}{$pop}{$endif}
function VerifyRoundTrip(const data: TBytes; out j: TJpeg): TJpegResult;
var other: TBytes; k: SizeInt;
begin
  Result := Decompose(data, j);
  if not Result.Ok then Exit;
  Result := Recompose(j, other);
  if not Result.Ok then Exit;
  for k := 0 to Min(High(other), High(data)) do
    if other[k] <> data[k] then Exit(Fail(jeNoRoundTrip, k));
  if Length(other) <> Length(data) then Exit(Fail(jeNoRoundTrip, Min(Length(other), Length(data))));
  Result := Success;
end;

end.

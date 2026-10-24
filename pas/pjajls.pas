{ Codec layer 1 for JPEG-LS (ITU-T T.87, LOCO-I): a .jls file split into what
  is stored verbatim (markers, LSE parameters, scan headers) and its samples,
  and back to the SAME file, byte for byte.

  The standard fixes what the encoder does (no tables chosen by the program,
  no runs at the encoder's liking), so decoding to samples and encoding them
  again with the same parameters gives the same bytes. The behaviour follows
  CharLS, the reference implementation (its scan.h, the contexts, the bit
  stuffing and the flush at the end of a scan), and VerifyJls compares the
  rebuilt file with the original all the same.

  Supported: 2 to 16 bits, 1 to 4 components, lossless and near-lossless
  (NEAR), the three interleave modes (none, line, sample), preset parameters
  (LSE type 1), mapping tables (kept as indices: LSE types 2 and 3 stay in
  raw), restart intervals. Unsupported: subsampled components, the point
  transform, LSE type 4 (oversize dimensions), sample interleave with other
  than 3 or 4 components.

  Errors use pjajpeg's TJpegResult, so that the codec treats both formats
  alike. }
unit pjajls;

{$I pja.inc}
{$ifopt R-}{$fatal pjajls: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjajls: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjajpeg;

const
  { Cap on samples over all components: 2^27 Words are 256 MB. }
  MAX_SAMPLES = 1 shl 27;

type
  TJlsComponent = record
    id: Byte;
    { sampling factors, and the component's own size (T.87 A.2:
      ceil(X * h / hmax) by ceil(Y * v / vmax), the frame's when nothing is
      subsampled) }
    h, v, width, height: Integer;
    samples: array of Word;      { width * height, row by row }
  end;

  TJlsScan = record
    ncomp: Integer;
    comp: array[0..3] of Integer;    { indices into TJls.comp }
    near, ilv: Integer;
    { the coding parameters in force (LSE type 1, or the defaults) }
    maxval, t1, t2, t3, reset: Integer;
    ri: Integer;                     { restart interval in lines, 0 = none }
    cut: SizeInt;                    { where in TJls.raw its data goes }
    { NEAR > 0 only: every run length, in coding order. The encoder that
      made the file ended each run where an ORIGINAL sample left the
      tolerance, and from the reconstructed samples that cannot be told
      (one may be within NEAR where the original was not), so decoding
      records them and encoding follows them. }
    runs: array of Integer;
  end;

  TJls = record
    width, height, bits: Integer;
    comp: array of TJlsComponent;
    scans: array of TJlsScan;
    raw: TBytes;
  end;

  { The symbols of the JPEG-LS state machine, for a coder other than its
    Golomb codes (CodeJlsSymbols). Each method codes the value it gets when
    encoding and returns it; when decoding it ignores it and returns the
    value it decodes. c is the component's place in the scan, i the column. }
  TJlsSymbols = class
    procedure BeginScan(const s: TJlsScan; const j: TJls); virtual; abstract;
    { A mapped error value (A.5.2 and A.7.2.1): ctx is the regular context
      (1..364), or 365 + the run context of an interruption sample (0, 1).
      k is the Golomb parameter JPEG-LS would use; the error is
      sgn * (sample - px), quantized and reduced modulo the range, and
      inv says that the regular mapping is inverted (err xor -1, A.5.2).
      False: no such value. }
    function Mapped(m, c, i, k, ctx, px, sgn: Integer; inv: Boolean; out v: Integer): Boolean; virtual; abstract;
    { The reconstructed sample at column i, once known. }
    procedure Sample(c, i, x: Integer); virtual; abstract;
    { One bit of the run length code (1: a whole segment of the run). }
    function RunBit(bit, c, i, runIndex: Integer): Integer; virtual; abstract;
    { The rest of a run that stops before the end of the line, bits wide. }
    function RunRest(v, bits, c, runIndex: Integer): Integer; virtual; abstract;
    { A run of len samples from column i, now known. }
    procedure RunEnd(c, i, len: Integer); virtual; abstract;
  end;

{ C.2.4.1.1: the default gradient thresholds for MAXVAL and NEAR. }
procedure DefaultThresholds(maxval, near: Integer; out t1, t2, t3: Integer);
{ True if data starts like a JPEG-LS file (SOI, then SOF55 before any SOS). }
function IsJls(const data: TBytes): Boolean;
function DecomposeJls(const data: TBytes; out j: TJls): TJpegResult;
{ From the raw part alone: frame, parameters, scans and cuts; samples at 0. }
function ParseJlsHeaders(const raw: TBytes; out j: TJls): TJpegResult;
function RecomposeJls(const j: TJls; out data: TBytes): TJpegResult;
{ Decompose + Recompose + compare: the only thing that allows a .jls to be
  stored as samples. }
function VerifyJls(const data: TBytes; out j: TJls): TJpegResult;
{ Every scan through `symbols` instead of the bits: encoding takes the
  samples (and the recorded runs) of j; decoding fills them, and records the
  runs again. j comes from DecomposeJls or ParseJlsHeaders. }
function CodeJlsSymbols(var j: TJls; symbols: TJlsSymbols; encoding: Boolean): Boolean;

implementation

uses Math;

function JFail(e: TJpegError; p: Int64; v: Integer = 0): TJpegResult;
begin
  Result := Default(TJpegResult);
  Result.err := e; Result.pos := p; Result.value := v;
end;

function JOk: TJpegResult;
begin Result := JFail(jeNone, 0); end;

const
  { RUN_J[RUNindex]: the run lengths of the run mode (A.7.1.2) }
  RUN_J: array[0..31] of Integer = (0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                                4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15);
  MAX_K = 16;      { CharLS's limit on the Golomb parameter }

{ ---------- the parameters of a scan ---------- }

function Log2Ceil(n: Integer): Integer;
begin
  Result := 0;
  while n > (1 shl Result) do Inc(Result);
end;

{ C.2.4.1.1: the default thresholds for MAXVAL and NEAR }
procedure DefaultThresholds(maxval, near: Integer; out t1, t2, t3: Integer);
  function ClampT(i, lo: Integer): Integer;
  begin if (i > maxval) or (i < lo) then Result := lo else Result := i; end;
var factor: Integer;
begin
  if maxval >= 128 then begin
    factor := (Min(maxval, 4095) + 128) div 256;
    t1 := ClampT(factor * (3 - 2) + 2 + 3 * near, near + 1);
    t2 := ClampT(factor * (7 - 3) + 3 + 5 * near, t1);
    t3 := ClampT(factor * (21 - 4) + 4 + 7 * near, t2);
  end else begin
    factor := 256 div (maxval + 1);
    t1 := ClampT(Max(2, 3 div factor + 3 * near), near + 1);
    t2 := ClampT(Max(3, 7 div factor + 5 * near), t1);
    t3 := ClampT(Max(4, 21 div factor + 7 * near), t2);
  end;
end;

type
  TRegular = record a, b, c, n: Integer; end;
  TRunCtx = record a, n, nn, typ: Integer; end;

  { Everything a scan's coding depends on, and its adaptive state. }
  TJlsCoder = record
    near, maxval, range, qbpp, bpp, limit, reset, t1, t2, t3: Integer;
    ctx: array[0..364] of TRegular;
    run: array[0..1] of TRunCtx;
    runIndex: Integer;
    { nil: the bits of the file; otherwise where the symbols go, with the
      component (its place in the scan) and column being coded }
    symbols: TJlsSymbols;
    symC, symI: Integer;
    procedure Put(i, x: Integer); inline;
    procedure Setup(const s: TJlsScan);
    procedure ResetState;
    function Quantize(d: Integer): Integer;
    function ContextId(rd, rb, rc, ra: Integer): Integer; inline;
    function CorrectPrediction(p: Integer): Integer; inline;
    function Reconstruct(px, err: Integer): Integer;
    function ErrorValue(e: Integer): Integer;
    function UpdateRegular(var c: TRegular; err: Integer): Boolean;
    function RunK(const r: TRunCtx): Integer;
    procedure UpdateRun(var r: TRunCtx; err, m: Integer);
  end;

procedure TJlsCoder.Setup(const s: TJlsScan);
begin
  near := s.near; maxval := s.maxval;
  range := (maxval + 2 * near) div (2 * near + 1) + 1;
  qbpp := Log2Ceil(range);
  bpp := Log2Ceil(maxval);
  limit := 2 * (bpp + Max(8, bpp));
  reset := s.reset; t1 := s.t1; t2 := s.t2; t3 := s.t3;
  symbols := nil; symC := 0; symI := 0;
  ResetState;
end;

procedure TJlsCoder.ResetState;
var i, a0: Integer;
begin
  a0 := Max(2, (range + 32) div 64);
  for i := 0 to 364 do begin ctx[i].a := a0; ctx[i].b := 0; ctx[i].c := 0; ctx[i].n := 1; end;
  for i := 0 to 1 do begin run[i].a := a0; run[i].n := 1; run[i].nn := 0; run[i].typ := i; end;
  runIndex := 0;
end;

function TJlsCoder.Quantize(d: Integer): Integer;
begin
  if d <= -t3 then Result := -4
  else if d <= -t2 then Result := -3
  else if d <= -t1 then Result := -2
  else if d < -near then Result := -1
  else if d <= near then Result := 0
  else if d < t1 then Result := 1
  else if d < t2 then Result := 2
  else if d < t3 then Result := 3
  else Result := 4;
end;

function TJlsCoder.ContextId(rd, rb, rc, ra: Integer): Integer;
begin
  Result := (Quantize(rd - rb) * 9 + Quantize(rb - rc)) * 9 + Quantize(rc - ra);
end;

function TJlsCoder.CorrectPrediction(p: Integer): Integer;
begin
  if p < 0 then Result := 0 else if p > maxval then Result := maxval else Result := p;
end;

{ A.4 and the modulo of A.9: back into [0, MAXVAL] }
function TJlsCoder.Reconstruct(px, err: Integer): Integer;
var v: Integer;
begin
  v := px + err * (2 * near + 1);
  if v < -near then v := v + range * (2 * near + 1)
  else if v > maxval + near then v := v - range * (2 * near + 1);
  Result := CorrectPrediction(v);
end;

{ quantized (near-lossless) and reduced modulo RANGE }
function TJlsCoder.ErrorValue(e: Integer): Integer;
begin
  if e > 0 then e := (e + near) div (2 * near + 1)
  else e := -((near - e) div (2 * near + 1));
  if e < 0 then e := e + range;
  if e >= (range + 1) div 2 then e := e - range;
  Result := e;
end;

{ A.12, A.13: variables and bias }
function TJlsCoder.UpdateRegular(var c: TRegular; err: Integer): Boolean;
begin
  c.a := c.a + Abs(err);
  c.b := c.b + err * (2 * near + 1);
  { CharLS's bound, before halving: past it the data is garbage, and A could
    overflow before a high RESET halves it }
  if (c.a >= 65536 * 256) or (Abs(c.b) >= 65536 * 256) then Exit(False);
  if c.n = reset then begin
    c.a := c.a shr 1;
    if c.b >= 0 then c.b := c.b div 2 else c.b := -((-c.b + 1) div 2);   { b >> 1, arithmetic }
    c.n := c.n shr 1;
  end;
  Inc(c.n);
  if c.b + c.n <= 0 then begin
    c.b := c.b + c.n;
    if c.b <= -c.n then c.b := -c.n + 1;
    if c.c > -128 then Dec(c.c);
  end else if c.b > 0 then begin
    c.b := c.b - c.n;
    if c.b > 0 then c.b := 0;
    if c.c < 127 then Inc(c.c);
  end;
  Result := True;
end;

function TJlsCoder.RunK(const r: TRunCtx): Integer;
var temp, nt: Integer;
begin
  temp := r.a + (r.n shr 1) * r.typ;
  nt := r.n; Result := 0;
  while nt < temp do begin nt := nt shl 1; Inc(Result); end;
end;

procedure TJlsCoder.UpdateRun(var r: TRunCtx; err, m: Integer);
begin
  if err < 0 then Inc(r.nn);
  r.a := r.a + (m + 1 - r.typ) shr 1;
  if r.n = reset then begin
    r.a := r.a shr 1; r.n := r.n shr 1; r.nn := r.nn shr 1;
  end;
  Inc(r.n);
end;

procedure TJlsCoder.Put(i, x: Integer);
begin
  if symbols <> nil then symbols.Sample(symC, i, x);
end;

function Med(ra, rb, rc: Integer): Integer; inline;
begin
  if rc >= Max(ra, rb) then Result := Min(ra, rb)
  else if rc <= Min(ra, rb) then Result := Max(ra, rb)
  else Result := ra + rb - rc;
end;

function SignOf(n: Integer): Integer; inline;
begin
  if n < 0 then Result := -1 else Result := 1;
end;

{ ---------- bits ---------- }

type
  { Reads one restart interval: data[p..last), then zeros. After an FF byte
    the next one carries 7 bits (its top bit is a stuffed 0). }
  TJlsReader = record
    d: TBytes;
    p, last: SizeInt;
    buf: QWord;
    nbits: Integer;
    prevFF: Boolean;
    loaded, real: Int64;    { bits loaded, and of them from real bytes }
    procedure Init(const data: TBytes; first, stop: SizeInt);
    { bits consumed past the real data: a valid stream never needs any }
    function Overrun: Int64;
    procedure Fill;
    function Bit: Integer; inline;
    function Bits(n: Integer): Integer;
  end;

  { The bits of CharLS's encoder: after an FF byte, 7 bits and a 0 on top;
    at the end, the last byte padded with zeros, and a 0 byte after a final
    FF. }
  TJlsWriter = record
    d: TBytes;
    n: SizeInt;
    acc: QWord;
    nacc: Integer;
    prevFF: Boolean;
    procedure Init;
    procedure PutBits(v: Cardinal; count: Integer);
    procedure Drain;
    procedure EndScan;
  end;

procedure TJlsReader.Init(const data: TBytes; first, stop: SizeInt);
begin
  d := data; p := first; last := stop; buf := 0; nbits := 0; prevFF := False; loaded := 0; real := 0;
end;

function TJlsReader.Overrun: Int64;
begin
  Result := (loaded - nbits) - real;
end;

procedure TJlsReader.Fill;
var c: Byte; w: Integer; isReal: Boolean;
begin
  while nbits <= 48 do begin
    isReal := p < last;
    if isReal then begin c := d[p]; Inc(p); end else c := 0;
    if prevFF then begin w := 7; c := c and $7F; end else w := 8;
    Inc(loaded, w);
    if isReal then Inc(real, w);
    prevFF := c = $FF;
    buf := (buf shl w) or c;
    Inc(nbits, w);
  end;
end;

function TJlsReader.Bit: Integer;
begin
  if nbits < 1 then Fill;
  Dec(nbits);
  Result := Integer((buf shr nbits) and 1);
end;

function TJlsReader.Bits(n: Integer): Integer;
begin
  Result := 0;
  if n = 0 then Exit;
  if nbits < n then Fill;
  Dec(nbits, n);
  Result := Integer((buf shr nbits) and ((QWord(1) shl n) - 1));
end;

procedure TJlsWriter.Init;
begin
  d := nil; SetLength(d, 4096); n := 0; acc := 0; nacc := 0; prevFF := False;
end;

procedure TJlsWriter.Drain;
var w: Integer; b: Byte;
begin
  while True do begin
    if prevFF then w := 7 else w := 8;
    if nacc < w then Exit;
    Dec(nacc, w);
    b := Byte((acc shr nacc) and ((1 shl w) - 1));
    if n >= Length(d) then SetLength(d, 2 * Length(d));
    d[n] := b; Inc(n);
    prevFF := b = $FF;
  end;
end;

procedure TJlsWriter.PutBits(v: Cardinal; count: Integer);
begin
  if count = 0 then Exit;
  acc := (acc shl count) or (QWord(v) and ((QWord(1) shl count) - 1));
  Inc(nacc, count);
  if nacc >= 32 then Drain;
  acc := acc and ((QWord(1) shl nacc) - 1);
end;

procedure TJlsWriter.EndScan;
var w: Integer;
begin
  Drain;
  if nacc > 0 then begin
    if prevFF then w := 7 else w := 8;
    PutBits(0, w - nacc);
    Drain;
  end;
  if prevFF then begin PutBits(0, 7); Drain; end;
end;

{ ---------- a scan ---------- }

type
  { One component's two lines, the previous and the current, with one slot
    on each side: index i is sample i - 1. }
  TLine = array of Integer;

  TScanState = record
    cd: TJlsCoder;
    width: Integer;
    cw: array[0..3] of Integer;         { each component's width, its place in the scan }
    prev, cur: array[0..3] of TLine;
    runIdx: array[0..3] of Integer;     { line interleave: one per component }
    runs: ^TJlsScan;                    { where the run lengths go or come from }
    runPos: SizeInt;
  end;

{ NEAR > 0: decoding records each run length, encoding takes it back. }
procedure RecordRun(var st: TScanState; len: Integer);
begin
  with st.runs^ do begin
    if st.runPos >= Length(runs) then SetLength(runs, 2 * Length(runs) + 64);
    runs[st.runPos] := len;
  end;
  Inc(st.runPos);
end;

function RecordedRun(var st: TScanState; out len: Integer): Boolean;
begin
  if st.runPos >= Length(st.runs^.runs) then Exit(False);
  len := st.runs^.runs[st.runPos];
  Inc(st.runPos);
  Result := True;
end;

function DecodeValue(var rd: TJlsReader; k, limit, qbpp: Integer; out v: Integer): Boolean;
var high: Integer;
begin
  high := 0;
  while rd.Bit = 0 do begin
    Inc(high);
    if high > 64 then Exit(False);
  end;
  if high >= limit - (qbpp + 1) then v := rd.Bits(qbpp) + 1
  else if k = 0 then v := high
  else v := (high shl k) + rd.Bits(k);
  Result := True;
end;

procedure EncodeMapped(var wr: TJlsWriter; k, m, limit, qbpp: Integer);
var high: Integer;
begin
  high := m shr k;
  if high < limit - qbpp - 1 then begin
    if high + 1 > 31 then begin
      wr.PutBits(0, high div 2);
      high := high - high div 2;
    end;
    wr.PutBits(1, high + 1);
    wr.PutBits(Cardinal(m and ((1 shl k) - 1)), k);
    Exit;
  end;
  if limit - qbpp > 31 then begin
    wr.PutBits(0, 31);
    wr.PutBits(1, limit - qbpp - 31);
  end else
    wr.PutBits(1, limit - qbpp);
  wr.PutBits(Cardinal((m - 1) and ((1 shl qbpp) - 1)), qbpp);
end;

function GolombK(const c: TRegular): Integer; inline;
begin
  Result := 0;
  while ((c.n shl Result) < c.a) and (Result < MAX_K) do Inc(Result);
end;

{ A regular-mode sample: decode (x ignored) or encode x; returns the
  reconstructed sample, -1 on garbage. }
function Regular(var cd: TJlsCoder; var rd: TJlsReader; var wr: TJlsWriter; encoding: Boolean;
                 qs, x, predicted: Integer): Integer;
var sign, q, k, px, err, m: Integer; inv: Boolean;
begin
  if qs < 0 then begin sign := -1; q := -qs; end else begin sign := 0; q := qs; end;
  k := GolombK(cd.ctx[q]);
  if k >= MAX_K then Exit(-1);
  if sign <> 0 then px := cd.CorrectPrediction(predicted - cd.ctx[q].c)
  else px := cd.CorrectPrediction(predicted + cd.ctx[q].c);
  { k = 0 and lossless: the mapping is inverted when the bias is negative }
  inv := (k = 0) and (cd.near = 0) and (2 * cd.ctx[q].b + cd.ctx[q].n - 1 < 0);
  if encoding then begin
    if sign <> 0 then err := cd.ErrorValue(px - x) else err := cd.ErrorValue(x - px);
    if inv then m := err xor -1 else m := err;
    if m >= 0 then m := 2 * m else m := -2 * m - 1;
    if cd.symbols <> nil then begin
      if not cd.symbols.Mapped(m, cd.symC, cd.symI, k, q, px, 1 + 2 * sign, inv, m) then Exit(-1);
    end else
      EncodeMapped(wr, k, m, cd.limit, cd.qbpp);
  end else begin
    if cd.symbols <> nil then begin
      if not cd.symbols.Mapped(0, cd.symC, cd.symI, k, q, px, 1 + 2 * sign, inv, m) then Exit(-1);
    end else
    if not DecodeValue(rd, k, cd.limit, cd.qbpp, m) then Exit(-1);
    if m and 1 <> 0 then err := -((m + 1) shr 1) else err := m shr 1;
    if Abs(err) > 65535 then Exit(-1);
    if inv then err := err xor -1;
  end;
  if not cd.UpdateRegular(cd.ctx[q], err) then Exit(-1);
  if sign <> 0 then err := -err;
  Result := cd.Reconstruct(px, err);
end;

{ The error of a run interruption sample, with run context r. }
function InterruptionError(var cd: TJlsCoder; var rd: TJlsReader; var wr: TJlsWriter; encoding: Boolean;
                           var r: TRunCtx; err, px, sgn: Integer; out ok: Boolean): Integer;
var k, m, t, absv: Integer; map: Boolean;
begin
  ok := True;
  k := cd.RunK(r);
  if encoding then begin
    map := ((k = 0) and (err > 0) and (2 * r.nn < r.n)) or ((err < 0) and (2 * r.nn >= r.n)) or
           ((err < 0) and (k <> 0));
    m := 2 * Abs(err) - r.typ - Ord(map);
    { an interruption equal to its reference cannot happen in a valid file
      (it would have continued the run); recorded runs that disagree with
      the samples get here }
    if m < 0 then begin ok := False; Exit(0); end;
    if cd.symbols <> nil then begin
      if not cd.symbols.Mapped(m, cd.symC, cd.symI, k, 365 + r.typ, px, sgn, False, m) then begin ok := False; Exit(0); end;
    end else
      EncodeMapped(wr, k, m, cd.limit - RUN_J[cd.runIndex] - 1, cd.qbpp);
  end else begin
    if cd.symbols <> nil then begin
      if not cd.symbols.Mapped(0, cd.symC, cd.symI, k, 365 + r.typ, px, sgn, False, m) then begin ok := False; Exit(0); end;
    end else
    if not DecodeValue(rd, k, cd.limit - RUN_J[cd.runIndex] - 1, cd.qbpp, m) then begin ok := False; Exit(0); end;
    t := m + r.typ;
    map := (t and 1) <> 0;
    absv := (t + Ord(map)) div 2;
    if ((k <> 0) or (2 * r.nn >= r.n)) = map then err := -absv else err := absv;
  end;
  cd.UpdateRun(r, err, m);
  Result := err;
end;

{ A run of `run` samples (A.7.1.2), of the `left` to the end of the line:
  the bits of the file, or the symbols. }
procedure EncodeRun(var st: TScanState; var wr: TJlsWriter; c, i, run, left: Integer);
var cnt: Integer;
begin
  cnt := run;
  while cnt >= (1 shl RUN_J[st.cd.runIndex]) do begin
    if st.cd.symbols <> nil then st.cd.symbols.RunBit(1, c, i + run - cnt, st.cd.runIndex)
    else wr.PutBits(1, 1);
    cnt := cnt - (1 shl RUN_J[st.cd.runIndex]);
    st.cd.runIndex := Min(31, st.cd.runIndex + 1);
  end;
  if st.cd.symbols <> nil then begin
    if run = left then begin
      if cnt <> 0 then st.cd.symbols.RunBit(1, c, i + run - cnt, st.cd.runIndex);
    end else begin
      st.cd.symbols.RunBit(0, c, i + run - cnt, st.cd.runIndex);
      if RUN_J[st.cd.runIndex] > 0 then st.cd.symbols.RunRest(cnt, RUN_J[st.cd.runIndex], c, st.cd.runIndex);
    end;
  end else if run = left then begin
    if cnt <> 0 then wr.PutBits(1, 1);
  end else
    wr.PutBits(Cardinal(cnt), RUN_J[st.cd.runIndex] + 1);
end;

function DecodeRun(var st: TScanState; var rd: TJlsReader; c, i, left: Integer; out run: Integer): Boolean;
var cnt, bit: Integer;
begin
  run := 0;
  while True do begin
    if st.cd.symbols <> nil then bit := st.cd.symbols.RunBit(0, c, i + run, st.cd.runIndex)
    else bit := rd.Bit;
    if bit <> 1 then Break;
    cnt := Min(1 shl RUN_J[st.cd.runIndex], left - run);
    Inc(run, cnt);
    if cnt = (1 shl RUN_J[st.cd.runIndex]) then st.cd.runIndex := Min(31, st.cd.runIndex + 1);
    if run = left then Break;
  end;
  if run <> left then
    if RUN_J[st.cd.runIndex] > 0 then
      if st.cd.symbols <> nil then
        Inc(run, st.cd.symbols.RunRest(0, RUN_J[st.cd.runIndex], c, st.cd.runIndex))
      else Inc(run, rd.Bits(RUN_J[st.cd.runIndex]));
  Result := run <= left;
end;

{ A line of one component (interleave none or line). The line arrays hold
  sample i at index i + 1. }
function CodeLine(var st: TScanState; c: Integer; var rd: TJlsReader; var wr: TJlsWriter; encoding: Boolean;
                  const input: array of Word; rowBase: SizeInt; var output: array of Word): Boolean;
var w, i, ra, rb, rc, rd_, qs, x, run, left, cnt, rbI, err: Integer; ok: Boolean;
    p, cu: TLine;
begin
  w := st.cw[c];
  p := st.prev[c]; cu := st.cur[c];
  p[w + 1] := p[w];          { the sample past the end of the line above }
  cu[0] := p[1];             { the sample before the start: the one above it }
  i := 0;
  while i < w do begin
    ra := cu[i]; rb := p[i + 1]; rc := p[i]; rd_ := p[i + 2];
    qs := st.cd.ContextId(rd_, rb, rc, ra);
    st.cd.symC := c; st.cd.symI := i;
    if qs <> 0 then begin
      if encoding then x := input[rowBase + i] else x := 0;
      x := Regular(st.cd, rd, wr, encoding, qs, x, Med(ra, rb, rc));
      if x < 0 then Exit(False);
      cu[i + 1] := x;
      st.cd.Put(i, x);
      Inc(i);
      Continue;
    end;
    { run mode }
    left := w - i;
    run := 0;
    if encoding then begin
      if st.cd.near > 0 then begin
        if not RecordedRun(st, run) or (run > left) then Exit(False);
      end else
        while (run < left) and (input[rowBase + i + run] = ra) do Inc(run);
      EncodeRun(st, wr, c, i, run, left);
    end else begin
      if not DecodeRun(st, rd, c, i, left, run) then Exit(False);
      if st.cd.near > 0 then RecordRun(st, run);
    end;
    for x := 0 to run - 1 do begin cu[i + 1 + x] := ra; st.cd.Put(i + x, ra); end;
    if st.cd.symbols <> nil then st.cd.symbols.RunEnd(c, i, run);
    Inc(i, run);
    st.cd.symI := i;
    if i = w then Break;
    { the interruption sample }
    rbI := p[i + 1];
    if encoding then x := input[rowBase + i] else x := 0;
    if Abs(ra - rbI) <= st.cd.near then begin
      if encoding then err := st.cd.ErrorValue(x - ra) else err := 0;
      err := InterruptionError(st.cd, rd, wr, encoding, st.cd.run[1], err, ra, 1, ok);
      if not ok then Exit(False);
      x := st.cd.Reconstruct(ra, err);
    end else begin
      if encoding then err := st.cd.ErrorValue((x - rbI) * SignOf(rbI - ra)) else err := 0;
      err := InterruptionError(st.cd, rd, wr, encoding, st.cd.run[0], err, rbI, SignOf(rbI - ra), ok);
      if not ok then Exit(False);
      x := st.cd.Reconstruct(rbI, err * SignOf(rbI - ra));
    end;
    cu[i + 1] := x;
    st.cd.Put(i, x);
    st.cd.runIndex := Max(0, st.cd.runIndex - 1);
    Inc(i);
  end;
  { decoding only: encoding must not write into the samples it reads }
  if not encoding then
    for i := 0 to w - 1 do output[rowBase + i] := cu[i + 1];
  Result := True;
end;

type
  TSamplesPtr = array[0..3] of ^TJlsComponent;

{ A line in sample interleave: n (3 or 4) components side by side, shared
  contexts, a run only when every component is in one. }
function CodeLineSample(var st: TScanState; n: Integer; var rd: TJlsReader; var wr: TJlsWriter;
                        encoding: Boolean; const comps: TSamplesPtr; rowBase: SizeInt): Boolean;
var w, i, c, x, run, left, err: Integer; ok, allZero, near_: Boolean;
    ra, rb, rc, rd_, qs, xs: array[0..3] of Integer;
begin
  w := st.width;
  for c := 0 to n - 1 do begin
    st.prev[c][w + 1] := st.prev[c][w];
    st.cur[c][0] := st.prev[c][1];
  end;
  i := 0;
  while i < w do begin
    allZero := True;
    for c := 0 to n - 1 do begin
      ra[c] := st.cur[c][i]; rb[c] := st.prev[c][i + 1]; rc[c] := st.prev[c][i]; rd_[c] := st.prev[c][i + 2];
      qs[c] := st.cd.ContextId(rd_[c], rb[c], rc[c], ra[c]);
      if qs[c] <> 0 then allZero := False;
    end;
    if not allZero then begin
      for c := 0 to n - 1 do begin
        st.cd.symC := c; st.cd.symI := i;
        if encoding then x := comps[c]^.samples[rowBase + i] else x := 0;
        x := Regular(st.cd, rd, wr, encoding, qs[c], x, Med(ra[c], rb[c], rc[c]));
        if x < 0 then Exit(False);
        st.cur[c][i + 1] := x;
        st.cd.Put(i, x);
      end;
      Inc(i);
      Continue;
    end;
    left := w - i;
    run := 0;
    if encoding then begin
      if st.cd.near > 0 then begin
        if not RecordedRun(st, run) or (run > left) then Exit(False);
      end else
        while run < left do begin
          near_ := True;
          for c := 0 to n - 1 do
            if comps[c]^.samples[rowBase + i + run] <> ra[c] then near_ := False;
          if not near_ then Break;
          Inc(run);
        end;
      EncodeRun(st, wr, 0, i, run, left);
    end else begin
      if not DecodeRun(st, rd, 0, i, left, run) then Exit(False);
      if st.cd.near > 0 then RecordRun(st, run);
    end;
    for x := 0 to run - 1 do
      for c := 0 to n - 1 do begin
        st.cur[c][i + 1 + x] := ra[c];
        st.cd.symC := c; st.cd.Put(i + x, ra[c]);
      end;
    if st.cd.symbols <> nil then
      for c := 0 to n - 1 do st.cd.symbols.RunEnd(c, i, run);
    Inc(i, run);
    if i = w then Break;
    { the interruption: every component with run context 0 }
    for c := 0 to n - 1 do begin
      st.cd.symC := c; st.cd.symI := i;
      rb[c] := st.prev[c][i + 1];
      if encoding then begin
        xs[c] := comps[c]^.samples[rowBase + i];
        err := st.cd.ErrorValue(SignOf(rb[c] - ra[c]) * (xs[c] - rb[c]));
      end else err := 0;
      err := InterruptionError(st.cd, rd, wr, encoding, st.cd.run[0], err, rb[c], SignOf(rb[c] - ra[c]), ok);
      if not ok then Exit(False);
      st.cur[c][i + 1] := st.cd.Reconstruct(rb[c], err * SignOf(rb[c] - ra[c]));
      st.cd.Put(i, st.cur[c][i + 1]);
    end;
    st.cd.runIndex := Max(0, st.cd.runIndex - 1);
    Inc(i);
  end;
  if not encoding then
    for c := 0 to n - 1 do
      for i := 0 to w - 1 do comps[c]^.samples[rowBase + i] := st.cur[c][i + 1];
  Result := True;
end;

{ A line-interleaved scan of components with sampling factors other than
  1x1 goes by groups of lines: v lines of each component in turn (T.87
  A.2.3). Without subsampling every factor is 1 and a group is a line. }
function Grouped(const j: TJls; const s: TJlsScan): Boolean;
var c: Integer;
begin
  Result := False;
  for c := 0 to s.ncomp - 1 do
    if (j.comp[s.comp[c]].h <> 1) or (j.comp[s.comp[c]].v <> 1) then Exit(True);
end;

{ What a scan's restart intervals and CodeLines count: the lines of its
  component (no interleave), its groups (subsampled, line interleave), or
  the frame's lines }
function ScanRows(const j: TJls; const s: TJlsScan): Integer;
var c: Integer;
begin
  if s.ilv = 0 then Exit(j.comp[s.comp[0]].height);
  if not Grouped(j, s) then Exit(j.height);
  Result := 0;
  for c := 0 to s.ncomp - 1 do
    with j.comp[s.comp[c]] do Result := Max(Result, (height + v - 1) div v);
end;

procedure SwapLines(var st: TScanState; n: Integer);
var c: Integer; t: TLine;
begin
  for c := 0 to n - 1 do begin t := st.prev[c]; st.prev[c] := st.cur[c]; st.cur[c] := t; end;
end;

procedure ClearLines(var st: TScanState; n: Integer);
var c: Integer;
begin
  for c := 0 to n - 1 do begin
    FillChar(st.prev[c][0], Length(st.prev[c]) * SizeOf(Integer), 0);
    FillChar(st.cur[c][0], Length(st.cur[c]) * SizeOf(Integer), 0);
    st.runIdx[c] := 0;
  end;
end;

{ All the lines of a scan between two restarts (or all of them). }
function CodeLines(var st: TScanState; var j: TJls; const s: TJlsScan; var rd: TJlsReader; var wr: TJlsWriter;
                   encoding: Boolean; y0, y1: Integer): Boolean;
var y, c, n, k, line: Integer; comps: TSamplesPtr; dummy: array of Word; t: TLine;
begin
  n := s.ncomp;
  for c := 0 to n - 1 do comps[c] := @j.comp[s.comp[c]];
  dummy := nil;
  if (s.ilv = 1) and Grouped(j, s) then begin
    { y counts groups: v lines of each component in turn, each line of a
      component following its own previous one }
    for y := y0 to y1 - 1 do
      for c := 0 to n - 1 do
        for k := 0 to comps[c]^.v - 1 do begin
          line := y * comps[c]^.v + k;
          if line >= comps[c]^.height then Break;
          t := st.prev[c]; st.prev[c] := st.cur[c]; st.cur[c] := t;
          st.cd.runIndex := st.runIdx[c];
          if not CodeLine(st, c, rd, wr, encoding, comps[c]^.samples, SizeInt(line) * st.cw[c], comps[c]^.samples) then
            Exit(False);
          st.runIdx[c] := st.cd.runIndex;
        end;
    Exit(True);
  end;
  for y := y0 to y1 - 1 do begin
    SwapLines(st, n);
    if s.ilv = 2 then begin
      if not CodeLineSample(st, n, rd, wr, encoding, comps, SizeInt(y) * st.width) then Exit(False);
    end else
      for c := 0 to n - 1 do begin
        { line interleave: the contexts are shared, the run index is not }
        st.cd.runIndex := st.runIdx[c];
        if not CodeLine(st, c, rd, wr, encoding, comps[c]^.samples, SizeInt(y) * st.cw[c], comps[c]^.samples) then
          Exit(False);
        st.runIdx[c] := st.cd.runIndex;
      end;
  end;
  Result := True;
end;

procedure InitScanState(var st: TScanState; const j: TJls; const s: TJlsScan);
var c: Integer;
begin
  st.cd.Setup(s);
  st.width := j.width;
  for c := 0 to s.ncomp - 1 do begin
    st.cw[c] := j.comp[s.comp[c]].width;
    st.prev[c] := nil; SetLength(st.prev[c], st.cw[c] + 2);
    st.cur[c] := nil; SetLength(st.cur[c], st.cw[c] + 2);
  end;
  ClearLines(st, s.ncomp);
end;

function IsRstMarker(b: Byte): Boolean; inline;
begin Result := (b >= $D0) and (b <= $D7); end;

{ Where the scan's bytes from p end: the first FF followed by a byte with
  its top bit set (with stuffing, a data FF is followed by < $80). }
function SegmentEnd(const data: TBytes; from: SizeInt): SizeInt;
var q: SizeInt;
begin
  q := from;
  while q + 1 < Length(data) do begin
    if (data[q] = $FF) and (data[q + 1] >= $80) then Exit(q);
    Inc(q);
  end;
  Result := Length(data);
end;

function DecodeScanJls(const data: TBytes; first: SizeInt; var j: TJls; var s: TJlsScan;
                       out last: SizeInt): TJpegResult;
var st: TScanState; rd: TJlsReader; wr: TJlsWriter; y0, y1, rst: Integer; p, stop: SizeInt;
begin
  last := first;
  InitScanState(st, j, s);
  s.runs := nil; st.runs := @s; st.runPos := 0;
  wr := Default(TJlsWriter);
  p := first; y0 := 0; rst := 0;
  while y0 < ScanRows(j, s) do begin
    if s.ri > 0 then y1 := Min(ScanRows(j, s), y0 + s.ri) else y1 := ScanRows(j, s);
    stop := SegmentEnd(data, p);
    rd.Init(data, p, stop);
    if y0 > 0 then begin st.cd.ResetState; ClearLines(st, s.ncomp); end;
    if not CodeLines(st, j, s, rd, wr, False, y0, y1) then Exit(JFail(jeBadCode, rd.p));
    { a decoder that needed bits past the end read into nothing }
    if rd.Overrun > 0 then Exit(JFail(jeTruncated, stop));
    if y1 < ScanRows(j, s) then begin
      if (stop + 1 >= Length(data)) or (data[stop + 1] <> $D0 + (rst and 7)) then Exit(JFail(jeBadRst, stop));
      p := stop + 2; Inc(rst);
    end else p := stop;
    y0 := y1;
  end;
  SetLength(s.runs, st.runPos);
  last := p;
  Result := JOk;
end;

function EncodeScanJls(var out_: TBytes; var outN: SizeInt; var j: TJls; const s: TJlsScan): Boolean;
var st: TScanState; rd: TJlsReader; wr: TJlsWriter; y0, y1, rst: Integer; k: SizeInt; sc: TJlsScan;
begin
  InitScanState(st, j, s);
  sc := s; st.runs := @sc; st.runPos := 0;
  rd := Default(TJlsReader);
  y0 := 0; rst := 0;
  wr.Init;
  while y0 < ScanRows(j, s) do begin
    if s.ri > 0 then y1 := Min(ScanRows(j, s), y0 + s.ri) else y1 := ScanRows(j, s);
    if y0 > 0 then begin
      wr.EndScan;
      if wr.n + 2 > Length(wr.d) then SetLength(wr.d, 2 * Length(wr.d) + 2);
      wr.d[wr.n] := $FF; wr.d[wr.n + 1] := $D0 + (rst and 7); Inc(wr.n, 2); Inc(rst);
      wr.prevFF := False;
      st.cd.ResetState; ClearLines(st, s.ncomp);
    end;
    if not CodeLines(st, j, s, rd, wr, True, y0, y1) then Exit(False);
    y0 := y1;
  end;
  wr.EndScan;
  { every recorded run used, no more and no less }
  if (s.near > 0) and (st.runPos <> Length(s.runs)) then Exit(False);
  if outN + wr.n > Length(out_) then SetLength(out_, outN + wr.n + Length(out_) + 4096);
  for k := 0 to wr.n - 1 do out_[outN + k] := wr.d[k];
  Inc(outN, wr.n);
  Result := True;
end;

{ ---------- headers ---------- }

function U16(const d: TBytes; i: SizeInt): Integer; inline;
begin Result := (d[i] shl 8) or d[i + 1]; end;

type
  TPreset = record maxval, t1, t2, t3, reset: Integer; end;

function IsJls(const data: TBytes): Boolean;
var p: SizeInt; m: Byte;
begin
  Result := False;
  if (Length(data) < 4) or (data[0] <> $FF) or (data[1] <> $D8) then Exit;
  p := 2;
  while p + 4 <= Length(data) do begin
    if data[p] <> $FF then Exit;
    m := data[p + 1];
    if m = $F7 then Exit(True);
    if (m = $DA) or (m = $D9) or ((m >= $C0) and (m <= $CF) and (m <> $C4) and (m <> $CC)) then Exit;
    p := p + 2 + U16(data, p + 2);
  end;
end;

function Parse(const data: TBytes; decode: Boolean; out j: TJls): TJpegResult;
var p, first, last, copied, seglen: SizeInt; m: Byte; ri, i, k, c, id, ns, hmax, vmax: Integer; haveFrame: Boolean;
    preset: TPreset; s: TJlsScan; rawN: SizeInt; total: Int64; dt1, dt2, dt3: Integer;

  procedure CopyUpTo(upto: SizeInt);
  var q: SizeInt;
  begin
    if upto <= copied then Exit;
    if rawN + (upto - copied) > Length(j.raw) then SetLength(j.raw, rawN + (upto - copied) + Length(j.raw) + 4096);
    for q := copied to upto - 1 do begin j.raw[rawN] := data[q]; Inc(rawN); end;
    copied := upto;
  end;

begin
  j := Default(TJls);
  if (Length(data) < 4) or (data[0] <> $FF) or (data[1] <> $D8) then Exit(JFail(jeNotJpeg, 0));
  p := 2; copied := 0; rawN := 0; ri := 0; haveFrame := False;
  preset := Default(TPreset);
  while True do begin
    if p >= Length(data) then Exit(JFail(jeTruncated, p));
    if data[p] <> $FF then Exit(JFail(jeUnexpectedMarker, p, data[p]));
    while (p < Length(data)) and (data[p] = $FF) do Inc(p);
    if p >= Length(data) then Exit(JFail(jeTruncated, p));
    m := data[p]; Inc(p);
    if m = $D9 then Break;
    if IsRstMarker(m) then Continue;
    if (m = 0) or (m = $D8) or (m = $01) then Exit(JFail(jeUnexpectedMarker, p - 1, m));
    if p + 2 > Length(data) then Exit(JFail(jeTruncated, p));
    seglen := U16(data, p);
    if seglen < 2 then Exit(JFail(jeBadSegment, p));
    if p + seglen > Length(data) then Exit(JFail(jeTruncated, p));
    first := p + 2; last := p + seglen;
    case m of
      $F7: begin
             if haveFrame then Exit(JFail(jeRepeatedSof, p - 1));
             if last - first < 6 then Exit(JFail(jeBadSof, first));
             j.bits := data[first];
             j.height := U16(data, first + 1); j.width := U16(data, first + 3);
             k := data[first + 5];
             if (j.bits < 2) or (j.bits > 16) then Exit(JFail(jeBadSof, first));
             if (j.width = 0) or (j.height = 0) then Exit(JFail(jeUnsupported, first, m));
             if (k < 1) or (k > 4) or (last - first <> 6 + 3 * k) then Exit(JFail(jeBadSof, first));
             SetLength(j.comp, k);
             hmax := 1; vmax := 1;
             for i := 0 to k - 1 do begin
               j.comp[i].id := data[first + 6 + 3 * i];
               for c := 0 to i - 1 do if j.comp[c].id = j.comp[i].id then Exit(JFail(jeBadSof, first));
               j.comp[i].h := data[first + 7 + 3 * i] shr 4; j.comp[i].v := data[first + 7 + 3 * i] and 15;
               if (j.comp[i].h < 1) or (j.comp[i].h > 4) or (j.comp[i].v < 1) or (j.comp[i].v > 4) then
                 Exit(JFail(jeBadSof, first));
               hmax := Max(hmax, j.comp[i].h); vmax := Max(vmax, j.comp[i].v);
             end;
             { each component's own size (T.87 A.2) }
             total := 0;
             for i := 0 to k - 1 do begin
               j.comp[i].width := Integer((Int64(j.width) * j.comp[i].h + hmax - 1) div hmax);
               j.comp[i].height := Integer((Int64(j.height) * j.comp[i].v + vmax - 1) div vmax);
               Inc(total, Int64(j.comp[i].width) * j.comp[i].height);
             end;
             if total > MAX_SAMPLES then Exit(JFail(jeTooLarge, first));
             for i := 0 to k - 1 do SetLength(j.comp[i].samples, j.comp[i].width * j.comp[i].height);
             haveFrame := True;
           end;
      $F8: begin
             { LSE }
             if last - first < 1 then Exit(JFail(jeBadLse, first));
             case data[first] of
               1: begin
                    if last - first <> 11 then Exit(JFail(jeBadLse, first));
                    preset.maxval := U16(data, first + 1); preset.t1 := U16(data, first + 3);
                    preset.t2 := U16(data, first + 5); preset.t3 := U16(data, first + 7);
                    preset.reset := U16(data, first + 9);
                  end;
               2, 3: ;   { mapping tables: the samples are their indices }
             else Exit(JFail(jeUnsupported, first, $F8));
             end;
           end;
      $DD: begin
             if (seglen < 4) or (seglen > 6) then Exit(JFail(jeBadDri, first));
             ri := 0;
             for i := first to last - 1 do ri := (ri shl 8) or data[i];
           end;
      $C0..$C3, $C5..$CB, $CD..$CF: Exit(JFail(jeUnsupported, p - 1, m));
      $DA: begin
             if not haveFrame then Exit(JFail(jeUnexpectedMarker, p - 1, m));
             s := Default(TJlsScan);
             if last - first < 1 then Exit(JFail(jeBadSos, first));
             ns := data[first];
             if (ns < 1) or (ns > Length(j.comp)) or (last - first <> 4 + 2 * ns) then Exit(JFail(jeBadSos, first));
             s.ncomp := ns;
             for i := 0 to ns - 1 do begin
               id := data[first + 1 + 2 * i];
               c := -1;
               for k := 0 to High(j.comp) do if j.comp[k].id = id then c := k;
               if c < 0 then Exit(JFail(jeBadSos, first));
               for k := 0 to i - 1 do if s.comp[k] = c then Exit(JFail(jeBadSos, first));
               s.comp[i] := c;
             end;
             k := first + 1 + 2 * ns;
             s.near := data[k]; s.ilv := data[k + 1];
             if data[k + 2] <> 0 then Exit(JFail(jeUnsupported, first, $DA));   { point transform }
             if s.ilv > 2 then Exit(JFail(jeBadSos, first));
             if (s.ilv = 0) and (ns <> 1) then Exit(JFail(jeBadSos, first));
             if (s.ilv > 0) and (ns < 2) then Exit(JFail(jeBadSos, first));
             if (s.ilv = 2) and (ns < 3) then Exit(JFail(jeUnsupported, first, $DA));
             { subsampling: none in sample interleave (T.87 needs the same
               sampling there), and no restarts in line interleave, whose
               intervals would count groups of lines }
             if Grouped(j, s) and ((s.ilv = 2) or ((s.ilv = 1) and (ri > 0))) then
               Exit(JFail(jeUnsupported, first, $DA));
             { the parameters in force }
             if preset.maxval <> 0 then s.maxval := preset.maxval else s.maxval := (1 shl j.bits) - 1;
             if (s.maxval < 1) or (s.maxval > (1 shl j.bits) - 1) then Exit(JFail(jeBadLse, first));
             if s.near > Min(255, s.maxval div 2) then Exit(JFail(jeBadSos, first));
             DefaultThresholds(s.maxval, s.near, dt1, dt2, dt3);
             if preset.t1 <> 0 then s.t1 := preset.t1 else s.t1 := dt1;
             if preset.t2 <> 0 then s.t2 := preset.t2 else s.t2 := dt2;
             if preset.t3 <> 0 then s.t3 := preset.t3 else s.t3 := dt3;
             if preset.reset <> 0 then s.reset := preset.reset else s.reset := 64;
             if (s.t1 < s.near + 1) or (s.t1 > s.maxval) or (s.t2 < s.t1) or (s.t2 > s.maxval) or
                (s.t3 < s.t2) or (s.t3 > s.maxval) or (s.reset < 3) or (s.reset > Max(255, s.maxval)) then
               Exit(JFail(jeBadLse, first));
             s.ri := ri;
             CopyUpTo(last);
             s.cut := rawN;
             if decode then begin
               Result := DecodeScanJls(data, last, j, s, copied);
               if not Result.Ok then Exit;
             end;
             SetLength(j.scans, Length(j.scans) + 1);
             j.scans[High(j.scans)] := s;
             p := copied;
             if decode and (p >= Length(data)) then Break;
             if not decode then p := last;
             Continue;
           end;
    end;
    p := last;
  end;
  if Length(j.scans) = 0 then Exit(JFail(jeUnexpectedMarker, p, $D9));
  CopyUpTo(Length(data));
  SetLength(j.raw, rawN);
  Result := JOk;
end;

function DecomposeJls(const data: TBytes; out j: TJls): TJpegResult;
begin
  Result := Parse(data, True, j);
end;

function ParseJlsHeaders(const raw: TBytes; out j: TJls): TJpegResult;
begin
  Result := Parse(raw, False, j);
end;

function RecomposeJls(const j: TJls; out data: TBytes): TJpegResult;
var i: Integer; from, k: SizeInt; n: SizeInt; jj: TJls;
begin
  data := nil;
  jj := j;
  SetLength(data, Length(j.raw) + 4096);
  n := 0; from := 0;
  for i := 0 to High(j.scans) do begin
    if n + (j.scans[i].cut - from) > Length(data) then SetLength(data, n + (j.scans[i].cut - from) + 4096);
    for k := from to j.scans[i].cut - 1 do begin data[n] := j.raw[k]; Inc(n); end;
    from := j.scans[i].cut;
    if not EncodeScanJls(data, n, jj, j.scans[i]) then Exit(JFail(jeNoRoundTrip, n));
  end;
  if n + (Length(j.raw) - from) > Length(data) then SetLength(data, n + (Length(j.raw) - from));
  for k := from to High(j.raw) do begin data[n] := j.raw[k]; Inc(n); end;
  SetLength(data, n);
  Result := JOk;
end;

function CodeJlsSymbols(var j: TJls; symbols: TJlsSymbols; encoding: Boolean): Boolean;
var si, y0, y1: Integer; st: TScanState; rd: TJlsReader; wr: TJlsWriter; sc: TJlsScan;
begin
  rd := Default(TJlsReader); wr := Default(TJlsWriter);
  for si := 0 to High(j.scans) do begin
    sc := j.scans[si];
    InitScanState(st, j, sc);
    st.cd.symbols := symbols;
    symbols.BeginScan(sc, j);
    if not encoding then j.scans[si].runs := nil;
    st.runs := @j.scans[si]; st.runPos := 0;
    y0 := 0;
    while y0 < ScanRows(j, sc) do begin
      if sc.ri > 0 then y1 := Min(ScanRows(j, sc), y0 + sc.ri) else y1 := ScanRows(j, sc);
      if y0 > 0 then begin st.cd.ResetState; ClearLines(st, sc.ncomp); end;
      if not CodeLines(st, j, sc, rd, wr, encoding, y0, y1) then Exit(False);
      y0 := y1;
    end;
    if encoding then begin
      if (sc.near > 0) and (st.runPos <> Length(j.scans[si].runs)) then Exit(False);
    end else
      SetLength(j.scans[si].runs, st.runPos);
  end;
  Result := True;
end;

function VerifyJls(const data: TBytes; out j: TJls): TJpegResult;
var other: TBytes; k: SizeInt;
begin
  Result := DecomposeJls(data, j);
  if not Result.Ok then Exit;
  Result := RecomposeJls(j, other);
  if not Result.Ok then Exit;
  for k := 0 to Min(High(other), High(data)) do
    if other[k] <> data[k] then Exit(JFail(jeNoRoundTrip, k));
  if Length(other) <> Length(data) then Exit(JFail(jeNoRoundTrip, Min(Length(other), Length(data))));
  Result := JOk;
end;

end.

{ Codec layer 3: the models that turn a decomposed JPEG into bits for the
  arithmetic coder, and back.

  ONE piece of code encodes and decodes: every routine takes the value by
  `var`, codes it when encoding, and fills it when decoding. The encoder and
  the decoder cannot drift apart because they are not two programs.

  Coefficients (per block, component by component, blocks in raster order):
  1. how many AC coefficients are nonzero, in context of the neighbours'
     counts (the block above and the one to the left);
  2. each AC in zigzag order until that count runs out: zero or not, then
     the bit length in unary, the sign and the mantissa. Contexts: the
     position, how many nonzeros are left, and the magnitude of the same
     coefficient in the neighbours;
  3. the DC last, as the residual from a gradient (MED) prediction from the
     neighbouring DCs.

  The raw part (headers, tables, garbage after EOI) goes through a byte model
  of orders 0-2 mixed in the logistic domain. }
unit pjamodel;

{$I pja.inc}
{ PJA_FAST: the release build of the model, without range and overflow
  checks (they cost 2.3x here). The checked build is the reference: the
  codec suite compresses the same files with both and demands identical
  streams, and the damaged-stream test runs on the fast one too. }
{$ifdef PJA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pjamodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pjamodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, pjaarith, pjajpeg, pjajls;

type
  TCoder = record
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    procedure InitEncoder;
    procedure InitDecoder(const data: TBytes; first: SizeInt);
    { The same over a stream another thread is writing (pjaarith.TLiveStream). }
    procedure InitLiveEncoder(s: TLiveStream);
    procedure InitLiveDecoder(s: TLiveStream);
    { Codes `bit` with the counter (encoding), or decodes one (decoding);
      either way updates the counter and returns the bit. }
    function Code(var c: TAdaptiveBit; bit: Integer): Integer;
    { With an explicit probability of a one (16 bits), no counter. }
    function CodeP(p: Integer; bit: Integer): Integer;
    { `count` bits at probability 1/2. }
    function Direct(v: Cardinal; count: Integer): Cardinal;
  end;

type
  TCostKind = (ckRaw, ckNz, ckZero, ckExpo, ckMant, ckSign, ckEZero, ckEExpo, ckEMant, ckESign, ckDc);
var
  { Measurement only, in a build with -dPJA_COSTS (tests/bench_costs): with
    CollectCosts, the encoder adds up the ideal cost in bits of each kind of
    decision. Not in the codec: the hot loop writing a global from every band
    thread made each band three times slower (one cache line bouncing between
    cores; measured 19/10/2026). }
  CollectCosts: Boolean = False;
  Costs: array[TCostKind] of Double;
  CostKind: TCostKind;

{ The raw bytes of the JPEG (TJpeg.raw), length included. Decoding refuses a
  length above maxLen. }
function CodeRaw(var cd: TCoder; var raw: TBytes; maxLen: SizeInt): Boolean;
const
  { The image is coded in horizontal bands, each with its own arithmetic
    stream and its own models, so that they can be decoded in parallel. How
    many depends only on the image (one per BAND_BLOCKS blocks, at most
    MAX_BANDS, at most one per MCU row): the same file everywhere. }
  BAND_BLOCKS = 65536;
  MAX_BANDS = 16;

function BandCount(const j: TJpeg): Integer;
{ The coefficients of one band (allocated by Decompose or ParseHeaders); its
  first block row has no neighbour above. False when decoding garbage
  produces a value that does not fit. fast: the fast model (one or two
  counters per decision, nothing mixed), a different stream. }
function CodeBand(var cd: TCoder; var j: TJpeg; band: Integer; fast: Boolean = False): Boolean;

const
  { JPEG-LS: one band per JLS_BAND_SAMPLES samples, at most MAX_BANDS, at
    most one per row. }
  JLS_BAND_SAMPLES = 1 shl 20;

function JlsBandCount(const j: TJls): Integer;
{ The samples of the rows of one band, all components. }
function CodeJlsBand(var cd: TCoder; var j: TJls; band: Integer): Boolean;
{ The run lengths that near-lossless scans need to be re-encoded exactly
  (pjajls.TJlsScan.runs), for the header stream. }
function CodeJlsRuns(var cd: TCoder; var j: TJls; maxRuns: SizeInt): Boolean;
{ The other JPEG-LS model: the file's own state machine (pjajls) run over
  every scan, its symbols coded here instead of with Golomb codes. One
  stream for the whole image; it carries the run lengths as well. }
function CodeJlsSymbolStream(var cd: TCoder; var j: TJls): Boolean;

implementation

uses Math;

const
  { Adaptation limit of the counters (see TAdaptiveBit) and the mixers'
    learning rate. Constants and not settings: the decoder has to use exactly
    what the encoder used. Measured on 30 photos, 18/10/2026: limit 30..255 x
    rate 2..8, best 255 and 6-8. }
  COUNTER_LIMIT = 255;
  MIX_LR = 6;

{ ---------- coder ---------- }

procedure TCoder.InitEncoder;
begin encoding := True; enc.Init; end;

procedure TCoder.InitDecoder(const data: TBytes; first: SizeInt);
begin encoding := False; dec.Init(data, first); end;

procedure TCoder.InitLiveEncoder(s: TLiveStream);
begin encoding := True; enc.InitLive(s); end;

procedure TCoder.InitLiveDecoder(s: TLiveStream);
begin encoding := False; dec.InitLive(s); end;

procedure AddCost(p, bit: Integer);
begin
  if bit = 0 then p := 65536 - p;
  if p < 1 then p := 1;
  Costs[CostKind] := Costs[CostKind] - Ln(p / 65536) / Ln(2);
end;

function TCoder.Code(var c: TAdaptiveBit; bit: Integer): Integer;
begin
  {$ifdef PJA_COSTS}if encoding and CollectCosts then AddCost(c.p, bit);{$endif}
  if encoding then begin enc.Encode(bit, c.p); Result := bit; end
  else Result := dec.Decode(c.p);
  c.Update(Result, COUNTER_LIMIT);
end;

function TCoder.CodeP(p: Integer; bit: Integer): Integer;
begin
  {$ifdef PJA_COSTS}if encoding and CollectCosts then AddCost(p, bit);{$endif}
  if encoding then begin enc.Encode(bit, p); Result := bit; end
  else Result := dec.Decode(p);
end;

function TCoder.Direct(v: Cardinal; count: Integer): Cardinal;
begin
  if encoding then begin enc.Direct(v, count); Result := v; end
  else Result := dec.Direct(count);
end;

type
  TBits = array of TAdaptiveBit;

function BitLen(const v: Int64): Integer; inline;
begin
  if v = 0 then Result := 0
  else if v < 0 then Result := BsrQWord(QWord(-v)) + 1
  else Result := BsrQWord(QWord(v)) + 1;
end;

{ Integer division rounded to nearest, for a positive divisor. }
function DivRound(const a, b: Int64): Int64; inline;
begin
  if a >= 0 then Result := (a + b div 2) div b else Result := -((-a + b div 2) div b);
end;

procedure NewBits(var b: TBits; n: SizeInt);
var i: SizeInt; e: TAdaptiveBit;
begin
  SetLength(b, n);
  if n = 0 then Exit;
  { one counter initialized and copied over all of them: the raw-byte model
    alone has 4M, set up for every file }
  e := Default(TAdaptiveBit);
  e.Init;
  {$if SizeOf(TAdaptiveBit) = 4}
  FillDWord(b[0], n, PLongWord(@e)^);
  {$else}
  for i := 0 to n - 1 do b[i] := e;
  {$endif}
end;

{ ---------- logistic mixing ---------- }

var
  SQUASH_T: array[0..4095] of Integer;     { stretch domain -2048..2047 -> 12-bit probability }
  STRETCH_T: array[0..4095] of Integer;    { 12-bit probability -> stretch domain }

{ x div 2^n, truncating toward zero exactly like `div`, without a division. }
function TruncShr(x: Integer; n: Integer): Integer; inline;
begin
  if x >= 0 then Result := x shr n else Result := -((-x) shr n);
end;

function TruncShr64(x: Int64; n: Integer): Int64; inline;
begin
  if x >= 0 then Result := x shr n else Result := -((-x) shr n);
end;

function Squash(x: Integer): Integer; inline;
begin
  if x > 2047 then x := 2047;
  if x < -2048 then x := -2048;
  Result := SQUASH_T[x + 2048];
end;

{ p16 in [0, 65535]: every caller passes a counter's probability or a
  constant. STRETCH_T[0] is STRETCH_T[1], so no clamp is needed. }
function Stretch(p16: Integer): Integer; inline;
begin
  Result := STRETCH_T[p16 shr 4];
end;

procedure InitTables;
var i, x, pi: Integer;
begin
  for i := 0 to 4095 do
    SQUASH_T[i] := Round(4096 / (1 + Exp(-(i - 2048) / 256)));
  for i := 0 to 4095 do begin
    if SQUASH_T[i] < 1 then SQUASH_T[i] := 1;
    if SQUASH_T[i] > 4095 then SQUASH_T[i] := 4095;
  end;
  { stretch = inverse of squash: the smallest x whose squash reaches p }
  pi := 0;
  for x := -2048 to 2047 do begin
    while (pi <= SQUASH_T[x + 2048]) and (pi <= 4095) do begin STRETCH_T[pi] := x; Inc(pi); end;
  end;
  while pi <= 4095 do begin STRETCH_T[pi] := 2047; Inc(pi); end;
  STRETCH_T[0] := STRETCH_T[1];
end;

const
  MAX_INPUTS = 7;
  MAX_WEIGHT = 1 shl 17;   { 2.0 }
  LANES = 8;               { inputs padded with zeros, for SIMD }

type
  { Weights in 16.16 fixed point, one set of LANES per selector context. The
    arithmetic is 32-bit on purpose: |st| <= 2047 and |w| <= 2^17, so a
    product fits in 2^28 and up to 7 of them in 32 bits, and the SSE4.1
    version below gives exactly the same numbers. }
  TMixer = record
    n, sel, pr: Integer;
    w: array of Integer;
    st: array[0..LANES - 1] of Integer;   { the lanes past n stay 0 }
    k: Integer;
    procedure Init(inputs, sets: Integer);
    procedure Add(p16: Integer); inline;
    { The mixed probability of a one, in 16 bits. }
    function Mix(selector: Integer): Integer;
    procedure Update(bit: Integer);
  end;

var
  { Set at start-up from cpuid; PJA_NOASM=1 forces the Pascal path. Either
    path gives the same streams: only the speed changes. }
  UseSse41: Boolean = False;

{$ifdef CPUX86_64}
{$asmmode intel}
function CpuHasSse41: Boolean;
var c: LongWord;
begin
  asm
    push rbx
    mov eax, 1
    cpuid
    mov c, ecx
    pop rbx
  end ['rax', 'rcx', 'rdx'];
  Result := (c and (1 shl 19)) <> 0;
end;

{ sum of st[i] * w[i] over the 8 lanes }
function DotSse41(st, w: PInteger): Integer;
var r: Integer; ps, pw: PInteger;
begin
  { through locals: FPC keeps register parameters out of reach of asm }
  ps := st; pw := w;
  asm
    mov rax, ps
    mov rdx, pw
    movdqu xmm0, [rax]
    movdqu xmm1, [rax + 16]
    movdqu xmm2, [rdx]
    movdqu xmm3, [rdx + 16]
    pmulld xmm0, xmm2
    pmulld xmm1, xmm3
    paddd xmm0, xmm1
    pshufd xmm1, xmm0, $4E
    paddd xmm0, xmm1
    pshufd xmm1, xmm0, $B1
    paddd xmm0, xmm1
    movd r, xmm0
  end ['rax', 'rdx', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  Result := r;
end;

{ w[i] := clamp(w[i] + TruncShr(st[i] * err, 14)) over the 8 lanes. The
  truncating shift of a negative x is (x + 2^14 - 1) sar 14, the same as
  -((-x) shr 14). }
procedure UpdateSse41(st, w: PInteger; err: Integer);
const
  LOW_MASK: array[0..3] of Integer = (16383, 16383, 16383, 16383);
  W_HI: array[0..3] of Integer = (MAX_WEIGHT, MAX_WEIGHT, MAX_WEIGHT, MAX_WEIGHT);
  W_LO: array[0..3] of Integer = (-MAX_WEIGHT, -MAX_WEIGHT, -MAX_WEIGHT, -MAX_WEIGHT);
var ps, pw: PInteger; e: Integer;
begin
  ps := st; pw := w; e := err;
  asm
    mov rax, ps
    mov rdx, pw
    movd xmm4, e
    pshufd xmm4, xmm4, 0
    movdqu xmm5, [rip + LOW_MASK]
    movdqu xmm6, [rip + W_HI]
    movdqu xmm7, [rip + W_LO]
    { lanes 0..3 }
    movdqu xmm0, [rax]
    pmulld xmm0, xmm4
    movdqa xmm1, xmm0
    psrad xmm1, 31
    pand xmm1, xmm5
    paddd xmm0, xmm1
    psrad xmm0, 14
    movdqu xmm2, [rdx]
    paddd xmm2, xmm0
    pminsd xmm2, xmm6
    pmaxsd xmm2, xmm7
    movdqu [rdx], xmm2
    { lanes 4..7 }
    movdqu xmm0, [rax + 16]
    pmulld xmm0, xmm4
    movdqa xmm1, xmm0
    psrad xmm1, 31
    pand xmm1, xmm5
    paddd xmm0, xmm1
    psrad xmm0, 14
    movdqu xmm2, [rdx + 16]
    paddd xmm2, xmm0
    pminsd xmm2, xmm6
    pmaxsd xmm2, xmm7
    movdqu [rdx + 16], xmm2
  end ['rax', 'rdx', 'xmm0', 'xmm1', 'xmm2', 'xmm4', 'xmm5', 'xmm6', 'xmm7'];
end;
{$asmmode default}
{$endif}

procedure TMixer.Init(inputs, sets: Integer);
var i, j: Integer;
begin
  n := inputs; k := 0; sel := 0; pr := 2048;
  FillChar(st, SizeOf(st), 0);
  SetLength(w, LANES * sets);
  for i := 0 to sets - 1 do
    for j := 0 to LANES - 1 do
      if j < inputs then w[i * LANES + j] := 65536 div inputs else w[i * LANES + j] := 0;
end;

procedure TMixer.Add(p16: Integer);
begin
  st[k] := Stretch(p16); Inc(k);
end;

function TMixer.Mix(selector: Integer): Integer;
var i, dot: Integer;
begin
  sel := selector * LANES;
  {$ifdef CPUX86_64}
  if UseSse41 then dot := DotSse41(@st[0], @w[sel]) else
  {$endif}
  begin
    dot := 0;
    for i := 0 to n - 1 do dot := dot + st[i] * w[sel + i];
  end;
  pr := Squash(TruncShr(dot, 16));
  Result := pr shl 4;
end;

procedure TMixer.Update(bit: Integer);
var i, err, wi: Integer;
begin
  { |st| < 2^11, |err| < 2^12, MIX_LR < 2^3: the product fits in 32 bits }
  err := ((bit shl 12) - pr) * MIX_LR;
  {$ifdef CPUX86_64}
  if UseSse41 then UpdateSse41(@st[0], @w[sel], err) else
  {$endif}
  for i := 0 to n - 1 do begin
    wi := w[sel + i] + TruncShr(st[i] * err, 14);
    if wi > MAX_WEIGHT then wi := MAX_WEIGHT else if wi < -MAX_WEIGHT then wi := -MAX_WEIGHT;
    w[sel + i] := wi;
  end;
  k := 0;
end;

{ ---------- raw bytes: orders 0, 1 and 2, mixed ---------- }

const
  O2_BITS = 22;

{ The order-2 context, hashed to O2_BITS - 8 bits. It overflows on purpose. }
{$push}{$Q-}{$R-}
function Hash2(c2, c1: Cardinal): Cardinal;
begin
  { Cardinal() around the product: on 64 bits FPC multiplies two Cardinals in
    64 bits, and without it the "hash" keeps the high bits }
  Result := Cardinal((c2 shl 8 or c1) * Cardinal(2654435761)) shr (32 - O2_BITS + 8);
end;
{$pop}

threadvar
  { The raw model's tables, kept for the next file in this thread: the
    order-2 one has 4M counters (16 MB), and a JPEG's raw bytes touch a few
    thousand of them. After each use, only the counters it touched are put
    back as new (RawReset); RawDirty says a use did not finish, and then all
    of them are. The same tables as freshly allocated ones, so the same
    streams. }
  RawO0, RawO1, RawO2: TBits;
  RawDirty: Boolean;

procedure RawReset(const raw: TBytes; len: SizeInt);
var e: TAdaptiveBit; i, b, node, c1, c2: SizeInt; h: Cardinal;
begin
  e := Default(TAdaptiveBit); e.Init;
  c1 := 0; c2 := 0;
  for i := 0 to len - 1 do begin
    node := 1;
    h := Hash2(c2, c1);
    for b := 7 downto 0 do begin
      RawO0[node] := e;
      RawO1[c1 * 256 + node] := e;
      RawO2[(h shl 8) or Cardinal(node)] := e;
      node := node * 2 + (raw[i] shr b) and 1;
    end;
    c2 := c1; c1 := raw[i];
  end;
end;

function CodeRaw(var cd: TCoder; var raw: TBytes; maxLen: SizeInt): Boolean;
var mx: TMixer; len: Int64; i, b, bit, node, c1, c2: SizeInt; h: Cardinal; p: Integer;
begin
  {$ifdef PJA_COSTS}CostKind := ckRaw;{$endif}
  len := cd.Direct(Cardinal(Length(raw)), 32);
  if (len < 0) or (len > maxLen) then Exit(False);
  if not cd.encoding then SetLength(raw, len);
  if (Length(RawO2) <> 1 shl O2_BITS) or RawDirty then begin
    NewBits(RawO0, 256); NewBits(RawO1, 256 * 256); NewBits(RawO2, 1 shl O2_BITS);
  end;
  RawDirty := True;
  mx.Init(4, 8);
  c1 := 0; c2 := 0;
  for i := 0 to len - 1 do begin
    node := 1;
    h := Hash2(c2, c1);
    for b := 7 downto 0 do begin
      if cd.encoding then bit := (raw[i] shr b) and 1 else bit := 0;
      mx.Add(RawO0[node].p);
      mx.Add(RawO1[c1 * 256 + node].p);
      mx.Add(RawO2[(h shl 8) or Cardinal(node)].p);
      mx.Add(32768);
      p := mx.Mix(7 - b);
      bit := cd.CodeP(p, bit);
      mx.Update(bit);
      RawO0[node].Update(bit, COUNTER_LIMIT);
      RawO1[c1 * 256 + node].Update(bit, COUNTER_LIMIT);
      RawO2[(h shl 8) or Cardinal(node)].Update(bit, COUNTER_LIMIT);
      node := node * 2 + bit;
    end;
    if not cd.encoding then raw[i] := Byte(node - 256);
    c2 := c1; c1 := node - 256;
  end;
  RawReset(raw, len);
  RawDirty := False;
  Result := True;
end;

{ ---------- coefficients ---------- }

const
  NZ_BUCKETS = 11;     { neighbour nonzero count }
  REM_BUCKETS = 9;     { nonzeros left in this block }
  MAG_BUCKETS = 20;    { magnitude of a prediction, in half octaves (FineLog); 19 = no neighbours }
  K_BUCKETS = 11;      { position in zigzag }
  RATIO_BUCKETS = 17;  { nonzeros left / positions left, in sixteenths }
  MAX_EXP_AC = 15;     { |AC| < 2^15 }
  MAX_EXP_DC = 17;     { a DC residual can reach 2^16 }
  ACT_BUCKETS = 24;    { DC: spread of the estimates, in half octaves; 23 = no neighbours }
  NO_NEIGHBOUR = MAG_BUCKETS - 1;
  PRED_BUCKETS = 22;   { |5/8 of the edge prediction| in half octaves; 21 = no prediction }
  NO_PRED = PRED_BUCKETS - 1;
  EDGE_POS = 14;       { row 0 (v = 1..7) and column 0 (u = 1..7) }

  { bucket of a zigzag position }
  K_BUCKET_OF: array[0..63] of Byte = (
    0, 0, 1, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10);

  { BASIS[k][n] = round(c(k) * cos((2n+1) k pi / 16) * 8192), c(0) = sqrt(1/8), c(k) = 1/2.
    Integers on purpose: the predictions have to come out the same on every
    machine, and a float could round differently on another CPU. }
  BASIS: array[0..7, 0..7] of Integer = (
    ( 2896,  2896,  2896,  2896,  2896,  2896,  2896,  2896),
    ( 4017,  3406,  2276,   799,  -799, -2276, -3406, -4017),
    ( 3784,  1567, -1567, -3784, -3784, -1567,  1567,  3784),
    ( 3406,  -799, -4017, -2276,  2276,  4017,   799, -3406),
    ( 2896, -2896, -2896,  2896,  2896, -2896, -2896,  2896),
    ( 2276, -4017,   799,  3406, -3406,  -799,  4017, -2276),
    ( 1567, -3784,  3784, -1567, -1567,  3784, -3784,  1567),
    (  799, -2276,  3406, -4017,  4017, -3406,  2276,  -799));

type
  { One per class of component: luma (the first) and chroma (the rest). }
  TCoefModel = record
    nz1, nz2, nz3: TBits;
    zero1, zero2, zero3, zero4, zero5: TBits;
    expo1, expo2, expo3, expo4: TBits;
    mant1, mant, sign: TBits;
    ezero1, ezero2, ezero3, ezero4, ezero5: TBits;
    eexpo1, eexpo2, eexpo3, eexpo4, eexpo5: TBits;
    emant1, esign: TBits;
    dcZero, dcExpo, dcSign, dcMant1, dcMant: TBits;
    dz2, dz3, dz4, dx2, dx3, dx4: TBits;
    mxDcZero, mxDcExpo: TMixer;
    mxNz, mxZero, mxExpo, mxEZero, mxEExpo: TMixer;
    { the fast model: no mixer; each decision codes with one counter in a
      joint context (the pair of contexts that measured best for a static
      model), averaged with one of the full model's counters for the
      biggest decisions }
    fast, chroma: Boolean;
    fz, fx, fez, fex, fdz, fdx: TBits;
    { only the tables the chosen model uses }
    procedure Init(isFast, isChroma: Boolean);
  end;

procedure TCoefModel.Init(isFast, isChroma: Boolean);
begin
  fast := isFast; chroma := isChroma;
  { both models }
  NewBits(nz2, NZ_BUCKETS * NZ_BUCKETS * 64);
  NewBits(nz3, (NZ_BUCKETS + 1) * NZ_BUCKETS * 64);
  NewBits(zero1, 64 * REM_BUCKETS * MAG_BUCKETS);
  NewBits(zero4, K_BUCKETS * MAG_BUCKETS * REM_BUCKETS);
  NewBits(expo1, K_BUCKETS * MAG_BUCKETS * MAX_EXP_AC);
  NewBits(mant1, (MAX_EXP_AC + 1) * K_BUCKETS);
  NewBits(mant, (MAX_EXP_AC + 1) * MAX_EXP_AC);
  NewBits(sign, K_BUCKETS * 9);
  NewBits(ezero5, EDGE_POS * 12 * 4);
  NewBits(eexpo5, EDGE_POS * 12 * MAX_EXP_AC);
  NewBits(emant1, (MAX_EXP_AC + 1) * PRED_BUCKETS);
  NewBits(esign, 2 * 3 * PRED_BUCKETS);
  NewBits(dcSign, ACT_BUCKETS);
  NewBits(dcMant1, (MAX_EXP_DC + 1) * ACT_BUCKETS);
  NewBits(dcMant, (MAX_EXP_DC + 1) * MAX_EXP_DC);
  if fast then begin
    NewBits(fz, 64 * REM_BUCKETS * MAG_BUCKETS);
    NewBits(fx, K_BUCKETS * REM_BUCKETS * MAG_BUCKETS * MAX_EXP_AC);
    NewBits(fez, EDGE_POS * NZ_BUCKETS * 8 * PRED_BUCKETS);
    NewBits(fex, EDGE_POS * NZ_BUCKETS * PRED_BUCKETS * 8 * MAX_EXP_AC);
    NewBits(fdz, 20 * ACT_BUCKETS * 3);
    NewBits(fdx, ACT_BUCKETS * 3 * MAX_EXP_DC);
    Exit;
  end;
  NewBits(nz1, NZ_BUCKETS * 64);
  NewBits(zero2, 64 * MAG_BUCKETS * 4);
  NewBits(zero3, 64 * RATIO_BUCKETS);
  NewBits(zero5, 64 * (NZ_BUCKETS + 1) * REM_BUCKETS);
  NewBits(expo2, K_BUCKETS * MAG_BUCKETS * MAX_EXP_AC);
  NewBits(expo3, K_BUCKETS * REM_BUCKETS * MAX_EXP_AC);
  NewBits(expo4, MAG_BUCKETS * MAX_EXP_AC);
  NewBits(ezero1, EDGE_POS * PRED_BUCKETS);
  NewBits(ezero2, EDGE_POS * NZ_BUCKETS);
  NewBits(ezero3, EDGE_POS * 8 * PRED_BUCKETS);
  NewBits(ezero4, EDGE_POS * MAG_BUCKETS);
  NewBits(eexpo1, EDGE_POS * PRED_BUCKETS * MAX_EXP_AC);
  NewBits(eexpo2, EDGE_POS * MAG_BUCKETS * MAX_EXP_AC);
  NewBits(eexpo3, PRED_BUCKETS * 8 * MAX_EXP_AC);
  NewBits(eexpo4, EDGE_POS * NZ_BUCKETS * MAX_EXP_AC);
  NewBits(dcZero, ACT_BUCKETS);
  NewBits(dcExpo, ACT_BUCKETS * MAX_EXP_DC);
  NewBits(dz2, 20);
  NewBits(dz3, NZ_BUCKETS * 8);
  NewBits(dz4, ACT_BUCKETS * 3);
  NewBits(dx2, 20 * MAX_EXP_DC);
  NewBits(dx3, NZ_BUCKETS * 8 * MAX_EXP_DC);
  NewBits(dx4, ACT_BUCKETS * 3 * MAX_EXP_DC);
  mxDcZero.Init(5, ACT_BUCKETS);
  mxDcExpo.Init(5, MAX_EXP_DC);
  mxNz.Init(4, 6);
  mxZero.Init(6, 64);
  mxExpo.Init(5, MAX_EXP_AC * K_BUCKETS);
  mxEZero.Init(6, EDGE_POS);
  mxEExpo.Init(6, MAX_EXP_AC * EDGE_POS);
end;

function NzBucket(n: Integer): Integer;
begin
  case n of
    0..4: Result := n;
    5..6: Result := 5;
    7..8: Result := 6;
    9..12: Result := 7;
    13..18: Result := 8;
    19..27: Result := 9;
  else Result := 10;
  end;
end;

function RemBucket(n: Integer): Integer;
begin
  case n of
    1..4: Result := n - 1;
    5..6: Result := 4;
    7..9: Result := 5;
    10..14: Result := 6;
    15..22: Result := 7;
  else Result := 8;
  end;
end;


{ log2 in half steps: 0 -> 0, 1 -> 1, 2 -> 2, 3 -> 3, 4..5 -> 4, 6..7 -> 5, 8..11 -> 6... }
function FineLog(v: Int64): Integer; inline;
var e: Integer; u: QWord;
begin
  if v < 0 then u := QWord(-v) else u := QWord(v);
  if u <= 1 then Result := Integer(u)
  else begin
    e := BsrQWord(u) + 1;
    Result := 2 * e - 2 + Integer((u shr (e - 2)) and 1);
  end;
end;

function Clip(v, hi: Integer): Integer; inline;
begin
  if v > hi then Result := hi else Result := v;
end;

{ The fast model's: two counters averaged in the logistic domain, nothing
  learned. }
function CodeAvg(var cd: TCoder; var a, b: TAdaptiveBit; bit: Integer): Integer;
var sa, sb, p: Integer;
begin
  sa := Stretch(a.p); sb := Stretch(b.p);
  { both in [-2048, 2047]: so is their mean, no clamp }
  p := SQUASH_T[(sa + sb) div 2 + 2048];
  Result := cd.CodeP(p shl 4, bit);
  a.Update(Result, COUNTER_LIMIT); b.Update(Result, COUNTER_LIMIT);
end;

{ Codes a bit mixing four counters; updates all of them. }
function CodeMix(var cd: TCoder; var mx: TMixer; sel: Integer;
                 var c1, c2, c3, c4: TAdaptiveBit; bit: Integer): Integer;
begin
  mx.Add(c1.p); mx.Add(c2.p); mx.Add(c3.p); mx.Add(c4.p); mx.Add(32768 + 8192);
  Result := cd.CodeP(mx.Mix(sel), bit);
  mx.Update(Result);
  c1.Update(Result, COUNTER_LIMIT); c2.Update(Result, COUNTER_LIMIT);
  c3.Update(Result, COUNTER_LIMIT); c4.Update(Result, COUNTER_LIMIT);
end;

{ The same with five counters. }
function CodeMix5(var cd: TCoder; var mx: TMixer; sel: Integer;
                  var c1, c2, c3, c4, c5: TAdaptiveBit; bit: Integer): Integer;
begin
  mx.Add(c1.p); mx.Add(c2.p); mx.Add(c3.p); mx.Add(c4.p); mx.Add(c5.p); mx.Add(32768 + 8192);
  Result := cd.CodeP(mx.Mix(sel), bit);
  mx.Update(Result);
  c1.Update(Result, COUNTER_LIMIT); c2.Update(Result, COUNTER_LIMIT);
  c3.Update(Result, COUNTER_LIMIT); c4.Update(Result, COUNTER_LIMIT);
  c5.Update(Result, COUNTER_LIMIT);
end;

{ Mantissa of a magnitude of bit length e: the bit below the top with
  mant1[e * m1stride + m1], the rest with mant[e][bit]. }
procedure CodeMantissa(var cd: TCoder; var mant1: TBits; m1, m1stride: Integer; var mant: TBits;
                       maxE, e: Integer; var a: Integer);
var i, b: Integer;
begin
  if not cd.encoding then a := 1 shl (e - 1);
  for i := e - 2 downto 0 do begin
    if i = e - 2 then b := cd.Code(mant1[e * m1stride + m1], (a shr i) and 1)
    else b := cd.Code(mant[e * maxE + i], (a shr i) and 1);
    if not cd.encoding then a := a or (b shl i);
  end;
end;

{ |v| >= 1 with a single context row: bit length in unary with
  expo[ebase + i], then the mantissa. For the DC. }
procedure CodeMagnitude(var cd: TCoder; var expo: TBits; ebase: Integer;
                        var mant1: TBits; m1, m1stride: Integer; var mant: TBits; maxE: Integer; var a: Integer);
var e, i: Integer;
begin
  if cd.encoding then e := BitLen(a) else e := 0;
  i := 1;
  while i < maxE do begin
    if cd.Code(expo[ebase + i - 1], Ord(e > i)) = 0 then Break;
    Inc(i);
  end;
  CodeMantissa(cd, mant1, m1, m1stride, mant, maxE, i, a);
end;

function Sgn3(v: Int64): Integer; inline;
begin
  if v < 0 then Result := 0 else if v = 0 then Result := 1 else Result := 2;
end;


{ The magnitude expected at zigzag position k from the blocks already coded
  around: above and left weigh 2, above-left and above-right 1; scaled to
  the sum of two neighbours. -1 when there is none. }
function NeighbourMag(const cp: TComponent; base: SizeInt; bx, by: SizeInt; k: Integer): Integer; inline;
var sum, wsum: Integer;
begin
  sum := 0; wsum := 0;
  if by > 0 then begin
    Inc(sum, 2 * Abs(cp.coef[base - cp.bw * 64 + k])); Inc(wsum, 2);
    if bx > 0 then begin Inc(sum, Abs(cp.coef[base - cp.bw * 64 - 64 + k])); Inc(wsum); end;
    if bx + 1 < cp.bw then begin Inc(sum, Abs(cp.coef[base - cp.bw * 64 + 64 + k])); Inc(wsum); end;
  end;
  if bx > 0 then begin Inc(sum, 2 * Abs(cp.coef[base - 64 + k])); Inc(wsum, 2); end;
  { wsum is 2 to 6: a division by a constant is a multiplication }
  case wsum of
    0: Result := -1;
    2: Result := Integer(Cardinal(sum * 2 + 1) div 2);
    3: Result := Integer(Cardinal(sum * 2 + 1) div 3);
    4: Result := Integer(Cardinal(sum * 2 + 2) div 4);
    5: Result := Integer(Cardinal(sum * 2 + 2) div 5);
  else Result := Integer(Cardinal(sum * 2 + 3) div 6);
  end;
end;

type
  TByteArr = array of Byte;

var
  { 3*BASIS[i,0] - BASIS[i,1] = 2 * (B0 + (B0 - B1) / 2): this block's edge
    extrapolated half a pixel outwards, doubled (the edge predictions);
    5*BASIS[i,0] - BASIS[i,1] = 4 * (B0 + (B0 - B1) / 4): a quarter of a
    pixel, times 4 (the DC estimates) }
  W3, W5: array[0..7] of Int64;
  { the same at the far side of a block (rows and columns 7 and 6) }
  E3, E5: array[0..7] of Int64;
  { what the coefficient at a position (u * 8 + v) adds per unit to each of
    the 8 values of FillCaches's px (right and bottom edges) and of the DC
    estimate's pc and pr (left and top edges) }
  KER_RIGHT, KER_BOTTOM, KER_LEFT, KER_TOP: array[0..63, 0..7] of Int64;
  { UNZIG[natural position] = zigzag index }
  UNZIG: array[0..63] of Byte;
  { interior positions (u, v >= 1) in zigzag order, and how many of them are
    left from each one on, itself included }
  INTERIOR: array[0..48] of Byte;
  INTERIOR_LEFT: array[0..48] of Byte;
  { RATIO_OF[left, rem] = rem * 16 div left, for rem < left }
  RATIO_OF: array[1..49, 0..48] of Byte;

const
  { A dequantized coefficient is clamped here: the predictions multiply it by
    the basis three times over, and a hostile DQT of 16 bits times a coefficient
    of 15 would overflow Int64. A legitimate 8-bit JPEG stays below 2047 * 255. }
  MAX_DEQUANT = 1 shl 22;

type
  { What a finished block leaves for the next ones: along one of its edges
    (the right one for the block to its right, the bottom one for the block
    below), for each frequency of that edge, 3*E7 - E6 (the edge profile
    extrapolated half a pixel, for the edge predictions), and the 8 boundary
    pixels extrapolated the same way, 5*P7 - P6 (for the DC). }
  TEdgeCache = record
    eg: array[0..7] of Int64;
    px: array[0..7] of Int64;
  end;

  { The current block, dequantized, in natural order (row = vertical
    frequency u, column = horizontal frequency v). }
  TBlockF = array[0..63] of Int64;

function Dequant(c: Integer; q: Integer): Int64; inline;
begin
  Result := Int64(c) * q;
  if Result > MAX_DEQUANT then Result := MAX_DEQUANT
  else if Result < -MAX_DEQUANT then Result := -MAX_DEQUANT;
end;

{ The caches of a finished block, from its nonzero coefficients only. }
{ mask: a bit set for (at least) every nonzero position of fb }
const
  { the interior of column 0 (rows 1 to 7) and of row 0 (columns 1 to 7) }
  COL_INTERIOR = QWord($0101010101010100);
  ROW_INTERIOR = QWord($FE);

{ a, b := min, max, without a branch }
procedure CompareSwap(var a, b: Int64); inline;
var d, m: Int64;
begin
  d := b - a;
  m := SarInt64(d, 63);      { all ones when b < a }
  a := a + (d and m);
  b := b - (d and m);
end;

type
  TEstimates = array[0..15] of Int64;

{ The 4 smallest of 16 to e[0..3] and the 4 largest to e[12..15], and of 8,
  the 2 smallest and the 2 largest: all the trimmed mean needs. Batcher's
  odd-even merge sort with every comparator removed that the split does not
  need (checked on all 2^16 and 2^8 inputs of 0s and 1s), written out with
  constant indices. }
procedure Split16(var e: TEstimates);
begin
  CompareSwap(e[0], e[1]); CompareSwap(e[2], e[3]); CompareSwap(e[4], e[5]);
  CompareSwap(e[6], e[7]); CompareSwap(e[8], e[9]); CompareSwap(e[10], e[11]);
  CompareSwap(e[12], e[13]); CompareSwap(e[0], e[2]); CompareSwap(e[1], e[3]);
  CompareSwap(e[4], e[6]); CompareSwap(e[5], e[7]); CompareSwap(e[8], e[10]);
  CompareSwap(e[9], e[11]); CompareSwap(e[12], e[14]); CompareSwap(e[13], e[15]);
  CompareSwap(e[1], e[2]); CompareSwap(e[5], e[6]); CompareSwap(e[9], e[10]);
  CompareSwap(e[13], e[14]); CompareSwap(e[0], e[4]); CompareSwap(e[1], e[5]);
  CompareSwap(e[2], e[6]); CompareSwap(e[3], e[7]); CompareSwap(e[8], e[12]);
  CompareSwap(e[9], e[13]); CompareSwap(e[10], e[14]); CompareSwap(e[11], e[15]);
  CompareSwap(e[2], e[4]); CompareSwap(e[3], e[5]); CompareSwap(e[10], e[12]);
  CompareSwap(e[11], e[13]); CompareSwap(e[1], e[2]); CompareSwap(e[5], e[6]);
  CompareSwap(e[0], e[8]); CompareSwap(e[1], e[9]); CompareSwap(e[2], e[10]);
  CompareSwap(e[3], e[11]); CompareSwap(e[4], e[12]); CompareSwap(e[5], e[13]);
  CompareSwap(e[6], e[14]); CompareSwap(e[7], e[15]); CompareSwap(e[4], e[8]);
  CompareSwap(e[5], e[9]); CompareSwap(e[6], e[10]); CompareSwap(e[7], e[11]);
  CompareSwap(e[2], e[4]); CompareSwap(e[3], e[5]); CompareSwap(e[10], e[12]);
  CompareSwap(e[11], e[13]); CompareSwap(e[3], e[4]); CompareSwap(e[11], e[12]);
end;

procedure Split8(var e: TEstimates);
begin
  CompareSwap(e[0], e[1]); CompareSwap(e[2], e[3]); CompareSwap(e[4], e[5]);
  CompareSwap(e[0], e[2]); CompareSwap(e[1], e[3]); CompareSwap(e[4], e[6]);
  CompareSwap(e[5], e[7]); CompareSwap(e[0], e[4]); CompareSwap(e[1], e[5]);
  CompareSwap(e[2], e[6]); CompareSwap(e[3], e[7]); CompareSwap(e[2], e[4]);
  CompareSwap(e[3], e[5]); CompareSwap(e[1], e[2]); CompareSwap(e[5], e[6]);
end;

{ Everything here is linear in the coefficients, so each nonzero one adds
  its own share, precomputed per position (KER_* below): with the few
  nonzero coefficients of a typical block, far less work than the 8x8
  products it replaces, and the same integers.
    right.eg[u]  = sum over v of fb[u,v] * (3 B[v,7] - B[v,6])
    bottom.eg[v] = sum over u of fb[u,v] * (3 B[u,7] - B[u,6])
    right.px[y]  = sum over u of B[u,y] * (sum over v of fb[u,v] * (5 B[v,7] - B[v,6]))
    bottom.px[y] = sum over v of B[v,y] * (sum over u of fb[u,v] * (5 B[u,7] - B[u,6])) }
procedure FillCaches(const fb: TBlockF; mask: QWord; out right, bottom: TEdgeCache);
var pos, u, v, y: Integer; f: Int64;
begin
  for y := 0 to 7 do begin right.eg[y] := 0; bottom.eg[y] := 0; right.px[y] := 0; bottom.px[y] := 0; end;
  while mask <> 0 do begin
    pos := BsfQWord(mask);
    mask := mask and (mask - 1);
    f := fb[pos];
    u := pos shr 3; v := pos and 7;
    right.eg[u] := right.eg[u] + E3[v] * f;
    bottom.eg[v] := bottom.eg[v] + E3[u] * f;
    for y := 0 to 7 do begin
      right.px[y] := right.px[y] + KER_RIGHT[pos, y] * f;
      bottom.px[y] := bottom.px[y] + KER_BOTTOM[pos, y] * f;
    end;
  end;
end;

function CodeComponent(var cd: TCoder; var cp: TComponent; const qt: array of Word; var m: TCoefModel;
                       const lumaNz: array of Byte; lumaW, sx, sy: SizeInt; y0, y1: SizeInt;
                       out nzOut: TByteArr): Boolean;
var bx, by, k, n, nzA, nzL, ctx, node, bit, rem, v, a, l, base, abase, lbase, pos, u, w, idx: SizeInt;
    nzc, dcr: array of Byte; haveA, haveL: Boolean; rb2, nbs: Integer; res, x, e, i, ep: Integer;
    nb, ib, mbN, mbI, mbS, kb, rb, za, zb, pb, prevB, nzB, sg, lz: Integer;
    q: array[0..63] of Integer; sum, predF, pred, est, lo, hi, total, f: Int64; nest: Integer;
    pc, pr: array[0..7] of Int64; ests: TEstimates; i2: Integer; tmp: Int64;
    fb: TBlockF; fm, mm: QWord; left: Integer; leftC: TEdgeCache; rowC: array of TEdgeCache; rightC: TEdgeCache;
begin
  for k := 0 to 63 do begin
    q[k] := 1;
    if (k < Length(qt)) and (qt[k] > 0) then q[k] := qt[k];
  end;
  rowC := nil; SetLength(rowC, cp.bw);
  leftC := Default(TEdgeCache);
  nzc := nil; SetLength(nzc, cp.bw * cp.bh);
  nzOut := nil;
  dcr := nil; SetLength(dcr, cp.bw * cp.bh);
  for by := y0 to y1 - 1 do
    for bx := 0 to cp.bw - 1 do begin
      base := (by * cp.bw + bx) * 64;
      haveA := by > y0; haveL := bx > 0;
      abase := base - cp.bw * 64; lbase := base - 64;
      if not haveA then abase := base;
      if not haveL then lbase := base;

      { 1. how many interior (7x7) coefficients are nonzero, as a 6-bit tree }
      n := 0;
      if cd.encoding then
        for i := 0 to 48 do if cp.coef[base + INTERIOR[i]] <> 0 then Inc(n);
      if haveA then nzA := nzc[(by - 1) * cp.bw + bx] else nzA := 0;
      if haveL then nzL := nzc[by * cp.bw + bx - 1] else nzL := 0;
      if haveA and haveL then ctx := NzBucket((nzA + nzL + 1) div 2)
      else if haveA then ctx := NzBucket(nzA)
      else if haveL then ctx := NzBucket(nzL)
      else ctx := 0;
      if haveA then za := NzBucket(nzA) else za := 0;
      if haveL then zb := NzBucket(nzL) else zb := 0;
      { the luma block at the same spot; NZ_BUCKETS = there is none }
      if Length(lumaNz) > 0 then lz := NzBucket(lumaNz[(by * sy) * lumaW + bx * sx]) else lz := NZ_BUCKETS;
      {$ifdef PJA_COSTS}CostKind := ckNz;{$endif}
      node := 1;
      for k := 5 downto 0 do begin
        if m.fast then begin
          if m.chroma then bit := cd.Code(m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node], (n shr k) and 1)
          else bit := cd.Code(m.nz2[(za * NZ_BUCKETS + zb) * 64 + node], (n shr k) and 1);
        end else begin
          m.mxNz.Add(m.nz1[ctx * 64 + node].p);
          m.mxNz.Add(m.nz2[(za * NZ_BUCKETS + zb) * 64 + node].p);
          m.mxNz.Add(m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node].p);
          m.mxNz.Add(32768 + 8192);
          bit := cd.CodeP(m.mxNz.Mix(5 - k), (n shr k) and 1);
          m.mxNz.Update(bit);
          m.nz1[ctx * 64 + node].Update(bit, COUNTER_LIMIT);
          m.nz2[(za * NZ_BUCKETS + zb) * 64 + node].Update(bit, COUNTER_LIMIT);
          m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node].Update(bit, COUNTER_LIMIT);
        end;
        node := node * 2 + bit;
      end;
      n := node - 64;
      if n > 49 then Exit(False);   { only possible decoding garbage }
      nzc[by * cp.bw + bx] := n;
      nzB := NzBucket(n);

      { 2. the interior in zigzag, while nonzeros are left }
      rem := n;
      idx := 0;
      while (rem > 0) and (idx <= 48) do begin
        k := INTERIOR[idx];
        nb := NeighbourMag(cp, base, bx, by - y0, k);
        { the interior neighbours in this block, already coded: (u-1, v) and
          (u, v-1); row 0 and column 0 come later }
        pos := ZIGZAG[k]; u := pos shr 3; w := pos and 7;
        if (u > 1) and (w > 1) then
          ib := Abs(cp.coef[base + UNZIG[pos - 8]]) + Abs(cp.coef[base + UNZIG[pos - 1]])
        else if u > 1 then ib := 2 * Abs(cp.coef[base + UNZIG[pos - 8]])
        else if w > 1 then ib := 2 * Abs(cp.coef[base + UNZIG[pos - 1]])
        else ib := -1;
        if ib < 0 then mbI := NO_NEIGHBOUR else mbI := Clip(FineLog(ib), NO_NEIGHBOUR - 1);
        if ib < 0 then ib := 0;
        if nb < 0 then begin mbN := NO_NEIGHBOUR; mbS := Clip(FineLog(2 * ib), NO_NEIGHBOUR - 1); end
        else begin mbN := Clip(FineLog(nb), NO_NEIGHBOUR - 1); mbS := Clip(FineLog(nb + ib), NO_NEIGHBOUR - 1); end;
        kb := K_BUCKET_OF[k]; rb := RemBucket(rem);
        if cd.encoding then v := cp.coef[base + k] else v := 0;
        {$ifdef PJA_COSTS}CostKind := ckZero;{$endif}
        { when every interior position left must be nonzero, nothing to code }
        if rem >= INTERIOR_LEFT[idx] then bit := 1
        else if m.fast then begin
          if m.chroma then bit := CodeAvg(cd, m.fz[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN],
                                          m.zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb], Ord(v <> 0))
          else bit := CodeAvg(cd, m.fz[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbS],
                              m.zero1[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN], Ord(v <> 0));
        end else
          bit := CodeMix5(cd, m.mxZero, k, m.zero5[(k * (NZ_BUCKETS + 1) + lz) * REM_BUCKETS + rb],
                         m.zero1[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN],
                         m.zero2[(k * MAG_BUCKETS + mbI) * 4 + Clip(mbN, 3)],
                         m.zero3[k * RATIO_BUCKETS + RATIO_OF[INTERIOR_LEFT[idx], rem]],
                         m.zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb],
                         Ord(v <> 0));
        if bit = 1 then begin
          x := Abs(v);
          {$ifdef PJA_COSTS}CostKind := ckExpo;{$endif}
          if cd.encoding then e := BitLen(x) else e := 0;
          i := 1;
          while i < MAX_EXP_AC do begin
            if m.fast then begin
              if CodeAvg(cd, m.fx[((kb * REM_BUCKETS + rb) * MAG_BUCKETS + mbS) * MAX_EXP_AC + i - 1],
                         m.expo1[(kb * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1], Ord(e > i)) = 0 then Break;
            end else
            if CodeMix(cd, m.mxExpo, (i - 1) * K_BUCKETS + kb,
                       m.expo1[(kb * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                       m.expo2[(kb * MAG_BUCKETS + mbI) * MAX_EXP_AC + i - 1],
                       m.expo3[(kb * REM_BUCKETS + rb) * MAX_EXP_AC + i - 1],
                       m.expo4[mbS * MAX_EXP_AC + i - 1],
                       Ord(e > i)) = 0 then Break;
            Inc(i);
          end;
          {$ifdef PJA_COSTS}CostKind := ckMant;{$endif}
          CodeMantissa(cd, m.mant1, kb, K_BUCKETS, m.mant, MAX_EXP_AC, i, x);
          {$ifdef PJA_COSTS}CostKind := ckSign;{$endif}
          if haveA then ctx := Sgn3(cp.coef[abase + k]) else ctx := 1;
          if haveL then ctx := ctx * 3 + Sgn3(cp.coef[lbase + k]) else ctx := ctx * 3 + 1;
          bit := cd.Code(m.sign[kb * 9 + ctx], Ord(v < 0));
          if not cd.encoding then
            if bit = 1 then cp.coef[base + k] := -x else cp.coef[base + k] := x;
          Dec(rem);
        end;
        Inc(idx);
      end;
      if rem > 0 then Exit(False);   { only possible decoding garbage }

      { this block dequantized: the interior now, row 0 and column 0 as they
        are coded, the DC last }
      { fm marks the nonzero positions of fb, so that the loops below only
        visit those }
      FillChar(fb, SizeOf(fb), 0);
      fm := 0;
      i := 0; left := n;
      while (left > 0) and (i <= 48) do begin
        k := INTERIOR[i];
        if cp.coef[base + k] <> 0 then begin
          fb[ZIGZAG[k]] := Dequant(cp.coef[base + k], q[k]);
          fm := fm or (QWord(1) shl ZIGZAG[k]);
          Dec(left);
        end;
        Inc(i);
      end;

      { 3. row 0 and column 0, interleaved by frequency, each predicted from
        the neighbour across its edge: the pixels have to continue across
        the boundary, which in 1D DCT terms fixes the one unknown term. }
      for ep := 0 to EDGE_POS - 1 do begin
        if ep and 1 = 0 then begin u := 0; w := ep div 2 + 1; end   { row 0, from above }
        else begin u := ep div 2 + 1; w := 0; end;                     { column 0, from the left }
        k := UNZIG[u * 8 + w];
        pb := NO_PRED; predF := 0;
        { the boundary, extrapolated half a pixel from both sides, has to meet:
          3*E7 - E6 of the neighbour against 3*E0 - E1 of this block, where
          only this coefficient is unknown (E0 and E1 weigh it the same) }
        if (u = 0) and haveA then begin
          sum := 0;
          mm := fm and (COL_INTERIOR shl w);
          while mm <> 0 do begin
            pos := BsfQWord(mm); mm := mm and (mm - 1);
            sum := sum + W3[pos shr 3] * fb[pos];
          end;
          predF := DivRound(rowC[bx].eg[w] - sum, 2 * Int64(BASIS[0, 0]) * q[k]);
          tmp := DivRound(5 * predF, 8);
          pb := Clip(FineLog(tmp), NO_PRED - 1);
        end else if (w = 0) and haveL then begin
          sum := 0;
          mm := fm and (ROW_INTERIOR shl (u * 8));
          while mm <> 0 do begin
            pos := BsfQWord(mm); mm := mm and (mm - 1);
            sum := sum + W3[pos and 7] * fb[pos];
          end;
          predF := DivRound(leftC.eg[u] - sum, 2 * Int64(BASIS[0, 0]) * q[k]);
          tmp := DivRound(5 * predF, 8);
          pb := Clip(FineLog(tmp), NO_PRED - 1);
        end;
        { the neighbours' same coefficient: only the full model's counters
          use it }
        if m.fast then mbN := NO_NEIGHBOUR
        else begin
          a := 0; l := 0;
          if haveA then a := Abs(cp.coef[abase + k]);
          if haveL then l := Abs(cp.coef[lbase + k]);
          if haveA and haveL then mbN := Clip(BitLen(a + l), NO_NEIGHBOUR - 1)
          else if haveA or haveL then mbN := Clip(BitLen(2 * (a + l)), NO_NEIGHBOUR - 1)
          else mbN := NO_NEIGHBOUR;
        end;
        { the previous coefficient along this same edge }
        if ep >= 2 then begin
          if u = 0 then prevB := Clip(BitLen(cp.coef[base + UNZIG[w - 1]]), 7)
          else prevB := Clip(BitLen(cp.coef[base + UNZIG[(u - 1) * 8]]), 7);
        end else prevB := 7;
        { the interior coefficient next to it, already coded }
        if u = 0 then ib := Clip(FineLog(cp.coef[base + UNZIG[8 + w]]), 11)
        else ib := Clip(FineLog(cp.coef[base + UNZIG[u * 8 + 1]]), 11);
        if cd.encoding then v := cp.coef[base + k] else v := 0;
        {$ifdef PJA_COSTS}CostKind := ckEZero;{$endif}
        if m.fast then
          bit := CodeAvg(cd, m.fez[((ep * NZ_BUCKETS + nzB) * 8 + prevB) * PRED_BUCKETS + pb],
                         m.ezero5[(ep * 12 + ib) * 4 + Clip(pb, 3)], Ord(v <> 0))
        else
        bit := CodeMix5(cd, m.mxEZero, ep, m.ezero5[(ep * 12 + ib) * 4 + Clip(pb, 3)],
                       m.ezero1[ep * PRED_BUCKETS + pb],
                       m.ezero2[ep * NZ_BUCKETS + nzB],
                       m.ezero3[(ep * 8 + prevB) * PRED_BUCKETS + pb],
                       m.ezero4[ep * MAG_BUCKETS + mbN],
                       Ord(v <> 0));
        if bit = 1 then begin
          x := Abs(v);
          {$ifdef PJA_COSTS}CostKind := ckEExpo;{$endif}
          if cd.encoding then e := BitLen(x) else e := 0;
          i := 1;
          while i < MAX_EXP_AC do begin
            if m.fast then begin
              if m.chroma then
                ctx := ((ep * PRED_BUCKETS + pb) * NZ_BUCKETS + nzB) * 8 * MAX_EXP_AC + i - 1
              else
                ctx := (((ep * NZ_BUCKETS + nzB) * PRED_BUCKETS + pb) * 8 + prevB) * MAX_EXP_AC + i - 1;
              if CodeAvg(cd, m.fex[ctx], m.eexpo5[(ep * 12 + ib) * MAX_EXP_AC + i - 1], Ord(e > i)) = 0 then Break;
            end else
            if CodeMix5(cd, m.mxEExpo, (i - 1) * EDGE_POS + ep, m.eexpo5[(ep * 12 + ib) * MAX_EXP_AC + i - 1],
                       m.eexpo1[(ep * PRED_BUCKETS + pb) * MAX_EXP_AC + i - 1],
                       m.eexpo2[(ep * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                       m.eexpo3[(pb * 8 + prevB) * MAX_EXP_AC + i - 1],
                       m.eexpo4[(ep * NZ_BUCKETS + nzB) * MAX_EXP_AC + i - 1],
                       Ord(e > i)) = 0 then Break;
            Inc(i);
          end;
          {$ifdef PJA_COSTS}CostKind := ckEMant;{$endif}
          CodeMantissa(cd, m.emant1, pb, PRED_BUCKETS, m.mant, MAX_EXP_AC, i, x);
          {$ifdef PJA_COSTS}CostKind := ckESign;{$endif}
          if pb = NO_PRED then sg := 1 else sg := Sgn3(predF);
          bit := cd.Code(m.esign[((ep and 1) * 3 + sg) * PRED_BUCKETS + pb], Ord(v < 0));
          if not cd.encoding then
            if bit = 1 then cp.coef[base + k] := -x else cp.coef[base + k] := x;
        end;
      end;

      for ep := 0 to EDGE_POS - 1 do begin
        if ep and 1 = 0 then pos := ep div 2 + 1 else pos := (ep div 2 + 1) * 8;
        k := UNZIG[pos];
        if cp.coef[base + k] <> 0 then begin
          fb[pos] := Dequant(cp.coef[base + k], q[k]);
          fm := fm or (QWord(1) shl pos);
        end;
      end;

      { 4. the DC, estimated pixel by pixel along both edges (Lepton's idea):
        each boundary pixel, extrapolated with its gradient from the
        neighbour and from this block (whose AC is all known now), says what
        the DC must be. The mean of up to 16 estimates is the prediction,
        and their spread the context. }
      { this block's boundary without its DC, extrapolated the same way:
        5*P0 - P1, per column (left edge) and per row (top edge) }
      { linear in the coefficients, like FillCaches:
          pc[i] = sum over u of B[u,i] * (sum over w of W5[w] fb[u,w])
          pr[i] = sum over w of B[w,i] * (sum over u of W5[u] fb[u,w]) }
      for i := 0 to 7 do begin pc[i] := 0; pr[i] := 0; end;
      mm := fm;
      while mm <> 0 do begin
        pos := BsfQWord(mm);
        mm := mm and (mm - 1);
        f := fb[pos];
        for i := 0 to 7 do begin
          pc[i] := pc[i] + KER_LEFT[pos, i] * f;
          pr[i] := pr[i] + KER_TOP[pos, i] * f;
        end;
      end;
      nest := 0; total := 0; lo := High(Int64); hi := Low(Int64);
      if haveL then begin
        for i := 0 to 7 do begin
          est := (leftC.px[i] - pc[i]) div 4;
          ests[nest] := est; Inc(nest);
          if est < lo then lo := est;
          if est > hi then hi := est;
        end;
      end;
      if haveA then begin
        for i := 0 to 7 do begin
          est := (rowC[bx].px[i] - pr[i]) div 4;
          ests[nest] := est; Inc(nest);
          if est < lo then lo := est;
          if est > hi then hi := est;
        end;
      end;
      { the middle half of the sorted estimates }
      if nest = 16 then Split16(ests) else if nest = 8 then Split8(ests);
      total := 0;
      for i := nest div 4 to nest - 1 - nest div 4 do total := total + ests[i];
      if nest > 0 then nest := nest - 2 * (nest div 4);
      { a pixel gets DC * BASIS[0,0]^2: back to a quantized DC }
      if nest > 0 then begin
        pred := DivRound(total, Int64(nest) * BASIS[0, 0] * BASIS[0, 0] * q[0]);
        tmp := DivRound(hi - lo, Int64(BASIS[0, 0]) * BASIS[0, 0] * q[0]);
        ctx := Clip(FineLog(tmp), ACT_BUCKETS - 2);
      end else begin pred := 0; ctx := ACT_BUCKETS - 1; end;
      if pred > 32767 then pred := 32767;
      if pred < -32767 then pred := -32767;
      {$ifdef PJA_COSTS}CostKind := ckDc;{$endif}
      if cd.encoding then res := cp.coef[base] - Integer(pred) else res := 0;
      { the neighbours' DC residuals, and how many neighbours there are }
      rb2 := 0; nbs := 0;
      if haveA then begin Inc(rb2, dcr[(by - 1) * cp.bw + bx]); Inc(nbs); end;
      if haveL then begin Inc(rb2, dcr[by * cp.bw + bx - 1]); Inc(nbs); end;
      rb2 := Clip(rb2, 19);
      if m.fast then
        bit := cd.Code(m.fdz[(rb2 * ACT_BUCKETS + ctx) * 3 + nbs], Ord(res <> 0))
      else
      bit := CodeMix(cd, m.mxDcZero, ctx, m.dcZero[ctx], m.dz2[rb2], m.dz3[nzB * 8 + ctx div 3],
                     m.dz4[ctx * 3 + nbs], Ord(res <> 0));
      if bit = 1 then begin
        x := Abs(res);
        if cd.encoding then e := BitLen(x) else e := 0;
        i := 1;
        while i < MAX_EXP_DC do begin
          if m.fast then begin
            if cd.Code(m.fdx[(ctx * 3 + nbs) * MAX_EXP_DC + i - 1], Ord(e > i)) = 0 then Break;
          end else
          if CodeMix(cd, m.mxDcExpo, i - 1, m.dcExpo[ctx * MAX_EXP_DC + i - 1], m.dx2[rb2 * MAX_EXP_DC + i - 1],
                     m.dx3[(nzB * 8 + ctx div 3) * MAX_EXP_DC + i - 1],
                     m.dx4[(ctx * 3 + nbs) * MAX_EXP_DC + i - 1], Ord(e > i)) = 0 then Break;
          Inc(i);
        end;
        CodeMantissa(cd, m.dcMant1, ctx, ACT_BUCKETS, m.dcMant, MAX_EXP_DC, i, x);
        bit := cd.Code(m.dcSign[ctx], Ord(res < 0));
        if bit = 1 then res := -x else res := x;
      end;
      dcr[by * cp.bw + bx] := Clip(FineLog(res), 15);
      if not cd.encoding then begin
        x := Integer(pred) + res;
        if (x < -32767) or (x > 32767) then Exit(False);
        cp.coef[base] := x;
      end;
      fb[0] := Dequant(cp.coef[base], q[0]);
      FillCaches(fb, fm or 1, rightC, rowC[bx]);
      leftC := rightC;
    end;
  nzOut := nzc;
  Result := True;
end;

function BandCount(const j: TJpeg): Integer;
var total: Int64; c: Integer;
begin
  total := 0;
  for c := 0 to High(j.comp) do Inc(total, Int64(j.comp[c].bw) * j.comp[c].bh);
  Result := Integer(total div BAND_BLOCKS);
  if Result > MAX_BANDS then Result := MAX_BANDS;
  if Result > j.mcusy then Result := j.mcusy;
  if Result < 1 then Result := 1;
end;

function CodeBand(var cd: TCoder; var j: TJpeg; band: Integer; fast: Boolean): Boolean;
var c, nb: Integer; luma, chroma: TCoefModel; ok: Boolean; lumaNz, other: TByteArr; sx, sy, m0, m1: SizeInt;
begin
  nb := BandCount(j);
  if (band < 0) or (band >= nb) then Exit(False);
  m0 := SizeInt(j.mcusy) * band div nb; m1 := SizeInt(j.mcusy) * (band + 1) div nb;
  luma.Init(fast, False); chroma.Init(fast, True);
  lumaNz := nil;
  for c := 0 to High(j.comp) do begin
    if c = 0 then
      ok := CodeComponent(cd, j.comp[c], j.qt[j.comp[c].tq], luma, [], 0, 0, 0,
                          m0 * j.comp[c].v, m1 * j.comp[c].v, lumaNz)
    else begin
      { how many luma blocks one of ours spans; a component sampled finer
        than the luma (H or V above it) maps to its first block }
      sx := j.comp[0].h div j.comp[c].h; sy := j.comp[0].v div j.comp[c].v;
      if (sx < 1) or (sy < 1) or (j.comp[c].bw * sx > j.comp[0].bw) or (j.comp[c].bh * sy > j.comp[0].bh) then
        ok := CodeComponent(cd, j.comp[c], j.qt[j.comp[c].tq], chroma, [], 0, 0, 0,
                            m0 * j.comp[c].v, m1 * j.comp[c].v, other)
      else
        ok := CodeComponent(cd, j.comp[c], j.qt[j.comp[c].tq], chroma, lumaNz, j.comp[0].bw, sx, sy,
                            m0 * j.comp[c].v, m1 * j.comp[c].v, other);
    end;
    if not ok then Exit(False);
  end;
  Result := True;
end;


{ ---------- JPEG-LS samples ----------

  Each sample is predicted with MED plus a bias correction per gradient
  context (the LOCO-I idea), and the residual, aligned by the context's sign
  and reduced modulo the range, goes through the arithmetic coder: zero or
  not, bit length in unary, mantissa, sign. The zero and bit-length
  decisions mix four counters: the context's mean residual, the context
  itself, the neighbours' residuals, and for the second and later
  components the residual of the first one at the same pixel. Rows go
  component after component, so that the first component's residual of the
  same row is known. }

const
  JLS_CTX = 365;
  JLS_ACT = 24;         { FineLog of the context's mean |residual| }
  JLS_NB = 24;          { FineLog of the neighbours' |residuals| }
  JLS_FIRST = 25;       { FineLog of the first component's |residual|; 24 = none }
  JLS_MAX_EXP = 18;     { a residual is below 2^17 }

type
  TJlsBias = record a, b, c, n: Integer; end;

  TJlsModel = record
    bias: array[0..1, 0..JLS_CTX - 1] of TJlsBias;     { [first component or not] }
    z1, z2, z3, z4: TBits;
    x1, x2, x3, x4: TBits;
    m1, mm, sg: TBits;
    mxZ, mxX: TMixer;
    procedure Init;
  end;

procedure TJlsModel.Init;
var k, c: Integer;
begin
  for c := 0 to 1 do
    for k := 0 to JLS_CTX - 1 do begin bias[c, k].a := 4; bias[c, k].b := 0; bias[c, k].c := 0; bias[c, k].n := 1; end;
  NewBits(z1, 2 * JLS_ACT);
  NewBits(z2, 2 * JLS_CTX);
  NewBits(z3, 2 * JLS_NB * 4);
  NewBits(z4, JLS_FIRST * JLS_ACT);
  NewBits(x1, 2 * JLS_ACT * JLS_MAX_EXP);
  NewBits(x2, 2 * JLS_CTX * JLS_MAX_EXP);
  NewBits(x3, 2 * JLS_NB * JLS_MAX_EXP);
  NewBits(x4, JLS_FIRST * JLS_MAX_EXP);
  NewBits(m1, (JLS_MAX_EXP + 1) * JLS_ACT);
  NewBits(mm, (JLS_MAX_EXP + 1) * JLS_MAX_EXP);
  NewBits(sg, 2 * JLS_ACT * 9);
  mxZ.Init(5, 2 * JLS_ACT);
  mxX.Init(5, 2 * JLS_MAX_EXP);
end;

function JlsBandCount(const j: TJls): Integer;
var total: Int64;
begin
  total := Int64(j.width) * j.height * Length(j.comp);
  Result := Integer(total div JLS_BAND_SAMPLES);
  if Result > MAX_BANDS then Result := MAX_BANDS;
  if Result > j.height then Result := j.height;
  if Result < 1 then Result := 1;
end;

function JlsQuantize(d, t1, t2, t3: Integer): Integer; inline;
begin
  if d <= -t3 then Result := -4
  else if d <= -t2 then Result := -3
  else if d <= -t1 then Result := -2
  else if d < 0 then Result := -1
  else if d = 0 then Result := 0
  else if d < t1 then Result := 1
  else if d < t2 then Result := 2
  else if d < t3 then Result := 3
  else Result := 4;
end;

function MedPredict(a, b, c: Integer): Integer; inline;
begin
  if c >= Max(a, b) then Result := Min(a, b)
  else if c <= Min(a, b) then Result := Max(a, b)
  else Result := a + b - c;
end;

function CodeJlsBand(var cd: TCoder; var j: TJls; band: Integer): Boolean;
var m: TJlsModel; nb, ci, cls, i, maxv, range, half, t1, t2, t3, a, b, c, d, ctx, sgn, px, x, e, v, ex, k,
    bit, act, nbb, first, bi: Integer; y, y0, y1, base, w: SizeInt; haveUp: Boolean;
    res: array of array of Integer;       { [component] this row's residuals }
    resUp: array of array of Integer;     { [component] the row above's }
    t: array of Integer;
    bs: ^TJlsBias;
begin
  nb := JlsBandCount(j);
  if (band < 0) or (band >= nb) then Exit(False);
  y0 := SizeInt(j.height) * band div nb; y1 := SizeInt(j.height) * (band + 1) div nb;
  w := j.width;
  maxv := (1 shl j.bits) - 1; range := maxv + 1; half := (maxv + 1) div 2;
  DefaultThresholds(maxv, 0, t1, t2, t3);
  m.Init;
  res := nil; resUp := nil;
  SetLength(res, Length(j.comp)); SetLength(resUp, Length(j.comp));
  for ci := 0 to High(j.comp) do begin
    SetLength(res[ci], w); SetLength(resUp[ci], w);
  end;
  for y := y0 to y1 - 1 do begin
    haveUp := y > y0;
    for ci := 0 to High(j.comp) do begin
      t := res[ci]; res[ci] := resUp[ci]; resUp[ci] := t;
      if ci = 0 then cls := 0 else cls := 1;
      base := y * w;
      for i := 0 to w - 1 do begin
        { the neighbours; a missing one takes the nearest present }
        if haveUp then b := j.comp[ci].samples[base - w + i]
        else if i > 0 then b := j.comp[ci].samples[base + i - 1]
        else b := half;
        if i > 0 then a := j.comp[ci].samples[base + i - 1] else a := b;
        if haveUp and (i > 0) then c := j.comp[ci].samples[base - w + i - 1] else c := b;
        if haveUp and (i + 1 < w) then d := j.comp[ci].samples[base - w + i + 1] else d := b;
        ctx := (JlsQuantize(d - b, t1, t2, t3) * 9 + JlsQuantize(b - c, t1, t2, t3)) * 9 + JlsQuantize(c - a, t1, t2, t3);
        if ctx < 0 then begin sgn := -1; ctx := -ctx; end else sgn := 1;
        bs := @m.bias[cls, ctx];
        px := MedPredict(a, b, c) + sgn * bs^.c;
        if px < 0 then px := 0 else if px > maxv then px := maxv;
        { the residual, aligned and reduced modulo the range }
        if cd.encoding then begin
          e := (j.comp[ci].samples[base + i] - px) * sgn;
          if e < -(range div 2) then e := e + range
          else if e >= (range + 1) div 2 then e := e - range;
        end else e := 0;
        act := Clip(FineLog(bs^.a div bs^.n), JLS_ACT - 1);
        nbb := 0;
        if i > 0 then Inc(nbb, Abs(res[ci][i - 1]));
        if haveUp then Inc(nbb, Abs(resUp[ci][i]));
        nbb := Clip(FineLog(nbb), JLS_NB - 1);
        if ci > 0 then first := Clip(FineLog(res[0][i]), JLS_FIRST - 2) else first := JLS_FIRST - 1;
        bi := cls * JLS_ACT + act;
        { zero or not }
        bit := CodeMix(cd, m.mxZ, bi, m.z1[bi], m.z2[cls * JLS_CTX + ctx],
                       m.z3[(cls * JLS_NB + nbb) * 4 + Clip(act, 3)], m.z4[first * JLS_ACT + act], Ord(e <> 0));
        if bit <> 0 then begin
          v := Abs(e);
          if cd.encoding then ex := BitLen(v) else ex := 0;
          k := 1;
          while k < JLS_MAX_EXP do begin
            if CodeMix(cd, m.mxX, cls * JLS_MAX_EXP + k - 1,
                       m.x1[bi * JLS_MAX_EXP + k - 1], m.x2[(cls * JLS_CTX + ctx) * JLS_MAX_EXP + k - 1],
                       m.x3[(cls * JLS_NB + nbb) * JLS_MAX_EXP + k - 1], m.x4[first * JLS_MAX_EXP + k - 1],
                       Ord(ex > k)) = 0 then Break;
            Inc(k);
          end;
          CodeMantissa(cd, m.m1, act, JLS_ACT, m.mm, JLS_MAX_EXP, k, v);
          { the sign, with the neighbours' signs }
          bit := 0;
          if (i > 0) and (res[ci][i - 1] < 0) then bit := 1 else if (i > 0) and (res[ci][i - 1] > 0) then bit := 2;
          if haveUp then begin
            if resUp[ci][i] < 0 then bit := bit + 3 else if resUp[ci][i] > 0 then bit := bit + 6;
          end;
          if cd.Code(m.sg[bi * 9 + bit], Ord(e < 0)) <> 0 then e := -v else e := v;
        end;
        if not cd.encoding then begin
          x := px + e * sgn;
          if x < 0 then x := x + range else if x > maxv then x := x - range;
          if (x < 0) or (x > maxv) then Exit(False);
          j.comp[ci].samples[base + i] := x;
        end;
        res[ci][i] := e;
        { LOCO's bias update (A.12, A.13), NEAR 0 }
        bs^.a := bs^.a + Abs(e); bs^.b := bs^.b + e;
        if bs^.n = 64 then begin
          bs^.a := bs^.a shr 1;
          if bs^.b >= 0 then bs^.b := bs^.b div 2 else bs^.b := -((-bs^.b + 1) div 2);
          bs^.n := bs^.n shr 1;
        end;
        Inc(bs^.n);
        if bs^.b + bs^.n <= 0 then begin
          bs^.b := bs^.b + bs^.n;
          if bs^.b <= -bs^.n then bs^.b := -bs^.n + 1;
          if bs^.c > -128 then Dec(bs^.c);
        end else if bs^.b > 0 then begin
          bs^.b := bs^.b - bs^.n;
          if bs^.b > 0 then bs^.b := 0;
          if bs^.c < 127 then Inc(bs^.c);
        end;
      end;
    end;
  end;
  Result := True;
end;

{ The run lengths of the near-lossless scans: a count (32 bits), then each
  length as an adaptive Elias-gamma code. }
function CodeJlsRuns(var cd: TCoder; var j: TJls; maxRuns: SizeInt): Boolean;
var s, n, i, e, k, b: Integer; x: Cardinal; ex, mn: TBits; v: Int64;
begin
  NewBits(ex, 32); NewBits(mn, 32 * 32);
  for s := 0 to High(j.scans) do begin
    if j.scans[s].near = 0 then Continue;
    n := Integer(cd.Direct(Cardinal(Length(j.scans[s].runs)), 32));
    if (n < 0) or (n > maxRuns) then Exit(False);
    if not cd.encoding then SetLength(j.scans[s].runs, n);
    for i := 0 to n - 1 do begin
      if cd.encoding then x := Cardinal(j.scans[s].runs[i]) + 1 else x := 0;
      if cd.encoding then e := BitLen(x) - 1 else e := 0;
      k := 0;
      while k < 31 do begin
        if cd.Code(ex[k], Ord(e > k)) = 0 then Break;
        Inc(k);
      end;
      v := 1;
      for b := k - 1 downto 0 do v := (v shl 1) or cd.Code(mn[k * 32 + b], Integer((x shr b) and 1));
      { a run never goes past its line }
      if v - 1 > j.width then Exit(False);
      if not cd.encoding then j.scans[s].runs[i] := Integer(v - 1);
    end;
  end;
  Result := True;
end;

{ ---------- JPEG-LS symbols ----------

  A mapped error value is coded as its bit length in unary and its mantissa.
  The model keeps the reconstructed samples and makes a second prediction,
  CALIC's GAP corrected by the mean error of its texture context, and from
  it the mapped value JPEG-LS would see if that prediction were right. The
  unary decisions mix seven counters: JPEG-LS's Golomb parameter k (the
  context's mean magnitude), its gradient context, the neighbours' values,
  the first component's value at the same column, that expected value, the
  gradients' energy, and the texture. The mantissa's lowest bit, which is
  the error's sign, goes in context of the expected error's sign. A run
  bit is in context of the run index and of what the line above had there.

  Measured on 19/10/2026 against the JPEG-LS files: 16 photos 84.35%
  (the sample model 89.63%), 8 ISO and HP test images 92.03% (97.16%). }

const
  SYM_K = 17;           { k: 0..16 }
  SYM_CTX = 367;        { 1..364 regular, 365 and 366 the interruptions }
  SYM_NB = 24;          { FineLog of the neighbours' sum }
  SYM_X = 20;           { FineLog of the first component's value; 19 = none }
  SYM_E = 19;           { a mapped value is below 2^18 }
  SYM_ACT = 24;         { FineLog of the gradients }
  SYM_TEX = 2 * 256 * 4;  { [first component or not][texture][energy] }

type
  TJlsSymModel = class(TJlsSymbols)
    cd: ^TCoder;
    f1, f2, f3, f4, f5, f6, f7: TBits;
    m1, mm, lsb: TBits;
    rb, rr: TBits;
    mx: TMixer;
    biasSum, biasN: array[0..SYM_TEX - 1] of Integer;
    { [component] at column + 1, the value at the left and, from i on, the
      one of the line above: |r| (or the mapped value of an interruption, 0
      in a run), and |sample - prediction| }
    vals, errs: array[0..3] of array of Integer;
    { [component][line] the reconstructed samples, 0 the current line, at
      column + 2 }
    lines: array[0..3, 0..2] of array of Integer;
    { [component] the sample just coded in regular mode: its texture
      context and prediction, to learn from the sample when it comes }
    pendTex, pendP, pendP2: array[0..3] of Integer;
    w, near, maxval, scale: Integer;
    constructor Create(var coder: TCoder);
    procedure BeginScan(const s: TJlsScan; width: Integer); override;
    function Mapped(m, c, i, k, ctx, px, sgn: Integer; inv: Boolean; out v: Integer): Boolean; override;
    procedure Sample(c, i, x: Integer); override;
    function RunBit(bit, c, i, runIndex: Integer): Integer; override;
    function RunRest(v, bits, c, runIndex: Integer): Integer; override;
    procedure RunEnd(c, i, len: Integer); override;
  end;

constructor TJlsSymModel.Create(var coder: TCoder);
var k: Integer;
begin
  inherited Create;
  cd := @coder;
  NewBits(f1, 3 * SYM_K * SYM_E);
  NewBits(f2, SYM_CTX * SYM_E);
  NewBits(f3, 3 * SYM_NB * SYM_E);
  NewBits(f4, SYM_X * SYM_K * SYM_E);
  NewBits(f5, 16 * SYM_K * SYM_E);
  NewBits(f6, SYM_ACT * SYM_K * SYM_E);
  NewBits(f7, SYM_TEX * SYM_E);
  NewBits(m1, (SYM_E + 1) * 16 * SYM_K);
  NewBits(mm, (SYM_E + 1) * 16 * SYM_E);
  NewBits(lsb, 3 * 15 * (SYM_E + 1) * 3);
  NewBits(rb, 2 * 32 * 8);
  NewBits(rr, 32 * 80);
  mx.Init(8, 3 * SYM_K * SYM_E);
  for k := 0 to SYM_TEX - 1 do begin biasSum[k] := 0; biasN[k] := 1; end;
end;

procedure TJlsSymModel.BeginScan(const s: TJlsScan; width: Integer);
var c, l: Integer;
begin
  w := width; near := s.near; maxval := s.maxval;
  { the gradient thresholds below are for 8 bits }
  scale := Max(1, (maxval + 1) div 256);
  for c := 0 to 3 do begin
    vals[c] := nil; errs[c] := nil;
    if c < s.ncomp then begin SetLength(vals[c], width + 2); SetLength(errs[c], width + 2); end;
    for l := 0 to 2 do begin
      lines[c, l] := nil;
      if c < s.ncomp then SetLength(lines[c, l], width + 4);
    end;
    pendTex[c] := -1;
  end;
end;

procedure TJlsSymModel.Sample(c, i, x: Integer);
var t: array of Integer; k: Integer;
begin
  if i = 0 then begin
    t := lines[c, 2]; lines[c, 2] := lines[c, 1]; lines[c, 1] := lines[c, 0]; lines[c, 0] := t;
  end;
  lines[c, 0][i + 2] := x;
  k := pendTex[c];
  if k >= 0 then begin
    { CALIC's error feedback: the mean of x - GAP per texture context }
    biasSum[k] := biasSum[k] + (x - pendP2[c]);
    Inc(biasN[k]);
    if biasN[k] >= 256 then begin biasSum[k] := biasSum[k] div 2; biasN[k] := biasN[k] div 2; end;
    errs[c][i + 1] := Abs(x - pendP[c]);
    pendTex[c] := -1;
  end else errs[c][i + 1] := 0;
end;

function SignedLog(v, hi: Integer): Integer; inline;
var f: Integer;
begin
  f := FineLog(v);
  if f > hi then f := hi;
  if v < 0 then Result := -f else Result := f;
end;

{ The mapping of A.5.2, both ways. }
function UnmapErr(m: Integer): Integer; inline;
begin
  if m and 1 <> 0 then Result := -((m + 1) shr 1) else Result := m shr 1;
end;

function MapErr(e: Integer): Integer; inline;
begin
  if e >= 0 then Result := 2 * e else Result := -2 * e - 1;
end;

function TJlsSymModel.Mapped(m, c, i, k, ctx, px, sgn: Integer; inv: Boolean; out v: Integer): Boolean;
var kind, kk, nb, x, e, t, sel, b, bit, act, q, tex, ex, me, eb, mb: Integer;
    row, l0, l1, l2: array of Integer;
    wa, wwa, nn, nw, ne, nnb, nne, dh, dv, p2, p3, delta: Integer;
    c1, c2, c3, c4, c5, c6, c7: ^TAdaptiveBit;
begin
  v := 0;
  if ctx >= 365 then kind := 1 + ctx - 365 else kind := 0;
  kk := Min(k, SYM_K - 1);
  row := vals[c];
  { left, above, above right: the line above is still there right of i }
  nb := Clip(FineLog(Int64(row[i]) + row[i + 1] + row[i + 2] div 2), SYM_NB - 1);
  if c > 0 then x := Clip(FineLog(vals[0][i + 1]), SYM_X - 2) else x := SYM_X - 1;
  q := 2 * near + 1;
  { a second prediction, CALIC's GAP with its error feedback, and the
    mapped value JPEG-LS would see if it were right }
  l0 := lines[c, 0]; l1 := lines[c, 1]; l2 := lines[c, 2];
  wa := l0[i + 1]; wwa := l0[i]; nn := l1[i + 2]; nw := l1[i + 1]; ne := l1[i + 3];
  nnb := l2[i + 2]; nne := l2[i + 3];
  dh := Abs(wa - wwa) + Abs(nn - nw) + Abs(nn - ne);
  dv := Abs(wa - nw) + Abs(nn - nnb) + Abs(ne - nne);
  if dv - dh > 80 * scale then p2 := wa
  else if dh - dv > 80 * scale then p2 := nn
  else begin
    p2 := (wa + nn) div 2 + (ne - nw) div 4;
    if dv - dh > 32 * scale then p2 := (p2 + wa) div 2
    else if dv - dh > 8 * scale then p2 := (3 * p2 + wa) div 4
    else if dh - dv > 32 * scale then p2 := (p2 + nn) div 2
    else if dh - dv > 8 * scale then p2 := (3 * p2 + nn) div 4;
  end;
  delta := (dh + dv + 2 * errs[c][i]) div q;
  tex := Ord(nn < p2) or (Ord(wa < p2) shl 1) or (Ord(nw < p2) shl 2) or (Ord(ne < p2) shl 3) or
         (Ord(wwa < p2) shl 4) or (Ord(nnb < p2) shl 5) or (Ord(2 * nn - nnb < p2) shl 6) or
         (Ord(2 * wa - wwa < p2) shl 7);
  tex := ((Min(c, 1) * 256 + tex) * 4) + Clip(FineLog(delta) div 3, 3);
  p3 := p2 + Integer(DivRound(biasSum[tex], biasN[tex]));
  if p3 < 0 then p3 := 0 else if p3 > maxval then p3 := maxval;
  if kind = 0 then begin pendTex[c] := tex; pendP[c] := p3; pendP2[c] := p2; end;
  ex := Integer(DivRound(Int64(p3 - px) * sgn, q));
  if inv then ex := -ex - 1;
  if kind = 0 then me := MapErr(ex) else me := 2 * Abs(ex);
  mb := Clip(FineLog(me), 15);
  eb := kind * 15 + SignedLog(ex, 7) + 7;
  act := Clip(FineLog(delta), SYM_ACT - 1);

  if cd^.encoding then begin
    e := BitLen(m);
    if e >= SYM_E then Exit(False);
  end else e := 0;
  t := 0;
  while t < SYM_E - 1 do begin
    sel := (kind * SYM_K + kk) * SYM_E + t;
    c1 := @f1[sel];
    c2 := @f2[ctx * SYM_E + t];
    c3 := @f3[(kind * SYM_NB + nb) * SYM_E + t];
    c4 := @f4[(x * SYM_K + kk) * SYM_E + t];
    c5 := @f5[(mb * SYM_K + kk) * SYM_E + t];
    c6 := @f6[(act * SYM_K + kk) * SYM_E + t];
    c7 := @f7[tex * SYM_E + t];
    mx.Add(c1^.p); mx.Add(c2^.p); mx.Add(c3^.p); mx.Add(c4^.p); mx.Add(c5^.p); mx.Add(c6^.p); mx.Add(c7^.p);
    mx.Add(32768 + 8192);
    bit := cd^.CodeP(mx.Mix(sel), Ord(e > t));
    mx.Update(bit);
    c1^.Update(bit, COUNTER_LIMIT); c2^.Update(bit, COUNTER_LIMIT); c3^.Update(bit, COUNTER_LIMIT);
    c4^.Update(bit, COUNTER_LIMIT); c5^.Update(bit, COUNTER_LIMIT); c6^.Update(bit, COUNTER_LIMIT);
    c7^.Update(bit, COUNTER_LIMIT);
    if bit = 0 then Break;
    Inc(t);
  end;
  e := t;
  { the mantissa; its lowest bit is the sign of the error }
  if e = 0 then v := 0
  else begin
    if cd^.encoding then v := m else v := 1 shl (e - 1);
    for b := e - 2 downto 0 do begin
      if b = 0 then bit := cd^.Code(lsb[(eb * (SYM_E + 1) + e) * 3 + Min(e - 1, 2)], v and 1)
      else if b = e - 2 then bit := cd^.Code(m1[(e * 16 + mb) * SYM_K + kk], (v shr b) and 1)
      else bit := cd^.Code(mm[(e * 16 + mb) * SYM_E + b], (v shr b) and 1);
      if not cd^.encoding then v := v or (bit shl b);
    end;
  end;
  row[i + 1] := v;
  Result := True;
end;

function TJlsSymModel.RunBit(bit, c, i, runIndex: Integer): Integer;
var above: Integer;
begin
  { what the line above had at this column: a run (0) or how much }
  if i < w then above := Clip(FineLog(vals[c][i + 1]), 7) else above := 0;
  Result := cd^.Code(rb[(Min(c, 1) * 32 + runIndex) * 8 + above], bit);
end;

function TJlsSymModel.RunRest(v, bits, c, runIndex: Integer): Integer;
var b, node, bit, idx: Integer;
begin
  Result := 0; node := 1;
  for b := bits - 1 downto 0 do begin
    if node < 64 then idx := node else idx := 64 + b;
    bit := cd^.Code(rr[runIndex * 80 + idx], (v shr b) and 1);
    Result := (Result shl 1) or bit;
    if node < 64 then node := 2 * node + bit else node := 64;
  end;
end;

procedure TJlsSymModel.RunEnd(c, i, len: Integer);
var k: Integer;
begin
  for k := i to i + len - 1 do vals[c][k + 1] := 0;
end;

function CodeJlsSymbolStream(var cd: TCoder; var j: TJls): Boolean;
var model: TJlsSymModel;
begin
  model := TJlsSymModel.Create(cd);
  try
    Result := CodeJlsSymbols(j, model, cd.encoding);
  finally
    model.Free;
  end;
end;

procedure InitUnzig;
var k, n: Integer;
begin
  for k := 0 to 63 do UNZIG[ZIGZAG[k]] := k;
  n := 0;
  for k := 1 to 63 do
    if (ZIGZAG[k] shr 3 > 0) and (ZIGZAG[k] and 7 > 0) then begin INTERIOR[n] := k; Inc(n); end;
  for k := 0 to 48 do INTERIOR_LEFT[k] := 49 - k;
  for k := 1 to 49 do
    for n := 0 to 48 do
      if n < k then RATIO_OF[k, n] := n * 16 div k else RATIO_OF[k, n] := 0;
  for k := 0 to 7 do begin
    W3[k] := 3 * BASIS[k, 0] - BASIS[k, 1];
    W5[k] := 5 * BASIS[k, 0] - BASIS[k, 1];
    E3[k] := 3 * BASIS[k, 7] - BASIS[k, 6];
    E5[k] := 5 * BASIS[k, 7] - BASIS[k, 6];
  end;
  for n := 0 to 63 do
    for k := 0 to 7 do begin
      KER_RIGHT[n, k] := BASIS[n shr 3, k] * E5[n and 7];
      KER_BOTTOM[n, k] := BASIS[n and 7, k] * E5[n shr 3];
      KER_LEFT[n, k] := BASIS[n shr 3, k] * W5[n and 7];
      KER_TOP[n, k] := BASIS[n and 7, k] * W5[n shr 3];
    end;
end;

initialization
  {$ifdef CPUX86_64}
  UseSse41 := CpuHasSse41 and (GetEnvironmentVariable('PJA_NOASM') <> '1');
  {$endif}
  InitTables;
  InitUnzig;
end.

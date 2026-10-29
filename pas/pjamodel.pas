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
  PAdaptiveBit = ^TAdaptiveBit;
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

type
  { A JPEG's coefficient models: the full one and the fast one (stream
    version 5), and version 7's (the full one with fewer decisions, in C:
    pjav7) }
  TModelKind = (mkFull, mkFast, mkV7);

{ The coefficients of one band (allocated by Decompose or ParseHeaders); its
  first block row has no neighbour above. False when decoding garbage
  produces a value that does not fit. model: which one; each is a different
  stream. mkV7 needs pjav7 in the program (V7Code). }
function CodeBand(var cd: TCoder; var j: TJpeg; band: Integer; model: TModelKind = mkFull): Boolean;

type
  { What version 7's C code (pjav7c.c) reads: the counters and the mixers'
    weights of one class of component, in its v7m_t order }
  TV7Model = record
    nz1, nz2, nz3, zero1, zero2, zero3, zero4, zero5, expo1, expo2, expo3, expo4,
    mant1, mant, ezero1, ezero3, ezero4, ezero5, eexpo1, eexpo2, eexpo3, eexpo4, eexpo5,
    emant1, esign, dcZero, dcExpo, dcSign, dcMant1, dcMant, dz2, dz3, dz4, dx2, dx3, dx4,
    ec1, ec2, ec3, ez6, nzm1, nzm2: PAdaptiveBit;
    wNz, wZero, wExpo, wEZero, wEExpo, wDcZero, wDcExpo, wECnt: PInteger;
  end;
  { this unit's tables, and two callbacks pjav7 sets (v7t_t) }
  TV7Tables = record
    sq: PWord; st: PSmallInt; rc: PInteger;
    interior, interiorLeft, ibNa, ibNb, ibWa, ibWb, ibNone, ratioOf: PByte;
    unzig, zzTable, nzTable, remTable, kBucket: PByte;
    w3, e3, kerLeft, kerTop, kerRight, kerBottom: PInt64;
    interiorZz, edgeZz: QWord;
    sse41: LongInt;          { the SSE4.1 copy of the loop may run: UseSse41 }
    put, get: Pointer;
  end;
  { a component's scratch, zeroed (v7work_t) }
  TV7Work = record
    rowC: Pointer;
    dcr, rcnt, ccnt: PByte;
  end;
  { one component of a band, either way: coder is the TArithEncoder or the
    TArithDecoder of cd }
  TV7Code = function(encoding: Boolean; coder: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt;
                     qt: PWord; lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte;
                     var wk: TV7Work): Boolean;

var
  { set by pjav7's initialization: a program without pjav7 (the zpaq-std
    plugin) has no C and does not code version 7 }
  V7Code: TV7Code = nil;

procedure V7FillTables(out t: TV7Tables);

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

{ DivRound by a b > 0 known in advance, with rb = 1 / b: a 64-bit division
  costs 40 to 90 cycles on the machines measured, a multiplication a few.
  The product is off from the exact quotient by less than 1 while n < 2^50,
  and one comparison each way corrects that: the result is DivRound's,
  exactly. Anything larger takes the division itself. }
function DivRoundR(const a, b: Int64; rb: Double): Int64; inline;
var n, q, sg: Int64;
begin
  { |a| and the sign put back without a branch: sg is 0 or all ones }
  sg := SarInt64(a, 63);
  n := (a xor sg) - sg + b div 2;
  if (n >= 0) and (n < Int64(1) shl 50) then begin
    q := Trunc(n * rb);
    if q * b > n then Dec(q) else if (q + 1) * b <= n then Inc(q);
  end else q := n div b;
  Result := (q xor sg) - sg;
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
  { 16 bits each, not 32: the two together take 16 KB instead of 32, the
    whole L1 data cache of many machines, and the fast model reads both for
    every bit it codes }
  SQUASH_T: array[0..4095] of Word;        { stretch domain -2048..2047 -> 12-bit probability }
  STRETCH_T: array[0..4095] of SmallInt;   { 12-bit probability -> stretch domain }

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

{ acc[i] += k[pos, i] * fb[pos] over the 8 Int64 lanes, for every pos set in
  mask: the accumulators stay in registers for the whole block. pmuldq
  (signed 32 x 32 -> 64 bits): fb[pos] and every k fit in 32 bits (the
  kernels are below 2^27, a dequantized coefficient within 2^22), so the
  products are exact, and integer sums do not depend on their order. Only
  xmm0-xmm5, which no caller keeps anything in on either ABI. }
procedure SumKernelsSse41(fb: PInt64; mask: QWord; k, acc: PInt64);
var pf, pk, pa: PInt64; m: QWord;
begin
  pf := fb; pk := k; pa := acc; m := mask;
  asm
    mov rax, pf
    mov rcx, pk
    mov rdx, pa
    mov r9, m
    movdqu xmm0, [rdx]
    movdqu xmm1, [rdx + 16]
    movdqu xmm2, [rdx + 32]
    movdqu xmm3, [rdx + 48]
    test r9, r9
    jz @done
  @loop:
    bsf r8, r9
    lea r10, [r9 - 1]
    and r9, r10
    movq xmm4, [rax + r8 * 8]
    punpcklqdq xmm4, xmm4
    shl r8, 6
    movdqu xmm5, [rcx + r8]
    pmuldq xmm5, xmm4
    paddq xmm0, xmm5
    movdqu xmm5, [rcx + r8 + 16]
    pmuldq xmm5, xmm4
    paddq xmm1, xmm5
    movdqu xmm5, [rcx + r8 + 32]
    pmuldq xmm5, xmm4
    paddq xmm2, xmm5
    movdqu xmm5, [rcx + r8 + 48]
    pmuldq xmm5, xmm4
    paddq xmm3, xmm5
    test r9, r9
    jnz @loop
  @done:
    movdqu [rdx], xmm0
    movdqu [rdx + 16], xmm1
    movdqu [rdx + 32], xmm2
    movdqu [rdx + 48], xmm3
  end ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'xmm0', 'xmm1', 'xmm2', 'xmm3', 'xmm4', 'xmm5'];
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
var e: TAdaptiveBit; i, b, node, c1, c2: SizeInt; h: Cardinal; o0, o1, o2: TBits;
begin
  { the threadvars once: each use of one is a call to find this thread's }
  o0 := RawO0; o1 := RawO1; o2 := RawO2;
  e := Default(TAdaptiveBit); e.Init;
  c1 := 0; c2 := 0;
  for i := 0 to len - 1 do begin
    node := 1;
    h := Hash2(c2, c1);
    for b := 7 downto 0 do begin
      o0[node] := e;
      o1[c1 * 256 + node] := e;
      o2[(h shl 8) or Cardinal(node)] := e;
      node := node * 2 + (raw[i] shr b) and 1;
    end;
    c2 := c1; c1 := raw[i];
  end;
end;

function CodeRaw(var cd: TCoder; var raw: TBytes; maxLen: SizeInt): Boolean;
var mx: TMixer; len: Int64; i, b, bit, node, c1, c2: SizeInt; h: Cardinal; p: Integer;
    o0, o1, o2: TBits;
begin
  {$ifdef PJA_COSTS}CostKind := ckRaw;{$endif}
  len := cd.Direct(Cardinal(Length(raw)), 32);
  if (len < 0) or (len > maxLen) then Exit(False);
  if not cd.encoding then SetLength(raw, len);
  if (Length(RawO2) <> 1 shl O2_BITS) or RawDirty then begin
    NewBits(RawO0, 256); NewBits(RawO1, 256 * 256); NewBits(RawO2, 1 shl O2_BITS);
  end;
  RawDirty := True;
  o0 := RawO0; o1 := RawO1; o2 := RawO2;
  mx.Init(4, 8);
  c1 := 0; c2 := 0;
  for i := 0 to len - 1 do begin
    node := 1;
    h := Hash2(c2, c1);
    for b := 7 downto 0 do begin
      if cd.encoding then bit := (raw[i] shr b) and 1 else bit := 0;
      mx.Add(o0[node].p);
      mx.Add(o1[c1 * 256 + node].p);
      mx.Add(o2[(h shl 8) or Cardinal(node)].p);
      mx.Add(32768);
      p := mx.Mix(7 - b);
      bit := cd.CodeP(p, bit);
      mx.Update(bit);
      o0[node].Update(bit, COUNTER_LIMIT);
      o1[c1 * 256 + node].Update(bit, COUNTER_LIMIT);
      o2[(h shl 8) or Cardinal(node)].Update(bit, COUNTER_LIMIT);
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
    { version 7: each edge's count of nonzeros (3-bit trees) and its flags
      given it; the interior count's bits below its bit length }
    ec1, ec2, ec3, ez6, nzm1, nzm2: TBits;
    mxECnt: TMixer;
    v7: Boolean;
    mxNz, mxZero, mxExpo, mxEZero, mxEExpo: TMixer;
    { the fast model: no mixer; each decision codes with one counter in a
      joint context (the pair of contexts that measured best for a static
      model), averaged with one of the full model's counters for the
      biggest decisions }
    fast, chroma: Boolean;
    fz, fx, fez, fex, fdz, fdx: TBits;
    { only the tables the chosen model uses }
    procedure Init(isFast, isChroma: Boolean);
    { version 7's: the full model's tables and its own. Apart from Init,
      whose tables tools/zpaql/gen_pjadec.py reads for the plugin's frozen
      ZPAQL decoders }
    procedure InitV7(isChroma: Boolean);
  end;

procedure TCoefModel.Init(isFast, isChroma: Boolean);
begin
  fast := isFast; chroma := isChroma; v7 := False;
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

procedure TCoefModel.InitV7(isChroma: Boolean);
begin
  Init(False, isChroma);
  v7 := True;
  NewBits(ec1, 2 * NZ_BUCKETS * 9 * 8); NewBits(ec2, 2 * 9 * 9 * 8); NewBits(ec3, 2 * 9 * PRED_BUCKETS * 8);
  NewBits(ez6, EDGE_POS * 8 * 8 * 4);
  NewBits(nzm1, NZ_BUCKETS * 8 * 8); NewBits(nzm2, (NZ_BUCKETS + 1) * 8 * 8);
  mxECnt.Init(5, 2 * 8);
end;

function NzBucketOf(n: Integer): Integer;
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

function RemBucketOf(n: Integer): Integer;
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

var
  { the two above for 0..63, filled from them at start }
  NZ_BUCKET_T, REM_BUCKET_T: array[0..63] of Byte;

function NzBucket(n: Integer): Integer; inline;
begin
  if (n < 0) or (n > 63) then Result := NzBucketOf(n) else Result := NZ_BUCKET_T[n];
end;

function RemBucket(n: Integer): Integer; inline;
begin
  if (n < 0) or (n > 63) then Result := RemBucketOf(n) else Result := REM_BUCKET_T[n];
end;

{ The bits set in x, inline: FPC's PopCnt is a call to a routine that
  counts by table. The multiplications wrap on purpose. }
{$push}{$Q-}{$R-}
function Ones(x: QWord): Integer; inline;
begin
  x := x - ((x shr 1) and QWord($5555555555555555));
  x := (x and QWord($3333333333333333)) + ((x shr 2) and QWord($3333333333333333));
  x := (x + (x shr 4)) and QWord($0F0F0F0F0F0F0F0F);
  Result := Integer((x * QWord($0101010101010101)) shr 56);
end;
{$pop}

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

function DOne(var dc: TArithDecoder; var c: TAdaptiveBit): Integer; forward;
function EOne(var e: TArithEncoder; var c: TAdaptiveBit; bit: Integer): Integer; forward;

{ Mantissa of a magnitude of bit length e: the bit below the top with
  mant1[e * m1stride + m1], the rest with mant[e][bit]. Through the fused
  EOne / DOne: TCoder.Code's arithmetic, without its layers. }
procedure CodeMantissa(var cd: TCoder; var mant1: TBits; m1, m1stride: Integer; var mant: TBits;
                       maxE, e: Integer; var a: Integer);
var i, b: Integer;
begin
  if cd.encoding then begin
    for i := e - 2 downto 0 do
      if i = e - 2 then EOne(cd.enc, mant1[e * m1stride + m1], (a shr i) and 1)
      else EOne(cd.enc, mant[e * maxE + i], (a shr i) and 1);
  end else begin
    a := 1 shl (e - 1);
    for i := e - 2 downto 0 do begin
      if i = e - 2 then b := DOne(cd.dec, mant1[e * m1stride + m1])
      else b := DOne(cd.dec, mant[e * maxE + i]);
      a := a or (b shl i);
    end;
  end;
end;

{ 0, 1 or 2 for a negative, zero or positive v. Comparisons, not branches:
  the sign of a neighbour is as unpredictable as the data. }
function Sgn3(v: Int64): Integer; inline;
begin
  Result := Ord(v > 0) - Ord(v < 0) + 1;
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

type
  { a coefficient's contribution to 8 values; 8 such values }
  TKernels = array[0..63, 0..7] of Int64;
  TLanes = array[0..7] of Int64;

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
  KER_RIGHT, KER_BOTTOM, KER_LEFT, KER_TOP: TKernels;
  { UNZIG[natural position] = zigzag index }
  UNZIG: array[0..63] of Byte;
  { interior positions (u, v >= 1) in zigzag order, and how many of them are
    left from each one on, itself included }
  INTERIOR: array[0..48] of Byte;
  INTERIOR_LEFT: array[0..48] of Byte;
  { the interior positions as a mask over the zigzag indices, NonzeroMask's
    order }
  INTERIOR_ZZ: QWord;
  { the same for row 0 and column 0 without the DC }
  EDGE_ZZ: QWord;
  { the interior neighbours in the block of INTERIOR[idx], already coded:
    (u-1, v) and (u, v-1), weights 1 and 1 when both are interior, 2 and 0
    when one is, none (both weights 0, at the DC) for (1, 1) }
  IB_NA, IB_NB, IB_WA, IB_WB: array[0..48] of Byte;
  IB_NONE: array[0..48] of Boolean;
  { RATIO_OF[left, rem] = rem * 16 div left, for rem < left }
  RATIO_OF: array[1..49, 0..48] of Byte;

const
  { A dequantized coefficient is clamped here. A real 8-bit JPEG's DCT
    coefficients stay below 2^14; with this bound every product the
    predictions take (a kernel below 2^15.5 times it) fits in 31 bits. }
  MAX_DEQUANT = 1 shl 15;

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

{ The predictions' arithmetic is 32-bit, wrapping, as a 32-bit machine (and
  the ZPAQL decoder for zpaq-std) does it: sums, differences and products
  are kept in Int64, which gives the same value modulo 2^32 wherever it is
  cut, and W32 cuts them to 32 bits right before anything that is not a
  sum or a product (a division, a comparison, a logarithm, a sign). On
  real JPEGs nothing ever wraps (0 of 611 million values checked); on a
  hostile one it wraps the same way everywhere. }
function W32(x: Int64): Int64; inline;
begin
  Result := LongInt(x);
end;

{ a, b := min, max, without a branch; the difference wraps as in 32 bits }
procedure CompareSwap(var a, b: Int64); inline;
var d, m: Int64;
begin
  d := W32(b - a);
  m := SarInt64(d, 63);      { all ones when b < a }
  a := a + (d and m);
  b := b - (d and m);
end;

function Min64(a, b: Int64): Int64; inline;
var d: Int64;
begin
  d := W32(b - a);
  Result := a + (d and SarInt64(d, 63));
end;

function Max64(a, b: Int64): Int64; inline;
var d: Int64;
begin
  d := W32(b - a);
  Result := b - (d and SarInt64(d, 63));
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
{ acc[y] += k[pos, y] * fb[pos], for every pos set in mask }
procedure SumKernels(const fb: TBlockF; mask: QWord; const k: TKernels; var acc: TLanes); inline;
var pos, y: Integer;
begin
  {$ifdef CPUX86_64}
  if UseSse41 then SumKernelsSse41(@fb[0], mask, @k[0, 0], @acc[0]) else
  {$endif}
  while mask <> 0 do begin
    pos := BsfQWord(mask);
    mask := mask and (mask - 1);
    for y := 0 to 7 do acc[y] := acc[y] + k[pos, y] * fb[pos];
  end;
end;

procedure FillCaches(const fb: TBlockF; mask: QWord; out right, bottom: TEdgeCache);
var pos, u, v, y: Integer; f: Int64; m0: QWord;
begin
  m0 := mask;
  for y := 0 to 7 do begin right.eg[y] := 0; bottom.eg[y] := 0; right.px[y] := 0; bottom.px[y] := 0; end;
  while mask <> 0 do begin
    pos := BsfQWord(mask);
    mask := mask and (mask - 1);
    f := fb[pos];
    u := pos shr 3; v := pos and 7;
    right.eg[u] := right.eg[u] + E3[v] * f;
    bottom.eg[v] := bottom.eg[v] + E3[u] * f;
  end;
  SumKernels(fb, m0, KER_RIGHT, right.px);
  SumKernels(fb, m0, KER_BOTTOM, bottom.px);
  for y := 0 to 7 do begin
    right.eg[y] := W32(right.eg[y]); bottom.eg[y] := W32(bottom.eg[y]);
    right.px[y] := W32(right.px[y]); bottom.px[y] := W32(bottom.px[y]);
  end;
end;

{ What the coefficient routine (pjacoef.inc) codes a counter's bit with.
  CodeOne is TCoder.Code; DecAvg and DecOne are the decoding side fused into
  one routine each: the arithmetic decoder and the counters' update written
  out (FPC does not inline a routine inside another one it inlines). The
  same arithmetic as CodeAvg, TCoder.Code, TArithDecoder.Decode and
  TAdaptiveBit.Update, so the same bits. }
function CodeOne(var cd: TCoder; var c: TAdaptiveBit; bit: Integer): Integer; inline;
begin
  Result := cd.Code(c, bit);
end;

function DecodeWith(var dc: TArithDecoder; prob: Cardinal): Integer; inline;
var xm: Cardinal; b: Byte;
begin
  { prob is a counter's or a squashed one: already in [1, 65535] }
  xm := dc.x1 + Cardinal((QWord(dc.x2 - dc.x1) * prob) shr 16);
  if dc.x <= xm then begin Result := 1; dc.x2 := xm; end
  else begin Result := 0; dc.x1 := xm + 1; end;
  while ((dc.x1 xor dc.x2) and $FF000000) = 0 do begin
    dc.x1 := dc.x1 shl 8;
    dc.x2 := (dc.x2 shl 8) or 255;
    if dc.live <> nil then b := dc.live.Get(dc.p)
    else if (dc.p >= 0) and (dc.p < Length(dc.d)) then b := dc.d[dc.p] else b := 0;
    Inc(dc.p);
    dc.x := (dc.x shl 8) or b;
  end;
end;

procedure Learn(var c: TAdaptiveBit; bit: Integer); inline;
var target: Integer; q: Int64;
begin
  if bit <> 0 then target := PROB_ONE - 1 else target := 1;
  q := Int64(target - c.p) * RECIPROCAL[c.n];
  q := SarInt64(q + (SarInt64(q, 63) and $FFFF), 16);
  c.p := c.p + q;
  if c.n < COUNTER_LIMIT then Inc(c.n);
end;

function DOne(var dc: TArithDecoder; var c: TAdaptiveBit): Integer;
begin
  Result := DecodeWith(dc, c.p);
  Learn(c, Result);
end;

function DAvg(var dc: TArithDecoder; var a, b: TAdaptiveBit): Integer;
begin
  Result := DecodeWith(dc, Cardinal(SQUASH_T[(STRETCH_T[a.p shr 4] + STRETCH_T[b.p shr 4]) div 2 + 2048]) shl 4);
  Learn(a, Result); Learn(b, Result);
end;

{ the encoding side, fused the same way }
procedure EncodeWith(var e: TArithEncoder; bit: Integer; prob: Cardinal); inline;
var xm: Cardinal;
begin
  xm := e.x1 + Cardinal((QWord(e.x2 - e.x1) * prob) shr 16);
  if bit <> 0 then e.x2 := xm else e.x1 := xm + 1;
  while ((e.x1 xor e.x2) and $FF000000) = 0 do begin
    if e.live <> nil then e.live.Put(Byte(e.x2 shr 24))
    else begin
      if e.n >= Length(e.d) then SetLength(e.d, 2 * Length(e.d));
      e.d[e.n] := Byte(e.x2 shr 24);
    end;
    Inc(e.n);
    e.x1 := e.x1 shl 8;
    e.x2 := (e.x2 shl 8) or 255;
  end;
end;

function EOne(var e: TArithEncoder; var c: TAdaptiveBit; bit: Integer): Integer;
begin
  {$ifdef PJA_COSTS}if CollectCosts then AddCost(c.p, bit);{$endif}
  EncodeWith(e, bit, c.p);
  Learn(c, bit);
  Result := bit;
end;

function EAvg(var e: TArithEncoder; var a, b: TAdaptiveBit; bit: Integer): Integer;
var p: Cardinal;
begin
  p := Cardinal(SQUASH_T[(STRETCH_T[a.p shr 4] + STRETCH_T[b.p shr 4]) div 2 + 2048]) shl 4;
  {$ifdef PJA_COSTS}if CollectCosts then AddCost(p, bit);{$endif}
  EncodeWith(e, bit, p);
  Learn(a, bit); Learn(b, bit);
  Result := bit;
end;

function EncOne(var cd: TCoder; var c: TAdaptiveBit; bit: Integer): Integer; inline;
begin
  Result := EOne(cd.enc, c, bit);
end;

function EncAvg(var cd: TCoder; var a, b: TAdaptiveBit; bit: Integer): Integer; inline;
begin
  Result := EAvg(cd.enc, a, b, bit);
end;

function DecOne(var cd: TCoder; var c: TAdaptiveBit; bit: Integer): Integer; inline;
begin
  Result := DOne(cd.dec, c);
end;

function DecAvg(var cd: TCoder; var a, b: TAdaptiveBit; bit: Integer): Integer; inline;
begin
  Result := DAvg(cd.dec, a, b);
end;

{$macro on}
{ the full model and anything not specialized }
{$define CC_NAME:=CodeComponent}{$define CC_FAST:=m.fast}{$define CC_ENC:=cd.encoding}
{$define CC_AVG:=CodeAvg}{$define CC_ONE:=CodeOne}
{$I pjacoef.inc}
{ the fast model, encoding, the coder fused }
{$define CC_NAME:=CodeComponentFast}{$define CC_FAST:=True}{$define CC_ENC:=True}
{$define CC_AVG:=EncAvg}{$define CC_ONE:=EncOne}
{$I pjacoef.inc}
{ the fast model, decoding }
{$define CC_NAME:=CodeComponentFastDec}{$define CC_ENC:=False}
{$define CC_AVG:=DecAvg}{$define CC_ONE:=DecOne}
{$I pjacoef.inc}
{$undef CC_NAME}{$undef CC_FAST}{$undef CC_ENC}{$undef CC_AVG}{$undef CC_ONE}
{$macro off}

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

threadvar
  { a band's two models, kept for the next band in this thread: Init only
    refills tables already allocated (NewBits), instead of allocating and
    zeroing megabytes per band }
  PoolLuma, PoolChroma: TCoefModel;

procedure V7FillTables(out t: TV7Tables);
begin
  t := Default(TV7Tables);
  t.sq := @SQUASH_T[0]; t.st := @STRETCH_T[0]; t.rc := @RECIPROCAL[0];
  t.interior := @INTERIOR[0]; t.interiorLeft := @INTERIOR_LEFT[0];
  t.ibNa := @IB_NA[0]; t.ibNb := @IB_NB[0]; t.ibWa := @IB_WA[0]; t.ibWb := @IB_WB[0];
  t.ibNone := PByte(@IB_NONE[0]); t.ratioOf := @RATIO_OF[1, 0];
  t.unzig := @UNZIG[0]; t.zzTable := @ZIGZAG[0]; t.nzTable := @NZ_BUCKET_T[0]; t.remTable := @REM_BUCKET_T[0];
  t.kBucket := @K_BUCKET_OF[0];
  t.w3 := @W3[0]; t.e3 := @E3[0];
  t.kerLeft := @KER_LEFT[0, 0]; t.kerTop := @KER_TOP[0, 0]; t.kerRight := @KER_RIGHT[0, 0]; t.kerBottom := @KER_BOTTOM[0, 0];
  t.interiorZz := INTERIOR_ZZ; t.edgeZz := EDGE_ZZ;
  t.sse41 := Ord(UseSse41);
end;

{ Version 7's component: the same arguments as CodeComponent, the work in
  pjav7c.c through V7Code. }
function V7Component(var cd: TCoder; var cp: TComponent; const qt: array of Word; var m: TCoefModel;
                     const lumaNz: array of Byte; lumaW, sx, sy: SizeInt; y0, y1: SizeInt;
                     out nzOut: TByteArr): Boolean;
var v: TV7Model; wk: TV7Work; qq: array[0..63] of Word; k: Integer; lz, coder: Pointer;
    rowC: array of TEdgeCache; dcr, rcnt, ccnt: TByteArr;
begin
  nzOut := nil;
  if (V7Code = nil) or (cp.bw <= 0) or (cp.bh <= 0) then Exit(False);
  for k := 0 to 63 do if k < Length(qt) then qq[k] := qt[k] else qq[k] := 0;
  v.nz1 := @m.nz1[0]; v.nz2 := @m.nz2[0]; v.nz3 := @m.nz3[0];
  v.zero1 := @m.zero1[0]; v.zero2 := @m.zero2[0]; v.zero3 := @m.zero3[0]; v.zero4 := @m.zero4[0]; v.zero5 := @m.zero5[0];
  v.expo1 := @m.expo1[0]; v.expo2 := @m.expo2[0]; v.expo3 := @m.expo3[0]; v.expo4 := @m.expo4[0];
  v.mant1 := @m.mant1[0]; v.mant := @m.mant[0];
  v.ezero1 := @m.ezero1[0]; v.ezero3 := @m.ezero3[0]; v.ezero4 := @m.ezero4[0]; v.ezero5 := @m.ezero5[0];
  v.eexpo1 := @m.eexpo1[0]; v.eexpo2 := @m.eexpo2[0]; v.eexpo3 := @m.eexpo3[0]; v.eexpo4 := @m.eexpo4[0];
  v.eexpo5 := @m.eexpo5[0]; v.emant1 := @m.emant1[0]; v.esign := @m.esign[0];
  v.dcZero := @m.dcZero[0]; v.dcExpo := @m.dcExpo[0]; v.dcSign := @m.dcSign[0]; v.dcMant1 := @m.dcMant1[0];
  v.dcMant := @m.dcMant[0]; v.dz2 := @m.dz2[0]; v.dz3 := @m.dz3[0]; v.dz4 := @m.dz4[0];
  v.dx2 := @m.dx2[0]; v.dx3 := @m.dx3[0]; v.dx4 := @m.dx4[0];
  v.ec1 := @m.ec1[0]; v.ec2 := @m.ec2[0]; v.ec3 := @m.ec3[0]; v.ez6 := @m.ez6[0]; v.nzm1 := @m.nzm1[0]; v.nzm2 := @m.nzm2[0];
  v.wNz := @m.mxNz.w[0]; v.wZero := @m.mxZero.w[0]; v.wExpo := @m.mxExpo.w[0]; v.wEZero := @m.mxEZero.w[0];
  v.wEExpo := @m.mxEExpo.w[0]; v.wDcZero := @m.mxDcZero.w[0]; v.wDcExpo := @m.mxDcExpo.w[0]; v.wECnt := @m.mxECnt.w[0];
  rowC := nil; SetLength(rowC, cp.bw);
  dcr := nil; SetLength(dcr, cp.bw * cp.bh); rcnt := nil; SetLength(rcnt, cp.bw * cp.bh);
  ccnt := nil; SetLength(ccnt, cp.bw * cp.bh); SetLength(nzOut, cp.bw * cp.bh);
  wk.rowC := @rowC[0]; wk.dcr := @dcr[0]; wk.rcnt := @rcnt[0]; wk.ccnt := @ccnt[0];
  if Length(lumaNz) > 0 then lz := @lumaNz[0] else lz := nil;
  if cd.encoding then coder := @cd.enc else coder := @cd.dec;
  Result := V7Code(cd.encoding, coder, v, @cp.coef[0], cp.bw, cp.bh, @qq[0], lz, lumaW, sx, sy, y0, y1,
                   @nzOut[0], wk);
end;

function CodeBand(var cd: TCoder; var j: TJpeg; band: Integer; model: TModelKind): Boolean;
var c, nb: Integer; ok: Boolean; lumaNz, other: TByteArr; sx, sy, m0, m1: SizeInt;
  { the variant compiled for the model and the direction }
  function CC(var cd: TCoder; var cp: TComponent; const qt: array of Word; var m: TCoefModel;
              const lumaNz: array of Byte; lumaW, sx, sy: SizeInt; y0, y1: SizeInt;
              out nzOut: TByteArr): Boolean;
  begin
    if m.v7 then Result := V7Component(cd, cp, qt, m, lumaNz, lumaW, sx, sy, y0, y1, nzOut)
    else if not m.fast then Result := CodeComponent(cd, cp, qt, m, lumaNz, lumaW, sx, sy, y0, y1, nzOut)
    else if cd.encoding then Result := CodeComponentFast(cd, cp, qt, m, lumaNz, lumaW, sx, sy, y0, y1, nzOut)
    else Result := CodeComponentFastDec(cd, cp, qt, m, lumaNz, lumaW, sx, sy, y0, y1, nzOut);
  end;
begin
  nb := BandCount(j);
  if (band < 0) or (band >= nb) then Exit(False);
  m0 := SizeInt(j.mcusy) * band div nb; m1 := SizeInt(j.mcusy) * (band + 1) div nb;
  if model = mkV7 then begin PoolLuma.InitV7(False); PoolChroma.InitV7(True); end
  else begin PoolLuma.Init(model = mkFast, False); PoolChroma.Init(model = mkFast, True); end;
  lumaNz := nil;
  for c := 0 to High(j.comp) do begin
    if c = 0 then
      ok := CC(cd, j.comp[c], j.qt[j.comp[c].tq], PoolLuma, [], 0, 0, 0,
                          m0 * j.comp[c].v, m1 * j.comp[c].v, lumaNz)
    else begin
      { how many luma blocks one of ours spans; a component sampled finer
        than the luma (H or V above it) maps to its first block }
      sx := j.comp[0].h div j.comp[c].h; sy := j.comp[0].v div j.comp[c].v;
      if (sx < 1) or (sy < 1) or (j.comp[c].bw * sx > j.comp[0].bw) or (j.comp[c].bh * sy > j.comp[0].bh) then
        ok := CC(cd, j.comp[c], j.qt[j.comp[c].tq], PoolChroma, [], 0, 0, 0,
                            m0 * j.comp[c].v, m1 * j.comp[c].v, other)
      else
        ok := CC(cd, j.comp[c], j.qt[j.comp[c].tq], PoolChroma, lumaNz, j.comp[0].bw, sx, sy,
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
var total: Int64; c: Integer;
begin
  total := 0;
  for c := 0 to High(j.comp) do Inc(total, Int64(j.comp[c].width) * j.comp[c].height);
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
    bit, act, nbb, first, bi: Integer; y, y0, y1, base, w, r, nr: SizeInt; haveUp, sub: Boolean;
    rowC: array of Integer; rowY, firstRow: array of SizeInt;
    res: array of array of Integer;       { [component] this row's residuals }
    resUp: array of array of Integer;     { [component] the row above's }
    t: array of Integer;
    bs: ^TJlsBias;
begin
  nb := JlsBandCount(j);
  if (band < 0) or (band >= nb) then Exit(False);
  maxv := (1 shl j.bits) - 1; range := maxv + 1; half := (maxv + 1) div 2;
  DefaultThresholds(maxv, 0, t1, t2, t3);
  m.Init;
  { subsampled: a component of another size than the frame's }
  sub := False;
  for ci := 0 to High(j.comp) do
    if (j.comp[ci].width <> j.width) or (j.comp[ci].height <> j.height) then sub := True;
  res := nil; resUp := nil;
  SetLength(res, Length(j.comp)); SetLength(resUp, Length(j.comp));
  for ci := 0 to High(j.comp) do begin
    SetLength(res[ci], j.comp[ci].width); SetLength(resUp[ci], j.comp[ci].width);
  end;
  { the band's rows, in coding order: line by line through the components;
    subsampled, each component's own rows of the band, one component after
    the other }
  rowC := nil; rowY := nil; nr := 0;
  for ci := 0 to High(j.comp) do Inc(nr, j.comp[ci].height * (band + 1) div nb - j.comp[ci].height * band div nb);
  SetLength(rowC, nr); SetLength(rowY, nr); SetLength(firstRow, Length(j.comp));
  for ci := 0 to High(j.comp) do firstRow[ci] := SizeInt(j.comp[ci].height) * band div nb;
  r := 0;
  if not sub then begin
    y0 := SizeInt(j.height) * band div nb; y1 := SizeInt(j.height) * (band + 1) div nb;
    for y := y0 to y1 - 1 do
      for ci := 0 to High(j.comp) do begin rowC[r] := ci; rowY[r] := y; Inc(r); end;
  end else
    for ci := 0 to High(j.comp) do
      for y := firstRow[ci] to SizeInt(j.comp[ci].height) * (band + 1) div nb - 1 do begin
        rowC[r] := ci; rowY[r] := y; Inc(r);
      end;
  for r := 0 to nr - 1 do begin
    ci := rowC[r]; y := rowY[r];
    w := j.comp[ci].width;
    haveUp := y > firstRow[ci];
    begin
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
        { the first component's residual at this column, when it has one }
        if (ci > 0) and not sub then first := Clip(FineLog(res[0][i]), JLS_FIRST - 2) else first := JLS_FIRST - 1;
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
    near, maxval, scale: Integer;
    { [component] its width; and whether it is the first's (its value at
      the same column is a context then: not with subsampling) }
    wc: array[0..3] of Integer;
    sameAsFirst: array[0..3] of Boolean;
    constructor Create(var coder: TCoder);
    procedure BeginScan(const s: TJlsScan; const j: TJls); override;
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

procedure TJlsSymModel.BeginScan(const s: TJlsScan; const j: TJls);
var c, l, width: Integer;
begin
  near := s.near; maxval := s.maxval;
  { the gradient thresholds below are for 8 bits }
  scale := Max(1, (maxval + 1) div 256);
  for c := 0 to 3 do begin
    vals[c] := nil; errs[c] := nil;
    width := 0;
    if c < s.ncomp then width := j.comp[s.comp[c]].width;
    wc[c] := width;
    sameAsFirst[c] := (c < s.ncomp) and (j.comp[s.comp[c]].width = j.comp[s.comp[0]].width) and
                      (j.comp[s.comp[c]].height = j.comp[s.comp[0]].height);
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
  if (c > 0) and sameAsFirst[c] then x := Clip(FineLog(vals[0][i + 1]), SYM_X - 2) else x := SYM_X - 1;
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
  if i < wc[c] then above := Clip(FineLog(vals[c][i + 1]), 7) else above := 0;
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
var k, n, pos, u, w: Integer;
begin
  for k := 0 to 63 do UNZIG[ZIGZAG[k]] := k;
  for k := 0 to 63 do begin NZ_BUCKET_T[k] := NzBucketOf(k); REM_BUCKET_T[k] := RemBucketOf(k); end;
  n := 0; INTERIOR_ZZ := 0; EDGE_ZZ := 0;
  for k := 1 to 63 do
    if (ZIGZAG[k] shr 3 = 0) or (ZIGZAG[k] and 7 = 0) then EDGE_ZZ := EDGE_ZZ or (QWord(1) shl k);
  for k := 1 to 63 do
    if (ZIGZAG[k] shr 3 > 0) and (ZIGZAG[k] and 7 > 0) then begin
      INTERIOR[n] := k; Inc(n);
      INTERIOR_ZZ := INTERIOR_ZZ or (QWord(1) shl k);
    end;
  for k := 0 to 48 do INTERIOR_LEFT[k] := 49 - k;
  for k := 0 to 48 do begin
    pos := ZIGZAG[INTERIOR[k]]; u := pos shr 3; w := pos and 7;
    IB_NA[k] := 0; IB_NB[k] := 0; IB_WA[k] := 0; IB_WB[k] := 0; IB_NONE[k] := False;
    if (u > 1) and (w > 1) then begin
      IB_NA[k] := UNZIG[pos - 8]; IB_WA[k] := 1; IB_NB[k] := UNZIG[pos - 1]; IB_WB[k] := 1;
    end else if u > 1 then begin IB_NA[k] := UNZIG[pos - 8]; IB_WA[k] := 2; end
    else if w > 1 then begin IB_NA[k] := UNZIG[pos - 1]; IB_WA[k] := 2; end
    else IB_NONE[k] := True;
  end;
  for k := 1 to 49 do
    for n := 0 to 48 do
      if n < k then RATIO_OF[k, n] := n * 16 div k else RATIO_OF[k, n] := 0;
  for k := 0 to 7 do begin
    { the edge weights over 8 and the kernels over BASIS[0, 0]: every
      product they take fits in 32 bits (MAX_DEQUANT) }
    W3[k] := (3 * BASIS[k, 0] - BASIS[k, 1]) div 8;
    W5[k] := 5 * BASIS[k, 0] - BASIS[k, 1];
    E3[k] := (3 * BASIS[k, 7] - BASIS[k, 6]) div 8;
    E5[k] := 5 * BASIS[k, 7] - BASIS[k, 6];
  end;
  for n := 0 to 63 do
    for k := 0 to 7 do begin
      KER_RIGHT[n, k] := DivRound(BASIS[n shr 3, k] * E5[n and 7], BASIS[0, 0]);
      KER_BOTTOM[n, k] := DivRound(BASIS[n and 7, k] * E5[n shr 3], BASIS[0, 0]);
      KER_LEFT[n, k] := DivRound(BASIS[n shr 3, k] * W5[n and 7], BASIS[0, 0]);
      KER_TOP[n, k] := DivRound(BASIS[n and 7, k] * W5[n shr 3], BASIS[0, 0]);
    end;
end;

initialization
  {$ifdef CPUX86_64}
  UseSse41 := CpuHasSse41 and (GetEnvironmentVariable('PJA_NOASM') <> '1');
  {$endif}
  InitTables;
  InitUnzig;
end.

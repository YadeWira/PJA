{ Codec layer 2: binary arithmetic coder.

  Carryless, with the interval in 32 bits [x1, x2] (the lpaq form): whenever
  both ends agree on the top byte, that byte is emitted. Probabilities come in
  16 bits: p = P(bit = 1) * 65536, in [1, 65535].

  The decoder cannot fail: past the end of the data it reads zeros. A damaged
  stream decodes to SOMETHING ELSE, and that is caught by the layer above (size
  and hash of the original), not by this one.

  TAdaptiveBit is the counter of each context: it starts at 1/2, adapts fast
  at first (1/2, 1/3, 1/4...) and then at a fixed rate of about 1/limit. }
unit pjaarith;

{$I pja.inc}
{ PJA_FAST: the release build of the model, without range and overflow
  checks (they cost 2.3x here). The checked build is the reference: the
  codec suite compresses the same files with both and demands identical
  streams, and the damaged-stream test runs on the fast one too. }
{$ifdef PJA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pjaarith: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pjaarith: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

const
  PROB_ONE = 65536;

type
  { A stream written by one thread and read by another while it is being
    written: the encoder of a band and the decoder that verifies it run side
    by side. The bytes go in blocks that never move, and the reader waits
    for bytes not ready yet; past the end, once finished, it reads
    zeros, as TArithDecoder does past the end of its data. }
  TLiveStream = class
  private
    blocks: array of TBytes;
    n: SizeInt;                   { written, by the writer }
    { on cache lines of their own: the writer bumps n on every byte, and a
      reader polling a line the writer keeps dirtying slows both down }
    pad1: array[0..15] of SizeInt;
    ready: SizeInt;               { what the reader may read }
    finished: Boolean;
    pad2: array[0..15] of SizeInt;
  public
    constructor Create;
    procedure Put(b: Byte);
    { No more bytes; also what unblocks the reader when the writer fails. }
    procedure Finish;
    function Get(p: SizeInt): Byte;
    function Bytes: TBytes;
  end;

  TArithEncoder = record
    x1, x2: Cardinal;
    d: TBytes;
    n: SizeInt;
    live: TLiveStream;            { nil: into d }
    procedure Init;
    { The bytes go to s as they come out (and Finish closes it). }
    procedure InitLive(s: TLiveStream);
    procedure Encode(bit: Integer; p: Integer);
    { The low `count` bits of v, most significant first, at probability 1/2. }
    procedure Direct(v: Cardinal; count: Integer);
    function Finish: TBytes;
  end;

  TArithDecoder = record
    x1, x2, x: Cardinal;
    d: TBytes;
    p: SizeInt;
    live: TLiveStream;            { nil: from d }
    procedure Init(const data: TBytes; first: SizeInt = 0);
    { From s, waiting for its writer when it gets ahead. }
    procedure InitLive(s: TLiveStream);
    function Decode(prob: Integer): Integer;
    function Direct(count: Integer): Cardinal;
    { Bytes consumed so far, counting the ones read past the end. }
    function Position: SizeInt;
  end;

  TAdaptiveBit = record
    p: Word;      { P(1) * 65536 }
    n: Byte;      { how many updates so far, up to the limit }
    procedure Init;
    procedure Update(bit: Integer; limit: Integer); inline;
  end;

const
  MAX_LIMIT = 255;

var
  { RECIPROCAL[n] = 65536 / (n + 1.5): the adaptation rate after n bits. In
    the interface so that TAdaptiveBit.Update can be inlined elsewhere. }
  RECIPROCAL: array[0..MAX_LIMIT] of Integer;

implementation

{$ifdef UNIX}uses BaseUnix;{$endif}

function Split(x1, x2: Cardinal; p: Integer): Cardinal; inline;
begin
  Result := x1 + Cardinal((QWord(x2 - x1) * Cardinal(p)) shr 16);
end;

function Clamp(p: Integer): Integer; inline;
begin
  if p < 1 then Result := 1 else if p > PROB_ONE - 1 then Result := PROB_ONE - 1 else Result := p;
end;

{ ---------- live stream ---------- }

const
  LIVE_BLOCK_BITS = 16;
  LIVE_BLOCK = 1 shl LIVE_BLOCK_BITS;
  { 2^16 blocks of 64 KB: 4 GB, more than a band can take }
  LIVE_BLOCKS = 1 shl 16;
  { the writer publishes every this many bytes, and when it finishes }
  LIVE_PUBLISH = 64;

constructor TLiveStream.Create;
begin
  inherited Create;
  { all the slots now: the array itself never moves while the reader reads }
  SetLength(blocks, LIVE_BLOCKS);
  n := 0; ready := 0; finished := False;
end;

procedure TLiveStream.Put(b: Byte);
begin
  if n shr LIVE_BLOCK_BITS >= LIVE_BLOCKS then raise ERangeError.Create('TLiveStream: full');
  if n and (LIVE_BLOCK - 1) = 0 then SetLength(blocks[n shr LIVE_BLOCK_BITS], LIVE_BLOCK);
  blocks[n shr LIVE_BLOCK_BITS][n and (LIVE_BLOCK - 1)] := b;
  Inc(n);
  if n and (LIVE_PUBLISH - 1) = 0 then begin
    WriteBarrier;
    ready := n;
  end;
end;

procedure TLiveStream.Finish;
begin
  WriteBarrier;
  ready := n;
  WriteBarrier;
  finished := True;
end;

procedure Nap;
{$ifdef UNIX}
var t: TTimeSpec;
begin
  t.tv_sec := 0; t.tv_nsec := 50000;
  fpNanoSleep(@t, nil);
end;
{$else}
begin
  ThreadSwitch;
end;
{$endif}

function TLiveStream.Get(p: SizeInt): Byte;
var done: Boolean;
begin
  Result := 0;
  repeat
    { finished first: once it is set, `ready` already counts every byte }
    done := finished;
    ReadBarrier;
    if p < ready then begin
      ReadBarrier;
      Result := blocks[p shr LIVE_BLOCK_BITS][p and (LIVE_BLOCK - 1)];
      Exit;
    end;
    if done then Exit;
    { caught up with the writer: sleep a little rather than spin, which
      would also take the turbo budget away from the writer's core }
    Nap;
  until False;
end;

function TLiveStream.Bytes: TBytes;
var k, take: SizeInt;
begin
  Result := nil;
  SetLength(Result, n);
  k := 0;
  while k < n do begin
    take := n - k;
    if take > LIVE_BLOCK then take := LIVE_BLOCK;
    Move(blocks[k shr LIVE_BLOCK_BITS][0], Result[k], take);
    Inc(k, take);
  end;
end;

{ ---------- encoder ---------- }

procedure TArithEncoder.Init;
begin
  x1 := 0; x2 := $FFFFFFFF;
  SetLength(d, 4096); n := 0;
  live := nil;
end;

procedure TArithEncoder.InitLive(s: TLiveStream);
begin
  Init;
  d := nil;
  live := s;
end;

procedure TArithEncoder.Encode(bit: Integer; p: Integer);
var xm: Cardinal;
begin
  xm := Split(x1, x2, Clamp(p));
  if bit <> 0 then x2 := xm else x1 := xm + 1;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    if live <> nil then live.Put(Byte(x2 shr 24))
    else begin
      if n >= Length(d) then SetLength(d, 2 * Length(d));
      d[n] := Byte(x2 shr 24);
    end;
    Inc(n);
    x1 := x1 shl 8;
    x2 := (x2 shl 8) or 255;
  end;
end;

procedure TArithEncoder.Direct(v: Cardinal; count: Integer);
var k: Integer;
begin
  for k := count - 1 downto 0 do Encode((v shr k) and 1, PROB_ONE div 2);
end;

function TArithEncoder.Finish: TBytes;
var k: Integer;
begin
  { all of x1: whatever tail the decoder reads falls inside [x1, x2] }
  for k := 0 to 3 do begin
    if live <> nil then live.Put(Byte(x1 shr 24))
    else begin
      if n >= Length(d) then SetLength(d, 2 * Length(d));
      d[n] := Byte(x1 shr 24);
    end;
    Inc(n);
    x1 := x1 shl 8;
  end;
  if live <> nil then begin
    live.Finish;
    Result := live.Bytes;
  end else
    Result := Copy(d, 0, n);
end;

{ ---------- decoder ---------- }

procedure TArithDecoder.InitLive(s: TLiveStream);
begin
  Init(nil, 0);
  { Init read four zeros from nothing: again, from s }
  live := s;
  x := (Cardinal(s.Get(0)) shl 24) or (Cardinal(s.Get(1)) shl 16) or (Cardinal(s.Get(2)) shl 8) or s.Get(3);
  p := 4;
end;

procedure TArithDecoder.Init(const data: TBytes; first: SizeInt);
var k: Integer; b: Byte;
begin
  live := nil;
  d := data; p := first;
  x1 := 0; x2 := $FFFFFFFF; x := 0;
  for k := 0 to 3 do begin
    if live <> nil then b := live.Get(p)
    else if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
    Inc(p);
    x := (x shl 8) or b;
  end;
end;

function TArithDecoder.Decode(prob: Integer): Integer;
var xm: Cardinal; b: Byte;
begin
  xm := Split(x1, x2, Clamp(prob));
  if x <= xm then begin Result := 1; x2 := xm; end
  else begin Result := 0; x1 := xm + 1; end;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    x1 := x1 shl 8;
    x2 := (x2 shl 8) or 255;
    if live <> nil then b := live.Get(p)
    else if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
    Inc(p);
    x := (x shl 8) or b;
  end;
end;

function TArithDecoder.Direct(count: Integer): Cardinal;
var k: Integer;
begin
  Result := 0;
  for k := 1 to count do Result := (Result shl 1) or Cardinal(Decode(PROB_ONE div 2));
end;

function TArithDecoder.Position: SizeInt;
begin Result := p; end;

{ ---------- counter ---------- }

procedure TAdaptiveBit.Init;
begin p := PROB_ONE div 2; n := 0; end;

procedure TAdaptiveBit.Update(bit: Integer; limit: Integer);
var target: Integer; q: Int64;
begin
  if bit <> 0 then target := PROB_ONE - 1 else target := 1;
  { div PROB_ONE, truncating toward zero, without a division }
  q := Int64(target - p) * RECIPROCAL[n];
  if q >= 0 then q := q shr 16 else q := -((-q) shr 16);
  q := p + q;
  { clamped here and not with Clamp: a call to a private routine would keep
    this method from being inlined in other units }
  if q < 1 then q := 1 else if q > PROB_ONE - 1 then q := PROB_ONE - 1;
  p := q;
  if (n < limit) and (n < MAX_LIMIT) then Inc(n);
end;

var k: Integer;
initialization
  for k := 0 to MAX_LIMIT do RECIPROCAL[k] := Round(PROB_ONE / (k + 1.5));
end.

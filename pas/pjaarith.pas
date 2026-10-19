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
  TArithEncoder = record
    x1, x2: Cardinal;
    d: TBytes;
    n: SizeInt;
    procedure Init;
    procedure Encode(bit: Integer; p: Integer);
    { The low `count` bits of v, most significant first, at probability 1/2. }
    procedure Direct(v: Cardinal; count: Integer);
    function Finish: TBytes;
  end;

  TArithDecoder = record
    x1, x2, x: Cardinal;
    d: TBytes;
    p: SizeInt;
    procedure Init(const data: TBytes; first: SizeInt = 0);
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

function Split(x1, x2: Cardinal; p: Integer): Cardinal; inline;
begin
  Result := x1 + Cardinal((QWord(x2 - x1) * Cardinal(p)) shr 16);
end;

function Clamp(p: Integer): Integer; inline;
begin
  if p < 1 then Result := 1 else if p > PROB_ONE - 1 then Result := PROB_ONE - 1 else Result := p;
end;

{ ---------- encoder ---------- }

procedure TArithEncoder.Init;
begin
  x1 := 0; x2 := $FFFFFFFF;
  SetLength(d, 4096); n := 0;
end;

procedure TArithEncoder.Encode(bit: Integer; p: Integer);
var xm: Cardinal;
begin
  xm := Split(x1, x2, Clamp(p));
  if bit <> 0 then x2 := xm else x1 := xm + 1;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    if n >= Length(d) then SetLength(d, 2 * Length(d));
    d[n] := Byte(x2 shr 24); Inc(n);
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
    if n >= Length(d) then SetLength(d, 2 * Length(d));
    d[n] := Byte(x1 shr 24); Inc(n);
    x1 := x1 shl 8;
  end;
  Result := Copy(d, 0, n);
end;

{ ---------- decoder ---------- }

procedure TArithDecoder.Init(const data: TBytes; first: SizeInt);
var k: Integer; b: Byte;
begin
  d := data; p := first;
  x1 := 0; x2 := $FFFFFFFF; x := 0;
  for k := 0 to 3 do begin
    if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
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
    if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
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

{ Layer 2: the arithmetic coder.
  - round trip of millions of bits, at fixed and adaptive probabilities;
  - cost: within 0.5% of the entropy when the probability is known;
  - decoding garbage (and truncated data) never raises an exception. }
program test_arith;
{$I ../pja.inc}
uses SysUtils, Math, pjaarith;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

const N = 2000000;
var
  bits, probs: array of Integer;
  enc: TArithEncoder; dec: TArithDecoder; stream, garbage: TBytes;
  i, k, bad, prob: Integer; entropy, q: Double; ctx: array[0..255] of TAdaptiveBit;
  seed: Cardinal; v: Cardinal;

function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;

begin
  cells := 0; failures := 0; seed := 2463534242;
  SetLength(bits, N); SetLength(probs, N);

  { 1. known probability: cost against entropy, including both extremes }
  entropy := 0;
  for i := 0 to N - 1 do begin
    case i mod 4 of
      0: prob := 1 + Integer(Rand mod 400);
      1: prob := 65135 + Integer(Rand mod 400);
      2: prob := 1 + Integer(Rand mod 65535);
    else prob := 32768;
    end;
    probs[i] := prob;
    if (Rand and $FFFF) < Cardinal(prob) then bits[i] := 1 else bits[i] := 0;
    q := prob / 65536; if bits[i] = 0 then q := 1 - q;
    entropy := entropy - Log2(q);
  end;
  enc.Init;
  for i := 0 to N - 1 do enc.Encode(bits[i], probs[i]);
  stream := enc.Finish;
  dec.Init(stream);
  bad := 0;
  for i := 0 to N - 1 do if dec.Decode(probs[i]) <> bits[i] then Inc(bad);
  Check(bad = 0, Format('%d bits at known probability: round trip', [N]));
  Check(Length(stream) * 8 < entropy * 1.005 + 64,
     Format('cost %d bytes, entropy %.0f bytes (+%.3f%%)', [Length(stream), entropy / 8, 100 * (Length(stream) * 8 / entropy - 1)]));

  { 2. adaptive contexts, each with its own bias }
  for k := 0 to 255 do ctx[k].Init;
  enc.Init;
  for i := 0 to N - 1 do begin
    k := i and 255;
    if (Rand and 255) < Cardinal(k) then bits[i] := 1 else bits[i] := 0;
    enc.Encode(bits[i], ctx[k].p); ctx[k].Update(bits[i], 60);
  end;
  stream := enc.Finish;
  for k := 0 to 255 do ctx[k].Init;
  dec.Init(stream); bad := 0;
  for i := 0 to N - 1 do begin
    k := i and 255;
    v := dec.Decode(ctx[k].p); ctx[k].Update(v, 60);
    if Integer(v) <> bits[i] then Inc(bad);
  end;
  Check(bad = 0, Format('%d bits in 256 adaptive contexts: round trip (%d bytes)', [N, Length(stream)]));

  { 3. direct bits }
  enc.Init;
  for i := 0 to 9999 do enc.Direct(Cardinal(i * 2654435761 and $FFFFFF), 24);
  stream := enc.Finish; dec.Init(stream); bad := 0;
  for i := 0 to 9999 do if dec.Direct(24) <> Cardinal(i * 2654435761 and $FFFFFF) then Inc(bad);
  Check(bad = 0, '24-bit direct values: round trip');

  { 4. garbage and truncation: never an exception }
  bad := 0;
  for k := 0 to 999 do begin
    SetLength(garbage, Integer(Rand mod 64));
    for i := 0 to High(garbage) do garbage[i] := Byte(Rand);
    try
      dec.Init(garbage);
      for i := 0 to 9999 do dec.Decode(1 + Integer(Rand mod 65535));
    except on e: Exception do Inc(bad); end;
  end;
  Check(bad = 0, '1000 garbage streams (0 to 63 bytes) x 10000 bits, no exception');

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 5) then Halt(1);
end.

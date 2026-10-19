{ pjablake3 against the vectors of the official implementation (kat.txt, the
  "b3" lines): every size there, whole, split into two ranges, and fed in
  pieces of several sizes, which have to give the same hash. A range outside
  the buffer has to be refused. }
program test_blake3;
{$I ../pja.inc}
uses SysUtils, Classes, pjablake3;
var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:58, '  ok') else begin Inc(failures); Writeln('  ', what:58, '  FAIL'); end; end;
function Hex(const x: array of Byte): string; var i: Integer;
begin Result := ''; for i := 0 to High(x) do Result := Result + LowerCase(IntToHex(x[i], 2)); end;

{ xorshift32 with no short period, so that a one-byte shift shows. }
function Pattern(n: SizeInt; seed: LongWord): TBytes; var x: LongWord; i: SizeInt;
begin
  Result := nil; SetLength(Result, n); x := seed;
  for i := 0 to n - 1 do begin
    x := x xor (x shl 13); x := x xor (x shr 17); x := x xor (x shl 5);
    Result[i] := Byte(x shr 3);
  end;
end;

{ fed in pieces of `step` bytes }
function InPieces(const d: TBytes; step: SizeInt): THash16;
var h: TBlake3; p, k: SizeInt;
begin
  h.Init; p := 0;
  while p < Length(d) do begin
    k := step; if p + k > Length(d) then k := Length(d) - p;
    h.Update(d[p], k); Inc(p, k);
  end;
  Result := h.Final;
end;

var kat: TStringList; l: string; fields: TStringArray; n, nb3, cut, s: Integer;
    d, x: TBytes; h: THash16; raised, same: Boolean;
const STEPS: array[0..5] of Integer = (1, 7, 63, 64, 65, 1024);
begin
  cells := 0; failures := 0; nb3 := 0;
  kat := TStringList.Create; kat.LoadFromFile(ParamStr(1));
  for l in kat do begin
    if (l = '') or (l[1] = '#') then Continue;
    fields := l.Split(' ');
    if fields[0] <> 'b3' then Continue;
    Inc(nb3);
    n := StrToInt(fields[1]);
    d := Pattern(n, $1234567 xor LongWord(n));
    Check(Hex(Blake3_128(d)) = fields[2], Format('BLAKE3-128 of %d B = the official one', [n]));
    if n > 1 then begin
      cut := n div 3;
      Check(Hex(Blake3_128(d, 0, cut, d, cut, n - cut)) = fields[2], Format('  split into two ranges at %d', [cut]));
    end;
    same := True;
    for s in STEPS do
      if (n <= 70000) or (s >= 63) then
        if Hex(InPieces(d, s)) <> fields[2] then same := False;
    Check(same, '  fed in pieces of 1, 7, 63, 64, 65, 1024 B');
  end;
  kat.Free;
  Check(nb3 >= 12, Format('vectors read: %d', [nb3]));

  x := nil;
  h := Blake3_128(x, 0, 0, nil, 0, 0);
  Check(Hex(h) = 'af1349b9f5f9a1a6a0404dea36dcc949', 'two empty ranges = BLAKE3 of nothing');
  SetLength(x, 10); raised := False;
  try h := Blake3_128(x, 5, 6, nil, 0, 0); except on ERangeError do raised := True; end;
  Check(raised, 'range [5,+6) over 10 bytes is refused');
  raised := False;
  try h := Blake3_128(x, -1, 2, nil, 0, 0); except on ERangeError do raised := True; end;
  Check(raised, 'a negative start is refused');

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 30) then Halt(1);
end.

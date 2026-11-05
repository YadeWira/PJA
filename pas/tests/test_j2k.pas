{ Where the JPEG 2000 family's codestreams are (pjaj2k), and the table of
  stream version 8 that keeps it. In stage A every byte goes through the raw
  bytes' model whatever the table says, so a round trip does not show a
  walker that lost a codestream: this test does.

  - each file of tests/j2k: its codestreams, K and each one's place and
    length, as they are; and its version 8 stream's table, the same;
  - files of boxes built here, one case each: a jp2c at the top, with a
    64-bit length (XLBox), with length 0 (to the end of the file), in an mdat,
    in a box that is not a superbox (not walked), with contents that are not
    a codestream, after a box that does not fit (the walk ends there), an
    XLBox too large or too small, superboxes MAX_J2K_DEPTH deep and one more;
    a raw codestream with bytes after its EOC.

    test_j2k <tests/j2k directory> }
program test_j2k;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjaj2k, pjacodec;

var cells, failures: Integer;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(cells);
  if not ok then begin Inc(failures); Writeln('  FAIL ', what); end;
end;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

function GetU32(const d: TBytes; p: Integer): Cardinal;
begin
  Result := Cardinal(d[p]) or (Cardinal(d[p + 1]) shl 8) or (Cardinal(d[p + 2]) shl 16) or (Cardinal(d[p + 3]) shl 24);
end;

function Cat(const a, b: TBytes): TBytes;
begin
  Result := nil; SetLength(Result, Length(a) + Length(b));
  if Length(a) > 0 then Move(a[0], Result[0], Length(a));
  if Length(b) > 0 then Move(b[0], Result[Length(a)], Length(b));
end;

function Be32(v: Cardinal): TBytes;
begin
  Result := nil; SetLength(Result, 4);
  Result[0] := v shr 24; Result[1] := (v shr 16) and $FF; Result[2] := (v shr 8) and $FF; Result[3] := v and $FF;
end;

function Kind(const t: string): TBytes;
var i: Integer;
begin
  Result := nil; SetLength(Result, 4);
  for i := 0 to 3 do Result[i] := Ord(t[i + 1]);
end;

function Box(const t: string; const payload: TBytes): TBytes;
begin
  Result := Cat(Cat(Be32(8 + Length(payload)), Kind(t)), payload);
end;

{ a box with LBox 1 and the 64-bit length given (16 + payload when 0) }
function XlBox(const t: string; const payload: TBytes; xl: QWord = 0): TBytes;
begin
  if xl = 0 then xl := 16 + Length(payload);
  Result := Cat(Cat(Cat(Be32(1), Kind(t)), Cat(Be32(xl shr 32), Be32(xl and $FFFFFFFF))), payload);
end;

{ a box with LBox 0: to the end of what holds it }
function OpenBox(const t: string; const payload: TBytes): TBytes;
begin
  Result := Cat(Cat(Be32(0), Kind(t)), payload);
end;

{ the codestreams of data, as "off+len off+len" }
function Places(const data: TBytes): string;
var cs: TJ2kCodestreams; i: Integer;
begin
  if not J2kCodestreams(data, cs) then Exit('none');
  Result := Format('K=%d', [Length(cs)]);
  for i := 0 to High(cs) do Result := Result + Format(' %d+%d', [cs[i].off, cs[i].len]);
end;

{ the table of data's version 8 stream, the same way }
function StreamPlaces(const data: TBytes): string;
var st: TBytes; r: TCodecResult; i, k: Integer;
begin
  r := Compress(data, st, True, 1, False, True, False);
  if not r.Ok then Exit('not compressed');
  if st[0] <> STREAM_J2K then Exit(Format('version %d', [st[0]]));
  k := Integer(GetU32(st, 2));
  Result := Format('K=%d', [k]);
  for i := 0 to k - 1 do Result := Result + Format(' %d+%d', [GetU32(st, 6 + 13 * i), GetU32(st, 6 + 13 * i + 4)]);
end;

procedure Expect(const what: string; const data: TBytes; const want: string);
begin
  Check(Places(data) = want, Format('%s: %s, not %s', [what, Places(data), want]));
end;

const
  { tests/j2k: each file and its codestreams (tests/README.md) }
  J2K_FILES: array[0..6, 0..1] of string = (
    ('gray_12bit.jp2', 'K=1 85+544'),
    ('layers.jp2', 'K=1 85+1360'),
    ('lossless53.j2k', 'K=1 0+2413'),
    ('plasma_cs.j2k', 'K=1 0+612'),
    ('plasma.jp2', 'K=1 85+3615'),
    { the first in an XLBox, the second in a box of length 0 }
    ('two_codestreams.jpx', 'K=2 197+612 817+2413'),
    { both in an mdat }
    ('two_frames.mj2', 'K=2 48+612 668+626'));

var
  dir: string; i: Integer; cs, sig, jp2c, nest, junk, d: TBytes;
begin
  dir := ParamStr(1);
  cells := 0; failures := 0;
  for i := 0 to High(J2K_FILES) do begin
    d := ReadFile(dir + '/' + J2K_FILES[i, 0]);
    Expect(J2K_FILES[i, 0], d, J2K_FILES[i, 1]);
    Check(StreamPlaces(d) = J2K_FILES[i, 1], Format('%s: stream %s, not %s', [J2K_FILES[i, 0], StreamPlaces(d), J2K_FILES[i, 1]]));
  end;

  { built here, around a raw codestream of 612 bytes }
  cs := ReadFile(dir + '/plasma_cs.j2k');
  Check(Length(cs) = 612, 'plasma_cs.j2k is 612 bytes');
  sig := Box('jP  ', Cat(Kind(#13#10#$87#10), nil));
  jp2c := Box('jp2c', cs);
  junk := Kind('junk');
  Expect('raw, bytes after the EOC', Cat(cs, junk), 'K=1 0+612');
  Expect('raw, not a codestream', junk, 'none');
  Expect('signature alone', sig, 'K=0');
  Expect('jp2c', Cat(sig, jp2c), 'K=1 20+612');
  Expect('jp2c, then junk', Cat(Cat(sig, jp2c), junk), 'K=1 20+612');
  Expect('jp2c with an XLBox', Cat(sig, XlBox('jp2c', cs)), 'K=1 28+612');
  Expect('jp2c of length 0', Cat(sig, OpenBox('jp2c', Cat(cs, junk))), 'K=1 20+616');
  Expect('jp2c in an mdat', Cat(sig, Box('mdat', jp2c)), 'K=1 28+612');
  Expect('jp2c in an mdat of length 0', Cat(sig, OpenBox('mdat', Cat(jp2c, jp2c))), 'K=2 28+612 648+612');
  Expect('jp2c in an mdat with an XLBox', Cat(sig, XlBox('mdat', jp2c)), 'K=1 36+612');
  Expect('jp2c in a box that is not a superbox', Cat(sig, Box('free', jp2c)), 'K=0');
  Expect('jp2c of other bytes', Cat(sig, Box('jp2c', Cat(junk, cs))), 'K=0');
  Expect('jp2c of 3 bytes', Cat(sig, Box('jp2c', Copy(cs, 0, 3))), 'K=0');
  { a box larger than what is left: the walk ends, what came before stays }
  d := Cat(Cat(sig, jp2c), Box('jp2c', cs));
  d := Copy(d, 0, Length(d) - 1);
  Expect('a box past the end', d, 'K=1 20+612');
  Expect('an XLBox past the end', Cat(Cat(sig, jp2c), XlBox('jp2c', cs, 16 + 613)), 'K=1 20+612');
  Expect('an XLBox of 15', Cat(Cat(sig, jp2c), XlBox('jp2c', cs, 15)), 'K=1 20+612');
  Expect('an XLBox past 2^32', Cat(Cat(sig, jp2c), XlBox('jp2c', cs, QWord(1) shl 32 + 16 + 612)), 'K=1 20+612');
  { a box of 7 bytes: the walk ends }
  Expect('LBox 7', Cat(Cat(sig, Cat(Be32(7), Kind('free'))), jp2c), 'K=0');
  { superboxes MAX_J2K_DEPTH deep are walked, one more is not }
  nest := jp2c;
  for i := 1 to MAX_J2K_DEPTH do nest := Box('asoc', nest);
  Expect('jp2c at the deepest', Cat(sig, nest), Format('K=1 %d+612', [12 + 8 * MAX_J2K_DEPTH + 8]));
  Expect('jp2c deeper', Cat(sig, Box('asoc', nest)), 'K=0');
  { and the stream's table follows the walk }
  d := Cat(Cat(sig, XlBox('jp2c', cs)), Box('mdat', Cat(Box('free', junk), OpenBox('jp2c', cs))));
  Expect('XLBox, then an mdat', d, 'K=2 28+612 668+612');
  Check(StreamPlaces(d) = 'K=2 28+612 668+612', 'XLBox, then an mdat: stream ' + StreamPlaces(d));

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 30) then Halt(1);
end.

{ What the zpaq-std plugin asks of its frozen ZPAQL decoders
  (pas/plugin/pjazpaqlargs), where the decoders cannot be run on a file
  large enough in the suite (test_pjadec.py is an interpreter):
  - pjall's H counts the bands ljpeg.zl's jlsbandcount decodes, each with
    its model and rows: a lossless JPEG of 2048x2048 has four;
  - a JPEG with more scans than pjadec.zl's MAXSCANS (256), built here, is
    refused by pjax's detection when it rides in a host, and by pja's and
    pjax's queries (each part is a version 5 stream), and a control with
    fewer is taken.

    test_zpaqlargs <dir with baseline_color.jpg> }
program test_zpaqlargs;
{$I ../pja.inc}
uses {$ifdef unix}cthreads,{$endif} SysUtils, Classes, pjajpeg, pjacodec, pjamodel, pjazpaqlargs, pjav7;
var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:62, '  ok') else begin Inc(failures); Writeln('  ', what:62, '  FAIL'); end; end;

function ReadFile(const name: string): TBytes;
var f: TFileStream;
begin
  Result := nil;
  f := TFileStream.Create(name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally f.Free; end;
end;

procedure Put(var d: TBytes; const b: array of Byte);
var i, n: SizeInt;
begin
  n := Length(d);
  SetLength(d, n + Length(b));
  for i := 0 to High(b) do d[n + i] := b[i];
end;

{ an 8x8 gray progressive JPEG, every coefficient 0: the DC and each AC
  coefficient alone, from the bit al down, one scan a bit: 64 * (al + 1)
  scans. Each scan's data is one code of 0 (DC category 0, an EOB run of
  1, or the DC's correction bit), padded with ones. }
function ManyScans(al: Integer): TBytes;
var k, a: Integer;

  procedure Scan(ss, ah, al_: Integer);
  begin
    Put(Result, [$FF, $DA, 0, 8, 1, 1, 0, ss, ss, (ah shl 4) or al_, $7F]);
  end;

begin
  Result := nil;
  Put(Result, [$FF, $D8]);
  Put(Result, [$FF, $DB, 0, 67, 0]);
  for k := 1 to 64 do Put(Result, [1]);
  Put(Result, [$FF, $C2, 0, 11, 8, 0, 8, 0, 8, 1, 1, $11, 0]);
  { one code of length 1 for symbol 0, DC and AC }
  Put(Result, [$FF, $C4, 0, 20, $00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  Put(Result, [$FF, $C4, 0, 20, $10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  for k := 0 to 63 do begin
    Scan(k, 0, al);
    for a := al - 1 downto 0 do Scan(k, a + 1, a);
  end;
  Put(Result, [$FF, $D9]);
end;

{ pjax's detection (pja_zpaqstd) for host + part }
procedure CheckHosted(const host, part: TBytes; take: Boolean; const what: string);
var d: TBytes; j: TJpeg; after, w: Int64;
begin
  d := Copy(host, 0, Length(host));
  SetLength(d, Length(host) + Length(part));
  Move(part[0], d[Length(host)], Length(part));
  if not VerifyRoundTrip(d, j).Ok then begin Check(False, what + ': the host rebuilds'); Exit; end;
  w := ZpaqlPjaxFileWords(d, j, after);
  Check((w >= 0) = take, what + ': pjax''s detection');
  w := ZpaqlPjaxFileWords(d, j, after, True);
  Check((w >= 0) = take, what + ': pjax7''s detection');
end;

{ pjax's query for a version 5 (or 7) stream of the JPEG: its scans are
  pjax.zl's as a part's }
procedure CheckQuery(const jpeg: TBytes; take: Boolean; const what: string);
var stream: TBytes;
begin
  Check(Compress(jpeg, stream, True, 1, False, False).Ok and ((ZpaqlPjaxArgs(stream) >= 0) = take),
        what + ': pjax''s query');
  Check((ZpaqlArgs(stream) >= 0) = take, what + ': pja''s query');
  Check(Compress(jpeg, stream, True, 1, False, False, True).Ok and ((ZpaqlPjaxArgs(stream, True) >= 0) = take),
        what + ': pjax7''s query');
  Check((ZpaqlArgs7(stream) >= 0) = take, what + ': pja7''s query');
end;

var j, j1: TJpeg; host, part: TBytes; pj: TJpeg; expect: Int64;
begin
  cells := 0; failures := 0;
  if ParamCount < 1 then begin Writeln('usage: test_zpaqlargs <tests/jpg>'); Halt(2); end;

  { pjall: one row against 2048, the same width and component }
  j := Default(TJpeg); j.width := 2048; j.height := 2048; SetLength(j.comp, 1);
  j1 := Default(TJpeg); j1.width := 2048; j1.height := 1; SetLength(j1.comp, 1);
  expect := ZpaqlLjpegWords(j1) + Int64(2048) * 2047 + 3 * (ZPAQL_LS_BAND_WORDS + 2 * 2048);
  Check(ZpaqlLjpegWords(j) = expect, 'pjall: 2048x2048 gray, 4 bands of model and rows');
  { 2048x1981 gray: 3 bands, past 2^22 words (0.6.3 said 2^22) }
  j.height := 1981;
  Check(ZpaqlLjpegWords(j) = ZpaqlLjpegWords(j1) + Int64(2048) * 1980 + 2 * (ZPAQL_LS_BAND_WORDS + 2 * 2048),
        'pjall: 2048x1981 gray, 3 bands');
  SetLength(j.comp, 3); SetLength(j1.comp, 3);
  Check(ZpaqlLjpegWords(j) = ZpaqlLjpegWords(j1) + Int64(2048) * 1980 * 3 + 10 * (ZPAQL_LS_BAND_WORDS + 2 * 2048 * 3),
        'pjall: 2048x1981 color, 11 bands');

  { the parts: 320 scans, refused; 64, taken }
  part := ManyScans(4);
  Check(VerifyRoundTrip(part, pj).Ok and (Length(pj.scans) = 320), 'the JPEG of 320 scans rebuilds');
  part := ManyScans(0);
  Check(VerifyRoundTrip(part, pj).Ok and (Length(pj.scans) = 64), 'the JPEG of 64 scans rebuilds');
  host := ReadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'baseline_color.jpg');
  CheckHosted(host, ManyScans(4), False, 'after the EOI, 320 scans');
  CheckHosted(host, ManyScans(0), True, 'after the EOI, 64 scans');
  CheckQuery(ManyScans(4), False, '320 scans');
  CheckQuery(ManyScans(0), True, '64 scans');

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 17) then Halt(1);
end.

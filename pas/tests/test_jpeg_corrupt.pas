{ Layer 1 against broken JPEGs: every bit of every file flipped (up to the
  first max bytes), and every truncation. VerifyRoundTrip must return a named
  error or rebuild identically: an exception (range, overflow) is a FAILURE.

    test_jpeg_corrupt <directory> [max bytes per file] }
program test_jpeg_corrupt;
{$I ../pja.inc}
uses SysUtils, Classes, pjajpeg, pjajls;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  dir: string; files: TStringList; sr: TSearchRec;
  i, b, maxBytes: Integer; n, variants, accepted, failures: Int64;
  d, m: TBytes; j: TJpeg; jl: TJls; r: TJpegResult; isLs: Boolean;

procedure Try1(const x: TBytes; const what: string);
begin
  Inc(variants);
  try
    { a JPEG-LS file, damaged, can stop looking like one: then it goes to the
      JPEG path, which has to reject it just as safely }
    if isLs and IsJls(x) then r := VerifyJls(x, jl) else r := VerifyRoundTrip(x, j);
    if r.Ok then Inc(accepted);
  except
    on e: Exception do begin
      Inc(failures);
      if failures <= 20 then Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', what);
    end;
  end;
end;

begin
  dir := ParamStr(1); maxBytes := StrToIntDef(ParamStr(2), 4096);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  variants := 0; accepted := 0; failures := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    isLs := IsJls(d);
    n := Length(d); if n > maxBytes then n := maxBytes;
    for b := 0 to n * 8 - 1 do begin
      m := Copy(d, 0, Length(d));
      m[b div 8] := m[b div 8] xor (1 shl (b mod 8));
      Try1(m, Format('%s bit %d', [ExtractFileName(files[i]), b]));
    end;
    for b := 0 to Length(d) - 1 do Try1(Copy(d, 0, b), Format('%s truncated to %d', [ExtractFileName(files[i]), b]));
  end;
  { an accepted variant is legitimate: VerifyRoundTrip rebuilt it identically }
  Writeln(files.Count, ' files, ', variants, ' variants, ', accepted, ' identical round trips, ', failures, ' failures');
  if (failures > 0) or (variants < 1000) then Halt(1);
end.

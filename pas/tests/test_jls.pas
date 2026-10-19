{ JPEG-LS, layer 1: every .jls in the directory, decomposed into samples and
  recomposed, must give the same file byte for byte, or a named error. An
  exception is a FAILURE. With a dump directory, the decoded samples go
  there (16-bit little endian, component after component) to be compared
  with another decoder.

    test_jls <directory> [minimum round trips] [dump directory] }
program test_jls;
{$I ../pja.inc}
uses SysUtils, Classes, pjajpeg, pjajls;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; i, c, ok, failures, minimum: Integer; d: TBytes; j: TJls;
  r: TJpegResult; dump: string; fs: TFileStream; k: SizeInt; w: Word;
begin
  minimum := StrToIntDef(ParamStr(2), 1); dump := ParamStr(3);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(ParamStr(1) + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(1) + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ok := 0; failures := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    try
      if not IsJls(d) then Continue;
      r := VerifyJls(d, j);
      if r.Ok then Inc(ok);
      { the samples, whenever they were decoded (also when the rebuild differs) }
      if (dump <> '') and (r.Ok or (r.err = jeNoRoundTrip)) then begin
        fs := TFileStream.Create(dump + '/' + ExtractFileName(files[i]) + '.raw', fmCreate);
        try
          for c := 0 to High(j.comp) do
            for k := 0 to High(j.comp[c].samples) do begin
              w := NtoLE(j.comp[c].samples[k]);
              fs.WriteBuffer(w, 2);
            end;
        finally fs.Free; end;
      end;
      if not r.Ok then begin
        if r.err = jeNoRoundTrip then Inc(failures);
        Writeln('  ', r.Text:30, '  ', ExtractFileName(files[i]));
      end;
    except
      on e: Exception do begin
        Inc(failures);
        Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', ExtractFileName(files[i]));
      end;
    end;
  end;
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: round trips ', ok, ' < minimum ', minimum); end;
  Writeln(files.Count, ' files, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.

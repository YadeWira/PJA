{ Layer 1: every JPEG in the directory, decomposed into coefficients and
  recomposed, must give the same file byte for byte, or a named error. An
  exception is a FAILURE (out of range, overflow): no JPEG, broken or not, may
  produce one.

    test_jpeg <directory> [minimum round trips] [-v] }
program test_jpeg;
{$I ../pja.inc}
uses SysUtils, Classes, pjajpeg;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  dir: string; files, reasons: TStringList; sr: TSearchRec;
  i, k, minimum, ok, failures: Integer; verbose: Boolean;
  d: TBytes; j: TJpeg; r: TJpegResult; key: string;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1); verbose := ParamStr(3) = '-v';
  files := TStringList.Create; files.Sorted := True;
  reasons := TStringList.Create; reasons.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ok := 0; failures := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    try
      r := VerifyRoundTrip(d, j);
      if r.Ok then begin Inc(ok); key := 'ok'; end
      else begin
        key := r.Text; Delete(key, Pos('@', key), MaxInt);
        { a different rebuild is a defect of this layer until explained }
        if r.err = jeNoRoundTrip then Inc(failures);
      end;
      if verbose or (r.err = jeNoRoundTrip) then Writeln('  ', key:28, '  ', r.Text, '  ', ExtractFileName(files[i]));
    except
      on e: Exception do begin
        Inc(failures); key := 'EXCEPTION';
        Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', ExtractFileName(files[i]));
      end;
    end;
    k := reasons.IndexOf(key);
    if k < 0 then reasons.AddObject(key, TObject(PtrInt(1)))
    else reasons.Objects[k] := TObject(PtrInt(reasons.Objects[k]) + 1);
  end;
  for i := 0 to reasons.Count - 1 do Writeln('  ', reasons[i]:28, ' ', PtrInt(reasons.Objects[i]):6);
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: round trips ', ok, ' < minimum ', minimum); end;
  Writeln(files.Count, ' files, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.

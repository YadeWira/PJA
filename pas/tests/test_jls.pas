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

function Bytes(const b: array of Byte): TBytes; var i: Integer;
begin Result := nil; SetLength(Result, Length(b)); for i := 0 to High(b) do Result[i] := b[i]; end;

function Splice(const parts: array of TBytes): TBytes; var i: Integer;
begin Result := nil; for i := 0 to High(parts) do Result := Concat(Result, parts[i]); end;

{ a synthetic file: taken (and given back the same) or refused, never an
  exception }
function CheckSynthetic(const d: TBytes; taken: Boolean; const what: string): Boolean;
var j: TJls; r: TJpegResult;
begin
  try
    r := VerifyJls(d, j);
    Result := IsJls(d) and (r.Ok = taken);
    if not Result then Writeln('  FAIL ', what, ': ', r.Text);
  except
    on e: Exception do begin
      Writeln('  FAIL ', what, ': ', e.ClassName, ': ', e.Message);
      Result := False;
    end;
  end;
end;

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
  { made from gray8.jls: fill bytes before markers are taken; a component
    coded by a second scan, and 1x1 components smaller than the frame in an
    interleaved scan, are refused without an exception }
  if FileExists(ParamStr(1) + '/gray8.jls') then
    try
      d := ReadFile(ParamStr(1) + '/gray8.jls');
      k := 2;
      while not ((d[k] = $FF) and (d[k + 1] = $DA)) do Inc(k);
      if not CheckSynthetic(Splice([Copy(d, 0, 2), Bytes([$FF]), Copy(d, 2, k - 2), Bytes([$FF]),
                                    Copy(d, k, Length(d) - k)]), True, 'fill bytes') then Inc(failures);
      if not CheckSynthetic(Splice([Copy(d, 0, Length(d) - 2), Copy(d, k, Length(d) - k)]), False,
                            'a component in two scans') then Inc(failures);
      { X=16 Y=2, components 1-3 1x1 (8x1), 4 2x2 (16x2) }
      for c := 1 to 2 do
        if not CheckSynthetic(Bytes([$FF, $D8, $FF, $F7, 0, 20, 8, 0, 2, 0, 16, 4, 1, $11, 0, 2, $11, 0, 3, $11, 0, 4, $22, 0,
                                     $FF, $DA, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, c, 0, 0, 0, 0, 0, $FF, $D9]), False,
                              'small 1x1 components, interleave ' + IntToStr(c)) then Inc(failures);
    except
      on e: Exception do begin
        Inc(failures);
        Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  synthetic files');
      end;
    end;
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: round trips ', ok, ' < minimum ', minimum); end;
  Writeln(files.Count, ' files, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.

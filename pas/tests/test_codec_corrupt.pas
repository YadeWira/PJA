{ Layer 4 against damaged streams: every JPEG in the directory is compressed,
  and then every bit of the stream (up to the first max bytes) is flipped
  and every truncation tried. Decompress may give an error or a JPEG (a
  different one is caught later by the container's size and hash); an
  exception is a FAILURE.

    test_codec_corrupt <directory> [max bytes per stream] }
program test_codec_corrupt;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; i, b, maxBytes: Integer; n: SizeInt;
  variants, decoded, same, failures: Int64; d, st, m, back: TBytes;

procedure Try1(const x: TBytes; const what: string);
begin
  Inc(variants);
  try
    if Decompress(x, back, 1 shl 24).Ok then begin
      Inc(decoded);
      if (Length(back) = Length(d)) and CompareMem(@back[0], @d[0], Length(d)) then Inc(same);
    end;
  except
    on e: Exception do begin
      Inc(failures);
      if failures <= 20 then Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', what);
    end;
  end;
end;

begin
  maxBytes := StrToIntDef(ParamStr(2), 4096);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(ParamStr(1) + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(1) + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  variants := 0; decoded := 0; same := 0; failures := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    if not Compress(d, st).Ok then Continue;
    n := Length(st); if n > maxBytes then n := maxBytes;
    for b := 0 to n * 8 - 1 do begin
      m := Copy(st, 0, Length(st));
      m[b div 8] := m[b div 8] xor (1 shl (b mod 8));
      Try1(m, Format('%s bit %d', [ExtractFileName(files[i]), b]));
    end;
    for b := 0 to Length(st) - 1 do Try1(Copy(st, 0, b), Format('%s truncated to %d', [ExtractFileName(files[i]), b]));
  end;
  { decoded but different is expected: the codec does not verify, the
    container does (size and hash of the original) }
  Writeln(files.Count, ' files, ', variants, ' variants, ', decoded, ' decoded (', same,
          ' identical to the original), ', failures, ' failures');
  if (failures > 0) or (variants < 1000) then Halt(1);
end.

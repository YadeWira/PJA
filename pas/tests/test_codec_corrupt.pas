{ Layer 4 against damaged streams: every JPEG in the directory is compressed,
  and then every bit of the stream (up to the first max bytes) is flipped
  and every truncation tried. So is the stream of the first file cut in
  half, which PJA takes only as bytes (stream version 6, BYTES). Decompress may give an error or a JPEG (a
  different one is caught later by the container's size and hash); an
  exception is a FAILURE. The variants run on every processor (corrupt_par).

    test_codec_corrupt <directory> [max bytes per stream] }
program test_codec_corrupt;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjacodec, corrupt_par;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; i, maxBytes: Integer;
  { the inputs: each original, its stream, its name; the last one may be the
    stream of a file cut in half, which went as bytes }
  orig, streams: array of TBytes; names: array of string; totals: array of Int64;
  d, st: TBytes; r: TCodecResult; bytesDone, fast: Boolean; c: TVariantCounts;

procedure AddInput(const o, s: TBytes; const name: string);
var n: Integer;
begin
  n := Length(streams);
  SetLength(orig, n + 1); SetLength(streams, n + 1); SetLength(names, n + 1); SetLength(totals, n + 1);
  orig[n] := o; streams[n] := s; names[n] := name;
  totals[n] := VariantCount(Length(s), maxBytes);
end;

{ variant v of input k: a bit flipped, or the stream truncated }
function TryVariant(k: Integer; v: Int64; out what: string): Integer;
var m, back: TBytes; flips: Int64;
begin
  Result := 0; what := '';
  flips := Length(streams[k]); if flips > maxBytes then flips := maxBytes; flips := flips * 8;
  if v < flips then begin
    m := Copy(streams[k], 0, Length(streams[k]));
    m[v div 8] := m[v div 8] xor (1 shl (v mod 8));
  end else m := Copy(streams[k], 0, v - flips);
  try
    if Decompress(m, back, 1 shl 24).Ok then begin
      Result := CV_TAKEN;
      if (Length(back) = Length(orig[k])) and CompareMem(@back[0], @orig[k][0], Length(back)) then
        Result := Result or CV_SAME;
    end;
  except
    on e: Exception do begin
      Result := CV_FAILURE;
      if v < flips then what := Format('%s: %s  %s bit %d', [e.ClassName, e.Message, names[k], v])
      else what := Format('%s: %s  %s truncated to %d', [e.ClassName, e.Message, names[k], v - flips]);
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
  { PJA_TEST_FAST=1: the streams of the fast model }
  fast := GetEnvironmentVariable('PJA_TEST_FAST') = '1';
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    if Compress(d, st, True, 1, fast).Ok then AddInput(d, st, ExtractFileName(files[i]));
  end;
  { a file cut in half goes as bytes: that stream damaged the same way }
  bytesDone := False;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    d := Copy(d, 0, Length(d) div 2);
    r := Compress(d, st, True, 1);
    if not r.Ok or not r.asBytes then Continue;
    AddInput(d, st, ExtractFileName(files[i]) + ' cut in half, as bytes');
    bytesDone := True;
    Break;
  end;
  c := RunVariants(totals, @TryVariant);
  if not bytesDone then begin Inc(c.failures); Writeln('  FAIL no file cut in half went as bytes'); end;
  { decoded but different is expected: the codec does not verify, the
    container does (size and hash of the original) }
  Writeln(files.Count, ' files, ', c.variants, ' variants, ', c.taken, ' decoded (', c.same,
          ' identical to the original), ', c.failures, ' failures');
  if (c.failures > 0) or (c.variants < 1000) then Halt(1);
end.

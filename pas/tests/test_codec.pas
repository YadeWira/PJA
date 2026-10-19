{ Layers 3 and 4: every JPEG in the directory compressed (Compress verifies
  the round trip itself) and decompressed again by a separate call, which has
  to give the same bytes. Prints sizes and the total ratio; with a reference
  file (`name size` per line, e.g. packJPG's .pjg sizes) it also compares.

    test_codec <directory> [minimum round trips] [reference sizes file] [-v] }
program test_codec;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, DateUtils, pjajpeg, pjacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  dir, name, refFile: string; files, reasons, ref: TStringList; sr: TSearchRec;
  i, k, minimum, ok, failures: Integer; verbose: Boolean;
  d, st, st4, back: TBytes; r, r2: TCodecResult; key: string;
  sumIn, sumOut, sumRefIn, sumRefOut, refSize: Int64; t0: TDateTime; ms: Int64;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1); refFile := ParamStr(3);
  verbose := (ParamStr(4) = '-v') or (ParamStr(3) = '-v');
  if refFile = '-v' then refFile := '';
  files := TStringList.Create; files.Sorted := True;
  reasons := TStringList.Create; reasons.Sorted := True;
  ref := TStringList.Create; ref.NameValueSeparator := ' ';
  if (refFile <> '') and FileExists(refFile) then ref.LoadFromFile(refFile);
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ok := 0; failures := 0; sumIn := 0; sumOut := 0; sumRefIn := 0; sumRefOut := 0;
  t0 := Now;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]); name := ExtractFileName(files[i]);
    try
      r := Compress(d, st);
      if r.Ok then begin
        { 4 threads: the same stream, and the same JPEG back }
        r2 := Compress(d, st4, True, 4);
        if not r2.Ok or (Length(st4) <> Length(st)) or not CompareMem(@st4[0], @st[0], Length(st)) then begin
          Inc(failures); Writeln('  FAIL the stream depends on the thread count  ', name);
        end;
        r2 := Decompress(st, back, 1 shl 28, 4);
        if r2.Ok and (Length(back) = Length(d)) and CompareMem(@back[0], @d[0], Length(d)) then begin
          Inc(ok); key := 'ok';
          Inc(sumIn, Length(d)); Inc(sumOut, Length(st));
          refSize := StrToInt64Def(ref.Values[name], -1);
          if refSize > 0 then begin Inc(sumRefIn, Length(d)); Inc(sumRefOut, refSize); end;
          if verbose then
            if refSize > 0 then
              Writeln(Format('  %-40s %9d -> %9d (%6.2f%%)  ref %9d (%6.2f%%)',
                [name, Length(d), Length(st), 100 * Length(st) / Length(d), refSize, 100 * refSize / Length(d)]))
            else
              Writeln(Format('  %-40s %9d -> %9d (%6.2f%%)', [name, Length(d), Length(st), 100 * Length(st) / Length(d)]));
        end else begin
          Inc(failures); key := 'SEPARATE DECOMPRESS DIFFERS';
          Writeln('  FAIL ', key, ' ', r2.Text, '  ', name);
        end;
      end else begin
        key := r.Text;
        if Pos('@', key) > 0 then Delete(key, Pos('@', key), MaxInt);
        if r.err = ceNoRoundTrip then begin Inc(failures); Writeln('  FAIL NoRoundTrip  ', name); end;
      end;
    except
      on e: Exception do begin
        Inc(failures); key := 'EXCEPTION';
        Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', name);
      end;
    end;
    k := reasons.IndexOf(key);
    if k < 0 then reasons.AddObject(key, TObject(PtrInt(1)))
    else reasons.Objects[k] := TObject(PtrInt(reasons.Objects[k]) + 1);
  end;
  ms := MilliSecondsBetween(Now, t0);
  for i := 0 to reasons.Count - 1 do Writeln('  ', reasons[i]:40, ' ', PtrInt(reasons.Objects[i]):6);
  if sumIn > 0 then
    Writeln(Format('  total: %d -> %d bytes, %.3f%% (saves %.3f%%), %.1f s', [sumIn, sumOut, 100 * sumOut / sumIn,
      100 - 100 * sumOut / sumIn, ms / 1000]));
  if sumRefIn > 0 then
    Writeln(Format('  reference on the same files: %d -> %d, %.3f%% (saves %.3f%%)', [sumRefIn, sumRefOut,
      100 * sumRefOut / sumRefIn, 100 - 100 * sumRefOut / sumRefIn]));
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: round trips ', ok, ' < minimum ', minimum); end;
  Writeln(files.Count, ' files, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.

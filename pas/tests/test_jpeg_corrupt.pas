{ Layer 1 against broken JPEGs: every bit of every file flipped (up to the
  first max bytes), and every truncation. VerifyRoundTrip must return a named
  error or rebuild identically: an exception (range, overflow) is a FAILURE.
  The variants run on every processor (corrupt_par). The verdicts (error and
  position of each variant) are summed into one number, which has to be the
  same with pjav7's Huffman scans in C and without them (PJA_NOASM=1).

    test_jpeg_corrupt <directory> [max bytes per file] }
program test_jpeg_corrupt;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjajpeg, pjajls, pjav7, corrupt_par;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  dir: string; files: TStringList; sr: TSearchRec; i, maxBytes: Integer;
  inputs: array of TBytes; names: array of string; totals: array of Int64; c: TVariantCounts;
  verdicts: LongInt = 0;

{ one variant's verdict as a number, summed in any order }
{$push}{$Q-}{$R-}
function VerdictHash(k: Integer; v: Int64; const r: TJpegResult): LongInt;
var h: QWord;
begin
  h := QWord(k) * $9E3779B97F4A7C15 + QWord(v) * $C2B2AE3D27D4EB4F + QWord(Ord(r.err)) * $165667B19E3779F9 +
       QWord(r.pos) * $27D4EB2F165667C5 + QWord(r.value);
  h := (h xor (h shr 29)) * $BF58476D1CE4E5B9;
  Result := LongInt(h xor (h shr 32));
end;
{$pop}

{ variant v of file k: a bit flipped, or the file truncated }
function TryVariant(k: Integer; v: Int64; out what: string): Integer;
var m: TBytes; flips: Int64; j: TJpeg; jl: TJls; r: TJpegResult;
begin
  Result := 0; what := '';
  flips := Length(inputs[k]); if flips > maxBytes then flips := maxBytes; flips := flips * 8;
  if v < flips then begin
    m := Copy(inputs[k], 0, Length(inputs[k]));
    m[v div 8] := m[v div 8] xor (1 shl (v mod 8));
  end else m := Copy(inputs[k], 0, v - flips);
  try
    { a JPEG-LS file, damaged, can stop looking like one: then it goes to the
      JPEG path, which has to reject it just as safely }
    if IsJls(inputs[k]) and IsJls(m) then r := VerifyJls(m, jl) else r := VerifyRoundTrip(m, j);
    if r.Ok then Result := CV_TAKEN;
    InterLockedExchangeAdd(verdicts, VerdictHash(k, v, r));
  except
    on e: Exception do begin
      Result := CV_FAILURE;
      if v < flips then what := Format('%s: %s  %s bit %d', [e.ClassName, e.Message, names[k], v])
      else what := Format('%s: %s  %s truncated to %d', [e.ClassName, e.Message, names[k], v - flips]);
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
  SetLength(inputs, files.Count); SetLength(names, files.Count); SetLength(totals, files.Count);
  for i := 0 to files.Count - 1 do begin
    inputs[i] := ReadFile(files[i]);
    names[i] := ExtractFileName(files[i]);
    totals[i] := VariantCount(Length(inputs[i]), maxBytes);
  end;
  c := RunVariants(totals, @TryVariant);
  { an accepted variant is legitimate: VerifyRoundTrip rebuilt it identically }
  Writeln(files.Count, ' files, ', c.variants, ' variants, ', c.taken, ' identical round trips, ', c.failures,
          ' failures, verdicts ', IntToHex(verdicts, 8));
  if (c.failures > 0) or (c.variants < 1000) then Halt(1);
end.

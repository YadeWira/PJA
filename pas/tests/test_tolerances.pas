{ What some encoders do that libjpeg does not, built from the JPEGs in the
  directory and checked through layer 1 and through the whole codec:

  - RST markers after the last restart interval (one and two, following the
    count): they stay in raw;
  - progressive EOB runs cut short because the AC table has no longer EOBr
    symbol: the largest one is taken out of a scan's DHT, the scan is
    re-encoded (so the runs get cut like such an encoder cuts them), and the
    result has to come back byte for byte and decode to the same
    coefficients.

    test_tolerances <directory> }
program test_tolerances;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjajpeg, pjacodec;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;
function Same(const x, y: TBytes): Boolean;
begin Result := (Length(x) = Length(y)) and ((Length(x) = 0) or CompareMem(@x[0], @y[0], Length(x))); end;

{ Through the codec: compressed and back, the same bytes. }
function CodecRoundTrip(const d: TBytes): Boolean;
var st, back: TBytes;
begin
  Result := Compress(d, st).Ok and Decompress(st, back).Ok and Same(back, d);
end;

{ The same coefficients, or for a lossless JPEG the same samples (its
  coefficient arrays are empty) }
function SameCoefficients(const a, b: TJpeg): Boolean;
var c: Integer;
begin
  Result := Length(a.comp) = Length(b.comp);
  if not Result then Exit;
  for c := 0 to High(a.comp) do begin
    if (Length(a.comp[c].coef) <> Length(b.comp[c].coef)) or
       (Length(a.comp[c].samples) <> Length(b.comp[c].samples)) then Exit(False);
    if (Length(a.comp[c].coef) > 0) and
       not CompareMem(@a.comp[c].coef[0], @b.comp[c].coef[0], Length(a.comp[c].coef) * SizeOf(SmallInt)) then
      Exit(False);
    if (Length(a.comp[c].samples) > 0) and
       not CompareMem(@a.comp[c].samples[0], @b.comp[c].samples[0], Length(a.comp[c].samples) * SizeOf(Word)) then
      Exit(False);
  end;
end;

{ How many RSTs the scan itself has: one between each two restart intervals. }
function RstsInScan(const j: TJpeg; const s: TScan): Integer;
var units: SizeInt;
begin
  { lossless JPEG: an MCU a sample position }
  if j.lossless then units := SizeInt(j.width) * j.height
  else if s.ncomp = 1 then units := j.comp[s.comp[0]].bwReal * j.comp[s.comp[0]].bhReal
  else units := SizeInt(j.mcusx) * j.mcusy;
  if s.ri = 0 then Result := 0 else Result := Integer((units - 1) div s.ri);
end;

{ The JPEG with `extra` RSTs right after the entropy-coded data of its last
  scan, continuing the count. }
function WithTrailingRsts(const j: TJpeg; extra: Integer; out d: TBytes): Boolean;
var j2: TJpeg; cut: SizeInt; n, k: Integer; ins: TBytes;
begin
  j2 := j;
  j2.raw := Copy(j.raw, 0, Length(j.raw));
  j2.scans := Copy(j.scans, 0, Length(j.scans));
  cut := j2.scans[High(j2.scans)].cut;
  n := RstsInScan(j, j2.scans[High(j2.scans)]);
  ins := nil; SetLength(ins, 2 * extra);
  for k := 0 to extra - 1 do begin ins[2 * k] := $FF; ins[2 * k + 1] := $D0 + ((n + k) and 7); end;
  Insert(ins, j2.raw, cut);
  Result := Recompose(j2, d).Ok;
end;

{ The progressive JPEG with the largest EOBr symbol taken out of the DHT that
  the AC scan `scan` uses; re-encoded with the same coefficients. }
function WithShorterEobRuns(const j: TJpeg; scan: Integer; out d: TBytes; out rmax: Integer): Boolean;
var h: THuff; r, l, i, at, k, cnt: Integer; seg: TBytes; raw: TBytes; j2: TJpeg; p, segStart: SizeInt;
    found: Boolean; sym, pos: Integer;
begin
  Result := False; d := nil; rmax := -1;
  h := j.scans[scan].ac[0];
  for r := 14 downto 1 do if h.len[r shl 4] > 0 then begin rmax := r; Break; end;
  if rmax < 1 then Exit;
  if h.len[(rmax - 1) shl 4] = 0 then Exit;   { the run has to be cut into something it has }
  { the DHT segment of this table: the last one before the scan's SOS that
    holds these exact counts and values }
  raw := j.raw;
  seg := nil; SetLength(seg, 17 + h.nvalues);
  for l := 1 to 16 do seg[l] := h.counts[l];
  for i := 0 to h.nvalues - 1 do seg[17 + i] := h.values[i];
  found := False; at := -1;
  for p := 0 to j.scans[scan].cut - Length(seg) do begin
    if (raw[p] shr 4 <> 1) then Continue;
    if CompareMem(@raw[p + 1], @seg[1], Length(seg) - 1) then begin at := p; found := True; end;
  end;
  if not found then Exit;
  { the length field of the segment that holds it }
  segStart := -1;
  for p := at downto 3 do
    if (raw[p - 4] = $FF) and (raw[p - 3] = $C4) then begin segStart := p - 2; Break; end;
  if segStart < 0 then Exit;
  sym := rmax shl 4;
  pos := -1;
  for i := 0 to h.nvalues - 1 do if h.values[i] = sym then pos := i;
  if pos < 0 then Exit;
  raw := Copy(j.raw, 0, Length(j.raw));
  Dec(raw[at + h.len[sym]]);                       { one code fewer of that length }
  Delete(raw, at + 17 + pos, 1);                   { and the value }
  k := (raw[segStart] shl 8 or raw[segStart + 1]) - 1;
  raw[segStart] := Byte(k shr 8); raw[segStart + 1] := Byte(k and $FF);
  { the cuts after that point moved one byte back }
  if not ParseHeaders(raw, j2).Ok then Exit;
  for k := 0 to High(j2.comp) do j2.comp[k].coef := Copy(j.comp[k].coef, 0, Length(j.comp[k].coef));
  for k := 0 to High(j2.scans) do j2.scans[k].padbit := j.scans[k].padbit;
  Result := Recompose(j2, d).Ok;
  cnt := 0;
end;

var
  files: TStringList; sr: TSearchRec; f: string; d, t: TBytes; j, jt: TJpeg; extra, sc, rmax, nprog: Integer;
begin
  cells := 0; failures := 0; nprog := 0;
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(ParamStr(1) + '/*.jpg', faAnyFile, sr) = 0 then begin
    repeat files.Add(ParamStr(1) + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  for f in files do begin
    d := ReadFile(f);
    if not Decompose(d, j).Ok then Continue;
    for extra := 1 to 2 do begin
      Check(WithTrailingRsts(j, extra, t) and VerifyRoundTrip(t, jt).Ok and SameCoefficients(j, jt)
            and CodecRoundTrip(t), Format('%s + %d RST after the scan', [ExtractFileName(f), extra]));
    end;
    if j.progressive and not j.arithmetic then
      for sc := 0 to High(j.scans) do
        if (j.scans[sc].se > 0) and WithShorterEobRuns(j, sc, t, rmax) then begin
          Inc(nprog);
          Check(not Same(t, d) and VerifyRoundTrip(t, jt).Ok and SameCoefficients(j, jt) and CodecRoundTrip(t),
                Format('%s scan %d without EOB%d: runs cut, same coefficients', [ExtractFileName(f), sc, rmax]));
        end;
  end;
  Check(nprog >= 1, Format('%d progressive scans with shorter EOB runs tried', [nprog]));
  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 10) then Halt(1);
end.

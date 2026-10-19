{ Where the bits go: compresses every JPEG in the directory without verifying
  and prints the ideal cost of each kind of decision, in bytes and as a share
  of the input.

    bench_costs <directory> [max files]

  Build it with -dPJA_COSTS: the accounting is compiled out of the codec. }
program bench_costs;
{$I ../pja.inc}
{$ifndef PJA_COSTS}{$fatal bench_costs: compile with -dPJA_COSTS}{$endif}
uses SysUtils, Classes, Math, pjamodel, pjacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const NAMES: array[TCostKind] of string = ('raw', 'nz count', 'zero flags', 'exponents', 'mantissas', 'signs',
  'edge zero', 'edge exp', 'edge mant', 'edge sign', 'dc');
var files: TStringList; sr: TSearchRec; i, maxFiles: Integer; d, st: TBytes; sumIn, sumOut: Int64;
    k: TCostKind; total: Double;
begin
  files := TStringList.Create; files.Sorted := True;
  maxFiles := StrToIntDef(ParamStr(2), MaxInt);
  if FindFirst(ParamStr(1) + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(1) + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  CollectCosts := True; sumIn := 0; sumOut := 0;
  for i := 0 to files.Count - 1 do begin
    if i >= maxFiles then Break;
    d := ReadFile(files[i]);
    if Compress(d, st, False).Ok then begin Inc(sumIn, Length(d)); Inc(sumOut, Length(st)); end;
  end;
  total := 0;
  for k := Low(k) to High(k) do total := total + Costs[k] / 8;
  for k := Low(k) to High(k) do
    Writeln(Format('  %-12s %12.0f B  %6.2f%% of output  %6.2f%% of input', [NAMES[k], Costs[k] / 8,
      100 * Costs[k] / 8 / total, 100 * Costs[k] / 8 / sumIn]));
  Writeln(Format('  total: %d -> %d (%.3f%%)', [sumIn, sumOut, 100 * sumOut / sumIn]));
end.

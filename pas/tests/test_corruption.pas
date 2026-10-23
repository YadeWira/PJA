{ Corruption battery for .pja: valid files, systematically damaged.

  1. The format alone. It cannot detect everything: a bit in the payload is
     a different codec stream, and it is exposed by whoever decodes,
     comparing with the declared size and hash. What IS required is that no
     mutation reads THE SAME as the original: that would be a byte that means
     nothing.
  2. End to end (Unpack, with the codec), on the smaller files: every bit of
     the header and the descriptor, about 200 bits spread over the payload,
     about 50 truncations (each decode costs ~10 ms: all of them would take
     ten minutes). Required: nothing comes out as good unless it IS the
     original, byte for byte. The codec's own damage tests flip every bit
     of the first bytes of its streams and try every truncation
     (run_codec_tests.sh).

  The buckets have to add up to the cells: without that, a new class falls off
  the table and the printed number still looks reasonable.

    test_corruption <directory> [directory...]     (JPEG and JPEG-LS files) }
program test_corruption;
{$I ../pja.inc}
{$ifopt R-}{$fatal test_corruption: range checks ($R+) are mandatory}{$endif}
uses SysUtils, Classes, Math, pjablake3, pjaformat, pjapack;

const
  { end to end decodes every variant: only the files up to this size }
  E2E_MAX = 4096;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:64, '  ok') else begin Inc(failures); Writeln('  ', what:64, '  FAIL'); end; end;

function ReadAll(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;
function Same(const x, y: TBytes): Boolean;
begin Result := (Length(x) = Length(y)) and ((Length(x) = 0) or CompareMem(@x[0], @y[0], Length(x))); end;

type
  TTally = record
    cells, rejected, desc_differs, payload_differs, reads_same: Int64;
    errors: TStringList;    { which errors came out, and how many times }
  end;
  TE2E = record
    cells, rejected, exact, wrong: Int64;
    errors: TStringList;
  end;

var
  original: TPja;       { what is read from the healthy file }

procedure Note(errs: TStringList; e: string);
var i: Integer;
begin
  { FutureVersion(37) and FutureVersion(38) are the same bucket }
  if Pos('(', e) > 0 then e := Copy(e, 1, Pos('(', e) - 1);
  i := errs.IndexOf(e);
  if i < 0 then errs.AddObject(e, TObject(PtrInt(1)))
  else errs.Objects[i] := TObject(PtrInt(errs.Objects[i]) + 1);
end;

procedure Try1(var c: TTally; const data: TBytes);
var r: TPjaResult; p: TPja;
begin
  Inc(c.cells);
  r := Open(data, p);
  if not r.Ok then begin Inc(c.rejected); Note(c.errors, r.Text); Exit; end;
  { the stored flag is part of what a .pja says: off on a stored file, the
    same bytes read as a codec stream }
  if (p.orig_size <> original.orig_size) or (p.stored <> original.stored) or (p.ext <> original.ext) or
     not CompareMem(@p.hash, @original.hash, 16) then Inc(c.desc_differs)
  else if not Same(p.payload, original.payload) then Inc(c.payload_differs)
  else Inc(c.reads_same);
end;

{ Every bit, every value of the header and descriptor bytes, every
  truncation, and additions at the end. }
procedure Sweep(const fileData: TBytes; var c: TTally);
var i, b, v, fixed: SizeInt; x: TBytes;
begin
  { the header and the whole descriptor, its extension field included }
  fixed := Length(fileData) - Length(original.payload);
  x := Copy(fileData, 0, Length(fileData));
  for i := 0 to High(fileData) do
    for b := 0 to 7 do begin
      x[i] := fileData[i] xor (1 shl b); Try1(c, x); x[i] := fileData[i];
    end;
  for i := 0 to fixed - 1 do
    for v := 0 to 255 do
      if v <> fileData[i] then begin x[i] := v; Try1(c, x); x[i] := fileData[i]; end;
  for i := 0 to High(fileData) do Try1(c, Copy(fileData, 0, i));
  for i := 1 to 64 do Try1(c, Concat(fileData, Copy(fileData, 0, i)));
end;

procedure Try2(var c: TE2E; const data, want: TBytes);
var r: TPackResult; back: TBytes; h: THash16;
begin
  Inc(c.cells);
  try
    r := Unpack(data, High(QWord), back, h);
  except
    on e: Exception do begin Inc(c.wrong); Note(c.errors, 'EXCEPTION ' + e.ClassName); Exit; end;
  end;
  if not r.Ok then begin Inc(c.rejected); Note(c.errors, r.Text); Exit; end;
  if Same(back, want) then Inc(c.exact) else Inc(c.wrong);
end;

procedure Report(errs: TStringList);
var i: Integer;
begin
  for i := 0 to errs.Count - 1 do
    Writeln(Format('      %-34s %d', [errs[i], PtrInt(errs.Objects[i])]));
end;

var
  files: TStringList; sr: TSearchRec; f: string; d: Integer; i, b: SizeInt;
  orig, pja, x: TBytes; c: TTally; e: TE2E; e2eFiles: Integer;
begin
  cells := 0; failures := 0;
  files := TStringList.Create; files.Sorted := True;
  for d := 1 to ParamCount do
    if FindFirst(ParamStr(d) + '/*', faAnyFile, sr) = 0 then begin
      repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(d) + '/' + sr.Name); until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  c := Default(TTally); c.errors := TStringList.Create; c.errors.Sorted := True;
  e := Default(TE2E); e.errors := TStringList.Create; e.errors.Sorted := True;
  e2eFiles := 0;
  for f in files do begin
    orig := ReadAll(f);
    { with its extension, so that its field is swept too }
    if not Pack(orig, pja, 1, False, True, Copy(ExtractFileExt(f), 2, MaxInt)).Ok then begin
      Check(False, ExtractFileName(f) + ' packs'); Continue;
    end;
    Open(pja, original);
    Sweep(pja, c);
    if Length(pja) <= E2E_MAX then begin
      Inc(e2eFiles);
      x := Copy(pja, 0, Length(pja));
      i := 0;
      while i < Length(pja) * 8 do begin
        x[i div 8] := pja[i div 8] xor (1 shl (i mod 8)); Try2(e, x, orig); x[i div 8] := pja[i div 8];
        if i < (Length(pja) - Length(original.payload)) * 8 then Inc(i)
        else Inc(i, Max(1, Length(original.payload) * 8 div 200));
      end;
      i := 0;
      while i < Length(pja) do begin Try2(e, Copy(pja, 0, i), orig); Inc(i, Max(1, Length(pja) div 50)); end;
    end;
  end;

  Writeln(Format('  format: %d cells = %d rejected + %d different descriptor + %d different payload + %d same',
                 [c.cells, c.rejected, c.desc_differs, c.payload_differs, c.reads_same]));
  Report(c.errors);
  Check(c.rejected + c.desc_differs + c.payload_differs + c.reads_same = c.cells, 'the format buckets add up');
  Check(c.reads_same = 0, 'no mutation reads the same as the original');
  Check(c.cells >= 100000, Format('at least 100,000 format cells (%d)', [c.cells]));

  Writeln(Format('  end to end, %d files: %d cells = %d rejected + %d the original + %d anything else',
                 [e2eFiles, e.cells, e.rejected, e.exact, e.wrong]));
  Report(e.errors);
  Check(e.rejected + e.exact + e.wrong = e.cells, 'the end-to-end buckets add up');
  Check(e.wrong = 0, 'nothing but the original comes out as good, and no exception');
  Check(e.cells >= 3000, Format('at least 3,000 end-to-end cells (%d)', [e.cells]));

  files.Free;
  Writeln(cells, ' cells, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.

{ The .pja format: round trip with real files, each header and descriptor
  error with ITS name, and the writer and the reader accepting and rejecting
  exactly the same.

    test_format <directory> [directory...]     (JPEG and JPEG-LS files) }
program test_format;
{$I ../pja.inc}
uses SysUtils, Classes, pjalimits, pjablake3, pjaformat, pjapack;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:62, '  ok') else begin Inc(failures); Writeln('  ', what:62, '  FAIL'); end; end;
procedure CheckR(const r: TPjaResult; const expected, what: string);
begin
  Inc(cells);
  if r.Text = expected then Writeln('  ', what:62, '  ok')
  else begin Inc(failures); Writeln('  ', what:62, '  FAIL: gave ', r.Text, ', expected ', expected); end;
end;

function Same(const x, y: TBytes): Boolean;
begin Result := (Length(x) = Length(y)) and ((Length(x) = 0) or CompareMem(@x[0], @y[0], Length(x))); end;
function ReadAll(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;
function Filled(n: SizeInt; v: Byte): TBytes;
begin Result := nil; SetLength(Result, n); if n > 0 then FillChar(Result[0], n, v); end;
function WithByte(const x: TBytes; i: SizeInt; v: Byte): TBytes;
begin Result := Copy(x, 0, Length(x)); Result[i] := v; end;

{ A .pja built by hand, without going through the writer: so the reader sees
  descriptors the writer refuses to produce. }
function ByHand(origSize: QWord; const hash: THash16; const payload: TBytes): TBytes;
var k: Integer;
begin
  Result := nil; SetLength(Result, HEADER_SIZE + DESCRIPTOR_SIZE + Length(payload));
  for k := 0 to 3 do Result[k] := MAGIC[k];
  Result[4] := VERSION;
  for k := 0 to 7 do Result[8 + k] := Byte((origSize shr (8 * k)) and $FF);
  Move(hash[0], Result[16], 16);
  if Length(payload) > 0 then Move(payload[0], Result[32], Length(payload));
end;

var
  files: TStringList; sr: TSearchRec; f: string; d: Integer;
  orig, b, other, back: TBytes; h, h2, hx: THash16; p: TPja; r, rw: TPjaResult; pr: TPackResult;
  i, n, k, symmetric: Integer;
  cases: array of record orig_size: QWord; len: SizeInt; expected: string; end;
begin
  cells := 0; failures := 0;
  files := TStringList.Create; files.Sorted := True;
  for d := 1 to ParamCount do
    if FindFirst(ParamStr(d) + '/*', faAnyFile, sr) = 0 then begin
      repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(d) + '/' + sr.Name); until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  Check(files.Count >= 10, Format('corpus: %d files', [files.Count]));

  Writeln('--- round trip through Pack and Unpack, with each file');
  for f in files do begin
    orig := ReadAll(f);
    pr := Pack(orig, b);
    Check(pr.Ok, ExtractFileName(f) + ': Pack ' + pr.Text);
    if not pr.Ok then Continue;
    r := Open(b, p); h := Blake3_128(orig);
    Check(r.Ok and (p.orig_size = QWord(Length(orig))) and CompareMem(@p.hash, @h, 16)
       and (Length(b) = WrittenLength(Length(p.payload))), '  opens: orig_size, hash, length');
    pr := Unpack(b, High(QWord), back, hx);
    Check(pr.Ok and Same(back, orig), '  Unpack gives the original byte for byte');
  end;
  orig := ReadAll(files[0]); Pack(orig, b); Open(b, p); h := p.hash;

  Writeln('--- Unpack: the caller''s cap and what does not verify');
  pr := Unpack(b, Length(orig) - 1, back, hx);
  Check((pr.err = ukTooLarge) and (Length(back) = 0), 'a cap one byte below the original: TooLarge, nothing');
  pr := Unpack(b, Length(orig), back, hx);
  Check(pr.Ok, 'a cap equal to the original: fine');
  other := WithByte(b, 16, b[16] xor 1);
  pr := Unpack(other, High(QWord), back, hx);
  Check((pr.err = ukHashMismatch) and Same(back, orig) and (hx[0] = b[16] xor 1),
     'one bit of the hash: HashMismatch, with the decoded and the expected');
  other := Copy(b, 0, Length(b)); other[8] := other[8] xor 1;
  pr := Unpack(other, High(QWord), back, hx);
  Check((not pr.Ok) and (Length(back) = 0), 'orig_size one off: ' + pr.Text + ', nothing');

  Writeln('--- header: each error with its name');
  for n := 0 to HEADER_SIZE - 1 do
    CheckR(Open(Copy(b, 0, n), p), 'ShortFile', Format('%d bytes', [n]));
  CheckR(Open(Copy(b, 0, HEADER_SIZE + DESCRIPTOR_SIZE - 1), p), 'ShortFile', 'header and 23 bytes of descriptor');
  CheckR(Open(WithByte(b, 0, Ord('X')), p), 'NotPja', 'magic: first byte');
  CheckR(Open(WithByte(b, 3, $02), p), 'NotPja', 'magic: the trailing $01');
  CheckR(Open(WithByte(b, 4, 4), p), 'FutureVersion(4)', 'version 4');
  CheckR(Open(WithByte(b, 4, 255), p), 'FutureVersion(255)', 'version 255');
  CheckR(Open(WithByte(b, 4, 2), p), 'OldVersion(2)', 'version 2 (the encrypted wrapper of .pjg)');
  CheckR(Open(WithByte(b, 4, 1), p), 'OldVersion(1)', 'version 1 (the dropped container)');
  CheckR(Open(WithByte(b, 4, 0), p), 'OldVersion(0)', 'version 0');
  for k := 0 to 7 do
    CheckR(Open(WithByte(b, 5, 1 shl k), p), 'UnknownFlag', Format('flag bit %d', [k]));
  CheckR(Open(WithByte(b, 6, 1), p), 'ReservedNotZero', 'reserved byte 6');
  CheckR(Open(WithByte(b, 7, $80), p), 'ReservedNotZero', 'reserved byte 7');
  CheckR(Open(Filled(200, $41), p), 'NotPja', 'garbage 0x41');
  CheckR(Open(Filled(200, 0), p), 'NotPja', 'zeros');

  Writeln('--- descriptor: the edges, in the writer AND in the reader');
  { Each case is asked of the writer and built by hand for the reader: they
    must give the SAME verdict. It is the rule the previous container broke. }
  SetLength(cases, 12);
  cases[0].orig_size := 0;     cases[0].len := 100; cases[0].expected := 'BadOrigSize';
  cases[1].orig_size := 1;     cases[1].len := 100; cases[1].expected := 'None';
  cases[2].orig_size := 100 * MAX_EXPANSION_RATIO;     cases[2].len := 100; cases[2].expected := 'None';
  cases[3].orig_size := 100 * MAX_EXPANSION_RATIO + 1; cases[3].len := 100; cases[3].expected := 'RatioExceeded';
  cases[4].orig_size := 100;   cases[4].len := MIN_PAYLOAD - 1; cases[4].expected := 'PayloadOutOfRange';
  cases[5].orig_size := 100;   cases[5].len := MIN_PAYLOAD; cases[5].expected := 'None';
  cases[6].orig_size := 0;     cases[6].len := 0; cases[6].expected := 'PayloadOutOfRange';
  cases[7].orig_size := MIN_PAYLOAD * MAX_EXPANSION_RATIO;     cases[7].len := MIN_PAYLOAD; cases[7].expected := 'None';
  cases[8].orig_size := MIN_PAYLOAD * MAX_EXPANSION_RATIO + 1; cases[8].len := MIN_PAYLOAD; cases[8].expected := 'RatioExceeded';
  cases[9].orig_size := QWord(High(Int64));     cases[9].len := 100;  cases[9].expected := 'RatioExceeded';
  cases[10].orig_size := QWord(High(Int64)) + 1; cases[10].len := 100; cases[10].expected := 'BadOrigSize';
  cases[11].orig_size := High(QWord);           cases[11].len := 100; cases[11].expected := 'BadOrigSize';
  symmetric := 0;
  for i := 0 to High(cases) do begin
    other := Filled(cases[i].len, $AB);
    rw := WritePja(other, h, cases[i].orig_size, b);
    r := Open(ByHand(cases[i].orig_size, h, other), p);
    CheckR(rw, cases[i].expected, Format('write orig_size %u, payload %d', [cases[i].orig_size, cases[i].len]));
    CheckR(r, cases[i].expected, '  and the reader, the same');
    if rw.Text = r.Text then Inc(symmetric);
    if not rw.Ok then Check(Length(b) = 0, '  and the writer hands out nothing');
    if not r.Ok then Check((p.orig_size = 0) and (Length(p.payload) = 0), '  and the reader leaves nothing read');
  end;
  Check(symmetric = Length(cases), Format('writer and reader agree on %d of %d', [symmetric, Length(cases)]));

  Writeln('--- the hash is just data');
  { The format recomputes nothing over the payload: the hash is of the
    original, and whoever decodes checks it. Any value is stored and comes
    back. }
  FillChar(h2, SizeOf(h2), $FF);
  WritePja(Filled(100, 1), h2, 1000, b);
  r := Open(b, p);
  Check(r.Ok and CompareMem(@p.hash, @h2, 16), 'an all-0xFF hash comes back the same');

  Writeln('--- WrittenLength');
  Check(WrittenLength(0) = HEADER_SIZE + DESCRIPTOR_SIZE, 'payload 0');
  Check(WrittenLength(1000) = HEADER_SIZE + DESCRIPTOR_SIZE + 1000, 'payload 1000');
  Check(WrittenLength(-1) = -1, 'negative length');
  Check(WrittenLength(High(SizeInt)) = -1, 'a length that does not fit');

  files.Free;
  Writeln; Writeln(cells, ' cells, ', failures, ' failures');
  if cells < 100 then begin Writeln('FAIL: expected at least 100 cells'); Halt(2); end;
  if failures > 0 then Halt(1);
end.

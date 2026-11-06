{ What a later release may write, read by this one: refused as
  FutureVersion, never read as something else (doc/STABILITY.md).

  - every codec stream of the samples (versions 5, 6, 7 and 8, PATCH among
    them) with its first byte set to each value from 9 to 255, and
    hand-made ones (that byte alone, with a zero, with 999 bytes after it):
    FutureVersion; set to 0 to 4: BadStream; to anything: no exception;
  - a PATCH stream whose repaired file's stream starts with 9 to 255:
    FutureVersion; a PATCH stream around a version 8 stream (never
    written: version 8 is a whole file): BadStream;
  - a version 6 stream with parts whose first part's stream starts with 9
    to 255: FutureVersion, not BadStream;
  - a version 8 stream with a flag set, or a codestream of a mode this
    release does not know (5 to 255): FutureVersion; a codestream of mode 1
    (modelled, pjaj2km), 2 (the pixels, pjaj2kpx), 3 (HTJ2K, pjaj2km) or 4
    (HTJ2K's pixels, pjaj2kpx) whose stream's layout byte is 1 to 255:
    FutureVersion; and modes 1 and 3 read by a program without pjaj2km,
    modes 2 and 4 by one without pjaj2kpx (the zpaq-std plugin: pjacodec's
    hooks nil): FutureVersion;
  - a .pja whose codec stream starts with 9 to 255: Unpack gives
    Codec(FutureVersion); a .pja of version 5 to 255: Format(FutureVersion).

    test_versions <directory>... }
program test_versions;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjacodec, pjapack, pjaformat, pjablake3, pjav7, pjaj2km, pjaj2kpx;

const
  J2K_ENTRY = 13;
  PART_ENTRY = 13;
  FLAG_QUIRKS = 1;
  FLAG_BYTES = 2;
  FLAG_CORRECTION = 4;
  FLAG_PATCH = 8;

var cells, failures: Integer;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(cells);
  if not ok then begin Inc(failures); Writeln('  FAIL ', what); end;
end;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

function GetU32(const d: TBytes; p: Integer): Cardinal;
begin
  Result := Cardinal(d[p]) or (Cardinal(d[p + 1]) shl 8) or (Cardinal(d[p + 2]) shl 16) or (Cardinal(d[p + 3]) shl 24);
end;

{ the stream decoded: its error, ceTooLarge standing for an exception }
function Verdict(const s: TBytes; out raised: Boolean): TCodecError;
var back: TBytes;
begin
  raised := False;
  try
    Result := Decompress(s, back, 1 shl 24).err;
  except
    raised := True; Result := ceTooLarge;
  end;
end;

{ every value of byte at of s: 9 to 255 FutureVersion, and none raises }
procedure Sweep(const s: TBytes; at: Integer; const name: string; first: Integer);
var m: TBytes; b: Integer; e: TCodecError; raised: Boolean;
begin
  for b := 0 to 255 do begin
    m := Copy(s, 0, Length(s));
    m[at] := b;
    e := Verdict(m, raised);
    Check(not raised, Format('%s: byte %d = %d raised', [name, at, b]));
    if b >= first then Check(e = ceFutureVersion, Format('%s: byte %d = %d gives %d', [name, at, b, Ord(e)]));
    if (at = 0) and (b <= 4) then Check(e = ceBadStream, Format('%s: version %d is not BadStream', [name, b]));
  end;
end;

var
  files: TStringList; sr: TSearchRec; i, d, b, k, p, e: Integer; data, st, pja, m, back: TBytes;
  r: TCodecResult; pr: TPackResult; h: THash16; seen: array[0..8] of Integer; patch, v8, inparts: Integer;
  mode1, mode2, mode3, mode4: Integer; enc1: TJ2kMode1Enc; enc2: TJ2kMode2Enc; dec1: TJ2kMode1Dec;
  raised: Boolean; name: string; pjas: Integer;
begin
  files := TStringList.Create; files.Sorted := True;
  for d := 1 to ParamCount do
    if FindFirst(ParamStr(d) + '/*', faAnyFile, sr) = 0 then begin
      repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(d) + '/' + sr.Name); until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  cells := 0; failures := 0; patch := 0; v8 := 0; pjas := 0; inparts := 0; mode1 := 0; mode2 := 0; mode3 := 0; mode4 := 0;
  FillChar(seen, SizeOf(seen), 0);
  { hand-made }
  RandSeed := 8;
  for b := 9 to 255 do begin
    m := nil; SetLength(m, 1); m[0] := b;
    Check(Verdict(m, raised) = ceFutureVersion, Format('[%d] alone', [b]));
    SetLength(m, 2); m[1] := 0;
    Check(Verdict(m, raised) = ceFutureVersion, Format('[%d 0]', [b]));
    SetLength(m, 1000);
    for k := 1 to 999 do m[k] := Random(256);
    Check(Verdict(m, raised) = ceFutureVersion, Format('[%d + 999 bytes]', [b]));
  end;
  for i := 0 to files.Count - 1 do begin
    data := ReadFile(files[i]); name := ExtractFileName(files[i]);
    { version 7's model (the command's) and version 5's }
    for k := 0 to 1 do begin
      r := Compress(data, st, True, 1, False, True, k = 0);
      if not r.Ok then Continue;
      if st[0] <= High(seen) then Inc(seen[st[0]]);
      Sweep(st, 0, name, 9);
      if (st[0] = STREAM_PARTS) and (st[1] = 8) then begin
        { PATCH: the edits, then the repaired file's stream }
        e := Integer(GetU32(st, 2)); p := 6;
        while e > 0 do begin p := p + 12 + Integer(GetU32(st, p + 8)); Dec(e); end;
        Sweep(st, p, name + ' (PATCH)', 9);
        Inc(patch);
      end;
      if (st[0] = STREAM_PARTS) and (st[1] and (FLAG_PATCH or FLAG_BYTES) = 0) then begin
        { parts: the table, the quirks' and corrections' scans, then the
          first part's stream (the first part is never a copy) }
        e := Integer(GetU32(st, 2)); p := 6 + PART_ENTRY * e;
        if st[1] and FLAG_QUIRKS <> 0 then p := p + 4 + 4 * Integer(GetU32(st, p));
        if st[1] and FLAG_CORRECTION <> 0 then p := p + 4 + 8 * Integer(GetU32(st, p));
        if e > 0 then begin
          Sweep(st, p, name + ' (part)', 9);
          Inc(inparts);
        end;
      end;
      if st[0] = STREAM_J2K then begin
        { the flags, then each codestream's mode }
        Sweep(st, 1, name + ' (flags)', 1);
        p := 6 + J2K_ENTRY * Integer(GetU32(st, 2));
        for e := 0 to Integer(GetU32(st, 2)) - 1 do begin
          Sweep(st, 6 + J2K_ENTRY * e + 12, name + ' (mode)', 5);
          if st[6 + J2K_ENTRY * e + 12] = 4 then begin
            { mode 4: its stream's layout byte, and a program without mode 4 }
            Sweep(st, p, name + ' (mode 4 layout)', 1);
            enc2 := J2kMode4Enc; dec1 := J2kMode4Dec;
            J2kMode4Enc := nil; J2kMode4Dec := nil;
            Check(Verdict(st, raised) = ceFutureVersion, name + ': mode 4 without pjaj2kpx is not FutureVersion');
            J2kMode4Enc := enc2; J2kMode4Dec := dec1;
            Inc(mode4);
          end;
          if st[6 + J2K_ENTRY * e + 12] = 2 then begin
            { mode 2: its stream's layout byte, and a program without mode 2 }
            Sweep(st, p, name + ' (mode 2 layout)', 1);
            enc2 := J2kMode2Enc; dec1 := J2kMode2Dec;
            J2kMode2Enc := nil; J2kMode2Dec := nil;
            Check(Verdict(st, raised) = ceFutureVersion, name + ': mode 2 without pjaj2kpx is not FutureVersion');
            J2kMode2Enc := enc2; J2kMode2Dec := dec1;
            Inc(mode2);
          end;
          if st[6 + J2K_ENTRY * e + 12] = 3 then begin
            { mode 3: its stream's layout byte, and a program without mode 3 }
            Sweep(st, p, name + ' (mode 3 layout)', 1);
            enc1 := J2kMode3Enc; dec1 := J2kMode3Dec;
            J2kMode3Enc := nil; J2kMode3Dec := nil;
            Check(Verdict(st, raised) = ceFutureVersion, name + ': mode 3 without pjaj2km is not FutureVersion');
            J2kMode3Enc := enc1; J2kMode3Dec := dec1;
            Inc(mode3);
          end;
          if st[6 + J2K_ENTRY * e + 12] = 1 then begin
            { mode 1: its stream's layout byte, and a program without mode 1 }
            Sweep(st, p, name + ' (mode 1 layout)', 1);
            enc1 := J2kMode1Enc; dec1 := J2kMode1Dec;
            J2kMode1Enc := nil; J2kMode1Dec := nil;
            Check(Verdict(st, raised) = ceFutureVersion, name + ': mode 1 without pjaj2km is not FutureVersion');
            J2kMode1Enc := enc1; J2kMode1Dec := dec1;
            Inc(mode1);
          end;
          p := p + Integer(GetU32(st, 6 + J2K_ENTRY * e + 8));
        end;
        { as a PATCH's repaired file (one edit, none or one byte put in
          front): never written, refused }
        for e := 0 to 1 do begin
          m := nil; SetLength(m, 6 + 12 + e);
          m[0] := STREAM_PARTS; m[1] := FLAG_PATCH; m[2] := 1;
          if e = 1 then begin m[14] := 1; m[18] := Ord('Z'); end;
          SetLength(m, Length(m) + Length(st));
          Move(st[0], m[Length(m) - Length(st)], Length(st));
          Check(Verdict(m, raised) = ceBadStream, Format('%s: version 8 inside PATCH (%d)', [name, e]));
          Check(not raised, name + ': version 8 inside PATCH raised');
        end;
        Inc(v8);
      end;
      { in a .pja, written as the command writes it }
      if k = 1 then Continue;
      pr := Pack(data, pja, 1, False, True, 'x', True);
      if not pr.Ok or (pja[5] and FLAG_STORED <> 0) then Continue;
      p := Length(pja) - Length(st);
      for b := 9 to 255 do begin
        m := Copy(pja, 0, Length(pja)); m[p] := b;
        pr := Unpack(m, QWord(1) shl 30, back, h);
        Check((pr.err = ukCodec) and (pr.codec.err = ceFutureVersion), Format('%s.pja: codec %d gives %s', [name, b, pr.Text]));
      end;
      for b := 5 to 255 do begin
        m := Copy(pja, 0, Length(pja)); m[4] := b;
        pr := Unpack(m, QWord(1) shl 30, back, h);
        Check((pr.err = ukFormat) and (pr.fmt.err = peFutureVersion), Format('%s.pja: version %d gives %s', [name, b, pr.Text]));
      end;
      Inc(pjas);
    end;
  end;
  Writeln(Format('  streams by version: 5: %d, 6: %d, 7: %d, 8: %d (codestreams of mode 1: %d, of mode 2: %d, of mode 3: %d, of mode 4: %d); PATCH %d, with parts %d, .pja %d',
                 [seen[5], seen[6], seen[7], seen[8], mode1, mode2, mode3, mode4, patch, inparts, pjas]));
  { each kind met, so that none of the sweeps above ran empty }
  Check((seen[5] > 0) and (seen[6] > 0) and (seen[7] > 0) and (seen[8] > 0) and (patch > 0) and (inparts > 0) and (v8 > 0) and (mode1 > 0) and (mode2 > 0) and (mode3 > 0) and (mode4 > 0) and (pjas > 0),
        'every kind of stream among the samples');
  Writeln(files.Count, ' files, ', cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 10000) then Halt(1);
end.

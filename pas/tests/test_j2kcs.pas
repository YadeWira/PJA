{ JPEG 2000 stage B: every codestream of the files given taken apart
  (pjaj2kcs.J2kAnalyze) and put back together from the side information
  and the decisions alone (J2kRebuild, which never sees the original), and
  compared byte for byte. J2kAnalyze checks it too before it says yes; this
  does it again on a copy of the blob, after the analysis is gone.

    test_j2kcs [-q] [-min N] [-fuzz N] [-side prefix] [-mode1] [-mode2] [-dumpcb file] [-l list] <file or directory>...

  A directory is walked (files of the JPEG 2000 family by their first
  bytes; the rest ignored); -l takes the names from a file, one a line.
  Prints a line per codestream (-q: only those refused and failures), then the totals: the
  codestreams rebuilt, those refused by reason, the failures (a rebuild that
  is not the codestream, or an exception: there must be none), the side
  information's size by stream, the rules' counts, and the speed (MB of
  codestream a second, analysis with its check and the rebuild). Exit code
  1 when anything failed.

  -min N: fails unless at least N codestreams come back. The last line
  but one gives a digest (FNV-1a, 64 bits) of all the blobs, in order: the
  same on every platform.

  -mode1: each codestream taken also as stream version 8's mode 1
  (pjaj2km), decoded and compared: its size and its side information's
  (a line MODE1 file #i length stream side encode-s decode-s), the totals;
  -threads N: its slices on N threads.

  -mode2: each codestream taken also as stream version 8's mode 2
  (pjaj2kpx, the pixels) when it can be, decoded and compared: a line
  MODE2 file #i length stream side encode-s decode-s, or MODE2REFUSED
  file #i why; the totals, those refused by reason, and (with -mode1)
  what each codestream would be given as by the choice of pjacodec (mode
  2 if it is smaller than the codestream, mode 1 if that is smaller still
  and mode 2 did not take it to half its bytes, else mode 0); with
  -m2fuzz N, N damaged copies of each mode 2 stream decoded (an error or
  the codestream, never an exception), and N / 4 damaged copies of its
  codestream taken as mode 2 (refused, or a stream that gives them back).

  -dumpcb file: what stream version 8's model is given for each codestream
  taken (pjaj2kcs's kmDump), to tune the model outside PJA.

  -side prefix: each stream of the side information of the codestreams
  taken, appended to prefix.<stream> (to measure what a general compressor
  makes of them).

  -fuzz N: besides, N damaged copies of each codestream (bits flipped
  anywhere or in its first 512 bytes, bytes set to FF or 00, cut short),
  each analysed: refused, or taken and given back byte for byte, never an
  exception; and N damaged copies of each blob rebuilt: refused or a
  codestream, never an exception (the C side is given only what the Pascal
  side checked). }
program test_j2kcs;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, DateUtils, Math, pjaarith, pjamodel, pjaj2k, pjaj2kcs, pjaj2km,
  pjaj2kpx;

var
  quiet: Boolean;
  fuzz, minOk: Integer;
  digest: QWord = QWord($CBF29CE484222325);
  sidePrefix: string;
  dumpS: TFileStream;
  mode1, mode2: Boolean;
  m2Fuzz: Integer;
  m2Digest: QWord;
  m2Cs, m2Bytes, m2Side, m2Fail, m2Ref, m2FzRuns, m2FzOk, m2FzCs, m2FzCsOk, m2Caps: Int64; tM2e, tM2d: Double;
  m2Reasons: TStringList;
  { the choice: per codestream, the smallest of the codestream, mode 1's and mode 2's streams }
  chCs, chBytes, chM0, chM1, chM2, chM1Bytes, chBestCs: Int64;
  lastM1: Int64;
  m1Threads: Integer = 1;
  m1Digest: QWord;
  m1Cs, m1Bytes, m1Side, m1Fail: Int64; tM1e, tM1d: Double;
  rnd: QWord = 88172645463325252;
  fzRuns, fzOk, fzFail, fzBlob, fzBlobOk: Int64;
  st: TJ2kStats;
  nfiles, ncs, nok, nfail: Int64;
  bytesCs, bytesOk, bytesSide, bytesDec: Int64;
  tAn, tRb: Double;
  reasons: TStringList;

function ReadFile(const f: string; out d: TBytes): Boolean;
var s: TFileStream;
begin
  d := nil; Result := False;
  try
    s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      SetLength(d, s.Size);
      if s.Size > 0 then s.ReadBuffer(d[0], s.Size);
      Result := True;
    finally s.Free; end;
  except
    Result := False;
  end;
end;

procedure Count(const why: string);
var i: Integer; key: string;
begin
  key := why;
  if Pos('verify: ', key) = 1 then key := 'verify'
  else if Pos('exception', key) = 1 then key := Copy(key, 1, 60);
  i := reasons.IndexOf(key);
  if i < 0 then reasons.AddObject(key, TObject(PtrInt(1)))
  else reasons.Objects[i] := TObject(PtrInt(reasons.Objects[i]) + 1);
end;

function Rand(n: QWord): QWord;
begin
  rnd := rnd xor (rnd shl 13); rnd := rnd xor (rnd shr 7); rnd := rnd xor (rnd shl 17);
  Result := rnd mod n;
end;

{ k damaged copies of d[off..off+len) analysed, and of its blob rebuilt }
procedure FuzzOne(const d: TBytes; off, len: Int64; const blob: TBytes; const f: string; ci: Integer);
var k, j, n, kind: Integer; m, b2, back: TBytes; why: string; s: TJ2kStats; p: QWord;
begin
  for k := 1 to fuzz do begin
    m := Copy(d, off, len);
    if len = 0 then Break;
    kind := Rand(5);
    n := 1 + Rand(4);
    case kind of
      0: for j := 1 to n do begin p := Rand(len); m[p] := m[p] xor (1 shl Rand(8)); end;
      1: for j := 1 to n do begin p := Rand(Min(len, 512)); m[p] := m[p] xor (1 shl Rand(8)); end;
      2: for j := 1 to n do begin p := Rand(len); if Rand(2) = 0 then m[p] := $FF else m[p] := 0; end;
      3: SetLength(m, Rand(len));
      else begin p := Rand(Min(len, 512)); m[p] := Rand(256); SetLength(m, len - Rand(Min(len, 64))); end;
    end;
    Inc(fzRuns);
    s := Default(TJ2kStats);
    try
      if J2kAnalyze(m, 0, Length(m), b2, why, s) then Inc(fzOk)
      else if (Pos('verify', why) = 1) or (Pos('exception', why) = 1) or (Pos('internal', why) = 1) then begin
        Inc(fzFail);
        Writeln('FUZZ FAIL ', f, ' #', ci, ' variant ', k, ' kind ', kind, ': ', why);
      end;
    except
      on E: Exception do begin Inc(fzFail); Writeln('FUZZ FAIL ', f, ' #', ci, ' variant ', k, ': ', E.ClassName, ' ', E.Message); end;
    end;
  end;
  if Length(blob) = 0 then Exit;
  for k := 1 to fuzz do begin
    b2 := Copy(blob);
    n := 1 + Rand(4);
    if Rand(4) = 0 then SetLength(b2, Rand(Length(b2)))
    else for j := 1 to n do begin p := Rand(Length(b2)); b2[p] := b2[p] xor (1 shl Rand(8)); end;
    Inc(fzBlob);
    try
      if J2kRebuildWhy(b2, back, why) then Inc(fzBlobOk)
      else if Pos('exception', why) = 1 then begin
        Inc(fzFail); Writeln('FUZZ FAIL blob ', f, ' #', ci, ' variant ', k, ': ', why);
      end;
    except
      on E: Exception do begin Inc(fzFail); Writeln('FUZZ FAIL blob ', f, ' #', ci, ' variant ', k, ': ', E.ClassName, ' ', E.Message); end;
    end;
  end;
end;

{ FNV-1a: wraps around, by design }
{$push}{$Q-}{$R-}
procedure AddDigest(const b: TBytes);
var k: SizeInt;
begin
  for k := 0 to High(b) do digest := (digest xor b[k]) * QWord($100000001B3);
end;
{$pop}

{ the blob's streams appended to sidePrefix.<name> }
procedure SaveSide(const blob: TBytes);
var p: SizeInt; i, sh: Integer; n: array[0..J2K_NSTREAMS - 1] of Int64; v: QWord; b: Byte; fs: TFileStream;
  name: string;
begin
  p := 1;
  for i := 0 to J2K_NSTREAMS - 1 do begin
    v := 0; sh := 0;
    repeat b := blob[p]; Inc(p); v := v or (QWord(b and 127) shl sh); Inc(sh, 7); until b < 128;
    n[i] := v;
  end;
  for i := 0 to J2K_NSTREAMS - 1 do begin
    name := sidePrefix + '.' + J2kStreamName(i);
    if FileExists(name) then fs := TFileStream.Create(name, fmOpenReadWrite) else fs := TFileStream.Create(name, fmCreate);
    try
      fs.Seek(0, soEnd);
      if n[i] > 0 then fs.WriteBuffer(blob[p], n[i]);
    finally fs.Free; end;
    p := p + n[i];
  end;
end;

{$push}{$Q-}{$R-}
function Fnv(const b: TBytes): QWord;
var k: SizeInt;
begin
  Result := QWord($CBF29CE484222325);
  for k := 0 to High(b) do Result := (Result xor b[k]) * QWord($100000001B3);
end;
{$pop}

{ -mode1: the codestream as stream version 8's mode 1 (pjaj2km), decoded
  again and compared; its size, its side information's, the time each way }
var m1WrongDone: Boolean;

{ the stream decoded for a length it is not: an error, never m1Ok nor an
  exception, on 32-bit too (lengths past what SizeInt holds) }
function Mode1WrongLengths(const m: TBytes; len: Int64): Boolean;
const L: array[0..5] of Int64 = (536854528, 540000000, 1000000000, 1800000000, 3000000000, 5000000000);
var i: Integer; r: TMode1Result; back: TBytes;
begin
  Result := True;
  for i := 0 to High(L) do
    try
      r := J2kMode1Decode(m, L[i], m1Threads, back);
      if r = m1Ok then begin Writeln('MODE1 FAIL: taken for ', L[i], ' bytes'); Result := False; end;
    except
      on E: Exception do begin
        Writeln('MODE1 FAIL: for ', L[i], ' bytes: ', E.ClassName, ': ', E.Message); Result := False;
      end;
    end;
  r := J2kMode1Decode(m, len + 1, m1Threads, back);
  if r = m1Ok then begin Writeln('MODE1 FAIL: taken for len + 1'); Result := False; end;
end;

procedure Mode1One(const d: TBytes; off, len: Int64; const f: string; ci: Integer);
var m, back: TBytes; why: string; t0: TDateTime; r: TMode1Result; side: Int64; te, td: Double;
begin
  lastM1 := -1;
  t0 := Now;
  r := J2kMode1Encode(d, off, len, m1Threads, m, why);
  te := MilliSecondsBetween(Now, t0) / 1000;
  if r <> m1Ok then begin Inc(m1Fail); Writeln('MODE1 FAIL ', f, ' #', ci, ': ', why); Exit; end;
  lastM1 := Length(m);
  t0 := Now;
  r := J2kMode1Decode(m, len, m1Threads, back);
  td := MilliSecondsBetween(Now, t0) / 1000;
  if (r <> m1Ok) or (Length(back) <> len) or not CompareMem(@back[0], @d[off], len) then begin
    Inc(m1Fail); Writeln('MODE1 FAIL ', f, ' #', ci, ': decode'); Exit;
  end;
  if not m1WrongDone then begin
    m1WrongDone := True;
    if not Mode1WrongLengths(m, len) then begin Inc(m1Fail); Exit; end;
  end;
  side := Int64(m[9 + 4 * Int64(m[5])]) or (Int64(m[10 + 4 * Int64(m[5])]) shl 8) or
    (Int64(m[11 + 4 * Int64(m[5])]) shl 16) or (Int64(m[12 + 4 * Int64(m[5])]) shl 24);
  m1Digest := m1Digest xor Fnv(m);
  m1Cs := m1Cs + len; m1Bytes := m1Bytes + Length(m); m1Side := m1Side + side;
  tM1e := tM1e + te; tM1d := tM1d + td;
  Writeln('MODE1 ', ExtractFileName(f), ' #', ci, ' ', len, ' ', Length(m), ' ', side, ' ',
    FormatFloat('0.000', te), ' ', FormatFloat('0.000', td));
end;

procedure Count2(const why: string);
var i: Integer; key: string;
begin
  key := why;
  if Pos('pixels: ', key) = 1 then key := Copy(key, 9, 60);
  i := m2Reasons.IndexOf(key);
  if i < 0 then m2Reasons.AddObject(key, TObject(PtrInt(1)))
  else m2Reasons.Objects[i] := TObject(PtrInt(m2Reasons.Objects[i]) + 1);
end;

{ -m2fuzz: damaged copies of a mode 2 stream decoded: an error or the
  codestream, never an exception; and damaged copies of its codestream
  (one in four) taken as mode 2: refused, or a stream that gives them back
  (J2kMode2Encode decodes and compares), never an exception nor a stream
  that does not come back (verify) }
procedure Mode2Fuzz(const m: TBytes; len: Int64; const f: string; ci: Integer; const d: TBytes; off: Int64);
var k, j, n: Integer; b2, back, cs2: TBytes; p: QWord; r: TMode2Result; why: string;
begin
  for k := 1 to m2Fuzz div 4 do begin
    cs2 := Copy(d, off, len);
    n := 1 + Rand(4);
    case Rand(5) of
      0: for j := 1 to n do begin p := Rand(len); cs2[p] := cs2[p] xor (1 shl Rand(8)); end;
      1: for j := 1 to n do begin p := Rand(Min(len, 512)); cs2[p] := cs2[p] xor (1 shl Rand(8)); end;
      2: for j := 1 to n do begin p := Rand(len); if Rand(2) = 0 then cs2[p] := $FF else cs2[p] := 0; end;
      3: SetLength(cs2, Rand(len));
      else begin p := Rand(Min(len, 512)); cs2[p] := Rand(256); SetLength(cs2, len - Rand(Min(len, 64))); end;
    end;
    Inc(m2FzCs);
    try
      r := J2kMode2Encode(cs2, 0, Length(cs2), m1Threads, b2, why);
      if r = m2Ok then Inc(m2FzCsOk)
      else if (Pos('verify', why) = 1) or (Pos('exception', why) = 1) or (Pos('internal', why) = 1) then begin
        Inc(m2Fail); Writeln('MODE2 FUZZ FAIL codestream ', f, ' #', ci, ' variant ', k, ': ', why);
      end;
    except
      on E: Exception do begin
        Inc(m2Fail); Writeln('MODE2 FUZZ FAIL codestream ', f, ' #', ci, ' variant ', k, ': ', E.ClassName, ' ', E.Message);
      end;
    end;
  end;
  for k := 1 to m2Fuzz do begin
    b2 := Copy(m);
    n := 1 + Rand(4);
    case Rand(4) of
      0: SetLength(b2, Rand(Length(b2)));
      1: for j := 1 to n do begin p := Rand(Min(Length(b2), 64)); b2[p] := b2[p] xor (1 shl Rand(8)); end;
      else for j := 1 to n do begin p := Rand(Length(b2)); b2[p] := b2[p] xor (1 shl Rand(8)); end;
    end;
    Inc(m2FzRuns);
    try
      r := J2kMode2DecodeWhy(b2, len, m1Threads, back, why);
      if r = m2Ok then Inc(m2FzOk);
      if Pos('exception', why) = 1 then begin
        Inc(m2Fail); Writeln('MODE2 FUZZ FAIL ', f, ' #', ci, ' variant ', k, ': ', why);
      end;
    except
      on E: Exception do begin
        Inc(m2Fail); Writeln('MODE2 FUZZ FAIL ', f, ' #', ci, ' variant ', k, ': ', E.ClassName, ' ', E.Message);
      end;
    end;
  end;
end;

{ a mode 2 stream whose side information's SIZ says planes past the caps
  (2^21 samples wide; 1,024 x max(2^17, len + 1) samples, more than 1,024
  a codestream's byte; on each component's grid): refused before a plane
  is made, at once (doc/CODEC.md, stage D, "Memory") }
procedure Mode2Caps(const m: TBytes; len: Int64; const f: string; ci: Integer);
var cd: TCoder; blob, raw, b2, side, ns, back: TBytes; sl, p, mdx, mdy, w, h: Int64; i: SizeInt; k: Integer;
  r: TMode2Result; why: string;
  t0: TDateTime;
  procedure Put32(var b: TBytes; q: Int64; v: Cardinal);
  begin
    b[q] := v shr 24; b[q + 1] := (v shr 16) and $FF; b[q + 2] := (v shr 8) and $FF; b[q + 3] := v and $FF;
  end;
  function Get32(const b: TBytes; q: Int64): Cardinal;
  begin
    Result := (Cardinal(b[q]) shl 24) or (Cardinal(b[q + 1]) shl 16) or (Cardinal(b[q + 2]) shl 8) or b[q + 3];
  end;
begin
  sl := Int64(m[5]) or (Int64(m[6]) shl 8) or (Int64(m[7]) shl 16) or (Int64(m[8]) shl 24);
  cd.InitDecoder(Copy(m, 9, sl), 0);
  if not CodeRaw(cd, blob, 1 shl 30) or not J2kBlobSiz(blob, raw) then begin
    Inc(m2Fail); Writeln('MODE2 CAPS FAIL ', f, ' #', ci, ': no SIZ'); Exit;
  end;
  p := -1;
  for i := 0 to Length(blob) - Length(raw) do
    if CompareMem(@blob[i], @raw[0], Length(raw)) then begin p := i; Break; end;
  if p < 0 then begin Inc(m2Fail); Writeln('MODE2 CAPS FAIL ', f, ' #', ci, ': SIZ not found'); Exit; end;
  mdx := 1; mdy := 1;
  for i := 0 to (Length(raw) - 40) div 3 - 1 do begin
    mdx := Max(mdx, raw[41 + 3 * i]); mdy := Max(mdy, raw[42 + 3 * i]);
  end;
  for k := 0 to 1 do begin
    b2 := Copy(blob);
    { Xsiz, Ysiz from XOsiz, YOsiz }
    { on each component's grid, whatever its sampling }
    if k = 0 then begin w := mdx shl 21; h := Get32(raw, 10) - Get32(raw, 18); end
    else begin w := mdx * 1024; h := mdy * Max(1 shl 17, len + 1); end;
    Put32(b2, p + 6, Min(Int64(Get32(raw, 14)) + w, High(Cardinal)));
    Put32(b2, p + 10, Min(Int64(Get32(raw, 18)) + h, High(Cardinal)));
    cd.InitEncoder; CodeRaw(cd, b2, MaxInt); side := cd.enc.Finish;
    SetLength(ns, 9 + Length(side));
    Move(m[0], ns[0], 9);
    ns[5] := Length(side) and $FF; ns[6] := (Length(side) shr 8) and $FF; ns[7] := (Length(side) shr 16) and $FF;
    ns[8] := Length(side) shr 24;
    if Length(side) > 0 then Move(side[0], ns[9], Length(side));
    ns := Concat(ns, Copy(m, 9 + sl, Length(m)));
    t0 := Now;
    r := J2kMode2DecodeWhy(ns, len, m1Threads, back, why);
    if (r <> m2Bad) or ((why <> 'too wide') and (why <> 'too many samples') and
       (why <> 'too many samples for its bytes')) or (MilliSecondsBetween(Now, t0) > 2000) then begin
      Inc(m2Fail); Writeln('MODE2 CAPS FAIL ', f, ' #', ci, ' variant ', k, ': ', Ord(r), ' ', why, ' in ',
        MilliSecondsBetween(Now, t0), ' ms');
    end else Inc(m2Caps);
  end;
end;

{ -mode2: the codestream as stream version 8's mode 2 (pjaj2kpx), decoded
  again and compared; and with -mode1, the choice }
procedure Mode2One(const d: TBytes; off, len: Int64; const f: string; ci: Integer);
var m, back: TBytes; why: string; t0: TDateTime; r: TMode2Result; side, best, floor1: Int64; te, td: Double;
  chosen: Integer;
begin
  t0 := Now;
  { every stream mode 2 makes, shorter than the codestream or not }
  r := J2kMode2Encode(d, off, len, m1Threads, High(Int64), m, why, floor1);
  te := MilliSecondsBetween(Now, t0) / 1000;
  if r <> m2Ok then begin
    if (Pos('verify', why) = 1) or (Pos('exception', why) = 1) or (Pos('internal', why) = 1) then begin
      Inc(m2Fail); Writeln('MODE2 FAIL ', f, ' #', ci, ': ', why);
    end else begin
      Inc(m2Ref);
      if not quiet then Writeln('MODE2REFUSED ', ExtractFileName(f), ' #', ci, ' ', why);
    end;
    Count2(why);
    m := nil;
  end else begin
    t0 := Now;
    r := J2kMode2Decode(m, len, m1Threads, back);
    td := MilliSecondsBetween(Now, t0) / 1000;
    if (r <> m2Ok) or (Length(back) <> len) or not CompareMem(@back[0], @d[off], len) then begin
      Inc(m2Fail); Writeln('MODE2 FAIL ', f, ' #', ci, ': decode'); Exit;
    end;
    side := Int64(m[5]) or (Int64(m[6]) shl 8) or (Int64(m[7]) shl 16) or (Int64(m[8]) shl 24);
    m2Digest := m2Digest xor Fnv(m);
    m2Cs := m2Cs + len; m2Bytes := m2Bytes + Length(m); m2Side := m2Side + side;
    tM2e := tM2e + te; tM2d := tM2d + td;
    Writeln('MODE2 ', ExtractFileName(f), ' #', ci, ' ', len, ' ', Length(m), ' ', side, ' ',
      FormatFloat('0.000', te), ' ', FormatFloat('0.000', td));
    Mode2Caps(m, len, f, ci);
    if m2Fuzz > 0 then Mode2Fuzz(m, len, f, ci, d, off);
  end;
  if mode1 then begin
    { the choice, as pjacodec.CompressJ2k makes it }
    best := len; chosen := 0;
    if (m <> nil) and (Length(m) < best) then begin best := Length(m); chosen := 2; end;
    if (lastM1 >= 0) and (lastM1 < best) and ((chosen = 0) or (best > floor1)) then begin
      best := lastM1; chosen := 1;
    end;
    chCs := chCs + len; chBytes := chBytes + best;
    if lastM1 >= 0 then chM1Bytes := chM1Bytes + Min(lastM1, len) else chM1Bytes := chM1Bytes + len;
    case chosen of 0: Inc(chM0); 1: Inc(chM1); else Inc(chM2); end;
    Writeln('CHOICE ', ExtractFileName(f), ' #', ci, ' ', len, ' mode1 ', lastM1, ' mode2 ', Length(m), ' -> mode ',
      chosen, ' ', best);
  end;
end;

procedure OneFile(const f: string);
var d, blob, back, blob2: TBytes; cs: TJ2kCodestreams; i: Integer; why: string; t0: TDateTime; ok: Boolean;
  s0, s1: TJ2kStats; sz: Int64; lkd: TJ2kModelLink;
begin
  if not ReadFile(f, d) then Exit;
  if not J2kCodestreams(d, cs) then Exit;
  Inc(nfiles);
  for i := 0 to High(cs) do begin
    Inc(ncs);
    bytesCs := bytesCs + cs[i].len;
    s0 := st;
    t0 := Now;
    ok := J2kAnalyze(d, cs[i].off, cs[i].len, blob, why, st);
    tAn := tAn + MilliSecondsBetween(Now, t0) / 1000;
    if not ok then begin
      if (Pos('verify', why) = 1) or (Pos('exception', why) = 1) or (Pos('internal', why) = 1) then begin
        Inc(nfail);
        Writeln('FAIL ', f, ' #', i, ' (', cs[i].len, ' bytes): ', why);
      end else Writeln('refused ', f, ' #', i, ': ', why);
      Count(why);
      if fuzz > 0 then FuzzOne(d, cs[i].off, cs[i].len, nil, f, i);
      Continue;
    end;
    lastM1 := -1;
    if mode1 then Mode1One(d, cs[i].off, cs[i].len, f, i);
    if mode2 then Mode2One(d, cs[i].off, cs[i].len, f, i);
    if dumpS <> nil then begin
      lkd.kind := kmDump; lkd.slice := nil; lkd.dump := dumpS;
      s1 := Default(TJ2kStats);
      if not J2kAnalyzeWith(d, cs[i].off, cs[i].len, lkd, blob2, why, s1) then Writeln('DUMP FAIL ', f, ': ', why);
    end;
    { again, from a copy of the blob alone }
    blob2 := Copy(blob);
    blob := nil;
    if sidePrefix <> '' then SaveSide(blob2);
    AddDigest(blob2);
    if fuzz > 0 then FuzzOne(d, cs[i].off, cs[i].len, blob2, f, i);
    t0 := Now;
    ok := J2kRebuild(blob2, back);
    tRb := tRb + MilliSecondsBetween(Now, t0) / 1000;
    if not ok or (Length(back) <> cs[i].len) or ((cs[i].len > 0) and not CompareMem(@back[0], @d[cs[i].off], cs[i].len)) then begin
      Inc(nfail);
      Writeln('FAIL ', f, ' #', i, ': the rebuild differs');
      Count('rebuild differs');
      Continue;
    end;
    Inc(nok);
    bytesOk := bytesOk + cs[i].len;
    sz := Length(blob2);
    bytesSide := bytesSide + sz - (st.side[SH_DEC] - s0.side[SH_DEC]);
    bytesDec := bytesDec + (st.side[SH_DEC] - s0.side[SH_DEC]);
    if not quiet then
      Writeln('ok ', f, ' #', i, ' ', cs[i].len, ' bytes, side ', sz - (st.side[SH_DEC] - s0.side[SH_DEC]),
        ' (', FormatFloat('0.00', 100.0 * (sz - (st.side[SH_DEC] - s0.side[SH_DEC])) / cs[i].len), '%), hdrx ',
        st.hdrExceptions - s0.hdrExceptions, ', cb raw ', st.cbRaw - s0.cbRaw, '/', st.cbs - s0.cbs + st.cbRaw - s0.cbRaw,
        ', tails ', st.tails - s0.tails);
  end;
end;

procedure Walk(const path: string);
var sr: TSearchRec;
begin
  if DirectoryExists(path) then begin
    if FindFirst(IncludeTrailingPathDelimiter(path) + '*', faAnyFile, sr) = 0 then begin
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if sr.Attr and faSymLink <> 0 then Continue;
        Walk(IncludeTrailingPathDelimiter(path) + sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end else OneFile(path);
end;

var i, k: Integer; lst: TStringList;
begin
  J2kTestSlicesFromEnv;
  reasons := TStringList.Create;
  m2Reasons := TStringList.Create;
  st := Default(TJ2kStats);
  i := 1;
  while i <= ParamCount do begin
    if ParamStr(i) = '-q' then quiet := True
    else if ParamStr(i) = '-fuzz' then begin Inc(i); fuzz := StrToInt(ParamStr(i)); end
    else if ParamStr(i) = '-side' then begin Inc(i); sidePrefix := ParamStr(i); end
    else if ParamStr(i) = '-mode1' then mode1 := True
    else if ParamStr(i) = '-mode2' then mode2 := True
    else if ParamStr(i) = '-m2fuzz' then begin Inc(i); m2Fuzz := StrToInt(ParamStr(i)); end
    else if ParamStr(i) = '-threads' then begin Inc(i); m1Threads := StrToInt(ParamStr(i)); end
    else if ParamStr(i) = '-dumpcb' then begin Inc(i); dumpS := TFileStream.Create(ParamStr(i), fmCreate); end
    else if ParamStr(i) = '-min' then begin Inc(i); minOk := StrToInt(ParamStr(i)); end
    else if ParamStr(i) = '-l' then begin
      Inc(i);
      lst := TStringList.Create;
      lst.LoadFromFile(ParamStr(i));
      for k := 0 to lst.Count - 1 do if Trim(lst[k]) <> '' then Walk(Trim(lst[k]));
      lst.Free;
    end else Walk(ParamStr(i));
    Inc(i);
  end;
  Writeln('files ', nfiles, ', codestreams ', ncs, ': rebuilt byte for byte ', nok, ', refused ', ncs - nok - nfail,
    ', FAILED ', nfail);
  for i := 0 to reasons.Count - 1 do Writeln('  ', PtrInt(reasons.Objects[i]), ' x ', reasons[i]);
  if bytesOk > 0 then begin
    Writeln('codestream bytes rebuilt ', bytesOk, ' of ', bytesCs, '; side information ', bytesSide, ' (',
      FormatFloat('0.000', 100.0 * bytesSide / bytesOk), '%), decisions ', st.decisions, ' (', bytesDec, ' bytes as bits)');
    Write('  side by stream:');
    for i := 0 to J2K_NSTREAMS - 1 do Write(' ', J2kStreamName(i), ' ', st.side[i]);
    Writeln;
    Writeln('  tiles ', st.tiles, ' packets ', st.packets, ' header exceptions ', st.hdrExceptions, ' tree overrides ',
      st.treeOverrides, ' Lblock not least ', st.lbNonMinimal);
    Writeln('  code-blocks ', st.cbs, ' (kept as bytes ', st.cbRaw, '), segments ', st.segs, ' (bypass ', st.rawSegs,
      '), tails ', st.tails, ' (', st.tailBits, ' bits)');
    Write('  segments by rule:');
    for i := 0 to 15 do if st.rule[i] > 0 then Write(' ', J2kRuleName(i), ' ', st.rule[i]);
    Writeln;
    Writeln('  layer boundaries ', st.bounds, ': OpenJPEG ', st.brule[0], ', shortest prefix ', st.brule[1], ', explicit ',
      st.brule[2], ', decoder reach ', st.brule[3]);
    if tAn > 0 then
      Writeln('  speed: analysis with its check ', FormatFloat('0.00', bytesCs / 1048576 / tAn), ' MB/s, rebuild ',
        FormatFloat('0.00', bytesOk / 1048576 / Max(tRb, 0.001)), ' MB/s (', FormatFloat('0.0', tAn), ' s + ',
        FormatFloat('0.0', tRb), ' s)');
  end;
  if mode1 and (m1Cs > 0) then
    Writeln('mode 1: ', m1Cs, ' bytes of codestream -> ', m1Bytes, ' (', FormatFloat('0.000', 100.0 * m1Bytes / m1Cs),
      '%, side ', m1Side, ' = ', FormatFloat('0.000', 100.0 * m1Side / m1Cs), '%), failed ', m1Fail, '; ',
      FormatFloat('0.000', m1Cs / 1048576 / Max(tM1e, 0.001)), ' MB/s encoding (with its check), ',
      FormatFloat('0.000', m1Cs / 1048576 / Max(tM1d, 0.001)), ' MB/s decoding; streams digest ',
      IntToHex(m1Digest, 16));
  if m1Fail > 0 then nfail := nfail + m1Fail;
  if mode2 then begin
    Write('mode 2: ', m2Cs, ' bytes of codestream taken -> ', m2Bytes);
    if m2Cs > 0 then Write(' (', FormatFloat('0.000', 100.0 * m2Bytes / m2Cs), '%, side ', m2Side, ' = ',
      FormatFloat('0.000', 100.0 * m2Side / m2Cs), '%; ', FormatFloat('0.000', m2Cs / 1048576 / Max(tM2e, 0.001)),
      ' MB/s encoding (with its check), ', FormatFloat('0.000', m2Cs / 1048576 / Max(tM2d, 0.001)), ' MB/s decoding)');
    Writeln('; refused ', m2Ref, ', failed ', m2Fail, '; streams digest ', IntToHex(m2Digest, 16));
    Writeln('mode 2 caps: ', m2Caps, ' streams past the caps refused at once');
    for i := 0 to m2Reasons.Count - 1 do Writeln('  mode 2 refused: ', PtrInt(m2Reasons.Objects[i]), ' x ', m2Reasons[i]);
    if m2Fuzz > 0 then Writeln('mode 2 fuzz: ', m2FzRuns, ' damaged streams (', m2FzOk, ' gave the codestream), ',
      m2FzCs, ' damaged codestreams (', m2FzCsOk, ' taken and given back)');
    if mode1 and (chCs > 0) then
      Writeln('choice: ', chCs, ' bytes of codestream -> ', chBytes, ' (saves ', FormatFloat('0.000',
        100.0 - 100.0 * chBytes / chCs), '%; mode 1 alone ', FormatFloat('0.000', 100.0 - 100.0 * chM1Bytes / chCs),
        '%); codestreams in mode 0 ', chM0, ', mode 1 ', chM1, ', mode 2 ', chM2);
  end;
  if m2Fail > 0 then nfail := nfail + m2Fail;
  if fuzz > 0 then
    Writeln('fuzz: ', fzRuns, ' damaged codestreams (', fzOk, ' taken and given back), ', fzBlob, ' damaged blobs (',
      fzBlobOk, ' gave a codestream), FAILED ', fzFail);
  if fzFail > 0 then nfail := nfail + fzFail;
  Writeln('blobs digest ', IntToHex(digest, 16));
  if nok < minOk then begin Writeln('FAIL: ', nok, ' codestreams back, fewer than ', minOk); Inc(nfail); end;
  { the same, one line, for a script that adds up several runs }
  Write('TOTALS files=', nfiles, ' cs=', ncs, ' ok=', nok, ' fail=', nfail, ' bytescs=', bytesCs, ' bytesok=', bytesOk,
    ' side=', bytesSide, ' dec=', bytesDec, ' decisions=', st.decisions, ' tan=', FormatFloat('0.000', tAn), ' trb=',
    FormatFloat('0.000', tRb), ' packets=', st.packets, ' hdrx=', st.hdrExceptions, ' tree=', st.treeOverrides,
    ' lb=', st.lbNonMinimal, ' cbs=', st.cbs, ' cbraw=', st.cbRaw, ' segs=', st.segs, ' rawsegs=', st.rawSegs,
    ' tails=', st.tailBits, ' tailsegs=', st.tails, ' b0=', st.brule[0], ' b1=', st.brule[1], ' b2=', st.brule[2], ' b3=', st.brule[3]);
  for i := 0 to 15 do Write(' r', i, '=', st.rule[i]);
  for i := 0 to J2K_NSTREAMS - 1 do Write(' s_', J2kStreamName(i), '=', st.side[i]);
  for i := 0 to reasons.Count - 1 do Write(' R:', StringReplace(reasons[i], ' ', '_', [rfReplaceAll]), '=',
    PtrInt(reasons.Objects[i]));
  Write(' fzruns=', fzRuns, ' fzok=', fzOk, ' fzblob=', fzBlob, ' fzblobok=', fzBlobOk, ' fzfail=', fzFail);
  Writeln;
  reasons.Free;
  m2Reasons.Free;
  dumpS.Free;
  if nfail > 0 then Halt(1);
end.

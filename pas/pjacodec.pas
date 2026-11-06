{ Codec layer 4: the compressed stream of ONE JPEG.

    byte 0          STREAM_VERSION (5), or STREAM_V7 (7) for a JPEG's
                    coefficients with version 7's model
    byte 1          the coefficient model: 0 the full one, 1 the fast one
                    (pjamodel.CodeBand); 0 for JPEG-LS and for version 7
    4 bytes (LE)    length H of the header stream
    H bytes         arithmetic stream: raw length (32 direct bits) and raw
                    bytes (pjamodel.CodeRaw), then one padding bit per scan;
                    for JPEG-LS instead, which model: 0 = samples, followed
                    by the run lengths (pjamodel.CodeJlsRuns) and bands as
                    below; 1 = the JPEG-LS symbols, in a single band
    for each band but the last: 4 bytes (LE) length, then that many bytes
    the last band   to the end

  Each band is an arithmetic stream of its own with the coefficients of a
  horizontal slice of the image (pjamodel.CodeBand), so the bands can be
  coded and decoded in parallel. How many bands there are follows from the
  image (pjamodel.BandCount): it is not stored.

  Nothing else is stored: the frame, the Huffman tables, the scans and their
  cuts come back from parsing the raw bytes again (pjajpeg.ParseHeaders).

  A JPEG with other JPEGs inside it (a thumbnail in an APP segment, the
  further images of an MPO, an Ultra HDR gain map) can go as version 6
  instead (STREAM_PARTS, below DecompressOne): each of those as a stream
  of its own, and the file around them as a version 5 stream.

  A file of the JPEG 2000 family goes as version 8 (STREAM_J2K, below
  ReadPatch): where its codestreams are, and its bytes.

  Compress verifies before handing anything out: it decompresses its own
  output and compares it with the input. A JPEG that does not come back
  byte for byte is rejected with its reason. With two threads or more, a
  JPEG's bands are decoded while they are being encoded (CompressLive).

  Threads: a program that passes threads > 1 on Unix has to use cthreads. }
unit pjacodec;

{$I pja.inc}
{$ifopt R-}{$fatal pjacodec: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjacodec: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjajpeg, pjajls;

const
  { PJA's release: the command and the zpaq-std plugin say this one }
  PJA_VERSION = '0.9.6';
  { 5 since 0.0.1: the predictions' arithmetic made 32-bit (pjamodel.W32),
    so a ZPAQL decoder can follow it exactly; 4 streams decoded with the
    64-bit one and are no longer read }
  STREAM_VERSION = 5;
  { a JPEG with other JPEGs inside it (an EXIF thumbnail, the further
    images of an MPO, an Ultra HDR gain map): each of them as a stream of
    its own, the rest as a version 5 stream (doc/CODEC.md). Compress writes
    it only when it found such a JPEG, version 5 otherwise. Since 0.0.2,
    with the encoder quirks and the files taken as bytes too }
  STREAM_PARTS = 6;
  { the layout of version 5, the coefficients with another model: the full
    one with fewer decisions, in C (pjav7; doc/CODEC.md). Only a program
    with pjav7 writes or reads it (the command, not the zpaq-std plugin).
    Since 0.1.0 }
  STREAM_V7 = 7;
  { a file of the JPEG 2000 family (pjaj2k): where its codestreams are,
    each with a mode, and the file's other bytes through the raw bytes'
    model. Since 0.9.5: a codestream is raw (mode 0: its bytes stay among
    the others), modelled (mode 1, pjaj2km) or kept as its pixels (mode 2,
    pjaj2kpx); since 0.9.6 an HTJ2K codestream modelled (mode 3, pjaj2km)
    or kept as its pixels (mode 4, pjaj2kpx);
    later stages bring other modes, which a reader that does not know them refuses as
    FutureVersion (doc/CODEC.md) }
  STREAM_J2K = 8;
  { the header: version, model, header stream length }
  STREAM_HEADER = 6;

type
  TCodecError = (
    ceOk,
    { Compress: the JPEG is not handled (detail in jpeg) }
    ceJpeg,
    { Compress: the stream did not decompress to the same bytes; a bug }
    ceNoRoundTrip,
    { Decompress: not a stream of this version, or damaged }
    ceBadStream, ceFutureVersion, ceTooLarge);

  TCodecResult = record
    err: TCodecError;
    jpeg: TJpegResult;    { with ceJpeg, and with ceBadStream when the raw bytes do not parse }
    { Compress: PJA did not take the file as a JPEG (jpeg says why), and it
      went through the raw bytes' model instead (stream version 6, BYTES) }
    asBytes: Boolean;
    { Compress: PJA took the file once it repaired an encoder's slip (jpeg
      says which), and keeps the repairs (stream version 6, PATCH) }
    repaired: Boolean;
    { Compress: a file of the JPEG 2000 family (stream version 8) }
    j2k: Boolean;
    { and how many of its bytes are in codestreams of mode 1 to 4
      (modelled), and of those how many in mode 2 (pixels), in mode 3
      (HTJ2K) and in mode 4 (HTJ2K's pixels) }
    j2kModelled, j2kPixels, j2kHt, j2kHtPixels: Int64;
    function Ok: Boolean;
    function Text: string;
  end;

type
  { Stream version 8's mode 1 (a codestream's decisions through a model),
    set by pjaj2km's initialization: a program without it (the zpaq-std
    plugin) writes mode 0 only and reads mode 1 as FutureVersion. Enc gives
    the codestream data[off..off + len)'s stream, decoded and compared
    already when check (else the caller decodes it: CompressJ2k checks only
    the stream it keeps); Dec the codestream (len bytes) back. }
  TJ2kMode1Enc = function(const data: TBytes; off, len: Int64; threads: Integer; check: Boolean;
    out stream: TBytes): Boolean;
  { mode 2's: a stream shorter than the codestream, and the least mode 1's
    could be (pjaj2kpx.J2kMode2Encode) }
  TJ2kMode2Enc = function(const data: TBytes; off, len: Int64; threads: Integer; check: Boolean;
    out stream: TBytes; out mode1Floor: Int64): Boolean;
  TJ2kMode1Dec = function(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TCodecError;

var
  J2kMode1Enc: TJ2kMode1Enc = nil;
  J2kMode1Dec: TJ2kMode1Dec = nil;
  { mode 2 (the codestream as its pixels), the same way, set by pjaj2kpx }
  J2kMode2Enc: TJ2kMode2Enc = nil;
  J2kMode2Dec: TJ2kMode1Dec = nil;
  { mode 3 (an HTJ2K codestream's code-blocks through a model), the same
    way as mode 1, set by pjaj2km }
  J2kMode3Enc: TJ2kMode1Enc = nil;
  J2kMode3Dec: TJ2kMode1Dec = nil;
  { mode 4 (a lossless HTJ2K codestream as its pixels), as mode 2, set by
    pjaj2kpx; its floor is mode 3's }
  J2kMode4Enc: TJ2kMode2Enc = nil;
  J2kMode4Dec: TJ2kMode1Dec = nil;
  { a file's codestreams coded side by side (CompressJ2k); the zpaq-std
    plugin turns it off, its mode 1 hook counting in threadvars }
  J2kCodestreamsTogether: Boolean = True;

{ JPEG -> stream. With verify (the default), the stream is decompressed and
  compared before returning (a repaired JPEG's always). threads: how many
  bands at once (1 = no thread is created). fast: a JPEG's coefficients
  with the fast model, which decodes about 1.5 times as fast for about 1.7%
  more (doc/CODEC.md); JPEG-LS files ignore it. parts: the JPEGs inside a JPEG compressed on
  their own (STREAM_PARTS); without it the stream is always version 5, the
  one the zpaq-std plugin's ZPAQL reads. v7: a JPEG's coefficients with
  version 7's model (fast is then ignored), which needs pjav7 in the
  program; JPEG-LS and lossless JPEG stay version 5. With parts, a file of
  the JPEG 2000 family goes as version 8; without, it is refused as
  today. }
function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean = True;
                  threads: Integer = 1; fast: Boolean = False; parts: Boolean = True;
                  v7: Boolean = False): TCodecResult;
{ What CompressOne writes (version 5, the full model) for a JPEG whose
  round trip the caller has verified on these very bytes already
  (VerifyRoundTrip): j as Decompose leaves it, not rebuilt and compared
  again. The zpaq-std plugin's compress after its detection; zpaq-std then
  decodes the block and compares it. }
function CompressVerified(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; threads: Integer = 1;
                          v7: Boolean = False): TCodecResult;
{ What the zpaq-std plugin's pjax codec writes: version 5 or 6 for a
  Huffman JPEG (8 or 12 bits, DNL, quirks), its parts version 5 and Huffman
  too, nothing as bytes: what pjax's ZPAQL decodes. }
function CompressPjax(const jpeg: TBytes; out stream: TBytes; verify: Boolean = True; threads: Integer = 1;
                      v7: Boolean = False): TCodecResult;
{ stream -> JPEG. maxRaw caps the raw part a damaged stream can claim.
  expected: the JPEG's size when the caller knows it (the .pja does), to
  allocate it once; 0 if not. Only a hint: the result is not checked
  against it here. }
function Decompress(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt = 1 shl 28;
                    threads: Integer = 1; expected: SizeInt = 0): TCodecResult;
{ A JPEG stream's headers only (its raw bytes, parsed), without decoding the
  bands: what a decoder will need, before decoding. Fails for JPEG-LS. }
function StreamHeaders(const stream: TBytes; out j: TJpeg; maxRaw: SizeInt = 1 shl 28): TCodecResult;
{ The same for a JPEG-LS stream: its headers, the near-lossless scans' run
  lengths when it has them, and which model it uses. Fails for JPEG. }
function StreamJlsHeaders(const stream: TBytes; out jl: TJls; out symbols: Boolean;
                          maxRaw: SizeInt = 1 shl 28): TCodecResult;

implementation

uses Classes, Math, pjaarith, pjamodel, pjastage, pjathread, pjaj2k;

type
  { scan numbers: version 6's quirks }
  TScanList = array of Integer;
  TQuirks = record
    { the scans that ignore the DRI in force }
    ri: TScanList;
    { the scans whose EOB runs hold another number of correction bits, and
      that number (pjajpeg TScan.maxBe) }
    be, beMax: TScanList;
  end;

const
  ERROR_NAMES: array[TCodecError] of string = ('Ok', 'Jpeg', 'NoRoundTrip', 'BadStream', 'FutureVersion', 'TooLarge');

function TCodecResult.Ok: Boolean;
begin Result := err = ceOk; end;

function TCodecResult.Text: string;
begin
  Result := ERROR_NAMES[err];
  if (err = ceJpeg) or ((err = ceBadStream) and not jpeg.Ok) then Result := Result + '(' + jpeg.Text + ')';
end;

function CodecFail(e: TCodecError): TCodecResult;
begin
  Result := Default(TCodecResult);
  Result.err := e;
end;

procedure CodeScanBits(var cd: TCoder; var j: TJpeg);
var i: Integer;
begin
  for i := 0 to High(j.scans) do
    j.scans[i].padbit := Integer(cd.Direct(Cardinal(j.scans[i].padbit), 1));
end;

{ ---------- bands, in sequence or in threads ---------- }

type
  PJpeg = ^TJpeg;
  PJls = ^TJls;

  { One band: encodes it into `output`, or decodes it from input[first..last).
    Of a JPEG (j) or of a JPEG-LS file (jl). }
  TBandJob = record
    j: PJpeg;
    jl: PJls;
    symbols: Boolean;     { JPEG-LS: the symbol model, not the samples }
    band: Integer;
    encoding: Boolean;
    input: TBytes;
    first, last: SizeInt;
    output: TBytes;
    { not nil: encoding writes into it, or decoding reads it while another
      thread writes it }
    live: TLiveStream;
    model: TModelKind;      { a JPEG's coefficients: which model }
    ok: Boolean;
  end;
  PBandJob = ^TBandJob;

  TBandThread = class(TJoinThread)
    job: PBandJob;
    procedure Execute; override;
  end;

procedure RunBand(var b: TBandJob);
var cd: TCoder; slice: TBytes;
begin
  b.ok := False;
  try
    if b.live <> nil then begin
      if b.encoding then cd.InitLiveEncoder(b.live) else cd.InitLiveDecoder(b.live);
    end else if b.encoding then cd.InitEncoder
    else begin
      { the band's own bytes only: past them the decoder reads zeros, never
        the next band }
      slice := Copy(b.input, b.first, b.last - b.first);
      cd.InitDecoder(slice, 0);
    end;
    if b.symbols then b.ok := CodeJlsSymbolStream(cd, b.jl^)
    else if b.jl <> nil then b.ok := CodeJlsBand(cd, b.jl^, b.band)
    else b.ok := CodeBand(cd, b.j^, b.band, b.model);
    if b.encoding then b.output := cd.enc.Finish;
  except
    b.ok := False;
  end;
  { an encoder that failed still closes its stream, or its reader would
    wait forever (closing twice changes nothing) }
  if b.encoding and (b.live <> nil) then b.live.Finish;
end;

procedure TBandThread.Execute;
begin
  RunBand(job^);
  ReleaseThreadModels;
end;

function Min2(a, b: Integer): Integer;
begin if a < b then Result := a else Result := b; end;

{ A thread for a job, not started; nil if the system has none to give (a
  host at its limit, an address space full of stacks). }
function NewBandThread(job: PBandJob): TBandThread;
begin
  try
    Result := TBandThread.Create(True);
  except
    Exit(nil);
  end;
  Result.job := job;
  Result.FreeOnTerminate := False;
end;

{ Runs every job, up to `threads` at a time. }
procedure RunBands(var jobs: array of TBandJob; threads: Integer);
var i, next, k, started: Integer; pool: array of TBandThread;
begin
  if (threads <= 1) or (Length(jobs) <= 1) then begin
    { PJA_BANDS_REVERSE=1 (the codec suite): the last band first, which shows
      that no band reads what an earlier band decodes }
    if GetEnvironmentVariable('PJA_BANDS_REVERSE') = '1' then
      for i := High(jobs) downto 0 do RunBand(jobs[i])
    else
      for i := 0 to High(jobs) do RunBand(jobs[i]);
    Exit;
  end;
  next := 0;
  while next < Length(jobs) do begin
    pool := nil;
    SetLength(pool, Min2(threads, Length(jobs) - next));
    started := 0;
    while started < Length(pool) do begin
      pool[started] := NewBandThread(@jobs[next + started]);
      if pool[started] = nil then Break;
      pool[started].Start;
      Inc(started);
    end;
    { the jobs no thread was had for, here; the threads running are waited
      for all the same, never left on jobs the caller is about to free }
    for k := started to High(pool) do RunBand(jobs[next + k]);
    for k := 0 to started - 1 do begin pool[k].Join; pool[k].Free; end;
    Inc(next, Length(pool));
  end;
end;

procedure PutU32(var d: TBytes; var p: SizeInt; v: Cardinal);
var k: Integer;
begin
  for k := 0 to 3 do begin d[p] := Byte((v shr (8 * k)) and $FF); Inc(p); end;
end;

function GetU32(const d: TBytes; p: SizeInt): Cardinal;
var k: Integer;
begin
  Result := 0;
  for k := 3 downto 0 do Result := (Result shl 8) or d[p + k];
end;

{ ---------- top ---------- }

function StreamVersionOf(model: TModelKind): Byte;
begin
  if model = mkV7 then Result := STREAM_V7 else Result := STREAM_VERSION;
end;

{ The bands of a JPEG or of a JPEG-LS file, encoded, and the whole stream. }
{ The stream from the header stream and the bands already encoded. }
function Build(const head: TBytes; const jobs: array of TBandJob; out stream: TBytes): Boolean;
var b, nb: Integer; total, p: SizeInt;
begin
  stream := nil;
  nb := Length(jobs);
  total := STREAM_HEADER + Length(head);
  for b := 0 to nb - 1 do begin
    if not jobs[b].ok then Exit(False);
    Inc(total, Length(jobs[b].output));
    if b < nb - 1 then Inc(total, 4);
  end;
  SetLength(stream, total);
  stream[0] := STREAM_VERSION;
  if (nb > 0) and (jobs[0].model = mkV7) then stream[0] := STREAM_V7;
  stream[1] := Ord((nb > 0) and (jobs[0].model = mkFast));
  p := 2;
  PutU32(stream, p, Length(head));
  Move(head[0], stream[p], Length(head)); Inc(p, Length(head));
  for b := 0 to nb - 1 do begin
    if b < nb - 1 then PutU32(stream, p, Length(jobs[b].output));
    if Length(jobs[b].output) > 0 then Move(jobs[b].output[0], stream[p], Length(jobs[b].output));
    Inc(p, Length(jobs[b].output));
  end;
  Result := True;
end;

{ A lossless JPEG's samples as a JPEG-LS file's, for its samples model
  (pjamodel.CodeJlsBand): the same arrays, not a copy, so what the model
  decodes is where pjajpeg.Recompose reads it. Their range is the point
  transform's, the same in every scan. }
procedure LosslessView(const j: TJpeg; out jl: TJls);
var c: Integer;
begin
  jl := Default(TJls);
  jl.width := j.width; jl.height := j.height;
  jl.bits := j.precision - j.scans[0].al;
  SetLength(jl.comp, Length(j.comp));
  for c := 0 to High(j.comp) do begin
    jl.comp[c].id := j.comp[c].id;
    jl.comp[c].h := 1; jl.comp[c].v := 1;
    jl.comp[c].width := j.width; jl.comp[c].height := j.height;
    jl.comp[c].samples := j.comp[c].samples;
  end;
end;

function Assemble(const head: TBytes; var jobs: array of TBandJob; threads: Integer; out stream: TBytes): Boolean;
begin
  RunBands(jobs, threads);
  Result := Build(head, jobs, stream);
end;

{ The header stream version 5 writes for this JPEG. The bands of a host
  and of the file it came from are the same: the host's stream is the
  file's with this instead of the file's own, and comparing the two tells
  whether the parts pay. j is only read (its scans are copied before
  CodeScanBits writes them back), so band threads may read it meanwhile. }
function HeadBytes(const j: TJpeg): TBytes;
var cd: TCoder; jj: TJpeg;
begin
  jj := j;
  jj.scans := Copy(j.scans);
  cd.InitEncoder;
  CodeRaw(cd, jj.raw, MaxInt);
  CodeScanBits(cd, jj);
  Result := cd.enc.Finish;
end;

const
  { raw bytes from which a header stream is worth a thread of its own: the
    raw model costs about 350 instructions a bit, a thread and its fresh
    tables (16 MB) a few milliseconds }
  HELPER_RAW = 1 shl 16;

type
  { HeadBytes on another thread, while the caller does something else. The
    tables libpja gives (GivenTables, a threadvar) go with it, or its header
    stream would not be the caller's. }
  THeadThread = class(TJoinThread)
    j: TJpeg;
    given, head: TBytes;
    procedure Execute; override;
  end;

procedure THeadThread.Execute;
begin
  try
    SetGivenTables(given);
    head := HeadBytes(j);
  except
    head := nil;
  end;
  ReleaseThreadModels;
end;

{ HeadBytes(j) started on a thread of its own; nil (the caller runs it
  itself) with one thread, little raw, or no thread to be had }
function StartHead(const j: TJpeg; threads: Integer): THeadThread;
begin
  Result := nil;
  if (threads <= 1) or (Length(j.raw) < HELPER_RAW) then Exit;
  try
    Result := THeadThread.Create(True);
  except
    Exit(nil);
  end;
  Result.FreeOnTerminate := False;
  Result.j := j;
  Result.j.scans := Copy(j.scans);
  Result.given := GetGivenTables;
  try
    Result.Start;
  except
    Result.Free;
    Result := nil;
  end;
end;

{ What StartHead's thread made (and the thread freed), or HeadBytes(j) here
  when it had none }
function FinishHead(var t: THeadThread; const j: TJpeg): TBytes;
begin
  if t = nil then Exit(HeadBytes(j));
  t.Join;
  Result := t.head;
  t.Free;
  t := nil;
  { a helper that failed (no memory): here, as without it }
  if Result = nil then Result := HeadBytes(j);
end;

{ ---------- reading a stream ---------- }

type
  { What the header stream says: the file's headers, and how its bands are
    coded. }
  THead = record
    j: TJpeg;
    jl: TJls;
    isLs, symbols: Boolean;
    nb: Integer;
  end;
  TRange = record first, last: Int64; end;

function DecodeHead(const head: TBytes; maxRaw: SizeInt; out h: THead): TCodecResult;
var cd: TCoder; raw: TBytes;
begin
  h := Default(THead);
  Result := CodecFail(ceOk);
  cd.InitDecoder(head, 0);
  raw := nil;
  if not CodeRaw(cd, raw, maxRaw) then Exit(CodecFail(ceTooLarge));
  h.isLs := IsJls(raw);
  if h.isLs then begin
    Result.jpeg := ParseJlsHeaders(raw, h.jl);
    if not Result.jpeg.Ok then begin Result.err := ceBadStream; Exit; end;
    h.symbols := cd.Direct(0, 1) = 1;
    if h.symbols then h.nb := 1
    else begin
      if not CodeJlsRuns(cd, h.jl, 1 shl 26) then Exit(CodecFail(ceBadStream));
      h.nb := JlsBandCount(h.jl);
    end;
  end else begin
    Result.jpeg := ParseHeaders(raw, h.j);
    if not Result.jpeg.Ok then begin Result.err := ceBadStream; Exit; end;
    CodeScanBits(cd, h.j);
    if h.j.lossless then begin
      LosslessView(h.j, h.jl);
      h.nb := JlsBandCount(h.jl);
    end else h.nb := BandCount(h.j);
  end;
end;

{ Where each of the nb bands lies in the stream, the header stream being
  `first` bytes from its start. False if the lengths do not fit. }
function BandRanges(const stream: TBytes; first: Int64; nb: Integer; out r: array of TRange): Boolean;
var b: Integer; p, len: Int64;
begin
  p := first;
  for b := 0 to nb - 1 do begin
    if b < nb - 1 then begin
      if p + 4 > Length(stream) then Exit(False);
      len := GetU32(stream, p); Inc(p, 4);
      if p + len > Length(stream) then Exit(False);
    end else len := Length(stream) - p;
    r[b].first := p; r[b].last := p + len;
    Inc(p, len);
  end;
  Result := True;
end;

{ JPEG-LS: one model's header stream: the raw bytes, which model, and the
  samples model's run lengths. Always on the caller's thread: CodeRaw reads
  its threadvars (the raw tables, the tables a library host gave). }
function JlsHead(var jl: TJls; model: Integer): TBytes;
var cd: TCoder;
begin
  cd.InitEncoder;
  CodeRaw(cd, jl.raw, MaxInt);
  cd.Direct(Cardinal(model), 1);
  if model = 0 then CodeJlsRuns(cd, jl, MaxInt);
  Result := cd.enc.Finish;
end;

type
  TBandJobs = array of TBandJob;

  { One model's bands (RunBands) on a thread of its own, while the caller
    codes the other model. }
  TBandsThread = class(TJoinThread)
    jobs: ^TBandJobs;
    threads: Integer;
    procedure Execute; override;
  end;

procedure TBandsThread.Execute;
begin
  try
    RunBands(jobs^, threads);
  except
    { a job that did not run is not ok, and its model is left out }
  end;
  ReleaseThreadModels;
end;

{ A JPEG-LS file's symbol stream checked as it was written: its framing
  read back with Decompress's own BandRanges, and the samples its reader
  decoded (into h, from the header stream as Decompress reads it) rebuilt
  into a file that has to be the input. }
function JlsLiveChecked(const jpeg, stream, head: TBytes; const enc, rd: TBandJob; const h: THead): Boolean;
var r: array of TRange; back: TBytes;
begin
  Result := False;
  if not enc.ok or not rd.ok then Exit;
  if (Length(stream) < STREAM_HEADER + Length(head)) or (stream[0] <> STREAM_VERSION) or (stream[1] <> 0) or
     (GetU32(stream, 2) <> Cardinal(Length(head))) or
     ((Length(head) > 0) and not CompareMem(@stream[STREAM_HEADER], @head[0], Length(head))) then Exit;
  r := nil; SetLength(r, 1);
  if not BandRanges(stream, STREAM_HEADER + Length(head), 1, r) then Exit;
  if (r[0].last - r[0].first <> Length(enc.output)) or
     ((Length(enc.output) > 0) and not CompareMem(@stream[r[0].first], @enc.output[0], Length(enc.output))) then Exit;
  if not RecomposeJls(h.jl, back).Ok or (Length(back) <> Length(jpeg)) or
     ((Length(back) > 0) and not CompareMem(@back[0], @jpeg[0], Length(back))) then Exit;
  Result := True;
end;

{ JPEG-LS: the stream with each model, the smaller one kept (the samples
  model on a tie). Both are exact; which one wins depends on the file (the
  symbols win on near-lossless, the samples on most lossless photos).

  With two threads or more and verify, the symbol stream is decoded while
  it is written (as CompressLive does a JPEG's bands), into a second copy
  of the samples built from its header stream as Decompress builds it.
  `checked`: that check passed and the stream kept is that one, so it need
  not be decompressed again (the symbols won on every photo measured).
  The samples model's bands run on a thread of their own next to the
  symbol stream when a thread is left for them (three or more, or two
  without verify), else after it. }
function AssembleJls(var jl: TJls; threads: Integer; out stream: TBytes; const jpeg: TBytes;
                     verify: Boolean; out checked: Boolean): Boolean;
var head0, head1, s0, s1: TBytes; jobs0, jobs1: TBandJobs; rd: TBandJob; nb, b, t0: Integer;
    ok0, ok1, live: Boolean; h: THead; th: TBandsThread; dt: TBandThread;
begin
  stream := nil; checked := False;
  head0 := JlsHead(jl, 0);
  head1 := JlsHead(jl, 1);
  nb := JlsBandCount(jl);
  jobs0 := nil; SetLength(jobs0, nb);
  for b := 0 to nb - 1 do begin
    jobs0[b] := Default(TBandJob);
    jobs0[b].jl := @jl; jobs0[b].band := b; jobs0[b].encoding := True;
  end;
  jobs1 := nil; SetLength(jobs1, 1);
  jobs1[0] := Default(TBandJob);
  jobs1[0].jl := @jl; jobs1[0].symbols := True; jobs1[0].encoding := True;
  live := False;
  rd := Default(TBandJob);
  h := Default(THead);
  if threads < 2 then begin
    RunBands(jobs0, threads);
    RunBand(jobs1[0]);
  end else begin
    { the live check: the symbol stream's reader on a thread of its own,
      into h (maxRaw: the input's size, as Decompress is given it) }
    if verify then begin
      live := DecodeHead(head1, Length(jpeg), h).Ok and h.isLs and h.symbols and (h.nb = 1);
      if live then begin
        jobs1[0].live := TLiveStream.Create;
        rd.jl := @h.jl; rd.symbols := True; rd.encoding := False; rd.live := jobs1[0].live;
      end;
    end;
    { the samples model: on the threads the symbol stream leaves, or, with
      none left (two threads and the check), after it on all of them }
    t0 := threads - 1;
    if live then Dec(t0);
    th := nil;
    if t0 >= 1 then
      try
        th := TBandsThread.Create(True);
      except
        th := nil;
      end;
    try
      if th <> nil then begin
        th.jobs := @jobs0; th.threads := t0; th.FreeOnTerminate := False;
        th.Start;
      end;
      dt := nil;
      if live then begin
        dt := NewBandThread(@rd);
        if dt <> nil then dt.Start;
      end;
      RunBand(jobs1[0]);
      { no thread for the reader: it reads here (a live stream keeps all it
        is given) }
      if live and (dt = nil) then RunBand(rd);
      if dt <> nil then begin dt.Join; dt.Free; end;
      if th = nil then RunBands(jobs0, threads);
    finally
      { waited for in any case, never left on jobs about to be freed }
      if th <> nil then begin th.Join; th.Free; end;
    end;
  end;
  try
    { a model that cannot code this file leaves the other }
    ok0 := Build(head0, jobs0, s0);
    ok1 := Build(head1, jobs1, s1);
    if ok0 then stream := s0;
    if ok1 and ((stream = nil) or (Length(s1) < Length(stream))) then begin
      stream := s1;
      checked := live and JlsLiveChecked(jpeg, s1, head1, jobs1[0], rd, h);
    end;
  finally
    if live then jobs1[0].live.Free;
  end;
  Result := stream <> nil;
end;

{ A JPEG compressed and verified at once: each band is decoded by a second
  thread while its encoder is still writing it (pjaarith.TLiveStream), into
  a second copy of the coefficients built from the header stream as
  Decompress builds it. Then the stream's framing is read back with
  Decompress's own BandRanges, and the copy is rebuilt into a JPEG that has
  to be the input. The same checks as compressing and then decompressing,
  in about the time of one of them. }
function CompressLive(const jpeg: TBytes; var j: TJpeg; const ownHead: TBytes; threads: Integer;
                      model: TModelKind; out stream: TBytes): Boolean;
var h: THead; nb, b, i, k, pairs, next, made: Integer; enc, dec: array of TBandJob; r: array of TRange;
    pool: array of TBandThread; back, head: TBytes; cr: TCodecResult; all, headOk, first: Boolean;
begin
  stream := nil;
  Result := False;
  nb := BandCount(j);
  enc := nil; dec := nil;
  SetLength(enc, nb); SetLength(dec, nb);
  for b := 0 to nb - 1 do begin
    enc[b] := Default(TBandJob);
    enc[b].j := @j; enc[b].band := b; enc[b].encoding := True; enc[b].model := model;
    enc[b].live := TLiveStream.Create;
    dec[b] := Default(TBandJob);
    dec[b].j := @h.j; dec[b].band := b; dec[b].encoding := False; dec[b].model := model;
    dec[b].live := enc[b].live;
  end;
  try
    { each band takes two threads, both running: the reader waits for the
      writer }
    pairs := threads div 2;
    if pairs < 1 then pairs := 1;
    next := 0;
    first := True;
    while next < nb do begin
      k := nb - next;
      if k > pairs then k := pairs;
      pool := nil;
      SetLength(pool, 2 * k);
      made := 0;
      while made < Length(pool) do begin
        if made mod 2 = 0 then pool[made] := NewBandThread(@enc[next + made div 2])
        else pool[made] := NewBandThread(@dec[next + made div 2]);
        if pool[made] = nil then Break;
        Inc(made);
      end;
      all := made = Length(pool);
      { the encoders first: they need only j }
      if all then for i := 0 to k - 1 do pool[2 * i].Start;
      if first then begin
        first := False;
        { meanwhile, here: the header stream, and the readers' headers from
          it as Decompress gets them (maxRaw: the input's own size, as
          Decompress is given it, never a cap below what CodeRaw took) }
        headOk := False;
        try
          if Length(ownHead) > 0 then head := ownHead else head := HeadBytes(j);
          cr := DecodeHead(head, Length(jpeg), h);
          headOk := cr.Ok and not h.isLs and (h.nb = nb);
        except
          headOk := False;
        end;
        if not headOk then begin
          { no reader can start: the encoders running end on their own (a
            live stream keeps all it is given), and are waited for }
          if all then for i := 0 to k - 1 do pool[2 * i].Join;
          for i := 0 to made - 1 do pool[i].Free;
          Exit;
        end;
      end;
      if all then begin
        for i := 0 to k - 1 do pool[2 * i + 1].Start;
        for i := 0 to High(pool) do begin pool[i].Join; pool[i].Free; end;
      end else begin
        { not every thread was had: none started, those made let go, and
          each band here, its encoder and then its reader (a live stream
          keeps all it is given) }
        for i := 0 to made - 1 do pool[i].Free;
        for i := 0 to k - 1 do begin RunBand(enc[next + i]); RunBand(dec[next + i]); end;
      end;
      Inc(next, k);
    end;
    for b := 0 to nb - 1 do
      if not enc[b].ok or not dec[b].ok then Exit;
    if not Build(head, enc, stream) then Exit;
    { the framing, read back the way Decompress reads it }
    if (Length(stream) < STREAM_HEADER + Length(head)) or (stream[0] <> StreamVersionOf(model)) or
       (stream[1] <> Ord(model = mkFast)) or (GetU32(stream, 2) <> Cardinal(Length(head))) or
       ((Length(head) > 0) and not CompareMem(@stream[STREAM_HEADER], @head[0], Length(head))) then Exit;
    r := nil; SetLength(r, nb);
    if not BandRanges(stream, STREAM_HEADER + Length(head), nb, r) then Exit;
    for b := 0 to nb - 1 do
      if (r[b].last - r[b].first <> Length(enc[b].output)) or
         ((Length(enc[b].output) > 0) and not CompareMem(@stream[r[b].first], @enc[b].output[0], Length(enc[b].output))) then
        Exit;
    cr.jpeg := Recompose(h.j, back, Length(jpeg));
    if not cr.jpeg.Ok or (Length(back) <> Length(jpeg)) or
       ((Length(back) > 0) and not CompareMem(@back[0], @jpeg[0], Length(back))) then Exit;
    Result := True;
  finally
    for b := 0 to nb - 1 do enc[b].live.Free;
    if not Result then stream := nil;
  end;
end;

{ With verify: the stream decompressed (maxRaw the input's size, as every
  decoder is given it) and compared with the input; a difference is a bug,
  and nothing is handed out }
function VerifyStream(const jpeg: TBytes; var stream: TBytes; verify: Boolean; threads: Integer): TCodecResult;
var r: TCodecResult; back: TBytes; was: TStage;
begin
  Result := CodecFail(ceOk);
  if not verify then Exit;
  { --stats: the time it takes, apart (pjastage) }
  was := StageEnter(stVerify);
  r := Decompress(stream, back, Length(jpeg), threads);
  StageEnter(was);
  if not r.Ok or (Length(back) <> Length(jpeg)) or
     ((Length(back) > 0) and not CompareMem(@back[0], @jpeg[0], Length(back))) then begin
    stream := nil;
    Result := CodecFail(ceNoRoundTrip);
  end;
end;

{ A JPEG (j: what VerifyRoundTrip made of it) -> its version 5 stream }
function CompressJpeg(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; verify: Boolean; threads: Integer;
                      model: TModelKind; const ownHead: TBytes = nil): TCodecResult; forward;

function CompressOne(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                     model: TModelKind): TCodecResult;
var j: TJpeg; jl: TJls; checked: Boolean;
begin
  stream := nil;
  Result := CodecFail(ceOk);
  StageEnter(stParse);
  if IsJls(jpeg) then begin
    Result.jpeg := VerifyJls(jpeg, jl);
    StageEnter(stEncode);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    if not AssembleJls(jl, threads, stream, jpeg, verify, checked) then Exit(CodecFail(ceNoRoundTrip));
    if not checked then Result := VerifyStream(jpeg, stream, verify, threads);
  end else begin
    Result.jpeg := VerifyRoundTrip(jpeg, j);
    StageEnter(stEncode);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    { a scan without its restarts needs version 6, which says so }
    if HasIgnoredRestarts(j) then begin
      Result.err := ceJpeg; Result.jpeg.err := jeBadRst;
      Exit;
    end;
    { and so does a scan with another correction bits' limit: version 5
      rebuilds libjpeg's }
    if HasCorrectionLimits(j) then begin
      Result.err := ceJpeg; Result.jpeg.err := jeNoRoundTrip;
      Exit;
    end;
    Result := CompressJpeg(jpeg, j, stream, verify, threads, model);
  end;
end;

function CompressVerified(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; threads: Integer;
                          v7: Boolean): TCodecResult;
begin
  stream := nil;
  { what CompressOne refuses for version 5 }
  if HasIgnoredRestarts(j) then begin
    Result := CodecFail(ceJpeg); Result.jpeg.err := jeBadRst;
    Exit;
  end;
  if HasCorrectionLimits(j) then begin
    Result := CodecFail(ceJpeg); Result.jpeg.err := jeNoRoundTrip;
    Exit;
  end;
  { v7: the plugin's pja7, version 7's coefficients }
  if v7 then Result := CompressJpeg(jpeg, j, stream, False, threads, mkV7)
  else Result := CompressJpeg(jpeg, j, stream, False, threads, mkFull);
end;

function CompressJpeg(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; verify: Boolean; threads: Integer;
                      model: TModelKind; const ownHead: TBytes): TCodecResult;
var jl: TJls; head: TBytes; jobs: array of TBandJob; nb, b: Integer;
begin
  stream := nil;
  Result := CodecFail(ceOk);
  jobs := nil;
  begin
    { ownHead: another file's header stream with these bands (a host's,
      whose bands are the file's), verified elsewhere; or this file's own,
      HeadBytes(j), already coded by CompressAt to weigh the parts }
    if not j.lossless and verify and (threads >= 2) then begin
      { the header stream made there, while the first bands' encoders run }
      if not CompressLive(jpeg, j, ownHead, threads, model, stream) then Exit(CodecFail(ceNoRoundTrip));
      Exit;
    end;
    if Length(ownHead) > 0 then head := ownHead else head := HeadBytes(j);
    if j.lossless then begin
      { the samples of a lossless JPEG: JPEG-LS's samples model }
      LosslessView(j, jl);
      nb := JlsBandCount(jl);
      SetLength(jobs, nb);
      for b := 0 to nb - 1 do begin
        jobs[b] := Default(TBandJob);
        jobs[b].jl := @jl; jobs[b].band := b; jobs[b].encoding := True;
      end;
    end else begin
      nb := BandCount(j);
      SetLength(jobs, nb);
      for b := 0 to nb - 1 do begin
        jobs[b] := Default(TBandJob);
        jobs[b].j := @j; jobs[b].band := b; jobs[b].encoding := True; jobs[b].model := model;
      end;
    end;
    if not Assemble(head, jobs, threads, stream) then Exit(CodecFail(ceNoRoundTrip));
  end;
  Result := VerifyStream(jpeg, stream, verify, threads);
end;

function StreamHeaders(const stream: TBytes; out j: TJpeg; maxRaw: SizeInt): TCodecResult;
var h: THead; len: Int64;
begin
  j := Default(TJpeg);
  if (Length(stream) < STREAM_HEADER) or not (((stream[0] = STREAM_VERSION) and (stream[1] <= 1)) or
     ((stream[0] = STREAM_V7) and (stream[1] = 0))) then
    Exit(CodecFail(ceBadStream));
  len := GetU32(stream, 2);
  if STREAM_HEADER + len > Length(stream) then Exit(CodecFail(ceBadStream));
  Result := DecodeHead(Copy(stream, STREAM_HEADER, len), maxRaw, h);
  if not Result.Ok then Exit;
  if h.isLs then Exit(CodecFail(ceBadStream));
  j := h.j;
end;

function StreamJlsHeaders(const stream: TBytes; out jl: TJls; out symbols: Boolean; maxRaw: SizeInt): TCodecResult;
var h: THead; len: Int64;
begin
  jl := Default(TJls); symbols := False;
  if (Length(stream) < STREAM_HEADER) or (stream[0] <> STREAM_VERSION) or (stream[1] > 1) then
    Exit(CodecFail(ceBadStream));
  len := GetU32(stream, 2);
  if STREAM_HEADER + len > Length(stream) then Exit(CodecFail(ceBadStream));
  Result := DecodeHead(Copy(stream, STREAM_HEADER, len), maxRaw, h);
  if not Result.Ok then Exit;
  if not h.isLs then Exit(CodecFail(ceBadStream));
  jl := h.jl; symbols := h.symbols;
end;

function DecompressOne(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                       expected: SizeInt; const quirks: TQuirks): TCodecResult;
var h: THead; jobs: array of TBandJob; r: array of TRange; b: Integer; len: Int64; model: TModelKind;
begin
  jpeg := nil;
  Result := CodecFail(ceOk);
  if Length(stream) < STREAM_HEADER then Exit(CodecFail(ceBadStream));
  if stream[0] = STREAM_V7 then begin
    { version 7: no model byte, and a program without pjav7 cannot read it }
    if stream[1] <> 0 then Exit(CodecFail(ceBadStream));
    if V7Code = nil then Exit(CodecFail(ceFutureVersion));
    model := mkV7;
  end else begin
    if (stream[0] <> STREAM_VERSION) or (stream[1] > 1) then Exit(CodecFail(ceBadStream));
    if stream[1] = 1 then model := mkFast else model := mkFull;
  end;
  len := GetU32(stream, 2);
  if STREAM_HEADER + len > Length(stream) then Exit(CodecFail(ceBadStream));
  Result := DecodeHead(Copy(stream, STREAM_HEADER, len), maxRaw, h);
  if not Result.Ok then Exit;
  { the fast model and version 7's are for a JPEG's coefficients only }
  if (h.isLs or h.j.lossless) and (model <> mkFull) then Exit(CodecFail(ceBadStream));
  { the scans that ignore the DRI in force (version 6 says which): only
    sequential Huffman or lossless ones, as Decompose finds them }
  for b := 0 to High(quirks.ri) do begin
    if h.isLs or h.j.progressive or h.j.arithmetic or (quirks.ri[b] > High(h.j.scans)) or
       (h.j.scans[quirks.ri[b]].ri = 0) then Exit(CodecFail(ceBadStream));
    h.j.scans[quirks.ri[b]].ri := 0; h.j.scans[quirks.ri[b]].ignoreRi := True;
  end;
  { the correction bits' limits: progressive Huffman AC refinement scans }
  for b := 0 to High(quirks.be) do begin
    if h.isLs or not h.j.progressive or h.j.arithmetic or (quirks.be[b] > High(h.j.scans)) then
      Exit(CodecFail(ceBadStream));
    with h.j.scans[quirks.be[b]] do begin
      if (ah = 0) or (ss = 0) then Exit(CodecFail(ceBadStream));
      maxBe := quirks.beMax[b];
    end;
  end;
  r := nil; SetLength(r, h.nb);
  if not BandRanges(stream, STREAM_HEADER + len, h.nb, r) then Exit(CodecFail(ceBadStream));
  jobs := nil; SetLength(jobs, h.nb);
  for b := 0 to h.nb - 1 do begin
    jobs[b] := Default(TBandJob);
    if h.isLs or h.j.lossless then jobs[b].jl := @h.jl else jobs[b].j := @h.j;
    jobs[b].symbols := h.symbols; jobs[b].model := model;
    jobs[b].band := b; jobs[b].encoding := False; jobs[b].input := stream;
    jobs[b].first := r[b].first; jobs[b].last := r[b].last;
  end;
  RunBands(jobs, threads);
  for b := 0 to h.nb - 1 do
    if not jobs[b].ok then Exit(CodecFail(ceBadStream));
  if h.isLs then Result.jpeg := RecomposeJls(h.jl, jpeg) else Result.jpeg := Recompose(h.j, jpeg, expected);
  if not Result.jpeg.Ok then begin jpeg := nil; Result.err := ceBadStream; end;
end;

{ ---------- version 6: JPEGs inside a JPEG, encoder quirks, bytes ----------

    byte 0          STREAM_PARTS
    byte 1          flags: bit 0 QUIRKS; bit 1 BYTES, alone; bit 2 CORRECTION;
                    bit 3 PATCH, alone
  BYTES: the rest is the whole file through the raw bytes' model
  (CodeRaw): a file that starts like a JPEG and that PJA takes no other
  way.
  PATCH (since 0.5.0, the top only): a JPEG with an encoder's slips that
  PJA repairs before compressing it (RepairJpeg: restarts numbered wrong,
  bytes between a scan and the next marker), and the repairs undone:
    4 bytes (LE)    E, 1 to MAX_EDITS
    E edits         ascending and apart, each where it is in the repaired
                    file (u32), how many of its bytes go (u32), how many
                    take their place (u32), and those bytes
    the rest        the repaired file's stream: version 5, 6 (not PATCH
                    nor BYTES) or 7
  Otherwise:
    4 bytes (LE)    K, the parts: 0 to MAX_PARTS (0 only with QUIRKS or
                    CORRECTION)
    K x 13 bytes    each part: where it is in the file (u32), its length
                    there (u32), its stream's length (u32), and its mode:
                    bit 0, how the host keeps its place (0 = cut out,
                    1 = zeros); bit 1, a copy of an earlier part (cameras
                    write the same thumbnail twice), whose number then
                    stands in place of the stream's length
    QUIRKS:         4 bytes (LE) Q, 1 to MAX_QUIRK_SCANS; then Q x 4 bytes,
                    ascending: the host's scans whose DRI is in force but
                    that have no restart markers (pjajpeg TScan.ignoreRi),
                    which the raw bytes cannot tell
    CORRECTION:     4 bytes (LE) C, 1 to MAX_QUIRK_SCANS; then C x 8 bytes,
                    ascending scans: the scan (u32) and how many correction
                    bits its EOB runs hold before the encoder ends them
                    (u32, pjajpeg TScan.maxBe; never libjpeg's 937): AC
                    refinement scans of an encoder such as Photoshop
    the K streams   each of a JPEG, version 5 or itself with parts (none
                    for a copy)
    the rest        the host, version 5: the file with the parts cut out or
                    zeroed (the file itself with none)

  A part inside one of the host's segments (a thumbnail in an APP1) is
  zeroed, so the host's markers still add up; one past the host's EOI (an
  MPO's next image) is cut out. }

const
  MAX_PARTS = 256;
  PART_ENTRY = 13;
  { a part's own parts are looked for, theirs not: an MPO's second image
    and its thumbnail }
  MAX_PART_DEPTH = 2;
  PART_ZEROS = 1;
  PART_COPY = 2;
  FLAG_QUIRKS = 1;
  FLAG_BYTES = 2;
  FLAG_CORRECTION = 4;
  FLAG_PATCH = 8;
  MAX_EDITS = 4096;
  { RepairJpeg's tries: one repair each, then the file parsed again }
  MAX_REPAIRS = 64;
  { and a cut scan's: each RST its filler needs is one more }
  MAX_FILL_TRIES = 4096;
  MAX_QUIRK_SCANS = 256;

type
  TPart = record
    off, len: Int64;
    mode: Byte;
    copyOf: Integer;
    stream: TBytes;
  end;

{ The scans with a DRI in force and no restarts, and those whose EOB runs
  hold another number of correction bits than libjpeg's }
function QuirkScans(const j: TJpeg): TQuirks;
var i, n, m: Integer;
begin
  Result := Default(TQuirks); n := 0; m := 0;
  for i := 0 to High(j.scans) do begin
    if j.scans[i].ignoreRi then begin SetLength(Result.ri, n + 1); Result.ri[n] := i; Inc(n); end;
    if j.scans[i].maxBe <> LIBJPEG_MAX_BE then begin
      SetLength(Result.be, m + 1); SetLength(Result.beMax, m + 1);
      Result.be[m] := i; Result.beMax[m] := j.scans[i].maxBe; Inc(m);
    end;
  end;
end;

function NoQuirks(const q: TQuirks): Boolean;
begin Result := (q.ri = nil) and (q.be = nil); end;

{ what they take in the stream }
function QuirkBytes(const q: TQuirks): Integer;
begin
  Result := 0;
  if q.ri <> nil then Inc(Result, 4 + 4 * Length(q.ri));
  if q.be <> nil then Inc(Result, 4 + 8 * Length(q.be));
end;

function SameScans(const a, b: TScanList): Boolean;
var i: Integer;
begin
  Result := Length(a) = Length(b);
  if Result then for i := 0 to High(a) do if a[i] <> b[i] then Exit(False);
end;

function SameQuirks(const a, b: TQuirks): Boolean;
begin Result := SameScans(a.ri, b.ri) and SameScans(a.be, b.be) and SameScans(a.beMax, b.beMax); end;

function DecompressAt(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                      expected: SizeInt; depth: Integer): TCodecResult; forward;

{ The file and its version 6 stream decompressed: the same bytes }
function SameAfter(const jpeg, stream: TBytes; threads, depth: Integer): Boolean;
var back: TBytes; was: TStage;
begin
  was := StageEnter(stVerify);
  { maxRaw as every caller gives it: the original's exact size }
  Result := DecompressAt(stream, back, Length(jpeg), threads, Length(jpeg), depth).Ok and (Length(back) = Length(jpeg)) and
            ((Length(back) = 0) or CompareMem(@back[0], @jpeg[0], Length(back)));
  StageEnter(was);
end;

function CompressAt(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                    model: TModelKind; depth: Integer; huffOnly: Boolean = False): TCodecResult;
var j, sj, hj: TJpeg; parts: array of TPart; k, len, p, from, nextFF: SizeInt; n, i, c: Integer;
    sub, ps, host, hs, hostHead, ownJ: TBytes; ok, fit, needOwn: Boolean; whole, withParts, without: Int64;
    quirks: TQuirks; helper: THeadThread;
begin
  stream := nil;
  { huffOnly (the zpaq-std plugin's pjax): Huffman JPEGs and parts of one
    level, version 5 each, what its ZPAQL decodes }
  if huffOnly and (IsJls(jpeg) or (Length(jpeg) >= High(Cardinal))) then begin
    Result := CodecFail(ceJpeg); Result.jpeg.err := jeUnsupported; Exit;
  end;
  if (depth >= MAX_PART_DEPTH) or IsJls(jpeg) or (Length(jpeg) >= High(Cardinal)) then
    Exit(CompressOne(jpeg, stream, verify, threads, model));
  { the file as PJA takes it today, decoded once: it gives the parts' places
    and, with none, the stream itself }
  Result := CodecFail(ceOk);
  StageEnter(stParse);
  Result.jpeg := VerifyRoundTrip(jpeg, j);
  StageEnter(stEncode);
  if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
  { pjax's ZPAQL knows the DRI's quirk, not the correction bits' }
  if huffOnly and (j.arithmetic or j.lossless or HasCorrectionLimits(j)) then begin
    Result.err := ceJpeg; Result.jpeg.err := jeUnsupported; Exit;
  end;
  quirks := QuirkScans(j);
  { every FF D8 FF that starts a JPEG PJA takes; none can be inside
    entropy-coded data, where FF is followed by 00 or a restart marker }
  parts := nil; n := 0;
  k := 2;
  while (k + 3 <= Length(jpeg)) and (n < MAX_PARTS) do begin
    { straight to the next FF (IndexByte: the RTL's vector search) }
    if jpeg[k] <> $FF then begin
      nextFF := IndexByte(jpeg[k], Length(jpeg) - 2 - k, $FF);
      if nextFF < 0 then Break;
      Inc(k, nextFF);
    end;
    ok := False;
    if (jpeg[k] = $FF) and (jpeg[k + 1] = $D8) and (jpeg[k + 2] = $FF) and
       Decompose(Copy(jpeg, k, Length(jpeg) - k), sj).Ok then begin
      len := sj.eoi;
      fit := not huffOnly or not (sj.arithmetic or sj.lossless);
      sj := Default(TJpeg);
      { wholly inside the host's segments or wholly after its end }
      if fit and ((k >= j.eoi) or (k + len <= j.eoi)) then begin
        { the same bytes as an earlier part: a copy of it }
        c := -1;
        for i := 0 to n - 1 do
          if (c < 0) and (parts[i].len = len) and CompareMem(@jpeg[parts[i].off], @jpeg[k], len) then c := i;
        ps := nil;
        if c < 0 then begin
          sub := Copy(jpeg, k, len);
          if huffOnly then ok := CompressOne(sub, ps, False, threads, model).Ok
          else ok := CompressAt(sub, ps, False, threads, model, depth + 1).Ok;
          if not ok or (Length(ps) + PART_ENTRY >= len) then ps := nil;
          ok := False;
        end;
        if (c >= 0) or (ps <> nil) then begin
          SetLength(parts, n + 1);
          parts[n].off := k; parts[n].len := len; parts[n].stream := ps; parts[n].copyOf := c;
          parts[n].mode := 0;
          if k < j.eoi then parts[n].mode := PART_ZEROS;
          if c >= 0 then parts[n].mode := parts[n].mode or PART_COPY;
          Inc(n);
          Inc(k, len);
          ok := True;
        end;
      end;
    end;
    if not ok then Inc(k);
  end;
  hostHead := nil; ownJ := nil; helper := nil;
  { the parts pay or not by the file's own header stream against the
    host's: with the file's raw bytes large and threads to spare, the
    file's on a thread of its own while the host's is made here }
  whole := 0;
  for i := 0 to n - 1 do Inc(whole, parts[i].len);
  needOwn := (n > 0) and ((whole * 4 < Length(jpeg)) or (Length(jpeg) < 1 shl 20));
  if needOwn then helper := StartHead(j, threads);
  try
    if n > 0 then begin
      { the host }
      host := nil; SetLength(host, Length(jpeg));
      p := 0; from := 0;
      for i := 0 to n - 1 do begin
        if parts[i].off > from then Move(jpeg[from], host[p], parts[i].off - from);
        Inc(p, parts[i].off - from);
        if parts[i].mode and PART_ZEROS <> 0 then begin FillChar(host[p], parts[i].len, 0); Inc(p, parts[i].len); end;
        from := parts[i].off + parts[i].len;
      end;
      if from < Length(jpeg) then begin Move(jpeg[from], host[p], Length(jpeg) - from); Inc(p, Length(jpeg) - from); end;
      SetLength(host, p);
      { a host PJA does not take as the file (a part that was not where it
        seemed) leaves the file whole }
      if VerifyRoundTripFrom(host, j, jpeg, hj).Ok and SameQuirks(QuirkScans(hj), quirks) then hostHead := HeadBytes(hj)
      else n := 0;
      hj := Default(TJpeg);
    end;
    if n > 0 then begin
      { the bands come after the header stream either way: the parts go only
        if what comes before is smaller with them. Small parts have to win
        (two copies of a thumbnail cost the raw bytes' model little, and a
        small file pays the parts' framing). In a file of 1 MB or more whose
        parts are a quarter of it (an MPO's images) they always win, and its
        raw bytes would take long to code only to see it }
      if needOwn then begin
        withParts := 6 + PART_ENTRY * n + STREAM_HEADER + Length(hostHead);
        for i := 0 to n - 1 do Inc(withParts, Length(parts[i].stream));
        ownJ := FinishHead(helper, j);
        without := STREAM_HEADER + Length(ownJ);
        if not NoQuirks(quirks) then without := without + 6;
        if withParts >= without then n := 0;
      end;
    end;
  finally
    { a helper not waited for above (no host after all, an exception): its
      header stream is the file's all the same }
    if helper <> nil then begin
      helper.Join;
      if ownJ = nil then ownJ := helper.head;
      helper.Free;
    end;
  end;
  { with no parts, the file's own header stream, when it was made above:
    the same bytes CompressJpeg would make }
  if (n = 0) and NoQuirks(quirks) then Exit(CompressJpeg(jpeg, j, stream, verify, threads, model, ownJ));
  { the host's stream: its header stream and the bands, coded once from the
    file, whose bands they are; the file's own with no parts }
  if n > 0 then Result := CompressJpeg(jpeg, j, hs, False, threads, model, hostHead)
  else Result := CompressJpeg(jpeg, j, hs, False, threads, model, ownJ);
  if not Result.Ok then Exit;
  len := 6 + PART_ENTRY * n + Length(hs);
  for i := 0 to n - 1 do Inc(len, Length(parts[i].stream));
  Inc(len, QuirkBytes(quirks));
  SetLength(stream, len);
  stream[0] := STREAM_PARTS; stream[1] := 0;
  if quirks.ri <> nil then stream[1] := FLAG_QUIRKS;
  if quirks.be <> nil then stream[1] := stream[1] or FLAG_CORRECTION;
  p := 2; PutU32(stream, p, n);
  for i := 0 to n - 1 do begin
    PutU32(stream, p, Cardinal(parts[i].off)); PutU32(stream, p, Cardinal(parts[i].len));
    if parts[i].mode and PART_COPY <> 0 then PutU32(stream, p, parts[i].copyOf)
    else PutU32(stream, p, Length(parts[i].stream));
    stream[p] := parts[i].mode; Inc(p);
  end;
  if quirks.ri <> nil then begin
    PutU32(stream, p, Length(quirks.ri));
    for i := 0 to High(quirks.ri) do PutU32(stream, p, quirks.ri[i]);
  end;
  if quirks.be <> nil then begin
    PutU32(stream, p, Length(quirks.be));
    for i := 0 to High(quirks.be) do begin PutU32(stream, p, quirks.be[i]); PutU32(stream, p, quirks.beMax[i]); end;
  end;
  for i := 0 to n - 1 do
    if Length(parts[i].stream) > 0 then begin
      Move(parts[i].stream[0], stream[p], Length(parts[i].stream)); Inc(p, Length(parts[i].stream));
    end;
  Move(hs[0], stream[p], Length(hs));
  Result := CodecFail(ceOk);
  if verify and not SameAfter(jpeg, stream, threads, depth) then begin
    { a bug in the parts must not cost the file: without quirks it goes as
      one stream }
    if NoQuirks(quirks) then Exit(CompressJpeg(jpeg, j, stream, verify, threads, model));
    stream := nil;
    Exit(CodecFail(ceNoRoundTrip));
  end;
end;

{ A file PJA takes no other way, through the raw bytes' model }
function CompressBytes(const data: TBytes; out stream: TBytes; verify: Boolean; threads: Integer): TCodecResult;
var cd: TCoder; body, d: TBytes;
begin
  d := data;
  cd.InitEncoder;
  CodeRaw(cd, d, MaxInt);
  body := cd.enc.Finish;
  stream := nil; SetLength(stream, 2 + Length(body));
  stream[0] := STREAM_PARTS; stream[1] := FLAG_BYTES;
  Move(body[0], stream[2], Length(body));
  Result := CodecFail(ceOk);
  if verify and not SameAfter(data, stream, threads, 0) then begin
    stream := nil;
    Result := CodecFail(ceNoRoundTrip);
  end;
end;

{ how much larger than the original (n bytes) its repaired file may be: a
  cut scan's filler, at most 4 times the file and 64 KB; RepairJpeg keeps
  to it and ReadPatch holds a stream to it }
function MaxFiller(n: Int64): Int64;
begin
  Result := 4 * n + 65536;
end;

type
  { one of PATCH's edits: in the repaired file, at pos, del bytes go and
    ins takes their place }
  TEdit = record
    pos, del: SizeInt;
    ins: TBytes;
  end;
  TEdits = array of TEdit;

{ A JPEG that PJA refuses for an encoder's slip it can undo, repaired
  (fixed) and the edits that give the original back: restarts numbered
  wrong (jeBadRst at an RST: the scan's RSTs from there numbered again, the
  way T.81 counts them), bytes that are no marker between a scan and the
  next one (jeDataAfterScan: taken out), and a scan that ends before its
  last block (jeTruncated at a marker or at the end of the file: zero bits
  after it, as libjpeg reads it, and the file rebuilt). One repair at a
  time, in the order the parser meets them; False if one is not of these,
  or if the file still does not parse after MAX_REPAIRS. }
function RepairJpeg(const data: TBytes; out fixed: TBytes; out edits: TEdits): Boolean;
var j: TJpeg; r: TJpegResult; t, t2: Integer; p, q, k, start, count, after, trimmed, rst1, rst2, at: SizeInt;
    b: Byte; e: TEdit; tmp, rebuilt, filler, interval, before: TBytes; copying: Boolean;

  { how many RSTs the scan around d[q] has before q: from its SOS (inside
    entropy-coded data FF is followed by 00 or an RST only); -1 if none }
  function RstsBefore(const d: TBytes; q: SizeInt): SizeInt;
  var i, first: SizeInt;
  begin
    i := q - 1;
    while (i > 0) and not ((d[i - 1] = $FF) and (d[i] = $DA)) do Dec(i);
    if (i = 0) or (i + 2 >= Length(d)) then Exit(-1);
    first := i + 1 + (SizeInt(d[i + 1]) shl 8 or d[i + 2]);
    Result := 0;
    for i := first to q - 2 do
      if (d[i] = $FF) and (d[i + 1] >= $D0) and (d[i + 1] <= $D7) then Inc(Result);
  end;

  { fixed with the filler at p }
  function WithFiller(const f: TBytes): TBytes;
  begin
    Result := nil; SetLength(Result, Length(fixed) + Length(f));
    if p > 0 then Move(fixed[0], Result[0], p);
    if Length(f) > 0 then Move(f[0], Result[p], Length(f));
    if Length(fixed) > p then Move(fixed[p], Result[p + Length(f)], Length(fixed) - p);
  end;

  { the filler about to be given up after intervals were copied into it:
    their lengths can vary (a byte or so: not every interval is the same
    bits), so the filler as it was before the first copy, and one decode an
    interval from there, as without copying; False if there was no copy }
  function Uncopy: Boolean;
  begin
    Result := copying and (before <> nil);
    if not Result then Exit;
    filler := before; before := nil; copying := False;
    trimmed := -1; rst1 := -1; rst2 := -1;
  end;

  procedure Add(pos, del: SizeInt; const ins: TBytes);
  begin
    e.pos := pos; e.del := del; e.ins := ins;
    SetLength(edits, Length(edits) + 1);
    edits[High(edits)] := e;
    after := pos + del;
  end;

begin
  fixed := Copy(data); edits := nil; after := 0;
  Result := False;
  for t := 1 to MAX_REPAIRS do begin
    r := VerifyRoundTrip(fixed, j);
    if r.Ok then Exit(Length(edits) > 0);
    p := r.pos;
    if (p < after) or (p > Length(fixed)) or ((p + 1 >= Length(fixed)) and (r.err <> jeTruncated)) or
       (Length(edits) >= MAX_EDITS) then Exit;
    case r.err of
      jeBadRst: begin
          { an RST of another number where one was due: the scan's start
            (its SOS: inside entropy-coded data, FF is followed by 00 or
            an RST only), how many RSTs it had before, and its RSTs from
            here numbered on }
          if (fixed[p] <> $FF) or (fixed[p + 1] < $D0) or (fixed[p + 1] > $D7) then Exit;
          k := p - 1;
          while (k > 0) and not ((fixed[k - 1] = $FF) and (fixed[k] = $DA)) do Dec(k);
          if (k = 0) or (k + 2 >= Length(fixed)) then Exit;
          start := k + 1 + (SizeInt(fixed[k + 1]) shl 8 or fixed[k + 2]);
          count := 0;
          for q := start to p - 1 do
            if (fixed[q] = $FF) and (fixed[q + 1] >= $D0) and (fixed[q + 1] <= $D7) then Inc(count);
          q := p;
          while q + 1 < Length(fixed) do begin
            if fixed[q] <> $FF then begin Inc(q); Continue; end;
            b := fixed[q + 1];
            if b = $FF then begin Inc(q); Continue; end;
            if b = 0 then begin Inc(q, 2); Continue; end;
            if (b < $D0) or (b > $D7) then Break;
            if b <> $D0 + (count and 7) then begin
              if Length(edits) >= MAX_EDITS then Exit;
              Add(q + 1, 1, TBytes.Create(b));
              fixed[q + 1] := $D0 + (count and 7);
            end;
            Inc(count); Inc(q, 2);
          end;
        end;
      jeDataAfterScan: begin
          { up to the next marker: FF and neither 00 nor FF }
          q := p;
          while (q + 1 < Length(fixed)) and not ((fixed[q] = $FF) and (fixed[q + 1] <> 0) and (fixed[q + 1] <> $FF)) do
            Inc(q);
          if q + 1 >= Length(fixed) then Exit;
          Add(p, 0, Copy(fixed, p, q - p));
          Delete(fixed, p, q - p);
          after := p;
        end;
      jeTruncated: begin
          { only a scan that stops at a marker or at the end of the file
            (a download cut short); a filler after it: zero bytes until
            the scan has all its blocks, with the RSTs its DRI asks for
            where it asks for them (each found as the parser misses it),
            and what it does not read taken out again; then the file
            decoded and rebuilt: its bytes up to p and from p on must be
            the file's }
          if (p < Length(fixed)) and (fixed[p] <> $FF) then Exit;
          filler := nil; SetLength(filler, 16);
          { the length the filler was last cut to: cut to it again with
            nothing else changed, the parser goes back and forth between a
            scan cut short and data after it (a damaged file), and each
            try decodes the whole file }
          trimmed := -1;
          { where the last two RSTs went into the filler: three a period
            apart, the intervals between them are the same bytes (zeros and
            the padding found, each interval starting afresh), and the
            filler after the third gets them all at once instead of one
            decode for each padding bit and each RST }
          rst1 := -1; rst2 := -1;
          copying := True; before := nil;
          for t2 := 1 to MAX_FILL_TRIES do begin
            tmp := WithFiller(filler);
            r := Decompose(tmp, j);
            if r.Ok then Break;
            q := r.pos - p;
            if (r.err = jeDataAfterScan) and (q >= 0) and (q <= Length(filler)) then begin
              if q = trimmed then begin
                if Uncopy then Continue;
                Exit;
              end;
              SetLength(filler, q);
              trimmed := q;
              Continue;
            end;
            { the end of a restart interval in the filler: its last byte's
              last bits are the padding, which the encoder writes as 1s;
              more of them set to 1 until they agree (the filler's bits are
              anyone's) }
            if (r.err = jeInconsistentPadding) and (q >= 1) and (q <= Length(filler)) and
               (filler[q - 1] and $7F <> $7F) then begin
              b := filler[q - 1];
              filler[q - 1] := b or ((b and $7F) shl 1 or 1) and $7F;
              if filler[q - 1] = b then filler[q - 1] := b or $7F;
              trimmed := -1;
              Continue;
            end;
            if (r.err = jeBadRst) and (q >= 0) and (q < Length(filler)) then begin
              count := RstsBefore(tmp, r.pos);
              if count < 0 then begin
                if Uncopy then Continue;
                Exit;
              end;
              Insert(TBytes.Create($FF, $D0 + (count and 7)), filler, q);
              trimmed := -1;
              if copying and (rst1 >= 0) and (q - rst2 = rst2 - rst1) and (q - rst2 > 2) then begin
                if before = nil then before := Copy(filler);
                k := q - rst2;
                interval := Copy(filler, rst2 + 2, k - 2);
                at := q + 2;
                while at + k <= Length(filler) do begin
                  Inc(count);
                  Move(interval[0], filler[at], k - 2);
                  filler[at + k - 2] := $FF; filler[at + k - 1] := $D0 + (count and 7);
                  Inc(at, k);
                end;
              end;
              rst1 := rst2; rst2 := q;
              Continue;
            end;
            if (r.err <> jeTruncated) or (Length(filler) > 4 * Length(fixed) + 65536) then begin
              if Uncopy then Continue;
              Exit;
            end;
            k := Length(filler);
            SetLength(filler, 2 * k);
            FillChar(filler[k], k, 0);
          end;
          if not r.Ok then Exit;
          if not Recompose(j, rebuilt).Ok or (Length(rebuilt) < Length(fixed)) then Exit;
          k := Length(rebuilt) - Length(fixed);
          if ((p > 0) and not CompareMem(@rebuilt[0], @fixed[0], p)) or
             ((Length(fixed) > p) and not CompareMem(@rebuilt[p + k], @fixed[p], Length(fixed) - p)) then Exit;
          Add(p, k, nil);
          fixed := rebuilt;
          if Length(fixed) - Length(data) > MaxFiller(Length(data)) then Exit;
        end;
    else
      Exit;
    end;
  end;
end;

{ edits undone on the repaired file: the original, or False if they do not
  fit it or would make it larger than maxRaw }
function ApplyEdits(const fixed: TBytes; const edits: TEdits; maxRaw: SizeInt; out data: TBytes): Boolean;
var i: Integer; from, n, size: SizeInt;
begin
  data := nil;
  size := Length(fixed); from := 0;
  for i := 0 to High(edits) do begin
    if (edits[i].pos < from) or (edits[i].del > Length(fixed) - edits[i].pos) then Exit(False);
    size := size - edits[i].del + Length(edits[i].ins);
    from := edits[i].pos + edits[i].del;
  end;
  if size > maxRaw then Exit(False);
  SetLength(data, size);
  from := 0; n := 0;
  for i := 0 to High(edits) do begin
    if edits[i].pos > from then Move(fixed[from], data[n], edits[i].pos - from);
    Inc(n, edits[i].pos - from);
    if Length(edits[i].ins) > 0 then Move(edits[i].ins[0], data[n], Length(edits[i].ins));
    Inc(n, Length(edits[i].ins));
    from := edits[i].pos + edits[i].del;
  end;
  if Length(fixed) > from then Move(fixed[from], data[n], Length(fixed) - from);
  Result := True;
end;

function ReadPatch(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer): TCodecResult; forward;
type TKnown = array of TBytes;
  TCodecErrors = array of TCodecError;
function ReadJ2k(const stream: TBytes; out data: TBytes; maxRaw: SizeInt; threads: Integer;
  const known: TKnown): TCodecResult; forward;
const
  { a file's codestreams coded (and decoded) side by side when there are
    several and none is larger than this (Motion JPEG 2000's frames, JPX
    layers): a codestream's memory each at once }
  CODESTREAMS_TOGETHER = 4 shl 20;
  { and none whose SIZ declares more samples (pjaj2kcs.J2kSamplesCap):
    eight at once take about what one at the bounds does }
  SAMPLES_TOGETHER = 1 shl 22;
{ ReadJ2k's: the codestreams whose stream src[i] is not nil decoded side by
  side (each its bytes and its error) }
procedure DecodeTogether(const src: TKnown; const modes: array of Byte; const cs: TJ2kCodestreams;
  threads: Integer; out outs: TKnown; out errs: TCodecErrors); forward;

function DecompressAt(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                      expected: SizeInt; depth: Integer): TCodecResult;
var n, i, flags: Integer; p, hp, op: SizeInt; total, cut, at: Int64; parts: array of TPart; host, part: TBytes;
    k: SizeInt; quirks, none: TQuirks; cd: TCoder;
begin
  jpeg := nil;
  if Length(stream) < 1 then Exit(CodecFail(ceBadStream));
  { a version this release does not know: a later one wrote it }
  if stream[0] > STREAM_J2K then Exit(CodecFail(ceFutureVersion));
  none := Default(TQuirks);
  if (stream[0] = STREAM_VERSION) or (stream[0] = STREAM_V7) then
    Exit(DecompressOne(stream, jpeg, maxRaw, threads, expected, none));
  if stream[0] = STREAM_J2K then begin
    { a whole file: never a part }
    if depth > 0 then Exit(CodecFail(ceBadStream));
    Exit(ReadJ2k(stream, jpeg, maxRaw, threads, nil));
  end;
  if (stream[0] <> STREAM_PARTS) or (depth > MAX_PART_DEPTH) or (Length(stream) < 2) then Exit(CodecFail(ceBadStream));
  flags := stream[1];
  if flags = FLAG_BYTES then begin
    { the whole file as bytes: only at the top, a part is a JPEG }
    if depth > 0 then Exit(CodecFail(ceBadStream));
    cd.InitDecoder(Copy(stream, 2, Length(stream) - 2), 0);
    if not CodeRaw(cd, jpeg, maxRaw) then begin jpeg := nil; Exit(CodecFail(ceTooLarge)); end;
    Exit(CodecFail(ceOk));
  end;
  if flags = FLAG_PATCH then begin
    { a repaired JPEG and its edits: only at the top }
    if depth > 0 then Exit(CodecFail(ceBadStream));
    Result := ReadPatch(stream, jpeg, maxRaw, threads);
    Exit;
  end;
  if (flags and not (FLAG_QUIRKS or FLAG_CORRECTION) <> 0) or (Length(stream) < 6) then Exit(CodecFail(ceBadStream));
  if GetU32(stream, 2) > MAX_PARTS then Exit(CodecFail(ceBadStream));
  n := Integer(GetU32(stream, 2));
  if (n = 0) and (flags = 0) then Exit(CodecFail(ceBadStream));
  if 6 + Int64(PART_ENTRY) * n > Length(stream) then Exit(CodecFail(ceBadStream));
  parts := nil; SetLength(parts, n);
  p := 6; total := 0; cut := 0;
  for i := 0 to n - 1 do begin
    parts[i].off := GetU32(stream, p); parts[i].len := GetU32(stream, p + 4);
    parts[i].stream := nil; parts[i].copyOf := Integer(Min(GetU32(stream, p + 8), MAX_PARTS));
    parts[i].mode := stream[p + 12];
    Inc(p, PART_ENTRY);
    { in order, not overlapping, each a JPEG's worth, all within the cap }
    if (parts[i].len < 4) or (parts[i].mode > PART_ZEROS or PART_COPY) or
       ((i > 0) and (parts[i].off < parts[i - 1].off + parts[i - 1].len)) then Exit(CodecFail(ceBadStream));
    Inc(total, parts[i].len);
    if total > maxRaw then Exit(CodecFail(ceTooLarge));
    if parts[i].mode and PART_ZEROS = 0 then Inc(cut, parts[i].len);
  end;
  quirks := Default(TQuirks);
  if flags and FLAG_QUIRKS <> 0 then begin
    { scans in order, each one at most once }
    if p + 4 > Length(stream) then Exit(CodecFail(ceBadStream));
    k := GetU32(stream, p); Inc(p, 4);
    if (k < 1) or (k > MAX_QUIRK_SCANS) or (p + 4 * k > Length(stream)) then Exit(CodecFail(ceBadStream));
    SetLength(quirks.ri, k);
    for i := 0 to k - 1 do begin
      if GetU32(stream, p) >= MAX_QUIRK_SCANS then Exit(CodecFail(ceBadStream));
      quirks.ri[i] := Integer(GetU32(stream, p)); Inc(p, 4);
      if (i > 0) and (quirks.ri[i] <= quirks.ri[i - 1]) then Exit(CodecFail(ceBadStream));
    end;
  end;
  if flags and FLAG_CORRECTION <> 0 then begin
    { scans in order, each with its limit, never libjpeg's }
    if p + 4 > Length(stream) then Exit(CodecFail(ceBadStream));
    k := GetU32(stream, p); Inc(p, 4);
    if (k < 1) or (k > MAX_QUIRK_SCANS) or (p + 8 * k > Length(stream)) then Exit(CodecFail(ceBadStream));
    SetLength(quirks.be, k); SetLength(quirks.beMax, k);
    for i := 0 to k - 1 do begin
      if (GetU32(stream, p) >= MAX_QUIRK_SCANS) or (GetU32(stream, p + 4) > MAX_BE_LIMIT) or
         (GetU32(stream, p + 4) = LIBJPEG_MAX_BE) then Exit(CodecFail(ceBadStream));
      quirks.be[i] := Integer(GetU32(stream, p)); quirks.beMax[i] := Integer(GetU32(stream, p + 4)); Inc(p, 8);
      if (i > 0) and (quirks.be[i] <= quirks.be[i - 1]) then Exit(CodecFail(ceBadStream));
    end;
  end;
  at := p;
  for i := 0 to n - 1 do begin
    k := parts[i].copyOf;
    if parts[i].mode and PART_COPY <> 0 then begin
      { an earlier part, of the same length }
      if (k >= i) or (parts[k].len <> parts[i].len) or (parts[k].mode and PART_COPY <> 0) then Exit(CodecFail(ceBadStream));
    end else begin
      k := GetU32(stream, 6 + PART_ENTRY * i + 8);
      if (k < 1) or (at + k > Length(stream)) then Exit(CodecFail(ceBadStream));
      parts[i].stream := Copy(stream, at, k);
      parts[i].copyOf := -1;
      Inc(at, k);
    end;
  end;
  Result := DecompressOne(Copy(stream, at, Length(stream) - at), host, maxRaw, threads, Max(0, expected - cut), quirks);
  if not Result.Ok then Exit;
  if Length(host) + cut > maxRaw then Exit(CodecFail(ceTooLarge));
  jpeg := nil; SetLength(jpeg, Length(host) + cut);
  hp := 0; op := 0;
  for i := 0 to n - 1 do begin
    { the host up to the part }
    if (parts[i].off < op) or (hp + (parts[i].off - op) > Length(host)) then begin jpeg := nil; Exit(CodecFail(ceBadStream)); end;
    if parts[i].off > op then Move(host[hp], jpeg[op], parts[i].off - op);
    Inc(hp, parts[i].off - op); op := parts[i].off;
    if parts[i].copyOf >= 0 then part := Copy(jpeg, parts[parts[i].copyOf].off, parts[i].len)
    else begin
      Result := DecompressAt(parts[i].stream, part, parts[i].len, threads, parts[i].len, depth + 1);
      { a part a later release wrote (or version 7 without pjav7): why the
        stream does not read, as at the top }
      if Result.err = ceFutureVersion then begin jpeg := nil; Exit; end;
      if not Result.Ok or (Length(part) <> parts[i].len) then begin jpeg := nil; Exit(CodecFail(ceBadStream)); end;
    end;
    if parts[i].mode and PART_ZEROS <> 0 then begin
      { its place in the host, zeros }
      if hp + parts[i].len > Length(host) then begin jpeg := nil; Exit(CodecFail(ceBadStream)); end;
      for k := hp to hp + parts[i].len - 1 do
        if host[k] <> 0 then begin jpeg := nil; Exit(CodecFail(ceBadStream)); end;
      Inc(hp, parts[i].len);
    end;
    Move(part[0], jpeg[op], parts[i].len); Inc(op, parts[i].len);
  end;
  if op + (Length(host) - hp) <> Length(jpeg) then begin jpeg := nil; Exit(CodecFail(ceBadStream)); end;
  if hp < Length(host) then Move(host[hp], jpeg[op], Length(host) - hp);
  Result := CodecFail(ceOk);
end;

{ PATCH: the edits, then the repaired file's stream }
function ReadPatch(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer): TCodecResult;
var p: SizeInt; e, i: Integer; pos, del, ins, grown, limit, m, cap: Int64; edits: TEdits; fixed, inner: TBytes;
begin
  jpeg := nil;
  if Length(stream) < 6 then Exit(CodecFail(ceBadStream));
  if (GetU32(stream, 2) < 1) or (GetU32(stream, 2) > MAX_EDITS) then Exit(CodecFail(ceBadStream));
  e := Integer(GetU32(stream, 2));
  edits := nil; SetLength(edits, e);
  { the repaired file, where the edits are: at most MaxFiller larger than
    the original (a cut scan's filler can be longer than what is left of
    the file), and the original at most maxRaw }
  { an edit's numbers are 32 bits: a maxRaw past 2^40 (a crafted size, or
    --max-output=0) bounds nothing more, and would overflow below }
  m := Min(Int64(maxRaw), Int64(1) shl 40);
  limit := Min(m + MaxFiller(m), High(SizeInt));
  p := 6; grown := 0;
  for i := 0 to e - 1 do begin
    if p + 12 > Length(stream) then Exit(CodecFail(ceBadStream));
    { each number checked before it becomes a SizeInt (32 bits on 32-bit
      systems) }
    pos := GetU32(stream, p); del := GetU32(stream, p + 4); ins := GetU32(stream, p + 8);
    if (pos > limit) or (del > limit) or (ins > Length(stream) - p - 12) then Exit(CodecFail(ceBadStream));
    edits[i].pos := pos; edits[i].del := del;
    grown := grown + del - ins;
    edits[i].ins := Copy(stream, p + 12, ins);
    p := p + 12 + Length(edits[i].ins);
  end;
  inner := Copy(stream, p, Length(stream) - p);
  { the repaired file: a JPEG's stream, neither repaired again nor as
    bytes, nor a file of the JPEG 2000 family (version 8, a whole file as
    BYTES is) }
  if (Length(inner) < 2) or ((inner[0] = STREAM_PARTS) and (inner[1] and (FLAG_PATCH or FLAG_BYTES) <> 0)) or
     (inner[0] = STREAM_J2K) then
    Exit(CodecFail(ceBadStream));
  { the repaired file is the original with what the edits take out and
    without what they put back: larger by what RepairJpeg holds to
    MaxFiller (a cut scan's filler), smaller by bytes taken out }
  if (grown > MaxFiller(m)) or ((grown < 0) and (maxRaw + grown < 0)) then Exit(CodecFail(ceBadStream));
  if grown > High(SizeInt) - maxRaw then cap := High(SizeInt) else cap := maxRaw + grown;
  Result := DecompressAt(inner, fixed, SizeInt(cap), threads, 0, 0);
  if not Result.Ok then Exit;
  if not ApplyEdits(fixed, edits, maxRaw, jpeg) then Exit(CodecFail(ceBadStream));
end;

function WritePatch(const edits: TEdits; const inner: TBytes): TBytes;
var i: Integer; p, size: SizeInt;
begin
  size := 6 + Length(inner);
  for i := 0 to High(edits) do size := size + 12 + Length(edits[i].ins);
  Result := nil; SetLength(Result, size);
  Result[0] := STREAM_PARTS; Result[1] := FLAG_PATCH;
  p := 2;
  PutU32(Result, p, Length(edits));
  for i := 0 to High(edits) do begin
    PutU32(Result, p, edits[i].pos); PutU32(Result, p, edits[i].del); PutU32(Result, p, Length(edits[i].ins));
    if Length(edits[i].ins) > 0 then Move(edits[i].ins[0], Result[p], Length(edits[i].ins));
    p := p + Length(edits[i].ins);
  end;
  if Length(inner) > 0 then Move(inner[0], Result[p], Length(inner));
end;

{ ---------- version 8: the JPEG 2000 family ----------

    byte 0          STREAM_J2K
    byte 1          flags: none yet, 0
    4 bytes (LE)    K, the codestreams: 0 to MAX_J2K_CODESTREAMS
    K x 13 bytes    each codestream, in the order of the file and apart:
                    where it is in the file (u32), its length there (u32,
                    1 or more), its stream's length (u32), and its mode
    the K streams   of the codestreams that have one, in order
    the rest        the host through the raw bytes' model (CodeRaw): the
                    file, without the codestreams that have a stream of
                    their own

  Mode 0 (J2K_RAW): the codestream's bytes stay where they are in the host,
  and it has no stream (length 0). Mode 1 (J2K_MODEL, since 0.9.5): its
  stream is pjaj2km's (the codestream taken apart, its decisions through a
  model), and its bytes are cut out of the host. Mode 2 (J2K_PIXELS, since
  0.9.5): its stream is pjaj2kpx's (the codestream as its pixels and what
  makes it again from them), cut out of the host as mode 1's. Mode 3
  (J2K_HT, since 0.9.6): an HTJ2K codestream, its stream pjaj2km's mode 3
  (its code-blocks' values through a model), cut out as mode 1's. Mode 4
  (J2K_HTPIXELS, since 0.9.6): a lossless HTJ2K codestream as its pixels,
  pjaj2kpx's mode 4, cut out as mode 2's. A reader
  that does not
  know a mode, or a flag, refuses the stream as FutureVersion, and never
  reads it as something else. }

const
  J2K_ENTRY = 13;
  J2K_RAW = 0;
  J2K_MODEL = 1;
  J2K_PIXELS = 2;
  J2K_HT = 3;
  J2K_HTPIXELS = 4;

{ known: the codestreams of mode 1 already in hand (their streams were
  decoded and compared when they were made), not decoded again; nil, or
  nil entries, otherwise }
function ReadJ2k(const stream: TBytes; out data: TBytes; maxRaw: SizeInt; threads: Integer;
  const known: TKnown): TCodecResult;
var k, i, nd: Integer; p, off, len, slen, prevEnd, sp, cut, hp, op, gap: Int64; cd: TCoder; host, cs: TBytes;
  e: TCodecError; mode: array of Byte; src, pre: TKnown; perr: TCodecErrors; ccs: TJ2kCodestreams; big: Boolean;
begin
  data := nil;
  if Length(stream) < 6 then Exit(CodecFail(ceBadStream));
  if stream[1] <> 0 then Exit(CodecFail(ceFutureVersion));
  if GetU32(stream, 2) > MAX_J2K_CODESTREAMS then Exit(CodecFail(ceBadStream));
  k := Integer(GetU32(stream, 2));
  if 6 + Int64(J2K_ENTRY) * k > Length(stream) then Exit(CodecFail(ceBadStream));
  { a mode of a later release first, or one this program cannot read:
    whatever the rest says, that is why it does not read }
  p := 6;
  for i := 0 to k - 1 do begin
    if (stream[p + 12] > J2K_HTPIXELS) or ((stream[p + 12] = J2K_MODEL) and not Assigned(J2kMode1Dec)) or
       ((stream[p + 12] = J2K_PIXELS) and not Assigned(J2kMode2Dec)) or
       ((stream[p + 12] = J2K_HT) and not Assigned(J2kMode3Dec)) or
       ((stream[p + 12] = J2K_HTPIXELS) and not Assigned(J2kMode4Dec)) then
      Exit(CodecFail(ceFutureVersion));
    Inc(p, J2K_ENTRY);
  end;
  p := 6; prevEnd := 0; sp := 6 + Int64(J2K_ENTRY) * k; cut := 0;
  SetLength(mode, k);
  for i := 0 to k - 1 do begin
    off := GetU32(stream, p); len := GetU32(stream, p + 4); slen := GetU32(stream, p + 8); mode[i] := stream[p + 12];
    if (len < 1) or (off < prevEnd) then Exit(CodecFail(ceBadStream));
    if (mode[i] = J2K_RAW) and (slen <> 0) then Exit(CodecFail(ceBadStream));
    if (mode[i] <> J2K_RAW) and ((slen < 1) or (slen > Length(stream) - sp)) then Exit(CodecFail(ceBadStream));
    if mode[i] <> J2K_RAW then cut := cut + len;
    sp := sp + slen;
    prevEnd := off + len;
    Inc(p, J2K_ENTRY);
  end;
  if cut > maxRaw then Exit(CodecFail(ceTooLarge));
  cd.InitDecoder(Copy(stream, sp, Length(stream) - sp), 0);
  if not CodeRaw(cd, host, maxRaw - cut) then begin host := nil; Exit(CodecFail(ceTooLarge)); end;
  { every codestream within the file }
  if prevEnd > Length(host) + cut then Exit(CodecFail(ceBadStream));
  if cut = 0 then begin data := host; Exit(CodecFail(ceOk)); end;
  { several codestreams to decode, none large, threads for more than one:
    decoded side by side first (each the same bytes, under the samples'
    cap), then put in place below in order; one refused there is decoded
    again on its own below, which gives the error where the loop meets it }
  src := nil; pre := nil; perr := nil;
  if threads > 1 then begin
    SetLength(src, k); SetLength(ccs, k);
    p := 6; sp := 6 + Int64(J2K_ENTRY) * k; nd := 0; big := False;
    for i := 0 to k - 1 do begin
      len := GetU32(stream, p + 4); slen := GetU32(stream, p + 8);
      ccs[i].off := 0; ccs[i].len := len;
      if (mode[i] <> J2K_RAW) and not ((i < Length(known)) and (known[i] <> nil)) then begin
        if len > CODESTREAMS_TOGETHER then big := True;
        src[i] := Copy(stream, sp, slen);
        Inc(nd);
      end;
      sp := sp + slen;
      Inc(p, J2K_ENTRY);
    end;
    if (nd > 1) and not big then DecodeTogether(src, mode, ccs, threads, pre, perr) else src := nil;
  end;
  { the host's bytes, and each codestream of mode 1 back in its place }
  SetLength(data, Length(host) + cut);
  p := 6; sp := 6 + Int64(J2K_ENTRY) * k; hp := 0; op := 0;
  for i := 0 to k - 1 do begin
    off := GetU32(stream, p); len := GetU32(stream, p + 4); slen := GetU32(stream, p + 8);
    if mode[i] <> J2K_RAW then begin
      gap := off - op;
      if gap > Length(host) - hp then begin data := nil; Exit(CodecFail(ceBadStream)); end;
      if gap > 0 then Move(host[hp], data[op], gap);
      hp := hp + gap; op := op + gap;
      if (i < Length(known)) and (known[i] <> nil) then cs := known[i]
      else if (i < Length(src)) and (src[i] <> nil) and (perr[i] = ceOk) then cs := pre[i]
      else begin
        { (decoded side by side and refused, maybe for the cap alone: again,
          on its own, which says why) }
        if mode[i] = J2K_PIXELS then e := J2kMode2Dec(Copy(stream, sp, slen), len, threads, cs)
        else if mode[i] = J2K_HT then e := J2kMode3Dec(Copy(stream, sp, slen), len, threads, cs)
        else if mode[i] = J2K_HTPIXELS then e := J2kMode4Dec(Copy(stream, sp, slen), len, threads, cs)
        else e := J2kMode1Dec(Copy(stream, sp, slen), len, threads, cs);
        if e <> ceOk then begin data := nil; Exit(CodecFail(e)); end;
      end;
      if Length(cs) <> len then begin data := nil; Exit(CodecFail(ceBadStream)); end;
      Move(cs[0], data[op], len);
      op := op + len;
    end;
    sp := sp + slen;
    Inc(p, J2K_ENTRY);
  end;
  if Length(host) - hp <> Length(data) - op then begin data := nil; Exit(CodecFail(ceBadStream)); end;
  if hp < Length(host) then Move(host[hp], data[op], Length(host) - hp);
  Result := CodecFail(ceOk);
end;

type
  { mode 1 coded on a thread of its own while mode 2 codes on the caller's
    (CompressJ2k) }
  TMode1Job = class(TJoinThread)
    data: TBytes; off, len: Int64; threads: Integer;
    ok: Boolean; s: TBytes; failed: Exception;
    procedure Execute; override;
  end;

procedure TMode1Job.Execute;
begin
  try
    ok := J2kMode1Enc(data, off, len, threads, False, s);
  except
    { raised again on the caller's thread, as if it had coded there }
    ok := False; s := nil;
    failed := Exception(AcquireExceptionObject);
  end;
end;

const
  { the largest codestream whose two modes are coded at the same time }
  MODES_TOGETHER = 64 shl 20;

{ The codestream data[off..off + len) in mode 2 or mode 1, whichever gives
  the smaller stream that is smaller than the codestream (mode: J2K_RAW,
  s nil, when neither does). Mode 2 is coded first, and mode 1 unless mode
  2's stream is no longer than the least mode 1's could be: the side
  information (the same in both) and half the coded bytes it does not keep
  (mode 1 saves a fifth on the codestreams it does best: a bitonal page is
  not coded twice). Both are coded before either is decoded, and only the
  stream kept is decoded and compared: the same choice as checking both
  (the smaller of those that come back, mode 2 on a tie; mode 1 not coded
  when mode 2's stream is below the least mode 1's could be, unless mode
  2's does not come back) for one decoding instead of two. }
procedure J2kChoose(const data: TBytes; off, len: Int64; threads: Integer; out s: TBytes; out mode: Byte);
var c1, c2: TBytes; floor1, t1: Int64; tried1: Boolean; job: TMode1Job; t2: Integer; failed: Exception;

  { mode m's stream gives the codestream back (--stats: the verify) }
  function Checked(m: Integer; const st: TBytes): Boolean;
  var e: TCodecError; w: TStage; back: TBytes;
  begin
    w := StageEnter(stVerify);
    try
      if m = J2K_PIXELS then e := J2kMode2Dec(st, len, threads, back)
      else e := J2kMode1Dec(st, len, threads, back);
      Result := (e = ceOk) and (Length(back) = len) and ((len = 0) or CompareMem(@back[0], @data[off], len));
    except
      { as when the encoders decoded their own streams (mode 2's caught
        everything, out of memory too): the stream is not kept }
      on Exception do Result := False;
    end;
    back := nil;
    StageEnter(w);
  end;

  { mode 1's stream, when it is shorter than the codestream }
  procedure Try1;
  begin
    tried1 := True;
    if not (Assigned(J2kMode1Enc) and J2kMode1Enc(data, off, len, threads, False, c1) and (Length(c1) < len)) then
      c1 := nil;
  end;

  { mode 1 on a thread beside mode 2, with threads to spare, where both are
    likely to be coded: a reversible codestream (the main header's COD has
    the 5/3; with the 9/7 mode 2 refuses at once, and mode 1 gets every
    thread) of more than one bit (a bitonal page's mode 2 is nearly always
    below the least mode 1's could be, and mode 1 is not coded for it), up
    to MODES_TOGETHER bytes (both modes' memory at once) }
  function Together: Boolean;
  var c, nc, m: Integer; e, p: Int64;
  begin
    Result := False;
    if (threads < 2) or not Assigned(J2kMode1Enc) or not Assigned(J2kMode2Enc) or
       (len > MODES_TOGETHER) or (len < 42) then Exit;
    { the SIZ: Csiz at 40, then each component's Ssiz }
    e := off + len;
    if (data[off] <> $FF) or (data[off + 1] <> $4F) or (data[off + 2] <> $FF) or (data[off + 3] <> $51) then Exit;
    nc := (data[off + 40] shl 8) or data[off + 41];
    if (nc < 1) or (42 + 3 * Int64(nc) > len) then Exit;
    c := 0;
    while (c < nc) and (data[off + 42 + 3 * c] and $7F = 0) do Inc(c);
    if c = nc then Exit;
    { the main header's marker segments, up to the first SOT }
    p := off + 2;
    while p + 4 <= e do begin
      m := (data[p] shl 8) or data[p + 1];
      if (m = $FF90) or (m < $FF30) then Exit;
      if m = $FF52 then Exit((p + 13 < e) and (data[p + 13] = 1));
      if m <= $FF3F then p := p + 2 else p := p + 2 + ((data[p + 2] shl 8) or data[p + 3]);
    end;
  end;

begin
  s := nil; mode := J2K_RAW;
  floor1 := 0; c1 := nil; c2 := nil; tried1 := False; job := nil; t2 := threads;
  if J2kIsHt(data, off, len) then begin
    { HTJ2K: mode 4 (its pixels) or mode 3 (its code-blocks' values), the
      smaller, each decoded and compared as it is made; mode 3 not coded
      when mode 4's stream is no longer than the least mode 3's could be;
      modes 1 and 2 do not take it }
    if Assigned(J2kMode4Enc) and J2kMode4Enc(data, off, len, threads, True, c2, floor1) and
       (Length(c2) < len) then begin s := c2; mode := J2K_HTPIXELS; end;
    if Assigned(J2kMode3Enc) and ((mode = J2K_RAW) or (Length(s) > floor1)) and
       J2kMode3Enc(data, off, len, threads, True, c1) and (Length(c1) < len) and
       ((mode = J2K_RAW) or (Length(c1) < Length(s))) then begin s := c1; mode := J2K_HT; end;
    Exit;
  end;
  if Together then begin
    { the threads shared (the streams are the same for any number): mode 1
      as many as it may have slices (one a MiB, pjaj2kcs.J2K_SLICE_BYTES),
      mode 2 the rest, one at least (its pixels are one arithmetic stream,
      its tiles' wavelets go on the others) }
    t1 := len shr 20;
    if t1 > threads - 1 then t1 := threads - 1;
    if t1 < 1 then t1 := 1;
    job := TMode1Job.Create(True);
    job.data := data; job.off := off; job.len := len; job.threads := t1;
    job.FreeOnTerminate := False;
    t2 := threads - t1;
    job.Start;
  end;
  try
    if not (Assigned(J2kMode2Enc) and J2kMode2Enc(data, off, len, t2, False, c2, floor1) and
            (Length(c2) < len)) then begin c2 := nil; floor1 := 0; end;
  finally
    if job <> nil then begin
      job.Join;
      tried1 := True;
      if job.ok and (Length(job.s) < len) then c1 := job.s;
      failed := job.failed;
      job.Free;
      if failed <> nil then raise failed;
    end;
  end;
  { the same choice as with mode 1 coded after mode 2: next to a mode 2
    stream below its floor, mode 1's is not looked at }
  if (c2 <> nil) and (Length(c2) <= floor1) then begin c1 := nil; tried1 := False; end;
  if not tried1 and ((c2 = nil) or (Length(c2) > floor1)) then Try1;
  if (c1 <> nil) and ((c2 = nil) or (Length(c1) < Length(c2))) then begin
    if Checked(J2K_MODEL, c1) then begin s := c1; mode := J2K_MODEL; end
    else if (c2 <> nil) and Checked(J2K_PIXELS, c2) then begin s := c2; mode := J2K_PIXELS; end;
  end else if c2 <> nil then begin
    if Checked(J2K_PIXELS, c2) then begin s := c2; mode := J2K_PIXELS; end
    else begin
      if not tried1 then Try1;
      if (c1 <> nil) and Checked(J2K_MODEL, c1) then begin s := c1; mode := J2K_MODEL; end;
    end;
  end;
end;

type
  { a file's codestreams on several threads: each takes the next one not
    taken (J2kChoose, or its stream decoded), until none is left or one
    raised (raised again on the caller's thread) }
  TCsPool = class;
  TCsThread = class(TJoinThread)
    pool: TCsPool;
    procedure Execute; override;
  end;
  TCsPool = class
    next: LongInt;
    n, each: Integer;
    stop: Boolean;
    data: TBytes;
    cs: TJ2kCodestreams;
    ms: TKnown; md: array of Byte;
    { decoding: each codestream's stream (nil: not decoded here) and mode
      in, its bytes and its error out }
    decoding: Boolean;
    src: TKnown; errs: TCodecErrors;
    failed: array of Exception;
    procedure Loop;
    procedure Run(threads: Integer);
  end;

procedure TCsThread.Execute;
begin
  pool.Loop;
end;

procedure TCsPool.Loop;
var k: Integer;
begin
  repeat
    if stop then Break;
    k := InterLockedIncrement(next) - 1;
    if k >= n then Break;
    try
      if not decoding then J2kChoose(data, cs[k].off, cs[k].len, each, ms[k], md[k])
      else if src[k] = nil then
      else begin
        J2kSamplesCap := SAMPLES_TOGETHER;
        try
          if md[k] = J2K_PIXELS then errs[k] := J2kMode2Dec(src[k], cs[k].len, each, ms[k])
          else if md[k] = J2K_HT then errs[k] := J2kMode3Dec(src[k], cs[k].len, each, ms[k])
          else if md[k] = J2K_HTPIXELS then errs[k] := J2kMode4Dec(src[k], cs[k].len, each, ms[k])
          else errs[k] := J2kMode1Dec(src[k], cs[k].len, each, ms[k]);
        finally
          J2kSamplesCap := 0;
        end;
      end;
    except
      failed[k] := Exception(AcquireExceptionObject);
      stop := True;
      Break;
    end;
  until False;
end;

{ every codestream, on up to threads threads (this one among them) }
procedure TCsPool.Run(threads: Integer);
var w: array of TCsThread; i, m: Integer;
begin
  m := threads; if m > n then m := n; if m < 1 then m := 1;
  each := threads div m; if each < 1 then each := 1;
  next := 0; stop := False;
  SetLength(failed, n); SetLength(ms, n);
  if Length(md) < n then SetLength(md, n);
  if decoding then begin
    SetLength(errs, n);
    for i := 0 to n - 1 do errs[i] := ceOk;
  end;
  SetLength(w, m);
  for i := 1 to m - 1 do begin
    try
      w[i] := TCsThread.Create(True);
    except
      w[i] := nil;
    end;
    if w[i] = nil then Break;
    w[i].pool := Self; w[i].FreeOnTerminate := False;
    w[i].Start;
  end;
  Loop;
  for i := 1 to m - 1 do
    if w[i] <> nil then begin w[i].Join; w[i].Free; end;
  for i := 0 to n - 1 do
    if failed[i] <> nil then raise failed[i];
end;

procedure DecodeTogether(const src: TKnown; const modes: array of Byte; const cs: TJ2kCodestreams;
  threads: Integer; out outs: TKnown; out errs: TCodecErrors);
var pool: TCsPool; i: Integer;
begin
  pool := TCsPool.Create;
  try
    pool.decoding := True; pool.n := Length(src); pool.cs := cs; pool.src := src;
    SetLength(pool.md, Length(src));
    for i := 0 to High(src) do pool.md[i] := modes[i];
    pool.Run(threads);
    outs := pool.ms; errs := pool.errs;
  finally
    pool.Free;
  end;
end;

{ several codestreams, none larger than CODESTREAMS_TOGETHER nor declaring
  more than SAMPLES_TOGETHER samples, and threads for more than one }
function CsTogether(const data: TBytes; const cs: TJ2kCodestreams; threads: Integer): Boolean;
var i: Integer; n: Int64;
begin
  Result := J2kCodestreamsTogether and (threads > 1) and (Length(cs) > 1);
  if not Result then Exit;
  for i := 0 to High(cs) do begin
    if (cs[i].len > CODESTREAMS_TOGETHER) or (cs[i].len < 42) then Exit(False);
    n := J2kSizSamples(Copy(data, cs[i].off + 2, 40));
    if (n < 0) or (n > SAMPLES_TOGETHER) then Exit(False);
  end;
end;

{ A file of the JPEG 2000 family as version 8: each codestream in mode 1
  or mode 2 (J2kChoose, with whichever of them this program has:
  J2kMode1Enc, J2kMode2Enc), an HTJ2K one in mode 3 or mode 4
  (J2kMode3Enc, J2kMode4Enc), else in mode 0; the rest of the file through
  the raw bytes' model. ceJpeg (NotJpeg) for a file that is not one or that
  is too large for the stream's 32-bit places. }
function CompressJ2k(const data: TBytes; out stream: TBytes; verify: Boolean; threads: Integer): TCodecResult;
var cs: TJ2kCodestreams; cd: TCoder; body, host, back: TBytes; i: Integer; p, hp, op, n: SizeInt;
  ms, known: TKnown; cut, pixels, hts, htpix, total: Int64; md: array of Byte; was: TStage; pool: TCsPool;
begin
  stream := nil;
  { --stats (pjastage): the box tree walked is the parse; each codestream
    taken apart and its decisions modelled, the encode (mode 1's own check
    of its stream, pjaj2km, the verify); the stream read back, the verify }
  StageEnter(stParse);
  if (Length(data) >= High(Cardinal)) or not J2kCodestreams(data, cs) then begin
    Result := CodecFail(ceJpeg); Result.jpeg.err := jeNotJpeg; Exit;
  end;
  StageEnter(stEncode);
  SetLength(ms, Length(cs)); SetLength(known, Length(cs)); SetLength(md, Length(cs));
  cut := 0; pixels := 0; hts := 0; htpix := 0;
  if CsTogether(data, cs, threads) then begin
    { the codestreams side by side: each one's stream is the same }
    pool := TCsPool.Create;
    try
      pool.data := data; pool.cs := cs; pool.n := Length(cs);
      SetLength(pool.ms, Length(cs)); SetLength(pool.md, Length(cs));
      pool.Run(threads);
      for i := 0 to High(cs) do begin ms[i] := pool.ms[i]; md[i] := pool.md[i]; end;
    finally
      pool.Free;
    end;
  end else
    for i := 0 to High(cs) do J2kChoose(data, cs[i].off, cs[i].len, threads, ms[i], md[i]);
  for i := 0 to High(cs) do begin
    known[i] := nil;
    if md[i] <> J2K_RAW then begin
      known[i] := Copy(data, cs[i].off, cs[i].len);
      cut := cut + cs[i].len;
      if md[i] = J2K_PIXELS then pixels := pixels + cs[i].len
      else if md[i] = J2K_HTPIXELS then htpix := htpix + cs[i].len
      else if md[i] = J2K_HT then hts := hts + cs[i].len;
    end;
  end;
  { the host: the file without the codestreams of mode 1 or 2 }
  if cut = 0 then host := data
  else begin
    SetLength(host, Length(data) - cut);
    hp := 0; op := 0;
    for i := 0 to High(cs) do
      if ms[i] <> nil then begin
        n := cs[i].off - op;
        if n > 0 then Move(data[op], host[hp], n);
        hp := hp + n; op := cs[i].off + cs[i].len;
      end;
    if op < Length(data) then Move(data[op], host[hp], Length(data) - op);
  end;
  cd.InitEncoder;
  CodeRaw(cd, host, MaxInt);
  body := cd.enc.Finish;
  total := 6 + Int64(J2K_ENTRY) * Length(cs) + Length(body);
  for i := 0 to High(cs) do total := total + Length(ms[i]);
  SetLength(stream, total);
  stream[0] := STREAM_J2K; stream[1] := 0;
  p := 2; PutU32(stream, p, Length(cs));
  for i := 0 to High(cs) do begin
    PutU32(stream, p, Cardinal(cs[i].off)); PutU32(stream, p, Cardinal(cs[i].len)); PutU32(stream, p, Length(ms[i]));
    stream[p] := md[i];
    Inc(p);
  end;
  for i := 0 to High(cs) do
    if Length(ms[i]) > 0 then begin Move(ms[i][0], stream[p], Length(ms[i])); p := p + Length(ms[i]); end;
  Move(body[0], stream[p], Length(body));
  Result := CodecFail(ceOk);
  Result.j2k := True;
  Result.j2kModelled := cut;
  Result.j2kPixels := pixels;
  Result.j2kHt := hts;
  Result.j2kHtPixels := htpix;
  { checked: the stream gives the file back; each mode 1 or 2 stream was
    decoded and compared when it was made, so its codestream is taken as
    known }
  if not verify then Exit;
  was := StageEnter(stVerify);
  if not ReadJ2k(stream, back, Length(data), threads, known).Ok or (Length(back) <> Length(data)) or
     ((Length(data) > 0) and not CompareMem(@back[0], @data[0], Length(data))) then begin
    stream := nil;
    Result := CodecFail(ceNoRoundTrip);
  end;
  StageEnter(was);
end;

function CompressPjax(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                      v7: Boolean): TCodecResult;
begin
  { v7: the zpaq-std plugin's pjax7, the same with version 7's model }
  if v7 then Result := CompressAt(jpeg, stream, verify, threads, mkV7, 0, True)
  else Result := CompressAt(jpeg, stream, verify, threads, mkFull, 0, True);
end;

function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                  fast: Boolean; parts: Boolean; v7: Boolean): TCodecResult;
var why: TCodecResult; model: TModelKind; fixed, inner, asBytes: TBytes; edits: TEdits;
begin
  if v7 then model := mkV7 else if fast then model := mkFast else model := mkFull;
  if not parts then Exit(CompressOne(jpeg, stream, verify, threads, model));
  { the JPEG 2000 family: version 8, nothing else (it does not start like a
    JPEG); a file too large for it is refused as before }
  if J2kKind(jpeg) <> jkNone then Exit(CompressJ2k(jpeg, stream, verify, threads));
  Result := CompressAt(jpeg, stream, verify, threads, model, 0);
  { an encoder's slip PJA can undo: the file repaired, compressed, and the
    repairs kept (PATCH, whose places are 32 bits), with the reason kept }
  if (Result.err = ceJpeg) and (Result.jpeg.err in [jeBadRst, jeDataAfterScan, jeTruncated]) and
     RepairJpeg(jpeg, fixed, edits) and (Length(fixed) < High(Cardinal)) then begin
    why := Result;
    if CompressAt(fixed, inner, False, threads, model, 0).Ok then begin
      stream := WritePatch(edits, inner);
      { a cut scan's filler may cost more than the model gains on the rest:
        then the file goes as bytes, below. Verified even without verify:
        the repairs are guesses, and a PATCH that does not give the file
        back is not written }
      if CompressBytes(jpeg, asBytes, False, threads).Ok and (Length(asBytes) <= Length(stream)) then
        stream := nil
      else if SameAfter(jpeg, stream, threads, 0) then begin
        Result := CodecFail(ceOk); Result.jpeg := why.jpeg; Result.repaired := True;
        Exit;
      end;
      stream := nil;
    end;
    Result := why;
  end;
  { a file that starts like a JPEG and that PJA does not take: as bytes,
    with the reason kept }
  if (Result.err = ceJpeg) and (Length(jpeg) >= 2) and (jpeg[0] = $FF) and (jpeg[1] = $D8) then begin
    why := Result;
    Result := CompressBytes(jpeg, stream, verify, threads);
    if Result.Ok then begin Result.jpeg := why.jpeg; Result.asBytes := True; end
    else Result := why;
  end;
end;

function Decompress(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                    expected: SizeInt): TCodecResult;
begin
  Result := DecompressAt(stream, jpeg, maxRaw, threads, expected, 0);
end;

end.

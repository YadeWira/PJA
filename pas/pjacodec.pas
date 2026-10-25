{ Codec layer 4: the compressed stream of ONE JPEG.

    byte 0          STREAM_VERSION
    byte 1          the coefficient model: 0 the full one, 1 the fast one
                    (pjamodel.CodeBand); 0 for JPEG-LS
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
  PJA_VERSION = '0.0.2';
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
    function Ok: Boolean;
    function Text: string;
  end;

{ JPEG -> stream. With verify (the default), the stream is decompressed and
  compared before returning. threads: how many bands at once (1 = no thread
  is created). fast: a JPEG's coefficients with the fast model, which
  decodes about 1.5 times as fast for about 1.7% more (doc/CODEC.md);
  JPEG-LS files ignore it. parts: the JPEGs inside a JPEG compressed on
  their own (STREAM_PARTS); without it the stream is always version 5, the
  one the zpaq-std plugin's ZPAQL reads. }
function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean = True;
                  threads: Integer = 1; fast: Boolean = False; parts: Boolean = True): TCodecResult;
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

uses Classes, Math, pjaarith, pjamodel;

type
  { scan numbers: version 6's quirks }
  TScanList = array of Integer;

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
    fast: Boolean;          { a JPEG's coefficients, with the fast model }
    ok: Boolean;
  end;
  PBandJob = ^TBandJob;

  TBandThread = class(TThread)
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
    else b.ok := CodeBand(cd, b.j^, b.band, b.fast);
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
end;

function Min2(a, b: Integer): Integer;
begin if a < b then Result := a else Result := b; end;

{ Runs every job, up to `threads` at a time. }
procedure RunBands(var jobs: array of TBandJob; threads: Integer);
var i, next, k: Integer; pool: array of TBandThread;
begin
  if (threads <= 1) or (Length(jobs) <= 1) then begin
    for i := 0 to High(jobs) do RunBand(jobs[i]);
    Exit;
  end;
  next := 0;
  while next < Length(jobs) do begin
    pool := nil;
    SetLength(pool, Min2(threads, Length(jobs) - next));
    for k := 0 to High(pool) do begin
      pool[k] := TBandThread.Create(True);
      pool[k].job := @jobs[next + k];
      pool[k].FreeOnTerminate := False;
      pool[k].Start;
    end;
    for k := 0 to High(pool) do begin pool[k].WaitFor; pool[k].Free; end;
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
  stream[1] := Ord((nb > 0) and jobs[0].fast);
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

{ JPEG-LS: the stream with each model, the smaller one kept. Both are
  exact; which one wins depends on the file (the symbols win on
  near-lossless, the samples on most lossless photos). }
function AssembleJls(var jl: TJls; threads: Integer; out stream: TBytes): Boolean;
var cd: TCoder; head, other: TBytes; jobs: array of TBandJob; nb, b: Integer; model: Integer;
begin
  stream := nil;
  for model := 0 to 1 do begin
    cd.InitEncoder;
    CodeRaw(cd, jl.raw, MaxInt);
    cd.Direct(Cardinal(model), 1);
    if model = 0 then begin
      CodeJlsRuns(cd, jl, MaxInt);
      nb := JlsBandCount(jl);
    end else nb := 1;
    head := cd.enc.Finish;
    jobs := nil;
    SetLength(jobs, nb);
    for b := 0 to nb - 1 do begin
      jobs[b] := Default(TBandJob);
      jobs[b].jl := @jl; jobs[b].symbols := model = 1; jobs[b].band := b; jobs[b].encoding := True;
    end;
    { a model that cannot code this file leaves the other }
    if not Assemble(head, jobs, threads, other) then Continue;
    if (stream = nil) or (Length(other) < Length(stream)) then stream := other;
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
function CompressLive(const jpeg: TBytes; var j: TJpeg; const head: TBytes; threads: Integer;
                      fast: Boolean; out stream: TBytes): Boolean;
var h: THead; nb, b, i, k, pairs, next: Integer; enc, dec: array of TBandJob; r: array of TRange;
    pool: array of TBandThread; back: TBytes; cr: TCodecResult;
begin
  stream := nil;
  Result := False;
  cr := DecodeHead(head, 1 shl 28, h);
  if not cr.Ok or h.isLs then Exit;
  nb := BandCount(j);
  if h.nb <> nb then Exit;
  enc := nil; dec := nil;
  SetLength(enc, nb); SetLength(dec, nb);
  for b := 0 to nb - 1 do begin
    enc[b] := Default(TBandJob);
    enc[b].j := @j; enc[b].band := b; enc[b].encoding := True; enc[b].fast := fast;
    enc[b].live := TLiveStream.Create;
    dec[b] := Default(TBandJob);
    dec[b].j := @h.j; dec[b].band := b; dec[b].encoding := False; dec[b].fast := fast;
    dec[b].live := enc[b].live;
  end;
  try
    { each band takes two threads, both running: the reader waits for the
      writer }
    pairs := threads div 2;
    if pairs < 1 then pairs := 1;
    next := 0;
    while next < nb do begin
      k := nb - next;
      if k > pairs then k := pairs;
      pool := nil;
      SetLength(pool, 2 * k);
      for i := 0 to k - 1 do begin
        pool[2 * i] := TBandThread.Create(True);
        pool[2 * i].job := @enc[next + i];
        pool[2 * i + 1] := TBandThread.Create(True);
        pool[2 * i + 1].job := @dec[next + i];
      end;
      for i := 0 to High(pool) do begin pool[i].FreeOnTerminate := False; pool[i].Start; end;
      for i := 0 to High(pool) do begin pool[i].WaitFor; pool[i].Free; end;
      Inc(next, k);
    end;
    for b := 0 to nb - 1 do
      if not enc[b].ok or not dec[b].ok then Exit;
    if not Build(head, enc, stream) then Exit;
    { the framing, read back the way Decompress reads it }
    if (Length(stream) < STREAM_HEADER + Length(head)) or (stream[0] <> STREAM_VERSION) or
       (stream[1] <> Ord(fast)) or (GetU32(stream, 2) <> Cardinal(Length(head))) or
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

{ With verify: the stream decompressed and compared with the input; a
  difference is a bug, and nothing is handed out }
function VerifyStream(const jpeg: TBytes; var stream: TBytes; verify: Boolean; threads: Integer): TCodecResult;
var r: TCodecResult; back: TBytes;
begin
  Result := CodecFail(ceOk);
  if not verify then Exit;
  r := Decompress(stream, back, 1 shl 28, threads);
  if not r.Ok or (Length(back) <> Length(jpeg)) or
     ((Length(back) > 0) and not CompareMem(@back[0], @jpeg[0], Length(back))) then begin
    stream := nil;
    Result := CodecFail(ceNoRoundTrip);
  end;
end;

{ A JPEG (j: what VerifyRoundTrip made of it) -> its version 5 stream }
function CompressJpeg(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; verify: Boolean; threads: Integer;
                      fast: Boolean; const ownHead: TBytes = nil): TCodecResult; forward;

function CompressOne(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                     fast: Boolean): TCodecResult;
var j: TJpeg; jl: TJls;
begin
  stream := nil;
  Result := CodecFail(ceOk);
  if IsJls(jpeg) then begin
    Result.jpeg := VerifyJls(jpeg, jl);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    if not AssembleJls(jl, threads, stream) then Exit(CodecFail(ceNoRoundTrip));
    Result := VerifyStream(jpeg, stream, verify, threads);
  end else begin
    Result.jpeg := VerifyRoundTrip(jpeg, j);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    { a scan without its restarts needs version 6, which says so }
    if HasIgnoredRestarts(j) then begin
      Result.err := ceJpeg; Result.jpeg.err := jeBadRst;
      Exit;
    end;
    Result := CompressJpeg(jpeg, j, stream, verify, threads, fast);
  end;
end;

function CompressJpeg(const jpeg: TBytes; var j: TJpeg; out stream: TBytes; verify: Boolean; threads: Integer;
                      fast: Boolean; const ownHead: TBytes): TCodecResult;
var jl: TJls; cd: TCoder; head: TBytes; jobs: array of TBandJob; nb, b: Integer;
begin
  stream := nil;
  Result := CodecFail(ceOk);
  jobs := nil;
  begin
    { ownHead: another file's header stream with these bands (a host's,
      whose bands are the file's), verified elsewhere }
    if Length(ownHead) > 0 then head := ownHead
    else begin
      cd.InitEncoder;
      CodeRaw(cd, j.raw, MaxInt);
      CodeScanBits(cd, j);
      head := cd.enc.Finish;
    end;
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
      if verify and (threads >= 2) then begin
        if not CompressLive(jpeg, j, head, threads, fast, stream) then Exit(CodecFail(ceNoRoundTrip));
        Exit;
      end;
      nb := BandCount(j);
      SetLength(jobs, nb);
      for b := 0 to nb - 1 do begin
        jobs[b] := Default(TBandJob);
        jobs[b].j := @j; jobs[b].band := b; jobs[b].encoding := True; jobs[b].fast := fast;
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
  if (Length(stream) < STREAM_HEADER) or (stream[0] <> STREAM_VERSION) or (stream[1] > 1) then
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
                       expected: SizeInt; const quirks: TScanList): TCodecResult;
var h: THead; jobs: array of TBandJob; r: array of TRange; b: Integer; len: Int64;
begin
  jpeg := nil;
  Result := CodecFail(ceOk);
  if (Length(stream) < STREAM_HEADER) or (stream[0] <> STREAM_VERSION) then Exit(CodecFail(ceBadStream));
  if stream[1] > 1 then Exit(CodecFail(ceBadStream));
  len := GetU32(stream, 2);
  if STREAM_HEADER + len > Length(stream) then Exit(CodecFail(ceBadStream));
  Result := DecodeHead(Copy(stream, STREAM_HEADER, len), maxRaw, h);
  if not Result.Ok then Exit;
  { the fast model is for a JPEG's coefficients only }
  if (h.isLs or h.j.lossless) and (stream[1] <> 0) then Exit(CodecFail(ceBadStream));
  { the scans that ignore the DRI in force (version 6 says which): only
    sequential Huffman or lossless ones, as Decompose finds them }
  for b := 0 to High(quirks) do begin
    if h.isLs or h.j.progressive or h.j.arithmetic or (quirks[b] > High(h.j.scans)) or
       (h.j.scans[quirks[b]].ri = 0) then Exit(CodecFail(ceBadStream));
    h.j.scans[quirks[b]].ri := 0; h.j.scans[quirks[b]].ignoreRi := True;
  end;
  r := nil; SetLength(r, h.nb);
  if not BandRanges(stream, STREAM_HEADER + len, h.nb, r) then Exit(CodecFail(ceBadStream));
  jobs := nil; SetLength(jobs, h.nb);
  for b := 0 to h.nb - 1 do begin
    jobs[b] := Default(TBandJob);
    if h.isLs or h.j.lossless then jobs[b].jl := @h.jl else jobs[b].j := @h.j;
    jobs[b].symbols := h.symbols; jobs[b].fast := stream[1] = 1;
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
    byte 1          flags: bit 0 QUIRKS; bit 1 BYTES, alone
  BYTES: the rest is the whole file through the raw bytes' model
  (CodeRaw): a file that starts like a JPEG and that PJA takes no other
  way. Otherwise:
    4 bytes (LE)    K, the parts: 0 to MAX_PARTS (0 only with QUIRKS)
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
  MAX_QUIRK_SCANS = 256;

type
  TPart = record
    off, len: Int64;
    mode: Byte;
    copyOf: Integer;
    stream: TBytes;
  end;

{ The header stream version 5 writes for this JPEG. The bands of a host
  and of the file it came from are the same: the host's stream is the
  file's with this instead of the file's own, and comparing the two tells
  whether the parts pay. }
function HeadBytes(const j: TJpeg): TBytes;
var cd: TCoder; jj: TJpeg;
begin
  jj := j;
  cd.InitEncoder;
  CodeRaw(cd, jj.raw, MaxInt);
  CodeScanBits(cd, jj);
  Result := cd.enc.Finish;
end;

{ The scans with a DRI in force and no restarts }
function QuirkScans(const j: TJpeg): TScanList;
var i, n: Integer;
begin
  Result := nil; n := 0;
  for i := 0 to High(j.scans) do
    if j.scans[i].ignoreRi then begin SetLength(Result, n + 1); Result[n] := i; Inc(n); end;
end;

function SameScans(const a, b: TScanList): Boolean;
var i: Integer;
begin
  Result := Length(a) = Length(b);
  if Result then for i := 0 to High(a) do if a[i] <> b[i] then Exit(False);
end;

function DecompressAt(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                      expected: SizeInt; depth: Integer): TCodecResult; forward;

{ The file and its version 6 stream decompressed: the same bytes }
function SameAfter(const jpeg, stream: TBytes; threads, depth: Integer): Boolean;
var back: TBytes;
begin
  Result := DecompressAt(stream, back, 1 shl 28, threads, Length(jpeg), depth).Ok and (Length(back) = Length(jpeg)) and
            ((Length(back) = 0) or CompareMem(@back[0], @jpeg[0], Length(back)));
end;

function CompressAt(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                    fast: Boolean; depth: Integer): TCodecResult;
var j, sj, hj: TJpeg; parts: array of TPart; k, len, p, from: SizeInt; n, i, c: Integer;
    sub, ps, host, hs, hostHead: TBytes; ok: Boolean; whole, withParts, without: Int64; quirks: TScanList;
begin
  stream := nil;
  if (depth >= MAX_PART_DEPTH) or IsJls(jpeg) or (Length(jpeg) >= High(Cardinal)) then
    Exit(CompressOne(jpeg, stream, verify, threads, fast));
  { the file as PJA takes it today, decoded once: it gives the parts' places
    and, with none, the stream itself }
  Result := CodecFail(ceOk);
  Result.jpeg := VerifyRoundTrip(jpeg, j);
  if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
  quirks := QuirkScans(j);
  { every FF D8 FF that starts a JPEG PJA takes; none can be inside
    entropy-coded data, where FF is followed by 00 or a restart marker }
  parts := nil; n := 0;
  k := 2;
  while (k + 3 <= Length(jpeg)) and (n < MAX_PARTS) do begin
    ok := False;
    if (jpeg[k] = $FF) and (jpeg[k + 1] = $D8) and (jpeg[k + 2] = $FF) and
       Decompose(Copy(jpeg, k, Length(jpeg) - k), sj).Ok then begin
      len := sj.eoi;
      sj := Default(TJpeg);
      { wholly inside the host's segments or wholly after its end }
      if (k >= j.eoi) or (k + len <= j.eoi) then begin
        { the same bytes as an earlier part: a copy of it }
        c := -1;
        for i := 0 to n - 1 do
          if (c < 0) and (parts[i].len = len) and CompareMem(@jpeg[parts[i].off], @jpeg[k], len) then c := i;
        ps := nil;
        if c < 0 then begin
          sub := Copy(jpeg, k, len);
          if not CompressAt(sub, ps, False, threads, fast, depth + 1).Ok or (Length(ps) + PART_ENTRY >= len) then ps := nil;
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
  hostHead := nil;
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
    if VerifyRoundTrip(host, hj).Ok and SameScans(QuirkScans(hj), quirks) then hostHead := HeadBytes(hj)
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
    whole := 0;
    for i := 0 to n - 1 do Inc(whole, parts[i].len);
    if (whole * 4 < Length(jpeg)) or (Length(jpeg) < 1 shl 20) then begin
      withParts := 6 + PART_ENTRY * n + STREAM_HEADER + Length(hostHead);
      for i := 0 to n - 1 do Inc(withParts, Length(parts[i].stream));
      without := STREAM_HEADER + Length(HeadBytes(j));
      if quirks <> nil then without := without + 6;
      if withParts >= without then n := 0;
    end;
  end;
  if (n = 0) and (quirks = nil) then Exit(CompressJpeg(jpeg, j, stream, verify, threads, fast));
  { the host's stream: its header stream and the bands, coded once from the
    file, whose bands they are; the file's own with no parts }
  if n > 0 then Result := CompressJpeg(jpeg, j, hs, False, threads, fast, hostHead)
  else Result := CompressJpeg(jpeg, j, hs, False, threads, fast);
  if not Result.Ok then Exit;
  len := 6 + PART_ENTRY * n + Length(hs);
  for i := 0 to n - 1 do Inc(len, Length(parts[i].stream));
  if quirks <> nil then Inc(len, 4 + 4 * Length(quirks));
  SetLength(stream, len);
  stream[0] := STREAM_PARTS; stream[1] := 0;
  if quirks <> nil then stream[1] := FLAG_QUIRKS;
  p := 2; PutU32(stream, p, n);
  for i := 0 to n - 1 do begin
    PutU32(stream, p, Cardinal(parts[i].off)); PutU32(stream, p, Cardinal(parts[i].len));
    if parts[i].mode and PART_COPY <> 0 then PutU32(stream, p, parts[i].copyOf)
    else PutU32(stream, p, Length(parts[i].stream));
    stream[p] := parts[i].mode; Inc(p);
  end;
  if quirks <> nil then begin
    PutU32(stream, p, Length(quirks));
    for i := 0 to High(quirks) do PutU32(stream, p, quirks[i]);
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
    if quirks = nil then Exit(CompressJpeg(jpeg, j, stream, verify, threads, fast));
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

function DecompressAt(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                      expected: SizeInt; depth: Integer): TCodecResult;
var n, i, flags: Integer; p, hp, op: SizeInt; total, cut, at: Int64; parts: array of TPart; host, part: TBytes;
    k: SizeInt; quirks: TScanList; cd: TCoder;
begin
  jpeg := nil;
  if Length(stream) < 1 then Exit(CodecFail(ceBadStream));
  if stream[0] > STREAM_PARTS then Exit(CodecFail(ceFutureVersion));
  if stream[0] = STREAM_VERSION then Exit(DecompressOne(stream, jpeg, maxRaw, threads, expected, nil));
  if (stream[0] <> STREAM_PARTS) or (depth > MAX_PART_DEPTH) or (Length(stream) < 2) then Exit(CodecFail(ceBadStream));
  flags := stream[1];
  if flags = FLAG_BYTES then begin
    { the whole file as bytes: only at the top, a part is a JPEG }
    if depth > 0 then Exit(CodecFail(ceBadStream));
    cd.InitDecoder(Copy(stream, 2, Length(stream) - 2), 0);
    if not CodeRaw(cd, jpeg, maxRaw) then begin jpeg := nil; Exit(CodecFail(ceTooLarge)); end;
    Exit(CodecFail(ceOk));
  end;
  if (flags and not FLAG_QUIRKS <> 0) or (Length(stream) < 6) then Exit(CodecFail(ceBadStream));
  if GetU32(stream, 2) > MAX_PARTS then Exit(CodecFail(ceBadStream));
  n := Integer(GetU32(stream, 2));
  if (n = 0) and (flags and FLAG_QUIRKS = 0) then Exit(CodecFail(ceBadStream));
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
  quirks := nil;
  if flags and FLAG_QUIRKS <> 0 then begin
    { scans in order, each one at most once }
    if p + 4 > Length(stream) then Exit(CodecFail(ceBadStream));
    k := GetU32(stream, p); Inc(p, 4);
    if (k < 1) or (k > MAX_QUIRK_SCANS) or (p + 4 * k > Length(stream)) then Exit(CodecFail(ceBadStream));
    SetLength(quirks, k);
    for i := 0 to k - 1 do begin
      if GetU32(stream, p) >= MAX_QUIRK_SCANS then Exit(CodecFail(ceBadStream));
      quirks[i] := Integer(GetU32(stream, p)); Inc(p, 4);
      if (i > 0) and (quirks[i] <= quirks[i - 1]) then Exit(CodecFail(ceBadStream));
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

function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                  fast: Boolean; parts: Boolean): TCodecResult;
var why: TCodecResult;
begin
  if not parts then Exit(CompressOne(jpeg, stream, verify, threads, fast));
  Result := CompressAt(jpeg, stream, verify, threads, fast, 0);
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

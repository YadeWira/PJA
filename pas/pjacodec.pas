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
  PJA_VERSION = '0.0.1';
  { 5 since 0.0.1: the predictions' arithmetic made 32-bit (pjamodel.W32),
    so a ZPAQL decoder can follow it exactly; 4 streams decoded with the
    64-bit one and are no longer read }
  STREAM_VERSION = 5;
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
    function Ok: Boolean;
    function Text: string;
  end;

{ JPEG -> stream. With verify (the default), the stream is decompressed and
  compared before returning. threads: how many bands at once (1 = no thread
  is created). fast: a JPEG's coefficients with the fast model, which
  decodes about 1.5 times as fast for about 1.7% more (doc/CODEC.md);
  JPEG-LS files ignore it. }
function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean = True;
                  threads: Integer = 1; fast: Boolean = False): TCodecResult;
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

uses Classes, pjaarith, pjamodel;

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
    h.nb := BandCount(h.j);
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

function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer;
                  fast: Boolean): TCodecResult;
var j: TJpeg; jl: TJls; cd: TCoder; head, back: TBytes; r: TCodecResult; jobs: array of TBandJob;
    nb, b: Integer;
begin
  stream := nil;
  Result := CodecFail(ceOk);
  jobs := nil;
  if IsJls(jpeg) then begin
    Result.jpeg := VerifyJls(jpeg, jl);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    if not AssembleJls(jl, threads, stream) then Exit(CodecFail(ceNoRoundTrip));
  end else begin
    Result.jpeg := VerifyRoundTrip(jpeg, j);
    if not Result.jpeg.Ok then begin Result.err := ceJpeg; Exit; end;
    cd.InitEncoder;
    CodeRaw(cd, j.raw, MaxInt);
    CodeScanBits(cd, j);
    head := cd.enc.Finish;
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
    if not Assemble(head, jobs, threads, stream) then Exit(CodecFail(ceNoRoundTrip));
  end;
  if verify then begin
    r := Decompress(stream, back, 1 shl 28, threads);
    if not r.Ok or (Length(back) <> Length(jpeg)) or
       ((Length(back) > 0) and not CompareMem(@back[0], @jpeg[0], Length(back))) then begin
      stream := nil;
      Exit(CodecFail(ceNoRoundTrip));
    end;
  end;
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

function Decompress(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer;
                    expected: SizeInt): TCodecResult;
var h: THead; jobs: array of TBandJob; r: array of TRange; b: Integer; len: Int64;
begin
  jpeg := nil;
  Result := CodecFail(ceOk);
  if Length(stream) < 1 then Exit(CodecFail(ceBadStream));
  if stream[0] > STREAM_VERSION then Exit(CodecFail(ceFutureVersion));
  if stream[0] < STREAM_VERSION then Exit(CodecFail(ceBadStream));
  if Length(stream) < STREAM_HEADER then Exit(CodecFail(ceBadStream));
  if stream[1] > 1 then Exit(CodecFail(ceBadStream));
  len := GetU32(stream, 2);
  if STREAM_HEADER + len > Length(stream) then Exit(CodecFail(ceBadStream));
  Result := DecodeHead(Copy(stream, STREAM_HEADER, len), maxRaw, h);
  if not Result.Ok then Exit;
  { the fast model is for a JPEG's coefficients only }
  if h.isLs and (stream[1] <> 0) then Exit(CodecFail(ceBadStream));
  r := nil; SetLength(r, h.nb);
  if not BandRanges(stream, STREAM_HEADER + len, h.nb, r) then Exit(CodecFail(ceBadStream));
  jobs := nil; SetLength(jobs, h.nb);
  for b := 0 to h.nb - 1 do begin
    jobs[b] := Default(TBandJob);
    if h.isLs then jobs[b].jl := @h.jl else jobs[b].j := @h.j;
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

end.

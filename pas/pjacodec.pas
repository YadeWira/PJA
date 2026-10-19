{ Codec layer 4: the compressed stream of ONE JPEG.

    byte 0          STREAM_VERSION
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
  byte for byte is rejected with its reason.

  Threads: a program that passes threads > 1 on Unix has to use cthreads. }
unit pjacodec;

{$I pja.inc}
{$ifopt R-}{$fatal pjacodec: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjacodec: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjajpeg, pjajls;

const
  STREAM_VERSION = 3;

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
  is created). }
function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean = True;
                  threads: Integer = 1): TCodecResult;
{ stream -> JPEG. maxRaw caps the raw part a damaged stream can claim. }
function Decompress(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt = 1 shl 28;
                    threads: Integer = 1): TCodecResult;

implementation

uses Classes, pjamodel;

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
    if b.encoding then cd.InitEncoder
    else begin
      { the band's own bytes only: past them the decoder reads zeros, never
        the next band }
      slice := Copy(b.input, b.first, b.last - b.first);
      cd.InitDecoder(slice, 0);
    end;
    if b.symbols then b.ok := CodeJlsSymbolStream(cd, b.jl^)
    else if b.jl <> nil then b.ok := CodeJlsBand(cd, b.jl^, b.band)
    else b.ok := CodeBand(cd, b.j^, b.band);
    if b.encoding then b.output := cd.enc.Finish;
  except
    b.ok := False;
  end;
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
function Assemble(const head: TBytes; var jobs: array of TBandJob; threads: Integer; out stream: TBytes): Boolean;
var b, nb: Integer; total, p: SizeInt;
begin
  stream := nil;
  RunBands(jobs, threads);
  nb := Length(jobs);
  total := 1 + 4 + Length(head);
  for b := 0 to nb - 1 do begin
    if not jobs[b].ok then Exit(False);
    Inc(total, Length(jobs[b].output));
    if b < nb - 1 then Inc(total, 4);
  end;
  SetLength(stream, total);
  stream[0] := STREAM_VERSION; p := 1;
  PutU32(stream, p, Length(head));
  Move(head[0], stream[p], Length(head)); Inc(p, Length(head));
  for b := 0 to nb - 1 do begin
    if b < nb - 1 then PutU32(stream, p, Length(jobs[b].output));
    if Length(jobs[b].output) > 0 then Move(jobs[b].output[0], stream[p], Length(jobs[b].output));
    Inc(p, Length(jobs[b].output));
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

function Compress(const jpeg: TBytes; out stream: TBytes; verify: Boolean; threads: Integer): TCodecResult;
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
    nb := BandCount(j);
    SetLength(jobs, nb);
    for b := 0 to nb - 1 do begin
      jobs[b] := Default(TBandJob);
      jobs[b].j := @j; jobs[b].band := b; jobs[b].encoding := True;
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

function Decompress(const stream: TBytes; out jpeg: TBytes; maxRaw: SizeInt; threads: Integer): TCodecResult;
var j: TJpeg; jl: TJls; cd: TCoder; raw, head: TBytes; jobs: array of TBandJob; nb, b: Integer;
    p, len: Int64; isLs, symbols: Boolean;
begin
  jpeg := nil;
  Result := CodecFail(ceOk);
  if Length(stream) < 5 then Exit(CodecFail(ceBadStream));
  if stream[0] > STREAM_VERSION then Exit(CodecFail(ceFutureVersion));
  if stream[0] < STREAM_VERSION then Exit(CodecFail(ceBadStream));
  len := GetU32(stream, 1);
  if 5 + len > Length(stream) then Exit(CodecFail(ceBadStream));
  head := Copy(stream, 5, len);
  cd.InitDecoder(head, 0);
  raw := nil;
  if not CodeRaw(cd, raw, maxRaw) then Exit(CodecFail(ceTooLarge));
  isLs := IsJls(raw); symbols := False;
  if isLs then begin
    Result.jpeg := ParseJlsHeaders(raw, jl);
    if not Result.jpeg.Ok then begin Result.err := ceBadStream; Exit; end;
    symbols := cd.Direct(0, 1) = 1;
    if symbols then nb := 1
    else begin
      if not CodeJlsRuns(cd, jl, 1 shl 26) then Exit(CodecFail(ceBadStream));
      nb := JlsBandCount(jl);
    end;
  end else begin
    Result.jpeg := ParseHeaders(raw, j);
    if not Result.jpeg.Ok then begin Result.err := ceBadStream; Exit; end;
    CodeScanBits(cd, j);
    nb := BandCount(j);
  end;
  jobs := nil; SetLength(jobs, nb);
  p := 5 + len;
  for b := 0 to nb - 1 do begin
    jobs[b] := Default(TBandJob);
    if isLs then jobs[b].jl := @jl else jobs[b].j := @j;
    jobs[b].symbols := symbols;
    jobs[b].band := b; jobs[b].encoding := False; jobs[b].input := stream;
    if b < nb - 1 then begin
      if p + 4 > Length(stream) then Exit(CodecFail(ceBadStream));
      len := GetU32(stream, p); Inc(p, 4);
      if p + len > Length(stream) then Exit(CodecFail(ceBadStream));
    end else len := Length(stream) - p;
    jobs[b].first := p; jobs[b].last := p + len;
    Inc(p, len);
  end;
  RunBands(jobs, threads);
  for b := 0 to nb - 1 do
    if not jobs[b].ok then Exit(CodecFail(ceBadStream));
  if isLs then Result.jpeg := RecomposeJls(jl, jpeg) else Result.jpeg := Recompose(j, jpeg);
  if not Result.jpeg.Ok then begin jpeg := nil; Result.err := ceBadStream; end;
end;

end.

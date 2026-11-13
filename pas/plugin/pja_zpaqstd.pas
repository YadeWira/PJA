{ pja_zpaqstd: PJA as a zpaq-std plugin for -sat / -sae (codecs for specific
  formats), on zpaq-std's plugin ABI 1 (compressors/plug/zs_codec.h in
  YadeWira/zpaq-std).

    pas/plugin/build.sh      -> codecs/pja.so, pja.dll (64 and 32 bits)

  Exported C functions:
  - zpaqstd_codecs_v1(i): the codecs, pja (0) for JPEG and pjals (1) for
    JPEG-LS; zpaqstd_codec_v1 is pja, for a zpaq-std that knows one codec a
    file. pja: compress() gets a file's block (the file and
    zpaq-std's list of fragments after it) and gives back the PJA codec stream
    (pjacodec.Compress), which keeps every byte after the end of the JPEG; it
    does not verify the stream itself, since zpaq-std decodes every block and
    compares before writing it. decompress() is pjacodec.Decompress, with
    zpaq-std's exact original size as the cap. data(ZS_DATA_ZPAQL) is its
    ZPAQL decoder (pjazpaql.inc, from pas/plugin/zpaql/ through
    tools/zpaql/gen_pjadec.py), which every block carries so that any zpaq
    reads it without this plugin. Its H is sized for each block: the config
    says $3, and query(ZS_QUERY_ZPAQL_ARGS) gives it (pjazpaqlargs); such a
    ZPAQL is handed out only as ZS_DATA_ZPAQL_ARGS, so a zpaq-std that does
    not ask sees none. The ZPAQL starts afresh after each segment, so
    query(ZS_QUERY_SEGMENTS) says 1: several files may share a block. data(ZS_DATA_INFO) is the card zpaq-std shows in
    codecinfoex. pjals is the same for JPEG-LS, with its own ZPAQL
    (pjalszpaql.inc, PJALS_ZPAQL) and query (ZpaqlJlsArgs).
  - The z codecs (5 .. 9): pjaz, pjalsz, pjaxz, pjallz, pjalsxz. Each is its
    codec without the z (detect, compress, decompress, query: the same
    functions) with another ZPAQL (lzzpaql.inc): zpaq-std passes each
    segment of a block, the codec's stream, through zpaq's level 1 LZ77
    (the -m1 method, rb = 0), whose matches may reach back into the
    segments before it in the block; the ZPAQL expands them into M, a ring
    of 2^$1 bytes, and decodes. Its config is comp 0 0 $3 $1 0: $3 is the
    codec's query's (the largest of the block), $1 the window's bits; no
    distance reaches 2^$1 and no segment comes out larger than 2^$1 bytes.
    zpaq-std makes the LZ77 and its native path (the expansion in C, then
    this plugin's decompress); the plugin never sees it.
  - The o codecs (14 .. 19, 0.7.0): pjalso, pjallo, pjalsxo and their z,
    pjalszo, pjallzo, pjalsxzo. Each is pjals, pjall, pjalsx (or its z)
    with the same streams, H and functions, and a ZPAQL half the size or
    less (ozpaql.inc: the same programs compiled with zpaqlc's opt=2): every
    block carries its decoder, so a smaller one pays off in small blocks.
  - The 8 codecs (20 .. 29, 0.8.0): pja78, pjax78, pja7z8, pjax7z8,
    pjals8, pjall8, pjalsx8, pjalsz8, pjallz8, pjalsxz8. Each is the codec
    its name has without the 8 (pja7, ..., pjalsxz) with the same streams,
    H and functions, and its ZPAQL compiled with zpaqlc's opt=3, 3 to 8%
    smaller (v8zpaql.inc).
  - The JPEG 2000 codec (30, 0.9.6; its name PROVISIONAL, pjazsj2k's
    PJK_NAME, until the owner approves it): a file of the JPEG 2000 family
    as stream version 8, each codestream in mode 1 where its ZPAQL
    (j2kzpaql.inc, comp 0 0 $3 $4 0: H and M from the query) rebuilds it
    within its limits, else in mode 0 (pjazsj2k).
  - zpaqstd_detect_v1: 1 if the codec named takes the file, looking only at
    its bytes: only what its ZPAQL decoder covers. pja: a JPEG, Huffman or
    arithmetic, sequential or progressive, that PJA's layer 1 rebuilds byte
    for byte and that fits the decoder's memory. pjals: a JPEG-LS file that
    comes back byte for byte (pjajls.VerifyJls) and fits its decoder's
    memory with either model. No global state, so several threads can ask
    at once.
  - zpaqstd_threads_v1(n), optional (0.5.1): how many threads zpaq-std
    runs; each compress() and decompress() then gives a file's bands
    n / (the calls running at that moment) threads, so that a few large
    files (an MPO of 10 MB) do not leave the rest idle. Without it, one
    thread a call, as before. The streams are the same with any number.
  - The detections of pja, pjax and pjall verify the same JPEG the same
    way: the first one keeps what it found (a few entries, by the bytes'
    size and BLAKE3), the others and pja's compress() use it, which then
    does not rebuild the JPEG a third time (pjacodec.CompressVerified);
    compress() looks for the file before zpaq-std's list of fragments.

  Levels: 2 = the full model, the stream frozen as pja5-full (stream version
  5, model byte 0). The fast model (level 1) joins once its stream is frozen.

  CONTRACT with zpaq-std: the library field starts with "pja stream v5 full"
  for as long as this plugin writes and reads that stream. A later stream
  needs a new codec name or a new library field, never a silent change. }
library pja_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}{$ifdef windows}pjaheap,{$endif}
  SysUtils, pjajpeg, pjajls, pjacodec, pjamodel, pjazpaqlargs, pjav7, pjablake3, pjazsj2k, pjaj2k;

{$I lzzpaql.inc}
{$I ozpaql.inc}
{$I v8zpaql.inc}

const
  ZS_DATA_ZPAQL = 2;
  { a ZPAQL whose config uses $3 .. $5: only through this, so that a
    zpaq-std without the query below sees no ZPAQL at all }
  ZS_DATA_ZPAQL_ARGS = 4;
  ZS_QUERY_ZPAQL_ARGS = 2;
  { 1: the ZPAQL decodes several segments in one block (it starts afresh
    after each), so zpaq-std may put consecutive files of the codec there }
  ZS_QUERY_SEGMENTS = 3;
  ZPAQL_LS_MAX_SCANS = 64;    { jls.zl's JMAXSCANS }
  { the JPEGs after the EOI pjax's detect asks for: they gain about a fifth
    of their size, which then pays pjax's ZPAQL (57,709 bytes) on its own }
  PJAX_MIN_AFTER = 256 * 1024;
  ZS_CODEC_ABI  = 1;
  ZS_ERR_DATA   = -1;
  ZS_ERR_MEMORY = -2;

  { zpaq-std shows the codecs files up to 64 MB; above this, refuse }
  MAX_BLOCK = SizeUInt(1) shl 30;

  LEVEL_FULL = 2;

type
  {$packrecords c}
  TBoundFn      = function(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
  TCompressFn   = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           level: LongInt): Int64; cdecl;
  TDecompressFn = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           param: LongInt): Int64; cdecl;
  TQueryFn      = function(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
  TDataFn       = function(what: LongInt; size: PSizeUInt): Pointer; cdecl;

  TZsCodec = record
    abi: LongInt;
    name: PChar;
    library_: PChar;   { the C names: compress, decompress; the "_" keeps them apart from pjacodec's }
    min_level, max_level: LongInt;
    bound: TBoundFn;
    compress_: TCompressFn;
    decompress_: TDecompressFn;
    query: TQueryFn;
    data: TDataFn;
  end;
  PZsCodec = ^TZsCodec;

var
  { zpaqstd_threads_v1's n, and the calls running }
  ThreadsGiven: LongInt = 1;
  Running: LongInt = 0;

{ a call starts: the threads its file's bands get; Leave when it ends }
function Enter: Integer;
var k: LongInt;
begin
  k := InterLockedIncrement(Running);
  if k < 1 then k := 1;
  Result := ThreadsGiven div k;
  if Result < 1 then Result := 1;
end;

procedure Leave;
begin
  InterLockedDecrement(Running);
end;

procedure zpaqstd_threads_v1(n: LongInt); cdecl;
begin
  if n < 1 then n := 1;
  if n > 256 then n := 256;
  ThreadsGiven := n;
end;

type
  { what the detections found for one JPEG: its round trip, and whether
    pja, pjax and pjall take it }
  TVerdict = record
    size: SizeUInt;
    hash: THash16;
    used, rt, pja, pjax, pjall, pja7, pjax7: Boolean;
  end;

const
  VERDICT_SLOTS = 64;

var
  KeptVerdicts: array[0..VERDICT_SLOTS - 1] of TVerdict;
  VerdictNext: Integer = 0;
  VerdictLock: TRTLCriticalSection;

{ the bytes' hash, to find a verdict again: BLAKE3, since a verdict found
  is not checked again (up to 0.6.3 a 64-bit FNV-like mix, which a file
  could be made to match: a JPEG pja refuses then got another's verdict,
  and a block its ZPAQL cannot decode) }
function BytesHash(src: PByte; n: SizeUInt): THash16;
var b: TBlake3;
begin
  b.Init;
  b.Update(src^, n);
  Result := b.Final;
end;

function FindVerdict(size: SizeUInt; const hash: THash16; out v: TVerdict): Boolean;
var i: Integer;
begin
  Result := False;
  EnterCriticalSection(VerdictLock);
  try
    for i := 0 to VERDICT_SLOTS - 1 do
      if KeptVerdicts[i].used and (KeptVerdicts[i].size = size) and
         CompareMem(@KeptVerdicts[i].hash[0], @hash[0], SizeOf(THash16)) then begin
        v := KeptVerdicts[i];
        Exit(True);
      end;
  finally
    LeaveCriticalSection(VerdictLock);
  end;
end;

procedure KeepVerdict(const v: TVerdict);
begin
  EnterCriticalSection(VerdictLock);
  try
    KeptVerdicts[VerdictNext] := v;
    VerdictNext := (VerdictNext + 1) mod VERDICT_SLOTS;
  finally
    LeaveCriticalSection(VerdictLock);
  end;
end;

function Bytes(src: Pointer; n: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, n);
  if n > 0 then Move(src^, Result[0], n);
end;

{ compress()'s block: the verdict of the file it holds, with or without
  zpaq-std's list of fragments after it (their sizes, 4 bytes each, then 4
  bytes and their count, little endian), which a file alone in its block
  and a group's last have; size: the file's }
function BlockVerdict(src: PByte; n: SizeUInt; out v: TVerdict; out size: SizeUInt): Boolean;
var f: SizeUInt;
begin
  size := n;
  Result := FindVerdict(n, BytesHash(src, n), v);
  if Result or (n < 12) then Exit;
  f := SizeUInt(src[n - 4]) or (SizeUInt(src[n - 3]) shl 8) or (SizeUInt(src[n - 2]) shl 16) or
       (SizeUInt(src[n - 1]) shl 24);
  if (f < 1) or (f > (n - 8) div 4) then Exit;
  size := n - 8 - 4 * f;
  Result := FindVerdict(size, BytesHash(src, size), v);
end;

{ The stream is the JPEG modelled, so it is usually smaller; a file the
  codec cannot shrink comes out a little larger, and zpaq-std then stores it
  as -m says. }
function CodecBound(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
begin
  if n > MAX_BLOCK then Exit(0);
  Result := n + n div 4 + 65536;
end;

{ compress() of either codec: pja takes no JPEG-LS file and pjals nothing
  else, so that each block's stream is the one its ZPAQL decodes }
function CompressAs(ls: Boolean; src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt; threads: Integer; v7: Boolean = False): Int64;
var stream, d: TBytes; r: TCodecResult; j: TJpeg; jl: TJls; symbols: Boolean; v: TVerdict; size: SizeUInt;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    d := Bytes(src, n);
    if IsJls(d) <> ls then Exit(ZS_ERR_DATA);
    { no verification here: zpaq-std decodes every block and compares }
    { version 5 only: the stream its ZPAQL reads; a JPEG pja's detection
      verified already is only taken apart. With the fragments after it,
      only if its EOI comes before them: they then go to raw as they are,
      and the block rebuilds as the file did }
    if not ls and BlockVerdict(src, n, v, size) and v.rt and (v.pja or v.pja7) and Decompose(d, j).Ok and
       (SizeUInt(j.eoi) <= size) then
      r := CompressVerified(d, j, stream, threads, v7)
    else
      r := Compress(d, stream, False, threads, False, False, v7);
    if not r.Ok then Exit(ZS_ERR_DATA);
    { a 12-bit or a lossless JPEG: PJA takes it, the frozen ZPAQL would not }
    if not ls and (not StreamHeaders(stream, j).Ok or (j.precision <> 8) or j.lossless or j.dnl) then Exit(ZS_ERR_DATA);
    { the same for a subsampled JPEG-LS file and the pjals ZPAQL }
    if ls and (not StreamJlsHeaders(stream, jl, symbols).Ok or JlsSubsampled(jl)) then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := CompressAs(False, src, n, dst, cap, level, t); finally Leave; end;
end;

function Pja7Compress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := CompressAs(False, src, n, dst, cap, level, t, True); finally Leave; end;
end;

function LsCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := CompressAs(True, src, n, dst, cap, level, t); finally Leave; end;
end;

{ pjax: what CompressPjax writes, version 5 or 6, its ZPAQL's }
function XCompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt; threads: Integer; v7: Boolean = False): Int64;
var stream: TBytes;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    { no verification here: zpaq-std decodes every block and compares }
    if not CompressPjax(Bytes(src, n), stream, False, threads, v7).Ok then Exit(ZS_ERR_DATA);
    if ZpaqlPjaxArgs(stream, v7) < 0 then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function XCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := XCompressIn(src, n, dst, cap, level, t); finally Leave; end;
end;

{ pjalsx: a JPEG-LS file with subsampled components, its version 5 stream
  (the smaller of the two models), its ZPAQL's }
function LsxCompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt; threads: Integer): Int64;
var stream, d: TBytes;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    d := Bytes(src, n);
    if not IsJls(d) then Exit(ZS_ERR_DATA);
    { no verification here: zpaq-std decodes every block and compares }
    if not Compress(d, stream, False, threads, False, False).Ok then Exit(ZS_ERR_DATA);
    if ZpaqlJlsxArgs(stream) < 0 then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function LsxCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := LsxCompressIn(src, n, dst, cap, level, t); finally Leave; end;
end;

function LsxQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlJlsxArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

{ pjall: a lossless JPEG's version 5 stream, its ZPAQL's }
function LlCompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt; threads: Integer): Int64;
var stream: TBytes;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    { no verification here: zpaq-std decodes every block and compares }
    if not Compress(Bytes(src, n), stream, False, threads, False, False).Ok then Exit(ZS_ERR_DATA);
    if ZpaqlLjpegArgs(stream) < 0 then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function LlCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := LlCompressIn(src, n, dst, cap, level, t); finally Leave; end;
end;

function LlQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlLjpegArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function XDecompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt; threads: Integer; v7: Boolean = False): Int64;
var jpeg: TBytes; r: TCodecResult;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) or (n < 2) then Exit(ZS_ERR_DATA);
  try
    { version 5 of the full model (version 7: pjax7), or 6 without bytes }
    if not ((((PByte(src)[0] = STREAM_VERSION) and not v7) or ((PByte(src)[0] = STREAM_V7) and v7)) and (PByte(src)[1] = 0) or
            ((PByte(src)[0] = STREAM_PARTS) and (PByte(src)[1] <= 1))) then Exit(ZS_ERR_DATA);
    r := Decompress(Bytes(src, n), jpeg, SizeInt(cap), threads, SizeInt(cap));
    if not r.Ok or (SizeUInt(Length(jpeg)) <> cap) then Exit(ZS_ERR_DATA);
    if Length(jpeg) > 0 then Move(jpeg[0], dst^, Length(jpeg));
    Result := Length(jpeg);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function XDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := XDecompressIn(src, n, dst, cap, param, t); finally Leave; end;
end;

function X7Compress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := XCompressIn(src, n, dst, cap, level, t, True); finally Leave; end;
end;

function X7Decompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := XDecompressIn(src, n, dst, cap, param, t, True); finally Leave; end;
end;

function X7Query(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlPjaxArgs(Bytes(src, n), True);
  except
    Result := -1;
  end;
end;

function Pja7Query(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlArgs7(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function XQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlPjaxArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function CodecDecompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt; threads: Integer): Int64;
var jpeg: TBytes; r: TCodecResult;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) then Exit(ZS_ERR_DATA);
  try
    { the full model only: a stream of another model is not this codec's }
    if (n >= 2) and (PByte(src)[1] <> 0) then Exit(ZS_ERR_DATA);
    { cap is the original's exact size: the raw part cannot be larger }
    r := Decompress(Bytes(src, n), jpeg, SizeInt(cap), threads, SizeInt(cap));
    if not r.Ok or (SizeUInt(Length(jpeg)) <> cap) then Exit(ZS_ERR_DATA);
    if Length(jpeg) > 0 then Move(jpeg[0], dst^, Length(jpeg));
    Result := Length(jpeg);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := CodecDecompressIn(src, n, dst, cap, param, t); finally Leave; end;
end;

{ 1 if PJA takes the file: what its ZPAQL decoder covers (stage 3), so that
  no block is left without one: a JPEG, Huffman or arithmetic, sequential
  or progressive, that
  layer 1 rebuilds byte for byte, with at most ZPAQL_MAX_SCANS scans and
  whose decoding fits the decoder's memory. Only the bytes; deterministic;
  no shared state. }
{ query(ZS_QUERY_ZPAQL_ARGS): for compress()'s output, the $3 of the
  decoder's config (log2 of its H for this very file), or negative.
  query(ZS_QUERY_SEGMENTS): 1, several files a block. }
function CodecQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function LsQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlJlsArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

{ the JPEG 2000 codec (pjazsj2k): a version 8 stream, modes 0 and 1 }
function PjkCompressFn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; level: LongInt): Int64; cdecl;
var stream: TBytes; t: Integer;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  t := Enter;
  try
    try
      if not PjkCompress(Bytes(src, n), stream, t) or (SizeUInt(Length(stream)) > cap) then Exit(ZS_ERR_DATA);
      Move(stream[0], dst^, Length(stream));
      Result := Length(stream);
    except
      on EOutOfMemory do Result := ZS_ERR_MEMORY;
      on Exception do Result := ZS_ERR_DATA;
    end;
  finally
    Leave;
  end;
end;

function PjkDecompressFn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; param: LongInt): Int64; cdecl;
var data: TBytes; t: Integer;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) then Exit(ZS_ERR_DATA);
  t := Enter;
  try
    try
      if not PjkDecompress(Bytes(src, n), SizeInt(cap), t, data) then Exit(ZS_ERR_DATA);
      if Length(data) > 0 then Move(data[0], dst^, Length(data));
      Result := Length(data);
    except
      on EOutOfMemory do Result := ZS_ERR_MEMORY;
      on Exception do Result := ZS_ERR_DATA;
    end;
  finally
    Leave;
  end;
end;

{ $3 (H) in bits 0-7 and $4 (M) in bits 8-15 }
function PjkQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := PjkArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function DetectTakes(codecName: PChar; src: Pointer; n: SizeUInt): LongInt;
var d: TBytes; j: TJpeg; jl: TJls; w, after: Int64; base: array[0..15] of Char; k: SizeInt; h: THash16; v: TVerdict;
begin
  Result := 0;
  if (codecName = nil) or (n < 4) or (n > MAX_BLOCK) then Exit;
  k := StrLen(codecName);
  { an 8 codec takes what its codec does: pja78, pja7's files; pjalsz8,
    pjalsz's, and so on }
  if (k >= 2) and (k < Length(base)) and (codecName[k - 1] = '8') then begin
    StrLCopy(@base[0], codecName, k - 1);
    if (StrComp(@base[0], 'pja7') = 0) or (StrComp(@base[0], 'pjax7') = 0) or
       (StrComp(@base[0], 'pja7z') = 0) or (StrComp(@base[0], 'pjax7z') = 0) or
       (StrComp(@base[0], 'pjals') = 0) or (StrComp(@base[0], 'pjall') = 0) or (StrComp(@base[0], 'pjalsx') = 0) or
       (StrComp(@base[0], 'pjalsz') = 0) or (StrComp(@base[0], 'pjallz') = 0) or (StrComp(@base[0], 'pjalsxz') = 0) then
      Exit(DetectTakes(@base[0], src, n));
    Exit;
  end;
  { an o codec takes what its codec does: pjalso, pjals' files; pjalszo,
    pjalsz's, and so on }
  if (k >= 2) and (k < Length(base)) and (codecName[k - 1] = 'o') then begin
    StrLCopy(@base[0], codecName, k - 1);
    if (StrComp(@base[0], 'pjals') = 0) or (StrComp(@base[0], 'pjall') = 0) or (StrComp(@base[0], 'pjalsx') = 0) or
       (StrComp(@base[0], 'pjalsz') = 0) or (StrComp(@base[0], 'pjallz') = 0) or (StrComp(@base[0], 'pjalsxz') = 0) then
      Exit(DetectTakes(@base[0], src, n));
    Exit;
  end;
  { a z codec takes what its codec does: pjaz, pja's files, and so on }
  if (k >= 2) and (k < Length(base)) and (codecName[k - 1] = 'z') then begin
    StrLCopy(@base[0], codecName, k - 1);
    if (StrComp(@base[0], 'pja') = 0) or (StrComp(@base[0], 'pjals') = 0) or (StrComp(@base[0], 'pjax') = 0) or
       (StrComp(@base[0], 'pjall') = 0) or (StrComp(@base[0], 'pjalsx') = 0) or
       (StrComp(@base[0], 'pja7') = 0) or (StrComp(@base[0], 'pjax7') = 0) then
      Exit(DetectTakes(@base[0], src, n));
    Exit;
  end;
  { the JPEG 2000 codec }
  if StrComp(codecName, PJK_NAME) = 0 then Exit(Ord(PjkDetect(src, n)));
  try
    if (StrComp(codecName, 'pja') = 0) or (StrComp(codecName, 'pjax') = 0) or (StrComp(codecName, 'pjall') = 0) or
       (StrComp(codecName, 'pja7') = 0) or (StrComp(codecName, 'pjax7') = 0) then begin
      { the three verify the JPEG the same way: once for all of them }
      h := BytesHash(src, n);
      if not FindVerdict(n, h, v) then begin
        v := Default(TVerdict);
        v.size := n; v.hash := h; v.used := True;
        d := Bytes(src, n);
        v.rt := (d[0] = $FF) and (d[1] = $D8) and not IsJls(d) and VerifyRoundTrip(d, j).Ok;
        if v.rt then begin
          { pja: 8-bit DCT with its height in the frame and its restarts
            where its DRI says: the ZPAQL decoder is frozen as v0.0.1 left
            it, which had neither 12-bit nor lossless JPEG nor DNL nor
            ignored DRIs, nor another encoder's correction bits' limit
            (0.0.8) }
          v.pja := (j.precision = 8) and not j.lossless and not j.dnl and not HasIgnoredRestarts(j) and
                   not HasCorrectionLimits(j) and (Length(j.scans) <= ZPAQL_MAX_SCANS) and
                   (ZpaqlPh(j) <= ZPAQL_MAX_PH);
          { pjax: a Huffman JPEG with what only version 6 holds: 12 bits, a
            DNL, a DRI with no restarts (pja takes none of them), or JPEGs
            after its EOI of PJAX_MIN_AFTER bytes or more. A camera's
            thumbnails gain a few KB, which do not pay pjax's ZPAQL nor the
            pja block they would split: those files are pja's }
          if not j.arithmetic and not j.lossless and not HasCorrectionLimits(j) and
             (Length(j.scans) <= ZPAQL_MAX_SCANS) then begin
            w := ZpaqlPjaxFileWords(d, j, after);
            v.pjax := ((after >= PJAX_MIN_AFTER) or (j.precision = 12) or j.dnl or HasIgnoredRestarts(j)) and
                      (w >= 0) and (Log2Words(w) <= ZPAQL_MAX_PH);
            { pjax7: the same files, version 7's decoder's memory }
            w := ZpaqlPjaxFileWords(d, j, after, True);
            v.pjax7 := ((after >= PJAX_MIN_AFTER) or (j.precision = 12) or j.dnl or HasIgnoredRestarts(j)) and
                       (w >= 0) and (Log2Words(w) <= ZPAQL_MAX_PH);
          end;
          { pja7: what pja takes, version 7's decoder's memory }
          v.pja7 := (j.precision = 8) and not j.lossless and not j.dnl and not HasIgnoredRestarts(j) and
                    not HasCorrectionLimits(j) and (Length(j.scans) <= ZPAQL_MAX_SCANS) and
                    (Log2Words(ZpaqlWords7(j)) <= ZPAQL_MAX_PH);
          { pjall: a lossless JPEG (SOF3), its restarts where its DRI says:
            no other codec takes it }
          v.pjall := j.lossless and not j.arithmetic and not HasIgnoredRestarts(j) and
                     (Length(j.scans) <= ZPAQL_MAX_SCANS) and (Log2Words(ZpaqlLjpegWords(j)) <= ZPAQL_MAX_PH);
        end;
        KeepVerdict(v);
      end;
      if StrComp(codecName, 'pja') = 0 then Result := Ord(v.pja)
      else if StrComp(codecName, 'pjax') = 0 then Result := Ord(v.pjax)
      else if StrComp(codecName, 'pja7') = 0 then Result := Ord(v.pja7)
      else if StrComp(codecName, 'pjax7') = 0 then Result := Ord(v.pjax7)
      else Result := Ord(v.pjall);
    end else if StrComp(codecName, 'pjalsx') = 0 then begin
      { JPEG-LS with subsampled components, which pjals' frozen ZPAQL has
        not; compress() keeps the smaller of the two models: either has to
        fit }
      d := Bytes(src, n);
      if IsJls(d) and VerifyJls(d, jl).Ok and JlsSubsampled(jl) and (Length(jl.scans) <= ZPAQL_LS_MAX_SCANS) and
         (Log2Words(ZpaqlJlsxWords(jl, False)) <= ZPAQL_MAX_PH) and
         (Log2Words(ZpaqlJlsxWords(jl, True)) <= ZPAQL_MAX_PH) then Result := 1;
    end else if StrComp(codecName, 'pjals') = 0 then begin
      d := Bytes(src, n);
      { compress() keeps the smaller of the two models: either has to fit }
      if IsJls(d) and VerifyJls(d, jl).Ok and not JlsSubsampled(jl) and (Length(jl.scans) <= ZPAQL_LS_MAX_SCANS) and
         (ZpaqlJlsPh(jl, False) <= ZPAQL_MAX_PH) and (ZpaqlJlsPh(jl, True) <= ZPAQL_MAX_PH) then Result := 1;
    end;
  except
    Result := 0;
  end;
end;

type TFormatKind = (fkNone, fkJpeg, fkJls, fkJ2k);

{ the format a codec's name is for: its base with the o, 8 and z of its
  variants taken off (pjalsxz8: pjalsx) }
function FormatOf(codecName: PChar): TFormatKind;
var b: AnsiString;
begin
  Result := fkNone;
  if codecName = nil then Exit;
  b := codecName;
  if b = PJK_NAME then Exit(fkJ2k);
  while (Length(b) > 3) and (b[Length(b)] in ['8', 'o', 'z']) do SetLength(b, Length(b) - 1);
  if (b = 'pja') or (b = 'pjax') or (b = 'pja7') or (b = 'pjax7') or (b = 'pjall') then Result := fkJpeg
  else if (b = 'pjals') or (b = 'pjalsx') then Result := fkJls;
end;

{ 1 if the codec takes the file; 2 (zpaq-std 2.9.0, +rcmd) if the file is
  of the codec's format but the codec does not take it, so that zpaq-std
  stores it with the card's fallback_ma / fallback_m; else 0. By the bytes
  only, like the rest: a JPEG starts FF D8 FF and is not JPEG-LS, a JPEG-LS
  file is what pjajls.IsJls says, a JPEG 2000 file what J2kKind says }
function zpaqstd_detect_v1(codecName: PChar; src: Pointer; n: SizeUInt): LongInt; cdecl;
var d: TBytes; k: TFormatKind; mine: Boolean;
begin
  Result := DetectTakes(codecName, src, n);
  if Result <> 0 then Exit;
  k := FormatOf(codecName);
  if (k = fkNone) or (src = nil) or (n < 4) then Exit;
  try
    mine := False;
    case k of
      fkJpeg, fkJls:
        if (PByte(src)[0] = $FF) and (PByte(src)[1] = $D8) and (PByte(src)[2] = $FF) then begin
          d := Bytes(src, n);
          mine := IsJls(d) = (k = fkJls);
        end;
      fkJ2k: begin d := Bytes(src, n); mine := J2kKind(d) <> jkNone; end;
    end;
    if mine then Result := 2;
  except
    Result := 0;
  end;
end;

const
  ZS_DATA_INFO = 3;
  { the card zpaq-std shows in codecinfoex: key=value lines. The commit is
    the one build.sh sets in PJA_COMMIT, empty when built otherwise }
  INFO: AnsiString =
    'name=pja'#10 +
    'version=' + PJA_VERSION + ' (stream v5 full)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v5, model byte 0 (the full model) of a JPEG'#10 +
    'notes=lossless: the original rebuilt byte for byte; ZPAQL decoder: JPEG, Huffman and arithmetic, sequential and progressive (JPEG-LS: the pjals codec)'#10;
  INFO_X: AnsiString =
    'name=pjax'#10 +
    'version=' + PJA_VERSION + ' (stream v6)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v6 (or v5) of a Huffman JPEG: the JPEGs inside it as JPEGs, 12 bits, DNL, a DRI with no restarts'#10 +
    'notes=lossless: the original rebuilt byte for byte; for the JPEGs pja leaves its embedded ones raw in (EXIF thumbnails, MPO, Ultra HDR); try it before pja'#10;
  INFO_LL: AnsiString =
    'name=pjall'#10 +
    'version=' + PJA_VERSION + ' (stream v5)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v5 of a lossless JPEG (SOF3, Huffman): its samples through the JPEG-LS samples model'#10 +
    'notes=lossless: the original rebuilt byte for byte; 2 to 16 bits, predictors 1 to 7, point transform, restarts, DNL'#10;
  INFO_LSX: AnsiString =
    'name=pjalsx'#10 +
    'version=' + PJA_VERSION + ' (stream v5)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v5 of a JPEG-LS file with subsampled components (samples or symbols model)'#10 +
    'notes=lossless: the original rebuilt byte for byte; what pjals takes, with components of other sizes than the frame (T.87 sampling factors)'#10;
  INFO_LS: AnsiString =
    'name=pjals'#10 +
    'version=' + PJA_VERSION + ' (stream v5)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v5 of a JPEG-LS file (samples or symbols model)'#10 +
    'notes=lossless: the original rebuilt byte for byte; JPEG-LS lossless and near-lossless, any interleave, LSE presets and restarts'#10;

  { the z codecs' cards: their codec's, with what the block holds }
  Z_FORMAT = 'format=its codec''s stream (%s) through zpaq''s level 1 LZ77 (-m1, rb 0), matches reaching back into the block''s segments before it'#10;
  Z_NOTES = 'notes=lossless; the same files and streams as %s: zpaq-std makes the LZ77 across a block''s files; ZPAQL config comp 0 0 $3 $1 0, $1 the window''s bits'#10;

function ZCard(const name, base, stream: AnsiString): AnsiString;
begin
  Result := 'name=' + name + #10 +
    'version=' + PJA_VERSION + ' (' + stream + ', LZ77)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    Format(Z_FORMAT, [base]) + Format(Z_NOTES, [base]);
end;

var
  InfoPjk: AnsiString;
  { INFO and the other constant cards, with their fallback keys }
  InfoJ, InfoJx, InfoJll, InfoJlsx, InfoJls: AnsiString;
  InfoZ, InfoLsZ, InfoXZ, InfoLlZ, InfoLsxZ: AnsiString;
  Info7, InfoX7, Info7Z, InfoX7Z: AnsiString;
  InfoLsO, InfoLlO, InfoLsxO, InfoLsZO, InfoLlZO, InfoLsxZO: AnsiString;
  Info78, InfoX78, Info7Z8, InfoX7Z8, InfoLs8, InfoLl8, InfoLsx8, InfoLsZ8, InfoLlZ8, InfoLsxZ8: AnsiString;

const
  OPT3 = 'opt=3 (3 to 8% smaller than opt=2)';

{ the o and 8 codecs' cards: their codec's, renamed, and what differs }
function OCard(const name, card: AnsiString; const how: AnsiString = 'opt=2 (about half the bytes)'): AnsiString;
var base: AnsiString;
begin
  base := Copy(card, 6, Pos(#10, card) - 6);
  Result := 'name=' + name + Copy(card, Pos(#10, card), MaxInt);
  Result := StringReplace(Result, 'notes=', 'notes=' + base + '''s streams, files and H, its ZPAQL compiled with zpaqlc''s ' + how + '; ', []);
end;

{ the version 7 codecs' cards: pja's and pjax's, version 7's coefficients }
function Card7(const name, base, stream: AnsiString; z: Boolean): AnsiString;
begin
  Result := 'name=' + name + #10 +
    'version=' + PJA_VERSION + ' (' + stream + ')'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=what ' + base + ' writes, its coefficients with stream version 7''s model';
  if z then Result := Result + ', through zpaq''s level 1 LZ77 across a block''s files (as ' + base + 'z)';
  Result := Result + #10'notes=lossless; the same files as ' + base + '; ZPAQL config comp 0 0 $3 ';
  if z then Result := Result + '$1 0, $1 the window''s bits'#10 else Result := Result + '$1+1 0'#10;
end;

{ data(): the ZPAQL decoder (as ZS_DATA_ZPAQL_ARGS: its H comes from the
  query) and the card; anything else, ZS_DATA_ZPAQL included, nil }
function DataOf(const zpaql, card: AnsiString; what: LongInt; size: PSizeUInt): Pointer;
begin
  if what = ZS_DATA_ZPAQL_ARGS then begin
    if size <> nil then size^ := Length(zpaql) + 1;
    Exit(PAnsiChar(zpaql));
  end;
  if what = ZS_DATA_INFO then begin
    if size <> nil then size^ := Length(card);
    Result := PAnsiChar(card);
  end else begin
    if size <> nil then size^ := 0;
    Result := nil;
  end;
end;

function PjkData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJK_ZPAQL, InfoPjk, what, size);
end;

function XData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX_ZPAQL, InfoJx, what, size);
end;

function LsxData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSX_ZPAQL, InfoJlsx, what, size);
end;

function LlData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALL_ZPAQL, InfoJll, what, size);
end;

function CodecData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA_ZPAQL, InfoJ, what, size);
end;

function LsData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALS_ZPAQL, InfoJls, what, size);
end;

function Pja7Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA7_ZPAQL, Info7, what, size);
end;

function X7Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX7_ZPAQL, InfoX7, what, size);
end;

function Pja7ZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA7Z_ZPAQL, Info7Z, what, size);
end;

function X7ZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX7Z_ZPAQL, InfoX7Z, what, size);
end;

function ZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAZ_ZPAQL, InfoZ, what, size);
end;

function LsZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSZ_ZPAQL, InfoLsZ, what, size);
end;

function XZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAXZ_ZPAQL, InfoXZ, what, size);
end;

function LlZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALLZ_ZPAQL, InfoLlZ, what, size);
end;

function LsxZData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSXZ_ZPAQL, InfoLsxZ, what, size);
end;

function Pja78Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA78_ZPAQL, Info78, what, size);
end;

function X78Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX78_ZPAQL, InfoX78, what, size);
end;

function Pja7Z8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA7Z8_ZPAQL, Info7Z8, what, size);
end;

function X7Z8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX7Z8_ZPAQL, InfoX7Z8, what, size);
end;

function Ls8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALS8_ZPAQL, InfoLs8, what, size);
end;

function Ll8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALL8_ZPAQL, InfoLl8, what, size);
end;

function Lsx8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSX8_ZPAQL, InfoLsx8, what, size);
end;

function LsZ8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSZ8_ZPAQL, InfoLsZ8, what, size);
end;

function LlZ8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALLZ8_ZPAQL, InfoLlZ8, what, size);
end;

function LsxZ8Data(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSXZ8_ZPAQL, InfoLsxZ8, what, size);
end;

function LsOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSO_ZPAQL, InfoLsO, what, size);
end;

function LlOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALLO_ZPAQL, InfoLlO, what, size);
end;

function LsxOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSXO_ZPAQL, InfoLsxO, what, size);
end;

function LsZOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSZO_ZPAQL, InfoLsZO, what, size);
end;

function LlZOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALLZO_ZPAQL, InfoLlZO, what, size);
end;

function LsxZOData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALSXZO_ZPAQL, InfoLsxZO, what, size);
end;

const
  ZsCodec: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'pja';
    library_: 'pja stream v5 full (YadeWira/PJA)';
    min_level: LEVEL_FULL;
    max_level: LEVEL_FULL;
    bound: @CodecBound;
    compress_: @CodecCompress;
    decompress_: @CodecDecompress;
    query: @CodecQuery;
    data: @CodecData
  );

  ZsCodecLs: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'pjals';
    library_: 'pja stream v5 jpeg-ls (YadeWira/PJA)';
    min_level: LEVEL_FULL;
    max_level: LEVEL_FULL;
    bound: @CodecBound;
    compress_: @LsCompress;
    decompress_: @CodecDecompress;
    query: @LsQuery;
    data: @LsData
  );

  ZsCodecX: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'pjax';
    library_: 'pja stream v6 pjax (YadeWira/PJA)';
    min_level: LEVEL_FULL;
    max_level: LEVEL_FULL;
    bound: @CodecBound;
    compress_: @XCompress;
    decompress_: @XDecompress;
    query: @XQuery;
    data: @XData
  );

  ZsCodecLl: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'pjall';
    library_: 'pja stream v5 lossless jpeg (YadeWira/PJA)';
    min_level: LEVEL_FULL;
    max_level: LEVEL_FULL;
    bound: @CodecBound;
    compress_: @LlCompress;
    decompress_: @CodecDecompress;
    query: @LlQuery;
    data: @LlData
  );

  ZsCodecLsx: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'pjalsx';
    library_: 'pja stream v5 jpeg-ls subsampled (YadeWira/PJA)';
    min_level: LEVEL_FULL;
    max_level: LEVEL_FULL;
    bound: @CodecBound;
    compress_: @LsxCompress;
    decompress_: @CodecDecompress;
    query: @LsxQuery;
    data: @LsxData
  );

  { the z codecs: the library field is their codec's with ", lz77" }
  ZsCodecZ: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjaz'; library_: 'pja stream v5 full, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress;
    query: @CodecQuery; data: @ZData);

  ZsCodecLsZ: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsz'; library_: 'pja stream v5 jpeg-ls, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsCompress; decompress_: @CodecDecompress;
    query: @LsQuery; data: @LsZData);

  ZsCodecXZ: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjaxz'; library_: 'pja stream v6 pjax, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @XCompress; decompress_: @XDecompress;
    query: @XQuery; data: @XZData);

  ZsCodecLlZ: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjallz'; library_: 'pja stream v5 lossless jpeg, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LlCompress; decompress_: @CodecDecompress;
    query: @LlQuery; data: @LlZData);

  ZsCodecLsxZ: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsxz'; library_: 'pja stream v5 jpeg-ls subsampled, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsxCompress; decompress_: @CodecDecompress;
    query: @LsxQuery; data: @LsxZData);

  { version 7 (0.6.0): pja's and pjax's files, version 7's coefficients;
    their z, as pjaz and pjaxz }
  ZsCodec7: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pja7'; library_: 'pja stream v7 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @Pja7Compress; decompress_: @CodecDecompress;
    query: @Pja7Query; data: @Pja7Data);

  ZsCodecX7: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjax7'; library_: 'pja stream v6 pjax, v7 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @X7Compress; decompress_: @X7Decompress;
    query: @X7Query; data: @X7Data);

  ZsCodec7Z: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pja7z'; library_: 'pja stream v7, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @Pja7Compress; decompress_: @CodecDecompress;
    query: @Pja7Query; data: @Pja7ZData);

  ZsCodecX7Z: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjax7z'; library_: 'pja stream v6 pjax, v7, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @X7Compress; decompress_: @X7Decompress;
    query: @X7Query; data: @X7ZData);

  { the o codecs (0.7.0): their codec's library field, streams and
    functions; only the ZPAQL differs }
  ZsCodecLsO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalso'; library_: 'pja stream v5 jpeg-ls (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsCompress; decompress_: @CodecDecompress;
    query: @LsQuery; data: @LsOData);

  ZsCodecLlO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjallo'; library_: 'pja stream v5 lossless jpeg (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LlCompress; decompress_: @CodecDecompress;
    query: @LlQuery; data: @LlOData);

  ZsCodecLsxO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsxo'; library_: 'pja stream v5 jpeg-ls subsampled (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsxCompress; decompress_: @CodecDecompress;
    query: @LsxQuery; data: @LsxOData);

  ZsCodecLsZO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalszo'; library_: 'pja stream v5 jpeg-ls, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsCompress; decompress_: @CodecDecompress;
    query: @LsQuery; data: @LsZOData);

  ZsCodecLlZO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjallzo'; library_: 'pja stream v5 lossless jpeg, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LlCompress; decompress_: @CodecDecompress;
    query: @LlQuery; data: @LlZOData);

  ZsCodecLsxZO: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsxzo'; library_: 'pja stream v5 jpeg-ls subsampled, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsxCompress; decompress_: @CodecDecompress;
    query: @LsxQuery; data: @LsxZOData);

  { the 8 codecs (0.8.0): their codec's library field, streams and
    functions; only the ZPAQL differs (opt=3) }
  ZsCodec78: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pja78'; library_: 'pja stream v7 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @Pja7Compress; decompress_: @CodecDecompress;
    query: @Pja7Query; data: @Pja78Data);

  ZsCodecX78: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjax78'; library_: 'pja stream v6 pjax, v7 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @X7Compress; decompress_: @X7Decompress;
    query: @X7Query; data: @X78Data);

  ZsCodec7Z8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pja7z8'; library_: 'pja stream v7, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @Pja7Compress; decompress_: @CodecDecompress;
    query: @Pja7Query; data: @Pja7Z8Data);

  ZsCodecX7Z8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjax7z8'; library_: 'pja stream v6 pjax, v7, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @X7Compress; decompress_: @X7Decompress;
    query: @X7Query; data: @X7Z8Data);

  ZsCodecLs8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjals8'; library_: 'pja stream v5 jpeg-ls (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsCompress; decompress_: @CodecDecompress;
    query: @LsQuery; data: @Ls8Data);

  ZsCodecLl8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjall8'; library_: 'pja stream v5 lossless jpeg (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LlCompress; decompress_: @CodecDecompress;
    query: @LlQuery; data: @Ll8Data);

  ZsCodecLsx8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsx8'; library_: 'pja stream v5 jpeg-ls subsampled (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsxCompress; decompress_: @CodecDecompress;
    query: @LsxQuery; data: @Lsx8Data);

  ZsCodecLsZ8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsz8'; library_: 'pja stream v5 jpeg-ls, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsCompress; decompress_: @CodecDecompress;
    query: @LsQuery; data: @LsZ8Data);

  ZsCodecLlZ8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjallz8'; library_: 'pja stream v5 lossless jpeg, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LlCompress; decompress_: @CodecDecompress;
    query: @LlQuery; data: @LlZ8Data);

  ZsCodecLsxZ8: TZsCodec = (
    abi: ZS_CODEC_ABI; name: 'pjalsxz8'; library_: 'pja stream v5 jpeg-ls subsampled, lz77 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @LsxCompress; decompress_: @CodecDecompress;
    query: @LsxQuery; data: @LsxZ8Data);

  { the JPEG 2000 codec (0.9.6) }
  ZsCodecPjk: TZsCodec = (
    abi: ZS_CODEC_ABI; name: PJK_NAME; library_: 'pja stream v8 jpeg 2000 (YadeWira/PJA)';
    min_level: LEVEL_FULL; max_level: LEVEL_FULL;
    bound: @CodecBound; compress_: @PjkCompressFn; decompress_: @PjkDecompressFn;
    query: @PjkQuery; data: @PjkData);

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @ZsCodec;
end;

function zpaqstd_codecs_v1(i: LongInt): PZsCodec; cdecl;
begin
  case i of
    0: Result := @ZsCodec;
    1: Result := @ZsCodecLs;
    2: Result := @ZsCodecX;
    3: Result := @ZsCodecLl;
    4: Result := @ZsCodecLsx;
    5: Result := @ZsCodecZ;
    6: Result := @ZsCodecLsZ;
    7: Result := @ZsCodecXZ;
    8: Result := @ZsCodecLlZ;
    9: Result := @ZsCodecLsxZ;
    10: Result := @ZsCodec7;
    11: Result := @ZsCodecX7;
    12: Result := @ZsCodec7Z;
    13: Result := @ZsCodecX7Z;
    14: Result := @ZsCodecLsO;
    15: Result := @ZsCodecLlO;
    16: Result := @ZsCodecLsxO;
    17: Result := @ZsCodecLsZO;
    18: Result := @ZsCodecLlZO;
    19: Result := @ZsCodecLsxZO;
    20: Result := @ZsCodec78;
    21: Result := @ZsCodecX78;
    22: Result := @ZsCodec7Z8;
    23: Result := @ZsCodecX7Z8;
    24: Result := @ZsCodecLs8;
    25: Result := @ZsCodecLl8;
    26: Result := @ZsCodecLsx8;
    27: Result := @ZsCodecLsZ8;
    28: Result := @ZsCodecLlZ8;
    29: Result := @ZsCodecLsxZ8;
    30: Result := @ZsCodecPjk;
  else Result := nil;
  end;
end;

{ FPC 3.2.2 exports these names as written on Darwin too, where the C
  symbol of dlsym("zpaqstd_codecs_v1") is "_zpaqstd_codecs_v1": the
  underscore goes in by hand there. }
{$ifdef darwin}
exports
  zpaqstd_codec_v1 name '_zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name '_zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name '_zpaqstd_detect_v1',
  zpaqstd_threads_v1 name '_zpaqstd_threads_v1';
{$else}
exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name 'zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name 'zpaqstd_detect_v1',
  zpaqstd_threads_v1 name 'zpaqstd_threads_v1';
{$endif}

{ zpaq-std 2.9.0's +rcmd: the method for the files of a codec's format it
  does not take (detect 2) or that give no gain, the best first, measured
  on PJA's test sets (doc/CODEC.md, "zpaq-std +rcmd") }
const
  FALLBACK: array[TFormatKind] of AnsiString = (
    '',
    'fallback_ma=flzma2:10,uflzma2:11,lzma:9,lz:9,zstd:19'#10'fallback_m=3,4,5,2,1'#10,
    'fallback_ma=flzma2:10,uflzma2:11,lz6hc:15,zstd:19,lzma:9'#10'fallback_m=3,4,5,2,1'#10,
    'fallback_ma=zstd:19,deflate:12,zxc:7,flzma2:10,lz6hc:15'#10'fallback_m=1,2,3,4,5'#10);

{ a card with its format's fallback keys after it }
procedure AddFallback(var card: AnsiString);
var name: AnsiString;
begin
  name := Copy(card, 6, Pos(#10, card) - 6);
  card := card + FALLBACK[FormatOf(PChar(name))];
end;

begin
  IsMultiThread := True;
  InitCriticalSection(VerdictLock);
  InfoPjk := 'name=' + PJK_NAME + #10 +
    'version=' + PJA_VERSION + ' (stream v8)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v8 of a JPEG 2000 file (JP2, J2K, J2C, JPX, JPM, MJ2, JPH): each codestream modelled ' +
    '(mode 1) or as bytes (mode 0), the rest through the raw bytes'' model'#10 +
    'notes=lossless: the original rebuilt byte for byte; Part 1 codestreams (not HTJ2K nor Part 2); ZPAQL config ' +
    'comp 0 0 $3 $4 0 (H and M from the query)'#10;
  InfoZ := ZCard('pjaz', 'pja', 'stream v5 full');
  InfoLsZ := ZCard('pjalsz', 'pjals', 'stream v5');
  InfoXZ := ZCard('pjaxz', 'pjax', 'stream v6');
  InfoLlZ := ZCard('pjallz', 'pjall', 'stream v5');
  InfoLsxZ := ZCard('pjalsxz', 'pjalsx', 'stream v5');
  Info7 := Card7('pja7', 'pja', 'stream v7', False);
  InfoX7 := Card7('pjax7', 'pjax', 'stream v6 pjax, v7', False);
  Info7Z := Card7('pja7z', 'pja', 'stream v7, LZ77', True);
  InfoX7Z := Card7('pjax7z', 'pjax', 'stream v6 pjax, v7, LZ77', True);
  InfoLsO := OCard('pjalso', INFO_LS);
  InfoLlO := OCard('pjallo', INFO_LL);
  InfoLsxO := OCard('pjalsxo', INFO_LSX);
  InfoLsZO := OCard('pjalszo', InfoLsZ);
  InfoLlZO := OCard('pjallzo', InfoLlZ);
  InfoLsxZO := OCard('pjalsxzo', InfoLsxZ);
  Info78 := OCard('pja78', Info7, OPT3);
  InfoX78 := OCard('pjax78', InfoX7, OPT3);
  Info7Z8 := OCard('pja7z8', Info7Z, OPT3);
  InfoX7Z8 := OCard('pjax7z8', InfoX7Z, OPT3);
  InfoLs8 := OCard('pjals8', INFO_LS, OPT3);
  InfoLl8 := OCard('pjall8', INFO_LL, OPT3);
  InfoLsx8 := OCard('pjalsx8', INFO_LSX, OPT3);
  InfoLsZ8 := OCard('pjalsz8', InfoLsZ, OPT3);
  InfoLlZ8 := OCard('pjallz8', InfoLlZ, OPT3);
  InfoLsxZ8 := OCard('pjalsxz8', InfoLsxZ, OPT3);
  InfoJ := INFO; InfoJx := INFO_X; InfoJll := INFO_LL; InfoJlsx := INFO_LSX; InfoJls := INFO_LS;
  AddFallback(InfoJ); AddFallback(InfoJx); AddFallback(InfoJll); AddFallback(InfoJlsx); AddFallback(InfoJls);
  AddFallback(InfoPjk);
  AddFallback(InfoZ); AddFallback(InfoLsZ); AddFallback(InfoXZ); AddFallback(InfoLlZ); AddFallback(InfoLsxZ);
  AddFallback(Info7); AddFallback(InfoX7); AddFallback(Info7Z); AddFallback(InfoX7Z);
  AddFallback(InfoLsO); AddFallback(InfoLlO); AddFallback(InfoLsxO);
  AddFallback(InfoLsZO); AddFallback(InfoLlZO); AddFallback(InfoLsxZO);
  AddFallback(Info78); AddFallback(InfoX78); AddFallback(Info7Z8); AddFallback(InfoX7Z8);
  AddFallback(InfoLs8); AddFallback(InfoLl8); AddFallback(InfoLsx8);
  AddFallback(InfoLsZ8); AddFallback(InfoLlZ8); AddFallback(InfoLsxZ8);
end.

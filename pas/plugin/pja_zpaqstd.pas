{ pja_zpaqstd: PJA as a zpaq-std plugin for -sat / -sae (codecs for specific
  formats), on zpaq-std's plugin ABI 1 (compressors/plug/zs_codec.h in
  YadeWira/zpaq-std).

    pas/plugin/build.sh      -> codecs/pja.so, pja.dll (64 and 32 bits)

  Two exported C functions:
  - zpaqstd_codec_v1: the codec. compress() gets a file's block (the file and
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
    not ask sees none. data(ZS_DATA_INFO) is the card zpaq-std shows in
    codecinfoex.
  - zpaqstd_detect_v1: 1 if PJA takes the file, looking only at its bytes:
    only what the ZPAQL decoder covers, stage 3: a JPEG, Huffman or
    arithmetic, sequential or progressive, that PJA's layer 1 rebuilds byte
    for byte and that fits the decoder's memory. JPEG-LS comes later. No global state, so several threads can ask at once.

  Levels: 2 = the full model, the stream frozen as pja5-full (stream version
  5, model byte 0). The fast model (level 1) joins once its stream is frozen.

  CONTRACT with zpaq-std: the library field starts with "pja stream v5 full"
  for as long as this plugin writes and reads that stream. A later stream
  needs a new codec name or a new library field, never a silent change. }
library pja_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, pjajpeg, pjacodec, pjamodel, pjazpaqlargs;

const
  ZS_DATA_ZPAQL = 2;
  { a ZPAQL whose config uses $3 .. $5: only through this, so that a
    zpaq-std without the query below sees no ZPAQL at all }
  ZS_DATA_ZPAQL_ARGS = 4;
  ZS_QUERY_ZPAQL_ARGS = 2;
  ZPAQL_MAX_SCANS = 256;
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

function Bytes(src: Pointer; n: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, n);
  if n > 0 then Move(src^, Result[0], n);
end;

{ The stream is the JPEG modelled, so it is usually smaller; a file the
  codec cannot shrink comes out a little larger, and zpaq-std then stores it
  as -m says. }
function CodecBound(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
begin
  if n > MAX_BLOCK then Exit(0);
  Result := n + n div 4 + 65536;
end;

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var stream: TBytes; r: TCodecResult;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    { no verification here: zpaq-std decodes every block and compares }
    r := Compress(Bytes(src, n), stream, False, 1, False);
    if not r.Ok then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var jpeg: TBytes; r: TCodecResult;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) then Exit(ZS_ERR_DATA);
  try
    { the full model only: a stream of another model is not this codec's }
    if (n >= 2) and (PByte(src)[1] <> 0) then Exit(ZS_ERR_DATA);
    { cap is the original's exact size: the raw part cannot be larger }
    r := Decompress(Bytes(src, n), jpeg, SizeInt(cap), 1, SizeInt(cap));
    if not r.Ok or (SizeUInt(Length(jpeg)) <> cap) then Exit(ZS_ERR_DATA);
    if Length(jpeg) > 0 then Move(jpeg[0], dst^, Length(jpeg));
    Result := Length(jpeg);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

{ 1 if PJA takes the file: what its ZPAQL decoder covers (stage 3), so that
  no block is left without one: a JPEG, Huffman or arithmetic, sequential
  or progressive, that
  layer 1 rebuilds byte for byte, with at most ZPAQL_MAX_SCANS scans and
  whose decoding fits the decoder's memory. Only the bytes; deterministic;
  no shared state. }
{ query(ZS_QUERY_ZPAQL_ARGS): for compress()'s output, the $3 of the
  decoder's config (log2 of its H for this very file), or negative }
function CodecQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
begin
  Result := -1;
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) then Exit;
  try
    Result := ZpaqlArgs(Bytes(src, n));
  except
    Result := -1;
  end;
end;

function zpaqstd_detect_v1(codecName: PChar; src: Pointer; n: SizeUInt): LongInt; cdecl;
var d: TBytes; j: TJpeg;
begin
  Result := 0;
  if (codecName = nil) or (StrComp(codecName, 'pja') <> 0) or (n < 4) or (n > MAX_BLOCK) then Exit;
  try
    d := Bytes(src, n);
    if (d[0] = $FF) and (d[1] = $D8) and VerifyRoundTrip(d, j).Ok and
       (Length(j.scans) <= ZPAQL_MAX_SCANS) and
       (ZpaqlPh(j) <= ZPAQL_MAX_PH) then Result := 1;
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
    'format=PJA codec stream v5, model byte 0 (the full model); JPEG and JPEG-LS'#10 +
    'notes=lossless: the original rebuilt byte for byte; ZPAQL decoder stage 3: JPEG, Huffman and arithmetic, sequential and progressive'#10;

{ data(): the ZPAQL decoder (as ZS_DATA_ZPAQL_ARGS: its H comes from the
  query) and the card; anything else, ZS_DATA_ZPAQL included, nil }
function CodecData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  if what = ZS_DATA_ZPAQL_ARGS then begin
    if size <> nil then size^ := Length(PJA_ZPAQL) + 1;
    Exit(PAnsiChar(PJA_ZPAQL));
  end;
  if what = ZS_DATA_INFO then begin
    if size <> nil then size^ := Length(INFO);
    Result := PAnsiChar(INFO);
  end else begin
    if size <> nil then size^ := 0;
    Result := nil;
  end;
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

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @ZsCodec;
end;

exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1',
  zpaqstd_detect_v1 name 'zpaqstd_detect_v1';

begin
  IsMultiThread := True;
end.

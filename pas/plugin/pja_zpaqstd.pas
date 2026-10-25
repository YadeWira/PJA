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
  - zpaqstd_detect_v1: 1 if the codec named takes the file, looking only at
    its bytes: only what its ZPAQL decoder covers. pja: a JPEG, Huffman or
    arithmetic, sequential or progressive, that PJA's layer 1 rebuilds byte
    for byte and that fits the decoder's memory. pjals: a JPEG-LS file that
    comes back byte for byte (pjajls.VerifyJls) and fits its decoder's
    memory with either model. No global state, so several threads can ask
    at once.

  Levels: 2 = the full model, the stream frozen as pja5-full (stream version
  5, model byte 0). The fast model (level 1) joins once its stream is frozen.

  CONTRACT with zpaq-std: the library field starts with "pja stream v5 full"
  for as long as this plugin writes and reads that stream. A later stream
  needs a new codec name or a new library field, never a silent change. }
library pja_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, pjajpeg, pjajls, pjacodec, pjamodel, pjazpaqlargs;

const
  ZS_DATA_ZPAQL = 2;
  { a ZPAQL whose config uses $3 .. $5: only through this, so that a
    zpaq-std without the query below sees no ZPAQL at all }
  ZS_DATA_ZPAQL_ARGS = 4;
  ZS_QUERY_ZPAQL_ARGS = 2;
  { 1: the ZPAQL decodes several segments in one block (it starts afresh
    after each), so zpaq-std may put consecutive files of the codec there }
  ZS_QUERY_SEGMENTS = 3;
  ZPAQL_MAX_SCANS = 256;
  ZPAQL_LS_MAX_SCANS = 64;    { jls.zl's JMAXSCANS }
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

{ compress() of either codec: pja takes no JPEG-LS file and pjals nothing
  else, so that each block's stream is the one its ZPAQL decodes }
function CompressAs(ls: Boolean; src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64;
var stream, d: TBytes; r: TCodecResult; j: TJpeg; jl: TJls; symbols: Boolean;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    d := Bytes(src, n);
    if IsJls(d) <> ls then Exit(ZS_ERR_DATA);
    { no verification here: zpaq-std decodes every block and compares }
    { version 5 only: the stream its ZPAQL reads }
    r := Compress(d, stream, False, 1, False, False);
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
begin
  Result := CompressAs(False, src, n, dst, cap, level);
end;

function LsCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
begin
  Result := CompressAs(True, src, n, dst, cap, level);
end;

{ pjax: what CompressPjax writes, version 5 or 6, its ZPAQL's }
function XCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var stream: TBytes;
begin
  if (n > MAX_BLOCK) or (level <> LEVEL_FULL) then Exit(ZS_ERR_DATA);
  try
    { no verification here: zpaq-std decodes every block and compares }
    if not CompressPjax(Bytes(src, n), stream, False, 1).Ok then Exit(ZS_ERR_DATA);
    if ZpaqlPjaxArgs(stream) < 0 then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function XDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var jpeg: TBytes; r: TCodecResult;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) or (n < 2) then Exit(ZS_ERR_DATA);
  try
    { version 5 of the full model, or 6 without bytes }
    if not (((PByte(src)[0] = STREAM_VERSION) and (PByte(src)[1] = 0)) or
            ((PByte(src)[0] = STREAM_PARTS) and (PByte(src)[1] <= 1))) then Exit(ZS_ERR_DATA);
    r := Decompress(Bytes(src, n), jpeg, SizeInt(cap), 1, SizeInt(cap));
    if not r.Ok or (SizeUInt(Length(jpeg)) <> cap) then Exit(ZS_ERR_DATA);
    if Length(jpeg) > 0 then Move(jpeg[0], dst^, Length(jpeg));
    Result := Length(jpeg);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
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

function zpaqstd_detect_v1(codecName: PChar; src: Pointer; n: SizeUInt): LongInt; cdecl;
var d: TBytes; j: TJpeg; jl: TJls; w: Int64; hasParts: Boolean;
begin
  Result := 0;
  if (codecName = nil) or (n < 4) or (n > MAX_BLOCK) then Exit;
  try
    if StrComp(codecName, 'pja') = 0 then begin
      d := Bytes(src, n);
      { 8-bit DCT with its height in the frame and its restarts where its DRI
        says: the ZPAQL decoder is frozen as v0.0.1 left it, which had
        neither 12-bit nor lossless JPEG nor DNL nor ignored DRIs }
      if (d[0] = $FF) and (d[1] = $D8) and not IsJls(d) and VerifyRoundTrip(d, j).Ok and
         (j.precision = 8) and not j.lossless and not j.dnl and not HasIgnoredRestarts(j) and
         (Length(j.scans) <= ZPAQL_MAX_SCANS) and
         (ZpaqlPh(j) <= ZPAQL_MAX_PH) then Result := 1;
    end else if StrComp(codecName, 'pjax') = 0 then begin
      { a Huffman JPEG with what only version 6 holds: JPEGs inside it, 12
        bits, a DNL, a DRI with no restarts; the others are pja's }
      d := Bytes(src, n);
      if (d[0] = $FF) and (d[1] = $D8) and not IsJls(d) and VerifyRoundTrip(d, j).Ok and
         not j.arithmetic and not j.lossless and (Length(j.scans) <= ZPAQL_MAX_SCANS) then begin
        w := ZpaqlPjaxFileWords(d, j, hasParts);
        if (hasParts or (j.precision = 12) or j.dnl or HasIgnoredRestarts(j)) and (Log2Words(w) <= ZPAQL_MAX_PH) then
          Result := 1;
      end;
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
  INFO_LS: AnsiString =
    'name=pjals'#10 +
    'version=' + PJA_VERSION + ' (stream v5)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PJA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PJA_COMMIT%} + #10 +
    'format=PJA codec stream v5 of a JPEG-LS file (samples or symbols model)'#10 +
    'notes=lossless: the original rebuilt byte for byte; JPEG-LS lossless and near-lossless, any interleave, LSE presets and restarts'#10;

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

function XData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJAX_ZPAQL, INFO_X, what, size);
end;

function CodecData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJA_ZPAQL, INFO, what, size);
end;

function LsData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  Result := DataOf(PJALS_ZPAQL, INFO_LS, what, size);
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
  else Result := nil;
  end;
end;

exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name 'zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name 'zpaqstd_detect_v1';

begin
  IsMultiThread := True;
end.

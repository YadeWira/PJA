{ The zpaq-std plugin's JPEG 2000 codec (doc/CODEC.md, "JPEG 2000 for
  zpaq-std (stage E)"): a file of the JPEG 2000 family as stream version 8,
  each codestream in mode 1 (pjaj2km) when its ZPAQL decoder
  (pas/plugin/zpaql/j2k*.zl, j2kzpaql.inc) can rebuild it within its limits
  and memory, in mode 0 otherwise; never mode 2 (the pixels), which the
  ZPAQL has not.

  The codec's names are PROVISIONAL until the owner approves them: they are
  here only (PJK_NAME), and frozen once released.

  - PjkDetect: the file is of the family and one of its codestreams at least
    looks takeable from its main header (not HTJ2K nor Part 2, the SIZ and
    the levels within the ZPAQL's limits); only its bytes.
  - PjkCompress: pjacodec's version 8 stream with this unit's mode 1 (the
    hook J2kMode1Enc, set here): a codestream goes in mode 1 when its stream
    is smaller and the ZPAQL's limits hold for it (PjkFits); its H and M are
    kept for the query (a few entries, by the stream's BLAKE3). A file
    whose codestreams all stay in mode 0 is refused (nothing to gain, and
    the block would carry the ZPAQL).
  - PjkArgs: the query's $3 | $4 << 8 for a stream: log2 of the words of H
    and of the bytes of M the ZPAQL takes; kept from compress, or worked
    out again from the stream (decoded, each codestream analysed again).
  - PjkDecompress: a version 8 stream of modes 0 and 1 only. }
unit pjazsj2k;

{$mode objfpc}{$H+}

interface

uses SysUtils, pjacodec, pjaj2k, pjaj2kcs, pjaj2km, pjablake3, pjaarith, pjamodel;

{$I j2kzpaql.inc}

const
  { the codec's name: PROVISIONAL (it may not end in z, o or 8, which
    zpaqstd_detect_v1 reads as other codecs' suffixes) }
  PJK_NAME = 'pja2k';
  { the ZPAQL's limits: 2^26 words of H, 2^28 bytes of M }
  PJK_MAX_PH = 26;
  PJK_MAX_PM = 28;
  { what j2kcs.zl's 32-bit arithmetic is exact for (pjazsj2k's checks):
    every SIZ value below 2^30, at most 256 components, 20 levels, bands of
    Mb 24 and sides of 65,535 at most }
  PJK_MAX_SIZ = 1 shl 30;
  PJK_MAX_COMPS = 256;
  PJK_MAX_NL = 20;
  PJK_MAX_MB = 24;
  PJK_MAX_DIM = 65535;

function PjkDetect(src: PByte; n: SizeUInt): Boolean;
function PjkCompress(const data: TBytes; out stream: TBytes; threads: Integer): Boolean;
function PjkArgs(const stream: TBytes): Int64;
function PjkDecompress(const stream: TBytes; cap: SizeInt; threads: Integer; out data: TBytes): Boolean;
{ the words of H and bytes of M the ZPAQL takes for a stream (-1: refused) }
function PjkMemory(const stream: TBytes; out words, bytes: Int64): Boolean;

implementation

const
  ARGS_SLOTS = 64;

type
  TArgsSlot = record used: Boolean; size: SizeInt; hash: THash16; args: Int64; end;

var
  ArgsSlots: array[0..ARGS_SLOTS - 1] of TArgsSlot;
  ArgsNext: Integer = 0;
  ArgsLock: TRTLCriticalSection;

threadvar
  { compress on this thread: the largest words and bytes a codestream of
    mode 1 needs (the host's and the segment's come on top), and how many }
  CsWords, CsBytes, CsCount: Int64;
  { the file's length (PjkFits' bound of the host) }
  FileLen: Int64;

{ pjadec.zl's coderaw: the bytes, its order-2 map or table, its mixer }
function RawWords(n: Int64): Int64;
var bits: Integer;
begin
  Result := n + 4;
  bits := 1;
  while (Int64(1) shl bits) < 16 * n do Inc(bits);
  if bits + 1 >= 22 then Inc(Result, Int64(1) shl 22)
  else Inc(Result, Int64(2) shl bits);
  Inc(Result, 12 + 8 * 8);
end;

function Log2Of(v: Int64): Integer;
begin
  Result := 0;
  while (Int64(1) shl Result) < v do Inc(Result);
end;

{ j2kcs.zl's allocations for one tile: words of H (an upper bound) and
  bytes of M (the maps, the largest code-block's scratch, the code-blocks'
  bytes and the packets, each at most the tile's bytes) }
procedure TileCost(const c: TJ2kTileCounts; out words, bytes: Int64);
begin
  words := 4 * c.ncomp + 100 * c.items + 6 * c.pocs + 1 + 9 * c.ncomp + 79 * c.nres + 14 * c.ncb + 5 * c.nprec + 1 +
    c.ncomp + c.nbands + 9 * c.npk + 2 + 7 * c.npb + 4 * c.nodes + 6 * c.nie + 4 * c.npc;
  bytes := c.mapNeed + 7 * c.maxCap + 192 + 2 * c.tileBytes;
end;

{ the model's tables at 2^hb counters at most: two words a counter }
function TableWords(hb: Integer): Int64;
var i: Integer; r: Int64;
begin
  Result := 0;
  for i := 0 to 7 do begin
    r := J2K_ZPAQL_RANGES[i];
    if r > Int64(1) shl hb then r := Int64(1) shl hb;
    Result := Result + 2 * r;
  end;
end;

{ pjaj2kcs.StartSlice's tables' bits for a codestream of len bytes in s slices }
function SliceHb(len: Int64; s: Integer): Integer;
begin
  Result := KM_HBMIN;
  while (Result < KM_HBMAX) and ((Int64(1) shl (Result + 1)) < len div s) do Inc(Result);
end;

function U32(const b: TBytes; p: SizeInt): Int64;
begin
  Result := Int64(b[p]) or (Int64(b[p + 1]) shl 8) or (Int64(b[p + 2]) shl 16) or (Int64(b[p + 3]) shl 24);
end;

{ whether j2kcs.zl takes a codestream so analysed: its arithmetic exact, its
  memory within the limits (the host bounded by the file); its words and
  bytes }
function PjkFits(const st: TJ2kStats; const stream: TBytes; len, blobLen: Int64; out words, bytes: Int64): Boolean;
var s: Integer;
begin
  Result := False; words := 0; bytes := 0;
  if (st.zSiz >= PJK_MAX_SIZ) or (st.zNcomp > PJK_MAX_COMPS) or (st.zMaxNl > PJK_MAX_NL) or
     (st.zMaxMb > PJK_MAX_MB) or (st.zMaxDim > PJK_MAX_DIM) or (Length(stream) < 13) then Exit;
  s := U32(stream, 5);
  if (s < 1) or (s > J2K_MAX_SLICES) then Exit;
  words := RawWords(blobLen) + 2 * s + st.zHdr + TableWords(SliceHb(len, s)) + st.zTileWords;
  bytes := len + st.zTileBytes;
  Result := (J2K_ZPAQL_STATIC_WORDS + RawWords(FileLen) + words + 64 <= Int64(1) shl PJK_MAX_PH) and
            (2 * FileLen + 1024 + bytes <= Int64(1) shl PJK_MAX_PM);
end;

{ mode 1 for the plugin (pjacodec's hook): pjaj2km's, when PjkFits }
function PjkMode1Enc(const data: TBytes; off, len: Int64; threads: Integer; decodeIt: Boolean;
  out stream: TBytes): Boolean;
var why: string; st: TJ2kStats; blobLen, w, b: Int64;
begin
  Result := (J2kMode1EncodeSt(data, off, len, threads, decodeIt, stream, why, st, blobLen) = m1Ok) and
            PjkFits(st, stream, len, blobLen, w, b);
  if not Result then begin stream := nil; Exit; end;
  if w > CsWords then CsWords := w;
  if b > CsBytes then CsBytes := b;
  Inc(CsCount);
end;

{ the stream's H and M: the static words, the host's raw bytes and the
  largest codestream's; the segment (the size and the stream), 16 bytes,
  the largest codestream's }
function Finish(const stream: TBytes; out words, bytes: Int64): Boolean;
var k, i: Integer; host: Int64;
begin
  Result := False;
  if (Length(stream) < 6) or (stream[0] <> STREAM_J2K) or (stream[1] <> 0) then Exit;
  k := U32(stream, 2);
  if 6 + 13 * Int64(k) > Length(stream) then Exit;
  host := FileLen;
  for i := 0 to k - 1 do begin
    if stream[6 + 13 * i + 12] > 1 then Exit;
    if stream[6 + 13 * i + 12] = 1 then host := host - U32(stream, 6 + 13 * i + 4);
  end;
  words := J2K_ZPAQL_STATIC_WORDS + RawWords(host) + CsWords + 64;
  bytes := 4 + Length(stream) + 16 + CsBytes + 64;
  Result := (Log2Of(words) <= PJK_MAX_PH) and (Log2Of(bytes) <= PJK_MAX_PM);
end;

procedure KeepArgs(const stream: TBytes; args: Int64);
var b: TBlake3;
begin
  b.Init; b.Update(stream[0], Length(stream));
  EnterCriticalSection(ArgsLock);
  try
    ArgsSlots[ArgsNext].used := True; ArgsSlots[ArgsNext].size := Length(stream);
    ArgsSlots[ArgsNext].hash := b.Final; ArgsSlots[ArgsNext].args := args;
    ArgsNext := (ArgsNext + 1) mod ARGS_SLOTS;
  finally
    LeaveCriticalSection(ArgsLock);
  end;
end;

function FindArgs(const stream: TBytes; out args: Int64): Boolean;
var b: TBlake3; h: THash16; i: Integer;
begin
  Result := False; args := -1;
  b.Init; b.Update(stream[0], Length(stream)); h := b.Final;
  EnterCriticalSection(ArgsLock);
  try
    for i := 0 to ARGS_SLOTS - 1 do
      if ArgsSlots[i].used and (ArgsSlots[i].size = Length(stream)) and
         CompareMem(@ArgsSlots[i].hash[0], @h[0], SizeOf(THash16)) then begin
        args := ArgsSlots[i].args;
        Exit(True);
      end;
  finally
    LeaveCriticalSection(ArgsLock);
  end;
end;

function PjkCompress(const data: TBytes; out stream: TBytes; threads: Integer): Boolean;
var words, bytes: Int64;
begin
  stream := nil; Result := False;
  if J2kKind(data) = jkNone then Exit;
  CsWords := 0; CsBytes := 0; CsCount := 0; FileLen := Length(data);
  { no verification here: zpaq-std decodes every block and compares }
  if not Compress(data, stream, False, threads, False, True).Ok or (Length(stream) < 6) or (stream[0] <> STREAM_J2K) or
     (CsCount = 0) or not Finish(stream, words, bytes) then begin
    stream := nil; Exit;
  end;
  KeepArgs(stream, Log2Of(words) or (Log2Of(bytes) shl 8));
  Result := True;
end;

function PjkMemory(const stream: TBytes; out words, bytes: Int64): Boolean;
var data, again: TBytes;
begin
  Result := False; words := -1; bytes := -1;
  { the file again, and each codestream analysed again as compress did }
  if (Length(stream) < 6) or (stream[0] <> STREAM_J2K) then Exit;
  if not Decompress(stream, data, 1 shl 30, 1).Ok then Exit;
  CsWords := 0; CsBytes := 0; CsCount := 0; FileLen := Length(data);
  if not Compress(data, again, False, 1, False, True).Ok or (Length(again) <> Length(stream)) or
     not CompareMem(@again[0], @stream[0], Length(stream)) then Exit;
  Result := (CsCount > 0) and Finish(stream, words, bytes);
end;

function PjkArgs(const stream: TBytes): Int64;
var words, bytes: Int64;
begin
  if FindArgs(stream, Result) then Exit;
  if not PjkMemory(stream, words, bytes) then Exit(-1);
  Result := Log2Of(words) or (Log2Of(bytes) shl 8);
  KeepArgs(stream, Result);
end;

function PjkDecompress(const stream: TBytes; cap: SizeInt; threads: Integer; out data: TBytes): Boolean;
var k, i: Integer;
begin
  data := nil; Result := False;
  if (Length(stream) < 6) or (stream[0] <> STREAM_J2K) or (stream[1] <> 0) then Exit;
  k := U32(stream, 2);
  if 6 + 13 * Int64(k) > Length(stream) then Exit;
  for i := 0 to k - 1 do
    if stream[6 + 13 * i + 12] > 1 then Exit;
  Result := Decompress(stream, data, cap, threads, cap).Ok and (Length(data) = cap);
  if not Result then data := nil;
end;

{ ---------------------------------------------------------------- detect }

function Be16(src: PByte; p: SizeUInt): Cardinal; inline;
begin
  Result := (Cardinal(src[p]) shl 8) or src[p + 1];
end;

function Be32(src: PByte; p: SizeUInt): Cardinal; inline;
begin
  Result := (Cardinal(src[p]) shl 24) or (Cardinal(src[p + 1]) shl 16) or (Cardinal(src[p + 2]) shl 8) or src[p + 3];
end;

{ a codestream's main header, src[off .. off + len): not HTJ2K nor Part 2,
  the SIZ and the levels within the ZPAQL's limits (the rest, Mb, the bands
  and the memory, is for the analysis, PjkFits) }
function MainHeaderTakeable(src: PByte; off, len: SizeUInt): Boolean;
var p, e: SizeUInt; m, L, i, nl: Cardinal; siz: Boolean;
begin
  Result := False; siz := False;
  if (len < 4) or (src[off] <> $FF) or (src[off + 1] <> $4F) then Exit;
  p := off + 2; e := off + len;
  while p + 4 <= e do begin
    m := Be16(src, p);
    if m = $FF90 then Break;
    if (m >= $FF30) and (m <= $FF3F) then begin Inc(p, 2); Continue; end;
    L := Be16(src, p + 2);
    if (src[p] <> $FF) or (L < 2) or (p + 2 + L > e) then Exit;
    case m of
      $FF51: begin
          if L < 41 then Exit;
          for i := 0 to 7 do if Be32(src, p + 6 + 4 * i) >= PJK_MAX_SIZ then Exit;
          if (Be16(src, p + 38) < 1) or (Be16(src, p + 38) > PJK_MAX_COMPS) then Exit;
          siz := True;
        end;
      $FF52, $FF53: begin
          { COD: Scod, prog, layers, mct, then NL; COC: its component (one
            byte), Scoc, then NL }
          if m = $FF52 then i := p + 9 else i := p + 6;
          if i + 4 > p + 2 + L then Exit;
          nl := src[i];
          if (nl > PJK_MAX_NL) or (src[i + 3] and $C0 <> 0) then Exit;
        end;
      $FF50: if (L >= 6) and (Be32(src, p + 4) and (1 shl 17) <> 0) then Exit;
      $FF72, $FF73: Exit;
    end;
    p := p + 2 + L;
  end;
  Result := siz;
end;

function PjkDetect(src: PByte; n: SizeUInt): Boolean;
var d: TBytes; cs: TJ2kCodestreams; i: Integer;
begin
  Result := False;
  try
    d := nil; SetLength(d, n);
    if n > 0 then Move(src^, d[0], n);
    if (J2kKind(d) = jkNone) or not J2kCodestreams(d, cs) then Exit;
    for i := 0 to High(cs) do
      if MainHeaderTakeable(src, cs[i].off, cs[i].len) then Exit(True);
  except
    Result := False;
  end;
end;

initialization
  InitCriticalSection(ArgsLock);
  J2kTileCost := @TileCost;
  J2kMode1Enc := @PjkMode1Enc;
  { PjkMode1Enc counts in this thread's CsWords, CsBytes, CsCount }
  J2kCodestreamsTogether := False;
  { modes 3 and 4 (HTJ2K) have no ZPAQL: an HTJ2K codestream stays as bytes
    (mode 0), as modes 2 and 4 are not linked in }
  J2kMode3Enc := nil;
  J2kMode3Dec := nil;
end.

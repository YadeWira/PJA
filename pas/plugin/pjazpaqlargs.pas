{ How much memory the plugin's ZPAQL decoder takes for a given JPEG: what
  zpaq-std's query ZS_QUERY_ZPAQL_ARGS returns (the $3 of the decoder's
  config, log2 of its H), and what the detection checks. It follows the
  decoder's alloc() calls one by one (pas/plugin/zpaql/): change one, change
  the other; the suite decodes with exactly this size. }
unit pjazpaqlargs;

{$mode objfpc}{$H+}

interface

uses SysUtils, pjajpeg, pjajls, pjacodec, pjamodel;

{$I pjazpaql.inc}
{$I pjalszpaql.inc}
{$I pjaxzpaql.inc}

const
  { the largest H a block may ask for: 2^26 words, 256 MB }
  ZPAQL_MAX_PH = 26;

{ The words of H the decoder takes for this JPEG (its headers parsed, raw
  included). }
function ZpaqlWords(const j: TJpeg): Int64;
{ log2 of that, rounded up: the H the decoder's config asks for. }
function ZpaqlPh(const j: TJpeg): Integer;
{ log2 of a number of words, rounded up: an H of that size holds them. }
function Log2Words(w: Int64): Integer;
{ For a PJA stream (compress()'s output): $3 in bits 0-7, or -1. }
function ZpaqlArgs(const stream: TBytes): Int64;
{ The same three for the JPEG-LS decoder (pjals), symbols: the stream uses
  the symbols model. }
function ZpaqlJlsWords(const jl: TJls; symbols: Boolean): Int64;
function ZpaqlJlsPh(const jl: TJls; symbols: Boolean): Integer;
function ZpaqlJlsArgs(const stream: TBytes): Int64;
{ The pjax codec's: its stream (version 5 or 6, pjacodec.CompressPjax)
  decoded JPEG by JPEG, each in memory of its own, and each part's bytes
  kept until the host puts them back. -1 for what its ZPAQL does not take. }
function ZpaqlPjaxWords(const stream: TBytes): Int64;
function ZpaqlPjaxArgs(const stream: TBytes): Int64;
{ For the detection, before compressing: an upper bound of what pjax's
  stream of this verified JPEG would take, every candidate part counted
  (a part that does not pay is left out later); also whether it has any. }
function ZpaqlPjaxFileWords(const d: TBytes; const j: TJpeg; out hasParts: Boolean): Int64;
{ Sampling factors other than 1x1: the pjals ZPAQL, frozen as v0.0.1 left
  it, has no subsampled JPEG-LS }
function JlsSubsampled(const jl: TJls): Boolean;

implementation

const
  O2_TABLE_BITS = 22;      { pjamodel.O2_BITS }

{ The tables the decoder's parseheaders defines: one per table of each DHT
  segment, walking the markers as it does (to the EOI). }
function DhtTables(const raw: TBytes): Int64;
var p, first, last, q, total, l: SizeInt; m: Byte;
begin
  Result := 0;
  p := 2;
  while p < Length(raw) do begin
    if raw[p] <> $FF then Exit;
    while (p < Length(raw)) and (raw[p] = $FF) do Inc(p);
    if p >= Length(raw) then Exit;
    m := raw[p]; Inc(p);
    if m = $D9 then Exit;
    if (m >= $D0) and (m <= $D7) then Continue;
    if p + 2 > Length(raw) then Exit;
    first := p + 2; last := p + ((raw[p] shl 8) or raw[p + 1]);
    if m = $C4 then begin
      q := first;
      while (q < last) and (q + 17 <= Length(raw)) do begin
        total := 0;
        for l := 1 to 16 do Inc(total, raw[q + l]);
        Inc(Result);
        Inc(q, 17 + total);
      end;
    end;
    p := last;
  end;
end;

{ coderaw: the raw bytes, its order-2 map or table, its mixer }
function RawWords(n: Int64): Int64;
var bits: Integer;
begin
  Result := n + 4;
  { o2init: a map of 2^(bits+1) words, or the table of 2^O2_BITS }
  bits := 1;
  while (Int64(1) shl bits) < 16 * n do Inc(bits);
  if bits + 1 >= O2_TABLE_BITS then Inc(Result, Int64(1) shl O2_TABLE_BITS)
  else Inc(Result, Int64(2) shl bits);
  Inc(Result, 12 + 8 * 8);
end;

function ZpaqlWords(const j: TJpeg): Int64;
var c: Integer; maxbw: SizeInt;
begin
  Result := ZPAQL_STATIC_WORDS + RawWords(Length(j.raw));
  Inc(Result, DhtTables(j.raw) * 512);
  maxbw := 0;
  for c := 0 to High(j.comp) do begin
    Inc(Result, Int64(j.comp[c].bw) * j.comp[c].bh * 32);   { coefficients, two a word }
    Inc(Result, Int64(j.comp[c].bw) * j.comp[c].bh * 2);    { nonzero counts, DC buckets }
    if j.comp[c].bw > maxbw then maxbw := j.comp[c].bw;
  end;
  Inc(Result, Int64(maxbw) * 16);
  Inc(Result, Int64(BandCount(j)) * 2 * ZPAQL_MODEL_WORDS);
end;

function Log2Words(w: Int64): Integer;
begin
  Result := 0;
  while (Int64(1) shl Result) < w do Inc(Result);
end;

function ZpaqlPh(const j: TJpeg): Integer;
begin
  Result := Log2Words(ZpaqlWords(j));
end;

function ZpaqlArgs(const stream: TBytes): Int64;
var j: TJpeg; ph: Integer;
begin
  Result := -1;
  try
    { the decoder takes 8-bit DCT JPEGs with their height in the frame only }
    if not StreamHeaders(stream, j).Ok or (j.precision <> 8) or j.lossless or j.dnl then Exit;
    ph := ZpaqlPh(j);
    if ph > ZPAQL_MAX_PH then Exit;
    Result := ph;
  except
    Result := -1;
  end;
end;

function JlsSubsampled(const jl: TJls): Boolean;
var c: Integer;
begin
  Result := False;
  for c := 0 to High(jl.comp) do
    if (jl.comp[c].h <> 1) or (jl.comp[c].v <> 1) then Exit(True);
end;

function U32At(const d: TBytes; p: SizeInt): Int64;
begin
  Result := Int64(d[p]) or (Int64(d[p + 1]) shl 8) or (Int64(d[p + 2]) shl 16) or (Int64(d[p + 3]) shl 24);
end;

{ What one version 5 stream takes beyond the decoder's own words: -1 if
  pjax does not decode it (arithmetic, lossless, JPEG-LS) }
function OneJpegWords(const st: TBytes): Int64;
var j: TJpeg;
begin
  if not StreamHeaders(st, j).Ok or j.arithmetic or j.lossless then Exit(-1);
  Result := ZpaqlWords(j) - ZPAQL_STATIC_WORDS;
end;

function ZpaqlPjaxWords(const stream: TBytes): Int64;
var n, q: Int64; i: Integer; p, at, k: SizeInt; w: Int64; copy_: Boolean;
begin
  Result := -1;
  if Length(stream) < 2 then Exit;
  if stream[0] = STREAM_VERSION then begin
    w := OneJpegWords(stream);
    if w >= 0 then Result := ZPAQL_X_STATIC_WORDS + w;
    Exit;
  end;
  { version 6: no bytes, at most 256 parts, each part version 5 }
  if (stream[0] <> STREAM_PARTS) or (stream[1] > 1) or (Length(stream) < 6) then Exit;
  n := U32At(stream, 2);
  if n > 256 then Exit;
  p := 6 + 13 * n;
  if p > Length(stream) then Exit;
  if stream[1] = 1 then begin
    if p + 4 > Length(stream) then Exit;
    q := U32At(stream, p);
    p := p + 4 + 4 * q;
    if (q > 256) or (p > Length(stream)) then Exit;
  end;
  Result := ZPAQL_X_STATIC_WORDS;
  at := p;
  for i := 0 to n - 1 do begin
    copy_ := stream[6 + 13 * i + 12] and 2 <> 0;
    if copy_ then Continue;
    k := U32At(stream, 6 + 13 * i + 8);
    if at + k > Length(stream) then Exit(-1);
    w := OneJpegWords(Copy(stream, at, k));
    if w < 0 then Exit(-1);
    { its decoding, and its bytes until the host is out }
    Result := Result + w + U32At(stream, 6 + 13 * i + 4);
    at := at + k;
  end;
  w := OneJpegWords(Copy(stream, at, Length(stream) - at));
  if w < 0 then Exit(-1);
  Result := Result + w;
end;

function ZpaqlPjaxFileWords(const d: TBytes; const j: TJpeg; out hasParts: Boolean): Int64;
var k, len: SizeInt; sj: TJpeg;
begin
  hasParts := False;
  Result := ZPAQL_X_STATIC_WORDS + ZpaqlWords(j) - ZPAQL_STATIC_WORDS;
  { as pjacodec.CompressAt looks for them: FF D8 FF from the third byte on,
    a Huffman JPEG inside the host's segments or after its end }
  k := 2;
  while k + 3 <= Length(d) do begin
    if (d[k] = $FF) and (d[k + 1] = $D8) and (d[k + 2] = $FF) and
       Decompose(Copy(d, k, Length(d) - k), sj).Ok and not sj.arithmetic and not sj.lossless then begin
      len := sj.eoi;
      if (k >= j.eoi) or (k + len <= j.eoi) then begin
        hasParts := True;
        Result := Result + ZpaqlWords(sj) - ZPAQL_STATIC_WORDS + len;
        Inc(k, len);
        Continue;
      end;
    end;
    Inc(k);
  end;
end;

function ZpaqlPjaxArgs(const stream: TBytes): Int64;
var w: Int64;
begin
  Result := -1;
  try
    w := ZpaqlPjaxWords(stream);
    if w < 0 then Exit;
    Result := Log2Words(w);
    if Result > ZPAQL_MAX_PH then Result := -1;
  except
    Result := -1;
  end;
end;

function ZpaqlJlsWords(const jl: TJls; symbols: Boolean): Int64;
var c, s, n: Integer; w, samples: Int64;
begin
  w := jl.width;
  samples := w * jl.height;
  n := Length(jl.comp);
  Result := ZPAQL_LS_STATIC_WORDS + RawWords(Length(jl.raw));
  Inc(Result, samples * n);                        { the samples }
  Inc(Result, 8 * (w + 2));                        { the scan's two lines }
  if symbols then begin
    Inc(Result, ZPAQL_LS_SYM_WORDS);
    for s := 0 to High(jl.scans) do begin
      c := jl.scans[s].ncomp;
      Inc(Result, Int64(c) * (2 * (w + 2) + 3 * (w + 4)));
      { near-lossless: the runs it records, at most one a line and component }
      if jl.scans[s].near > 0 then
        if jl.scans[s].ilv = 2 then Inc(Result, samples) else Inc(Result, samples * c);
    end;
  end else begin
    Inc(Result, 32 + 32 * 32);
    for s := 0 to High(jl.scans) do
      if jl.scans[s].near > 0 then Inc(Result, Length(jl.scans[s].runs) + 1);
    Inc(Result, Int64(JlsBandCount(jl)) * (ZPAQL_LS_BAND_WORDS + 2 * w * n));
  end;
end;

function ZpaqlJlsPh(const jl: TJls; symbols: Boolean): Integer;
begin
  Result := Log2Words(ZpaqlJlsWords(jl, symbols));
end;

function ZpaqlJlsArgs(const stream: TBytes): Int64;
var jl: TJls; symbols: Boolean; ph: Integer;
begin
  Result := -1;
  try
    if not StreamJlsHeaders(stream, jl, symbols).Ok or JlsSubsampled(jl) then Exit;
    ph := ZpaqlJlsPh(jl, symbols);
    if ph > ZPAQL_MAX_PH then Exit;
    Result := ph;
  except
    Result := -1;
  end;
end;

end.

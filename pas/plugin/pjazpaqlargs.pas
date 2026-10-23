{ How much memory the plugin's ZPAQL decoder takes for a given JPEG: what
  zpaq-std's query ZS_QUERY_ZPAQL_ARGS returns (the $3 of the decoder's
  config, log2 of its H), and what the detection checks. It follows the
  decoder's alloc() calls one by one (pas/plugin/zpaql/): change one, change
  the other; the suite decodes with exactly this size. }
unit pjazpaqlargs;

{$mode objfpc}{$H+}

interface

uses SysUtils, pjajpeg, pjacodec, pjamodel;

{$I pjazpaql.inc}

const
  { the largest H a block may ask for: 2^26 words, 256 MB }
  ZPAQL_MAX_PH = 26;

{ The words of H the decoder takes for this JPEG (its headers parsed, raw
  included). }
function ZpaqlWords(const j: TJpeg): Int64;
{ log2 of that, rounded up: the H the decoder's config asks for. }
function ZpaqlPh(const j: TJpeg): Integer;
{ For a PJA stream (compress()'s output): $3 in bits 0-7, or -1. }
function ZpaqlArgs(const stream: TBytes): Int64;

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

function ZpaqlWords(const j: TJpeg): Int64;
var c, bits: Integer; maxbw: SizeInt; n: Int64;
begin
  n := Length(j.raw);
  Result := ZPAQL_STATIC_WORDS + n + 4;
  { o2init: a map of 2^(bits+1) words, or the table of 2^O2_BITS }
  bits := 1;
  while (Int64(1) shl bits) < 16 * n do Inc(bits);
  if bits + 1 >= O2_TABLE_BITS then Inc(Result, Int64(1) shl O2_TABLE_BITS)
  else Inc(Result, Int64(2) shl bits);
  Inc(Result, 12 + 8 * 8);                         { the raw model's mixer }
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

function ZpaqlPh(const j: TJpeg): Integer;
var w: Int64;
begin
  w := ZpaqlWords(j);
  Result := 0;
  while (Int64(1) shl Result) < w do Inc(Result);
end;

function ZpaqlArgs(const stream: TBytes): Int64;
var j: TJpeg; ph: Integer;
begin
  Result := -1;
  try
    if not StreamHeaders(stream, j).Ok then Exit;
    ph := ZpaqlPh(j);
    if ph > ZPAQL_MAX_PH then Exit;
    Result := ph;
  except
    Result := -1;
  end;
end;

end.

{ The info provider (pjainfo) of the .pja: the container (doc/FORMAT.md)
  and the codec stream inside it (doc/CODEC.md), read as those documents
  lay them out, without decoding the bands.

  Container: its version, flags, the original's size, hash and extension.
  Stream: its version and model; for versions 5 and 7, the image its
  header stream describes (decoded: only the raw bytes' model, never the
  bands) and its bands; for version 6, as bytes, PATCH (its edits, then the
  repaired file's stream) or parts (each JPEG inside, then the host's
  stream), each stream described the same way. }
unit pjainfopja;

{$I pja.inc}
{$ifopt R-}{$fatal pjainfopja: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjainfopja: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjainfo;

function ProbePja(const d: TBytes): Boolean;
procedure DescribePja(const d: TBytes; n: TInfoNode);
{ The stream's description into n (maxRaw: the original's size). }
procedure DescribeStream(const s: TBytes; maxRaw: QWord; n: TInfoNode; depth: Integer = 0);
{ How many bands the stream's main image has (the host's, with parts; the
  repaired file's, with PATCH); 0 when it has none (as bytes, stored) or
  it cannot be told. For --stats. }
function StreamBands(const s: TBytes; maxRaw: QWord): Integer;

implementation

uses pjaformat, pjacodec, pjajpeg, pjajls, pjamodel;

const
  { doc/CODEC.md, version 6 }
  V6_QUIRKS = 1; V6_BYTES = 2; V6_CORRECTION = 4; V6_PATCH = 8;
  PART_ENTRY = 13;
  PART_ZEROS = 1; PART_COPY = 2;
  MAX_LISTED_PARTS = 64;
  MAX_STREAM_DEPTH = 4;

function ProbePja(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

function GetU32(const s: TBytes; p: Int64): Int64;
begin
  Result := Int64(s[p]) or (Int64(s[p + 1]) shl 8) or (Int64(s[p + 2]) shl 16) or (Int64(s[p + 3]) shl 24);
end;

function CapRaw(maxRaw: QWord): SizeInt;
begin
  if maxRaw > QWord(High(SizeInt)) then Result := High(SizeInt) else Result := SizeInt(maxRaw);
end;

{ the host or repaired stream at the end of a version 6 stream; nil if
  there is none, or the stream is damaged }
function InnerStream(const s: TBytes): TBytes;
var p, k, n, e, i: Int64; flags: Integer;
begin
  Result := nil;
  if (Length(s) < 6) or (s[0] <> STREAM_PARTS) then Exit;
  flags := s[1];
  if flags = V6_BYTES then Exit;
  if flags = V6_PATCH then begin
    e := GetU32(s, 2);
    p := 6;
    for i := 1 to e do begin
      if p + 12 > Length(s) then Exit;
      p := p + 12 + GetU32(s, p + 8);
    end;
    if p > Length(s) then Exit;
    Exit(Copy(s, p, Length(s) - p));
  end;
  n := GetU32(s, 2);
  if 6 + PART_ENTRY * n > Length(s) then Exit;
  p := 6 + PART_ENTRY * n;
  if flags and V6_QUIRKS <> 0 then begin
    if p + 4 > Length(s) then Exit;
    p := p + 4 + 4 * GetU32(s, p);
  end;
  if flags and V6_CORRECTION <> 0 then begin
    if p + 4 > Length(s) then Exit;
    p := p + 4 + 8 * GetU32(s, p);
  end;
  for i := 0 to n - 1 do begin
    k := 6 + PART_ENTRY * i;
    if s[k + 12] and PART_COPY = 0 then p := p + GetU32(s, k + 8);
  end;
  if p > Length(s) then Exit;
  Result := Copy(s, p, Length(s) - p);
end;

function StreamBands(const s: TBytes; maxRaw: QWord): Integer;
var j: TJpeg; jl: TJls; symbols: Boolean;
begin
  Result := 0;
  if Length(s) < 2 then Exit;
  if s[0] = STREAM_PARTS then Exit(StreamBands(InnerStream(s), maxRaw));
  if StreamHeaders(s, j, CapRaw(maxRaw)).Ok then begin
    if not j.lossless then Result := BandCount(j);
  end else if StreamJlsHeaders(s, jl, symbols, CapRaw(maxRaw)).Ok then begin
    if symbols then Result := 1 else Result := JlsBandCount(jl);
  end;
end;

procedure DescribeStream(const s: TBytes; maxRaw: QWord; n: TInfoNode; depth: Integer);
var j: TJpeg; jl: TJls; symbols: Boolean; img, parts, it, sub: TInfoNode; flags, mode: Integer;
    k, cnt, p, at, len: Int64; i: Integer; ps: TBytes;
begin
  n.Num('bytes', Length(s));
  if Length(s) < 2 then begin n.Str('problem', 'too short'); Exit; end;
  n.Num('version', s[0]);
  if depth > MAX_STREAM_DEPTH then Exit;
  if (s[0] = STREAM_VERSION) or (s[0] = STREAM_V7) then begin
    if s[1] = 1 then n.Str('model', 'fast') else n.Str('model', 'full');
    if s[0] = STREAM_V7 then n.Str('model', 'version 7 (C)');
    if Length(s) >= STREAM_HEADER then n.Num('header_stream', GetU32(s, 2));
    if StreamHeaders(s, j, CapRaw(maxRaw)).Ok then begin
      img := n.Obj('image');
      img.Str('kind', 'JPEG');
      img.Num('width', j.width); img.Num('height', j.height); img.Num('precision', j.precision);
      img.Num('components', Length(j.comp)); img.Num('scans', Length(j.scans));
      img.Bool('progressive', j.progressive); img.Bool('arithmetic', j.arithmetic);
      img.Bool('lossless', j.lossless); img.Bool('dnl', j.dnl);
      img.Num('raw_bytes', Length(j.raw));
      if not j.lossless then n.Num('bands', BandCount(j));
    end else if StreamJlsHeaders(s, jl, symbols, CapRaw(maxRaw)).Ok then begin
      img := n.Obj('image');
      img.Str('kind', 'JPEG-LS');
      img.Num('width', jl.width); img.Num('height', jl.height); img.Num('bits', jl.bits);
      img.Num('components', Length(jl.comp)); img.Num('scans', Length(jl.scans));
      img.Num('raw_bytes', Length(jl.raw));
      if symbols then begin n.Str('jls_model', 'symbols'); n.Num('bands', 1); end
      else begin n.Str('jls_model', 'samples'); n.Num('bands', JlsBandCount(jl)); end;
    end else n.Str('problem', 'its header stream does not decode');
    Exit;
  end;
  if s[0] <> STREAM_PARTS then begin
    n.Str('problem', 'a version this PJA does not know');
    Exit;
  end;
  flags := s[1];
  n.Num('flags', flags);
  if flags = V6_BYTES then begin
    n.Str('kind', 'as bytes (the raw bytes'' model)');
    Exit;
  end;
  if flags = V6_PATCH then begin
    n.Str('kind', 'PATCH (a repaired file and its edits)');
    if Length(s) < 6 then begin n.Str('problem', 'cut short'); Exit; end;
    n.Num('edits', GetU32(s, 2));
    ps := InnerStream(s);
    if ps = nil then n.Str('problem', 'edits past the end')
    else DescribeStream(ps, maxRaw, n.Obj('repaired'), depth + 1);
    Exit;
  end;
  n.Str('kind', 'parts (JPEGs inside, each a stream; then the host)');
  if flags and V6_QUIRKS <> 0 then n.Bool('restart_quirk', True);
  if flags and V6_CORRECTION <> 0 then n.Bool('correction_bits_quirk', True);
  if Length(s) < 6 then begin n.Str('problem', 'cut short'); Exit; end;
  cnt := GetU32(s, 2);
  n.Num('parts', cnt);
  if 6 + PART_ENTRY * cnt > Length(s) then begin n.Str('problem', 'part entries past the end'); Exit; end;
  { where the parts' streams start }
  p := 6 + PART_ENTRY * cnt;
  if flags and V6_QUIRKS <> 0 then begin
    if p + 4 > Length(s) then Exit;
    n.Num('scans_without_restarts', GetU32(s, p));
    p := p + 4 + 4 * GetU32(s, p);
  end;
  if flags and V6_CORRECTION <> 0 then begin
    if p + 4 > Length(s) then Exit;
    n.Num('scans_with_other_correction_limit', GetU32(s, p));
    p := p + 4 + 8 * GetU32(s, p);
  end;
  parts := n.List('part_list');
  at := p;
  for i := 0 to Integer(cnt) - 1 do begin
    k := 6 + PART_ENTRY * i;
    mode := s[k + 12];
    len := GetU32(s, k + 8);
    if i >= MAX_LISTED_PARTS then begin
      if mode and PART_COPY = 0 then at := at + len;
      Continue;
    end;
    it := parts.Obj;
    it.Num('offset', GetU32(s, k));
    it.Num('length', GetU32(s, k + 4));
    if mode and PART_ZEROS <> 0 then it.Str('place', 'inside the file''s segments')
    else it.Str('place', 'after the image');
    it.line := 'at ' + IntToStr(GetU32(s, k)) + ', ' + IntToStr(GetU32(s, k + 4)) + ' B, ';
    if mode and PART_ZEROS <> 0 then it.line := it.line + 'inside the segments'
    else it.line := it.line + 'after the image';
    if mode and PART_COPY <> 0 then begin
      it.Num('copy_of', len);
      it.line := it.line + ', a copy of part ' + IntToStr(len);
    end else begin
      it.Num('stream_bytes', len);
      it.line := it.line + ', stream ' + IntToStr(len) + ' B';
      if (at >= 0) and (at + len <= Length(s)) and (len > 0) then begin
        it.Num('stream_version', s[at]);
        it.line := it.line + ' (version ' + IntToStr(s[at]) + ')';
      end;
      at := at + len;
    end;
  end;
  if at <= Length(s) then begin
    ps := Copy(s, at, Length(s) - at);
    sub := n.Obj('host');
    DescribeStream(ps, maxRaw, sub, depth + 1);
  end else n.Str('problem', 'parts past the end');
end;

procedure DescribePja(const d: TBytes; n: TInfoNode);
var p: TPja; r: TPjaResult; c, st: TInfoNode;
begin
  n.Str('format', 'PJA');
  n.Num('size', Length(d));
  c := n.Obj('container');
  if Length(d) >= 6 then begin
    c.Num('version', d[4]);
    c.Num('flags', d[5]);
  end;
  r := Open(d, p);
  if not r.Ok then begin
    c.Str('problem', r.Text);
    Exit;
  end;
  c.Num('original_size', p.orig_size);
  c.Str('original_blake3_128', HexBytes(p.hash));
  c.Str('extension', p.ext);
  c.Bool('stored', p.stored);
  c.Num('payload', Length(p.payload));
  if p.orig_size > 0 then c.Fixed('ratio_percent', 100 * Length(d) / p.orig_size);
  if p.stored then Exit;
  st := n.Obj('stream');
  DescribeStream(p.payload, p.orig_size, st);
end;

initialization
  RegisterInfoProvider('PJA', @ProbePja, @DescribePja);
end.

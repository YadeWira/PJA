{ The JPEG 2000 family's files: where their codestreams are.

  Two kinds of file (ISO/IEC 15444):
  - a raw codestream (.j2k, .j2c, .jpc): SOC (FF 4F) and SIZ (FF 51) first;
  - a file of boxes (JP2, JPX, JPM, Motion JPEG 2000, JPH): the signature
    box (00 00 00 0C 6A 50 20 20 0D 0A 87 0A) first, then boxes, each a
    length (LBox, 4 bytes, big-endian), a type (4 bytes) and its contents;
    LBox 1: an 8-byte length follows (XLBox); LBox 0: the box runs to the
    end of what holds it. A codestream is the contents of a jp2c box, at
    the top or inside a superbox (an MJ2's mdat, for instance).

  Stream version 8 (pjacodec) keeps where each codestream is; stage A of
  JPEG 2000 codes every byte with the raw bytes' model, and the later
  stages will model a codestream's contents. Nothing here decodes a
  codestream: the box tree is walked, and a raw codestream's markers to its
  end (EOC). Bounded: a box tree at most MAX_J2K_DEPTH deep and
  MAX_J2K_BOXES boxes, at most MAX_J2K_CODESTREAMS codestreams kept (the
  others stay among the file's other bytes). A box that does not fit where
  it is ends the walk at its level: what is before it is kept, the rest is
  plain bytes. }
unit pjaj2k;

{$I pja.inc}
{$ifopt R-}{$fatal pjaj2k: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaj2k: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { the codestreams stream version 8 keeps at most; more stay as bytes }
  MAX_J2K_CODESTREAMS = 16384;
  { superboxes inside superboxes }
  MAX_J2K_DEPTH = 16;
  { boxes walked in all }
  MAX_J2K_BOXES = 1 shl 20;

type
  TJ2kKind = (jkNone, jkCodestream, jkBoxes);
  TJ2kCodestream = record
    off, len: Int64;
  end;
  TJ2kCodestreams = array of TJ2kCodestream;

{ What the file starts with: a raw codestream, the signature box, or
  neither }
function J2kKind(const data: TBytes): TJ2kKind;
{ The codestreams of a JPEG 2000 family file, in the order of the file,
  apart. False for a file of neither kind. A raw codestream is one, from 0
  to its EOC (to the end of the file when its markers do not lead there);
  a file of boxes has one per jp2c box whose contents start with SOC and
  SIZ, and may have none. }
function J2kCodestreams(const data: TBytes; out cs: TJ2kCodestreams): Boolean;
{ Where a codestream at off ends (after its EOC), its markers walked up to
  limit; -1 when they do not add up (or a tile-part runs to the EOC,
  Psot 0, and the codestream does not end at limit with one) }
function CodestreamEnd(const data: TBytes; off, limit: Int64): Int64;
{ The usual extension of such a file, without the dot: j2k for a raw
  codestream, and by the brand of its ftyp box jp2, jpx, jpm, mj2 or jph;
  '' for another file }
function J2kExtension(const data: TBytes): string;
{ A box that holds boxes, whose jp2c boxes the walk looks into (pjainfoj2k
  walks the same tree); t its type, 4 bytes big-endian }
function J2kIsSuperbox(t: Cardinal): Boolean;
{ Whether the codestream data[off..off + len) is an HTJ2K one (Part 15):
  its main header has a CAP marker segment with Part 15's bit, or a COD or
  COC whose code-block style has the HT bit (0x40). Its main header alone
  is read (at most 1 MB of it). }
function J2kIsHt(const data: TBytes; off, len: Int64): Boolean;

threadvar
  { > 0: a codestream whose SIZ declares more samples (its image area times
    its components, more than its planes hold) is refused before it is
    decoded (pjaj2kcs, pjaj2kpx). pjacodec decodes a file's small
    codestreams side by side under it, and those refused there again alone:
    the memory of several at once stays small }
  J2kSamplesCap: Int64;

{ (x - xo) (y - yo) n, 0 for an empty area, High(Int64) past it }
function J2kAreaTimes(x, y, xo, yo, n: Int64): Int64;
{ that of a SIZ marker segment (from its marker); -1 when it is not one }
function J2kSizSamples(const siz: TBytes): Int64;

implementation

const
  SIGNATURE: array[0..11] of Byte = ($00, $00, $00, $0C, $6A, $50, $20, $20, $0D, $0A, $87, $0A);

function BoxType(const s: string): Cardinal;
begin
  Result := (Cardinal(Ord(s[1])) shl 24) or (Cardinal(Ord(s[2])) shl 16) or
            (Cardinal(Ord(s[3])) shl 8) or Cardinal(Ord(s[4]));
end;

function Be16(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 8) or d[p + 1];
end;

function Be32(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 24) or (Cardinal(d[p + 1]) shl 16) or (Cardinal(d[p + 2]) shl 8) or d[p + 3];
end;

function J2kIsHt(const data: TBytes; off, len: Int64): Boolean;
var p, e, L: Int64; m, nc: Integer;
begin
  Result := False;
  if (off < 0) or (len < 4) or (off + len > Length(data)) then Exit;
  e := off + len; if e > off + (1 shl 20) then e := off + (1 shl 20);
  if (data[off] <> $FF) or (data[off + 1] <> $4F) then Exit;
  p := off + 2; nc := 0;
  while p + 4 <= e do begin
    if data[p] <> $FF then Exit;
    m := Be16(data, p);
    if (m = $FF90) or (m = $FF93) or (m = $FFD9) then Exit;
    if (m >= $FF30) and (m <= $FF3F) then begin p := p + 2; Continue; end;
    L := Be16(data, p + 2);
    if (L < 2) or (p + 2 + L > e) then Exit;
    case m of
      $FF51: if L >= 38 then nc := Be16(data, p + 38);
      $FF50: if (L >= 6) and (Be32(data, p + 4) and (1 shl 17) <> 0) then Exit(True);
      $FF52: if (L >= 12) and (data[p + 12] and $40 <> 0) then Exit(True);
      $FF53: if nc < 257 then begin
               if (L >= 9) and (data[p + 9] and $40 <> 0) then Exit(True);
             end else if (L >= 10) and (data[p + 10] and $40 <> 0) then Exit(True);
    end;
    p := p + 2 + L;
  end;
end;

function J2kKind(const data: TBytes): TJ2kKind;
var i: Integer;
begin
  Result := jkNone;
  if (Length(data) >= 4) and (data[0] = $FF) and (data[1] = $4F) and (data[2] = $FF) and (data[3] = $51) then
    Exit(jkCodestream);
  if Length(data) < Length(SIGNATURE) then Exit;
  for i := 0 to High(SIGNATURE) do
    if data[i] <> SIGNATURE[i] then Exit;
  Result := jkBoxes;
end;

function CodestreamEnd(const data: TBytes; off, limit: Int64): Int64;
var p, psot: Int64; m: Byte;
begin
  Result := -1;
  if (off < 0) or (limit > Length(data)) or (off + 4 > limit) then Exit;
  if (data[off] <> $FF) or (data[off + 1] <> $4F) then Exit;
  { the main header: segments with a length each, up to the first SOT }
  p := off + 2;
  while True do begin
    if p + 4 > limit then Exit;
    if data[p] <> $FF then Exit;
    m := data[p + 1];
    if m = $90 then Break;
    { a marker without a segment (FF30 to FF3F, SOC, SOD, EOC) has no place here }
    if (m < $40) or (m = $4F) or (m = $93) or (m = $D9) then Exit;
    if Be16(data, p + 2) < 2 then Exit;
    p := p + 2 + Be16(data, p + 2);
  end;
  { the tile-parts, each Psot long, and the EOC }
  while True do begin
    if p + 2 > limit then Exit;
    if (data[p] = $FF) and (data[p + 1] = $D9) then Exit(p + 2);
    if (data[p] <> $FF) or (data[p + 1] <> $90) or (p + 12 > limit) or (Be16(data, p + 2) <> 10) then Exit;
    psot := Be32(data, p + 6);
    if psot = 0 then begin
      { the last tile-part, to the EOC that ends the codestream }
      if (limit - p >= 14) and (data[limit - 2] = $FF) and (data[limit - 1] = $D9) then Exit(limit);
      Exit;
    end;
    if (psot < 14) or (psot > limit - p) then Exit;
    p := p + psot;
  end;
end;

function J2kAreaTimes(x, y, xo, yo, n: Int64): Int64;
var a, b: Int64;
begin
  a := x - xo; b := y - yo;
  if (a <= 0) or (b <= 0) or (n <= 0) then Exit(0);
  if b > High(Int64) div a then Exit(High(Int64));
  Result := a * b;
  if n > High(Int64) div Result then Exit(High(Int64));
  Result := Result * n;
end;

function J2kSizSamples(const siz: TBytes): Int64;
begin
  if (Length(siz) < 40) or (Be16(siz, 0) <> $FF51) then Exit(-1);
  Result := J2kAreaTimes(Be32(siz, 6), Be32(siz, 10), Be32(siz, 14), Be32(siz, 18), Be16(siz, 38));
end;

function J2kIsSuperbox(t: Cardinal): Boolean;
begin
  { JP2 and JPX (15444-1 and -2), JPM (-6), and the ISO base media file
    format's that Motion JPEG 2000 (-3) uses; an mdat holds an MJ2's frames
    as jp2c boxes }
  Result := (t = BoxType('jp2h')) or (t = BoxType('res ')) or (t = BoxType('uinf')) or
            (t = BoxType('asoc')) or (t = BoxType('jpch')) or (t = BoxType('jplh')) or
            (t = BoxType('cgrp')) or (t = BoxType('comp')) or (t = BoxType('drep')) or
            (t = BoxType('page')) or (t = BoxType('pcol')) or (t = BoxType('lobj')) or
            (t = BoxType('objc')) or (t = BoxType('moov')) or (t = BoxType('trak')) or
            (t = BoxType('mdia')) or (t = BoxType('minf')) or (t = BoxType('stbl')) or
            (t = BoxType('dinf')) or (t = BoxType('edts')) or (t = BoxType('udta')) or
            (t = BoxType('mvex')) or (t = BoxType('moof')) or (t = BoxType('traf')) or
            (t = BoxType('mdat'));
end;

type
  TWalk = record
    boxes: Integer;
    cs: TJ2kCodestreams;
    n: Integer;
  end;

{ the boxes between a and b, at depth }
procedure Walk(const data: TBytes; a, b: Int64; depth: Integer; var w: TWalk);
var p, len, head: Int64; t, l: Cardinal; x: QWord;
begin
  p := a;
  while (b - p >= 8) and (w.boxes < MAX_J2K_BOXES) do begin
    l := Be32(data, p); t := Be32(data, p + 4); head := 8;
    if l = 1 then begin
      if b - p < 16 then Exit;
      x := (QWord(Be32(data, p + 8)) shl 32) or Be32(data, p + 12);
      if x > QWord(b - p) then Exit;
      len := Int64(x); head := 16;
    end else if l = 0 then len := b - p
    else len := l;
    if (len < head) or (len > b - p) then Exit;
    Inc(w.boxes);
    if t = BoxType('jp2c') then begin
      if (len - head >= 4) and (w.n < MAX_J2K_CODESTREAMS) and (data[p + head] = $FF) and
         (data[p + head + 1] = $4F) and (data[p + head + 2] = $FF) and (data[p + head + 3] = $51) then begin
        if w.n = Length(w.cs) then SetLength(w.cs, 2 * w.n + 4);
        w.cs[w.n].off := p + head; w.cs[w.n].len := len - head;
        Inc(w.n);
      end;
    end else if J2kIsSuperbox(t) and (depth < MAX_J2K_DEPTH) then
      Walk(data, p + head, p + len, depth + 1, w);
    p := p + len;
  end;
end;

function J2kCodestreams(const data: TBytes; out cs: TJ2kCodestreams): Boolean;
var w: TWalk; e: Int64;
begin
  cs := nil;
  case J2kKind(data) of
    jkCodestream: begin
      e := CodestreamEnd(data, 0, Length(data));
      if e < 0 then e := Length(data);
      SetLength(cs, 1);
      cs[0].off := 0; cs[0].len := e;
      Result := True;
    end;
    jkBoxes: begin
      w := Default(TWalk);
      Walk(data, 0, Length(data), 0, w);
      cs := Copy(w.cs, 0, w.n);
      Result := True;
    end;
    else Result := False;
  end;
end;

function J2kExtension(const data: TBytes): string;
var brand: Cardinal;
begin
  case J2kKind(data) of
    jkCodestream: Result := 'j2k';
    jkBoxes: begin
      Result := 'jp2';
      { ftyp right after the signature, its brand first }
      if (Length(data) >= 24) and (Be32(data, 16) = BoxType('ftyp')) then begin
        brand := Be32(data, 20);
        if brand = BoxType('jpx ') then Result := 'jpx'
        else if brand = BoxType('jpm ') then Result := 'jpm'
        else if (brand = BoxType('mjp2')) or (brand = BoxType('mj2s')) then Result := 'mj2'
        else if brand = BoxType('jph ') then Result := 'jph';
      end;
    end;
    else Result := '';
  end;
end;

end.

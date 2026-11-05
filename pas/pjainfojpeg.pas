{ The info provider (pjainfo) of JPEG and JPEG-LS files, MPOs among them:
  their structure from the markers alone, without decoding a sample.

  It walks the segments as they are written, whatever PJA's codec thinks
  of them: the list of markers with their places and lengths, the frame
  (SOF: coding, precision, size, components and their sampling), each
  scan's components, band and bits (for JPEG-LS: NEAR and the interleave),
  its entropy-coded bytes and restarts, DRI, DNL, what follows the EOI,
  the JPEGs inside APP segments and after the EOI (an EXIF thumbnail, an
  MPO's further images, a gain map), and the MPF index.

  Privacy: no metadata is printed, only its size. An APP segment is named
  by its identifier only when it is one of the known ones below (Exif,
  XMP, ICC_PROFILE, MPF...); a COM segment by its length alone. }
unit pjainfojpeg;

{$I pja.inc}
{$ifopt R-}{$fatal pjainfojpeg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjainfojpeg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjainfo;

{ JPEG (SOI, FF D8) or JPEG-LS }
function ProbeJpeg(const d: TBytes): Boolean;
procedure DescribeJpeg(const d: TBytes; n: TInfoNode);

implementation

uses pjajpeg, pjajls;

const
  { segments listed one by one; past these, counted }
  MAX_LISTED = 300;
  { JPEGs found inside a file, and how deep inside inside }
  MAX_EMBEDDED = 32;
  MAX_DEPTH = 2;
  { MPF entries listed }
  MAX_MPF = 64;

  { known APP identifiers, NUL included where the format has one }
  APP_IDS: array[0..14] of string = (
    'JFIF'#0, 'JFXX'#0, 'Exif'#0, 'http://ns.adobe.com/xap/1.0/'#0, 'http://ns.adobe.com/xmp/extension/'#0,
    'ICC_PROFILE'#0, 'MPF'#0, 'Adobe', 'Ducky', 'Photoshop 3.0'#0, 'FPXR'#0, 'AROT'#0,
    'urn:iso:std:iso:ts:21496:-1'#0, 'HDR_GAIN_MAP'#0, 'XMP'#0);

type
  { what a walk found that the file's description sums up }
  TWalk = record
    ls: Boolean;               { a JPEG-LS frame (SOF55) }
    frames, scans, restarts, listed, segments: Integer;
    eoiEnd: SizeInt;           { just past the EOI; -1 with none }
    exif, xmp, icc, comments, otherApp: Int64;   { bytes }
    commentCount: Integer;
    sofMarker: Integer;
    width, height, precision: Integer;
    dnlHeight: Integer;
    ri: Integer;
    embedded: Integer;
  end;

function ProbeJpeg(const d: TBytes): Boolean;
begin
  Result := (Length(d) >= 2) and (d[0] = $FF) and (d[1] = $D8);
end;

function U16(const d: TBytes; p: SizeInt): Integer;
begin
  Result := (d[p] shl 8) or d[p + 1];
end;

function MarkerName(m: Integer): string;
begin
  case m of
    $C4: Result := 'DHT';
    $C8: Result := 'JPG';
    $CC: Result := 'DAC';
    $C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF: Result := 'SOF' + IntToStr(m - $C0);
    $D0..$D7: Result := 'RST' + IntToStr(m - $D0);
    $D8: Result := 'SOI';
    $D9: Result := 'EOI';
    $DA: Result := 'SOS';
    $DB: Result := 'DQT';
    $DC: Result := 'DNL';
    $DD: Result := 'DRI';
    $DE: Result := 'DHP';
    $DF: Result := 'EXP';
    $E0..$EF: Result := 'APP' + IntToStr(m - $E0);
    $F7: Result := 'SOF55';
    $F8: Result := 'LSE';
    $FE: Result := 'COM';
    $01: Result := 'TEM';
  else
    if (m >= $F0) and (m <= $FD) then Result := 'JPG' + IntToStr(m - $F0)
    else Result := 'RES(' + IntToHex(m, 2) + ')';
  end;
end;

function IsSof(m: Integer): Boolean;
begin
  Result := (m in [$C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF]) or (m = $F7);
end;

function SofWords(m: Integer): string;
begin
  case m of
    $C0: Result := 'baseline, Huffman';
    $C1: Result := 'extended sequential, Huffman';
    $C2: Result := 'progressive, Huffman';
    $C3: Result := 'lossless, Huffman';
    $C5: Result := 'differential sequential, Huffman (hierarchical)';
    $C6: Result := 'differential progressive, Huffman (hierarchical)';
    $C7: Result := 'differential lossless, Huffman (hierarchical)';
    $C9: Result := 'extended sequential, arithmetic';
    $CA: Result := 'progressive, arithmetic';
    $CB: Result := 'lossless, arithmetic';
    $CD: Result := 'differential sequential, arithmetic (hierarchical)';
    $CE: Result := 'differential progressive, arithmetic (hierarchical)';
    $CF: Result := 'differential lossless, arithmetic (hierarchical)';
    $F7: Result := 'JPEG-LS';
  else
    Result := '?';
  end;
end;

{ the known identifier at the start of an APP segment's payload, or '' }
function AppId(const d: TBytes; first, last: SizeInt): string;
var k, i: Integer; ok: Boolean; id: string;
begin
  Result := '';
  for k := 0 to High(APP_IDS) do begin
    id := APP_IDS[k];
    if first + Length(id) > last then Continue;
    ok := True;
    for i := 1 to Length(id) do
      if d[first + i - 1] <> Ord(id[i]) then begin ok := False; Break; end;
    if ok then begin
      if id[Length(id)] = #0 then SetLength(id, Length(id) - 1);
      Exit(id);
    end;
  end;
end;

function Hex(v: Int64; digits: Integer): string;
begin
  Result := '0x' + IntToHex(v, digits);
end;

function MpfTypeWords(t: LongWord): string;
begin
  case t of
    $000000: Result := 'undefined';
    $010001: Result := 'large thumbnail (VGA)';
    $010002: Result := 'large thumbnail (full HD)';
    $020001: Result := 'multi-frame panorama';
    $020002: Result := 'multi-frame disparity';
    $020003: Result := 'multi-frame multi-angle';
    $030000: Result := 'baseline MP primary';
  else
    Result := 'other';
  end;
end;

{ An APP2 MPF index (CIPA DC-007): its entries, type and size each }
procedure DescribeMpf(const d: TBytes; first, last: SizeInt; n: TInfoNode);
var base, ifd, count, k, e, entries, eoff, ecount: Int64; little: Boolean; tag: Integer;
    mpf, list, it: TInfoNode; attr, size, off: LongWord;

  function R16(p: Int64): Integer;
  begin
    if little then Result := d[p] or (d[p + 1] shl 8) else Result := (d[p] shl 8) or d[p + 1];
  end;
  function R32(p: Int64): LongWord;
  begin
    if little then Result := LongWord(d[p]) or (LongWord(d[p + 1]) shl 8) or (LongWord(d[p + 2]) shl 16) or (LongWord(d[p + 3]) shl 24)
    else Result := (LongWord(d[p]) shl 24) or (LongWord(d[p + 1]) shl 16) or (LongWord(d[p + 2]) shl 8) or LongWord(d[p + 3]);
  end;

begin
  mpf := n.Obj('mpf');
  base := first + 4;                     { past "MPF\0": a TIFF header }
  if base + 8 > last then begin mpf.Str('problem', 'too short'); Exit; end;
  if (d[base] = Ord('I')) and (d[base + 1] = Ord('I')) then little := True
  else if (d[base] = Ord('M')) and (d[base + 1] = Ord('M')) then little := False
  else begin mpf.Str('problem', 'no byte order'); Exit; end;
  ifd := R32(base + 4);
  if (ifd < 8) or (base + ifd + 2 > last) then begin mpf.Str('problem', 'index out of the segment'); Exit; end;
  count := R16(base + ifd);
  eoff := -1; ecount := 0;
  for k := 0 to count - 1 do begin
    e := base + ifd + 2 + 12 * k;
    if e + 12 > last then begin mpf.Str('problem', 'index cut short'); Break; end;
    tag := R16(e);
    if tag = $B001 then mpf.Num('images', R32(e + 8))
    else if tag = $B002 then begin
      ecount := R32(e + 4) div 16;
      eoff := R32(e + 8);
    end;
  end;
  if eoff < 0 then Exit;
  list := mpf.List('entries');
  entries := 0;
  for k := 0 to ecount - 1 do begin
    if entries >= MAX_MPF then begin mpf.Num('entries_not_listed', ecount - entries); Break; end;
    e := base + eoff + 16 * k;
    if (e < base) or (e + 16 > last) then begin mpf.Str('problem', 'entries out of the segment'); Break; end;
    attr := R32(e); size := R32(e + 4); off := R32(e + 8);
    it := list.Obj;
    it.Str('type', Hex(attr and $FFFFFF, 6));
    it.Str('kind', MpfTypeWords(attr and $FFFFFF));
    it.Num('size', size);
    it.Num('offset', off);
    it.line := Hex(attr and $FFFFFF, 6) + ' ' + MpfTypeWords(attr and $FFFFFF) + ', ' + IntToStr(size) +
               ' B at ' + IntToStr(off);
    Inc(entries);
  end;
end;

procedure Walk(const d: TBytes; start: SizeInt; depth: Integer; n: TInfoNode; brief: Boolean;
               var w: TWalk; var embeddedLeft: Integer); forward;

{ JPEGs that start within [first, last): each found is walked (briefly) to
  its end and listed in `list` }
procedure FindEmbedded(const d: TBytes; first, last: SizeInt; const where: string; depth: Integer;
                       n: TInfoNode; var embeddedLeft: Integer);
var k, ff: SizeInt; sub: TWalk; it, list: TInfoNode;
begin
  if depth >= MAX_DEPTH then Exit;
  list := n.Find('embedded');
  k := first;
  while k + 3 <= last do begin
    if embeddedLeft <= 0 then Exit;
    ff := IndexByte(d[k], last - 2 - k, $FF);
    if ff < 0 then Exit;
    Inc(k, ff);
    if (d[k + 1] = $D8) and (d[k + 2] = $FF) then begin
      if list = nil then list := n.List('embedded');
      Dec(embeddedLeft);
      it := list.Obj;
      it.Num('offset', k);
      it.Str('where', where);
      sub := Default(TWalk);
      Walk(d, k, depth + 1, it, True, sub, embeddedLeft);
      if sub.eoiEnd > 0 then it.Num('length', sub.eoiEnd - k);
      it.line := 'at ' + IntToStr(k) + ' ' + where;
      if sub.eoiEnd > 0 then it.line := it.line + ', ' + IntToStr(sub.eoiEnd - k) + ' B'
      else it.line := it.line + ', no EOI';
      if sub.frames > 0 then
        it.line := it.line + ', ' + MarkerName(sub.sofMarker) + ' ' + IntToStr(sub.width) + 'x' +
                   IntToStr(sub.height) + ', ' + IntToStr(sub.scans) + ' scan(s)';
      if (sub.eoiEnd > k) and (sub.eoiEnd <= last) then begin k := sub.eoiEnd; Continue; end;
    end;
    Inc(k);
  end;
end;

procedure Walk(const d: TBytes; start: SizeInt; depth: Integer; n: TInfoNode; brief: Boolean;
               var w: TWalk; var embeddedLeft: Integer);
var p, q, len, segEnd, k, ff, dataStart: SizeInt; m, L, i, nc, rst: Integer;
    segs, it, frame, comps, c, problems, scans: TInfoNode; id, words: string;

  procedure Problem(const s: string);
  begin
    if problems = nil then problems := n.List('problems');
    problems.Add(TInfoNode.Create(ikText)).value := s;
  end;

  { a segment in the list; nil past MAX_LISTED (counted all the same) }
  function Seg(marker: Integer; at, segLen: Int64): TInfoNode;
  begin
    Inc(w.segments);
    Result := nil;
    if brief then Exit;
    if w.listed >= MAX_LISTED then Exit;
    Inc(w.listed);
    Result := segs.Obj;
    Result.Str('marker', MarkerName(marker));
    Result.Num('offset', at);
    if segLen >= 0 then Result.Num('length', segLen);
    Result.line := MarkerName(marker) + ' at ' + IntToStr(at);
    if segLen >= 0 then Result.line := Result.line + ', ' + IntToStr(segLen) + ' B';
  end;

begin
  problems := nil;
  len := Length(d);
  w.eoiEnd := -1;
  segs := nil;
  if not brief then segs := n.List('segments');
  frame := nil;
  scans := nil;
  if (start + 2 > len) or (d[start] <> $FF) or (d[start + 1] <> $D8) then begin Problem('no SOI'); Exit; end;
  Seg($D8, start, -1);
  p := start + 2;
  while p < len do begin
    if d[p] <> $FF then begin
      { bytes where a marker should be }
      ff := IndexByte(d[p], len - p, $FF);
      if ff < 0 then ff := len - p;
      Problem(IntToStr(ff) + ' B that are not a marker at ' + IntToStr(p));
      Inc(p, ff);
      Continue;
    end;
    q := p;
    while (q < len) and (d[q] = $FF) do Inc(q);
    if q >= len then begin Problem('cut short at ' + IntToStr(p)); Break; end;
    m := d[q];
    if q - p > 1 then
      if not brief then Problem(IntToStr(q - p - 1) + ' fill byte(s) FF before the marker at ' + IntToStr(q - 1));
    p := q - 1;                          { the marker's FF }
    if m = $D9 then begin
      Seg(m, p, -1);
      w.eoiEnd := p + 2;
      Break;
    end;
    if (m = $D8) or (m = $01) or ((m >= $D0) and (m <= $D7)) or (m = $00) then begin
      if m = $00 then Problem('FF 00 outside a scan at ' + IntToStr(p))
      else begin
        Seg(m, p, -1);
        if m = $D8 then Problem('a second SOI at ' + IntToStr(p));
        if (m >= $D0) and (m <= $D7) then Problem(MarkerName(m) + ' outside a scan at ' + IntToStr(p));
      end;
      Inc(p, 2);
      Continue;
    end;
    if p + 4 > len then begin Problem(MarkerName(m) + ' cut short at ' + IntToStr(p)); p := len; Break; end;
    L := U16(d, p + 2);
    if L < 2 then begin Problem(MarkerName(m) + ' with length ' + IntToStr(L) + ' at ' + IntToStr(p)); Break; end;
    segEnd := p + 2 + L;
    if segEnd > len then begin
      Problem(MarkerName(m) + ' at ' + IntToStr(p) + ' says ' + IntToStr(L) + ' B, the file ends first');
      segEnd := len;
    end;
    it := Seg(m, p, L);
    { the payload: [p + 4, segEnd) }
    k := p + 4;
    if IsSof(m) then begin
      Inc(w.frames);
      if m = $F7 then w.ls := True;
      if w.frames > 1 then Problem('another frame (' + MarkerName(m) + ') at ' + IntToStr(p))
      else if k + 6 <= segEnd then begin
        w.sofMarker := m;
        w.precision := d[k]; w.height := U16(d, k + 1); w.width := U16(d, k + 3);
        nc := d[k + 5];
        frame := n.Obj('frame');
        frame.Str('marker', MarkerName(m));
        frame.Str('coding', SofWords(m));
        frame.Num('precision', w.precision);
        frame.Num('width', w.width);
        frame.Num('height', w.height);
        frame.Num('components', nc);
        comps := frame.List('sampling');
        words := '';
        for i := 0 to nc - 1 do begin
          if k + 6 + 3 * i + 3 > segEnd then begin Problem('SOF cut short'); Break; end;
          c := comps.Obj;
          c.Num('id', d[k + 6 + 3 * i]);
          c.Num('h', d[k + 7 + 3 * i] shr 4);
          c.Num('v', d[k + 7 + 3 * i] and 15);
          c.Num('table', d[k + 8 + 3 * i]);
          c.line := 'component ' + IntToStr(d[k + 6 + 3 * i]) + ': ' + IntToStr(d[k + 7 + 3 * i] shr 4) + 'x' +
                    IntToStr(d[k + 7 + 3 * i] and 15) + ', table ' + IntToStr(d[k + 8 + 3 * i]);
          if words <> '' then words := words + ' ';
          words := words + IntToStr(d[k + 7 + 3 * i] shr 4) + 'x' + IntToStr(d[k + 7 + 3 * i] and 15);
        end;
        if it <> nil then
          it.line := it.line + ': ' + SofWords(m) + ', ' + IntToStr(w.precision) + ' bits, ' + IntToStr(w.width) +
                     'x' + IntToStr(w.height) + ', ' + IntToStr(nc) + ' component(s) ' + words;
      end else Problem('SOF cut short');
    end else case m of
      $E0..$EF: begin
        id := AppId(d, k, segEnd);
        if it <> nil then begin
          if id <> '' then begin
            it.Str('id', id);
            it.line := MarkerName(m) + ' ' + id + ' at ' + IntToStr(p) + ', ' + IntToStr(L) + ' B';
          end;
        end;
        if id = 'Exif' then Inc(w.exif, segEnd - k)
        else if (id = 'http://ns.adobe.com/xap/1.0/') or (id = 'http://ns.adobe.com/xmp/extension/') or (id = 'XMP') then
          Inc(w.xmp, segEnd - k)
        else if id = 'ICC_PROFILE' then Inc(w.icc, segEnd - k)
        else Inc(w.otherApp, segEnd - k);
        if (id = 'MPF') and not brief then DescribeMpf(d, k, segEnd, n);
        if not brief then FindEmbedded(d, k, segEnd, 'in ' + MarkerName(m), depth, n, embeddedLeft);
      end;
      $FE: begin
        Inc(w.comments, segEnd - k);
        Inc(w.commentCount);
      end;
      $DD: if k + 2 <= segEnd then begin
        w.ri := U16(d, k);
        if it <> nil then begin it.Num('interval', w.ri); it.line := it.line + ': every ' + IntToStr(w.ri) + ' MCUs'; end;
      end;
      $DC: if k + 2 <= segEnd then begin
        w.dnlHeight := U16(d, k);
        if it <> nil then begin it.Num('height', w.dnlHeight); it.line := it.line + ': height ' + IntToStr(w.dnlHeight); end;
      end;
      $DB: if it <> nil then begin
        { the tables it defines: precision and number }
        words := '';
        i := k;
        while i < segEnd do begin
          if words <> '' then words := words + ', ';
          words := words + IntToStr(d[i] and 15);
          if d[i] shr 4 <> 0 then begin words := words + ' (16-bit)'; Inc(i, 129); end else Inc(i, 65);
        end;
        it.Str('tables', words);
        it.line := it.line + ': table(s) ' + words;
      end;
      $C4: if it <> nil then begin
        words := '';
        i := k;
        while i + 17 <= segEnd do begin
          if words <> '' then words := words + ', ';
          if d[i] shr 4 = 0 then words := words + 'DC' else words := words + 'AC';
          words := words + IntToStr(d[i] and 15);
          L := 0;
          for nc := 1 to 16 do Inc(L, d[i + nc]);
          Inc(i, 17 + L);
        end;
        it.Str('tables', words);
        it.line := it.line + ': ' + words;
      end;
      $F8: if (it <> nil) and (k < segEnd) then begin
        it.Num('id', d[k]);
        it.line := it.line + ': id ' + IntToStr(d[k]);
      end;
      $DA: begin
        Inc(w.scans);
        if (it <> nil) and (k < segEnd) then begin
          nc := d[k];
          words := '';
          for i := 0 to nc - 1 do
            if k + 1 + 2 * i < segEnd then begin
              if words <> '' then words := words + ',';
              words := words + IntToStr(d[k + 1 + 2 * i]);
            end;
          it.Str('components', words);
          i := k + 1 + 2 * nc;
          if i + 3 <= segEnd then begin
            if w.ls then begin
              it.Num('near', d[i]); it.Num('interleave', d[i + 1]); it.Num('point_transform', d[i + 2] and 15);
              it.line := it.line + ': components ' + words + ', NEAR ' + IntToStr(d[i]) + ', interleave ' +
                         IntToStr(d[i + 1]);
            end else begin
              it.Num('ss', d[i]); it.Num('se', d[i + 1]); it.Num('ah', d[i + 2] shr 4); it.Num('al', d[i + 2] and 15);
              it.line := it.line + ': components ' + words + ', Ss ' + IntToStr(d[i]) + ' Se ' + IntToStr(d[i + 1]) +
                         ' Ah ' + IntToStr(d[i + 2] shr 4) + ' Al ' + IntToStr(d[i + 2] and 15);
            end;
          end;
        end;
        { the entropy-coded data, to the next marker that is not a restart }
        dataStart := segEnd;
        k := segEnd; rst := 0;
        while k < len do begin
          ff := IndexByte(d[k], len - k, $FF);
          if ff < 0 then begin k := len; Break; end;
          Inc(k, ff);
          if k + 1 >= len then begin k := len; Break; end;
          m := d[k + 1];
          if (m = $00) or (w.ls and (m < $80)) then Inc(k, 2)
          else if (m >= $D0) and (m <= $D7) then begin Inc(rst); Inc(k, 2); end
          else if m = $FF then Inc(k)
          else Break;
        end;
        Inc(w.restarts, rst);
        if it <> nil then begin
          it.Num('data', k - dataStart);
          it.Num('restarts', rst);
          it.line := it.line + '; data ' + IntToStr(k - dataStart) + ' B';
          if rst > 0 then it.line := it.line + ', ' + IntToStr(rst) + ' restart(s)';
        end;
        if k >= len then Problem('the file ends in a scan');
        segEnd := k;
      end;
    end;
    p := segEnd;
  end;
  if (w.eoiEnd < 0) and (p >= len) then Problem('no EOI');
end;

procedure DescribeJpeg(const d: TBytes; n: TInfoNode);
var w: TWalk; left: Integer; tail: SizeInt; meta: TInfoNode; fmt: string;
begin
  w := Default(TWalk);
  left := MAX_EMBEDDED;
  if IsJls(d) then fmt := 'JPEG-LS'
  else if IsMpo(d) then fmt := 'MPO'
  else fmt := 'JPEG';
  n.Str('format', fmt);
  n.Num('size', Length(d));
  Walk(d, 0, 0, n, False, w, left);
  n.Num('scans', w.scans);
  if w.frames > 0 then begin
    n.Bool('progressive', w.sofMarker in [$C2, $C6, $CA, $CE]);
    n.Bool('arithmetic', (w.sofMarker >= $C9) and (w.sofMarker <= $CF));
    n.Bool('lossless', w.sofMarker in [$C3, $C7, $CB, $CF, $F7]);
    n.Bool('hierarchical', w.sofMarker in [$C5..$C7, $CD..$CF]);
  end;
  n.Num('restart_interval', w.ri);
  n.Num('restarts', w.restarts);
  if w.dnlHeight > 0 then n.Num('dnl_height', w.dnlHeight);
  if w.segments > w.listed then n.Num('segments_not_listed', w.segments - w.listed);
  meta := n.Obj('metadata_bytes');
  meta.Num('exif', w.exif);
  meta.Num('xmp', w.xmp);
  meta.Num('icc', w.icc);
  meta.Num('other_app', w.otherApp);
  meta.Num('comments', w.commentCount);
  meta.Num('comment_bytes', w.comments);
  meta.line := 'Exif ' + IntToStr(w.exif) + ' B, XMP ' + IntToStr(w.xmp) + ' B, ICC ' + IntToStr(w.icc) +
               ' B, other APP ' + IntToStr(w.otherApp) + ' B, ' + IntToStr(w.commentCount) + ' COM (' +
               IntToStr(w.comments) + ' B); contents not shown';
  if w.eoiEnd > 0 then begin
    tail := Length(d) - w.eoiEnd;
    n.Num('after_eoi', tail);
    if tail > 0 then FindEmbedded(d, w.eoiEnd, Length(d), 'after the EOI', 0, n, left);
  end;
end;

initialization
  RegisterInfoProvider('JPEG', @ProbeJpeg, @DescribeJpeg);
end.

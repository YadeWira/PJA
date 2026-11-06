{ The info provider (pjainfo) of the JPEG 2000 family: raw codestreams and
  files of boxes (JP2, JPX, JPM, Motion JPEG 2000, JPH), their structure
  from the boxes and the markers alone, without decoding a sample.

  The box tree as it is written (type, place, length, depth), with what a
  few boxes say of the image (ftyp's brands, ihdr, colr's method); then
  each codestream PJA finds (pjaj2k.J2kCodestreams, the very list stream
  version 8 keeps): its SIZ (size, offsets, tiles, components and their
  bits), CAP (HTJ2K), COD (levels, layers, progression, code-block size
  and style, the wavelet: 5/3 reversible or 9/7 irreversible, SOP and
  EPH), QCD, the markers of its headers counted, its tile-parts, and what
  PJA does with it. By default (pjainfo.InfoDepth idDefault) a verdict
  from the headers alone, nothing coded: mode 2 eligible or why not (not
  reversible, RGN, HTJ2K, Part 2, its SIZ's caps, pjaj2kpx), mode 1
  analysable or why not, the codestream complete or not. With --estimate
  (idEstimate) each codestream coded as a's CompressJ2k does it: mode 2,
  then mode 1 unless mode 2 is already below mode 1's floor, the smaller
  kept; mode 0 and why (the analysis's own reason, pjaj2km).

  Privacy: no metadata is printed, only its size. The XML, UUID, label,
  URL and IPR boxes, an ICC profile and a COM marker's text are counted
  and measured, never shown. Lists are capped as the JPEG provider's:
  boxes and markers past MAX_LISTED, problems past MAX_PROBLEMS, tile-parts
  past MAX_TILE_PARTS, components past MAX_COMPONENTS and codestreams past
  MAX_CODESTREAMS are counted, not listed (nor analysed). }
unit pjainfoj2k;

{$I pja.inc}
{$ifopt R-}{$fatal pjainfoj2k: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjainfoj2k: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjainfo;

{ a raw codestream (SOC, SIZ) or the JPEG 2000 signature box }
function ProbeJ2k(const d: TBytes): Boolean;
procedure DescribeJ2k(const d: TBytes; n: TInfoNode);

implementation

uses pjaj2k, pjaj2kcs, pjaj2km, pjaj2kpx;

const
  { boxes listed one by one, and markers of a codestream's main header;
    past these, counted }
  MAX_LISTED = 300;
  { problems listed one by one; past these, counted }
  MAX_PROBLEMS = 100;
  { tile-parts listed a codestream }
  MAX_TILE_PARTS = 64;
  { components listed a codestream }
  MAX_COMPONENTS = 64;
  { codestreams described (and with --estimate coded: each costs what a's
    modes 1 and 2 cost) }
  MAX_CODESTREAMS = 32;

type
  { what the description sums up }
  TSums = record
    problems: Integer;
    boxes, listed: Integer;
    xml, uuid, labels, urls, ipr, icc, comments, commentBytes: Int64;
    xmlCount, uuidCount: Integer;
  end;

function ProbeJ2k(const d: TBytes): Boolean;
begin
  Result := J2kKind(d) <> jkNone;
end;

function Be16(const d: TBytes; p: Int64): Int64;
begin
  Result := (Int64(d[p]) shl 8) or d[p + 1];
end;

function Be32(const d: TBytes; p: Int64): Int64;
begin
  Result := (Int64(d[p]) shl 24) or (Int64(d[p + 1]) shl 16) or (Int64(d[p + 2]) shl 8) or d[p + 3];
end;

function Tag(const s: string): Int64;
begin
  Result := (Int64(Ord(s[1])) shl 24) or (Int64(Ord(s[2])) shl 16) or (Int64(Ord(s[3])) shl 8) or Ord(s[4]);
end;

{ a box type or brand as text: its four characters when they are printable,
  else its hex }
function TypeText(t: Int64): string;
var k: Integer; c: Byte;
begin
  Result := '';
  for k := 3 downto 0 do begin
    c := (t shr (8 * k)) and $FF;
    if (c < $20) or (c > $7E) then Exit('0x' + IntToHex(t, 8));
    Result := Result + Chr(c);
  end;
end;

function MarkerName(m: Integer): string;
begin
  case m of
    $4F: Result := 'SOC';
    $50: Result := 'CAP';
    $51: Result := 'SIZ';
    $52: Result := 'COD';
    $53: Result := 'COC';
    $55: Result := 'TLM';
    $56: Result := 'PRF';
    $57: Result := 'PLM';
    $58: Result := 'PLT';
    $59: Result := 'CPF';
    $5C: Result := 'QCD';
    $5D: Result := 'QCC';
    $5E: Result := 'RGN';
    $5F: Result := 'POC';
    $60: Result := 'PPM';
    $61: Result := 'PPT';
    $63: Result := 'CRG';
    $64: Result := 'COM';
    $90: Result := 'SOT';
    $91: Result := 'SOP';
    $92: Result := 'EPH';
    $93: Result := 'SOD';
    $D9: Result := 'EOC';
  else
    Result := 'FF' + IntToHex(m, 2);
  end;
end;

function ProgressionName(p: Integer): string;
begin
  case p of
    0: Result := 'LRCP';
    1: Result := 'RLCP';
    2: Result := 'RPCL';
    3: Result := 'PCRL';
    4: Result := 'CPRL';
  else
    Result := 'unknown (' + IntToStr(p) + ')';
  end;
end;

function StyleWords(s: Integer): string;
begin
  Result := '';
  if s and $01 <> 0 then Result := Result + ' BYPASS';
  if s and $02 <> 0 then Result := Result + ' RESET';
  if s and $04 <> 0 then Result := Result + ' TERMALL';
  if s and $08 <> 0 then Result := Result + ' VCAUSAL';
  if s and $10 <> 0 then Result := Result + ' PTERM';
  if s and $20 <> 0 then Result := Result + ' SEGSYM';
  if s and $40 <> 0 then Result := Result + ' HT';
  if s and $80 <> 0 then Result := Result + ' 0x80';
  if Result = '' then Result := 'none' else Delete(Result, 1, 1);
end;

function CeilDiv(a, b: Int64): Int64;
begin
  Result := (a + b - 1) div b;
end;

{ ---------- the box tree ---------- }

procedure Problem(n: TInfoNode; var sums: TSums; const s: string);
var list: TInfoNode;
begin
  Inc(sums.problems);
  if sums.problems > MAX_PROBLEMS then Exit;
  list := n.Find('problems');
  if list = nil then list := n.List('problems');
  list.Add(TInfoNode.Create(ikText)).value := s;
end;

{ the boxes between a and b, at depth; their items in list (flat, with
  their depth: the text indents them) }
procedure WalkBoxes(const d: TBytes; a, b: Int64; depth: Integer; n, list: TInfoNode; var sums: TSums;
                    var csIndex: Integer);
var p, len, head, q: Int64; t, l: Int64; it: TInfoNode; extra, pad: string; k: Integer;
begin
  p := a;
  pad := StringOfChar(' ', 2 * depth);
  while b - p > 0 do begin
    if b - p < 8 then begin
      Problem(n, sums, IntToStr(b - p) + ' B at ' + IntToStr(p) + ' that are not a box');
      Exit;
    end;
    if sums.boxes >= MAX_J2K_BOXES then begin Problem(n, sums, 'more than ' + IntToStr(MAX_J2K_BOXES) + ' boxes'); Exit; end;
    l := Be32(d, p); t := Be32(d, p + 4); head := 8;
    if l = 1 then begin
      if b - p < 16 then begin Problem(n, sums, 'a box at ' + IntToStr(p) + ' cut short'); Exit; end;
      if d[p + 8] > $7F then begin Problem(n, sums, 'a box at ' + IntToStr(p) + ' larger than the file'); Exit; end;
      len := (Be32(d, p + 8) shl 32) or Be32(d, p + 12);
      head := 16;
    end else if l = 0 then len := b - p
    else len := l;
    if (len < head) or (len > b - p) then begin
      Problem(n, sums, TypeText(t) + ' box at ' + IntToStr(p) + ' says ' + IntToStr(len) + ' B, ' +
                       IntToStr(b - p) + ' B left where it is');
      Exit;
    end;
    Inc(sums.boxes);
    q := p + head;                       { its contents: [q, p + len) }
    extra := '';
    if t = Tag('xml ') then begin Inc(sums.xml, len - head); Inc(sums.xmlCount); end
    else if t = Tag('uuid') then begin Inc(sums.uuid, len - head); Inc(sums.uuidCount); end
    else if t = Tag('lbl ') then Inc(sums.labels, len - head)
    else if t = Tag('url ') then Inc(sums.urls, len - head)
    else if t = Tag('jp2i') then Inc(sums.ipr, len - head);
    it := nil;
    if sums.listed < MAX_LISTED then begin
      Inc(sums.listed);
      it := list.Obj;
      it.Str('type', TypeText(t));
      it.Num('offset', p);
      it.Num('length', len);
      it.Num('depth', depth);
    end;
    if t = Tag('ftyp') then begin
      if len - head >= 8 then begin
        extra := ': brand ' + TrimRight(TypeText(Be32(d, q)));
        if it <> nil then begin
          it.Str('brand', TypeText(Be32(d, q)));
          it.Num('minor_version', Be32(d, q + 4));
        end;
        k := 0;
        while (q + 8 + 4 * k + 4 <= p + len) and (k < 16) do begin
          if k = 0 then extra := extra + ', compatible' else extra := extra + ',';
          extra := extra + ' ' + TrimRight(TypeText(Be32(d, q + 8 + 4 * k)));
          Inc(k);
        end;
      end;
    end else if (t = Tag('ihdr')) and (len - head >= 14) then begin
      extra := ': ' + IntToStr(Be32(d, q + 4)) + 'x' + IntToStr(Be32(d, q)) + ', ' + IntToStr(Be16(d, q + 8)) +
               ' component(s), ';
      if d[q + 10] = 255 then extra := extra + 'bits per component in bpcc'
      else extra := extra + IntToStr((d[q + 10] and $7F) + 1) + ' bits';
      if (d[q + 10] <> 255) and (d[q + 10] and $80 <> 0) then extra := extra + ' signed';
      if it <> nil then begin
        it.Num('width', Be32(d, q + 4)); it.Num('height', Be32(d, q));
        it.Num('components', Be16(d, q + 8));
        if d[q + 10] <> 255 then it.Num('bits', (d[q + 10] and $7F) + 1);
      end;
    end else if (t = Tag('colr')) and (len - head >= 3) then begin
      case d[q] of
        1: if len - head >= 7 then begin
             extra := ': enumerated colour space ' + IntToStr(Be32(d, q + 3));
             case Be32(d, q + 3) of
               16: extra := extra + ' (sRGB)';
               17: extra := extra + ' (greyscale)';
               18: extra := extra + ' (sYCC)';
             end;
             if it <> nil then it.Num('enumerated_colour_space', Be32(d, q + 3));
           end;
        2, 3: begin
             { a profile: its size, never its contents }
             Inc(sums.icc, len - head - 3);
             extra := ': ICC profile, ' + IntToStr(len - head - 3) + ' B';
             if it <> nil then it.Num('icc_bytes', len - head - 3);
           end;
        else extra := ': method ' + IntToStr(d[q]);
      end;
      if it <> nil then it.Num('method', d[q]);
    end else if t = Tag('jp2c') then begin
      if (len - head >= 4) and (d[q] = $FF) and (d[q + 1] = $4F) and (d[q + 2] = $FF) and (d[q + 3] = $51) then begin
        extra := ': codestream ' + IntToStr(csIndex);
        if it <> nil then it.Num('codestream', csIndex);
        Inc(csIndex);
      end else extra := ': not a codestream (no SOC and SIZ)';
    end else if (t = Tag('xml ')) or (t = Tag('uuid')) or (t = Tag('lbl ')) or (t = Tag('url ')) or
                (t = Tag('jp2i')) then
      extra := ': contents not shown';
    if it <> nil then it.line := pad + TypeText(t) + ' at ' + IntToStr(p) + ', ' + IntToStr(len) + ' B' + extra;
    if J2kIsSuperbox(t) then begin
      if depth < MAX_J2K_DEPTH then WalkBoxes(d, q, p + len, depth + 1, n, list, sums, csIndex)
      else Problem(n, sums, TypeText(t) + ' box at ' + IntToStr(p) + ' deeper than ' + IntToStr(MAX_J2K_DEPTH) +
                            ': not walked');
    end;
    p := p + len;
  end;
end;

{ ---------- a codestream ---------- }

type
  { what the headers say of modes 1 and 2 }
  TVerdict = record
    notRev, part2: string;
    rgn, ht: Boolean;
    htMixed, part1Cb: Boolean;   { a code-block style with the mixed bit, without the HT bit }
  end;

{ a marker segment of a main or tile-part header (its contents [q, q +
  L - 2)), for the verdict; csiz: the SIZ's components (COC and QCC give a
  component in 1 byte below 257, else 2) }
procedure Judge(const d: TBytes; m: Integer; q, L: Int64; csiz: Integer; var vd: TVerdict);
var c: Int64;
begin
  if csiz < 257 then c := 1 else c := 2;
  case m of
    $52: if L >= 12 then begin
      if (d[q] and $F8 <> 0) and (vd.part2 = '') then vd.part2 := 'Part 2: COD style';
      if d[q + 8] and $40 <> 0 then vd.ht := True;
      if d[q + 8] and $80 <> 0 then vd.htMixed := True;
      if d[q + 8] and $40 = 0 then vd.part1Cb := True;
      if (d[q + 9] <> 1) and (vd.notRev = '') then vd.notRev := 'not reversible: the 9/7 wavelet';
    end;
    $53: if L >= 2 + c + 6 then begin
      if (d[q + c] and $FE <> 0) and (vd.part2 = '') then vd.part2 := 'Part 2: COC style';
      if d[q + c + 4] and $40 <> 0 then vd.ht := True;
      if d[q + c + 4] and $80 <> 0 then vd.htMixed := True;
      if d[q + c + 4] and $40 = 0 then vd.part1Cb := True;
      if (d[q + c + 5] <> 1) and (vd.notRev = '') then vd.notRev := 'not reversible: the 9/7 wavelet';
    end;
    $5C: if (L >= 3) and (d[q] and $1F <> 0) and (vd.notRev = '') then vd.notRev := 'not reversible: quantized';
    $5D: if (L >= 2 + c + 1) and (d[q + c] and $1F <> 0) and (vd.notRev = '') then
           vd.notRev := 'not reversible: quantized';
    $5E: vd.rgn := True;
    $72, $73: if vd.part2 = '' then vd.part2 := 'Part 2 decomposition';
  end;
end;

procedure DescribeCodestream(const d: TBytes; off, len: Int64; n: TInfoNode; var sums: TSums);
var p, e, L, q, psot, hdrEnd, tiles, tx, ty, xsiz, ysiz, xo, yo, xt, yt, xto, yto, sp: Int64; i: Integer;
    m, k, v, nl, prog, csiz: Integer; segs: Int64; it, siz, cod, comps, c, parts, hdr, sum: TInfoNode;
    counts: array[0..255] of Int64; seen: array of Boolean; tp, tpListed, tilesSeen: Int64;
    words: string; eoc, ht, capSeen: Boolean; stream, s2, sizRaw: TBytes; why, why2, m1, m2, m3: string;
    r: TMode1Result; r2: TMode2Result; floor1: Int64; tried1, complete: Boolean;
    listed, problems0: Integer; vd: TVerdict; ok2, ok1: Boolean; st3: TJ2kStats;
begin
  vd := Default(TVerdict); sizRaw := nil; csiz := 0;
  problems0 := sums.problems;
  n.Num('offset', off);
  n.Num('length', len);
  for k := 0 to 255 do counts[k] := 0;
  e := off + len;
  ht := False; capSeen := False; eoc := False;
  xt := 0; yt := 0; xsiz := 0; ysiz := 0; xto := 0; yto := 0; tiles := 0;
  hdr := n.List('main_header');
  listed := 0; segs := 0;
  { the main header: SOC, then marker segments up to the first SOT }
  p := off + 2;
  counts[$4F] := 1;
  while True do begin
    if p + 4 > e then begin Problem(n, sums, 'the main header cut short at ' + IntToStr(p)); Break; end;
    if d[p] <> $FF then begin Problem(n, sums, 'no marker at ' + IntToStr(p)); Break; end;
    m := d[p + 1];
    if m = $90 then Break;
    if (m < $40) or (m = $4F) or (m = $93) or (m = $D9) then begin
      Problem(n, sums, MarkerName(m) + ' in the main header at ' + IntToStr(p)); Break;
    end;
    L := Be16(d, p + 2);
    if (L < 2) or (p + 2 + L > e) then begin
      Problem(n, sums, MarkerName(m) + ' at ' + IntToStr(p) + ' says ' + IntToStr(L) + ' B, the codestream ends first');
      Break;
    end;
    Inc(counts[m]);
    Inc(segs);
    q := p + 4;                          { its contents: [q, p + 2 + L) }
    if m = $51 then sizRaw := Copy(d, p, L + 2)
    else Judge(d, m, q, L, csiz, vd);
    it := nil;
    if listed < MAX_LISTED then begin
      Inc(listed);
      it := hdr.Obj;
      it.Str('marker', MarkerName(m));
      it.Num('offset', p);
      it.Num('length', L);
      it.line := MarkerName(m) + ' at ' + IntToStr(p) + ', ' + IntToStr(L) + ' B';
    end;
    case m of
      $51: if L >= 41 then begin
        xsiz := Be32(d, q + 2); ysiz := Be32(d, q + 6); xo := Be32(d, q + 10); yo := Be32(d, q + 14);
        xt := Be32(d, q + 18); yt := Be32(d, q + 22); xto := Be32(d, q + 26); yto := Be32(d, q + 30);
        csiz := Be16(d, q + 34);
        siz := n.Obj('siz');
        siz.Num('rsiz', Be16(d, q));
        siz.Num('width', xsiz - xo); siz.Num('height', ysiz - yo);
        siz.Num('x_offset', xo); siz.Num('y_offset', yo);
        siz.Num('tile_width', xt); siz.Num('tile_height', yt);
        siz.Num('tile_x_offset', xto); siz.Num('tile_y_offset', yto);
        siz.Num('components', csiz);
        if (xt > 0) and (yt > 0) and (xsiz > xto) and (ysiz > yto) then begin
          tx := CeilDiv(xsiz - xto, xt); ty := CeilDiv(ysiz - yto, yt);
          tiles := tx * ty;
          siz.Num('tiles', tiles);
          siz.Str('tile_grid', IntToStr(tx) + 'x' + IntToStr(ty));
        end else Problem(n, sums, 'SIZ: no tile grid');
        comps := siz.List('component_list');
        words := '';
        for i := 0 to csiz - 1 do begin
          sp := q + 36 + 3 * i;
          if sp + 3 > p + 2 + L then begin Problem(n, sums, 'SIZ cut short'); Break; end;
          if i >= MAX_COMPONENTS then begin siz.Num('components_not_listed', csiz - MAX_COMPONENTS); Break; end;
          c := comps.Obj;
          c.Num('bits', (d[sp] and $7F) + 1);
          c.Bool('signed', d[sp] and $80 <> 0);
          c.Num('dx', d[sp + 1]); c.Num('dy', d[sp + 2]);
          c.line := IntToStr((d[sp] and $7F) + 1) + ' bits';
          if d[sp] and $80 <> 0 then c.line := c.line + ' signed';
          c.line := c.line + ', subsampled ' + IntToStr(d[sp + 1]) + 'x' + IntToStr(d[sp + 2]);
          if i < 4 then begin
            if words <> '' then words := words + ' ';
            words := words + IntToStr((d[sp] and $7F) + 1);
          end;
        end;
        if it <> nil then
          it.line := it.line + ': ' + IntToStr(xsiz - xo) + 'x' + IntToStr(ysiz - yo) + ', ' + IntToStr(csiz) +
                     ' component(s) of ' + words + ' bits, tiles ' + IntToStr(xt) + 'x' + IntToStr(yt);
      end else Problem(n, sums, 'SIZ cut short');
      $50: begin
        capSeen := True;
        { Pcap: bit 17 (from the least) for Part 15, HTJ2K }
        if L >= 6 then ht := Be32(d, q) and $00020000 <> 0;
        if (it <> nil) and ht then it.line := it.line + ': Part 15 (HTJ2K)';
      end;
      $52: if L >= 12 then begin
        if n.Find('cod') = nil then begin
          cod := n.Obj('cod');
          prog := d[q + 1];
          nl := d[q + 5];
          cod.Num('levels', nl);
          cod.Num('layers', Be16(d, q + 2));
          cod.Str('progression', ProgressionName(prog));
          cod.Num('mct', d[q + 4]);
          if (d[q + 6] <= 8) and (d[q + 7] <= 8) then begin
            cod.Num('code_block_width', 1 shl (d[q + 6] + 2));
            cod.Num('code_block_height', 1 shl (d[q + 7] + 2));
          end else Problem(n, sums, 'COD: code-block size out of range');
          cod.Num('code_block_style', d[q + 8]);
          cod.Str('code_block_style_words', StyleWords(d[q + 8]));
          if d[q + 9] = 1 then cod.Str('wavelet', '5/3 reversible')
          else if d[q + 9] = 0 then cod.Str('wavelet', '9/7 irreversible')
          else cod.Str('wavelet', 'unknown (' + IntToStr(d[q + 9]) + ')');
          cod.Bool('reversible', d[q + 9] = 1);
          cod.Bool('precincts', d[q] and 1 <> 0);
          cod.Bool('sop', d[q] and 2 <> 0);
          cod.Bool('eph', d[q] and 4 <> 0);
          if it <> nil then begin
            it.line := it.line + ': ' + IntToStr(nl) + ' level(s), ' + IntToStr(Be16(d, q + 2)) + ' layer(s), ' +
                       ProgressionName(prog);
            if (d[q + 6] <= 8) and (d[q + 7] <= 8) then
              it.line := it.line + ', code-blocks ' + IntToStr(1 shl (d[q + 6] + 2)) + 'x' + IntToStr(1 shl (d[q + 7] + 2));
            it.line := it.line + ' (' + StyleWords(d[q + 8]) + ')';
            if d[q + 9] = 1 then it.line := it.line + ', 5/3 reversible'
            else if d[q + 9] = 0 then it.line := it.line + ', 9/7 irreversible';
            if d[q] and 2 <> 0 then it.line := it.line + ', SOP';
            if d[q] and 4 <> 0 then it.line := it.line + ', EPH';
          end;
          if d[q + 8] and $40 <> 0 then ht := True;
        end;
      end else Problem(n, sums, 'COD cut short');
      $5C: if (L >= 3) and (it <> nil) then begin
        v := d[q] and $1F;
        case v of
          0: words := 'no quantization';
          1: words := 'scalar derived';
          2: words := 'scalar expounded';
        else words := 'style ' + IntToStr(v);
        end;
        it.Str('quantization', words);
        it.Num('guard_bits', d[q] shr 5);
        it.line := it.line + ': ' + words + ', ' + IntToStr(d[q] shr 5) + ' guard bit(s)';
      end;
      $64: begin
        { a comment: its size and whether it says it is text, never what it says }
        Inc(sums.comments);
        if L > 4 then Inc(sums.commentBytes, L - 4);
        if (it <> nil) and (L >= 4) then begin
          if Be16(d, q) = 1 then it.line := it.line + ': text, contents not shown'
          else it.line := it.line + ': binary, contents not shown';
        end;
      end;
    end;
    p := p + 2 + L;
  end;
  if listed >= MAX_LISTED then n.Num('main_header_not_listed', segs - listed);
  { the tile-parts: SOT, its header's markers to the SOD, Psot bytes in all }
  parts := nil;
  tp := 0; tpListed := 0; tilesSeen := 0;
  if (tiles > 0) and (tiles <= 65535) then SetLength(seen, tiles) else seen := nil;
  while (p + 2 <= e) and (d[p] = $FF) and (d[p + 1] = $90) do begin
    if (p + 12 > e) or (Be16(d, p + 2) <> 10) then begin Problem(n, sums, 'SOT at ' + IntToStr(p) + ' cut short'); Break; end;
    Inc(counts[$90]);
    psot := Be32(d, p + 6);
    if psot = 0 then begin
      { to the EOC that ends the codestream }
      if (e - p >= 14) and (d[e - 2] = $FF) and (d[e - 1] = $D9) then psot := e - 2 - p else psot := e - p;
    end;
    if (psot < 14) or (psot > e - p) then begin
      Problem(n, sums, 'tile-part at ' + IntToStr(p) + ' says ' + IntToStr(psot) + ' B, ' + IntToStr(e - p) + ' B left');
      Break;
    end;
    k := Be16(d, p + 4);
    if (seen <> nil) and (k < Length(seen)) and not seen[k] then begin seen[k] := True; Inc(tilesSeen); end;
    { its header: marker segments up to the SOD }
    q := p + 12; hdrEnd := p + psot;
    while q + 2 <= hdrEnd do begin
      if d[q] <> $FF then begin Problem(n, sums, 'no marker at ' + IntToStr(q)); Break; end;
      m := d[q + 1];
      if m = $93 then begin Inc(counts[m]); q := q + 2; Break; end;
      if (q + 4 > hdrEnd) or (Be16(d, q + 2) < 2) or (q + 2 + Be16(d, q + 2) > hdrEnd) then begin
        Problem(n, sums, MarkerName(m) + ' at ' + IntToStr(q) + ' cut short'); Break;
      end;
      Inc(counts[m]);
      Judge(d, m, q + 4, Be16(d, q + 2), csiz, vd);
      if m = $64 then begin
        Inc(sums.comments);
        if Be16(d, q + 2) > 4 then Inc(sums.commentBytes, Be16(d, q + 2) - 4);
      end;
      q := q + 2 + Be16(d, q + 2);
    end;
    if tpListed < MAX_TILE_PARTS then begin
      if parts = nil then parts := n.List('tile_parts');
      it := parts.Obj;
      it.Num('tile', k); it.Num('part', d[p + 10]); it.Num('parts', d[p + 11]);
      it.Num('offset', p); it.Num('length', psot); it.Num('header', q - p);
      it.line := 'tile ' + IntToStr(k) + ' part ' + IntToStr(d[p + 10]) + ' at ' + IntToStr(p) + ', ' +
                 IntToStr(psot) + ' B (header ' + IntToStr(q - p) + ' B)';
      Inc(tpListed);
    end;
    Inc(tp);
    p := p + psot;
  end;
  if tp > tpListed then n.Num('tile_parts_not_listed', tp - tpListed);
  n.Num('tile_part_count', tp);
  if seen <> nil then n.Num('tiles_present', tilesSeen);
  if (p + 2 <= e) and (d[p] = $FF) and (d[p + 1] = $D9) then begin
    eoc := True; Inc(counts[$D9]); p := p + 2;
  end else Problem(n, sums, 'no EOC');
  n.Bool('eoc', eoc);
  if e - p > 0 then n.Num('after_eoc', e - p);
  n.Bool('ht', ht);
  n.Bool('cap', capSeen);
  { the markers met, with how many }
  sum := n.Obj('markers');
  words := '';
  for k := 0 to 255 do
    if counts[k] > 0 then begin
      sum.Num(MarkerName(k), counts[k]);
      if words <> '' then words := words + ', ';
      words := words + MarkerName(k);
      if counts[k] > 1 then words := words + ' x' + IntToStr(counts[k]);
    end;
  sum.line := words;
  { what PJA does with it: what stream version 8 decides (pjacodec's
    CompressJ2k), with --estimate; else what the headers say of it }
  it := n.Obj('pja');
  if ht then vd.ht := True;
  complete := (sums.problems = problems0) and eoc and ((seen = nil) or (tilesSeen = tiles));
  if InfoDepth <> idEstimate then begin
    it.Bool('estimated', False);
    it.Bool('complete', complete);
    { mode 2: the headers' reasons, in the order the encoder meets them }
    if sizRaw = nil then m2 := 'no SIZ'
    else m2 := J2kMode2SizWhy(sizRaw, len);
    if m2 = '' then begin
      if vd.ht then m2 := 'HTJ2K'
      else if vd.part2 <> '' then m2 := vd.part2
      else if vd.notRev <> '' then m2 := vd.notRev
      else if vd.rgn then m2 := 'RGN';
    end;
    if m2 = '' then begin
      it.Str('mode2', 'eligible');
      words := 'mode 2: eligible by its headers (whether every code-block has all its passes only --estimate tells)';
    end else begin
      it.Str('mode2', 'not eligible');
      it.Str('mode2_reason', m2);
      words := 'mode 2: not eligible: ' + m2;
    end;
    m1 := '';
    if vd.ht then m1 := 'HTJ2K' else if vd.part2 <> '' then m1 := vd.part2;
    if m1 = '' then begin
      it.Str('mode1', 'analysable');
      words := words + '; mode 1: analysable by its headers';
    end else begin
      it.Str('mode1', 'not analysable');
      it.Str('mode1_reason', m1);
      words := words + '; mode 1: not analysable: ' + m1;
    end;
    { mode 3: an HTJ2K codestream whose code-blocks are all HT ones }
    if not vd.ht then m3 := 'not HTJ2K'
    else if vd.htMixed then m3 := 'HTJ2K: mixed code-blocks'
    else if vd.part1Cb then m3 := 'HTJ2K: Part 1 code-blocks'
    else if vd.part2 <> '' then m3 := vd.part2
    else m3 := '';
    if m3 = '' then begin
      it.Str('mode3', 'eligible');
      words := words + '; mode 3: eligible by its headers (HTJ2K)';
    end else begin
      it.Str('mode3', 'not eligible');
      it.Str('mode3_reason', m3);
      if vd.ht then words := words + '; mode 3: not eligible: ' + m3;
    end;
    if not complete then words := words + '; not complete (see its problems)';
    it.line := 'not estimated (pja info --estimate codes it): ' + words;
    Exit;
  end;
  it.Bool('estimated', True);
  if QWord(len) > InfoMaxOutput then begin
    it.Str('mode', 'not analysed');
    it.line := 'not analysed: larger than --max-output';
    Exit;
  end;
  { as CompressJ2k: an HTJ2K codestream in mode 3 or nothing }
  if J2kIsHt(d, off, len) then begin
    st3 := Default(TJ2kStats);
    r := J2kMode3Encode(d, off, len, InfoThreads, stream, why, st3);
    if (r = m1Ok) and (Length(stream) < len) then begin
      it.Num('mode', 3);
      it.Num('stream_bytes', Length(stream));
      it.Fixed('saving_percent', 100 * (len - Length(stream)) / len);
      it.Num('ht_code_blocks', st3.htCbs);
      it.Num('ht_code_blocks_as_bytes', st3.cbRaw);
      it.line := 'mode 3 (HTJ2K, modelled): ' + IntToStr(len) + ' B -> ' + IntToStr(Length(stream)) + ' B, ' +
                 DotNumber(100 * (len - Length(stream)) / len, 2) + '% less; ' + IntToStr(st3.htCbs) +
                 ' code-blocks modelled, ' + IntToStr(st3.cbRaw) + ' kept as bytes';
    end else begin
      if r = m1Ok then why := 'its stream would not be smaller (' + IntToStr(Length(stream)) + ' B)'
      else if why = '' then why := 'refused';
      it.Num('mode', 0);
      it.Str('reason', why);
      it.line := 'mode 0 (as bytes): mode 3: ' + why;
    end;
    Exit;
  end;
  { as CompressJ2k: mode 2 first (its stream kept only when shorter than
    the codestream), then mode 1 unless mode 2's is no longer than mode 1's
    could be at the least; the smaller }
  floor1 := 0;
  r2 := J2kMode2Encode(d, off, len, InfoThreads, len, s2, why2, floor1);
  ok2 := r2 = m2Ok;
  if ok2 then it.Num('mode2_stream_bytes', Length(s2))
  else begin
    if why2 = '' then why2 := 'refused';
    it.Str('mode2_reason', why2);
  end;
  tried1 := not ok2 or (Length(s2) > floor1);
  ok1 := False; r := m1Refused; why := ''; stream := nil;
  if tried1 then begin
    r := J2kMode1Encode(d, off, len, InfoThreads, stream, why);
    ok1 := (r = m1Ok) and (Length(stream) < len);
    if r = m1Ok then it.Num('mode1_stream_bytes', Length(stream))
    else begin
      if why = '' then why := 'refused';
      it.Str('mode1_reason', why);
    end;
  end else it.Str('mode1_reason', 'not tried: mode 2''s stream is below what mode 1 could reach');
  if ok2 and (not ok1 or (Length(s2) <= Length(stream))) then begin
    it.Num('mode', 2);
    it.Num('stream_bytes', Length(s2));
    it.Fixed('saving_percent', 100 * (len - Length(s2)) / len);
    it.line := 'mode 2 (pixels): ' + IntToStr(len) + ' B -> ' + IntToStr(Length(s2)) + ' B, ' +
               DotNumber(100 * (len - Length(s2)) / len, 2) + '% less; mode 1: ';
    if not tried1 then it.line := it.line + 'not tried (mode 2 is below what it could reach)'
    else if r = m1Ok then it.line := it.line + IntToStr(Length(stream)) + ' B'
    else it.line := it.line + why;
  end else if ok1 then begin
    it.Num('mode', 1);
    it.Num('stream_bytes', Length(stream));
    it.Fixed('saving_percent', 100 * (len - Length(stream)) / len);
    it.line := 'mode 1 (modelled): ' + IntToStr(len) + ' B -> ' + IntToStr(Length(stream)) + ' B, ' +
               DotNumber(100 * (len - Length(stream)) / len, 2) + '% less; mode 2: ';
    if ok2 then it.line := it.line + IntToStr(Length(s2)) + ' B' else it.line := it.line + why2;
  end else begin
    it.Num('mode', 0);
    if r = m1Ok then why := 'its stream would not be smaller (' + IntToStr(Length(stream)) + ' B)';
    it.Str('reason', why);
    it.line := 'mode 0 (as bytes): ' + why;
    if why2 <> why then it.line := it.line + '; mode 2: ' + why2;
  end;
end;

procedure DescribeJ2k(const d: TBytes; n: TInfoNode);
var sums: TSums; boxes, list, it, meta: TInfoNode; cs: TJ2kCodestreams; i, csIndex: Integer; ext: string;
begin
  sums := Default(TSums);
  ext := J2kExtension(d);
  case ext of
    'j2k': n.Str('format', 'JPEG 2000 codestream');
    'jpx': n.Str('format', 'JPX');
    'jpm': n.Str('format', 'JPM');
    'mj2': n.Str('format', 'Motion JPEG 2000');
    'jph': n.Str('format', 'JPH (HTJ2K)');
  else
    n.Str('format', 'JP2');
  end;
  n.Num('size', Length(d));
  if J2kKind(d) = jkBoxes then begin
    boxes := n.List('boxes');
    csIndex := 0;
    WalkBoxes(d, 0, Length(d), 0, n, boxes, sums, csIndex);
    n.Num('box_count', sums.boxes);
    if sums.boxes > sums.listed then n.Num('boxes_not_listed', sums.boxes - sums.listed);
  end;
  J2kCodestreams(d, cs);
  n.Num('codestream_count', Length(cs));
  list := n.List('codestreams');
  for i := 0 to High(cs) do begin
    if i >= MAX_CODESTREAMS then begin
      n.Num('codestreams_not_listed', Length(cs) - MAX_CODESTREAMS);
      Break;
    end;
    it := list.Obj;
    DescribeCodestream(d, cs[i].off, cs[i].len, it, sums);
  end;
  if (J2kKind(d) = jkCodestream) and (Length(cs) = 1) and (cs[0].len < Length(d)) then
    n.Num('after_codestream', Length(d) - cs[0].len);
  meta := n.Obj('metadata_bytes');
  meta.Num('xml', sums.xml); meta.Num('xml_boxes', sums.xmlCount);
  meta.Num('uuid', sums.uuid); meta.Num('uuid_boxes', sums.uuidCount);
  meta.Num('labels', sums.labels); meta.Num('urls', sums.urls); meta.Num('ipr', sums.ipr);
  meta.Num('icc', sums.icc);
  meta.Num('comments', sums.comments); meta.Num('comment_bytes', sums.commentBytes);
  meta.line := 'XML ' + IntToStr(sums.xml) + ' B, UUID ' + IntToStr(sums.uuid) + ' B, ICC ' + IntToStr(sums.icc) +
               ' B, labels ' + IntToStr(sums.labels) + ' B, URLs ' + IntToStr(sums.urls) + ' B, IPR ' +
               IntToStr(sums.ipr) + ' B, ' + IntToStr(sums.comments) + ' COM (' + IntToStr(sums.commentBytes) +
               ' B); contents not shown';
  if sums.problems > MAX_PROBLEMS then n.Num('problems_not_listed', sums.problems - MAX_PROBLEMS);
end;

initialization
  RegisterInfoProvider('JPEG 2000', @ProbeJ2k, @DescribeJ2k);
end.

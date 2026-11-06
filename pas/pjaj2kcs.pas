{ JPEG 2000 Part 1 codestreams taken apart and put back together, byte for
  byte (doc/CODEC.md, "JPEG 2000, stage B").

  J2kAnalyze takes a codestream (SOC to EOC) to
  - its headers' bytes (the main header's and the tile-parts' marker
    segments as they are, but for the ones that follow from the rest: TLM,
    PLT, Psot);
  - side information: per packet whether it is empty and its SOP and EPH,
    per code-block of a packet whether it is in it, its zero bit-planes (the
    first time) and its new coding passes, the tag trees' values a decoder
    learns that do not follow from those, Lblock where it is not the least
    the lengths need, a packet header that does not come back as the
    canonical one, and per segment of a code-block how its bytes end
    (FLUSH, ERTERM, the shortest prefix of either that still decodes, a
    literal tail after the bytes committed, raw bytes; a BYPASS segment's
    padding) and where a layer cuts it (OpenJPEG's rule, the shortest valid
    prefix near the bytes committed, how far the decoder has read, or the
    length);
  - the decisions: every code-block's coding passes decoded (pjaj2kt1.c),
    one bit each, in the order of the tile, the component, the
    resolution, the band and the code-block's place in it.
  J2kRebuild gives the codestream back from those alone: the decisions
  coded again with the MQ coder and ended as the side information says,
  the packet headers written again (tag trees, Lblock, lengths), the
  tile-parts put together.

  The packets come in the order of the progression (LRCP, RLCP, RPCL,
  PCRL, CPRL) and of the POC markers, as OpenJPEG 2 counts them; their
  headers are in the tile-parts or in PPM or PPT (kept as they are). A
  tile-part's bytes that are not whole packets (a codestream cut short,
  padding) are kept as they are, and so is a code-block whose passes do not
  decode within the limits. Refused (the whole codestream, the caller keeps
  its bytes): HTJ2K (CAP, the HT code-block style), Part 2's decomposition
  styles, what is out of the limits below or does not parse; and anything
  whose rebuild does not give the codestream back, which J2kAnalyze checks
  before it says yes.

  Bounded: tiles as the SIZ allows them (at most 65,535), components 16,384,
  2^21 code-blocks and 2^22 precincts a tile, 2^26 steps of the progression
  in all, 2^25 code-block entries of a tile's packets, 120 coding passes a
  code-block (more: its bytes kept as they are), a literal tail of 16 MB.
  J2kRebuild checks everything it reads from the blob against these and
  against what it has built so far, and refuses a blob that does not hold;
  the C side is only given buffers whose sizes it is told.

  Stage B has no stream of its own: the blob (a version byte, the streams'
  lengths, the streams) is what stage C will code with a model of the
  decisions and of the side information, as codec stream version 8's mode 1. }
unit pjaj2kcs;

{$I pja.inc}
{$ifopt R-}{$fatal pjaj2kcs: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaj2kcs: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { the side information's streams }
  SH_HDR = 0; SH_LAY = 1; SH_T2 = 2; SH_ZBP = 3; SH_TREE = 4; SH_LB = 5; SH_T1R = 6; SH_T1X = 7;
  SH_HDRX = 8; SH_DEC = 9; J2K_NSTREAMS = 10;

type
  TJ2kStats = record
    codestreams, tiles, packets, hdrExceptions, treeOverrides, lbNonMinimal: Int64;
    cbs, cbRaw, segs, rawSegs, bounds, tails, tailBits, decisions: Int64;
    rule: array[0..15] of Int64;      { segments by how they end }
    brule: array[0..3] of Int64;      { layer boundaries: OpenJPEG's, shortest prefix, explicit, decoder's reach }
    side: array[0..J2K_NSTREAMS - 1] of Int64;
  end;

{ The codestream data[off..off + len) as side information and decisions,
  one blob that J2kRebuild turns back into it; checked here. False and
  why when it is refused. }
function J2kAnalyze(const data: TBytes; off, len: Int64; out blob: TBytes; out reason: string;
  var st: TJ2kStats): Boolean;
{ The codestream from the blob alone; False when the blob does not hold one,
  and why: a check that failed, or (a bug) 'exception ...' }
function J2kRebuild(const blob: TBytes; out cs: TBytes): Boolean;
function J2kRebuildWhy(const blob: TBytes; out cs: TBytes; out why: string): Boolean;
function J2kStreamName(i: Integer): string;
function J2kRuleName(i: Integer): string;

implementation

{$L pjaj2kt1.o}

function pjaj2k_t1_decode(w, h, orient, sty, npasses: LongInt; data: PByte; seglen, segpasses: PLongInt;
  nseg: LongInt; sym: PByte; symcap: Int64; passend: PLongInt; st: PByte): Int64; cdecl; external;
function pjaj2k_t1_replay(w, h, orient, sty, npasses: LongInt; bits: PByte; bitpos, nbits: Int64;
  out used: Int64; sym: PByte; symcap: Int64; passend: PLongInt; st: PByte): Int64; cdecl; external;
function pjaj2k_mq_encode(sym: PByte; n: Int64; pe: PInt64; npe, reset: LongInt; ctx, F, E: PByte;
  cap: Int64; outv, Kp: PInt64): LongInt; cdecl; external;
function pjaj2k_mq_valid(X: PByte; L: Int64; ctx0, sym: PByte; lim: Int64; pe: PInt64;
  npe, reset: LongInt): LongInt; cdecl; external;
function pjaj2k_mq_minprefix(X: PByte; n: Int64; ctx0, sym: PByte; nsym: Int64; pe: PInt64;
  npe, reset, window: LongInt): Int64; cdecl; external;
function pjaj2k_raw_pack(sym: PByte; n: Int64; pad: LongInt; outp: PByte; cap: Int64): Int64; cdecl; external;
function pjaj2k_mq_reach(X: PByte; n: Int64; ctx0, sym: PByte; lim: Int64; pe: PInt64;
  npe, reset: LongInt): Int64; cdecl; external;

const
  MAXNL = 32;
  MAXCOMPS = 16384;
  MAXTILES = 65535;
  MAXCBS = 1 shl 21;
  MAXPRECINCTS = 1 shl 22;
  MAXITER = Int64(1) shl 26;
  MAXENTRIES = 1 shl 25;
  MAXPASSES = 120;
  ZBPLIMIT = 128;          { the zero bit-planes' tag tree is read to this threshold }
  MINWINDOW = 32;          { the shortest valid prefix is looked for this many bytes down at most }
  TAILMAX = 1 shl 24;      { a literal tail's bytes, at most }
  INF = High(LongInt);

  { how a segment ends (the T1R stream) }
  R_FLUSH = 0; R_ERTERM = 1; R_MINF = 2; R_MINE = 3; R_TAILE = 4; R_TAILF = 5; R_RAW = 6; R_EMPTY = 7;
  R_PAD0 = 10; R_PAD1 = 11; R_PAD2 = 12; R_RAWB = 13;

type
  EJ2k = class(Exception);

procedure Refuse(const why: string);
begin
  raise EJ2k.Create(why);
end;

function J2kStreamName(i: Integer): string;
const N: array[0..J2K_NSTREAMS - 1] of string = ('hdr', 'layout', 't2', 'zbp', 'tree', 'lblock', 't1rule',
  't1x', 'hdrx', 'dec');
begin
  if (i >= 0) and (i < J2K_NSTREAMS) then Result := N[i] else Result := '?';
end;

function J2kRuleName(i: Integer): string;
begin
  case i of
    R_FLUSH: Result := 'flush'; R_ERTERM: Result := 'erterm'; R_MINF: Result := 'minprefix(flush)';
    R_MINE: Result := 'minprefix(erterm)'; R_TAILE: Result := 'tail(erterm)'; R_TAILF: Result := 'tail(flush)';
    R_RAW: Result := 'raw'; R_EMPTY: Result := 'empty'; R_PAD0: Result := 'bypass pad 0101';
    R_PAD1: Result := 'bypass pad 0'; R_PAD2: Result := 'bypass pad 1'; R_RAWB: Result := 'bypass raw';
    else Result := '';
  end;
end;

{ ------------------------------------------------------------------ bytes }
type
  TBW = record
    d: TBytes; n: SizeInt;
    procedure Put(b: Byte);
    procedure PutN(const src: TBytes; off, cnt: Int64);
    procedure V(x: QWord);
    procedure S(x: Int64);
    function Bytes: TBytes;
  end;
  TBR = record
    d: TBytes; p, e: SizeInt;
    function Get: Byte;
    function V: QWord;
    function VI(maxv: Int64): Int64;
    function S: Int64;
    function SI(minv, maxv: Int64): Int64;
    procedure GetN(var w: TBW; cnt: Int64);
    function Take(cnt: Int64): TBytes;
  end;

procedure Grow(var d: TBytes; need: Int64);
var old: SizeInt;
begin
  if need <= Length(d) then Exit;
  old := Length(d);
  if need < 2 * Int64(old) + 256 then need := 2 * Int64(old) + 256;
  SetLength(d, need);
  FillChar(d[old], Length(d) - old, 0);
end;

procedure TBW.Put(b: Byte);
begin
  if n >= Length(d) then Grow(d, n + 1);
  d[n] := b; Inc(n);
end;

procedure TBW.PutN(const src: TBytes; off, cnt: Int64);
begin
  if cnt <= 0 then Exit;
  if (off < 0) or (off + cnt > Length(src)) then Refuse('internal: PutN');
  Grow(d, n + cnt);
  Move(src[off], d[n], cnt); Inc(n, cnt);
end;

procedure TBW.V(x: QWord);
begin
  while x >= 128 do begin Put(Byte(x and 127) or 128); x := x shr 7; end;
  Put(Byte(x));
end;

procedure TBW.S(x: Int64);
begin
  if x < 0 then V((QWord(-(x + 1)) shl 1) or 1) else V(QWord(x) shl 1);
end;

function TBW.Bytes: TBytes;
begin
  Result := Copy(d, 0, n);
end;

function TBR.Get: Byte;
begin
  if p >= e then Refuse('side information cut short');
  Result := d[p]; Inc(p);
end;

function TBR.V: QWord;
var sh: Integer; b: Byte;
begin
  Result := 0; sh := 0;
  repeat
    b := Get;
    if sh > 63 then Refuse('bad number');
    Result := Result or (QWord(b and 127) shl sh); Inc(sh, 7);
  until b < 128;
end;

function TBR.VI(maxv: Int64): Int64;
var x: QWord;
begin
  x := V;
  if x > QWord(maxv) then Refuse('number out of range');
  Result := Int64(x);
end;

function TBR.S: Int64;
var x: QWord;
begin
  x := V;
  if x and 1 <> 0 then Result := -Int64(x shr 1) - 1 else Result := Int64(x shr 1);
end;

function TBR.SI(minv, maxv: Int64): Int64;
begin
  Result := S;
  if (Result < minv) or (Result > maxv) then Refuse('number out of range');
end;

procedure TBR.GetN(var w: TBW; cnt: Int64);
begin
  if (cnt < 0) or (cnt > e - p) then Refuse('side information cut short');
  if cnt = 0 then Exit;
  Grow(w.d, w.n + cnt);
  Move(d[p], w.d[w.n], cnt); Inc(w.n, cnt); Inc(p, cnt);
end;

function TBR.Take(cnt: Int64): TBytes;
begin
  if (cnt < 0) or (cnt > e - p) then Refuse('side information cut short');
  Result := Copy(d, p, cnt); Inc(p, cnt);
end;

function Be16(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 8) or d[p + 1];
end;

function Be32(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 24) or (Cardinal(d[p + 1]) shl 16) or (Cardinal(d[p + 2]) shl 8) or d[p + 3];
end;

function FloorDivP2(a: Int64; n: Integer): Int64;
begin
  if a >= 0 then Result := a shr n else Result := -((-a + (Int64(1) shl n) - 1) shr n);
end;

function CeilDivP2(a: Int64; n: Integer): Int64;
begin
  Result := -FloorDivP2(-a, n);
end;

function CeilDiv(a, b: Int64): Int64;
begin
  if a >= 0 then Result := (a + b - 1) div b else Result := -((-a) div b);
end;

function Flog2(x: QWord): Integer;
begin
  Result := 0;
  while x > 1 do begin x := x shr 1; Inc(Result); end;
end;

function Max64(a, b: Int64): Int64; begin if a > b then Result := a else Result := b; end;
function Min64(a, b: Int64): Int64; begin if a < b then Result := a else Result := b; end;

{ the address of d[i] without a range check, for the C side (which is
  given every length); nil for an empty array }
function At(const d: TBytes; i: SizeInt): PByte; inline;
begin
  Result := PByte(Pointer(d));
  if Result <> nil then Inc(Result, i);
end;

{ ------------------------------------------------------------------ headers }
type
  TCodC = record
    nl, xcb, ycb, sty: Integer; prec: Boolean;
    pp: array[0..MAXNL] of Byte;       { PPx in the low nibble, PPy in the high one }
  end;
  TQntC = record
    style, guard, n: Integer;
    ex: array[0..3 * MAXNL] of Byte;   { the bands' exponents as given }
  end;
  TPocE = record rs, cs, lye, re, ce, prg: Integer; end;
  TItem = record
    code: Integer;
    raw: TBytes;                       { the marker segment, marker and length included }
    kind: Integer;                     { 0 as it is; 1 TLM, 2 PLT that follow from the rest }
    z, st: Byte; cnt: Integer;
  end;
  TTp = record
    isot, tpsot, tnsot, psotMode: Integer; psot: Int64;
    hstart, dstart, dend: Int64;       { analysis: where it is }
    items: array of TItem;
    npk, pk0: Integer;                 { its packets, the first's index in its tile }
    gap: TBytes;                       { what follows them in its data }
    ppmOff, ppmLen: Int64;             { its hdrPacked headers in the PPM data }
    plens: array of Int64;             { its packets' lengths }
    bytes: TBytes;                     { rebuild: the whole tile-part }
  end;
  TCodG = record have: Boolean; scod, prog, layers: Integer; cod: TCodC; end;
  { what the headers say for one tile }
  TParams = record
    g: TCodG;
    cod: array of TCodC;
    qnt: array of TQntC;
    pocs: array of TPocE;
  end;

  TBandG = record
    orient: Integer; x0, y0, x1, y1: Int64; cbw, cbh: Integer; gx0, gy0: Int64; ncbx, ncby: Integer;
    base, mb, comp, res: Integer;
  end;
  TResG = record
    x0, y0, x1, y1: Int64; ppx, ppy, pw, ph, prBase, nb: Integer; band: array[0..2] of Integer;
  end;
  TCompG = record
    dx, dy: Integer; x0, y0, x1, y1: Int64; nres, res0, sty: Integer;
  end;

  TEmit = function(c, r, p, l: Integer): Boolean of object;

  { one codestream, analysed or rebuilt }
  TJ2k = class
    an: Boolean;                       { analysing (else rebuilding) }
    cs: TBytes; csOff, csLen: Int64;   { analysis: the codestream }
    sw: array[0..J2K_NSTREAMS - 1] of TBW;
    sr: array[0..J2K_NSTREAMS - 1] of TBR;
    dbits: Int64;                      { the decisions' bits written or read }
    st: TJ2kStats;
    { SIZ }
    xsiz, ysiz, xosiz, yosiz, xtsiz, ytsiz, xtosiz, ytosiz: Int64;
    ncomp, nxt, nyt: Integer;
    cdx, cdy: array of Integer;
    { the headers }
    main: array of TItem;
    tps: array of TTp;
    tail: TBytes;
    mainG: TCodG; mainCoc: array of TCodC; hasMainCoc: array of Boolean;
    mainQcd: TQntC; hasMainQcd: Boolean; mainQcc: array of TQntC; hasMainQcc: array of Boolean;
    mainPoc: array of TPocE;
    ppm: TBW; hasPpm: Boolean;
    iterations: Int64;
    { the tile at hand }
    tileNo: Integer; tx0, ty0, tx1, ty1: Int64;
    par: TParams;
    comps: array of TCompG; ress: array of TResG; bands: array of TBandG;
    ncb, nprec: Integer;
    hdrPacked: Boolean; pkd: TBytes; pkdLen: Int64; pkdPos: Int64;
    tileTps: array of Integer;
    { code-blocks }
    cbBand, cbFirst, cbZbp, cbPasses, cbNseg, cbSegHave, cbSegMax, cbLb, cbHead, cbTail, cbPb, cbLeaf,
      cbELb: array of LongInt;
    cbDOff, cbCur: array of Int64;
    cbData: TBW;
    bandZ: array of LongInt;
    { precincts, their bands, the tag trees }
    prNext, prPb: array of LongInt;
    pbCw, pbCh, pbLx, pbLy, pbBand, pbNode, pbNn: array of LongInt;
    npb: Integer;
    ndParent, ndLow, ndVal, eLow, eVal: array of LongInt;
    eKnown: array of Boolean;
    nnd: Integer;
    lgNode, lgLow, lgVal: array of LongInt; nlg: Integer;
    { packets, their code-block entries, the pieces of the code-blocks' segments }
    pkC, pkR, pkP, pkL, pkFlags, pkNsop, pkIe0, pkIeN: array of LongInt;
    pkHdrPos, pkHdrLen, pkStart, pkEnd: array of Int64;
    npk, nsopLast: Integer;
    ieCb, ieFlags, ieNp, ieInc, iePc0, iePcN: array of LongInt;
    nie: Integer;
    pcSeg, pcNp, pcNext: array of LongInt;
    pcLen, pcPos: array of Int64;
    npc: Integer;
    { the packet being read: its code-blocks }
    tCb, tIncl, tFirst, tZbp, tNp, tInc, tL0, tLn, tNps: array of LongInt;
    tLens: array of Int64;
    { analysis: where the tile is being read; rebuild: how many packets }
    curTp: Integer; curPos: Int64; npkTarget: Integer;
    tileOut: TBW; tilePk: array of Int64;
    { tier-1 buffers }
    symb, fb, eb, segdata: TBytes;
    passend: array of LongInt;
    stb: TBytes;
    seglen, segpass, segp0: array of LongInt;
    pev, kpv: array of Int64;
    { the bit reader of packet headers }
    brD: TBytes; brP, brE: Int64; brBuf, brCt: Cardinal; brBad: Boolean;
    { the bit writer }
    bw: TBW; bwBuf, bwCt: Cardinal;
    constructor Create(analysing: Boolean);
    { headers }
    procedure ParseMainItem(const it: TItem);
    procedure ParseCod(const d: TBytes; p, e: Int64; isCoc: Boolean; out c: TCodC; out g: TCodG);
    procedure ParseQnt(const d: TBytes; p, e: Int64; out q: TQntC);
    function CompIndex(const d: TBytes; var p: Int64): Integer;
    procedure Structure;
    procedure SplitPpm;
    procedure TileParams;
    procedure Geometry;
    { packets }
    procedure Iterate(emit: TEmit);
    function PbOf(c, r, p: Integer): Integer;
    procedure MakePb(c, r, p: Integer);
    function NewNodes(cw, ch: Integer): Integer;
    function BitIn: Integer;
    function BitsIn(n: Integer): QWord;
    procedure Undo(n: Integer);
    procedure LogNode(nd: Integer);
    function TTDecode(base, leaf, thr: Integer): Boolean;
    function TryPacket(c, r, p, l: Integer; tpEnd: Int64): Boolean;
    function EmitAnalyse(c, r, p, l: Integer): Boolean;
    function EmitRebuild(c, r, p, l: Integer): Boolean;
    procedure AddIe(cb, flags, np, lbInc: Integer);
    procedure NextSeg(sty: Integer; var nseg, have, mx: Integer);
    procedure Derive(cb, np: Integer; pos: Int64; l0: Integer; useLens: Boolean);
    function Pieces(cb, np, k0: Integer): Integer;
    procedure Trees;
    procedure DoCb(cb: Integer);
    procedure BitOut(b: Integer);
    procedure BitsOut(v: QWord; n: Integer);
    procedure TTEncode(base, leaf, thr: Integer);
    procedure Pass3;
    procedure Tile(t: Integer);
    procedure WriteHeaders;
    procedure ReadHeaders;
    function Assemble: TBytes;
  end;

constructor TJ2k.Create(analysing: Boolean);
begin
  inherited Create;
  an := analysing;
end;

{ FF30 to FF3F: markers without a segment, which a decoder skips }
function IsBareMarker(m: Integer): Boolean;
begin
  Result := (m >= $FF30) and (m <= $FF3F);
end;

function IsMarkerWithLength(m: Integer): Boolean;
begin
  { FF30-FF3F, SOC, SOD, EOC have no length; FF00 and FFFF are not markers }
  Result := not ((m < $FF40) or (m = $FF4F) or (m = $FF93) or (m = $FFD9) or (m = $FFFF));
end;

function TJ2k.CompIndex(const d: TBytes; var p: Int64): Integer;
begin
  if ncomp < 257 then begin Result := d[p]; Inc(p); end
  else begin Result := Be16(d, p); Inc(p, 2); end;
end;

procedure TJ2k.ParseCod(const d: TBytes; p, e: Int64; isCoc: Boolean; out c: TCodC; out g: TCodG);
var s, i: Integer;
begin
  c := Default(TCodC); g := Default(TCodG);
  if isCoc then begin
    if p + 1 > e then Refuse('COC');
    s := d[p]; Inc(p);
    if s and $FE <> 0 then Refuse('COC: Part 2 style');
  end else begin
    if p + 5 > e then Refuse('COD');
    s := d[p]; g.scod := s; g.prog := d[p + 1]; g.layers := Be16(d, p + 2); Inc(p, 5);
    if s and $F8 <> 0 then Refuse('COD: Part 2 style');
    if g.prog > 4 then Refuse('COD: progression');
    if g.layers = 0 then Refuse('COD: layers');
    g.have := True;
  end;
  if p + 5 > e then Refuse('COD');
  c.nl := d[p]; c.xcb := d[p + 1] + 2; c.ycb := d[p + 2] + 2; c.sty := d[p + 3]; Inc(p, 5);
  if c.nl > MAXNL then Refuse('COD: levels');
  if (c.xcb > 10) or (c.ycb > 10) or (c.xcb + c.ycb > 12) then Refuse('COD: code-block size');
  if c.sty and $40 <> 0 then Refuse('HTJ2K');
  if c.sty and $80 <> 0 then Refuse('COD: code-block style');
  c.prec := s and 1 <> 0;
  for i := 0 to c.nl do
    if c.prec then begin
      if p + 1 > e then Refuse('COD: precincts');
      c.pp[i] := d[p]; Inc(p);
      if (i > 0) and ((c.pp[i] and 15 = 0) or (c.pp[i] shr 4 = 0)) then Refuse('COD: precinct size');
    end else c.pp[i] := $FF;
  g.cod := c;
end;

procedure TJ2k.ParseQnt(const d: TBytes; p, e: Int64; out q: TQntC);
var i: Integer;
begin
  q := Default(TQntC);
  if p + 1 > e then Refuse('QCD');
  q.style := d[p] and 31; q.guard := d[p] shr 5; Inc(p);
  case q.style of
    0: begin
         q.n := Min64(e - p, Length(q.ex));
         for i := 0 to q.n - 1 do q.ex[i] := d[p + i] shr 3;
       end;
    1, 2: begin
         q.n := Min64((e - p) div 2, Length(q.ex));
         for i := 0 to q.n - 1 do q.ex[i] := d[p + 2 * i] shr 3;
       end;
    else Refuse('QCD: style');
  end;
end;

procedure AddPocs(j: TJ2k; const d: TBytes; p, e: Int64; var pocs: array of TPocE; var cnt: Integer); forward;

procedure TJ2k.ParseMainItem(const it: TItem);
var c, i: Integer; p, e: Int64; cc: TCodC; g: TCodG; q: TQntC; n: Integer;
begin
  p := 4; e := Length(it.raw);
  case it.code of
    $FF52: begin ParseCod(it.raw, p, e, False, cc, g); mainG := g; end;
    $FF53: begin
             c := CompIndex(it.raw, p);
             if c >= ncomp then Refuse('COC: component');
             ParseCod(it.raw, p, e, True, cc, g); mainCoc[c] := cc; hasMainCoc[c] := True;
           end;
    $FF5C: begin ParseQnt(it.raw, p, e, q); mainQcd := q; hasMainQcd := True; end;
    $FF5D: begin
             c := CompIndex(it.raw, p);
             if c >= ncomp then Refuse('QCC: component');
             ParseQnt(it.raw, p, e, q); mainQcc[c] := q; hasMainQcc[c] := True;
           end;
    $FF5F: begin
             n := Length(mainPoc);
             SetLength(mainPoc, n + (e - p) div 7 + 1);
             AddPocs(Self, it.raw, p, e, mainPoc, n);
             SetLength(mainPoc, n);
           end;
    $FF50: { CAP: Part 15 (HTJ2K) }
           if (e >= 8) and (Be32(it.raw, 4) and (1 shl 17) <> 0) then Refuse('HTJ2K');
    $FF60: begin
             hasPpm := True;
           end;
    $FF72, $FF73: Refuse('Part 2 decomposition');
  end;
  if (it.code = $FF51) then begin
    { SIZ }
    if e < 4 + 38 then Refuse('SIZ');
    xsiz := Be32(it.raw, 6); ysiz := Be32(it.raw, 10); xosiz := Be32(it.raw, 14); yosiz := Be32(it.raw, 18);
    xtsiz := Be32(it.raw, 22); ytsiz := Be32(it.raw, 26); xtosiz := Be32(it.raw, 30); ytosiz := Be32(it.raw, 34);
    ncomp := Be16(it.raw, 38);
    if (ncomp < 1) or (ncomp > MAXCOMPS) or (e < 40 + 3 * Int64(ncomp)) then Refuse('SIZ: components');
    if (xtsiz = 0) or (ytsiz = 0) or (xsiz <= xosiz) or (ysiz <= yosiz) or (xtosiz > xosiz) or (ytosiz > yosiz) or
       (xtosiz + xtsiz <= xosiz) or (ytosiz + ytsiz <= yosiz) then Refuse('SIZ: grid');
    if CeilDiv(xsiz - xtosiz, xtsiz) * CeilDiv(ysiz - ytosiz, ytsiz) > MAXTILES then Refuse('SIZ: tiles');
    nxt := CeilDiv(xsiz - xtosiz, xtsiz); nyt := CeilDiv(ysiz - ytosiz, ytsiz);
    SetLength(cdx, ncomp); SetLength(cdy, ncomp);
    for i := 0 to ncomp - 1 do begin
      cdx[i] := it.raw[41 + 3 * i]; cdy[i] := it.raw[42 + 3 * i];
      if (cdx[i] = 0) or (cdy[i] = 0) then Refuse('SIZ: subsampling');
    end;
    SetLength(mainCoc, ncomp); SetLength(hasMainCoc, ncomp); SetLength(mainQcc, ncomp); SetLength(hasMainQcc, ncomp);
  end;
end;

procedure AddPocs(j: TJ2k; const d: TBytes; p, e: Int64; var pocs: array of TPocE; var cnt: Integer);
var sz: Integer; x: TPocE;
begin
  if j.ncomp < 257 then sz := 7 else sz := 9;
  while (p + sz <= e) and (cnt <= High(pocs)) do begin
    x.rs := d[p]; Inc(p);
    x.cs := j.CompIndex(d, p);
    x.lye := Be16(d, p); Inc(p, 2);
    x.re := d[p]; Inc(p);
    x.ce := j.CompIndex(d, p);
    x.prg := d[p]; Inc(p);
    if x.prg > 4 then Refuse('POC: progression');
    pocs[cnt] := x; Inc(cnt);
  end;
end;

{ analysis: the main header and the tile-parts, where they are }
procedure TJ2k.Structure;
var p, e, q, L: Int64; m, n, i: Integer; it: TItem; tp: TTp; ok: Boolean;
begin
  e := csOff + csLen;
  if (csLen < 4) or (cs[csOff] <> $FF) or (cs[csOff + 1] <> $4F) then Refuse('no SOC');
  p := csOff + 2; n := 0;
  while True do begin
    if p + 4 > e then Refuse('main header cut short');
    if cs[p] <> $FF then Refuse('main header');
    m := Be16(cs, p);
    if m = $FF90 then Break;
    if (n = 0) and (m <> $FF51) then Refuse('no SIZ');
    if IsBareMarker(m) then begin
      it := Default(TItem); it.code := m; it.raw := Copy(cs, p, 2);
      SetLength(main, n + 1); main[n] := it; Inc(n);
      p := p + 2;
      Continue;
    end;
    if not IsMarkerWithLength(m) then Refuse('main header');
    L := Be16(cs, p + 2);
    if (L < 2) or (p + 2 + L > e) then Refuse('main header');
    it := Default(TItem); it.code := m; it.raw := Copy(cs, p, 2 + L);
    SetLength(main, n + 1); main[n] := it; Inc(n);
    ParseMainItem(it);
    p := p + 2 + L;
  end;
  if not mainG.have then Refuse('no COD');
  if not hasMainQcd then Refuse('no QCD');
  { the tile-parts }
  n := 0;
  while p + 2 <= e do begin
    if (cs[p] <> $FF) or (cs[p + 1] <> $90) or (p + 12 > e) or (Be16(cs, p + 2) <> 10) then Break;
    tp := Default(TTp);
    tp.hstart := p; tp.isot := Be16(cs, p + 4); tp.psot := Be32(cs, p + 6); tp.tpsot := cs[p + 10];
    tp.tnsot := cs[p + 11];
    if tp.isot >= nxt * nyt then Refuse('SOT: tile');
    q := p + 12; ok := False; i := 0;
    while q + 2 <= e do begin
      m := Be16(cs, q);
      if m = $FF93 then begin ok := True; Break; end;
      if IsBareMarker(m) then begin
        it := Default(TItem); it.code := m; it.raw := Copy(cs, q, 2);
        SetLength(tp.items, i + 1); tp.items[i] := it; Inc(i);
        q := q + 2;
        Continue;
      end;
      if (cs[q] <> $FF) or not IsMarkerWithLength(m) or (q + 4 > e) then Break;
      L := Be16(cs, q + 2);
      if (L < 2) or (q + 2 + L > e) then Break;
      it := Default(TItem); it.code := m; it.raw := Copy(cs, q, 2 + L);
      SetLength(tp.items, i + 1); tp.items[i] := it; Inc(i);
      q := q + 2 + L;
    end;
    if not ok then Break;
    tp.dstart := q + 2;
    if tp.psot = 0 then begin
      tp.psotMode := 1; tp.dend := e;
      if (e - 2 >= tp.dstart) and (cs[e - 2] = $FF) and (cs[e - 1] = $D9) then tp.dend := e - 2;
    end else if p + tp.psot > e then begin
      tp.psotMode := 2; tp.dend := e;
    end else begin
      tp.psotMode := 0; tp.dend := p + tp.psot;
      if tp.dend < tp.dstart then Refuse('SOT: Psot');
    end;
    SetLength(tps, n + 1); tps[n] := tp; Inc(n);
    p := tp.dend;
    if tp.psotMode = 1 then Break;
  end;
  if n = 0 then Refuse('no tile-part');
  tail := Copy(cs, p, e - p);
  SplitPpm;
end;

{ what holds for tile t: the main header's, then its tile-parts' headers }
procedure TJ2k.TileParams;
var i, j, c, z: Integer; p, e: Int64; cc: TCodC; g: TCodG; q: TQntC; tg: TCodG;
  tcoc: array of TCodC; htcoc: array of Boolean; tqcc: array of TQntC; htqcc: array of Boolean;
  tqcd: TQntC; htqcd: Boolean; tpoc: array of TPocE; npoc: Integer;
begin
  tg := Default(TCodG); htqcd := False; tcoc := nil; htcoc := nil; tqcc := nil; htqcc := nil; tpoc := nil; npoc := 0;
  tqcd := Default(TQntC);
  hdrPacked := hasPpm; pkdLen := 0;
  SetLength(pkd, 0);
  for j := 0 to High(tileTps) do
    with tps[tileTps[j]] do begin
      if hasPpm and (ppmLen > 0) then begin
        Grow(pkd, pkdLen + ppmLen);
        Move(ppm.d[ppmOff], pkd[pkdLen], ppmLen); Inc(pkdLen, ppmLen);
      end;
      for i := 0 to High(items) do begin
        p := 4; e := Length(items[i].raw);
        case items[i].code of
          $FF52: begin ParseCod(items[i].raw, p, e, False, cc, g); tg := g; end;
          $FF53: begin
                   c := CompIndex(items[i].raw, p);
                   if c >= ncomp then Refuse('COC: component');
                   if tcoc = nil then begin SetLength(tcoc, ncomp); SetLength(htcoc, ncomp); end;
                   ParseCod(items[i].raw, p, e, True, cc, g); tcoc[c] := cc; htcoc[c] := True;
                 end;
          $FF5C: begin ParseQnt(items[i].raw, p, e, q); tqcd := q; htqcd := True; end;
          $FF5D: begin
                   c := CompIndex(items[i].raw, p);
                   if c >= ncomp then Refuse('QCC: component');
                   if tqcc = nil then begin SetLength(tqcc, ncomp); SetLength(htqcc, ncomp); end;
                   ParseQnt(items[i].raw, p, e, q); tqcc[c] := q; htqcc[c] := True;
                 end;
          $FF5F: begin
                   SetLength(tpoc, npoc + (e - p) div 7 + 1);
                   AddPocs(Self, items[i].raw, p, e, tpoc, npoc);
                   SetLength(tpoc, npoc);
                 end;
          $FF61: begin
                   if hasPpm then Refuse('PPM and PPT');
                   if e < 5 then Refuse('PPT');
                   hdrPacked := True;
                 end;
          $FF72, $FF73: Refuse('Part 2 decomposition');
        end;
      end;
    end;
  { PPT: the tile's marker segments' data in the order of their index Zppt }
  if hdrPacked and not hasPpm then
    for z := 0 to 255 do
      for j := 0 to High(tileTps) do
        with tps[tileTps[j]] do
          for i := 0 to High(items) do
            if (items[i].code = $FF61) and (items[i].raw[4] = z) and (Length(items[i].raw) > 5) then begin
              Grow(pkd, pkdLen + Length(items[i].raw) - 5);
              Move(items[i].raw[5], pkd[pkdLen], Length(items[i].raw) - 5); Inc(pkdLen, Length(items[i].raw) - 5);
            end;
  par := Default(TParams);
  if tg.have then par.g := tg else par.g := mainG;
  SetLength(par.cod, ncomp); SetLength(par.qnt, ncomp);
  for c := 0 to ncomp - 1 do begin
    par.cod[c] := mainG.cod;
    if hasMainCoc[c] then par.cod[c] := mainCoc[c];
    if tg.have then par.cod[c] := tg.cod;
    if (htcoc <> nil) and htcoc[c] then par.cod[c] := tcoc[c];
    par.qnt[c] := mainQcd;
    if hasMainQcc[c] then par.qnt[c] := mainQcc[c];
    if htqcd then par.qnt[c] := tqcd;
    if (htqcc <> nil) and htqcc[c] then par.qnt[c] := tqcc[c];
  end;
  if npoc > 0 then par.pocs := tpoc else par.pocs := Copy(mainPoc);
end;

{ the tile's components, resolutions, bands, code-blocks and precincts }
procedure TJ2k.Geometry;
var c, r, b, nb, ix, nl, lv, n, cbw, cbh, xo, yo, ebi: Integer; p, q: Int64; cbs, precs: Int64;
  cg: TCompG; rg: TResG; bg: TBandG;
const XOFF: array[0..2] of Integer = (1, 0, 1); YOFF: array[0..2] of Integer = (0, 1, 1);
begin
  p := tileNo mod nxt; q := tileNo div nxt;
  tx0 := Max64(xtosiz + p * xtsiz, xosiz); ty0 := Max64(ytosiz + q * ytsiz, yosiz);
  tx1 := Min64(xtosiz + (p + 1) * xtsiz, xsiz); ty1 := Min64(ytosiz + (q + 1) * ytsiz, ysiz);
  if (tx0 >= tx1) or (ty0 >= ty1) then Refuse('empty tile');
  SetLength(comps, ncomp); SetLength(ress, 0); SetLength(bands, 0);
  cbs := 0; precs := 0; nb := 0; ix := 0;
  for c := 0 to ncomp - 1 do begin
    cg := Default(TCompG);
    cg.dx := cdx[c]; cg.dy := cdy[c];
    cg.x0 := CeilDiv(tx0, cg.dx); cg.y0 := CeilDiv(ty0, cg.dy); cg.x1 := CeilDiv(tx1, cg.dx); cg.y1 := CeilDiv(ty1, cg.dy);
    nl := par.cod[c].nl; cg.nres := nl + 1; cg.res0 := ix; cg.sty := par.cod[c].sty;
    if Length(ress) < ix + cg.nres then SetLength(ress, 2 * Length(ress) + cg.nres + 8);
    for r := 0 to nl do begin
      rg := Default(TResG);
      lv := nl - r;
      rg.x0 := CeilDivP2(cg.x0, lv); rg.y0 := CeilDivP2(cg.y0, lv); rg.x1 := CeilDivP2(cg.x1, lv); rg.y1 := CeilDivP2(cg.y1, lv);
      rg.ppx := par.cod[c].pp[r] and 15; rg.ppy := par.cod[c].pp[r] shr 4;
      if rg.x0 = rg.x1 then rg.pw := 0 else rg.pw := CeilDivP2(rg.x1, rg.ppx) - FloorDivP2(rg.x0, rg.ppx);
      if rg.y0 = rg.y1 then rg.ph := 0 else rg.ph := CeilDivP2(rg.y1, rg.ppy) - FloorDivP2(rg.y0, rg.ppy);
      if Int64(rg.pw) * rg.ph + precs > MAXPRECINCTS then Refuse('limits: precincts');
      rg.prBase := precs; precs := precs + Int64(rg.pw) * rg.ph;
      if r = 0 then rg.nb := 1 else rg.nb := 3;
      if r = 0 then begin cbw := Min64(par.cod[c].xcb, rg.ppx); cbh := Min64(par.cod[c].ycb, rg.ppy); end
      else begin cbw := Min64(par.cod[c].xcb, rg.ppx - 1); cbh := Min64(par.cod[c].ycb, rg.ppy - 1); end;
      for b := 0 to rg.nb - 1 do begin
        bg := Default(TBandG);
        bg.comp := c; bg.res := r;
        if r = 0 then begin
          bg.orient := 0; bg.x0 := rg.x0; bg.y0 := rg.y0; bg.x1 := rg.x1; bg.y1 := rg.y1; ebi := 0;
        end else begin
          n := nl - r + 1; xo := XOFF[b]; yo := YOFF[b]; bg.orient := b + 1;
          bg.x0 := CeilDivP2(cg.x0 - (Int64(xo) shl (n - 1)), n); bg.y0 := CeilDivP2(cg.y0 - (Int64(yo) shl (n - 1)), n);
          bg.x1 := CeilDivP2(cg.x1 - (Int64(xo) shl (n - 1)), n); bg.y1 := CeilDivP2(cg.y1 - (Int64(yo) shl (n - 1)), n);
          ebi := 1 + 3 * (r - 1) + b;
        end;
        bg.cbw := cbw; bg.cbh := cbh;
        if (bg.x0 >= bg.x1) or (bg.y0 >= bg.y1) then begin bg.ncbx := 0; bg.ncby := 0; end
        else begin
          bg.gx0 := FloorDivP2(bg.x0, cbw); bg.gy0 := FloorDivP2(bg.y0, cbh);
          if (CeilDivP2(bg.x1, cbw) - bg.gx0) * (CeilDivP2(bg.y1, cbh) - bg.gy0) + cbs > MAXCBS then Refuse('limits: code-blocks');
          bg.ncbx := CeilDivP2(bg.x1, cbw) - bg.gx0; bg.ncby := CeilDivP2(bg.y1, cbh) - bg.gy0;
        end;
        bg.base := cbs; cbs := cbs + Int64(bg.ncbx) * bg.ncby;
        { Mb, only a prediction of the passes }
        if par.qnt[c].style = 1 then begin
          if ebi = 0 then bg.mb := par.qnt[c].guard + par.qnt[c].ex[0] - 1
          else bg.mb := par.qnt[c].guard + Max64(0, par.qnt[c].ex[0] - (ebi - 1) div 3) - 1;
        end else if ebi < par.qnt[c].n then bg.mb := par.qnt[c].guard + par.qnt[c].ex[ebi] - 1
        else bg.mb := par.qnt[c].guard + 8;
        if Length(bands) <= nb then SetLength(bands, 2 * Length(bands) + 8);
        bands[nb] := bg; rg.band[b] := nb; Inc(nb);
      end;
      ress[ix] := rg; Inc(ix);
    end;
    comps[c] := cg;
  end;
  SetLength(bands, nb); SetLength(ress, ix);
  ncb := cbs; nprec := precs;
  SetLength(cbBand, ncb); SetLength(cbFirst, ncb); SetLength(cbZbp, ncb); SetLength(cbPasses, ncb);
  SetLength(cbNseg, ncb); SetLength(cbSegHave, ncb); SetLength(cbSegMax, ncb); SetLength(cbLb, ncb);
  SetLength(cbHead, ncb); SetLength(cbTail, ncb); SetLength(cbPb, ncb); SetLength(cbLeaf, ncb); SetLength(cbELb, ncb);
  SetLength(cbDOff, ncb); SetLength(cbCur, ncb);
  for b := 0 to nb - 1 do
    for n := bands[b].base to bands[b].base + bands[b].ncbx * bands[b].ncby - 1 do cbBand[n] := b;
  for n := 0 to ncb - 1 do begin
    cbFirst[n] := -1; cbZbp[n] := 0; cbPasses[n] := 0; cbNseg[n] := 0; cbSegHave[n] := 0; cbSegMax[n] := 0;
    cbLb[n] := 3; cbHead[n] := -1; cbTail[n] := -1; cbPb[n] := -1; cbLeaf[n] := 0;
  end;
  SetLength(prNext, nprec); SetLength(prPb, nprec);
  for n := 0 to nprec - 1 do begin prNext[n] := 0; prPb[n] := -1; end;
  npb := 0; nnd := 0; npk := 0; nie := 0; npc := 0; nlg := 0;
end;

{ ------------------------------------------------------------------ the progression }
{ calls emit(c, r, p, l) for each packet of the tile in its order (as
  OpenJPEG 2's pi.c), each at most once; stops when emit says False. False
  when the steps would go past the limit. }
procedure TJ2k.Iterate(emit: TEmit);
var pocs: array of TPocE; k, l, r, c, pr, rs, re, cs0, ce, ly, nres, lv, rpx, rpy, prci, prcj, idx: Integer;
  maxres: Integer; dx, dy, x, y, ddx, ddy: Int64; rg: TResG; cg: TCompG;

  procedure Step;
  begin
    Inc(iterations);
    if iterations > MAXITER then Refuse('limits: progression');
  end;

  { the packets of precinct (c, r, pr), layers up to ly: False to stop }
  function Layers(cc, rr, pp: Integer): Boolean;
  var ll: Integer;
  begin
    Result := True;
    idx := ress[comps[cc].res0 + rr].prBase + pp;
    for ll := prNext[idx] to ly - 1 do begin
      Step;
      prNext[idx] := ll + 1;
      if not emit(cc, rr, pp, ll) then Exit(False);
    end;
  end;

  { the precinct at position (x, y) of resolution r of component c, or -1 }
  function PrecAt(cc, rr: Integer; xx, yy: Int64): Integer;
  var dxl, dyl: Int64;
  begin
    Result := -1;
    cg := comps[cc]; rg := ress[cg.res0 + rr];
    lv := cg.nres - 1 - rr;
    rpx := rg.ppx + lv; rpy := rg.ppy + lv;
    if (rpx >= 31) or (rpy >= 31) then Exit;
    dxl := Int64(cg.dx) shl rpx; dyl := Int64(cg.dy) shl rpy;
    if not ((yy mod dyl = 0) or ((yy = ty0) and (((rg.y0 shl lv) mod (Int64(1) shl rpy)) <> 0))) then Exit;
    if not ((xx mod dxl = 0) or ((xx = tx0) and (((rg.x0 shl lv) mod (Int64(1) shl rpx)) <> 0))) then Exit;
    if (rg.pw = 0) or (rg.ph = 0) then Exit;
    if (rg.x0 = rg.x1) or (rg.y0 = rg.y1) then Exit;
    prci := FloorDivP2(CeilDiv(xx, Int64(cg.dx) shl lv), rg.ppx) - FloorDivP2(rg.x0, rg.ppx);
    prcj := FloorDivP2(CeilDiv(yy, Int64(cg.dy) shl lv), rg.ppy) - FloorDivP2(rg.y0, rg.ppy);
    if (prci < 0) or (prcj < 0) or (prci >= rg.pw) or (prcj >= rg.ph) then Exit;
    Result := prci + prcj * rg.pw;
  end;

  procedure MinStep(c0, c1: Integer; out mx, my: Int64);
  var cc, rr, l2: Integer; v: Int64;
  begin
    mx := 0; my := 0;
    for cc := c0 to c1 - 1 do
      for rr := 0 to comps[cc].nres - 1 do begin
        rg := ress[comps[cc].res0 + rr]; l2 := comps[cc].nres - 1 - rr;
        if rg.ppx + l2 < 40 then begin
          v := Int64(comps[cc].dx) shl (rg.ppx + l2);
          if (mx = 0) or (v < mx) then mx := v;
        end;
        if rg.ppy + l2 < 40 then begin
          v := Int64(comps[cc].dy) shl (rg.ppy + l2);
          if (my = 0) or (v < my) then my := v;
        end;
      end;
  end;

begin
  maxres := 0;
  for c := 0 to ncomp - 1 do if comps[c].nres > maxres then maxres := comps[c].nres;
  if Length(par.pocs) > 0 then pocs := par.pocs
  else begin
    SetLength(pocs, 1);
    pocs[0].rs := 0; pocs[0].cs := 0; pocs[0].lye := par.g.layers; pocs[0].re := maxres; pocs[0].ce := ncomp;
    pocs[0].prg := par.g.prog;
  end;
  MinStep(0, ncomp, dx, dy);
  for k := 0 to High(pocs) do begin
    rs := pocs[k].rs; re := Min64(pocs[k].re, maxres); cs0 := pocs[k].cs; ce := Min64(pocs[k].ce, ncomp);
    ly := Min64(pocs[k].lye, par.g.layers);
    case pocs[k].prg of
      0: { LRCP }
        for l := 0 to ly - 1 do
          for r := rs to re - 1 do
            for c := cs0 to ce - 1 do begin
              Step;
              if r >= comps[c].nres then Continue;
              rg := ress[comps[c].res0 + r];
              for pr := 0 to rg.pw * rg.ph - 1 do begin
                Step;
                idx := rg.prBase + pr;
                if prNext[idx] > l then Continue;
                if prNext[idx] < l then Continue;   { an earlier layer not given: not this one either }
                prNext[idx] := l + 1;
                if not emit(c, r, pr, l) then Exit;
              end;
            end;
      1: { RLCP }
        for r := rs to re - 1 do
          for l := 0 to ly - 1 do
            for c := cs0 to ce - 1 do begin
              Step;
              if r >= comps[c].nres then Continue;
              rg := ress[comps[c].res0 + r];
              for pr := 0 to rg.pw * rg.ph - 1 do begin
                Step;
                idx := rg.prBase + pr;
                if prNext[idx] <> l then Continue;
                prNext[idx] := l + 1;
                if not emit(c, r, pr, l) then Exit;
              end;
            end;
      2: { RPCL }
        begin
          if (dx <= 0) or (dy <= 0) then Refuse('progression step');
          for r := rs to re - 1 do begin
            y := ty0;
            while y < ty1 do begin
              x := tx0;
              while x < tx1 do begin
                for c := cs0 to ce - 1 do begin
                  Step;
                  if r >= comps[c].nres then Continue;
                  pr := PrecAt(c, r, x, y);
                  if pr < 0 then Continue;
                  if not Layers(c, r, pr) then Exit;
                end;
                x := x + dx - (x mod dx);
              end;
              y := y + dy - (y mod dy);
            end;
          end;
        end;
      3: { PCRL }
        begin
          if (dx <= 0) or (dy <= 0) then Refuse('progression step');
          y := ty0;
          while y < ty1 do begin
            x := tx0;
            while x < tx1 do begin
              for c := cs0 to ce - 1 do begin
                nres := comps[c].nres;
                for r := rs to Min64(re, nres) - 1 do begin
                  Step;
                  pr := PrecAt(c, r, x, y);
                  if pr < 0 then Continue;
                  if not Layers(c, r, pr) then Exit;
                end;
              end;
              x := x + dx - (x mod dx);
            end;
            y := y + dy - (y mod dy);
          end;
        end;
      4: { CPRL }
        for c := cs0 to ce - 1 do begin
          MinStep(c, c + 1, ddx, ddy);
          if (ddx <= 0) or (ddy <= 0) then Refuse('progression step');
          nres := comps[c].nres;
          y := ty0;
          while y < ty1 do begin
            x := tx0;
            while x < tx1 do begin
              for r := rs to Min64(re, nres) - 1 do begin
                Step;
                pr := PrecAt(c, r, x, y);
                if pr < 0 then Continue;
                if not Layers(c, r, pr) then Exit;
              end;
              x := x + ddx - (x mod ddx);
            end;
            y := y + ddy - (y mod ddy);
          end;
        end;
    end;
  end;
end;

{ ------------------------------------------------------------------ precincts and tag trees }
function TJ2k.NewNodes(cw, ch: Integer): Integer;
var nplh, nplv: array[0..40] of Integer; lv, i, j, k, t, nn, node, pn, pn0, b: Integer; n: Int64;
begin
  { OpenJPEG's opj_tgt_create: the leaves first, then each level above;
    two trees, inclusion and zero bit-planes }
  nplh[0] := cw; nplv[0] := ch; lv := 0; nn := 0;
  repeat
    n := Int64(nplh[lv]) * nplv[lv];
    nplh[lv + 1] := (nplh[lv] + 1) div 2; nplv[lv + 1] := (nplv[lv] + 1) div 2;
    nn := nn + n; Inc(lv);
  until n <= 1;
  if Int64(nnd) + 2 * Int64(nn) > 8 * Int64(MAXCBS) then Refuse('limits: tag trees');
  Result := nnd;
  if Length(ndParent) < nnd + 2 * nn then begin
    k := 2 * Length(ndParent) + 2 * nn + 64;
    SetLength(ndParent, k); SetLength(ndLow, k); SetLength(ndVal, k); SetLength(eLow, k); SetLength(eVal, k);
    SetLength(eKnown, k);
  end;
  for t := 0 to 1 do begin
    b := nnd + t * nn;
    node := 0; pn := cw * ch; pn0 := pn;
    for i := 0 to lv - 2 do
      for j := 0 to nplv[i] - 1 do begin
        k := nplh[i];
        while True do begin
          Dec(k);
          if k < 0 then Break;
          ndParent[b + node] := b + pn; Inc(node);
          Dec(k);
          if k >= 0 then begin ndParent[b + node] := b + pn; Inc(node); end;
          Inc(pn);
        end;
        if (j and 1 <> 0) or (j = nplv[i] - 1) then pn0 := pn
        else begin pn := pn0; pn0 := pn0 + nplh[i]; end;
      end;
    if node <> nn - 1 then Refuse('internal: tag tree');
    ndParent[b + node] := -1;
    for i := 0 to nn - 1 do begin ndLow[b + i] := 0; ndVal[b + i] := INF; end;
  end;
  nnd := nnd + 2 * nn;
end;

procedure TJ2k.MakePb(c, r, p: Integer);
var rg: TResG; bg: TBandG; b, i, j, sh, cw, ch, idx, pi, pj: Integer;
  sx, sy, ex, ey, px0, py0, px1, py1, cx0, cy0: Int64;
begin
  rg := ress[comps[c].res0 + r];
  prPb[rg.prBase + p] := npb;
  pi := p mod rg.pw; pj := p div rg.pw;
  if r > 0 then sh := 1 else sh := 0;
  for b := 0 to rg.nb - 1 do begin
    bg := bands[rg.band[b]];
    { the precinct in the band (OpenJPEG's tcd.c: a band of a resolution above
      0 has precincts half as large) }
    sx := ((FloorDivP2(rg.x0, rg.ppx) + pi) shl rg.ppx) shr sh; ex := sx + (Int64(1) shl (rg.ppx - sh));
    sy := ((FloorDivP2(rg.y0, rg.ppy) + pj) shl rg.ppy) shr sh; ey := sy + (Int64(1) shl (rg.ppy - sh));
    px0 := Max64(bg.x0, sx); px1 := Min64(bg.x1, ex); py0 := Max64(bg.y0, sy); py1 := Min64(bg.y1, ey);
    if Length(pbCw) <= npb then begin
      i := 2 * npb + 16;
      SetLength(pbCw, i); SetLength(pbCh, i); SetLength(pbLx, i); SetLength(pbLy, i); SetLength(pbBand, i);
      SetLength(pbNode, i); SetLength(pbNn, i);
    end;
    pbBand[npb] := rg.band[b];
    if (px0 >= px1) or (py0 >= py1) or (bg.ncbx = 0) then begin
      cw := 0; ch := 0; pbLx[npb] := 0; pbLy[npb] := 0;
    end else begin
      cx0 := FloorDivP2(px0, bg.cbw); cy0 := FloorDivP2(py0, bg.cbh);
      if (CeilDivP2(px1, bg.cbw) - cx0 > 1 shl 16) or (CeilDivP2(py1, bg.cbh) - cy0 > 1 shl 16) then
        Refuse('precinct geometry');
      cw := CeilDivP2(px1, bg.cbw) - cx0; ch := CeilDivP2(py1, bg.cbh) - cy0;
      if (cx0 - bg.gx0 < 0) or (cy0 - bg.gy0 < 0) or (cx0 - bg.gx0 + cw > bg.ncbx) or
         (cy0 - bg.gy0 + ch > bg.ncby) then Refuse('precinct geometry');
      pbLx[npb] := cx0 - bg.gx0; pbLy[npb] := cy0 - bg.gy0;
    end;
    pbCw[npb] := cw; pbCh[npb] := ch; pbNode[npb] := -1; pbNn[npb] := 0;
    if Int64(cw) * ch > 0 then begin
      pbNode[npb] := NewNodes(cw, ch);
      pbNn[npb] := (nnd - pbNode[npb]) div 2;
      for j := 0 to ch - 1 do
        for i := 0 to cw - 1 do begin
          idx := bg.base + (pbLy[npb] + j) * bg.ncbx + pbLx[npb] + i;
          cbPb[idx] := npb; cbLeaf[idx] := j * cw + i;
        end;
    end;
    Inc(npb);
  end;
end;

function TJ2k.PbOf(c, r, p: Integer): Integer;
var idx: Integer;
begin
  idx := ress[comps[c].res0 + r].prBase + p;
  if prPb[idx] < 0 then MakePb(c, r, p);
  Result := prPb[idx];
end;

procedure TJ2k.LogNode(nd: Integer);
begin
  if nlg >= Length(lgNode) then begin
    SetLength(lgNode, 2 * nlg + 64); SetLength(lgLow, 2 * nlg + 64); SetLength(lgVal, 2 * nlg + 64);
  end;
  lgNode[nlg] := nd; lgLow[nlg] := ndLow[nd]; lgVal[nlg] := ndVal[nd]; Inc(nlg);
end;

procedure TJ2k.Undo(n: Integer);
begin
  while nlg > n do begin
    Dec(nlg);
    ndLow[lgNode[nlg]] := lgLow[nlg]; ndVal[lgNode[nlg]] := lgVal[nlg];
  end;
end;

{ ------------------------------------------------------------------ packet header bits }
{ OpenJPEG's bio: after a byte FF the next one has 7 bits }
function TJ2k.BitIn: Integer;
begin
  if brCt = 0 then begin
    brBuf := (brBuf shl 8) and $FFFF;
    if brBuf = $FF00 then brCt := 7 else brCt := 8;
    if brP < brE then begin brBuf := brBuf or brD[brP]; Inc(brP); end
    else begin brBad := True; brCt := 0; Exit(0); end;
  end;
  Dec(brCt);
  Result := (brBuf shr brCt) and 1;
end;

function TJ2k.BitsIn(n: Integer): QWord;
var i: Integer;
begin
  Result := 0;
  for i := 1 to n do Result := (Result shl 1) or QWord(BitIn);
end;

{ opj_tgt_decode, each change logged so that a packet that does not fit is undone }
function TJ2k.TTDecode(base, leaf, thr: Integer): Boolean;
var stk: array[0..63] of Integer; sp, nd, low: Integer;
begin
  sp := 0; nd := base + leaf;
  while ndParent[nd] >= 0 do begin
    if sp > High(stk) then Refuse('tag tree depth');
    stk[sp] := nd; Inc(sp); nd := ndParent[nd];
  end;
  low := 0;
  while True do begin
    if low > ndLow[nd] then begin LogNode(nd); ndLow[nd] := low; end else low := ndLow[nd];
    while (low < thr) and (low < ndVal[nd]) do begin
      if BitIn <> 0 then begin LogNode(nd); ndVal[nd] := low; end
      else Inc(low);
      if brBad then Exit(False);
    end;
    if ndLow[nd] <> low then begin LogNode(nd); ndLow[nd] := low; end;
    if sp = 0 then Break;
    Dec(sp); nd := stk[sp];
  end;
  Result := ndVal[base + leaf] < thr;
end;

{ a new segment: how many passes it takes (OpenJPEG's opj_t2_init_seg) }
procedure TJ2k.NextSeg(sty: Integer; var nseg, have, mx: Integer);
begin
  if sty and 4 <> 0 then mx := 1
  else if sty and 1 <> 0 then begin
    if nseg = 0 then mx := 10 else if (mx = 1) or (mx = 10) then mx := 2 else mx := 1;
  end else mx := 109;
  have := 0; Inc(nseg);
end;

{ the passes of the pieces np new passes of cb make, into tNps[k0..], the
  code-block left as it is; their count }
function TJ2k.Pieces(cb, np, k0: Integer): Integer;
var have, mx, n, sty, take: Integer;
begin
  sty := comps[bands[cbBand[cb]].comp].sty;
  have := cbSegHave[cb]; mx := cbSegMax[cb]; n := cbNseg[cb]; Result := 0;
  while np > 0 do begin
    if (n = 0) or (have = mx) then NextSeg(sty, n, have, mx);
    take := mx - have; if take > np then take := np;
    if k0 + Result >= Length(tNps) then SetLength(tNps, 2 * Length(tNps) + 256);
    tNps[k0 + Result] := take; Inc(Result);
    have := have + take; np := np - take;
  end;
end;

{ the pieces of np new passes of cb added to it; with useLens their lengths
  from tLens[l0..] and their places from pos }
procedure TJ2k.Derive(cb, np: Integer; pos: Int64; l0: Integer; useLens: Boolean);
var take, sty, k, mx, have, n: Integer;
begin
  sty := comps[bands[cbBand[cb]].comp].sty;
  k := 0;
  while np > 0 do begin
    if (cbNseg[cb] = 0) or (cbSegHave[cb] = cbSegMax[cb]) then begin
      n := cbNseg[cb]; have := cbSegHave[cb]; mx := cbSegMax[cb];
      NextSeg(sty, n, have, mx);
      cbNseg[cb] := n; cbSegHave[cb] := have; cbSegMax[cb] := mx;
    end;
    take := cbSegMax[cb] - cbSegHave[cb];
    if take > np then take := np;
    if npc >= Length(pcSeg) then begin
      n := 2 * npc + 64;
      SetLength(pcSeg, n); SetLength(pcNp, n); SetLength(pcNext, n); SetLength(pcLen, n); SetLength(pcPos, n);
    end;
    pcSeg[npc] := cbNseg[cb] - 1; pcNp[npc] := take; pcNext[npc] := -1;
    if useLens then begin pcLen[npc] := tLens[l0 + k]; pcPos[npc] := pos; pos := pos + tLens[l0 + k]; end
    else begin pcLen[npc] := 0; pcPos[npc] := 0; end;
    if cbTail[cb] >= 0 then pcNext[cbTail[cb]] := npc else cbHead[cb] := npc;
    cbTail[cb] := npc;
    Inc(npc); Inc(k);
    cbSegHave[cb] := cbSegHave[cb] + take; np := np - take;
    cbPasses[cb] := cbPasses[cb] + take;
  end;
end;

procedure TJ2k.AddIe(cb, flags, np, lbInc: Integer);
var n: Integer;
begin
  if nie >= MAXENTRIES then Refuse('limits: packet entries');
  if nie >= Length(ieCb) then begin
    n := 2 * nie + 64;
    SetLength(ieCb, n); SetLength(ieFlags, n); SetLength(ieNp, n); SetLength(ieInc, n); SetLength(iePc0, n);
    SetLength(iePcN, n);
  end;
  ieCb[nie] := cb; ieFlags[nie] := flags; ieNp[nie] := np; ieInc[nie] := lbInc; iePc0[nie] := npc; iePcN[nie] := 0;
  Inc(nie);
end;

{ the passes' prediction: those left to code, at least 1 }
function PassPred(j: TJ2k; cb: Integer): Int64;
begin
  Result := Max64(1, 3 * Int64(j.bands[j.cbBand[cb]].mb - j.cbZbp[cb]) - 2 - j.cbPasses[cb]);
end;

{ ------------------------------------------------------------------ analysis: one packet }
function TJ2k.TryPacket(c, r, p, l: Integer; tpEnd: Int64): Boolean;
var pos, hstart, body, tot: Int64; sop, eph, present, b, i, j, k, n, pb, cb, cw, ch, lg0, np, lbInc, lb, nt, nl,
  nsop, pred: Integer; bg: TBandG;
  procedure Room(m: Integer);
  var q: Integer;
  begin
    if m <= Length(tCb) then Exit;
    q := 2 * m + 64;
    SetLength(tCb, q); SetLength(tIncl, q); SetLength(tFirst, q); SetLength(tZbp, q); SetLength(tNp, q);
    SetLength(tInc, q); SetLength(tL0, q); SetLength(tLn, q);
  end;
begin
  Result := False;
  pos := curPos; lg0 := nlg;
  sop := 0; eph := 0; nsop := 0;
  if (par.g.scod and 2 <> 0) and (pos + 6 <= tpEnd) and (cs[pos] = $FF) and (cs[pos + 1] = $91) and
     (cs[pos + 2] = 0) and (cs[pos + 3] = 4) then begin
    sop := 1; nsop := Be16(cs, pos + 4); pos := pos + 6;
  end;
  if hdrPacked then begin brD := pkd; brP := pkdPos; brE := pkdLen; end
  else begin brD := cs; brP := pos; brE := tpEnd; end;
  hstart := brP; brBuf := 0; brCt := 0; brBad := False;
  present := BitIn;
  if brBad then Exit;
  nt := 0; nl := 0;
  if present <> 0 then
    for b := 0 to ress[comps[c].res0 + r].nb - 1 do begin
      pb := PbOf(c, r, p) + b;
      cw := pbCw[pb]; ch := pbCh[pb];
      if cw * ch = 0 then Continue;
      bg := bands[pbBand[pb]];
      Room(nt + cw * ch);
      for j := 0 to ch - 1 do
        for i := 0 to cw - 1 do begin
          cb := bg.base + (pbLy[pb] + j) * bg.ncbx + pbLx[pb] + i;
          tCb[nt] := cb; tNp[nt] := 0; tInc[nt] := 0; tFirst[nt] := 0; tL0[nt] := nl; tLn[nt] := 0; tZbp[nt] := 0;
          if cbFirst[cb] < 0 then begin
            tIncl[nt] := Ord(TTDecode(pbNode[pb], j * cw + i, l + 1));
            tFirst[nt] := tIncl[nt];
          end else tIncl[nt] := BitIn;
          if brBad then begin Undo(lg0); Exit; end;
          if tIncl[nt] <> 0 then begin
            if tFirst[nt] <> 0 then begin
              if not TTDecode(pbNode[pb] + pbNn[pb], j * cw + i, ZBPLIMIT) then begin Undo(lg0); Exit; end;
              tZbp[nt] := ndVal[pbNode[pb] + pbNn[pb] + j * cw + i];
              lb := 3;
            end else lb := cbLb[cb];
            { the number of new passes }
            if BitIn = 0 then np := 1
            else if BitIn = 0 then np := 2
            else begin
              np := BitsIn(2);
              if np <> 3 then np := np + 3
              else begin
                np := BitsIn(5);
                if np <> 31 then np := np + 6 else np := BitsIn(7) + 37;
              end;
            end;
            lbInc := 0;
            while BitIn = 1 do begin
              Inc(lbInc);
              if (lbInc > 32) or brBad then begin Undo(lg0); Exit; end;
            end;
            lb := lb + lbInc;
            if brBad or (lb > 32) or (cbPasses[cb] + np > 4 * MAXPASSES) then begin Undo(lg0); Exit; end;
            tNp[nt] := np; tInc[nt] := lbInc;
            n := Pieces(cb, np, 0);
            if Length(tLens) < nl + n then SetLength(tLens, 2 * (nl + n) + 256);
            for k := 0 to n - 1 do begin
              tLens[nl + k] := Int64(BitsIn(lb + Flog2(tNps[k])));
              if tLens[nl + k] > tpEnd then begin Undo(lg0); Exit; end;
            end;
            if brBad then begin Undo(lg0); Exit; end;
            tLn[nt] := n; nl := nl + n;
          end;
          Inc(nt);
        end;
    end;
  { the header ends on a byte: one after a byte FF is stuffed }
  if brBuf and $FF = $FF then begin
    if brP >= brE then begin Undo(lg0); Exit; end;
    Inc(brP);
  end;
  brCt := 0;
  if (par.g.scod and 4 <> 0) and (brP + 2 <= brE) and (brD[brP] = $FF) and (brD[brP + 1] = $92) then begin
    eph := 1; brP := brP + 2;
  end;
  if hdrPacked then body := pos else body := brP;
  tot := 0;
  for i := 0 to nl - 1 do tot := tot + tLens[i];
  if body + tot > tpEnd then begin Undo(lg0); Exit; end;
  { the packet is whole: kept, and its side information written }
  if npk >= Length(pkC) then begin
    n := 2 * npk + 64;
    SetLength(pkC, n); SetLength(pkR, n); SetLength(pkP, n); SetLength(pkL, n); SetLength(pkFlags, n);
    SetLength(pkNsop, n); SetLength(pkIe0, n); SetLength(pkIeN, n); SetLength(pkHdrPos, n); SetLength(pkHdrLen, n);
    SetLength(pkStart, n); SetLength(pkEnd, n);
  end;
  pkC[npk] := c; pkR[npk] := r; pkP[npk] := p; pkL[npk] := l;
  pkFlags[npk] := present or (sop shl 1) or (eph shl 2); pkNsop[npk] := nsop;
  pkHdrPos[npk] := hstart; pkHdrLen[npk] := brP - hstart - 2 * eph;
  pkStart[npk] := curPos; pkEnd[npk] := body + tot;
  pkIe0[npk] := nie;
  sw[SH_T2].Put(pkFlags[npk]);
  pred := (nsopLast + 1) and $FFFF;
  if sop <> 0 then begin sw[SH_T2].S(nsop - pred); nsopLast := nsop; end else nsopLast := pred;
  for i := 0 to nt - 1 do begin
    cb := tCb[i];
    AddIe(cb, tIncl[i] or (Ord(cbFirst[cb] >= 0) shl 1), tNp[i], tInc[i]);
    sw[SH_T2].Put(tIncl[i]);
    if tIncl[i] = 0 then Continue;
    if tFirst[i] <> 0 then begin
      b := cbBand[cb];
      sw[SH_ZBP].S(tZbp[i] - bandZ[b]); bandZ[b] := tZbp[i];
      cbFirst[cb] := l; cbZbp[cb] := tZbp[i]; cbLb[cb] := 3;
    end;
    sw[SH_T2].S(PassPred(Self, cb) - tNp[i]);
    cbLb[cb] := cbLb[cb] + tInc[i];
    Derive(cb, tNp[i], body, tL0[i], True);
    iePcN[nie - 1] := npc - iePc0[nie - 1];
    for k := tL0[i] to tL0[i] + tLn[i] - 1 do body := body + tLens[k];
  end;
  pkIeN[npk] := nie - pkIe0[npk];
  Inc(npk);
  nlg := 0;
  if hdrPacked then pkdPos := brP;
  curPos := body;
  Result := True;
end;

function TJ2k.EmitAnalyse(c, r, p, l: Integer): Boolean;
begin
  while curTp <= High(tileTps) do begin
    if TryPacket(c, r, p, l, tps[tileTps[curTp]].dend) then begin
      Inc(tps[tileTps[curTp]].npk);
      Exit(True);
    end;
    { the rest of this tile-part is not a packet: on to the next one }
    tps[tileTps[curTp]].gap := Copy(cs, curPos, tps[tileTps[curTp]].dend - curPos);
    Inc(curTp);
    if curTp <= High(tileTps) then curPos := tps[tileTps[curTp]].dstart;
  end;
  Result := False;
end;

{ ------------------------------------------------------------------ rebuild: one packet's side information }
function TJ2k.EmitRebuild(c, r, p, l: Integer): Boolean;
var flags, b, i, j, pb, cw, ch, cb, ex, pred, bb: Integer; bg: TBandG; zp, np: Int64;
begin
  if npk >= npkTarget then Exit(False);
  if npk >= Length(pkC) then begin
    i := 2 * npk + 64;
    SetLength(pkC, i); SetLength(pkR, i); SetLength(pkP, i); SetLength(pkL, i); SetLength(pkFlags, i);
    SetLength(pkNsop, i); SetLength(pkIe0, i); SetLength(pkIeN, i);
  end;
  flags := sr[SH_T2].Get;
  if flags > 7 then Refuse('bad packet flags');
  pkC[npk] := c; pkR[npk] := r; pkP[npk] := p; pkL[npk] := l; pkFlags[npk] := flags;
  pred := (nsopLast + 1) and $FFFF;
  if flags and 2 <> 0 then begin
    pkNsop[npk] := pred + sr[SH_T2].SI(-pred, 65535 - pred); nsopLast := pkNsop[npk];
  end else begin pkNsop[npk] := pred; nsopLast := pred; end;
  pkIe0[npk] := nie;
  if flags and 1 <> 0 then
    for b := 0 to ress[comps[c].res0 + r].nb - 1 do begin
      pb := PbOf(c, r, p) + b;
      cw := pbCw[pb]; ch := pbCh[pb];
      if cw * ch = 0 then Continue;
      bg := bands[pbBand[pb]];
      for j := 0 to ch - 1 do
        for i := 0 to cw - 1 do begin
          cb := bg.base + (pbLy[pb] + j) * bg.ncbx + pbLx[pb] + i;
          ex := sr[SH_T2].Get;
          if ex > 1 then Refuse('bad inclusion');
          AddIe(cb, ex or (Ord(cbFirst[cb] >= 0) shl 1), 0, 0);
          if ex = 0 then Continue;
          if cbFirst[cb] < 0 then begin
            bb := cbBand[cb];
            zp := bandZ[bb] + sr[SH_ZBP].SI(-ZBPLIMIT, ZBPLIMIT);
            if (zp < 0) or (zp >= ZBPLIMIT) then Refuse('bad zero bit-planes');
            bandZ[bb] := zp;
            cbFirst[cb] := l; cbZbp[cb] := zp;
          end;
          np := PassPred(Self, cb) - sr[SH_T2].SI(-1000, 1000);
          if (np < 1) or (np > 164) or (cbPasses[cb] + np > 4 * MAXPASSES) then Refuse('bad passes');
          ieNp[nie - 1] := np;
          Derive(cb, np, 0, 0, False);
          iePcN[nie - 1] := npc - iePc0[nie - 1];
        end;
    end;
  pkIeN[npk] := nie - pkIe0[npk];
  Inc(npk);
  Result := True;
end;

{ ------------------------------------------------------------------ tag tree values }
{ The encoder's tag trees: each node the least of its leaves, a leaf the
  layer a code-block is first in and its zero bit-planes (never in: no
  value); analysis: where the decoder learnt otherwise, written (SH_TREE);
  rebuild: read. }
procedure TJ2k.Trees;
var pb, t, base, nn, i, j, cb, k, nov: Integer; v: Int64; bg: TBandG;
  ovPb, ovT, ovN, ovV: array of LongInt;
begin
  nov := 0; ovPb := nil; ovT := nil; ovN := nil; ovV := nil;
  for pb := 0 to npb - 1 do begin
    nn := pbNn[pb];
    if nn = 0 then Continue;
    bg := bands[pbBand[pb]];
    for t := 0 to 1 do begin
      base := pbNode[pb] + t * nn;
      for i := 0 to nn - 1 do eVal[base + i] := INF;
      for j := 0 to pbCh[pb] - 1 do
        for i := 0 to pbCw[pb] - 1 do begin
          cb := bg.base + (pbLy[pb] + j) * bg.ncbx + pbLx[pb] + i;
          if cbFirst[cb] >= 0 then
            if t = 0 then eVal[base + j * pbCw[pb] + i] := cbFirst[cb]
            else eVal[base + j * pbCw[pb] + i] := cbZbp[cb];
        end;
      for i := 0 to nn - 1 do begin
        k := ndParent[base + i];
        if (k >= 0) and (eVal[base + i] < eVal[k]) then eVal[k] := eVal[base + i];
      end;
      if an then
        for i := 0 to nn - 1 do
          if ndVal[base + i] <> eVal[base + i] then begin
            if nov >= Length(ovPb) then begin
              k := 2 * nov + 16;
              SetLength(ovPb, k); SetLength(ovT, k); SetLength(ovN, k); SetLength(ovV, k);
            end;
            ovPb[nov] := pb; ovT[nov] := t; ovN[nov] := i; ovV[nov] := ndVal[base + i]; Inc(nov);
          end;
    end;
  end;
  if an then begin
    sw[SH_TREE].V(nov);
    for i := 0 to nov - 1 do begin
      sw[SH_TREE].V(ovPb[i]); sw[SH_TREE].Put(ovT[i]); sw[SH_TREE].V(ovN[i]);
      if ovV[i] = INF then sw[SH_TREE].V(0) else sw[SH_TREE].V(QWord(ovV[i]) + 1);
      eVal[pbNode[ovPb[i]] + ovT[i] * pbNn[ovPb[i]] + ovN[i]] := ovV[i];
    end;
    st.treeOverrides := st.treeOverrides + nov;
  end else begin
    nov := sr[SH_TREE].VI(MAXENTRIES);
    if (nov > 0) and (npb = 0) then Refuse('bad tree');
    for i := 0 to nov - 1 do begin
      pb := sr[SH_TREE].VI(npb - 1);
      t := sr[SH_TREE].Get;
      if (t > 1) or (pbNn[pb] = 0) then Refuse('bad tree');
      k := sr[SH_TREE].VI(pbNn[pb] - 1);
      v := sr[SH_TREE].VI(1 shl 24);
      if v = 0 then eVal[pbNode[pb] + t * pbNn[pb] + k] := INF
      else eVal[pbNode[pb] + t * pbNn[pb] + k] := v - 1;
    end;
  end;
  for i := 0 to nnd - 1 do begin eLow[i] := 0; eKnown[i] := False; end;
end;

{ ------------------------------------------------------------------ tier-1, one code-block }
procedure EnsureB(var d: TBytes; n: Int64);
begin
  if Length(d) < n then SetLength(d, n + n div 4 + 64);
end;

procedure ResetCtx(var x: array of Byte);
var i: Integer;
begin
  for i := 0 to 37 do x[i] := 0;
  x[18] := 46; x[17] := 3; x[0] := 4;
end;

procedure TJ2k.DoCb(cb: Integer);
var bg: TBandG; w, h, sty, npass, nseg, k, pc, i, pad, rule, br, p0, p1, npe, sp, reset: Integer;
  x0, y0, x1, y1, tot, nsym, a, n, used, nf, ne, kk, on, L, Lo, Lt, prev, cap, segStart, d, dd,
  bitsN, nb, gx, gy: Int64;
  ctx, ctx0: array[0..37] of Byte;
  outv: array[0..2] of Int64;
  O: TBytes; okF, okE, isRaw: Boolean; segOut: TBW; w8, b: Integer; ok: Boolean;

  function RefBit(const R_: TBytes; nr: Int64; i_: Int64): Integer;
  var by: Int64;
  begin
    by := kk + i_ div 8;
    if by < nr then Result := (R_[by] shr (7 - i_ mod 8)) and 1 else Result := 0;
  end;

  { Kakadu: the shortest prefix near the bytes committed at the end of the
    segment's pass sp that decodes the passes so far; -1 }
  function BndShortest(sp_: Integer): Int64;
  var L_, k_: Int64;
  begin
    Result := -1;
    k_ := kpv[3 * (sp_ - 1)];
    L_ := Max64(0, k_ - 3);
    while L_ <= Min64(k_ + 8, segOut.n) do begin
      if pjaj2k_mq_valid(At(segOut.d, 0), L_, @ctx0[0], At(symb, a), pev[sp_ - 1], @pev[0], npe, reset) <> 0 then
        Exit(L_);
      Inc(L_);
    end;
  end;

  { Adobe: what the decoder has read when it has decoded the passes so far }
  function BndReach(sp_: Integer): Int64;
  begin
    Result := pjaj2k_mq_reach(At(segOut.d, 0), segOut.n, @ctx0[0], At(symb, a), pev[sp_ - 1], @pev[0], npe, reset);
  end;

  function MinPfx(const X: TBytes; nx: Int64): Int64;
  begin
    Result := pjaj2k_mq_minprefix(At(X, 0), nx, @ctx0[0], At(symb, a), n, @pev[0], npe, reset, MINWINDOW);
  end;

begin
  bg := bands[cbBand[cb]];
  gx := (cb - bg.base) mod bg.ncbx; gy := (cb - bg.base) div bg.ncbx;
  x0 := Max64(bg.x0, (bg.gx0 + gx) shl bg.cbw); x1 := Min64(bg.x1, (bg.gx0 + gx + 1) shl bg.cbw);
  y0 := Max64(bg.y0, (bg.gy0 + gy) shl bg.cbh); y1 := Min64(bg.y1, (bg.gy0 + gy + 1) shl bg.cbh);
  w := x1 - x0; h := y1 - y0;
  sty := comps[bg.comp].sty; reset := Ord(sty and 2 <> 0);
  npass := cbPasses[cb]; nseg := cbNseg[cb];
  if Length(seglen) < nseg + 1 then begin
    SetLength(seglen, nseg + 16); SetLength(segpass, nseg + 16); SetLength(segp0, nseg + 16);
  end;
  for k := 0 to nseg - 1 do begin seglen[k] := 0; segpass[k] := 0; end;
  { the segments: their passes, and (analysis) their bytes }
  tot := 0; pc := cbHead[cb];
  while pc >= 0 do begin
    segpass[pcSeg[pc]] := segpass[pcSeg[pc]] + pcNp[pc];
    if an then begin
      if pcLen[pc] > High(LongInt) - seglen[pcSeg[pc]] then Refuse('limits: segment');
      seglen[pcSeg[pc]] := seglen[pcSeg[pc]] + pcLen[pc]; tot := tot + pcLen[pc];
    end;
    pc := pcNext[pc];
  end;
  segp0[0] := 0;
  for k := 1 to nseg - 1 do segp0[k] := segp0[k - 1] + segpass[k - 1];
  if an then begin
    EnsureB(segdata, tot + 8);
    a := 0; pc := cbHead[cb];
    while pc >= 0 do begin
      if pcLen[pc] > 0 then Move(cs[pcPos[pc]], segdata[a], pcLen[pc]);
      a := a + pcLen[pc]; pc := pcNext[pc];
    end;
  end;
  cap := Int64(npass) * (2 * Int64(w) * h + 3 * Int64(w) * ((h + 3) div 4) + 8) + 64;
  if Length(stb) < 2 * (w + 2) * (h + 2) then SetLength(stb, 2 * (w + 2) * (h + 2));
  if Length(passend) < npass + 1 then SetLength(passend, npass + 16);
  { decode (analysis) or replay (rebuild) }
  if an then begin
    ok := (npass <= MAXPASSES) and (w <= 1024) and (h <= 1024) and (w * h <= 4096);
    nsym := -1;
    if ok then begin
      EnsureB(symb, cap);
      nsym := pjaj2k_t1_decode(w, h, bg.orient, sty, npass, At(segdata, 0), @seglen[0], @segpass[0], nseg,
        At(symb, 0), cap, @passend[0], @stb[0]);
      ok := nsym >= 0;
    end;
    sw[SH_T1R].Put(Ord(not ok));
    if not ok then begin
      Inc(st.cbRaw);
      pc := cbHead[cb];
      while pc >= 0 do begin sw[SH_T1X].V(pcLen[pc]); pc := pcNext[pc]; end;
      sw[SH_T1X].PutN(segdata, 0, tot);
      Exit;
    end;
    st.decisions := st.decisions + nsym;
    { the decisions' bits }
    Grow(sw[SH_DEC].d, (dbits + nsym) div 8 + 8);
    a := 0;
    while a < nsym do begin
      if symb[a] and 1 <> 0 then
        sw[SH_DEC].d[dbits shr 3] := sw[SH_DEC].d[dbits shr 3] or (128 shr (dbits and 7));
      Inc(dbits); Inc(a);
    end;
    sw[SH_DEC].n := (dbits + 7) div 8;
  end else begin
    cbDOff[cb] := cbData.n;
    if sr[SH_T1R].Get <> 0 then begin
      tot := 0; pc := cbHead[cb];
      while pc >= 0 do begin pcLen[pc] := sr[SH_T1X].VI(High(LongInt)); tot := tot + pcLen[pc]; pc := pcNext[pc]; end;
      sr[SH_T1X].GetN(cbData, tot);
      Exit;
    end;
    if (npass > MAXPASSES) or (w > 1024) or (h > 1024) or (w * h > 4096) then Refuse('bad passes');
    EnsureB(symb, cap);
    nsym := pjaj2k_t1_replay(w, h, bg.orient, sty, npass, At(sr[SH_DEC].d, 0), dbits, 8 * Int64(sr[SH_DEC].e),
      used, At(symb, 0), cap, @passend[0], @stb[0]);
    if nsym < 0 then Refuse('decisions');
    dbits := dbits + used;
  end;
  Inc(st.cbs);
  { each segment's bytes }
  ResetCtx(ctx);
  segStart := 0;
  pc := cbHead[cb];
  for k := 0 to nseg - 1 do begin
    p0 := segp0[k]; p1 := p0 + segpass[k];
    if p0 = 0 then a := 0 else a := passend[p0 - 1];
    n := passend[p1 - 1] - a;
    Inc(st.segs);
    if an then begin on := seglen[k]; O := Copy(segdata, segStart, on); end else begin on := 0; O := nil; end;
    segOut := Default(TBW);
    npe := 0;
    isRaw := (sty and 1 <> 0) and (p0 >= 10) and ((p0 - 1) mod 3 < 2);
    if isRaw then begin
      { a raw (BYPASS) segment }
      Inc(st.rawSegs);
      EnsureB(fb, n div 7 + 16);
      if an then begin
        rule := R_RAWB;
        for pad := 0 to 2 do begin
          nb := pjaj2k_raw_pack(At(symb, a), n, pad, At(fb, 0), Length(fb));
          if (nb = on) and ((on = 0) or CompareMem(@fb[0], @O[0], on)) then begin rule := R_PAD0 + pad; Break; end;
        end;
        sw[SH_T1R].Put(rule);
        if rule = R_RAWB then begin sw[SH_T1X].V(on); sw[SH_T1X].PutN(O, 0, on); end;
        segOut.PutN(O, 0, on);
      end else begin
        rule := sr[SH_T1R].Get;
        if (rule >= R_PAD0) and (rule <= R_PAD2) then begin
          nb := pjaj2k_raw_pack(At(symb, a), n, rule - R_PAD0, At(fb, 0), Length(fb));
          if nb < 0 then Refuse('internal: raw pack');
          segOut.PutN(fb, 0, nb);
        end else if rule = R_RAWB then sr[SH_T1X].GetN(segOut, sr[SH_T1X].VI(High(LongInt)))
        else Refuse('bad rule');
      end;
      Inc(st.rule[rule]);
    end else begin
      { an MQ segment }
      npe := p1 - 1 - p0;
      if Length(pev) < npe + 1 then begin SetLength(pev, npe + 16); SetLength(kpv, 3 * npe + 48); end;
      for i := 0 to npe - 1 do pev[i] := passend[p0 + i] - a;
      Move(ctx[0], ctx0[0], 38);
      EnsureB(fb, 3 * n + 64); EnsureB(eb, 3 * n + 64);
      if pjaj2k_mq_encode(At(symb, a), n, @pev[0], npe, reset, @ctx[0], At(fb, 0), At(eb, 0),
        Min64(Length(fb), Length(eb)), @outv[0], @kpv[0]) <> 0 then Refuse('internal: MQ encode');
      if reset <> 0 then ResetCtx(ctx);
      nf := outv[0]; ne := outv[1]; kk := outv[2];
      if an then begin
        okF := (on <= nf) and ((on = 0) or CompareMem(@O[0], @fb[0], on));
        okE := (on <= ne) and ((on = 0) or CompareMem(@O[0], @eb[0], on));
        if on = 0 then rule := R_EMPTY
        else if okF and (on = nf) then rule := R_FLUSH
        else if okE and (on = ne) then rule := R_ERTERM
        else if okF and (nf - on <= MINWINDOW) and (MinPfx(fb, nf) = on) then rule := R_MINF
        else if okE and (ne - on <= MINWINDOW) and (MinPfx(eb, ne) = on) then rule := R_MINE
        else if (kk <= on) and (kk <= nf) and (on - kk <= TAILMAX) and ((kk = 0) or CompareMem(@O[0], @fb[0], kk)) then
          rule := R_TAILF
        else rule := R_RAW;
        if rule = R_TAILF then begin
          { the bits after the committed bytes: how far they go along with
            FLUSH's or ERTERM's, the next one the other way, the rest as they are }
          bitsN := 8 * (on - kk);
          d := 0;
          while (d < bitsN) and (((O[kk + d div 8] shr (7 - d mod 8)) and 1) = RefBit(fb, nf, d)) do Inc(d);
          dd := 0;
          while (dd < bitsN) and (((O[kk + dd div 8] shr (7 - dd mod 8)) and 1) = RefBit(eb, ne, dd)) do Inc(dd);
          if dd > d then begin rule := R_TAILE; d := dd; end;
          sw[SH_T1R].Put(rule);
          sw[SH_T1X].V(on - kk); sw[SH_T1X].V(d);
          w8 := 0; b := 0;
          i := d + 1;
          while i < bitsN do begin
            w8 := (w8 shl 1) or ((O[kk + i div 8] shr (7 - i mod 8)) and 1); Inc(b);
            if b = 8 then begin sw[SH_T1X].Put(w8); w8 := 0; b := 0; end;
            Inc(i);
          end;
          if b > 0 then sw[SH_T1X].Put((w8 shl (8 - b)) and $FF);
          Inc(st.tails);
          if bitsN > d then st.tailBits := st.tailBits + bitsN - d - 1;
        end else begin
          sw[SH_T1R].Put(rule);
          if rule = R_RAW then begin sw[SH_T1X].V(on); sw[SH_T1X].PutN(O, 0, on); end;
        end;
        segOut.PutN(O, 0, on);
      end else begin
        rule := sr[SH_T1R].Get;
        case rule of
          R_EMPTY: ;
          R_FLUSH: segOut.PutN(fb, 0, nf);
          R_ERTERM: segOut.PutN(eb, 0, ne);
          R_MINF: segOut.PutN(fb, 0, MinPfx(fb, nf));
          R_MINE: segOut.PutN(eb, 0, MinPfx(eb, ne));
          R_TAILF, R_TAILE: begin
              if kk > nf then Refuse('bad tail');
              on := kk + sr[SH_T1X].VI(TAILMAX);
              bitsN := 8 * (on - kk);
              d := sr[SH_T1X].VI(bitsN);
              segOut.PutN(fb, 0, kk);
              Grow(segOut.d, on);
              segOut.n := on;
              { the reference's bytes (zeros past its end), its bit d the other
                way, the bits after it as written }
              for i := kk to on - 1 do
                if rule = R_TAILF then begin if i < nf then segOut.d[i] := fb[i] else segOut.d[i] := 0; end
                else if i < ne then segOut.d[i] := eb[i] else segOut.d[i] := 0;
              if d < bitsN then begin
                segOut.d[kk + d div 8] := segOut.d[kk + d div 8] xor (128 shr (d mod 8));
                b := 0; w8 := 0;
                i := d + 1;
                while i < bitsN do begin
                  if b = 0 then begin w8 := sr[SH_T1X].Get; b := 8; end;
                  Dec(b);
                  if (w8 shr b) and 1 <> 0 then segOut.d[kk + i div 8] := segOut.d[kk + i div 8] or (128 shr (i mod 8))
                  else segOut.d[kk + i div 8] := segOut.d[kk + i div 8] and not (128 shr (i mod 8));
                  Inc(i);
                end;
              end;
            end;
          R_RAW: sr[SH_T1X].GetN(segOut, sr[SH_T1X].VI(High(LongInt)));
          else Refuse('bad rule');
        end;
      end;
      Inc(st.rule[rule]);
    end;
    { where the layers cut the segment: the pieces before its last }
    prev := 0; sp := 0;
    while (pc >= 0) and (pcSeg[pc] = k) do begin
      sp := sp + pcNp[pc];
      if (pcNext[pc] < 0) or (pcSeg[pcNext[pc]] <> k) then L := segOut.n
      else begin
        if isRaw then begin
          { BYPASS: the bytes that hold the bits so far (a last FF dropped), as
            OpenJPEG's rate allocator has it }
          Lo := pjaj2k_raw_pack(At(symb, a), passend[p0 + sp - 1] - a, 1, At(fb, 0), Length(fb));
          if Lo < 0 then Refuse('internal: raw pack');
        end else begin
          { MQ: OpenJPEG's rate allocator, the bytes committed + 3 (a last FF dropped) }
          kk := kpv[3 * (sp - 1)];
          Lo := Min64(kk + 3, segOut.n);
          if (Lo > 0) and (segOut.d[Lo - 1] = $FF) then Dec(Lo);
        end;
        { the other rules (MQ only) are tried one after the other; the rebuild
          works out only the one it is told }
        if an then begin
          Lt := prev + pcLen[pc];
          if Lo = Lt then br := 0
          else if not isRaw and (BndShortest(sp) = Lt) then br := 1
          else if not isRaw and (BndReach(sp) = Lt) then br := 3
          else br := 2;
          sw[SH_T1R].Put(br);
          if br = 2 then sw[SH_T1X].S(Lt - Lo);
          L := Lt;
        end else begin
          br := sr[SH_T1R].Get;
          if br = 0 then L := Lo
          else if (br = 1) and not isRaw then L := BndShortest(sp)
          else if (br = 3) and not isRaw then L := BndReach(sp)
          else if br = 2 then L := Lo + sr[SH_T1X].SI(-segOut.n - 1, segOut.n + 1)
          else Refuse('bad boundary');
          if (L < prev) or (L > segOut.n) then Refuse('bad boundary');
        end;
        Inc(st.bounds); Inc(st.brule[br]);
      end;
      if an then begin
        if L - prev <> pcLen[pc] then Refuse('internal: piece length');
      end else pcLen[pc] := L - prev;
      prev := L;
      pc := pcNext[pc];
    end;
    if an and ((segOut.n <> on) or ((on > 0) and not CompareMem(@segOut.d[0], @O[0], on))) then
      Refuse('internal: segment');
    if not an then cbData.PutN(segOut.d, 0, segOut.n);
    segStart := segStart + segOut.n;
  end;
end;

{ ------------------------------------------------------------------ packet headers written }
{ OpenJPEG's bio, writing }
procedure TJ2k.BitOut(b: Integer);
begin
  if bwCt = 0 then begin
    bwBuf := (bwBuf shl 8) and $FFFF;
    if bwBuf = $FF00 then bwCt := 7 else bwCt := 8;
    bw.Put(bwBuf shr 8);
  end;
  Dec(bwCt);
  bwBuf := bwBuf or (Cardinal(b) shl bwCt);
end;

procedure TJ2k.BitsOut(v: QWord; n: Integer);
var i: Integer;
begin
  for i := n - 1 downto 0 do BitOut((v shr i) and 1);
end;

{ opj_tgt_encode }
procedure TJ2k.TTEncode(base, leaf, thr: Integer);
var stk: array[0..63] of Integer; sp, nd, low: Integer;
begin
  sp := 0; nd := base + leaf;
  while ndParent[nd] >= 0 do begin stk[sp] := nd; Inc(sp); nd := ndParent[nd]; end;
  low := 0;
  while True do begin
    if low > eLow[nd] then eLow[nd] := low else low := eLow[nd];
    while low < thr do begin
      if low >= eVal[nd] then begin
        if not eKnown[nd] then begin BitOut(1); eKnown[nd] := True; end;
        Break;
      end;
      BitOut(0); Inc(low);
    end;
    eLow[nd] := low;
    if sp = 0 then Break;
    Dec(sp); nd := stk[sp];
  end;
end;

{ the packets again: their headers written (analysis: checked against the
  codestream's), Lblock, and (rebuild) the whole packets }
procedure TJ2k.Pass3;
var k, i, e, cb, pb, np, lbInc, need, lb, q, n: Integer; same: Boolean; hl: Int64;
begin
  for i := 0 to ncb - 1 do begin cbELb[i] := 3; cbCur[i] := cbDOff[i]; end;
  tileOut.n := 0;
  SetLength(tilePk, npk + 1);
  for k := 0 to npk - 1 do begin
    tilePk[k] := tileOut.n;
    if not an and (pkFlags[k] and 2 <> 0) then begin
      tileOut.Put($FF); tileOut.Put($91); tileOut.Put(0); tileOut.Put(4);
      tileOut.Put(pkNsop[k] shr 8); tileOut.Put(pkNsop[k] and $FF);
    end;
    if not hdrPacked then begin
      bw.n := 0; bwBuf := 0; bwCt := 8;
      BitOut(pkFlags[k] and 1);
      for e := pkIe0[k] to pkIe0[k] + pkIeN[k] - 1 do begin
        cb := ieCb[e];
        pb := cbPb[cb];
        if ieFlags[e] and 2 = 0 then TTEncode(pbNode[pb], cbLeaf[cb], pkL[k] + 1)
        else BitOut(ieFlags[e] and 1);
        if ieFlags[e] and 1 = 0 then Continue;
        if ieFlags[e] and 2 = 0 then begin
          TTEncode(pbNode[pb] + pbNn[pb], cbLeaf[cb], ZBPLIMIT); cbELb[cb] := 3;
        end;
        np := ieNp[e];
        if np = 1 then BitOut(0)
        else if np = 2 then BitsOut(2, 2)
        else if np <= 5 then BitsOut($C or (np - 3), 4)
        else if np <= 36 then BitsOut($1E0 or (np - 6), 9)
        else BitsOut($FF80 or (np - 37), 16);
        { Lblock: the least the lengths need, and what the codestream has over it }
        lb := cbELb[cb]; need := 0;
        for q := iePc0[e] to iePc0[e] + iePcN[e] - 1 do begin
          n := Flog2(pcLen[q]) + 1 - (lb + Flog2(pcNp[q]));
          if n > need then need := n;
        end;
        if an then begin
          lbInc := ieInc[e];
          if lbInc < need then Refuse('internal: Lblock');
          sw[SH_LB].V(lbInc - need);
          if lbInc <> need then Inc(st.lbNonMinimal);
        end else lbInc := need + sr[SH_LB].VI(32);
        if lb + lbInc > 40 then Refuse('bad Lblock');
        for q := 1 to lbInc do BitOut(1);
        BitOut(0);
        lb := lb + lbInc; cbELb[cb] := lb;
        for q := iePc0[e] to iePc0[e] + iePcN[e] - 1 do BitsOut(QWord(pcLen[q]), lb + Flog2(pcNp[q]));
      end;
      { the byte under way, and one more after a byte FF (opj_bio_flush) }
      bwBuf := (bwBuf shl 8) and $FFFF;
      if bwBuf = $FF00 then bwCt := 7 else bwCt := 8;
      bw.Put(bwBuf shr 8);
      if bwCt = 7 then begin bwBuf := (bwBuf shl 8) and $FFFF; bwCt := 8; bw.Put(bwBuf shr 8); end;
      if an then begin
        hl := pkHdrLen[k];
        same := (hl = bw.n) and ((hl = 0) or CompareMem(@bw.d[0], @cs[pkHdrPos[k]], hl));
        sw[SH_HDRX].Put(Ord(not same));
        if not same then begin
          Inc(st.hdrExceptions);
          sw[SH_HDRX].V(hl); sw[SH_HDRX].PutN(cs, pkHdrPos[k], hl);
        end;
      end else begin
        if sr[SH_HDRX].Get <> 0 then sr[SH_HDRX].GetN(tileOut, sr[SH_HDRX].VI(High(LongInt)))
        else tileOut.PutN(bw.d, 0, bw.n);
        if pkFlags[k] and 4 <> 0 then begin tileOut.Put($FF); tileOut.Put($92); end;
      end;
    end;
    if not an then
      for e := pkIe0[k] to pkIe0[k] + pkIeN[k] - 1 do begin
        if ieFlags[e] and 1 = 0 then Continue;
        cb := ieCb[e];
        for q := iePc0[e] to iePc0[e] + iePcN[e] - 1 do begin
          if cbCur[cb] + pcLen[q] > cbData.n then Refuse('bad lengths');
          tileOut.PutN(cbData.d, cbCur[cb], pcLen[q]);
          cbCur[cb] := cbCur[cb] + pcLen[q];
        end;
      end;
  end;
  tilePk[npk] := tileOut.n;
end;

{ ------------------------------------------------------------------ PLT and TLM }
{ the packets in a PLT marker segment (whole values only) }
function PltCount(const raw: TBytes): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 5 to High(raw) do if raw[i] and $80 = 0 then Inc(Result);
end;

function PltBytes(z: Byte; const lens: array of Int64; from, cnt: Integer): TBytes;
var w: TBW; i, k: Integer; v: Int64; t: array[0..9] of Byte;
begin
  w := Default(TBW);
  w.Put($FF); w.Put($58); w.Put(0); w.Put(0); w.Put(z);
  for i := from to from + cnt - 1 do begin
    v := lens[i]; k := 0;
    repeat t[k] := v and 127; v := v shr 7; Inc(k); until (v = 0) or (k = 10);
    while k > 0 do begin Dec(k); if k > 0 then w.Put(t[k] or 128) else w.Put(t[k]); end;
  end;
  if w.n - 2 > 65535 then Refuse('PLT too long');
  w.d[2] := (w.n - 2) shr 8; w.d[3] := (w.n - 2) and $FF;
  Result := w.Bytes;
end;

{ the tile-parts a TLM marker segment lists, 0 when it does not parse }
function TlmCount(const raw: TBytes): Integer;
var st, esz: Integer;
begin
  Result := 0;
  if Length(raw) < 6 then Exit;
  st := raw[5];
  if (st shr 4) and 3 = 3 then Exit;
  esz := (st shr 4) and 3 + 2 + 2 * ((st shr 6) and 1);
  if (Length(raw) - 6) mod esz <> 0 then Exit;
  Result := (Length(raw) - 6) div esz;
end;

function TlmBytes(j: TJ2k; z, st: Byte; from, cnt: Integer; const lens: array of Int64): TBytes;
var w: TBW; i, tsz, psz: Integer; v: Int64;
begin
  w := Default(TBW);
  tsz := (st shr 4) and 3; psz := (st shr 6) and 1;
  w.Put($FF); w.Put($55); w.Put(0); w.Put(0); w.Put(z); w.Put(st);
  for i := from to from + cnt - 1 do begin
    if (i < 0) or (i > High(lens)) then Refuse('TLM');
    if tsz = 1 then w.Put(j.tps[i].isot and $FF)
    else if tsz = 2 then begin w.Put(j.tps[i].isot shr 8); w.Put(j.tps[i].isot and $FF); end;
    v := lens[i];
    if psz = 1 then begin
      if v > High(Cardinal) then Refuse('TLM');
      w.Put(v shr 24); w.Put((v shr 16) and $FF); w.Put((v shr 8) and $FF); w.Put(v and $FF);
    end else begin
      if v > 65535 then Refuse('TLM');
      w.Put(v shr 8); w.Put(v and $FF);
    end;
  end;
  if w.n - 2 > 65535 then Refuse('TLM too long');
  w.d[2] := (w.n - 2) shr 8; w.d[3] := (w.n - 2) and $FF;
  Result := w.Bytes;
end;

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

{ ------------------------------------------------------------------ one tile }
procedure TJ2k.Tile(t: Integer);
var i, k, j, q, pi: Integer; w: TBW; v: Int64; b: TBytes;
begin
  tileNo := t;
  { its tile-parts, in the order of the codestream }
  SetLength(tileTps, 0);
  for i := 0 to High(tps) do
    if tps[i].isot = t then begin SetLength(tileTps, Length(tileTps) + 1); tileTps[High(tileTps)] := i; end;
  TileParams;
  Geometry;
  SetLength(bandZ, Length(bands));
  for i := 0 to High(bandZ) do bandZ[i] := 0;
  pkdPos := 0; nsopLast := -1;
  Inc(st.tiles);
  if an then begin
    curTp := 0; curPos := tps[tileTps[0]].dstart;
    for i := 0 to High(tileTps) do begin tps[tileTps[i]].npk := 0; tps[tileTps[i]].gap := nil; end;
    Iterate(@EmitAnalyse);
    { what is left of the tile-parts }
    while curTp <= High(tileTps) do begin
      tps[tileTps[curTp]].gap := Copy(cs, curPos, tps[tileTps[curTp]].dend - curPos);
      Inc(curTp);
      if curTp <= High(tileTps) then curPos := tps[tileTps[curTp]].dstart;
    end;
    sw[SH_LAY].V(npk);
    k := 0;
    for i := 0 to High(tileTps) do
      with tps[tileTps[i]] do begin
        sw[SH_LAY].V(npk); sw[SH_LAY].V(Length(gap)); sw[SH_LAY].PutN(gap, 0, Length(gap));
        pk0 := k; k := k + npk;
        SetLength(plens, npk);
        for j := 0 to npk - 1 do plens[j] := Self.pkEnd[pk0 + j] - Self.pkStart[pk0 + j];
      end;
  end else begin
    npkTarget := sr[SH_LAY].VI(MAXENTRIES);
    k := 0;
    for i := 0 to High(tileTps) do
      with tps[tileTps[i]] do begin
        npk := sr[SH_LAY].VI(npkTarget);
        gap := sr[SH_LAY].Take(sr[SH_LAY].VI(High(LongInt)));
        pk0 := k; k := k + npk;
      end;
    if k <> npkTarget then Refuse('bad layout');
    Iterate(@EmitRebuild);
    if npk <> npkTarget then Refuse('packets missing');
  end;
  st.packets := st.packets + npk;
  if not hdrPacked then Trees;
  cbData.n := 0;
  for i := 0 to ncb - 1 do begin cbDOff[i] := 0; if cbPasses[i] > 0 then DoCb(i); end;
  Pass3;
  if not an then
    { the tile-parts }
    for i := 0 to High(tileTps) do
      with tps[tileTps[i]] do begin
        w := Default(TBW);
        w.Put($FF); w.Put($90); w.Put(0); w.Put(10); w.Put(isot shr 8); w.Put(isot and $FF);
        w.Put(0); w.Put(0); w.Put(0); w.Put(0); w.Put(tpsot); w.Put(tnsot);
        pi := 0;
        SetLength(plens, npk);
        for j := 0 to npk - 1 do plens[j] := tilePk[pk0 + j + 1] - tilePk[pk0 + j];
        for q := 0 to High(items) do
          if items[q].kind = 2 then begin
            if pi + items[q].cnt > npk then Refuse('bad PLT');
            b := PltBytes(items[q].z, plens, pi, items[q].cnt);
            w.PutN(b, 0, Length(b));
            pi := pi + items[q].cnt;
          end else begin
            w.PutN(items[q].raw, 0, Length(items[q].raw));
            if items[q].code = $FF58 then pi := pi + PltCount(items[q].raw);
          end;
        w.Put($FF); w.Put($93);
        w.PutN(tileOut.d, tilePk[pk0], tilePk[pk0 + npk] - tilePk[pk0]);
        w.PutN(gap, 0, Length(gap));
        case psotMode of
          0: v := w.n;
          1: v := 0;
          else v := psot;
        end;
        if v > High(Cardinal) then Refuse('tile-part too long');
        w.d[6] := v shr 24; w.d[7] := (v shr 16) and $FF; w.d[8] := (v shr 8) and $FF; w.d[9] := v and $FF;
        bytes := w.Bytes;
      end;
end;

{ ------------------------------------------------------------------ the headers' side information }
procedure TJ2k.WriteHeaders;
var i, q, tli, pi: Integer; h: ^TBW; lens: array of Int64; b: TBytes; it: TItem;
begin
  h := @sw[SH_HDR];
  SetLength(lens, Length(tps));
  for i := 0 to High(tps) do lens[i] := tps[i].dend - tps[i].hstart;
  h^.V(Length(main)); tli := 0;
  for i := 0 to High(main) do begin
    it := main[i];
    if it.code = $FF55 then begin
      q := TlmCount(it.raw);
      if (q > 0) and (tli + q <= Length(tps)) then begin
        b := TlmBytes(Self, it.raw[4], it.raw[5], tli, q, lens);
        if SameBytes(b, it.raw) then begin
          h^.Put(1); h^.Put(it.raw[4]); h^.Put(it.raw[5]); h^.V(q);
          tli := tli + q;
          Continue;
        end;
      end;
      tli := tli + q;
    end;
    h^.Put(0); h^.V(Length(it.raw)); h^.PutN(it.raw, 0, Length(it.raw));
  end;
  h^.V(Length(tps));
  for i := 0 to High(tps) do
    with tps[i] do begin
      h^.V(isot); h^.Put(tpsot); h^.Put(tnsot); h^.Put(psotMode);
      if psotMode = 2 then h^.V(psot);
      h^.V(Length(items)); pi := 0;
      for q := 0 to High(items) do begin
        it := items[q];
        if it.code = $FF58 then begin
          if (Length(it.raw) > 5) and (pi + PltCount(it.raw) <= npk) then begin
            b := PltBytes(it.raw[4], plens, pi, PltCount(it.raw));
            if SameBytes(b, it.raw) then begin
              h^.Put(2); h^.Put(it.raw[4]); h^.V(PltCount(it.raw));
              pi := pi + PltCount(it.raw);
              Continue;
            end;
          end;
          pi := pi + PltCount(it.raw);
        end;
        h^.Put(0); h^.V(Length(it.raw)); h^.PutN(it.raw, 0, Length(it.raw));
      end;
    end;
  h^.V(Length(tail)); h^.PutN(tail, 0, Length(tail));
end;

procedure TJ2k.ReadHeaders;
var i, q, n, kind: Integer; h: ^TBR; it: TItem;
begin
  h := @sr[SH_HDR];
  n := h^.VI(Min64(1 shl 20, h^.e - h^.p));
  SetLength(main, n);
  for i := 0 to n - 1 do begin
    it := Default(TItem);
    kind := h^.Get;
    if kind = 1 then begin
      it.code := $FF55; it.kind := 1; it.z := h^.Get; it.st := h^.Get; it.cnt := h^.VI(MAXTILES * 256);
    end else if kind = 0 then begin
      it.raw := h^.Take(h^.VI(65537));
      if (Length(it.raw) < 2) or (it.raw[0] <> $FF) or ((Length(it.raw) < 4) and not IsBareMarker(Be16(it.raw, 0))) then
        Refuse('bad header');
      it.code := Be16(it.raw, 0);
      if (i = 0) and (it.code <> $FF51) then Refuse('bad header');
      ParseMainItem(it);
    end else Refuse('bad header');
    main[i] := it;
  end;
  if (n = 0) or not mainG.have or not hasMainQcd then Refuse('bad header');
  n := h^.VI(Min64(MAXTILES * 256, (h^.e - h^.p) div 5));
  SetLength(tps, n);
  for i := 0 to n - 1 do
    with tps[i] do begin
      isot := h^.VI(nxt * nyt - 1); tpsot := h^.Get; tnsot := h^.Get; psotMode := h^.Get;
      if psotMode > 2 then Refuse('bad header');
      if psotMode = 2 then psot := h^.VI(High(Cardinal));
      SetLength(items, h^.VI(Min64(1 shl 20, h^.e - h^.p)));
      for q := 0 to High(items) do begin
        it := Default(TItem);
        kind := h^.Get;
        if kind = 2 then begin it.code := $FF58; it.kind := 2; it.z := h^.Get; it.cnt := h^.VI(MAXENTRIES); end
        else if kind = 0 then begin
          it.raw := h^.Take(h^.VI(65537));
          if (Length(it.raw) < 2) or (it.raw[0] <> $FF) or ((Length(it.raw) < 4) and not IsBareMarker(Be16(it.raw, 0))) then
            Refuse('bad header');
          it.code := Be16(it.raw, 0);
        end else Refuse('bad header');
        items[q] := it;
      end;
    end;
  if n = 0 then Refuse('bad header');
  tail := h^.Take(h^.VI(High(LongInt)));
  SplitPpm;
end;

{ PPM: each tile-part's hdrPacked headers, Nppm and its bytes, in order }
procedure TJ2k.SplitPpm;
var q, L: Int64; i, z: Integer;
begin
  if not hasPpm then Exit;
  { the PPM marker segments' data in the order of their index Zppm (the
    order of the codestream among equal ones) }
  ppm.n := 0;
  for z := 0 to 255 do
    for i := 0 to High(main) do
      if (main[i].code = $FF60) and (Length(main[i].raw) >= 5) and (main[i].raw[4] = z) then
        ppm.PutN(main[i].raw, 5, Length(main[i].raw) - 5);
  q := 0;
  for i := 0 to High(tps) do begin
    if q + 4 > ppm.n then Refuse('PPM cut short');
    L := Be32(ppm.d, q);
    if L > ppm.n - q - 4 then Refuse('PPM cut short');
    tps[i].ppmOff := q + 4; tps[i].ppmLen := L; q := q + 4 + L;
  end;
end;

function TJ2k.Assemble: TBytes;
var w: TBW; i, tli: Integer; lens: array of Int64; b: TBytes;
begin
  w := Default(TBW);
  w.Put($FF); w.Put($4F);
  SetLength(lens, Length(tps));
  for i := 0 to High(tps) do lens[i] := Length(tps[i].bytes);
  tli := 0;
  for i := 0 to High(main) do
    if main[i].kind = 1 then begin
      if tli + main[i].cnt > Length(tps) then Refuse('bad TLM');
      b := TlmBytes(Self, main[i].z, main[i].st, tli, main[i].cnt, lens);
      w.PutN(b, 0, Length(b));
      tli := tli + main[i].cnt;
    end else begin
      w.PutN(main[i].raw, 0, Length(main[i].raw));
      if main[i].code = $FF55 then tli := tli + TlmCount(main[i].raw);
    end;
  for i := 0 to High(tps) do w.PutN(tps[i].bytes, 0, Length(tps[i].bytes));
  w.PutN(tail, 0, Length(tail));
  Result := w.Bytes;
end;

{ the tiles that have tile-parts, in order }
function TileList(j: TJ2k): TBytes;
var used: array of Boolean; i: Integer;
begin
  Result := nil;
  SetLength(used, j.nxt * j.nyt);
  for i := 0 to High(j.tps) do used[j.tps[i].isot] := True;
  SetLength(Result, Length(used));
  for i := 0 to High(used) do Result[i] := Ord(used[i]);
end;

const BLOB_VERSION = 1;

function J2kRebuildInto(const blob: TBytes; out cs: TBytes; out why: string): Boolean;
var j: TJ2k; r: TBR; i: Integer; n: array[0..J2K_NSTREAMS - 1] of Int64; p: Int64; used: TBytes;
begin
  cs := nil; why := ''; Result := False;
  j := TJ2k.Create(False);
  try
    try
      r := Default(TBR); r.d := blob; r.p := 0; r.e := Length(blob);
      if r.Get <> BLOB_VERSION then Refuse('blob version');
      for i := 0 to J2K_NSTREAMS - 1 do n[i] := r.VI(High(LongInt));
      p := r.p;
      for i := 0 to J2K_NSTREAMS - 1 do begin
        if n[i] > Length(blob) - p then Refuse('blob cut short');
        j.sr[i].d := Copy(blob, p, n[i]); j.sr[i].p := 0; j.sr[i].e := n[i];
        p := p + n[i];
      end;
      j.ReadHeaders;
      used := TileList(j);
      for i := 0 to High(used) do
        if used[i] <> 0 then j.Tile(i);
      for i := 0 to J2K_NSTREAMS - 1 do
        if (i <> SH_DEC) and (j.sr[i].p <> j.sr[i].e) then Refuse('side information left over: ' + J2kStreamName(i));
      if (j.dbits + 7) div 8 <> j.sr[SH_DEC].e then Refuse('decisions left over');
      cs := j.Assemble;
      Result := True;
    except
      on E: EJ2k do why := E.Message;
      on E: Exception do why := 'exception ' + E.ClassName + ': ' + E.Message;
    end;
  finally
    j.Free;
  end;
end;

function J2kRebuild(const blob: TBytes; out cs: TBytes): Boolean;
var why: string;
begin
  Result := J2kRebuildInto(blob, cs, why);
end;

function J2kRebuildWhy(const blob: TBytes; out cs: TBytes; out why: string): Boolean;
begin
  Result := J2kRebuildInto(blob, cs, why);
end;

function J2kAnalyze(const data: TBytes; off, len: Int64; out blob: TBytes; out reason: string;
  var st: TJ2kStats): Boolean;
var j: TJ2k; i, k: Integer; w: TBW; used, back: TBytes; why: string;
begin
  blob := nil; reason := ''; Result := False;
  if (off < 0) or (len < 0) or (off + len > Length(data)) then begin reason := 'bad range'; Exit; end;
  j := TJ2k.Create(True);
  try
    try
      j.cs := data; j.csOff := off; j.csLen := len;
      j.Structure;
      used := TileList(j);
      for i := 0 to High(used) do
        if used[i] <> 0 then j.Tile(i);
      j.WriteHeaders;
      w := Default(TBW);
      w.Put(BLOB_VERSION);
      for i := 0 to J2K_NSTREAMS - 1 do w.V(j.sw[i].n);
      for i := 0 to J2K_NSTREAMS - 1 do w.PutN(j.sw[i].d, 0, j.sw[i].n);
      blob := w.Bytes;
      { checked: the blob alone gives the codestream back }
      if not J2kRebuildInto(blob, back, why) then Refuse('verify: ' + why);
      if (Length(back) <> len) or ((len > 0) and not CompareMem(@back[0], @data[off], len)) then begin
        k := 0;
        while (k < Length(back)) and (k < len) and (back[k] = data[off + k]) do Inc(k);
        Refuse('verify: differs at ' + IntToStr(k) + ' of ' + IntToStr(len) + ' (' + IntToStr(Length(back)) + ')');
      end;
      Inc(st.codestreams); st.tiles := st.tiles + j.st.tiles; st.packets := st.packets + j.st.packets;
      st.hdrExceptions := st.hdrExceptions + j.st.hdrExceptions; st.treeOverrides := st.treeOverrides + j.st.treeOverrides;
      st.lbNonMinimal := st.lbNonMinimal + j.st.lbNonMinimal; st.cbs := st.cbs + j.st.cbs; st.cbRaw := st.cbRaw + j.st.cbRaw;
      st.segs := st.segs + j.st.segs; st.rawSegs := st.rawSegs + j.st.rawSegs; st.bounds := st.bounds + j.st.bounds;
      st.tails := st.tails + j.st.tails; st.tailBits := st.tailBits + j.st.tailBits; st.decisions := st.decisions + j.st.decisions;
      for i := 0 to 15 do st.rule[i] := st.rule[i] + j.st.rule[i];
      for i := 0 to 3 do st.brule[i] := st.brule[i] + j.st.brule[i];
      for i := 0 to J2K_NSTREAMS - 1 do st.side[i] := st.side[i] + j.sw[i].n;
      Result := True;
    except
      on E: EJ2k do reason := E.Message;
      on E: Exception do reason := 'exception ' + E.ClassName + ': ' + E.Message;
    end;
  finally
    j.Free;
  end;
  if not Result then blob := nil;
end;

end.

{ Stream version 8's mode 2: a reversible JPEG 2000 codestream kept as its
  pixels and what it takes to make the codestream again from them
  (doc/CODEC.md, "JPEG 2000, stage D"). A codestream's mode 2 stream:

    byte 0          its layout: 0 (another: a later release's, FutureVersion)
    4 bytes (LE)    a check: the first 4 bytes of the codestream's BLAKE3
    4 bytes (LE)    the side information's length, L
    L bytes         the side information (pjaj2kcs's blob, version 2, as
                    mode 1's: without the decisions, with its slice table)
                    through the raw bytes' model (pjamodel.CodeRaw): at most
                    J2kSideBound(codestream's length) bytes, on both sides
    byte            hb, the bitonal model's large tables (2^hb counters,
                    the far ones 2^(hb - 2)): PX_HBMIN to PX_HBMAX
    byte            the colour: 0, or 1 when planes 0 to 2 (the same size
                    and depth, 15 bits at most) go to the models as the
                    reversible colour transform makes them (Y, then Db and
                    Dr + 2^depth, of depth + 1 bits): what the encoder does
                    when every tile of the codestream has that transform
    the rest        the planes, one after the other, through the pixel
                    models (pjaj2kpm.c) with one arithmetic stream

  The planes, one a component, are the image area of the SIZ on the
  component's grid (ceil(Xsiz / XRsiz) - ceil(XOsiz / XRsiz) samples wide,
  the same down); the side information's SIZ gives them, and the decoder
  checks them against the bounds before it decodes anything else. The
  pixels: each tile's coefficients decoded from its code-blocks'
  decisions, through the inverse 5/3 wavelet, the inverse reversible
  colour transform when the tile has it, and the DC level shift (a sample
  is kept as v + 2^(depth - 1), signed or not). Back: the same forward,
  the coefficients to the decisions (the passes and zero bit-planes the
  side information says), and those to the codestream as mode 1's
  rebuild does it.

  Taken (else the codestream goes in mode 1 or 0): every tile-component
  reversible (the 5/3 wavelet, no quantization), no RGN, a precision of 1
  to 16 bits, every code-block decoded with all its passes (but trailing
  ones that change nothing: not rate-truncated), every sample in its
  range, and the stream decoded and compared. Bounded: the planes
  PX_MAXSAMPLES samples in all (2 bytes each) and max(PX_FREE, PX_PERBYTE
  x the codestream's bytes), a plane of 2 bits or more PX_MAXWIDTH wide, a
  tile's coefficients PX_TILECAP (4 bytes each, on each worker), so that a
  codestream of more is not taken and a stream that says more is refused
  before anything is decoded.

  This unit links C (pjaj2kcs's tier-1 and pjaj2kpm.c): a program without
  it reads mode 2 as FutureVersion (pjacodec's hooks, set here). }
unit pjaj2kpx;

{$I pja.inc}
{$ifopt R-}{$fatal pjaj2kpx: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaj2kpx: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, Classes, pjaarith, pjamodel, pjablake3, pjaj2kcs;

const
  { the planes' samples in all, and a tile's (all its components) }
  PX_MAXSAMPLES = 1 shl 27;
  PX_TILECAP = 1 shl 26;
  { the workers' coefficients in all: fewer workers for larger tiles }
  PX_WORKBYTES = 1 shl 28;
  PX_HBMIN = 12; PX_HBMAX = 22;
  { a plane of 2 to 16 bits (as the model takes it: the colour transform
    makes a 1-bit plane 2-bit) at most so many samples wide: the model keeps
    PX_RESW (18) int32 a column of the widest }
  PX_MAXWIDTH = 1 shl 20;
  { the planes' samples at most max(PX_FREE, PX_PERBYTE x the codestream's
    bytes): time and memory follow the bytes, not what a few of them
    declare }
  PX_FREE = 1 shl 20; PX_PERBYTE = 1024;

type
  TMode2Result = (m2Ok, m2Refused, m2Bad, m2Future, m2TooLarge);

{ The codestream data[off..off + len) as mode 2's stream, decoded and
  compared before it is given; m2Refused (and why) when it is not taken,
  or when the stream is not shorter than limit (then not decoded).
  mode1Floor: what mode 1's stream would be at the least, if it coded the
  codestream's coded bytes (those the side information does not keep) to
  half (it saves a fifth at best); 0 when not taken. }
function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; limit: Int64; out stream: TBytes;
  out why: string; out mode1Floor: Int64): TMode2Result; overload;
{ the same, the stream decoded and compared only when decodeIt (pjacodec's
  CompressJ2k checks the one it keeps) }
function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; limit: Int64; decodeIt: Boolean;
  out stream: TBytes; out why: string; out mode1Floor: Int64): TMode2Result; overload;
function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; out stream: TBytes;
  out why: string): TMode2Result; overload;
{ What the codestream's SIZ alone says of mode 2 (pjainfoj2k, without
  coding): '' when its planes are within mode 2's bounds for a codestream
  of len bytes, else why not ('more than 16 bits', 'too wide', 'too many
  samples', 'too many samples for its bytes', 'SIZ'). siz: the SIZ marker
  segment, from its marker. }
function J2kMode2SizWhy(const siz: TBytes; len: Int64): string;
{ A mode 2 stream back to its codestream, which must be len bytes. }
function J2kMode2Decode(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TMode2Result;
function J2kMode2DecodeWhy(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes;
  out why: string): TMode2Result;

implementation

uses pjacodec, pjastage, pjaj2k;

{$L pjaj2kpm.o}

type
  TPxPut = procedure(ctx: Pointer; b: PByte; n: PtrInt); cdecl;
  PPWord = ^PWord;

function pjaj2kp_t1_size: Int64; cdecl; external;
function pjaj2kp_cb_coef(tmem: Pointer; w, h, orient, sty, npasses, P: LongInt; sym: PByte; n: Int64;
  passend: PLongInt; coef: PLongInt; cstride: Int64): LongInt; cdecl; external;
function pjaj2kp_cb_sym(tmem: Pointer; w, h, orient, sty, npasses, P: LongInt; coef: PLongInt; cstride: Int64;
  sym: PByte; cap: Int64; passend: PLongInt): Int64; cdecl; external;
function pjaj2kp_dwt(a: PLongInt; stride: Int64; W, H: LongInt; x0, y0: Int64; nl, fwd: LongInt;
  line: PInt64): LongInt; cdecl; external;
function pjaj2kp_rct(c0, c1, c2: PLongInt; n: Int64; fwd: LongInt): LongInt; cdecl; external;
function pjaj2kp_put(a: PLongInt; astride: Int64; W, H, depth: LongInt; p: PWord; pstride: Int64): LongInt;
  cdecl; external;
function pjaj2kp_get(a: PLongInt; astride: Int64; W, H, depth: LongInt; p: PWord; pstride: Int64): LongInt;
  cdecl; external;
function pjaj2kp_model_size(hb: LongInt): Int64; cdecl; external;
function pjaj2kp_code(mem: Pointer; size: Int64; hb, encoding: LongInt; put: TPxPut; pctx: Pointer;
  data: PByte; len: Int64; n: LongInt; w, h, depth: PLongInt; planes: PPWord; res: PLongInt;
  rescap: Int64; path: LongInt): LongInt; cdecl; external;
function pjaj2kp_res_width: LongInt; cdecl; external;
function pjaj2kp_cb_full(tmem: Pointer; w, h, orient, sty, P: LongInt; coef: PLongInt; cstride: Int64): LongInt;
  cdecl; external;
function pjaj2kp_planes_rct(p0, p1, p2: PWord; n: Int64; depth, fwd: LongInt): LongInt; cdecl; external;

const
  LAYOUT = 0;

type
  { the SIZ: what the planes are }
  TSiz = record
    ix0, iy0, ix1, iy1, tw, th: Int64;
    n: Integer;
    dx, dy, depth: array of Integer; signed: array of Boolean;
    pw, ph, ox, oy: array of Int64;    { each plane's size, its origin on the component's grid }
    total, tileMax: Int64;             { the planes' samples, a tile's at most }
  end;

  { a worker's tile: its components' coefficients one after the other, in
    the Mallat layout; where each band is }
  TPxWorker = class
    t1: Pointer;
    buf: array of LongInt;
    line: array of Int64;
    sym2: TBytes; pe2: array of LongInt;
    tile: TJ2kPixTile;
    coff: array of Int64;              { each component's first coefficient }
    cw, ch: array of Int64;            { its size }
    boff: array of Int64;              { each band's first coefficient }
    bw, bh: array of Int64;
    destructor Destroy; override;
  end;

  TPx = class
    encoding: Boolean;
    siz: TSiz;
    planes: array of array of Word;
    workers: array of TPxWorker;
    noMct: LongInt;                    { encoding: the tiles without the colour transform }
    truncated: Boolean;                { encoding: a code-block without all its passes }
    constructor Create(enc: Boolean);
    destructor Destroy; override;
    procedure SetWorkers(n: Integer);
    function Slice(k, hb, worker: Integer): Pointer;
    procedure SliceEnd(k, worker: Integer);
    function Tile(km: Pointer; const t: TJ2kPixTile): string;
    function Cb(km: Pointer; band, x0, y0, w, h, sty, npass, zbp: Integer; sym: PByte; n, cap: Int64;
      passend: PLongInt): Int64;
    function TileEnd(km: Pointer): string;
  end;

destructor TPxWorker.Destroy;
begin
  if t1 <> nil then FreeMem(t1);
  inherited Destroy;
end;

constructor TPx.Create(enc: Boolean);
begin
  inherited Create;
  encoding := enc;
end;

destructor TPx.Destroy;
begin
  SetWorkers(0);
  inherited Destroy;
end;

procedure TPx.SetWorkers(n: Integer);
var k: Integer;
begin
  for k := 0 to High(workers) do workers[k].Free;
  workers := nil;
  SetLength(workers, n);
  for k := 0 to n - 1 do workers[k] := nil;
end;

{ each worker's state, made when it first asks }
function TPx.Slice(k, hb, worker: Integer): Pointer;
begin
  Result := nil;
  if (worker < 0) or (worker > High(workers)) then Exit;
  if workers[worker] = nil then begin
    workers[worker] := TPxWorker.Create;
    workers[worker].t1 := GetMem(pjaj2kp_t1_size);
  end;
  Result := workers[worker];
end;

procedure TPx.SliceEnd(k, worker: Integer);
begin
end;

{ ceil(a / 2^n), a >= 0 }
function CeilShr(a: Int64; n: Integer): Int64;
begin
  Result := (a + (Int64(1) shl n) - 1) shr n;
end;

function CeilDiv(a, b: Int64): Int64;
begin
  Result := (a + b - 1) div b;
end;

function Be16(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 8) or d[p + 1];
end;

function Be32(const d: TBytes; p: Int64): Cardinal;
begin
  Result := (Cardinal(d[p]) shl 24) or (Cardinal(d[p + 1]) shl 16) or (Cardinal(d[p + 2]) shl 8) or d[p + 3];
end;

{ the SIZ marker segment (from its marker) to the planes; '' or why they
  cannot be taken }
function ParseSiz(const raw: TBytes; out z: TSiz): string;
var c: Integer; t: Int64;
begin
  Result := ''; z := Default(TSiz);
  if (Length(raw) < 42) or (Be16(raw, 0) <> $FF51) then Exit('SIZ');
  z.ix1 := Be32(raw, 6); z.iy1 := Be32(raw, 10); z.ix0 := Be32(raw, 14); z.iy0 := Be32(raw, 18);
  z.tw := Be32(raw, 22); z.th := Be32(raw, 26);
  z.n := Be16(raw, 38);
  if (z.n < 1) or (z.n > 16384) or (Length(raw) < 40 + 3 * z.n) then Exit('SIZ');
  if (z.ix1 <= z.ix0) or (z.iy1 <= z.iy0) or (z.tw = 0) or (z.th = 0) then Exit('SIZ');
  SetLength(z.dx, z.n); SetLength(z.dy, z.n); SetLength(z.depth, z.n); SetLength(z.signed, z.n);
  SetLength(z.pw, z.n); SetLength(z.ph, z.n); SetLength(z.ox, z.n); SetLength(z.oy, z.n);
  for c := 0 to z.n - 1 do begin
    z.depth[c] := (raw[40 + 3 * c] and $7F) + 1; z.signed[c] := raw[40 + 3 * c] and $80 <> 0;
    z.dx[c] := raw[41 + 3 * c]; z.dy[c] := raw[42 + 3 * c];
    if (z.dx[c] = 0) or (z.dy[c] = 0) then Exit('SIZ');
    if z.depth[c] > 16 then Exit('more than 16 bits');
    z.ox[c] := CeilDiv(z.ix0, z.dx[c]); z.oy[c] := CeilDiv(z.iy0, z.dy[c]);
    z.pw[c] := CeilDiv(z.ix1, z.dx[c]) - z.ox[c]; z.ph[c] := CeilDiv(z.iy1, z.dy[c]) - z.oy[c];
    if (z.depth[c] > 1) and (z.pw[c] > PX_MAXWIDTH) then Exit('too wide');
    z.total := z.total + z.pw[c] * z.ph[c];
    if z.total > PX_MAXSAMPLES then Exit('too many samples');
    { a tile-component at most (its first and last tiles may start or end
      within a sample) }
    t := CeilDiv(z.tw, z.dx[c]) + 1; if t > z.pw[c] then t := z.pw[c];
    if CeilDiv(z.th, z.dy[c]) + 1 < z.ph[c] then t := t * (CeilDiv(z.th, z.dy[c]) + 1) else t := t * z.ph[c];
    z.tileMax := z.tileMax + t;
  end;
  if z.tileMax > PX_TILECAP then z.tileMax := PX_TILECAP;
end;

{ the planes within what a codestream of len bytes may ask }
function SamplesFit(const z: TSiz; len: Int64): Boolean;
begin
  Result := (z.total <= PX_FREE) or (z.total <= PX_PERBYTE * len);
end;

function J2kMode2SizWhy(const siz: TBytes; len: Int64): string;
var z: TSiz;
begin
  Result := ParseSiz(siz, z);
  if (Result = '') and not SamplesFit(z, len) then Result := 'too many samples for its bytes';
end;

function TPx.Tile(km: Pointer; const t: TJ2kPixTile): string;
var wk: TPxWorker; c, b, r, o, nl, lv: Integer; total, a, sn, sv, rw, rh, ox, oy: Int64;
begin
  Result := '';
  wk := TPxWorker(km);
  if t.rgn then Exit('RGN');
  if not t.mct then InterLockedIncrement(noMct);
  if Length(t.comps) <> siz.n then Exit('components');
  if (t.ix0 <> siz.ix0) or (t.iy0 <> siz.iy0) or (t.ix1 <> siz.ix1) or (t.iy1 <> siz.iy1) then Exit('SIZ');
  if t.mct and ((siz.n < 3) or (t.comps[1].x0 <> t.comps[0].x0) or (t.comps[1].x1 <> t.comps[0].x1) or
    (t.comps[2].x0 <> t.comps[0].x0) or (t.comps[2].x1 <> t.comps[0].x1) or (t.comps[1].y0 <> t.comps[0].y0) or
    (t.comps[1].y1 <> t.comps[0].y1) or (t.comps[2].y0 <> t.comps[0].y0) or (t.comps[2].y1 <> t.comps[0].y1)) then
    Exit('colour transform');
  total := 0;
  SetLength(wk.coff, siz.n); SetLength(wk.cw, siz.n); SetLength(wk.ch, siz.n);
  for c := 0 to siz.n - 1 do
    with t.comps[c] do begin
      if not ok then Exit('not reversible');
      if (depth <> siz.depth[c]) or (signed <> siz.signed[c]) or (dx <> siz.dx[c]) or (dy <> siz.dy[c]) or
         (nres < 1) or (nres > 33) then Exit('SIZ');
      if (x0 < siz.ox[c]) or (y0 < siz.oy[c]) or (x1 > siz.ox[c] + siz.pw[c]) or (y1 > siz.oy[c] + siz.ph[c]) or
         (x1 < x0) or (y1 < y0) then Exit('planes');
      wk.coff[c] := total; wk.cw[c] := x1 - x0; wk.ch[c] := y1 - y0;
      total := total + (x1 - x0) * (y1 - y0);
      if total > PX_TILECAP then Exit('tile too large');
    end;
  if Length(wk.buf) < total then begin wk.buf := nil; SetLength(wk.buf, total); end;
  a := 0;
  for c := 0 to siz.n - 1 do if wk.cw[c] > a then a := wk.cw[c];
  for c := 0 to siz.n - 1 do if wk.ch[c] > a then a := wk.ch[c];
  if Length(wk.line) < a + 8 then SetLength(wk.line, a + 8);
  { the bands, where the Mallat layout puts them }
  SetLength(wk.boff, Length(t.bands)); SetLength(wk.bw, Length(t.bands)); SetLength(wk.bh, Length(t.bands));
  for b := 0 to High(t.bands) do
    with t.bands[b] do begin
      if (comp < 0) or (comp >= siz.n) then Exit('bands');
      c := comp; r := res; o := orient;
      nl := t.comps[c].nres - 1;
      if (r < 0) or (r > nl) or ((r = 0) <> (o = 0)) or (o < 0) or (o > 3) then Exit('bands');
      lv := nl - r;
      rw := CeilShr(t.comps[c].x1, lv) - CeilShr(t.comps[c].x0, lv);
      rh := CeilShr(t.comps[c].y1, lv) - CeilShr(t.comps[c].y0, lv);
      if r = 0 then begin sn := rw; sv := rh; end
      else begin
        sn := CeilShr(t.comps[c].x1, lv + 1) - CeilShr(t.comps[c].x0, lv + 1);
        sv := CeilShr(t.comps[c].y1, lv + 1) - CeilShr(t.comps[c].y0, lv + 1);
      end;
      if o in [1, 3] then begin ox := sn; wk.bw[b] := rw - sn; end else begin ox := 0; wk.bw[b] := sn; end;
      if o in [2, 3] then begin oy := sv; wk.bh[b] := rh - sv; end else begin oy := 0; wk.bh[b] := sv; end;
      if (wk.bw[b] <> x1 - x0) or (wk.bh[b] <> y1 - y0) then Exit('band size');
      wk.boff[b] := wk.coff[c] + oy * wk.cw[c] + ox;
    end;
  wk.tile := t;
  if encoding then begin
    if total > 0 then FillChar(wk.buf[0], total * SizeOf(LongInt), 0);
  end else begin
    { the coefficients from the pixels }
    for c := 0 to siz.n - 1 do
      with t.comps[c] do
        if (wk.cw[c] > 0) and (wk.ch[c] > 0) then
          if pjaj2kp_get(@wk.buf[wk.coff[c]], wk.cw[c], wk.cw[c], wk.ch[c], depth,
            @planes[c][(y0 - siz.oy[c]) * siz.pw[c] + (x0 - siz.ox[c])], siz.pw[c]) <> 0 then Exit('planes');
    if t.mct and (wk.cw[0] > 0) and (wk.ch[0] > 0) then
      if pjaj2kp_rct(@wk.buf[wk.coff[0]], @wk.buf[wk.coff[1]], @wk.buf[wk.coff[2]], wk.cw[0] * wk.ch[0], 1) <> 0 then
        Exit('overflow');
    for c := 0 to siz.n - 1 do
      with t.comps[c] do
        if (wk.cw[c] > 0) and (wk.ch[c] > 0) then
          if pjaj2kp_dwt(@wk.buf[wk.coff[c]], wk.cw[c], wk.cw[c], wk.ch[c], x0, y0, nres - 1, 1, @wk.line[0]) <> 0 then
            Exit('overflow');
  end;
end;

function TPx.Cb(km: Pointer; band, x0, y0, w, h, sty, npass, zbp: Integer; sym: PByte; n, cap: Int64;
  passend: PLongInt): Int64;
var wk: TPxWorker; P, c: Integer; at: PLongInt;
begin
  Result := -1;
  wk := TPxWorker(km);
  if (band < 0) or (band > High(wk.tile.bands)) or (x0 < 0) or (y0 < 0) or (w < 1) or (h < 1) or
     (x0 + Int64(w) > wk.bw[band]) or (y0 + Int64(h) > wk.bh[band]) then Exit;
  P := wk.tile.bands[band].mb - zbp;
  if (P < 1) or (P > 30) then Exit;
  c := wk.tile.bands[band].comp;
  at := @wk.buf[wk.boff[band] + Int64(y0) * wk.cw[c] + x0];
  if encoding then begin
    { -1 too for more passes than the bit-planes have (seen: a DICOM file's
      code-blocks of 116 passes for 14 planes) }
    if pjaj2kp_cb_coef(wk.t1, w, h, wk.tile.bands[band].orient, sty, npass, P, sym, n, passend, at, wk.cw[c]) <> 0 then
      Exit;
    { the coefficients give these decisions back }
    if Length(wk.sym2) < n + 16 then SetLength(wk.sym2, n + n div 4 + 64);
    if Length(wk.pe2) < npass + 1 then SetLength(wk.pe2, npass + 16);
    if (pjaj2kp_cb_sym(wk.t1, w, h, wk.tile.bands[band].orient, sty, npass, P, at, wk.cw[c], @wk.sym2[0],
      Length(wk.sym2), @wk.pe2[0]) <> n) or ((n > 0) and not CompareMem(@wk.sym2[0], sym, n)) then Exit;
    { all its passes, but the trailing ones that change nothing (Kakadu
      leaves those out): else a rate-truncated, lossy code-block, whose
      pixels are not the image's }
    if npass < pjaj2kp_cb_full(wk.t1, w, h, wk.tile.bands[band].orient, sty, P, at, wk.cw[c]) then begin
      truncated := True; Exit;
    end;
    Result := n;
  end else
    Result := pjaj2kp_cb_sym(wk.t1, w, h, wk.tile.bands[band].orient, sty, npass, P, at, wk.cw[c], sym, cap, passend);
end;

function TPx.TileEnd(km: Pointer): string;
var wk: TPxWorker; c: Integer;
begin
  Result := '';
  if not encoding then Exit;
  wk := TPxWorker(km);
  with wk.tile do begin
    for c := 0 to siz.n - 1 do
      with comps[c] do
        if (wk.cw[c] > 0) and (wk.ch[c] > 0) then
          if pjaj2kp_dwt(@wk.buf[wk.coff[c]], wk.cw[c], wk.cw[c], wk.ch[c], x0, y0, nres - 1, 0, @wk.line[0]) <> 0 then
            Exit('overflow');
    if mct and (wk.cw[0] > 0) and (wk.ch[0] > 0) then
      if pjaj2kp_rct(@wk.buf[wk.coff[0]], @wk.buf[wk.coff[1]], @wk.buf[wk.coff[2]], wk.cw[0] * wk.ch[0], 0) <> 0 then
        Exit('overflow');
    for c := 0 to siz.n - 1 do
      with comps[c] do
        if (wk.cw[c] > 0) and (wk.ch[c] > 0) then
          if pjaj2kp_put(@wk.buf[wk.coff[c]], wk.cw[c], wk.cw[c], wk.ch[c], depth,
            @planes[c][(y0 - siz.oy[c]) * siz.pw[c] + (x0 - siz.ox[c])], siz.pw[c]) <> 0 then
            Exit('a sample out of range');
  end;
end;

{ ------------------------------------------------------------------ bytes }
procedure PutU32(var b: TBytes; var p: SizeInt; v: Cardinal);
begin
  b[p] := v and $FF; b[p + 1] := (v shr 8) and $FF; b[p + 2] := (v shr 16) and $FF; b[p + 3] := v shr 24;
  Inc(p, 4);
end;

function GetU32(const b: TBytes; p: SizeInt): Cardinal;
begin
  Result := Cardinal(b[p]) or (Cardinal(b[p + 1]) shl 8) or (Cardinal(b[p + 2]) shl 16) or (Cardinal(b[p + 3]) shl 24);
end;

function Check(const d: TBytes; off, len: Int64): Cardinal;
var h: THash16;
begin
  h := Blake3_128(d, off, len, nil, 0, 0);
  Result := Cardinal(h[0]) or (Cardinal(h[1]) shl 8) or (Cardinal(h[2]) shl 16) or (Cardinal(h[3]) shl 24);
end;

type
  TOut = record d: TBytes; n: Int64; end;
  POut = ^TOut;

procedure PutBytes(ctx: Pointer; b: PByte; n: PtrInt); cdecl;
var o: POut;
begin
  o := ctx;
  if o^.n + n > Length(o^.d) then SetLength(o^.d, 2 * (o^.n + n) + 4096);
  Move(b^, o^.d[o^.n], n);
  o^.n := o^.n + n;
end;

{ the bitonal model's tables: 2^hb counters for so many samples of 1 bit }
function HbFor(const z: TSiz): Integer;
var c: Integer; n: Int64;
begin
  n := 0;
  for c := 0 to z.n - 1 do if z.depth[c] = 1 then n := n + z.pw[c] * z.ph[c];
  Result := PX_HBMIN;
  while (Result < PX_HBMAX) and (Int64(1) shl Result < n) do Inc(Result);
end;

{ whether planes 0 to 2 can go through the colour transform }
function ColourOk(const z: TSiz): Boolean;
begin
  Result := (z.n >= 3) and (z.depth[0] <= 15) and (z.depth[1] = z.depth[0]) and (z.depth[2] = z.depth[0]) and
    (z.pw[1] = z.pw[0]) and (z.pw[2] = z.pw[0]) and (z.ph[1] = z.ph[0]) and (z.ph[2] = z.ph[0]) and
    (z.pw[0] * z.ph[0] > 0);
end;

{ the planes through the models (colour: planes 0 to 2 in the colour
  transform's terms); False when they do not decode. Encoding changes the
  planes. }
function CodePlanes(px: TPx; hb: Integer; colour: Boolean; encoding: Boolean; var o: TOut; const src: TBytes;
  srcOff, srcLen: Int64): Boolean;
var mem: Pointer; size, maxw: Int64; w, h, dp: array of LongInt; pp: array of PWord; res: array of LongInt;
  c: Integer; sse41, avx2: Boolean; path: LongInt;
begin
  size := pjaj2kp_model_size(hb);
  if size < 0 then Exit(False);
  SetLength(w, px.siz.n + 1); SetLength(h, px.siz.n + 1); SetLength(dp, px.siz.n + 1); SetLength(pp, px.siz.n + 1);
  maxw := 1;
  for c := 0 to px.siz.n - 1 do begin
    w[c] := px.siz.pw[c]; h[c] := px.siz.ph[c]; dp[c] := px.siz.depth[c];
    if Length(px.planes[c]) > 0 then pp[c] := @px.planes[c][0] else pp[c] := nil;
  end;
  if colour then begin
    if not ColourOk(px.siz) then Exit(False);
    dp[1] := dp[0] + 1; dp[2] := dp[0] + 1;
  end;
  { the multi-bit model's rows: the widest plane of 2 bits or more }
  for c := 0 to px.siz.n - 1 do
    if (dp[c] > 1) and (px.siz.pw[c] > maxw) then maxw := px.siz.pw[c];
  if maxw > PX_MAXWIDTH then Exit(False);
  if colour and encoding and (pjaj2kp_planes_rct(pp[0], pp[1], pp[2], w[0] * h[0], px.siz.depth[0], 1) <> 0) then
    Exit(False);
  SetLength(res, pjaj2kp_res_width * maxw);
  { the SIMD copy of the models pjamodel's cpuid allows (the same bits) }
  GetSimd(sse41, avx2);
  if avx2 then path := 2 else if sse41 then path := 1 else path := 0;
  mem := GetMem(size);
  try
    if encoding then
      Result := pjaj2kp_code(mem, size, hb, 1, @PutBytes, @o, nil, 0, px.siz.n, @w[0], @h[0], @dp[0], @pp[0],
        @res[0], Length(res), path) = 0
    else
      Result := pjaj2kp_code(mem, size, hb, 0, nil, nil, PByte(src) + srcOff, srcLen, px.siz.n, @w[0], @h[0],
        @dp[0], @pp[0], @res[0], Length(res), path) = 0;
  finally
    FreeMem(mem);
  end;
  if Result and colour and not encoding then
    Result := pjaj2kp_planes_rct(pp[0], pp[1], pp[2], w[0] * h[0], px.siz.depth[0], 0) = 0;
end;

{ how many workers, each with a tile of at most tileMax samples }
function WorkerCount(threads: Integer; tileMax: Int64): Integer;
begin
  Result := threads;
  if tileMax < 1 then tileMax := 1;
  if Result > PX_WORKBYTES div (4 * tileMax) then Result := PX_WORKBYTES div (4 * tileMax);
  if Result < 1 then Result := 1;
end;

function Link(px: TPx; kind: TJ2kModelKind; threads: Integer): TJ2kModelLink;
begin
  Result := Default(TJ2kModelLink);
  Result.kind := kind; Result.slice := @px.Slice; Result.sliceEnd := @px.SliceEnd; Result.threads := threads;
  Result.pixTile := @px.Tile; Result.pixCb := @px.Cb; Result.pixEnd := @px.TileEnd;
end;

function DecodeIn(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes;
  out why: string): TMode2Result;
var p, side, bound: Int64; cd: TCoder; blob, raw: TBytes; px: TPx; c, hb, nw: Integer; o: TOut;
begin
  cs := nil; why := '';
  if len < 0 then Exit(m2Bad);
  bound := J2kSideBound(len);
  {$ifndef CPU64}
  if bound > High(SizeInt) then Exit(m2TooLarge);
  {$endif}
  if Length(stream) < 11 then Exit(m2Bad);
  if stream[0] <> LAYOUT then Exit(m2Future);
  side := GetU32(stream, 5); p := 9;
  if side > Length(stream) - p - 2 then Exit(m2Bad);
  hb := stream[p + side];
  if (hb < PX_HBMIN) or (hb > PX_HBMAX) or (stream[p + side + 1] > 1) then Exit(m2Bad);
  { the side information: at most what the encoder writes for a codestream
    of len bytes }
  cd.InitDecoder(Copy(stream, p, side), 0);
  if not CodeRaw(cd, blob, bound) then Exit(m2Bad);
  { the planes from its SIZ, within the bounds, before they are decoded }
  if not J2kBlobSiz(blob, raw) then Exit(m2Bad);
  if (J2kSamplesCap > 0) and (J2kSizSamples(raw) > J2kSamplesCap) then begin
    why := 'more samples than the cap'; Exit(m2Bad);
  end;
  px := TPx.Create(False);
  try
    why := ParseSiz(raw, px.siz);
    if why <> '' then Exit(m2Bad);
    if not SamplesFit(px.siz, len) then begin why := 'too many samples for its bytes'; Exit(m2Bad); end;
    SetLength(px.planes, px.siz.n);
    for c := 0 to px.siz.n - 1 do SetLength(px.planes[c], px.siz.pw[c] * px.siz.ph[c]);
    o := Default(TOut);
    if not CodePlanes(px, hb, stream[p + side + 1] = 1, False, o, stream, p + side + 2, Length(stream) - p - side - 2) then begin
      why := 'pixels'; Exit(m2Bad);
    end;
    { the codestream from them }
    nw := WorkerCount(threads, px.siz.tileMax);
    px.SetWorkers(nw);
    if not J2kRebuildWith(blob, Link(px, kmPixDecode, nw), cs, why) then begin cs := nil; Exit(m2Bad); end;
    if (Length(cs) <> len) or (Check(cs, 0, len) <> GetU32(stream, 1)) then begin
      cs := nil; why := 'check'; Exit(m2Bad);
    end;
    Result := m2Ok;
  finally
    px.Free;
  end;
end;

{ the planes and the tiles' coefficients in memory: a host that has not
  that much gives TooLarge (decoding) or a refusal (encoding), never an
  exception }
function J2kMode2DecodeWhy(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes;
  out why: string): TMode2Result;
begin
  try
    Result := DecodeIn(stream, len, threads, cs, why);
  except
    on E: EOutOfMemory do begin cs := nil; why := 'memory'; Result := m2TooLarge; end;
    on E: Exception do begin cs := nil; why := 'exception ' + E.ClassName + ': ' + E.Message; Result := m2Bad; end;
  end;
end;

function J2kMode2Decode(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TMode2Result;
var why: string;
begin
  Result := J2kMode2DecodeWhy(stream, len, threads, cs, why);
end;

{$ifdef PJA_PX_DUMP}
{ a build for the model's tuning only: each codestream's planes appended
  to the file $PJA_PX_DUMP (per plane: width, height, depth as u32 LE, then
  the samples as u16 LE) }
var dumpNo: Integer = 0;
procedure DumpPlanes(px: TPx);
var f: TFileStream; c: Integer; hd: array[0..2] of LongWord; name: string;
begin
  name := GetEnvironmentVariable('PJA_PX_DUMP');
  if name = '' then Exit;
  if FileExists(name) then f := TFileStream.Create(name, fmOpenReadWrite) else f := TFileStream.Create(name, fmCreate);
  try
    f.Seek(0, soEnd);
    for c := 0 to px.siz.n - 1 do begin
      hd[0] := px.siz.pw[c]; hd[1] := px.siz.ph[c]; hd[2] := px.siz.depth[c];
      f.WriteBuffer(hd, 12);
      if Length(px.planes[c]) > 0 then f.WriteBuffer(px.planes[c][0], 2 * Length(px.planes[c]));
    end;
  finally
    f.Free;
  end;
  Inc(dumpNo);
end;
{$endif}

function EncodeIn(const data: TBytes; off, len: Int64; threads: Integer; limit: Int64; decodeIt: Boolean;
  out stream: TBytes; out why: string; out mode1Floor: Int64): TMode2Result;
var px: TPx; raw, blob, side, back: TBytes; st: TJ2kStats; cd: TCoder; o: TOut; c, hb, nw: Integer;
  p: SizeInt; total: Int64; why2: string; colour: Boolean; was: TStage;
begin
  stream := nil; why := ''; mode1Floor := 0;
  if (off < 0) or (len < 46) or (off + len > Length(data)) then begin why := 'no SIZ'; Exit(m2Refused); end;
  if (data[off] <> $FF) or (data[off + 1] <> $4F) or (data[off + 2] <> $FF) or (data[off + 3] <> $51) or
     (Be16(data, off + 4) + 2 > len - 2) then begin why := 'no SIZ'; Exit(m2Refused); end;
  raw := Copy(data, off + 2, Be16(data, off + 4) + 2);
  px := TPx.Create(True);
  try
    why := ParseSiz(raw, px.siz);
    if why <> '' then Exit(m2Refused);
    if not SamplesFit(px.siz, len) then begin why := 'too many samples for its bytes'; Exit(m2Refused); end;
    SetLength(px.planes, px.siz.n);
    for c := 0 to px.siz.n - 1 do SetLength(px.planes[c], px.siz.pw[c] * px.siz.ph[c]);
    nw := WorkerCount(threads, px.siz.tileMax);
    px.SetWorkers(nw);
    st := Default(TJ2kStats);
    if not J2kAnalyzeWith(data, off, len, Link(px, kmPixEncode, nw), blob, why, st) then begin
      if px.truncated then why := 'rate-truncated: a code-block without all its passes';
      Exit(m2Refused);
    end;
    if Length(blob) > J2kSideBound(len) then begin why := 'side information too large'; Exit(m2Refused); end;
    {$ifdef PJA_PX_DUMP}DumpPlanes(px);{$endif}
    cd.InitEncoder;
    CodeRaw(cd, blob, MaxInt);
    side := cd.enc.Finish;
    hb := HbFor(px.siz);
    { a 1-bit image made 2-bit by the colour transform: within the width }
    colour := (px.noMct = 0) and ColourOk(px.siz) and ((px.siz.depth[0] > 1) or (px.siz.pw[0] <= PX_MAXWIDTH));
    o := Default(TOut);
    if not CodePlanes(px, hb, colour, True, o, nil, 0, 0) then begin why := 'internal: pixels'; Exit(m2Refused); end;
    total := 11 + Int64(Length(side)) + o.n;
    if total >= High(LongInt) then begin why := 'too large'; Exit(m2Refused); end;
    { not kept: not decoded either }
    if total >= limit then begin why := 'not smaller'; Exit(m2Refused); end;
    mode1Floor := Length(side) + (len - Length(blob)) div 2;
    SetLength(stream, total);
    stream[0] := LAYOUT;
    p := 1; PutU32(stream, p, Check(data, off, len));
    PutU32(stream, p, Length(side));
    if Length(side) > 0 then Move(side[0], stream[p], Length(side));
    p := p + Length(side);
    stream[p] := hb; stream[p + 1] := Ord(colour); Inc(p, 2);
    if o.n > 0 then Move(o.d[0], stream[p], o.n);
  finally
    px.Free;
  end;
  { checked: the stream alone gives the codestream back (--stats: the
    verify, pjastage) }
  if not decodeIt then Exit(m2Ok);
  was := StageEnter(stVerify);
  if (J2kMode2DecodeWhy(stream, len, threads, back, why2) <> m2Ok) or (Length(back) <> len) or
     ((len > 0) and not CompareMem(@back[0], @data[off], len)) then begin
    StageEnter(was);
    stream := nil; why := 'verify: ' + why2;
    Exit(m2Refused);
  end;
  StageEnter(was);
  Result := m2Ok;
end;

function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; limit: Int64; decodeIt: Boolean;
  out stream: TBytes; out why: string; out mode1Floor: Int64): TMode2Result;
begin
  mode1Floor := 0;
  try
    Result := EncodeIn(data, off, len, threads, limit, decodeIt, stream, why, mode1Floor);
  except
    on E: EOutOfMemory do begin stream := nil; why := 'memory'; Result := m2Refused; end;
    on E: Exception do begin stream := nil; why := 'exception ' + E.ClassName + ': ' + E.Message; Result := m2Refused; end;
  end;
  if Result <> m2Ok then mode1Floor := 0;
end;

function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; limit: Int64; out stream: TBytes;
  out why: string; out mode1Floor: Int64): TMode2Result;
begin
  Result := J2kMode2Encode(data, off, len, threads, limit, True, stream, why, mode1Floor);
end;

function J2kMode2Encode(const data: TBytes; off, len: Int64; threads: Integer; out stream: TBytes;
  out why: string): TMode2Result;
var f: Int64;
begin
  Result := J2kMode2Encode(data, off, len, threads, High(Int64), stream, why, f);
end;

{ pjacodec's hook: only a stream shorter than the codestream }
function Mode2Enc(const data: TBytes; off, len: Int64; threads: Integer; decodeIt: Boolean; out stream: TBytes;
  out mode1Floor: Int64): Boolean;
var why: string;
begin
  Result := J2kMode2Encode(data, off, len, threads, len, decodeIt, stream, why, mode1Floor) = m2Ok;
end;

function Mode2Dec(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TCodecError;
begin
  case J2kMode2Decode(stream, len, threads, cs) of
    m2Ok: Result := ceOk;
    m2Future: Result := ceFutureVersion;
    m2TooLarge: Result := ceTooLarge;
    else Result := ceBadStream;
  end;
end;

initialization
  J2kMode2Enc := @Mode2Enc;
  J2kMode2Dec := @Mode2Dec;
end.

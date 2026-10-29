{ Stream version 7's coefficient model, in C (pjav7c.c, compiled to
  pjav7c.o before this unit: pas/build_c.sh). A program that uses this unit
  codes version 7; one that does not (the zpaq-std plugin) has no C in it
  and never writes or reads version 7.

  The C code takes no memory and calls no library: pjamodel hands it the
  tables, the counters and the scratch, and the two callbacks here carry
  bytes in and out of pjaarith's coder. It also brings pjasysc.c's helpers
  (BLAKE3's chunks four at a time, the sequential Huffman scan both ways),
  which it installs in the units that stay Pascal for the plugin. }
unit pjav7;

{$I pja.inc}
{$ifopt R-}{$fatal pjav7: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjav7: overflow checks ($Q+) are mandatory}{$endif}

interface

implementation

uses SysUtils, pjaarith, pjamodel, pjablake3, pjajpeg;

{$L pjav7c.o}
{$L pjasysc.o}

type
  { pjav7c.c's aenc_t: the encoder's interval, and where its bytes go }
  TV7Encoder = record
    x1, x2: Cardinal;
    ctx: Pointer;
    n: SizeInt;                         { bytes in buf, not yet out }
    buf: array[0..4095] of Byte;        { pjav7c.c's EBUF }
  end;

procedure pjav7_tables(constref t: TV7Tables); cdecl; external;
procedure pjasys_b3chunks(input: PByte; n: SizeInt; counter: QWord; cv: PLongWord); cdecl; external;
function pjasys_huffenc(var hs: THuffEncScan): SizeInt; cdecl; external;
function pjasys_huffdec(var hs: THuffDecScan): SizeInt; cdecl; external;

{ pjasysc.c's huff_t is THuff as laid out here: no padding anywhere }
function HuffLayoutOk: Boolean;
var h: THuff;
begin
  Result := (SizeOf(THuff) = 2260) and (PtrUInt(@h.nvalues) - PtrUInt(@h) = 272) and
            (PtrUInt(@h.mincode) - PtrUInt(@h) = 276) and (PtrUInt(@h.code) - PtrUInt(@h) = 468) and
            (PtrUInt(@h.lut) - PtrUInt(@h) = 1236);
end;
function pjav7_component_d(dc: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt; qt: PWord;
  lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte; var wk: TV7Work): LongInt; cdecl; external;
function pjav7_component_e(e: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt; qt: PWord;
  lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte; var wk: TV7Work): LongInt; cdecl; external;

{ n bytes of the encoder's output, as TArithEncoder.Encode writes them }
procedure Put(ctx: Pointer; b: PByte; n: SizeInt); cdecl;
var e: ^TArithEncoder; i: SizeInt;
begin
  e := ctx;
  if e^.live <> nil then
    for i := 0 to n - 1 do e^.live.Put(b[i])
  else begin
    if e^.n + n > Length(e^.d) then SetLength(e^.d, 2 * Length(e^.d) + n + 4096);
    Move(b^, e^.d[e^.n], n);
  end;
  Inc(e^.n, n);
end;

{ byte p of a band still being written by another thread (TLiveStream) }
function Get(live: Pointer; p: SizeInt): Cardinal; cdecl;
begin
  Result := TLiveStream(live).Get(p);
end;

function Code(encoding: Boolean; coder: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt;
              qt: PWord; lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte;
              var wk: TV7Work): Boolean;
var e: TV7Encoder; enc: ^TArithEncoder;
begin
  if not encoding then
    Exit(pjav7_component_d(coder, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk) <> 0);
  enc := coder;
  e.x1 := enc^.x1; e.x2 := enc^.x2; e.ctx := enc; e.n := 0;
  Result := pjav7_component_e(@e, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk) <> 0;
  enc^.x1 := e.x1; enc^.x2 := e.x2;
end;

var t: TV7Tables;
initialization
  V7FillTables(t);
  t.put := @Put; t.get := @Get;
  pjav7_tables(t);
  V7Code := @Code;
  { pjasysc.c's helpers, for the units that have no C of their own }
  Blake3Chunks := @pjasys_b3chunks;
  { the JPEG's own Huffman coding: PJA_NOASM=1 leaves it to Pascal (the
    suite compares the two) }
  if GetEnvironmentVariable('PJA_NOASM') <> '1' then begin
    HuffEncodeScan := @pjasys_huffenc;
    if HuffLayoutOk then HuffDecodeScan := @pjasys_huffdec;
  end;
end.

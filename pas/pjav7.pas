{ Stream version 7's coefficient model, in C (pjav7c.c, compiled to
  pjav7c.o before this unit: pas/build_c.sh). A program that uses this unit
  codes version 7; one that does not (the zpaq-std plugin) has no C in it
  and never writes or reads version 7.

  The C code takes no memory and calls no library: pjamodel hands it the
  tables, the counters and the scratch, and the two callbacks here carry
  bytes in and out of pjaarith's coder. }
unit pjav7;

{$I pja.inc}
{$ifopt R-}{$fatal pjav7: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjav7: overflow checks ($Q+) are mandatory}{$endif}

interface

implementation

uses pjaarith, pjamodel;

{$L pjav7c.o}

type
  { pjav7c.c's aenc_t: the encoder's interval, and where its bytes go }
  TV7Encoder = record
    x1, x2: Cardinal;
    ctx: Pointer;
  end;

procedure pjav7_tables(constref t: TV7Tables); cdecl; external;
function pjav7_component_d(dc: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt; qt: PWord;
  lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte; var wk: TV7Work): LongInt; cdecl; external;
function pjav7_component_e(e: Pointer; var m: TV7Model; coef: PSmallInt; bw, bh: SizeInt; qt: PWord;
  lumaNz: PByte; lumaW, sx, sy, y0, y1: SizeInt; nzc: PByte; var wk: TV7Work): LongInt; cdecl; external;

{ one byte of the encoder's output, as TArithEncoder.Encode writes it }
procedure Put(ctx: Pointer; b: Cardinal); cdecl;
var e: ^TArithEncoder;
begin
  e := ctx;
  if e^.live <> nil then e^.live.Put(Byte(b))
  else begin
    if e^.n >= Length(e^.d) then SetLength(e^.d, 2 * Length(e^.d) + 4096);
    e^.d[e^.n] := Byte(b);
  end;
  Inc(e^.n);
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
  e.x1 := enc^.x1; e.x2 := enc^.x2; e.ctx := enc;
  Result := pjav7_component_e(@e, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk) <> 0;
  enc^.x1 := e.x1; enc^.x2 := e.x2;
end;

var t: TV7Tables;
initialization
  V7FillTables(t);
  t.put := @Put; t.get := @Get;
  pjav7_tables(t);
  V7Code := @Code;
end.

{ Stream version 8's mode 1: a JPEG 2000 codestream taken apart (pjaj2kcs)
  and its decisions coded with a context-mixing model (pjaj2kmc.c), the
  rest of it through the raw bytes' model (doc/CODEC.md, "JPEG 2000, stage
  C"). A codestream's mode 1 stream:

    byte 0          its layout: 0 (another: a later release's, FutureVersion;
                    1 is meant for a codestream coded with the model and
                    the side information's context as the previous
                    codestream of the file left them: MJ2 frames, JPX)
    4 bytes (LE)    a check: the first 4 bytes of the codestream's BLAKE3
    4 bytes (LE)    S, the slices: 1 to J2K_MAX_SLICES
    S x 4 bytes     each slice's decisions' length
    4 bytes (LE)    the side information's length, L
    L bytes         the side information (pjaj2kcs's blob, version 2,
                    without the decisions, with its slice table) through
                    the raw bytes' model (pjamodel.CodeRaw): at most
                    J2kSideBound(codestream's length) bytes, on both sides
    the S slices'   decisions, each through the model (pjaj2kmc.c) with its
    decisions       own arithmetic stream

  The tiles are cut into S slices (pjaj2kcs.J2kAnalyzeWith: one per
  J2K_SLICE_BYTES of codestream, at most one a tile), each with its own
  model, so that they can be decoded on several threads: the stream is the
  same for any number of threads.

  This unit links C (pjaj2kcs's tier-1 and the model): a program that does
  not use it (the zpaq-std plugin) writes mode 0 only and reads mode 1 as
  FutureVersion (pjacodec's hooks, set here). The command and libpja use
  it. }
unit pjaj2km;

{$I pja.inc}
{$ifopt R-}{$fatal pjaj2km: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaj2km: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, Classes, pjaarith, pjamodel, pjablake3, pjaj2kcs;

type
  TMode1Result = (m1Ok, m1Refused, m1Bad, m1Future, m1TooLarge);

{ The codestream data[off..off + len) as mode 1's stream, decoded and
  compared before it is given. m1Refused (and why) when it is not taken. }
function J2kMode1Encode(const data: TBytes; off, len: Int64; threads: Integer; out stream: TBytes;
  out why: string): TMode1Result;
{ A mode 1 stream back to its codestream, which must be len bytes. }
function J2kMode1Decode(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TMode1Result;

implementation

uses pjacodec, pjastage;

const
  LAYOUT = 0;

type
  TSlices = class;
  TSliceOut = record owner: TSlices; k: Integer; end;
  PSliceOut = ^TSliceOut;
  TSlices = class
    encoding: Boolean;
    mems: array of Pointer;          { one model a worker, made when it first asks }
    memSize: Int64;
    { encoding: each slice's bytes }
    outs: array[0..J2K_MAX_SLICES - 1] of TBytes;
    outN: array[0..J2K_MAX_SLICES - 1] of Int64;
    ctx: array[0..J2K_MAX_SLICES - 1] of TSliceOut;
    { decoding: where each slice is in the stream }
    src: TBytes;
    srcOff, srcLen: array of Int64;
    asked: array[0..J2K_MAX_SLICES - 1] of Boolean;
    nAsked: LongInt;
    constructor Create(encode: Boolean; threads: Integer);
    destructor Destroy; override;
    function Slice(k, hb, worker: Integer): Pointer;
    procedure SliceEnd(k, worker: Integer);
  end;

procedure PutBytes(ctx: Pointer; b: PByte; n: PtrInt); cdecl;
var o: PSliceOut; s: TSlices; k: Integer;
begin
  o := ctx; s := o^.owner; k := o^.k;
  if s.outN[k] + n > Length(s.outs[k]) then SetLength(s.outs[k], 2 * (s.outN[k] + n) + 4096);
  Move(b^, s.outs[k][s.outN[k]], n);
  s.outN[k] := s.outN[k] + n;
end;

constructor TSlices.Create(encode: Boolean; threads: Integer);
var k: Integer;
begin
  inherited Create;
  encoding := encode;
  memSize := KmSize(KM_HBMAX);
  if threads < 1 then threads := 1;
  SetLength(mems, threads);
  for k := 0 to J2K_MAX_SLICES - 1 do begin ctx[k].owner := Self; ctx[k].k := k; end;
end;

destructor TSlices.Destroy;
var k: Integer;
begin
  for k := 0 to High(mems) do if mems[k] <> nil then FreeMem(mems[k]);
  inherited Destroy;
end;

{ slice k starts on worker: its model, set up (each slice once) }
function TSlices.Slice(k, hb, worker: Integer): Pointer;
begin
  Result := nil;
  if (k < 0) or (k >= J2K_MAX_SLICES) or (worker < 0) or (worker > High(mems)) or asked[k] then Exit;
  if encoding then begin
    asked[k] := True;
    InterLockedIncrement(nAsked);
  end else begin
    if k >= Length(srcOff) then Exit;
    asked[k] := True;
    InterLockedIncrement(nAsked);
  end;
  if mems[worker] = nil then mems[worker] := GetMem(memSize);
  if encoding then begin
    outN[k] := 0;
    if not KmInit(mems[worker], memSize, hb, True, @PutBytes, @ctx[k], nil, 0) then Exit;
  end else
    if not KmInit(mems[worker], memSize, hb, False, nil, nil, PByte(src) + srcOff[k], srcLen[k]) then Exit;
  Result := mems[worker];
end;

procedure TSlices.SliceEnd(k, worker: Integer);
begin
  if encoding and (worker >= 0) and (worker <= High(mems)) and (mems[worker] <> nil) then KmFinish(mems[worker]);
end;

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

function J2kMode1Decode(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TMode1Result;
var s, k: Integer; p, side, total, bound: Int64; cd: TCoder; blob: TBytes; sl: TSlices; lk: TJ2kModelLink;
  why: string;
begin
  cs := nil;
  if len < 0 then Exit(m1Bad);
  bound := J2kSideBound(len);
  {$ifndef CPU64}
  { more than a 32-bit program can hold: an error, not a range check }
  if bound > High(SizeInt) then Exit(m1TooLarge);
  {$endif}
  if Length(stream) < 9 then Exit(m1Bad);
  if stream[0] <> LAYOUT then Exit(m1Future);
  if (GetU32(stream, 5) < 1) or (GetU32(stream, 5) > J2K_MAX_SLICES) then Exit(m1Bad);
  s := GetU32(stream, 5);
  if 13 + 4 * Int64(s) > Length(stream) then Exit(m1Bad);
  p := 9 + 4 * s;
  side := GetU32(stream, p); p := p + 4;
  if side > Length(stream) - p then Exit(m1Bad);
  sl := TSlices.Create(False, threads);
  try
    SetLength(sl.srcOff, s); SetLength(sl.srcLen, s);
    total := p + side;
    for k := 0 to s - 1 do begin
      sl.srcOff[k] := total; sl.srcLen[k] := GetU32(stream, 9 + 4 * k);
      total := total + sl.srcLen[k];
    end;
    if total <> Length(stream) then Exit(m1Bad);
    sl.src := stream;
    { the side information: at most what the encoder writes for a codestream
      of len bytes (a longer one is refused as soon as its length is read) }
    cd.InitDecoder(Copy(stream, p, side), 0);
    if not CodeRaw(cd, blob, bound) then Exit(m1Bad);
    lk := Default(TJ2kModelLink);
    lk.kind := kmDecode; lk.slice := @sl.Slice; lk.sliceEnd := @sl.SliceEnd; lk.threads := threads;
    if not J2kRebuildWith(blob, lk, cs, why) then begin cs := nil; Exit(m1Bad); end;
    if (sl.nAsked <> s) or (Length(cs) <> len) or (Check(cs, 0, len) <> GetU32(stream, 1)) then begin
      cs := nil; Exit(m1Bad);
    end;
    Result := m1Ok;
  finally
    sl.Free;
  end;
end;

function J2kMode1Encode(const data: TBytes; off, len: Int64; threads: Integer; out stream: TBytes;
  out why: string): TMode1Result;
var sl: TSlices; lk: TJ2kModelLink; blob, side, back: TBytes; st: TJ2kStats; cd: TCoder; k, s: Integer;
  p: SizeInt; total: Int64; was: TStage;
begin
  stream := nil; why := '';
  sl := TSlices.Create(True, threads);
  try
    lk := Default(TJ2kModelLink);
    lk.kind := kmEncode; lk.slice := @sl.Slice; lk.sliceEnd := @sl.SliceEnd; lk.threads := threads;
    st := Default(TJ2kStats);
    if not J2kAnalyzeWith(data, off, len, lk, blob, why, st) then Exit(m1Refused);
    if Length(blob) > J2kSideBound(len) then begin why := 'side information too large'; Exit(m1Refused); end;
    s := sl.nAsked;
    if (s < 1) or (s > J2K_MAX_SLICES) then begin why := 'internal: slices'; Exit(m1Refused); end;
    for k := 0 to s - 1 do
      if not sl.asked[k] then begin why := 'internal: slices'; Exit(m1Refused); end;
    cd.InitEncoder;
    CodeRaw(cd, blob, MaxInt);
    side := cd.enc.Finish;
    total := 13 + 4 * Int64(s) + Length(side);
    for k := 0 to s - 1 do total := total + sl.outN[k];
    if total >= High(LongInt) then begin why := 'too large'; Exit(m1Refused); end;
    SetLength(stream, total);
    stream[0] := LAYOUT;
    p := 1; PutU32(stream, p, Check(data, off, len));
    PutU32(stream, p, s);
    for k := 0 to s - 1 do PutU32(stream, p, sl.outN[k]);
    PutU32(stream, p, Length(side));
    if Length(side) > 0 then Move(side[0], stream[p], Length(side));
    p := p + Length(side);
    for k := 0 to s - 1 do begin
      if sl.outN[k] > 0 then Move(sl.outs[k][0], stream[p], sl.outN[k]);
      p := p + sl.outN[k];
    end;
  finally
    sl.Free;
  end;
  { checked: the stream alone gives the codestream back (--stats: the
    verify, pjastage) }
  was := StageEnter(stVerify);
  if (J2kMode1Decode(stream, len, threads, back) <> m1Ok) or (Length(back) <> len) or
     ((len > 0) and not CompareMem(@back[0], @data[off], len)) then begin
    StageEnter(was);
    stream := nil; why := 'verify';
    Exit(m1Refused);
  end;
  StageEnter(was);
  Result := m1Ok;
end;

function Mode1Enc(const data: TBytes; off, len: Int64; threads: Integer; out stream: TBytes): Boolean;
var why: string;
begin
  Result := J2kMode1Encode(data, off, len, threads, stream, why) = m1Ok;
end;

function Mode1Dec(const stream: TBytes; len: Int64; threads: Integer; out cs: TBytes): TCodecError;
begin
  case J2kMode1Decode(stream, len, threads, cs) of
    m1Ok: Result := ceOk;
    m1Future: Result := ceFutureVersion;
    m1TooLarge: Result := ceTooLarge;
    else Result := ceBadStream;
  end;
end;

initialization
  J2kMode1Enc := @Mode1Enc;
  J2kMode1Dec := @Mode1Dec;
end.

{ The .pja format: ONE compressed JPEG (or JPEG-LS file), with its declared
  size and hash. Layout in doc/FORMAT.md.

  What .pja adds on top of the codec stream and nothing else:
  - the BLAKE3-128 hash of the original file, to verify the rebuild (a
    stream with a flipped bit can decode to ANOTHER valid JPEG without
    anything noticing);
  - the original size, to reject a bomb before decoding, and to cap the
    decoder.

  The writer and the reader validate with the SAME function: what is written
  can be read, and what is rejected on reading cannot be written. }
unit pjaformat;

{$I pja.inc}
{$ifopt R-}{$fatal pjaformat: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaformat: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjalimits, pjablake3;

const
  MAGIC: array[0..3] of Byte = (Ord('P'), Ord('J'), Ord('A'), $01);
  { 1 was a multi-file container and 2 an encrypted wrapper of packJPG's
    .pjg, both dropped before being published. }
  VERSION = 3;

  { no flag is defined yet }
  KNOWN_FLAGS = 0;

  { magic(4) + version(1) + flags(1) + reserved(2) }
  HEADER_SIZE = 8;
  { orig_size(8) + hash(16) }
  DESCRIPTOR_SIZE = 24;

type
  TPjaError = (
    peNone,
    peShortFile, peNotPja, peFutureVersion, peOldVersion, peUnknownFlag,
    peReservedNotZero,
    pePayloadOutOfRange, peBadOrigSize, peRatioExceeded, peOverflow);

  TPjaResult = record
    err: TPjaError;
    value: QWord;               { the version, with peFutureVersion and peOldVersion }
    function Ok: Boolean;
    { "FutureVersion(4)", "RatioExceeded"... }
    function Text: string;
  end;

  TPja = record
    orig_size: QWord;   { of the original file }
    hash: THash16;      { BLAKE3-128 of the original file }
    payload: TBytes;    { the codec stream }
  end;

{ The descriptor rules, shared by the reader and the writer. }
function ValidateDescriptor(origSize: QWord; payloadSize: QWord): TPjaResult;

{ Header, then descriptor; only then is the payload handed out. }
function Open(const data: TBytes; out p: TPja): TPjaResult;

{ How many bytes the .pja of a payload of that length takes. -1 if it does not
  fit in SizeInt (32 bits). }
function WrittenLength(payloadSize: Int64): Int64;

function WritePja(const payload: TBytes; const hash: THash16; origSize: QWord;
                  out bytes: TBytes): TPjaResult;

implementation

const
  ERROR_NAMES: array[TPjaError] of string = (
    'None',
    'ShortFile', 'NotPja', 'FutureVersion', 'OldVersion', 'UnknownFlag',
    'ReservedNotZero',
    'PayloadOutOfRange', 'BadOrigSize', 'RatioExceeded', 'Overflow');

function TPjaResult.Ok: Boolean;
begin Result := err = peNone; end;

function TPjaResult.Text: string;
begin
  case err of
    peFutureVersion, peOldVersion: Result := ERROR_NAMES[err] + '(' + IntToStr(value) + ')';
  else
    Result := ERROR_NAMES[err];
  end;
end;

function PjaFail(e: TPjaError; v: QWord = 0): TPjaResult;
begin
  Result := Default(TPjaResult);
  Result.err := e; Result.value := v;
end;

function U64(const b: TBytes; i: SizeInt): QWord;
var k: Integer;
begin
  Result := 0;
  for k := 7 downto 0 do Result := (Result shl 8) or b[i + k];
end;

procedure PutU64(var b: TBytes; i: SizeInt; v: QWord);
var k: Integer;
begin
  for k := 0 to 7 do b[i + k] := Byte((v shr (8 * k)) and $FF);
end;

{ ------------------------------------------------------------------------ }

function ReadHeader(const data: TBytes): TPjaResult;
var i: Integer; ver, flags: Byte;
   { NOT `version`: Pascal is case-insensitive, and a variable `version`
     shadows the constant VERSION. It happened in the previous container: the
     comparison became `version > version`, always false. }
begin
  if Length(data) < HEADER_SIZE then Exit(PjaFail(peShortFile));
  for i := 0 to 3 do
    if data[i] <> MAGIC[i] then Exit(PjaFail(peNotPja));
  ver := data[4];
  if ver > VERSION then Exit(PjaFail(peFutureVersion, ver));
  if ver < VERSION then Exit(PjaFail(peOldVersion, ver));
  flags := data[5];
  if (flags and (not KNOWN_FLAGS) and $FF) <> 0 then Exit(PjaFail(peUnknownFlag));
  if (data[6] <> 0) or (data[7] <> 0) then Exit(PjaFail(peReservedNotZero));
  Result := PjaFail(peNone);
end;

function ValidateDescriptor(origSize: QWord; payloadSize: QWord): TPjaResult;
begin
  if payloadSize < MIN_PAYLOAD then Exit(PjaFail(pePayloadOutOfRange));
  { An empty JPEG does not exist, and above High(Int64) no stream size can
    hold it. }
  if (origSize = 0) or (origSize > QWord(High(Int64))) then Exit(PjaFail(peBadOrigSize));
  { Divide instead of multiplying: payloadSize * ratio can overflow, the
    quotient cannot. origSize > ratio * payloadSize  <=>  (origSize - 1) div ratio >= payloadSize }
  if (origSize - 1) div MAX_EXPANSION_RATIO >= payloadSize then Exit(PjaFail(peRatioExceeded));
  Result := PjaFail(peNone);
end;

{ A rejection leaves nothing half filled: neither the orig_size nor the hash
  read before validation failed. }
procedure Clear(out p: TPja);
begin
  p.orig_size := 0; FillChar(p.hash, SizeOf(p.hash), 0); p.payload := nil;
end;

function Open(const data: TBytes; out p: TPja): TPjaResult;
var rest: SizeInt;
begin
  Clear(p);
  Result := ReadHeader(data);
  if not Result.Ok then Exit;
  rest := Length(data) - HEADER_SIZE;
  if rest < DESCRIPTOR_SIZE then Exit(PjaFail(peShortFile));
  p.orig_size := U64(data, HEADER_SIZE);
  Move(data[HEADER_SIZE + 8], p.hash[0], 16);
  Result := ValidateDescriptor(p.orig_size, QWord(rest - DESCRIPTOR_SIZE));
  if not Result.Ok then begin Clear(p); Exit; end;
  { Copy does NOT range-check, not even with $R+: it trims silently. The
    length is already validated above; this is what actually remains. }
  p.payload := Copy(data, HEADER_SIZE + DESCRIPTOR_SIZE, rest - DESCRIPTOR_SIZE);
  if Length(p.payload) <> rest - DESCRIPTOR_SIZE then
    raise ERangeError.Create('Open: the payload did not come out whole');
end;

{ ------------------------------------------------------------------------ }

function WrittenLength(payloadSize: Int64): Int64;
begin
  if (payloadSize < 0) or (payloadSize > High(SizeInt) - HEADER_SIZE - DESCRIPTOR_SIZE) then Exit(-1);
  Result := HEADER_SIZE + DESCRIPTOR_SIZE + payloadSize;
end;

function WritePja(const payload: TBytes; const hash: THash16; origSize: QWord;
                  out bytes: TBytes): TPjaResult;
var total: Int64; i: Integer;
begin
  bytes := nil;
  Result := ValidateDescriptor(origSize, Length(payload));
  if not Result.Ok then Exit;
  total := WrittenLength(Length(payload));
  if total < 0 then Exit(PjaFail(peOverflow));
  SetLength(bytes, total);
  for i := 0 to 3 do bytes[i] := MAGIC[i];
  bytes[4] := VERSION; bytes[5] := 0; bytes[6] := 0; bytes[7] := 0;
  PutU64(bytes, HEADER_SIZE, origSize);
  Move(hash[0], bytes[HEADER_SIZE + 8], 16);
  if Length(payload) > 0 then Move(payload[0], bytes[HEADER_SIZE + DESCRIPTOR_SIZE], Length(payload));
end;

end.

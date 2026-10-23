{ The .pja format: ONE compressed JPEG (or JPEG-LS file), with its declared
  size and hash. Layout in doc/FORMAT.md.

  What .pja adds on top of the codec stream and nothing else:
  - the BLAKE3-128 hash of the original file, to verify the rebuild (a
    stream with a flipped bit can decode to ANOTHER valid JPEG without
    anything noticing);
  - the original size, to reject a bomb before decoding, and to cap the
    decoder;
  - (version 4) the original's extension, as it was written, for the
    extracted file's name, with a check of its own (the hash covers the
    content only).

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
    .pjg, both dropped before being published. 3 had no extension; it is
    still read. }
  VERSION = 4;
  OLDEST_VERSION = 3;

  { the payload is the original itself, stored: the codec would not have
    made it smaller }
  FLAG_STORED = 1;
  KNOWN_FLAGS = FLAG_STORED;

  { magic(4) + version(1) + flags(1) + reserved(2) }
  HEADER_SIZE = 8;
  { orig_size(8) + hash(16); version 4 adds the extension field after it }
  DESCRIPTOR_SIZE = 24;
  { the extension: its length, its characters (letters, digits, '_' and
    '-', no dot), and 4 bytes of the BLAKE3 of both }
  MAX_EXT = 15;
  EXT_CHECK = 4;

type
  TPjaError = (
    peNone,
    peShortFile, peNotPja, peFutureVersion, peOldVersion, peUnknownFlag,
    peReservedNotZero,
    pePayloadOutOfRange, peBadOrigSize, peRatioExceeded, peOverflow,
    peBadExtension);

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
    stored: Boolean;    { FLAG_STORED: the payload is the original }
    ext: string;        { the original's extension without the dot; '' if none (or version 3) }
    payload: TBytes;    { the codec stream, or the original }
  end;

{ The descriptor rules, shared by the reader and the writer. A stored
  payload is the original, so its length has to be orig_size exactly. }
function ValidateDescriptor(origSize: QWord; payloadSize: QWord; stored: Boolean = False): TPjaResult;

{ Header, then descriptor; only then is the payload handed out. }
function Open(const data: TBytes; out p: TPja): TPjaResult;

{ An extension the format keeps: 0 to MAX_EXT letters, digits, '_' or '-'.
  Anything else is not written (the reader then names the file by its
  content), so nothing read can reach outside the directory. }
function ValidExtension(const ext: string): Boolean;

{ The extension field's check: the first EXT_CHECK bytes of the BLAKE3 of
  its length byte and its characters. }
function ExtensionCheck(const ext: string): THash16;

{ How many bytes the .pja of a payload of that length takes, with an
  extension of extLen characters. -1 if it does not fit in SizeInt (32 bits). }
function WrittenLength(payloadSize: Int64; extLen: Integer = 0): Int64;

function WritePja(const payload: TBytes; const hash: THash16; origSize: QWord;
                  out bytes: TBytes; stored: Boolean = False; const ext: string = ''): TPjaResult;

implementation

const
  ERROR_NAMES: array[TPjaError] of string = (
    'None',
    'ShortFile', 'NotPja', 'FutureVersion', 'OldVersion', 'UnknownFlag',
    'ReservedNotZero',
    'PayloadOutOfRange', 'BadOrigSize', 'RatioExceeded', 'Overflow',
    'BadExtension');

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

function ReadHeader(const data: TBytes; out flags, ver: Byte): TPjaResult;
var i: Integer;
   { NOT `version`: Pascal is case-insensitive, and a variable `version`
     shadows the constant VERSION. It happened in the previous container: the
     comparison became `version > version`, always false. }
begin
  flags := 0; ver := 0;
  if Length(data) < HEADER_SIZE then Exit(PjaFail(peShortFile));
  for i := 0 to 3 do
    if data[i] <> MAGIC[i] then Exit(PjaFail(peNotPja));
  ver := data[4];
  if ver > VERSION then Exit(PjaFail(peFutureVersion, ver));
  if ver < OLDEST_VERSION then Exit(PjaFail(peOldVersion, ver));
  flags := data[5];
  if (flags and (not KNOWN_FLAGS) and $FF) <> 0 then Exit(PjaFail(peUnknownFlag));
  if (data[6] <> 0) or (data[7] <> 0) then Exit(PjaFail(peReservedNotZero));
  Result := PjaFail(peNone);
end;

function ValidateDescriptor(origSize: QWord; payloadSize: QWord; stored: Boolean): TPjaResult;
begin
  if stored then begin
    if payloadSize = 0 then Exit(PjaFail(pePayloadOutOfRange));
    if origSize <> payloadSize then Exit(PjaFail(peBadOrigSize));
    Exit(PjaFail(peNone));
  end;
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
  p.orig_size := 0; FillChar(p.hash, SizeOf(p.hash), 0); p.stored := False; p.ext := ''; p.payload := nil;
end;

function ValidExtension(const ext: string): Boolean;
var i: Integer;
begin
  if Length(ext) > MAX_EXT then Exit(False);
  for i := 1 to Length(ext) do
    if not (ext[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then Exit(False);
  Result := True;
end;

function ExtensionCheck(const ext: string): THash16;
var b: TBytes; i: Integer;
begin
  b := nil; SetLength(b, 1 + Length(ext));
  b[0] := Length(ext);
  for i := 1 to Length(ext) do b[i] := Ord(ext[i]);
  Result := Blake3_128(b);
end;

function Open(const data: TBytes; out p: TPja): TPjaResult;
var rest, desc: SizeInt; flags, ver: Byte; n, i: Integer; check: THash16;
begin
  Clear(p);
  Result := ReadHeader(data, flags, ver);
  if not Result.Ok then Exit;
  rest := Length(data) - HEADER_SIZE;
  if rest < DESCRIPTOR_SIZE then Exit(PjaFail(peShortFile));
  desc := DESCRIPTOR_SIZE;
  if ver >= 4 then begin
    { the extension: its length within bounds, the whole field there, only
      the allowed characters, and its check }
    if rest < DESCRIPTOR_SIZE + 1 then Exit(PjaFail(peShortFile));
    n := data[HEADER_SIZE + DESCRIPTOR_SIZE];
    if n > MAX_EXT then Exit(PjaFail(peBadExtension));
    desc := DESCRIPTOR_SIZE + 1 + n + EXT_CHECK;
    if rest < desc then Exit(PjaFail(peShortFile));
    SetLength(p.ext, n);
    for i := 1 to n do p.ext[i] := Chr(data[HEADER_SIZE + DESCRIPTOR_SIZE + i]);
    check := ExtensionCheck(p.ext);
    if not ValidExtension(p.ext) or
       not CompareMem(@check[0], @data[HEADER_SIZE + DESCRIPTOR_SIZE + 1 + n], EXT_CHECK) then begin
      Clear(p); Exit(PjaFail(peBadExtension));
    end;
  end;
  p.orig_size := U64(data, HEADER_SIZE);
  Move(data[HEADER_SIZE + 8], p.hash[0], 16);
  p.stored := (flags and FLAG_STORED) <> 0;
  Result := ValidateDescriptor(p.orig_size, QWord(rest - desc), p.stored);
  if not Result.Ok then begin Clear(p); Exit; end;
  { Copy does NOT range-check, not even with $R+: it trims silently. The
    length is already validated above; this is what actually remains. }
  p.payload := Copy(data, HEADER_SIZE + desc, rest - desc);
  if Length(p.payload) <> rest - desc then
    raise ERangeError.Create('Open: the payload did not come out whole');
end;

{ ------------------------------------------------------------------------ }

function WrittenLength(payloadSize: Int64; extLen: Integer): Int64;
var fixed: Int64;
begin
  if (extLen < 0) or (extLen > MAX_EXT) then Exit(-1);
  fixed := HEADER_SIZE + DESCRIPTOR_SIZE + 1 + extLen + EXT_CHECK;
  if (payloadSize < 0) or (payloadSize > High(SizeInt) - fixed) then Exit(-1);
  Result := fixed + payloadSize;
end;

function WritePja(const payload: TBytes; const hash: THash16; origSize: QWord;
                  out bytes: TBytes; stored: Boolean; const ext: string): TPjaResult;
var total: Int64; i, at: Integer; check: THash16;
begin
  bytes := nil;
  if not ValidExtension(ext) then Exit(PjaFail(peBadExtension));
  Result := ValidateDescriptor(origSize, Length(payload), stored);
  if not Result.Ok then Exit;
  total := WrittenLength(Length(payload), Length(ext));
  if total < 0 then Exit(PjaFail(peOverflow));
  SetLength(bytes, total);
  for i := 0 to 3 do bytes[i] := MAGIC[i];
  bytes[4] := VERSION; bytes[5] := Ord(stored) * FLAG_STORED; bytes[6] := 0; bytes[7] := 0;
  PutU64(bytes, HEADER_SIZE, origSize);
  Move(hash[0], bytes[HEADER_SIZE + 8], 16);
  at := HEADER_SIZE + DESCRIPTOR_SIZE;
  bytes[at] := Length(ext);
  for i := 1 to Length(ext) do bytes[at + i] := Ord(ext[i]);
  check := ExtensionCheck(ext);
  Move(check[0], bytes[at + 1 + Length(ext)], EXT_CHECK);
  at := at + 1 + Length(ext) + EXT_CHECK;
  if Length(payload) > 0 then Move(payload[0], bytes[at], Length(payload));
end;

end.

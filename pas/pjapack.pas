{ A whole file to a .pja and back: the codec (pjacodec) inside the format
  (pjaformat), in the order doc/FORMAT.md gives.

  Pack: compress (which verifies its own stream), hash the original, write.
  Unpack: open the format, refuse a declared size above the caller's cap,
  decode with that size as the decoder's cap, check the length and the hash.
  What comes out of Unpack with ukOk is the original, byte for byte. }
unit pjapack;

{$I pja.inc}
{$ifopt R-}{$fatal pjapack: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjapack: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pjablake3, pjaformat, pjacodec;

type
  TPackError = (
    ukOk,
    { the .pja is malformed (detail in fmt) }
    ukFormat,
    { the codec refused the input, or the stream (detail in codec) }
    ukCodec,
    { the declared size is above the caller's cap }
    ukTooLarge,
    { decoded, but not to the declared length or hash: damaged }
    ukSizeMismatch, ukHashMismatch);

  TPackResult = record
    err: TPackError;
    fmt: TPjaResult;
    codec: TCodecResult;
    function Ok: Boolean;
    { "Format(RatioExceeded)", "Codec(Jpeg(Unsupported(F7)@6))", "HashMismatch" }
    function Text: string;
  end;

{ The original file (JPEG or JPEG-LS) -> .pja. fast: the codec's fast model
  (pjacodec.Compress). }
function Pack(const original: TBytes; out pja: TBytes; threads: Integer = 1; fast: Boolean = False): TPackResult;

{ .pja -> the original. maxOutput: the largest original accepted. With
  ukHashMismatch, `original` holds what was decoded and `expected` the hash
  it should have had, for a caller that keeps damaged output under another
  name; with any other error it is empty. }
function Unpack(const pja: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16;
                threads: Integer = 1): TPackResult;

implementation

const
  ERROR_NAMES: array[TPackError] of string = ('Ok', 'Format', 'Codec', 'TooLarge', 'SizeMismatch', 'HashMismatch');

function TPackResult.Ok: Boolean;
begin Result := err = ukOk; end;

function TPackResult.Text: string;
begin
  Result := ERROR_NAMES[err];
  case err of
    ukFormat: Result := Result + '(' + fmt.Text + ')';
    ukCodec: Result := Result + '(' + codec.Text + ')';
  end;
end;

function PackFail(e: TPackError): TPackResult;
begin
  Result := Default(TPackResult);
  Result.err := e;
end;

function Pack(const original: TBytes; out pja: TBytes; threads: Integer; fast: Boolean): TPackResult;
var stream: TBytes;
begin
  pja := nil;
  Result := PackFail(ukOk);
  Result.codec := Compress(original, stream, True, threads, fast);
  if not Result.codec.Ok then begin Result.err := ukCodec; Exit; end;
  Result.fmt := WritePja(stream, Blake3_128(original), Length(original), pja);
  if not Result.fmt.Ok then begin pja := nil; Result.err := ukFormat; end;
end;

function Unpack(const pja: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16;
                threads: Integer): TPackResult;
var p: TPja; actual: THash16; cap: QWord;
begin
  original := nil;
  FillChar(expected, SizeOf(expected), 0);
  Result := PackFail(ukOk);
  Result.fmt := Open(pja, p);
  if not Result.fmt.Ok then begin Result.err := ukFormat; Exit; end;
  expected := p.hash;
  if p.orig_size > maxOutput then Exit(PackFail(ukTooLarge));
  { the raw part of the stream can never be longer than the whole file }
  cap := p.orig_size;
  if cap > QWord(High(SizeInt)) then cap := QWord(High(SizeInt));
  Result.codec := Decompress(p.payload, original, SizeInt(cap), threads);
  if not Result.codec.Ok then begin original := nil; Result.err := ukCodec; Exit; end;
  if QWord(Length(original)) <> p.orig_size then begin original := nil; Exit(PackFail(ukSizeMismatch)); end;
  actual := Blake3_128(original);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then Result.err := ukHashMismatch;
end;

end.

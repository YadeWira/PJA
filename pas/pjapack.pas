{ A whole file to a .pja and back: the codec (pjacodec) inside the format
  (pjaformat), in the order doc/FORMAT.md gives.

  Pack: compress (which verifies its own stream), hash the original, write;
  a stream no smaller than the original is not worth it, and the original
  is stored instead (pjaformat.FLAG_STORED).
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
    { Unpack: the original's extension the .pja keeps, without the dot; ''
      when it has none (a version 3 .pja, or one that was not kept) }
    ext: string;
    function Ok: Boolean;
    { "Format(RatioExceeded)", "Codec(Jpeg(Unsupported(F7)@6))", "HashMismatch" }
    function Text: string;
  end;

{ The original file (JPEG or JPEG-LS) -> .pja. fast: the codec's fast model
  (pjacodec.Compress). verify: decompress the stream and compare it with
  the original before writing (the default); without it, a codec bug would
  only show when extracting, where the hash catches it. The JPEG's own round
  trip (pjajpeg.VerifyRoundTrip) runs either way. ext: the original's
  extension without the dot, kept for the extracted name when the format
  allows it (pjaformat.ValidExtension); any other is left out. }
function Pack(const original: TBytes; out pja: TBytes; threads: Integer = 1; fast: Boolean = False;
              verify: Boolean = True; const ext: string = ''): TPackResult;

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

function Pack(const original: TBytes; out pja: TBytes; threads: Integer; fast: Boolean;
              verify: Boolean; const ext: string): TPackResult;
var stream: TBytes; e: string;
begin
  e := ext;
  if not ValidExtension(e) then e := '';
  pja := nil;
  Result := PackFail(ukOk);
  Result.codec := Compress(original, stream, verify, threads, fast);
  if not Result.codec.Ok then begin Result.err := ukCodec; Exit; end;
  if Length(stream) >= Length(original) then
    Result.fmt := WritePja(original, Blake3_128(original), Length(original), pja, True, e)
  else
    Result.fmt := WritePja(stream, Blake3_128(original), Length(original), pja, False, e);
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
  Result.ext := p.ext;
  if p.orig_size > maxOutput then Exit(PackFail(ukTooLarge));
  { the raw part of the stream can never be longer than the whole file }
  cap := p.orig_size;
  if cap > QWord(High(SizeInt)) then cap := QWord(High(SizeInt));
  if p.stored then original := p.payload
  else begin
    Result.codec := Decompress(p.payload, original, SizeInt(cap), threads, SizeInt(cap));
    if not Result.codec.Ok then begin original := nil; Result.err := ukCodec; Exit; end;
  end;
  if QWord(Length(original)) <> p.orig_size then begin original := nil; Exit(PackFail(ukSizeMismatch)); end;
  actual := Blake3_128(original);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then Result.err := ukHashMismatch;
end;

end.

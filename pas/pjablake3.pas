{ BLAKE3, in Pascal: the hash only (no keyed mode, no key derivation), as the
  specification describes it (github.com/BLAKE3-team/BLAKE3-specs) and as the
  reference implementation in its repository does it. The output used here is
  the first 16 bytes, BLAKE3-128.

  Checked against the official implementation through the vectors in
  tests/kat.txt (sizes 0 to 1 MiB, across the 64-byte block and the 1 KiB
  chunk boundaries). }
unit pjablake3;

{$I pja.inc}
{$ifopt R-}{$fatal pjablake3: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjablake3: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

type
  THash16 = array[0..15] of Byte;

  { Incremental: Init, Update as many times as needed, Final. }
  TBlake3 = record
  private
    cv: array[0..7] of LongWord;          { the current chunk's chaining value }
    block: array[0..63] of Byte;
    blockLen: Integer;
    blocksDone: Integer;                  { blocks of the current chunk already compressed }
    chunk: QWord;                         { the current chunk's number }
    stack: array[0..53] of array[0..7] of LongWord;   { 2^54 chunks are 2^64 bytes }
    depth: Integer;
    procedure FinishChunk;
  public
    procedure Init;
    procedure Update(const data; len: SizeInt);
    function Final: THash16;
  end;

function Blake3_128(const a: TBytes): THash16;
{ The hash of a[aFirst..aFirst+aLen) followed by b[bFirst..bFirst+bLen). }
function Blake3_128(const a: TBytes; aFirst, aLen: SizeInt;
                    const b: TBytes; bFirst, bLen: SizeInt): THash16;

implementation

const
  IV: array[0..7] of LongWord = ($6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
                                 $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19);
  MSG_PERMUTATION: array[0..15] of Integer = (2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8);
  CHUNK_START = 1;
  CHUNK_END = 2;
  PARENT = 4;
  ROOT = 8;
  CHUNK_LEN = 1024;

type
  TWords16 = array[0..15] of LongWord;
  TCv = array[0..7] of LongWord;

{ The arithmetic of the hash is modulo 2^32: wrapping is the algorithm, not
  a mistake to catch. }
{$push}{$Q-}{$R-}
procedure G(var s: TWords16; a, b, c, d: Integer; mx, my: LongWord); inline;
begin
  s[a] := s[a] + s[b] + mx; s[d] := RorDWord(s[d] xor s[a], 16);
  s[c] := s[c] + s[d];      s[b] := RorDWord(s[b] xor s[c], 12);
  s[a] := s[a] + s[b] + my; s[d] := RorDWord(s[d] xor s[a], 8);
  s[c] := s[c] + s[d];      s[b] := RorDWord(s[b] xor s[c], 7);
end;

{ The compression function: the full 16-word state. }
procedure Compress(const cv: TCv; const blockBytes; counter: QWord; blockLen, flags: LongWord;
                   out s: TWords16);
var m, t: TWords16; i, r: Integer; p: PByte;
begin
  p := @blockBytes;
  for i := 0 to 15 do
    m[i] := LongWord(p[4 * i]) or (LongWord(p[4 * i + 1]) shl 8) or
            (LongWord(p[4 * i + 2]) shl 16) or (LongWord(p[4 * i + 3]) shl 24);
  for i := 0 to 7 do s[i] := cv[i];
  s[8] := IV[0]; s[9] := IV[1]; s[10] := IV[2]; s[11] := IV[3];
  s[12] := LongWord(counter); s[13] := LongWord(counter shr 32);
  s[14] := blockLen; s[15] := flags;
  for r := 0 to 6 do begin
    G(s, 0, 4, 8, 12, m[0], m[1]);
    G(s, 1, 5, 9, 13, m[2], m[3]);
    G(s, 2, 6, 10, 14, m[4], m[5]);
    G(s, 3, 7, 11, 15, m[6], m[7]);
    G(s, 0, 5, 10, 15, m[8], m[9]);
    G(s, 1, 6, 11, 12, m[10], m[11]);
    G(s, 2, 7, 8, 13, m[12], m[13]);
    G(s, 3, 4, 9, 14, m[14], m[15]);
    if r < 6 then begin
      for i := 0 to 15 do t[i] := m[MSG_PERMUTATION[i]];
      m := t;
    end;
  end;
  for i := 0 to 7 do begin
    s[i] := s[i] xor s[i + 8];
    s[i + 8] := s[i + 8] xor cv[i];
  end;
end;
{$pop}

procedure CompressCv(var cv: TCv; const blockBytes; counter: QWord; blockLen, flags: LongWord);
var s: TWords16; i: Integer;
begin
  Compress(cv, blockBytes, counter, blockLen, flags, s);
  for i := 0 to 7 do cv[i] := s[i];
end;

{ The block of a parent node: the two children's chaining values. }
procedure ParentBlock(const left, right: TCv; out b: TWords16);
var i: Integer;
begin
  for i := 0 to 7 do begin b[i] := NtoLE(left[i]); b[i + 8] := NtoLE(right[i]); end;
end;

procedure TBlake3.Init;
var i: Integer;
begin
  for i := 0 to 7 do cv[i] := IV[i];
  FillChar(block, SizeOf(block), 0);
  blockLen := 0; blocksDone := 0; chunk := 0; depth := 0;
end;

{ The current chunk is full and more input follows: its chaining value goes
  into the tree, merging every pair of subtrees that is now complete. }
procedure TBlake3.FinishChunk;
var c: TCv; flags: LongWord; total: QWord; b: TWords16; i: Integer;
begin
  for i := 0 to 7 do c[i] := cv[i];
  flags := CHUNK_END;
  if blocksDone = 0 then flags := flags or CHUNK_START;
  CompressCv(c, block, chunk, blockLen, flags);
  Inc(chunk);
  total := chunk;
  while total and 1 = 0 do begin
    Dec(depth);
    ParentBlock(TCv(stack[depth]), c, b);
    for i := 0 to 7 do c[i] := IV[i];
    CompressCv(c, b, 0, 64, PARENT);
    total := total shr 1;
  end;
  for i := 0 to 7 do stack[depth][i] := c[i];
  Inc(depth);
  for i := 0 to 7 do cv[i] := IV[i];
  FillChar(block, SizeOf(block), 0);
  blockLen := 0; blocksDone := 0;
end;

procedure TBlake3.Update(const data; len: SizeInt);
var p: PByte; take: SizeInt; flags: LongWord;
begin
  p := @data;
  while len > 0 do begin
    { a full block is only compressed when more input follows: the last
      block of the last chunk has to wait for its CHUNK_END and ROOT }
    if blockLen = 64 then begin
      if blocksDone = CHUNK_LEN div 64 - 1 then FinishChunk
      else begin
        if blocksDone = 0 then flags := CHUNK_START else flags := 0;
        CompressCv(TCv(cv), block, chunk, 64, flags);
        Inc(blocksDone);
        FillChar(block, SizeOf(block), 0);
        blockLen := 0;
      end;
    end;
    take := 64 - blockLen;
    if take > len then take := len;
    Move(p^, block[blockLen], take);
    Inc(blockLen, take); Inc(p, take); Dec(len, take);
  end;
end;

function TBlake3.Final: THash16;
var c: TCv; blk: TWords16; counter: QWord; blen, flags: LongWord; s: TWords16; i: Integer;
begin
  { the output node: the last chunk's last block, unless there are parents }
  for i := 0 to 7 do c[i] := cv[i];
  Move(block, blk, 64);
  counter := chunk; blen := blockLen;
  flags := CHUNK_END;
  if blocksDone = 0 then flags := flags or CHUNK_START;
  while depth > 0 do begin
    { this node becomes the right child of the one below it on the stack }
    Compress(c, blk, counter, blen, flags, s);
    for i := 0 to 7 do c[i] := s[i];
    Dec(depth);
    ParentBlock(TCv(stack[depth]), c, blk);
    for i := 0 to 7 do c[i] := IV[i];
    counter := 0; blen := 64; flags := PARENT;
  end;
  Compress(c, blk, counter, blen, flags or ROOT, s);
  for i := 0 to 3 do begin
    Result[4 * i] := Byte(s[i]); Result[4 * i + 1] := Byte(s[i] shr 8);
    Result[4 * i + 2] := Byte(s[i] shr 16); Result[4 * i + 3] := Byte(s[i] shr 24);
  end;
end;

function Blake3_128(const a: TBytes): THash16;
begin
  Result := Blake3_128(a, 0, Length(a), nil, 0, 0);
end;

function Blake3_128(const a: TBytes; aFirst, aLen: SizeInt;
                    const b: TBytes; bFirst, bLen: SizeInt): THash16;
var h: TBlake3;
begin
  if (aFirst < 0) or (aLen < 0) or (aFirst + aLen > Length(a)) or
     (bFirst < 0) or (bLen < 0) or (bFirst + bLen > Length(b)) then
    raise ERangeError.Create('Blake3_128: range outside the buffer');
  h.Init;
  if aLen > 0 then h.Update(a[aFirst], aLen);
  if bLen > 0 then h.Update(b[bFirst], bLen);
  Result := h.Final;
end;

end.

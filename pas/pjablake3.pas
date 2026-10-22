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
{ The compression function: the full 16-word state. Unrolled, the message
  schedule written out, every word a local: the compiler keeps what it can
  in registers. (A loop over arrays that permutes the message ran at 28
  cycles a byte; this one at a fraction of that.) }
procedure Compress(const cv: TCv; const blockBytes; counter: QWord; blockLen, flags: LongWord;
                   out s: TWords16);
var m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15: LongWord;
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: LongWord;
    p: PByte;
begin
  p := @blockBytes;
  m0 := LEtoN(PLongWord(p)[0]);
  m1 := LEtoN(PLongWord(p)[1]);
  m2 := LEtoN(PLongWord(p)[2]);
  m3 := LEtoN(PLongWord(p)[3]);
  m4 := LEtoN(PLongWord(p)[4]);
  m5 := LEtoN(PLongWord(p)[5]);
  m6 := LEtoN(PLongWord(p)[6]);
  m7 := LEtoN(PLongWord(p)[7]);
  m8 := LEtoN(PLongWord(p)[8]);
  m9 := LEtoN(PLongWord(p)[9]);
  m10 := LEtoN(PLongWord(p)[10]);
  m11 := LEtoN(PLongWord(p)[11]);
  m12 := LEtoN(PLongWord(p)[12]);
  m13 := LEtoN(PLongWord(p)[13]);
  m14 := LEtoN(PLongWord(p)[14]);
  m15 := LEtoN(PLongWord(p)[15]);
  s0 := cv[0]; s1 := cv[1]; s2 := cv[2]; s3 := cv[3];
  s4 := cv[4]; s5 := cv[5]; s6 := cv[6]; s7 := cv[7];
  s8 := IV[0]; s9 := IV[1]; s10 := IV[2]; s11 := IV[3];
  s12 := LongWord(counter); s13 := LongWord(counter shr 32);
  s14 := blockLen; s15 := flags;
    { round 1 }
    s0 := s0 + s4 + m0; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m1; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m2; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m3; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m4; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m5; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m6; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m7; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m8; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m9; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m10; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m11; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m12; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m13; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m14; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m15; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 2 }
    s0 := s0 + s4 + m2; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m6; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m3; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m10; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m7; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m0; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m4; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m13; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m1; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m11; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m12; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m5; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m9; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m14; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m15; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m8; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 3 }
    s0 := s0 + s4 + m3; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m4; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m10; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m12; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m13; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m2; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m7; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m14; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m6; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m5; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m9; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m0; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m11; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m15; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m8; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m1; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 4 }
    s0 := s0 + s4 + m10; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m7; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m12; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m9; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m14; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m3; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m13; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m15; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m4; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m0; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m11; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m2; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m5; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m8; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m1; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m6; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 5 }
    s0 := s0 + s4 + m12; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m13; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m9; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m11; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m15; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m10; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m14; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m8; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m7; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m2; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m5; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m3; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m0; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m1; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m6; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m4; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 6 }
    s0 := s0 + s4 + m9; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m14; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m11; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m5; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m8; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m12; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m15; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m1; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m13; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m3; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m0; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m10; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m2; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m6; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m4; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m7; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
    { round 7 }
    s0 := s0 + s4 + m11; s12 := RorDWord(s12 xor s0, 16); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 12);
    s0 := s0 + s4 + m15; s12 := RorDWord(s12 xor s0, 8); s8 := s8 + s12; s4 := RorDWord(s4 xor s8, 7);
    s1 := s1 + s5 + m5; s13 := RorDWord(s13 xor s1, 16); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 12);
    s1 := s1 + s5 + m0; s13 := RorDWord(s13 xor s1, 8); s9 := s9 + s13; s5 := RorDWord(s5 xor s9, 7);
    s2 := s2 + s6 + m1; s14 := RorDWord(s14 xor s2, 16); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 12);
    s2 := s2 + s6 + m9; s14 := RorDWord(s14 xor s2, 8); s10 := s10 + s14; s6 := RorDWord(s6 xor s10, 7);
    s3 := s3 + s7 + m8; s15 := RorDWord(s15 xor s3, 16); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 12);
    s3 := s3 + s7 + m6; s15 := RorDWord(s15 xor s3, 8); s11 := s11 + s15; s7 := RorDWord(s7 xor s11, 7);
    s0 := s0 + s5 + m14; s15 := RorDWord(s15 xor s0, 16); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 12);
    s0 := s0 + s5 + m10; s15 := RorDWord(s15 xor s0, 8); s10 := s10 + s15; s5 := RorDWord(s5 xor s10, 7);
    s1 := s1 + s6 + m2; s12 := RorDWord(s12 xor s1, 16); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 12);
    s1 := s1 + s6 + m12; s12 := RorDWord(s12 xor s1, 8); s11 := s11 + s12; s6 := RorDWord(s6 xor s11, 7);
    s2 := s2 + s7 + m3; s13 := RorDWord(s13 xor s2, 16); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 12);
    s2 := s2 + s7 + m4; s13 := RorDWord(s13 xor s2, 8); s8 := s8 + s13; s7 := RorDWord(s7 xor s8, 7);
    s3 := s3 + s4 + m7; s14 := RorDWord(s14 xor s3, 16); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 12);
    s3 := s3 + s4 + m13; s14 := RorDWord(s14 xor s3, 8); s9 := s9 + s14; s4 := RorDWord(s4 xor s9, 7);
  s[0] := s0 xor s8; s[1] := s1 xor s9; s[2] := s2 xor s10; s[3] := s3 xor s11;
  s[4] := s4 xor s12; s[5] := s5 xor s13; s[6] := s6 xor s14; s[7] := s7 xor s15;
  s[8] := s8 xor cv[0]; s[9] := s9 xor cv[1]; s[10] := s10 xor cv[2]; s[11] := s11 xor cv[3];
  s[12] := s12 xor cv[4]; s[13] := s13 xor cv[5]; s[14] := s14 xor cv[6]; s[15] := s15 xor cv[7];
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

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
  TCvWords = array[0..7] of LongWord;

  { Incremental: Init, Update as many times as needed, Final. }
  PBlake3 = ^TBlake3;
  TBlake3 = record
  private
    cv: array[0..7] of LongWord;          { the current chunk's chaining value }
    block: array[0..63] of Byte;
    blockLen: Integer;
    blocksDone: Integer;                  { blocks of the current chunk already compressed }
    chunk: QWord;                         { the current chunk's number }
    stack: array[0..53] of array[0..7] of LongWord;   { 2^54 chunks are 2^64 bytes }
    depth: Integer;
    kcv: array[0..7] of LongWord;         { the key: IV, or the key's words, or the context's hash }
    bflags: LongWord;                     { KEYED_HASH, DERIVE_KEY_MATERIAL, or 0 }
    procedure FinishChunk;
    procedure PushCv(const c: TCvWords);
  public
    procedure Init;
    { keyed hash (a MAC): key is 32 bytes }
    procedure InitKeyed(const key; keyLen: SizeInt);
    { derive_key: context is the application's context string (UTF-8), then the key material goes
      through Update; FinalXof (32 bytes usually) is the derived key }
    procedure InitDeriveKey(const context; contextLen: SizeInt);
    procedure Update(const data; len: SizeInt);
    function Final: THash16;
    { any length of output (BLAKE3's XOF); the first 16 bytes are Final's }
    procedure FinalXof(out outp; outLen: SizeInt);
    { for threads: true when the state is at a chunk's start in the plain hash mode, so that chaining
      values computed elsewhere (Blake3ChunkCv / Blake3Chunks) can be taken in }
    function CanTakeChunkCvs: Boolean;
    { when more input is certain to follow, a chunk whose last block is waiting can be closed: this does it,
      so that the state is at a chunk start (a block waits for its CHUNK_END only if it may be the last) }
    procedure FlushPending;
    function ChunkIndex: QWord;           { the number of the chunk that comes next }
    { the chaining values (8 words each) of the next count whole chunks, which must not be the input's
      last: more input has to follow, or the last chunk has to be given through Update }
    procedure AddChunkCvs(const cvs; count: SizeInt);
    { the same for count subtrees of 2^g chunks each (their chaining values, as Blake3SubtreeCvs makes them);
      the state must be at a chunk start whose number is a multiple of 2^g }
    procedure AddSubtreeCvs(const cvs; count: SizeInt; g: Integer);
  end;

type
  { n full chunks at input, the first numbered counter, none of them the
    last of the input: their chaining values, 8 words each, into cv }
  TBlake3Chunks = procedure(input: PByte; n: SizeInt; counter: QWord; cv: PLongWord); cdecl;
var
  { set by pjav7 (pjasysc.c, several chunks at once); nil: this unit's own
    compression function, chunk by chunk. The same hash either way }
  Blake3Chunks: TBlake3Chunks = nil;

{ the chaining value of one whole chunk (1024 bytes at p), number counter, plain hash mode }
procedure Blake3ChunkCv(p: PByte; counter: QWord; out cv: TCvWords);
{ cvs holds 2^g chunk chaining values (8 words each); they are merged pairwise into the subtree's one, left in cvs[0..7] }
procedure Blake3MergeCvs(cvs: PLongWord; g: Integer);

function Blake3_128(const a: TBytes): THash16;
{ The hash of a[aFirst..aFirst+aLen) followed by b[bFirst..bFirst+bLen). }
function Blake3_128(const a: TBytes; aFirst, aLen: SizeInt;
                    const b: TBytes; bFirst, bLen: SizeInt): THash16;

implementation

const
  IV: array[0..7] of LongWord = ($6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
                                 $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19);
  KEYED_HASH = 16;
  DERIVE_KEY_CONTEXT = 32;
  DERIVE_KEY_MATERIAL = 64;
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
  for i := 0 to 7 do begin kcv[i] := IV[i]; cv[i] := IV[i]; end;
  bflags := 0;
  FillChar(block, SizeOf(block), 0);
  blockLen := 0; blocksDone := 0; chunk := 0; depth := 0;
end;

procedure TBlake3.InitKeyed(const key; keyLen: SizeInt);
var i: Integer; p: PByte;
begin
  if keyLen <> 32 then raise ERangeError.Create('InitKeyed: the key is 32 bytes');
  Init; p := @key;
  for i := 0 to 7 do begin
    kcv[i] := LEtoN(PLongWord(p)[i]); cv[i] := kcv[i];
  end;
  bflags := KEYED_HASH;
end;

procedure TBlake3.InitDeriveKey(const context; contextLen: SizeInt);
var h: TBlake3; k: array[0..31] of Byte; i: Integer;
begin
  if contextLen < 0 then raise ERangeError.Create('InitDeriveKey: negative length');
  h.Init; h.bflags := DERIVE_KEY_CONTEXT;
  if contextLen > 0 then h.Update(context, contextLen);
  h.FinalXof(k, 32);
  Init;
  for i := 0 to 7 do begin
    kcv[i] := LEtoN(PLongWord(@k[0])[i]); cv[i] := kcv[i];
  end;
  bflags := DERIVE_KEY_MATERIAL;
end;

{ The current chunk is full and more input follows: its chaining value goes
  into the tree, merging every pair of subtrees that is now complete. }
procedure TBlake3.FinishChunk;
var c: TCv; flags: LongWord; i: Integer;
begin
  for i := 0 to 7 do c[i] := cv[i];
  flags := CHUNK_END or bflags;
  if blocksDone = 0 then flags := flags or CHUNK_START;
  CompressCv(c, block, chunk, blockLen, flags);
  PushCv(TCvWords(c));
  for i := 0 to 7 do cv[i] := kcv[i];
  FillChar(block, SizeOf(block), 0);
  blockLen := 0; blocksDone := 0;
end;

{ A finished chunk's chaining value into the tree, merging every pair of
  subtrees that is now complete. }
procedure TBlake3.PushCv(const c: TCvWords);
var x: TCv; total: QWord; b: TWords16; i: Integer;
begin
  for i := 0 to 7 do x[i] := c[i];
  Inc(chunk);
  total := chunk;
  while total and 1 = 0 do begin
    Dec(depth);
    ParentBlock(TCv(stack[depth]), x, b);
    for i := 0 to 7 do x[i] := kcv[i];
    CompressCv(x, b, 0, 64, PARENT or bflags);
    total := total shr 1;
  end;
  for i := 0 to 7 do stack[depth][i] := x[i];
  Inc(depth);
end;

procedure TBlake3.Update(const data; len: SizeInt);
var p: PByte; take, k, i: SizeInt; flags: LongWord; cvs: array[0..15] of TCvWords;
begin
  p := @data;
  while len > 0 do begin
    { a full block is only compressed (here, at the top, so that a chunk's end left
      pending by the previous call does not keep us off the fast path below) when more input follows: the last
      block of the last chunk has to wait for its CHUNK_END and ROOT }
    if blockLen = 64 then begin
      if blocksDone = CHUNK_LEN div 64 - 1 then FinishChunk
      else begin
        if blocksDone = 0 then flags := CHUNK_START or bflags else flags := bflags;
        CompressCv(TCv(cv), block, chunk, 64, flags);
        Inc(blocksDone);
        FillChar(block, SizeOf(block), 0);
        blockLen := 0;
      end;
    end;
    { at a chunk's start with more than a chunk to come: whole chunks at
      once through Blake3Chunks, all but the input's last one }
    if (blockLen = 0) and (blocksDone = 0) and (len > CHUNK_LEN) and Assigned(Blake3Chunks) and (bflags = 0) then begin
      k := (len - 1) div CHUNK_LEN;
      if k > Length(cvs) then k := Length(cvs);
      Blake3Chunks(p, k, chunk, @cvs[0][0]);
      for i := 0 to k - 1 do PushCv(cvs[i]);
      Inc(p, k * CHUNK_LEN); Dec(len, k * CHUNK_LEN);
      Continue;
    end;
    take := 64 - blockLen;
    if take > len then take := len;
    Move(p^, block[blockLen], take);
    Inc(blockLen, take); Inc(p, take); Dec(len, take);
  end;
end;

procedure TBlake3.FinalXof(out outp; outLen: SizeInt);
var c: TCv; blk: TWords16; counter, ob: QWord; blen, flags: LongWord; s: TWords16; i: Integer;
    o: PByte; k: SizeInt; dp: Integer; t: array[0..63] of Byte;
begin
  if outLen < 0 then raise ERangeError.Create('FinalXof: negative length');
  { the output node: the last chunk's last block, unless there are parents }
  for i := 0 to 7 do c[i] := cv[i];
  Move(block, blk, 64);
  counter := chunk; blen := blockLen;
  flags := CHUNK_END or bflags;
  if blocksDone = 0 then flags := flags or CHUNK_START;
  dp := depth;   { local: the state is not consumed, Final and FinalXof can be called again }
  while dp > 0 do begin
    { this node becomes the right child of the one below it on the stack }
    Compress(c, blk, counter, blen, flags, s);
    for i := 0 to 7 do c[i] := s[i];
    Dec(dp);
    ParentBlock(TCv(stack[dp]), c, blk);
    for i := 0 to 7 do c[i] := kcv[i];
    counter := 0; blen := 64; flags := PARENT or bflags;
  end;
  { the root node, compressed again for each 64 bytes of output, its counter the block's number }
  o := @outp; ob := 0;
  while outLen > 0 do begin
    Compress(c, blk, ob, blen, flags or ROOT, s);
    for i := 0 to 15 do begin
      t[4 * i] := Byte(s[i]); t[4 * i + 1] := Byte(s[i] shr 8);
      t[4 * i + 2] := Byte(s[i] shr 16); t[4 * i + 3] := Byte(s[i] shr 24);
    end;
    k := 64; if k > outLen then k := outLen;
    Move(t, o^, k); Inc(o, k); Dec(outLen, k); Inc(ob);
  end;
end;

function TBlake3.CanTakeChunkCvs: Boolean;
begin Result := (blockLen = 0) and (blocksDone = 0) and (bflags = 0); end;

procedure TBlake3.FlushPending;
begin
  if (blockLen = 64) and (blocksDone = CHUNK_LEN div 64 - 1) then FinishChunk;
end;

function TBlake3.ChunkIndex: QWord;
begin Result := chunk; end;

procedure TBlake3.AddChunkCvs(const cvs; count: SizeInt);
var p: PLongWord; i: SizeInt; c: TCvWords; j: Integer;
begin
  if (count < 0) or not CanTakeChunkCvs then raise ERangeError.Create('AddChunkCvs: not at a chunk start');
  p := @cvs;
  for i := 0 to count - 1 do begin
    for j := 0 to 7 do c[j] := p[8 * i + j];
    PushCv(c);
  end;
end;

procedure TBlake3.AddSubtreeCvs(const cvs; count: SizeInt; g: Integer);
var p: PLongWord; i: SizeInt; x: TCv; b: TWords16; total: QWord; j: Integer;
begin
  if (count < 0) or (g < 0) or (g > 40) or not CanTakeChunkCvs or (chunk and ((QWord(1) shl g) - 1) <> 0) then
    raise ERangeError.Create('AddSubtreeCvs: not at a subtree start');
  p := @cvs;
  for i := 0 to count - 1 do begin
    for j := 0 to 7 do x[j] := p[8 * i + j];
    Inc(chunk, QWord(1) shl g);
    total := chunk shr g;
    while total and 1 = 0 do begin
      Dec(depth);
      ParentBlock(TCv(stack[depth]), x, b);
      for j := 0 to 7 do x[j] := kcv[j];
      CompressCv(x, b, 0, 64, PARENT or bflags);
      total := total shr 1;
    end;
    for j := 0 to 7 do stack[depth][j] := x[j];
    Inc(depth);
  end;
end;

procedure Blake3MergeCvs(cvs: PLongWord; g: Integer);
var lvl, n, i, j: Integer; x: TCv; b: TWords16;
begin
  n := 1 shl g;
  for lvl := 1 to g do begin
    n := n shr 1;
    for i := 0 to n - 1 do begin
      for j := 0 to 7 do begin b[j] := NtoLE(cvs[16 * i + j]); b[j + 8] := NtoLE(cvs[16 * i + 8 + j]); end;
      for j := 0 to 7 do x[j] := IV[j];
      CompressCv(x, b, 0, 64, PARENT);
      for j := 0 to 7 do cvs[8 * i + j] := x[j];
    end;
  end;
end;

procedure Blake3ChunkCv(p: PByte; counter: QWord; out cv: TCvWords);
var c: TCv; b: Integer; flags: LongWord; i: Integer;
begin
  for i := 0 to 7 do c[i] := IV[i];
  for b := 0 to CHUNK_LEN div 64 - 1 do begin
    flags := 0;
    if b = 0 then flags := CHUNK_START;
    if b = CHUNK_LEN div 64 - 1 then flags := flags or CHUNK_END;
    CompressCv(c, p[64 * b], counter, 64, flags);
  end;
  for i := 0 to 7 do cv[i] := c[i];
end;

function TBlake3.Final: THash16;
begin
  FinalXof(Result, SizeOf(Result));
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

/* pBLAKE3: BLAKE3 chunks, several at once (pjablake3.Blake3Chunks).
   Every full chunk that is not the last one of the input gets its chaining
   value here, many at a time with one chunk per 32-bit lane: 4 (SSE2 or
   NEON), 8 (AVX2) or 16 (AVX-512), chosen when first called by what the CPU
   (and the OS) can do; the rest one at a time. No memory taken, no library called. Plain path: build with
   -DB3_PLAIN (or no SSE2); both give the same words. */
#include <stdint.h>
/* AVX2 and AVX-512 are compiled whatever the baseline is (target attributes) and used only
   where cpuid and xgetbv say the CPU and the OS support them */
#if (defined(__x86_64__) || defined(__i386__)) && defined(__GNUC__) && !defined(B3_PLAIN) && !defined(B3_NO_AVX)
#include <immintrin.h>
#include <cpuid.h>
#define B3_X86WIDE 1
#endif
#if defined(__SSE2__) && !defined(B3_PLAIN)
#include <emmintrin.h>
#define B3_SSE2 1
#elif defined(__aarch64__) && defined(__ARM_NEON) && !defined(B3_PLAIN) && \
      (!defined(__BYTE_ORDER__) || __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#include <arm_neon.h>
#define B3_NEON 1
#endif
enum { B3_CHUNK_START = 1, B3_CHUNK_END = 2, B3_BLOCKS = 16 };

static const uint32_t B3IV[8] = {0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
                                 0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u};
static const uint8_t B3SCHED[7][16] = {
  {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
  {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
  {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
  {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
  {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
  {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
  {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13}};

static inline uint32_t b3rot(uint32_t w, int c) { return (w >> c) | (w << (32 - c)); }
static inline uint32_t b3load(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline void b3g(uint32_t *s, int a, int b, int c, int d, uint32_t x, uint32_t y) {
  s[a] = s[a] + s[b] + x; s[d] = b3rot(s[d] ^ s[a], 16); s[c] = s[c] + s[d]; s[b] = b3rot(s[b] ^ s[c], 12);
  s[a] = s[a] + s[b] + y; s[d] = b3rot(s[d] ^ s[a], 8); s[c] = s[c] + s[d]; s[b] = b3rot(s[b] ^ s[c], 7);
}

/* one chunk of 1024 bytes, number counter: its chaining value */
static void b3chunk(const uint8_t *in, uint64_t counter, uint32_t *cv) {
  uint32_t h[8], s[16], m[16];
  int i, b, r;
  for (i = 0; i < 8; i++) h[i] = B3IV[i];
  for (b = 0; b < B3_BLOCKS; b++) {
    for (i = 0; i < 16; i++) m[i] = b3load(in + 64 * b + 4 * i);
    for (i = 0; i < 8; i++) { s[i] = h[i]; s[i + 8] = B3IV[i]; }
    s[12] = (uint32_t)counter; s[13] = (uint32_t)(counter >> 32); s[14] = 64;
    s[15] = (b == 0 ? B3_CHUNK_START : 0) | (b == B3_BLOCKS - 1 ? B3_CHUNK_END : 0);
    for (r = 0; r < 7; r++) {
      const uint8_t *q = B3SCHED[r];
      b3g(s, 0, 4, 8, 12, m[q[0]], m[q[1]]);
      b3g(s, 1, 5, 9, 13, m[q[2]], m[q[3]]);
      b3g(s, 2, 6, 10, 14, m[q[4]], m[q[5]]);
      b3g(s, 3, 7, 11, 15, m[q[6]], m[q[7]]);
      b3g(s, 0, 5, 10, 15, m[q[8]], m[q[9]]);
      b3g(s, 1, 6, 11, 12, m[q[10]], m[q[11]]);
      b3g(s, 2, 7, 8, 13, m[q[12]], m[q[13]]);
      b3g(s, 3, 4, 9, 14, m[q[14]], m[q[15]]);
    }
    for (i = 0; i < 8; i++) h[i] = s[i] ^ s[i + 8];
  }
  for (i = 0; i < 8; i++) cv[i] = h[i];
}

#ifdef B3_SSE2
#define ROTV(x, c) _mm_or_si128(_mm_srli_epi32((x), (c)), _mm_slli_epi32((x), 32 - (c)))
static inline __m128i rot16v(__m128i x) { return _mm_shufflehi_epi16(_mm_shufflelo_epi16(x, 0xB1), 0xB1); }
static inline void g4(__m128i *v, int a, int b, int c, int d, __m128i x, __m128i y) {
  v[a] = _mm_add_epi32(_mm_add_epi32(v[a], v[b]), x); v[d] = rot16v(_mm_xor_si128(v[d], v[a]));
  v[c] = _mm_add_epi32(v[c], v[d]); v[b] = ROTV(_mm_xor_si128(v[b], v[c]), 12);
  v[a] = _mm_add_epi32(_mm_add_epi32(v[a], v[b]), y); v[d] = ROTV(_mm_xor_si128(v[d], v[a]), 8);
  v[c] = _mm_add_epi32(v[c], v[d]); v[b] = ROTV(_mm_xor_si128(v[b], v[c]), 7);
}
/* rows (one lane's 4 words each) to columns (one word of the 4 lanes each), and back */
static inline void transpose4(__m128i *a, __m128i *b, __m128i *c, __m128i *d) {
  __m128i ab0 = _mm_unpacklo_epi32(*a, *b), ab1 = _mm_unpackhi_epi32(*a, *b);
  __m128i cd0 = _mm_unpacklo_epi32(*c, *d), cd1 = _mm_unpackhi_epi32(*c, *d);
  *a = _mm_unpacklo_epi64(ab0, cd0); *b = _mm_unpackhi_epi64(ab0, cd0);
  *c = _mm_unpacklo_epi64(ab1, cd1); *d = _mm_unpackhi_epi64(ab1, cd1);
}
/* four consecutive chunks, numbers counter .. counter + 3 */
static void b3chunk4(const uint8_t *in, uint64_t counter, uint32_t *cv) {
  __m128i h[8], v[16], m[16];
  int i, b, r;
  uint64_t c0 = counter, c1 = counter + 1, c2 = counter + 2, c3 = counter + 3;
  __m128i lo = _mm_set_epi32((int)(uint32_t)c3, (int)(uint32_t)c2, (int)(uint32_t)c1, (int)(uint32_t)c0);
  __m128i hi = _mm_set_epi32((int)(uint32_t)(c3 >> 32), (int)(uint32_t)(c2 >> 32), (int)(uint32_t)(c1 >> 32),
                             (int)(uint32_t)(c0 >> 32));
  for (i = 0; i < 8; i++) h[i] = _mm_set1_epi32((int)B3IV[i]);
  for (b = 0; b < B3_BLOCKS; b++) {
    for (i = 0; i < 4; i++) {
      const uint8_t *p = in + 64 * b + 16 * i;
      m[4 * i] = _mm_loadu_si128((const __m128i *)p);
      m[4 * i + 1] = _mm_loadu_si128((const __m128i *)(p + 1024));
      m[4 * i + 2] = _mm_loadu_si128((const __m128i *)(p + 2048));
      m[4 * i + 3] = _mm_loadu_si128((const __m128i *)(p + 3072));
      transpose4(&m[4 * i], &m[4 * i + 1], &m[4 * i + 2], &m[4 * i + 3]);
    }
    for (i = 0; i < 8; i++) v[i] = h[i];
    for (i = 0; i < 4; i++) v[i + 8] = _mm_set1_epi32((int)B3IV[i]);
    v[12] = lo; v[13] = hi; v[14] = _mm_set1_epi32(64);
    v[15] = _mm_set1_epi32((b == 0 ? B3_CHUNK_START : 0) | (b == B3_BLOCKS - 1 ? B3_CHUNK_END : 0));
    for (r = 0; r < 7; r++) {
      const uint8_t *q = B3SCHED[r];
      g4(v, 0, 4, 8, 12, m[q[0]], m[q[1]]);
      g4(v, 1, 5, 9, 13, m[q[2]], m[q[3]]);
      g4(v, 2, 6, 10, 14, m[q[4]], m[q[5]]);
      g4(v, 3, 7, 11, 15, m[q[6]], m[q[7]]);
      g4(v, 0, 5, 10, 15, m[q[8]], m[q[9]]);
      g4(v, 1, 6, 11, 12, m[q[10]], m[q[11]]);
      g4(v, 2, 7, 8, 13, m[q[12]], m[q[13]]);
      g4(v, 3, 4, 9, 14, m[q[14]], m[q[15]]);
    }
    for (i = 0; i < 8; i++) h[i] = _mm_xor_si128(v[i], v[i + 8]);
  }
  transpose4(&h[0], &h[1], &h[2], &h[3]);
  transpose4(&h[4], &h[5], &h[6], &h[7]);
  for (i = 0; i < 4; i++) {
    _mm_storeu_si128((__m128i *)(cv + 8 * i), h[i]);
    _mm_storeu_si128((__m128i *)(cv + 8 * i + 4), h[i + 4]);
  }
}
#endif

#ifdef B3_NEON
/* the same four-chunks-at-once as the SSE2 one: a vector's lane k is chunk k */
#define ROTN(x, c) vsriq_n_u32(vshlq_n_u32((x), 32 - (c)), (x), (c))
static inline uint32x4_t rot16n(uint32x4_t x) { return vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(x))); }
static inline void g4n(uint32x4_t *v, int a, int b, int c, int d, uint32x4_t x, uint32x4_t y) {
  v[a] = vaddq_u32(vaddq_u32(v[a], v[b]), x); v[d] = rot16n(veorq_u32(v[d], v[a]));
  v[c] = vaddq_u32(v[c], v[d]); v[b] = ROTN(veorq_u32(v[b], v[c]), 12);
  v[a] = vaddq_u32(vaddq_u32(v[a], v[b]), y); v[d] = ROTN(veorq_u32(v[d], v[a]), 8);
  v[c] = vaddq_u32(v[c], v[d]); v[b] = ROTN(veorq_u32(v[b], v[c]), 7);
}
static inline void transpose4n(uint32x4_t *a, uint32x4_t *b, uint32x4_t *c, uint32x4_t *d) {
  uint32x4_t t0 = vtrn1q_u32(*a, *b), t1 = vtrn2q_u32(*a, *b), t2 = vtrn1q_u32(*c, *d), t3 = vtrn2q_u32(*c, *d);
  *a = vreinterpretq_u32_u64(vtrn1q_u64(vreinterpretq_u64_u32(t0), vreinterpretq_u64_u32(t2)));
  *b = vreinterpretq_u32_u64(vtrn1q_u64(vreinterpretq_u64_u32(t1), vreinterpretq_u64_u32(t3)));
  *c = vreinterpretq_u32_u64(vtrn2q_u64(vreinterpretq_u64_u32(t0), vreinterpretq_u64_u32(t2)));
  *d = vreinterpretq_u32_u64(vtrn2q_u64(vreinterpretq_u64_u32(t1), vreinterpretq_u64_u32(t3)));
}
static inline uint32x4_t ld4n(const uint8_t *p) { return vreinterpretq_u32_u8(vld1q_u8(p)); }
/* four consecutive chunks, numbers counter .. counter + 3 */
static void b3chunk4(const uint8_t *in, uint64_t counter, uint32_t *cv) {
  uint32x4_t h[8], v[16], m[16];
  int i, b, r;
  uint32_t lw[4], hw[4];
  uint32x4_t lo, hi;
  for (i = 0; i < 4; i++) { lw[i] = (uint32_t)(counter + (uint64_t)i); hw[i] = (uint32_t)((counter + (uint64_t)i) >> 32); }
  lo = vld1q_u32(lw); hi = vld1q_u32(hw);
  for (i = 0; i < 8; i++) h[i] = vdupq_n_u32(B3IV[i]);
  for (b = 0; b < B3_BLOCKS; b++) {
    for (i = 0; i < 4; i++) {
      const uint8_t *p = in + 64 * b + 16 * i;
      m[4 * i] = ld4n(p);
      m[4 * i + 1] = ld4n(p + 1024);
      m[4 * i + 2] = ld4n(p + 2048);
      m[4 * i + 3] = ld4n(p + 3072);
      transpose4n(&m[4 * i], &m[4 * i + 1], &m[4 * i + 2], &m[4 * i + 3]);
    }
    for (i = 0; i < 8; i++) v[i] = h[i];
    for (i = 0; i < 4; i++) v[i + 8] = vdupq_n_u32(B3IV[i]);
    v[12] = lo; v[13] = hi; v[14] = vdupq_n_u32(64);
    v[15] = vdupq_n_u32((b == 0 ? B3_CHUNK_START : 0) | (b == B3_BLOCKS - 1 ? B3_CHUNK_END : 0));
    for (r = 0; r < 7; r++) {
      const uint8_t *q = B3SCHED[r];
      g4n(v, 0, 4, 8, 12, m[q[0]], m[q[1]]);
      g4n(v, 1, 5, 9, 13, m[q[2]], m[q[3]]);
      g4n(v, 2, 6, 10, 14, m[q[4]], m[q[5]]);
      g4n(v, 3, 7, 11, 15, m[q[6]], m[q[7]]);
      g4n(v, 0, 5, 10, 15, m[q[8]], m[q[9]]);
      g4n(v, 1, 6, 11, 12, m[q[10]], m[q[11]]);
      g4n(v, 2, 7, 8, 13, m[q[12]], m[q[13]]);
      g4n(v, 3, 4, 9, 14, m[q[14]], m[q[15]]);
    }
    for (i = 0; i < 8; i++) h[i] = veorq_u32(v[i], v[i + 8]);
  }
  transpose4n(&h[0], &h[1], &h[2], &h[3]);
  transpose4n(&h[4], &h[5], &h[6], &h[7]);
  for (i = 0; i < 4; i++) {
    vst1q_u32(cv + 8 * i, h[i]);
    vst1q_u32(cv + 8 * i + 4, h[i + 4]);
  }
}
#endif


#ifdef B3_X86WIDE
#define T_AVX2 __attribute__((target("avx2")))
#define T_AVX512 __attribute__((target("avx512f,avx2")))

/* ---- AVX2: eight chunks at once ---- */
#define ROT8V(x, c) _mm256_or_si256(_mm256_srli_epi32((x), (c)), _mm256_slli_epi32((x), 32 - (c)))
T_AVX2 static inline __m256i rotb2(__m256i x, int s) {
  /* rotate by whole bytes (16 and 8 bits) with a byte shuffle */
  const __m256i m16 = _mm256_setr_epi8(2,3,0,1,6,7,4,5,10,11,8,9,14,15,12,13, 2,3,0,1,6,7,4,5,10,11,8,9,14,15,12,13);
  const __m256i m8 = _mm256_setr_epi8(1,2,3,0,5,6,7,4,9,10,11,8,13,14,15,12, 1,2,3,0,5,6,7,4,9,10,11,8,13,14,15,12);
  return _mm256_shuffle_epi8(x, s == 16 ? m16 : m8);
}
T_AVX2 static inline void g8(__m256i *v, int a, int b, int c, int d, __m256i x, __m256i y) {
  v[a] = _mm256_add_epi32(_mm256_add_epi32(v[a], v[b]), x); v[d] = rotb2(_mm256_xor_si256(v[d], v[a]), 16);
  v[c] = _mm256_add_epi32(v[c], v[d]); v[b] = ROT8V(_mm256_xor_si256(v[b], v[c]), 12);
  v[a] = _mm256_add_epi32(_mm256_add_epi32(v[a], v[b]), y); v[d] = rotb2(_mm256_xor_si256(v[d], v[a]), 8);
  v[c] = _mm256_add_epi32(v[c], v[d]); v[b] = ROT8V(_mm256_xor_si256(v[b], v[c]), 7);
}
/* eight rows of eight words to eight columns */
T_AVX2 static inline void transpose8(__m256i *r) {
  __m256i t0 = _mm256_unpacklo_epi32(r[0], r[1]), t1 = _mm256_unpackhi_epi32(r[0], r[1]);
  __m256i t2 = _mm256_unpacklo_epi32(r[2], r[3]), t3 = _mm256_unpackhi_epi32(r[2], r[3]);
  __m256i t4 = _mm256_unpacklo_epi32(r[4], r[5]), t5 = _mm256_unpackhi_epi32(r[4], r[5]);
  __m256i t6 = _mm256_unpacklo_epi32(r[6], r[7]), t7 = _mm256_unpackhi_epi32(r[6], r[7]);
  __m256i u0 = _mm256_unpacklo_epi64(t0, t2), u1 = _mm256_unpackhi_epi64(t0, t2);
  __m256i u2 = _mm256_unpacklo_epi64(t1, t3), u3 = _mm256_unpackhi_epi64(t1, t3);
  __m256i u4 = _mm256_unpacklo_epi64(t4, t6), u5 = _mm256_unpackhi_epi64(t4, t6);
  __m256i u6 = _mm256_unpacklo_epi64(t5, t7), u7 = _mm256_unpackhi_epi64(t5, t7);
  r[0] = _mm256_permute2x128_si256(u0, u4, 0x20); r[1] = _mm256_permute2x128_si256(u1, u5, 0x20);
  r[2] = _mm256_permute2x128_si256(u2, u6, 0x20); r[3] = _mm256_permute2x128_si256(u3, u7, 0x20);
  r[4] = _mm256_permute2x128_si256(u0, u4, 0x31); r[5] = _mm256_permute2x128_si256(u1, u5, 0x31);
  r[6] = _mm256_permute2x128_si256(u2, u6, 0x31); r[7] = _mm256_permute2x128_si256(u3, u7, 0x31);
}
T_AVX2 static void b3chunk8(const uint8_t *in, uint64_t counter, uint32_t *cv) {
  __m256i h[8], v[16], m[16], t[8];
  int i, b, r, l;
  uint32_t lw[8], hw[8];
  __m256i lo, hi;
  for (l = 0; l < 8; l++) { lw[l] = (uint32_t)(counter + (uint64_t)l); hw[l] = (uint32_t)((counter + (uint64_t)l) >> 32); }
  lo = _mm256_loadu_si256((const __m256i *)lw); hi = _mm256_loadu_si256((const __m256i *)hw);
  for (i = 0; i < 8; i++) h[i] = _mm256_set1_epi32((int)B3IV[i]);
  for (b = 0; b < B3_BLOCKS; b++) {
    for (l = 0; l < 8; l++) t[l] = _mm256_loadu_si256((const __m256i *)(in + 1024 * l + 64 * b));
    transpose8(t); for (i = 0; i < 8; i++) m[i] = t[i];
    for (l = 0; l < 8; l++) t[l] = _mm256_loadu_si256((const __m256i *)(in + 1024 * l + 64 * b + 32));
    transpose8(t); for (i = 0; i < 8; i++) m[8 + i] = t[i];
    for (i = 0; i < 8; i++) v[i] = h[i];
    for (i = 0; i < 4; i++) v[i + 8] = _mm256_set1_epi32((int)B3IV[i]);
    v[12] = lo; v[13] = hi; v[14] = _mm256_set1_epi32(64);
    v[15] = _mm256_set1_epi32((b == 0 ? B3_CHUNK_START : 0) | (b == B3_BLOCKS - 1 ? B3_CHUNK_END : 0));
    for (r = 0; r < 7; r++) {
      const uint8_t *q = B3SCHED[r];
      g8(v, 0, 4, 8, 12, m[q[0]], m[q[1]]);
      g8(v, 1, 5, 9, 13, m[q[2]], m[q[3]]);
      g8(v, 2, 6, 10, 14, m[q[4]], m[q[5]]);
      g8(v, 3, 7, 11, 15, m[q[6]], m[q[7]]);
      g8(v, 0, 5, 10, 15, m[q[8]], m[q[9]]);
      g8(v, 1, 6, 11, 12, m[q[10]], m[q[11]]);
      g8(v, 2, 7, 8, 13, m[q[12]], m[q[13]]);
      g8(v, 3, 4, 9, 14, m[q[14]], m[q[15]]);
    }
    for (i = 0; i < 8; i++) h[i] = _mm256_xor_si256(v[i], v[i + 8]);
  }
  transpose8(h);
  for (l = 0; l < 8; l++) _mm256_storeu_si256((__m256i *)(cv + 8 * l), h[l]);
}

/* ---- AVX-512F: sixteen chunks at once ---- */
T_AVX512 static inline void g16(__m512i *v, int a, int b, int c, int d, __m512i x, __m512i y) {
  v[a] = _mm512_add_epi32(_mm512_add_epi32(v[a], v[b]), x); v[d] = _mm512_ror_epi32(_mm512_xor_si512(v[d], v[a]), 16);
  v[c] = _mm512_add_epi32(v[c], v[d]); v[b] = _mm512_ror_epi32(_mm512_xor_si512(v[b], v[c]), 12);
  v[a] = _mm512_add_epi32(_mm512_add_epi32(v[a], v[b]), y); v[d] = _mm512_ror_epi32(_mm512_xor_si512(v[d], v[a]), 8);
  v[c] = _mm512_add_epi32(v[c], v[d]); v[b] = _mm512_ror_epi32(_mm512_xor_si512(v[b], v[c]), 7);
}
/* sixteen rows of sixteen words to sixteen columns */
T_AVX512 static inline void transpose16(__m512i *r) {
  __m512i t[16], u[16], a0, a1, b0, b1;
  int i, k;
  for (i = 0; i < 8; i++) { t[2 * i] = _mm512_unpacklo_epi32(r[2 * i], r[2 * i + 1]); t[2 * i + 1] = _mm512_unpackhi_epi32(r[2 * i], r[2 * i + 1]); }
  for (i = 0; i < 4; i++) {
    u[4 * i] = _mm512_unpacklo_epi64(t[4 * i], t[4 * i + 2]); u[4 * i + 1] = _mm512_unpackhi_epi64(t[4 * i], t[4 * i + 2]);
    u[4 * i + 2] = _mm512_unpacklo_epi64(t[4 * i + 1], t[4 * i + 3]); u[4 * i + 3] = _mm512_unpackhi_epi64(t[4 * i + 1], t[4 * i + 3]);
  }
  for (k = 0; k < 4; k++) {
    a0 = _mm512_shuffle_i32x4(u[k], u[4 + k], 0x88); a1 = _mm512_shuffle_i32x4(u[k], u[4 + k], 0xDD);
    b0 = _mm512_shuffle_i32x4(u[8 + k], u[12 + k], 0x88); b1 = _mm512_shuffle_i32x4(u[8 + k], u[12 + k], 0xDD);
    r[k] = _mm512_shuffle_i32x4(a0, b0, 0x88); r[k + 4] = _mm512_shuffle_i32x4(a1, b1, 0x88);
    r[k + 8] = _mm512_shuffle_i32x4(a0, b0, 0xDD); r[k + 12] = _mm512_shuffle_i32x4(a1, b1, 0xDD);
  }
}
T_AVX512 static void b3chunk16(const uint8_t *in, uint64_t counter, uint32_t *cv) {
  __m512i h[8], v[16], m[16], t[16];
  int i, b, r, l;
  uint32_t lw[16], hw[16];
  __m512i lo, hi;
  for (l = 0; l < 16; l++) { lw[l] = (uint32_t)(counter + (uint64_t)l); hw[l] = (uint32_t)((counter + (uint64_t)l) >> 32); }
  lo = _mm512_loadu_si512((const void *)lw); hi = _mm512_loadu_si512((const void *)hw);
  for (i = 0; i < 8; i++) h[i] = _mm512_set1_epi32((int)B3IV[i]);
  for (b = 0; b < B3_BLOCKS; b++) {
    for (l = 0; l < 16; l++) t[l] = _mm512_loadu_si512((const void *)(in + 1024 * l + 64 * b));
    transpose16(t); for (i = 0; i < 16; i++) m[i] = t[i];
    for (i = 0; i < 8; i++) v[i] = h[i];
    for (i = 0; i < 4; i++) v[i + 8] = _mm512_set1_epi32((int)B3IV[i]);
    v[12] = lo; v[13] = hi; v[14] = _mm512_set1_epi32(64);
    v[15] = _mm512_set1_epi32((b == 0 ? B3_CHUNK_START : 0) | (b == B3_BLOCKS - 1 ? B3_CHUNK_END : 0));
    for (r = 0; r < 7; r++) {
      const uint8_t *q = B3SCHED[r];
      g16(v, 0, 4, 8, 12, m[q[0]], m[q[1]]);
      g16(v, 1, 5, 9, 13, m[q[2]], m[q[3]]);
      g16(v, 2, 6, 10, 14, m[q[4]], m[q[5]]);
      g16(v, 3, 7, 11, 15, m[q[6]], m[q[7]]);
      g16(v, 0, 5, 10, 15, m[q[8]], m[q[9]]);
      g16(v, 1, 6, 11, 12, m[q[10]], m[q[11]]);
      g16(v, 2, 7, 8, 13, m[q[12]], m[q[13]]);
      g16(v, 3, 4, 9, 14, m[q[14]], m[q[15]]);
    }
    for (i = 0; i < 8; i++) h[i] = _mm512_xor_si512(v[i], v[i + 8]);
  }
  for (i = 0; i < 8; i++) t[i] = h[i];
  for (i = 8; i < 16; i++) t[i] = _mm512_setzero_si512();
  transpose16(t);   /* t[c]: chunk c's eight words, then zeros */
  for (l = 0; l < 16; l++) _mm256_storeu_si256((__m256i *)(cv + 8 * l), _mm512_castsi512_si256(t[l]));
}

/* what this CPU and OS can do: 2 = AVX2, 3 = AVX-512F (and AVX2), 0 = neither */
static int b3_x86_wide_level(void) {
  unsigned a, b, c, d, lo, hi;
  if (!__get_cpuid_count(1, 0, &a, &b, &c, &d)) return 0;
  if (!(c & (1u << 27)) || !(c & (1u << 28))) return 0;            /* OSXSAVE, AVX */
  __asm__ volatile(".byte 0x0f,0x01,0xd0" : "=a"(lo), "=d"(hi) : "c"(0));   /* xgetbv(0) */
  if ((lo & 6) != 6) return 0;                                      /* the OS keeps XMM and YMM */
  if (__get_cpuid_max(0, 0) < 7) return 0;
  __get_cpuid_count(7, 0, &a, &b, &c, &d);
  if (!(b & (1u << 5))) return 0;                                   /* AVX2 */
  if ((b & (1u << 16)) && (lo & 0xE0) == 0xE0) return 3;            /* AVX-512F, opmask and ZMM state */
  return 2;
}
#endif

/* The widest path in use. pblake3_chunks_level(max) caps it for tests (0 = one chunk at a time, 1 = 4 at a
   time, 2 = AVX2, 3 = AVX-512) and returns what the CPU can do; (-1) just asks. */
static int b3_cap = 3, b3_detected = -1;
static int b3_detect(void) {
  if (b3_detected < 0) {
    int lv = 0;
#if defined(B3_SSE2) || defined(B3_NEON)
    lv = 1;
#endif
#ifdef B3_X86WIDE
    { int w = b3_x86_wide_level(); if (w > lv) lv = w; }
#endif
    b3_detected = lv;
  }
  return b3_detected;
}
int pblake3_chunks_level(int max) {
  int d = b3_detect();
  if (max >= 0) b3_cap = max;
  return d;
}

/* n full chunks at in, the first numbered counter: their chaining values,
   8 words each, into cv */
void pblake3_chunks(const uint8_t *in, intptr_t n, uint64_t counter, uint32_t *cv) {
  intptr_t k = 0;
  int lv = b3_detect();
  if (lv > b3_cap) lv = b3_cap;
#ifdef B3_X86WIDE
  if (lv >= 3) for (; k + 16 <= n; k += 16) b3chunk16(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
  if (lv >= 2) for (; k + 8 <= n; k += 8) b3chunk8(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
#endif
#if defined(B3_SSE2) || defined(B3_NEON)
  if (lv >= 1) for (; k + 4 <= n; k += 4) b3chunk4(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
#endif
  for (; k < n; k++) b3chunk(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
}

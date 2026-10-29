/* The C helpers of PJA around the model (pjav7c.c is the model): taken by
   pjav7.pas, which installs them in the Pascal units that can use them.
   Like pjav7c.c, this file takes no memory and calls no library.

   BLAKE3's chunks, several at once (pjablake3.Blake3Chunks): every full
   chunk that is not the last one of the input gets its chaining value
   here, four at a time in SSE2 (one chunk per 32-bit lane), the rest one
   at a time. A hash has one answer: the plain path (PJA_V7_PLAIN, or no
   SSE2) gives the same words, and tests/test_blake3 checks both against
   the official vectors. */
#include <stdint.h>
/* 64-bit bit scans without libgcc: on 32-bit targets gcc may call
   __ctzdi2 / __clzdi2 for the builtins on 64-bit operands, so there they
   are two 32-bit scans. x must not be 0. */
#if UINTPTR_MAX > 0xFFFFFFFFu
static inline int ctz64(uint64_t x) { return __builtin_ctzll(x); }
static inline int clz64(uint64_t x) { return __builtin_clzll(x); }
#else
static inline int ctz64(uint64_t x) {
  uint32_t lo = (uint32_t)x;
  return lo ? __builtin_ctz(lo) : 32 + __builtin_ctz((uint32_t)(x >> 32));
}
static inline int clz64(uint64_t x) {
  uint32_t hi = (uint32_t)(x >> 32);
  return hi ? __builtin_clz(hi) : 32 + __builtin_clz((uint32_t)x);
}
#endif
#if defined(__SSE2__) && !defined(PJA_V7_PLAIN)
#include <emmintrin.h>
#define B3_SSE2 1
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

/* n full chunks at in, the first numbered counter: their chaining values,
   8 words each, into cv */
void pjasys_b3chunks(const uint8_t *in, intptr_t n, uint64_t counter, uint32_t *cv) {
  intptr_t k = 0;
#ifdef B3_SSE2
  for (; k + 4 <= n; k += 4) b3chunk4(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
#endif
  for (; k < n; k++) b3chunk(in + 1024 * k, counter + (uint64_t)k, cv + 8 * k);
}

/* ---------- a sequential Huffman scan, written (pjajpeg.HuffEncodeScan) ----------

   pjajpeg.EncodeScan's work for a scan that is not progressive: the units
   in order, each block as EncodeBlock writes it (F.1.2: ZRL only before a
   nonzero coefficient, EOB if zeros are left), restarts, the padding. The
   bytes are the same whatever the drain policy: bits, then FF 00 stuffing.
   pjajpeg fills hencscan_t (its THuffEncScan), keeps every block inside its
   component, and does the scan itself when this one answers HE_FAIL (a
   symbol the table lacks: its position in the output is pjajpeg's to give).
   HE_ROOM: out has less than HE_UNIT_ROOM bytes left; the state is saved and
   the call goes on from there once pjajpeg has grown it. */
enum { HE_OK = 0, HE_FAIL = 1, HE_ROOM = 2 };
/* one MCU (at most 10 blocks of 64 codes of at most 32 bits, each byte
   maybe stuffed) and a restart marker */
#define HE_UNIT_ROOM 6144
/* pjajpeg's MAX_BE_LIMIT + 64 */
#define HE_BEBUF 4096

typedef struct {
  int16_t *coef; intptr_t bw, h, v;
  const uint16_t *dcCode, *acCode; const uint8_t *dcLen, *acLen;
  intptr_t predIdx;                     /* pjajpeg.IndexInScan of its component */
} hslot_t;
/* a table's symbol: (code << 5) | length, the code cut to its length (as
   pjajpeg's writer cuts it); 0 = not in the table */
typedef struct { uint32_t dc[256], ac[256]; } hetab_t;
/* The tables live in the caller's record, not on this stack: a frame of
   more than a page calls a stack probe on Windows (___chkstk_ms), which
   is libgcc's */
typedef struct {
  uint64_t acc;
  hslot_t slot[4];
  intptr_t nslot, unitsX, total, ri, padbit;
  uint8_t *out; intptr_t n, cap;
  intptr_t u, ux, uy, rst;
  intptr_t pred[4];
  intptr_t nacc;
  /* a progressive scan (progressive <> 0): its band and bits, and the EOB
     run and the correction bits waiting (pjajpeg.TProgState) */
  intptr_t progressive, ss, se, ah, al, maxEob, maxBe;
  intptr_t eobrun, be;
  uint8_t bebuf[HE_BEBUF];
  hetab_t tab[4];                       /* scratch: each slot's tables */
} hencscan_t;

typedef struct { uint8_t *o; intptr_t n; uint64_t acc; int nacc; } hw_t;

static inline void hw_byte(hw_t *w, uint32_t b) {
  w->o[w->n++] = (uint8_t)b;
  if (b == 0xFF) w->o[w->n++] = 0;
}
/* bits: len of them (at most 32), nothing above */
static inline void hw_bits(hw_t *w, uint64_t bits, int len) {
  w->acc = (w->acc << len) | bits;
  w->nacc += len;
  if (w->nacc >= 32) {
    uint32_t x = (uint32_t)(w->acc >> (w->nacc - 32));
    w->nacc -= 32;
    if ((((~x) - 0x01010101u) & x & 0x80808080u) == 0) {
      uint8_t *o = w->o + w->n;
      o[0] = (uint8_t)(x >> 24); o[1] = (uint8_t)(x >> 16); o[2] = (uint8_t)(x >> 8); o[3] = (uint8_t)x;
      w->n += 4;
    } else {
      hw_byte(w, x >> 24); hw_byte(w, (x >> 16) & 255); hw_byte(w, (x >> 8) & 255); hw_byte(w, x & 255);
    }
  }
}
static inline void hw_align(hw_t *w, intptr_t padbit) {
  int r = w->nacc & 7;
  if (r) hw_bits(w, padbit == 0 ? 0 : 0xFFu >> r, 8 - r);
  while (w->nacc >= 8) {
    w->nacc -= 8;
    hw_byte(w, (uint32_t)(w->acc >> w->nacc) & 255);
  }
  w->acc = 0;
}
static inline int hcat(int32_t v) {
  uint32_t a = v < 0 ? 0u - (uint32_t)v : (uint32_t)v;
  return a ? 32 - __builtin_clz(a) : 0;
}
/* a bit per coefficient of the block (zigzag order), set where it is not zero */
static inline uint64_t hnzmask(const int16_t *cf) {
#ifdef B3_SSE2
  const __m128i z = _mm_setzero_si128();
  uint64_t m = 0;
  for (int i = 0; i < 64; i += 16) {
    __m128i a = _mm_cmpeq_epi16(_mm_loadu_si128((const __m128i *)(cf + i)), z);
    __m128i b = _mm_cmpeq_epi16(_mm_loadu_si128((const __m128i *)(cf + i + 8)), z);
    m |= (uint64_t)(uint16_t)_mm_movemask_epi8(_mm_packs_epi16(a, b)) << i;
  }
  return ~m;
#else
  uint64_t m = 0;
  for (int i = 0; i < 64; i++) m |= (uint64_t)(cf[i] != 0) << i;
  return m;
#endif
}
static void hetab(hetab_t *e, const hslot_t *sl) {
  for (int i = 0; i < 256; i++) {
    uint32_t l = sl->dcLen[i], m = l >= 32 ? 0xFFFFFFFFu : (1u << l) - 1;
    e->dc[i] = l ? ((sl->dcCode[i] & m) << 5) | l : 0;
    l = sl->acLen[i]; m = l >= 32 ? 0xFFFFFFFFu : (1u << l) - 1;
    e->ac[i] = l ? ((sl->acCode[i] & m) << 5) | l : 0;
  }
}
static inline int hblock(hw_t *w, const int16_t *cf, const hetab_t *tb, intptr_t *pred) {
  int32_t v = cf[0], diff = v - (int32_t)*pred;
  int t = hcat(diff), last = 0;
  uint32_t e = tb->dc[t];
  uint64_t nz;
  *pred = v;
  if (e == 0) return 0;
  hw_bits(w, ((uint64_t)(e >> 5) << t) | (uint64_t)((uint32_t)(diff - (diff < 0)) & ((1u << t) - 1)),
          (int)(e & 31) + t);
  nz = hnzmask(cf) & ~(uint64_t)1;
  while (nz) {
    int k = ctz64(nz), r = k - last - 1;
    nz &= nz - 1;
    last = k;
    v = cf[k];
    while (r > 15) {
      e = tb->ac[0xF0];
      if (e == 0) return 0;
      hw_bits(w, e >> 5, (int)(e & 31));
      r -= 16;
    }
    t = hcat(v);
    e = tb->ac[(r << 4) | t];
    if (e == 0) return 0;
    hw_bits(w, ((uint64_t)(e >> 5) << t) | (uint64_t)((uint32_t)(v - (v < 0)) & ((1u << t) - 1)),
            (int)(e & 31) + t);
  }
  if (last < 63) {
    e = tb->ac[0];
    if (e == 0) return 0;
    hw_bits(w, e >> 5, (int)(e & 31));
  }
  return 1;
}

/* ---- progressive (G.1.2.2, as jcphuff.c writes it) ---- */
static inline int hp_flush(hw_t *w, hencscan_t *S, const hetab_t *tb) {
  int nb, k;
  uint32_t e;
  if (S->eobrun == 0) return 1;
  nb = hcat((int32_t)S->eobrun) - 1;
  if (nb > 14) return 0;
  e = tb->ac[nb << 4];
  if (e == 0) return 0;
  hw_bits(w, e >> 5, (int)(e & 31));
  if (nb > 0) hw_bits(w, (uint64_t)S->eobrun & ((1u << nb) - 1), nb);
  S->eobrun = 0;
  for (k = 0; k < S->be; k++) hw_bits(w, S->bebuf[k], 1);
  S->be = 0;
  return 1;
}
static inline int hp_dcfirst(hw_t *w, const int16_t *cf, const hetab_t *tb, intptr_t *pred, int al) {
  int32_t v = (int32_t)cf[0] >> al, diff = v - (int32_t)*pred;
  int t = hcat(diff);
  uint32_t e = tb->dc[t];
  *pred = v;
  if (e == 0) return 0;
  hw_bits(w, e >> 5, (int)(e & 31));
  if (t > 0) hw_bits(w, (uint32_t)(diff - (diff < 0)) & ((1u << t) - 1), t);
  return 1;
}
static int hp_acfirst(hw_t *w, const int16_t *cf, const hetab_t *tb, hencscan_t *S) {
  int k, r = 0, t, al = (int)S->al;
  uint32_t e;
  for (k = (int)S->ss; k <= (int)S->se; k++) {
    int32_t v = cf[k];
    int neg = v < 0;
    v = (neg ? -v : v) >> al;
    if (v == 0) { r++; continue; }
    if (!hp_flush(w, S, tb)) return 0;
    while (r > 15) {
      e = tb->ac[0xF0];
      if (e == 0) return 0;
      hw_bits(w, e >> 5, (int)(e & 31));
      r -= 16;
    }
    t = hcat(v);
    e = tb->ac[(r << 4) | t];
    if (e == 0) return 0;
    hw_bits(w, e >> 5, (int)(e & 31));
    hw_bits(w, (uint32_t)(neg ? -v - 1 : v) & ((1u << t) - 1), t);
    r = 0;
  }
  if (r > 0) {
    S->eobrun++;
    if (S->eobrun == S->maxEob && !hp_flush(w, S, tb)) return 0;
  }
  return 1;
}
static int hp_acrefine(hw_t *w, const int16_t *cf, const hetab_t *tb, hencscan_t *S) {
  int k, r = 0, br = 0, ib, eob = 0, al = (int)S->al, ss = (int)S->ss, se = (int)S->se;
  int32_t absv[64];
  uint8_t brbuf[64];
  uint32_t e;
  for (k = ss; k <= se; k++) {
    int32_t v = cf[k];
    absv[k] = (v < 0 ? -v : v) >> al;
    if (absv[k] == 1) eob = k;
  }
  for (k = ss; k <= se; k++) {
    int32_t v = absv[k];
    if (v == 0) { r++; continue; }
    while (r > 15 && k <= eob) {
      if (!hp_flush(w, S, tb)) return 0;
      e = tb->ac[0xF0];
      if (e == 0) return 0;
      hw_bits(w, e >> 5, (int)(e & 31));
      r -= 16;
      for (ib = 0; ib < br; ib++) hw_bits(w, brbuf[ib], 1);
      br = 0;
    }
    if (v > 1) { brbuf[br++] = (uint8_t)(v & 1); continue; }
    if (!hp_flush(w, S, tb)) return 0;
    e = tb->ac[(r << 4) | 1];
    if (e == 0) return 0;
    hw_bits(w, e >> 5, (int)(e & 31));
    hw_bits(w, cf[k] > 0, 1);
    for (ib = 0; ib < br; ib++) hw_bits(w, brbuf[ib], 1);
    br = 0; r = 0;
  }
  if (r > 0 || br > 0) {
    S->eobrun++;
    if (S->be + br > HE_BEBUF) return 0;
    for (ib = 0; ib < br; ib++) S->bebuf[S->be++] = brbuf[ib];
    if ((S->eobrun == S->maxEob || S->be > S->maxBe) && !hp_flush(w, S, tb)) return 0;
  }
  return 1;
}
/* one block of a progressive scan */
static inline int hp_block(hw_t *w, const int16_t *cf, const hetab_t *tb, intptr_t *pred, hencscan_t *S) {
  if (S->ss == 0) {
    if (S->ah == 0) return hp_dcfirst(w, cf, tb, pred, (int)S->al);
    hw_bits(w, (uint32_t)((int32_t)cf[0] >> S->al) & 1, 1);
    return 1;
  }
  if (S->ah == 0) return hp_acfirst(w, cf, tb, S);
  return hp_acrefine(w, cf, tb, S);
}

intptr_t pjasys_huffenc(hencscan_t *S) {
  hw_t w;
  intptr_t u = S->u, ux = S->ux, uy = S->uy, rst = S->rst, i, x, y, r = HE_OK;
  intptr_t pred[4];
  hetab_t *tb = S->tab;
  for (i = 0; i < S->nslot && i < 4; i++) hetab(&tb[i], &S->slot[i]);
  w.o = S->out; w.n = S->n; w.acc = S->acc; w.nacc = (int)S->nacc;
  for (i = 0; i < 4; i++) pred[i] = S->pred[i];
  for (; u < S->total; u++) {
    if (w.n + HE_UNIT_ROOM > S->cap) { r = HE_ROOM; break; }
    if (S->ri > 0 && u > 0 && u % S->ri == 0) {
      if (S->progressive && !hp_flush(&w, S, &tb[0])) return HE_FAIL;
      hw_align(&w, S->padbit);
      w.o[w.n++] = 0xFF; w.o[w.n++] = (uint8_t)(0xD0 + (rst & 7));
      rst++;
      for (i = 0; i < 4; i++) pred[i] = 0;
    }
    for (i = 0; i < S->nslot; i++) {
      const hslot_t *sl = &S->slot[i];
      for (y = 0; y < sl->v; y++)
        for (x = 0; x < sl->h; x++) {
          const int16_t *cf = sl->coef + ((uy * sl->v + y) * sl->bw + ux * sl->h + x) * 64;
          /* a progressive AC scan takes the first entry's table, as pjajpeg does */
          if (S->progressive ? !hp_block(&w, cf, S->ss > 0 ? &tb[0] : &tb[i], &pred[sl->predIdx], S)
                             : !hblock(&w, cf, &tb[i], &pred[sl->predIdx]))
            return HE_FAIL;
        }
    }
    if (++ux == S->unitsX) { ux = 0; uy++; }
  }
  if (r == HE_OK) {
    if (S->progressive && !hp_flush(&w, S, &tb[0])) return HE_FAIL;
    hw_align(&w, S->padbit);
  }
  S->n = w.n; S->acc = w.acc; S->nacc = w.nacc;
  S->u = u; S->ux = ux; S->uy = uy; S->rst = rst;
  for (i = 0; i < 4; i++) S->pred[i] = pred[i];
  return r;
}

/* ---------- a sequential Huffman scan, read (pjajpeg.HuffDecodeScan) ----------

   pjajpeg.DecodeScan's work, on the path a well-formed scan takes: the
   reader through a 64-bit accumulator (FF 00 unstuffed, stopping at a
   marker), each block as DecodeBlock (or, progressive, DecodeDcFirst,
   DecodeDcRefine, DecodeAcFirst, DecodeAcRefine) reads it, restarts and
   their padding, what has to follow the scan. Anything else (a code the
   table does not have, data that runs out, a coefficient out of range,
   padding that changes, a wrong restart marker) answers 1 with the state
   at the start of that unit (reader, predictions, EOB runs), and pjajpeg
   goes on from there itself, for its own error and position. What this
   one wrote of that unit is written again the same way: values put where
   they were, bits or-ed in again; an AC refinement block, whose new
   coefficients would change how it reads, is only written once read.
   huff_t is pjajpeg's THuff as FreePascal lays it out (pjajpeg checks its
   size before taking this). */
typedef struct {
  uint8_t counts[16], values[256];
  int32_t nvalues;
  int32_t mincode[16], maxcode[16], valptr[16];   /* [1..16] there */
  uint16_t code[256];
  uint8_t len[256];
  uint16_t lut[512];                             /* 9 bits: (length << 8) | symbol, 0 = longer */
} huff_t;
typedef struct {
  int16_t *coef; intptr_t bw, h, v;
  const huff_t *dc, *ac;
  intptr_t predIdx;
} hdslot_t;
/* An AC table's short pairs (hdtab) */
typedef struct { int32_t ac[512]; } hdtab_t;
typedef struct {
  uint64_t acc;                                  /* the reader's, with pos, nbits and stopped below */
  const uint8_t *d; intptr_t len, first;
  hdslot_t slot[4];
  intptr_t nslot, unitsX, total, ri, precision;
  intptr_t progressive, ss, se, ah, al, maxEob;
  intptr_t padbit, last;                         /* out, read */
  /* out, not read: where pjajpeg goes on, the start of unit u */
  intptr_t u, ux, uy, rst, pred[4];
  intptr_t pos, nbits, stopped;
  /* pjajpeg.TProgState's decoder part; beLow and beHigh also when read */
  intptr_t eobrun, runBe, runLen, prevEnded, prevBe, prevLen, beLow, beHigh;
  hdtab_t fast[4];                               /* scratch, in the caller's record (see hencscan_t) */
} hdecscan_t;

typedef struct { const uint8_t *d; intptr_t len, pos; uint64_t acc; int nbits, stopped; } hr_t;

static inline void hr_fill(hr_t *r) {
  while (r->nbits <= 48 && !r->stopped && r->pos + 8 <= r->len) {
    const uint8_t *p = r->d + r->pos;
    uint64_t w = (uint64_t)p[0] << 56 | (uint64_t)p[1] << 48 | (uint64_t)p[2] << 40 | (uint64_t)p[3] << 32 |
                 (uint64_t)p[4] << 24 | (uint64_t)p[5] << 16 | (uint64_t)p[6] << 8 | (uint64_t)p[7];
    int k;
    if (((~w) - 0x0101010101010101ull) & w & 0x8080808080808080ull) break;
    k = (64 - r->nbits) >> 3;
    if (k > 7) k = 7;
    r->acc = (r->acc << (8 * k)) | (w >> (64 - 8 * k));
    r->pos += k; r->nbits += 8 * k;
  }
  while (r->nbits <= 56 && !r->stopped) {
    uint32_t c;
    if (r->pos >= r->len) { r->stopped = 1; break; }
    c = r->d[r->pos];
    if (c == 0xFF) {
      if (r->pos + 1 >= r->len || r->d[r->pos + 1] != 0) { r->stopped = 1; break; }
      r->pos += 2;
    } else r->pos++;
    r->acc = (r->acc << 8) | c;
    r->nbits += 8;
  }
}
/* the next 9 bits, zeros past the data */
static inline uint32_t hr_peek9(const hr_t *r) {
  if (r->nbits >= 9) return (uint32_t)(r->acc >> (r->nbits - 9)) & 511;
  return (uint32_t)(r->acc << (9 - r->nbits)) & 511;
}
static inline int hr_sym(hr_t *r, const huff_t *h, int *sym) {
  uint32_t e, cd;
  int l;
  if (r->nbits < 16) hr_fill(r);
  e = h->lut[hr_peek9(r)];
  if (e) {
    l = (int)(e >> 8);
    if (l > r->nbits) return 0;
    r->nbits -= l; *sym = (int)(e & 255);
    return 1;
  }
  if (r->nbits < 9) return 0;
  cd = hr_peek9(r);
  for (l = 10; l <= 16; l++) {
    if (l > r->nbits) return 0;
    cd = (cd << 1) | (uint32_t)((r->acc >> (r->nbits - l)) & 1);
    if ((int32_t)cd <= h->maxcode[l - 1]) {
      int32_t idx = h->valptr[l - 1] + (int32_t)cd - h->mincode[l - 1];
      if (idx < 0 || idx > 255) return 0;
      *sym = h->values[idx];
      r->nbits -= l;
      return 1;
    }
  }
  return 0;
}
static inline int hr_bits(hr_t *r, int t, int32_t *v) {
  if (r->nbits < t) { hr_fill(r); if (r->nbits < t) return 0; }
  r->nbits -= t;
  *v = (int32_t)(r->acc >> r->nbits) & (int32_t)((1u << t) - 1);
  return 1;
}
/* the padding: 1, 0, -1 (none), or 2 (mixed); the bytes read ahead go back */
static inline int hr_align(hr_t *r) {
  int pr = r->nbits & 7, wb = r->nbits >> 3, pb = -1, i;
  if (pr) {
    uint32_t m = (1u << pr) - 1, b = (uint32_t)(r->acc >> (r->nbits - pr)) & m;
    pb = b == m ? 1 : b == 0 ? 0 : 2;
  }
  for (i = 0; i < wb; i++) r->pos -= ((r->acc >> (8 * i)) & 255) == 255 ? 2 : 1;
  r->acc = 0; r->nbits = 0; r->stopped = 0;
  return pb;
}
/* An AC table's short pairs: for 9 bits that start with a code of length l
   whose symbol has t extra bits, t > 0 and l + t <= 9, the coefficient
   itself: (value << 16) | (run << 8) | (l + t); 0 = take the long way */
static void hdtab(hdtab_t *f, const huff_t *h, int precision) {
  for (uint32_t p = 0; p < 512; p++) {
    uint32_t e = h->lut[p], l = e >> 8, rs = e & 255, t = rs & 15;
    int32_t v;
    f->ac[p] = 0;
    if (e == 0 || t == 0 || l + t > 9 || (int)t > precision + 2) continue;
    v = (int32_t)((p >> (9 - l - t)) & ((1u << t) - 1));
    if (v < (1 << (t - 1))) v = v - (1 << t) + 1;
    f->ac[p] = (int32_t)((uint32_t)v << 16) | (int32_t)((rs >> 4) << 8) | (int32_t)(l + t);
  }
}
static inline int hdblock(hr_t *r, int16_t *cf, const hdslot_t *sl, const hdtab_t *fa, intptr_t *pred,
                          int precision) {
  int t, k, rs, rr;
  int32_t v;
  if (!hr_sym(r, sl->dc, &t)) return 0;
  if (t > precision + 3) return 0;
  v = 0;
  if (t > 0 && !hr_bits(r, t, &v)) return 0;
  if (t > 0 && v < (1 << (t - 1))) v = v - (1 << t) + 1;
  v += (int32_t)*pred;
  if (v < -32767 || v > 32767) return 0;
  *pred = v;
  cf[0] = (int16_t)v;
  k = 1;
  while (k <= 63) {
    uint32_t lu = 0;
    if (r->nbits < 26) hr_fill(r);
    if (r->nbits >= 26) {
      uint32_t p9 = (uint32_t)(r->acc >> (r->nbits - 9)) & 511;
      int32_t f = fa->ac[p9];
      if (f) {
        /* the code and its extra bits in one: the same as the long way */
        r->nbits -= f & 255;
        k += (f >> 8) & 15;
        if (k > 63) return 0;
        cf[k] = (int16_t)(f >> 16);
        k++;
        continue;
      }
      lu = sl->ac->lut[p9];
    }
    if (lu) { r->nbits -= (int)(lu >> 8); rs = (int)(lu & 255); }
    else if (!hr_sym(r, sl->ac, &rs)) return 0;
    rr = rs >> 4; t = rs & 15;
    if (t == 0) {
      if (rr != 15) break;
      k += 16;
      continue;
    }
    if (t > precision + 2) return 0;
    k += rr;
    if (k > 63) return 0;
    if (!hr_bits(r, t, &v)) return 0;
    if (v < (1 << (t - 1))) v = v - (1 << t) + 1;
    cf[k] = (int16_t)v;
    k++;
  }
  return 1;
}

/* ---- progressive ---- */
typedef struct { intptr_t eobrun, runBe, runLen, prevEnded, prevBe, prevLen, beLow, beHigh; } hpst_t;

static inline int hd_dcfirst(hr_t *r, int16_t *cf, const huff_t *dc, intptr_t *pred, int precision, int al) {
  int t;
  int32_t v = 0;
  int64_t x;
  if (!hr_sym(r, dc, &t)) return 0;
  if (t > precision + 3) return 0;
  if (t > 0) {
    if (!hr_bits(r, t, &v)) return 0;
    if (v < (1 << (t - 1))) v = v - (1 << t) + 1;
  }
  v += (int32_t)*pred;
  *pred = v;
  x = (int64_t)v * ((int64_t)1 << al);
  if (v < -32767 || v > 32767 || x < -32767 || x > 32767) return 0;
  cf[0] = (int16_t)x;
  return 1;
}
static int hd_acfirst(hr_t *r, int16_t *cf, const huff_t *ac, hpst_t *st, int ss, int se, int precision,
                      int al) {
  int k = ss, rs, rr, t;
  int32_t v;
  int64_t x;
  if (st->eobrun > 0) { st->eobrun--; return 1; }
  while (k <= se) {
    if (!hr_sym(r, ac, &rs)) return 0;
    rr = rs >> 4; t = rs & 15;
    if (t == 0) {
      if (rr == 15) { k += 16; continue; }
      st->eobrun = (intptr_t)1 << rr;
      if (rr > 0) {
        if (!hr_bits(r, rr, &v)) return 0;
        st->eobrun += v;
      }
      st->eobrun--;
      break;
    }
    if (t > precision + 2) return 0;
    k += rr;
    if (k > se) return 0;
    if (!hr_bits(r, t, &v)) return 0;
    if (v < (1 << (t - 1))) v = v - (1 << t) + 1;
    x = (int64_t)v * ((int64_t)1 << al);
    if (x < -32767 || x > 32767) return 0;
    cf[k] = (int16_t)x;
    k++;
  }
  return 1;
}
static inline int16_t hd_refine(int c, int p1) { return (int16_t)(c > 0 ? (c | p1) : -((-c) | p1)); }
static int hd_acrefine(hr_t *r, int16_t *out, const huff_t *ac, hpst_t *st, int ss, int se, int al, intptr_t maxEob) {
  int16_t cf[64];
  int k = ss, rs, rr, t, c, first = 1, bits, p1 = 1 << al;
  int32_t v;
  if (p1 > 16383) return 0;
  for (k = 0; k < 64; k++) cf[k] = out[k];
  k = ss;
  if (st->eobrun == 0)
    while (k <= se) {
      if (!hr_sym(r, ac, &rs)) return 0;
      rr = rs >> 4; t = rs & 15;
      if (t != 0) {
        if (t != 1) return 0;
        if (!hr_bits(r, 1, &v)) return 0;
        t = v == 1 ? p1 : -p1;
      } else if (rr != 15) {
        st->eobrun = (intptr_t)1 << rr;
        if (rr > 0) {
          if (!hr_bits(r, rr, &v)) return 0;
          st->eobrun += v;
        }
        /* a run that starts with the block, right after another: that one
           was ended by its correction bits, unless by its length */
        if (first && st->prevEnded && st->prevLen < maxEob && st->prevBe - 1 < st->beHigh)
          st->beHigh = st->prevBe - 1;
        st->runBe = 0; st->runLen = st->eobrun;
        break;
      }
      first = 0;
      do {
        c = cf[k];
        if (c != 0) {
          if (!hr_bits(r, 1, &v)) return 0;
          if (v == 1) cf[k] = hd_refine(c, p1);
        } else {
          rr--;
          if (rr < 0) break;
        }
        k++;
      } while (k <= se);
      if (t != 0) {
        if (k > se) return 0;
        cf[k] = (int16_t)t;
      }
      k++;
    }
  if (st->eobrun > 0) {
    bits = 0;
    while (k <= se) {
      c = cf[k];
      if (c != 0) {
        if (!hr_bits(r, 1, &v)) return 0;
        if (v == 1) cf[k] = hd_refine(c, p1);
        bits++;
      }
      k++;
    }
    st->eobrun--;
    st->runBe += bits;
    if (st->eobrun > 0) {
      if (st->runBe > st->beLow) st->beLow = st->runBe;
    } else {
      st->prevEnded = 1; st->prevBe = st->runBe; st->prevLen = st->runLen;
    }
  } else st->prevEnded = 0;
  for (k = 0; k < 64; k++) out[k] = cf[k];
  return 1;
}

intptr_t pjasys_huffdec(hdecscan_t *S) {
  hr_t r, r0;
  hpst_t st, st0;
  intptr_t u, ux = 0, uy = 0, rst = 0, i, x, y, padbit = -1, padbit0, rst0;
  intptr_t pred[4] = {0, 0, 0, 0}, pred0[4];
  int pb, precision = (int)S->precision, prog = S->progressive != 0;
  int ss = (int)S->ss, se = (int)S->se, al = (int)S->al;
  hdtab_t *fa = S->fast;
  if (!prog)
    for (i = 0; i < S->nslot && i < 4; i++) hdtab(&fa[i], S->slot[i].ac, precision);
  r.d = S->d; r.len = S->len; r.pos = S->first; r.acc = 0; r.nbits = 0; r.stopped = 0;
  st.eobrun = st.runBe = st.runLen = st.prevEnded = st.prevBe = st.prevLen = st.beLow = 0;
  st.beHigh = 2147483647;
  for (u = 0; u < S->total; u++) {
    /* where pjajpeg goes on if this unit is not read to the end */
    r0 = r; st0 = st; padbit0 = padbit; rst0 = rst;
    for (i = 0; i < 4; i++) pred0[i] = pred[i];
    if (S->ri > 0 && u > 0 && u % S->ri == 0) {
      pb = hr_align(&r);
      if (pb == 2) goto stop;
      if (pb >= 0) { if (padbit < 0) padbit = pb; else if (padbit != pb) goto stop; }
      if (r.pos + 1 >= r.len || r.d[r.pos] != 0xFF || r.d[r.pos + 1] != 0xD0 + (rst & 7)) goto stop;
      r.pos += 2; rst++;
      for (i = 0; i < 4; i++) pred[i] = 0;
      st.eobrun = 0; st.prevEnded = 0;
    }
    for (i = 0; i < S->nslot; i++) {
      const hdslot_t *sl = &S->slot[i];
      for (y = 0; y < sl->v; y++)
        for (x = 0; x < sl->h; x++) {
          int16_t *cf = sl->coef + ((uy * sl->v + y) * sl->bw + ux * sl->h + x) * 64;
          int ok;
          if (!prog) ok = hdblock(&r, cf, sl, &fa[i], &pred[sl->predIdx], precision);
          else if (ss == 0) {
            if (S->ah == 0) ok = hd_dcfirst(&r, cf, sl->dc, &pred[sl->predIdx], precision, al);
            else {
              int32_t v;
              ok = hr_bits(&r, 1, &v);
              if (ok && v == 1) cf[0] = (int16_t)(cf[0] | (int16_t)(1 << al));
            }
          } else if (S->ah == 0) ok = hd_acfirst(&r, cf, S->slot[0].ac, &st, ss, se, precision, al);
          else ok = hd_acrefine(&r, cf, S->slot[0].ac, &st, ss, se, al, S->maxEob);
          if (!ok) goto stop;
        }
    }
    if (++ux == S->unitsX) { ux = 0; uy++; }
  }
  r0 = r; st0 = st; padbit0 = padbit; rst0 = rst;
  for (i = 0; i < 4; i++) pred0[i] = pred[i];
  pb = hr_align(&r);
  if (pb == 2) goto stop;
  if (pb >= 0) { if (padbit < 0) padbit = pb; else if (padbit != pb) goto stop; }
  if (padbit < 0) padbit = 1;
  if (r.pos < r.len && (r.d[r.pos] != 0xFF || r.pos + 1 >= r.len || r.d[r.pos + 1] == 0)) goto stop;
  S->padbit = padbit; S->last = r.pos;
  S->beLow = st.beLow; S->beHigh = st.beHigh;
  return 0;
stop:
  S->u = u; S->ux = ux; S->uy = uy; S->rst = rst0; S->padbit = padbit0;
  for (i = 0; i < 4; i++) S->pred[i] = pred0[i];
  S->acc = r0.acc; S->pos = r0.pos; S->nbits = r0.nbits; S->stopped = r0.stopped;
  S->eobrun = st0.eobrun; S->runBe = st0.runBe; S->runLen = st0.runLen; S->prevEnded = st0.prevEnded;
  S->prevBe = st0.prevBe; S->prevLen = st0.prevLen; S->beLow = st0.beLow; S->beHigh = st0.beHigh;
  return 1;
}

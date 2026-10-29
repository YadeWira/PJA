/* The coefficient model of stream version 7, in C (doc/CODEC.md, "Stream
   version 7"). Called through pjav7.pas, which owns every table and every
   buffer: this file takes no memory and calls no library, so the object
   links the same with FreePascal on every platform PJA builds for.

   The model is the full one of version 5 with fewer decisions: each edge
   (row 0, column 0) says first how many of its coefficients are nonzero,
   the interior's signs go as direct bits, and the interior's count goes as
   its bit length in unary and the bits below it. The coefficient loop is
   pjav7c_loop.h, compiled here twice: once decoding, once encoding.

   Determinism: integer arithmetic, but for DivRoundR's reciprocal, which a
   comparison each way makes exact (as pjamodel's). The SSE2 nonzero mask
   has a plain path (PJA_V7_PLAIN) that gives the same bits. On x86 the
   loop is compiled a second time for SSE4.1, taken when pjamodel's cpuid
   says so (UseSse41, which PJA_NOASM=1 turns off): the compiler's own
   vectorization, the same arithmetic. Build with -O3 -fwrapv
   -ffp-contract=off (pas/build_c.sh). */
#include <stdint.h>
#if defined(__SSE2__) && !defined(PJA_V7_PLAIN)
#include <emmintrin.h>
#define V7_SSE2 1
#endif

/* pjaarith's TAdaptiveBit and TArithDecoder, as FreePascal lays them out */
typedef struct { uint16_t p; uint8_t n, pad; } abit_t;
typedef struct { uint32_t x1, x2, x; const uint8_t *d; intptr_t p; void *live; } adec_t;
/* the encoder's state; its bytes go out through the put callback */
typedef struct { uint32_t x1, x2; void *ctx; } aenc_t;

/* the counters and the mixers' weights of one class of component (pjav7.TV7Model) */
typedef struct {
  abit_t *nz1, *nz2, *nz3, *zero1, *zero2, *zero3, *zero4, *zero5, *expo1, *expo2, *expo3, *expo4,
    *mant1, *mant, *ezero1, *ezero3, *ezero4, *ezero5, *eexpo1, *eexpo2, *eexpo3, *eexpo4, *eexpo5,
    *emant1, *esign, *dcZero, *dcExpo, *dcSign, *dcMant1, *dcMant, *dz2, *dz3, *dz4, *dx2, *dx3, *dx4,
    *ec1, *ec2, *ec3, *ez6, *nzm1, *nzm2;
  int32_t *wNz, *wZero, *wExpo, *wEZero, *wEExpo, *wDcZero, *wDcExpo, *wECnt;
} v7m_t;

/* pjamodel's tables and the callbacks (pjav7.TV7Tables) */
typedef struct {
  const uint16_t *sq; const int16_t *st; const int32_t *rc;
  const uint8_t *interior, *interiorLeft, *ibNa, *ibNb, *ibWa, *ibWb, *ibNone, *ratioOf;
  const uint8_t *unzig, *zzTable, *nzTable, *remTable, *kBucket;
  const int64_t *w3, *e3, *kerLeft, *kerTop, *kerRight, *kerBottom;
  uint64_t interiorZz, edgeZz;
  int32_t sse41;                                /* the SSE4.1 copy of the loop may run */
  void (*put)(void *ctx, uint32_t b);           /* one byte of the encoder's output */
  uint32_t (*get)(void *live, intptr_t p);      /* byte p of a stream still being written */
} v7t_t;

/* a block's edges, for the blocks right of it and below it (pjamodel.TEdgeCache) */
typedef struct { int64_t eg[8], px[8]; } ecache_t;
/* what the caller allocates, zeroed: rowC[bw]; dcr, rcnt, ccnt[bw * bh] */
typedef struct { ecache_t *rowC; uint8_t *dcr, *rcnt, *ccnt; } v7work_t;

static v7t_t T;
/* the prediction kernels in 32 bits (each below 2^15.5): half the cache */
static int32_t KL[512], KT[512], KR[512], KB[512];

void pjav7_tables(const v7t_t *t) {
  T = *t;
  for (int i = 0; i < 512; i++) {
    KL[i] = (int32_t)t->kerLeft[i]; KT[i] = (int32_t)t->kerTop[i];
    KR[i] = (int32_t)t->kerRight[i]; KB[i] = (int32_t)t->kerBottom[i];
  }
}

enum { NZ_BUCKETS = 11, REM_BUCKETS = 9, MAG_BUCKETS = 20, K_BUCKETS = 11, RATIO_BUCKETS = 17,
       MAX_EXP_AC = 15, MAX_EXP_DC = 17, ACT_BUCKETS = 24, NO_NEIGHBOUR = 19, PRED_BUCKETS = 22,
       NO_PRED = 21, EDGE_POS = 14, LANES = 8, MIX_LR = 6, MAX_W = 1 << 17, LIMIT = 255 };
#define MAX_DEQUANT (1 << 15)
#define COL_INTERIOR 0x0101010101010100ull
#define ROW_INTERIOR 0xFEull

/* ---------- 64-bit division without libgcc on 32-bit targets ---------- */
#if UINTPTR_MAX > 0xFFFFFFFFu
static inline int64_t sdiv(int64_t a, int64_t b) { return a / b; }
#else
static uint64_t udiv(uint64_t n, uint64_t d) {
  uint64_t q = 0, r = 0;
  for (int i = 63; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) { r -= d; q |= (uint64_t)1 << i; }
  }
  return q;
}
/* truncating toward zero, as C's / */
static int64_t sdiv(int64_t a, int64_t b) {
  int neg = (a < 0) != (b < 0);
  uint64_t q = udiv(a < 0 ? 0 - (uint64_t)a : (uint64_t)a, b < 0 ? 0 - (uint64_t)b : (uint64_t)b);
  return neg ? -(int64_t)q : (int64_t)q;
}
#endif

/* ---------- the arithmetic coder, both ways (pjaarith's), and the counters ---------- */
static inline uint32_t clampp(uint32_t p16) { return p16 < 1 ? 1 : p16 > 65535 ? 65535 : p16; }

static inline int dbit(adec_t *dc, uint32_t p16) {
  uint32_t xm = dc->x1 + (uint32_t)(((uint64_t)(dc->x2 - dc->x1) * clampp(p16)) >> 16);
  int bit = dc->x <= xm;
  uint32_t m = 0u - (uint32_t)bit;
  dc->x2 = (xm & m) | (dc->x2 & ~m);
  dc->x1 = ((xm + 1) & ~m) | (dc->x1 & m);
  while (((dc->x1 ^ dc->x2) & 0xFF000000u) == 0) {
    uint32_t b;
    dc->x1 <<= 8; dc->x2 = (dc->x2 << 8) | 255;
    if (dc->live) b = T.get(dc->live, dc->p);
    else {
      /* a FreePascal dynamic array: its high index just before the data */
      intptr_t len = dc->d ? ((const intptr_t *)dc->d)[-1] + 1 : 0;
      b = dc->p >= 0 && dc->p < len ? dc->d[dc->p] : 0;
    }
    dc->p++;
    dc->x = (dc->x << 8) | b;
  }
  return bit;
}
static inline int ebit(aenc_t *e, uint32_t p16, int bit) {
  uint32_t xm = e->x1 + (uint32_t)(((uint64_t)(e->x2 - e->x1) * clampp(p16)) >> 16);
  uint32_t m = 0u - (uint32_t)(bit != 0);
  e->x2 = (xm & m) | (e->x2 & ~m);
  e->x1 = ((xm + 1) & ~m) | (e->x1 & m);
  while (((e->x1 ^ e->x2) & 0xFF000000u) == 0) {
    T.put(e->ctx, e->x2 >> 24);
    e->x1 <<= 8; e->x2 = (e->x2 << 8) | 255;
  }
  return bit != 0;
}
static inline void learn(abit_t *c, int bit) {
  int32_t target = bit ? 65535 : 1;
  int64_t q = (int64_t)(target - (int32_t)c->p) * T.rc[c->n];
  q = (q + ((q >> 63) & 0xFFFF)) >> 16;
  c->p = (uint16_t)(c->p + q);
  c->n += c->n < LIMIT;
}
static inline int32_t truncshr(int32_t x, int n) { return (x + ((x >> 31) & ((1 << n) - 1))) >> n; }
static inline int32_t clampi(int32_t x, int32_t lo, int32_t hi) { x = x < lo ? lo : x; return x > hi ? hi : x; }

/* ---------- pjamodel's helpers ---------- */
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline uint64_t uabs64(int64_t v) { return v < 0 ? 0 - (uint64_t)v : (uint64_t)v; }
static inline int bitlen64(int64_t v) { uint64_t u = uabs64(v); return u ? 64 - __builtin_clzll(u) : 0; }
static inline int finelog(int64_t v) {
  uint64_t u = uabs64(v);
  if (u <= 1) return (int)u;
  int e = 64 - __builtin_clzll(u);
  return 2 * e - 2 + (int)((u >> (e - 2)) & 1);
}
static inline int ones64(uint64_t x) {
  x = x - ((x >> 1) & 0x5555555555555555ull);
  x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
  x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0Full;
  return (int)((x * 0x0101010101010101ull) >> 56);
}
static inline int clip(int v, int hi) { return v > hi ? hi : v; }
static inline int sgn3(int64_t v) { return (v > 0) - (v < 0) + 1; }
static inline int64_t w32(int64_t x) { return (int32_t)x; }
static inline int64_t divround(int64_t a, int64_t b) { return a >= 0 ? sdiv(a + b / 2, b) : -sdiv(-a + b / 2, b); }
/* DivRound(a, 8) with a shift: no division, on 32-bit targets either */
static inline int64_t div8round(int64_t a) { return a >= 0 ? (a + 4) >> 3 : -((-a + 4) >> 3); }
static inline int64_t divroundr(int64_t a, int64_t b, double rb) {
  int64_t sg = a >> 63, n = (a ^ sg) - sg + b / 2, q;
  if (n >= 0 && n < ((int64_t)1 << 50)) {
    q = (int64_t)((double)n * rb);
    if (q * b > n) q--; else if ((q + 1) * b <= n) q++;
  } else q = sdiv(n, b);
  return (q ^ sg) - sg;
}
static inline int64_t dequant(int c, int q) {
  int64_t r = (int64_t)c * q;
  return r > MAX_DEQUANT ? MAX_DEQUANT : r < -MAX_DEQUANT ? -MAX_DEQUANT : r;
}
static inline void cswap(int64_t *a, int64_t *b) {
  int64_t d = w32(*b - *a), m = d >> 63;
  *a += d & m; *b -= d & m;
}
static inline int64_t min64(int64_t a, int64_t b) { int64_t d = w32(b - a); return a + (d & (d >> 63)); }
static inline int64_t max64(int64_t a, int64_t b) { int64_t d = w32(b - a); return b - (d & (d >> 63)); }

/* pjamodel's Split16 and Split8: the 4 (2) smallest and largest to the ends */
#define CS(i, j) cswap(&e[i], &e[j])
static void split16(int64_t *e) {
  CS(0,1); CS(2,3); CS(4,5); CS(6,7); CS(8,9); CS(10,11); CS(12,13); CS(0,2); CS(1,3); CS(4,6); CS(5,7); CS(8,10);
  CS(9,11); CS(12,14); CS(13,15); CS(1,2); CS(5,6); CS(9,10); CS(13,14); CS(0,4); CS(1,5); CS(2,6); CS(3,7);
  CS(8,12); CS(9,13); CS(10,14); CS(11,15); CS(2,4); CS(3,5); CS(10,12); CS(11,13); CS(1,2); CS(5,6); CS(0,8);
  CS(1,9); CS(2,10); CS(3,11); CS(4,12); CS(5,13); CS(6,14); CS(7,15); CS(4,8); CS(5,9); CS(6,10); CS(7,11);
  CS(2,4); CS(3,5); CS(10,12); CS(11,13); CS(3,4); CS(11,12);
}
static void split8(int64_t *e) {
  CS(0,1); CS(2,3); CS(4,5); CS(0,2); CS(1,3); CS(4,6); CS(5,7); CS(0,4); CS(1,5); CS(2,6); CS(3,7); CS(2,4);
  CS(3,5); CS(1,2); CS(5,6);
}
#undef CS

/* acc[y] += k[pos][y] * fb[pos] for every pos set in mask */
static inline void sumkernels(const int64_t *fb, uint64_t mask, const int32_t *k, int64_t *acc) {
  while (mask) {
    int pos = __builtin_ctzll(mask); mask &= mask - 1;
    const int32_t *kp = k + pos * 8; int64_t f = fb[pos];
    for (int y = 0; y < 8; y++) acc[y] += kp[y] * f;
  }
}
static void fillcaches(const int64_t *fb, uint64_t mask, ecache_t *right, ecache_t *bottom) {
  uint64_t m0 = mask;
  for (int y = 0; y < 8; y++) right->eg[y] = bottom->eg[y] = right->px[y] = bottom->px[y] = 0;
  while (mask) {
    int pos = __builtin_ctzll(mask); mask &= mask - 1;
    int64_t f = fb[pos]; int u = pos >> 3, v = pos & 7;
    right->eg[u] += T.e3[v] * f; bottom->eg[v] += T.e3[u] * f;
  }
  sumkernels(fb, m0, KR, right->px);
  sumkernels(fb, m0, KB, bottom->px);
  for (int y = 0; y < 8; y++) {
    right->eg[y] = w32(right->eg[y]); bottom->eg[y] = w32(bottom->eg[y]);
    right->px[y] = w32(right->px[y]); bottom->px[y] = w32(bottom->px[y]);
  }
}
/* a bit per coefficient of the block (zigzag), set where it is not zero */
static inline uint64_t nzmask(const int16_t *b) {
  uint64_t m = 0;
#ifdef V7_SSE2
  __m128i z = _mm_setzero_si128();
  for (int h = 0; h < 4; h++) {
    __m128i a = _mm_cmpeq_epi16(_mm_loadu_si128((const __m128i *)(b + 16 * h)), z);
    __m128i c = _mm_cmpeq_epi16(_mm_loadu_si128((const __m128i *)(b + 16 * h + 8)), z);
    m |= (uint64_t)(uint16_t)~_mm_movemask_epi8(_mm_packs_epi16(a, c)) << (16 * h);
  }
#else
  for (int k = 0; k < 64; k++) m |= (uint64_t)(b[k] != 0) << k;
#endif
  return m;
}
static inline int nzb(int n) { return T.nzTable[n]; }
static inline int remb(int n) { return T.remTable[n]; }

/* pjamodel's NeighbourMag: the magnitude expected at k from the blocks around */
static int neighbourmag(const int16_t *coef, intptr_t base, intptr_t bw, intptr_t bx, intptr_t by, int k) {
  int sum = 0, wsum = 0;
  if (by > 0) {
    sum += 2 * iabs(coef[base - bw * 64 + k]); wsum += 2;
    if (bx > 0) { sum += iabs(coef[base - bw * 64 - 64 + k]); wsum++; }
    if (bx + 1 < bw) { sum += iabs(coef[base - bw * 64 + 64 + k]); wsum++; }
  }
  if (bx > 0) { sum += 2 * iabs(coef[base - 64 + k]); wsum += 2; }
  switch (wsum) {
    case 0: return -1;
    case 2: return (int)((uint32_t)(sum * 2 + 1) / 2);
    case 3: return (int)((uint32_t)(sum * 2 + 1) / 3);
    case 4: return (int)((uint32_t)(sum * 2 + 2) / 4);
    case 5: return (int)((uint32_t)(sum * 2 + 2) / 5);
    default: return (int)((uint32_t)(sum * 2 + 3) / 6);
  }
}

#define TARGET
#define SUFFIX
#define ENC 0
#include "pjav7c_loop.h"
#undef ENC
#define ENC 1
#include "pjav7c_loop.h"
#undef ENC
#undef TARGET
#undef SUFFIX

#if (defined(__x86_64__) || defined(__i386__)) && !defined(PJA_V7_PLAIN)
#define V7_SSE41 1
#define TARGET __attribute__((target("sse4.1")))
#define SUFFIX _sse41
#define ENC 0
#include "pjav7c_loop.h"
#undef ENC
#define ENC 1
#include "pjav7c_loop.h"
#undef ENC
#undef TARGET
#undef SUFFIX
#endif

typedef int (*decfn)(adec_t *, v7m_t *, int16_t *, intptr_t, intptr_t, const uint16_t *, const uint8_t *,
                     intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, uint8_t *, v7work_t *);
typedef int (*encfn)(aenc_t *, v7m_t *, int16_t *, intptr_t, intptr_t, const uint16_t *, const uint8_t *,
                     intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, uint8_t *, v7work_t *);

/* The blocks of rows y0..y1-1 of one component (pjamodel.CodeComponent's
   arguments; wk zeroed by the caller), decoding or encoding. Returns 1
   when it went through: 0 is only possible decoding a damaged stream. */
int pjav7_component_d(adec_t *dc, v7m_t *m, int16_t *coef, intptr_t bw, intptr_t bh, const uint16_t *qt,
                      const uint8_t *lumaNz, intptr_t lumaW, intptr_t sx, intptr_t sy, intptr_t y0, intptr_t y1,
                      uint8_t *nzc, v7work_t *wk) {
  decfn f = component_d;
#ifdef V7_SSE41
  if (T.sse41) f = component_d_sse41;
#endif
  return f(dc, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk);
}
int pjav7_component_e(aenc_t *e, v7m_t *m, int16_t *coef, intptr_t bw, intptr_t bh, const uint16_t *qt,
                      const uint8_t *lumaNz, intptr_t lumaW, intptr_t sx, intptr_t sy, intptr_t y0, intptr_t y1,
                      uint8_t *nzc, v7work_t *wk) {
  encfn f = component_e;
#ifdef V7_SSE41
  if (T.sse41) f = component_e_sse41;
#endif
  return f(e, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk);
}

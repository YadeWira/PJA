/* The coefficient model of stream version 7, in C (doc/CODEC.md, "Stream
   version 7"). Called through pjav7.pas, which owns every table and every
   buffer: this file takes no memory and calls no library, so the object
   links the same with FreePascal on every platform PJA builds for.

   The model is the full one of version 5 with fewer decisions: each edge
   (row 0, column 0) says first how many of its coefficients are nonzero,
   the interior's signs go as direct bits, and the interior's count goes as
   its bit length in unary and the bits below it. The coefficient loop is
   pjav7c_loop.h, compiled here twice: once decoding, once encoding.

   Its contexts go past the full model's (doc/CODEC.md, "Version 7's
   contexts"): a chroma block sees the luma block over it and Cr the Cb
   block at the same place (coefficients, counts, signs, DC residuals); a
   luma block uses those inputs for the sum coded so far in the block and
   its neighbours; the edge mantissa is coded against the edge prediction.

   Determinism: integer arithmetic, but for DivRoundR's reciprocal, which a
   comparison each way makes exact (as pjamodel's). The SSE2 nonzero mask
   has a plain path (PJA_V7_PLAIN) that gives the same bits. On x86 the
   loop is compiled a second time for SSE4.1 and a third for AVX2, taken
   when pjamodel's cpuid says so (UseSse41, UseAvx2; PJA_NOASM=1 turns both
   off, PJA_NOAVX2=1 the second): the mixer, the prediction kernels and the
   DC's estimates in intrinsics there, every lane the plain path's 32-bit
   arithmetic. Build with -O3 -fwrapv -ffp-contract=off (pas/build_c.sh). */
#include <stdint.h>
#if defined(__SSE2__) && !defined(PJA_V7_PLAIN)
#include <emmintrin.h>
#define V7_SSE2 1
#endif

/* pjaarith's TAdaptiveBit and TArithDecoder, as FreePascal lays them out */
typedef struct { uint16_t p; uint8_t n, pad; } abit_t;
typedef struct { uint32_t x1, x2, x; const uint8_t *d; intptr_t p; void *live; } adec_t;
/* the encoder's state; its bytes gather in buf and go out through the put
   callback when it is full and when the component ends (pjav7.TV7Encoder) */
#define EBUF 4096
typedef struct { uint32_t x1, x2; void *ctx; intptr_t n; uint8_t buf[EBUF]; } aenc_t;

/* the counters and the mixers' weights of one class of component (pjav7.TV7Model) */
typedef struct {
  abit_t *nz1, *nz2, *nz3, *zero1, *zero2, *zero3, *zero4, *zero5, *expo1, *expo2, *expo3, *expo4,
    *mant1, *mant, *ezero1, *ezero3, *ezero4, *ezero5, *eexpo1, *eexpo2, *eexpo3, *eexpo4, *eexpo5,
    *emant1, *esign, *dcZero, *dcExpo, *dcSign, *dcMant1, *dcMant, *dz2, *dz3, *dz4, *dx2, *dx3, *dx4,
    *ec1, *ec2, *ec3, *ez6, *nzm1, *nzm2,
    /* contexts of version 7 alone (pjamodel.InitV7 sizes them) */
    *nz4, *zLum, *zCb, *xPos, *xRow, *xLum, *xCb, *mFirst, *mRest, *iSign, *ecX, *ezLum, *exLum, *exCb, *eMant,
    *eSgn, *dzX, *dxX, *dsX,
    /* the edge sign by the size coded against the prediction, the DC sign and
       zero flag by the prediction's eighths, the edge counts by how many edge
       predictions are big */
    *esr, *dsf, *dzf, *ecp;
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
  int32_t avx2;                                 /* the AVX2 copy may run */
  void (*put)(void *ctx, const uint8_t *b, intptr_t n);   /* n bytes of the encoder's output */
  uint32_t (*get)(void *live, intptr_t p);      /* byte p of a stream still being written */
} v7t_t;

/* a block's edges, for the blocks right of it and below it (pjamodel.TV7EdgeCache):
   pjamodel.TEdgeCache's values, which pjamodel only ever uses modulo 2^32
   (W32 before any division, comparison or logarithm), so kept in 32 bits */
typedef struct { uint32_t eg[8], px[8]; } ecache_t;
/* what the caller allocates, zeroed: rowC[bw]; dcr, rcnt, ccnt[bw * bh]. Then
   what the components coded before this one in the band left: the luma's
   coefficients and DC residuals (a chroma component, lumaNz set), the
   previous component's (Cr after Cb, same size); nil where there are none */
typedef struct {
  ecache_t *rowC; uint8_t *dcr, *rcnt, *ccnt;
  const int16_t *lumaC, *prevC; const uint8_t *lumaD, *prevD;
} v7work_t;

static v7t_t T;
/* The prediction kernels. Every sum of their products is only used modulo
   2^32 (above), so they are summed in uint32_t, where wrapping is defined.
   K4[pos]: what the coefficient at pos adds per unit to the 8 values of each
   kernel, left and top (the DC's estimates), right and bottom (the edge
   caches), side by side so one pass serves the four, 16-byte aligned. */
static uint32_t K4[64][32] __attribute__((aligned(32)));
static uint32_t E3U[8];
/* the zigzag indices of row 0 and of column 0, the DC left out */
static uint64_t ROW0ZZ, COL0ZZ;

void pjav7_tables(const v7t_t *t) {
  T = *t;
  for (int pos = 0; pos < 64; pos++)
    for (int y = 0; y < 8; y++) {
      K4[pos][y] = (uint32_t)t->kerLeft[pos * 8 + y]; K4[pos][8 + y] = (uint32_t)t->kerTop[pos * 8 + y];
      K4[pos][16 + y] = (uint32_t)t->kerRight[pos * 8 + y]; K4[pos][24 + y] = (uint32_t)t->kerBottom[pos * 8 + y];
    }
  for (int i = 0; i < 8; i++) E3U[i] = (uint32_t)t->e3[i];
  ROW0ZZ = COL0ZZ = 0;
  for (int i = 1; i < 8; i++) { ROW0ZZ |= 1ull << t->unzig[i]; COL0ZZ |= 1ull << t->unzig[i * 8]; }
}

enum { NZ_BUCKETS = 11, REM_BUCKETS = 9, MAG_BUCKETS = 20, K_BUCKETS = 11, RATIO_BUCKETS = 17,
       MAX_EXP_AC = 15, MAX_EXP_DC = 17, ACT_BUCKETS = 24, NO_NEIGHBOUR = 19, PRED_BUCKETS = 22,
       ACT2 = 28, NO_PRED = 21, PQ_BUCKETS = 26, NO_PQ = 25, EDGE_POS = 14, LANES = 8,
       /* the mixers' learning rates (zero flags, edge exponent, the rest) and their constant input */
       MIX_LR = 6, LR_ZERO = 4, LR_EEXPO = 10, BIAS = 384,
       MAX_W = 1 << 17, LIMIT = 255,
       /* an edge prediction is big (the edge counts' context) from PTH quarters of a
          quantum, very big from PTH2: part of the format, so constants, not build flags */
       PTH = 6, PTH2 = 40,
       /* the rows of the exponent ladders and of the mantissas: 16 counters,
          64 bytes, one cache line (pjamodel's InitV7 lays them out so) */
       ROW = 16 };
#define MAX_DEQUANT (1 << 15)

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
/* p16 is always in [1, 65535] (pjaarith's clamp never acts here): a
   counter's p stays there, a squashed probability is in [16, 65520] */

static inline int dbit(adec_t *dc, uint32_t p16) {
  uint32_t xm = dc->x1 + (uint32_t)(((uint64_t)(dc->x2 - dc->x1) * p16) >> 16);
  int bit = dc->x <= xm;
  /* both stores, selects rather than a branch on the bit */
  dc->x2 = bit ? xm : dc->x2; dc->x1 = bit ? dc->x1 : xm + 1;
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
  uint32_t xm = e->x1 + (uint32_t)(((uint64_t)(e->x2 - e->x1) * p16) >> 16);
  e->x2 = bit ? xm : e->x2; e->x1 = bit ? e->x1 : xm + 1;
  while (((e->x1 ^ e->x2) & 0xFF000000u) == 0) {
    e->buf[e->n++] = (uint8_t)(e->x2 >> 24);
    if (e->n == EBUF) { T.put(e->ctx, e->buf, EBUF); e->n = 0; }
    e->x1 <<= 8; e->x2 = (e->x2 << 8) | 255;
  }
  return bit != 0;
}
/* pjaarith's Update: p += (target - p) * rc[n] / 65536, truncated toward
   zero. Toward the target the distance (65535 - p, or p - 1) times rc[n]
   (at most 43691) stays below 2^32, so the step is an unsigned 32-bit
   product, floored, added or taken away: the same p, no 64-bit multiply. */
static inline __attribute__((always_inline)) void learn(abit_t *c, int bit) {
  uint32_t p = c->p, n = c->n, d = bit ? 65535 - p : p - 1;
  uint32_t step = (d * (uint32_t)T.rc[n]) >> 16;
  c->p = (uint16_t)(bit ? p + step : p - step);
  c->n = (uint8_t)(n + (n < LIMIT));
}
static inline int32_t truncshr(int32_t x, int n) { return (x + ((x >> 31) & ((1 << n) - 1))) >> n; }
static inline int32_t clampi(int32_t x, int32_t lo, int32_t hi) { x = x < lo ? lo : x; return x > hi ? hi : x; }

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

/* ---------- pjamodel's helpers ---------- */
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline uint64_t uabs64(int64_t v) { return v < 0 ? 0 - (uint64_t)v : (uint64_t)v; }
static inline int bitlen64(int64_t v) { uint64_t u = uabs64(v); return u ? 64 - clz64(u) : 0; }
static inline int finelog(int64_t v) {
  uint64_t u = uabs64(v);
  if (u <= 1) return (int)u;
  int e = 64 - clz64(u);
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
/* floor(a / b) for 0 <= a, by the reciprocal rb = 1 / b, exact by correction */
static inline int64_t divfloorr(int64_t a, int64_t b, double rb) {
  int64_t t;
  if (a < ((int64_t)1 << 50)) {
    t = (int64_t)((double)a * rb);
    if (t * b > a) t--; else if ((t + 1) * b <= a) t++;
  } else t = sdiv(a, b);
  return t;
}
/* the edge prediction n / (724 b) rounded to an integer (*pf) and to quarters (*pq),
   both from one truncated division in eighths, so each is exact; b4 = 181 b, rb4 = 1 / b4 */
static inline void edgepred(int64_t n, int64_t b4, double rb4, int64_t *pf, int64_t *pq) {
  int64_t sg = n >> 63, t = divfloorr(2 * ((n ^ sg) - sg), b4, rb4);
  int64_t f = (t + 4) >> 3, qq = (t + 1) >> 1;
  *pf = (f ^ sg) - sg; *pq = (qq ^ sg) - sg;
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

/* W32 of a 32-bit sum: as int32_t (the conversion every compiler PJA
   builds with defines as modular) */
static inline int64_t s32(uint32_t x) { return (int32_t)x; }

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

/* pjamodel's NeighbourMag, the magnitude expected at k from the blocks
   around, set up once per block: the four neighbours (a block of zeros
   where there is none, so it adds nothing), the weights' sum ws and the
   rounding division by it as a multiply, exact for every sum (below 2^20):
   x * (floor(2^32 / ws) + 1) >> 32 is floor(x / ws) while x * ws < 2^32. */
static const int16_t ZEROBLOCK[64];
/* floor(2^32 / ws) + 1, without a 64-bit division on 32-bit targets */
static const uint64_t NBRMUL[7] = {0, 4294967297u, 2147483649u, 1431655766u, 1073741825u, 858993460u, 715827883u};
typedef struct { const int16_t *a, *al, *ar, *l; uint32_t half; uint64_t mul; int none; } nbr_t;
static inline void nbrsetup(nbr_t *nb, const int16_t *coef, intptr_t base, intptr_t bw, intptr_t bx, int haveA) {
  int haveL = bx > 0, haveAL = haveA && haveL, haveAR = haveA && bx + 1 < bw;
  uint32_t ws = (haveA ? 2 : 0) + haveAL + haveAR + (haveL ? 2 : 0);
  nb->a = haveA ? coef + base - bw * 64 : ZEROBLOCK;
  nb->al = haveAL ? coef + base - bw * 64 - 64 : ZEROBLOCK;
  nb->ar = haveAR ? coef + base - bw * 64 + 64 : ZEROBLOCK;
  nb->l = haveL ? coef + base - 64 : ZEROBLOCK;
  nb->none = ws == 0;
  nb->half = ws / 2;
  nb->mul = NBRMUL[ws];
}
static inline int nbrmag(const nbr_t *nb, int k) {
  uint32_t sum = 2 * iabs(nb->a[k]) + iabs(nb->al[k]) + iabs(nb->ar[k]) + 2 * iabs(nb->l[k]);
  return (int)(((uint64_t)(sum * 2 + nb->half) * nb->mul) >> 32);
}

#define TARGET
#define SUFFIX
#define IN_SSE41 0
#define IN_AVX2 0
#define ENC 0
#include "pjav7c_loop.h"
#undef ENC
#define ENC 1
#include "pjav7c_loop.h"
#undef ENC
#undef TARGET
#undef SUFFIX

#if (defined(__x86_64__) || defined(__i386__)) && !defined(PJA_V7_PLAIN)
#include <smmintrin.h>
#define V7_SSE41 1
#undef IN_SSE41
#define IN_SSE41 1
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
/* and once more for AVX2 (pjamodel's cpuid check, UseAvx2): the mixer's 8
   lanes and the kernels' 32 in 256-bit vectors, the same arithmetic */
#include <immintrin.h>
#define V7_AVX2 1
#undef IN_AVX2
#define IN_AVX2 1
#define TARGET __attribute__((target("avx2")))
#define SUFFIX _avx2
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
#ifdef V7_AVX2
  if (T.avx2) f = component_d_avx2;
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
#ifdef V7_AVX2
  if (T.avx2) f = component_e_avx2;
#endif
  int ok = f(e, m, coef, bw, bh, qt, lumaNz, lumaW, sx, sy, y0, y1, nzc, wk);
  if (e->n > 0) { T.put(e->ctx, e->buf, e->n); e->n = 0; }
  return ok;
}

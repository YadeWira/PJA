/* Stream version 8's mode 1: the decisions of a JPEG 2000 codestream's
   code-blocks coded with a context-mixing model (doc/CODEC.md, "JPEG 2000,
   stage C"). Called through pjaj2km.pas, which owns every buffer: this
   file takes no memory and calls no library, as pjav7c.c.

   The coding passes are walked as pjaj2kt1.c walks them, and each decision
   (a byte ctx << 1 | bit, as pjaj2kt1.c's) is coded as what it means for
   the coefficient: whether it becomes significant, its sign, its next bit.
   In a cleanup pass's run mode the run decision and its two uniform
   decisions become the significance of the column's coefficients up to the
   first one that is. The model sees the coefficients known so far: in the
   code-block, its neighbours' values; around it, the code-blocks already
   coded in the band, the band one resolution coarser (the parent) and the
   first two components' band of the same resolution and orientation, kept
   as one byte per coefficient (the maps, pjaj2km_tile). From those, NC
   contexts, each with two counters (one that slows down, one fast), a
   mixer with two sets of weights chosen by the kind of decision, and two
   adaptive probability maps; then PJA's binary arithmetic coder
   (pjaarith's, the same arithmetic as pjav7c.c's).

   Determinism: integer arithmetic only; the stretch and squash tables are
   constants (pjaj2km_tab.h). Build with -fwrapv (pas/build_c.sh). */
#include <stdint.h>
#include "pjaj2kt1.h"
#include "pjaj2km_tab.h"

#if defined(__GNUC__) || defined(__clang__)
#define KM_INLINE static inline __attribute__((always_inline))
#else
#define KM_INLINE static inline
#endif

/* ------------------------------------------------------------------ parameters */
/* part of the format: constants, not build options */
#define KM_LIMIT 255        /* the slow counters' last rate, 1 / (limit + 1.5) */
#define KM_FAST 3           /* the fast counters' rate, 2^-KM_FAST */
#define KM_APMR 6           /* the maps' rate */
#define KM_LR0 31457        /* the mixer's rate: KM_LR1 + KM_LR0 / (1024 + 64 (updates / 64)) */
#define KM_LR1 6
#define KM_HBMIN 10         /* a table has at most 2^hb counters, hb from KM_HBMIN */
#define KM_HBMAX 20         /* to KM_HBMAX (pjaj2kcs.pas's KM_HBMIN and KM_HBMAX) */
#define NC 8                /* contexts */
#define NW (2 * NC)         /* the mixer's inputs: each context's two counters */
#define WMAX (1 << 22)
#define NK 5                /* kinds of event */
#define NSA (NK * 20 * 24)  /* weight sets A: kind, neighbours, depth */
#define NSB (NK * 12 * 18)  /* weight sets B: kind, standard context, parent */
#define NSC (NK * 64 * 4)   /* weight sets C: kind, orientation and level, component */
#define A0N (NK * 20)       /* the first map's contexts: kind, neighbours */
#define A1N (NK * 18 * 18)  /* the second's: kind, parent, the other component */
#define A2N (NK * 12 * 21)  /* the third's: kind, standard context, depth */

/* the code-block's largest arrays: w, h <= 1024 and w h <= 4096 */
#define CBMAX 4096
#define STMAX (CBMAX + 2 * 1028 + 4)
#define RMAX (CBMAX + 4 * 1028 + 16)

/* a band of the tile (pjaj2kcs.pas's TKmBand: its parent is coarser there) */
typedef struct {
  int32_t comp, res, orient, nres, w, h, mb, parent, cross0, cross1;
  int64_t map;                 /* where its map is in the maps, -1: none */
} j2kmband_t;

/* a counter: p and f are probabilities of a 1 xor 0x8000 (so that zeroed
   memory is 1/2), n how many updates the slow one has had (0: none) */
typedef struct { uint16_t p, f; uint8_t n, pad; } ctr_t;

typedef void (*km_put_t)(void *ctx, const uint8_t *b, intptr_t n);

#define EBUF 4096
typedef struct {
  uint32_t x1, x2, x;
  km_put_t put; void *pctx; int32_t n;
  const uint8_t *d; int64_t len, p;
  uint8_t buf[EBUF];
} ac_t;

typedef struct {
  ac_t ac;
  int32_t enc, err;
  int32_t path;                    /* the copy of the passes that runs: 0 plain, 1 SSE4.1, 2 AVX2 */
  int64_t tsize[NC];             /* each context's table, in counters */
  ctr_t *t[NC];
  int32_t wa[NSA][NW] __attribute__((aligned(32))), wb[NSB][NW] __attribute__((aligned(32)));
  int32_t wc[NSC][NW] __attribute__((aligned(32)));
  uint16_t ca[NSA], cb[NSB], cc[NSC];
  int32_t w2[NK * 24][4];          /* the second layer: the three sets' outputs, by kind and depth */       /* a weight set's updates, at most 65535 */
  int32_t lr[1024];                /* the rate after 64 i updates */
  int32_t hshift;                  /* 32 - log2 of a hashed table's size */
  uint16_t apm0[A0N][33], apm1[A1N][33], apm2[A2N][33];
  ctr_t misc[64];
  uint32_t magc[64];
  /* the tile */
  const j2kmband_t *bands; int32_t nb; uint8_t *maps; int64_t mapsize; int32_t zcomp;
  /* the code-block */
  int32_t w, h, rw, mbc, orient, lvl, comp, haveP, haveX;
  int32_t pqoff, xqoff;
  uint8_t st[2 * STMAX];
  int32_t R[RMAX];
  int16_t PQ[CBMAX], XQ[CBMAX];
  int8_t PS[CBMAX], XS[CBMAX];
  int32_t colA[1024], rowA[1024], colB[1024], rowB[1024], colC[1024], rowC[1024];
  /* decisions */
  uint8_t *sym; int64_t ns, cap;
} j2km_t;

/* ------------------------------------------------------------------ the arithmetic coder (pjaarith) */
KM_INLINE int ac_code(ac_t *a, uint32_t p16, int bit, const int dec)
{
  uint32_t xm;
  if (p16 < 1) p16 = 1; else if (p16 > 65535) p16 = 65535;
  xm = a->x1 + (uint32_t)(((uint64_t)(a->x2 - a->x1) * p16) >> 16);
  if (dec) bit = a->x <= xm;
  {
    /* without a branch on the bit (decoding, a guess the processor misses
       about once an event) */
    uint32_t mk = 0u - (uint32_t)bit;
    a->x2 = (xm & mk) | (a->x2 & ~mk);
    a->x1 = (a->x1 & mk) | ((xm + 1) & ~mk);
  }
  while (((a->x1 ^ a->x2) & 0xFF000000u) == 0) {
    if (dec) {
      uint32_t b = a->p >= 0 && a->p < a->len ? a->d[a->p] : 0;
      a->p++;
      a->x = (a->x << 8) | b;
    } else {
      a->buf[a->n++] = (uint8_t)(a->x2 >> 24);
      if (a->n == EBUF) { a->put(a->pctx, a->buf, EBUF); a->n = 0; }
    }
    a->x1 <<= 8; a->x2 = (a->x2 << 8) | 255;
  }
  return bit;
}

/* ------------------------------------------------------------------ helpers */
static inline int clampi(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline uint32_t ab(int32_t v) { return v < 0 ? 0u - (uint32_t)v : (uint32_t)v; }
/* floor(log2 v), v > 0; on a 32-bit target two 32-bit scans, so that it
   calls no library */
#if UINTPTR_MAX > 0xFFFFFFFFu
static inline int ilog2_64(uint64_t v) { return 63 - __builtin_clzll(v); }
#else
static inline int ilog2_64(uint64_t v)
{
  uint32_t hi = (uint32_t)(v >> 32);
  return hi ? 63 - __builtin_clz(hi) : 31 - __builtin_clz((uint32_t)v);
}
#endif
/* floor(2 log2 v), 0 < v < 2^63: 2 l and the bit below the top one (none
   for v = 1: (v << 1) >> 0 is even) */
static inline int q2log(uint64_t v)
{
  int l = ilog2_64(v);
  return 2 * l + (int)(((v << 1) >> l) & 1);
}
/* c ? a : b, without a branch */
static inline int sel(int c, int a, int b) { return b ^ ((a ^ b) & -(c != 0)); }
/* q2log(v) - d clamped to [lo, hi] for v > 0, z for v = 0 */
static inline int qlog_or(uint64_t v, int d, int lo, int hi, int z)
{
  return sel(v != 0, clampi(q2log(v | (v == 0)) - d, lo, hi), z);
}
static inline int sgn3(int32_t v) { return (v > 0) - (v < 0); }
static inline int32_t truncshr(int32_t x, int n) { return (x + ((x >> 31) & ((1 << n) - 1))) >> n; }

/* a * b / c for a, b, c >= 0 (c > 0) whose product fits 63 bits, without
   libgcc's 64-bit division on 32-bit targets */
#if UINTPTR_MAX > 0xFFFFFFFFu
static inline int32_t muldiv(int64_t a, int64_t b, int64_t c) { return (int32_t)(a * b / c); }
#else
static int32_t muldiv(int64_t a, int64_t b, int64_t c)
{
  uint64_t n = (uint64_t)a * (uint64_t)b, d = (uint64_t)c, q = 0, r = 0; int i;
  for (i = 63; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) { r -= d; q |= (uint64_t)1 << i; }
  }
  return (int32_t)q;
}
#endif

/* a map's byte: 0 for 0, else floor(2 log2 |v|) + 1, and 128 when v < 0 */
static inline uint8_t mapcode(int32_t v)
{
  uint32_t u = ab(v);
  int c = (q2log(u | (u == 0)) + 1) | (v < 0 ? 128 : 0);
  return (uint8_t)(c & -(u != 0));
}
KM_INLINE int32_t mapval(const j2km_t *m, uint8_t c)
{
  int32_t v = (int32_t)m->magc[c & 63];
  return c & 128 ? -v : v;
}

/* ------------------------------------------------------------------ sizes */
/* each context's natural range, the sum over the kinds of decision (see
   ctxs below); a table holds min(range, 2^hb) counters, indexed directly
   when the range fits and by a hash otherwise */
enum {
  R_SD = 12, R_LN = 20, R_LN2 = 14, R_LP = 18, R_DEP = 21, R_ORL = 64, R_CMP = 4, R_RC = 3, R_NS = 9,
  R_R = 8, R_REL = 17, R_MB = 8, R_CMB = 81, R_EXT = 9
};
/* each context's values for one kind of event; the table has NK times as many */
static const int64_t PK[NC] = {
  /* 0 */ (int64_t)R_SD * R_RC * R_R,
  /* 1 */ (int64_t)R_SD * R_LN * R_RC * 81,
  /* 2 */ (int64_t)R_LN * R_LP * R_CMP * 4 * 9,
  /* 3 */ (int64_t)R_SD * R_LP * R_LP * R_DEP * R_CMP,
  /* 4 */ (int64_t)R_NS * R_LN2 * R_LN * R_RC * 4 * R_REL,
  /* 5 */ (int64_t)R_LN * R_DEP * R_ORL * R_CMP * R_MB,
  /* 6 */ (int64_t)R_LP * R_LP * R_LN * R_LN2 * 4,
  /* 7 */ (int64_t)R_LN * R_LP * R_LP * 11 * R_EXT * 4
};
#define RANGE(i) (PK[i] * NK)

static int64_t tables_size(int32_t hb)
{
  int i; int64_t n = 0;
  for (i = 0; i < NC; i++) n += RANGE(i) < ((int64_t)1 << hb) ? RANGE(i) : ((int64_t)1 << hb);
  return n * (int64_t)sizeof(ctr_t);
}

/* the bytes pjaj2km_init needs for tables of at most 2^hb counters, hb in
   [KM_HBMIN, KM_HBMAX]; -1 for another hb */
int64_t pjaj2km_size(int32_t hb)
{
  if (hb < KM_HBMIN || hb > KM_HBMAX) return -1;
  return (int64_t)sizeof(j2km_t) + 64 + tables_size(hb);
}

/* ------------------------------------------------------------------ the model */
enum { K_SIGP = 0, K_SIGC = 1, K_SIGN = 2, K_REF = 3, K_RUN = 4 };

/* p of a 1 from a counter's stored value */
#define CP(v) ((uint32_t)((v) ^ 0x8000))

KM_INLINE void learn(ctr_t *c, int bit)
{
  /* p stays in [1, 65535]: a step is at most 2/3 of the distance to it */
  uint32_t p = CP(c->p), n = c->n, d = bit ? 65535 - p : p - 1;
  int32_t f = (int32_t)CP(c->f);
  uint32_t step = (d * (uint32_t)J2KM_RC[n]) >> 16;
  p = bit ? p + step : p - step;
  c->p = (uint16_t)(p ^ 0x8000);
  c->n = (uint8_t)(n + (n < KM_LIMIT));
  f += ((bit ? 65535 : 0) - f) >> KM_FAST;
  c->f = (uint16_t)((uint32_t)f ^ 0x8000);
}

/* one event: its contexts' values v[0..NC), the mixer's sets, the maps'
   contexts; the bit coded (enc) or decoded */
KM_INLINE int mix_code(j2km_t *m, const int dec, int bit, const uint32_t *v, int sa, int sb, int sc, int a0, int a1, int a2)
{
  ctr_t *c[NC]; int32_t s[NW] __attribute__((aligned(32))); int i; int32_t da = 0, db = 0, x, pm, pa0, pa1, pa2, pf, pos, lo, fr, ea, eb, la, lb;
  int32_t *wa = m->wa[sa], *wb = m->wb[sb], *wc = m->wc[sc], dc = 0, ec, lc; uint16_t *t0 = m->apm0[a0], *t1 = m->apm1[a1], *t2 = m->apm2[a2];
  for (i = 0; i < NC; i++) {
    uint32_t idx = v[i];
    if (RANGE(i) > m->tsize[i]) idx = ((idx + 1) * 0x9E3779B1u) >> m->hshift;
    c[i] = m->t[i] + idx;
    /* an unseen counter is at 1/2, whose stretch is 0 */
    s[2 * i] = J2KM_ST[CP(c[i]->p) >> 4]; s[2 * i + 1] = J2KM_ST[CP(c[i]->f) >> 4];
  }
  for (i = 0; i < NW; i++) da += s[i] * wa[i];
  for (i = 0; i < NW; i++) db += s[i] * wb[i];
  for (i = 0; i < NW; i++) dc += s[i] * wc[i];
  dc = clampi(truncshr(dc, 16), -3071, 3071);
  da = clampi(truncshr(da, 16), -3071, 3071); db = clampi(truncshr(db, 16), -3071, 3071);
  x = truncshr((da + db + dc) * 21846, 16);
  pm = J2KM_SQ[x + 3072];
  pos = (clampi(x, -2047, 2047) + 2048) * 32; lo = pos >> 12; fr = pos & 4095;
  pa0 = (t0[lo] * (4096 - fr) + t0[lo + 1] * fr) >> 12;
  pa1 = (t1[lo] * (4096 - fr) + t1[lo + 1] * fr) >> 12;
  pa2 = (t2[lo] * (4096 - fr) + t2[lo + 1] * fr) >> 12;
  pf = (pm + pa0 + pa1 + pa2) >> 2;
  bit = ac_code(&m->ac, (uint32_t)pf, bit, dec);
  /* the updates */
  ea = ((bit << 16) - (int32_t)J2KM_SQ[da + 3072]) >> 4;
  eb = ((bit << 16) - (int32_t)J2KM_SQ[db + 3072]) >> 4;
  la = m->lr[m->ca[sa] >> 6]; lb = m->lr[m->cb[sb] >> 6];
  m->ca[sa] += m->ca[sa] < 65535; m->cb[sb] += m->cb[sb] < 65535;
  ea *= la; eb *= lb;
  for (i = 0; i < NW; i++) wa[i] = clampi(wa[i] + truncshr(s[i] * ea, 16), -WMAX, WMAX);
  for (i = 0; i < NW; i++) wb[i] = clampi(wb[i] + truncshr(s[i] * eb, 16), -WMAX, WMAX);
  ec = ((bit << 16) - (int32_t)J2KM_SQ[dc + 3072]) >> 4;
  lc = m->lr[m->cc[sc] >> 6]; m->cc[sc] += m->cc[sc] < 65535;
  ec *= lc;
  for (i = 0; i < NW; i++) wc[i] = clampi(wc[i] + truncshr(s[i] * ec, 16), -WMAX, WMAX);
  {
    int32_t tg = bit ? 65535 : 0;
    t0[lo] = (uint16_t)(t0[lo] + truncshr((tg - t0[lo]) * (4096 - fr) >> 6, 6 + KM_APMR));
    t0[lo + 1] = (uint16_t)(t0[lo + 1] + truncshr((tg - t0[lo + 1]) * fr >> 6, 6 + KM_APMR));
    t1[lo] = (uint16_t)(t1[lo] + truncshr((tg - t1[lo]) * (4096 - fr) >> 6, 6 + KM_APMR));
    t1[lo + 1] = (uint16_t)(t1[lo + 1] + truncshr((tg - t1[lo + 1]) * fr >> 6, 6 + KM_APMR));
    t2[lo] = (uint16_t)(t2[lo] + truncshr((tg - t2[lo]) * (4096 - fr) >> 6, 6 + KM_APMR));
    t2[lo + 1] = (uint16_t)(t2[lo + 1] + truncshr((tg - t2[lo + 1]) * fr >> 6, 6 + KM_APMR));
  }
  for (i = 0; i < NC; i++) learn(c[i], bit);
  return bit;
}

#define RI(x, y) m->R[((y) + 2) * m->rw + (x) + 2]

/* an event of kind k at (x, y) of plane B; sd the standard context's index
   (R_SD of them), rc whether it is in a run (1) or after one (2) */
KM_INLINE int event(j2km_t *m, const int dec, int bit, int k, int x, int y, int B, int sd, int rc)
{
  const int32_t *R = m->R; int rw = m->rw, i = (y + 2) * rw + x + 2, pi = y * m->w + x;
  uint64_t n4 = (uint64_t)ab(R[i - 1]) + ab(R[i + 1]) + ab(R[i - rw]) + ab(R[i + rw]);
  uint64_t nd = (uint64_t)ab(R[i - rw - 1]) + ab(R[i - rw + 1]) + ab(R[i + rw - 1]) + ab(R[i + rw + 1]);
  uint64_t n2 = (uint64_t)ab(R[i - 2]) + ab(R[i + 2]) + ab(R[i - 2 * rw]) + ab(R[i + 2 * rw]);
  uint64_t nsum = 2 * n4 + nd;
  int ln = qlog_or(nsum, 2 * B + 2, -6, 12, -7);
  int ln2 = qlog_or(n2, 2 * B, -4, 8, -5);
  int lp = -9, lps = 0, lx = -9, lxs = 0, depth = clampi(m->mbc - B, 0, 20), orl = m->orient * 16 + m->lvl;
  int lnI, lpI, lxI, ext = 0, sa, sb, a0, a1, j;
  uint32_t v[NC], K = (uint32_t)k;
  if (m->haveP) { int q = m->PQ[pi]; lps = m->PS[pi]; if (q > -100) lp = clampi(q + m->pqoff - 2 * B, -8, 8); }
  if (m->haveX) { int q = m->XQ[pi]; lxs = m->XS[pi]; if (q > -100) lx = clampi(q + m->xqoff - 2 * B, -8, 8); }
  lnI = ln + 7; lpI = lp + 9; lxI = lx + 9;
  if (k == K_SIGP || k == K_SIGC) {
    int nsig = (R[i - 1] != 0) + (R[i + 1] != 0) + (R[i - rw] != 0) + (R[i + rw] != 0) + (R[i - rw - 1] != 0) +
      (R[i - rw + 1] != 0) + (R[i + rw - 1] != 0) + (R[i + rw + 1] != 0);
    v[0] = (sd * R_RC + rc) * R_R;
    v[1] = (sd * R_LN + lnI) * R_RC + rc;
    v[2] = ((lnI * R_LP + lxI) * R_CMP + m->comp) * 4 + m->orient;
    v[3] = (((uint32_t)sd * R_LP + lpI) * R_LP + lxI) * R_DEP * R_CMP + depth * R_CMP + m->comp;
    v[4] = ((((uint32_t)nsig * R_LN2 + (ln2 + 5)) * R_LN + lnI) * R_RC + rc) * 4 + m->orient;
    v[5] = (((uint32_t)lnI * R_DEP + depth) * R_ORL + orl) * R_CMP + m->comp;
    v[6] = ((((uint32_t)lpI * R_LP + lxI) * R_LN + lnI) * R_LN2 + (ln2 + 5)) * 4 + m->orient;
  } else if (k == K_SIGN) {
    int sl = sgn3(R[i - 1]) + 1, su = sgn3(R[i - rw]) + 1, sr = sgn3(R[i + 1]) + 1, sbl = sgn3(R[i + rw]) + 1;
    int sul = sgn3(R[i - rw - 1]) + 1, sur = sgn3(R[i - rw + 1]) + 1;
    ext = sl * 3 + su;
    v[0] = sd;
    v[1] = ((sl * 27 + su * 9 + sr * 3 + sbl) * 3 + sul) * 4 + m->orient;
    v[2] = (((lxs + 1) * R_CMP + m->comp) * 9 + ext) * 4 + m->orient;
    v[3] = (((lps + 1) * 9 + sul * 3 + sur) * 9 + ext) * R_ORL + orl;
    v[4] = (sd * R_LN + lnI) * R_ORL + orl;
    v[5] = (((ext * 3 + lps + 1) * 3 + lxs + 1) * 9 + sr * 3 + sbl) * 4 + m->orient;
    v[6] = (sd * 3 + lps + 1) * 3 + lxs + 1;
  } else {
    uint32_t me = ab(R[i]);
    int r = clampi(ilog2_64(me ? me : 1) - B, 1, 8) - 1;
    int rel = sel(me != 0, clampi(q2log(nsum + 1) - q2log(me | (me == 0)), -8, 8), 0);
    int mb = (int)((me >> (B > 0 ? B - 1 : 0)) & 7);
    ext = r;
    v[0] = sd * R_RC * R_R + r;
    v[1] = (r * R_LN + lnI) * 4 + m->orient;
    v[2] = (r * R_REL + rel + 8) * R_ORL + orl;
    v[3] = ((sd * R_R + r) * R_DEP + depth) * R_CMP + m->comp;
    v[4] = ((r * R_REL + rel + 8) * R_LP + lpI) * R_LN2 + ln2 + 5;
    v[5] = ((r * R_MB + mb) * R_LN + lnI) * R_ORL + orl;
    v[6] = ((r * R_REL + rel + 8) * R_LP + lxI) * R_CMP + m->comp;
  }
  v[7] = (((((uint32_t)lnI * R_LP + lpI) * R_LP + lxI) * 11 + (depth >> 1)) * R_EXT + ext) * 4 + m->orient;
  for (j = 0; j < NC; j++) {
#ifdef KM_CHECK
    if (v[j] >= (uint32_t)PK[j]) __builtin_trap();
#endif
    v[j] += K * (uint32_t)PK[j];
  }
  sa = (k * 20 + lnI) * 24 + clampi(depth, 0, 23);
  sb = (k * 12 + sd) * 18 + clampi(lpI, 0, 17);
  a0 = k * 20 + lnI;
  a1 = (k * 18 + lpI) * 18 + lxI;
  return mix_code(m, dec, bit, v, sa, sb, (k * 64 + orl) * 4 + m->comp, a0, a1, (k * 12 + sd) * 21 + depth);
}

/* whether any of the four coefficients of a run (column x, rows y0 to y0 +
   3) becomes significant: none of them nor their neighbours in the
   code-block is, so what is around (two away, and outside the code-block),
   the parent, the other components and how many runs before it in the
   stripe came to nothing (rl) say what can be said */
KM_INLINE int event_run(j2km_t *m, const int dec, int bit, int x, int y0, int B, int rl)
{
  const int32_t *R = m->R; int rw = m->rw, i0 = (y0 + 2) * rw + x + 2, pi = y0 * m->w + x, k, j, dx;
  uint64_t sw = 0; uint32_t v[NC], K = K_RUN;
  int lw, lp = -9, lx = -9, depth = clampi(m->mbc - B, 0, 20), orl = m->orient * 16 + m->lvl, lwI, lpI, lxI;
  int sa, sb, a0, a1, a2, pos;
  for (k = -2; k < 6; k++)
    for (dx = -2; dx <= 2; dx++) sw += ab(R[i0 + k * rw + dx]);
  lw = qlog_or(sw, 2 * B + 2, -6, 12, -7);
  for (k = 0; k < 4; k++) {
    if (m->haveP && m->PQ[pi + k * m->w] > -100) { j = clampi(m->PQ[pi + k * m->w] + m->pqoff - 2 * B, -8, 8); if (j > lp) lp = j; }
    if (m->haveX && m->XQ[pi + k * m->w] > -100) { j = clampi(m->XQ[pi + k * m->w] + m->xqoff - 2 * B, -8, 8); if (j > lx) lx = j; }
  }
  lwI = lw + 7; lpI = lp + 9; lxI = lx + 9;
  pos = (x == 0) | (x == m->w - 1) << 1 | (y0 == 0) << 2 | (y0 + 4 >= m->h) << 3;
  v[0] = rl * R_LN + lwI;
  v[1] = (lwI * R_LP + lpI) * R_ORL + orl;
  v[2] = (lpI * R_LP + lxI) * R_DEP + depth;
  v[3] = ((lwI * R_DEP + depth) * 8 + rl) * R_CMP + m->comp;
  v[4] = (pos * R_LN + lwI) * R_ORL + orl;
  v[5] = (((uint32_t)lwI * R_DEP + depth) * R_ORL + orl) * R_CMP + m->comp;
  v[6] = ((((uint32_t)lpI * R_LP + lxI) * R_LN + lwI) * 8 + rl) * 4 + m->orient;
  v[7] = (((((uint32_t)lwI * R_LP + lpI) * R_LP + lxI) * 11 + (depth >> 1)) * R_EXT + rl) * 4 + m->orient;
  for (j = 0; j < NC; j++) {
#ifdef KM_CHECK
    if (v[j] >= (uint32_t)PK[j]) __builtin_trap();
#endif
    v[j] += K * (uint32_t)PK[j];
  }
  sa = (K_RUN * 20 + lwI) * 24 + clampi(depth, 0, 23);
  sb = (K_RUN * 12 + rl) * 18 + clampi(lpI, 0, 17);
  a0 = K_RUN * 20 + lwI;
  a1 = (K_RUN * 18 + lpI) * 18 + lxI;
  a2 = (K_RUN * 12 + rl) * 21 + depth;
  return mix_code(m, dec, bit, v, sa, sb, (K_RUN * 64 + orl) * 4 + m->comp, a0, a1, a2);
}

/* a decision of no context of the model's: SEGMARK's, by its place j */
KM_INLINE int event_misc(j2km_t *m, const int dec, int bit, int j)
{
  ctr_t *c = &m->misc[j];
  uint32_t p = CP(c->p);
  bit = ac_code(&m->ac, p, bit, dec);
  learn(c, bit);
  return bit;
}

/* ------------------------------------------------------------------ the decisions */
/* encoding: the next decision's bit, which must be of context ctx (a
   decision given with context 127 is not checked); decoding: written */
KM_INLINE int take(j2km_t *m, int ctx)
{
  int c;
  if (m->ns >= m->cap) { m->err = 1; return 0; }
  c = m->sym[m->ns++];
  if ((c >> 1) != 127 && (c >> 1) != ctx) { m->err = 3; return 0; }
  return c & 1;
}
KM_INLINE void give(j2km_t *m, int ctx, int bit)
{
  if (m->ns >= m->cap) { m->err = 1; return; }
  m->sym[m->ns++] = (uint8_t)((ctx << 1) | bit);
}

/* the coefficient at (x, y), i in st, becomes significant at plane B */
KM_INLINE void set_sig(j2km_t *m, uint8_t *st, uint8_t *nb, int i, int stride, int x, int y, int B, int neg)
{
  int32_t v = (int32_t)((1u << B) | (B > 0 ? 1u << (B - 1) : 0));
  make_sig(st, nb, i, stride, neg);
  RI(x, y) = neg ? -v : v;
}

KM_INLINE void sign_step(j2km_t *m, uint8_t *st, uint8_t *nb, int i, int stride, int excl, int x, int y, int B,
  int raw, const int dec)
{
  int xr, cx = sc_ctx(st, i, stride, excl, &xr), neg, sd = raw ? 10 : (cx - 9) * 2 + xr;
  if (raw) xr = 0;
  if (!dec) neg = take(m, raw ? 19 : cx) ^ xr;
  else neg = 0;
  neg = event(m, dec, neg, K_SIGN, x, y, B, sd, 0);
  if (dec) give(m, raw ? 19 : cx, neg ^ xr);
  set_sig(m, st, nb, i, stride, x, y, B, neg);
}

KM_INLINE void pass_spp(j2km_t *m, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int B,
  int raw, const int dec)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int mk, cx, b;
        if (st[i] & SIG) continue;
        mk = nb[i];
        if (causal && (y & 3) == 3) mk &= ~SOUTH;
        if (!mk) continue;
        st[i] |= PIV;
        cx = raw ? 19 : zc[mk];
        b = dec ? 0 : take(m, cx);
        b = event(m, dec, b, K_SIGP, x, y, B, raw ? 9 : zc[mk], 0);
        if (dec) give(m, cx, b);
        if (b) sign_step(m, st, nb, i, stride, causal && (y & 3) == 3, x, y, B, raw, dec);
      }
      if (m->err) return;
    }
  }
}

KM_INLINE void pass_mrp(j2km_t *m, uint8_t *st, uint8_t *nb, int w, int h, int causal, int B, int raw, const int dec)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int mk, cx, b;
        int32_t half = B > 0 ? (int32_t)1 << (B - 1) : 0, v;
        if ((st[i] & (SIG | PIV)) != SIG) continue;
        mk = nb[i];
        if (causal && (y & 3) == 3) mk &= ~SOUTH;
        cx = (st[i] & REF) ? 16 : mk ? 15 : 14;
        b = dec ? 0 : take(m, raw ? 19 : cx);
        b = event(m, dec, b, K_REF, x, y, B, raw ? 3 : cx - 14, 0);
        if (dec) give(m, raw ? 19 : cx, b);
        st[i] |= REF;
        v = RI(x, y);
        if (v < 0) v -= b ? half : -half; else v += b ? half : -half;
        RI(x, y) = v;
      }
      if (m->err) return;
    }
  }
}

KM_INLINE void pass_cup(j2km_t *m, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int segmark,
  int B, const int dec)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h, rl = 0;
    for (x = 0; x < w; x++) {
      int i0 = (y0 + 1) * stride + x + 1, i, rc = 0;
      y = y0;
      if (y1 - y0 == 4 && !(st[i0] | st[i0 + stride] | st[i0 + 2 * stride] | (st[i0 + 3 * stride] & (SIG | PIV))) &&
          !(nb[i0] | nb[i0 + stride] | nb[i0 + 2 * stride] | (nb[i0 + 3 * stride] & (causal ? ~SOUTH : 0xFF)))) {
        /* run-length mode: whether any of the four becomes significant, and
           if one does, the significance of each up to the first that is */
        /* rl's bucket: 0, 1, 2-3, 4-7, .., 32-63, 64 and more */
        int r = 4, k, rq = sel(rl, clampi(ilog2_64((uint64_t)(rl | 1)) + 1, 0, 7), 0);
        if (!dec) {
          if (take(m, 17)) { r = take(m, 18) << 1; r |= take(m, 18); }
          if (m->err) return;
          event_run(m, 0, r < 4, x, y0, B, rq);
          for (k = 0; k < 3 && k <= r && r < 4; k++)
            event(m, 0, k == r, K_SIGC, x, y0 + k, B, 0, 1);
        } else {
          if (event_run(m, 1, 0, x, y0, B, rq)) {
            r = 3;
            for (k = 0; k < 3; k++)
              if (event(m, 1, 0, K_SIGC, x, y0 + k, B, 0, 1)) { r = k; break; }
          }
          give(m, 17, r < 4);
          if (r < 4) { give(m, 18, r >> 1); give(m, 18, r & 1); }
        }
        if (r == 4) { rl++; continue; }
        rl = 0;
        y = y0 + r;
        sign_step(m, st, nb, i0 + r * stride, stride, causal && (y & 3) == 3, x, y, B, 0, dec);
        y++; rc = 2;
      }
      if (rc == 0) rl = 0;
      for (i = i0 + (y - y0) * stride; y < y1; y++, i += stride) {
        int mk, b;
        if (st[i] & (SIG | PIV)) continue;
        mk = nb[i];
        if (causal && (y & 3) == 3) mk &= ~SOUTH;
        b = dec ? 0 : take(m, zc[mk]);
        b = event(m, dec, b, K_SIGC, x, y, B, zc[mk], rc);
        if (dec) give(m, zc[mk], b);
        if (b) sign_step(m, st, nb, i, stride, causal && (y & 3) == 3, x, y, B, 0, dec);
      }
      if (m->err) return;
    }
  }
  for (y = 0; y < h; y++) {
    uint8_t *p = st + (y + 1) * stride + 1;
    for (x = 0; x < w; x++) p[x] &= (uint8_t)~PIV;
  }
  if (segmark) {
    int k;
    for (k = 0; k < 4; k++) {
      int b = dec ? 0 : take(m, 18);
      b = event_misc(m, dec, b, k);
      if (dec) give(m, 18, b);
    }
  }
}

KM_INLINE int64_t run_cb(j2km_t *m, int32_t w, int32_t h, int32_t sty, int32_t npasses, int32_t top, int32_t *passend,
  const int dec)
{
  int k, causal = (sty & 8) != 0; int64_t n = (int64_t)(w + 2) * (h + 2), i;
  uint8_t *st = m->st, *nb = m->st + n; const uint8_t *zc = ZC[m->orient];
  for (i = 0; i < 2 * n; i++) st[i] = 0;
  for (k = 0; k < npasses; k++) {
    int type = k == 0 ? 2 : (k - 1) % 3;
    int raw = (sty & 1) && k >= 10 && type < 2;
    int B = clampi(top - (k + 2) / 3, 0, 30);
    if (type == 0) pass_spp(m, st, nb, w, h, zc, causal, B, raw, dec);
    else if (type == 1) pass_mrp(m, st, nb, w, h, causal, B, raw, dec);
    else pass_cup(m, st, nb, w, h, zc, causal, (sty & 32) != 0, B, dec);
    if (m->err) return m->err == 1 ? -1 : m->err == 3 ? -5 : -2;
    passend[k] = (int32_t)m->ns;
  }
  return m->ns;
}

/* The passes compiled once for each direction, and again on x86 for SSE4.1
   and for AVX2 (the mixer's 16 lanes in pmulld, pminsd and pmaxsd), taken
   when pjamodel's cpuid says so (pjaj2km_path, from UseSse41 and UseAvx2,
   which PJA_NOASM=1 and PJA_NOAVX2=1 turn off): the same C, the same
   integer arithmetic, so the same bits on every path. */
#define KM_COPY(SUF, ATTR) \
  ATTR static int64_t run_cb_e##SUF(j2km_t *m, int32_t w, int32_t h, int32_t sty, int32_t np, int32_t top, \
    int32_t *passend) { return run_cb(m, w, h, sty, np, top, passend, 0); } \
  ATTR static int64_t run_cb_d##SUF(j2km_t *m, int32_t w, int32_t h, int32_t sty, int32_t np, int32_t top, \
    int32_t *passend) { return run_cb(m, w, h, sty, np, top, passend, 1); }
KM_COPY(, )
#if (defined(__x86_64__) || defined(__i386__)) && !defined(PJA_V7_PLAIN) && (defined(__GNUC__) || defined(__clang__))
#define KM_SIMD 1
KM_COPY(_sse41, __attribute__((target("sse4.1"))))
KM_COPY(_avx2, __attribute__((target("avx2"))))
#endif

static int64_t run_path(j2km_t *m, int32_t w, int32_t h, int32_t sty, int32_t np, int32_t top, int32_t *passend)
{
#ifdef KM_SIMD
  if (m->path == 2) return m->enc ? run_cb_e_avx2(m, w, h, sty, np, top, passend) : run_cb_d_avx2(m, w, h, sty, np, top, passend);
  if (m->path == 1) return m->enc ? run_cb_e_sse41(m, w, h, sty, np, top, passend) : run_cb_d_sse41(m, w, h, sty, np, top, passend);
#endif
  return m->enc ? run_cb_e(m, w, h, sty, np, top, passend) : run_cb_d(m, w, h, sty, np, top, passend);
}

/* ------------------------------------------------------------------ the API */
static j2km_t *M(void *mem) { return (j2km_t *)(((uintptr_t)mem + 63) & ~(uintptr_t)63); }

/* a model with tables of at most 2^hb counters in mem (pjaj2km_size(hb)
   bytes, any alignment); encoding: its bytes go out through put(pctx, ..);
   decoding: from data[0..len), zeros past it. 0, or -1 when hb is not one
   or size is short. */
int32_t pjaj2km_init(void *mem, int64_t size, int32_t hb, int32_t encoding, km_put_t put, void *pctx,
  const uint8_t *data, int64_t len)
{
  j2km_t *m; int i, j; uint8_t *p; int64_t k, words;
  if (pjaj2km_size(hb) < 0 || size < pjaj2km_size(hb)) return -1;
  m = M(mem);
  /* everything zero: counters at 1/2, unseen */
  words = (pjaj2km_size(hb) - 64) / 8;
  { uint64_t *z = (uint64_t *)m; for (k = 0; k < words; k++) z[k] = 0; }
  p = (uint8_t *)(m + 1);
  for (i = 0; i < NC; i++) {
    m->tsize[i] = RANGE(i) < ((int64_t)1 << hb) ? RANGE(i) : ((int64_t)1 << hb);
    m->t[i] = (ctr_t *)p; p += m->tsize[i] * (int64_t)sizeof(ctr_t);
  }
  for (i = 0; i < NSA; i++) for (j = 0; j < NC; j++) m->wa[i][2 * j] = 65536 / NC;
  for (i = 0; i < NSB; i++) for (j = 0; j < NC; j++) m->wb[i][2 * j] = 65536 / NC;
  for (i = 0; i < NSC; i++) for (j = 0; j < NC; j++) m->wc[i][2 * j] = 65536 / NC;
  for (i = 0; i < NK * 24; i++) for (j = 0; j < 3; j++) m->w2[i][j] = 21846;
  for (i = 0; i < A0N; i++) for (j = 0; j < 33; j++) m->apm0[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  for (i = 0; i < A1N; i++) for (j = 0; j < 33; j++) m->apm1[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  for (i = 0; i < A2N; i++) for (j = 0; j < 33; j++) m->apm2[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  m->magc[0] = 0;
  for (i = 1; i < 64; i++) {
    int q = i - 1, l = q >> 1;
    m->magc[i] = (1u << (l > 30 ? 30 : l)) | ((q & 1) && l > 0 && l <= 30 ? 1u << (l - 1) : 0);
  }
  for (i = 0; i < 1024; i++) m->lr[i] = KM_LR1 + KM_LR0 / (1024 + 64 * i);
  m->hshift = 32 - hb;
  m->enc = encoding != 0;
  m->ac.x1 = 0; m->ac.x2 = 0xFFFFFFFFu; m->ac.x = 0; m->ac.put = put; m->ac.pctx = pctx; m->ac.n = 0;
  m->ac.d = data; m->ac.len = data ? len : 0; m->ac.p = 0;
  if (!m->enc)
    for (i = 0; i < 4; i++) {
      uint32_t b = m->ac.p < m->ac.len ? m->ac.d[m->ac.p] : 0;
      m->ac.p++; m->ac.x = (m->ac.x << 8) | b;
    }
  m->bands = 0; m->nb = 0; m->maps = 0; m->mapsize = 0; m->zcomp = -1;
  return 0;
}

/* the copy of the passes the model runs (after pjaj2km_init): 2 AVX2, 1
   SSE4.1, else the plain one; a copy this object does not have is not taken */
void pjaj2km_path(void *mem, int32_t path)
{
#ifdef KM_SIMD
  M(mem)->path = path == 1 || path == 2 ? path : 0;
#else
  (void)path; M(mem)->path = 0;
#endif
}

/* encoding: the last bytes out (x1, as pjaarith's Finish) */
void pjaj2km_finish(void *mem)
{
  j2km_t *m = M(mem); int k;
  for (k = 0; k < 4; k++) {
    m->ac.buf[m->ac.n++] = (uint8_t)(m->ac.x1 >> 24);
    if (m->ac.n == EBUF) { m->ac.put(m->ac.pctx, m->ac.buf, EBUF); m->ac.n = 0; }
    m->ac.x1 <<= 8;
  }
  if (m->ac.n) m->ac.put(m->ac.pctx, m->ac.buf, m->ac.n);
  m->ac.n = 0;
}

/* decoding: the bytes read so far, past the end too */
int64_t pjaj2km_used(void *mem) { return M(mem)->ac.p; }

/* a new tile: its bands (nb, kept until the next tile) and the maps' memory
   (mapsize bytes), zeroed here for the components 0 and 1; a band whose
   map does not fit has none */
void pjaj2km_tile(void *mem, const j2kmband_t *bands, int32_t nb, uint8_t *maps, int64_t mapsize)
{
  j2km_t *m = M(mem); int32_t b; int64_t k;
  m->bands = bands; m->nb = nb; m->maps = maps; m->mapsize = maps ? mapsize : 0; m->zcomp = -1;
  for (b = 0; b < nb; b++) {
    const j2kmband_t *g = &bands[b];
    if (g->map < 0 || g->comp > 1 || g->w <= 0 || g->h <= 0) continue;
    if (g->map + (int64_t)g->w * g->h > m->mapsize) continue;
    for (k = 0; k < (int64_t)g->w * g->h; k++) maps[g->map + k] = 0;
  }
}

static const uint8_t *band_map(const j2km_t *m, int32_t b)
{
  const j2kmband_t *g;
  if (b < 0 || b >= m->nb || !m->maps) return 0;
  g = &m->bands[b];
  if (g->map < 0 || g->w <= 0 || g->h <= 0 || g->map + (int64_t)g->w * g->h > m->mapsize) return 0;
  return m->maps + g->map;
}

/* the code-block at (x0, y0) of band b (w x h), its style, passes and zero
   bit-planes. Encoding: its decisions sym[0..n) (as pjaj2kt1.c gives them),
   coded; decoding: written to sym (at most n), and passend[k] how many
   there are after pass k. Returns how many, or -1 (more than n), -2 (bad
   arguments), -5 (a decision given is not the one the passes make). */
int64_t pjaj2km_cb(void *mem, int32_t b, int32_t x0, int32_t y0, int32_t w, int32_t h, int32_t sty, int32_t npasses,
  int32_t zbp, uint8_t *sym, int64_t n, int32_t *passend)
{
  j2km_t *m = M(mem); const j2kmband_t *g; const uint8_t *map, *pmap, *xm0, *xm1; int32_t x, y; int64_t r;
  if (b < 0 || b >= m->nb || w < 1 || h < 1 || w > 1024 || h > 1024 || (int64_t)w * h > CBMAX || npasses < 0 ||
      npasses > 255 || n < 0) return -2;
  g = &m->bands[b];
  if (g->orient < 0 || g->orient > 3) return -2;
  m->w = w; m->h = h; m->rw = w + 4; m->orient = g->orient; m->mbc = g->mb;
  m->lvl = clampi(g->nres - g->res, 0, 15); m->comp = clampi(g->comp, 0, 3);
  m->sym = sym; m->ns = 0; m->cap = n; m->err = 0;
  map = band_map(m, b);
  if (map && (x0 < 0 || y0 < 0 || (int64_t)x0 + w > g->w || (int64_t)y0 + h > g->h)) map = 0;
  /* a component past the second: its maps are reused, zeroed when it starts */
  if (map && g->comp > 1 && g->comp != m->zcomp) {
    int32_t k; int64_t j;
    m->zcomp = g->comp;
    for (k = 0; k < m->nb; k++)
      if (m->bands[k].comp == g->comp) {
        const uint8_t *q = band_map(m, k);
        if (q) for (j = 0; j < (int64_t)m->bands[k].w * m->bands[k].h; j++) m->maps[m->bands[k].map + j] = 0;
      }
  }
  /* the values around the code-block, as the maps have them (the two
     rows and columns around it inside the band; 0 elsewhere) */
  {
    int64_t k, nr = (int64_t)(h + 4) * m->rw;
    for (k = 0; k < nr; k++) m->R[k] = 0;
  }
  if (map)
    for (y = -2; y < h + 2; y++) {
      int64_t gy = (int64_t)y0 + y;
      const uint8_t *row;
      int inner = y >= 0 && y < h;
      if (gy < 0 || gy >= g->h) continue;
      row = map + gy * g->w;
      for (x = -2; x < w + 2; x++) {
        int64_t gx = (int64_t)x0 + x;
        if (inner && x == 0) { x = w - 1; continue; }
        if (gx >= 0 && gx < g->w) RI(x, y) = mapval(m, row[gx]);
      }
    }
  /* the parent and the other components */
  pmap = map ? band_map(m, g->parent) : 0;
  xm0 = map && g->comp > 0 ? band_map(m, g->cross0) : 0;
  xm1 = map && g->comp > 1 ? band_map(m, g->cross1) : 0;
  m->haveP = pmap != 0; m->haveX = xm0 != 0;
  if (pmap) {
    const j2kmband_t *pg = &m->bands[g->parent];
    for (x = 0; x < w; x++) m->colA[x] = muldiv((int64_t)x0 + x, pg->w, g->w);
    for (y = 0; y < h; y++) m->rowA[y] = muldiv((int64_t)y0 + y, pg->h, g->h);
    m->pqoff = -2 * pg->mb + 2 * g->mb - 4;
    /* a parent coefficient serves the coefficients it maps to (about four):
       a row or a column that maps where the one before it did is a copy */
    for (y = 0; y < h; y++) {
      int16_t *pq = m->PQ + y * w; int8_t *ps = m->PS + y * w;
      int32_t py = m->rowA[y], pw = pg->w, ph = pg->h;
      const uint8_t *r0, *ru, *rd;
      if (y > 0 && py == m->rowA[y - 1]) {
        for (x = 0; x < w; x++) { pq[x] = pq[x - w]; ps[x] = ps[x - w]; }
        continue;
      }
      r0 = pmap + (int64_t)py * pw; ru = pmap + (int64_t)(py > 0 ? py - 1 : py) * pw;
      rd = pmap + (int64_t)(py + 1 < ph ? py + 1 : py) * pw;
      for (x = 0; x < w; x++) {
        int32_t px = m->colA[x], pv;
        uint64_t s;
        if (x > 0 && px == m->colA[x - 1]) { pq[x] = pq[x - 1]; ps[x] = ps[x - 1]; continue; }
        pv = mapval(m, r0[px]);
        s = 2 * (uint64_t)ab(pv);
        s += ab(mapval(m, r0[px > 0 ? px - 1 : px]));
        s += ab(mapval(m, r0[px + 1 < pw ? px + 1 : px]));
        s += ab(mapval(m, ru[px]));
        s += ab(mapval(m, rd[px]));
        ps[x] = (int8_t)sgn3(pv);
        pq[x] = (int16_t)sel(s != 0, q2log(s | (s == 0)), -100);
      }
    }
  }
  if (xm0) {
    const j2kmband_t *g0 = &m->bands[g->cross0], *g1 = xm1 ? &m->bands[g->cross1] : 0;
    for (x = 0; x < w; x++) m->colB[x] = muldiv((int64_t)x0 + x, g0->w, g->w);
    for (y = 0; y < h; y++) m->rowB[y] = muldiv((int64_t)y0 + y, g0->h, g->h);
    if (g1) {
      for (x = 0; x < w; x++) m->colC[x] = muldiv((int64_t)x0 + x, g1->w, g->w);
      for (y = 0; y < h; y++) m->rowC[y] = muldiv((int64_t)y0 + y, g1->h, g->h);
    }
    m->xqoff = -2 * g0->mb + 2 * g->mb - 2;
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) {
        int32_t v0 = mapval(m, xm0[(int64_t)m->rowB[y] * g0->w + m->colB[x]]);
        uint64_t s = 2 * (uint64_t)ab(v0);
        if (g1) s += 2 * (uint64_t)ab(mapval(m, xm1[(int64_t)m->rowC[y] * g1->w + m->colC[x]]));
        m->XS[y * w + x] = (int8_t)sgn3(v0);
        m->XQ[y * w + x] = (int16_t)sel(s != 0, q2log(s | (s == 0)), -100);
      }
  }
  r = run_path(m, w, h, sty, npasses, g->mb - zbp, passend);
  if (r >= 0 && m->enc && r != n) r = -5;
  /* the code-block's values into its band's map */
  if (r >= 0 && map) {
    uint8_t *wm = m->maps + g->map;
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) wm[((int64_t)y0 + y) * g->w + x0 + x] = mapcode(RI(x, y));
  }
  return r;
}

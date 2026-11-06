/* Stream version 8's mode 3: the values of an HTJ2K codestream's code-blocks
   (pjaj2kht.c's: the cleanup's magnitudes and signs, and with refinement
   passes SigProp's new significance and MagRef's bits) coded with a
   context-mixing model (doc/CODEC.md, "JPEG 2000, stage F"). Called
   through pjaj2kcs.pas, which owns every buffer: this file takes no memory
   and calls no library, as pjaj2kmc.c, whose counters, mixer, maps and
   arithmetic coder (pjaarith's) it uses as they are, with its own events
   and contexts.

   A code-block's samples are coded in raster order: whether the cleanup's
   magnitude mu is 0, its bit length (unary: more than 1, 2, ..), the bits
   below its top one, its sign; then, with refinement passes, each sample
   SigProp visits (the same rule as pjaj2kht.c's: an insignificant sample
   with a significant neighbour) whether it becomes significant and its
   sign, and each sample significant in the cleanup its MagRef bit. The
   model sees the values known so far as magnitudes in the code-block's
   unit (2^B for the cleanup's plane B, 2^(B - 1) with refinement passes):
   in the code-block the samples already coded, around it the code-blocks
   of the band already coded, the band one resolution coarser (the parent)
   and the first two components' band of the same resolution and
   orientation (the maps, one byte a sample, as pjaj2kmc.c's).

   Determinism: integer arithmetic only, the tables of pjaj2km_tab.h.
   Build with -fwrapv (pas/build_c.sh). */
#include <stdint.h>
#include "pjaj2km_tab.h"
#ifdef HM_STATS
/* tuning only: the bits each kind of event costs, printed at the end of each slice */
#include <stdio.h>
#include <math.h>
static double hm_cost[16]; static long hm_n[16]; static int hm_kind;
#define HM_COST(p16, bit) do { double pp = (p16) / 65536.0; if (pp < 1e-9) pp = 1e-9; if (pp > 1 - 1e-9) pp = 1 - 1e-9; \
  hm_cost[hm_kind] += (bit) ? -log2(pp) : -log2(1 - pp); hm_n[hm_kind]++; } while (0)
#define HM_KIND(k) (hm_kind = (k))
#else
#define HM_COST(p16, bit) ((void)0)
#define HM_KIND(k) ((void)0)
#endif

#if defined(__GNUC__) || defined(__clang__)
#define HM_INLINE static inline __attribute__((always_inline))
#else
#define HM_INLINE static inline
#endif

/* ------------------------------------------------------------------ parameters (part of the format) */
#define HM_LIMIT 255
#define HM_FAST 3
#define HM_APMR 6
#define HM_LR0 31457
#define HM_LR1 6
#define HM_HBMIN 10
#define HM_HBMAX 20
#define NC 8
#define NW (2 * NC)
#define WMAX (1 << 22)
#define NK 7                /* kinds of event */
enum { K_Z = 0, K_L = 1, K_M = 2, K_S = 3, K_P = 4, K_R = 5, K_N = 6 };
#define NSA (NK * 42 * 24)  /* weight sets A: kind, neighbours, depth */
#define NSB (NK * 32 * 18)  /* B: kind, aux, parent */
#define NSC (NK * 64 * 4)   /* C: kind, orientation and level, component */
#define A0N (NK * 42)
#define A1N (NK * 18 * 18)
#define A2N (NK * 32 * 24)

#define CBMAX 4096
#define RMAX (CBMAX + 4 * 1028 + 16 * 4 + 64)

typedef struct {
  int32_t comp, res, orient, nres, w, h, mb, parent, cross0, cross1;
  int64_t map;
} hmband_t;

typedef struct { uint16_t p, f; uint8_t n, pad; } ctr_t;
typedef void (*hm_put_t)(void *ctx, const uint8_t *b, intptr_t n);

#define EBUF 4096
typedef struct {
  uint32_t x1, x2, x;
  hm_put_t put; void *pctx; int32_t n;
  const uint8_t *d; int64_t len, p;
  uint8_t buf[EBUF];
} ac_t;

typedef struct {
  ac_t ac;
  int32_t enc;
  int64_t tsize[NC];
  ctr_t *t[NC];
  int32_t wa[NSA][NW] __attribute__((aligned(32))), wb[NSB][NW] __attribute__((aligned(32)));
  int32_t wc[NSC][NW] __attribute__((aligned(32)));
  uint16_t ca[NSA], cb[NSB], cc[NSC];
  int32_t lr[1024];
  int32_t hshift;
  uint16_t apm0[A0N][33], apm1[A1N][33], apm2[A2N][33];
  ctr_t low[32 * 32 * 2];          /* the mantissas' lower bits: by length and place */
  /* the tile */
  const hmband_t *bands; int32_t nb; uint8_t *maps; int64_t mapsize; int32_t zcomp;
  /* the code-block */
  int32_t w, h, rw, orient, lvl, comp, dep, haveP, haveX, Bq;
  int32_t pqoff, xqoff;
  int32_t R[RMAX];                 /* signed magnitudes x 2 in the unit (0: none), with a border of 2 */
  uint8_t flg[CBMAX];
  int16_t PQ[CBMAX], XQ[CBMAX];
  int8_t PS[CBMAX], XS[CBMAX];
  int32_t colA[1024], rowA[1024], colB[1024], rowB[1024], colC[1024], rowC[1024];
  int32_t newl[16];
} hm_t;

/* ------------------------------------------------------------------ the arithmetic coder (pjaarith's) */
HM_INLINE int ac_code(ac_t *a, uint32_t p16, int bit, const int dec)
{
  uint32_t xm;
  if (p16 < 1) p16 = 1; else if (p16 > 65535) p16 = 65535;
  xm = a->x1 + (uint32_t)(((uint64_t)(a->x2 - a->x1) * p16) >> 16);
  if (dec) bit = a->x <= xm;
  if (bit) a->x2 = xm; else a->x1 = xm + 1;
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

static inline int clampi(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline uint32_t ab(int32_t v) { return v < 0 ? 0u - (uint32_t)v : (uint32_t)v; }
static inline int ilog2_64(uint64_t v)
{
  uint32_t hi = (uint32_t)(v >> 32);
  return hi ? 63 - __builtin_clz(hi) : 31 - __builtin_clz((uint32_t)v);
}
static inline int q2log(uint64_t v)
{
  int l = ilog2_64(v);
  return 2 * l + (l > 0 ? (int)((v >> (l - 1)) & 1) : 0);
}
static inline int sgn3(int32_t v) { return v > 0 ? 1 : v < 0 ? -1 : 0; }
static inline int32_t truncshr(int32_t x, int n) { return (x + ((x >> 31) & ((1 << n) - 1))) >> n; }
static inline int bitlen32(uint32_t x) { return x ? 32 - __builtin_clz(x) : 0; }

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

/* a map's byte: 0, or floor(2 log2 a) + 1 for a = |value| in half units of
   the band (at most 127), and 128 when it is negative */
static inline uint8_t mapcode(int32_t r2, int32_t Bq)
{
  int c;
  if (!r2) return 0;
  c = q2log(ab(r2)) + 2 * Bq + 1;
  if (c > 127) c = 127;
  if (c < 1) c = 1;
  return (uint8_t)(c | (r2 < 0 ? 128 : 0));
}
/* the magnitude x 2 in units of 2^Bq of a map's byte */
static inline int32_t mapval(uint8_t c, int32_t Bq)
{
  int l, e; int32_t mant, v;
  if (!(c & 127)) return 0;
  l = (c & 127) - 1; e = (l >> 1) - 1 - Bq; mant = (l & 1) ? 3 : 2;
  if (e >= 0) v = mant << (e > 28 ? 28 : e);
  else v = -e > 31 ? 0 : mant >> -e;
  return c & 128 ? -v : v;
}

/* ------------------------------------------------------------------ sizes */
enum { R_LN = 42, R_LP = 18, R_DEP = 24, R_ORL = 64, R_CMP = 4, R_K = 32, R_W = 25 };
/* each context's values for one kind (the largest over the kinds) */
static const int64_t PK[NC] = {
  /* 0 */ (int64_t)R_K * R_LN * 5,
  /* 1 */ (int64_t)R_K * R_W * R_W * 4,
  /* 2 */ (int64_t)R_K * R_LN * R_LP * R_LP,
  /* 3 */ (int64_t)R_K * R_LN * 34 * 4,
  /* 4 */ (int64_t)R_K * R_LN * R_DEP * R_ORL * R_CMP,
  /* 5 */ (int64_t)R_K * 5 * R_LP * R_DEP,
  /* 6 */ (int64_t)R_K * 128 * 11 * 4,
  /* 7 */ (int64_t)R_K * R_LN * R_LP * R_DEP
};
#define RANGE(i) (PK[i] * NK)

static int64_t tables_size(int32_t hb)
{
  int i; int64_t n = 0;
  for (i = 0; i < NC; i++) n += RANGE(i) < ((int64_t)1 << hb) ? RANGE(i) : ((int64_t)1 << hb);
  return n * (int64_t)sizeof(ctr_t);
}

int64_t pjaj2khm_size(int32_t hb)
{
  if (hb < HM_HBMIN || hb > HM_HBMAX) return -1;
  return (int64_t)sizeof(hm_t) + 64 + tables_size(hb);
}

#define CP(v) ((uint32_t)((v) ^ 0x8000))

HM_INLINE void learn(ctr_t *c, int bit)
{
  uint32_t p = CP(c->p), n = c->n, d = bit ? 65535 - p : p - 1;
  int32_t f = (int32_t)CP(c->f);
  uint32_t step = (d * (uint32_t)J2KM_RC[n]) >> 16;
  p = bit ? p + step : p - step;
  c->p = (uint16_t)(p ^ 0x8000);
  c->n = (uint8_t)(n + (n < HM_LIMIT));
  f += ((bit ? 65535 : 0) - f) >> HM_FAST;
  c->f = (uint16_t)((uint32_t)f ^ 0x8000);
}

HM_INLINE int mix_code(hm_t *m, const int dec, int bit, const uint32_t *v, int sa, int sb, int sc, int a0, int a1, int a2)
{
  ctr_t *c[NC]; int32_t s[NW] __attribute__((aligned(32))); int i; int32_t da = 0, db = 0, x, pm, pa0, pa1, pa2, pf, pos, lo, fr, ea, eb, la, lb;
  int32_t *wa = m->wa[sa], *wb = m->wb[sb], *wc = m->wc[sc], dc = 0, ec, lc; uint16_t *t0 = m->apm0[a0], *t1 = m->apm1[a1], *t2 = m->apm2[a2];
  for (i = 0; i < NC; i++) {
    uint32_t idx = v[i];
    if (RANGE(i) > m->tsize[i]) idx = ((idx + 1) * 0x9E3779B1u) >> m->hshift;
    c[i] = m->t[i] + idx;
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
  if (m->enc) HM_COST(pf < 1 ? 1 : pf > 65535 ? 65535 : pf, bit);
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
    t0[lo] = (uint16_t)(t0[lo] + truncshr((tg - t0[lo]) * (4096 - fr) >> 6, 6 + HM_APMR));
    t0[lo + 1] = (uint16_t)(t0[lo + 1] + truncshr((tg - t0[lo + 1]) * fr >> 6, 6 + HM_APMR));
    t1[lo] = (uint16_t)(t1[lo] + truncshr((tg - t1[lo]) * (4096 - fr) >> 6, 6 + HM_APMR));
    t1[lo + 1] = (uint16_t)(t1[lo + 1] + truncshr((tg - t1[lo + 1]) * fr >> 6, 6 + HM_APMR));
    t2[lo] = (uint16_t)(t2[lo] + truncshr((tg - t2[lo]) * (4096 - fr) >> 6, 6 + HM_APMR));
    t2[lo + 1] = (uint16_t)(t2[lo + 1] + truncshr((tg - t2[lo + 1]) * fr >> 6, 6 + HM_APMR));
  }
  for (i = 0; i < NC; i++) learn(c[i], bit);
  return bit;
}

/* a bit with one counter of its own */
HM_INLINE int code_low(hm_t *m, const int dec, int bit, int j)
{
  ctr_t *c = &m->low[j];
  HM_KIND(7);
  bit = ac_code(&m->ac, CP(c->p), bit, dec);
  if (m->enc) HM_COST(CP(c->p) < 1 ? 1 : CP(c->p), bit);
  learn(c, bit);
  return bit;
}

#define RI(x, y) m->R[((y) + 2) * m->rw + (x) + 2]

/* the features around (x, y) */
typedef struct { int lnI, ln2I, nsig, wI, nI, lpI, lxI, mxI, pat, sP, sX; } feat_t;

HM_INLINE int lgI(uint64_t v, int top) { return v ? clampi(q2log(v), 0, top - 2) + 1 : 0; }

HM_INLINE void features(const hm_t *m, int x, int y, feat_t *f)
{
  const int32_t *R = m->R; int rw = m->rw, i = (y + 2) * rw + x + 2, pi = y * m->w + x;
  uint32_t W_ = ab(R[i - 1]), N_ = ab(R[i - rw]), NW_ = ab(R[i - rw - 1]), NE_ = ab(R[i - rw + 1]);
  uint32_t WW = ab(R[i - 2]), NN = ab(R[i - 2 * rw]), E_ = ab(R[i + 1]), S_ = ab(R[i + rw]);
  uint32_t mx = W_ > N_ ? W_ : N_;
  uint64_t s = 2 * ((uint64_t)W_ + N_) + NW_ + NE_ + E_ + S_ + ((uint64_t)WW + NN) / 2;
  if (NW_ > mx) mx = NW_;
  if (NE_ > mx) mx = NE_;
  f->lnI = lgI(s, R_LN);
  f->ln2I = lgI((uint64_t)WW + NN + ab(R[i - rw + 2]) + ab(R[i - rw - 2]), 34);
  f->nsig = (W_ != 0) + (N_ != 0) + (NW_ != 0) + (NE_ != 0);
  f->wI = lgI(W_, R_W); f->nI = lgI(N_, R_W); f->mxI = lgI(mx, R_LN);
  f->pat = (W_ != 0) | (N_ != 0) << 1 | (NW_ != 0) << 2 | (NE_ != 0) << 3 | (WW != 0) << 4 | (NN != 0) << 5 |
    (ab(R[i - rw + 2]) != 0) << 6;
  f->lpI = 0; f->lxI = 0; f->sP = 1; f->sX = 1;
  if (m->haveP) { int q = m->PQ[pi]; f->sP = m->PS[pi] + 1; if (q > -100) f->lpI = clampi(q + m->pqoff - 2 * m->Bq, -8, 8) + 9; }
  if (m->haveX) { int q = m->XQ[pi]; f->sX = m->XS[pi] + 1; if (q > -100) f->lxI = clampi(q + m->xqoff - 2 * m->Bq, -8, 8) + 9; }
}

/* an event of kind k, aux its own context (0 to R_K - 1) */
HM_INLINE int event(hm_t *m, const int dec, int bit, int k, int aux, const feat_t *f)
{
  uint32_t v[NC], K = (uint32_t)k, A = (uint32_t)aux; int j, orl = m->orient * 16 + m->lvl;
  HM_KIND(k);
  v[0] = (A * R_LN + f->lnI) * 5 + f->nsig;
  v[1] = ((A * R_W + clampi(f->wI, 0, R_W - 1)) * R_W + clampi(f->nI, 0, R_W - 1)) * 4 + m->orient;
  v[2] = ((A * R_LN + f->lnI) * R_LP + f->lpI) * R_LP + f->lxI;
  v[3] = ((A * R_LN + f->lnI) * 34 + f->ln2I) * 4 + m->orient;
  v[4] = (((A * R_LN + f->lnI) * R_DEP + m->dep) * R_ORL + orl) * R_CMP + m->comp;
  v[5] = ((A * 5 + f->nsig) * R_LP + f->lpI) * R_DEP + m->dep;
  if (k == K_L || k == K_M) v[6] = ((uint32_t)clampi(2 * (k == K_L ? aux : (aux & 15)) - f->lnI + 30, 0, 63) * R_K + A) * 4 + m->orient;
  else v[6] = ((A * 128 + f->pat) * 11 + (f->mxI >> 2)) * 4 + m->orient;
  v[7] = ((A * R_LN + f->mxI) * R_LP + f->lpI) * R_DEP + m->dep;
  for (j = 0; j < NC; j++) v[j] += K * (uint32_t)PK[j];
  return mix_code(m, dec, bit, v, (k * 42 + f->lnI) * 24 + m->dep, (k * 32 + aux) * 18 + f->lpI,
    (k * 64 + orl) * 4 + m->comp, k * 42 + f->lnI, (k * 18 + f->lpI) * 18 + f->lxI, (k * 32 + aux) * 24 + m->dep);
}

/* a sign: the neighbours' signs, the parent's and the other component's */
HM_INLINE int event_sign(hm_t *m, const int dec, int bit, int x, int y, const feat_t *f)
{
  const int32_t *R = m->R; int rw = m->rw, i = (y + 2) * rw + x + 2;
  int sw = sgn3(R[i - 1]) + 1, sn = sgn3(R[i - rw]) + 1, snw = sgn3(R[i - rw - 1]) + 1, sne = sgn3(R[i - rw + 1]) + 1;
  int se = sgn3(R[i + 1]) + 1, ss = sgn3(R[i + rw]) + 1;
  int a = (sw * 3 + sn) * 3 + se;         /* 27 */
  int b = (snw * 3 + sne) * 3 + ss;       /* 27 */
  uint32_t v[NC], K = K_S; int j, orl = m->orient * 16 + m->lvl;
  HM_KIND(K_S);
  v[0] = (uint32_t)(a * 27 + b) * 4 + m->orient;
  v[1] = ((uint32_t)a * 3 + f->sP) * 3 + f->sX;
  v[2] = (((uint32_t)sw * 3 + sn) * 3 + f->sP) * R_ORL + orl;
  v[3] = ((uint32_t)b * 3 + f->sP) * 4 + m->orient;
  v[4] = ((uint32_t)a * 3 + f->sX) * R_CMP + m->comp;
  v[5] = ((uint32_t)(sw * 3 + sn) * R_LN + f->lnI) * 4 + m->orient;
  v[6] = ((uint32_t)f->sP * 3 + f->sX) * R_LP + f->lpI;
  v[7] = (uint32_t)(a * 27 + b) * 9 + f->sP * 3 + f->sX;
  for (j = 0; j < NC; j++) v[j] += K * (uint32_t)PK[j];
  return mix_code(m, dec, bit, v, (K_S * 42 + clampi(a, 0, 41)) * 24 + m->dep, (K_S * 32 + sw * 3 + sn) * 18 + f->sP * 3 + f->sX,
    (K_S * 64 + orl) * 4 + m->comp, K_S * 42 + clampi(b, 0, 41), (K_S * 18 + f->sP * 3 + f->sX) * 18 + sw * 3 + sn,
    (K_S * 32 + sw * 3 + sn) * 24 + m->dep);
}

/* ------------------------------------------------------------------ a code-block's samples */
static int sigat(const hm_t *m, int x, int y, int ys, int causal)
{
  int i;
  if (x < 0 || y < 0 || x >= m->w || y >= m->h) return 0;
  i = y * m->w + x;
  if (m->flg[i] & 1) return !(causal && y >= ys + 4);
  return (m->flg[i] & 6) == 6;
}
static int nbsig(const hm_t *m, int x, int y, int ys, int causal)
{
  return sigat(m, x - 1, y - 1, ys, causal) | sigat(m, x, y - 1, ys, causal) | sigat(m, x + 1, y - 1, ys, causal) |
    sigat(m, x - 1, y, ys, causal) | sigat(m, x + 1, y, ys, causal) | sigat(m, x - 1, y + 1, ys, causal) |
    sigat(m, x, y + 1, ys, causal) | sigat(m, x + 1, y + 1, ys, causal);
}

HM_INLINE int run_cb(hm_t *m, int32_t causal, int32_t np, int32_t *q, const int dec)
{
  int w = m->w, h = m->h, x, y, sh = np > 1, i;
  feat_t f;
  /* the cleanup: mu and its sign */
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++) {
      uint32_t mu = 0; int neg = 0, nz, L = 0, k, j;
      i = y * w + x;
      if (!dec) { uint32_t a = ab(q[i]); mu = a >> sh; neg = q[i] < 0; if (mu > (1u << 28)) return -2; L = bitlen32(mu); }
      features(m, x, y, &f);
      nz = event(m, dec, mu != 0, K_Z, 0, &f);
      if (!nz) { RI(x, y) = 0; m->flg[i] = 0; if (dec) q[i] = 0; continue; }
      /* the length: more than k, for k = 1, 2, .. */
      if (dec) {
        L = 1;
        while (L < 29 && event(m, 1, 0, K_L, clampi(L, 0, R_K - 1), &f)) L++;
      } else {
        for (k = 1; k < 29 && k <= L; k++) event(m, 0, L > k, K_L, clampi(k, 0, R_K - 1), &f);
      }
      /* the bits under the top one: two through the mixer, the rest a counter each */
      {
        uint32_t v = 1; int b, aux;
        for (j = L - 2; j >= 0; j--) {
          b = dec ? 0 : (int)((mu >> j) & 1);
          if (j >= L - 3) {
            /* the first: by the length; the second: by the length and the first */
            aux = j == L - 2 ? clampi(L, 0, 15) : 16 + clampi(L, 0, 7) * 2 + (int)(v & 1);
            b = event(m, dec, b, K_M, aux, &f);
          } else b = code_low(m, dec, b, (clampi(L, 0, 31) * 32 + clampi(L - 2 - j, 0, 31)) * 2 + (int)(v & 1));
          v = (v << 1) | (uint32_t)b;
        }
        mu = v;
      }
      neg = event_sign(m, dec, neg, x, y, &f);
      RI(x, y) = (int32_t)(((2 * mu + 1) << sh) > (1u << 30) ? (1u << 30) : ((2 * mu + 1) << sh));
      if (neg) RI(x, y) = -RI(x, y);
      m->flg[i] = 1;
      if (dec) q[i] = (int32_t)(mu << sh) * (neg ? -1 : 1);
    }
  if (np == 1) return 0;
  /* SigProp: as pjaj2kht.c walks it */
  {
    int ys, xg;
    for (ys = 0; ys < h; ys += 4)
      for (xg = 0; xg < w; xg += 4) {
        int nn = 0, kk;
        for (x = xg; x < xg + 4 && x < w; x++)
          for (y = ys; y < ys + 4 && y < h; y++) {
            int b;
            i = y * w + x;
            if (m->flg[i] & 1) continue;
            if (!nbsig(m, x, y, ys, causal)) { m->flg[i] |= 4; continue; }
            b = dec ? 0 : ab(q[i]) == 1;
            features(m, x, y, &f);
            b = event(m, dec, b, K_P, 0, &f);
            m->flg[i] |= (uint8_t)(4 | (b << 1));
            if (b) { m->newl[nn++] = i; RI(x, y) = 3; }
          }
        for (kk = 0; kk < nn; kk++) {
          int neg;
          i = m->newl[kk]; x = i % w; y = i / w;
          features(m, x, y, &f);
          neg = event_sign(m, dec, dec ? 0 : q[i] < 0, x, y, &f);
          if (neg) RI(x, y) = -3;
          if (dec) q[i] = neg ? -1 : 1;
        }
      }
  }
  /* MagRef: the bit under the cleanup's of each sample significant there */
  if (np > 2)
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) {
        int b; uint32_t a;
        i = y * w + x;
        if (!(m->flg[i] & 1)) continue;
        a = ab(RI(x, y));
        features(m, x, y, &f);
        b = dec ? 0 : (int)(ab(q[i]) & 1);
        b = event(m, dec, b, K_R, clampi(bitlen32(a >> 2), 0, R_K - 1), &f);
        /* 4 mu + 2 (the middle of the cleanup's bin) to 4 mu + 2 b + 1 */
        if (b) a += 1; else a -= 1;
        RI(x, y) = RI(x, y) < 0 ? -(int32_t)a : (int32_t)a;
        if (dec) q[i] = q[i] < 0 ? q[i] - b : q[i] + b;
      }
  return 0;
}

/* ------------------------------------------------------------------ the API */
static hm_t *M(void *mem) { return (hm_t *)(((uintptr_t)mem + 63) & ~(uintptr_t)63); }

int32_t pjaj2khm_init(void *mem, int64_t size, int32_t hb, int32_t encoding, hm_put_t put, void *pctx,
  const uint8_t *data, int64_t len)
{
  hm_t *m; int i, j; uint8_t *p; int64_t k, words;
  if (pjaj2khm_size(hb) < 0 || size < pjaj2khm_size(hb)) return -1;
  m = M(mem);
  words = (pjaj2khm_size(hb) - 64) / 8;
  { uint64_t *z = (uint64_t *)m; for (k = 0; k < words; k++) z[k] = 0; }
  p = (uint8_t *)(m + 1);
  for (i = 0; i < NC; i++) {
    m->tsize[i] = RANGE(i) < ((int64_t)1 << hb) ? RANGE(i) : ((int64_t)1 << hb);
    m->t[i] = (ctr_t *)p; p += m->tsize[i] * (int64_t)sizeof(ctr_t);
  }
  for (i = 0; i < NSA; i++) for (j = 0; j < NC; j++) m->wa[i][2 * j] = 65536 / NC;
  for (i = 0; i < NSB; i++) for (j = 0; j < NC; j++) m->wb[i][2 * j] = 65536 / NC;
  for (i = 0; i < NSC; i++) for (j = 0; j < NC; j++) m->wc[i][2 * j] = 65536 / NC;
  for (i = 0; i < A0N; i++) for (j = 0; j < 33; j++) m->apm0[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  for (i = 0; i < A1N; i++) for (j = 0; j < 33; j++) m->apm1[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  for (i = 0; i < A2N; i++) for (j = 0; j < 33; j++) m->apm2[i][j] = J2KM_SQ[(j - 16) * 128 + 3072];
  for (i = 0; i < 1024; i++) m->lr[i] = HM_LR1 + HM_LR0 / (1024 + 64 * i);
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

void pjaj2khm_finish(void *mem)
{
  hm_t *m = M(mem); int k;
#ifdef HM_STATS
  { static const char *nm[8] = { "zero", "length", "mantissa", "sign", "sigprop", "magref", "-", "low" };
    for (k = 0; k < 8; k++) if (hm_n[k]) fprintf(stderr, "HMSTAT %s %ld %.0f\n", nm[k], hm_n[k], hm_cost[k] / 8); }
#endif
  for (k = 0; k < 4; k++) {
    m->ac.buf[m->ac.n++] = (uint8_t)(m->ac.x1 >> 24);
    if (m->ac.n == EBUF) { m->ac.put(m->ac.pctx, m->ac.buf, EBUF); m->ac.n = 0; }
    m->ac.x1 <<= 8;
  }
  if (m->ac.n) m->ac.put(m->ac.pctx, m->ac.buf, m->ac.n);
  m->ac.n = 0;
}

int64_t pjaj2khm_used(void *mem) { return M(mem)->ac.p; }

void pjaj2khm_tile(void *mem, const hmband_t *bands, int32_t nb, uint8_t *maps, int64_t mapsize)
{
  hm_t *m = M(mem); int32_t b; int64_t k;
  m->bands = bands; m->nb = nb; m->maps = maps; m->mapsize = maps ? mapsize : 0; m->zcomp = -1;
  for (b = 0; b < nb; b++) {
    const hmband_t *g = &bands[b];
    if (g->map < 0 || g->comp > 1 || g->w <= 0 || g->h <= 0) continue;
    if (g->map + (int64_t)g->w * g->h > m->mapsize) continue;
    for (k = 0; k < (int64_t)g->w * g->h; k++) maps[g->map + k] = 0;
  }
}

static const uint8_t *band_map(const hm_t *m, int32_t b)
{
  const hmband_t *g;
  if (b < 0 || b >= m->nb || !m->maps) return 0;
  g = &m->bands[b];
  if (g->map < 0 || g->w <= 0 || g->h <= 0 || g->map + (int64_t)g->w * g->h > m->mapsize) return 0;
  return m->maps + g->map;
}

/* the code-block at (x0, y0) of band b (w x h), stripe-causal or not, with
   np passes (1 to 3) whose cleanup is at plane B (the band's Mb - 1 - its
   zero bit-planes, placeholder sets included): encoding, its values q[0..w
   h) (pjaj2kht.c's) coded; decoding, written. 0, or -2 (bad arguments, or
   a value too large) */
int32_t pjaj2khm_cb(void *mem, int32_t b, int32_t x0, int32_t y0, int32_t w, int32_t h, int32_t causal, int32_t np,
  int32_t B, int32_t *q)
{
  hm_t *m = M(mem); const hmband_t *g; const uint8_t *map, *pmap, *xm0, *xm1; int32_t x, y, r, Bq;
  if (b < 0 || b >= m->nb || w < 1 || h < 1 || w > 1024 || h > 1024 || (int64_t)w * h > CBMAX || np < 1 || np > 3 ||
      B < -64 || B > 64) return -2;
  g = &m->bands[b];
  if (g->orient < 0 || g->orient > 3) return -2;
  Bq = B - (np > 1 ? 1 : 0);
  if (Bq < 0) Bq = 0;
  m->w = w; m->h = h; m->rw = w + 4; m->orient = g->orient; m->Bq = Bq;
  m->lvl = clampi(g->nres - g->res, 0, 15); m->comp = clampi(g->comp, 0, 3);
  m->dep = clampi(g->mb - B, 0, R_DEP - 1);
  map = band_map(m, b);
  if (map && (x0 < 0 || y0 < 0 || (int64_t)x0 + w > g->w || (int64_t)y0 + h > g->h)) map = 0;
  if (map && g->comp > 1 && g->comp != m->zcomp) {
    int32_t k; int64_t j;
    m->zcomp = g->comp;
    for (k = 0; k < m->nb; k++)
      if (m->bands[k].comp == g->comp) {
        const uint8_t *qq = band_map(m, k);
        if (qq) for (j = 0; j < (int64_t)m->bands[k].w * m->bands[k].h; j++) m->maps[m->bands[k].map + j] = 0;
      }
  }
  for (y = -2; y < h + 2; y++)
    for (x = -2; x < w + 2; x++) {
      int64_t gx = (int64_t)x0 + x, gy = (int64_t)y0 + y;
      int32_t v = 0;
      if (map && (x < 0 || y < 0 || x >= w || y >= h) && gx >= 0 && gy >= 0 && gx < g->w && gy < g->h)
        v = mapval(map[gy * g->w + gx], Bq);
      RI(x, y) = v;
    }
  pmap = map ? band_map(m, g->parent) : 0;
  xm0 = map && g->comp > 0 ? band_map(m, g->cross0) : 0;
  xm1 = map && g->comp > 1 ? band_map(m, g->cross1) : 0;
  m->haveP = pmap != 0; m->haveX = xm0 != 0;
  if (pmap) {
    const hmband_t *pg = &m->bands[g->parent];
    for (x = 0; x < w; x++) m->colA[x] = muldiv((int64_t)x0 + x, pg->w, g->w);
    for (y = 0; y < h; y++) m->rowA[y] = muldiv((int64_t)y0 + y, pg->h, g->h);
    m->pqoff = -2 * pg->mb + 2 * g->mb - 4;
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) {
        int32_t px = m->colA[x], py = m->rowA[y], pw = pg->w, ph = pg->h;
        uint8_t pc = pmap[(int64_t)py * pw + px];
        uint64_t s = 2 * (uint64_t)ab(mapval(pc, -1));
        s += ab(mapval(pmap[(int64_t)py * pw + (px > 0 ? px - 1 : px)], -1));
        s += ab(mapval(pmap[(int64_t)py * pw + (px + 1 < pw ? px + 1 : px)], -1));
        s += ab(mapval(pmap[(int64_t)(py > 0 ? py - 1 : py) * pw + px], -1));
        s += ab(mapval(pmap[(int64_t)(py + 1 < ph ? py + 1 : py) * pw + px], -1));
        m->PS[y * w + x] = (int8_t)(pc ? (pc & 128 ? -1 : 1) : 0);
        m->PQ[y * w + x] = (int16_t)(s ? q2log(s) : -100);
      }
  }
  if (xm0) {
    const hmband_t *g0 = &m->bands[g->cross0], *g1 = xm1 ? &m->bands[g->cross1] : 0;
    for (x = 0; x < w; x++) m->colB[x] = muldiv((int64_t)x0 + x, g0->w, g->w);
    for (y = 0; y < h; y++) m->rowB[y] = muldiv((int64_t)y0 + y, g0->h, g->h);
    if (g1) {
      for (x = 0; x < w; x++) m->colC[x] = muldiv((int64_t)x0 + x, g1->w, g->w);
      for (y = 0; y < h; y++) m->rowC[y] = muldiv((int64_t)y0 + y, g1->h, g->h);
    }
    m->xqoff = -2 * g0->mb + 2 * g->mb - 2;
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) {
        uint8_t c0 = xm0[(int64_t)m->rowB[y] * g0->w + m->colB[x]];
        uint64_t s = 2 * (uint64_t)ab(mapval(c0, -1));
        if (g1) s += 2 * (uint64_t)ab(mapval(xm1[(int64_t)m->rowC[y] * g1->w + m->colC[x]], -1));
        m->XS[y * w + x] = (int8_t)(c0 ? (c0 & 128 ? -1 : 1) : 0);
        m->XQ[y * w + x] = (int16_t)(s ? q2log(s) : -100);
      }
  }
  if (m->enc) r = run_cb(m, causal, np, q, 0);
  else r = run_cb(m, causal, np, q, 1);
  if (r >= 0 && map) {
    uint8_t *wm = m->maps + g->map;
    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++) wm[((int64_t)y0 + y) * g->w + x0 + x] = mapcode(RI(x, y), Bq);
  }
  return r;
}

/* Stream version 8's mode 2: a JPEG 2000 codestream kept as its pixels
   (doc/CODEC.md, "JPEG 2000, stage D"). Called through pjaj2kpx.pas, which
   owns every buffer: this file takes no memory and calls no library, as
   pjav7c.c and pjaj2kmc.c.

   - pjaj2kp_cb_coef / pjaj2kp_cb_sym: a code-block's decisions (bytes ctx
     << 1 | bit, as pjaj2kt1.c's) to its coefficients, and its coefficients
     back to the decisions, walking the coding passes as pjaj2kt1.c does;
   - pjaj2kp_dwt: the reversible 5/3 wavelet of a tile-component, both
     ways, in place, its bands where the Mallat layout puts them;
   - pjaj2kp_rct, pjaj2kp_put, pjaj2kp_get: the reversible colour
     transform, the DC level shift and the copy to and from the planes;
   - pjaj2kp_code: the planes through the pixel models (one for 1-bit
     components, one for 2 to 16 bits) and PJA's binary arithmetic coder.

   Determinism: integer arithmetic only, the tables are constants
   (pjaj2km_tab.h, shared with mode 1's model). Build with -fwrapv
   (pas/build_c.sh). */
#include <stdint.h>
#include "pjaj2kt1.h"
#include "pjaj2km_tab.h"

#if defined(__GNUC__) || defined(__clang__)
#define PX_INLINE static inline __attribute__((always_inline))
#else
#define PX_INLINE static inline
#endif

static inline int clampi(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline uint32_t ab32(int32_t v) { return v < 0 ? 0u - (uint32_t)v : (uint32_t)v; }
static inline int32_t truncshr(int32_t x, int n) { return (x + ((x >> 31) & ((1 << n) - 1))) >> n; }
static inline int ilog2_32(uint32_t v) { return 31 - __builtin_clz(v); }

/* ================================================================== tier-1 */
/* the largest code-block: w, h <= 1024, w h <= 4096; (w + 2) (h + 2) <= 6156 */
#define CBMAX 4096
#define STN 6160

typedef struct {
  uint8_t st[2 * STN];
  uint32_t mag[CBMAX];
} pxt1_t;

typedef struct {
  int raw;
  const uint8_t *in; int64_t n;       /* coefficients from decisions: the decisions */
  uint8_t *out; int64_t cap;          /* decisions from coefficients: where they go */
  int64_t ns;
  int64_t nsig;                       /* the coefficients made significant */
  uint32_t *mag;                      /* the magnitudes, w a row */
  int32_t w;
  int err;
} pxs_t;

int64_t pjaj2kp_t1_size(void) { return (int64_t)sizeof(pxt1_t); }

/* one decision of context ctx: written (mode 1, bit b), only counted (mode
   2, bit b) or read (mode 0) */
PX_INLINE int px_dec(pxs_t *s, int ctx, int b, const int mode)
{
  int c = s->raw ? 19 : ctx;
  if (mode == 2) { s->ns++; return b; }
  if (mode) {
    if (s->ns >= s->cap) { s->err = 1; return 0; }
    s->out[s->ns++] = (uint8_t)((c << 1) | b);
    return b;
  }
  if (s->ns >= s->n) { s->err = 2; return 0; }
  b = s->in[s->ns++];
  if ((b >> 1) != c) { s->err = 3; return 0; }
  return b & 1;
}

/* the magnitudes keep a coefficient's sign in their top bit (mode 1) */
#define MSIGN 0x80000000u
PX_INLINE void px_sign(pxs_t *s, uint8_t *st, uint8_t *nb, int i, int stride, int excl, int ci, const int mode)
{
  int xr, cx = sc_ctx(st, i, stride, excl, &xr), b, neg = 0;
  if (mode) { neg = (s->mag[ci] & MSIGN) != 0; b = s->raw ? neg : neg ^ xr; } else b = 0;
  b = px_dec(s, cx, b, mode);
  if (!mode) neg = s->raw ? b : b ^ xr;
  s->nsig++;
  make_sig(st, nb, i, stride, neg);
}

PX_INLINE void px_spp(pxs_t *s, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int p,
  const int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int m, ci = y * w + x, b;
        if (st[i] & SIG) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        if (!m) continue;
        st[i] |= PIV;
        b = mode ? (int)((s->mag[ci] >> p) & 1) : 0;
        b = px_dec(s, zc[m], b, mode);
        if (b) {
          if (!mode) s->mag[ci] |= 1u << p;
          px_sign(s, st, nb, i, stride, causal && (y & 3) == 3, ci, mode);
        }
      }
      if (s->err) return;
    }
  }
}

PX_INLINE void px_mrp(pxs_t *s, uint8_t *st, uint8_t *nb, int w, int h, int causal, int p, const int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int m, ci = y * w + x, b;
        if ((st[i] & (SIG | PIV)) != SIG) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        b = mode ? (int)((s->mag[ci] >> p) & 1) : 0;
        b = px_dec(s, (st[i] & REF) ? 16 : m ? 15 : 14, b, mode);
        if (!mode && b) s->mag[ci] |= 1u << p;
        st[i] |= REF;
      }
      if (s->err) return;
    }
  }
}

PX_INLINE void px_cup(pxs_t *s, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int segmark,
  int p, const int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i0 = (y0 + 1) * stride + x + 1, i;
      y = y0;
      if (y1 - y0 == 4 && !(st[i0] | st[i0 + stride] | st[i0 + 2 * stride] | (st[i0 + 3 * stride] & (SIG | PIV))) &&
          !(nb[i0] | nb[i0 + stride] | nb[i0 + 2 * stride] | (nb[i0 + 3 * stride] & (causal ? ~SOUTH : 0xFF)))) {
        /* run-length mode */
        int r = 0, any = 0, ci = y0 * w + x;
        if (mode) {
          for (r = 0; r < 4; r++) if ((s->mag[ci + r * w] >> p) & 1) { any = 1; break; }
        }
        if (!px_dec(s, 17, any, mode)) { if (s->err) return; continue; }
        if (mode) { px_dec(s, 18, r >> 1, mode); px_dec(s, 18, r & 1, mode); }
        else { r = px_dec(s, 18, 0, mode) << 1; r |= px_dec(s, 18, 0, mode); }
        if (s->err) return;
        y = y0 + r;
        if (!mode) s->mag[ci + r * w] |= 1u << p;
        px_sign(s, st, nb, i0 + r * stride, stride, causal && (y & 3) == 3, ci + r * w, mode);
        y++;
      }
      for (i = i0 + (y - y0) * stride; y < y1; y++, i += stride) {
        int m, ci = y * w + x, b;
        if (st[i] & (SIG | PIV)) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        b = mode ? (int)((s->mag[ci] >> p) & 1) : 0;
        b = px_dec(s, zc[m], b, mode);
        if (b) {
          if (!mode) s->mag[ci] |= 1u << p;
          px_sign(s, st, nb, i, stride, causal && (y & 3) == 3, ci, mode);
        }
      }
      if (s->err) return;
    }
  }
  for (y = 0; y < h; y++) {
    uint8_t *q = st + (y + 1) * stride + 1;
    for (x = 0; x < w; x++) q[x] &= (uint8_t)~PIV;
  }
  if (segmark) { px_dec(s, 18, 1, mode); px_dec(s, 18, 0, mode); px_dec(s, 18, 1, mode); px_dec(s, 18, 0, mode); }
}

/* the passes; P the bit-planes (Mb - zero bit-planes): pass k is at plane
   P - 1 - (k + 2) / 3. In mode 1 the magnitudes carry the signs (MSIGN) */
PX_INLINE int64_t px_passes(pxs_t *s, pxt1_t *t, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  int32_t P, int32_t *passend, const int mode)
{
  int k, causal = (sty & 8) != 0; int64_t n = (int64_t)(w + 2) * (h + 2);
  uint8_t *st = t->st, *nb = t->st + n; const uint8_t *zc = ZC[orient];
  for (k = 0; k < npasses; k++) {
    int type = k == 0 ? 2 : (k - 1) % 3, p = P - 1 - (k + 2) / 3;
    if (p < 0) return -5;
    s->raw = (sty & 1) && k >= 10 && type < 2;
    if (type == 0) px_spp(s, st, nb, w, h, zc, causal, p, mode);
    else if (type == 1) px_mrp(s, st, nb, w, h, causal, p, mode);
    else px_cup(s, st, nb, w, h, zc, causal, (sty & 32) != 0, p, mode);
    if (s->err) return -1 - s->err;
    if (mode) passend[k] = (int32_t)s->ns;
    else if (passend[k] != s->ns) return -6;
  }
  return s->ns;
}

static int px_args(int32_t w, int32_t h, int32_t orient, int32_t npasses, int32_t P)
{
  return w >= 1 && h >= 1 && w <= 1024 && h <= 1024 && (int64_t)w * h <= CBMAX && orient >= 0 && orient <= 3 &&
    npasses >= 0 && npasses <= 255 && P >= 1 && P <= 30;
}

/* a code-block's n decisions (as pjaj2k_t1_decode gives them, its pass ends
   in passend) to its coefficients, coef[y * cstride + x]: 0, or -1 when they
   are not those passes' at P bit-planes */
int32_t pjaj2kp_cb_coef(void *tmem, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses, int32_t P,
  const uint8_t *sym, int64_t n, const int32_t *passend, int32_t *coef, int64_t cstride)
{
  pxt1_t *t = tmem; pxs_t s; int64_t i, m; int x, y, stride = w + 2;
  if (!px_args(w, h, orient, npasses, P)) return -1;
  m = (int64_t)(w + 2) * (h + 2);
  for (i = 0; i < 2 * m; i++) t->st[i] = 0;
  for (i = 0; i < (int64_t)w * h; i++) t->mag[i] = 0;
  s.raw = 0; s.in = sym; s.n = n; s.out = 0; s.cap = 0; s.ns = 0; s.nsig = 0; s.mag = t->mag; s.w = w; s.err = 0;
  if (px_passes(&s, t, w, h, orient, sty, npasses, P, (int32_t *)passend, 0) != n) return -1;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++) {
      uint32_t v = t->mag[y * w + x];
      coef[y * cstride + x] = (t->st[(y + 1) * stride + x + 1] & NEG) ? -(int32_t)v : (int32_t)v;
    }
  return 0;
}

/* a code-block's coefficients coef[y * cstride + x] to its decisions (at
   most cap) and pass ends: how many, or -1 (a coefficient of more than P
   bit-planes, the passes past plane 0, cap too small) */
int64_t pjaj2kp_cb_sym(void *tmem, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses, int32_t P,
  const int32_t *coef, int64_t cstride, uint8_t *sym, int64_t cap, int32_t *passend)
{
  pxt1_t *t = tmem; pxs_t s; int64_t i, m, r; int x, y;
  if (!px_args(w, h, orient, npasses, P)) return -1;
  m = (int64_t)(w + 2) * (h + 2);
  for (i = 0; i < 2 * m; i++) t->st[i] = 0;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++) {
      int32_t v = coef[y * cstride + x]; uint32_t a = ab32(v);
      if (a >> P) return -1;
      t->mag[y * w + x] = a | (v < 0 ? MSIGN : 0);
    }
  s.raw = 0; s.in = 0; s.n = 0; s.out = sym; s.cap = cap; s.ns = 0; s.nsig = 0; s.mag = t->mag; s.w = w; s.err = 0;
  r = px_passes(&s, t, w, h, orient, sty, npasses, P, passend, 1);
  return r < 0 ? -1 : r;
}

/* how many of a code-block's passes change its coefficients coef[y *
   cstride + x] (P bit-planes): all 3 P - 2 of them less the trailing ones
   that change nothing (no coefficient made significant, none refined), as
   Kakadu leaves them out; -1 for a coefficient of more than P bit-planes.
   A code-block whose passes are fewer than this lost some (rate-truncated):
   mode 2 does not take it */
int32_t pjaj2kp_cb_full(void *tmem, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t P,
  const int32_t *coef, int64_t cstride)
{
  pxt1_t *t = tmem; pxs_t s; int64_t i, m; int x, y, k, full = 3 * P - 2, last = 0, causal = (sty & 8) != 0;
  uint8_t *st, *nb; const uint8_t *zc;
  if (!px_args(w, h, orient, 0, P)) return -1;
  m = (int64_t)(w + 2) * (h + 2);
  st = t->st; nb = t->st + m; zc = ZC[orient];
  for (i = 0; i < 2 * m; i++) t->st[i] = 0;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++) {
      int32_t v = coef[y * cstride + x]; uint32_t a = ab32(v);
      if (a >> P) return -1;
      t->mag[y * w + x] = a | (v < 0 ? MSIGN : 0);
    }
  /* pass by pass: what each makes significant, and its decisions (all of a
     refinement pass's are refinements); counted, not written */
  s.raw = 0; s.in = 0; s.n = 0; s.out = 0; s.cap = 0; s.ns = 0; s.nsig = 0; s.mag = t->mag; s.w = w; s.err = 0;
  for (k = 0; k < full; k++) {
    int type = k == 0 ? 2 : (k - 1) % 3, p = P - 1 - (k + 2) / 3;
    int64_t sg = s.nsig, ns = s.ns;
    s.raw = (sty & 1) && k >= 10 && type < 2;
    if (type == 0) px_spp(&s, st, nb, w, h, zc, causal, p, 2);
    else if (type == 1) px_mrp(&s, st, nb, w, h, causal, p, 2);
    else px_cup(&s, st, nb, w, h, zc, causal, 0, p, 2);
    if (s.err) return -1;
    if (type == 1 ? s.ns > ns : s.nsig > sg) last = k + 1;
  }
  return last;
}

/* ================================================================== 5/3 and RCT */
static inline int64_t ceil_shr(int64_t a, int n) { return -((-a) >> n); }

/* index j of a signal of n >= 2, extended symmetrically */
static inline int64_t ext(int64_t j, int64_t n) { return j < 0 ? -j : j >= n ? 2 * (n - 1) - j : j; }

/* one signal of n samples whose first is at abs. position i0 (odd: its
   parity), in place: inverse, from the interleaved Y to X (F.3.8); forward,
   from X to the interleaved Y (F.4.8). Every result within +-2^30, else -1;
   -1 too for an inverse that the forward would not undo (a lone odd
   sample, which only a codestream of no forward transform can hold) */
static int lift(int64_t *v, int64_t n, int odd, int fwd)
{
  int64_t i;
  if (n == 1) {
    /* back, an odd sample would not come again: the forward doubles it */
    if (odd && !fwd && (v[0] & 1)) return -1;
    if (odd) v[0] = fwd ? 2 * v[0] : v[0] >> 1;
  } else {
    /* each step: the samples at the ends through the symmetric extension,
       the others (i - 1 >= 0, i + 1 < n) without it */
#define LIFT(start, OP, rnd, sh) do { \
      for (i = (start); i < n && i < 1; i += 2) v[i] OP (v[ext(i - 1, n)] + v[ext(i + 1, n)] + (rnd)) >> (sh); \
      for (; i + 1 < n; i += 2) v[i] OP (v[i - 1] + v[i + 1] + (rnd)) >> (sh); \
      for (; i < n; i += 2) v[i] OP (v[ext(i - 1, n)] + v[ext(i + 1, n)] + (rnd)) >> (sh); \
    } while (0)
    if (!fwd) { LIFT(odd, -=, 2, 2); LIFT(!odd, +=, 0, 1); }
    else { LIFT(!odd, -=, 0, 1); LIFT(odd, +=, 2, 2); }
#undef LIFT
  }
  {
    /* the whole line within 30 bits (no early exit: the loop vectorizes) */
    int bad = 0;
    for (i = 0; i < n; i++) bad |= (v[i] > (1 << 30)) | (v[i] < -(1 << 30));
    if (bad) return -1;
  }
  return 0;
}

/* a line of n samples a[0], a[step], ..: inverse, the low-pass ones first
   then the high-pass ones in, the signal out in order; forward the other
   way. line: 2n int64 */
static int line53(int32_t *a, int64_t step, int64_t n, int odd, int fwd, int64_t *line)
{
  int64_t i, sn = odd ? n / 2 : (n + 1) / 2, li = 0, hi = sn;
  if (n <= 0) return 0;
  if (!fwd) {
    for (i = 0; i < n; i++) line[i] = ((i + odd) & 1) ? a[(hi++) * step] : a[(li++) * step];
    if (lift(line, n, odd, 0)) return -1;
    for (i = 0; i < n; i++) a[i * step] = (int32_t)line[i];
  } else {
    for (i = 0; i < n; i++) line[i] = a[i * step];
    if (lift(line, n, odd, 1)) return -1;
    for (i = 0; i < n; i++) {
      if ((i + odd) & 1) a[(hi++) * step] = (int32_t)line[i]; else a[(li++) * step] = (int32_t)line[i];
    }
  }
  return 0;
}

/* a tile-component's W x H samples a[y * stride + x] (its origin x0, y0 on
   its grid) through nl levels of the 5/3 wavelet: fwd, samples to bands in
   the Mallat layout (the band of resolution r and orientation 1 (HL) at
   (w(r - 1), 0), 2 (LH) at (0, h(r - 1)), 3 (HH) at (w(r - 1), h(r - 1)),
   LL at (0, 0)); else back. line: 2 max(W, H) int64. 0, or -1 when a value
   goes past +-2^30 */
int32_t pjaj2kp_dwt(int32_t *a, int64_t stride, int32_t W, int32_t H, int64_t x0, int64_t y0, int32_t nl,
  int32_t fwd, int64_t *line)
{
  int r, k; int64_t x1 = x0 + W, y1 = y0 + H;
  if (nl < 0 || nl > 32 || W < 0 || H < 0) return -1;
  for (k = 0; k < nl; k++) {
    int lv, odd; int64_t rx0, ry0, rw, rh, i;
    r = fwd ? nl - k : k + 1;
    lv = nl - r;
    rx0 = ceil_shr(x0, lv); ry0 = ceil_shr(y0, lv);
    rw = ceil_shr(x1, lv) - rx0; rh = ceil_shr(y1, lv) - ry0;
    if (!fwd) {
      odd = (int)(rx0 & 1);
      for (i = 0; i < rh; i++) if (line53(a + i * stride, 1, rw, odd, 0, line)) return -1;
      odd = (int)(ry0 & 1);
      for (i = 0; i < rw; i++) if (line53(a + i, stride, rh, odd, 0, line)) return -1;
    } else {
      odd = (int)(ry0 & 1);
      for (i = 0; i < rw; i++) if (line53(a + i, stride, rh, odd, 1, line)) return -1;
      odd = (int)(rx0 & 1);
      for (i = 0; i < rh; i++) if (line53(a + i * stride, 1, rw, odd, 1, line)) return -1;
    }
  }
  return 0;
}

/* the reversible colour transform of n samples of three components (G.2):
   forward from (R, G, B) to (Y, Db, Dr), else back. 0, or -1 past +-2^30 */
int32_t pjaj2kp_rct(int32_t *c0, int32_t *c1, int32_t *c2, int64_t n, int32_t fwd)
{
  int64_t i, r, g, b, y, u, v;
  for (i = 0; i < n; i++) {
    if (fwd) {
      r = c0[i]; g = c1[i]; b = c2[i];
      y = (r + 2 * g + b) >> 2; u = b - g; v = r - g;
    } else {
      y = c0[i]; u = c1[i]; v = c2[i];
      g = y - ((u + v) >> 2); r = v + g; b = u + g;
      y = r; u = g; v = b;
    }
    if (y > (1 << 30) || y < -(1 << 30) || u > (1 << 30) || u < -(1 << 30) || v > (1 << 30) || v < -(1 << 30))
      return -1;
    c0[i] = (int32_t)y; c1[i] = (int32_t)u; c2[i] = (int32_t)v;
  }
  return 0;
}

/* W x H samples a[y * astride + x] to the plane p[y * pstride + x], the DC
   level shift added (v + 2^(depth - 1), signed or not: a sample of a
   signed component is kept with the same offset): 0, or -1 when one is not
   in [0, 2^depth) */
int32_t pjaj2kp_put(const int32_t *a, int64_t astride, int32_t W, int32_t H, int32_t depth, uint16_t *p,
  int64_t pstride)
{
  int64_t x, y; int32_t off = 1 << (depth - 1), mx = (1 << depth) - 1;
  if (depth < 1 || depth > 16) return -1;
  for (y = 0; y < H; y++)
    for (x = 0; x < W; x++) {
      int64_t v = (int64_t)a[y * astride + x] + off;
      if (v < 0 || v > mx) return -1;
      p[y * pstride + x] = (uint16_t)v;
    }
  return 0;
}

/* the other way: the plane to samples, the shift taken off */
int32_t pjaj2kp_get(int32_t *a, int64_t astride, int32_t W, int32_t H, int32_t depth, const uint16_t *p,
  int64_t pstride)
{
  int64_t x, y; int32_t off = 1 << (depth - 1);
  if (depth < 1 || depth > 16) return -1;
  for (y = 0; y < H; y++)
    for (x = 0; x < W; x++) a[y * astride + x] = (int32_t)p[y * pstride + x] - off;
  return 0;
}

/* ================================================================== the pixel models */
/* part of the format: constants, not build options */
#define PX_LIMIT 255       /* the slow counters' last rate, 1 / (limit + 1.5) (J2KM_RC) */
#define PX_FAST 4          /* the fast counters' rate, 2^-PX_FAST */
#define PX_APMR 6          /* the maps' rate */
#define PX_HBMIN 12        /* the bitonal model's large tables: 2^hb counters, hb in [PX_HBMIN, PX_HBMAX] */
#define PX_HBMAX 22
#define WMAX (1 << 22)

typedef void (*px_put_t)(void *ctx, const uint8_t *b, intptr_t n);

#define EBUF 4096
typedef struct {
  uint32_t x1, x2, x;
  px_put_t put; void *pctx; int32_t n;
  const uint8_t *d; int64_t len, p;
  uint8_t buf[EBUF];
} ac_t;

/* PJA's binary arithmetic coder (pjaarith), p16 the probability of a 1 */
PX_INLINE int ac_code(ac_t *a, uint32_t p16, int bit, const int dec)
{
  uint32_t xm;
  if (p16 < 1) p16 = 1; else if (p16 > 65535) p16 = 65535;
  xm = a->x1 + (uint32_t)(((uint64_t)(a->x2 - a->x1) * p16) >> 16);
  if (dec) bit = a->x <= xm;
  {
    /* without a branch on the bit (pjaj2kmc.c's) */
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

/* a counter: p and f are probabilities of a 1 xor 0x8000 (zeroed memory is
   1/2), n how many updates the slow one has had */
typedef struct { uint16_t p, f; uint8_t n, pad; } ctr_t;
#define CP(v) ((uint32_t)((v) ^ 0x8000))

PX_INLINE void learn(ctr_t *c, int bit)
{
  uint32_t p = CP(c->p), n = c->n, d = bit ? 65535 - p : p - 1;
  int32_t f = (int32_t)CP(c->f);
  uint32_t step = (d * (uint32_t)J2KM_RC[n]) >> 16;
  p = bit ? p + step : p - step;
  c->p = (uint16_t)(p ^ 0x8000);
  c->n = (uint8_t)(n + (n < PX_LIMIT));
  f += ((bit ? 65535 : 0) - f) >> PX_FAST;
  c->f = (uint16_t)((uint32_t)f ^ 0x8000);
}

/* a mixer of N stretched probabilities, a set of weights chosen by sel; an
   adaptive probability map of 33 bins chosen by a; the final probability
   (mixer + map) / 2 */
#define NIN 14
typedef struct { int32_t w[NIN]; uint16_t cnt, pad; } wset_t;

typedef struct {
  ac_t ac;
  int32_t lr[1024];
  int32_t blr[1024];                   /* the bitonal mixer's rates */
  int32_t lms[8];                      /* the adaptive predictor's weights, 2^-12 */
  int64_t hsize;                       /* the bitonal model's large tables, in counters */
  int32_t hbits;
  /* bitonal */
  ctr_t b1[1 << 10], b2[1 << 16];
  ctr_t *b3, *b4;
  ctr_t *bx[3];                        /* the far templates: 2^(hb - 2) counters each */
  wset_t bw[1 << 8];
  uint16_t bapm[1 << 10][33];
  /* 2 to 16 bits */
  struct { int32_t a, b, c, n; } bias[2][365];
  ctr_t z[5][1 << 16];                 /* zero or not */
  ctr_t xe[5][1 << 16];                /* the bit length */
  ctr_t mm[3][4096];                   /* the mantissa */
  ctr_t sg[2][1024];                   /* the sign */
  wset_t mw[3][512];
  uint16_t mapm[3][1024][33];
} pxm_t;

int64_t pjaj2kp_model_size(int32_t hb)
{
  if (hb < PX_HBMIN || hb > PX_HBMAX) return -1;
  return (int64_t)sizeof(pxm_t) + 64 + (2 * ((int64_t)1 << hb) + 3 * ((int64_t)1 << (hb - 2))) * (int64_t)sizeof(ctr_t);
}

/* p (16 bits) of the mix of n inputs s[] with the set ws, and the map t
   (at the stretched x); coded; then everything learns */
PX_INLINE int mix_code(pxm_t *m, const int dec, int bit, ctr_t **c, int n, wset_t *ws, uint16_t *t,
  const int32_t *lrt)
{
  int32_t s[NIN], dot = 0, x, pm, pa, pf, pos, lo, fr, e, lr; int i;
  for (i = 0; i < n; i++) { s[2 * i] = J2KM_ST[CP(c[i]->p) >> 4]; s[2 * i + 1] = J2KM_ST[CP(c[i]->f) >> 4]; }
  for (i = 0; i < 2 * n; i++) dot += s[i] * ws->w[i];
  x = clampi(truncshr(dot, 16), -3071, 3071);
  pm = J2KM_SQ[x + 3072];
  pos = (clampi(x, -2047, 2047) + 2048) * 32; lo = pos >> 12; fr = pos & 4095;
  pa = (t[lo] * (4096 - fr) + t[lo + 1] * fr) >> 12;
  pf = (pm + pa) >> 1;
  bit = ac_code(&m->ac, (uint32_t)pf, bit, dec);
  e = ((bit << 16) - pm) >> 4;
  lr = lrt[ws->cnt >> 6]; ws->cnt += ws->cnt < 65535;
  e *= lr;
  for (i = 0; i < 2 * n; i++) ws->w[i] = clampi(ws->w[i] + truncshr(s[i] * e, 16), -WMAX, WMAX);
  {
    int32_t tg = bit ? 65535 : 0;
    t[lo] = (uint16_t)(t[lo] + truncshr((tg - t[lo]) * (4096 - fr) >> 6, 6 + PX_APMR));
    t[lo + 1] = (uint16_t)(t[lo + 1] + truncshr((tg - t[lo + 1]) * fr >> 6, 6 + PX_APMR));
  }
  for (i = 0; i < n; i++) learn(c[i], bit);
  return bit;
}

static void px_init(pxm_t *m, int hb)
{
  int i, j, k; uint8_t *p = (uint8_t *)m; int64_t z;
  /* 8 bytes at a time: pxm_t's size is a multiple of 8 (it holds int64_t),
     and so is the large tables' (hsize is a multiple of 4: 6 hsize / 4 x 4) */
  { uint64_t *q = (uint64_t *)p; for (z = 0; z < (int64_t)sizeof(pxm_t) / 8; z++) q[z] = 0; }
  for (i = 0; i < 1024; i++) { m->lr[i] = 6 + 31457 / (1024 + 64 * i); m->blr[i] = m->lr[i] * 3 / 2; }
  m->hbits = hb; m->hsize = (int64_t)1 << hb;
  m->b3 = (ctr_t *)(p + sizeof(pxm_t) + 64 - ((uintptr_t)(p + sizeof(pxm_t)) & 63));
  m->b4 = m->b3 + m->hsize;
  m->bx[0] = m->b4 + m->hsize; m->bx[1] = m->bx[0] + (m->hsize >> 2); m->bx[2] = m->bx[1] + (m->hsize >> 2);
  { uint64_t *q = (uint64_t *)m->b3;
    for (z = 0; z < (2 * m->hsize + 3 * (m->hsize >> 2)) * (int64_t)sizeof(ctr_t) / 8; z++) q[z] = 0; }
  /* the weights start at 1/N of each input, the maps at the identity */
  for (i = 0; i < (1 << 8); i++) for (j = 0; j < 14; j++) m->bw[i].w[j] = 65536 / 7;
  for (k = 0; k < 3; k++) for (i = 0; i < 512; i++) for (j = 0; j < NIN; j++) m->mw[k][i].w[j] = 65536 / 5;
  for (j = 0; j < 33; j++) {
    int32_t v = J2KM_SQ[clampi((j - 16) * 128, -3071, 3071) + 3072];
    for (i = 0; i < (1 << 10); i++) m->bapm[i][j] = (uint16_t)v;
    for (k = 0; k < 3; k++) for (i = 0; i < 1024; i++) m->mapm[k][i][j] = (uint16_t)v;
  }
  for (k = 0; k < 2; k++) for (i = 0; i < 365; i++) { m->bias[k][i].a = 4; m->bias[k][i].n = 1; }
}

/* ------------------------------------------------------------------ 1 bit */
/* the pixel of row r (0: above the plane) at x; 0 outside the row */
#define PXB(r, x) ((r) && (x) >= 0 && (x) < w ? (uint32_t)((r)[x] & 1) : 0u)

/* one pixel of code_bitonal at x: FETCH(r, x) the pixel of row r at x, 0
   outside it */
#define BITONAL_PIXEL(FETCH) do { \
      uint32_t t1, t2, t3, t4, h3, h4, sel; uint64_t k; ctr_t *c[7]; int bit; \
      t1 = ((w2 >> 3) & 7) << 7 | ((w1 >> 4) & 0x1F) << 2 | (uint32_t)(w0 & 3); \
      t2 = ((w2 >> 2) & 0x1F) << 11 | ((w1 >> 3) & 0x7F) << 4 | (uint32_t)(w0 & 0xF); \
      t3 = ((w2 >> 1) & 0x7F) << 15 | ((w1 >> 2) & 0x1FF) << 6 | (uint32_t)(w0 & 0x3F); \
      t4 = (w2 & 0x1FF) << 21 | (w1 & 0x1FFF) << 8 | (uint32_t)(w0 & 0xFF); \
      h3 = m->hbits >= 22 ? t3 : ((t3 + 1) * 0x9E3779B1u) >> sh; \
      h4 = ((t4 + 1) * 0x9E3779B1u + 0x632BE5ABu) >> sh; \
      c[0] = &m->b1[t1]; c[1] = &m->b2[t2]; c[2] = &m->b3[h3 & hmask]; c[3] = &m->b4[h4 & hmask]; \
      /* rows y - 4 (x - 4 .. x + 4) and y - 3 (x - 8 .. x + 8) with t3 */ \
      k = (uint64_t)((w4 >> 4) & 0x1FF) << 40 ^ (uint64_t)w3 << 22 ^ t3; \
      c[4] = &m->bx[0][(k * 0x9E3779B97F4A7C15ull) >> xs]; \
      /* row y - 1 at x - 16 .. x + 16, row y at x - 16 .. x - 1, row y - 2 at x - 2 .. x + 2 */ \
      k = ((wl >> 8) & 0x1FFFFFFFFull) << 16 ^ (w0 & 0xFFFF) ^ (uint64_t)((w2 >> 2) & 0x1F) << 50; \
      c[5] = &m->bx[1][((k + 7) * 0xD6E8FEB86659FD93ull) >> xs]; \
      /* t1, rows y - 6, y - 8 and y - 12 at x - 4, x and x + 4, row y - 1 at \
         x - 20, x - 12, x + 12 and x + 20, row y at x - 12 and x - 20 */ \
      k = t1; \
      k = k << 3 | ((w6 >> 8) & 1) << 2 | ((w6 >> 4) & 1) << 1 | (w6 & 1); \
      k = k << 3 | ((w8 >> 8) & 1) << 2 | ((w8 >> 4) & 1) << 1 | (w8 & 1); \
      k = k << 3 | ((wc >> 8) & 1) << 2 | ((wc >> 4) & 1) << 1 | (wc & 1); \
      k = k << 4 | ((wl >> 44) & 1) << 3 | ((wl >> 36) & 1) << 2 | ((wl >> 12) & 1) << 1 | ((wl >> 4) & 1); \
      k = k << 2 | ((w0 >> 11) & 1) << 1 | ((w0 >> 19) & 1); \
      c[6] = &m->bx[2][((k + 3) * 0x9E3779B97F4A7C15ull) >> xs]; \
      sel = ((w2 >> 3) & 7) << 5 | ((w1 >> 5) & 7) << 2 | (uint32_t)(w0 & 3); \
      bit = dec ? 0 : r0[x] & 1; \
      bit = mix_code(m, dec, bit, c, 7, &m->bw[sel], m->bapm[t1], m->blr); \
      if (dec) r0[x] = (uint16_t)bit; \
      w2 = ((w2 << 1) | FETCH(r2, x + 5)) & 0x1FF; \
      w1 = ((w1 << 1) | FETCH(r1, x + 7)) & 0x1FFF; \
      w0 = ((w0 << 1) | (uint32_t)bit) & 0xFFFFFFFFull; \
      w3 = ((w3 << 1) | FETCH(r3, x + 9)) & 0x1FFFF; \
      w4 = ((w4 << 1) | FETCH(r4, x + 9)) & 0x1FFFF; \
      w6 = ((w6 << 1) | FETCH(r6, x + 5)) & 0x1FF; \
      w8 = ((w8 << 1) | FETCH(r8, x + 5)) & 0x1FF; \
      wc = ((wc << 1) | FETCH(r12, x + 5)) & 0x1FF; \
      wl = ((wl << 1) | FETCH(r1, x + 25)) & 0x1FFFFFFFFFFFFull; \
    } while (0)

/* a 1-bit plane, row by row: seven templates, mixed and mapped. Four of
   the rows y - 2 to y (10, 16, 22 and 30 pixels; the two large ones in
   tables of 2^hb counters, hashed when they do not fit) and three farther
   ones, hashed into tables of 2^(hb - 2): rows y - 4 and y - 3 with the
   22-pixel one; rows y - 1 and y, 16 pixels each way, with three of row y
   - 2; and the 10-pixel one with sparse pixels of rows y - 12, y - 8, y -
   6, y - 1 and y (a text line's period and the far left and right) */
PX_INLINE int code_bitonal(pxm_t *m, const int dec, uint16_t *pl, int64_t w, int64_t h)
{
  int64_t x, y; uint32_t hmask = (uint32_t)m->hsize - 1; int sh = 32 - m->hbits, xs = 64 - (m->hbits - 2);
  for (y = 0; y < h; y++) {
    uint16_t *r0 = pl + y * w; const uint16_t *r1 = y >= 1 ? r0 - w : 0, *r2 = y >= 2 ? r0 - 2 * w : 0;
    const uint16_t *r3 = y >= 3 ? r0 - 3 * w : 0, *r4 = y >= 4 ? r0 - 4 * w : 0, *r6 = y >= 6 ? r0 - 6 * w : 0;
    const uint16_t *r8 = y >= 8 ? r0 - 8 * w : 0, *r12 = y >= 12 ? r0 - 12 * w : 0;
    /* windows (the rightmost pixel at bit 0): row y - 2 at x - 4 .. x + 4,
       row y - 1 at x - 6 .. x + 6 and x - 24 .. x + 24, row y at x - 32 ..
       x - 1; rows y - 3 and y - 4 at x - 8 .. x + 8, rows y - 6, y - 8 and
       y - 12 at x - 4 .. x + 4 */
    uint32_t w2 = 0, w1 = 0, w3 = 0, w4 = 0, w6 = 0, w8 = 0, wc = 0; uint64_t wl = 0, w0 = 0;
    for (x = -4; x <= 4; x++) {
      w2 = (w2 << 1) | PXB(r2, x); w6 = (w6 << 1) | PXB(r6, x); w8 = (w8 << 1) | PXB(r8, x);
      wc = (wc << 1) | PXB(r12, x);
    }
    for (x = -6; x <= 6; x++) w1 = (w1 << 1) | PXB(r1, x);
    for (x = -8; x <= 8; x++) { w3 = (w3 << 1) | PXB(r3, x); w4 = (w4 << 1) | PXB(r4, x); }
    for (x = -24; x <= 24; x++) wl = (wl << 1) | PXB(r1, x);
    /* where every pixel the windows take in (up to x + 25) is in the row,
       without the bounds: a row above the plane (none) reads row y, masked */
    {
      const uint16_t *q1 = r1 ? r1 : r0, *q2 = r2 ? r2 : r0, *q3 = r3 ? r3 : r0, *q4 = r4 ? r4 : r0;
      const uint16_t *q6 = r6 ? r6 : r0, *q8 = r8 ? r8 : r0, *q12 = r12 ? r12 : r0;
      uint16_t k1 = r1 ? 1 : 0, k2 = r2 ? 1 : 0, k3 = r3 ? 1 : 0, k4 = r4 ? 1 : 0, k6 = r6 ? 1 : 0, k8 = r8 ? 1 : 0;
      uint16_t k12 = r12 ? 1 : 0;
      int64_t xf = w - 25;
#define PXF(r, xx) ((uint32_t)(Q_##r[xx] & K_##r))
#define Q_r1 q1
#define Q_r2 q2
#define Q_r3 q3
#define Q_r4 q4
#define Q_r6 q6
#define Q_r8 q8
#define Q_r12 q12
#define K_r1 k1
#define K_r2 k2
#define K_r3 k3
#define K_r4 k4
#define K_r6 k6
#define K_r8 k8
#define K_r12 k12
      for (x = 0; x < xf; x++) BITONAL_PIXEL(PXF);
#undef PXF
      for (; x < w; x++) BITONAL_PIXEL(PXB);
    }
  }
  return 0;
}
#undef PXB
#undef BITONAL_PIXEL
#undef Q_r1
#undef Q_r2
#undef Q_r3
#undef Q_r4
#undef Q_r6
#undef Q_r8
#undef Q_r12
#undef K_r1
#undef K_r2
#undef K_r3
#undef K_r4
#undef K_r6
#undef K_r8
#undef K_r12

/* ------------------------------------------------------------------ 2 to 16 bits */
static inline int med(int a, int b, int c)
{
  int mx = a > b ? a : b, mn = a < b ? a : b;
  return c >= mx ? mn : c <= mn ? mx : a + b - c;
}
static inline int quant(int d, int t1, int t2, int t3)
{
  if (d <= -t3) return -4;
  if (d <= -t2) return -3;
  if (d <= -t1) return -2;
  if (d < 0) return -1;
  if (d == 0) return 0;
  if (d < t1) return 1;
  if (d < t2) return 2;
  if (d < t3) return 3;
  return 4;
}
static inline int tclamp(int i, int j, int mx) { return i > mx || i < j ? j : i; }
/* a magnitude's coarse log: 0 for 0, else floor(2 log2 v) + 1 */
static inline int flog(uint32_t v)
{
  int l;
  if (!v) return 0;
  l = ilog2_32(v);
  return 2 * l + (l > 0 ? (int)((v >> (l - 1)) & 1) : 0) + 1;
}

/* a plane of depth bits, row by row: NP predictors weighted by their
   errors around the sample (each half octave of error halves a weight;
   one of them MED plus the previous component's error under MED, po, when
   that component has the same size; one a sign-sign LMS); the residual
   (aligned by the sign of LOCO's gradient context, modulo the range) as
   zero or not, bit length, mantissa and sign, each decision from five
   contexts mixed and mapped: LOCO's mean residual of the context (its
   bias is kept for that alone), the gradients, the neighbours' residuals,
   the previous component's error, the predictors' least error and their
   spread. res:
   PX_RESW w int32, the residuals and the predictors' errors of this row
   and the row above */
#define NP 8
#define PX_RESW (2 + 2 * NP)
PX_INLINE int code_samples(pxm_t *m, const int dec, uint16_t *pl, int64_t w, int64_t h, int depth, int cls,
  int32_t *res, const uint16_t *po)
{
  int maxv = (1 << depth) - 1, range = maxv + 1, half = range >> 1, t1, t2, t3, f;
  int64_t x, y;
  /* JPEG-LS's default thresholds (C.2.4.1.1.1), NEAR 0 */
  if (maxv >= 128) {
    f = ((maxv < 4095 ? maxv : 4095) + 128) >> 8;
    t1 = tclamp(f * (3 - 2) + 2, 1, maxv); t2 = tclamp(f * (7 - 3) + 3, t1, maxv);
    t3 = tclamp(f * (21 - 4) + 4, t2, maxv);
  } else {
    f = 256 / (maxv + 1);
    t1 = tclamp(3 / f > 2 ? 3 / f : 2, 1, maxv); t2 = tclamp(7 / f > 3 ? 7 / f : 3, t1, maxv);
    t3 = tclamp(21 / f > 4 ? 21 / f : 4, t2, maxv);
  }
  for (y = 0; y < h; y++) {
    uint16_t *r0 = pl + y * w; const uint16_t *r1 = y > 0 ? r0 - w : 0;
    int32_t *e0 = res + (y & 1) * w; const int32_t *e1 = y > 0 ? res + ((y - 1) & 1) * w : 0;
    int32_t *pe0 = res + 2 * w + (y & 1) * NP * w; const int32_t *pe1 = y > 0 ? res + 2 * w + ((y - 1) & 1) * NP * w : 0;
    const uint16_t *o0 = po ? po + y * w : 0, *o1 = po && y > 0 ? o0 - w : 0;
    for (x = 0; x < w; x++) {
      int a, b, c, d, ctx, sgn = 1, px, e, v, act, nbb, oth, k, ex, bit, bi, ci, eo = 0, i, lmin = 99;
      int P[NP], L[NP], pmin, pmax, spr, lq[8]; uint32_t sw = 0, sp = 0;
      ctr_t *cc[5];
      if (o0) {
        int ob = o1 ? o1[x] : x > 0 ? o0[x - 1] : half, oa = x > 0 ? o0[x - 1] : ob, oc = o1 && x > 0 ? o1[x - 1] : ob;
        eo = (int)o0[x] - med(oa, ob, oc);
      }
      b = r1 ? r1[x] : x > 0 ? r0[x - 1] : half;
      a = x > 0 ? r0[x - 1] : b;
      c = r1 && x > 0 ? r1[x - 1] : b;
      d = r1 && x + 1 < w ? r1[x + 1] : b;
      ctx = (quant(d - b, t1, t2, t3) * 9 + quant(b - c, t1, t2, t3)) * 9 + quant(c - a, t1, t2, t3);
      if (ctx < 0) { sgn = -1; ctx = -ctx; }
      P[0] = med(a, b, c);
      P[1] = a + b - c;
      P[2] = b + ((d - c) >> 1);
      P[3] = a + ((d - b) >> 1);
      P[4] = o0 ? P[0] + eo : (a + d + 1) >> 1;
      P[5] = b; P[6] = a;
      /* sign-sign LMS over eight neighbours, against W */
      {
        int nn = y > 1 ? r1[x - w] : b, ww = x > 1 ? r0[x - 2] : a, nw2 = y > 1 && x > 0 ? r1[x - w - 1] : c,
          ne2 = y > 1 && x + 1 < w ? r1[x - w + 1] : d;
        int32_t q[8] = {0, b - a, c - a, d - a, nn - a, ww - a, nw2 - a, ne2 - a}; int64_t acc = 0;
        for (i = 1; i < 8; i++) acc += (int64_t)m->lms[i] * q[i];
        P[7] = a + (int)(acc >> 12);
        for (i = 1; i < 8; i++) lq[i] = q[i];
      }
      for (i = 0; i < NP; i++) {
        uint32_t E = 0;
        if (P[i] < 0) P[i] = 0; else if (P[i] > maxv) P[i] = maxv;
        if (x > 0) E += (uint32_t)pe0[i * w + x - 1];
        if (pe1) {
          E += (uint32_t)pe1[i * w + x];
          if (x > 0) E += (uint32_t)pe1[i * w + x - 1] >> 1;
          if (x + 1 < w) E += (uint32_t)pe1[i * w + x + 1] >> 1;
        }
        L[i] = flog(E);
        if (L[i] < lmin) lmin = L[i];
      }
      for (i = 0; i < NP; i++) {
        uint32_t wt = 4096u >> ((L[i] - lmin) * 3 / 4 > 12 ? 12 : (L[i] - lmin) * 3 / 4);
        sw += wt; sp += wt * (uint32_t)P[i];
      }
      px = (int)((sp + (sw >> 1)) / sw);
      pmin = pmax = P[0];
      for (i = 1; i < NP; i++) { if (P[i] < pmin) pmin = P[i]; if (P[i] > pmax) pmax = P[i]; }
      spr = clampi(flog((uint32_t)(pmax - pmin)), 0, 31);
      if (lmin > 39) lmin = 39;
      if (px < 0) px = 0; else if (px > maxv) px = maxv;
      if (!dec) {
        e = ((int)r0[x] - px) * sgn;
        if (e < -(range >> 1)) e += range; else if (e >= (range + 1) >> 1) e -= range;
      } else e = 0;
      { int32_t q = m->bias[cls][ctx].a / m->bias[cls][ctx].n; act = clampi(flog((uint32_t)q), 0, 31); }
      nbb = 0;
      if (x > 0) nbb += ab32(e0[x - 1]);
      if (e1) { nbb += ab32(e1[x]); if (x + 1 < w) nbb += ab32(e1[x + 1]) >> 1; if (x > 0) nbb += ab32(e1[x - 1]) >> 1; }
      nbb = clampi(flog((uint32_t)nbb), 0, 31);
      oth = o0 ? clampi(flog(ab32(eo)), 0, 30) + 1 : 0;
      bi = cls * 32 + act;
      /* zero or not */
      cc[0] = &m->z[0][bi];
      cc[1] = &m->z[1][cls * 365 + ctx];
      cc[2] = &m->z[2][(cls * 32 + nbb) * 32 + act];
      cc[3] = &m->z[3][(oth * 32 + act) * 2 + cls];
      cc[4] = &m->z[4][(cls * 40 + lmin) * 32 + spr];
      bit = mix_code(m, dec, e != 0, cc, 5, &m->mw[0][cls * 256 + (lmin >> 2) * 16 + (spr >> 1)], m->mapm[0][(cls * 32 + act) * 16 + (nbb >> 1)], m->lr);
      if (bit) {
        uint32_t av = ab32(e);
        ex = dec ? 0 : ilog2_32(av) + 1;
        /* the bit length, 1 to depth + 1: whether it is more than k */
        k = 1;
        while (k <= depth) {
          int g;
          ci = k - 1;
          cc[0] = &m->xe[0][(bi * 18 + ci)];
          cc[1] = &m->xe[1][((cls * 365 + ctx) * 18 + ci)];
          cc[2] = &m->xe[2][((cls * 32 + nbb) * 32 + act) * 18 + ci];
          cc[3] = &m->xe[3][((oth * 32 + act) * 18 + ci) * 2 + cls];
          cc[4] = &m->xe[4][(lmin * 32 + spr) * 18 + ci];
          g = mix_code(m, dec, ex > k, cc, 5, &m->mw[1][(cls * 16 + clampi(ci, 0, 15)) * 16 + (act >> 1)],
            m->mapm[1][((cls * 18 + ci) * 32 + act) & 1023], m->lr);
          if (!g) break;
          k++;
        }
        if (dec) ex = k;
        /* the mantissa, below the leading 1 (ex bits in all) */
        if (dec) av = 1;
        for (ci = ex - 2; ci >= 0; ci--) {
          int top = ex - 2 - ci, mb, pb = (int)((dec ? av : av >> (ci + 1)) & 1);
          if (top < 2) {
            cc[0] = &m->mm[0][((cls * 18 + ex) * 2 + top) * 2 + (top ? pb : 0)];
            cc[1] = &m->mm[1][((((cls * 18 + ex) * 2 + top) * 2 + (top ? pb : 0)) * 32 + act) & 4095];
            cc[2] = &m->mm[2][((((cls * 18 + ex) * 2 + top) * 2 + (top ? pb : 0)) * 32 + nbb) & 4095];
            mb = mix_code(m, dec, dec ? 0 : (int)((av >> ci) & 1), cc, 3, &m->mw[2][(cls * 18 + ex) * 2 + top],
              m->mapm[2][((cls * 18 + ex) * 2 + top) * 8 + (act >> 2)], m->lr);
          } else {
            ctr_t *c1 = &m->mm[0][2048 + ((cls * 18 + ex) * 18 + ci) % 2048];
            mb = ac_code(&m->ac, CP(c1->p), dec ? 0 : (int)((av >> ci) & 1), dec);
            learn(c1, mb);
          }
          if (dec) av = (av << 1) | (uint32_t)mb;
        }
        /* the sign, with the neighbours' */
        {
          int sc = 0, neg;
          if (x > 0) sc = e0[x - 1] < 0 ? 1 : e0[x - 1] > 0 ? 2 : 0;
          if (e1) sc += e1[x] < 0 ? 3 : e1[x] > 0 ? 6 : 0;
          if (o0) sc += eo < 0 ? 9 : eo > 0 ? 18 : 0;
          {
            ctr_t *c1 = &m->sg[cls][(sc * 32 + act) & 1023];
            neg = ac_code(&m->ac, CP(c1->p), e < 0, dec);
            learn(c1, neg);
          }
          if (dec) e = neg ? -(int)av : (int)av;
        }
      }
      if (dec) {
        int xv = px + e * sgn;
        if (xv < 0) xv += range; else if (xv > maxv) xv -= range;
        if (xv < 0 || xv > maxv) return -1;
        r0[x] = (uint16_t)xv;
      }
      e0[x] = e;
      for (i = 0; i < NP; i++) pe0[i * w + x] = (int32_t)ab32((int)r0[x] - P[i]);
      /* the LMS weights: towards the sample, by the signs */
      {
        int er = (int)r0[x] - P[7];
        if (er) for (i = 1; i < 8; i++) {
          if (lq[i] > 0) m->lms[i] += er > 0 ? 16 : -16; else if (lq[i] < 0) m->lms[i] += er > 0 ? -16 : 16;
          m->lms[i] = clampi(m->lms[i], -8192, 8192);
        }
      }
      /* LOCO's bias update (A.12, A.13) */
      {
        int32_t *A = &m->bias[cls][ctx].a, *B = &m->bias[cls][ctx].b, *C = &m->bias[cls][ctx].c, *N = &m->bias[cls][ctx].n;
        v = e;
        *A += (int32_t)ab32(v); *B += v;
        if (*N == 64) { *A >>= 1; *B = *B >= 0 ? *B / 2 : -((-*B + 1) / 2); *N >>= 1; }
        (*N)++;
        if (*B + *N <= 0) { *B += *N; if (*B <= -*N) *B = -*N + 1; if (*C > -128) (*C)--; }
        else if (*B > 0) { *B -= *N; if (*B > 0) *B = 0; if (*C < 127) (*C)++; }
      }
    }
  }
  return 0;
}

/* The planes of n components (w[i] x h[i] samples of depth[i] bits, 1 to
   16, in planes[i]), one after the other, through the models: encoding,
   to put(pctx, ..); decoding, from data[0..len) into the planes. mem (size
   bytes, pjaj2kp_model_size(hb)) holds the model; res, pjaj2kp_res_width()
   max(w) int32. 0, or -1 */
int32_t pjaj2kp_res_width(void) { return PX_RESW; }

/* the two models compiled once for each direction, and again on x86 for
   SSE4.1 and (the multi-bit one) for AVX2: the mixers' lanes in pmulld,
   pminsd and pmaxsd, taken by path (2 AVX2, 1 SSE4.1: pjamodel's cpuid, as
   pjaj2kmc.c's). The same C, the same integer arithmetic, so the same bits
   on every path. The bitonal model's AVX2 copy was 7% slower than its
   SSE4.1 one (its 14 lanes are 8 + 4 + 2 there; a bitonal page, one
   thread): it takes the SSE4.1 copy on both paths */
#define PX_COPY_B(SUF, ATTR) \
  ATTR static int bitonal_e##SUF(pxm_t *m, uint16_t *pl, int64_t w, int64_t h) { return code_bitonal(m, 0, pl, w, h); } \
  ATTR static int bitonal_d##SUF(pxm_t *m, uint16_t *pl, int64_t w, int64_t h) { return code_bitonal(m, 1, pl, w, h); }
#define PX_COPY_S(SUF, ATTR) \
  ATTR static int samples_e##SUF(pxm_t *m, uint16_t *pl, int64_t w, int64_t h, int depth, int cls, int32_t *res, \
    const uint16_t *po) { return code_samples(m, 0, pl, w, h, depth, cls, res, po); } \
  ATTR static int samples_d##SUF(pxm_t *m, uint16_t *pl, int64_t w, int64_t h, int depth, int cls, int32_t *res, \
    const uint16_t *po) { return code_samples(m, 1, pl, w, h, depth, cls, res, po); }
PX_COPY_B(, )
PX_COPY_S(, )
#if (defined(__x86_64__) || defined(__i386__)) && !defined(PJA_V7_PLAIN) && (defined(__GNUC__) || defined(__clang__))
#define PX_SIMD 1
PX_COPY_B(_sse41, __attribute__((target("sse4.1"))))
PX_COPY_S(_sse41, __attribute__((target("sse4.1"))))
PX_COPY_S(_avx2, __attribute__((target("avx2"))))
#endif

static int bitonal(pxm_t *m, int dec, int path, uint16_t *pl, int64_t w, int64_t h)
{
#ifdef PX_SIMD
  if (path == 1 || path == 2) return dec ? bitonal_d_sse41(m, pl, w, h) : bitonal_e_sse41(m, pl, w, h);
#endif
  (void)path;
  return dec ? bitonal_d(m, pl, w, h) : bitonal_e(m, pl, w, h);
}

static int samples(pxm_t *m, int dec, int path, uint16_t *pl, int64_t w, int64_t h, int depth, int cls, int32_t *res,
  const uint16_t *po)
{
#ifdef PX_SIMD
  if (path == 2)
    return dec ? samples_d_avx2(m, pl, w, h, depth, cls, res, po) : samples_e_avx2(m, pl, w, h, depth, cls, res, po);
  if (path == 1)
    return dec ? samples_d_sse41(m, pl, w, h, depth, cls, res, po) : samples_e_sse41(m, pl, w, h, depth, cls, res, po);
#endif
  (void)path;
  return dec ? samples_d(m, pl, w, h, depth, cls, res, po) : samples_e(m, pl, w, h, depth, cls, res, po);
}

int32_t pjaj2kp_code(void *mem, int64_t size, int32_t hb, int32_t encoding, px_put_t put, void *pctx,
  const uint8_t *data, int64_t len, int32_t n, const int32_t *w, const int32_t *h, const int32_t *depth,
  uint16_t **planes, int32_t *res, int64_t rescap, int32_t path)
{
  pxm_t *m = mem; int i, k, dec = !encoding;
  if (size < pjaj2kp_model_size(hb) || n < 0) return -1;
  px_init(m, hb);
  m->ac.x1 = 0; m->ac.x2 = 0xFFFFFFFFu; m->ac.x = 0; m->ac.put = put; m->ac.pctx = pctx; m->ac.n = 0;
  m->ac.d = data; m->ac.len = data ? len : 0; m->ac.p = 0;
  if (dec) for (i = 0; i < 4; i++) {
    uint32_t b = m->ac.p < m->ac.len ? data[m->ac.p] : 0;
    m->ac.p++; m->ac.x = (m->ac.x << 8) | b;
  }
  for (i = 0; i < n; i++) {
    int64_t sz = (int64_t)w[i] * h[i];
    const uint16_t *po = 0;
    if (w[i] < 0 || h[i] < 0 || depth[i] < 1 || depth[i] > 16) return -1;
    if (sz == 0) continue;
    if (depth[i] == 1) {
      if (bitonal(m, dec, path, planes[i], w[i], h[i])) return -1;
      continue;
    }
    if (PX_RESW * (int64_t)w[i] > rescap) return -1;
    /* the previous component, when it has the same size */
    if (i > 0 && w[i - 1] == w[i] && h[i - 1] == h[i] && depth[i - 1] > 1) po = planes[i - 1];
    if (samples(m, dec, path, planes[i], w[i], h[i], depth[i], i > 0, res, po)) return -1;
  }
  if (!dec) {
    /* the last bytes out (x1, as pjaarith's Finish) */
    for (k = 0; k < 4; k++) {
      m->ac.buf[m->ac.n++] = (uint8_t)(m->ac.x1 >> 24);
      if (m->ac.n == EBUF) { m->ac.put(m->ac.pctx, m->ac.buf, EBUF); m->ac.n = 0; }
      m->ac.x1 <<= 8;
    }
    if (m->ac.n) m->ac.put(m->ac.pctx, m->ac.buf, m->ac.n);
    m->ac.n = 0;
  }
  return 0;
}

/* the planes p0, p1, p2 (n samples of depth bits, at most 15) to the
   reversible colour transform's (fwd: Y of depth bits, Db + 2^depth and
   Dr + 2^depth of depth + 1 bits), or back: 0, or -1 when a sample is out
   of its range */
int32_t pjaj2kp_planes_rct(uint16_t *p0, uint16_t *p1, uint16_t *p2, int64_t n, int32_t depth, int32_t fwd)
{
  int64_t i; int32_t off = 1 << depth, mx = (1 << depth) - 1;
  if (depth < 1 || depth > 15) return -1;
  for (i = 0; i < n; i++) {
    int32_t r, g, b, y, u, v;
    if (fwd) {
      r = p0[i]; g = p1[i]; b = p2[i];
      if (r > mx || g > mx || b > mx) return -1;
      p0[i] = (uint16_t)((r + 2 * g + b) >> 2); p1[i] = (uint16_t)(b - g + off); p2[i] = (uint16_t)(r - g + off);
    } else {
      y = p0[i]; u = (int32_t)p1[i] - off; v = (int32_t)p2[i] - off;
      g = y - ((u + v) >> 2); r = v + g; b = u + g;
      if (r < 0 || r > mx || g < 0 || g > mx || b < 0 || b > mx) return -1;
      p0[i] = (uint16_t)r; p1[i] = (uint16_t)g; p2[i] = (uint16_t)b;
    }
  }
  return 0;
}

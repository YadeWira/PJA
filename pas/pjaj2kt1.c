/* JPEG 2000 Part 1 tier-1, in C (doc/CODEC.md, "JPEG 2000, stage B"):
   a code-block's coding passes to its decisions and back, and the MQ coder's
   ways of ending a segment. Called through pjaj2kcs.pas, which owns every
   buffer: this file takes no memory and calls no library, as pjav7c.c.

   A decision is one byte, ctx << 1 | bit: ctx 0-8 the zero coding contexts,
   9-13 sign coding, 14-16 magnitude refinement, 17 run length, 18 uniform,
   19 a raw (BYPASS) bit. The bit is what the coder codes: a sign's bit
   before the sign prediction's xor, as the MQ coder sees it.

   - pjaj2k_t1_decode: the passes of a code-block from its segments' bytes,
     as a decoder reads them (OpenJPEG 2's conventions: past the end of a
     segment, bytes FF; a byte FF followed by one above 8F ends the data);
   - pjaj2k_t1_replay: the same passes from the decisions' bits alone, which
     gives each decision its context back (what the rebuild does);
   - pjaj2k_mq_encode: a segment's decisions coded with the MQ coder, ended
     both ways the standard has (FLUSH and ERTERM), with the bytes committed
     at each pass end;
   - pjaj2k_mq_valid / pjaj2k_mq_minprefix: whether a prefix of bytes decodes
     a segment's first decisions, and the shortest such prefix found going
     down from a length;
   - pjaj2k_raw_pack: a BYPASS segment's bits as bytes, with one of three
     paddings.

   Determinism: integer arithmetic only, no table built at run time. Every
   buffer's size is passed and checked; a call that would go past one
   returns an error instead. */
#include <stdint.h>

#include "pjaj2kt1.h"

/* the MQ coder's tables (ISO/IEC 15444-1, table C.2) */
static const uint16_t QE[47] = {0x5601,0x3401,0x1801,0x0AC1,0x0521,0x0221,0x5601,0x5401,0x4801,0x3801,0x3001,
  0x2401,0x1C01,0x1601,0x5601,0x5401,0x5101,0x4801,0x3801,0x3401,0x3001,0x2801,0x2401,0x2201,0x1C01,0x1801,
  0x1601,0x1401,0x1201,0x1101,0x0AC1,0x09C1,0x08A1,0x0521,0x0441,0x02A1,0x0221,0x0141,0x0111,0x0085,0x0049,
  0x0025,0x0015,0x0009,0x0005,0x0001,0x5601};
static const uint8_t NMPS[47] = {1,2,3,4,5,38,7,8,9,10,11,12,13,29,15,16,17,18,19,20,21,22,23,24,25,26,27,28,
  29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,45,46};
static const uint8_t NLPS[47] = {1,6,9,12,29,33,6,14,14,14,17,18,20,21,14,14,15,16,17,18,19,19,20,21,22,23,24,
  25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,46};
static const uint8_t SWITCH[47] = {1,0,0,0,0,0,1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0};

/* the contexts' states: I[19] then M[19] */
#define NCTX 19
static void ctx_reset(uint8_t *x)
{
  int i;
  for (i = 0; i < 2 * NCTX; i++) x[i] = 0;
  x[18] = 46; x[17] = 3; x[0] = 4;
}

/* ------------------------------------------------------------------ MQ decoder */
typedef struct { const uint8_t *d; int64_t n, p; uint32_t A, C; int32_t CT; uint32_t fill; } mqd_t;
static inline uint32_t rdb(const mqd_t *q, int64_t i) { return i < q->n ? q->d[i] : q->fill; }
static inline void bytein(mqd_t *q)
{
  if (rdb(q, q->p) == 0xFF) {
    if (rdb(q, q->p + 1) > 0x8F) { q->C += 0xFF00; q->CT = 8; }
    else { q->p++; q->C += rdb(q, q->p) << 9; q->CT = 7; }
  } else { q->p++; q->C += rdb(q, q->p) << 8; q->CT = 8; }
}
static void initdec(mqd_t *q, const uint8_t *d, int64_t n)
{
  q->d = d; q->n = n; q->p = 0; q->fill = 0xFF; q->C = rdb(q, 0) << 16; bytein(q); q->C <<= 7; q->CT -= 7; q->A = 0x8000;
}
static inline int mqdec(mqd_t *q, uint8_t *x, int cx)
{
  int i = x[cx], d; uint32_t qe = QE[i];
  q->A -= qe;
  if ((q->C >> 16) < qe) {
    if (q->A < qe) { q->A = qe; d = x[NCTX + cx]; x[cx] = NMPS[i]; }
    else { q->A = qe; d = 1 - x[NCTX + cx]; if (SWITCH[i]) x[NCTX + cx] ^= 1; x[cx] = NLPS[i]; }
  } else {
    q->C -= qe << 16;
    if ((q->A & 0x8000) == 0) {
      if (q->A < qe) { d = 1 - x[NCTX + cx]; if (SWITCH[i]) x[NCTX + cx] ^= 1; x[cx] = NLPS[i]; }
      else { d = x[NCTX + cx]; x[cx] = NMPS[i]; }
    } else return x[NCTX + cx];
  }
  do { if (q->CT == 0) bytein(q); q->A <<= 1; q->C <<= 1; q->CT--; } while ((q->A & 0x8000) == 0);
  return d;
}

/* ------------------------------------------------------------------ tier-1 */
typedef struct {
  int raw;                        /* the pass is a raw (BYPASS) one */
  mqd_t q; uint8_t x[2 * NCTX];   /* decode: the MQ decoder and the contexts */
  int64_t rp; uint32_t rc; int32_t rct;  /* decode: the raw reader */
  const uint8_t *bits; int64_t bp, nb;   /* replay: the decisions' bits */
  uint8_t *sym; int64_t ns, cap;
  int err;
} t1s_t;

static inline int rawbit(t1s_t *s)
{
  if (s->rct == 0) {
    if (s->rc == 0xFF) {
      uint32_t b = rdb(&s->q, s->rp);
      if (b > 0x8F) { s->rc = 0xFF; s->rct = 8; }
      else { s->rc = b; s->rp++; s->rct = 7; }
    } else { s->rc = rdb(&s->q, s->rp); s->rp++; s->rct = 8; }
  }
  s->rct--;
  return (int)((s->rc >> s->rct) & 1);
}

/* the passes are compiled twice, decoding and replaying (mode a constant) */
#if defined(__GNUC__) || defined(__clang__)
#define T1_INLINE static inline __attribute__((always_inline))
#else
#define T1_INLINE static inline
#endif

T1_INLINE int decide(t1s_t *s, int ctx, int mode)
{
  int b;
  if (s->ns >= s->cap) { s->err = 1; return 0; }
  if (mode) {
    if (s->bp >= s->nb) { s->err = 2; return 0; }
    b = (s->bits[s->bp >> 3] >> (7 - (s->bp & 7))) & 1; s->bp++;
  } else if (s->raw) b = rawbit(s);
  else b = mqdec(&s->q, s->x, ctx);
  s->sym[s->ns++] = (uint8_t)(((s->raw ? 19 : ctx) << 1) | b);
  return b;
}

T1_INLINE void sign_step(t1s_t *s, uint8_t *st, uint8_t *nb, int i, int stride, int excl, int mode)
{
  int xr, cx = sc_ctx(st, i, stride, excl, &xr);
  int b = decide(s, cx, mode);
  make_sig(st, nb, i, stride, s->raw ? b : (b ^ xr));
}

T1_INLINE void pass_spp(t1s_t *s, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int m;
        if (st[i] & SIG) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        if (!m) continue;
        st[i] |= PIV;
        if (decide(s, zc[m], mode)) sign_step(s, st, nb, i, stride, causal && (y & 3) == 3, mode);
      }
      if (s->err) return;
    }
  }
}

T1_INLINE void pass_mrp(t1s_t *s, uint8_t *st, uint8_t *nb, int w, int h, int causal, int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i = (y0 + 1) * stride + x + 1;
      for (y = y0; y < y1; y++, i += stride) {
        int m;
        if ((st[i] & (SIG | PIV)) != SIG) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        decide(s, (st[i] & REF) ? 16 : m ? 15 : 14, mode);
        st[i] |= REF;
      }
      if (s->err) return;
    }
  }
}

T1_INLINE void pass_cup(t1s_t *s, uint8_t *st, uint8_t *nb, int w, int h, const uint8_t *zc, int causal, int segmark,
  int mode)
{
  int stride = w + 2, y0, x, y;
  for (y0 = 0; y0 < h; y0 += 4) {
    int y1 = y0 + 4 < h ? y0 + 4 : h;
    for (x = 0; x < w; x++) {
      int i0 = (y0 + 1) * stride + x + 1, i;
      y = y0;
      if (y1 - y0 == 4 && !(st[i0] | st[i0 + stride] | st[i0 + 2 * stride] | (st[i0 + 3 * stride] & (SIG | PIV))) &&
          !(nb[i0] | nb[i0 + stride] | nb[i0 + 2 * stride] | (nb[i0 + 3 * stride] & (causal ? ~SOUTH : 0xFF)))) {
        /* run-length mode: the four insignificant, not visited, no significant neighbour */
        int r;
        if (!decide(s, 17, mode)) { if (s->err) return; continue; }
        r = decide(s, 18, mode) << 1; r |= decide(s, 18, mode);
        y = y0 + r;
        sign_step(s, st, nb, i0 + r * stride, stride, causal && (y & 3) == 3, mode);
        y++;
      }
      for (i = i0 + (y - y0) * stride; y < y1; y++, i += stride) {
        int m;
        if (st[i] & (SIG | PIV)) continue;
        m = nb[i];
        if (causal && (y & 3) == 3) m &= ~SOUTH;
        if (decide(s, zc[m], mode)) sign_step(s, st, nb, i, stride, causal && (y & 3) == 3, mode);
      }
      if (s->err) return;
    }
  }
  for (y = 0; y < h; y++) {
    uint8_t *p = st + (y + 1) * stride + 1;
    for (x = 0; x < w; x++) p[x] &= (uint8_t)~PIV;
  }
  if (segmark) { decide(s, 18, mode); decide(s, 18, mode); decide(s, 18, mode); decide(s, 18, mode); }
}

/* the passes of a code-block, in either mode; st is 2 (w + 2) (h + 2) bytes */
T1_INLINE int64_t run_passes(t1s_t *s, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  const uint8_t *data, const int32_t *seglen, const int32_t *segpasses, int32_t nseg,
  int32_t *passend, uint8_t *st, int mode)
{
  int k, seg = -1, left = 0, causal = (sty & 8) != 0; int64_t off = 0, n = (int64_t)(w + 2) * (h + 2), i;
  uint8_t *nb = st + n; const uint8_t *zc;
  if (w < 1 || h < 1 || w > 1024 || h > 1024 || (int64_t)w * h > 4096 || orient < 0 || orient > 3 ||
      npasses < 0 || npasses > 255) return -3;
  zc = ZC[orient];
  for (i = 0; i < 2 * n; i++) st[i] = 0;
  ctx_reset(s->x);
  for (k = 0; k < npasses; k++) {
    int type = k == 0 ? 2 : (k - 1) % 3;   /* 0 significance, 1 refinement, 2 cleanup */
    s->raw = (sty & 1) && k >= 10 && type < 2;
    if (mode == 0) {
      if (left == 0) {
        seg++;
        if (seg >= nseg) return -4;
        if (seg > 0) off += seglen[seg - 1];
        left = segpasses[seg];
        if (left <= 0 || seglen[seg] < 0) return -4;
        if (s->raw) { s->q.d = data + off; s->q.n = seglen[seg]; s->rp = 0; s->rc = 0; s->rct = 0; }
        else initdec(&s->q, data + off, seglen[seg]);
      }
      left--;
    }
    if (type == 0) pass_spp(s, st, nb, w, h, zc, causal, mode);
    else if (type == 1) pass_mrp(s, st, nb, w, h, causal, mode);
    else pass_cup(s, st, nb, w, h, zc, causal, (sty & 32) != 0, mode);
    if (s->err) return s->err == 1 ? -1 : -2;
    passend[k] = (int32_t)s->ns;
    if ((sty & 2) && !s->raw && mode == 0) ctx_reset(s->x);
  }
  if (mode == 0 && (seg != nseg - 1 || left != 0)) return -4;
  return s->ns;
}

static int64_t run_decode(t1s_t *s, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  const uint8_t *data, const int32_t *seglen, const int32_t *segpasses, int32_t nseg, int32_t *passend, uint8_t *st)
{
  return run_passes(s, w, h, orient, sty, npasses, data, seglen, segpasses, nseg, passend, st, 0);
}

static int64_t run_replay(t1s_t *s, int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  int32_t *passend, uint8_t *st)
{
  return run_passes(s, w, h, orient, sty, npasses, 0, 0, 0, 0, passend, st, 1);
}

/* decode: the segments' bytes one after the other in data, seglen[i] bytes and
   segpasses[i] passes each (in all npasses). sym gets the decisions (at most
   symcap), passend[k] how many there are at the end of pass k; st is the
   state, 2 (w + 2) (h + 2) bytes. Returns the number of decisions, or -1
   (more than symcap), -3 (bad arguments), -4 (the segments do not add up). */
int64_t pjaj2k_t1_decode(int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  const uint8_t *data, const int32_t *seglen, const int32_t *segpasses, int32_t nseg,
  uint8_t *sym, int64_t symcap, int32_t *passend, uint8_t *st)
{
  t1s_t s;
  s.raw = 0; s.bits = 0; s.bp = 0; s.nb = 0; s.sym = sym; s.ns = 0; s.cap = symcap; s.err = 0;
  s.rp = 0; s.rc = 0; s.rct = 0; s.q.d = data; s.q.n = 0; s.q.p = 0; s.q.A = 0; s.q.C = 0; s.q.CT = 0; s.q.fill = 0xFF;
  return run_decode(&s, w, h, orient, sty, npasses, data, seglen, segpasses, nseg, passend, st);
}

/* replay: the decisions' bits from bit bitpos of bits (nbits there in all),
   most significant first; *used gets how many it took. Returns the number of
   decisions, or -1 (more than symcap), -2 (the bits ran out), -3. */
int64_t pjaj2k_t1_replay(int32_t w, int32_t h, int32_t orient, int32_t sty, int32_t npasses,
  const uint8_t *bits, int64_t bitpos, int64_t nbits, int64_t *used,
  uint8_t *sym, int64_t symcap, int32_t *passend, uint8_t *st)
{
  t1s_t s; int64_t r;
  s.raw = 0; s.bits = bits; s.bp = bitpos; s.nb = nbits; s.sym = sym; s.ns = 0; s.cap = symcap;
  s.err = 0; s.rp = 0; s.rc = 0; s.rct = 0; s.q.d = 0; s.q.n = 0; s.q.p = 0; s.q.A = 0; s.q.C = 0; s.q.CT = 0;
  s.q.fill = 0xFF;
  r = run_replay(&s, w, h, orient, sty, npasses, passend, st);
  *used = s.bp - bitpos;
  return r;
}

/* ------------------------------------------------------------------ MQ encoder */
typedef struct { uint32_t A, C; int32_t CT; int64_t bp; uint8_t *buf; } mqe_t;
static inline void byteout(mqe_t *m)
{
  if (m->buf[m->bp] == 0xFF) { m->bp++; m->buf[m->bp] = (uint8_t)(m->C >> 20); m->C &= 0xFFFFF; m->CT = 7; }
  else if ((m->C & 0x8000000) == 0) { m->bp++; m->buf[m->bp] = (uint8_t)(m->C >> 19); m->C &= 0x7FFFF; m->CT = 8; }
  else {
    m->buf[m->bp]++;
    if (m->buf[m->bp] == 0xFF) { m->C &= 0x7FFFFFF; m->bp++; m->buf[m->bp] = (uint8_t)(m->C >> 20); m->C &= 0xFFFFF; m->CT = 7; }
    else { m->bp++; m->buf[m->bp] = (uint8_t)(m->C >> 19); m->C &= 0x7FFFF; m->CT = 8; }
  }
}
static inline void renorme(mqe_t *m) { do { m->A <<= 1; m->C <<= 1; if (--m->CT == 0) byteout(m); } while ((m->A & 0x8000) == 0); }
static inline void mqenc(mqe_t *m, uint8_t *x, int cx, int d)
{
  int i = x[cx]; uint32_t q = QE[i];
  if (d == x[NCTX + cx]) {
    m->A -= q;
    if ((m->A & 0x8000) == 0) { if (m->A < q) m->A = q; else m->C += q; x[cx] = NMPS[i]; renorme(m); }
    else m->C += q;
  } else {
    m->A -= q;
    if (m->A < q) m->C += q; else m->A = q;
    if (SWITCH[i]) x[NCTX + cx] ^= 1;
    x[cx] = NLPS[i]; renorme(m);
  }
}

/* the two ways to end a segment, on the encoder m (its buffer changed from
   m->bp on); the length of the segment then */
static int64_t end_flush(mqe_t *m)
{
  uint32_t t = m->C + m->A;
  m->C |= 0xFFFF; if (m->C >= t) m->C -= 0x8000;
  m->C <<= m->CT; byteout(m); m->C <<= m->CT; byteout(m);
  return m->buf[m->bp] == 0xFF ? m->bp - 1 : m->bp;
}
static int64_t end_erterm(mqe_t *m)
{
  int k = 11 - m->CT + 1;
  while (k > 0) { m->C <<= m->CT; m->CT = 0; byteout(m); k -= m->CT; }
  if (m->buf[m->bp] != 0xFF) byteout(m);
  return m->bp - 1;
}
/* the lengths the segment would have, ended now, without changing m */
static void end_lengths(const mqe_t *m, int64_t *nf, int64_t *ne)
{
  uint8_t t1[16], t2[16]; mqe_t a = *m, b = *m;
  t1[0] = t2[0] = m->buf[m->bp];
  a.buf = t1; a.bp = 0; b.buf = t2; b.bp = 0;
  *nf = m->bp + end_flush(&a);
  *ne = m->bp + end_erterm(&b);
}

/* sym[0..n) of one MQ segment from the contexts ctx (38 bytes, updated to
   the state after it), the contexts reset after each internal pass end
   pe[0..npe) (symbol indices, increasing, inside the segment) when reset.
   F and E (cap bytes each, cap at least 3n + 32) get the segment ended with
   FLUSH and with ERTERM; out[0] = FLUSH's length, out[1] = ERTERM's,
   out[2] = the bytes committed when the last decision is coded; at pass end
   pe[i], Kp[3i] the bytes committed, Kp[3i + 1] and Kp[3i + 2] the lengths
   FLUSH and ERTERM would give there. Returns 0, or -1 (cap too small, or a
   decision that is not an MQ one). */
int32_t pjaj2k_mq_encode(const uint8_t *sym, int64_t n, const int64_t *pe, int32_t npe, int32_t reset,
  uint8_t *ctx, uint8_t *F, uint8_t *E, int64_t cap, int64_t *out, int64_t *Kp)
{
  mqe_t m, m2; int64_t i; int j = 0;
  if (n < 0 || cap < 3 * n + 32) return -1;
  m.A = 0x8000; m.C = 0; m.CT = 12; m.bp = 0; m.buf = F; F[0] = 0;
  for (i = 0; ; ) {
    /* the decisions up to the next pass end */
    int64_t e = j < npe ? pe[j] : n;
    if (e < i || e > n) return -1;
    for (; i < e; i++) {
      int c = sym[i];
      if (c >= 2 * NCTX) return -1;
      mqenc(&m, ctx, c >> 1, c & 1);
    }
    if (j >= npe) break;
    Kp[3 * j] = m.bp - 1 < 0 ? 0 : m.bp - 1;
    end_lengths(&m, &Kp[3 * j + 1], &Kp[3 * j + 2]);
    if (reset) ctx_reset(ctx);
    j++;
  }
  out[2] = m.bp - 1 < 0 ? 0 : m.bp - 1;
  /* ERTERM on a copy */
  m2 = m; m2.buf = E;
  for (i = 0; i <= m.bp; i++) E[i] = F[i];
  out[0] = end_flush(&m);
  out[1] = end_erterm(&m2);
  /* the bytes start at index 1 */
  for (i = 0; i < out[0]; i++) F[i] = F[i + 1];
  for (i = 0; i < out[1]; i++) E[i] = E[i + 1];
  return 0;
}

/* whether X[0..L) (FF past it) decodes the first lim decisions of sym, from
   the contexts ctx0, reset after the pass ends pe[0..npe) when reset */
int32_t pjaj2k_mq_valid(const uint8_t *X, int64_t L, const uint8_t *ctx0, const uint8_t *sym, int64_t lim,
  const int64_t *pe, int32_t npe, int32_t reset)
{
  mqd_t q; uint8_t x[2 * NCTX]; int64_t i; int j = 0, k;
  for (k = 0; k < 2 * NCTX; k++) x[k] = ctx0[k];
  initdec(&q, X, L);
  for (i = 0; i < lim; i++) {
    int c = sym[i];
    while (j < npe && pe[j] == i) { if (reset) ctx_reset(x); j++; }
    if ((c >> 1) >= NCTX) return 0;
    if (mqdec(&q, x, c >> 1) != (c & 1)) return 0;
  }
  return 1;
}

/* how far into X[0..n) the decoder has read when it has decoded the first
   lim decisions: its byte pointer plus one, and one more when its bit
   counter has at most one bit left (the next decision reads that byte); a
   layer's end inside a segment for some encoders (Adobe's). -1 when they do
   not decode. */
int64_t pjaj2k_mq_reach(const uint8_t *X, int64_t n, const uint8_t *ctx0, const uint8_t *sym, int64_t lim,
  const int64_t *pe, int32_t npe, int32_t reset)
{
  mqd_t q; uint8_t x[2 * NCTX]; int64_t i; int j = 0, k;
  for (k = 0; k < 2 * NCTX; k++) x[k] = ctx0[k];
  initdec(&q, X, n);
  for (i = 0; i < lim; i++) {
    int c = sym[i];
    while (j < npe && pe[j] == i) { if (reset) ctx_reset(x); j++; }
    if ((c >> 1) >= NCTX) return -1;
    if (mqdec(&q, x, c >> 1) != (c & 1)) return -1;
  }
  return q.p + 1 + (q.CT <= 1);
}

/* the shortest prefix found going down from n, one byte at a time, while the
   prefix one byte shorter still decodes all nsym decisions, and at most
   window bytes down (each step decodes the segment again) */
int64_t pjaj2k_mq_minprefix(const uint8_t *X, int64_t n, const uint8_t *ctx0, const uint8_t *sym, int64_t nsym,
  const int64_t *pe, int32_t npe, int32_t reset, int32_t window)
{
  int64_t L = n;
  while (L > 0 && L > n - window && pjaj2k_mq_valid(X, L - 1, ctx0, sym, nsym, pe, npe, reset)) L--;
  return L;
}

/* a raw segment's bits as bytes: after a byte FF the next one has 7 bits (its
   top bit 0); the last byte's free bits padded with 0101.. (pad 0), zeros (1)
   or ones (2); a last byte FF dropped. -1 when cap is too small. */
int64_t pjaj2k_raw_pack(const uint8_t *sym, int64_t n, int32_t pad, uint8_t *out, int64_t cap)
{
  int64_t p = 0, i; int ct = 8; uint32_t c = 0; uint32_t prev = 0;
  /* cap < n / 7 + 4, without a 64-bit division (a libgcc call on 32-bit
     x86, which the C here does not link): floor(n / 7) >= cap - 3 */
  if (n < 0 || cap < 4 || n >= 7 * (cap - 3)) return -1;
  for (i = 0; i < n; i++) {
    if (ct == 0) { out[p++] = (uint8_t)c; prev = c; ct = prev == 0xFF ? 7 : 8; c = 0; }
    ct--; c |= (uint32_t)(sym[i] & 1) << ct;
  }
  if (ct < (prev == 0xFF ? 7 : 8)) {
    int bv = 0;
    while (ct > 0) { ct--; if (pad == 0) { c |= (uint32_t)bv << ct; bv ^= 1; } else if (pad == 2) c |= 1u << ct; }
    out[p++] = (uint8_t)c;
  }
  while (p > 0 && out[p - 1] == 0xFF) p--;
  return p;
}

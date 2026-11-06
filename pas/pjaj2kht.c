/* HTJ2K (ITU-T T.814 | ISO/IEC 15444-15) code-blocks taken apart and made
   again byte for byte, for stream version 8's mode 3 (doc/CODEC.md, "JPEG
   2000, stage F"). Called through pjaj2kcs.pas, which owns every buffer:
   this file takes no memory and calls no library, as pjav7c.c, and every
   buffer's size is checked.

   pjaj2kh_decode reads a code-block's HT cleanup segment (MagSgn, MEL and
   VLC, with the UVLC of the quads' exponents) and its refinement segment
   (SigProp forward from its start, MagRef backward from its end) into one
   signed value a sample:
     1 pass (the cleanup alone)   mu, the cleanup's magnitude
     2 or 3 passes                2 mu + r for a sample significant in the
                                  cleanup (r its MagRef bit, 0 with 2
                                  passes), 1 for one SigProp made
                                  significant, 0 for the others
   with the sample's sign. pjaj2kh_cup and pjaj2kh_ref write the segments
   again from those values, the way an encoder ends them (its rule):

   cleanup rules (the MEL and VLC segments' ends; MagSgn padded with 1s,
   a last FF dropped), with OpenJPH's choice of the VLC codeword where a
   quad's exponents leave a choice (HT_EMB_OJPH) or the one with the
   fewest bits (HT_EMB_MIN, + 8):
     0  OpenJPH and Grok: a MEL run under way ended with a 1, and the last
        MEL and VLC bytes fused into one when their bits agree
     1  OpenHTJ2K: the same, but no MEL byte when the MEL has no bits left
     2  Kakadu 8 (the research's rule 16): a terminal MEL codeword when a
        run is under way or the last codeword was a 1; the last MEL byte
        fused with the last VLC byte when the MEL's own bits agree with
        the VLC's and the MEL still decodes every event
     3  the same, rule 17 (the fused byte may be FF where they share no bit)
     4  the shortest prefix of the MEL bytes (in the last 4) that decodes
        every event, fused with the last VLC byte when that is shorter
   refinement rules (SigProp's bytes, then MagRef's in memory order):
     0..3  (spp << 1) | mrp: each its bytes as written (0) or without its
           trailing zero bytes (1)
     4     the last SigProp byte and the first MagRef byte ORed into one

   A code-block that does not come back with one of them is kept as its
   bytes by the caller. Integer arithmetic only. */
#include <stdint.h>
#include "pjaj2kht_tab.h"

#define HT_MAXS 4096            /* samples a code-block: w, h <= 1024, w h <= 4096 */
#define HT_MAXQ 2304            /* quads: ceil(w / 2) ceil(h / 2) */
#define HT_MSCAP 20480          /* MagSgn bytes: 4096 samples x 29 bits, one in 8 stuffed */
#define HT_MVCAP 8192           /* MEL or VLC bytes */
#define HT_EVCAP 8192           /* MEL events */
#define HT_RCAP 4096            /* SigProp or MagRef bytes */
#define HT_UMAX 29              /* U_q at most: a value fits 31 bits */

#define HT_EMB_MIN 8

typedef struct {
  uint8_t *b; int32_t n, cap;   /* the bytes so far */
  int32_t rem, tmp, run, k, thr, lastcw;
  int8_t *ev; int32_t nev;      /* the events, for the check of the shortest-prefix rules */
} htmel_t;

typedef struct {
  uint8_t *b; int32_t n, cap;   /* in reverse: b[0] is the segment's last byte */
  int32_t used, tmp, gt;
} htvlc_t;

typedef struct {
  int32_t ready;
  uint16_t vdec[2][1024];       /* (c_q << 7 | 7 bits) -> e_k << 12 | e_1 << 8 | rho << 4 | u_off << 3 | len */
  uint16_t eidx[2][8][16][2];   /* the encoder's: each (c_q, rho)'s rows of the table */
  /* the code-block */
  uint32_t mu[HT_MAXS];
  uint8_t sg[HT_MAXS];
  uint8_t E[HT_MAXS + 8];       /* scratch rows */
  uint8_t qrho[HT_MAXQ];
  uint8_t flg[HT_MAXS];         /* refinement: 1 significant in the cleanup, 2 SigProp new, 4 visited */
  int32_t newl[16];
  uint8_t ms[HT_MSCAP];
  uint8_t mel[HT_MVCAP], mel2[HT_MVCAP];
  uint8_t vlc[HT_MVCAP];
  uint8_t cand[2 * HT_MVCAP + 16], best[2 * HT_MVCAP + 16];
  int8_t ev[HT_EVCAP];
  uint8_t spp[HT_RCAP], mrp[HT_RCAP];
} htws_t;

static const int mel_exp[13] = { 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5 };

static int popc4(int x) { return (x & 1) + ((x >> 1) & 1) + ((x >> 2) & 1) + ((x >> 3) & 1); }
static int bitlen32(uint32_t x) { int n = 0; while (x) { n++; x >>= 1; } return n; }
static void bcopy8(uint8_t *d, const uint8_t *s, int32_t n) { int32_t i; for (i = 0; i < n; i++) d[i] = s[i]; }

static htws_t *W(void *mem) { return (htws_t *)(((uintptr_t)mem + 63) & ~(uintptr_t)63); }

int64_t pjaj2kh_wsize(void) { return (int64_t)sizeof(htws_t) + 64; }

static void init_tables(htws_t *w)
{
  int t, i, j, n;
  for (t = 0; t < 2; t++) {
    const uint8_t (*T)[7] = t ? HT_T1 : HT_T0;
    n = t ? (int)(sizeof(HT_T1) / 7) : (int)(sizeof(HT_T0) / 7);
    for (i = 0; i < 1024; i++) w->vdec[t][i] = 0;
    for (i = 0; i < 8; i++) for (j = 0; j < 16; j++) { w->eidx[t][i][j][0] = 0; w->eidx[t][i][j][1] = 0; }
    for (i = 0; i < 1024; i++) {
      int cw = i & 0x7F, cq = i >> 7;
      for (j = 0; j < n; j++)
        if (T[j][0] == cq && T[j][5] == (cw & ((1 << T[j][6]) - 1)))
          w->vdec[t][i] = (uint16_t)((T[j][3] << 12) | (T[j][4] << 8) | (T[j][1] << 4) | (T[j][2] << 3) | T[j][6]);
    }
    for (j = 0; j < n; j++) {
      uint16_t *e = w->eidx[t][T[j][0] & 7][T[j][1] & 15];
      if (e[1] == 0) e[0] = (uint16_t)j;
      e[1] = (uint16_t)(j + 1);
    }
  }
  w->ready = 1;
}

/* ------------------------------------------------------------------ readers */
/* MEL: forward, the most significant bit first; after an FF the next byte
   has 7 bits; the last byte of the MEL and VLC segments has its low
   nibble set (it holds the length); FF past the end */
typedef struct { const uint8_t *d; int32_t pos, size, cur, nb, unst; int32_t k, zeros, one; } melr_t;
static int melr_bit(melr_t *r)
{
  if (r->nb == 0) {
    int32_t v;
    if (r->size > 0) { v = r->d[r->pos++]; if (r->size == 1) v |= 0xF; r->size--; } else v = 0xFF;
    r->nb = r->unst ? 7 : 8; r->cur = v; r->unst = v == 0xFF;
  }
  r->nb--;
  return (r->cur >> r->nb) & 1;
}
static int melr_event(melr_t *r)
{
  for (;;) {
    int e;
    if (r->zeros > 0) { r->zeros--; return 0; }
    if (r->one) { r->one = 0; return 1; }
    e = mel_exp[r->k];
    if (melr_bit(r)) { r->zeros = 1 << e; r->k = r->k < 12 ? r->k + 1 : 12; }
    else {
      int v = 0, i;
      for (i = 0; i < e; i++) v = (v << 1) | melr_bit(r);
      r->zeros = v; r->one = 1; r->k = r->k > 0 ? r->k - 1 : 0;
    }
  }
}

/* a bit buffer, the least significant bit first */
typedef struct { uint64_t acc; int32_t n; const uint8_t *d; int32_t pos, end, unst, kind; } bitr_t;
/* kind 0: VLC (backward, after a byte above 8F a byte whose 7 low bits are
   all 1 has 7 bits; zeros past the start); 1: MagSgn (forward, 7 bits
   after an FF; FF past the end); 2: SigProp (forward, as MagSgn; zeros
   past the end); 3: MagRef (backward as VLC, the first byte checked too) */
static void bitr_fill(bitr_t *r)
{
  while (r->n <= 56) {
    int32_t v, nb;
    if (r->kind == 0 || r->kind == 3) {
      if (r->pos >= r->end) { v = r->d[r->pos]; r->pos--; } else v = 0;
      nb = (r->unst && (v & 0x7F) == 0x7F) ? 7 : 8;
      r->unst = v > 0x8F;
    } else {
      if (r->pos < r->end) v = r->d[r->pos++]; else v = r->kind == 1 ? 0xFF : 0;
      nb = r->unst ? 7 : 8;
      r->unst = v == 0xFF;
    }
    r->acc |= (uint64_t)(v & ((1 << nb) - 1)) << r->n;
    r->n += nb;
  }
}
static uint32_t bitr_peek(bitr_t *r, int n)
{
  if (r->n < n) bitr_fill(r);
  return (uint32_t)(r->acc & (((uint64_t)1 << n) - 1));
}
static uint32_t bitr_get(bitr_t *r, int n)
{
  uint32_t v;
  if (n == 0) return 0;
  if (r->n < n) bitr_fill(r);
  v = (uint32_t)(r->acc & (((uint64_t)1 << n) - 1));
  r->acc >>= n; r->n -= n;
  return v;
}

/* a UVLC prefix: 1, 2, 3 (a suffix of 1 bit) or 5 (5 bits, and 4 more
   past 27) */
static int uv_prefix(bitr_t *r)
{
  if (bitr_get(r, 1)) return 1;
  if (bitr_get(r, 1)) return 2;
  if (bitr_get(r, 1)) return 3;
  return 5;
}
static int uv_suffix(bitr_t *r, int pfx)
{
  int s;
  if (pfx < 3) return pfx;
  if (pfx == 3) return 3 + (int)bitr_get(r, 1);
  s = (int)bitr_get(r, 5);
  if (s < 28) return 5 + s;
  return 33 + 4 * (int)bitr_get(r, 4) + (s - 28);
}

/* ------------------------------------------------------------------ decoding */
static int dec_cup(htws_t *w, int32_t W_, int32_t H, const uint8_t *d, int32_t L1)
{
  int32_t scup, nqx, nqy, qy, qx0, j, n;
  melr_t mel; bitr_t vlc, ms;
  uint8_t *Eab = w->E;                       /* the E of the row above's lower samples, by column + 1 */
  uint8_t sab[1032], scur[1032], ecur[1032]; /* significance and E of this row's lower samples */
  if (L1 < 2) return -1;
  scup = ((int32_t)d[L1 - 1] << 4) + (d[L1 - 2] & 0xF);
  if (scup < 2 || scup > L1 || scup > 4079) return -2;
  mel.d = d; mel.pos = L1 - scup; mel.size = scup - 1; mel.cur = 0; mel.nb = 0; mel.unst = 0;
  mel.k = 0; mel.zeros = 0; mel.one = 0;
  /* VLC: the high nibble of the byte before the last, then backward */
  vlc.d = d; vlc.pos = L1 - 3; vlc.end = L1 - scup; vlc.kind = 0;
  {
    int32_t v = d[L1 - 2] >> 4;
    vlc.n = (v & 7) == 7 ? 3 : 4;
    vlc.acc = (uint64_t)(v & ((1 << vlc.n) - 1));
    vlc.unst = (d[L1 - 2] | 0xF) > 0x8F;
  }
  ms.d = d; ms.pos = 0; ms.end = L1 - scup; ms.kind = 1; ms.acc = 0; ms.n = 0; ms.unst = 0;
  nqx = (W_ + 1) / 2; nqy = (H + 1) / 2;
  if ((int64_t)nqx * nqy > HT_MAXQ || W_ > 1024) return -3;
  for (n = 0; n < W_ + 4; n++) { Eab[n] = 0; sab[n] = 0; }
  for (qy = 0; qy < nqy; qy++) {
    int first = qy == 0, leftrho = 0, y = 2 * qy;
    for (n = 0; n < W_ + 4; n++) { scur[n] = 0; ecur[n] = 0; }
    for (qx0 = 0; qx0 < nqx; qx0 += 2) {
      int rho[2] = { 0, 0 }, uoff[2] = { 0, 0 }, ek[2] = { 0, 0 }, e1[2] = { 0, 0 }, u[2] = { 0, 0 }, U[2];
      int have1 = qx0 + 1 < nqx;
      for (j = 0; j < 2; j++) {
        int qx = qx0 + j, x = 2 * qx, cq, ent = 0;
        if (j == 1 && !have1) break;
        if (first) cq = (leftrho >> 1) | (leftrho & 1);
        else cq = (sab[x] | sab[x + 1]) | (((leftrho >> 2) | (leftrho >> 3)) & 1) << 1 | (sab[x + 2] | sab[x + 3]) << 2;
        if (cq == 0 && !melr_event(&mel)) ent = 0;
        else {
          ent = w->vdec[first ? 0 : 1][(cq << 7) | (int)bitr_peek(&vlc, 7)];
          if (ent == 0) return -4;
          bitr_get(&vlc, ent & 7);
          if (((ent >> 4) & 15) == 0 && cq == 0) return -4;
        }
        rho[j] = (ent >> 4) & 15; uoff[j] = (ent >> 3) & 1; ek[j] = (ent >> 12) & 15; e1[j] = (ent >> 8) & 15;
        /* samples outside the code-block are never significant */
        if (x + 1 >= W_ && (rho[j] & 12)) return -5;
        if (y + 1 >= H && (rho[j] & 10)) return -5;
        leftrho = rho[j];
        w->qrho[qy * nqx + qx] = (uint8_t)rho[j];
      }
      /* the exponents' offsets (UVLC) */
      if (first && uoff[0] && uoff[1]) {
        if (melr_event(&mel)) {
          int p0 = uv_prefix(&vlc), p1 = uv_prefix(&vlc);
          u[0] = 2 + uv_suffix(&vlc, p0); u[1] = 2 + uv_suffix(&vlc, p1);
        } else {
          int p0 = uv_prefix(&vlc);
          if (p0 > 2) { u[1] = 1 + (int)bitr_get(&vlc, 1); u[0] = uv_suffix(&vlc, p0); }
          else { int p1 = uv_prefix(&vlc); u[0] = p0; u[1] = uv_suffix(&vlc, p1); }
        }
      } else {
        int p0 = uoff[0] ? uv_prefix(&vlc) : 0, p1 = uoff[1] ? uv_prefix(&vlc) : 0;
        if (uoff[0]) u[0] = uv_suffix(&vlc, p0);
        if (uoff[1]) u[1] = uv_suffix(&vlc, p1);
      }
      /* MagSgn */
      for (j = 0; j < 2; j++) {
        int qx = qx0 + j, x = 2 * qx, kappa = 1;
        if (j == 1 && !have1) break;
        if (!first && popc4(rho[j]) >= 2) {
          int me = Eab[x], t;
          if (Eab[x + 1] > me) me = Eab[x + 1];
          if (Eab[x + 2] > me) me = Eab[x + 2];
          if (Eab[x + 3] > me) me = Eab[x + 3];
          t = me - 1; kappa = t > 1 ? t : 1;
        }
        U[j] = u[j] + kappa;
        if (U[j] > HT_UMAX) return -6;
        for (n = 0; n < 4; n++) {
          int sx = x + (n >> 1), sy = y + (n & 1), mn;
          uint32_t v;
          if (!((rho[j] >> n) & 1)) {
            if (sx < W_ && sy < H) { w->mu[sy * W_ + sx] = 0; w->sg[sy * W_ + sx] = 0; }
            continue;
          }
          mn = U[j] - ((ek[j] >> n) & 1);
          v = mn > 0 ? bitr_get(&ms, mn) : 0;
          v |= (uint32_t)((e1[j] >> n) & 1) << mn;
          w->mu[sy * W_ + sx] = (v >> 1) + 1;
          w->sg[sy * W_ + sx] = (uint8_t)(v & 1);
        }
        /* this row's lower samples, for the next row's contexts and kappa */
        if (y + 1 < H) {
          int i0 = (y + 1) * W_ + x;
          if (rho[j] & 2) { scur[x + 1] = 1; ecur[x + 1] = (uint8_t)bitlen32(2 * w->mu[i0] - 1); }
          if ((rho[j] & 8) && x + 1 < W_) { scur[x + 2] = 1; ecur[x + 2] = (uint8_t)bitlen32(2 * w->mu[i0 + 1] - 1); }
        }
      }
    }
    for (n = 0; n < W_ + 4; n++) { sab[n] = scur[n]; Eab[n] = ecur[n]; }
  }
  return 0;
}

/* SigProp and MagRef: the samples insignificant after the cleanup with a
   significant neighbour (in the stripe-causal mode none below the stripe)
   in stripes of 4 rows and groups of 4 columns, each group's signs after
   its significance; then MagRef's bit of each sample significant in the
   cleanup, stripe by stripe, column by column */
static int sigat(const htws_t *w, int W_, int H, int x, int y, int ys, int causal)
{
  int i;
  if (x < 0 || y < 0 || x >= W_ || y >= H) return 0;
  i = y * W_ + x;
  if (w->flg[i] & 1) return !(causal && y >= ys + 4);
  return (w->flg[i] & 6) == 6;
}
static int nbsig(const htws_t *w, int W_, int H, int x, int y, int ys, int causal)
{
  return sigat(w, W_, H, x - 1, y - 1, ys, causal) | sigat(w, W_, H, x, y - 1, ys, causal) |
    sigat(w, W_, H, x + 1, y - 1, ys, causal) | sigat(w, W_, H, x - 1, y, ys, causal) |
    sigat(w, W_, H, x + 1, y, ys, causal) | sigat(w, W_, H, x - 1, y + 1, ys, causal) |
    sigat(w, W_, H, x, y + 1, ys, causal) | sigat(w, W_, H, x + 1, y + 1, ys, causal);
}

/* the code-block's values from its segments: 0, or < 0 when they are not
   an HT code-block's (the caller keeps its bytes) */
int32_t pjaj2kh_decode(void *mem, int32_t w_, int32_t h, int32_t causal, int32_t np, const uint8_t *data, int32_t L1,
  int32_t L2, int32_t *q)
{
  htws_t *w = W(mem); int32_t i, n, r, ys, xg, x, y;
  if (!w->ready) init_tables(w);
  if (w_ < 1 || h < 1 || w_ > 1024 || h > 1024 || (int64_t)w_ * h > HT_MAXS || np < 1 || np > 3 || L1 < 2 || L2 < 0)
    return -1;
  n = w_ * h;
  r = dec_cup(w, w_, h, data, L1);
  if (r < 0) return r;
  if (np == 1) {
    for (i = 0; i < n; i++) q[i] = w->sg[i] ? -(int32_t)w->mu[i] : (int32_t)w->mu[i];
    return 0;
  }
  {
    bitr_t sp, mr;
    sp.d = data + L1; sp.pos = 0; sp.end = L2; sp.kind = 2; sp.acc = 0; sp.n = 0; sp.unst = 0;
    mr.d = data + L1; mr.pos = L2 - 1; mr.end = 0; mr.kind = 3; mr.acc = 0; mr.n = 0; mr.unst = 1;
    for (i = 0; i < n; i++) w->flg[i] = w->mu[i] ? 1 : 0;
    for (ys = 0; ys < h; ys += 4)
      for (xg = 0; xg < w_; xg += 4) {
        int nn = 0, k;
        for (x = xg; x < xg + 4 && x < w_; x++)
          for (y = ys; y < ys + 4 && y < h; y++) {
            int b;
            i = y * w_ + x;
            if (w->flg[i] & 1) continue;
            if (!nbsig(w, w_, h, x, y, ys, causal)) { w->flg[i] |= 4; continue; }
            b = (int)bitr_get(&sp, 1);
            w->flg[i] |= (uint8_t)(4 | (b << 1));
            if (b) w->newl[nn++] = i;
          }
        for (k = 0; k < nn; k++) w->sg[w->newl[k]] = (uint8_t)bitr_get(&sp, 1);
      }
    for (i = 0; i < n; i++) {
      int32_t v;
      if (w->flg[i] & 1) v = (int32_t)(2 * w->mu[i]);
      else v = (w->flg[i] & 2) ? 1 : 0;
      q[i] = v;
    }
    if (np > 2)
      for (ys = 0; ys < h; ys += 4)
        for (x = 0; x < w_; x++)
          for (y = ys; y < ys + 4 && y < h; y++) {
            i = y * w_ + x;
            if (w->flg[i] & 1) q[i] |= (int32_t)bitr_get(&mr, 1);
          }
    for (i = 0; i < n; i++) if (w->sg[i] && q[i]) q[i] = -q[i];
  }
  return 0;
}

/* ------------------------------------------------------------------ the cleanup's writers (OpenJPH's conventions) */
static int mel_bit(htmel_t *m, int v)
{
  m->tmp = (m->tmp << 1) + v;
  if (--m->rem == 0) {
    if (m->n >= m->cap) return -1;
    m->b[m->n++] = (uint8_t)m->tmp;
    m->rem = m->tmp == 0xFF ? 7 : 8; m->tmp = 0;
  }
  return 0;
}
static int mel_enc(htmel_t *m, int bit)
{
  if (!bit) {
    if (++m->run >= m->thr) {
      m->lastcw = 1;
      if (mel_bit(m, 1)) return -1;
      m->run = 0; m->k = m->k < 12 ? m->k + 1 : 12; m->thr = 1 << mel_exp[m->k];
    }
  } else {
    int t = mel_exp[m->k];
    m->lastcw = 0;
    if (mel_bit(m, 0)) return -1;
    while (t > 0) { t--; if (mel_bit(m, (m->run >> t) & 1)) return -1; }
    m->run = 0; m->k = m->k > 0 ? m->k - 1 : 0; m->thr = 1 << mel_exp[m->k];
  }
  return 0;
}
static int mel_event(htmel_t *m, int bit)
{
  if (m->ev) { if (m->nev >= HT_EVCAP) return -1; m->ev[m->nev++] = (int8_t)bit; }
  return mel_enc(m, bit);
}
static int vlc_enc(htvlc_t *v, uint32_t cwd, int len)
{
  while (len > 0) {
    int avail = 8 - v->gt - v->used, t = avail < len ? avail : len;
    v->tmp |= (int32_t)((cwd & ((1u << t) - 1)) << v->used); v->used += t; avail -= t; len -= t; cwd >>= t;
    if (avail == 0) {
      if (v->gt && v->tmp != 0x7F) { v->gt = 0; continue; }
      if (v->n >= v->cap) return -1;
      v->b[v->n++] = (uint8_t)v->tmp; v->gt = v->tmp > 0x8F; v->tmp = 0; v->used = 0;
    }
  }
  return 0;
}
typedef struct { uint8_t *b; int32_t n, cap, maxb, used; uint64_t tmp; } htms_t;
static int ms_enc(htms_t *m, uint64_t cwd, int len)
{
  while (len > 0) {
    int t = m->maxb - m->used < len ? m->maxb - m->used : len;
    m->tmp |= (cwd & (((uint64_t)1 << t) - 1)) << m->used; m->used += t; cwd >>= t; len -= t;
    if (m->used >= m->maxb) {
      if (m->n >= m->cap) return -1;
      m->b[m->n++] = (uint8_t)m->tmp; m->maxb = (m->tmp & 0xFF) == 0xFF ? 7 : 8; m->tmp = 0; m->used = 0;
    }
  }
  return 0;
}
/* padded with 1s; a last byte FF is not written */
static void ms_term(htms_t *m)
{
  if (m->used) {
    int t = m->maxb - m->used;
    m->tmp |= (uint64_t)(0xFF & ((1u << t) - 1)) << m->used;
    if ((m->tmp & 0xFF) != 0xFF) m->b[m->n++] = (uint8_t)m->tmp;
  } else if (m->maxb == 7 && m->n > 0) m->n--;
}

/* the UVLC codes: prefix, its length, suffix, its length, extension, its length */
static void uv_code(int u, int *c)
{
  int i;
  for (i = 0; i < 6; i++) c[i] = 0;
  if (u == 1) { c[0] = 1; c[1] = 1; }
  else if (u == 2) { c[0] = 2; c[1] = 2; }
  else if (u == 3 || u == 4) { c[0] = 4; c[1] = 3; c[2] = u - 3; c[3] = 1; }
  else if (u >= 5 && u < 33) { c[0] = 0; c[1] = 3; c[2] = u - 5; c[3] = 5; }
  else if (u >= 33) { c[0] = 0; c[1] = 3; c[2] = 28 + (u - 33) % 4; c[3] = 5; c[4] = (u - 33) / 4; c[5] = 4; }
}
static int uv_pre(htvlc_t *v, int u) { int c[6]; uv_code(u, c); return c[1] ? vlc_enc(v, (uint32_t)c[0], c[1]) : 0; }
static int uv_suf(htvlc_t *v, int u)
{
  int c[6]; uv_code(u, c);
  if (c[3] && vlc_enc(v, (uint32_t)c[2], c[3])) return -1;
  if (c[5] && vlc_enc(v, (uint32_t)c[4], c[5])) return -1;
  return 0;
}

/* the MEL and VLC segments as a decoder reads them (MEL bytes, then the
   VLC's in memory order), their length in the last two bytes */
static int32_t build_mv(uint8_t *c, int32_t cap, const uint8_t *M, int32_t nm, const uint8_t *V, int32_t nv)
{
  int32_t i, sc = nm + nv;
  if (sc > cap) return -1;
  for (i = 0; i < nm; i++) c[i] = M[i];
  for (i = 0; i < nv; i++) c[nm + i] = V[nv - 1 - i];
  if (sc >= 2) { c[sc - 1] = (uint8_t)(sc >> 4); c[sc - 2] = (uint8_t)((c[sc - 2] & 0xF0) | (sc & 0xF)); }
  return sc;
}

/* whether a MEL decoder reading R (MEL and VLC, as build_mv) gives the events ev */
static int mel_check(const uint8_t *R, int32_t scup, const int8_t *ev, int32_t nev)
{
  melr_t r; int32_t i;
  r.d = R; r.pos = 0; r.size = scup - 1; r.cur = 0; r.nb = 0; r.unst = 0; r.k = 0; r.zeros = 0; r.one = 0;
  for (i = 0; i < nev; i++) if (melr_event(&r) != ev[i]) return 0;
  return 1;
}

static void mel_copy(htmel_t *d, const htmel_t *s, uint8_t *buf)
{
  *d = *s; d->b = buf; bcopy8(buf, s->b, s->n);
}

/* rule 0 and 1 (OpenJPH, OpenHTJ2K): into M (MEL bytes), V (VLC, reversed) */
static int term_ojph(htmel_t *m, htvlc_t *v, int fuse2)
{
  int mel_mask, vlc_mask, f, can;
  if (m->run > 0 && mel_bit(m, 1)) return -1;
  m->tmp = m->tmp << m->rem;
  mel_mask = (0xFF << m->rem) & 0xFF; vlc_mask = 0xFF >> (8 - v->used);
  if ((mel_mask | vlc_mask) == 0) return 0;
  if (m->n + 1 >= m->cap || v->n + 1 >= v->cap) return -1;
  if (fuse2 && mel_mask == 0) { v->b[v->n++] = (uint8_t)v->tmp; return 0; }
  f = m->tmp | v->tmp;
  can = ((((f ^ m->tmp) & mel_mask) | ((f ^ v->tmp) & vlc_mask)) == 0) && f != 0xFF && v->n > 1;
  if (can) m->b[m->n++] = (uint8_t)f;
  else { m->b[m->n++] = (uint8_t)m->tmp; v->b[v->n++] = (uint8_t)v->tmp; }
  return 0;
}

/* rules 2 and 3 (Kakadu): into out, the MEL and VLC segments; their length */
static int32_t term_kdu(htws_t *w, htmel_t *m, htvlc_t *v, int var, uint8_t *out, int32_t cap)
{
  htmel_t mm; int e, tb, doterm, rem, cp, used, tin, termmask, usedmask, realmask, vpart, vmask;
  int32_t nM, nV, sc;
  uint8_t *V = v->b;
  mel_copy(&mm, m, w->mel2);
  e = mel_exp[mm.k]; tb = 1 + e;
  doterm = mm.run > 0 || mm.lastcw == 1;
  if (doterm) { if (mel_enc(&mm, 1)) return -1; } else tb = 0;
  nM = mm.n;
  {
    int lastff = nM > 0 && mm.b[nM - 1] == 0xFF;
    if (mm.rem < 8 && mm.rem != (lastff ? 7 : 8)) {
      cp = lastff ? 7 : 8; rem = mm.rem;
      if (nM >= mm.cap) return -1;
      mm.b[nM++] = (uint8_t)(mm.tmp << mm.rem);
    } else { rem = 0; cp = (nM >= 2 && mm.b[nM - 2] == 0xFF) ? 7 : 8; }
  }
  used = cp - rem; tin = tb < used ? tb : used;
  termmask = ((1 << tin) - 1) << rem; usedmask = ((1 << used) - 1) << rem; realmask = usedmask & ~termmask;
  nV = v->n; vpart = v->used > 0; vmask = vpart ? (1 << v->used) - 1 : 0xFF;
  if (vpart) { if (nV >= v->cap) return -1; V[nV++] = (uint8_t)v->tmp; }
  if (nM > 0 && nV > 1) {
    int F = mm.b[nM - 1], G = V[nV - 1];
    int c10 = ((F ^ G) & vmask & realmask) == 0, cor = (F & ~G & vmask) == 0;
    if (cor && c10) {
      int f = (F & ~vmask) | (G & vmask);
      if (var == 16 ? 1 : ((usedmask & vmask) == 0 || !vpart)) {
        uint8_t keep = mm.b[nM - 1];
        mm.b[nM - 1] = (uint8_t)f;
        sc = build_mv(out, cap, mm.b, nM, V, nV - 1);
        if (sc >= 2 && mel_check(out, sc, m->ev, m->nev)) return sc;
        mm.b[nM - 1] = keep;
      }
    }
  }
  return build_mv(out, cap, mm.b, nM, V, nV);
}

/* rule 4: the shortest prefix (of the last 4 MEL bytes or so) that decodes */
static int32_t term_min(htws_t *w, htmel_t *m, htvlc_t *v, uint8_t *out, int32_t cap)
{
  htmel_t mm; int32_t nM, nV, k, bestn = -1, o, sc, i;
  int vused = v->used, vmask = 0xFF >> (8 - vused);
  uint8_t *V = v->b;
  mel_copy(&mm, m, w->mel2);
  if (mm.run > 0 && mel_enc(&mm, 1)) return -1;
  nM = mm.n;
  if (mm.rem < 8) { if (nM >= mm.cap) return -1; mm.b[nM++] = (uint8_t)(mm.tmp << mm.rem); }
  nV = v->n;
  for (k = nM - 4 > 0 ? nM - 4 : 0; k <= nM && bestn < 0; k++)
    for (o = 0; o < 2; o++) {
      int32_t nv2 = nV, nm2 = k;
      uint8_t keep = 0;
      if (o == 1) {
        int f;
        if (k == 0 || vused == 0 || nV <= 1) continue;
        f = (mm.b[k - 1] & ~vmask) | v->tmp;
        if (f == 0xFF) continue;
        keep = mm.b[k - 1]; mm.b[k - 1] = (uint8_t)f;
      } else if (vused > 0 || nV == 1) { if (nv2 >= v->cap) return -1; V[nv2++] = (uint8_t)v->tmp; }
      sc = build_mv(w->cand, (int32_t)sizeof(w->cand), mm.b, nm2, V, nv2);
      if (o == 1) mm.b[k - 1] = keep;
      if (sc < 2) continue;
      if (mel_check(w->cand, sc, m->ev, m->nev) && (bestn < 0 || sc < bestn)) {
        bestn = sc;
        for (i = 0; i < sc; i++) w->best[i] = w->cand[i];
      }
    }
  if (bestn < 0 || bestn > cap) return -1;
  for (i = 0; i < bestn; i++) out[i] = w->best[i];
  return bestn;
}

/* the VLC row for a quad, by the rule's choice of exponents */
static int pick(const htws_t *w, int first, int cq, int rho, int uoff, int eps, int minc)
{
  const uint8_t (*T)[7] = first ? HT_T0 : HT_T1;
  int j, best = -1, be = -1, bc = 1 << 30;
  int j0 = w->eidx[first ? 0 : 1][cq][rho][0], j1 = w->eidx[first ? 0 : 1][cq][rho][1];
  for (j = j0; j < j1; j++) {
    if (T[j][2] != uoff) continue;
    if (!uoff) return j;
    if ((eps & T[j][3]) != T[j][4]) continue;
    if (minc) { int c = T[j][6] - popc4(T[j][3]); if (c < bc) { bc = c; best = j; } }
    else { int oc = popc4(T[j][3]); if (oc >= be) { best = j; be = oc; } }
  }
  return best;
}

/* the cleanup segment from the values q (np passes: their units), by rule;
   its length in out, or < 0 */
int32_t pjaj2kh_cup(void *mem, int32_t W_, int32_t H, int32_t np, const int32_t *q, int32_t rule, uint8_t *out,
  int32_t cap)
{
  htws_t *w = W(mem); htmel_t mel; htvlc_t vlc; htms_t ms;
  int32_t nqx, nqy, qy, qx0, j, n, sh = np > 1 ? 1 : 0, term = rule & 7, minc = (rule & HT_EMB_MIN) != 0, i, nmv;
  uint8_t *Eab = w->E;
  uint8_t sab[1032], scur[1032], ecur[1032];
  if (!w->ready) init_tables(w);
  if (W_ < 1 || H < 1 || W_ > 1024 || H > 1024 || (int64_t)W_ * H > HT_MAXS || np < 1 || np > 3 || term > 4 || cap < 2)
    return -1;
  nqx = (W_ + 1) / 2; nqy = (H + 1) / 2;
  mel.b = w->mel; mel.n = 0; mel.cap = HT_MVCAP; mel.rem = 8; mel.tmp = 0; mel.run = 0; mel.k = 0; mel.thr = 1;
  mel.lastcw = -1; mel.ev = w->ev; mel.nev = 0;
  vlc.b = w->vlc; vlc.n = 1; vlc.cap = HT_MVCAP; vlc.b[0] = 0xFF; vlc.used = 4; vlc.tmp = 0xF; vlc.gt = 1;
  ms.b = w->ms; ms.n = 0; ms.cap = HT_MSCAP; ms.maxb = 8; ms.used = 0; ms.tmp = 0;
  for (n = 0; n < W_ + 4; n++) { Eab[n] = 0; sab[n] = 0; }
  for (qy = 0; qy < nqy; qy++) {
    int first = qy == 0, leftrho = 0, y = 2 * qy;
    for (n = 0; n < W_ + 4; n++) { scur[n] = 0; ecur[n] = 0; }
    for (qx0 = 0; qx0 < nqx; qx0 += 2) {
      int uq[2] = { 0, 0 }, have1 = qx0 + 1 < nqx;
      for (j = 0; j < 2; j++) {
        int qx = qx0 + j, x = 2 * qx, rho = 0, emax = 0, cq, kappa = 1, Uq, u, uoff, eps = 0, e = -1, ek = 0, e1 = 0;
        uint32_t v[4] = { 0, 0, 0, 0 }; int E[4] = { 0, 0, 0, 0 };
        if (j == 1 && !have1) break;
        for (n = 0; n < 4; n++) {
          int sx = x + (n >> 1), sy = y + (n & 1);
          uint32_t a, m;
          if (sx >= W_ || sy >= H) continue;
          a = q[sy * W_ + sx] < 0 ? 0u - (uint32_t)q[sy * W_ + sx] : (uint32_t)q[sy * W_ + sx];
          m = a >> sh;
          if (m) {
            if (m > (1u << (HT_UMAX - 1))) return -2;
            rho |= 1 << n; E[n] = bitlen32(2 * m - 1); v[n] = 2 * (m - 1) + (q[sy * W_ + sx] < 0);
            if (E[n] > emax) emax = E[n];
          }
        }
        if (first) cq = (leftrho >> 1) | (leftrho & 1);
        else cq = (sab[x] | sab[x + 1]) | (((leftrho >> 2) | (leftrho >> 3)) & 1) << 1 | (sab[x + 2] | sab[x + 3]) << 2;
        if (!first && popc4(rho) >= 2) {
          int me = Eab[x], t;
          if (Eab[x + 1] > me) me = Eab[x + 1];
          if (Eab[x + 2] > me) me = Eab[x + 2];
          if (Eab[x + 3] > me) me = Eab[x + 3];
          t = me - 1; kappa = t > 1 ? t : 1;
        }
        Uq = emax > kappa ? emax : kappa;
        if (Uq > HT_UMAX) return -2;
        u = rho ? Uq - kappa : 0; uoff = u > 0;
        if (uoff) for (n = 0; n < 4; n++) if (((rho >> n) & 1) && E[n] == Uq) eps |= 1 << n;
        if (rho || cq) {
          e = pick(w, first, cq, rho, uoff, eps, minc);
          if (e < 0) return -3;
          {
            const uint8_t *t = first ? HT_T0[e] : HT_T1[e];
            ek = t[3]; e1 = t[4];
            if (vlc_enc(&vlc, t[5], t[6])) return -4;
          }
        }
        if (cq == 0 && mel_event(&mel, rho != 0)) return -4;
        for (n = 0; n < 4; n++)
          if ((rho >> n) & 1) {
            int mn = Uq - ((ek >> n) & 1);
            if ((ek >> n) & 1) { if (((v[n] >> mn) & 1) != (uint32_t)((e1 >> n) & 1) || (v[n] >> (mn + 1))) return -5; }
            else if (v[n] >> mn) return -5;
            if (ms_enc(&ms, v[n] & ((mn >= 32) ? 0xFFFFFFFFu : ((1u << mn) - 1)), mn)) return -4;
          }
        uq[j] = u;
        scur[x + 1] = (uint8_t)((rho >> 1) & 1); ecur[x + 1] = (uint8_t)E[1];
        scur[x + 2] = (uint8_t)((rho >> 3) & 1); ecur[x + 2] = (uint8_t)E[3];
        leftrho = rho;
      }
      if (first) {
        if (uq[0] > 0 && uq[1] > 0 && mel_event(&mel, (uq[0] < uq[1] ? uq[0] : uq[1]) > 2)) return -4;
        if (uq[0] > 2 && uq[1] > 2) {
          if (uv_pre(&vlc, uq[0] - 2) || uv_pre(&vlc, uq[1] - 2) || uv_suf(&vlc, uq[0] - 2) || uv_suf(&vlc, uq[1] - 2))
            return -4;
        } else if (uq[0] > 2 && uq[1] > 0) {
          if (uv_pre(&vlc, uq[0]) || vlc_enc(&vlc, (uint32_t)(uq[1] - 1), 1) || uv_suf(&vlc, uq[0])) return -4;
        } else if (uv_pre(&vlc, uq[0]) || uv_pre(&vlc, uq[1]) || uv_suf(&vlc, uq[0]) || uv_suf(&vlc, uq[1])) return -4;
      } else if (uv_pre(&vlc, uq[0]) || uv_pre(&vlc, uq[1]) || uv_suf(&vlc, uq[0]) || uv_suf(&vlc, uq[1])) return -4;
    }
    for (n = 0; n < W_ + 4; n++) { sab[n] = scur[n]; Eab[n] = ecur[n]; }
  }
  /* the ends */
  if (term <= 1) {
    if (term_ojph(&mel, &vlc, term == 1)) return -4;
    nmv = build_mv(w->cand, (int32_t)sizeof(w->cand), mel.b, mel.n, vlc.b, vlc.n);
  } else if (term <= 3) nmv = term_kdu(w, &mel, &vlc, term == 2 ? 16 : 17, w->cand, (int32_t)sizeof(w->cand));
  else nmv = term_min(w, &mel, &vlc, w->cand, (int32_t)sizeof(w->cand));
  ms_term(&ms);
  if (nmv < 2 || nmv > 4079) return -6;
  if ((int64_t)ms.n + nmv > cap) return -7;
  for (i = 0; i < ms.n; i++) out[i] = ms.b[i];
  for (i = 0; i < nmv; i++) out[ms.n + i] = w->cand[i];
  return ms.n + nmv;
}

/* the refinement segment (np 2 or 3) from the values q, by rule; its length
   in out, or < 0 */
int32_t pjaj2kh_ref(void *mem, int32_t W_, int32_t H, int32_t causal, int32_t np, const int32_t *q, int32_t rule,
  uint8_t *out, int32_t cap)
{
  htws_t *w = W(mem); int32_t n, i, ys, xg, x, y, nsp = 0, nmr = 0, k;
  int32_t fused = 0, fmax = 8, frem = 0; uint32_t ftmp = 0;    /* SigProp: forward */
  int32_t rused = 0, rgt = 1; uint32_t rtmp = 0;               /* MagRef: backward */
  int spt = rule >> 1 & 1, mrt = rule & 1, fuse = rule == 4;
  (void)frem;
  if (!w->ready) init_tables(w);
  if (W_ < 1 || H < 1 || W_ > 1024 || H > 1024 || (int64_t)W_ * H > HT_MAXS || np < 2 || np > 3 || rule < 0 || rule > 4)
    return -1;
  if (fuse) { spt = 0; mrt = 0; }
  n = W_ * H;
  for (i = 0; i < n; i++) {
    uint32_t a = q[i] < 0 ? 0u - (uint32_t)q[i] : (uint32_t)q[i];
    w->flg[i] = a >= 2 ? 1 : 0;
    w->sg[i] = q[i] < 0;
  }
#define FW_BIT(bit) do { ftmp |= (uint32_t)(bit) << fused; if (++fused == fmax) { \
    if (nsp >= HT_RCAP) return -2; w->spp[nsp++] = (uint8_t)ftmp; fmax = ftmp == 0xFF ? 7 : 8; ftmp = 0; fused = 0; } } while (0)
  for (ys = 0; ys < H; ys += 4)
    for (xg = 0; xg < W_; xg += 4) {
      int nn = 0;
      for (x = xg; x < xg + 4 && x < W_; x++)
        for (y = ys; y < ys + 4 && y < H; y++) {
          uint32_t a;
          i = y * W_ + x;
          if (w->flg[i] & 1) continue;
          a = q[i] < 0 ? 0u - (uint32_t)q[i] : (uint32_t)q[i];
          if (!nbsig(w, W_, H, x, y, ys, causal)) { if (a) return -3; w->flg[i] |= 4; continue; }
          FW_BIT(a != 0);
          w->flg[i] |= (uint8_t)(4 | (a ? 2 : 0));
          if (a) w->newl[nn++] = i;
        }
      for (k = 0; k < nn; k++) FW_BIT(w->sg[w->newl[k]]);
    }
#undef FW_BIT
  if (fused) { if (nsp >= HT_RCAP) return -2; w->spp[nsp++] = (uint8_t)ftmp; }
  if (spt) while (nsp > 0 && w->spp[nsp - 1] == 0) nsp--;
  if (np > 2) {
    for (ys = 0; ys < H; ys += 4)
      for (x = 0; x < W_; x++)
        for (y = ys; y < ys + 4 && y < H; y++) {
          int cp;
          i = y * W_ + x;
          if (!(w->flg[i] & 1)) continue;
          rtmp |= (uint32_t)(q[i] & 1) << rused; rused++;
          cp = 8 - rgt;
          if (rused == cp) {
            if (rgt && rtmp != 0x7F) { rgt = 0; continue; }
            if (nmr >= HT_RCAP) return -2;
            w->mrp[nmr++] = (uint8_t)rtmp; rgt = rtmp > 0x8F; rtmp = 0; rused = 0;
          } else if (rused == 8) {
            if (nmr >= HT_RCAP) return -2;
            w->mrp[nmr++] = (uint8_t)rtmp; rgt = rtmp > 0x8F; rtmp = 0; rused = 0;
          }
        }
    if (rused) { if (nmr >= HT_RCAP) return -2; w->mrp[nmr++] = (uint8_t)rtmp; }
    if (mrt) while (nmr > 0 && w->mrp[nmr - 1] == 0) nmr--;
  }
  /* SigProp's bytes, then MagRef's in memory order (the last written first) */
  if (fuse) {
    if (nsp < 1 || nmr < 1) return -4;
    if ((int64_t)nsp + nmr - 1 > cap) return -5;
    for (i = 0; i < nsp; i++) out[i] = w->spp[i];
    out[nsp - 1] |= w->mrp[nmr - 1];
    for (i = 1; i < nmr; i++) out[nsp - 1 + i] = w->mrp[nmr - 1 - i];
    return nsp + nmr - 1;
  }
  if ((int64_t)nsp + nmr > cap) return -5;
  for (i = 0; i < nsp; i++) out[i] = w->spp[i];
  for (i = 0; i < nmr; i++) out[nsp + i] = w->mrp[nmr - 1 - i];
  return nsp + nmr;
}

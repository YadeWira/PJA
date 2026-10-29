/* The coefficient loop of stream version 7 and its coding primitives,
   included by pjav7c.c once per direction: ENC 0 decodes (each bit from the
   stream), ENC 1 encodes (each bit from the data). One text, so the two
   cannot drift apart. pjacoef.inc is the same loop for versions 5 and 6. */
/* TARGET and SUFFIX: the copy compiled for SSE4.1 (pjav7c.c) */
#define CAT3_(a, b, c) a##b##c
#define CAT3(a, b, c) CAT3_(a, b, c)
#if ENC
#define FN(x) CAT3(x, _e, SUFFIX)
#define CD_T aenc_t
#define BITP(cd, p16, b) ebit(cd, p16, b)
#else
#define FN(x) CAT3(x, _d, SUFFIX)
#define CD_T adec_t
#define BITP(cd, p16, b) dbit(cd, p16)
#endif

static inline TARGET int FN(one)(CD_T *dc, abit_t *c, int b) { b = BITP(dc, c->p, b); learn(c, b); return b; }
static inline TARGET int FN(avg2)(CD_T *dc, abit_t *a, abit_t *c, int b) {
  int s = (T.st[a->p >> 4] + T.st[c->p >> 4]) / 2;
  b = BITP(dc, (uint32_t)T.sq[s + 2048] << 4, b);
  learn(a, b); learn(c, b);
  return b;
}
static inline TARGET int FN(direct)(CD_T *dc, int v, int count) {
  int r = 0;
  for (int k = count - 1; k >= 0; k--) r = (r << 1) | BITP(dc, 32768, (v >> k) & 1);
  return r;
}
/* n counters (3 to 7) and the constant input, the mixer's weights at its
   selector, learning at rate lr. The SSE4.1 copy does the dot product and
   the update four lanes at a time, the AVX2 copy eight: the lanes past n are
   0 in the inputs and in the weights (pjamodel's TMixer.Init and
   V7Weights), so they add nothing and stay 0, and every lane is the same
   32-bit arithmetic as the plain loop (no product or sum overflows: n + 1
   inputs below 2^11 times weights below 2^17 stay below 2^31). */
static inline __attribute__((always_inline)) TARGET int FN(mixn)(CD_T *dc, int32_t *w, abit_t *const *c, const int n, const int lr, int b) {
#if IN_SSE41
#define SV(i) ((i) < n ? (int32_t)T.st[c[(i) < n ? (i) : 0]->p >> 4] : (i) == n ? BIAS : 0)
#if IN_AVX2
  if (n >= 4) {   /* 8 lanes in one vector */
    __m256i s8 = _mm256_setr_epi32(SV(0), SV(1), SV(2), SV(3), SV(4), SV(5), SV(6), SV(7));
    __m256i w8 = _mm256_loadu_si256((const __m256i *)w), p8 = _mm256_mullo_epi32(s8, w8);
    __m128i acc = _mm_add_epi32(_mm256_castsi256_si128(p8), _mm256_extracti128_si256(p8, 1));
    acc = _mm_add_epi32(acc, _mm_shuffle_epi32(acc, 0x4E));
    acc = _mm_add_epi32(acc, _mm_shuffle_epi32(acc, 0xB1));
    int32_t dot = _mm_cvtsi128_si32(acc);
    int32_t pr = T.sq[clampi(truncshr(dot, 16), -2048, 2047) + 2048];
    b = BITP(dc, (uint32_t)pr << 4, b);
    __m256i u = _mm256_mullo_epi32(s8, _mm256_set1_epi32(((b << 12) - pr) * lr));
    u = _mm256_srai_epi32(_mm256_add_epi32(u, _mm256_srli_epi32(_mm256_srai_epi32(u, 31), 32 - 14)), 14);
    w8 = _mm256_min_epi32(_mm256_max_epi32(_mm256_add_epi32(w8, u), _mm256_set1_epi32(-MAX_W)), _mm256_set1_epi32(MAX_W));
    _mm256_storeu_si256((__m256i *)w, w8);
    goto learnt;
  }
#endif
  __m128i s0 = _mm_setr_epi32(SV(0), SV(1), SV(2), SV(3)), s1 = _mm_setzero_si128();
  if (n >= 4) s1 = _mm_setr_epi32(SV(4), SV(5), SV(6), SV(7));
#undef SV
  __m128i w0 = _mm_loadu_si128((const __m128i *)w), w1 = _mm_setzero_si128();
  __m128i acc = _mm_mullo_epi32(s0, w0);
  if (n >= 4) { w1 = _mm_loadu_si128((const __m128i *)(w + 4)); acc = _mm_add_epi32(acc, _mm_mullo_epi32(s1, w1)); }
  acc = _mm_add_epi32(acc, _mm_shuffle_epi32(acc, 0x4E));
  acc = _mm_add_epi32(acc, _mm_shuffle_epi32(acc, 0xB1));
  int32_t dot = _mm_cvtsi128_si32(acc);
  int32_t pr = T.sq[clampi(truncshr(dot, 16), -2048, 2047) + 2048];
  b = BITP(dc, (uint32_t)pr << 4, b);
  __m128i err = _mm_set1_epi32(((b << 12) - pr) * lr), rnd = _mm_set1_epi32((1 << 14) - 1);
  __m128i lo = _mm_set1_epi32(-MAX_W), hi = _mm_set1_epi32(MAX_W), u = _mm_mullo_epi32(s0, err);
  u = _mm_srai_epi32(_mm_add_epi32(u, _mm_and_si128(_mm_srai_epi32(u, 31), rnd)), 14);
  _mm_storeu_si128((__m128i *)w, _mm_min_epi32(_mm_max_epi32(_mm_add_epi32(w0, u), lo), hi));
  if (n >= 4) {
    u = _mm_mullo_epi32(s1, err);
    u = _mm_srai_epi32(_mm_add_epi32(u, _mm_and_si128(_mm_srai_epi32(u, 31), rnd)), 14);
    _mm_storeu_si128((__m128i *)(w + 4), _mm_min_epi32(_mm_max_epi32(_mm_add_epi32(w1, u), lo), hi));
  }
#else
  int32_t st[8], dot = 0;
  for (int i = 0; i < n; i++) { st[i] = T.st[c[i]->p >> 4]; dot += st[i] * w[i]; }
  st[n] = BIAS; dot += st[n] * w[n];
  int32_t pr = T.sq[clampi(truncshr(dot, 16), -2048, 2047) + 2048];
  b = BITP(dc, (uint32_t)pr << 4, b);
  int32_t err = ((b << 12) - pr) * lr;
  for (int i = 0; i <= n; i++) w[i] = clampi(w[i] + truncshr(st[i] * err, 14), -MAX_W, MAX_W);
#endif
#if IN_AVX2
learnt:
#endif
  /* the counters, each way with the bit a constant: one branch, short updates */
  if (b) for (int i = 0; i < n; i++) learn(c[i], 1);
  else for (int i = 0; i < n; i++) learn(c[i], 0);
  return b;
}
/* The four kernels' sums over the coefficients in mask (acc[0..31], K4's
   order), and the edge sums (eg[0..7] right, eg[8..15] bottom) */
static inline TARGET void FN(kernels)(const int64_t *fb, uint64_t mask, uint32_t *acc, uint32_t *eg) {
#if IN_AVX2
  __m256i a0 = _mm256_setzero_si256(), a1 = a0, a2 = a0, a3 = a0;
  while (mask) {
    int pos = __builtin_ctzll(mask); mask &= mask - 1;
    uint32_t f = (uint32_t)fb[pos];
    const __m256i *k = (const __m256i *)K4[pos]; __m256i fv = _mm256_set1_epi32((int32_t)f);
    a0 = _mm256_add_epi32(a0, _mm256_mullo_epi32(_mm256_load_si256(k), fv));
    a1 = _mm256_add_epi32(a1, _mm256_mullo_epi32(_mm256_load_si256(k + 1), fv));
    a2 = _mm256_add_epi32(a2, _mm256_mullo_epi32(_mm256_load_si256(k + 2), fv));
    a3 = _mm256_add_epi32(a3, _mm256_mullo_epi32(_mm256_load_si256(k + 3), fv));
    eg[pos >> 3] += E3U[pos & 7] * f; eg[8 + (pos & 7)] += E3U[pos >> 3] * f;
  }
  __m256i *o = (__m256i *)acc;
  _mm256_storeu_si256(o, a0); _mm256_storeu_si256(o + 1, a1); _mm256_storeu_si256(o + 2, a2); _mm256_storeu_si256(o + 3, a3);
#elif IN_SSE41
  __m128i a0 = _mm_setzero_si128(), a1 = a0, a2 = a0, a3 = a0, a4 = a0, a5 = a0, a6 = a0, a7 = a0;
  while (mask) {
    int pos = __builtin_ctzll(mask); mask &= mask - 1;
    uint32_t f = (uint32_t)fb[pos];
    const __m128i *k = (const __m128i *)K4[pos]; __m128i fv = _mm_set1_epi32((int32_t)f);
    a0 = _mm_add_epi32(a0, _mm_mullo_epi32(_mm_load_si128(k), fv));
    a1 = _mm_add_epi32(a1, _mm_mullo_epi32(_mm_load_si128(k + 1), fv));
    a2 = _mm_add_epi32(a2, _mm_mullo_epi32(_mm_load_si128(k + 2), fv));
    a3 = _mm_add_epi32(a3, _mm_mullo_epi32(_mm_load_si128(k + 3), fv));
    a4 = _mm_add_epi32(a4, _mm_mullo_epi32(_mm_load_si128(k + 4), fv));
    a5 = _mm_add_epi32(a5, _mm_mullo_epi32(_mm_load_si128(k + 5), fv));
    a6 = _mm_add_epi32(a6, _mm_mullo_epi32(_mm_load_si128(k + 6), fv));
    a7 = _mm_add_epi32(a7, _mm_mullo_epi32(_mm_load_si128(k + 7), fv));
    eg[pos >> 3] += E3U[pos & 7] * f; eg[8 + (pos & 7)] += E3U[pos >> 3] * f;
  }
  __m128i *o = (__m128i *)acc;
  _mm_storeu_si128(o, a0); _mm_storeu_si128(o + 1, a1); _mm_storeu_si128(o + 2, a2); _mm_storeu_si128(o + 3, a3);
  _mm_storeu_si128(o + 4, a4); _mm_storeu_si128(o + 5, a5); _mm_storeu_si128(o + 6, a6); _mm_storeu_si128(o + 7, a7);
#else
  for (int y = 0; y < 32; y++) acc[y] = 0;
  while (mask) {
    int pos = __builtin_ctzll(mask); mask &= mask - 1;
    uint32_t f = (uint32_t)fb[pos]; const uint32_t *k = K4[pos];
    for (int y = 0; y < 32; y++) acc[y] += k[y] * f;
    eg[pos >> 3] += E3U[pos & 7] * f; eg[8 + (pos & 7)] += E3U[pos >> 3] * f;
  }
#endif
}
#if IN_SSE41
/* The 16 DC estimates of a block with both neighbours, (left - kernel) / 4
   truncated, and what split16 gives of them: the fourth smallest (lo), the
   fourth largest (hi) and the sum of the 8 in the middle (modulo 2^32, as
   W32 takes it). A bitonic network in four lanes: each vector sorted,
   merged to two sorted 8s, and the last merge only as far as the sets need
   (min, max and sums do not depend on the order within a set). */
#define MM(x, y) { __m128i t_ = _mm_min_epi32(x, y); y = _mm_max_epi32(x, y); x = t_; }
static inline TARGET __m128i FN(bm4)(__m128i v) {   /* sorts a bitonic 4 */
  __m128i s = _mm_shuffle_epi32(v, 0x4E);
  v = _mm_blend_epi16(_mm_min_epi32(v, s), _mm_max_epi32(v, s), 0xF0);
  s = _mm_shuffle_epi32(v, 0xB1);
  return _mm_blend_epi16(_mm_min_epi32(v, s), _mm_max_epi32(v, s), 0xCC);
}
static inline TARGET void FN(mid16)(const uint32_t *left, const uint32_t *top, const uint32_t *ka,
                                    int64_t *lo, int64_t *hi, int64_t *total) {
  __m128i a = _mm_sub_epi32(_mm_loadu_si128((const __m128i *)left), _mm_loadu_si128((const __m128i *)ka));
  __m128i b = _mm_sub_epi32(_mm_loadu_si128((const __m128i *)(left + 4)), _mm_loadu_si128((const __m128i *)(ka + 4)));
  __m128i c = _mm_sub_epi32(_mm_loadu_si128((const __m128i *)top), _mm_loadu_si128((const __m128i *)(ka + 8)));
  __m128i d = _mm_sub_epi32(_mm_loadu_si128((const __m128i *)(top + 4)), _mm_loadu_si128((const __m128i *)(ka + 12)));
#define Q4(x) x = _mm_srai_epi32(_mm_add_epi32(x, _mm_srli_epi32(_mm_srai_epi32(x, 31), 30)), 2)
  Q4(a); Q4(b); Q4(c); Q4(d);
#undef Q4
  /* sort the columns, then transpose: four sorted vectors */
  MM(a, b); MM(c, d); MM(a, c); MM(b, d); MM(b, c);
  __m128i t0 = _mm_unpacklo_epi32(a, b), t1 = _mm_unpacklo_epi32(c, d);
  __m128i t2 = _mm_unpackhi_epi32(a, b), t3 = _mm_unpackhi_epi32(c, d);
  a = _mm_unpacklo_epi64(t0, t1); b = _mm_unpackhi_epi64(t0, t1);
  c = _mm_unpacklo_epi64(t2, t3); d = _mm_unpackhi_epi64(t2, t3);
  /* (a, b) and (c, d) to sorted 8s */
  b = _mm_shuffle_epi32(b, 0x1B); MM(a, b); a = FN(bm4)(a); b = FN(bm4)(b);
  d = _mm_shuffle_epi32(d, 0x1B); MM(c, d); c = FN(bm4)(c); d = FN(bm4)(d);
  /* the last merge: (a, b) ascending against (c, d) reversed */
  __m128i r0 = _mm_shuffle_epi32(d, 0x1B), r1 = _mm_shuffle_epi32(c, 0x1B);
  MM(a, r0); MM(b, r1);          /* a, b: the 8 smallest; r0, r1: the 8 largest, each bitonic */
  MM(a, b); MM(r0, r1);          /* a: the 4 smallest, b the next 4; r0 the next 4, r1 the 4 largest */
  __m128i mn = _mm_max_epi32(a, _mm_shuffle_epi32(a, 0x4E)), mx = _mm_min_epi32(r1, _mm_shuffle_epi32(r1, 0x4E));
  mn = _mm_max_epi32(mn, _mm_shuffle_epi32(mn, 0xB1)); mx = _mm_min_epi32(mx, _mm_shuffle_epi32(mx, 0xB1));
  __m128i sm = _mm_add_epi32(b, r0);
  sm = _mm_add_epi32(sm, _mm_shuffle_epi32(sm, 0x4E)); sm = _mm_add_epi32(sm, _mm_shuffle_epi32(sm, 0xB1));
  *lo = _mm_cvtsi128_si32(mn); *hi = _mm_cvtsi128_si32(mx); *total = _mm_cvtsi128_si32(sm);
}
#undef MM
#endif
/* a magnitude's bits below its top: the first with m1, the rest with mant[e][i] */
static inline TARGET int FN(mantissa)(CD_T *dc, abit_t *m1, abit_t *mant, int maxE, int e, int a) {
  int r = 1 << (e - 1);
  for (int i = e - 2; i >= 0; i--) {
    int b = i == e - 2 ? FN(one)(dc, m1, (a >> i) & 1) : FN(one)(dc, &mant[e * maxE + i], (a >> i) & 1);
    r |= b << i;
  }
  return r;
}
/* the same for the interior: the first bit with two counters (m1 by the
   position's bucket, m1b by the neighbourhood), the rest one counter each
   by the position's bucket, the bit length and the bit (mk) */
static inline TARGET int FN(mantissai)(CD_T *dc, abit_t *m1, abit_t *m1b, abit_t *mk, int e, int a) {
  int r = 1 << (e - 1);
  for (int i = e - 2; i >= 0; i--) {
    int b = i == e - 2 ? FN(avg2)(dc, m1, m1b, (a >> i) & 1) : FN(one)(dc, &mk[e * 16 + i], (a >> i) & 1);
    r |= b << i;
  }
  return r;
}

static TARGET int FN(component)(CD_T *dc, v7m_t *m, int16_t *coef, intptr_t bw, intptr_t bh, const uint16_t *qt,
                        const uint8_t *lumaNz, intptr_t lumaW, intptr_t sx, intptr_t sy, intptr_t y0, intptr_t y1,
                        uint8_t *nzc, v7work_t *wk) {
  int q[64]; double rq4[64];
  for (int k = 0; k < 64; k++) { q[k] = qt[k] > 0 ? qt[k] : 1; rq4[k] = 1.0 / (double)(181 * (int64_t)q[k]); }
  /* a big edge prediction (pcn): |predQ| >= PTH, i.e. 2 |n| >= (2 PTH - 1) 181 q; row 0 and column 0, natural order */
  uint32_t pthR[8], pthC[8], pthR2[8], pthC2[8];
  pthR[0] = pthC[0] = pthR2[0] = pthC2[0] = 0xFFFFFFFFu;
  for (int i = 1; i < 8; i++) {
    pthR[i] = (uint32_t)(((2 * PTH - 1) * 181 * (int64_t)q[T.unzig[i]] + 1) >> 1);
    pthC[i] = (uint32_t)(((2 * PTH - 1) * 181 * (int64_t)q[T.unzig[i * 8]] + 1) >> 1);
    pthR2[i] = (uint32_t)(((2 * PTH2 - 1) * 181 * (int64_t)q[T.unzig[i]] + 1) >> 1);
    pthC2[i] = (uint32_t)(((2 * PTH2 - 1) * 181 * (int64_t)q[T.unzig[i * 8]] + 1) >> 1);
  }
  int64_t dq0 = 2896 * (int64_t)q[0], dc5 = 5 * dq0, dc3 = 3 * dq0;
  double rq0 = 1.0 / (double)dq0, rc5 = 1.0 / (double)dc5, rc3 = 1.0 / (double)dc3;
  int64_t fb[64];
  for (int k = 0; k < 64; k++) fb[k] = 0;
  ecache_t *rowC = wk->rowC, cache[2], *leftC = &cache[0], *rightC = &cache[1];
  for (int y = 0; y < 8; y++) leftC->eg[y] = leftC->px[y] = 0;
  uint8_t *dcr = wk->dcr, *rcnt = wk->rcnt, *ccnt = wk->ccnt;
  int ok = 1;
  for (intptr_t by = y0; by < y1 && ok; by++)
    for (intptr_t bx = 0; bx < bw; bx++) {
      intptr_t base = (by * bw + bx) * 64;
      int haveA = by > y0, haveL = bx > 0;
      intptr_t abase = haveA ? base - bw * 64 : base, lbase = haveL ? base - 64 : base;
      int16_t *b = coef + base;
      nbr_t nbr; nbrsetup(&nbr, coef, base, bw, bx, haveA);
      /* the luma block over this one (chroma) and the Cb block at the same place (Cr) */
      const int16_t *lb = wk->lumaC ? wk->lumaC + ((by * sy) * lumaW + bx * sx) * 64 : 0;
      const int16_t *cb = wk->prevC ? wk->prevC + base : 0;
      /* 1. the interior count: its bit length in unary, mixed; the bits below with two counters */
      int nzA = haveA ? nzc[(by - 1) * bw + bx] : 0, nzL = haveL ? nzc[by * bw + bx - 1] : 0, ctx;
      if (haveA && haveL) ctx = nzb((nzA + nzL + 1) / 2); else if (haveA) ctx = nzb(nzA);
      else if (haveL) ctx = nzb(nzL); else ctx = 0;
      int za = haveA ? nzb(nzA) : 0, zb = haveL ? nzb(nzL) : 0;
      int lz = lumaNz ? nzb(lumaNz[(by * sy) * lumaW + bx * sx]) : NZ_BUCKETS;
      int nT = ENC ? ones64(nzmask(b) & T.interiorZz) : 0, eT = bitlen64(nT);
      /* the blocks above left and above right, and the Cb block's count */
      int c4;
      {
        int haveAL = haveA && haveL, haveAR = haveA && bx + 1 < bw;
        int nAL = haveAL ? nzc[(by - 1) * bw + bx - 1] : 0, nAR = haveAR ? nzc[(by - 1) * bw + bx + 1] : 0;
        c4 = haveAL && haveAR ? nzb((nAL + nAR + 1) / 2) : haveAL ? nzb(nAL) : haveAR ? nzb(nAR) : NZ_BUCKETS;
        c4 = c4 * 12 + (cb ? nzb(ones64(nzmask(cb) & T.interiorZz)) : NZ_BUCKETS);
      }
      int e = 0;
      while (e < 6) {
        abit_t *const nc[3] = {&m->nz2[(za * NZ_BUCKETS + zb) * 64 + e + 1], &m->nz3[(lz * NZ_BUCKETS + ctx) * 64 + e + 1],
                               &m->nz4[c4 * 8 + e]};
        if (!FN(mixn)(dc, m->wNz + e * LANES, nc, 3, MIX_LR, eT > e)) break;
        e++;
      }
      int n = 0;
      if (e > 0) {
        int node = 1;
        for (int k = e - 2; k >= 0; k--) node = node * 2 + FN(avg2)(dc, &m->nzm1[(ctx * 8 + e) * 8 + k], &m->nzm2[(lz * 8 + e) * 8 + k], (nT >> k) & 1);
        n = node;
      }
      if (n > 49) { ok = 0; break; }
      nzc[by * bw + bx] = (uint8_t)n;
      int nzB = nzb(n);
      /* 2. the interior in zigzag, while nonzeros are left */
      int rem = n, ssum = 0, lastIdx = 0;
      uint64_t cm = 0;  /* the nonzeros coded so far, by raster position */
      for (int idx = 0; rem > 0 && idx <= 48; idx++) {
        int k = T.interior[idx];
        int nb = nbr.none ? -1 : nbrmag(&nbr, k);
        int ib = T.ibWa[idx] * iabs(b[T.ibNa[idx]]) + T.ibWb[idx] * iabs(b[T.ibNb[idx]]);
        int mbI = T.ibNone[idx] ? NO_NEIGHBOUR : clip(finelog(ib), NO_NEIGHBOUR - 1), mbN, mbS;
        if (nb < 0) { mbN = NO_NEIGHBOUR; mbS = clip(finelog(2 * ib), NO_NEIGHBOUR - 1); }
        else { mbN = clip(finelog(nb), NO_NEIGHBOUR - 1); mbS = clip(finelog(nb + ib), NO_NEIGHBOUR - 1); }
        int kb = T.kBucket[k], rb = remb(rem), bit, v = ENC ? b[k] : 0, vT = bitlen64(v);
        /* the nonzeros so far on this row and this column of the block */
        int pos = T.zzTable[k];
        int rcN = clip(ones64(cm & (0xFFull << (pos & 56))), 3), ccN = clip(ones64(cm & (0x0101010101010101ull << (pos & 7))), 3);
        /* two contexts by component: chroma the luma's magnitude here, luma (and a
           chroma without one) the sum of the magnitudes coded so far in the block;
           Cr the Cb's magnitude here, luma and Cb how far back the last nonzero was */
        int cl = lb ? clip(finelog(lb[k]), 11) : 12 + clip(finelog(ssum), 15);
        int cc = cb ? clip(finelog(cb[k]), 11) : 12 + clip(idx - lastIdx, 15);
        /* nonzeros left against positions left, in eighths (RATIO_OF, at most 15),
           halved: the interior exponent's weight set. When every position left is
           nonzero (rem = left) RATIO_OF has no column: 16 then, and no read */
        int left = T.interiorLeft[idx], ratio = rem < left ? T.ratioOf[(left - 1) * 49 + rem] : 16;
        if (rem >= left) bit = 1;
        else {
          abit_t *const zc[4] = {&m->zero2[(k * MAG_BUCKETS + mbI) * 4 + clip(mbN, 3)],
                                 &m->zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb],
                                 &m->zLum[(k * 28 + cl) * REM_BUCKETS + rb], &m->zCb[(k * 28 + cc) * REM_BUCKETS + rb]};
          bit = FN(mixn)(dc, m->wZero + k * LANES, zc, 4, LR_ZERO, v != 0);
        }
        if (bit) {
          int i = 1;
          cm |= 1ull << pos;
          while (i < MAX_EXP_AC) {
            abit_t *const xc[5] = {&m->expo3[(kb * REM_BUCKETS + rb) * ROW + i - 1],
                                   &m->xPos[(k * MAG_BUCKETS + mbS) * ROW + i - 1],
                                   &m->xRow[((kb * 4 + rcN) * 4 + ccN) * ROW + i - 1],
                                   &m->xLum[(kb * 28 + cl) * ROW + i - 1], &m->xCb[(kb * 28 + cc) * ROW + i - 1]};
            if (!FN(mixn)(dc, m->wExpo + (((i - 1) * K_BUCKETS + kb) * 9 + ratio / 2) * LANES, xc, 5, MIX_LR, vT > i)) break;
            i++;
          }
          int x = FN(mantissai)(dc, &m->mant1[i * K_BUCKETS + kb], &m->mFirst[(i * MAG_BUCKETS + mbS) * 16 + clip(cl, 15)], &m->mRest[kb * 256], i, iabs(v));
          ssum += x; lastIdx = idx;
          /* the sign: chroma's by the luma's and the Cb's signs here, luma's as a bit */
          int ls = lb ? sgn3(lb[k]) : 1, cs = cb ? sgn3(cb[k]) : 1;
          int neg = ls != 1 || cs != 1 ? FN(one)(dc, &m->iSign[(k * 3 + ls) * 3 + cs], v < 0) : FN(direct)(dc, v < 0, 1);
          if (!ENC) b[k] = (int16_t)(neg ? -x : x);
          rem--;
        }
      }
      if (rem > 0) { ok = 0; break; }
      uint64_t fm = 0, zm = nzmask(b) & T.interiorZz;
      while (zm) { int k = __builtin_ctzll(zm); zm &= zm - 1; fb[T.zzTable[k]] = dequant(b[k], q[k]); fm |= 1ull << T.zzTable[k]; }
      /* 3. each edge coefficient predicted across its edge (from the interior and the block there only) */
      int32_t pn[16]; int pcn[2] = {15, 15};   /* pn: each prediction's numerator, row 0 even, column 0 odd, from lane 2 */
      {
        /* the interior's share of each column (for row 0) and each row (for column 0), in one pass */
        int64_t csum[8] = {0}, rsum[8] = {0};
        uint64_t mm = fm;
        while (mm) {
          int pos = __builtin_ctzll(mm); mm &= mm - 1;
          int64_t f = fb[pos];
          csum[pos & 7] += T.w3[pos >> 3] * f; rsum[pos >> 3] += T.w3[pos & 7] * f;
        }
        /* pcn, how many predictions are big (|predQ| >= PTH) plus how many very big (>= PTH2), without
           dividing: exactly when |n| >= pthR/pthC (pthR2/pthC2); lane 0 never. 15: no prediction */
        if (haveA) {
          int c = 0;
          for (int w = 0; w < 8; w++) {
            int32_t n = (int32_t)(rowC[bx].eg[w] - (uint32_t)csum[w]); uint32_t s = (uint32_t)(n >> 31);
            pn[2 * w] = n; c += (((uint32_t)n ^ s) - s >= pthR[w]) + (((uint32_t)n ^ s) - s >= pthR2[w]);
          }
          pcn[0] = c;
        }
        if (haveL) {
          int c = 0;
          for (int u = 0; u < 8; u++) {
            int32_t n = (int32_t)(leftC->eg[u] - (uint32_t)rsum[u]); uint32_t s = (uint32_t)(n >> 31);
            pn[2 * u + 1] = n; c += (((uint32_t)n ^ s) - s >= pthC[u]) + (((uint32_t)n ^ s) - s >= pthC2[u]);
          }
          pcn[1] = c;
        }
      }
      /* 3a. how many nonzero on row 0 and on column 0 */
      int ecn[2], erem[2], eleft[2], agr[2] = {0, 0};   /* agr: the last sign against its prediction, 0 none, 1 agreed, 2 not */
      for (int et = 0; et < 2; et++) {
        int a, l;
        if (et == 0) { a = haveA ? rcnt[(by - 1) * bw + bx] : 8; l = haveL ? rcnt[by * bw + bx - 1] : 8; }
        else { a = haveL ? ccnt[by * bw + bx - 1] : 8; l = haveA ? ccnt[(by - 1) * bw + bx] : 8; }
        int cbk = et == 1 ? ecn[0] : 8, cnode = 1, cT = 0;
        /* the interior's nonzeros on the row (column) next to this edge; chroma:
           the luma's and the Cb's counts on the same edge */
        int r1 = ones64(et == 0 ? (fm >> 8) & 0xFE : fm & 0x0202020202020200ull), ex;
        if (lb) {
          uint64_t em = et == 0 ? ROW0ZZ : COL0ZZ;
          ex = 2048 + ((et * 9 + ones64(nzmask(lb) & em)) * 18 + (cb ? ones64(nzmask(cb) & em) : 9 + r1)) * 8;
        } else ex = ((et * 8 + r1) * 8 + clip(nzB, 7)) * 8;
        if (ENC) for (int i = 1; i <= 7; i++) cT += (et == 0 ? b[T.unzig[i]] : b[T.unzig[i * 8]]) != 0;
        for (int i = 2; i >= 0; i--) {
          abit_t *const ec[5] = {&m->ec1[((et * NZ_BUCKETS + nzB) * 9 + a) * 8 + cnode], &m->ec2[((et * 9 + a) * 9 + l) * 8 + cnode],
                                 &m->ec3[((et * 9 + cbk) * PRED_BUCKETS + clip(nzB, PRED_BUCKETS - 1)) * 8 + cnode],
                                 &m->ecX[ex + cnode], &m->ecp[((et * 16 + pcn[et]) * NZ_BUCKETS + nzB) * 8 + cnode]};
          int bit = FN(mixn)(dc, m->wECnt + ((et * 8 + cnode) * NZ_BUCKETS + nzB) * LANES, ec, 5, MIX_LR, (cT >> i) & 1);
          cnode = cnode * 2 + bit;
        }
        ecn[et] = cnode - 8; erem[et] = ecn[et]; eleft[et] = 7;
      }
      rcnt[by * bw + bx] = (uint8_t)ecn[0]; ccnt[by * bw + bx] = (uint8_t)ecn[1];
      /* 3b. row 0 and column 0, interleaved, each predicted across its edge */
      for (int ep = 0; ep < EDGE_POS; ep++) {
        int u, w, et = ep & 1;
        if (!et) { u = 0; w = ep / 2 + 1; } else { u = ep / 2 + 1; w = 0; }
        if (erem[et] == 0) continue;
        int k = T.unzig[u * 8 + w], pb = NO_PRED;
        int64_t predF = 0, predQ = 0;
        if (u == 0 ? haveA : haveL) {
          edgepred(pn[ep + 2], 181 * (int64_t)q[k], rq4[k], &predF, &predQ);
          pb = clip(finelog(div8round(w32(5 * predF))), NO_PRED - 1);
        }
        int pbq = pb == NO_PRED ? NO_PQ : clip(finelog(div8round(w32(4 * predQ))), NO_PQ - 1);
        int a = haveA ? iabs(coef[abase + k]) : 0, l = haveL ? iabs(coef[lbase + k]) : 0, mbN;
        if (haveA && haveL) mbN = clip(bitlen64(a + l), NO_NEIGHBOUR - 1);
        else if (haveA || haveL) mbN = clip(bitlen64(2 * (a + l)), NO_NEIGHBOUR - 1);
        else mbN = NO_NEIGHBOUR;
        int prevB = ep >= 2 ? clip(bitlen64(u == 0 ? b[T.unzig[w - 1]] : b[T.unzig[(u - 1) * 8]]), 7) : 7;
        int ib = u == 0 ? clip(finelog(b[T.unzig[8 + w]]), 11) : clip(finelog(b[T.unzig[u * 8 + 1]]), 11);
        int bit, v = ENC ? b[k] : 0, vT = bitlen64(v);
        /* chroma: the luma's and the Cb's magnitudes here; luma: the interior's
           sum, and the neighbour across the edge */
        int el = lb ? clip(finelog(lb[k]), 11) : 13 + clip(finelog(ssum), 12);
        int ec = cb ? clip(finelog(cb[k]), 11) : 12 + (haveA && haveL ? clip(finelog(u == 0 ? a : l), 11) : 12);
        if (erem[et] >= eleft[et]) bit = 1;
        else {
          abit_t *const zc[3] = {&m->ez6[((ep * 8 + erem[et]) * 8 + eleft[et]) * 4 + clip(pb, 3)],
                                 &m->ezero4[ep * MAG_BUCKETS + mbN], &m->ezLum[(ep * 26 + el) * 4 + clip(pb, 3)]};
          bit = FN(mixn)(dc, m->wEZero + (ep * 64 + erem[et] * 8 + eleft[et]) * LANES, zc, 3, LR_ZERO, v != 0);
        }
        eleft[et]--;
        if (bit) {
          erem[et]--;
          int i = 1;
          while (i < MAX_EXP_AC) {
            abit_t *const xc[7] = {&m->eexpo5[(ep * 12 + ib) * ROW + i - 1], &m->eexpo1[(ep * PQ_BUCKETS + pbq) * ROW + i - 1],
                                   &m->eexpo2[(ep * MAG_BUCKETS + mbN) * ROW + i - 1],
                                   &m->eexpo3[(pbq * 8 + prevB) * ROW + i - 1],
                                   &m->eexpo4[(ep * NZ_BUCKETS + nzB) * ROW + i - 1],
                                   &m->exLum[(ep * 26 + el) * ROW + i - 1], &m->exCb[(ep * 26 + ec) * ROW + i - 1]};
            if (!FN(mixn)(dc, m->wEExpo + (((i - 1) * EDGE_POS + ep) * 4 + clip(erem[et], 3)) * LANES, xc, 7, LR_EEXPO, vT > i)) break;
            i++;
          }
          /* the bits below the top, each by where the prediction falls against the
             two halves left (none without a prediction) */
          int x = 1 << (i - 1);
          {
            uint64_t ap = uabs64(predF);
            int P = pb == NO_PRED ? -1 : ap > 65536 ? 65536 : (int)ap, av = iabs(v);
            abit_t *em = &m->eMant[ep * 1280];
            for (int j = i - 2; j >= 0; j--) {
              int c5 = 4;
              if (P >= 0) { int d = P - (x | (1 << j)); c5 = d < -(1 << j) ? 0 : d < 0 ? 1 : d < (1 << j) ? 2 : 3; }
              abit_t *cx = &em[(i * 16 + j) * 5 + c5];
              int bt = j == i - 2 ? FN(avg2)(dc, &m->emant1[i * PQ_BUCKETS + pbq], cx, (av >> j) & 1) : FN(one)(dc, cx, (av >> j) & 1);
              x |= bt << j;
            }
          }
          int sg = pb == NO_PRED ? 1 : sgn3(predF);
          /* the sign: chroma by the luma's and the Cb's signs here, luma by the
             neighbours' along the edge and across it */
          int s1, s2;
          if (lb) { s1 = sgn3(lb[k]); s2 = cb ? sgn3(cb[k]) : 1; }
          else {
            int sA = haveA ? sgn3(coef[abase + k]) : 1, sL = haveL ? sgn3(coef[lbase + k]) : 1;
            s1 = u == 0 ? sL : sA; s2 = u == 0 ? sA : sL;
          }
          /* two counters: one by the prediction's sign and size and the size coded
             against it (rel), one by the position, the last sign against its
             prediction (agr), those two signs and the prediction's size */
          int rel = pb == NO_PRED ? 4 : clampi(finelog(4 * x) - pbq + 4, 0, 8);
          int neg = FN(avg2)(dc, &m->esr[(((ep & 1) * 3 + sg) * PQ_BUCKETS + (pbq >> 1)) * 9 + rel],
                             &m->eSgn[((((ep * 3 + agr[et]) * 3 + sg) * 3 + s1) * 3 + s2) * 3 + clip(pb, 2)], v < 0);
          if (sg != 1) agr[et] = neg == (sg == 0) ? 1 : 2;
          if (!ENC) b[k] = (int16_t)(neg ? -x : x);
        }
      }
      zm = nzmask(b) & T.edgeZz;
      while (zm) { int k = __builtin_ctzll(zm); zm &= zm - 1; int pos = T.zzTable[k]; fb[pos] = dequant(b[k], q[k]); fm |= 1ull << pos; }
      /* 4. the DC, from up to 16 boundary estimates */
      int64_t ests[16], lo = 0, hi = 0, total = 0, pred;
      uint32_t ka[32] __attribute__((aligned(16))), eg[16];
      for (int i = 0; i < 16; i++) eg[i] = 0;
      FN(kernels)(fb, fm, ka, eg);
      int nest = 0;
#if IN_SSE41
      if (haveL && haveA) { nest = 16; FN(mid16)(leftC->px, rowC[bx].px, ka, &lo, &hi, &total); } else
#endif
      {
        if (haveL) for (int i = 0; i < 8; i++) ests[nest++] = s32(leftC->px[i] - ka[i]) / 4;
        if (haveA) for (int i = 0; i < 8; i++) ests[nest++] = s32(rowC[bx].px[i] - ka[8 + i]) / 4;
        if (nest == 16) {
          /* the four smallest and largest go to the ends: the largest of the first four,
             the smallest of the last four (lo, hi) and the sum of the eight between */
          split16(ests);
          lo = max64(max64(ests[0], ests[1]), max64(ests[2], ests[3]));
          hi = min64(min64(ests[12], ests[13]), min64(ests[14], ests[15]));
          for (int i = 4; i < 12; i++) total += ests[i];
        }
      }
      if (nest == 16) {
        /* the middle ten: lo, hi (the spread, the context) and the eight between */
        total = w32(total + lo + hi); nest = 10;
      } else if (nest == 8) {
        split8(ests); lo = max64(ests[0], ests[1]); hi = min64(ests[6], ests[7]);
        total = w32(lo + ests[2] + ests[3] + ests[4] + ests[5] + hi); nest = 6;
      }
      int dctx, frac = 4;
      if (nest > 0) {
        /* the prediction in eighths, truncated, then rounded to an integer: the eighths left are a context */
        int64_t sgt = total >> 63, at = (total ^ sgt) - sgt, t;
        if (nest == 10) t = divfloorr(4 * at, dc5, rc5);
        else t = divfloorr(4 * at, dc3, rc3);
        int64_t pa = (t + 4) >> 3;
        pred = (pa ^ sgt) - sgt;
        frac = (int)(((t - 8 * pa) ^ sgt) - sgt) + 4;
        dctx = clip(finelog(divroundr(4 * w32(hi - lo), dq0, rq0)), ACT2 - 2);
      } else { pred = 0; dctx = ACT2 - 1; }
      int d3 = dctx < 4 ? 0 : clip((dctx - 4) / 3, 7);
      if (pred > 32767) { pred = 32767; frac = 4; }
      if (pred < -32767) { pred = -32767; frac = 4; }
      int rb2 = 0, nbs = 0, nsg = 0;   /* nsg: the neighbours' residual signs, 3 * above + left */
      if (haveA) { int d = dcr[(by - 1) * bw + bx]; rb2 += d & 15; nbs++; nsg += 3 * (d >> 4); }
      if (haveL) { int d = dcr[by * bw + bx - 1]; rb2 += d & 15; nbs++; nsg += d >> 4; }
      rb2 = clip(rb2, 19);
      int res = 0, rT = ENC ? (int)(b[0] - pred) : 0, rE = bitlen64(rT);
      /* the residual of the Cb block here (Cr) or of the luma block over this
         one (Cb): its size (dX, 0 without one) and its sign (dS) */
      int dX = 0, dS = 0;
      {
        int o = -1;
        if (wk->prevD) o = wk->prevD[by * bw + bx];
        else if (wk->lumaD && lumaNz) o = wk->lumaD[(by * sy) * lumaW + bx * sx];
        if (o >= 0) { dX = 1 + (o & 15); dS = o >> 4; }
      }
      abit_t *const dzc[5] = {&m->dcZero[dctx], &m->dzf[rb2 * 5 + iabs(frac - 4)], &m->dz3[nzB * 8 + d3], &m->dz4[dctx * 3 + nbs], &m->dzX[dctx * 17 + dX]};
      if (FN(mixn)(dc, m->wDcZero + dctx * LANES, dzc, 5, MIX_LR, rT != 0)) {
        int i = 1;
        while (i < MAX_EXP_DC) {
          abit_t *const dxc[5] = {&m->dcExpo[dctx * ROW + i - 1], &m->dx2[rb2 * ROW + i - 1],
                                  &m->dx3[(nzB * 8 + d3) * ROW + i - 1], &m->dx4[(dctx * 3 + nbs) * ROW + i - 1],
                                  &m->dxX[(d3 * 17 + dX) * ROW + i - 1]};
          if (!FN(mixn)(dc, m->wDcExpo + (i - 1) * LANES, dxc, 5, MIX_LR, rE > i)) break;
          i++;
        }
        int x = FN(mantissa)(dc, &m->dcMant1[i * ACT2 + dctx], m->dcMant, ROW, i, iabs(rT));
        /* the sign: by the spread and the prediction's eighths, and by the
           neighbours' residual signs, the eighths and the other component's sign here */
        /* (and on which side of the prediction the DCs left and above are) */
        int gl = haveL ? sgn3(coef[lbase] - pred) : 1, ga = haveA ? sgn3(coef[abase] - pred) : 1;
        res = FN(avg2)(dc, &m->dsf[(((dctx >> 1) * 9 + frac) * 3 + gl) * 3 + ga], &m->dsX[(nsg * 9 + frac) * 3 + dS], rT < 0) ? -x : x;
      }
      /* its size and, above it, its sign, for the blocks right and below and the next component */
      dcr[by * bw + bx] = (uint8_t)(clip(finelog(res), 15) | ((res > 0) + 2 * (res < 0)) << 4);
      if (!ENC) {
        int64_t xdc = pred + res;
        if (xdc < -32767 || xdc > 32767) { ok = 0; break; }
        b[0] = (int16_t)xdc;
      }
      fb[0] = dequant(b[0], q[0]);
      /* the edge caches, the DC added */
      {
        uint32_t f = (uint32_t)fb[0];
        ecache_t *rc_ = rightC, *bc_ = &rowC[bx];
        for (int y = 0; y < 8; y++) {
          rc_->px[y] = ka[16 + y] + K4[0][16 + y] * f; bc_->px[y] = ka[24 + y] + K4[0][24 + y] * f;
          rc_->eg[y] = eg[y]; bc_->eg[y] = eg[8 + y];
        }
        rc_->eg[0] += E3U[0] * f; bc_->eg[0] += E3U[0] * f;
      }
      uint64_t mm = fm | 1;
      while (mm) { fb[__builtin_ctzll(mm)] = 0; mm &= mm - 1; }
      { ecache_t *t = leftC; leftC = rightC; rightC = t; }  /* this block is the next one's left */
    }
  return ok;
}

#undef FN
#undef CD_T
#undef BITP
#undef CAT3
#undef CAT3_

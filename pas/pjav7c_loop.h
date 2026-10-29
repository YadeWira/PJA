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
/* n counters and the constant input, the mixer's weights at its selector */
static inline __attribute__((always_inline)) TARGET int FN(mixn)(CD_T *dc, int32_t *w, abit_t *const *c, const int n, int b) {
  int32_t st[8], dot = 0;
  for (int i = 0; i < n; i++) { st[i] = T.st[c[i]->p >> 4]; dot += st[i] * w[i]; }
  st[n] = T.st[(32768 + 8192) >> 4]; dot += st[n] * w[n];
  int32_t pr = T.sq[clampi(truncshr(dot, 16), -2048, 2047) + 2048];
  b = BITP(dc, (uint32_t)pr << 4, b);
  int32_t err = ((b << 12) - pr) * MIX_LR;
  for (int i = 0; i <= n; i++) w[i] = clampi(w[i] + truncshr(st[i] * err, 14), -MAX_W, MAX_W);
  for (int i = 0; i < n; i++) learn(c[i], b);
  return b;
}
/* a magnitude's bits below its top: the first with m1, the rest with mant[e][i] */
static inline TARGET int FN(mantissa)(CD_T *dc, abit_t *m1, abit_t *mant, int maxE, int e, int a) {
  int r = 1 << (e - 1);
  for (int i = e - 2; i >= 0; i--) {
    int b = i == e - 2 ? FN(one)(dc, m1, (a >> i) & 1) : FN(one)(dc, &mant[e * maxE + i], (a >> i) & 1);
    r |= b << i;
  }
  return r;
}
#undef MIX3
#undef MIX4
#undef MIX5
#define MIX3(b, w, a1, a2, a3) ({ abit_t *const cs_[3] = {a1, a2, a3}; FN(mixn)(dc, w, cs_, 3, b); })
#define MIX4(b, w, a1, a2, a3, a4) ({ abit_t *const cs_[4] = {a1, a2, a3, a4}; FN(mixn)(dc, w, cs_, 4, b); })
#define MIX5(b, w, a1, a2, a3, a4, a5) ({ abit_t *const cs_[5] = {a1, a2, a3, a4, a5}; FN(mixn)(dc, w, cs_, 5, b); })

static TARGET int FN(component)(CD_T *dc, v7m_t *m, int16_t *coef, intptr_t bw, intptr_t bh, const uint16_t *qt,
                        const uint8_t *lumaNz, intptr_t lumaW, intptr_t sx, intptr_t sy, intptr_t y0, intptr_t y1,
                        uint8_t *nzc, v7work_t *wk) {
  int q[64]; double rq[64];
  for (int k = 0; k < 64; k++) { q[k] = qt[k] > 0 ? qt[k] : 1; rq[k] = 1.0 / (double)(724 * (int64_t)q[k]); }
  int64_t dq0 = 2896 * (int64_t)q[0], dc4 = 4 * dq0, dc8 = 8 * dq0;
  double rq0 = 1.0 / (double)dq0, rc4 = 1.0 / (double)dc4, rc8 = 1.0 / (double)dc8;
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
      /* 1. the interior count: its bit length in unary, mixed; the bits below with two counters */
      int nzA = haveA ? nzc[(by - 1) * bw + bx] : 0, nzL = haveL ? nzc[by * bw + bx - 1] : 0, ctx;
      if (haveA && haveL) ctx = nzb((nzA + nzL + 1) / 2); else if (haveA) ctx = nzb(nzA);
      else if (haveL) ctx = nzb(nzL); else ctx = 0;
      int za = haveA ? nzb(nzA) : 0, zb = haveL ? nzb(nzL) : 0;
      int lz = lumaNz ? nzb(lumaNz[(by * sy) * lumaW + bx * sx]) : NZ_BUCKETS;
      int nT = ENC ? ones64(nzmask(b) & T.interiorZz) : 0, eT = bitlen64(nT);
      int e = 0;
      while (e < 6) {
        int bit = MIX3(eT > e, m->wNz + e * LANES, &m->nz1[ctx * 64 + e + 1], &m->nz2[(za * NZ_BUCKETS + zb) * 64 + e + 1],
                       &m->nz3[(lz * NZ_BUCKETS + ctx) * 64 + e + 1]);
        if (!bit) break;
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
      int rem = n;
      for (int idx = 0; rem > 0 && idx <= 48; idx++) {
        int k = T.interior[idx];
        int nb = neighbourmag(coef, base, bw, bx, by - y0, k);
        int ib = T.ibWa[idx] * iabs(b[T.ibNa[idx]]) + T.ibWb[idx] * iabs(b[T.ibNb[idx]]);
        int mbI = T.ibNone[idx] ? NO_NEIGHBOUR : clip(finelog(ib), NO_NEIGHBOUR - 1), mbN, mbS;
        if (nb < 0) { mbN = NO_NEIGHBOUR; mbS = clip(finelog(2 * ib), NO_NEIGHBOUR - 1); }
        else { mbN = clip(finelog(nb), NO_NEIGHBOUR - 1); mbS = clip(finelog(nb + ib), NO_NEIGHBOUR - 1); }
        int kb = T.kBucket[k], rb = remb(rem), bit, v = ENC ? b[k] : 0, vT = bitlen64(v);
        if (rem >= T.interiorLeft[idx]) bit = 1;
        else bit = MIX5(v != 0, m->wZero + k * LANES, &m->zero5[(k * (NZ_BUCKETS + 1) + lz) * REM_BUCKETS + rb],
                        &m->zero1[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN],
                        &m->zero2[(k * MAG_BUCKETS + mbI) * 4 + clip(mbN, 3)],
                        &m->zero3[k * RATIO_BUCKETS + T.ratioOf[(T.interiorLeft[idx] - 1) * 49 + rem]],
                        &m->zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb]);
        if (bit) {
          int i = 1;
          while (i < MAX_EXP_AC) {
            if (!MIX4(vT > i, m->wExpo + ((i - 1) * K_BUCKETS + kb) * LANES, &m->expo1[(kb * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                      &m->expo2[(kb * MAG_BUCKETS + mbI) * MAX_EXP_AC + i - 1],
                      &m->expo3[(kb * REM_BUCKETS + rb) * MAX_EXP_AC + i - 1],
                      &m->expo4[mbS * MAX_EXP_AC + i - 1])) break;
            i++;
          }
          int x = FN(mantissa)(dc, &m->mant1[i * K_BUCKETS + kb], m->mant, MAX_EXP_AC, i, iabs(v));
          int neg = FN(direct)(dc, v < 0, 1);
          if (!ENC) b[k] = (int16_t)(neg ? -x : x);
          rem--;
        }
      }
      if (rem > 0) { ok = 0; break; }
      uint64_t fm = 0, zm = nzmask(b) & T.interiorZz;
      while (zm) { int k = __builtin_ctzll(zm); zm &= zm - 1; fb[T.zzTable[k]] = dequant(b[k], q[k]); fm |= 1ull << T.zzTable[k]; }
      /* 3a. how many nonzero on row 0 and on column 0 */
      int ecn[2], erem[2], eleft[2];
      for (int et = 0; et < 2; et++) {
        int a, l;
        if (et == 0) { a = haveA ? rcnt[(by - 1) * bw + bx] : 8; l = haveL ? rcnt[by * bw + bx - 1] : 8; }
        else { a = haveL ? ccnt[by * bw + bx - 1] : 8; l = haveA ? ccnt[(by - 1) * bw + bx] : 8; }
        int cb = et == 1 ? ecn[0] : 8, cnode = 1, cT = 0;
        if (ENC) for (int i = 1; i <= 7; i++) cT += (et == 0 ? b[T.unzig[i]] : b[T.unzig[i * 8]]) != 0;
        for (int i = 2; i >= 0; i--) {
          int bit = MIX4((cT >> i) & 1, m->wECnt + (et * 8 + cnode) * LANES, &m->ec1[((et * NZ_BUCKETS + nzB) * 9 + a) * 8 + cnode],
                         &m->ec2[((et * 9 + a) * 9 + l) * 8 + cnode],
                         &m->ec3[((et * 9 + cb) * PRED_BUCKETS + clip(nzB, PRED_BUCKETS - 1)) * 8 + cnode],
                         &m->ec1[((et * NZ_BUCKETS + nzB) * 9 + cb) * 8 + cnode]);
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
        int64_t predF = 0;
        if (u == 0 && haveA) {
          int64_t sum = 0; uint64_t mm = fm & (COL_INTERIOR << w);
          while (mm) { int pos = __builtin_ctzll(mm); mm &= mm - 1; sum += T.w3[pos >> 3] * fb[pos]; }
          predF = divroundr(w32(rowC[bx].eg[w] - sum), 724 * (int64_t)q[k], rq[k]);
          pb = clip(finelog(div8round(w32(5 * predF))), NO_PRED - 1);
        } else if (w == 0 && haveL) {
          int64_t sum = 0; uint64_t mm = fm & (ROW_INTERIOR << (u * 8));
          while (mm) { int pos = __builtin_ctzll(mm); mm &= mm - 1; sum += T.w3[pos & 7] * fb[pos]; }
          predF = divroundr(w32(leftC->eg[u] - sum), 724 * (int64_t)q[k], rq[k]);
          pb = clip(finelog(div8round(w32(5 * predF))), NO_PRED - 1);
        }
        int a = haveA ? iabs(coef[abase + k]) : 0, l = haveL ? iabs(coef[lbase + k]) : 0, mbN;
        if (haveA && haveL) mbN = clip(bitlen64(a + l), NO_NEIGHBOUR - 1);
        else if (haveA || haveL) mbN = clip(bitlen64(2 * (a + l)), NO_NEIGHBOUR - 1);
        else mbN = NO_NEIGHBOUR;
        int prevB = ep >= 2 ? clip(bitlen64(u == 0 ? b[T.unzig[w - 1]] : b[T.unzig[(u - 1) * 8]]), 7) : 7;
        int ib = u == 0 ? clip(finelog(b[T.unzig[8 + w]]), 11) : clip(finelog(b[T.unzig[u * 8 + 1]]), 11);
        int bit, v = ENC ? b[k] : 0, vT = bitlen64(v);
        if (erem[et] >= eleft[et]) bit = 1;
        else bit = MIX5(v != 0, m->wEZero + ep * LANES, &m->ezero5[(ep * 12 + ib) * 4 + clip(pb, 3)],
                        &m->ezero1[ep * PRED_BUCKETS + pb],
                        &m->ez6[((ep * 8 + erem[et]) * 8 + eleft[et]) * 4 + clip(pb, 3)],
                        &m->ezero3[(ep * 8 + prevB) * PRED_BUCKETS + pb],
                        &m->ezero4[ep * MAG_BUCKETS + mbN]);
        eleft[et]--;
        if (bit) {
          erem[et]--;
          int i = 1;
          while (i < MAX_EXP_AC) {
            if (!MIX5(vT > i, m->wEExpo + ((i - 1) * EDGE_POS + ep) * LANES, &m->eexpo5[(ep * 12 + ib) * MAX_EXP_AC + i - 1],
                      &m->eexpo1[(ep * PRED_BUCKETS + pb) * MAX_EXP_AC + i - 1],
                      &m->eexpo2[(ep * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                      &m->eexpo3[(pb * 8 + prevB) * MAX_EXP_AC + i - 1],
                      &m->eexpo4[(ep * NZ_BUCKETS + nzB) * MAX_EXP_AC + i - 1])) break;
            i++;
          }
          int x = FN(mantissa)(dc, &m->emant1[i * PRED_BUCKETS + pb], m->mant, MAX_EXP_AC, i, iabs(v));
          int sg = pb == NO_PRED ? 1 : sgn3(predF);
          int neg = FN(one)(dc, &m->esign[((ep & 1) * 3 + sg) * PRED_BUCKETS + pb], v < 0);
          if (!ENC) b[k] = (int16_t)(neg ? -x : x);
        }
      }
      zm = nzmask(b) & T.edgeZz;
      while (zm) { int k = __builtin_ctzll(zm); zm &= zm - 1; int pos = T.zzTable[k]; fb[pos] = dequant(b[k], q[k]); fm |= 1ull << pos; }
      /* 4. the DC, from up to 16 boundary estimates */
      int64_t pc[8], pr[8], ests[16], lo = 0, hi = 0, total = 0, pred;
      for (int i = 0; i < 8; i++) pc[i] = pr[i] = 0;
      sumkernels(fb, fm, KL, pc); sumkernels(fb, fm, KT, pr);
      int nest = 0;
      if (haveL) for (int i = 0; i < 8; i++) ests[nest++] = w32(leftC->px[i] - pc[i]) / 4;
      if (haveA) for (int i = 0; i < 8; i++) ests[nest++] = w32(rowC[bx].px[i] - pr[i]) / 4;
      if (nest == 16) { split16(ests); lo = min64(min64(ests[0], ests[1]), min64(ests[2], ests[3])); hi = max64(max64(ests[12], ests[13]), max64(ests[14], ests[15])); }
      else if (nest == 8) { split8(ests); lo = min64(ests[0], ests[1]); hi = max64(ests[6], ests[7]); }
      for (int i = nest / 4; i <= nest - 1 - nest / 4; i++) total += ests[i];
      total = w32(total);
      if (nest > 0) nest -= 2 * (nest / 4);
      int dctx;
      if (nest > 0) {
        if (nest == 8) pred = divroundr(total, dc8, rc8);
        else if (nest == 4) pred = divroundr(total, dc4, rc4);
        else pred = divround(total, (int64_t)nest * dq0);
        dctx = clip(finelog(divroundr(w32(hi - lo), dq0, rq0)), ACT_BUCKETS - 2);
      } else { pred = 0; dctx = ACT_BUCKETS - 1; }
      if (pred > 32767) pred = 32767;
      if (pred < -32767) pred = -32767;
      int rb2 = 0, nbs = 0;
      if (haveA) { rb2 += dcr[(by - 1) * bw + bx]; nbs++; }
      if (haveL) { rb2 += dcr[by * bw + bx - 1]; nbs++; }
      rb2 = clip(rb2, 19);
      int res = 0, rT = ENC ? (int)(b[0] - pred) : 0, rE = bitlen64(rT);
      if (MIX4(rT != 0, m->wDcZero + dctx * LANES, &m->dcZero[dctx], &m->dz2[rb2], &m->dz3[nzB * 8 + dctx / 3], &m->dz4[dctx * 3 + nbs])) {
        int i = 1;
        while (i < MAX_EXP_DC) {
          if (!MIX4(rE > i, m->wDcExpo + (i - 1) * LANES, &m->dcExpo[dctx * MAX_EXP_DC + i - 1], &m->dx2[rb2 * MAX_EXP_DC + i - 1],
                    &m->dx3[(nzB * 8 + dctx / 3) * MAX_EXP_DC + i - 1], &m->dx4[(dctx * 3 + nbs) * MAX_EXP_DC + i - 1])) break;
          i++;
        }
        int x = FN(mantissa)(dc, &m->dcMant1[i * ACT_BUCKETS + dctx], m->dcMant, MAX_EXP_DC, i, iabs(rT));
        res = FN(one)(dc, &m->dcSign[dctx], rT < 0) ? -x : x;
      }
      dcr[by * bw + bx] = (uint8_t)clip(finelog(res), 15);
      if (!ENC) {
        int64_t xdc = pred + res;
        if (xdc < -32767 || xdc > 32767) { ok = 0; break; }
        b[0] = (int16_t)xdc;
      }
      fb[0] = dequant(b[0], q[0]);
      fillcaches(fb, fm | 1, rightC, &rowC[bx]);
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

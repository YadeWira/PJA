{ The body of the coefficient routine, written once and compiled three
  times by pjamodel with these macros:
    CC_NAME  the routine's name
    CC_FAST  the fast model (a constant True, or m.fast)
    CC_ENC   encoding (a constant True or False, or cd.encoding)
    CC_AVG   two counters averaged: CodeAvg, or the fused EncAvg / DecAvg
    CC_ONE   one counter: CodeOne, or the fused EncOne / DecOne
  A constant condition lets FPC drop the branches that cannot run, and the
  fused routines skip the coder's layers; every variant codes the same bits
  (the codec suite demands identical streams). }
function CC_NAME(var cd: TCoder; var cp: TComponent; const qt: array of Word; var m: TCoefModel;
                       const lumaNz: array of Byte; lumaW, sx, sy: SizeInt; y0, y1: SizeInt;
                       out nzOut: TByteArr): Boolean;
var bx, by, k, n, nzA, nzL, ctx, node, bit, rem, v, a, l, base, abase, lbase, pos, u, w, idx: SizeInt;
    nzc, dcr: array of Byte; haveA, haveL: Boolean; rb2, nbs: Integer; res, x, e, i, ep: Integer;
    nb, ib, mbN, mbI, mbS, kb, rb, za, zb, pb, prevB, nzB, sg, lz: Integer;
    q: array[0..63] of Integer; rq: array[0..63] of Double; dq0, dc4, dc8: Int64; rq0, rc4, rc8: Double; sum, predF, pred, lo, hi, total, f: Int64; nest: Integer;
    pc, pr: TLanes; ests: TEstimates; i2: Integer; tmp: Int64;
    fb: TBlockF; fm, mm, zm, zm0: QWord; leftC: TEdgeCache; rowC: array of TEdgeCache; rightC: TEdgeCache;
begin
  for k := 0 to 63 do begin
    q[k] := 1;
    if (k < Length(qt)) and (qt[k] > 0) then q[k] := qt[k];
    rq[k] := 1 / (2 * Int64(BASIS[0, 0]) * q[k]);
  end;
  { the DC's divisors: the spread's, and the mean's of 4 or 8 estimates }
  dq0 := Int64(BASIS[0, 0]) * BASIS[0, 0] * q[0]; rq0 := 1 / dq0;
  dc4 := 4 * dq0; rc4 := 1 / dc4; dc8 := 8 * dq0; rc8 := 1 / dc8;
  FillChar(fb, SizeOf(fb), 0);
  zm0 := 0; mbI := 0;
  rowC := nil; SetLength(rowC, cp.bw);
  leftC := Default(TEdgeCache);
  nzc := nil; SetLength(nzc, cp.bw * cp.bh);
  nzOut := nil;
  dcr := nil; SetLength(dcr, cp.bw * cp.bh);
  for by := y0 to y1 - 1 do
    for bx := 0 to cp.bw - 1 do begin
      base := (by * cp.bw + bx) * 64;
      haveA := by > y0; haveL := bx > 0;
      abase := base - cp.bw * 64; lbase := base - 64;
      if not haveA then abase := base;
      if not haveL then lbase := base;

      { 1. how many interior (7x7) coefficients are nonzero, as a 6-bit tree }
      n := 0;
      if CC_ENC then begin zm0 := NonzeroMask(@cp.coef[base]); n := Ones(zm0 and INTERIOR_ZZ); end;
      if haveA then nzA := nzc[(by - 1) * cp.bw + bx] else nzA := 0;
      if haveL then nzL := nzc[by * cp.bw + bx - 1] else nzL := 0;
      if haveA and haveL then ctx := NzBucket((nzA + nzL + 1) div 2)
      else if haveA then ctx := NzBucket(nzA)
      else if haveL then ctx := NzBucket(nzL)
      else ctx := 0;
      if haveA then za := NzBucket(nzA) else za := 0;
      if haveL then zb := NzBucket(nzL) else zb := 0;
      { the luma block at the same spot; NZ_BUCKETS = there is none }
      if Length(lumaNz) > 0 then lz := NzBucket(lumaNz[(by * sy) * lumaW + bx * sx]) else lz := NZ_BUCKETS;
      {$ifdef PJA_COSTS}CostKind := ckNz;{$endif}
      node := 1;
      for k := 5 downto 0 do begin
        if CC_FAST then begin
          if m.chroma then bit := CC_ONE(cd, m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node], (n shr k) and 1)
          else bit := CC_ONE(cd, m.nz2[(za * NZ_BUCKETS + zb) * 64 + node], (n shr k) and 1);
        end else begin
          m.mxNz.Add(m.nz1[ctx * 64 + node].p);
          m.mxNz.Add(m.nz2[(za * NZ_BUCKETS + zb) * 64 + node].p);
          m.mxNz.Add(m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node].p);
          m.mxNz.Add(32768 + 8192);
          bit := cd.CodeP(m.mxNz.Mix(5 - k), (n shr k) and 1);
          m.mxNz.Update(bit);
          m.nz1[ctx * 64 + node].Update(bit, COUNTER_LIMIT);
          m.nz2[(za * NZ_BUCKETS + zb) * 64 + node].Update(bit, COUNTER_LIMIT);
          m.nz3[(lz * NZ_BUCKETS + ctx) * 64 + node].Update(bit, COUNTER_LIMIT);
        end;
        node := node * 2 + bit;
      end;
      n := node - 64;
      if n > 49 then Exit(False);   { only possible decoding garbage }
      nzc[by * cp.bw + bx] := n;
      nzB := NzBucket(n);

      { 2. the interior in zigzag, while nonzeros are left }
      rem := n;
      idx := 0;
      while (rem > 0) and (idx <= 48) do begin
        k := INTERIOR[idx];
        nb := NeighbourMag(cp, base, bx, by - y0, k);
        { the interior neighbours in this block, already coded: (u-1, v) and
          (u, v-1); row 0 and column 0 come later }
        { both when there are both, twice the one there is; none for (1, 1):
          from tables per position, without a branch }
        ib := IB_WA[idx] * Abs(cp.coef[base + IB_NA[idx]]) + IB_WB[idx] * Abs(cp.coef[base + IB_NB[idx]]);
        if not CC_FAST then
          if IB_NONE[idx] then mbI := NO_NEIGHBOUR else mbI := Clip(FineLog(ib), NO_NEIGHBOUR - 1);
        if nb < 0 then begin mbN := NO_NEIGHBOUR; mbS := Clip(FineLog(2 * ib), NO_NEIGHBOUR - 1); end
        else begin mbN := Clip(FineLog(nb), NO_NEIGHBOUR - 1); mbS := Clip(FineLog(nb + ib), NO_NEIGHBOUR - 1); end;
        kb := K_BUCKET_OF[k]; rb := RemBucket(rem);
        if CC_ENC then v := cp.coef[base + k] else v := 0;
        {$ifdef PJA_COSTS}CostKind := ckZero;{$endif}
        { when every interior position left must be nonzero, nothing to code }
        if rem >= INTERIOR_LEFT[idx] then bit := 1
        else if CC_FAST then begin
          if m.chroma then bit := CC_AVG(cd, m.fz[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN],
                                          m.zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb], Ord(v <> 0))
          else bit := CC_AVG(cd, m.fz[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbS],
                              m.zero1[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN], Ord(v <> 0));
        end else
          bit := CodeMix5(cd, m.mxZero, k, m.zero5[(k * (NZ_BUCKETS + 1) + lz) * REM_BUCKETS + rb],
                         m.zero1[(k * REM_BUCKETS + rb) * MAG_BUCKETS + mbN],
                         m.zero2[(k * MAG_BUCKETS + mbI) * 4 + Clip(mbN, 3)],
                         m.zero3[k * RATIO_BUCKETS + RATIO_OF[INTERIOR_LEFT[idx], rem]],
                         m.zero4[(kb * MAG_BUCKETS + mbS) * REM_BUCKETS + rb],
                         Ord(v <> 0));
        if bit = 1 then begin
          x := Abs(v);
          {$ifdef PJA_COSTS}CostKind := ckExpo;{$endif}
          if CC_ENC then e := BitLen(x) else e := 0;
          i := 1;
          while i < MAX_EXP_AC do begin
            if CC_FAST then begin
              if CC_AVG(cd, m.fx[((kb * REM_BUCKETS + rb) * MAG_BUCKETS + mbS) * MAX_EXP_AC + i - 1],
                         m.expo1[(kb * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1], Ord(e > i)) = 0 then Break;
            end else
            if CodeMix(cd, m.mxExpo, (i - 1) * K_BUCKETS + kb,
                       m.expo1[(kb * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                       m.expo2[(kb * MAG_BUCKETS + mbI) * MAX_EXP_AC + i - 1],
                       m.expo3[(kb * REM_BUCKETS + rb) * MAX_EXP_AC + i - 1],
                       m.expo4[mbS * MAX_EXP_AC + i - 1],
                       Ord(e > i)) = 0 then Break;
            Inc(i);
          end;
          {$ifdef PJA_COSTS}CostKind := ckMant;{$endif}
          CodeMantissa(cd, m.mant1, kb, K_BUCKETS, m.mant, MAX_EXP_AC, i, x);
          {$ifdef PJA_COSTS}CostKind := ckSign;{$endif}
          if haveA then ctx := Sgn3(cp.coef[abase + k]) else ctx := 1;
          if haveL then ctx := ctx * 3 + Sgn3(cp.coef[lbase + k]) else ctx := ctx * 3 + 1;
          bit := CC_ONE(cd, m.sign[kb * 9 + ctx], Ord(v < 0));
          if not CC_ENC then
            if bit = 1 then cp.coef[base + k] := -x else cp.coef[base + k] := x;
          Dec(rem);
        end;
        Inc(idx);
      end;
      if rem > 0 then Exit(False);   { only possible decoding garbage }

      { this block dequantized: the interior now, row 0 and column 0 as they
        are coded, the DC last }
      { fm marks the nonzero positions of fb, so that the loops below only
        visit those; fb is zero everywhere else (cleared once, then after
        each block where it was written) }
      fm := 0;
      { exactly the n nonzero interior coefficients: decoding checked that
        n were coded }
      { encoding, the block has not changed since it was counted }
      if CC_ENC then zm := zm0 and INTERIOR_ZZ else zm := NonzeroMask(@cp.coef[base]) and INTERIOR_ZZ;
      while zm <> 0 do begin
        k := BsfQWord(zm); zm := zm and (zm - 1);
        fb[ZIGZAG[k]] := Dequant(cp.coef[base + k], q[k]);
        fm := fm or (QWord(1) shl ZIGZAG[k]);
      end;

      { 3. row 0 and column 0, interleaved by frequency, each predicted from
        the neighbour across its edge: the pixels have to continue across
        the boundary, which in 1D DCT terms fixes the one unknown term. }
      for ep := 0 to EDGE_POS - 1 do begin
        if ep and 1 = 0 then begin u := 0; w := ep div 2 + 1; end   { row 0, from above }
        else begin u := ep div 2 + 1; w := 0; end;                     { column 0, from the left }
        k := UNZIG[u * 8 + w];
        pb := NO_PRED; predF := 0;
        { the boundary, extrapolated half a pixel from both sides, has to meet:
          3*E7 - E6 of the neighbour against 3*E0 - E1 of this block, where
          only this coefficient is unknown (E0 and E1 weigh it the same) }
        if (u = 0) and haveA then begin
          sum := 0;
          mm := fm and (COL_INTERIOR shl w);
          while mm <> 0 do begin
            pos := BsfQWord(mm); mm := mm and (mm - 1);
            sum := sum + W3[pos shr 3] * fb[pos];
          end;
          predF := DivRoundR(rowC[bx].eg[w] - sum, 2 * Int64(BASIS[0, 0]) * q[k], rq[k]);
          tmp := DivRound(5 * predF, 8);
          pb := Clip(FineLog(tmp), NO_PRED - 1);
        end else if (w = 0) and haveL then begin
          sum := 0;
          mm := fm and (ROW_INTERIOR shl (u * 8));
          while mm <> 0 do begin
            pos := BsfQWord(mm); mm := mm and (mm - 1);
            sum := sum + W3[pos and 7] * fb[pos];
          end;
          predF := DivRoundR(leftC.eg[u] - sum, 2 * Int64(BASIS[0, 0]) * q[k], rq[k]);
          tmp := DivRound(5 * predF, 8);
          pb := Clip(FineLog(tmp), NO_PRED - 1);
        end;
        { the neighbours' same coefficient: only the full model's counters
          use it }
        if CC_FAST then mbN := NO_NEIGHBOUR
        else begin
          a := 0; l := 0;
          if haveA then a := Abs(cp.coef[abase + k]);
          if haveL then l := Abs(cp.coef[lbase + k]);
          if haveA and haveL then mbN := Clip(BitLen(a + l), NO_NEIGHBOUR - 1)
          else if haveA or haveL then mbN := Clip(BitLen(2 * (a + l)), NO_NEIGHBOUR - 1)
          else mbN := NO_NEIGHBOUR;
        end;
        { the previous coefficient along this same edge }
        if ep >= 2 then begin
          if u = 0 then prevB := Clip(BitLen(cp.coef[base + UNZIG[w - 1]]), 7)
          else prevB := Clip(BitLen(cp.coef[base + UNZIG[(u - 1) * 8]]), 7);
        end else prevB := 7;
        { the interior coefficient next to it, already coded }
        if u = 0 then ib := Clip(FineLog(cp.coef[base + UNZIG[8 + w]]), 11)
        else ib := Clip(FineLog(cp.coef[base + UNZIG[u * 8 + 1]]), 11);
        if CC_ENC then v := cp.coef[base + k] else v := 0;
        {$ifdef PJA_COSTS}CostKind := ckEZero;{$endif}
        if CC_FAST then
          bit := CC_AVG(cd, m.fez[((ep * NZ_BUCKETS + nzB) * 8 + prevB) * PRED_BUCKETS + pb],
                         m.ezero5[(ep * 12 + ib) * 4 + Clip(pb, 3)], Ord(v <> 0))
        else
        bit := CodeMix5(cd, m.mxEZero, ep, m.ezero5[(ep * 12 + ib) * 4 + Clip(pb, 3)],
                       m.ezero1[ep * PRED_BUCKETS + pb],
                       m.ezero2[ep * NZ_BUCKETS + nzB],
                       m.ezero3[(ep * 8 + prevB) * PRED_BUCKETS + pb],
                       m.ezero4[ep * MAG_BUCKETS + mbN],
                       Ord(v <> 0));
        if bit = 1 then begin
          x := Abs(v);
          {$ifdef PJA_COSTS}CostKind := ckEExpo;{$endif}
          if CC_ENC then e := BitLen(x) else e := 0;
          i := 1;
          while i < MAX_EXP_AC do begin
            if CC_FAST then begin
              if m.chroma then
                ctx := ((ep * PRED_BUCKETS + pb) * NZ_BUCKETS + nzB) * 8 * MAX_EXP_AC + i - 1
              else
                ctx := (((ep * NZ_BUCKETS + nzB) * PRED_BUCKETS + pb) * 8 + prevB) * MAX_EXP_AC + i - 1;
              if CC_AVG(cd, m.fex[ctx], m.eexpo5[(ep * 12 + ib) * MAX_EXP_AC + i - 1], Ord(e > i)) = 0 then Break;
            end else
            if CodeMix5(cd, m.mxEExpo, (i - 1) * EDGE_POS + ep, m.eexpo5[(ep * 12 + ib) * MAX_EXP_AC + i - 1],
                       m.eexpo1[(ep * PRED_BUCKETS + pb) * MAX_EXP_AC + i - 1],
                       m.eexpo2[(ep * MAG_BUCKETS + mbN) * MAX_EXP_AC + i - 1],
                       m.eexpo3[(pb * 8 + prevB) * MAX_EXP_AC + i - 1],
                       m.eexpo4[(ep * NZ_BUCKETS + nzB) * MAX_EXP_AC + i - 1],
                       Ord(e > i)) = 0 then Break;
            Inc(i);
          end;
          {$ifdef PJA_COSTS}CostKind := ckEMant;{$endif}
          CodeMantissa(cd, m.emant1, pb, PRED_BUCKETS, m.mant, MAX_EXP_AC, i, x);
          {$ifdef PJA_COSTS}CostKind := ckESign;{$endif}
          if pb = NO_PRED then sg := 1 else sg := Sgn3(predF);
          bit := CC_ONE(cd, m.esign[((ep and 1) * 3 + sg) * PRED_BUCKETS + pb], Ord(v < 0));
          if not CC_ENC then
            if bit = 1 then cp.coef[base + k] := -x else cp.coef[base + k] := x;
        end;
      end;

      { the nonzero ones of row 0 and column 0, from the mask: no question
        per coefficient }
      if CC_ENC then zm := zm0 and EDGE_ZZ else zm := NonzeroMask(@cp.coef[base]) and EDGE_ZZ;
      while zm <> 0 do begin
        k := BsfQWord(zm); zm := zm and (zm - 1);
        pos := ZIGZAG[k];
        fb[pos] := Dequant(cp.coef[base + k], q[k]);
        fm := fm or (QWord(1) shl pos);
      end;

      { 4. the DC, estimated pixel by pixel along both edges (Lepton's idea):
        each boundary pixel, extrapolated with its gradient from the
        neighbour and from this block (whose AC is all known now), says what
        the DC must be. The mean of up to 16 estimates is the prediction,
        and their spread the context. }
      { this block's boundary without its DC, extrapolated the same way:
        5*P0 - P1, per column (left edge) and per row (top edge) }
      { linear in the coefficients, like FillCaches:
          pc[i] = sum over u of B[u,i] * (sum over w of W5[w] fb[u,w])
          pr[i] = sum over w of B[w,i] * (sum over u of W5[u] fb[u,w]) }
      for i := 0 to 7 do begin pc[i] := 0; pr[i] := 0; end;
      SumKernels(fb, fm, KER_LEFT, pc);
      SumKernels(fb, fm, KER_TOP, pr);
      nest := 0; total := 0; lo := 0; hi := 0;
      if haveL then begin
        for i := 0 to 7 do begin
          ests[nest] := (leftC.px[i] - pc[i]) div 4; Inc(nest);
        end;
      end;
      if haveA then begin
        for i := 0 to 7 do begin
          ests[nest] := (rowC[bx].px[i] - pr[i]) div 4; Inc(nest);
        end;
      end;
      { the middle half of the sorted estimates; the split leaves the
        smallest and the largest at the ends, where their extremes are taken
        without a branch }
      if nest = 16 then begin
        Split16(ests);
        lo := Min64(Min64(ests[0], ests[1]), Min64(ests[2], ests[3]));
        hi := Max64(Max64(ests[12], ests[13]), Max64(ests[14], ests[15]));
      end else if nest = 8 then begin
        Split8(ests);
        lo := Min64(ests[0], ests[1]);
        hi := Max64(ests[6], ests[7]);
      end;
      total := 0;
      for i := nest div 4 to nest - 1 - nest div 4 do total := total + ests[i];
      if nest > 0 then nest := nest - 2 * (nest div 4);
      { a pixel gets DC * BASIS[0,0]^2: back to a quantized DC }
      if nest > 0 then begin
        if nest = 8 then pred := DivRoundR(total, dc8, rc8)
        else if nest = 4 then pred := DivRoundR(total, dc4, rc4)
        else pred := DivRound(total, Int64(nest) * dq0);
        tmp := DivRoundR(hi - lo, dq0, rq0);
        ctx := Clip(FineLog(tmp), ACT_BUCKETS - 2);
      end else begin pred := 0; ctx := ACT_BUCKETS - 1; end;
      if pred > 32767 then pred := 32767;
      if pred < -32767 then pred := -32767;
      {$ifdef PJA_COSTS}CostKind := ckDc;{$endif}
      if CC_ENC then res := cp.coef[base] - Integer(pred) else res := 0;
      { the neighbours' DC residuals, and how many neighbours there are }
      rb2 := 0; nbs := 0;
      if haveA then begin Inc(rb2, dcr[(by - 1) * cp.bw + bx]); Inc(nbs); end;
      if haveL then begin Inc(rb2, dcr[by * cp.bw + bx - 1]); Inc(nbs); end;
      rb2 := Clip(rb2, 19);
      if CC_FAST then
        bit := CC_ONE(cd, m.fdz[(rb2 * ACT_BUCKETS + ctx) * 3 + nbs], Ord(res <> 0))
      else
      bit := CodeMix(cd, m.mxDcZero, ctx, m.dcZero[ctx], m.dz2[rb2], m.dz3[nzB * 8 + ctx div 3],
                     m.dz4[ctx * 3 + nbs], Ord(res <> 0));
      if bit = 1 then begin
        x := Abs(res);
        if CC_ENC then e := BitLen(x) else e := 0;
        i := 1;
        while i < MAX_EXP_DC do begin
          if CC_FAST then begin
            if CC_ONE(cd, m.fdx[(ctx * 3 + nbs) * MAX_EXP_DC + i - 1], Ord(e > i)) = 0 then Break;
          end else
          if CodeMix(cd, m.mxDcExpo, i - 1, m.dcExpo[ctx * MAX_EXP_DC + i - 1], m.dx2[rb2 * MAX_EXP_DC + i - 1],
                     m.dx3[(nzB * 8 + ctx div 3) * MAX_EXP_DC + i - 1],
                     m.dx4[(ctx * 3 + nbs) * MAX_EXP_DC + i - 1], Ord(e > i)) = 0 then Break;
          Inc(i);
        end;
        CodeMantissa(cd, m.dcMant1, ctx, ACT_BUCKETS, m.dcMant, MAX_EXP_DC, i, x);
        bit := CC_ONE(cd, m.dcSign[ctx], Ord(res < 0));
        if bit = 1 then res := -x else res := x;
      end;
      dcr[by * cp.bw + bx] := Clip(FineLog(res), 15);
      if not CC_ENC then begin
        x := Integer(pred) + res;
        if (x < -32767) or (x > 32767) then Exit(False);
        cp.coef[base] := x;
      end;
      fb[0] := Dequant(cp.coef[base], q[0]);
      FillCaches(fb, fm or 1, rightC, rowC[bx]);
      mm := fm or 1;
      while mm <> 0 do begin fb[BsfQWord(mm)] := 0; mm := mm and (mm - 1); end;
      leftC := rightC;
    end;
  nzOut := nzc;
  Result := True;
end;

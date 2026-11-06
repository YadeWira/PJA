/* JPEG 2000 tier-1's tables and neighbourhood helpers, shared by
   pjaj2kt1.c (the decoder, the replay and the MQ coder) and pjaj2kmc.c
   (stream version 8's model, which walks the same passes). Static: each
   object has its own copy, and neither takes memory nor calls a library. */
#ifndef PJAJ2KT1_H
#define PJAJ2KT1_H
#include <stdint.h>

/* a coefficient's flags */
#define SIG 1
#define NEG 2
#define PIV 4
#define REF 8

/* Each coefficient has its own flags (st) and a mask of which of its eight
   neighbours are significant (nb), kept up to date as they become so. */
#define NW_ 1
#define N_ 2
#define NE_ 4
#define W_ 8
#define E_ 16
#define SW_ 32
#define S_ 64
#define SE_ 128
/* the neighbours below a stripe's last row, which CAUSAL leaves out */
#define SOUTH (SW_ | S_ | SE_)

/* the zero coding context by orientation (0 LL, 1 HL: horizontally
   high-pass, 2 LH, 3 HH) and neighbour mask, table D.1 */
static const uint8_t ZC[4][256] = {
{
  0,1,3,3,1,2,3,3,5,6,7,7,6,6,7,7,5,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  1,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  1,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  2,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8},
{
  0,1,5,6,1,2,6,6,3,3,7,7,3,3,7,7,3,3,7,7,3,3,7,7,4,4,7,7,4,4,7,7,
  1,2,6,6,2,2,6,6,3,3,7,7,3,3,7,7,3,3,7,7,3,3,7,7,4,4,7,7,4,4,7,7,
  5,6,8,8,6,6,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,
  6,6,8,8,6,6,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,
  1,2,6,6,2,2,6,6,3,3,7,7,3,3,7,7,3,3,7,7,3,3,7,7,4,4,7,7,4,4,7,7,
  2,2,6,6,2,2,6,6,3,3,7,7,3,3,7,7,3,3,7,7,3,3,7,7,4,4,7,7,4,4,7,7,
  6,6,8,8,6,6,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,
  6,6,8,8,6,6,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8,7,7,8,8},
{
  0,1,3,3,1,2,3,3,5,6,7,7,6,6,7,7,5,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  1,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  1,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  2,2,3,3,2,2,3,3,6,6,7,7,6,6,7,7,6,6,7,7,6,6,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,
  3,3,4,4,3,3,4,4,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8},
{
  0,3,1,4,3,6,4,7,1,4,2,5,4,7,5,7,1,4,2,5,4,7,5,7,2,5,2,5,5,7,5,7,
  3,6,4,7,6,8,7,8,4,7,5,7,7,8,7,8,4,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,
  1,4,2,5,4,7,5,7,2,5,2,5,5,7,5,7,2,5,2,5,5,7,5,7,2,5,2,5,5,7,5,7,
  4,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,
  3,6,4,7,6,8,7,8,4,7,5,7,7,8,7,8,4,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,
  6,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8,
  4,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,5,7,5,7,7,8,7,8,
  7,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8,7,8,7,8,8,8,8,8}};

static inline int sgn(uint8_t f) { return (f & SIG) ? ((f & NEG) ? -1 : 1) : 0; }
/* the sign coding context, and the prediction's xor (table D.3) */
static inline int sc_ctx(const uint8_t *st, int i, int stride, int excl, int *xr)
{
  int hc = sgn(st[i - 1]) + sgn(st[i + 1]);
  int vc = sgn(st[i - stride]) + (excl ? 0 : sgn(st[i + stride]));
  hc = hc > 1 ? 1 : hc < -1 ? -1 : hc;
  vc = vc > 1 ? 1 : vc < -1 ? -1 : vc;
  /* the contributions taken with hc >= 0 (and vc >= 0 when hc is 0), the xor
     1 when they had to be negated */
  if (hc < 0 || (hc == 0 && vc < 0)) { *xr = 1; hc = -hc; vc = -vc; } else *xr = 0;
  if (hc == 0) return 9 + (vc != 0);
  return 12 + vc;
}

static inline void make_sig(uint8_t *st, uint8_t *nb, int i, int stride, int neg)
{
  st[i] |= SIG | (neg ? NEG : 0);
  nb[i - stride - 1] |= SE_; nb[i - stride] |= S_; nb[i - stride + 1] |= SW_;
  nb[i - 1] |= E_; nb[i + 1] |= W_;
  nb[i + stride - 1] |= NE_; nb[i + stride] |= N_; nb[i + stride + 1] |= NW_;
}

#endif

/* libpja's test, in C against pja.h, the way an archiver uses it:

     test_lib FILE...

   Each file through pja_compress and pja_decompress (a file PJA does not
   take must say so, and nothing else may fail); then every file put
   together into one stream with bytes around them, through the filter in
   read sizes of 1 byte to 1 MiB, and back: the same bytes, every time. A
   damaged filter stream must give an error or other bytes, never a crash.
   And the first Huffman JPEG cut in two as FlashPix keeps its tiles: a JPEG
   of its tables only, and the JPEG without them, before and after it; the
   filter must take those (smaller than with the tables broken) and give
   them back.
   Prints a line per check and "N checks, 0 failures" at the end. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pja.h"

static int checks, failures;
static void check(int ok, const char *what, const char *name) {
  checks++;
  if (!ok) { failures++; printf("  FAIL  %s %s\n", what, name); }
}

typedef struct { const unsigned char *d; size_t n, p, step; } src_t;
typedef struct { unsigned char *d; size_t n, cap; } dst_t;

static ptrdiff_t rd(void *ctx, void *buf, size_t size) {
  src_t *s = ctx;
  size_t k = s->n - s->p;
  if (k > size) k = size;
  if (k > s->step) k = s->step;
  memcpy(buf, s->d + s->p, k);
  s->p += k;
  return (ptrdiff_t)k;
}
static int wr(void *ctx, const void *buf, size_t size) {
  dst_t *d = ctx;
  if (d->n + size > d->cap) {
    d->cap = (d->n + size) * 2 + 4096;
    d->d = realloc(d->d, d->cap);
    if (!d->d) return -1;
  }
  memcpy(d->d + d->n, buf, size);
  d->n += size;
  return 0;
}

static unsigned char *slurp(const char *name, size_t *n) {
  FILE *f = fopen(name, "rb");
  if (!f) return 0;
  fseek(f, 0, SEEK_END);
  long k = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *d = malloc(k > 0 ? (size_t)k : 1);
  *n = fread(d, 1, (size_t)k, f);
  fclose(f);
  return d;
}

/* d[0..n), a Huffman JPEG: its DQT and DHT segments as a JPEG of tables
   only (*t, *tn) and the rest as a JPEG without them (*a, *an); 0 if it
   has no DHT before its first scan */
static int split_tables(const unsigned char *d, size_t n, unsigned char **t, size_t *tn,
                        unsigned char **a, size_t *an) {
  if (n < 4 || d[0] != 0xFF || d[1] != 0xD8) return 0;
  *t = malloc(n + 4); *a = malloc(n);
  size_t i = 2, ti = 2, ai = 2;
  int dht = 0;
  (*t)[0] = (*a)[0] = 0xFF; (*t)[1] = (*a)[1] = 0xD8;
  while (i + 4 <= n && d[i] == 0xFF && d[i + 1] != 0xDA) {
    unsigned char m = d[i + 1];
    size_t len = 2 + ((size_t)d[i + 2] << 8 | d[i + 3]);
    if (i + len > n || (m >= 0xC9 && m <= 0xCF && m != 0xCC)) break;   /* arithmetic: none */
    if (m == 0xDB || m == 0xC4) { memcpy(*t + ti, d + i, len); ti += len; dht |= m == 0xC4; }
    else { memcpy(*a + ai, d + i, len); ai += len; }
    i += len;
  }
  if (!dht || i + 4 > n || d[i + 1] != 0xDA) { free(*t); free(*a); return 0; }
  memcpy(*a + ai, d + i, n - i); ai += n - i;
  (*t)[ti++] = 0xFF; (*t)[ti++] = 0xD9;
  *tn = ti; *an = ai;
  return 1;
}

/* JPEGs without tables, as FlashPix keeps them: one before its JPEG of
   tables, one after; the filter, both versions, against the same stream
   with that JPEG of tables broken */
static void abbreviated(const char *name) {
  size_t n, tn, an;
  unsigned char *d = slurp(name, &n), *t, *a;
  if (!d || !split_tables(d, n, &t, &tn, &a, &an)) { free(d); return; }
  size_t cn = 0;
  unsigned char *c = malloc(3 * 100 + tn + 2 * an);
  memset(c, 0x11, 100); cn += 100;
  memcpy(c + cn, a, an); cn += an;
  memset(c + cn, 0x22, 100); cn += 100;
  size_t at = cn;
  memcpy(c + cn, t, tn); cn += tn;
  memset(c + cn, 0x33, 100); cn += 100;
  memcpy(c + cn, a, an); cn += an;
  size_t sizes[2][2];
  for (int broken = 0; broken < 2; broken++) {
    c[at + 1] = broken ? 0x00 : 0xD8;
    for (int v = 1; v <= 2; v++) {
      src_t in = {c, cn, 0, 4096};
      dst_t e = {0}, eb = {0}, back = {0};
      int r = v == 1 ? pja_filter_encode(rd, &in, wr, &e, 2) : pja_filter2_encode(rd, &in, wr, &e, wr, &eb, 2);
      check(r == PJA_OK, "abbreviated: filter encode", name);
      src_t ia = {e.d, e.n, 0, 4096}, ib = {eb.d, eb.n, 0, 4096};
      r = v == 1 ? pja_filter_decode(rd, &ia, wr, &back, 2) : pja_filter2_decode(rd, &ia, rd, &ib, wr, &back, 2);
      check(r == PJA_OK && back.n == cn && memcmp(back.d, c, cn) == 0, "abbreviated: filter round trip", name);
      sizes[broken][v - 1] = e.n + eb.n;
      free(e.d); free(eb.d); free(back.d);
    }
  }
  /* smaller even with the 02 record's copy of the tables, which the
     archiver's compressor finds next to the JPEG of tables itself */
  check(sizes[0][0] < sizes[1][0] && sizes[0][1] < sizes[1][1], "abbreviated: taken", name);
  printf("abbreviated JPEGs (%s): %zu bytes -> %zu, %zu + B; with the tables broken %zu, %zu\n",
         name, cn, sizes[0][0], sizes[0][1], sizes[1][0], sizes[1][1]);
  free(c); free(t); free(a); free(d);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);   /* every line out at once, even if a check hangs */
  printf("%s\n", pja_version());
  unsigned char *all = 0;
  size_t alln = 0, taken = 0, insum = 0, outsum = 0;
  unsigned seed = 1;
  for (int a = 1; a < argc; a++) {
    size_t n;
    unsigned char *d = slurp(argv[a], &n);
    if (!d) { check(0, "read", argv[a]); continue; }
    void *p = 0, *back = 0;
    size_t pn = 0, bn = 0;
    int r = pja_compress(d, n, &p, &pn, 2);
    check(r == PJA_OK || r == PJA_E_NOT_TAKEN, "compress", argv[a]);
    if (r == PJA_OK) {
      taken++; insum += n; outsum += pn;
      r = pja_decompress(p, pn, &back, &bn, 0, 2);
      check(r == PJA_OK && bn == n && memcmp(back, d, n) == 0, "decompress", argv[a]);
      pja_free(back);
      if (pn > 40) {                               /* one flipped byte: caught */
        ((unsigned char *)p)[pn / 2] ^= 0x55;
        back = 0;
        r = pja_decompress(p, pn, &back, &bn, 0, 1);
        check(r != PJA_OK, "damaged .pja refused", argv[a]);
        pja_free(back);
      }
    }
    pja_free(p);
    /* the stream: some bytes, the file, more */
    size_t junk = (seed = seed * 1103515245u + 12345u) % 3000;
    all = realloc(all, alln + junk + n + 3);
    for (size_t k = 0; k < junk; k++) all[alln++] = (unsigned char)((seed >> (k % 24)) ^ k);
    all[alln++] = 0xFF; all[alln++] = 0xD8; all[alln++] = 0xFF;   /* a false start */
    memcpy(all + alln, d, n); alln += n;
    free(d);
  }
  printf("%zu of %d files taken: %zu -> %zu bytes as .pja\n", taken, argc - 1, insum, outsum);
  for (int a = 1, done = 0; a < argc && !done; a++) {
    size_t n, tn, an;
    unsigned char *d = slurp(argv[a], &n), *t, *ab;
    if (d && split_tables(d, n, &t, &tn, &ab, &an)) { free(t); free(ab); abbreviated(argv[a]); done = 1; }
    free(d);
  }
  static const size_t steps[] = {1 << 20, 4096, 1000, 7, 1};
  dst_t enc = {0};
  for (unsigned s = 0; s < sizeof steps / sizeof steps[0]; s++) {
    if (steps[s] < 1000 && alln > (8u << 20)) continue;   /* byte by byte only on small sets */
    src_t in = {all, alln, 0, steps[s]};
    dst_t e = {0}, b = {0};
    int r = pja_filter_encode(rd, &in, wr, &e, 4);
    check(r == PJA_OK, "filter encode", "");
    src_t in2 = {e.d, e.n, 0, steps[s]};
    r = pja_filter_decode(rd, &in2, wr, &b, 4);
    check(r == PJA_OK && b.n == alln && memcmp(b.d, all, alln) == 0, "filter round trip", "");
    printf("filter, reads of %zu: %zu -> %zu bytes, %s\n", steps[s], alln, e.n,
           r == PJA_OK && b.n == alln ? "back" : "NOT back");
    if (s == 0) enc = e; else free(e.d);
    free(b.d);
  }
  /* version 2: two streams; the stream twice over, so that the second
     copy's files come out as matches against the first's */
  {
    size_t n2 = 2 * alln;
    unsigned char *two = malloc(n2);
    memcpy(two, all, alln); memcpy(two + alln, all, alln);
    for (unsigned s = 0; s < 3; s++) {
      static const size_t st2[] = {1 << 20, 4096, 7};
      src_t in = {two, n2, 0, st2[s]};
      dst_t a = {0}, b = {0}, back = {0};
      int r = pja_filter2_encode(rd, &in, wr, &a, wr, &b, 4);
      check(r == PJA_OK, "filter2 encode", "");
      src_t ia = {a.d, a.n, 0, st2[s]}, ib = {b.d, b.n, 0, st2[s]};
      r = pja_filter2_decode(rd, &ia, rd, &ib, wr, &back, 4);
      check(r == PJA_OK && back.n == n2 && memcmp(back.d, two, n2) == 0, "filter2 round trip", "");
      check(b.n < enc.n, "filter2: the second copy deduplicated", "");
      printf("filter2, reads of %zu: %zu -> %zu + %zu bytes, %s\n", st2[s], n2, a.n, b.n,
             r == PJA_OK && back.n == n2 ? "back" : "NOT back");
      if (s == 0 && b.n > 20) {                   /* damaged B: an error or other bytes */
        int refused = 0;
        for (size_t k = 5; k < b.n; k += b.n / 100 + 1) {
          b.d[k] ^= 0x41;
          src_t ja = {a.d, a.n, 0, 1 << 20}, jb = {b.d, b.n, 0, 1 << 20};
          dst_t o2 = {0};
          refused += pja_filter2_decode(rd, &ja, rd, &jb, wr, &o2, 1) != PJA_OK;
          free(o2.d);
          b.d[k] ^= 0x41;
        }
        printf("damaged filter2 B streams: %d refused of about 100, no crash\n", refused);
      }
      free(a.d); free(b.d); free(back.d);
    }
    free(two);
  }
  /* damaged filter streams: about 300 bytes spread over the stream
     flipped, one at a time, and cut short at a few places */
  int bad = 0, same = 0;
  for (size_t k = 0; k < enc.n; k += enc.n / 300 + 1) {
    enc.d[k] ^= 0x41;
    src_t in = {enc.d, enc.n, 0, 1 << 20};
    dst_t b = {0};
    int r = pja_filter_decode(rd, &in, wr, &b, 1);
    if (r != PJA_OK) bad++;
    else same += b.n == alln && memcmp(b.d, all, alln) == 0;
    free(b.d);
    enc.d[k] ^= 0x41;
  }
  for (size_t cut = 0; cut < enc.n; cut += enc.n / 7 + 1) {
    src_t in = {enc.d, cut, 0, 1 << 20};
    dst_t b = {0};
    check(pja_filter_decode(rd, &in, wr, &b, 1) != PJA_OK, "cut filter stream refused", "");
    free(b.d);
  }
  printf("damaged filter streams: %d refused, %d decoded the same, the rest other bytes, no crash\n",
         bad, same);
  free(enc.d);
  free(all);
  printf("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}

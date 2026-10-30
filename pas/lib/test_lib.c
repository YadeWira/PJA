/* libpja's test, in C against pja.h, the way an archiver uses it:

     test_lib FILE...

   Each file through pja_compress and pja_decompress (a file PJA does not
   take must say so, and nothing else may fail); then every file put
   together into one stream with bytes around them, through the filter in
   read sizes of 1 byte to 1 MiB, and back: the same bytes, every time. A
   damaged filter stream must give an error or other bytes, never a crash.
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

int main(int argc, char **argv) {
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

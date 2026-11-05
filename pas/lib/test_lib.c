/* libpja's test, in C against pja.h, the way an archiver uses it:

     test_lib FILE...

   Each file through pja_compress and pja_decompress (a file PJA does not
   take must say so, and nothing else may fail); then every file put
   together into one stream with bytes around them, through the filter in
   read sizes of 1 byte to 1 MiB, and back: the same bytes, every time. A
   damaged filter stream must give an error or other bytes, never a crash.
   And color_plasma.jpg (cjpeg -optimize: its own tables, not the standard
   ones) cut in two as FlashPix keeps its tiles: a JPEG of its tables only, and
   the JPEG without them, before and after it; the filter must take those
   (smaller than with the tables broken) and give them back. And
   baseline_444.jpg (cjpeg's standard tables) without any, alone and after
   a JPEG of color_plasma.jpg's tables (another file's, which do not fit
   it): the filter must take it with the standard tables both times and
   give it back. A lossless JPEG (no DQT, and none needed) must be taken as
   it is, in a 01 record, smaller than it was. And version 2 with B's write
   failing must stop there with PJA_E_WRITE, not read the rest. And what a
   newer PJA would write (a .pja, a codec stream, a filter version or
   record) must give PJA_E_VERSION.
   Prints a line per check and "N checks, 0 failures" at the end. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
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

/* a JPEG written with cjpeg's standard tables, without them: with no JPEG
   of tables anywhere, or after one of another file's (other) tables, the
   filter gives it the standard ones */
static void standard_tables(const char *name, const char *other) {
  size_t n, tn, an, on = 0, otn = 0, oan;
  unsigned char *d = slurp(name, &n), *t, *a, *od = other ? slurp(other, &on) : 0, *ot = 0, *oa = 0;
  if (!d || !split_tables(d, n, &t, &tn, &a, &an)) { free(d); free(od); return; }
  if (od && !split_tables(od, on, &ot, &otn, &oa, &oan)) otn = 0;
  unsigned char *c = malloc(200 + otn + an);
  size_t cn = 0;
  memset(c, 0x44, 100); cn += 100;
  if (otn) { memcpy(c + cn, ot, otn); cn += otn; }
  memcpy(c + cn, a, an); cn += an;
  memset(c + cn, 0x55, 100); cn += 100;
  src_t in = {c, cn, 0, 4096};
  dst_t e = {0}, back = {0};
  int r = pja_filter_encode(rd, &in, wr, &e, 2);
  src_t ie = {e.d, e.n, 0, 4096};
  if (r == PJA_OK) r = pja_filter_decode(rd, &ie, wr, &back, 2);
  check(r == PJA_OK && back.n == cn && memcmp(back.d, c, cn) == 0, "standard tables: round trip", name);
  /* taken: a 03 record in the stream (one JPEG of 2 KB does not pay the
     02 record's 570 bytes of tables, which an archive pays once) */
  int t3 = 0;
  for (size_t i = 5; i < e.n && e.d[i] != 0xFF; ) {
    unsigned char tag = e.d[i++];
    uint64_t v[2] = {0, 0};
    for (int k = 0; k < (tag == 0x01 || tag == 0x03 ? 2 : 1); k++)
      for (int sh = 0; i < e.n; sh += 7) { v[k] |= (uint64_t)(e.d[i] & 0x7F) << sh; if (!(e.d[i++] & 0x80)) break; }
    t3 += tag == 0x03;
    i += (size_t)(tag == 0x01 || tag == 0x03 ? v[1] : v[0]);
  }
  check(t3 == 1, "standard tables: taken", name);
  printf("a JPEG without tables (%s)%s, the standard ones given: %zu bytes -> %zu\n", name,
         otn ? ", after another file's tables" : "", cn, e.n);
  free(e.d); free(back.d); free(c); free(t); free(a); free(d); free(od); free(ot); free(oa);
}

/* a lossless JPEG (SOF3): no DQT, and none needed; taken as it is, a 01
   record, not given tables it has no use for */
static void lossless(const char *name) {
  size_t n;
  unsigned char *d = slurp(name, &n);
  if (!d) return;
  src_t in = {d, n, 0, 4096};
  dst_t e = {0}, back = {0};
  int r = pja_filter_encode(rd, &in, wr, &e, 2);
  src_t ie = {e.d, e.n, 0, 4096};
  if (r == PJA_OK) r = pja_filter_decode(rd, &ie, wr, &back, 2);
  check(r == PJA_OK && back.n == n && memcmp(back.d, d, n) == 0, "lossless: round trip", name);
  check(e.n > 5 && e.d[5] == 0x01 && e.n < n, "lossless: taken without tables", name);
  printf("a lossless JPEG (%s): %zu bytes -> %zu\n", name, n, e.n);
  free(e.d); free(back.d); free(d);
}

/* version 2, B's write failing after its magic: PJA_E_WRITE, and the
   input not read to its end */
static int b_calls;
static int wr_b_fails(void *ctx, const void *buf, size_t size) {
  return ++b_calls > 1 ? -1 : wr(ctx, buf, size);
}
static void b_failure(const unsigned char *all, size_t alln) {
  src_t in = {all, alln, 0, 4096};
  dst_t a = {0}, b = {0};
  b_calls = 0;
  int r = pja_filter2_encode(rd, &in, wr, &a, wr_b_fails, &b, 1);
  check(r == PJA_E_WRITE && in.p < in.n, "filter2: stops when B fails", "");
  printf("filter2 with B failing: %d, %zu of %zu bytes read\n", r, in.p, in.n);
  free(a.d); free(b.d);
}

/* a filter stream (A, and B for version 2) through the decoder: its result */
static int filter_result(const unsigned char *a, size_t an, const unsigned char *b, size_t bn) {
  src_t ia = {a, an, 0, 4096}, ib = {b, bn, 0, 4096};
  dst_t o = {0};
  int r = b ? pja_filter2_decode(rd, &ia, rd, &ib, wr, &o, 1) : pja_filter_decode(rd, &ia, wr, &o, 1);
  free(o.d);
  return r;
}

/* what a newer PJA wrote: PJA_E_VERSION, never PJA_E_DATA nor a crash. A
   .pja (its version, its codec stream's first byte from 9 to 255), the
   filter's versions and its records 04 to FE, a file record whose codec
   stream is of a later version. pja is a .pja of a JPEG, not stored, with
   no extension (pja_compress's): its codec stream from byte 37 */
static void versions(const unsigned char *pja, size_t pn) {
  unsigned char *p = malloc(pn);
  void *back = 0;
  size_t bn = 0;
  int bad = 0;
  memcpy(p, pja, pn);
  p[4] = 5;
  check(pja_decompress(p, pn, &back, &bn, 0, 1) == PJA_E_VERSION, "a .pja of version 5: PJA_E_VERSION", "");
  pja_free(back); back = 0;
  memcpy(p, pja, pn);
  for (int v = 9; v < 256; v++) {
    p[37] = (unsigned char)v;
    bad += pja_decompress(p, pn, &back, &bn, 0, 1) != PJA_E_VERSION;
    pja_free(back); back = 0;
  }
  check(bad == 0, "codec stream versions 9 to 255 in a .pja: PJA_E_VERSION", "");
  p[37] = 4;
  check(pja_decompress(p, pn, &back, &bn, 0, 1) == PJA_E_DATA, "codec stream version 4: PJA_E_DATA", "");
  pja_free(back);
  free(p);
  static const unsigned char f3[] = {'P', 'J', 'A', 'F', 3, 0xFF}, f1end[] = {'P', 'J', 'A', 'F', 1, 0xFF},
    f1cut[] = {'P', 'J', 'A', 'F', 1}, f2[] = {'P', 'J', 'A', 'F', 2, 0xFF},
    b1[] = {'P', 'J', 'A', 'B', 1}, b2[] = {'P', 'J', 'A', 'B', 2};
  check(filter_result(f3, sizeof f3, 0, 0) == PJA_E_VERSION, "filter version 3: PJA_E_VERSION", "");
  check(filter_result(f1end, sizeof f1end, 0, 0) == PJA_OK, "filter version 1, empty", "");
  check(filter_result(f1cut, sizeof f1cut, 0, 0) == PJA_E_DATA, "filter version 1 cut short: PJA_E_DATA", "");
  check(filter_result(f2, sizeof f2, 0, 0) == PJA_E_DATA, "version 2 to filter_decode: PJA_E_DATA", "");
  check(filter_result(f1end, sizeof f1end, b1, sizeof b1) == PJA_E_DATA, "version 1 to filter2_decode: PJA_E_DATA", "");
  check(filter_result(f2, sizeof f2, b1, sizeof b1) == PJA_OK, "filter version 2, empty", "");
  check(filter_result(f3, sizeof f3, b1, sizeof b1) == PJA_E_VERSION, "filter2, A of version 3: PJA_E_VERSION", "");
  check(filter_result(f2, sizeof f2, b2, sizeof b2) == PJA_E_VERSION, "filter2, B of version 2: PJA_E_VERSION", "");
  bad = 0;
  for (int t = 0x04; t < 0xFF; t++) {
    /* a raw record first, then the unknown one */
    unsigned char s1[] = {'P', 'J', 'A', 'F', 1, 0x00, 0x01, 'x', (unsigned char)t, 0x01, 0x01, 0xFF};
    unsigned char s2[] = {'P', 'J', 'A', 'F', 2, 0x00, 0x01, 'x', (unsigned char)t, 0x01, 0x01, 0xFF};
    bad += filter_result(s1, sizeof s1, 0, 0) != PJA_E_VERSION;
    bad += filter_result(s2, sizeof s2, b1, sizeof b1) != PJA_E_VERSION;
  }
  check(bad == 0, "filter records 04 to FE: PJA_E_VERSION, both versions", "");
  bad = 0;
  for (int v = 9; v < 256; v++) {
    /* a file of 100 bytes whose codec stream (10 bytes) is version v */
    unsigned char s1[] = {'P', 'J', 'A', 'F', 1, 0x01, 100, 10, (unsigned char)v, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF};
    bad += filter_result(s1, sizeof s1, 0, 0) != PJA_E_VERSION;
  }
  check(bad == 0, "a filter record whose codec stream is version 9 to 255: PJA_E_VERSION", "");
  printf("what a newer PJA wrote: PJA_E_VERSION (.pja, codec stream, filter version and records)\n");
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);   /* every line out at once, even if a check hangs */
  printf("%s\n", pja_version());
  unsigned char *all = 0;
  size_t alln = 0, taken = 0, insum = 0, outsum = 0;
  unsigned seed = 1;
  int versioned = 0;
  for (int a = 1; a < argc; a++) {
    size_t n;
    unsigned char *d = slurp(argv[a], &n);
    if (!d) { check(0, "read", argv[a]); continue; }
    void *p = 0, *back = 0;
    size_t pn = 0, bn = 0;
    int r = pja_compress(d, n, &p, &pn, 2);
    check(r == PJA_OK || r == PJA_E_NOT_TAKEN, "compress", argv[a]);
    if (r == PJA_OK && !versioned && pn > 40 && n > 4 && d[0] == 0xFF && d[1] == 0xD8 && !(((unsigned char *)p)[5] & 1)) {
      versions(p, pn);
      versioned = 1;
    }
    if (r == PJA_OK) {
      void *p2 = 0;                                /* again, on the models the call parked */
      size_t pn2 = 0;
      check(pja_compress(d, n, &p2, &pn2, 1) == PJA_OK && pn2 == pn && memcmp(p2, p, pn) == 0,
            "the same bytes again", argv[a]);
      pja_free(p2);
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
  check(versioned, "a JPEG for the version checks", "");
  {                                                /* null pointers: an error, not a crash */
    static const unsigned char some[4] = {0xFF, 0xD8, 0xFF, 0xD9};
    void *p = 0;
    size_t pn = 0;
    check(pja_compress(some, 4, NULL, &pn, 1) == PJA_E_ARG, "compress, null out", "");
    check(pja_compress(some, 4, &p, NULL, 1) == PJA_E_ARG, "compress, null out_size", "");
    check(pja_decompress(some, 4, NULL, &pn, 0, 1) == PJA_E_ARG, "decompress, null out", "");
    check(pja_decompress(some, 4, &p, NULL, 0, 1) == PJA_E_ARG, "decompress, null out_size", "");
    check(pja_filter_encode(NULL, NULL, NULL, NULL, 1) == PJA_E_ARG, "filter, null functions", "");
    check(pja_filter2_decode(NULL, NULL, NULL, NULL, NULL, NULL, 1) == PJA_E_ARG,
          "filter2, null functions", "");
  }
  {
    const char *plasma = 0, *b444 = 0;
    for (int a = 1; a < argc; a++) {
      if (strstr(argv[a], "color_plasma.jpg")) plasma = argv[a];
      if (strstr(argv[a], "baseline_444.jpg")) b444 = argv[a];
      if (strstr(argv[a], "dnl_lossless.jpg") || strstr(argv[a], "lossless_restart.jpg")) lossless(argv[a]);
    }
    if (plasma) abbreviated(plasma);
    if (b444) { standard_tables(b444, 0); if (plasma) standard_tables(b444, plasma); }
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
  b_failure(all, alln);
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

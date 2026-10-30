/* libpja's filter (pja.h: pja_filter_encode and pja_filter_decode, through pjalib.pas): the JPEG
   and JPEG-LS files inside a stream of any bytes, recompressed by PJA; every
   other byte passed through as it was, for the archiver's own compressor.

   The filter's stream (doc/LIBRARY.md):

     "PJAF" 01                     magic and version
     records, each a tag byte:
       00 n bytes                  n raw bytes (n a LEB128 number, >= 1)
       01 size n stream            a file of `size` bytes, as PJA's codec
                                   stream of n bytes (pjacodec.Compress)
       FF                          the end

   The encoder finds a file by its first bytes (FF D8 FF), then walks its
   markers to the EOI: segment lengths, and after each SOS the entropy-coded
   bytes up to the next marker (JPEG: FF 00 and the RSTs are data; JPEG-LS,
   after an SOF55: FF and a byte under 80). A file whose markers do not add
   up, that PJA does not take, that does not come back byte for byte (the
   codec verifies) or that does not get smaller stays raw. So does anything
   past MAX_FILE.

   Like pjav7c.c, this file calls no library: the host (pjalib.pas) gives it
   memory and PJA's codec through pjafilter_host. */
#include <stddef.h>
#include <stdint.h>

#define PJA_OK 0
#define PJA_E_DATA 2
#define PJA_E_MEMORY 3
#define PJA_E_READ 4
#define PJA_E_WRITE 5
#define PJA_E_ARG 6

#if defined(_WIN32) && !defined(_WIN64)
#define PJA_CALL __cdecl
#else
#define PJA_CALL
#endif

typedef ptrdiff_t (PJA_CALL *pja_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PJA_CALL *pja_write_fn)(void *ctx, const void *buf, size_t size);

/* what pjalib.pas gives: memory, and a pool of threads that runs PJA's
   codec on one file at a time each. A job is submitted, runs when a thread
   is free, and is waited for, in any order. Then ok is set and, when ok,
   out (from alloc) and out_size: encoding, PJA's codec stream of the file
   (ok = 0 when PJA does not take it); decoding, the file, which must be
   `expected` bytes. threads: how many threads the file's bands may use. */
typedef struct {
  const uint8_t *in;
  size_t size, expected;
  uint8_t *out;
  size_t out_size;
  int ok, threads;
  volatile int done;  /* set by the pool */
} job_t;
typedef struct {
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  void *(*pool_open)(int threads, int encode);
  void (*pool_submit)(void *pool, job_t *job);
  void (*pool_wait)(void *pool, job_t *job);
  void (*pool_close)(void *pool);
} host_t;

static host_t H;

void pjafilter_host(const host_t *h) { H = *h; }

enum {
  MAX_FILE = 256 << 20,         /* the largest file recompressed; past it, raw */
  WINDOW = 1 << 20,             /* the encoder's first buffer */
  RAW_RUN = 1 << 18,            /* the longest raw record */
  AHEAD_BYTES = 64 << 20,       /* the files' bytes in the pool at most */
  IOBUF = 1 << 16,              /* the decoder's read buffer */
  TAG_RAW = 0x00, TAG_FILE = 0x01, TAG_END = 0xFF
};
static const uint8_t MAGIC[5] = {'P', 'J', 'A', 'F', 1};

static void copy(uint8_t *d, const uint8_t *s, size_t n) {
  while (n--) *d++ = *s++;
}
static void move_down(uint8_t *d, const uint8_t *s, size_t n) {  /* d < s */
  while (n--) *d++ = *s++;
}

/* ---------- where a JPEG or JPEG-LS file ends ---------- */

enum { EXT_NOT = 0, EXT_MORE = -1 };

/* p[0..n): a file that starts with FF D8. Its length up to and with its
   EOI, EXT_MORE if n bytes are not enough to tell, EXT_NOT if its markers
   do not add up. */
static ptrdiff_t jpeg_extent(const uint8_t *p, size_t n) {
  size_t i = 2;
  int ls = 0, frames = 0, scans = 0;
  for (;;) {
    if (i + 2 > n) return EXT_MORE;
    if (p[i] != 0xFF) return EXT_NOT;
    while (p[i + 1] == 0xFF) {                    /* fill bytes */
      if (++i + 2 > n) return EXT_MORE;
    }
    uint8_t m = p[i + 1];
    i += 2;
    if (m == 0xD9) return (frames && scans) ? (ptrdiff_t)i : EXT_NOT;
    if (m == 0x00 || m == 0xD8) return EXT_NOT;
    if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue;
    if (i + 2 > n) return EXT_MORE;
    size_t len = ((size_t)p[i] << 8) | p[i + 1];
    if (len < 2) return EXT_NOT;
    if ((m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) || m == 0xF7) {
      frames++;
      if (m == 0xF7) ls = 1;
    }
    i += len;
    if (i > MAX_FILE) return EXT_NOT;
    if (m != 0xDA) continue;
    if (!frames) return EXT_NOT;
    scans++;
    /* the entropy-coded bytes, up to the next marker */
    for (;;) {
      while (i < n && p[i] != 0xFF) i++;
      if (i + 2 > n) return i > MAX_FILE ? EXT_NOT : EXT_MORE;
      uint8_t b = p[i + 1];
      if (ls ? b < 0x80 : (b == 0x00 || (b >= 0xD0 && b <= 0xD7))) { i += 2; continue; }
      if (b == 0xFF && !ls) { i++; continue; }     /* a fill byte before a marker */
      break;
    }
  }
}

/* ---------- writing ---------- */

typedef struct {
  pja_write_fn write;
  void *ctx;
  int err;
} out_t;

static void put(out_t *o, const void *b, size_t n) {
  if (o->err || !n) return;
  if (o->write(o->ctx, b, n) != 0) o->err = PJA_E_WRITE;
}
static void put_num(out_t *o, uint64_t v) {
  uint8_t b[10];
  int k = 0;
  do { b[k] = (uint8_t)(v & 0x7F); v >>= 7; if (v) b[k] |= 0x80; k++; } while (v);
  put(o, b, (size_t)k);
}
static void put_raw(out_t *o, const uint8_t *b, size_t n) {
  if (!n) return;
  uint8_t t = TAG_RAW;
  put(o, &t, 1); put_num(o, n); put(o, b, n);
}

/* ---------- version 2: two streams, PJA's data deduplicated ---------- */

/* Version 2 writes two streams, for an archiver that can store them apart
   (7-Zip's coders with several outputs): A holds the records and the raw
   bytes, for the archiver's compressor; B holds the files' codec streams,
   which no compressor makes smaller, so they skip it. What a compressor
   would still find in B, the same coefficients in several files (one image
   saved more than once), is taken out here: each stream is coded against
   the streams before it as literal runs and long matches.

     B: "PJAB" 01, then for each file, in A's order, until its n bytes:
          L, L literal bytes, [M, D]...   L, M, D: LEB128 numbers
        a match copies M bytes (>= MIN_MATCH) from D bytes back in the
        streams so far (they may overlap what it writes)

   The history is every file's stream since the start, or since it was
   reset: when the next one would take it past MAX_HISTORY, it starts
   again empty, on both sides. Matches are found through a hash of
   MIN_MATCH bytes at every position, against a table of the history's
   positions every STRIDE bytes, so any repeat of MIN_MATCH + STRIDE bytes
   or more is found. */
enum {
  MIN_MATCH = 32, STRIDE = 8, TAB_BITS = 20,
  MAX_HISTORY = 128 << 20
};
static const uint8_t MAGIC2[5] = {'P', 'J', 'A', 'F', 2};
static const uint8_t MAGIC_B[5] = {'P', 'J', 'A', 'B', 1};
#define HMUL 0x9E3779B1u

typedef struct {
  uint8_t *hist;
  size_t hn, cap;
  uint32_t *tab;     /* a history position + 1, 0 when empty */
  uint32_t pow;      /* HMUL^MIN_MATCH */
  int err;
} dedup_t;

static uint32_t hash_at(const uint8_t *p) {
  uint32_t h = 0;
  for (int k = 0; k < MIN_MATCH; k++) h = h * HMUL + p[k];
  return h;
}
static uint32_t slot(uint32_t h) { return h >> (32 - TAB_BITS); }

static int dedup_init(dedup_t *d, int encoder) {
  d->hist = 0; d->hn = d->cap = 0; d->err = 0; d->tab = 0;
  d->pow = 1;
  for (int k = 0; k < MIN_MATCH; k++) d->pow *= HMUL;
  if (encoder) {
    d->tab = H.alloc(sizeof(uint32_t) << TAB_BITS);
    if (!d->tab) return 0;
    for (size_t k = 0; k < ((size_t)1 << TAB_BITS); k++) d->tab[k] = 0;
  }
  return 1;
}
static void dedup_free(dedup_t *d) {
  if (d->hist) H.release(d->hist);
  if (d->tab) H.release(d->tab);
}
/* room for n more bytes of history; reset when it would pass MAX_HISTORY */
static int dedup_room(dedup_t *d, size_t n) {
  if (d->hn + n > MAX_HISTORY) {
    d->hn = 0;
    if (d->tab) for (size_t k = 0; k < ((size_t)1 << TAB_BITS); k++) d->tab[k] = 0;
  }
  if (d->hn + n <= d->cap) return 1;
  size_t c = d->cap ? d->cap : (1 << 20);
  while (c < d->hn + n) c *= 2;
  uint8_t *b = H.alloc(c);
  if (!b) { d->err = PJA_E_MEMORY; return 0; }
  copy(b, d->hist, d->hn);
  if (d->hist) H.release(d->hist);
  d->hist = b; d->cap = c;
  return 1;
}

/* a file's codec stream b[0..n), coded against the history into B, then
   added to the history */
static void dedup_put(dedup_t *d, out_t *ob, const uint8_t *b, size_t n) {
  if (!dedup_room(d, n)) return;
  const uint8_t *hist = d->hist;
  size_t base = d->hn, lit = 0, i = 0;
  uint32_t h = n >= MIN_MATCH ? hash_at(b) : 0;
  while (i + MIN_MATCH <= n) {
    uint32_t c = d->tab[slot(h)];
    if (c) {
      size_t cand = c - 1, len = 0;
      while (len < MIN_MATCH && cand + len < base && hist[cand + len] == b[i + len]) len++;
      if (len == MIN_MATCH) {
        while (i + len < n && cand + len < base && hist[cand + len] == b[i + len]) len++;
        size_t j = i;
        while (j > lit && cand > 0 && hist[cand - 1] == b[j - 1]) { j--; cand--; len++; }
        put_num(ob, j - lit); put(ob, b + lit, j - lit);
        put_num(ob, len); put_num(ob, base + j - cand);
        i = j + len; lit = i;
        if (i + MIN_MATCH <= n) h = hash_at(b + i);
        continue;
      }
    }
    if (i + MIN_MATCH < n) h = h * HMUL + b[i + MIN_MATCH] - d->pow * b[i];
    i++;
  }
  if (lit < n || n == 0) { put_num(ob, n - lit); put(ob, b + lit, n - lit); }
  /* into the history, and its positions into the table */
  copy(d->hist + base, b, n);
  d->hn = base + n;
  if (n >= MIN_MATCH) {
    uint32_t g = hash_at(b);
    for (size_t p = 0; p + MIN_MATCH <= n; p++) {
      if (((base + p) & (STRIDE - 1)) == 0) d->tab[slot(g)] = (uint32_t)(base + p + 1);
      if (p + MIN_MATCH < n) g = g * HMUL + b[p + MIN_MATCH] - d->pow * b[p];
    }
  }
}

/* ---------- the encoder ---------- */

/* Files go to the pool as they are found, up to 8 per thread (or
   AHEAD_BYTES) ahead of the oldest, which is written as soon as it is done,
   with the raw bytes before it; so reading, compressing and writing
   overlap. What is written does not depend on any of this (nor on how the
   bytes were read): raw bytes go out in records of RAW_RUN bytes counted
   from the end of the last file written, the rest of a run just before the
   next file. */

typedef struct {
  pja_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t cap, have;
  int eof, err;
  /* buf[rs..): not written yet; files in the pool, oldest first: a ring of
     np from first, their place in buf in at[] */
  size_t rs;
  job_t *files;
  size_t *at;
  int first, np, maxp;
  size_t pbytes;
  void *pool;
  int threads;
  out_t *ob;         /* version 2: stream B, and its history */
  dedup_t *dd;
} in_t;

/* more bytes. When the buffer is full, what is before rs (written already)
   makes room, and every position kept moves with it (*x, the files); if it
   is still full, the buffer doubles. */
static void fill(in_t *s, size_t *x) {
  if (s->have == s->cap && s->rs) {
    size_t d = s->rs;
    move_down(s->buf, s->buf + d, s->have - d);
    s->have -= d; *x -= d; s->rs = 0;
    for (int k = 0; k < s->np; k++) s->at[(s->first + k) % s->maxp] -= d;
  }
  if (s->have == s->cap) {
    size_t c = s->cap * 2;
    uint8_t *b = H.alloc(c);
    if (!b) { s->err = PJA_E_MEMORY; return; }
    copy(b, s->buf, s->have);
    H.release(s->buf);
    s->buf = b; s->cap = c;
  }
  ptrdiff_t got = s->read(s->ctx, s->buf + s->have, s->cap - s->have);
  if (got < 0) s->err = PJA_E_READ;
  else if (got == 0) s->eof = 1;
  else s->have += (size_t)got;
}

/* raw bytes up to `to`: whole RAW_RUN records only, unless `all` */
static void raw_upto(in_t *s, out_t *o, size_t to, int all) {
  while (to - s->rs >= RAW_RUN) { put_raw(o, s->buf + s->rs, RAW_RUN); s->rs += RAW_RUN; }
  if (all) { put_raw(o, s->buf + s->rs, to - s->rs); s->rs = to; }
}

/* the file buf[c..c+len) to the pool, as a copy (the buffer moves) */
static void submit(in_t *s, size_t c, size_t len) {
  int k = (s->first + s->np) % s->maxp;
  job_t *f = &s->files[k];
  uint8_t *in = H.alloc(len);
  if (!in) { s->err = PJA_E_MEMORY; return; }
  copy(in, s->buf + c, len);
  f->in = in; f->size = len; f->expected = 0; f->out = 0; f->out_size = 0; f->ok = 0; f->done = 0;
  /* a file alone gets the threads for its bands; more files share them */
  f->threads = s->threads / (s->np + 1);
  if (f->threads < 1) f->threads = 1;
  s->at[k] = c;
  s->np++; s->pbytes += len;
  H.pool_submit(s->pool, f);
}

/* the oldest file in the pool, waited for and written with the raw bytes
   before it; one PJA did not take, or that did not get smaller, stays in
   the raw run around it */
static void retire(in_t *s, out_t *o) {
  int k = s->first;
  job_t *f = &s->files[k];
  H.pool_wait(s->pool, f);
  if (f->ok && f->out_size + 12 < f->size && !s->err) {
    raw_upto(s, o, s->at[k], 1);
    uint8_t t = TAG_FILE;
    put(o, &t, 1); put_num(o, f->size); put_num(o, f->out_size);
    if (s->ob) dedup_put(s->dd, s->ob, f->out, f->out_size);
    else put(o, f->out, f->out_size);
    s->rs = s->at[k] + f->size;
  }
  if (f->out) H.release(f->out);
  H.release((void *)f->in);
  s->first = (s->first + 1) % s->maxp;
  s->np--; s->pbytes -= f->size;
}

/* version 1 (write_b null) or 2 */
static int encode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                  pja_write_fn write_b, void *write_b_ctx, int threads) {
  if (!read || !write || !H.alloc) return PJA_E_ARG;
  if (threads < 1) threads = 1;
  in_t s = {0};
  s.read = read; s.ctx = read_ctx; s.cap = WINDOW;
  s.maxp = 8 * threads; s.threads = threads;
  out_t o = {write, write_ctx, 0}, ob = {write_b, write_b_ctx, 0};
  dedup_t dd;
  int ddok = dedup_init(&dd, write_b != 0);
  s.buf = H.alloc(s.cap);
  s.files = H.alloc(sizeof(job_t) * (size_t)s.maxp);
  s.at = H.alloc(sizeof(size_t) * (size_t)s.maxp);
  s.pool = H.pool_open(threads, 1);
  if (!ddok || !s.buf || !s.files || !s.at || !s.pool) s.err = PJA_E_MEMORY;
  if (write_b) {
    s.ob = &ob; s.dd = &dd;
    put(&o, MAGIC2, sizeof MAGIC2);
    put(&ob, MAGIC_B, sizeof MAGIC_B);
  } else
    put(&o, MAGIC, sizeof MAGIC);
  size_t pos = 0;                                 /* where the search goes on */
  while (!s.err && !o.err && !dd.err) {
    size_t c = pos;
    while (c + 3 <= s.have && !(s.buf[c] == 0xFF && s.buf[c + 1] == 0xD8 && s.buf[c + 2] == 0xFF)) c++;
    if (!s.np) raw_upto(&s, &o, c, 0);
    if (c + 3 > s.have) {                         /* no file starts in what is here */
      if (s.eof) {
        while (s.np) retire(&s, &o);
        raw_upto(&s, &o, s.have, 1);
        break;
      }
      pos = c;
      /* files in the pool while raw bytes pile up behind them: write them,
         so that the buffer does not grow with the raw bytes */
      if (s.np && s.have - s.rs >= AHEAD_BYTES) while (s.np) retire(&s, &o);
      fill(&s, &pos);
      continue;
    }
    ptrdiff_t len;
    for (;;) {
      len = jpeg_extent(s.buf + c, s.have - c);
      if (len != EXT_MORE || s.eof || s.err || s.have - c > MAX_FILE) break;
      fill(&s, &c);
    }
    if (s.err) break;
    if (len <= 0) { pos = c + 1; continue; }
    while (s.np && (s.np == s.maxp || s.pbytes + (size_t)len > AHEAD_BYTES)) retire(&s, &o);
    submit(&s, c, (size_t)len);
    pos = c + (size_t)len;
  }
  /* on an error, the files still in the pool are waited for and dropped */
  while (s.np) {
    job_t *f = &s.files[s.first];
    H.pool_wait(s.pool, f);
    if (f->out) H.release(f->out);
    H.release((void *)f->in);
    s.first = (s.first + 1) % s.maxp; s.np--;
  }
  if (!s.err && dd.err) s.err = dd.err;
  if (!s.err && !o.err) { uint8_t t = TAG_END; put(&o, &t, 1); }
  if (s.pool) H.pool_close(s.pool);
  if (s.buf) H.release(s.buf);
  if (s.files) H.release(s.files);
  if (s.at) H.release(s.at);
  dedup_free(&dd);
  return s.err ? s.err : o.err ? o.err : ob.err;
}

int pjafilter_encode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                     int threads) {
  return encode(read, read_ctx, write, write_ctx, 0, 0, threads);
}
int pjafilter2_encode(pja_read_fn read, void *read_ctx, pja_write_fn write_a, void *a_ctx,
                      pja_write_fn write_b, void *b_ctx, int threads) {
  if (!write_b) return PJA_E_ARG;
  return encode(read, read_ctx, write_a, a_ctx, write_b, b_ctx, threads);
}

/* ---------- the decoder ---------- */

typedef struct {
  pja_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t p, n;
  int err;
} rd_t;

static size_t rd(rd_t *r, uint8_t *d, size_t want) {
  size_t got = 0;
  while (got < want && !r->err) {
    if (r->p == r->n) {
      ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
      if (k < 0) { r->err = PJA_E_READ; break; }
      if (k == 0) break;
      r->p = 0; r->n = (size_t)k;
    }
    size_t k = r->n - r->p;
    if (k > want - got) k = want - got;
    copy(d + got, r->buf + r->p, k);
    r->p += k; got += k;
  }
  return got;
}
static int rd_byte(rd_t *r) {
  if (r->p == r->n) {
    if (r->err) return -1;
    ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
    if (k < 0) r->err = PJA_E_READ;
    if (k <= 0) return -1;
    r->p = 0; r->n = (size_t)k;
  }
  return r->buf[r->p++];
}
static int rd_num(rd_t *r, uint64_t *v) {
  *v = 0;
  for (int sh = 0; sh < 64; sh += 7) {
    int b = rd_byte(r);
    if (b < 0) return 0;
    *v |= (uint64_t)(b & 0x7F) << sh;
    if (!(b & 0x80)) return 1;
  }
  return 0;
}

/* The decoder works the same way: each file's stream goes to the pool as
   it is read, raw records wait in memory behind the files before them, and
   the oldest item is written as soon as it can be: up to 8 files per
   thread (or AHEAD_BYTES) ahead. */
typedef struct {
  int file;          /* 1: job holds a file in the pool; 0: raw bytes in job.in */
  job_t job;
} item_t;
typedef struct {
  item_t *items;     /* a ring of n from first */
  int first, n, max, files, maxf;
  size_t bytes;
  void *pool;
} queue_t;

static void drop(queue_t *q, item_t *it) {
  if (it->file) {
    H.pool_wait(q->pool, &it->job);
    if (it->job.out) H.release(it->job.out);
    q->files--;
  }
  H.release((void *)it->job.in);
  q->bytes -= it->file ? it->job.expected : it->job.size;
  q->first = (q->first + 1) % q->max; q->n--;
}

/* the oldest item written; PJA_E_DATA when its file did not come back */
static int retire_item(queue_t *q, out_t *o) {
  item_t *it = &q->items[q->first];
  int res = PJA_OK;
  if (!it->file) put(o, it->job.in, it->job.size);
  else {
    H.pool_wait(q->pool, &it->job);
    if (!it->job.ok || it->job.out_size != it->job.expected) res = PJA_E_DATA;
    else put(o, it->job.out, it->job.out_size);
  }
  drop(q, it);
  return res;
}

/* a file's codec stream of n bytes from B, through the history, into st */
static int dedup_get(dedup_t *d, rd_t *rb, uint8_t *st, size_t n) {
  if (!dedup_room(d, n)) return 0;
  uint8_t *w = d->hist + d->hn;
  size_t pos = 0;
  for (;;) {
    uint64_t l, m, dist;
    if (!rd_num(rb, &l) || l > n - pos || rd(rb, w + pos, (size_t)l) != l) return 0;
    pos += (size_t)l;
    if (pos == n) break;
    if (!rd_num(rb, &m) || !rd_num(rb, &dist) || m < MIN_MATCH || m > n - pos || !dist || dist > d->hn + pos)
      return 0;
    const uint8_t *src = w + pos - (size_t)dist;
    for (size_t k = 0; k < m; k++) w[pos + k] = src[k];    /* may overlap */
    pos += (size_t)m;
    if (pos == n) break;
  }
  copy(st, w, n);
  d->hn += n;
  return 1;
}

/* version 1 (read_b null) or 2 */
static int decode(pja_read_fn read, void *read_ctx, pja_read_fn read_b, void *read_b_ctx,
                  pja_write_fn write, void *write_ctx, int threads) {
  if (!read || !write || !H.alloc) return PJA_E_ARG;
  if (threads < 1) threads = 1;
  rd_t r = {read, read_ctx, 0, 0, 0, 0}, rb = {read_b, read_b_ctx, 0, 0, 0, 0};
  dedup_t dd;
  dedup_init(&dd, 0);
  out_t o = {write, write_ctx, 0};
  queue_t q = {0};
  q.maxf = 8 * threads; q.max = 2 * q.maxf + 2;
  r.buf = H.alloc(IOBUF);
  if (read_b) rb.buf = H.alloc(IOBUF);
  q.items = H.alloc(sizeof(item_t) * (size_t)q.max);
  q.pool = H.pool_open(threads, 0);
  int res = PJA_E_DATA;
  if (!r.buf || !q.items || !q.pool || (read_b && !rb.buf)) { res = PJA_E_MEMORY; goto done; }
  for (size_t k = 0; k < sizeof MAGIC; k++) if (rd_byte(&r) != (read_b ? MAGIC2 : MAGIC)[k]) goto done;
  if (read_b) for (size_t k = 0; k < sizeof MAGIC_B; k++) if (rd_byte(&rb) != MAGIC_B[k]) goto done;
  for (;;) {
    int t = rd_byte(&r);
    uint64_t n, size;
    if (t == TAG_END) {
      res = PJA_OK;
      while (q.n && res == PJA_OK && !o.err) res = retire_item(&q, &o);
      break;
    }
    /* room for one more item */
    int bad = 0;
    while (q.n && (q.n >= q.max - 1 || q.files >= q.maxf || q.bytes >= AHEAD_BYTES))
      if (retire_item(&q, &o) != PJA_OK) { bad = 1; break; }
    if (bad || o.err) break;
    item_t *it = &q.items[(q.first + q.n) % q.max];
    if (t == TAG_RAW) {
      if (!rd_num(&r, &n) || !n || n > RAW_RUN) break;
      uint8_t *b = H.alloc((size_t)n);
      if (!b) { res = PJA_E_MEMORY; break; }
      it->file = 0; it->job.in = b; it->job.size = (size_t)n; it->job.out = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, b, (size_t)n) != n) break;
    } else if (t == TAG_FILE) {
      if (!rd_num(&r, &size) || !rd_num(&r, &n) || !size || size > MAX_FILE || !n || n >= size) break;
      uint8_t *st = H.alloc((size_t)n);
      if (!st) { res = PJA_E_MEMORY; break; }
      it->file = 0; it->job.in = st; it->job.size = (size_t)n; it->job.expected = (size_t)size;
      it->job.out = 0; it->job.out_size = 0; it->job.ok = 0; it->job.done = 0;
      q.n++; q.bytes += (size_t)n;
      if (read_b ? !dedup_get(&dd, &rb, st, (size_t)n) : rd(&r, st, (size_t)n) != n) {
        if (dd.err) res = dd.err;
        break;
      }
      q.bytes += (size_t)size - (size_t)n;
      it->file = 1; q.files++;
      it->job.threads = threads / q.files; if (it->job.threads < 1) it->job.threads = 1;
      H.pool_submit(q.pool, &it->job);
    } else break;
  }
done:
  if (q.items) while (q.n) drop(&q, &q.items[q.first]);
  if (q.pool) H.pool_close(q.pool);
  if (q.items) H.release(q.items);
  if (r.buf) H.release(r.buf);
  if (rb.buf) H.release(rb.buf);
  dedup_free(&dd);
  if (r.err) return r.err;
  if (rb.err) return rb.err;
  if (o.err) return o.err;
  return res;
}

int pjafilter_decode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                     int threads) {
  return decode(read, read_ctx, 0, 0, write, write_ctx, threads);
}
int pjafilter2_decode(pja_read_fn read_a, void *a_ctx, pja_read_fn read_b, void *b_ctx,
                      pja_write_fn write, void *write_ctx, int threads) {
  if (!read_b) return PJA_E_ARG;
  return decode(read_a, a_ctx, read_b, b_ctx, write, write_ctx, threads);
}

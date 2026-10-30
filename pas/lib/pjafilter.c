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

/* what pjalib.pas gives: memory, and the codec on a batch of files, run on
   up to `threads` threads at once. For each job, run() sets ok and, when
   ok, out (from alloc) and out_size: encoding, PJA's codec stream of the
   file (ok = 0 when PJA does not take it); decoding, the file, which must
   be `expected` bytes. */
typedef struct {
  const uint8_t *in;
  size_t size, expected;
  uint8_t *out;
  size_t out_size;
  int ok;
} job_t;
typedef struct {
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  void (*run)(job_t *jobs, int n, int encode, int threads);
} host_t;

static host_t H;

void pjafilter_host(const host_t *h) { H = *h; }

enum {
  MAX_FILE = 256 << 20,         /* the largest file recompressed; past it, raw */
  WINDOW = 1 << 20,             /* the encoder's first buffer */
  RAW_RUN = 1 << 18,            /* the longest raw record */
  BATCH_BYTES = 64 << 20,       /* files gathered before a batch runs */
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

/* ---------- the encoder ---------- */

/* Files are gathered and compressed in batches, several at once; what is
   written does not depend on the batches (nor on how the bytes were read):
   raw bytes go out in records of RAW_RUN bytes counted from the end of the
   last file written, the rest of a run just before the next file. */

typedef struct {
  pja_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t cap, have;
  int eof, err;
  /* buf[rs..): not written yet; files[0..nf) found in it, in order */
  size_t rs;
  job_t *files;
  size_t *at;
  int nf, maxf;
  size_t fbytes;
} in_t;

/* more bytes. When the buffer is full, what is before rs (written already)
   makes room, and every position kept moves with it (*x, the files); if it
   is still full, the buffer doubles. */
static void fill(in_t *s, size_t *x) {
  if (s->have == s->cap && s->rs) {
    size_t d = s->rs;
    move_down(s->buf, s->buf + d, s->have - d);
    s->have -= d; *x -= d; s->rs = 0;
    for (int k = 0; k < s->nf; k++) s->at[k] -= d;
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

/* the files gathered: compressed, then written in order with the raw bytes
   between them; a file PJA did not take, or that did not get smaller,
   stays in the raw run around it */
static void run_batch(in_t *s, out_t *o, int threads) {
  if (!s->nf) return;
  for (int k = 0; k < s->nf; k++) {
    s->files[k].in = s->buf + s->at[k];
    s->files[k].out = 0; s->files[k].ok = 0;
  }
  H.run(s->files, s->nf, 1, threads);
  for (int k = 0; k < s->nf; k++) {
    job_t *f = &s->files[k];
    if (f->ok && f->out_size + 12 < f->size) {
      raw_upto(s, o, s->at[k], 1);
      uint8_t t = TAG_FILE;
      put(o, &t, 1); put_num(o, f->size); put_num(o, f->out_size); put(o, f->out, f->out_size);
      s->rs = s->at[k] + f->size;
    }
    if (f->out) H.release(f->out);
  }
  s->nf = 0; s->fbytes = 0;
}

int pjafilter_encode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                     int threads) {
  if (!read || !write || !H.alloc) return PJA_E_ARG;
  if (threads < 1) threads = 1;
  in_t s = {0};
  s.read = read; s.ctx = read_ctx; s.cap = WINDOW;
  s.maxf = 8 * threads;
  out_t o = {write, write_ctx, 0};
  s.buf = H.alloc(s.cap);
  s.files = H.alloc(sizeof(job_t) * (size_t)s.maxf);
  s.at = H.alloc(sizeof(size_t) * (size_t)s.maxf);
  if (!s.buf || !s.files || !s.at) s.err = PJA_E_MEMORY;
  put(&o, MAGIC, sizeof MAGIC);
  size_t pos = 0;                                 /* where the search goes on */
  while (!s.err && !o.err) {
    size_t c = pos;
    while (c + 3 <= s.have && !(s.buf[c] == 0xFF && s.buf[c + 1] == 0xD8 && s.buf[c + 2] == 0xFF)) c++;
    if (!s.nf) raw_upto(&s, &o, c, 0);
    if (c + 3 > s.have) {                         /* no file starts in what is here */
      if (s.eof) { run_batch(&s, &o, threads); raw_upto(&s, &o, s.have, 1); break; }
      pos = c;
      /* files waiting while raw bytes pile up behind them: run them now,
         so that the buffer does not grow with the raw bytes */
      if (s.nf && s.have - s.rs >= BATCH_BYTES) run_batch(&s, &o, threads);
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
    s.at[s.nf] = c;
    s.files[s.nf].size = (size_t)len;
    s.nf++; s.fbytes += (size_t)len;
    pos = c + (size_t)len;
    if (s.nf == s.maxf || s.fbytes >= BATCH_BYTES) run_batch(&s, &o, threads);
  }
  if (!s.err && !o.err) { uint8_t t = TAG_END; put(&o, &t, 1); }
  if (s.buf) H.release(s.buf);
  if (s.files) H.release(s.files);
  if (s.at) H.release(s.at);
  return s.err ? s.err : o.err;
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

/* The decoder gathers records the same way: up to 8 x threads files (or
   BATCH_BYTES), the raw records between them kept in memory, then
   decompresses the files at once and writes everything in order. */
typedef struct {
  uint8_t *raw;      /* a raw record's bytes, or 0 for the next file */
  size_t n;
} item_t;
typedef struct {
  item_t *items;
  job_t *files;
  int ni, nf, maxi, maxf;
  size_t bytes;
} queue_t;

static void clear(queue_t *q) {
  for (int k = 0; k < q->ni; k++) if (q->items[k].raw) H.release(q->items[k].raw);
  for (int k = 0; k < q->nf; k++) {
    H.release((void *)q->files[k].in);
    if (q->files[k].out) H.release(q->files[k].out);
  }
  q->ni = q->nf = 0; q->bytes = 0;
}

/* returns 0, or PJA_E_DATA when a file did not come back */
static int flush(queue_t *q, out_t *o, int threads) {
  int res = PJA_OK;
  if (q->nf) H.run(q->files, q->nf, 0, threads);
  for (int k = 0, f = 0; k < q->ni && !o->err; k++) {
    if (q->items[k].raw) { put(o, q->items[k].raw, q->items[k].n); continue; }
    job_t *j = &q->files[f++];
    if (!j->ok || j->out_size != j->expected) { res = PJA_E_DATA; break; }
    put(o, j->out, j->out_size);
  }
  clear(q);
  return res;
}

int pjafilter_decode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                     int threads) {
  if (!read || !write || !H.alloc) return PJA_E_ARG;
  if (threads < 1) threads = 1;
  rd_t r = {read, read_ctx, 0, 0, 0, 0};
  out_t o = {write, write_ctx, 0};
  queue_t q = {0};
  q.maxf = 8 * threads; q.maxi = 2 * q.maxf + 2;
  r.buf = H.alloc(IOBUF);
  q.items = H.alloc(sizeof(item_t) * (size_t)q.maxi);
  q.files = H.alloc(sizeof(job_t) * (size_t)q.maxf);
  int res = PJA_E_DATA;
  if (!r.buf || !q.items || !q.files) { res = PJA_E_MEMORY; goto done; }
  for (size_t k = 0; k < sizeof MAGIC; k++) if (rd_byte(&r) != MAGIC[k]) goto done;
  for (;;) {
    int t = rd_byte(&r);
    uint64_t n, size;
    if (t == TAG_END) { res = flush(&q, &o, threads); break; }
    if (t == TAG_RAW) {
      if (!rd_num(&r, &n) || !n || n > RAW_RUN) break;
      uint8_t *b = H.alloc((size_t)n);
      if (!b) { res = PJA_E_MEMORY; break; }
      q.items[q.ni].raw = b; q.items[q.ni].n = (size_t)n; q.ni++;
      q.bytes += (size_t)n;
      if (rd(&r, b, (size_t)n) != n) break;
    } else if (t == TAG_FILE) {
      if (!rd_num(&r, &size) || !rd_num(&r, &n) || !size || size > MAX_FILE || !n || n >= size) break;
      uint8_t *st = H.alloc((size_t)n);
      if (!st) { res = PJA_E_MEMORY; break; }
      job_t *j = &q.files[q.nf++];
      j->in = st; j->size = (size_t)n; j->expected = (size_t)size; j->out = 0; j->out_size = 0; j->ok = 0;
      q.items[q.ni].raw = 0; q.items[q.ni].n = 0; q.ni++;
      q.bytes += (size_t)size;
      if (rd(&r, st, (size_t)n) != n) break;
    } else break;
    if (q.nf == q.maxf || q.ni >= q.maxi - 1 || q.bytes >= BATCH_BYTES) {
      res = flush(&q, &o, threads);
      if (res != PJA_OK) break;
      res = PJA_E_DATA;
    }
  }
done:
  if (q.items) { clear(&q); H.release(q.items); }
  if (q.files) H.release(q.files);
  if (r.buf) H.release(r.buf);
  if (r.err) return r.err;
  if (o.err) return o.err;
  return res;
}

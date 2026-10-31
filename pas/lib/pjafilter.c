/* libpja's filter (pja.h: pja_filter_encode and pja_filter_decode, through pjalib.pas): the JPEG
   and JPEG-LS files inside a stream of any bytes, recompressed by PJA; every
   other byte passed through as it was, for the archiver's own compressor.

   The filter's stream (doc/LIBRARY.md):

     "PJAF" 01                     magic and version
     records, each a tag byte:
       00 n bytes                  n raw bytes (n a LEB128 number, >= 1)
       01 size n stream            a file of `size` bytes, as PJA's codec
                                   stream of n bytes (pjacodec.Compress)
       02 n segments               tables: n bytes of DQT, DHT, DRI or COM
                                   segments, for the 03 records after it;
                                   nothing is written
       03 size n stream            a file of `size` bytes without tables of
                                   its own (an "abbreviated" JPEG): its
                                   codec stream is that of the file with
                                   the tables put after its SOI, coded as
                                   known (pjamodel.SetGivenTables)
       FF                          the end

   FlashPix (and Picture It's and PhotoDraw's .mix, built on it) and
   TIFF's JPEG (its JPEGTables) keep the tables once, as a JPEG of tables
   only (SOI, the segments, EOI), and the image as many JPEGs without
   them, which PJA cannot decode alone. The encoder gives such a file the
   last tables it saw, or, before any, the first ones ahead (FlashPix
   writes them after the tiles), or, with none in 16 MiB, the standard
   ones (STD_TABLES, 0.5.2); the JPEGs of tables stay among the raw
   bytes. A decoder of 0.4.0 or before does not know 02 and 03 and stops
   with a data error.

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
  /* a file without tables of its own: the tables put after its SOI, which
     its codec stream leaves out (pjamodel.SetGivenTables); 0 bytes if none */
  const uint8_t *given;
  size_t given_size;
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
  TAG_RAW = 0x00, TAG_FILE = 0x01, TAG_TABLES = 0x02, TAG_FILE_T = 0x03, TAG_END = 0xFF,
  MAX_TABLES = 1 << 16,         /* the longest JPEG of tables taken */
  TABLES_AHEAD = 16 << 20       /* how far ahead the first tables are looked for */
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

/* p[0..n): a JPEG of tables only (SOI, then DQT, DHT, DRI or COM
   segments, at least one DQT or DHT, then EOI): its length, EXT_MORE if n
   bytes are not enough to tell, EXT_NOT if it is not one */
static ptrdiff_t tables_extent(const uint8_t *p, size_t n) {
  size_t i = 2;
  int tables = 0;
  for (;;) {
    if (i + 2 > n) return i + 2 > MAX_TABLES ? EXT_NOT : EXT_MORE;
    if (p[i] != 0xFF) return EXT_NOT;
    uint8_t m = p[i + 1];
    i += 2;
    if (m == 0xD9) return tables ? (ptrdiff_t)i : EXT_NOT;
    if (m != 0xDB && m != 0xC4 && m != 0xDD && m != 0xFE) return EXT_NOT;
    if (m != 0xFE) tables = 1;
    if (i + 2 > n) return EXT_MORE;
    size_t len = ((size_t)p[i] << 8) | p[i + 1];
    if (len < 2) return EXT_NOT;
    i += len;
    if (i > MAX_TABLES) return EXT_NOT;
  }
}

/* The tables libjpeg writes when it is not asked to optimize: T.81's
   example tables (K.1's quantization at quality 50, K.3's Huffman), DQT
   and DHT segments as cjpeg -quality 50 writes them. A JPEG without tables
   whose container keeps none (Konica's Q-Photo .kqp and .pic, whose
   program assumes them) is given these: if they are not its own, it does
   not come back and stays raw. */
static const uint8_t STD_TABLES[570] = {
  0xFF, 0xDB, 0x00, 0x43, 0x00, 0x10, 0x0B, 0x0C, 0x0E, 0x0C, 0x0A, 0x10, 0x0E, 0x0D, 0x0E, 0x12,
  0x11, 0x10, 0x13, 0x18, 0x28, 0x1A, 0x18, 0x16, 0x16, 0x18, 0x31, 0x23, 0x25, 0x1D, 0x28, 0x3A,
  0x33, 0x3D, 0x3C, 0x39, 0x33, 0x38, 0x37, 0x40, 0x48, 0x5C, 0x4E, 0x40, 0x44, 0x57, 0x45, 0x37,
  0x38, 0x50, 0x6D, 0x51, 0x57, 0x5F, 0x62, 0x67, 0x68, 0x67, 0x3E, 0x4D, 0x71, 0x79, 0x70, 0x64,
  0x78, 0x5C, 0x65, 0x67, 0x63, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x11, 0x12, 0x12, 0x18, 0x15, 0x18,
  0x2F, 0x1A, 0x1A, 0x2F, 0x63, 0x42, 0x38, 0x42, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
  0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
  0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
  0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
  0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10,
  0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
  0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
  0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
  0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
  0xF9, 0xFA, 0xFF, 0xC4, 0x00, 0x1F, 0x01, 0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
  0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
  0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x11, 0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04,
  0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, 0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
  0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
  0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
  0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
  0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
  0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
  0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
  0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
  0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
  0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA
};

/* p[0..n): DQT, DHT, DRI or COM segments, n bytes of them exactly */
static int tables_segments(const uint8_t *p, size_t n) {
  size_t i = 0;
  while (i < n) {
    if (i + 4 > n || p[i] != 0xFF) return 0;
    uint8_t m = p[i + 1];
    if (m != 0xDB && m != 0xC4 && m != 0xDD && m != 0xFE) return 0;
    size_t len = ((size_t)p[i + 2] << 8) | p[i + 3];
    if (len < 2) return 0;
    i += 2 + len;
  }
  return i == n && n > 0;
}

/* p[0..n), a whole JPEG: 1 if it has no DHT (Huffman) or no DQT before
   its first scan, so that PJA could not decode it alone */
static int lacks_tables(const uint8_t *p, size_t n) {
  size_t i = 2;
  int dqt = 0, dht = 0, arith = 0;
  while (i + 4 <= n && p[i] == 0xFF) {
    uint8_t m = p[i + 1];
    if (m == 0xFF) { i++; continue; }
    if (m == 0xDA || m == 0xD9) break;
    if (m == 0xDB) dqt = 1;
    if (m == 0xC4) dht = 1;
    if (m >= 0xC9 && m <= 0xCF && m != 0xCC) arith = 1;
    if (m == 0xF7) return 0;                       /* JPEG-LS */
    i += 2 + (((size_t)p[i + 2] << 8) | p[i + 3]);
  }
  return !dqt || (!dht && !arith);
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
  /* the last JPEG of tables, its segments (without SOI and EOI); for each
     file in the pool, how many bytes of them it was given (0: none); the
     tables the decoder has (the last 02 record); how far ahead tables were
     looked for, counted from the start of the input (base: the bytes the
     buffer has dropped) */
  uint8_t *tab, *dtab;
  size_t tabn, dtabn, *given, base, looked;
} in_t;

/* more bytes. When the buffer is full, what is before rs (written already)
   makes room, and every position kept moves with it (*x, the files); if it
   is still full, the buffer doubles. */
static void fill(in_t *s, size_t *x) {
  if (s->have == s->cap && s->rs) {
    size_t d = s->rs;
    move_down(s->buf, s->buf + d, s->have - d);
    s->have -= d; *x -= d; s->rs = 0; s->base += d;
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

/* before any tables: the first JPEG of tables after buf[c], up to
   TABLES_AHEAD bytes on, into s->tab; each byte looked at once */
static void tables_ahead(in_t *s, size_t *c) {
  size_t i = s->looked > s->base + *c ? s->looked - s->base : *c;
  for (;;) {
    while (i + 3 <= s->have && !(s->buf[i] == 0xFF && s->buf[i + 1] == 0xD8 && s->buf[i + 2] == 0xFF)) i++;
    if (i - *c >= TABLES_AHEAD) break;
    if (i + 3 <= s->have) {
      ptrdiff_t t = tables_extent(s->buf + i, s->have - i);
      if (t > 0) {
        s->tabn = (size_t)t - 4;
        copy(s->tab, s->buf + i + 2, s->tabn);
        break;
      }
      if (t != EXT_MORE || s->eof) { i++; continue; }
    }
    if (s->eof || s->err) break;
    size_t at = i - *c;
    fill(s, c);
    i = *c + at;
  }
  s->looked = s->base + i;
}

/* the file buf[c..c+len) to the pool, as a copy (the buffer moves); one
   without tables of its own with the tables put after its SOI, which its
   codec stream then leaves out */
static void submit(in_t *s, size_t *pc, size_t len) {
  if (!s->tabn && lacks_tables(s->buf + *pc, len)) tables_ahead(s, pc);
  size_t c = *pc;
  int k = (s->first + s->np) % s->maxp;
  job_t *f = &s->files[k];
  int lacks = lacks_tables(s->buf + c, len);
  /* the container's tables, or else the standard ones */
  const uint8_t *tab = s->tabn ? s->tab : STD_TABLES;
  size_t g = lacks ? (s->tabn ? s->tabn : sizeof STD_TABLES) : 0;
  uint8_t *in = H.alloc(len + g);
  if (!in) { s->err = PJA_E_MEMORY; return; }
  copy(in, s->buf + c, 2);
  copy(in + 2, tab, g);
  copy(in + 2 + g, s->buf + c + 2, len - 2);
  s->given[k] = g;
  f->given = in + 2; f->given_size = g;
  f->in = in; f->size = len + g; f->expected = 0; f->out = 0; f->out_size = 0; f->ok = 0; f->done = 0;
  /* a file alone gets the threads for its bands; more files share them */
  f->threads = s->threads / (s->np + 1);
  if (f->threads < 1) f->threads = 1;
  s->at[k] = c;
  s->np++; s->pbytes += len + g;
  H.pool_submit(s->pool, f);
}

/* the oldest file in the pool, waited for and written with the raw bytes
   before it; one PJA did not take, or that did not get smaller, stays in
   the raw run around it */
static void retire(in_t *s, out_t *o) {
  int k = s->first;
  job_t *f = &s->files[k];
  size_t g = s->given[k], size = f->size - g;      /* the file's own bytes */
  H.pool_wait(s->pool, f);
  if (f->ok && f->out_size + 12 < size && !s->err) {
    raw_upto(s, o, s->at[k], 1);
    /* its tables, unless the decoder has them already */
    int same = g == s->dtabn;
    for (size_t j = 0; same && j < g; j++) same = f->in[2 + j] == s->dtab[j];
    if (g && !same) {
      uint8_t t = TAG_TABLES;
      put(o, &t, 1); put_num(o, g); put(o, f->in + 2, g);
      copy(s->dtab, f->in + 2, g); s->dtabn = g;
    }
    uint8_t t = g ? TAG_FILE_T : TAG_FILE;
    put(o, &t, 1); put_num(o, size); put_num(o, f->out_size);
    if (s->ob) dedup_put(s->dd, s->ob, f->out, f->out_size);
    else put(o, f->out, f->out_size);
    s->rs = s->at[k] + size;
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
  s.given = H.alloc(sizeof(size_t) * (size_t)s.maxp);
  s.tab = H.alloc(MAX_TABLES);
  s.dtab = H.alloc(MAX_TABLES);
  s.pool = H.pool_open(threads, 1);
  if (!ddok || !s.buf || !s.files || !s.at || !s.given || !s.tab || !s.dtab || !s.pool) s.err = PJA_E_MEMORY;
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
    /* a JPEG of tables: the tables from here on; it stays raw */
    for (;;) {
      len = tables_extent(s.buf + c, s.have - c);
      if (len != EXT_MORE || s.eof || s.err) break;
      fill(&s, &c);
    }
    if (s.err) break;
    if (len > 0) {
      s.tabn = (size_t)len - 4;
      copy(s.tab, s.buf + c + 2, s.tabn);
      pos = c + (size_t)len;
      continue;
    }
    for (;;) {
      len = jpeg_extent(s.buf + c, s.have - c);
      if (len != EXT_MORE || s.eof || s.err || s.have - c > MAX_FILE) break;
      fill(&s, &c);
    }
    if (s.err) break;
    if (len <= 0) { pos = c + 1; continue; }
    while (s.np && (s.np == s.maxp || s.pbytes + (size_t)len > AHEAD_BYTES)) retire(&s, &o);
    submit(&s, &c, (size_t)len);
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
  if (s.given) H.release(s.given);
  if (s.tab) H.release(s.tab);
  if (s.dtab) H.release(s.dtab);
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
  size_t given;      /* a file: the bytes of tables put after its SOI, to take out */
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
  it->given = 0;
  q->first = (q->first + 1) % q->max; q->n--;
}

/* the oldest item written; PJA_E_DATA when its file did not come back. A
   file given tables: they come out of it, after its SOI, and must be the
   ones it was given */
static int retire_item(queue_t *q, out_t *o, const uint8_t *tab) {
  item_t *it = &q->items[q->first];
  int res = PJA_OK;
  size_t g = it->given;
  if (!it->file) put(o, it->job.in, it->job.size);
  else {
    H.pool_wait(q->pool, &it->job);
    const uint8_t *b = it->job.out;
    if (!it->job.ok || it->job.out_size != it->job.expected) res = PJA_E_DATA;
    else if (!g) put(o, b, it->job.out_size);
    else {
      for (size_t k = 0; k < g && res == PJA_OK; k++) if (b[2 + k] != tab[k]) res = PJA_E_DATA;
      if (res == PJA_OK) { put(o, b, 2); put(o, b + 2 + g, it->job.out_size - 2 - g); }
    }
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
  /* the tables of the last 02 record; a new one waits until the files
     before it, which were given the old ones, are written */
  uint8_t *tab = 0;
  size_t tabn = 0;
  dedup_t dd;
  dedup_init(&dd, 0);
  out_t o = {write, write_ctx, 0};
  queue_t q = {0};
  q.maxf = 8 * threads; q.max = 2 * q.maxf + 2;
  r.buf = H.alloc(IOBUF);
  if (read_b) rb.buf = H.alloc(IOBUF);
  q.items = H.alloc(sizeof(item_t) * (size_t)q.max);
  q.pool = H.pool_open(threads, 0);
  tab = H.alloc(MAX_TABLES);
  int res = PJA_E_DATA;
  if (!r.buf || !q.items || !q.pool || !tab || (read_b && !rb.buf)) { res = PJA_E_MEMORY; goto done; }
  for (size_t k = 0; k < sizeof MAGIC; k++) if (rd_byte(&r) != (read_b ? MAGIC2 : MAGIC)[k]) goto done;
  if (read_b) for (size_t k = 0; k < sizeof MAGIC_B; k++) if (rd_byte(&rb) != MAGIC_B[k]) goto done;
  for (;;) {
    int t = rd_byte(&r);
    uint64_t n, size;
    if (t == TAG_END) {
      res = PJA_OK;
      while (q.n && res == PJA_OK && !o.err) res = retire_item(&q, &o, tab);
      break;
    }
    /* room for one more item */
    int bad = 0;
    while (q.n && (q.n >= q.max - 1 || q.files >= q.maxf || q.bytes >= AHEAD_BYTES || t == TAG_TABLES))
      if (retire_item(&q, &o, tab) != PJA_OK) { bad = 1; break; }
    if (bad || o.err) break;
    item_t *it = &q.items[(q.first + q.n) % q.max];
    it->given = 0;
    if (t == TAG_TABLES) {
      if (!rd_num(&r, &n) || !n || n > MAX_TABLES) break;
      if (rd(&r, tab, (size_t)n) != n || !tables_segments(tab, (size_t)n)) break;
      tabn = (size_t)n;
    } else if (t == TAG_RAW) {
      if (!rd_num(&r, &n) || !n || n > RAW_RUN) break;
      uint8_t *b = H.alloc((size_t)n);
      if (!b) { res = PJA_E_MEMORY; break; }
      it->file = 0; it->job.in = b; it->job.size = (size_t)n; it->job.out = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, b, (size_t)n) != n) break;
    } else if (t == TAG_FILE || t == TAG_FILE_T) {
      if (!rd_num(&r, &size) || !rd_num(&r, &n) || !size || size > MAX_FILE || !n || n >= size) break;
      size_t g = t == TAG_FILE_T ? tabn : 0;
      if (t == TAG_FILE_T && !g) break;               /* no tables yet */
      uint8_t *st = H.alloc((size_t)n);
      if (!st) { res = PJA_E_MEMORY; break; }
      it->file = 0; it->job.in = st; it->job.size = (size_t)n; it->job.expected = (size_t)size + g;
      it->given = g; it->job.given = tab; it->job.given_size = g;
      it->job.out = 0; it->job.out_size = 0; it->job.ok = 0; it->job.done = 0;
      q.n++; q.bytes += (size_t)n;
      if (read_b ? !dedup_get(&dd, &rb, st, (size_t)n) : rd(&r, st, (size_t)n) != n) {
        if (dd.err) res = dd.err;
        break;
      }
      q.bytes += (size_t)size + g - (size_t)n;
      it->file = 1; q.files++;
      it->job.threads = threads / q.files; if (it->job.threads < 1) it->job.threads = 1;
      H.pool_submit(q.pool, &it->job);
    } else break;
  }
done:
  if (q.items) while (q.n) drop(&q, &q.items[q.first]);
  if (q.pool) H.pool_close(q.pool);
  if (q.items) H.release(q.items);
  if (tab) H.release(tab);
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

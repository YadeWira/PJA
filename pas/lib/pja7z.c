/* libpja as a 7-Zip codec plugin: put pja.dll (pja.so) in the Codecs folder
   next to 7-Zip (7z.exe, or 7z and 7z.so on Linux), or 7-Zip-zstd, and the
   method PJA is there:

     7z a -m0=PJA -m1=LZMA2 photos.7z photos/        (7-Zip-zstd: -m1=zstd)

   PJA is a filter in 7-Zip's sense of a first coder: it takes the solid
   block, recompresses the JPEG and JPEG-LS files in it (pjafilter.c) and
   passes every other byte on to the next coder; its own data goes into the
   archive by a second stream (see METHODS). Extracting needs the plugin
   too.

   7-Zip's interfaces are C++ classes with only virtual methods, which is a
   table of function pointers first in the object: plain C builds them. On
   Windows x86 they are __stdcall; elsewhere the default convention. IUnknown
   has no virtual destructor (GetModuleProp says so: 7-Zip on Linux since
   v23 checks it). The exported functions are pjalib.pas's, which call the
   pja7z_* ones here.

   The methods' IDs, 03 7F 02 (PJA) and 03 7F 01 (PJA1), are in the slot
   7-Zip's DOC/Methods.txt leaves for an experimental method, until 7-Zip
   gives PJA an ID of its own. */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(_WIN64)
#define COMCALL __stdcall
#define PJA_CALL __cdecl
#else
#define COMCALL
#define PJA_CALL
#endif

typedef int32_t HRESULT;
#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_NOTIMPL ((HRESULT)0x80004001u)
#define E_NOINTERFACE ((HRESULT)0x80004002u)
#define E_ABORT ((HRESULT)0x80004004u)
#define E_FAIL ((HRESULT)0x80004005u)
#define E_OUTOFMEMORY ((HRESULT)0x8007000Eu)
#define E_INVALIDARG ((HRESULT)0x80070057u)
#define CLASS_E_CLASSNOTAVAILABLE ((HRESULT)0x80040111u)

typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } guid_t;

enum { VT_EMPTY = 0, VT_BOOL = 11, VT_UI4 = 19, VT_UI8 = 21, VT_BSTR = 8 };
typedef struct {
  uint16_t vt, r1, r2, r3;
  union { uint64_t u64; uint32_t u32; int16_t b; void *p; } v;
} propvariant_t;

/* what pjalib.pas gives: a BSTR the way this platform's 7-Zip frees it
   (Windows: OLE's SysAllocStringByteLen; elsewhere 7-Zip's own layout, a
   32-bit byte count before the string, from malloc), and the filter */
typedef struct {
  void *(*bstr)(const void *bytes, uint32_t len);
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  int threads;    /* when 7-Zip says nothing: the processors, up to 8 */
  int cpus;       /* the processors (-mmt=p50 is half of them) */
  /* the process's command line, read only while pja7z_host runs: its
     arguments, each ended by a zero byte (Linux, macOS), or Windows' line
     (GetCommandLineW); 0 when there is none */
  const char *args;
  size_t args_size;
  const uint16_t *wline;
} host7z_t;
static host7z_t H7;
static int cmdline_mt(const host7z_t *h);
static int MT;    /* -mmt on 7-Zip's command line: the threads, or 0 */
void pja7z_host(const host7z_t *h) {
  H7 = *h;
  MT = cmdline_mt(h);
  H7.args = 0; H7.args_size = 0; H7.wline = 0;
}

typedef ptrdiff_t (PJA_CALL *pja_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PJA_CALL *pja_write_fn)(void *ctx, const void *buf, size_t size);
int pjafilter_encode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx, int threads);
int pjafilter_decode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx, int threads);
int pjafilter2_encode(pja_read_fn read, void *read_ctx, pja_write_fn write_a, void *a_ctx,
                      pja_write_fn write_b, void *b_ctx, int threads);
int pjafilter2_decode(pja_read_fn read_a, void *a_ctx, pja_read_fn read_b, void *b_ctx,
                      pja_write_fn write, void *write_ctx, int threads);

/* The methods. PJA: the filter's version 2, two streams: the first (the
   raw bytes and the records) goes on to the next coder of the chain, the
   second (PJA's data, deduplicated by the filter itself) into the archive
   as it is, so that LZMA2 or zstd does not spend its time on bytes it
   cannot make smaller. PJA1: version 1, one stream, what 0.2.0 wrote; kept
   so that those archives open, and still usable. */
typedef struct { const char *name; uint64_t id; uint32_t streams; } method_t;
static const method_t METHODS[] = {
  {"PJA", 0x037F02, 2},
  {"PJA1", 0x037F01, 1},
};
enum { NUM_METHODS = sizeof METHODS / sizeof METHODS[0] };

/* {23170F69-40C1-278A-0000-00gg00ss0000}: 7-Zip's interfaces, group g and
   sub-id s; the coder classes: Data3 2790 (decoder) or 2791 (encoder) and
   the method's ID in Data4, little-endian */
static int is_7zip_iid(const guid_t *g, uint8_t group, uint8_t sub) {
  return g->d1 == 0x23170F69u && g->d2 == 0x40C1 && g->d3 == 0x278A && g->d4[0] == 0 && g->d4[1] == 0
         && g->d4[2] == 0 && g->d4[3] == group && g->d4[4] == 0 && g->d4[5] == sub && g->d4[6] == 0
         && g->d4[7] == 0;
}
static int is_iunknown(const guid_t *g) {
  static const uint8_t d4[8] = {0xC0, 0, 0, 0, 0, 0, 0, 0x46};
  if (g->d1 || g->d2 || g->d3) return 0;
  for (int k = 0; k < 8; k++) if (g->d4[k] != d4[k]) return 0;
  return 1;
}
enum { G_STREAM = 3, G_CODER = 4, S_CODER = 0x05, S_CODER2 = 0x18, S_PROGRESS = 0x04, S_CODER_MT = 0x25 };

/* ---------- the streams 7-Zip hands in ---------- */

typedef struct instream instream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(instream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(instream_t *);
  uint32_t (COMCALL *Release)(instream_t *);
  HRESULT (COMCALL *Read)(instream_t *, void *data, uint32_t size, uint32_t *processed);
} instream_vt;
struct instream { const instream_vt *vt; };

typedef struct outstream outstream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(outstream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(outstream_t *);
  uint32_t (COMCALL *Release)(outstream_t *);
  HRESULT (COMCALL *Write)(outstream_t *, const void *data, uint32_t size, uint32_t *processed);
} outstream_vt;
struct outstream { const outstream_vt *vt; };

typedef struct progress progress_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(progress_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(progress_t *);
  uint32_t (COMCALL *Release)(progress_t *);
  HRESULT (COMCALL *SetRatioInfo)(progress_t *, const uint64_t *in_size, const uint64_t *out_size);
} progress_vt;
struct progress { const progress_vt *vt; };

/* one run of the coder: progress and the first error, shared by its
   streams */
typedef struct {
  progress_t *progress;
  uint64_t in_pos, out_pos, next_report;
  HRESULT err;    /* the first error a stream or the progress gave */
} run_t;
typedef struct {
  instream_t *in;
  outstream_t *out;
  run_t *run;
} io_t;

enum { REPORT_EVERY = 1 << 20 };

static void report(run_t *r) {
  if (!r->progress || r->in_pos + r->out_pos < r->next_report) return;
  r->next_report = r->in_pos + r->out_pos + REPORT_EVERY;
  HRESULT h = r->progress->vt->SetRatioInfo(r->progress, &r->in_pos, &r->out_pos);
  if (h != S_OK && !r->err) r->err = h;
}

static ptrdiff_t PJA_CALL io_read(void *ctx, void *buf, size_t size) {
  io_t *io = ctx;
  run_t *r = io->run;
  if (r->err) return -1;
  if (size > 0x40000000u) size = 0x40000000u;
  uint32_t got = 0;
  HRESULT h = io->in->vt->Read(io->in, buf, (uint32_t)size, &got);
  if (h != S_OK) { r->err = h; return -1; }
  r->in_pos += got;
  report(r);
  return r->err ? -1 : (ptrdiff_t)got;
}

static int PJA_CALL io_write(void *ctx, const void *buf, size_t size) {
  io_t *io = ctx;
  run_t *r = io->run;
  const uint8_t *p = buf;
  while (size && !r->err) {
    uint32_t n = size > 0x40000000u ? 0x40000000u : (uint32_t)size, done = 0;
    HRESULT h = io->out->vt->Write(io->out, p, n, &done);
    if (h != S_OK) { r->err = h; break; }
    if (!done) { r->err = E_FAIL; break; }
    p += done; size -= done; r->out_pos += done;
  }
  report(r);
  return r->err ? -1 : 0;
}

static HRESULT result(const run_t *r, int res) {
  if (r->err) return r->err;
  switch (res) {
    case 0: return S_OK;
    case 3: return E_OUTOFMEMORY;
    case 2: return S_FALSE;    /* 7-Zip's "data error" */
    /* PJA_E_VERSION, a later PJA's stream: 7-Zip says "Unsupported
       Method" for the files of the block, as for a method it lacks */
    case 7: return E_NOTIMPL;
    default: return E_FAIL;
  }
}

/* ---------- -mmt on the command line ----------

   Extracting, 7-Zip gives its thread count (-mmt, or the processors) to one
   coder of the folder only: CDecoder::Decode (Archive/7z/7zDecode.cpp)
   calls ICompressSetCoderMt::SetNumberOfThreads, or SetMemLimit, on the
   first coder that takes either, sets mt_wasUsed and asks no other. The
   folder lists the coders backwards from the methods (7zEncode.cpp:
   folder.Coders[i] is method numMethods - 1 - i), so with -m0=PJA
   -m1=LZMA2 (zstd, BZip2 alike) that is LZMA2, never PJA; and nothing else
   reaches a decoder (SetCoderPropertiesOpt is the encoder's). 7-Zip-zstd
   does the same. So PJA reads -mmt where 7-Zip's console took it, the
   process's command line, as 7-Zip parses it: switches up to "--"
   (Common/CommandLineParser.cpp); "-mNAME=VALUE", a VALUE of digits a
   number, "-mNAME-" and "-mNAME+" off and on (UI/Common/SetProperties.cpp);
   then ParseMtProp2 (Common/MethodProps.cpp). The last -mmt counts; one
   that leaves 7-Zip's count to the processors leaves PJA's default; one
   7-Zip refuses does not matter (7-Zip stops). A host that is not 7-Zip's
   console (7zFM, 7zG, another program) has no -mmt there: PJA's default. */

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int is_digit(int c) { return c >= '0' && c <= '9'; }

/* ParseMtProp2's string, [d|u][p]N, again and again: the threads, or -1.
   In 32 bits (no 64-bit division: the DLL has no C runtime), past 64
   threads any number is as good as another */
static long mt_string(const char *s, const char *end, int cpus) {
  uint32_t c32 = cpus < 1 ? 1 : cpus > 4096 ? 4096 : (uint32_t)cpus, v = c32;
  while (s < end) {
    int c = lower(*s);
    if (c == 'd' || c == 'u') { s++; continue; }
    int percent = c == 'p';
    if (percent) s++;
    if (s >= end || !is_digit(*s)) return -1;
    uint32_t n = 0;
    while (s < end && is_digit(*s)) {
      n = n * 10 + (uint32_t)(*s - '0');
      if (n > 10000) n = 10000;
      s++;
    }
    v = percent ? c32 * n / 100 : n;
  }
  return v > 64 ? 64 : (long)v;
}

/* one argument: -1 when it is not -mmt (or is one 7-Zip refuses), 0 when it
   leaves the count to the processors, else the threads (1 to 64) */
static long mt_arg(const char *a, size_t len, int cpus) {
  if (len < 4 || a[0] != '-' || lower(a[1]) != 'm' || lower(a[2]) != 'm' || lower(a[3]) != 't')
    return -1;
  const char *end = a + len, *rest = a + 4, *eq = rest;
  while (eq < end && *eq != '=') eq++;
  long v;
  if (eq == end) {    /* -mmt, -mmt-, -mmt+, -mmtN */
    if (rest == end || (end - rest == 1 && *rest == '+')) return 0;
    if (end - rest == 1 && *rest == '-') return 1;
    if (lower(*rest) == 'f') return -1;    /* -mmtf: the 7z handler's mixer */
    if (end[-1] == '-' || end[-1] == '+') return -1;
    v = mt_string(rest, end, cpus);
  } else {            /* -mmt=VALUE */
    if (eq != rest) return -1;
    const char *s = eq + 1, *d = s;
    size_t n = (size_t)(end - s);
    if (!n) return 0;
    while (d < end && is_digit(*d)) d++;
    if (d == end) {   /* a number, VT_UI4 (7-Zip refuses a larger one) */
      uint32_t x = 0;
      for (d = s; d < end; d++) {
        uint32_t k = (uint32_t)(*d - '0');
        if (x > 429496729u || (x == 429496729u && k > 5)) return -1;
        x = x * 10 + k;
      }
      v = x > 64 ? 64 : (long)x;
    } else if ((n == 1 && *s == '+') || (n == 2 && lower(s[0]) == 'o' && lower(s[1]) == 'n')) {
      return 0;
    } else if ((n == 1 && *s == '-')
               || (n == 3 && lower(s[0]) == 'o' && lower(s[1]) == 'f' && lower(s[2]) == 'f')) {
      return 1;
    } else {
      v = mt_string(s, end, cpus);
    }
  }
  if (v < 0) return -1;
  return v < 1 ? 1 : v;
}

/* the arguments a character at a time, each ended by end_arg */
typedef struct {
  char buf[64];    /* a longer argument is no -mmt */
  size_t n;
  int index, stopped, cpus;
  long mt;
} args_t;
static void put_char(args_t *g, unsigned c) {
  if (g->n < sizeof g->buf) g->buf[g->n] = (char)(c > 0 && c < 128 ? c : '?');
  g->n++;
}
static void end_arg(args_t *g) {
  if (g->index++ > 0 && !g->stopped && g->n <= sizeof g->buf) {    /* not the program */
    if (g->n == 2 && g->buf[0] == '-' && g->buf[1] == '-') g->stopped = 1;
    else {
      long r = mt_arg(g->buf, g->n, g->cpus);
      if (r >= 0) g->mt = r;
    }
  }
  g->n = 0;
}

static int cmdline_mt(const host7z_t *h) {
  args_t g;
  g.n = 0; g.index = 0; g.stopped = 0; g.mt = 0;
  g.cpus = h->cpus > 0 ? h->cpus : 1;
  if (h->args) {
    for (size_t k = 0; k < h->args_size; k++) {
      if (h->args[k]) put_char(&g, (uint8_t)h->args[k]);
      else end_arg(&g);
    }
    if (g.n) end_arg(&g);
  } else if (h->wline) {
    /* Windows: 7-Zip's console splits the line itself (SplitCommandLine):
       spaces and tabs outside quotes part the arguments; quotes go */
    int quote = 0, started = 0;
    for (const uint16_t *w = h->wline; *w; w++) {
      if ((*w == ' ' || *w == '\t') && !quote) {
        if (started) end_arg(&g);
        started = 0;
        continue;
      }
      started = 1;
      if (*w == '"') quote = !quote;
      else put_char(&g, *w);
    }
    if (started) end_arg(&g);
  }
  return (int)g.mt;
}

/* ---------- the coder ---------- */

/* ICompressCoder (PJA1) or ICompressCoder2 (PJA): the same object, its
   first table one or the other */
typedef struct coder coder_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(coder_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(coder_t *);
  uint32_t (COMCALL *Release)(coder_t *);
  HRESULT (COMCALL *Code)(coder_t *, instream_t *, outstream_t *, const uint64_t *in_size,
                          const uint64_t *out_size, progress_t *);
} coder_vt;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(coder_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(coder_t *);
  uint32_t (COMCALL *Release)(coder_t *);
  HRESULT (COMCALL *Code)(coder_t *, instream_t *const *ins, const uint64_t *const *in_sizes, uint32_t nin,
                          outstream_t *const *outs, const uint64_t *const *out_sizes, uint32_t nout,
                          progress_t *);
} coder2_vt;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(void *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(void *);
  uint32_t (COMCALL *Release)(void *);
  HRESULT (COMCALL *SetNumberOfThreads)(void *, uint32_t threads);
} coder_mt_vt;
struct coder {
  const void *vt;              /* coder_vt or coder2_vt */
  const coder_mt_vt *mt_vt;    /* ICompressSetCoderMt: a second table, at &c->mt_vt */
  int32_t refs;
  int encode, streams;
  int threads;
};

static coder_t *from_mt(void *p) { return (coder_t *)((char *)p - offsetof(coder_t, mt_vt)); }

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out);
/* a plain count, as 7-Zip's own coders keep it (CMyUnknownImp): a coder is
   used by one thread at a time */
static uint32_t COMCALL c_addref(coder_t *c) { return (uint32_t)++c->refs; }
static uint32_t COMCALL c_release(coder_t *c) {
  int32_t n = --c->refs;
  if (!n) H7.release(c);
  return (uint32_t)n;
}

static HRESULT COMCALL c_code(coder_t *c, instream_t *in, outstream_t *out, const uint64_t *in_size,
                              const uint64_t *out_size, progress_t *progress) {
  (void)in_size; (void)out_size;
  if (!in || !out) return E_INVALIDARG;
  run_t r = {progress, 0, 0, REPORT_EVERY, S_OK};
  io_t io = {in, out, &r};
  int res = c->encode ? pjafilter_encode(io_read, &io, io_write, &io, c->threads)
                      : pjafilter_decode(io_read, &io, io_write, &io, c->threads);
  return result(&r, res);
}

static HRESULT COMCALL c_code2(coder_t *c, instream_t *const *ins, const uint64_t *const *in_sizes, uint32_t nin,
                               outstream_t *const *outs, const uint64_t *const *out_sizes, uint32_t nout,
                               progress_t *progress) {
  (void)in_sizes; (void)out_sizes;
  run_t r = {progress, 0, 0, REPORT_EVERY, S_OK};
  int res;
  if (c->encode) {
    if (nin != 1 || nout != 2 || !ins || !outs || !ins[0] || !outs[0] || !outs[1]) return E_INVALIDARG;
    io_t in = {ins[0], 0, &r}, a = {0, outs[0], &r}, b = {0, outs[1], &r};
    res = pjafilter2_encode(io_read, &in, io_write, &a, io_write, &b, c->threads);
  } else {
    if (nin != 2 || nout != 1 || !ins || !outs || !ins[0] || !ins[1] || !outs[0]) return E_INVALIDARG;
    io_t a = {ins[0], 0, &r}, b = {ins[1], 0, &r}, out = {0, outs[0], &r};
    res = pjafilter2_decode(io_read, &a, io_read, &b, io_write, &out, c->threads);
  }
  return result(&r, res);
}

static HRESULT COMCALL m_query(void *p, const guid_t *iid, void **out) { return c_query(from_mt(p), iid, out); }
static uint32_t COMCALL m_addref(void *p) { return c_addref(from_mt(p)); }
static uint32_t COMCALL m_release(void *p) { return c_release(from_mt(p)); }
static HRESULT COMCALL m_threads(void *p, uint32_t threads) {
  coder_t *c = from_mt(p);
  c->threads = threads < 1 ? 1 : threads > 64 ? 64 : (int)threads;
  /* a 32-bit 7-Zip: no more than the default (the processors, up to 8) */
  if (sizeof(void *) == 4 && H7.threads > 0 && c->threads > H7.threads) c->threads = H7.threads;
  return S_OK;
}

static const coder_vt CODER_VT = {c_query, c_addref, c_release, c_code};
static const coder2_vt CODER2_VT = {c_query, c_addref, c_release, c_code2};
static const coder_mt_vt CODER_MT_VT = {m_query, m_addref, m_release, m_threads};

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out) {
  if (!out) return E_INVALIDARG;
  *out = 0;
  if (is_iunknown(iid) || is_7zip_iid(iid, G_CODER, c->streams == 2 ? S_CODER2 : S_CODER)) *out = c;
  else if (is_7zip_iid(iid, G_CODER, S_CODER_MT)) *out = &c->mt_vt;
  else return E_NOINTERFACE;
  c_addref(c);
  return S_OK;
}

static HRESULT new_coder(uint32_t index, int encode, const guid_t *iid, void **out) {
  if (!out) return E_INVALIDARG;
  *out = 0;
  if (index >= NUM_METHODS) return CLASS_E_CLASSNOTAVAILABLE;
  coder_t *c = H7.alloc(sizeof *c);
  if (!c) return E_OUTOFMEMORY;
  c->streams = (int)METHODS[index].streams;
  c->vt = c->streams == 2 ? (const void *)&CODER2_VT : (const void *)&CODER_VT;
  c->mt_vt = &CODER_MT_VT; c->refs = 1; c->encode = encode;
  /* extracting, 7-Zip tells only the first coder of the chain that takes
     it (LZMA2 or zstd) how many threads to use: -mmt on the command line,
     else the processors (up to 8); a 32-bit 7-Zip no more than that
     default. SetNumberOfThreads, when 7-Zip calls it (compressing), wins.
     (Ported from PPA, 13ccd32.) */
  int t = MT > 0 ? MT : H7.threads > 0 ? H7.threads : 1;
  if (sizeof(void *) == 4 && H7.threads > 0 && t > H7.threads) t = H7.threads;
  c->threads = t;
  HRESULT r = c_query(c, iid, out);
  c_release(c);
  return r;
}

/* ---------- what the plugin exports (through pjalib.pas) ---------- */

HRESULT pja7z_GetNumberOfMethods(uint32_t *n) {
  if (!n) return E_INVALIDARG;
  *n = NUM_METHODS;
  return S_OK;
}

static void set_bstr(propvariant_t *v, const void *bytes, uint32_t len) {
  void *b = H7.bstr(bytes, len);
  if (b) { v->vt = VT_BSTR; v->v.p = b; }
}
static void class_id(uint32_t index, uint16_t data3, guid_t *g) {
  g->d1 = 0x23170F69u; g->d2 = 0x40C1; g->d3 = data3;
  for (int k = 0; k < 8; k++) g->d4[k] = (uint8_t)(METHODS[index].id >> (8 * k));
}

enum { P_ID, P_NAME, P_DECODER, P_ENCODER, P_PACK_STREAMS, P_UNPACK_STREAMS, P_DESCRIPTION,
       P_DECODER_ASSIGNED, P_ENCODER_ASSIGNED, P_DIGEST_SIZE, P_IS_FILTER };

HRESULT pja7z_GetMethodProperty(uint32_t index, uint32_t prop, propvariant_t *v) {
  if (!v) return E_INVALIDARG;
  if (index >= NUM_METHODS) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  guid_t g;
  const method_t *m = &METHODS[index];
  switch (prop) {
    case P_ID: v->vt = VT_UI8; v->v.u64 = m->id; break;
    case P_NAME: {
      /* a BSTR holds wchar_t: 2 bytes on Windows, 4 on Linux and macOS */
      __WCHAR_TYPE__ w[8];
      unsigned n = 0;
      while (m->name[n] && n < 7) { w[n] = (__WCHAR_TYPE__)(uint8_t)m->name[n]; n++; }
      w[n] = 0;
      set_bstr(v, w, (uint32_t)(sizeof w[0] * n));
      break;
    }
    case P_DECODER: class_id(index, 0x2790, &g); set_bstr(v, &g, sizeof g); break;
    case P_ENCODER: class_id(index, 0x2791, &g); set_bstr(v, &g, sizeof g); break;
    case P_PACK_STREAMS:
      if (m->streams != 1) { v->vt = VT_UI4; v->v.u32 = m->streams; }
      break;
    case P_DECODER_ASSIGNED: case P_ENCODER_ASSIGNED: v->vt = VT_BOOL; v->v.b = -1; break;
    case P_IS_FILTER: v->vt = VT_BOOL; v->v.b = 0; break;
    default: break;
  }
  return S_OK;
}

HRESULT pja7z_CreateDecoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 0, iid, out);
}
HRESULT pja7z_CreateEncoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 1, iid, out);
}
/* CreateObject / CreateCoder: by class ID */
HRESULT pja7z_CreateObject(const guid_t *clsid, const guid_t *iid, void **out) {
  if (out) *out = 0;
  if (!clsid) return E_INVALIDARG;
  for (uint32_t i = 0; i < NUM_METHODS; i++) {
    guid_t d, e;
    class_id(i, 0x2790, &d); class_id(i, 0x2791, &e);
    int isd = 1, ise = 1;
    const uint8_t *a = (const uint8_t *)clsid, *bd = (const uint8_t *)&d, *be = (const uint8_t *)&e;
    for (unsigned k = 0; k < sizeof d; k++) { if (a[k] != bd[k]) isd = 0; if (a[k] != be[k]) ise = 0; }
    if (isd || ise) return new_coder(i, ise, iid, out);
  }
  return CLASS_E_CLASSNOTAVAILABLE;
}

enum { M_INTERFACE_TYPE = 0, M_VERSION = 1 };
HRESULT pja7z_GetModuleProp(uint32_t prop, propvariant_t *v) {
  if (!v) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  if (prop == M_INTERFACE_TYPE) { v->vt = VT_UI4; v->v.u32 = 0; }   /* no virtual destructor */
  else if (prop == M_VERSION) { v->vt = VT_UI4; v->v.u32 = (0u << 16) | 102u; }   /* 0.102 = PJA 0.9.12, checked against PJA_VERSION by run_tests.sh */
  return S_OK;
}

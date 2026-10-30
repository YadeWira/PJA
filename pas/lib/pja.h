/* libpja: PJA as a library, for archivers and other programs.

   PJA recompresses JPEG and JPEG-LS files losslessly: the original comes
   back byte for byte. The library is one shared object (pja.so, pja.dll,
   pja.dylib) with a C interface; every function may be called from several
   threads at once.

   Two ways to use it:

   - One file in memory: pja_compress() writes a .pja (the same format as
     the `pja` command, with the original's size and BLAKE3 hash), and
     pja_decompress() gives the original back. A file PJA does not take
     comes back as PJA_E_NOT_TAKEN, and the caller stores it its own way.

   - A filter over a stream of any bytes, for an archiver that puts many
     files in one stream (a solid block): pja_filter_encode() finds the
     JPEG and JPEG-LS files inside, recompresses each one that comes back
     byte for byte, and passes every other byte through untouched, so the
     archiver's own compressor (LZMA2, zstd...) still sees them and can
     match them across files. pja_filter_decode() gives the stream back.
     The filter's format is in doc/LIBRARY.md.

   Every buffer the library returns is freed with pja_free(). */
#ifndef PJA_H
#define PJA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define PJA_CALL __cdecl
#else
#define PJA_CALL
#endif

enum {
  PJA_OK = 0,
  PJA_E_NOT_TAKEN = 1,  /* pja_compress: not a file PJA takes (store it as is) */
  PJA_E_DATA = 2,       /* the input is damaged or not PJA's */
  PJA_E_MEMORY = 3,     /* out of memory, or over a size limit */
  PJA_E_READ = 4,       /* the filter's read callback failed */
  PJA_E_WRITE = 5,      /* the filter's write callback failed */
  PJA_E_ARG = 6         /* a null pointer or a bad argument */
};

/* "pja 0.5.1" */
const char *PJA_CALL pja_version(void);

/* A JPEG or JPEG-LS file -> a .pja. threads: how many at once (1 or more).
   On PJA_OK, *out holds *out_size bytes, to free with pja_free(). */
int PJA_CALL pja_compress(const void *in, size_t in_size, void **out, size_t *out_size, int threads);

/* A .pja -> the original, checked against its size and hash. max_size caps
   the original's size (0: no cap but the library's own, 2^31). */
int PJA_CALL pja_decompress(const void *in, size_t in_size, void **out, size_t *out_size,
                            size_t max_size, int threads);

void PJA_CALL pja_free(void *p);

/* The filter's callbacks. read: up to size bytes into buf; returns how
   many (0 at the end), or -1 on an error. write: all size bytes; returns 0,
   or -1 on an error. */
typedef ptrdiff_t (PJA_CALL *pja_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PJA_CALL *pja_write_fn)(void *ctx, const void *buf, size_t size);

/* Every byte read -> the filter's stream, written. */
int PJA_CALL pja_filter_encode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                               int threads);
/* The filter's stream, read -> the original bytes, written. */
int PJA_CALL pja_filter_decode(pja_read_fn read, void *read_ctx, pja_write_fn write, void *write_ctx,
                               int threads);

/* Version 2, for an archiver that stores two streams apart: A (the records
   and the raw bytes) for its compressor, B (PJA's data, deduplicated
   across files) stored as it is. */
int PJA_CALL pja_filter2_encode(pja_read_fn read, void *read_ctx, pja_write_fn write_a, void *a_ctx,
                                pja_write_fn write_b, void *b_ctx, int threads);
int PJA_CALL pja_filter2_decode(pja_read_fn read_a, void *a_ctx, pja_read_fn read_b, void *b_ctx,
                                pja_write_fn write, void *write_ctx, int threads);

#ifdef __cplusplus
}
#endif
#endif

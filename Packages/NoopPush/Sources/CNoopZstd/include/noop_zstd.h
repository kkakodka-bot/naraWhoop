#ifndef NOOP_ZSTD_H
#define NOOP_ZSTD_H

#include <stddef.h>
#include <stdint.h>

/// Compresses `src` with libzstd. On success writes an allocated buffer to `*out` and length to `*out_len`.
/// Caller must free with `noop_zstd_free`. Returns 0 on success, non-zero on failure.
int noop_zstd_compress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len);
/// Explicit measured levels only; the production entry point uses level 1.
int noop_zstd_compress_level(const uint8_t *src, size_t src_len, int level, uint8_t **out, size_t *out_len);
unsigned noop_zstd_version(void);

void noop_zstd_free(uint8_t *out);

/// Bounded decoding into caller-owned storage. Used as an independent codec oracle.
int noop_zstd_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_capacity, size_t *out_len);

/// Incremental single-threaded encoder. Caller owns bounded input/output buffers. Levels 1/3 only.
typedef struct noop_zstd_stream noop_zstd_stream;
noop_zstd_stream *noop_zstd_stream_create(int level, uint64_t pledged_size, int size_known);
int noop_zstd_stream_encode(noop_zstd_stream *stream, const uint8_t *src, size_t src_len,
    size_t *consumed, uint8_t *dst, size_t dst_capacity, size_t *written, int finish, int *finished);
void noop_zstd_stream_destroy(noop_zstd_stream *stream);

#endif

#include "noop_zstd.h"
#include <stdlib.h>
#include <zstd.h>

int noop_zstd_compress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len) {
    return noop_zstd_compress_level(src, src_len, 1, out, out_len);
}

int noop_zstd_compress_level(const uint8_t *src, size_t src_len, int level, uint8_t **out, size_t *out_len) {
    if ((src == NULL && src_len != 0) || out == NULL || out_len == NULL) return -1;
    *out = NULL;
    *out_len = 0;
    if (level != 1 && level != 3) return -1;
    size_t bound = ZSTD_compressBound(src_len);
    if (ZSTD_isError(bound)) return -1;
    uint8_t *dst = (uint8_t *)malloc(bound);
    if (dst == NULL) return -1;
    /* ZSTD_compress uses one thread; no worker pool or dictionary training is enabled. */
    size_t written = ZSTD_compress(dst, bound, src, src_len, level);
    if (ZSTD_isError(written)) {
        free(dst);
        return -1;
    }
    *out = dst;
    *out_len = written;
    return 0;
}

unsigned noop_zstd_version(void) { return ZSTD_versionNumber(); }

void noop_zstd_free(uint8_t *out) {
    free(out);
}

int noop_zstd_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_capacity, size_t *out_len) {
    if (src == NULL || dst == NULL || out_len == NULL) return -1;
    size_t written = ZSTD_decompress(dst, dst_capacity, src, src_len);
    if (ZSTD_isError(written)) return -1;
    *out_len = written;
    return 0;
}

struct noop_zstd_stream { ZSTD_CCtx *context; };

noop_zstd_stream *noop_zstd_stream_create(int level, uint64_t pledged_size, int size_known) {
    if (level != 1 && level != 3) return NULL;
    noop_zstd_stream *stream = (noop_zstd_stream *)calloc(1, sizeof(*stream));
    if (stream == NULL) return NULL;
    stream->context = ZSTD_createCCtx();
    if (stream->context == NULL ||
        ZSTD_isError(ZSTD_CCtx_setParameter(stream->context, ZSTD_c_compressionLevel, level)) ||
        ZSTD_isError(ZSTD_CCtx_setParameter(stream->context, ZSTD_c_nbWorkers, 0)) ||
        (size_known && ZSTD_isError(ZSTD_CCtx_setPledgedSrcSize(stream->context, pledged_size)))) {
        noop_zstd_stream_destroy(stream);
        return NULL;
    }
    return stream;
}

int noop_zstd_stream_encode(noop_zstd_stream *stream, const uint8_t *src, size_t src_len,
    size_t *consumed, uint8_t *dst, size_t dst_capacity, size_t *written, int finish, int *finished) {
    if (stream == NULL || (src == NULL && src_len != 0) || consumed == NULL ||
        dst == NULL || dst_capacity == 0 || written == NULL || finished == NULL) return -1;
    *consumed = 0; *written = 0; *finished = 0;
    ZSTD_inBuffer input = { src, src_len, 0 };
    ZSTD_outBuffer output = { dst, dst_capacity, 0 };
    size_t result = ZSTD_compressStream2(stream->context, &output, &input,
        finish ? ZSTD_e_end : ZSTD_e_continue);
    if (ZSTD_isError(result)) return -1;
    *consumed = input.pos; *written = output.pos;
    *finished = finish && result == 0;
    return 0;
}

void noop_zstd_stream_destroy(noop_zstd_stream *stream) {
    if (stream == NULL) return;
    ZSTD_freeCCtx(stream->context);
    free(stream);
}

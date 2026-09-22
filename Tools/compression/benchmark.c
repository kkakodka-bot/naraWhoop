#include "noop_zstd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static double seconds(struct timespec t) { return (double)t.tv_sec + (double)t.tv_nsec / 1e9; }
static double cpu(struct rusage r) {
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 + r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}
static long long rss(struct rusage r) {
#ifdef __APPLE__
    return r.ru_maxrss;
#else
    return (long long)r.ru_maxrss * 1024;
#endif
}

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    int level = atoi(argv[2]), iterations = atoi(argv[3]);
    if ((level != 1 && level != 3) || iterations < 1 || iterations > 1000) return 2;
    FILE *input = fopen(argv[1], "rb");
    if (!input || fseek(input, 0, SEEK_END)) return 3;
    long length = ftell(input);
    if (length < 0 || length > 64 * 1024 * 1024 || fseek(input, 0, SEEK_SET)) return 3;
    size_t count = (size_t)length;
    unsigned char *bytes = malloc(count ? count : 1);
    if (!bytes || fread(bytes, 1, count, input) != count) return 3;
    fclose(input);
    struct rusage before, after;
    struct timespec start, end;
    getrusage(RUSAGE_SELF, &before);
    clock_gettime(CLOCK_MONOTONIC, &start);
    unsigned char *wire = NULL;
    size_t wire_count = 0;
    for (int i = 0; i < iterations; i++) {
        noop_zstd_free(wire);
        if (noop_zstd_compress_level(bytes, count, level, &wire, &wire_count)) return 4;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    getrusage(RUSAGE_SELF, &after);
    unsigned char *decoded = malloc(count ? count : 1);
    size_t decoded_count = 0;
    if (!decoded || noop_zstd_decompress(wire, wire_count, decoded, count ? count : 1, &decoded_count) ||
        decoded_count != count || memcmp(bytes, decoded, count)) return 5;
    FILE *output = fopen(argv[4], "wb");
    if (!output || fwrite(wire, 1, wire_count, output) != wire_count || fclose(output)) return 6;
    printf("{\"codec_version\":%u,\"level\":%d,\"iterations\":%d,\"input_bytes\":%zu,"
           "\"wire_bytes\":%zu,\"wall_seconds\":%.9f,\"cpu_seconds\":%.9f,"
           "\"baseline_rss_bytes\":%lld,\"peak_rss_bytes\":%lld,\"roundtrip_verified\":true}\n",
           noop_zstd_version(), level, iterations, count, wire_count, seconds(end) - seconds(start),
           cpu(after) - cpu(before), rss(before), rss(after));
    free(bytes); free(decoded); noop_zstd_free(wire);
    return 0;
}

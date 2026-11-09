/* Sector-sized libcaes backend comparison; synthetic keys only. */
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libcaes_context.h"
#include "libcaes_tweaked_context.h"
#include "libcaes_definitions.h"

static libcerror_error_t *error;
static void check(int result) {
    if (result != 1) {
        libcerror_error_backtrace_fprint(error, stderr);
        libcerror_error_free(&error);
        exit(1);
    }
}
static double now(void) {
#ifdef _WIN32
    LARGE_INTEGER ticks, frequency;
    QueryPerformanceCounter(&ticks);
    QueryPerformanceFrequency(&frequency);
    return (double)ticks.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) exit(1);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
#endif
}
/* CBC NIST SP 800-38A F.2.1, independently published expected ciphertext. */
static void known_answer(void) {
    const unsigned char key[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
    const unsigned char iv[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const unsigned char plain[16] = {0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a};
    const unsigned char cipher[16] = {0x76,0x49,0xab,0xac,0x81,0x19,0xb2,0x46,0xce,0xe9,0x8e,0x9b,0x12,0xe9,0x19,0x7d};
    unsigned char out[16] = {0};
    libcaes_context_t *ctx = NULL;
    check(libcaes_context_initialize(&ctx, &error));
    check(libcaes_context_set_key(ctx, 0, key, 128, &error));
    check(libcaes_crypt_cbc(ctx, 0, iv, 16, cipher, 16, out, 16, &error));
    if (memcmp(out, plain, 16)) { fputs("CBC known answer mismatch\n", stderr); exit(1); }
    check(libcaes_context_free(&ctx, &error));
}
/* libbde configure's runtime probe cannot run when cross-compiling. */
static void duplicate_xts_keys(FILE *vectors) {
    unsigned char key[32] = {0}, iv[16] = {0}, input[512] = {0}, out[512];
    int bits;
    for (bits = 128; bits <= 256; bits += 128) {
        libcaes_tweaked_context_t *ctx = NULL;
        check(libcaes_tweaked_context_initialize(&ctx, &error));
        check(libcaes_tweaked_context_set_keys(ctx, 0, key, bits, key, bits, &error));
        check(libcaes_crypt_xts(ctx, 0, iv, 16, input, sizeof(input), out, sizeof(out), &error));
        if (vectors && fwrite(out, 1, sizeof(out), vectors) != sizeof(out)) exit(1);
        check(libcaes_tweaked_context_free(&ctx, &error));
    }
}
int main(int argc, char **argv) {
    unsigned char key[32], tweak_key[32], iv[16] = {0}, plain[4096], cipher[4096], out[4096];
    FILE *vectors = argc == 2 ? fopen(argv[1], "wb") : NULL;
    int xts, bits, size, round, i;
    if (argc == 2 && !vectors) return 1;
    known_answer();
    duplicate_xts_keys(vectors);
    for (i = 0; i < 32; i++) { key[i] = (unsigned char)i; tweak_key[i] = (unsigned char)(i + 73); }
    for (i = 0; i < 4096; i++) plain[i] = (unsigned char)(i * 13 + i / 512);
    puts("mode,key_bits,sector_bytes,round,ms,mib_per_second");
    for (xts = 0; xts <= 1; xts++) for (bits = 128; bits <= 256; bits += 128) {
        libcaes_context_t *enc = NULL, *dec = NULL;
        libcaes_tweaked_context_t *te = NULL, *td = NULL;
        if (xts) {
            check(libcaes_tweaked_context_initialize(&te, &error));
            check(libcaes_tweaked_context_initialize(&td, &error));
            check(libcaes_tweaked_context_set_keys(te, 1, key, bits, tweak_key, bits, &error));
            check(libcaes_tweaked_context_set_keys(td, 0, key, bits, tweak_key, bits, &error));
        } else {
            check(libcaes_context_initialize(&enc, &error));
            check(libcaes_context_initialize(&dec, &error));
            check(libcaes_context_set_key(enc, 1, key, bits, &error));
            check(libcaes_context_set_key(dec, 0, key, bits, &error));
        }
        for (size = 512; size <= 4096; size *= 8) {
            /* Different sector numbers catch incorrect tweak/context reuse. */
            for (i = 0; i < 32; i++) {
                iv[0] = (unsigned char)i; iv[8] = (unsigned char)(31-i);
                if (xts) {
                    check(libcaes_crypt_xts(te, 1, iv, 16, plain, size, cipher, size, &error));
                    check(libcaes_crypt_xts(td, 0, iv, 16, cipher, size, out, size, &error));
                } else {
                    check(libcaes_crypt_cbc(enc, 1, iv, 16, plain, size, cipher, size, &error));
                    check(libcaes_crypt_cbc(dec, 0, iv, 16, cipher, size, out, size, &error));
                }
                if (memcmp(out, plain, size)) { fputs("Roundtrip mismatch\n", stderr); return 1; }
                if (vectors && fwrite(cipher, 1, size, vectors) != (size_t)size) return 1;
            }
            for (round = 0; round < 5; round++) {
                const int count = 32 * 1024 * 1024 / size;
                double start = now(), elapsed;
                for (i = 0; i < count; i++) {
                    iv[0] = (unsigned char)i; iv[1] = (unsigned char)(i >> 8);
                    if (xts) check(libcaes_crypt_xts(td, 0, iv, 16, cipher, size, out, size, &error));
                    else check(libcaes_crypt_cbc(dec, 0, iv, 16, cipher, size, out, size, &error));
                }
                elapsed = now() - start;
                printf("%s,%d,%d,%d,%.3f,%.3f\n", xts ? "XTS" : "CBC", bits, size, round, elapsed * 1000, 32 / elapsed);
            }
        }
        if (xts) { check(libcaes_tweaked_context_free(&te, &error)); check(libcaes_tweaked_context_free(&td, &error)); }
        else { check(libcaes_context_free(&enc, &error)); check(libcaes_context_free(&dec, &error)); }
    }
    if (vectors && fclose(vectors)) return 1;
    return 0;
}

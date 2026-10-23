#include "IdentityScan.h"
#include <CommonCrypto/CommonDigest.h>
#include <string.h>

// Pure in-memory bounded hash comparison. No files, network, logging or secrets
// persisted. The caller controls the range, concurrency and total time budget.
uint64_t ts_scan_identity(uint64_t begin, uint64_t end, const unsigned char *target) {
    char digits[24];
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    uint64_t n = begin;
    int length = 0;
    do { digits[length++] = (char)('0' + n % 10); n /= 10; } while (n);
    for (int i = 0; i < length / 2; i++) {
        char tmp = digits[i]; digits[i] = digits[length - 1 - i]; digits[length - 1 - i] = tmp;
    }
    for (n = begin; n < end; n++) {
        CC_SHA512(digits, (CC_LONG)length, digest);
        if (memcmp(digest, target, sizeof(digest)) == 0) return n;
        int i = length - 1;
        while (i >= 0 && digits[i] == '9') { digits[i] = '0'; i--; }
        if (i >= 0) digits[i]++;
        else { memmove(digits + 1, digits, (size_t)length); digits[0] = '1'; length++; }
    }
    return UINT64_MAX;
}

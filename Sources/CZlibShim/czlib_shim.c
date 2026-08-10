// SPDX-License-Identifier: GPL-3.0-or-later

#include "czlib_shim.h"
#include <zlib.h>

size_t czlib_compress_bound(size_t src_len) {
    return (size_t)compressBound((uLong)src_len);
}

int czlib_compress(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t *dst_len, int level) {
    uLongf compressed_len = (uLongf)*dst_len;
    int status = compress2((Bytef *)dst, &compressed_len,
                           (const Bytef *)src, (uLong)src_len, level);
    *dst_len = (size_t)compressed_len;
    return status;
}

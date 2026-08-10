// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef CZLIB_SHIM_H
#define CZLIB_SHIM_H

#include <stddef.h>

// Compress `src` into `dst` in zlib/RFC-1950 format at the given deflate
// `level`. On input `*dst_len` is the capacity of `dst`; on success it holds
// the compressed length. Returns the zlib status (0 == Z_OK).
//
// zlib is lossless, so any valid level yields a stream that inflates back to
// identical bytes. The compressed form can differ by level, so the caller
// chooses the wire representation.
int czlib_compress(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t *dst_len, int level);

// Upper bound on the compressed size for `src_len` input bytes.
size_t czlib_compress_bound(size_t src_len);

#endif /* CZLIB_SHIM_H */

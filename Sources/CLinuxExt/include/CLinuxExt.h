//===----------------------------------------------------------------------===//
//
//  CLinuxExt.h
//  CLinuxExt
//
//  Thin wrappers for GNU-extension syscalls that Swift's Glibc module
//  does not expose. Server-level helpers only — the epoll/eventfd
//  wrappers live in the standalone mio package (CMIO target).
//
//===----------------------------------------------------------------------===//

#ifndef CLINUXEXT_H
#define CLINUXEXT_H

#ifdef __linux__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Accept a connection, atomically setting SOCK_NONBLOCK | SOCK_CLOEXEC
/// on the returned fd. Wrapper around accept4(2).
int sl_accept4(int fd);

/// Pin the calling thread to CPU `cpu`. Wrapper around sched_setaffinity(2).
void sl_pin_to_cpu(int cpu);

/// Bind a TCP listener on `(host, port)` with SO_REUSEADDR | SO_REUSEPORT
/// and listen(2). Returns the listening fd (≥ 0) on success, or -errno on
/// failure. `host` is a NUL-terminated C string (may be NULL for
/// INADDR_ANY); `port` is the port number.
int sl_bind_listener(const char *host, int port);

/// Zero-copy file→socket transfer. Wrapper around sendfile(2).
/// Returns bytes sent, or -1 on error.
long sl_sendfile(int out_fd, int in_fd, long offset, long count);

/// Compress data using gzip (zlib). Returns compressed size, or -1 on error.
/// `output` must be at least `input_len + 64` bytes.
long sl_gzip_compress(const unsigned char *input, long input_len,
                      unsigned char *output, long output_len, int level);

#ifdef __cplusplus
}
#endif

#endif /* __linux__ */
#endif /* CLINUXEXT_H */

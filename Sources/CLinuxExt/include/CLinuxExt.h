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

#ifdef __cplusplus
}
#endif

#endif /* __linux__ */
#endif /* CLINUXEXT_H */

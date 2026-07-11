//===----------------------------------------------------------------------===//
//
//  CLinuxExt.h
//  CLinuxExt
//
//  Thin wrappers for GNU-extension syscalls that Swift's Glibc module
//  does not expose. No ring management — that is Apple SystemPackage.IORing.
//
//===----------------------------------------------------------------------===//

#ifndef CLINUXEXT_H
#define CLINUXEXT_H

#ifdef __linux__

/// Accept a connection, atomically setting SOCK_NONBLOCK | SOCK_CLOEXEC
/// on the returned fd. Wrapper around accept4(2).
int sl_accept4(int fd);

/// Create an eventfd. Wrapper around eventfd(2).
int sl_eventfd(unsigned int initval, int flags);

/// Create a pipe with atomic flags. Wrapper around pipe2(2).
int sl_pipe2(int fds[2], int flags);

/// Pin the calling thread to CPU `cpu`. Wrapper around sched_setaffinity(2).
void sl_pin_to_cpu(int cpu);

#endif /* __linux__ */
#endif /* CLINUXEXT_H */

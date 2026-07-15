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

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Accept a connection, atomically setting SOCK_NONBLOCK | SOCK_CLOEXEC
/// on the returned fd. Wrapper around accept4(2).
int sl_accept4(int fd);

/// Create an eventfd. Wrapper around eventfd(2).
int sl_eventfd(unsigned int initval, int flags);

/// Create a pipe with atomic flags. Wrapper around pipe2(2).
int sl_pipe2(int fds[2], int flags);

/// Pin the calling thread to CPU `cpu`. Wrapper around sched_setaffinity(2).
void sl_pin_to_cpu(int cpu);

// ─── epoll wrappers ────────────────────────────────────────────────────
//
// Swift's Glibc module does not expose <sys/epoll.h>. These thin wrappers
// provide the full epoll(7) surface that StarlightPoll needs.
//
// `sl_epoll_event` is declared `__packed__` to match the kernel's 12-byte
// `struct epoll_event` ABI exactly (4-byte events + 8-byte data, no padding).
// epoll_wait(2) writes contiguous 12-byte records into the caller-supplied
// buffer; any compiler-inserted padding would corrupt the result. Swift
// imports this struct verbatim and the Clang importer honours the packed
// attribute, so array allocation via
// `UnsafeMutablePointer<sl_epoll_event>.allocate(capacity:)` is safe.

/// Mirror of `struct epoll_event` from <sys/epoll.h>.
/// 12 bytes, packed. `data` carries the user-supplied Token (u64).
typedef struct __attribute__((packed)) sl_epoll_event {
    uint32_t events;   /* EPOLLIN | EPOLLOUT | ... */
    uint64_t data;     /* Token raw value */
} sl_epoll_event;

/// Create an epoll fd with EPOLL_CLOEXEC. Wrapper around epoll_create1(2).
/// Returns fd ≥ 0, or -errno on failure.
int sl_epoll_create1(void);

/// Add `fd` to the epoll interest list. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev). Returns 0 on success, -errno on
/// failure.
int sl_epoll_ctl_add(int epfd, int fd, uint32_t events, uint64_t data);

/// Modify an already-registered `fd`. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev). Returns 0 on success, -errno on
/// failure.
int sl_epoll_ctl_mod(int epfd, int fd, uint32_t events, uint64_t data);

/// Remove `fd` from the epoll interest list. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL). Returns 0 on success, -errno on
/// failure.
int sl_epoll_ctl_del(int epfd, int fd);

/// Block waiting for events. Wrapper around epoll_wait(2).
/// Writes up to `maxevents` records into `events` (caller-allocated).
/// Returns the number of events delivered, 0 on timeout, or -errno on
/// failure (note: EINTR is reported as -EINTR; the caller may retry).
int sl_epoll_wait(int epfd, sl_epoll_event *events, int maxevents, int timeout);

#ifdef __cplusplus
}
#endif

#endif /* __linux__ */
#endif /* CLINUXEXT_H */

//===----------------------------------------------------------------------===//
//
//  helper.c
//  CLinuxExt
//
//  GNU-extension wrappers for the server layer (accept4, eventfd,
//  sched_setaffinity). The epoll/eventfd-wait wrappers used by the
//  readiness primitives now live in the mio package.
//
//===----------------------------------------------------------------------===//

#define _GNU_SOURCE
#ifdef __linux__

#include "CLinuxExt.h"
#include <sched.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>

int sl_accept4(int fd) {
    return accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

void sl_pin_to_cpu(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

#endif /* __linux__ */

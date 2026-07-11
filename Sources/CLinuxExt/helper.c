//===----------------------------------------------------------------------===//
//
//  helper.c
//  CLinuxExt
//
//  GNU-extension wrappers — ~15 lines of C, nothing more.
//
//===----------------------------------------------------------------------===//

#define _GNU_SOURCE
#ifdef __linux__

#include "CLinuxExt.h"
#include <sched.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <unistd.h>

int sl_accept4(int fd) {
    return accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

int sl_eventfd(unsigned int initval, int flags) {
    return eventfd(initval, flags);
}

int sl_pipe2(int fds[2], int flags) {
    return pipe2(fds, flags);
}

void sl_pin_to_cpu(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

#endif /* __linux__ */

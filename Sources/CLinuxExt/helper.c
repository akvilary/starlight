//===----------------------------------------------------------------------===//
//
//  helper.c
//  CLinuxExt
//
//  GNU-extension wrappers for the server layer (accept4,
//  sched_setaffinity, bind+listen with SO_REUSEPORT). The
//  epoll/eventfd-wait wrappers used by the readiness primitives
//  now live in the mio package.
//
//===----------------------------------------------------------------------===//

#define _GNU_SOURCE
#ifdef __linux__

#include "CLinuxExt.h"
#include <sched.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

int sl_accept4(int fd) {
    return accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

void sl_pin_to_cpu(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

int sl_bind_listener(const char *host, int port) {
    // Resolve `host` (or "0.0.0.0" if NULL) using getaddrinfo so the
    // caller can pass either an IP literal or a hostname. We ask for
    // AF_UNSPEC and TCP, then bind the first viable result.
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags    = AI_PASSIVE;

    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);

    struct addrinfo *result = NULL;
    int rc = getaddrinfo(host, port_str, &hints, &result);
    if (rc != 0) {
        return -EADDRNOTAVAIL;
    }

    int fd = -1;
    for (struct addrinfo *ai = result; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family,
                    ai->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC,
                    ai->ai_protocol);
        if (fd < 0) continue;

        int one = 1;
        // SO_REUSEADDR — quick rebinding after restart.
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0) {
            close(fd); fd = -1; continue;
        }
        // SO_REUSEPORT — kernel load-balances accept across worker loops.
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0) {
            close(fd); fd = -1; continue;
        }

        if (bind(fd, ai->ai_addr, ai->ai_addrlen) < 0) {
            int saved = errno;
            close(fd); fd = -1;
            errno = saved;
            continue;
        }

        // listen(2) with a 1024-deep backlog — large enough that a busy
        // server doesn't drop connections between accept bursts.
        if (listen(fd, 1024) < 0) {
            int saved = errno;
            close(fd); fd = -1;
            errno = saved;
            continue;
        }

        break;  // success
    }

    freeaddrinfo(result);
    if (fd < 0) {
        return -errno;
    }
    return fd;
}

#endif /* __linux__ */

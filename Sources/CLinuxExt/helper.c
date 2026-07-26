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
#include <signal.h>
#include <pthread.h>
#include <sys/sendfile.h>
#include <zlib.h>
#include <sys/stat.h>
#include <fcntl.h>

int sl_accept4(int fd) {
    int accepted = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    return accepted < 0 ? -errno : accepted;
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

// ── sendfile(2) zero-copy file→socket transfer ──────────────────
long sl_sendfile(int out_fd, int in_fd, long offset, long count) {
    off_t off = (off_t)offset;
    ssize_t n = sendfile(out_fd, in_fd, &off, (size_t)count);
    return (long)n;
}

// ── gzip compression via zlib ────────────────────────────────────
long sl_gzip_compress(const unsigned char *input, long input_len,
                      unsigned char *output, long output_len, int level) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // 15 + 16 = gzip encoding (window bits + gzip header)
    int ret = deflateInit2(&stream, level, Z_DEFLATED,
                           15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) return -1;

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;
    stream.next_out = (Bytef *)output;
    stream.avail_out = (uInt)output_len;

    ret = deflate(&stream, Z_FINISH);
    long total = (long)stream.total_out;
    deflateEnd(&stream);

    if (ret != Z_STREAM_END) return -1;
    return total;
}

// ─── Signal handling ────────────────────────────────────────────────

void sl_install_shutdown_handlers(void (*handler)(int)) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = SA_RESTART;  // auto-restart interrupted syscalls
    sigemptyset(&sa.sa_mask);  // don't block extra signals during handler

    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    // Unblock SIGINT/SIGTERM in case the parent process (e.g. systemd)
    // blocked them in the process signal mask. Without this, the handler
    // never fires and the server can't shut down gracefully.
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGTERM);
    pthread_sigmask(SIG_UNBLOCK, &mask, NULL);
}

#endif /* __linux__ */

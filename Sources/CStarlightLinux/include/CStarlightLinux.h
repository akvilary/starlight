//===----------------------------------------------------------------------===//
//
//  CStarlightLinux.h
//  CStarlightLinux
//
//  Self-contained io_uring C shim — zero external dependencies.
//
//  Uses the kernel UAPI header <linux/io_uring.h> when available
//  (standard on virtually all Linux systems). Falls back to inline
//  struct definitions for minimal Docker images that lack
//  linux-headers. The io_uring UAPI is a stable kernel ABI —
//  struct layouts never change (new fields are appended, never
//  reordered or removed).
//
//  Reference: liburing 2.7 src/setup.c, src/queue.c
//
//===----------------------------------------------------------------------===//

#ifndef CSTARLIGHTLINUX_H
#define CSTARLIGHTLINUX_H

#ifdef __linux__

/* ── io_uring UAPI types ──────────────────────────────────────────────── */

#if __has_include(<linux/io_uring.h>)

/* System kernel header — preferred path. */
#include <linux/io_uring.h>

#else
/*
 * Fallback definitions for images without linux-headers.
 * These match the kernel UAPI exactly (linux/io_uring.h).
 * Verified against kernel 6.x source.
 */

#include <stdint.h>
typedef int8_t   __s8;
typedef uint8_t  __u8;
typedef int16_t  __s16;
typedef uint16_t __u16;
typedef int32_t  __s32;
typedef uint32_t __u32;
typedef int64_t  __s64;
typedef uint64_t __u64;

/* SQE — submission queue entry (64 bytes) */
struct io_uring_sqe {
    __u8  opcode;       /*  0: IORING_OP_*                  */
    __u8  flags;        /*  1: IOSQE_*                      */
    __u16 ioprio;       /*  2:                              */
    __s32 fd;           /*  4: file descriptor              */
    __u64 off;          /*  8: offset / addr2               */
    __u64 addr;         /* 16: buffer pointer / splice_off  */
    __u32 len;          /* 24: buffer length                */
    __u32 rw_flags;     /* 28: union of all *_flags         */
    __u64 user_data;    /* 32: tag returned in CQE          */
    __u16 buf_index;    /* 40:                              */
    __u16 buf_group;    /* 42:                              */
    __u32 __pad1;       /* 44:                              */
    __u64 __pad2;       /* 48: union: addr3 / timeout / ... */
    __u32 __pad3;       /* 56:                              */
    __u32 __pad4;       /* 60:                              */
};

/* CQE — completion queue entry (16 bytes) */
struct io_uring_cqe {
    __s32 res;          /*  0: result (bytes, or -errno)    */
    __u32 flags;        /*  4: IORING_CQE_F_*               */
    __u64 user_data;    /*  8: tag from SQE                 */
};

struct io_sqring_offsets {
    __u32 head, tail, ring_mask, ring_entries, flags, dropped, array;
    __u32 resv1;
    __u64 resv2;
};

struct io_cqring_offsets {
    __u32 head, tail, ring_mask, ring_entries, overflow, cqes, flags;
    __u32 resv1;
    __u64 resv2;
};

struct io_uring_params {
    __u32 sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle;
    __u32 features, wq_fd;
    __u32 resv[3];
    struct io_sqring_offsets sq_off;
    struct io_cqring_offsets cq_off;
};

/* io_uring_setup flags (we use none — simplest path) */

/* ── io_uring opcodes ───────────────────────────────────────────────────
 * These values match the kernel's enum io_uring_op exactly.
 * Verified against /usr/include/linux/io_uring.h (kernel 6.x).
 * DO NOT change these — they are kernel ABI.
 *
 * Full enum reference (we only need the 5 listed here):
 *   0=NOP 1=READV 2=WRITEV 3=FSYNC 4=READ_FIXED 5=WRITE_FIXED
 *   6=POLL_ADD 7=POLL_REMOVE 8=SYNC_FILE_RANGE 9=SENDMSG 10=RECVMSG
 *  11=TIMEOUT 12=TIMEOUT_REMOVE 13=ACCEPT 14=ASYNC_CANCEL 15=LINK_TIMEOUT
 *  16=CONNECT 17=FALLOCATE 18=OPENAT 19=CLOSE 20=FILES_UPDATE 21=STATX
 *  22=READ 23=WRITE 24=FADVISE 25=MADVISE 26=SEND 27=RECV ...
 */
#define IORING_OP_NOP        0
#define IORING_OP_POLL_ADD   6
#define IORING_OP_ACCEPT     13
#define IORING_OP_SEND       26
#define IORING_OP_RECV       27

/* io_uring_enter flags */
#define IORING_ENTER_GETEVENTS (1U << 0)

/* mmap offsets */
#define IORING_OFF_SQ_RING  0ULL
#define IORING_OFF_CQ_RING  0x8000000ULL
#define IORING_OFF_SQES     0x10000000ULL

/* feature: single mmap for SQ+CQ (kernel ≥ 5.5) */
#define IORING_FEAT_SINGLE_MMAP (1U << 0)

/* syscall numbers (x86_64, stable ABI) */
#define __NR_io_uring_setup    425
#define __NR_io_uring_enter    426
#define __NR_io_uring_register 427

#endif /* __has_include(<linux/io_uring.h>) */

/* ── Socket + system headers ──────────────────────────────────────────── */
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/eventfd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* ── Ring handle ──────────────────────────────────────────────────────── */

/*
 * Holds the mmap'd ring pointers. Analogous to liburing's
 * (io_uring + io_uring_sq + io_uring_cq) combined.
 *
 * The SQ ring uses a three-counter design (from liburing):
 *   sqe_tail  — userspace-side, incremented by sl_get_sqe
 *   sqe_head  — userspace-side, synced to kernel during sl_submit
 *   *sq_ktail — kernel-visible SQ tail, updated atomically during submit
 *   *sq_khead — kernel-visible SQ head (kernel advances it as it consumes SQEs)
 */
struct sl_ring {
    int ring_fd;

    /* SQ ring — mmap'd at IORING_OFF_SQ_RING */
    void    *sq_ring_ptr;
    unsigned *sq_khead;        /* kernel head (read-only for us)     */
    unsigned *sq_ktail;        /* kernel tail (we write, release)    */
    unsigned *sq_kmask;        /* ring mask = entries - 1            */
    unsigned *sq_kentries;     /* ring entries count                 */
    unsigned *sq_array;        /* SQ index array (identity-mapped)   */
    size_t   sq_ring_sz;

    /* SQE array — mmap'd at IORING_OFF_SQES */
    struct io_uring_sqe *sqes;
    size_t sqes_sz;

    /* CQ ring — mmap'd at IORING_OFF_CQ_RING (or same as SQ if SINGLE_MMAP) */
    void    *cq_ring_ptr;
    unsigned *cq_khead;        /* CQ head (we advance after reading) */
    unsigned *cq_ktail;        /* CQ tail (kernel advances on done)  */
    unsigned *cq_kmask;
    struct io_uring_cqe *cqes;
    size_t   cq_ring_sz;

    /* userspace-side SQE counters */
    unsigned sqe_head;
    unsigned sqe_tail;
};

/* ── API ──────────────────────────────────────────────────────────────── */

/*
 * Create an io_uring instance with `entries` submission entries.
 * Returns 0 on success, negative errno on failure.
 * The SQ array is identity-mapped internally (array[i] = i),
 * matching liburing's behaviour.
 */
int sl_ring_init(struct sl_ring *r, unsigned entries);

/*
 * Tear down: munmap all regions, close ring fd.
 */
void sl_ring_exit(struct sl_ring *r);

/*
 * Obtain a free SQE slot. Returns NULL if the ring is full.
 * The SQE is zero-initialised before returning.
 *
 * Thread-safety: must be called from a single thread (the event loop
 * thread that owns this ring).
 */
struct io_uring_sqe *sl_get_sqe(struct sl_ring *r);

/*
 * Flush pending SQEs to the kernel and call io_uring_enter.
 * Returns the number of SQEs submitted, or negative errno.
 */
int sl_submit(struct sl_ring *r);

/*
 * Flush pending SQEs and wait for at least one completion.
 * Sets *cqe_out to the CQE pointer. Returns 0 on success,
 * negative errno on error.
 *
 * The caller MUST call sl_cqe_seen() after processing the CQE.
 */
int sl_wait_cqe(struct sl_ring *r, struct io_uring_cqe **cqe_out);

/*
 * Non-blocking peek for a completion.
 * Sets *cqe_out if available, sets to NULL if none.
 * Returns 1 if a CQE was found, 0 if none, negative on error.
 */
int sl_peek_cqe(struct sl_ring *r, struct io_uring_cqe **cqe_out);

/*
 * Advance the CQ head by one — marks the CQE as consumed.
 * Must be called exactly once per CQE obtained from sl_wait_cqe / sl_peek_cqe.
 */
void sl_cqe_seen(struct sl_ring *r);

/*
 * Read the 64-bit user_data tag from a CQE.
 */
static inline unsigned long long sl_cqe_data(const struct io_uring_cqe *cqe) {
    return (unsigned long long)cqe->user_data;
}

/*
 * Write a 64-bit user_data tag into an SQE.
 */
static inline void sl_sqe_set_data(struct io_uring_sqe *sqe,
                                   unsigned long long data) {
    sqe->user_data = (__u64)data;
}

/* ── SQE prep helpers (inline, zero overhead) ─────────────────────────── */

static inline void sl_prep_accept(struct io_uring_sqe *sqe, int fd) {
    /* POLL_ADD on listener fd (like NIO). When it fires, the loop
     * calls sl_accept4() directly. Avoids EINVAL issues with
     * IORING_OP_ACCEPT on some kernel configs. */
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_POLL_ADD;
    sqe->fd = fd;
    sqe->rw_flags = 0x001;  /* POLLIN */
}

/// Direct accept4 syscall — declared in shim.c (requires _GNU_SOURCE).
int sl_accept4(int fd);

static inline void sl_prep_recv(struct io_uring_sqe *sqe, int fd,
                                void *buf, unsigned len) {
    sqe->opcode = IORING_OP_RECV;
    sqe->fd = fd;
    sqe->addr = (__u64)(unsigned long)buf;
    sqe->len = len;
    sqe->rw_flags = 0;
}

static inline void sl_prep_send(struct io_uring_sqe *sqe, int fd,
                                const void *buf, unsigned len) {
    sqe->opcode = IORING_OP_SEND;
    sqe->fd = fd;
    sqe->addr = (__u64)(unsigned long)buf;
    sqe->len = len;
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0x4000
#endif
    sqe->rw_flags = MSG_NOSIGNAL;
}

static inline void sl_prep_poll_add(struct io_uring_sqe *sqe, int fd,
                                    unsigned poll_mask, int multishot) {
    sqe->opcode = IORING_OP_POLL_ADD;
    sqe->fd = fd;
    sqe->rw_flags = poll_mask & 0xFFFF;  /* poll_events is 16-bit */
    if (multishot)
        sqe->len = 1;  /* IORING_POLL_ADD_MULTI = (1U << 0) */
    else
        sqe->len = 0;
}

/* ── Socket helpers ───────────────────────────────────────────────────── */

/*
 * Create a non-blocking TCP listener with SO_REUSEADDR + SO_REUSEPORT.
 * Returns the fd, or negative errno.
 */
int sl_listen(const char *host, int port, int backlog);

/*
 * Set TCP_NODELAY on a socket. Returns 0 on success.
 */
static inline int sl_set_tcp_nodelay(int fd) {
    int flag = 1;
    return setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
}

/*
 * Enable TCP keepalive on a socket to automatically close idle
 * connections. Probes after `idle_sec` of inactivity, every
 * `intvl_sec`, up to `cnt` times before giving up.
 *
 * This prevents resource leaks from clients that open a connection
 * and never send data (or never close it).
 */
static inline void sl_set_keepalive(int fd, int idle_sec, int intvl_sec, int cnt) {
    int flag = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &flag, sizeof(flag));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle_sec, sizeof(idle_sec));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl_sec, sizeof(intvl_sec));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
}

/// Direct accept4 syscall — declared in shim.c (requires _GNU_SOURCE).
int sl_accept4(int fd);

/// Pin the calling thread to a specific CPU core.
/// Implemented in shim.c (requires _GNU_SOURCE for sched_setaffinity).
/// Best-effort: silently ignores errors (e.g., cpu index > num cores).
void sl_pin_to_cpu(int cpu);

#endif /* __linux__ */
#endif /* CSTARLIGHTLINUX_H */

//===----------------------------------------------------------------------===//
//
//  shim.c
//  CStarlightLinux
//
//  io_uring ring management via raw syscalls — no liburing dependency.
//
//  All barrier patterns match liburing 2.7 exactly:
//    - sq_ktail write:  __atomic_store_n(..., __ATOMIC_RELEASE)
//    - sq_khead read:   __atomic_load_n(...,  __ATOMIC_ACQUIRE)
//    - cq_khead write:  __atomic_store_n(..., __ATOMIC_RELEASE)
//    - cq_ktail read:   __atomic_load_n(...,  __ATOMIC_ACQUIRE)
//
//  Reference: liburing/src/setup.c (io_uring_queue_init, io_uring_mmap)
//             liburing/src/queue.c (__io_uring_flush_sq, _io_uring_get_sqe)
//
//===----------------------------------------------------------------------===//

#define _GNU_SOURCE
#ifdef __linux__

#include "CStarlightLinux.h"
#include <sys/syscall.h>
#include <sched.h>
#include <stdlib.h>

/* ── Raw syscall wrappers ─────────────────────────────────────────────── */

static int sl_io_uring_setup(unsigned entries, struct io_uring_params *p) {
    return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int sl_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                             unsigned flags) {
    return (int)syscall(__NR_io_uring_enter, fd, to_submit,
                        min_complete, flags, NULL, 0);
}

/* ── Ring lifecycle ───────────────────────────────────────────────────── */

/*
 * Portability note: on kernel ≥ 5.5 the IORING_FEAT_SINGLE_MMAP
 * feature means SQ and CQ rings share one mmap. We handle both
 * the single-mmap and dual-mmap cases.
 */

int sl_ring_init(struct sl_ring *r, unsigned entries) {
    memset(r, 0, sizeof(*r));

    struct io_uring_params p;
    memset(&p, 0, sizeof(p));

    r->ring_fd = sl_io_uring_setup(entries, &p);
    if (r->ring_fd < 0)
        return r->ring_fd;

    /* ── Calculate mmap sizes from kernel-provided offsets ────────── */
    size_t cqe_sz = sizeof(struct io_uring_cqe);
    r->sq_ring_sz  = (size_t)p.sq_off.array +
                     (size_t)p.sq_entries * sizeof(unsigned);
    r->cq_ring_sz  = (size_t)p.cq_off.cqes +
                     (size_t)p.cq_entries * cqe_sz;

    int single_mmap = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
    if (single_mmap) {
        /* Use the larger of the two — they share one mapping. */
        if (r->cq_ring_sz > r->sq_ring_sz)
            r->sq_ring_sz = r->cq_ring_sz;
        r->cq_ring_sz = r->sq_ring_sz;
    }

    /* ── mmap SQ ring ─────────────────────────────────────────────── */
    r->sq_ring_ptr = mmap(NULL, r->sq_ring_sz,
                          PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_POPULATE,
                          r->ring_fd, IORING_OFF_SQ_RING);
    if (r->sq_ring_ptr == MAP_FAILED) {
        r->sq_ring_ptr = NULL;
        int err = -errno;
        close(r->ring_fd);
        return err;
    }

    /* ── mmap CQ ring ─────────────────────────────────────────────── */
    if (single_mmap) {
        r->cq_ring_ptr = r->sq_ring_ptr;
    } else {
        r->cq_ring_ptr = mmap(NULL, r->cq_ring_sz,
                              PROT_READ | PROT_WRITE,
                              MAP_SHARED | MAP_POPULATE,
                              r->ring_fd, IORING_OFF_CQ_RING);
        if (r->cq_ring_ptr == MAP_FAILED) {
            r->cq_ring_ptr = NULL;
            int err = -errno;
            munmap(r->sq_ring_ptr, r->sq_ring_sz);
            close(r->ring_fd);
            return err;
        }
    }

    /* ── mmap SQE array ───────────────────────────────────────────── */
    r->sqes_sz = (size_t)p.sq_entries * sizeof(struct io_uring_sqe);
    r->sqes = mmap(NULL, r->sqes_sz,
                   PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_POPULATE,
                   r->ring_fd, IORING_OFF_SQES);
    if (r->sqes == MAP_FAILED) {
        r->sqes = NULL;
        int err = -errno;
        munmap(r->sq_ring_ptr, r->sq_ring_sz);
        if (!single_mmap)
            munmap(r->cq_ring_ptr, r->cq_ring_sz);
        close(r->ring_fd);
        return err;
    }

    /* ── Set up ring pointers (into mmap'd memory) ────────────────── */

    /* SQ ring control fields */
    r->sq_khead    = (unsigned *)((char *)r->sq_ring_ptr + p.sq_off.head);
    r->sq_ktail    = (unsigned *)((char *)r->sq_ring_ptr + p.sq_off.tail);
    r->sq_kmask    = (unsigned *)((char *)r->sq_ring_ptr + p.sq_off.ring_mask);
    r->sq_kentries = (unsigned *)((char *)r->sq_ring_ptr + p.sq_off.ring_entries);
    r->sq_array    = (unsigned *)((char *)r->sq_ring_ptr + p.sq_off.array);

    /* CQ ring control fields */
    r->cq_khead = (unsigned *)((char *)r->cq_ring_ptr + p.cq_off.head);
    r->cq_ktail = (unsigned *)((char *)r->cq_ring_ptr + p.cq_off.tail);
    r->cq_kmask = (unsigned *)((char *)r->cq_ring_ptr + p.cq_off.ring_mask);
    r->cqes     = (struct io_uring_cqe *)
                      ((char *)r->cq_ring_ptr + p.cq_off.cqes);

    /* ── Identity-map the SQ array ──────────────────────────────────
     *
     * The kernel reads sq_array[head & mask] to find the SQE index.
     * Identity mapping (array[i] = i) means the SQE index equals the
     * ring position — the simplest correct setup. liburing does this
     * in io_uring_queue_init. Without it the kernel would read
     * uninitialized indices and crash.
     */
    for (unsigned i = 0; i < p.sq_entries; i++)
        r->sq_array[i] = i;

    /* Userspace SQE counters start at 0 */
    r->sqe_head = 0;
    r->sqe_tail = 0;

    return 0;
}

void sl_ring_exit(struct sl_ring *r) {
    if (r->sqes)
        munmap(r->sqes, r->sqes_sz);
    if (r->sq_ring_ptr) {
        munmap(r->sq_ring_ptr, r->sq_ring_sz);
        /* If single-mmap, CQ shares SQ's mapping — don't double-unmap. */
        if (r->cq_ring_ptr && r->cq_ring_ptr != r->sq_ring_ptr)
            munmap(r->cq_ring_ptr, r->cq_ring_sz);
    }
    if (r->ring_fd >= 0)
        close(r->ring_fd);
    memset(r, 0, sizeof(*r));
    r->ring_fd = -1;
}

/* ── SQE submission ───────────────────────────────────────────────────── */

struct io_uring_sqe *sl_get_sqe(struct sl_ring *r) {
    /*
     * Mirror of liburing's _io_uring_get_sqe.
     *
     * sq_khead is written by the kernel (it advances head as it
     * consumes SQEs). We read it with acquire ordering to ensure
     * we see all kernel reads of SQE data before we decide the
     * ring is not full.
     *
     * sqe_tail is our private userspace counter — no barrier needed.
     */
    unsigned head = __atomic_load_n(r->sq_khead, __ATOMIC_ACQUIRE);
    unsigned tail = r->sqe_tail;
    unsigned entries = *r->sq_kentries;

    if (tail - head >= entries)
        return NULL;  /* ring full */

    unsigned index = tail & *r->sq_kmask;
    struct io_uring_sqe *sqe = &r->sqes[index];
    memset(sqe, 0, sizeof(*sqe));
    r->sqe_tail = tail + 1;
    return sqe;
}

/*
 * Internal: flush userspace SQEs to the kernel-visible SQ ring.
 *
 * Updates *sq_ktail with release ordering so the kernel sees SQE
 * field writes BEFORE the tail advance. This is the critical
 * synchronization point.
 *
 * Returns the number of SQEs now visible to the kernel (total
 * pending = tail - kernel_head).
 */
static unsigned sl_flush_sq(struct sl_ring *r) {
    unsigned tail = r->sqe_tail;

    if (r->sqe_head != tail) {
        r->sqe_head = tail;
        /*
         * RELEASE: pairs with the kernel's ACQUIRE read of ktail.
         * Ensures all SQE field writes (opcode, fd, addr, len,
         * user_data) are visible to the kernel before it sees
         * the new tail.
         */
        __atomic_store_n(r->sq_ktail, tail, __ATOMIC_RELEASE);
    }

    /*
     * RELAXED is sufficient for khead here — the kernel advances
     * khead only to signal "I'm done reading these SQEs, you can
     * reuse the slots." We use it only to compute how many SQEs
     * are in flight.
     */
    unsigned khead = __atomic_load_n(r->sq_khead, __ATOMIC_RELAXED);
    return tail - khead;
}

int sl_submit(struct sl_ring *r) {
    unsigned to_submit = sl_flush_sq(r);
    if (to_submit == 0)
        return 0;
    return sl_io_uring_enter(r->ring_fd, to_submit, 0, 0);
}

/* ── CQE processing ───────────────────────────────────────────────────── */

int sl_peek_cqe(struct sl_ring *r, struct io_uring_cqe **cqe_out) {
    /*
     * ACQUIRE on cq_ktail: pairs with the kernel's RELEASE write.
     * Ensures we see all CQE field writes (res, user_data) before
     * we observe the new tail.
     */
    unsigned head = __atomic_load_n(r->cq_khead, __ATOMIC_ACQUIRE);
    unsigned tail = __atomic_load_n(r->cq_ktail, __ATOMIC_ACQUIRE);

    if (head == tail) {
        *cqe_out = NULL;
        return 0;
    }

    unsigned index = head & *r->cq_kmask;
    *cqe_out = &r->cqes[index];
    return 1;
}

int sl_wait_cqe(struct sl_ring *r, struct io_uring_cqe **cqe_out) {
    /* Fast path: check without entering the kernel. */
    int ret = sl_peek_cqe(r, cqe_out);
    if (ret > 0)
        return 0;

    /* Flush any pending SQEs, then block waiting for ≥1 completion. */
    unsigned to_submit = sl_flush_sq(r);
    ret = sl_io_uring_enter(r->ring_fd, to_submit,
                            1,  /* min_complete */
                            IORING_ENTER_GETEVENTS);
    if (ret < 0)
        return ret;

    return sl_peek_cqe(r, cqe_out) > 0 ? 0 : -EAGAIN;
}

void sl_cqe_seen(struct sl_ring *r) {
    /*
     * RELEASE on cq_khead: tells the kernel "I've consumed this CQE,
     * you can reuse the slot." Ensures our reads of CQE fields
     * happened before the kernel sees the head advance.
     */
    unsigned head = __atomic_load_n(r->cq_khead, __ATOMIC_RELAXED);
    __atomic_store_n(r->cq_khead, head + 1, __ATOMIC_RELEASE);
}

/* ── Socket helper ────────────────────────────────────────────────────── */

int sl_listen(const char *host, int port, int backlog) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -errno;

    int flag = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &flag, sizeof(flag));
#endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        close(fd);
        return -EINVAL;
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int err = -errno;
        close(fd);
        return err;
    }

    if (listen(fd, backlog) < 0) {
        int err = -errno;
        close(fd);
        return err;
    }

    return fd;
}

/* ── accept4 wrapper ──────────────────────────────────────────────────── */

int sl_accept4(int fd) {
    return accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
}

/* ── CPU pinning ──────────────────────────────────────────────────────── */

void sl_pin_to_cpu(int cpu) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    sched_setaffinity(0, sizeof(cpuset), &cpuset);
}

#endif /* __linux__ */

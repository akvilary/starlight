//===----------------------------------------------------------------------===//
//
//  PollConstants.swift
//  StarlightPoll
//
//  Constants that Swift's Glibc module does not re-export. Kept in one
//  place so they can be cross-checked against <sys/epoll.h> and
//  <sys/eventfd.h>. Numeric values match Linux UAPI on every supported
//  arch (x86_64, arm64, riscv64, ppc64le).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

/// Constants not exposed by Swift's Glibc module. Values are UAPI-stable
/// on Linux and match those in `<sys/epoll.h>` and `<sys/eventfd.h>`.
@usableFromInline
internal enum PollConstants {
    // eventfd(2) flags.
    @usableFromInline static let EFD_SEMAPHORE: Int32 = 1
    @usableFromInline static let EFD_NONBLOCK:  Int32 = 2048   // O_NONBLOCK
    @usableFromInline static let EFD_CLOEXEC:   Int32 = 524288 // O_CLOEXEC
}

/// Public re-export of the flag values needed by callers constructing
/// non-blocking fds by hand (StarlightPoll already handles the waker's
/// eventfd internally; this is here for `Source` conformers).
@frozen
public enum PollFlag {
    public static let EFD_SEMAPHORE = PollConstants.EFD_SEMAPHORE
    public static let EFD_NONBLOCK  = PollConstants.EFD_NONBLOCK
    public static let EFD_CLOEXEC   = PollConstants.EFD_CLOEXEC
}

#endif // os(Linux)

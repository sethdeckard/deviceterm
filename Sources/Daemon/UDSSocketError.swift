// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UDSSocketError: Error, Equatable, Sendable {
    /// `socket(2)` returned -1.
    case socketFailed(
        errno:
        Int32
        )
    /// `bind(2)` returned -1.
    case bindFailed(
        errno:
        Int32,
        path: String
        )
    /// `listen(2)` returned -1.
    case listenFailed(
        errno:
        Int32
        )
    /// `accept(2)` returned -1 (other than EAGAIN/EWOULDBLOCK, which
    /// caller-visible as `nil` from `acceptOne`).
    case acceptFailed(
        errno:
        Int32
        )
    /// `read(2)` returned -1 (other than EAGAIN/EWOULDBLOCK/EINTR,
    /// which are handled internally).
    case readFailed(
        errno:
        Int32
        )
    /// `write(2)` returned -1 (likewise).
    case writeFailed(
        errno:
        Int32
        )
    /// `connect(2)` returned -1.
    case connectFailed(
        errno:
        Int32,
        path: String
        )
    /// `sockaddr_un.sun_path` has a fixed 104-byte ceiling on macOS;
    /// paths that exceed it are rejected before any system call.
    case socketPathTooLong(
        path:
        String
        )
    /// A live listener already owns the requested socket path, or a
    /// non-socket file sits there. A *stale* socket (no listener behind
    /// it) is self-healed by `bindListener` and does not raise this.
    case socketPathExists(
        path:
        String
        )
}

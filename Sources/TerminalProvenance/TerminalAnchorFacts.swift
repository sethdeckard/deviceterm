// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Kernel-verified facts describing a terminal, and the identity a session
/// binds. These are the exact fields a UDS peer's `PeerProcessIdentity` is
/// matched against.
///
/// The numeric foreground pid that produced these facts is never retained. The
/// stable boundary is the POSIX session id, the controlling TTY device, and the
/// session-leader start time, which together survive pid reuse.
public struct TerminalAnchorFacts: Sendable, Equatable {
    /// The terminal's POSIX session id (`getsid(foregroundPid)`).
    public let terminalSessionId: pid_t
    /// The session leader's start time, microseconds since the epoch. Guards
    /// against SID/pid reuse: a recycled session-leader pid has a different
    /// start time.
    public let sessionLeaderStartTime: UInt64
    /// The controlling terminal device (`stat(ttyName).st_rdev`), cross-checked
    /// against the foreground process' `e_tdev`.
    public let controllingTTYDevice: dev_t

    public init(
        terminalSessionId: pid_t,
        sessionLeaderStartTime: UInt64,
        controllingTTYDevice: dev_t
    ) {
        self.terminalSessionId = terminalSessionId
        self.sessionLeaderStartTime = sessionLeaderStartTime
        self.controllingTTYDevice = controllingTTYDevice
    }
}

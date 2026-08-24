// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The kernel identity of a terminal's foreground process, as reported by the
/// engine. Sent verbatim to the daemon, which re-derives the trusted anchor
/// (POSIX session id, controlling TTY device, session-leader start time) from
/// the kernel. Neither field is trusted as authority on its own.
public struct TerminalIdentity: Sendable, Equatable {
    /// The foreground process id in the terminal's PTY.
    public let foregroundPid: Int32
    /// The controlling tty device name (e.g. `/dev/ttys003`).
    public let ttyName: String

    public init(foregroundPid: Int32, ttyName: String) {
        self.foregroundPid = foregroundPid
        self.ttyName = ttyName
    }
}

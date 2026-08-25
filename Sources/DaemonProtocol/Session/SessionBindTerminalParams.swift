// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for the `session.bindTerminal`
/// RPC method that binds a session to its terminal's kernel identity.
///
/// The validated GUI reads its terminal surface's foreground process id and
/// controlling tty name from libghostty (`ghostty_surface_foreground_pid` /
/// `ghostty_surface_tty_name`) and sends them here. Neither value is authority
/// on its own. The daemon re-derives the anchor from the kernel and keeps only
/// kernel-verified facts (the POSIX session id, controlling TTY device, and
/// session-leader start time). The numeric pid is never retained.
///
/// No `(sessionId, cap)` handshake rides on this method: it is `.validatedGUI`-
/// scoped, so the peer's audit token is the authority and only the host GUI can
/// reach it. That scope, not any privileged view of the terminal, is what makes
/// the GUI the legitimate binder. Any same-uid process can read a tty's
/// foreground pid, which is why the payload is treated as a hint and verified.
public struct SessionBindTerminalParams: Codable, Sendable, Equatable {
    public let sessionId: String
    /// The terminal surface's foreground process id, from libghostty. Used
    /// only to derive the anchor (session id, tty device, leader start); the
    /// daemon does not retain it.
    public let foregroundPid: Int32
    /// The terminal's controlling tty name (e.g. `/dev/ttys003`), from
    /// libghostty. Cross-checked against the foreground process' controlling
    /// tty device before the anchor is stored.
    public let ttyName: String

    public init(sessionId: String, foregroundPid: Int32, ttyName: String) {
        self.sessionId = sessionId
        self.foregroundPid = foregroundPid
        self.ttyName = ttyName
    }
}

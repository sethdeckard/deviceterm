// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Darwin)
import Darwin

/// What a bound terminal is doing, as far as the kernel will say.
///
/// Three cases, not two. Collapsing `unknown` into `idle` is the mistake
/// worth naming: the foreground process may be unreadable, a `sudo` running
/// as root being the ordinary way, and a caller that reads "cannot tell" as
/// "nothing is running" will act as though the terminal were free. Anything
/// that types into a terminal must wait for `idle` and treat `unknown` as a
/// reason to do nothing.
public enum TerminalForegroundState: Equatable, Sendable {
    /// The terminal's foreground process is its own shell. Usually that is
    /// a prompt, but it also covers the shell running something of its own,
    /// a builtin or a `wait`, which this cannot tell apart.
    case idle
    /// The terminal is running this process.
    case running(pid_t)
    /// The kernel view is incomplete or ambiguous, so neither answer is
    /// established. Never a licence to act.
    case unknown
}
#endif

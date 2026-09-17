// SPDX-License-Identifier: GPL-3.0-or-later

/// Who raised the restart, which decides the copy and the second button: the
/// two ways a restart gets proposed.
///
/// The reason is separate from the choice (`HelperRestartChoice`) because the
/// same restart reads very differently depending on who raised it. One is the
/// app interrupting to say something is wrong, and its decline ("Keep
/// Waiting") is a statement about the diagnosis, not just a dismissal, so it
/// snoozes the detector. The other is the user asking for it, where declining
/// is an ordinary cancel and there is nothing to snooze.
enum HelperRestartReason: Sendable, Equatable {
    /// A call went unanswered and so did the ping sent after it, so the app is
    /// proposing this.
    case unresponsive
    /// The user asked for it from the menu.
    case requested
    /// The user asked to restart CoreSimulator, which takes the helper with
    /// it: the helper holds proxies into that service and has no way to
    /// invalidate one whose other end has gone, so the two restart together or
    /// the helper is left holding handles to a process that no longer exists.
    ///
    /// It carries the roster tally because the prompt names what the restart
    /// destroys, and that has to be read before the helper is stopped. After
    /// it there is nothing left to ask.
    case coreSimulator(CoreSimulatorRestartDecision.Tally)
}

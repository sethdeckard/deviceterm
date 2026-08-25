// SPDX-License-Identifier: GPL-3.0-or-later
//
// HelperRestartPrompt: the two ways a restart gets proposed, and what the
// user answered.
//
// The reason is separate from the choice because the same restart reads very
// differently depending on who raised it. One is the app interrupting to say
// something is wrong, and its decline ("Keep Waiting") is a statement about
// the diagnosis, not just a dismissal, so it snoozes the detector. The other
// is the user asking for it, where declining is an ordinary cancel and there
// is nothing to snooze.

/// Who raised the restart, which decides the copy and the second button.
enum HelperRestartReason: Sendable, Equatable {
    /// A call went unanswered and so did the ping sent after it, so the app is
    /// proposing this.
    case unresponsive
    /// The user asked for it from the menu.
    case requested
}

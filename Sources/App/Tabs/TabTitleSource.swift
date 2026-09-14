// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Which of a tab's panes its label describes.
///
/// A tab shows one label and the pane holding focus is what it should name.
/// That is two questions rather than one, because the label's sources are not
/// all terminal-shaped: the automatic tiers (OSC title, working directory,
/// session name) belong to a terminal and are also what the daemon caches per
/// session, while a focused device pane contributes only its name. Resolving
/// both at once keeps a terminal bound for the daemon cache even while a
/// device pane is the thing on screen.
struct TabTitleSource: Equatable, Sendable {
    /// Terminal whose OSC title, working directory, and session name feed the
    /// automatic label tiers and the daemon-side title cache. Always a
    /// terminal the tab currently holds.
    let terminal: TerminalPaneID
    /// Device pane holding focus, whose name outranks the terminal tiers on
    /// screen. Nil while a terminal holds focus.
    let device: PaneTarget?
}

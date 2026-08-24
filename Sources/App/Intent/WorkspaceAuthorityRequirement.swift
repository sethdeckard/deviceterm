// SPDX-License-Identifier: GPL-3.0-or-later

/// What the caller must satisfy to act on a target without a grant.
enum WorkspaceAuthorityRequirement: Equatable {
    /// The caller owns a terminal in the target's tab. `tab rename`,
    /// `pane open --terminal`, and `pane close` carry this.
    case ownership

    /// The caller owns the target tab's *only* terminal. `tab close`
    /// and `window close` carry this: a split tab holds independent
    /// sessions, so closing it ends someone else's work, which is the
    /// same cross-session destruction as closing a foreign tab by a
    /// different route.
    case soleTerminal
}

// SPDX-License-Identifier: GPL-3.0-or-later

/// The resolved target, reduced to what the decision needs.
struct WorkspaceAuthorityTarget: Equatable {
    /// Whether the caller's session holds a terminal in the tab.
    let callerOwnsIt: Bool

    /// How many terminal sessions the tab holds. A close is self-only
    /// when `callerOwnsIt` is true and this is one; beyond that, closing
    /// takes sibling sessions with it.
    let terminalCount: Int
}

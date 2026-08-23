// SPDX-License-Identifier: GPL-3.0-or-later
//
// WorkspaceAuthorityDecision: may this caller mutate this resolved
// target, or does it need an automation grant first?
//
// Ownership suffices for rename and the pane verbs. Close additionally
// requires a sole-terminal tab, because the trust unit is the session
// and a tab may hold several of them. Anything else needs a live grant.
//
// Pure by construction: the dispatcher resolves the target and reduces
// it to `WorkspaceAuthorityTarget`, so this type never reads the
// workspace and can be tested against the matrix directly. Visibility is
// not its business.
// Resolution runs first and a foreign protected tab is already
// `notFound` by the time anything gets here, so every target this sees
// is one the caller can legitimately name.

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

/// The resolved target, reduced to what the decision needs.
struct WorkspaceAuthorityTarget: Equatable {
    /// Whether the caller's session holds a terminal in the tab.
    let callerOwnsIt: Bool

    /// How many terminal sessions the tab holds. A close is self-only
    /// when `callerOwnsIt` is true and this is one; beyond that, closing
    /// takes sibling sessions with it.
    let terminalCount: Int
}

enum WorkspaceAuthorityDecision: Equatable {
    case allowed
    case requiresAutomation

    static func decide(
        origin: IntentOrigin,
        requirement: WorkspaceAuthorityRequirement,
        target: WorkspaceAuthorityTarget
    ) -> WorkspaceAuthorityDecision {
        // The human at the keyboard owns the workspace. This gate is
        // only ever about an external caller.
        guard case let .external(_, hasAutomationGrant) = origin else {
            return .allowed
        }
        if hasAutomationGrant { return .allowed }
        switch requirement {
        case .ownership:
            // A nil-session caller owns nothing, so it falls out here
            // with no special case: every predicate is false and it
            // needs a grant it cannot have.
            return target.callerOwnsIt ? .allowed : .requiresAutomation

        case .soleTerminal:
            return target.callerOwnsIt && target.terminalCount == 1
                ? .allowed
                : .requiresAutomation
        }
    }
}

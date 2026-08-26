// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Builds the daemon's session-restoration inventory
/// from the live GUI model.
///
/// After a daemon-only restart the validated GUI re-supplies its COMPLETE
/// session inventory (the daemon rehydrates nothing from disk). This pure
/// mapping is the authoritative source: one `RestoredSession` per terminal pane
/// (each backs its own daemon session), assembled straight from the workspace's
/// `TabState`s: not from `DaemonClient.liveSessions`, which retains only
/// `(sessionId, cap)` and can't source role / short id / name / protection.
///
/// Protection is derived FAIL-CLOSED from `isEffectivelyProtected`, not
/// committed `isProtected`: a tab mid-transition to protected
/// (`.pendingProtected`) restores protected so it is never briefly exposed
/// through `tabs.list`. Entry
/// order is significant (it defines the restored set's `tabs.list` ordering)
/// so tabs are walked in workspace order and terminals in tab order.
enum SessionRestoreInventory {
    /// Map the workspace's tabs (in order) to the restore inventory. The result
    /// is **complete with respect to real daemon sessions**: the only excluded
    /// terminals are ones that have no daemon session to restore, so releasing
    /// the daemon's restoration barrier after this batch never strands a live
    /// session.
    ///
    /// A terminal with an **empty `sessionId`** has no daemon session yet (its
    /// `session.create` hasn't completed): there is nothing to restore and it
    /// is created fresh later, so excluding it is correct, not a dropped
    /// session.
    ///
    /// A terminal with a **non-empty `sessionId` but nil `shortId`** is a live
    /// session missing its immutable short id: a daemon-contract violation
    /// that cannot occur with a current daemon (the short id ships in the
    /// `session.create` response and is stored on the terminal). Rather than
    /// silently omit that session and release the barrier with a PARTIAL
    /// inventory (stranding it), `build` **returns nil** so the caller treats it
    /// as a failed restore attempt and retries instead of shipping a partial
    /// batch.
    static func build(from tabs: [TabState]) -> [RestoredSession]? {
        var inventory: [RestoredSession] = []
        for tab in tabs {
            let isProtected = tab.isEffectivelyProtected
            for terminal in tab.terminals {
                // No daemon session yet → nothing to restore (created fresh).
                if terminal.sessionId.isEmpty { continue }
                // A live session must carry its short id (daemon contract): a
                // missing one means we cannot build a complete inventory.
                guard let shortId = terminal.shortId else { return nil }
                inventory.append(
                    RestoredSession(
                        sessionId: terminal.sessionId,
                        capability: terminal.capability,
                        shortId: shortId,
                        role: tab.role,
                        name: terminal.name,
                        isProtected: isProtected
                    )
                )
            }
        }
        return inventory
    }
}

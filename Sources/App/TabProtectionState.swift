// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A tab's protection as two axes collapsed into one value: what the daemon
/// has *committed* (confirmed on the wire) and what the tab *presents*
/// right now. Keeping them separate is what lets a protection transition be
/// fail-closed without lying about the committed state:
///
///  - `.unprotected`: committed unprotected, no transition; the only
///    non-hidden state.
///  - `.protected`: committed protected (also the resting state of a
///    protected→unprotected transition, which stays hidden until its ack).
///  - `.pendingProtected`: hidden but not committed: either an
///    unprotected→protected transition is in flight (hidden immediately,
///    fail-closed, commits to `.protected` only on the ack), or a
///    reconciliation left the tab hidden-and-unresolved (a mixed /
///    unfenced / membership-changed `session.protectionSnapshot`). The tab
///    is never exposed from this state except by an authoritative signal: a
///    fenced uniform-unprotected snapshot or the owning transition's
///    highest-key unprotect ack.
///
/// `isEffectivelyProtected` (absolute) drives tab chrome and the protection a
/// new terminal inherits; `externallyAccessible` (caller-relative, in
/// `IntentResolver`) drives what an external caller may reach.
enum TabProtectionState: Equatable, Sendable {
    case unprotected
    case protected
    case pendingProtected
}

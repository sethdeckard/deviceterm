// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The pure logic behind "which welcome, if any, do we
/// show right now".
///
/// Kept free of AppKit and of storage so the rules are unit testable on
/// their own: `WelcomeCoordinator` supplies the state and performs the
/// presentation, `WelcomeSeenStore` owns the on-disk format, this
/// decides.
///
/// The rule that earns its own type is **at most one welcome per
/// launch**, even when several are unseen. Stacking two explanatory
/// windows on a first launch trains the user to dismiss without reading,
/// which costs more than the delay of showing the second one next time.
enum WelcomeSelection {
    /// The next welcome to present, or nil to present none.
    ///
    /// Order matters and mirrors `HeadlessAdvisoryViewModel`'s
    /// cheap-gates-first shape: the two latches short-circuit before we
    /// walk the catalog.
    ///
    /// Within the catalog the same shape holds: `seen` is a set lookup and
    /// `isRelevant` reaches Launch Services, so the cheap test comes first
    /// and the expensive one runs only for ids that could actually show. A
    /// call-counting test pins that, the way `HeadlessAdvisoryDecision`'s
    /// does.
    ///
    /// - Parameters:
    ///   - catalog: every known welcome id, in presentation order.
    ///   - seen: ids already shown, from `WelcomeSeenStore`.
    ///   - isRelevant: whether an id applies to this machine. A welcome it
    ///     rejects is passed over and **not** recorded as seen, so it is
    ///     still waiting if the answer changes.
    ///   - isSuppressed: `welcome-messages = suppress`, the master opt-out.
    ///   - shownThisLaunch: whether a welcome already appeared this launch.
    @MainActor
    static func next(
        catalog: [String],
        seen: Set<String>,
        isRelevant: (String) -> Bool,
        isSuppressed: Bool,
        shownThisLaunch: Bool
    ) -> String? {
        guard !shownThisLaunch else { return nil }
        guard !isSuppressed else { return nil }
        return catalog.first { !seen.contains($0) && isRelevant($0) }
    }
}

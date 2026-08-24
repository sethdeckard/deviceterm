// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What a pane record's cohort reference resolves to for authorization.
///
/// The three cases are deliberately distinct; keep `unbound` and `denied`
/// apart. Treating "this pane never had a cohort" and "this pane's cohort is
/// gone" identically would restore the own-session fallback the moment a
/// cohort was retired.
enum CohortResolution: Sendable, Equatable {
    /// The record names no cohort. Compatibility only. The caller falls back to
    /// the record's own session.
    case unbound
    /// A live cohort. These are the sessions permitted to drive the pane. The
    /// member list may be empty while every member is torn down and none has
    /// been reconciled back; an empty list admits nobody.
    case live(members: [CohortMember], representative: UUID)
    /// The record names a cohort that is retired or was never installed. No
    /// session may drive it; the GUI keeps rendering it as `.guiPeer`.
    case denied
}

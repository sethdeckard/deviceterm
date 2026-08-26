// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// External handle for a tab, one of the source-agnostic identifiers
/// carried in `RouteIntent`. Resolves to a `(WindowID, TabID)` pair
/// via `IntentResolver`. `current` reads the caller's session-env
/// (CLI) or the GUI's key window's selected tab (menu).
///
/// Callers name a tab by a user-facing identifier: its sessionId, shortId,
/// or human-set name. The GUI-internal model speaks in
/// monotonically-allocated `WindowID` / `TabID` integers minted by the
/// `Router`. This type is the boundary, alongside `PaneRef` and
/// `WindowRef`: `IntentResolver` reads them and produces the GUI IDs the
/// Router needs.
///
/// Keeping a ref as an enum (rather than a free-form string) means each
/// caller picks the right disambiguator once, and downstream code never
/// has to re-guess "is this a UUID or a shortId?": the case carries the
/// meaning.
enum TabRef: Sendable, Equatable {
    /// The "this tab" default. For CLI use, the tab whose
    /// DEVICETERM_SESSION env matches; for in-process callers, the key
    /// window's selected tab.
    case current
    case sessionId(String)
    case shortId(String)
    case name(String)
}

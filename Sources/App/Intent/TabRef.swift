// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntentRefs: source-agnostic identifiers carried in `RouteIntent`.
//
// External inputs (CLI verbs, deep links, future AppleScript) name
// things by user-facing identifiers: a tab by its sessionId / shortId /
// human-set name, a pane by its paneId / udid / shortId, a window by
// position or focus state. The GUI-internal model speaks in
// monotonically-allocated `WindowID` / `TabID` integers minted by the
// `Router`. These types are the boundary: `IntentResolver` reads them
// and produces the GUI IDs the Router needs.
//
// Keeping refs as an enum (rather than a free-form string) means the
// translator at each input boundary picks the right disambiguator
// once, and downstream code never has to re-guess "is this a UUID or
// a shortId?": the case carries the meaning.

import Foundation

/// External handle for a tab. Resolves to a `(WindowID, TabID)` pair
/// via `IntentResolver`. `current` reads the caller's session-env
/// (CLI) or the GUI's key window's selected tab (menu / deep link).
enum TabRef: Sendable, Equatable {
    /// The "this tab" default. For CLI use, the tab whose
    /// DEVICETERM_SESSION env matches; for in-process callers, the key
    /// window's selected tab.
    case current
    case sessionId(String)
    case shortId(String)
    case name(String)
}

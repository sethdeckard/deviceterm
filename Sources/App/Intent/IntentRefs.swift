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

/// External handle for a sim pane. Resolves to a `(WindowID, TabID,
/// paneId)` triple. `current` is "the only sim pane in the current
/// tab, error if ambiguous": the same heuristic the existing
/// `PaneRefResolver` uses for unflagged input commands.
enum PaneRef: Sendable, Equatable {
    case current
    case paneId(String)
    case udid(String)
    case shortId(String)
}

/// External handle for a window. Resolves to a `WindowID`.
enum WindowRef: Sendable, Equatable {
    /// Key window per the workspace's `selectedWindowID`. Note that
    /// `selectedWindowID` only moves with Router routes
    /// (`selectWindow`), NOT with AppKit focus changes, so a menu
    /// action in a strip whose window is not the routed selection
    /// will hit the wrong window. Strips that know their concrete
    /// `WindowID` should use `.windowID(_)` below.
    case current
    /// Position in the workspace's ordered window list, 1-indexed
    /// to match `⌘1` / `⌘2` mental model.
    case index(Int)
    /// Window identity, for when windows gain stable user-
    /// facing ids; `WindowID` is monotonic-internal-only).
    case keyed(String)
    /// **GUI-internal only.** Direct concrete-ID targeting from a
    /// caller that holds the `WindowID`, typically the
    /// `TabStripViewController` for its own window. CLI / deep
    /// links never emit this case (the wire `Wire.WindowRef` has
    /// no encoding for it); the `CLIIntentTranslator` consequently
    /// can't produce it. Lives on `WindowRef` rather than a
    /// parallel internal enum so the dispatcher's resolution path
    /// stays one switch, with no parallel snowflakes.
    case windowID(WindowID)
}

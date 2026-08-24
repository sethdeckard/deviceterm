// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// External handle for a window. Resolves to a `WindowID`.
enum WindowRef: Sendable, Equatable {
    /// The current window for the dispatch origin: an in-process caller
    /// gets `workspace.selectedWindowID`, an external one the window
    /// holding its own session's tab (never the human's).
    /// `selectedWindowID` is deviceterm's own state rather than a live
    /// window-server read: the AppDelegate mirrors focus changes into
    /// it through `windowDidBecomeKey`, a notification behind. Strips
    /// that know their concrete `WindowID` should use `.windowID(_)`
    /// below rather than depend on being key when their action fires.
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

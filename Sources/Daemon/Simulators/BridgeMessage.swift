// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Extract a clean, agent-readable error message string
/// from an `Error` raised inside `CoreSimulatorBridge`.
///
/// The bridge layer carries high-quality diagnostic hints on the
/// `NSLocalizedDescriptionKey` of every NSError it throws, the
/// headline example being SimAccessibility's "No element at point:
/// fullscreen modal, out of bounds, or no AX server?", which names
/// the three likely causes so a caller can act on it. Swift formats
/// NSError values via `String(describing:)` / `"\(error)"` as the
/// verbose
///
///     Error Domain=CoreSimulatorBridge.SimHIDClient Code=49
///     "HID send did not complete within 1s" UserInfo={}
///
/// shape, which buries the actual hint inside boilerplate the CLI then
/// prints verbatim ("pane.tap: Error Domain=…"). This namespace unwraps
/// the localized description so `PaneError.bridgeFailed`'s `message:`
/// field carries only the hint the bridge wanted to surface, and
/// `mapPaneError` emits `pane.<op>: <hint>` on the wire instead of
/// `pane.<op>: Error Domain=…`.
///
/// Pure helper (no module imports beyond Foundation) per AGENTS.md's
/// pure-namespace convention so the extraction is unit-testable with
/// synthetic errors. Used by every catch block in `PaneCoordinator`
/// that converts a bridge-thrown error into a `bridgeFailed` message.
enum BridgeMessage {
    /// Return the bridge's intended user-facing message for `error`.
    /// All `CoreSimulatorBridge` .m files raise NSError values whose
    /// `NSLocalizedDescriptionKey` carries the actionable hint; Swift's
    /// `NSError.localizedDescription` returns that key's value
    /// (falling back to a synthesized "Operation couldn't be
    /// completed" form when no description key is set, which
    /// shouldn't occur for our bridge errors but is the safe
    /// default). For non-NSError Swift errors (e.g. `JSONSerialization`
    /// failures, decoded `PaneError` round-trips) the same accessor
    /// returns the value Swift's `LocalizedError` synthesis emits,
    /// which is still cleaner than the type's `String(describing:)`
    /// debug representation.
    static func unwrap(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}

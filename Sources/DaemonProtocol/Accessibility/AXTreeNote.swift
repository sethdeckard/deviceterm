// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finite wire-value vocabulary for the optional `note`
/// field the daemon may inject into an `ax tree` response when the
/// tree it gets back from the bridge is misleadingly empty.
///
/// Why: on watchOS, `AXPMacPlatformElement`'s `accessibilityChildren`
/// returns empty even when the screen has elements that `objectAtPoint:`
/// can resolve. A bare `{"children": []}` response is indistinguishable
/// from a legitimately empty tree, so a client has no way to tell the
/// limitation from the fact. The note makes it explicit, so a client can
/// detect it programmatically and branch to the grid-walk (`deviceterm ax
/// sweep`, which aggregates `objectAtPoint:` calls across the screen) or
/// to a single-point lookup (`deviceterm ax point <x> <y>`).
///
/// Lives in `DaemonProtocol` so agent-side decoders can pattern-match
/// the enum instead of doing string compares. Unknown-key-tolerant on
/// the wire: clients that don't decode `AXTreeNote` see a plain
/// String at `tree["note"]` and can compare manually.
public enum AXTreeNote: String, Codable, Sendable, Equatable, CaseIterable {
    /// watchOS's `AXPMacPlatformElement.accessibilityChildren` returns
    /// empty regardless of on-screen state, so the recursive walk
    /// produces a `{"children": []}` tree. Agents enumerate the
    /// screen via `deviceterm ax sweep` (grid-walks `objectAtPoint:`),
    /// or resolve a single point with `deviceterm ax point <x> <y>`.
    case watchOSEnumerationUnsupported =
        // swiftlint:disable:next line_length
        "AX tree enumeration is unsupported on watchOS; use 'deviceterm ax sweep' to grid-walk via objectAtPoint, or 'deviceterm ax point <x> <y>' for a single element"
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXTreeNote: finite wire-value vocabulary for the optional `note`
// field the daemon may inject into an `ax tree` response when the
// tree it gets back from the bridge is misleadingly empty.
//
// Why: on watchOS, `AXPMacPlatformElement`'s `accessibilityChildren`
// returns empty even when the screen has elements that
// `objectAtPoint:` can resolve. The bare `{"children":
// []}` response was indistinguishable from a legitimate empty tree,
// so the watchOS-game-dev agent gave up on `ax tree` and routed
// around it. The daemon now annotates the response with an explicit
// note so agents can detect the limitation programmatically + branch
// to the grid-walk (`deviceterm ax sweep`, which aggregates
// `objectAtPoint:` calls across the screen) or to a single-point
// lookup (`deviceterm ax point <x> <y>`).
//
// Lives in `DaemonProtocol` so agent-side decoders can pattern-match
// the enum instead of doing string compares. Unknown-key-tolerant on
// the wire: clients that don't decode `AXTreeNote` see a plain
// String at `tree["note"]` and can compare manually.

import Foundation

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

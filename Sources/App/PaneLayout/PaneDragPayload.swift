// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The pasteboard payload for a pane drag. Carries
/// the source tab id + the dragged leaf's slot. The destination
/// rejects drags whose `tabID` doesn't match its own: moving a pane
/// between tabs would need a rehoming verb for the daemon's per-tab
/// session linkage, which doesn't exist. (Dragging whole *tabs*
/// across windows is a separate, supported path.)
///
/// Encoded as JSON via `JSONEncoder()` on the source side, decoded
/// with `JSONDecoder()` on the destination. JSON is overkill for a
/// 1-record payload but matches the codebase's existing IPC framing
/// pattern; JSON admits additive fields
/// without breaking pasteboards mid-flight.
struct PaneDragPayload: Codable, Sendable, Equatable {
    /// Custom pasteboard type. Bundle-scoped so a stray drag from
    /// another app's pasteboard never registers as ours.
    static let pasteboardType = "com.deviceterm.pane.drag"

    let tabID: TabID
    let slot: PaneSlot
}

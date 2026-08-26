// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The identity of one leaf pane in the recursive
/// `PaneNode` layout tree. A leaf is either a terminal pane (keyed by
/// the typed `TerminalPaneID`), a sim pane (keyed by its lowercase
/// UDID, the canonical form the daemon stores), or a physical-device
/// pane (keyed by its daemon `deviceId`). The mirror typed-storage
/// arrays on `TabState` hold the per-pane state; this enum just says
/// "which leaf is here" inside the tree's structure.
///
/// `Codable` because the drag pasteboard payload encodes a slot as
/// JSON so the drag destination can decode the dragged pane back from
/// the wire. The serialized shape uses external tagging
/// (`{"sim":{"udid":"ABC-123"}}`, and the same nested shape for the other
/// cases) via Swift's
/// automatic associated-value Codable synthesis, which is stable
/// enough for an in-process pasteboard payload that never crosses a
/// process or disk boundary.
enum PaneSlot: Equatable, Hashable, Sendable, Codable {
    case terminal(TerminalPaneID)
    case sim(udid: String)
    case device(deviceId: String)
    /// A transient placeholder leaf occupying the slot a sim/device pane
    /// will take once its attach completes. Keyed by `PendingPaneID`
    /// (not the target identity) because the real pane id isn't known
    /// yet; the success swap replaces this leaf with `.sim`/`.device` at
    /// the same tree position. Never drag-encoded (pending panes aren't
    /// draggable), so it carries no `target`.
    case pending(PendingPaneID)

    /// The backend-neutral device identity this slot mirrors, if it is
    /// a device-backed pane (a sim or a physical device). Terminal slots
    /// return `nil`. The layout tree, drag pasteboard, and resurrect paths
    /// read this so a device leaf slots in without re-deriving identity per
    /// call site.
    var target: PaneTarget? {
        switch self {
        case .terminal, .pending:
            return nil

        case let .sim(udid):
            return .sim(udid: udid)

        case let .device(deviceId):
            return .device(deviceId: deviceId)
        }
    }
}

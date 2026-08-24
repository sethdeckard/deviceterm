// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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

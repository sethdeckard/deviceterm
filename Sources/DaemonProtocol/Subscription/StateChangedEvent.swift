// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `state.changed`. `state` is the pane's
/// `PaneLifecycle`; on the wire it is its rawValue string
/// (`booting`/`rendering`/`shutdown`/`failed`).
public struct StateChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    public let state: PaneLifecycle

    public init(paneId: String, state: PaneLifecycle) {
        self.paneId = paneId
        self.state = state
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLocationStateParams: wire shape for `pane.location.state`.
//
// Reads back what deviceterm last applied to the pane, plus the
// scenarios its device offers.

public struct PaneLocationStateParams: Codable, Sendable, Equatable {
    public let paneId: String

    public init(paneId: String) {
        self.paneId = paneId
    }
}

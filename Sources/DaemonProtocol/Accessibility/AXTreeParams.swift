// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXTreeParams: wire shape for `pane.ax.tree`.
//
// Requests the accessibility tree for the pane's frontmost element.

public struct AXTreeParams: Codable, Sendable {
    public let paneId: String

    public init(paneId: String) {
        self.paneId = paneId
    }
}

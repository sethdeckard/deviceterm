// SPDX-License-Identifier: GPL-3.0-or-later

/// Text captured from one explicitly resolved terminal pane.
public struct WorkspaceCaptureResult: Codable, Sendable, Equatable {
    public let pane: WorkspacePane
    public let text: String

    public init(pane: WorkspacePane, text: String) {
        self.pane = pane
        self.text = text
    }
}

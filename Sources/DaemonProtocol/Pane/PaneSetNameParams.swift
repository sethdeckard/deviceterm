// SPDX-License-Identifier: GPL-3.0-or-later

/// GUI-authoritative name update for a daemon-backed device pane.
public struct PaneSetNameParams: Codable, Sendable, Equatable {
    public let paneId: String
    public let name: String?

    public init(paneId: String, name: String?) {
        self.paneId = paneId
        self.name = name
    }
}

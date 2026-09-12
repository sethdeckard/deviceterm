// SPDX-License-Identifier: GPL-3.0-or-later

/// Stable public projection of one live DeviceTerm window.
public struct WorkspaceWindow: Codable, Sendable, Equatable {
    public let id: String
    public let shortId: String
    public let name: String?
    public let index: Int
    public let current: Bool
    public let focused: Bool
    public let selectedTabId: String?
    public let tabCount: Int

    public init(
        id: String,
        shortId: String,
        name: String?,
        index: Int,
        current: Bool,
        focused: Bool,
        selectedTabId: String?,
        tabCount: Int
    ) {
        self.id = id
        self.shortId = shortId
        self.name = name
        self.index = index
        self.current = current
        self.focused = focused
        self.selectedTabId = selectedTabId
        self.tabCount = tabCount
    }
}

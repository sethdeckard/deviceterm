// SPDX-License-Identifier: GPL-3.0-or-later

/// Stable public projection of one tab workspace.
public struct WorkspaceTab: Codable, Sendable, Equatable {
    public let id: String
    public let shortId: String
    public let name: String?
    public let title: String
    public let windowId: String
    public let current: Bool
    public let selected: Bool
    public let protected: Bool
    public let state: WorkspaceTabLifecycle
    public let paneCount: Int

    public init(
        id: String,
        shortId: String,
        name: String?,
        title: String,
        windowId: String,
        current: Bool,
        selected: Bool,
        protected: Bool,
        state: WorkspaceTabLifecycle,
        paneCount: Int
    ) {
        self.id = id
        self.shortId = shortId
        self.name = name
        self.title = title
        self.windowId = windowId
        self.current = current
        self.selected = selected
        self.protected = protected
        self.state = state
        self.paneCount = paneCount
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

/// A window row plus its caller-visible tabs.
public struct WorkspaceWindowDetail: Codable, Sendable, Equatable {
    public let window: WorkspaceWindow
    public let tabs: [WorkspaceTab]

    public init(window: WorkspaceWindow, tabs: [WorkspaceTab]) {
        self.window = window
        self.tabs = tabs
    }
}

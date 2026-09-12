// SPDX-License-Identifier: GPL-3.0-or-later

/// A tab row plus its addressable panes and layout.
public struct WorkspaceTabDetail: Codable, Sendable, Equatable {
    public let tab: WorkspaceTab
    public let panes: [WorkspacePane]
    public let layout: WorkspaceLayoutNode?

    public init(tab: WorkspaceTab, panes: [WorkspacePane], layout: WorkspaceLayoutNode?) {
        self.tab = tab
        self.panes = panes
        self.layout = layout
    }
}

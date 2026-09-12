// SPDX-License-Identifier: GPL-3.0-or-later

/// Committed resource state returned by workspace mutations.
public struct WorkspaceMutationReceipt: Codable, Sendable, Equatable {
    public struct Closed: Codable, Sendable, Equatable {
        public let resource: String
        public let window: WorkspaceWindow?
        public let tab: WorkspaceTab?
        public let pane: WorkspacePane?

        public init(
            resource: String,
            window: WorkspaceWindow? = nil,
            tab: WorkspaceTab? = nil,
            pane: WorkspacePane? = nil
        ) {
            self.resource = resource
            self.window = window
            self.tab = tab
            self.pane = pane
        }
    }

    public let ok: Bool
    public let window: WorkspaceWindow?
    public let tab: WorkspaceTab?
    public let pane: WorkspacePane?
    public let closed: Closed?
    public let mode: WorkspaceCloseMode?
    public let bytes: Int?
    public let typeDelayMs: Int?

    public init(
        window: WorkspaceWindow? = nil,
        tab: WorkspaceTab? = nil,
        pane: WorkspacePane? = nil,
        closed: Closed? = nil,
        mode: WorkspaceCloseMode? = nil,
        bytes: Int? = nil,
        typeDelayMs: Int? = nil
    ) {
        self.ok = true
        self.window = window
        self.tab = tab
        self.pane = pane
        self.closed = closed
        self.mode = mode
        self.bytes = bytes
        self.typeDelayMs = typeDelayMs
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

/// Stable public projection of one terminal, Simulator, or physical-device pane.
public struct WorkspacePane: Codable, Sendable, Equatable {
    public struct Terminal: Codable, Sendable, Equatable {
        public let sessionId: String
        public let cwd: String?

        public init(sessionId: String, cwd: String?) {
            self.sessionId = sessionId
            self.cwd = cwd
        }
    }

    public struct Simulator: Codable, Sendable, Equatable {
        public let udid: String
        public let displayName: String
        public let family: String
        public let state: PaneLifecycle?
        public let orientation: Orientation?
        public let pixelWidth: Int?
        public let pixelHeight: Int?
        public let capabilities: PaneCapabilities?

        public init(
            udid: String,
            displayName: String,
            family: String,
            state: PaneLifecycle?,
            orientation: Orientation?,
            pixelWidth: Int?,
            pixelHeight: Int?,
            capabilities: PaneCapabilities?
        ) {
            self.udid = udid
            self.displayName = displayName
            self.family = family
            self.state = state
            self.orientation = orientation
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.capabilities = capabilities
        }
    }

    public struct Device: Codable, Sendable, Equatable {
        public let deviceId: String
        public let displayName: String
        public let family: String
        public let state: PaneLifecycle?
        public let orientation: Orientation?
        public let pixelWidth: Int?
        public let pixelHeight: Int?
        public let capabilities: PaneCapabilities?

        public init(
            deviceId: String,
            displayName: String,
            family: String,
            state: PaneLifecycle?,
            orientation: Orientation?,
            pixelWidth: Int?,
            pixelHeight: Int?,
            capabilities: PaneCapabilities?
        ) {
            self.deviceId = deviceId
            self.displayName = displayName
            self.family = family
            self.state = state
            self.orientation = orientation
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.capabilities = capabilities
        }
    }

    public let id: String
    public let shortId: String
    public let name: String?
    public let kind: WorkspacePaneKind
    public let tabId: String
    public let current: Bool
    public let focused: Bool
    public let capabilities: [WorkspacePaneCapability]
    public let terminal: Terminal?
    public let simulator: Simulator?
    public let device: Device?

    public init(
        id: String,
        shortId: String,
        name: String?,
        kind: WorkspacePaneKind,
        tabId: String,
        current: Bool,
        focused: Bool,
        capabilities: [WorkspacePaneCapability],
        terminal: Terminal? = nil,
        simulator: Simulator? = nil,
        device: Device? = nil
    ) {
        self.id = id
        self.shortId = shortId
        self.name = name
        self.kind = kind
        self.tabId = tabId
        self.current = current
        self.focused = focused
        self.capabilities = capabilities
        self.terminal = terminal
        self.simulator = simulator
        self.device = device
    }
}

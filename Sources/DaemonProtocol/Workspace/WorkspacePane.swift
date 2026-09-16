// SPDX-License-Identifier: GPL-3.0-or-later

/// Stable public projection of one terminal, Simulator, or physical-device pane.
public struct WorkspacePane: Codable, Sendable, Equatable {
    public struct Terminal: Codable, Sendable, Equatable {
        /// Stands in when no title tier produced anything, and when decoding a
        /// terminal object that predates the field.
        public static let defaultTitle = "shell"

        public let sessionId: String
        /// This pane's own live label. Always present, so a consumer never
        /// branches on absence. A split tab's terminals each report their own,
        /// which is what the enclosing tab's single title cannot express.
        public let title: String
        /// Controlling tty device path, e.g. `/dev/ttys003`. Absent means
        /// terminal identity is temporarily unavailable, commonly before the
        /// shell spawns or after the surface detaches. It never means the field
        /// is unsupported, so retry rather than falling back permanently.
        public let tty: String?
        public let cwd: String?

        public init(sessionId: String, title: String, tty: String?, cwd: String?) {
            self.sessionId = sessionId
            self.title = title
            self.tty = tty
            self.cwd = cwd
        }

        /// `title` is required, but it arrived without a `wireVersion` bump,
        /// because the daemon relays these bytes and never decodes them, so
        /// nothing in the GUI-to-daemon handshake this version gates was
        /// affected.
        ///
        /// The CLI does decode, and it is symlinked out of the app bundle. A
        /// Sparkle swap therefore replaces it behind a still-running older GUI,
        /// and that GUI emits no `title`. The CLI decodes this type in human
        /// mode for any response carrying a terminal pane, receipts included,
        /// so under synthesized decoding the missing key would fail those
        /// commands for the rest of the session. Defaulting it keeps them
        /// working through the window.
        ///
        /// JSON mode is untouched by this, because it relays the GUI's bytes
        /// unchanged. A caller reading raw JSON across that window sees rows
        /// with no `title` at all rather than this default.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
            tty = try container.decodeIfPresent(String.self, forKey: .tty)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
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

    /// Stands in for a context field whose object could not be resolved, and
    /// when decoding a pane that predates the field. Empty rather than absent,
    /// because these are always-present fields: the projection already reports
    /// an unresolvable `tabId` this way.
    public static let unknownContext = ""

    public let id: String
    public let shortId: String
    public let name: String?
    public let kind: WorkspacePaneKind
    public let tabId: String
    /// Title of the tab holding this pane, so listing panes across the
    /// workspace needs no second call to name their tabs.
    ///
    /// It describes the tab, not this pane. A tab whose focused pane is a
    /// Simulator takes that pane's name, so a terminal row's `tabTitle` can
    /// name something other than that terminal. `terminal.title` is the pane's
    /// own label.
    public let tabTitle: String
    /// Public id of the window holding this pane, so panes from a workspace-wide
    /// listing group by window without a join against `window list`.
    public let windowId: String
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
        tabTitle: String,
        windowId: String,
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
        self.tabTitle = tabTitle
        self.windowId = windowId
        self.current = current
        self.focused = focused
        self.capabilities = capabilities
        self.terminal = terminal
        self.simulator = simulator
        self.device = device
    }

    /// `tabTitle` and `windowId` are required and arrived without a
    /// `wireVersion` bump, for the same reason `Terminal.title` did: the daemon
    /// relays these bytes and never decodes them.
    ///
    /// The CLI decodes this type in human mode, and it is symlinked out of the
    /// app bundle, so a Sparkle swap can pair it with an older GUI that emits
    /// neither field. Defaulting both keeps human-mode commands and receipts
    /// working through that window. JSON mode relays the GUI's bytes unchanged,
    /// so a caller reading raw JSON across it sees rows without the keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shortId = try container.decode(String.self, forKey: .shortId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        kind = try container.decode(WorkspacePaneKind.self, forKey: .kind)
        tabId = try container.decode(String.self, forKey: .tabId)
        tabTitle = try container.decodeIfPresent(String.self, forKey: .tabTitle)
            ?? Self.unknownContext
        windowId = try container.decodeIfPresent(String.self, forKey: .windowId)
            ?? Self.unknownContext
        current = try container.decode(Bool.self, forKey: .current)
        focused = try container.decode(Bool.self, forKey: .focused)
        capabilities = try container.decode([WorkspacePaneCapability].self, forKey: .capabilities)
        terminal = try container.decodeIfPresent(Terminal.self, forKey: .terminal)
        simulator = try container.decodeIfPresent(Simulator.self, forKey: .simulator)
        device = try container.decodeIfPresent(Device.self, forKey: .device)
    }
}

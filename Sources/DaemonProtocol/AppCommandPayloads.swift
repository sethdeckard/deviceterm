// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommandPayloads: Codable response payloads for
// `AppCommandResult.data` (info / list verbs).
//
// Lives in DaemonProtocol because both the GUI (encoder, fills the
// fields after `IntentDispatcher` produces them) and the CLI
// (decoder, renders to a CLI receipt) need to see the same shapes.
// Synthesized Codable; new fields can ride in as Optionals without
// a wire-version bump.

import Foundation

public struct TabInfoPayload: Codable, Sendable, Equatable {
    public let sessionId: String
    public let shortId: String?
    public let name: String?
    public let role: String
    public let cwd: String?
    public let label: String?
    public let isCurrent: Bool
    public let simPanes: [SimPanePayload]

    public init(
        sessionId: String,
        shortId: String?,
        name: String?,
        role: String,
        cwd: String?,
        label: String?,
        isCurrent: Bool,
        simPanes: [SimPanePayload]
    ) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.name = name
        self.role = role
        self.cwd = cwd
        self.label = label
        self.isCurrent = isCurrent
        self.simPanes = simPanes
    }
}

public struct PaneInfoPayload: Codable, Sendable, Equatable {
    public let paneId: String
    public let udid: String
    public let shortId: String?
    public let name: String?
    public let displayName: String
    public let family: String
    public let linkedSessionId: String

    public init(
        paneId: String,
        udid: String,
        shortId: String?,
        name: String?,
        displayName: String,
        family: String,
        linkedSessionId: String
    ) {
        self.paneId = paneId
        self.udid = udid
        self.shortId = shortId
        self.name = name
        self.displayName = displayName
        self.family = family
        self.linkedSessionId = linkedSessionId
    }
}

public struct SimPanePayload: Codable, Sendable, Equatable {
    public let paneId: String
    public let udid: String
    public let shortId: String?
    public let displayName: String
    public let family: String

    public init(
        paneId: String,
        udid: String,
        shortId: String?,
        displayName: String,
        family: String
    ) {
        self.paneId = paneId
        self.udid = udid
        self.shortId = shortId
        self.displayName = displayName
        self.family = family
    }
}

public struct TabCapturePayload: Codable, Sendable, Equatable {
    /// Captured screen content with `"\n"` separating rows. May be
    /// empty when the surface is attached but has nothing rendered
    /// yet (a freshly-attached tab before the shell prompt
    /// arrives).
    public let text: String

    public init(text: String) { self.text = text }
}

public struct WindowInfoPayload: Codable, Sendable, Equatable {
    public let index: Int
    public let isKey: Bool
    public let tabCount: Int
    public let selectedTabShortId: String?

    public init(
        index: Int,
        isKey: Bool,
        tabCount: Int,
        selectedTabShortId: String?
    ) {
        self.index = index
        self.isKey = isKey
        self.tabCount = tabCount
        self.selectedTabShortId = selectedTabShortId
    }
}

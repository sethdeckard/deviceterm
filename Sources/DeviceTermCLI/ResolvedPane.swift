// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Resolution result from `panes.list`: the daemon's canonical
/// `paneId` (UUID), the canonical lowercased `udid` from the
/// daemon's pane record (NOT the caller-typed `--pane` argument;
/// daemon's is the truth), and the `shortId` for display when
/// available. nil `shortId` means the daemon predates the
/// identifier model; callers fall back to `paneId` for the display
/// label.
public struct ResolvedPane: Equatable, Sendable {
    public let paneId: String
    public let udid: String
    public let shortId: String?

    /// The label used in `pane=<…>` echo columns. Short_id when the
    /// daemon emitted one (the current default), the full paneId
    /// UUID as a fallback. Centralized so every echo path uses the
    /// same convention.
    public var displayLabel: String {
        shortId ?? paneId
    }

    public init(paneId: String, udid: String, shortId: String?) {
        self.paneId = paneId
        self.udid = udid
        self.shortId = shortId
    }
}

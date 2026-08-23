// SPDX-License-Identifier: GPL-3.0-or-later
//
/// One entry of the bare-array `panes.list` result. Mirrors
/// `PaneMethods.PanesListEntry` (the daemon's encoder shape). The CLI
/// resolves a target pane through this (default = the tab's sole
/// device pane, `--pane <ref>` to disambiguate).
///
/// `shortId` + `name` are the three-layer identifier model that rides
/// alongside the always-present `paneId` (UUID string). Both are
/// Optional on this client-side shape so an older daemon (Sparkle
/// update window) decodes cleanly; current daemons always emit
/// `shortId`. `PaneRefResolver` resolves user-supplied `--pane <ref>`
/// strings against this triple in the documented order
/// (short_id → name → UUID prefix → sentinel).
public struct PanesListEntry: Codable, Sendable, Equatable {
    public let paneId: String
    public let udid: String
    public let state: PaneLifecycle
    /// Coarse device family (see `DeviceFamily`). Optional-decoded for
    /// daemon-version skew.
    public let family: String?
    /// Crockford base32 short_id (6 chars, lowercased). Current
    /// daemons always emit it.
    public let shortId: String?
    /// Optional human-set name. Nil at create. The `deviceterm pane
    /// rename` command ships, but currently returns `intent.internalError`
    /// without mutating this field.
    public let name: String?
    /// Per-pane device-control capabilities. Optional for skew: a peer
    /// that omits it leaves the client on
    /// `PaneCapabilities.missingBlockFallback`, which enables the
    /// original flags and disables flags added to the block.
    public let capabilities: PaneCapabilities?
    /// Backend-neutral identity + kind discriminator. Optional for
    /// skew; backs the CLI `type` column and `--pane` device matching.
    public let target: PaneTarget?

    public init(
        paneId: String,
        udid: String,
        state: PaneLifecycle,
        family: String? = nil,
        shortId: String? = nil,
        name: String? = nil,
        capabilities: PaneCapabilities? = nil,
        target: PaneTarget? = nil
    ) {
        self.paneId = paneId
        self.udid = udid
        self.state = state
        self.family = family
        self.shortId = shortId
        self.name = name
        self.capabilities = capabilities
        self.target = target
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

struct SimPaneState: MirroredPaneState, Equatable, Sendable {
    /// Daemon pane id from device.attach. The glue creates a pane VM for
    /// this id (the attach already happened in the Router).
    let paneId: String
    /// See `MirroredPaneState.attachment`.
    let attachment: UInt64?
    let udid: String
    let displayName: String
    /// Coarse device family (drives watch-aware pane sizing).
    let family: String
    /// Daemon-minted Crockford base32 short_id (6 chars). Optional in
    /// the GUI model: nil when decoded from a pre-identifier-model
    /// daemon response. Consumers (status item grouping, pane-ref
    /// resolution) treat nil as "fall back to udid / paneId for
    /// display." Defaults nil so synthetic test fixtures stay terse;
    /// production instances are constructed by the Router with the
    /// response's values.
    let shortId: String?
    /// Optional pane name, echoed back from `pane.create` /
    /// `device.attach`. The daemon emits nil at create and populates it
    /// on `deviceterm pane rename`, so this is nil until the pane state
    /// is rebuilt from a later response.
    let name: String?
    /// Native pixel width of the device's display, from the daemon's
    /// attach response. Drives the size-preset math (Physical / Point
    /// Accurate / Pixel Accurate / Fit Screen). Nil when the renderable
    /// hasn't bound a surface yet at attach time, in which case the chrome
    /// falls back to family-default sizing.
    let pixelWidth: Int?
    /// Pairs with `pixelWidth`.
    let pixelHeight: Int?
    /// Per-pane device-control capabilities from the daemon's attach
    /// response. Nil when decoded from an older daemon that omits the
    /// block. The VM resolves nil to `.simulator` (historical
    /// all-enabled behavior).
    let capabilities: PaneCapabilities?

    /// `MirroredPaneState` identity: a sim pane keys on its UDID.
    var target: PaneTarget { .sim(udid: udid) }

    init(
        paneId: String,
        udid: String,
        displayName: String,
        family: String,
        attachment: UInt64? = nil,
        shortId: String? = nil,
        name: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        capabilities: PaneCapabilities? = nil
    ) {
        self.paneId = paneId
        self.attachment = attachment
        self.udid = udid
        self.displayName = displayName
        self.family = family
        self.shortId = shortId
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capabilities = capabilities
    }
}

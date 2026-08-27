// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The value record of one physically-connected device
/// pane attached to a tab. Mirrors `SimPaneState` field-for-field except the
/// identity key is the physical device's CoreDevice UDID (`deviceId`) rather
/// than a CoreSimulator UDID (`udid`). Kept as a separate type + array
/// (`TabState.devicePanes`) so the sim drag/resurrect/reconcile path is
/// untouched; both conform to `MirroredPaneState` and render through the same
/// `SimulatorPaneViewController`.
///
/// REFACTOR: collapse `simPanes` and `devicePanes` into one
/// `PaneTarget`-keyed pane type; `MirroredPaneState` is the seam that
/// consolidation builds on.
struct DevicePaneState: MirroredPaneState, Equatable, Sendable {
    /// Daemon pane id from `physicalDevice.attach`.
    let paneId: String
    /// See `MirroredPaneState.attachment`.
    let attachment: UInt64?
    /// The physical device's stable CoreDevice UDID; the layout-tree leaf key.
    let deviceId: String
    let displayName: String
    let family: String
    let shortId: String?
    let name: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let capabilities: PaneCapabilities?
    /// See `MirroredPaneState.sizePreset`. Mutable because the pane's chrome
    /// reports a newly-picked preset back into nav state.
    var sizePreset: SimSizePreset?

    var target: PaneTarget { .device(deviceId: deviceId) }

    init(
        paneId: String,
        deviceId: String,
        displayName: String,
        family: String,
        attachment: UInt64? = nil,
        shortId: String? = nil,
        name: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        capabilities: PaneCapabilities? = nil,
        sizePreset: SimSizePreset? = nil
    ) {
        self.paneId = paneId
        self.attachment = attachment
        self.deviceId = deviceId
        self.displayName = displayName
        self.family = family
        self.shortId = shortId
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capabilities = capabilities
        self.sizePreset = sizePreset
    }
}

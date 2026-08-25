// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.create` / `device.attach` → `{paneId, attachment?, scale?,
/// family?, shortId?, name?, deviceType?, pixelWidth?, pixelHeight?,
/// capabilities?, target?}`. Mirrors `PaneMethods.CreateResponse`.
///
/// Initial-render delivery flows through `pane.subscribe`, not this
/// response: the daemon's subscribe handler immediately emits a
/// `surface.changed` evt + side-band surface payload when the pane is
/// already rendering, so the GUI's first surface arrives over the same
/// stream as every follow-on update.
///
/// `shortId` + `name` are the three-layer identifier model.
/// Optional-decoded for daemon-version skew, the same shape `family`
/// already uses.
public struct PaneCreateResponse: Codable, Sendable, Equatable {
    public let paneId: String
    /// Identifies this admission of the pane, advanced by every fresh create,
    /// revisioned same-owner re-attach, and ownership transfer. Pass it back on
    /// `pane.closeById` to fence the close to the admission it was issued
    /// for: a close carrying a superseded value is refused, so a close racing
    /// a re-attach can't retire the pane the re-attach handed to someone else.
    /// Optional-decoded for daemon-version skew; a peer that omits it leaves
    /// the caller with only the unconditional close.
    public let attachment: UInt64?
    public let scale: Double?
    /// Coarse device family (see `DeviceFamily`). Optional-decoded for
    /// daemon-version skew.
    public let family: String?
    /// Crockford base32 short_id (6 chars, lowercased). Daemon-minted
    /// at create time; current daemons always emit it.
    public let shortId: String?
    /// Optional human-set name. Nil at create. The `deviceterm pane
    /// rename` command ships, but currently returns `intent.internalError`
    /// without mutating this field.
    public let name: String?
    /// Human-readable device type from `SimDeviceType.name`, e.g.
    /// "Apple Watch Ultra 3 (49mm)". Optional for skew tolerance.
    /// Carried on the attach response so the Router can compose
    /// "Name · Type" without an extra `device.list` roundtrip in the
    /// hot path.
    public let deviceType: String?
    /// Native pixel width of the device's display, read from
    /// `SimDisplayHandle.displaySize`. Optional for skew tolerance and
    /// because the renderable may not have a bound surface yet on
    /// fast-attach paths. The GUI uses this for the four size presets
    /// (Physical / Point Accurate / Pixel Accurate / Fit Screen);
    /// nil falls back to family-default sizing.
    public let pixelWidth: Int?
    /// Native pixel height, pairing with `pixelWidth`.
    public let pixelHeight: Int?
    /// Per-pane device-control capabilities. Optional for skew: a peer
    /// that omits it leaves the client on
    /// `PaneCapabilities.missingBlockFallback`, which enables the
    /// original capability flags and disables flags added to the block.
    public let capabilities: PaneCapabilities?
    /// Backend-neutral device identity + kind discriminator (`.sim` vs
    /// `.device`). Optional for skew: an omitted `target` decodes to a
    /// sim by convention.
    public let target: PaneTarget?

    public init(
        paneId: String,
        scale: Double?,
        attachment: UInt64? = nil,
        family: String? = nil,
        shortId: String? = nil,
        name: String? = nil,
        deviceType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        capabilities: PaneCapabilities? = nil,
        target: PaneTarget? = nil
    ) {
        self.paneId = paneId
        self.attachment = attachment
        self.scale = scale
        self.family = family
        self.shortId = shortId
        self.name = name
        self.deviceType = deviceType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capabilities = capabilities
        self.target = target
    }
}

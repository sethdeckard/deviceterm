// SPDX-License-Identifier: GPL-3.0-or-later
//
/// One entry of the bare-array `devices.list` result: the aggregate
/// live roster the CLI `deviceterm devices list` renders. Combines booted
/// CoreSimulators and connected physical devices, each annotated with
/// whether a deviceterm pane currently mirrors it.
///
/// This is **not** a `simctl list` / `devicectl list` clone; it never
/// enumerates shutdown or never-booted sims. The value it adds over
/// Apple's tools is the pane/ownership layer.
///
/// Protection: the `ownerSessionId` annotation obeys the same protected-tab
/// opacity rule as `tabs.list`. A caller that doesn't own a *protected*
/// session never learns a device is attached to it. The device is
/// reported `attached == false` / `ownerSessionId == nil`, exactly as
/// `tabs.list` hides protected tabs from non-owners.
public struct DeviceRosterEntry: Codable, Sendable, Equatable {
    /// Identity: a CoreSimulator UDID for a sim, or the physical
    /// device's `deviceId`.
    public let id: String
    /// `.sim` or `.device`, the roster's type column.
    public let kind: DeviceKind
    /// Human-readable name when known.
    public let name: String?
    /// Hardware model, physical devices only (e.g. `"iPhone 15 Pro"`).
    /// nil for sims and for skew against pre-model daemons. Disambiguates
    /// two connected devices that share a name.
    public let model: String?
    /// OS version, physical devices only (e.g. `"17.5"`). nil for sims
    /// and for skew. Disambiguates same-model devices on different
    /// releases.
    public let osVersion: String?
    /// Live state: the CoreSimulator state for a sim (e.g. `"Booted"`),
    /// or `"connected"` for a physical device. Optional for skew.
    public let state: String?
    /// Whether a deviceterm pane visible to the caller currently mirrors
    /// this device. False for an unattached device, and also false when
    /// the only attachment is in a protected session the caller doesn't
    /// own (opacity).
    public let attached: Bool
    /// Owning session UUID string when `attached`, else nil (also nil
    /// when hidden by opacity).
    public let ownerSessionId: String?

    public init(
        id: String,
        kind: DeviceKind,
        name: String? = nil,
        model: String? = nil,
        osVersion: String? = nil,
        state: String? = nil,
        attached: Bool = false,
        ownerSessionId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.state = state
        self.attached = attached
        self.ownerSessionId = ownerSessionId
    }
}

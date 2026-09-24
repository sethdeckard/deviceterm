// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// Per-pane device-control capabilities. The coordinator gates each
/// input and accessibility verb on the relevant flag, so one daemon can
/// host a sim pane (supports everything) beside a physical-device pane
/// (a subset) without a daemon-wide capability switch; those flags drive
/// the coordinator's per-verb `unsupportedOperation` guard, `location`
/// included. `pane.location.set` gates on it through `requireBackend`,
/// and `pane.location.state` reports no scenarios for a backend that
/// lacks it.
struct DeviceBackendCapabilities: Sendable, Equatable {
    /// Everything a CoreSimulator pane supports. The daemon imposes no
    /// per-verb restriction on sims. Family-based gating (e.g. hiding
    /// Crown on a phone) is a GUI concern, not a daemon one, so every
    /// flag is `true`.
    ///
    /// `fold` is the exception, and it is not family-based: it depends on
    /// whether the individual device has a second panel. The backend reads
    /// that from the device's sized display candidates, before the display
    /// bootstrap binds one, because a pane reports what it can do at create
    /// time. So it starts false and the backend raises it for the devices
    /// that have one.
    static let simulator = DeviceBackendCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: true,
        accessibility: true,
        location: true,
        fold: false
    )

    /// The **maximal** physical-device capability set: relay-backed input
    /// (touch via the digitizer, hardware buttons, orientation, and
    /// `key`/`text` via a host-registered virtual keyboard) plus location
    /// through `devicectl`. Crown (no hardware) and accessibility (no AX
    /// service over the tunnel) are never supported. A concrete backend
    /// derives the relay-backed flags from which channels/roles opened;
    /// location is independent of them. This is a fixture/default, not
    /// every device's set.
    static let physicalDevice = DeviceBackendCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: false,
        accessibility: false,
        location: true,
        fold: false
    )

    var touch: Bool
    var key: Bool
    var text: Bool
    var button: Bool
    var rotate: Bool
    var crown: Bool
    var accessibility: Bool
    var location: Bool
    /// Whether the device has a hinge this daemon can drive. Set from how
    /// many sized display candidates the device vends, not from its family: a
    /// foldable and a slab report the same family.
    var fold: Bool = false

    /// The same set with `location` cleared.
    ///
    /// For any conformer that takes the protocol's throwing location
    /// defaults: advertising location while using those defaults would
    /// make the wire capability disagree with backend dispatch.
    var withoutLocation: DeviceBackendCapabilities {
        var copy = self
        copy.location = false
        return copy
    }
}

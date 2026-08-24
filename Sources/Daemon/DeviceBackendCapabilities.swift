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
    static let simulator = DeviceBackendCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: true,
        accessibility: true,
        location: true
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
        location: true
    )

    var touch: Bool
    var key: Bool
    var text: Bool
    var button: Bool
    var rotate: Bool
    var crown: Bool
    var accessibility: Bool
    var location: Bool

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

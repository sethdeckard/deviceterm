// SPDX-License-Identifier: GPL-3.0-or-later
/// What a channel is *for*, in deviceterm's own terms. The daemon reasons about
/// roles, never Apple service identifiers.
///
/// Each role maps privately to the device service that fulfils it (see
/// `serviceIdentifier`, and `identifyingFeature` for telling that service apart
/// by behaviour); that mapping is the only place the identifiers are used, and
/// it never crosses the package boundary. `description` is the
/// human-facing name the daemon surfaces when a required role is absent.
package enum ChannelRole: Sendable, Hashable, CaseIterable {
    /// The display mirror (decoded video frames).
    case mirror
    /// Touch and virtual-keyboard input.
    case humanInput
    /// Hardware buttons.
    case hardwareControls
    /// Device-level control such as orientation.
    case deviceControl

    /// The device service identifier that backs this role. Private to the
    /// target: the mapping is the single home for these literals.
    var serviceIdentifier: String {
        switch self {
        case .mirror:
            "com.apple.coredevice.displayservice"

        case .humanInput:
            "com.apple.coredevice.hid.universalhidservice"

        case .hardwareControls:
            "com.apple.coredevice.hid.indigo"

        case .deviceControl:
            "com.apple.coredevice.devicecontrol"
        }
    }

    /// A read-only feature that only this role's service answers with output,
    /// so the service can be told apart from its neighbours without a directory.
    /// Nil for roles whose services drop any message they can't act on.
    var identifyingFeature: String? {
        switch self {
        case .mirror:
            "com.apple.coredevice.feature.getmediastreamserverstatus"

        case .humanInput, .hardwareControls, .deviceControl:
            nil
        }
    }

    /// A short, human-facing name for the role, used in daemon-facing errors.
    package var description: String {
        switch self {
        case .mirror:
            "display mirror"

        case .humanInput:
            "human input"

        case .hardwareControls:
            "hardware controls"

        case .deviceControl:
            "device control"
        }
    }
}

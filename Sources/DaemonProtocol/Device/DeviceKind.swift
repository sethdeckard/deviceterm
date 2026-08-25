// SPDX-License-Identifier: GPL-3.0-or-later

/// The kind of device a roster entry / pane refers to: a CoreSimulator
/// or a physically-connected iPhone/iPad. The `devices.list` `type`
/// column and any other sim-vs-device discriminator on the wire use
/// this shared enum rather than a bare string literal.
public enum DeviceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sim
    case device
}

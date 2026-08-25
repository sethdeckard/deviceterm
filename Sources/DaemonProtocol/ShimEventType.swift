// SPDX-License-Identifier: GPL-3.0-or-later

/// The `shim.event` `event` field: which shim-observed
/// intent the daemon should act on. Shared between the shim binary
/// (producer) and the daemon's provenance handler (consumer).
/// `CaseIterable` backs the daemon's validation error message.
///
/// `booted`/`shutdown` are CoreSimulator transitions the shim detects by
/// diffing `simctl list` snapshots and carry a `udid`. `deviceAttach` is a
/// physical-device contextual auto-attach: the shim saw `xcrun devicectl
/// device install|process launch --device <id>` succeed and carries that
/// `--device` spec in `deviceIdentifier` (no sim UDID exists). The daemon
/// resolves the spec to a connected device and drives the same explicit
/// attach + mount path the GUI picker and `deviceterm device attach` use.
public enum ShimEventType: String, Sendable, Equatable, CaseIterable {
    case booted
    case shutdown
    case deviceAttach
}

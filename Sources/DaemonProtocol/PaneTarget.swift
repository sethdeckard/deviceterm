// SPDX-License-Identifier: GPL-3.0-or-later
//
/// The identity of the *device* a pane mirrors, independent of the
/// pane itself. A pane mirrors either a CoreSimulator (keyed by its
/// **UDID**) or a physically-connected iPhone/iPad (keyed by its stable
/// CoreDevice **UDID** from `devicectl`, carried in `deviceId`). The
/// field names distinguish the Simulator and physical-device namespaces:
/// `udid` means exactly "a CoreSimulator UDID," while `deviceId` means
/// exactly "a physical-device UDID."
///
/// This is the seam that lets a pane be a sim or a physical device
/// without the rest of the system caring which. Consumers that need an
/// *identity/dedup* key
/// read `key`; consumers that genuinely need a CoreSimulator UDID keep
/// reading the sim udid directly (they only ever hold sim panes).
///
/// `Codable` via Swift's automatic external-tagging synthesis, which
/// matches the existing `PaneSlot` precedent exactly:
///
///   - `.sim(udid: "ABC")` → `{"sim":{"udid":"ABC"}}`
///   - `.device(deviceId: "00008130-…")`
///     → `{"device":{"deviceId":"00008130-…"}}`
///
/// The `.sim` encoding is **byte-identical** to the `PaneSlot`
/// `.sim` branch, so a sim payload is the same bytes either way.
/// A golden-fixture test pins those exact bytes
/// so a future compiler change to the synthesis can't drift silently.
public enum PaneTarget: Equatable, Hashable, Sendable, Codable {
    case sim(udid: String)
    case device(deviceId: String)

    /// Stable identity/dedup key. For a sim this is the UDID (so a
    /// dedup keyed on `key` is byte-identical to UDID dedup);
    /// for a physical device it is the `deviceId`.
    public var key: String {
        switch self {
        case let .sim(udid):
            return udid

        case let .device(deviceId):
            return deviceId
        }
    }
}

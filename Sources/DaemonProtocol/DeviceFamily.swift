// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceFamily: the coarse product family the GUI branches on (e.g.
// sizing a watch pane smaller than a phone pane). The daemon classifies a
// CoreSimulator device-type identifier into one of these; clients consume
// the result off the wire and never parse identifiers themselves.
//
// On the wire the field stays a `String?` for forward-compatibility:
// Apple adds device families independently of our `wireVersion`, so a
// newer daemon can legitimately send a family an older client doesn't
// know. Consume it through `init(wire:)`, which maps any unrecognized
// value to `.unknown`; never strict-decode it.

public enum DeviceFamily: String, Sendable, Equatable, CaseIterable {
    case watch
    case phone
    case pad
    // This enum mirrors device *hardware* classes (watch/phone/pad/tv),
    // not OS names, so the two-letter `tv` is the right identifier here:
    // `tvOS` would describe the OS, not the device. Disable the min-length
    // rule for this one case rather than distort the API.
    // swiftlint:disable:next identifier_name
    case tv
    case unknown

    /// Lenient decode of a wire family string: an unrecognized value
    /// (a future family) becomes `.unknown` rather than failing.
    public init(wire raw: String) {
        self = DeviceFamily(rawValue: raw) ?? .unknown
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One line of hinge reader output, parsed.
///
/// Split from `HingeMonitor` so the parse is testable without spawning
/// anything. Two readers print two shapes (`HingeReaderSource`).
///
/// `devicectl device motion hinge-angle`, with the angle's own field unpadded
/// on a three-digit value:
///
/// ```
/// • +3.973s : Angle: 30.0°  Mech: 30.0°  Velocity:+0.0°/s  AngleValid:Y  …
/// • +10.718s : Angle:150.0°  Mech:150.0°  Velocity:+0.0°/s  AngleValid:Y  …
/// ```
///
/// Text rather than JSON because `--json-output` writes a single result
/// document when the command exits and moves these lines to stderr. There is
/// no machine-readable form of the live stream, so this is the contract
/// available, and it is Apple's to change.
///
/// The guest helper's `watch` mode, whose format is DeviceTerm's own
/// (`FoldHelperSource`):
///
/// ```
/// angle 180.0
/// orientation landscape-right
/// ```
///
/// The second shape is the device orientation an orientation control event
/// turned it to, which only the guest helper reports.
enum HingeReading {
    /// The angle this line reports, or nil when it carries none.
    ///
    /// Nil on `AngleValid:N`, which the device emits for a reading it does not
    /// stand behind, and nil outside `0...180`. Both would otherwise reach a
    /// slider and a renderer as a number.
    static func degrees(fromLine line: String) -> Double? {
        let degrees = line.hasPrefix("angle ") ? helperDegrees(line) : devicectlDegrees(line)
        guard let degrees, FoldPosture.degreeRange.contains(degrees) else { return nil }
        return degrees
    }

    /// The device orientation a `watch` line reports, or nil when it carries
    /// none: exactly `orientation <value>`, in the values the helper's
    /// `orientation` command takes. A flat value is nil, since the pane is
    /// drawn in the upright orientation the device was last in.
    static func orientation(fromLine line: String) -> Orientation? {
        let fields = line.split(separator: " ")
        guard fields.count == 2, fields[0] == "orientation" else { return nil }
        return FoldHelperSource.orientation(fromValue: String(fields[1]))
    }

    /// A `watch` line: exactly `angle <degrees>`.
    private static func helperDegrees(_ line: String) -> Double? {
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { return nil }
        return Double(fields[1])
    }

    /// A `devicectl` line. `AngleValid:` cannot be mistaken for `Angle:`
    /// here, because the literal searched for ends in the colon and that
    /// field's name does not.
    private static func devicectlDegrees(_ line: String) -> Double? {
        guard line.contains("AngleValid:Y"), let marker = line.range(of: "Angle:") else { return nil }
        let rest = line[marker.upperBound...]
        let digits = rest.drop { $0 == " " }.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }
}

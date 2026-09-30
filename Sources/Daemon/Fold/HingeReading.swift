// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One line of `devicectl device motion hinge-angle` output, parsed.
///
/// Split from `HingeMonitor` so the parse is testable without spawning
/// anything. The shape it reads is, with the angle's own field unpadded on a
/// three-digit value:
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
enum HingeReading {
    /// The angle this line reports, or nil when it carries none.
    ///
    /// Nil on `AngleValid:N`, which the device emits for a reading it does not
    /// stand behind, and nil outside `0...180`. Both would otherwise reach a
    /// slider and a renderer as a number.
    ///
    /// `AngleValid:` cannot be mistaken for `Angle:` here, because the literal
    /// searched for ends in the colon and that field's name does not.
    static func degrees(fromLine line: String) -> Double? {
        guard line.contains("AngleValid:Y") else { return nil }
        guard let marker = line.range(of: "Angle:") else { return nil }
        let rest = line[marker.upperBound...]
        let digits = rest.drop { $0 == " " }.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let degrees = Double(digits), FoldPosture.degreeRange.contains(degrees) else {
            return nil
        }
        return degrees
    }
}

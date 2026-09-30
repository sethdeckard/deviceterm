// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

/// The parse of `devicectl device motion hinge-angle` output.
///
/// Every accepted line here is copied from a real run against a booted Duo,
/// because the format is Apple's and inventing plausible lines would pin
/// something nobody emits.
struct HingeReadingTests {
    @Test("reads the angle out of a real line", arguments: [
        ("• +0.000s : Angle:  0.0°  Mech:  0.0°  Velocity:+0.0°/s  AngleValid:Y  VelocityValid:N  Range:0-180°", 0.0),
        ("• +3.973s : Angle: 30.0°  Mech: 30.0°  Velocity:+0.0°/s  AngleValid:Y  VelocityValid:N  Range:0-180°", 30.0),
        ("• +7.347s : Angle: 90.0°  Mech: 90.0°  Velocity:+0.0°/s  AngleValid:Y  VelocityValid:N  Range:0-180°", 90.0),
        ("• +10.718s : Angle:150.0°  Mech:150.0°  Velocity:+0.0°/s  AngleValid:Y  Range:0-180°", 150.0),
        ("• +0.000s : Angle: 51.5°  Mech: 51.5°  Velocity:+0.0°/s  AngleValid:Y  VelocityValid:N  Range:0-180°", 51.5)
    ])
    func parsesRealLines(line: String, expected: Double) {
        // The 150° line is the one with no space after the colon, which a
        // parser that skipped a fixed width would get wrong.
        #expect(HingeReading.degrees(fromLine: line) == expected)
    }

    @Test("an invalid reading is not an angle")
    func rejectsAnInvalidReading() {
        let line = "• +1.000s : Angle: 44.0°  Mech: 44.0°  Velocity:+0.0°/s"
            + "  AngleValid:N  VelocityValid:N  Range:0-180°"
        // The device says it does not stand behind this number, so neither
        // does the slider or the renderer downstream.
        #expect(HingeReading.degrees(fromLine: line) == nil)
    }

    @Test("the banner and other chatter carry no angle", arguments: [
        "Hinge angle monitoring started. 86400 seconds remaining:",
        "ERROR: Command timeout of 25.0 seconds exceeded. Assuming command got stuck and aborting.",
        "",
        "• +1.0s : Mech: 30.0°  Velocity:+0.0°/s  AngleValid:Y"
    ])
    func rejectsLinesWithoutAnAngle(line: String) {
        #expect(HingeReading.degrees(fromLine: line) == nil)
    }

    @Test("an out-of-range angle is refused", arguments: [
        "• +1.0s : Angle:-10.0°  AngleValid:Y",
        "• +1.0s : Angle:900.0°  AngleValid:Y"
    ])
    func rejectsOutOfRange(line: String) {
        #expect(HingeReading.degrees(fromLine: line) == nil)
    }

    @Test("AngleValid is not mistaken for Angle")
    func doesNotReadTheValidityFieldAsTheAngle() {
        // `AngleValid:` ends in a colon too, so a search for `Angle` rather
        // than `Angle:` would land on it and parse nothing usable. Ordering
        // saves a first-match search here, but only by accident, so this pins
        // the field that would break it.
        let reversed = "• +1.0s : AngleValid:Y  Angle: 77.0°"
        #expect(HingeReading.degrees(fromLine: reversed) == 77.0)
    }
}

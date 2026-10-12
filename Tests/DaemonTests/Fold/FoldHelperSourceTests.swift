// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Testing

/// The guest helper's modes, and the payload values the daemon sends it.
struct FoldHelperSourceTests {
    @Test
    func theHingeModeCarriesTheAngle() {
        #expect(FoldHelperSource.hingeArguments(degrees: 95) == ["hinge", "95.0"])
    }

    @Test
    func theWatchModeIsTheHelpersOwn() {
        #expect(FoldHelperSource.watchArguments == ["watch"])
        #expect(FoldHelperSource.code.contains("strcmp(argv[1], \"watch\")"))
    }

    @Test("each device orientation sends Device Hub's value", arguments: [
        (Orientation.portrait, "portrait"),
        (.portraitUpsideDown, "pud"),
        (.landscapeLeft, "landscape-left"),
        (.landscapeRight, "landscape-right")
    ])
    func theOrientationModeSendsDeviceHubsValue(orientation: Orientation, value: String) {
        #expect(FoldHelperSource.orientationArguments(orientation) == ["orientation", value])
    }

    @Test("the helper accepts every value the daemon sends", arguments: Orientation.allCases)
    func theHelperAcceptsEveryValueTheDaemonSends(orientation: Orientation) throws {
        // The C program checks its argument against its own list. A value the
        // Swift side sends but the list lacks would fail every rotation to it.
        let value = try #require(FoldHelperSource.orientationArguments(orientation).last)
        #expect(FoldHelperSource.code.contains("\"\(value)\""))
    }

    @Test("each flat orientation sends Device Hub's value", arguments: [
        (FlatOrientation.faceUp, "faceup"),
        (.faceDown, "facedown")
    ])
    func theOrientationModeLaysTheDeviceFlat(flat: FlatOrientation, value: String) {
        #expect(FoldHelperSource.orientationArguments(flat) == ["orientation", value])
        // The C program's own list has to carry it too, or the helper refuses.
        #expect(FoldHelperSource.code.contains("\"\(value)\""))
    }
}

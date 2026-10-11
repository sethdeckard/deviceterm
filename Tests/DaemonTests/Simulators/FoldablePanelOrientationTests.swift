// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Testing

/// How a foldable's device orientation reads on each panel.
///
/// The inner-panel table is the one measured on the iPhone Duo across two
/// boots: device portrait reads `landscapeRight`, and so on round the cycle.
struct FoldablePanelOrientationTests {
    @Test("the cover reads the device orientation unchanged", arguments: Orientation.allCases)
    func theCoverReadsTheDeviceOrientation(device: Orientation) {
        #expect(FoldablePanelOrientation.display(forDevice: device, onInnerPanel: false) == device)
        #expect(FoldablePanelOrientation.device(forDisplay: device, onInnerPanel: false) == device)
    }

    @Test("the inner panel reads a quarter turn off the device", arguments: [
        (Orientation.portrait, Orientation.landscapeRight),
        (.landscapeLeft, .portrait),
        (.portraitUpsideDown, .landscapeLeft),
        (.landscapeRight, .portraitUpsideDown)
    ])
    func theInnerPanelReadsAQuarterTurnOff(device: Orientation, display: Orientation) {
        #expect(FoldablePanelOrientation.display(forDevice: device, onInnerPanel: true) == display)
        #expect(FoldablePanelOrientation.device(forDisplay: display, onInnerPanel: true) == device)
    }

    @Test("an absolute request names the device and waits for its reading")
    func anAbsoluteRequestResolvesThroughThePanel() {
        let resolution = FoldablePanelOrientation.resolve(
            .absolute(.landscapeLeft),
            confirmed: nil,
            onInnerPanel: true
        )
        #expect(resolution == .init(device: .landscapeLeft, display: .portrait))
    }

    @Test("a relative step turns the device, not the reading")
    func aRelativeStepTurnsTheDevice() {
        // The inner panel reads portrait while the device is landscapeLeft.
        // Rotating left from there turns the device to portraitUpsideDown,
        // which the inner panel reads as landscapeLeft. Stepping from the
        // reading instead would send landscapeLeft, which the device is
        // already at.
        let resolution = FoldablePanelOrientation.resolve(
            .relative(.left),
            confirmed: .portrait,
            onInnerPanel: true
        )
        #expect(resolution == .init(device: .portraitUpsideDown, display: .landscapeLeft))
    }

    @Test
    func aRelativeStepWithNothingConfirmedCannotResolve() {
        #expect(FoldablePanelOrientation.resolve(.relative(.right), confirmed: nil, onInnerPanel: true) == nil)
    }
}

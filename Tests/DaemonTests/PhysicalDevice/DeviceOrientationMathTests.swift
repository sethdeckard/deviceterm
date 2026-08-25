// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import InteractionRelay
import Testing

// The pure stepping math that turns an absolute target orientation into the
// device's relative left/right 90° steps. Device-free.

@Test
func leftStepCyclesCounterClockwise() {
    #expect(DeviceOrientationMath.step(.portrait, .left) == .landscapeLeft)
    #expect(DeviceOrientationMath.step(.landscapeLeft, .left) == .portraitUpsideDown)
    #expect(DeviceOrientationMath.step(.portraitUpsideDown, .left) == .landscapeRight)
    #expect(DeviceOrientationMath.step(.landscapeRight, .left) == .portrait)
}

@Test
func rightStepCyclesClockwise() {
    #expect(DeviceOrientationMath.step(.portrait, .right) == .landscapeRight)
    #expect(DeviceOrientationMath.step(.landscapeRight, .right) == .portraitUpsideDown)
    #expect(DeviceOrientationMath.step(.portraitUpsideDown, .right) == .landscapeLeft)
    #expect(DeviceOrientationMath.step(.landscapeLeft, .right) == .portrait)
}

@Test
func directionTakesTheFewestSteps() {
    #expect(DeviceOrientationMath.direction(from: .portrait, to: .portrait) == nil)
    #expect(DeviceOrientationMath.direction(from: .portrait, to: .landscapeLeft) == .left) // 1 left
    #expect(DeviceOrientationMath.direction(from: .portrait, to: .landscapeRight) == .right) // 1 right vs 3 left
    #expect(DeviceOrientationMath.direction(from: .portrait, to: .portraitUpsideDown) == .left) // 2 either way
}

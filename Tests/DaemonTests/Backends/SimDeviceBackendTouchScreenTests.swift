// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

@Test("touch screen addressing", arguments: [
    // A single-panel device keeps the fixed digitizer target, held or not.
    (false, false, UInt32(0), UInt32(1), UInt32(0)),
    (false, true, UInt32(3), UInt32(1), UInt32(0)),
    // A new contact on a foldable goes to the bound panel.
    (true, false, UInt32(0), UInt32(1), UInt32(1)),
    (true, false, UInt32(1), UInt32(3), UInt32(3)),
    // A held contact stays on the panel it went down on after a fold moves
    // the binding, so its moves and release don't land on the other panel.
    (true, true, UInt32(1), UInt32(3), UInt32(1)),
    (true, true, UInt32(3), UInt32(1), UInt32(3))
])
func addressesTouchToTheRightPanel(
    foldable: Bool,
    holding: Bool,
    heldOn: UInt32,
    bound: UInt32,
    expected: UInt32
) {
    #expect(
        SimDeviceBackend.touchScreenID(foldable: foldable, holding: holding, heldOn: heldOn, bound: bound)
            == expected
    )
}

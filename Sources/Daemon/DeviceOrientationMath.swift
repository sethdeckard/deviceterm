// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceOrientationMath: pure helpers for reaching an absolute `Orientation`
// via the device's *relative* 90° steps (it only rotates left/right, one step at
// a time). Kept pure and standalone so the stepping is unit-tested without a
// device. The relay performs each `RotationInput` step; this decides which.

import DaemonProtocol
import InteractionRelay

enum DeviceOrientationMath {
    /// The counter-clockwise ("left") rotation order: one `left` step advances by
    /// one index (wrapping), one `right` step retreats by one. Matches the
    /// device's documented cycle.
    static let leftCycle: [Orientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]

    /// The orientation reached by stepping `direction` once from `current`.
    static func step(_ current: Orientation, _ direction: RotationInput) -> Orientation {
        let index = leftCycle.firstIndex(of: current) ?? 0
        let next = direction == .left ? (index + 1) % 4 : (index + 3) % 4
        return leftCycle[next]
    }

    /// The direction to step from `current` toward `target` in the fewest steps
    /// (a 3-left is one right), or nil when already there.
    static func direction(from current: Orientation, to target: Orientation) -> RotationInput? {
        guard current != target else { return nil }
        let currentIndex = leftCycle.firstIndex(of: current) ?? 0
        let targetIndex = leftCycle.firstIndex(of: target) ?? 0
        let stepsLeft = (targetIndex - currentIndex + 4) % 4
        return stepsLeft <= 2 ? .left : .right
    }
}

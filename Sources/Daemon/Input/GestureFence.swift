// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The preempt signal a paced gesture polls from off-actor.
///
/// A one-way flag: the lane raises it, the gesture polls it, and it never
/// lowers. A preempted gesture releases its contact and ends, so nothing needs
/// to reuse a fence.
///
/// A gesture runs outside `PaneCoordinator`'s isolation (that is the point of
/// `SimInputSynthesis` being nonisolated), so it cannot read the lane's lease to
/// learn that live input wants the digitizer. The fence is the one bit it can
/// read from where it runs.
///
/// Isolated by a documented serial queue rather than a lock, matching
/// `SimDeviceBackend.inputGate`, which the paced loops already poll the same way
/// through `isInputGenerationCurrent`.
final class GestureFence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.pane.gesture-fence")
    private var preempted = false

    var isPreempted: Bool {
        queue.sync { preempted }
    }

    /// Ask the holder to release its contact and stop. Idempotent.
    func requestPreempt() {
        queue.sync { preempted = true }
    }
}

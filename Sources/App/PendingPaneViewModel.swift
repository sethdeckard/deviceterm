// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Observation
import SwiftUI

/// Presentation state for a pending pane. The controller flips `phase`
/// on each reconcile; `PendingPaneView` re-renders via Observation.
@MainActor
@Observable
final class PendingPaneViewModel {
    var phase: PendingPanePhase
    let label: String
    @ObservationIgnored var onRetry: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    init(phase: PendingPanePhase, label: String) {
        self.phase = phase
        self.label = label
    }
}

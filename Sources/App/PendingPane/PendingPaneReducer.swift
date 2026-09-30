// SPDX-License-Identifier: GPL-3.0-or-later

/// The placeholder pane's tiny state machine as a
/// pure function. The Router / TabListViewModel feed it the events a
/// pending pane can see (its attach threw or was refused as not booted, the
/// user hit Boot, or a fresh attach started); the transitions are
/// unit-tested without any view or daemon. Mirrors the shape of
/// `SimPaneReducer` for the live render path.
enum PendingPaneReducer {
    static func reduce(
        _ phase: PendingPanePhase,
        _ event: PendingPaneEvent
    ) -> PendingPanePhase {
        switch event {
        case let .attachFailed(message):
            return .failed(message)

        case let .deviceNotBooted(message):
            return .notBooted(message)

        case .bootStarted:
            // Only a not-booted placeholder has a Boot button to press.
            guard case .notBooted = phase else { return phase }
            return .booting

        case .retried:
            return .attaching
        }
    }
}

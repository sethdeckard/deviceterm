// SPDX-License-Identifier: GPL-3.0-or-later

/// The placeholder pane's tiny state machine as a
/// pure function. The Router / TabListViewModel feed it the two events a
/// pending pane can see (its attach threw, or the user hit Retry); the
/// transitions are unit-tested without any view or daemon. Mirrors the
/// shape of `SimPaneReducer` for the live render path.
enum PendingPaneReducer {
    static func reduce(
        _ phase: PendingPanePhase,
        _ event: PendingPaneEvent
    ) -> PendingPanePhase {
        switch event {
        case let .attachFailed(message):
            return .failed(message)

        case .retried:
            return .attaching
        }
    }
}

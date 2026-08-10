// SPDX-License-Identifier: GPL-3.0-or-later
//
// PendingPaneReducer: the placeholder pane's tiny state machine as a
// pure function. The Router / TabListViewModel feed it the two events a
// pending pane can see (its attach threw, or the user hit Retry); the
// transitions are unit-tested without any view or daemon. Mirrors the
// shape of `SimPaneReducer` for the live render path.

/// A pending pane's view-facing phase.
enum PendingPanePhase: Equatable, Sendable {
    /// The attach RPC is in flight, so show a spinner.
    case attaching
    /// The attach threw, so show the message + a Retry button.
    case failed(String)
}

/// Inputs that move a pending pane between phases.
enum PendingPaneEvent: Equatable, Sendable {
    /// The attach RPC threw; carry the message for the error overlay.
    case attachFailed(String)
    /// The user hit Retry; a fresh attach is being spawned.
    case retried
}

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

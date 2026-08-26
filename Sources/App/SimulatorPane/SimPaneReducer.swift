// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The simulator pane's state machine as a pure
/// function. SimulatorPaneViewModel feeds it daemon lifecycle events
/// + surface arrivals; the transitions are unit-tested without any
/// view or daemon. Consumes the shared `PaneLifecycle` wire enum.
enum SimPaneReducer {
    static func reduce(
        _ state: SimulatorPaneState,
        _ event: SimPaneEvent
    ) -> SimulatorPaneState {
        switch event {
        case .surfaceAttached:
            // The first surface promotes a booting pane to rendering;
            // once rendering/shutdown/failed, a frame doesn't regress it.
            return state == .booting ? .rendering : state

        case .lifecycle(.booting):
            // The daemon walking back to booting only matters if we were
            // already rendering (e.g. a reboot mid-stream).
            return state == .rendering ? .booting : state

        case .lifecycle(.rendering):
            return .rendering

        case .lifecycle(.shutdown):
            return .shutdown

        case .lifecycle(.failed):
            return .failed("daemon reported pane failure")

        case let .subscriptionFailed(message):
            return .failed(message)
        }
    }
}

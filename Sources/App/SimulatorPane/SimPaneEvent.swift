// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Inputs that can move a sim pane between states.
enum SimPaneEvent: Equatable {
    /// A non-nil IOSurface arrived (a surface.changed that looked up).
    case surfaceAttached
    /// The daemon reported a lifecycle transition (state.changed).
    case lifecycle(PaneLifecycle)
    /// The subscription stream threw / the daemon dropped the pane.
    case subscriptionFailed(String)
}

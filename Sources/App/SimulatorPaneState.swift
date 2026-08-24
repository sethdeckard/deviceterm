// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The pane's view-facing state (overlay + surface presentation).
enum SimulatorPaneState: Equatable {
    case booting
    case rendering
    case shutdown
    case failed(String)
}

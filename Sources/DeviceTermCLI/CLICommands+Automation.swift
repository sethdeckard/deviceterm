// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Request encoding for the automation-program verbs.
///
/// Its own file rather than a case in `CLICommands+Workspace`: these name
/// no window, tab, or pane, and the separation keeps that visible.
extension CLICommands {
    static func automationStatusRequest() throws -> RPCEnvelope {
        try request(
            method: .automationStatus,
            body: AppCommandParams.ListAutomationPrograms()
        )
    }

    static func automationRestartRequest(name: String?) throws -> RPCEnvelope {
        try request(
            method: .automationRestart,
            body: AppCommandParams.RestartAutomationProgram(name: name)
        )
    }
}

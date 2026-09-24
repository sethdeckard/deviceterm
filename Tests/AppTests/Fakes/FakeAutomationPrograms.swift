// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation

/// Supervision as the two automation verbs see it, with no coordinator
/// behind it.
///
/// Defaults to no configured programs, which is what every test that is
/// not about those verbs wants: the dispatcher needs the role injected,
/// but nothing else in the workspace touches it.
@MainActor
final class FakeAutomationPrograms: AutomationProgramReading {
    var programs: [AutomationProgramStatus] = []
    /// Thrown by `restart` to model a name matching no configured entry.
    var restartError: Error?
    private(set) var restartCalls: [String?] = []

    func status() -> [AutomationProgramStatus] { programs }

    func restart(name: String?) async throws -> [AutomationProgramStatus] {
        restartCalls.append(name)
        // Yield so the fake still crosses a suspension point, like the real
        // coordinator does when it has to open a tab.
        await Task.yield()
        if let restartError { throw restartError }
        return programs
    }
}

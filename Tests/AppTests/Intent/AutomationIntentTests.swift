// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// The two automation verbs across the intent layer: the back-channel frame
// becomes an intent, and the dispatcher answers it from supervision without
// touching the Router.
//
// Neither verb names a window, tab or pane, so neither goes through the
// resolver or the authority check. That is what makes them reachable from
// any authenticated session rather than only a granted one.

@MainActor
private func dispatcher(
    _ programs: FakeAutomationPrograms
) -> (IntentDispatcher, WorkspaceViewModel) {
    let workspace = WorkspaceViewModel()
    let dispatcher = IntentDispatcher(
        workspace: workspace,
        router: Router(
            workspace: workspace,
            daemon: FakeDaemonClient(),
            rpcPerformance: nil
        ),
        actionDelegate: nil,
        automationPrograms: programs
    )
    return (dispatcher, workspace)
}

private func frame(_ kind: AppCommandKind, params: some Encodable) throws -> AppCommand {
    AppCommand(
        commandId: "c1",
        kind: kind,
        originatingSessionId: nil,
        params: try JSONEncoder().encode(params),
        originAutomationGrant: false,
        expiresAtMonotonicNanos: nil
    )
}

@Test
@MainActor
func translatesAutomationStatus() throws {
    let command = try frame(.automationStatus, params: AppCommandParams.ListAutomationPrograms())
    #expect(try CLIIntentTranslator.translate(command) == .automationProgramStatus)
}

@Test
@MainActor
func translatesAutomationRestartWithItsName() throws {
    let command = try frame(
        .automationRestart,
        params: AppCommandParams.RestartAutomationProgram(name: "clock")
    )
    #expect(try CLIIntentTranslator.translate(command) == .automationProgramRestart(name: "clock"))
}

@Test
@MainActor
func statusAnswersFromSupervision() async {
    let programs = FakeAutomationPrograms()
    programs.programs = [AutomationProgramStatus(name: "clock", state: .running, pid: 910)]
    let (dispatcher, _) = dispatcher(programs)
    let result = await dispatcher.dispatch(.automationProgramStatus, origin: .inProcess)
    #expect(result == .data(.automationPrograms(programs.programs)))
}

@Test
@MainActor
func restartPassesItsNameThrough() async {
    let programs = FakeAutomationPrograms()
    let (dispatcher, _) = dispatcher(programs)
    _ = await dispatcher.dispatch(
        .automationProgramRestart(name: "clock"),
        origin: .inProcess
    )
    #expect(programs.restartCalls == ["clock"])
}

/// A name no entry has is the one thing these verbs can be told that they
/// cannot act on, and it has to reach the caller as a failure.
@Test
@MainActor
func restartSurfacesAnUnknownName() async {
    let programs = FakeAutomationPrograms()
    programs.restartError = IntentError.notFound(kind: "automation program", ref: "nope")
    let (dispatcher, _) = dispatcher(programs)
    let result = await dispatcher.dispatch(
        .automationProgramRestart(name: "nope"),
        origin: .inProcess
    )
    guard case .error = result else {
        Issue.record("expected a failure for a name no entry has")
        return
    }
}

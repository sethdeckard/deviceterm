// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

/// Records requests and replays canned responses without a daemon.
private final class FakeTransport: CLITransport {
    private var queue: [Data]
    private let fallback: Data
    var error: CLIError?
    private(set) var sent: [RPCEnvelope] = []
    private(set) var timeouts: [Double] = []

    init(response: Data = Data(), error: CLIError? = nil) {
        queue = []
        fallback = response
        self.error = error
    }

    init(responses: [Data], error: CLIError? = nil) {
        queue = responses
        fallback = Data()
        self.error = error
    }

    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data {
        sent.append(envelope)
        timeouts.append(timeoutSeconds)
        if !queue.isEmpty { return queue.removeFirst() }
        if let error { throw error }
        return fallback
    }
}

private let testCredentials = (sessionId: "S1", cap: "C1")

private func encoded(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
}

private func testWindow() -> WorkspaceWindow {
    WorkspaceWindow(
        id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        shortId: "aaaaaa",
        name: "main",
        index: 0,
        current: true,
        focused: true,
        selectedTabId: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        tabCount: 1
    )
}

private func testTab() -> WorkspaceTab {
    WorkspaceTab(
        id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        shortId: "bbbbbb",
        name: "build",
        title: "swift test",
        windowId: testWindow().id,
        current: true,
        selected: true,
        protected: false,
        state: .ready,
        paneCount: 1
    )
}

private func testTerminalPane() -> WorkspacePane {
    WorkspacePane(
        id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
        shortId: "cccccc",
        name: "shell",
        kind: .terminal,
        tabId: testTab().id,
        tabTitle: testTab().title,
        windowId: testTab().windowId,
        current: true,
        focused: true,
        capabilities: [.sendInput, .captureText],
        terminal: .init(
            sessionId: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            title: "swift test",
            tty: "/dev/ttys003",
            cwd: "/project"
        )
    )
}

private func testSimulatorPane() -> WorkspacePane {
    WorkspacePane(
        id: "AAAAAAAA-1111-2222-3333-444444444444",
        shortId: "aaaaaa",
        name: "phone",
        kind: .simulator,
        tabId: testTab().id,
        tabTitle: testTab().title,
        windowId: testTab().windowId,
        current: false,
        focused: false,
        capabilities: [.touch, .text],
        simulator: .init(
            udid: "U1",
            displayName: "iPhone",
            family: "phone",
            state: .rendering,
            orientation: .portrait,
            pixelWidth: 1_206,
            pixelHeight: 2_622,
            capabilities: .simulator
        )
    )
}

private func oneDevicePaneResponse() throws -> Data {
    try encoded([
        PanesListEntry(
            paneId: "p1",
            udid: "U1",
            state: .rendering,
            family: "iphone",
            shortId: "sh1"
        )
    ])
}

// MARK: - Workspace reads

@Test
func workspaceListJSONPreservesGUIProjection() throws {
    let payload = try encoded([testWindow()])
    let fake = FakeTransport(response: payload)
    let outcome = run(.windowList(all: true), transport: fake, output: .json)

    var expected = payload
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
    #expect(fake.sent.map(\.method) == [RPCMethod.windowList.rawValue])
}

@Test
func workspaceListsUseLiveHumanFormatters() throws {
    let tabs = [testTab()]
    let fake = FakeTransport(response: try encoded(tabs))
    let outcome = run(.tabList(window: "main", all: false), transport: fake, output: .human)

    #expect(outcome == .stdout(formatWorkspaceTabs(tabs) + "\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.tabList.rawValue])
}

@Test
func workspaceShowRendersPaneDetails() throws {
    let pane = testTerminalPane()
    let fake = FakeTransport(response: try encoded(pane))
    let outcome = run(.paneShow(pane: "shell"), transport: fake, output: .human)

    #expect(outcome == .stdout(formatWorkspacePane(pane) + "\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.paneShow.rawValue])
}

/// `workspaceShowRendersPaneDetails` compares the output against the formatter
/// itself, so it pins the wiring and not the content. This pins the content:
/// the detail view carries every terminal field the projection publishes.
@Test
func humanPaneDetailCarriesEveryTerminalField() {
    let rendered = formatWorkspacePane(testTerminalPane())
    #expect(rendered.contains("session: CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
    #expect(rendered.contains("title:   swift test"))
    #expect(rendered.contains("tty:     /dev/ttys003"))
    #expect(rendered.contains("cwd:     /project"))
}

/// An absent optional omits its line rather than printing an empty field, and
/// the title prints either way because it is always present.
@Test
func humanPaneDetailOmitsAbsentTerminalFields() {
    let source = testTerminalPane()
    let pane = WorkspacePane(
        id: source.id,
        shortId: source.shortId,
        name: source.name,
        kind: .terminal,
        tabId: source.tabId,
        tabTitle: source.tabTitle,
        windowId: source.windowId,
        current: source.current,
        focused: source.focused,
        capabilities: source.capabilities,
        terminal: .init(sessionId: source.id, title: "shell", tty: nil, cwd: nil)
    )
    let rendered = formatWorkspacePane(pane)
    #expect(rendered.contains("title:   shell"))
    #expect(!rendered.contains("tty:"))
    #expect(!rendered.contains("cwd:"))
}

@Test
func malformedWorkspaceProjectionIsProtocolFailure() {
    let command = CLICommand.windowList(all: false)
    let outcome = run(
        command,
        transport: FakeTransport(response: Data(#"[{"id":1}]"#.utf8)),
        output: .human
    ).renderingFailure(for: command, output: .json)

    #expect(outcome.exitCode == 1)
    #expect(outcome.failure?.code == .protocolInvalidResponse)
    #expect(outcome.stdout.last == 0x0A)
}

// MARK: - Committed mutations

@Test
func workspaceMutationHumanUsesCommittedObjects() throws {
    let receipt = WorkspaceMutationReceipt(window: testWindow(), tab: testTab(), pane: testTerminalPane())
    let fake = FakeTransport(response: try encoded(receipt))
    let outcome = try sendWorkspaceMutation(
        transport: fake,
        output: .human,
        build: { try CLICommands.tabOpenRequest(window: nil) }
    )

    #expect(outcome == .stdout("ok window=aaaaaa tab=bbbbbb pane=cccccc\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.tabOpen.rawValue])
    #expect(fake.timeouts == [AppCommandDeadline.workspaceCLIRequestTimeoutSeconds])
}

@Test
func workspaceMutationJSONPreservesCommittedReceipt() throws {
    let receipt = WorkspaceMutationReceipt(pane: testTerminalPane())
    let payload = try encoded(receipt)
    let fake = FakeTransport(response: payload)
    let outcome = try sendWorkspaceMutation(
        transport: fake,
        output: .json,
        build: { try CLICommands.paneSplitRequest(pane: "shell", direction: .right) }
    )

    var expected = payload
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
    #expect(fake.sent.map(\.method) == [RPCMethod.paneSplit.rawValue])
}

@Test
func runRoutesPaneFocusThroughAutomationMethod() throws {
    let receipt = WorkspaceMutationReceipt(pane: testTerminalPane())
    let fake = FakeTransport(response: try encoded(receipt))
    let outcome = run(.paneFocus(pane: "shell"), transport: fake, output: .human)

    #expect(outcome.exitCode == 0)
    #expect(fake.sent.map(\.method) == [RPCMethod.paneFocus.rawValue])
    #expect(fake.timeouts == [AppCommandDeadline.workspaceCLIRequestTimeoutSeconds])
}

// MARK: - Explicit terminal operations

@Test
func paneCaptureHumanAppendsOnlyMissingNewline() throws {
    let pane = testTerminalPane()
    let first = FakeTransport(response: try encoded(WorkspaceCaptureResult(pane: pane, text: "one\ntwo")))
    let second = FakeTransport(response: try encoded(WorkspaceCaptureResult(pane: pane, text: "already\n")))

    #expect(
        try handlePaneCaptureText(pane: "shell", ansi: false, transport: first, output: .human)
            == .stdout("one\ntwo\n")
    )
    #expect(
        try handlePaneCaptureText(pane: "shell", ansi: false, transport: second, output: .human)
            == .stdout("already\n")
    )
    #expect(first.sent.map(\.method) == [RPCMethod.paneCaptureText.rawValue])
}

@Test
func paneCaptureAnsiPassesTheFlagAndTheEscapesThrough() throws {
    let styled = "\u{1b}[31mred\u{1b}[0m plain\n"
    let fake = FakeTransport(
        response: try encoded(WorkspaceCaptureResult(pane: testTerminalPane(), text: styled))
    )

    let outcome = try handlePaneCaptureText(
        pane: "shell",
        ansi: true,
        transport: fake,
        output: .human
    )

    // Human mode writes the bytes as they arrived, which is what makes
    // `--ansi` render in color at a terminal.
    #expect(outcome == .stdout(Data(styled.utf8)))

    let sent = try #require(fake.sent.first)
    guard case let .params(data) = sent.body else {
        Issue.record("expected params body")
        return
    }
    let params = try JSONDecoder().decode(
        AppCommandParams.CapturePaneText.self,
        from: data
    )
    #expect(params.ansi)
}

@Test
func paneCaptureJSONIncludesResolvedPane() throws {
    let result = WorkspaceCaptureResult(pane: testTerminalPane(), text: "contents")
    let payload = try encoded(result)
    let fake = FakeTransport(response: payload)
    let outcome = try handlePaneCaptureText(pane: "shell", ansi: false, transport: fake, output: .json)

    var expected = payload
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
}

@Test
func paneSendInputReturnsGUIReceipt() throws {
    let receipt = WorkspaceMutationReceipt(pane: testTerminalPane(), bytes: 5, typeDelayMs: 8)
    let fake = FakeTransport(response: try encoded(receipt))
    let outcome = run(
        .paneSendInput(pane: "shell", text: "hello", typeDelay: 8),
        transport: fake,
        output: .human
    )

    #expect(outcome == .stdout("ok pane=cccccc bytes=5 typeDelayMs=8\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.paneSendInput.rawValue])
}

// MARK: - Device verbs and legacy device-pane resolution

@Test
func devicesListFormatsBothOutputModes() throws {
    let roster = [DeviceRosterEntry(id: "U1", kind: .sim, name: "iPhone", state: "Booted")]
    let human = try handleDevicesList(transport: FakeTransport(response: encoded(roster)), output: .human)
    let json = try handleDevicesList(transport: FakeTransport(response: encoded(roster)), output: .json)

    #expect(human == .stdout(formatDeviceRoster(roster) + "\n"))
    #expect(json.stdout == (try encodeJSONReceipt(roster)))
}

@Test
func deviceAttachResolvesThenPublishes() throws {
    let roster = [DeviceRosterEntry(id: "U1", kind: .sim, name: "iPhone", state: "Booted")]
    let receipt = WorkspaceMutationReceipt(pane: testSimulatorPane())
    let fake = FakeTransport(responses: [try encoded(roster), try encoded(receipt)])
    let outcome = try handleDeviceAttach(
        ref: "U1",
        transport: fake,
        output: .human,
        creds: testCredentials
    )

    #expect(outcome == .stdout("ok pane=aaaaaa\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.devicesList.rawValue, RPCMethod.paneAttach.rawValue])
}

@Test
func deviceAttachUnknownRefDoesNotPublish() throws {
    let fake = FakeTransport(response: try encoded([DeviceRosterEntry]()))
    let outcome = try handleDeviceAttach(
        ref: "nope",
        transport: fake,
        output: .human,
        creds: testCredentials
    )

    #expect(outcome.exitCode == 1)
    #expect(fake.sent.map(\.method) == [RPCMethod.devicesList.rawValue])
}

@Test
func deviceInputResolutionUsesInternalDevicePaneList() throws {
    let fake = FakeTransport(response: try oneDevicePaneResponse())
    let resolved = try resolvePane(ref: nil, transport: fake, creds: testCredentials)

    #expect(resolved == ResolvedPane(paneId: "p1", udid: "U1", shortId: "sh1"))
    #expect(fake.sent.map(\.method) == [RPCMethod.paneDeviceList.rawValue])
}

@Test
func tapStillResolvesThenDispatches() throws {
    let fake = FakeTransport(response: try oneDevicePaneResponse())
    let outcome = try sendResolved(
        ref: nil,
        output: .json,
        transport: fake,
        creds: testCredentials,
        humanFields: { _ in [("x", "1"), ("y", "2")] },
        jsonReceipt: { resolved in
            Receipt.Tap(
                udid: resolved.udid,
                paneId: resolved.paneId,
                shortId: resolved.shortId,
                x: 1,
                y: 2
            )
        },
        build: { try CLICommands.tapRequest(paneId: $0, x: 1, y: 2) }
    )

    #expect(outcome.exitCode == 0)
    #expect(fake.sent.map(\.method) == [RPCMethod.paneDeviceList.rawValue, RPCMethod.paneInputTap.rawValue])
}

// MARK: - Error mapping

@Test
func runMapsDaemonAndTransportErrors() {
    let daemon = run(
        .tabList(window: nil, all: false),
        transport: FakeTransport(error: .daemon(code: -32_000, message: "boom")),
        output: .human
    )
    let transport = run(
        .tabList(window: nil, all: false),
        transport: FakeTransport(error: .transport("cannot connect")),
        output: .human
    )

    #expect(daemon.failure?.code == .rpcServerError)
    #expect(daemon.stderr == "daemon error -32000: boom")
    #expect(transport.stderr == "cannot connect")
}

@Test
func daemonIntentDetailsSurviveJSONFailureRendering() throws {
    let details = Data(#"{"committed":{"tab":{"id":"T"}}}"#.utf8)
    let command = CLICommand.tabOpen(window: nil, cwd: nil, command: nil)
    let outcome = run(
        command,
        transport: FakeTransport(
            error: .daemon(
                code: -32_000,
                message: "intent.mutationFailed: session mint failed",
                details: details
            )
        ),
        output: .json
    ).renderingFailure(for: command, output: .json)
    let root = try #require(JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any])
    let error = try #require(root["error"] as? [String: Any])
    let renderedDetails = try #require(error["details"] as? [String: Any])

    #expect(error["code"] as? String == "intent.mutationFailed")
    #expect(renderedDetails["rpcCode"] as? Int == -32_000)
    #expect(renderedDetails["committed"] != nil)
}

@Test
func runRoutesAgentsToStdout() {
    #expect(run(.agents, transport: FakeTransport(), output: .human) == .stdout(AgentsText.documentation))
}

// MARK: - session show

private func capabilities(
    role: SessionRole?,
    sessionId: String?,
    automationGrant: Bool,
    allowedMethods: [String] = []
) -> DaemonCapabilitiesResponse {
    DaemonCapabilitiesResponse(
        role: role,
        sessionId: sessionId,
        automationGrant: automationGrant,
        allowedMethods: allowedMethods,
        wireVersion: DaemonProtocolInfo.wireVersion,
        linkagePolicyVersion: LinkagePolicy.currentVersion
    )
}

/// The three states a caller has to tell apart, and the whole reason the verb
/// exists. Holding no grant and failing to reach DeviceTerm call for opposite
/// responses, so they must never render alike.
@Test
func sessionShowReportsAGrantedSession() throws {
    let fake = FakeTransport(
        response: try encoded(
            capabilities(role: .automation, sessionId: "S-1", automationGrant: true)
        )
    )
    let outcome = try handleSessionShow(
        transport: fake,
        output: .json
    )

    #expect(outcome.exitCode == 0)
    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(text.contains("\"automationGrant\":true"))
    #expect(text.contains("\"id\":\"S-1\""))
    #expect(fake.sent.map(\.method) == [RPCMethod.daemonCapabilities.rawValue])
}

@Test
func sessionShowReportsAnUngrantedSessionWithoutFailing() throws {
    let fake = FakeTransport(
        response: try encoded(
            capabilities(role: .automation, sessionId: "S-1", automationGrant: false)
        )
    )
    let outcome = try handleSessionShow(
        transport: fake,
        output: .json
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.failure == nil)
    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(text.contains("\"automationGrant\":false"))
}

/// Reaching the daemon from outside a tab is a report, not a refusal.
@Test
func sessionShowReportsNoSessionWhenOutOfTab() throws {
    let fake = FakeTransport(
        response: try encoded(
            capabilities(role: nil, sessionId: nil, automationGrant: false)
        )
    )
    let outcome = try handleSessionShow(
        transport: fake,
        output: .json
    )

    #expect(outcome.exitCode == 0)
    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(text.contains("\"automationGrant\":false"))
    #expect(!text.contains("\"id\""))
    #expect(!text.contains("\"role\""))
}

/// An unreachable daemon must never render as "no grant". It fails with a
/// typed transport code, a nonzero exit, and no `automationGrant` key at all.
@Test
func sessionShowFailsTypedWhenTheDaemonIsUnreachable() throws {
    let command = CLICommand.sessionShow
    let fake = FakeTransport(
        error: .classified(code: .transportUnavailable, message: "no daemon")
    )
    let outcome = run(command, transport: fake, output: .json)
        .renderingFailure(for: command, output: .json)

    #expect(outcome.exitCode != 0)
    #expect(outcome.failure?.code == .transportUnavailable)
    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(!text.contains("automationGrant"))
}

/// End to end against a reply from a daemon that predates the explicit flag,
/// which a Sparkle swap can pair this CLI with. The response carries no
/// `automationGrant` key at all, and `session show` still reports the grant,
/// because an automation method appears in `allowedMethods` exactly when the
/// grant is live.
@Test("reports a flagless daemon's grant", arguments: [
    (#"["daemon.ping","pane.sendInput"]"#, "\"automationGrant\":true"),
    (#"["daemon.ping"]"#, "\"automationGrant\":false")
])
func sessionShowReadsAGrantFromAFlaglessDaemon(allowed: String, expected: String) throws {
    // A real reply from such a daemon omits BOTH new fields, not just the flag.
    let wire = #"{"allowedMethods":\#(allowed),"linkagePolicyVersion":1,"#
        + #""role":"automation","wireVersion":"0.6.0"}"#
    let outcome = try handleSessionShow(
        transport: FakeTransport(response: Data(wire.utf8)),
        output: .json
    )

    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(text.contains(expected))
    // The role still comes through, so the caller learns the session is real
    // even though this daemon cannot name it.
    #expect(text.contains(#""role":"automation""#))
    #expect(!text.contains(#""id""#))
}

/// `DEVICETERM_SESSION` is the caller's own claim, so it never reaches the
/// report. A caller whose cap is missing or empty never authenticates: the
/// daemon answers with no role and no session, while the variable still reads
/// as one. Reporting it would assert an identity nothing verified.
@Test
func sessionShowNeverReportsAnUnauthenticatedIdentity() throws {
    let wire = #"{"allowedMethods":["daemon.ping"],"linkagePolicyVersion":1,"wireVersion":"0.6.0"}"#
    let previous = ProcessInfo.processInfo.environment[DeviceTermEnv.session]
    setenv(DeviceTermEnv.session, "S-CLAIMED", 1)
    defer {
        if let previous { setenv(DeviceTermEnv.session, previous, 1) } else {
            unsetenv(DeviceTermEnv.session)
        }
    }

    let outcome = try handleSessionShow(
        transport: FakeTransport(response: Data(wire.utf8)),
        output: .json
    )

    let text = try #require(String(bytes: outcome.stdout, encoding: .utf8))
    #expect(!text.contains("S-CLAIMED"))
    #expect(!text.contains(#""id""#))
    #expect(!text.contains(#""role""#))
}

/// The two reasons an id can be missing are different answers, and the human
/// column has to say which. Reporting an authenticated session as having none
/// would contradict the role printed beneath it.
@Test
func sessionShowHumanSeparatesNoSessionFromNoReportedId() {
    let unauthenticated = SessionReportFormat.formatHuman(
        SessionReport(id: nil, role: nil, automationGrant: false)
    )
    let noReportedId = SessionReportFormat.formatHuman(
        SessionReport(id: nil, role: .automation, automationGrant: true)
    )

    #expect(unauthenticated.contains("(no authenticated session)"))
    #expect(noReportedId.contains("(not reported)"))
}

@Test
func sessionShowHumanRendersTheGrantAsWords() {
    #expect(
        SessionReportFormat.formatHuman(
            SessionReport(id: "S-1", role: .automation, automationGrant: true)
        ) == "session       S-1\nrole          automation\nautomation    granted\n"
    )
    #expect(
        SessionReportFormat.formatHuman(
            SessionReport(id: nil, role: nil, automationGrant: false)
        ) == "session       (no authenticated session)\nrole          (none)\nautomation    not granted\n"
    )
}

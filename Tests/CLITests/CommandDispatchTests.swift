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
        current: true,
        focused: true,
        capabilities: [.sendInput, .captureText],
        terminal: .init(
            sessionId: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
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
        try handlePaneCaptureText(pane: "shell", transport: first, output: .human)
            == .stdout("one\ntwo\n")
    )
    #expect(
        try handlePaneCaptureText(pane: "shell", transport: second, output: .human)
            == .stdout("already\n")
    )
    #expect(first.sent.map(\.method) == [RPCMethod.paneCaptureText.rawValue])
}

@Test
func paneCaptureJSONIncludesResolvedPane() throws {
    let result = WorkspaceCaptureResult(pane: testTerminalPane(), text: "contents")
    let payload = try encoded(result)
    let fake = FakeTransport(response: payload)
    let outcome = try handlePaneCaptureText(pane: "shell", transport: fake, output: .json)

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

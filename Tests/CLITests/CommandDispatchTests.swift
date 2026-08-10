// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

@testable import DeviceTermCLI

/// Records the envelopes it's handed and replays a canned response (or
/// throws), so the typed command handlers can be exercised without a
/// daemon, a socket, or a process exit.
private final class FakeTransport: CLITransport {
    private var queue: [Data]
    private let fallback: Data
    var error: CLIError?
    private(set) var sent: [RPCEnvelope] = []

    /// Replay `response` for every send (for single-round-trip handlers).
    init(response: Data = Data(), error: CLIError? = nil) {
        self.queue = []
        self.fallback = response
        self.error = error
    }

    /// Replay `responses` in order, one per send (for handlers that make
    /// more than one round-trip, e.g. resolve-then-act).
    init(responses: [Data]) {
        self.queue = responses
        self.fallback = Data()
        self.error = nil
    }

    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data {
        sent.append(envelope)
        if let error { throw error }
        if !queue.isEmpty { return queue.removeFirst() }
        return fallback
    }
}

/// A session owning a single sim pane: the sole-pane resolution target.
private func onePaneResponse() throws -> Data {
    try JSONEncoder().encode([
        PanesListEntry(paneId: "p1", udid: "U1", state: .rendering, family: "iphone", shortId: "sh1")
    ])
}

private let testCreds = (sessionId: "S1", cap: "C1")

private func encoded(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
}

private func stdoutString(_ outcome: CommandOutcome) -> String {
    String(bytes: outcome.stdout, encoding: .utf8) ?? ""
}

// MARK: - tabs list

@Test
func tabsListHumanMatchesFormatter() throws {
    let entries = [
        TabsListEntry(sessionId: "S1", label: "L1", shortId: "s1", name: "n1"),
        TabsListEntry(sessionId: "S2", label: "L2", shortId: "s2", name: nil)
    ]
    let fake = FakeTransport(response: try encoded(entries))
    let outcome = try handleTabsList(transport: fake, output: .human, currentSession: "S1")

    #expect(outcome.exitCode == 0)
    #expect(outcome.stderr == nil)
    // Deterministic against the shared formatter + line helper.
    #expect(outcome == .lines(
        TabsListFormatter.formatList(entries: entries, currentSessionId: "S1")
    ))
    #expect(fake.sent.count == 1)
    #expect(fake.sent.first?.method == RPCMethod.tabsList.rawValue)
}

@Test
func tabsListJSONEncodesRowsWithCurrentFlag() throws {
    let entries = [
        TabsListEntry(sessionId: "S1", label: "L1", shortId: "s1", name: "n1"),
        TabsListEntry(sessionId: "S2", label: "L2", shortId: "s2", name: nil)
    ]
    let fake = FakeTransport(response: try encoded(entries))
    let outcome = try handleTabsList(transport: fake, output: .json, currentSession: "S2")

    let expected = [
        Receipt.TabsListRow(
            current: false,
            shortId: "s1",
            name: "n1",
            displayTitle: nil,
            sessionId: "S1",
            label: "L1"
        ),
        Receipt.TabsListRow(
            current: true,
            shortId: "s2",
            name: nil,
            displayTitle: nil,
            sessionId: "S2",
            label: "L2"
        )
    ]
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout == (try encodeJSONReceipt(expected)))
}

@Test
func tabsListJSONCarriesTheLiveDisplayTitle() throws {
    // The daemon-side title cache reaches an external consumer: `--json`
    // carries the GUI's normalized label alongside the static name stamped
    // at session create. The human columns stay a pinned five-column shape,
    // so this rides JSON only.
    let entries = [
        TabsListEntry(
            sessionId: "S1",
            label: "L1",
            shortId: "s1",
            name: "branch",
            displayTitle: "vim foo.swift"
        )
    ]
    let fake = FakeTransport(response: try encoded(entries))
    let outcome = try handleTabsList(transport: fake, output: .json, currentSession: "S1")

    let expected = [
        Receipt.TabsListRow(
            current: true,
            shortId: "s1",
            name: "branch",
            displayTitle: "vim foo.swift",
            sessionId: "S1",
            label: "L1"
        )
    ]
    #expect(outcome.stdout == (try encodeJSONReceipt(expected)))
    // The human row is unchanged: a sixth column would break `awk -F'\t'`.
    #expect(TabsListFormatter.formatRow(entry: entries[0], isCurrent: true)
        == "*\ts1\tbranch\tS1\tL1")
}

@Test
func tabsListEmptyProducesNoOutput() throws {
    let fake = FakeTransport(response: try encoded([TabsListEntry]()))
    let outcome = try handleTabsList(transport: fake, output: .human, currentSession: nil)
    #expect(outcome == .ok)
}

// MARK: - tabs current

@Test
func tabsCurrentOutOfTabIsFailureWithHint() throws {
    let outcome = try handleTabsCurrent(
        transport: FakeTransport(),
        output: .human,
        currentSession: nil
    )
    #expect(outcome.exitCode == 1)
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.stderr == "not inside a deviceterm tab (\(DeviceTermEnv.session) unset); "
        + "run `deviceterm tabs list` to see open tabs")
}

@Test
func tabsCurrentStaleSessionIsFailure() throws {
    let fake = FakeTransport(response: try encoded([
        TabsListEntry(sessionId: "OTHER", label: nil)
    ]))
    let outcome = try handleTabsCurrent(transport: fake, output: .human, currentSession: "S1")
    #expect(outcome.exitCode == 1)
    #expect(outcome.stderr == "\(DeviceTermEnv.session)=S1 has no live tab; "
        + "the daemon may have restarted; try opening a fresh tab")
}

@Test
func tabsCurrentSuccessRendersRow() throws {
    let entry = TabsListEntry(sessionId: "S1", label: "L1", shortId: "s1", name: "n1")
    let fake = FakeTransport(response: try encoded([entry]))
    let outcome = try handleTabsCurrent(transport: fake, output: .human, currentSession: "S1")
    #expect(outcome.exitCode == 0)
    #expect(outcome == .stdout(TabsListFormatter.formatRow(entry: entry, isCurrent: true) + "\n"))
}

// MARK: - panes list

@Test
func panesListJSONEmitsWireEntries() throws {
    let panes = [
        PanesListEntry(paneId: "p1", udid: "U1", state: .rendering, family: "iphone", shortId: "sh1")
    ]
    let fake = FakeTransport(response: try encoded(panes))
    let outcome = try handlePanesList(
        transport: fake,
        output: .json,
        creds: (sessionId: "S1", cap: "C1")
    )
    #expect(outcome.stdout == (try encodeJSONReceipt(panes)))
    #expect(fake.sent.first?.method == RPCMethod.panesList.rawValue)
}

@Test
func panesListHumanColumnsPerRow() throws {
    let panes = [
        PanesListEntry(paneId: "p1", udid: "U1", state: .rendering, family: "iphone", shortId: "sh1")
    ]
    let fake = FakeTransport(response: try encoded(panes))
    let outcome = try handlePanesList(
        transport: fake,
        output: .human,
        creds: (sessionId: "S1", cap: "C1")
    )
    let text = stdoutString(outcome)
    #expect(text.hasPrefix("p1\tU1\trendering\t"))
    #expect(text.hasSuffix("\n"))
}

// MARK: - devices list

@Test
func devicesListHumanTrailsNewlineEvenWhenEmpty() throws {
    let fake = FakeTransport(response: try encoded([DeviceRosterEntry]()))
    let outcome = try handleDevicesList(transport: fake, output: .human)
    // Legacy `print(formatDeviceRoster(roster))` emitted a lone newline
    // for an empty roster; preserve that.
    #expect(outcome == .stdout("\n"))
    #expect(fake.sent.first?.method == RPCMethod.devicesList.rawValue)
}

@Test
func devicesListJSONEmitsRoster() throws {
    let roster = [
        DeviceRosterEntry(id: "U1", kind: .sim, name: "iPhone", state: "Booted")
    ]
    let fake = FakeTransport(response: try encoded(roster))
    let outcome = try handleDevicesList(transport: fake, output: .json)
    #expect(outcome.stdout == (try encodeJSONReceipt(roster)))
}

// MARK: - windows list

@Test
func windowsListJSONPassesDaemonBytesVerbatim() throws {
    let payload = [WindowInfoPayload(index: 1, isKey: true, tabCount: 2, selectedTabShortId: "s1")]
    let data = try encoded(payload)
    let fake = FakeTransport(response: data)
    let outcome = try handleWindowsList(all: false, transport: fake, output: .json)
    // JSON mode echoes the daemon's payload bytes verbatim + a newline.
    var expected = data
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
    #expect(fake.sent.first?.method == RPCMethod.windowsList.rawValue)
}

// MARK: - workspace verbs

@Test
func workspaceMutationHumanEcho() throws {
    let fake = FakeTransport(response: Data("{}".utf8))
    let outcome = try sendWorkspaceMutation(
        transport: fake,
        output: .human,
        build: { try CLICommands.tabSelectRequest(tab: Wire.TabRef(type: "current", value: nil)) },
        humanEcho: { "ok tab=current" },
        jsonReceipt: { Receipt.TabSelect(tab: "current") }
    )
    #expect(outcome == .stdout("ok tab=current\n"))
    #expect(fake.sent.first?.method == RPCMethod.tabSelect.rawValue)
}

@Test
func workspaceMutationJSONReceipt() throws {
    let fake = FakeTransport(response: Data("{}".utf8))
    let outcome = try sendWorkspaceMutation(
        transport: fake,
        output: .json,
        build: { try CLICommands.tabSelectRequest(tab: Wire.TabRef(type: "current", value: nil)) },
        humanEcho: { "ok tab=current" },
        jsonReceipt: { Receipt.TabSelect(tab: "current") }
    )
    #expect(outcome.stdout == (try encodeJSONReceipt(Receipt.TabSelect(tab: "current"))))
}

@Test
func tabMoveMutationSendsMoveMethodAndEcho() throws {
    let fake = FakeTransport(response: Data("{}".utf8))
    let outcome = try sendWorkspaceMutation(
        transport: fake,
        output: .human,
        build: {
            try CLICommands.tabMoveRequest(
                tab: Wire.TabRef(type: "current", value: nil),
                toIndex: 1,
                toWindow: Wire.WindowRef(type: "index", value: "2")
            )
        },
        humanEcho: { "ok tab=current window=2 to=1" },
        jsonReceipt: { Receipt.TabMove(tab: "current", toIndex: 1, toWindow: "2") }
    )
    #expect(outcome == .stdout("ok tab=current window=2 to=1\n"))
    #expect(fake.sent.first?.method == RPCMethod.tabMove.rawValue)
}

@Test
func workspaceInfoJSONPassesPayloadVerbatim() throws {
    let payload = Data(#"{"sessionId":"S1"}"#.utf8)
    let fake = FakeTransport(response: payload)
    let outcome = try sendWorkspaceInfo(
        transport: fake,
        output: .json,
        build: { try CLICommands.tabInfoRequest(tab: Wire.TabRef(type: "current", value: nil)) },
        humanRender: { (payload: TabInfoPayload) in formatTabInfo(payload) }
    )
    var expected = payload
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
}

@Test
func deviceAttachSuccessEcho() throws {
    let roster = [DeviceRosterEntry(id: "U1", kind: .sim, name: "iPhone", state: "Booted")]
    let fake = FakeTransport(responses: [try encoded(roster), Data("{}".utf8)])
    let outcome = try handleDeviceAttach(
        ref: "U1",
        transport: fake,
        output: .human,
        creds: testCreds
    )
    #expect(outcome == .stdout("ok target=U1 kind=sim\n"))
    #expect(fake.sent.map(\.method) == [RPCMethod.devicesList.rawValue, RPCMethod.paneAttach.rawValue])
}

@Test
func deviceAttachUnknownRefIsFailure() throws {
    let fake = FakeTransport(response: try encoded([DeviceRosterEntry]()))
    let outcome = try handleDeviceAttach(
        ref: "nope",
        transport: fake,
        output: .human,
        creds: testCreds
    )
    #expect(outcome.exitCode == 1)
    #expect(outcome.stderr == "no device matching 'nope'\n"
        + "  run `deviceterm devices list` to see available devices")
    // Only the roster fetch happened, with no attach publish.
    #expect(fake.sent.map(\.method) == [RPCMethod.devicesList.rawValue])
}

@Test
func tabCaptureHumanAppendsNewlineWhenMissing() throws {
    let payload = TabCapturePayload(text: "line one\nline two")
    let fake = FakeTransport(response: try encoded(payload))
    let outcome = try handleTabCapture(
        tabRef: Wire.TabRef(type: "current", value: nil),
        transport: fake,
        output: .human
    )
    #expect(outcome == .stdout("line one\nline two\n"))
}

@Test
func tabCaptureHumanKeepsExistingTrailingNewline() throws {
    let payload = TabCapturePayload(text: "already\n")
    let fake = FakeTransport(response: try encoded(payload))
    let outcome = try handleTabCapture(
        tabRef: Wire.TabRef(type: "current", value: nil),
        transport: fake,
        output: .human
    )
    #expect(outcome == .stdout("already\n"))
}

// MARK: - driver intercept + error mapping

@Test
func runRoutesAgentsToStdout() {
    // A pure doc-dump verb: no I/O, no creds, and `run` returns the guide.
    let outcome = run(.agents, transport: FakeTransport(), output: .human)
    #expect(outcome == .stdout(AgentsText.documentation))
}

@Test
func runMapsDaemonError() {
    let fake = FakeTransport(error: .daemon(code: -32_000, message: "boom"))
    let outcome = run(.tabsList, transport: fake, output: .human)
    #expect(outcome.exitCode == 1)
    // The underscore is only in the Swift literal; the interpolated Int
    // renders without it.
    #expect(outcome.stderr == "daemon error -32000: boom")
    #expect(outcome.stdout.isEmpty)
}

@Test
func runMapsTransportError() {
    let fake = FakeTransport(error: .transport("cannot connect"))
    let outcome = run(.tabsList, transport: fake, output: .human)
    #expect(outcome.exitCode == 1)
    // `.transport` surfaces its message verbatim, matching the wording
    // the docs, help topics, and man page quote for resolution errors.
    #expect(outcome.stderr == "cannot connect")
}

// MARK: - pane-targeted input (tap / swipe / ax)

@Test
func resolvePaneReturnsSolePaneWhenNoRef() throws {
    let fake = FakeTransport(response: try onePaneResponse())
    let resolved = try resolvePane(ref: nil, transport: fake, creds: testCreds)
    #expect(resolved == ResolvedPane(paneId: "p1", udid: "U1", shortId: "sh1"))
    #expect(fake.sent.first?.method == RPCMethod.panesList.rawValue)
}

@Test
func resolvePaneUnknownRefThrows() throws {
    let fake = FakeTransport(response: try onePaneResponse())
    #expect(throws: CLIError.self) {
        _ = try resolvePane(ref: "nope", transport: fake, creds: testCreds)
    }
}

@Test
func tapJSONReceiptAndEnvelope() throws {
    let fake = FakeTransport(response: try onePaneResponse())
    let outcome = try sendResolved(
        ref: nil,
        output: .json,
        transport: fake,
        creds: testCreds,
        humanFields: { _ in [("x", "1.0"), ("y", "2.0")] },
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
    let expected = Receipt.Tap(udid: "U1", paneId: "p1", shortId: "sh1", x: 1, y: 2)
    #expect(outcome.stdout == (try encodeJSONReceipt(expected)))
    // Two round-trips: resolve (panes.list) then the tap itself.
    #expect(fake.sent.map(\.method) == [RPCMethod.panesList.rawValue, RPCMethod.paneInputTap.rawValue])
}

@Test
func tapHumanEchoLine() throws {
    let fake = FakeTransport(response: try onePaneResponse())
    let outcome = try sendResolved(
        ref: nil,
        output: .human,
        transport: fake,
        creds: testCreds,
        humanFields: { _ in [("x", "1.0"), ("y", "2.0")] },
        jsonReceipt: { _ in Receipt.Tap(udid: "U1", paneId: "p1", shortId: "sh1", x: 1, y: 2) },
        build: { try CLICommands.tapRequest(paneId: $0, x: 1, y: 2) }
    )
    let resolved = ResolvedPane(paneId: "p1", udid: "U1", shortId: "sh1")
    #expect(outcome == .stdout(
        Echo.ok(udid: "U1", pane: resolved.displayLabel, fields: [("x", "1.0"), ("y", "2.0")]) + "\n"
    ))
}

@Test
func swipeDecodesAckAndTargetsPane() throws {
    let ack = SwipeAck(steps: 3, durationMs: 200)
    let fake = FakeTransport(responses: [try onePaneResponse(), try JSONEncoder().encode(ack)])
    let outcome = try handleSwipe(
        pane: nil,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 200,
        holdMs: nil,
        transport: fake,
        output: .json,
        creds: testCreds
    )
    let expected = Receipt.Swipe(
        udid: "U1",
        paneId: "p1",
        shortId: "sh1",
        dispatched: ack.dispatched?.rawValue,
        steps: ack.steps,
        durationMs: ack.durationMs
    )
    #expect(outcome.stdout == (try encodeJSONReceipt(expected)))
    #expect(fake.sent.map(\.method) == [RPCMethod.panesList.rawValue, RPCMethod.paneInputSwipe.rawValue])
}

@Test
func axTreeReturnsDaemonPayloadVerbatim() throws {
    let axPayload = Data(#"{"role":"window","children":[]}"#.utf8)
    let fake = FakeTransport(responses: [try onePaneResponse(), axPayload])
    let outcome = try sendResolvedPrintingResult(ref: nil, transport: fake, creds: testCreds) {
        try CLICommands.axTreeRequest(paneId: $0)
    }
    var expected = axPayload
    expected.append(0x0A)
    #expect(outcome.stdout == expected)
    #expect(fake.sent.map(\.method) == [RPCMethod.panesList.rawValue, RPCMethod.paneAXTree.rawValue])
}

@Test
func errorOutcomeMappings() {
    #expect(errorOutcome(CLIError.daemon(code: 7, message: "x"))
        == CommandOutcome(stderr: "daemon error 7: x", exitCode: 1))
    #expect(errorOutcome(CLIError.notInTab("no tab"))
        == CommandOutcome(stderr: "no tab", exitCode: 1))
    #expect(errorOutcome(CLIError.transport("t")).exitCode == 1)
}

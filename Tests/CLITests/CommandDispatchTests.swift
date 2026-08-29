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
    /// The response timeout each send was given, positionally aligned with
    /// `sent`, so a test can assert the budget a verb chose.
    private(set) var timeouts: [Double] = []

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
        timeouts.append(timeoutSeconds)
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
func axCallGetsItsOwnBudgetWhilePaneResolutionKeepsTheDefault() throws {
    let fake = FakeTransport(responses: [try onePaneResponse(), Data(#"{}"#.utf8)])
    _ = try sendResolvedPrintingResult(
        ref: nil,
        transport: fake,
        creds: testCreds,
        timeoutSeconds: AXTimeout.response
    ) {
        try CLICommands.axTreeRequest(paneId: $0)
    }
    // Resolution is a cheap `panes.list`, so it keeps the short wait and a
    // wedged resolve still fails fast; only the AX envelope waits longer.
    #expect(fake.timeouts == [AppCommandDeadline.cliRequestTimeoutSeconds, AXTimeout.response])
}

@Test
func theAXWaitCoversTheLongestSweepAnyoneCanBuy() {
    // Every `ax` verb queues on the pane's one accessibility queue, so any of
    // them can wait out another caller's sweep before its own work starts.
    // Each wait therefore has to exceed `AXSweepBudget.maxMs`: anything sized
    // to the default budget fails on a request the daemon goes on to answer
    // whenever someone else holds the queue with a ceiling-budget sweep.
    let ceilingSeconds = Double(AXSweepBudget.maxMs) / 1_000.0
    #expect(AXTimeout.response > ceilingSeconds)
    #expect(AXTimeout.response > AppCommandDeadline.cliRequestTimeoutSeconds)
    // Headroom, not a second budget: covering the ceiling twice would mean a
    // wedged bridge call hangs the caller for two minutes.
    #expect(AXTimeout.response < ceilingSeconds * 2)
}

@Test
func aSweepsOwnBudgetDoesNotAddToTheWaitItNeeds() {
    // The daemon takes a sweep's deadline when the request arrives, not when
    // it reaches the queue, so time spent queued is spent out of the budget
    // rather than deferring it. Worst case is max(queue wait, own budget) and
    // the same ceiling caps both, which is why one constant serves all three
    // verbs and `--budget` needs no client-side arithmetic.
    let ceilingSeconds = Double(AXSweepBudget.maxMs) / 1_000.0
    #expect(AXTimeout.response > ceilingSeconds)
    #expect(AXTimeout.response > Double(AXSweepBudget.defaultMs) / 1_000.0)
}

@Test
func errorOutcomeMappings() {
    let daemon = errorOutcome(CLIError.daemon(code: 7, message: "x"))
    #expect(daemon.stderr == "daemon error 7: x")
    #expect(daemon.failure?.code == .rpcError)

    let notInTab = errorOutcome(CLIError.notInTab("no tab"))
    #expect(notInTab.stderr == "no tab")
    #expect(notInTab.failure?.code == .sessionRequired)

    let transport = errorOutcome(CLIError.transport("t"))
    #expect(transport.exitCode == 1)
    #expect(transport.failure?.code == .transportInterrupted)
}

// MARK: - response budgets for caller-paced verbs

/// Verbs the daemon answers only once work the caller sized has finished: the
/// paced gestures, and the sweep whose walk runs under a budget the caller can
/// buy. Each can exceed the default five-second client wait, which is why each
/// one overrides it.
///
/// These drive `run` rather than reconstructing the `sendResolved` call the way
/// the tap tests above do, because what needs pinning is the dispatch site's own
/// choice of budget. A reconstructed call would pass even if the verb omitted
/// `timeoutSeconds:` entirely.
///
/// Serialized because `run` reads the session credentials from the process
/// environment and there is no seam for injecting them, so concurrent cases
/// would race over a process-wide value. Each call restores what it found.
@Suite(.serialized)
struct ResponseBudgetTests {
    private func withTabEnv<T>(_ body: () throws -> T) rethrows -> T {
        let priorSession = ProcessInfo.processInfo.environment[DeviceTermEnv.session]
        let priorCap = ProcessInfo.processInfo.environment[DeviceTermEnv.sessionCap]
        defer {
            if let priorSession {
                setenv(DeviceTermEnv.session, priorSession, 1)
            } else {
                unsetenv(DeviceTermEnv.session)
            }
            if let priorCap {
                setenv(DeviceTermEnv.sessionCap, priorCap, 1)
            } else {
                unsetenv(DeviceTermEnv.sessionCap)
            }
        }
        setenv(DeviceTermEnv.session, testCreds.sessionId, 1)
        setenv(DeviceTermEnv.sessionCap, testCreds.cap, 1)
        return try body()
    }

    /// The budget the action envelope was sent with. Index 1 because index 0 is
    /// the `panes.list` resolution, which deliberately keeps the short wait.
    private func actionBudget(for command: CLICommand) throws -> Double {
        let fake = FakeTransport(responses: [try onePaneResponse(), Data(#"{}"#.utf8)])
        let outcome = withTabEnv { run(command, transport: fake, output: .json) }
        #expect(outcome.exitCode == 0)
        #expect(fake.timeouts.count == 2)
        #expect(fake.timeouts.first == AppCommandDeadline.cliRequestTimeoutSeconds)
        return fake.timeouts[1]
    }

    private func pinch(durationMs: Int?) -> CLICommand {
        .pinch(
            pane: nil,
            fromF1X: 0.4,
            fromF1Y: 0.4,
            fromF2X: 0.6,
            fromF2Y: 0.6,
            toF1X: 0.3,
            toF1Y: 0.3,
            toF2X: 0.7,
            toF2Y: 0.7,
            durationMs: durationMs
        )
    }

    @Test
    func longPressWaitsOutTheHoldItAskedFor() throws {
        let budget = try actionBudget(
            for: .longPress(pane: nil, x: 0.5, y: 0.5, durationMs: 5_000)
        )
        #expect(budget == gestureTimeout(5_000))
        // A five-second hold has to keep headroom beyond the ordinary
        // five-second request timeout, or it expires on a press it dispatched.
        #expect(budget > AppCommandDeadline.cliRequestTimeoutSeconds + 5)
    }

    @Test
    func pinchWaitsOutTheDurationItAskedFor() throws {
        #expect(try actionBudget(for: pinch(durationMs: 8_000)) == gestureTimeout(8_000))
    }

    @Test
    func crownWaitsOutASubSteppedRotation() throws {
        let budget = try actionBudget(
            for: .crown(pane: nil, delta: 100, velocity: nil, durationMs: 6_000)
        )
        #expect(budget == gestureTimeout(6_000))
    }

    /// An omitted `--duration` must resolve the daemon's own default, not the
    /// bare floor: the daemon still holds a long-press for half a second, and a
    /// client that assumed zero would be cutting its own margin.
    @Test(arguments: [
        (
            CLICommand.longPress(pane: nil, x: 0.5, y: 0.5, durationMs: nil),
            GestureDuration.longPressDefaultMs
        ),
        (
            CLICommand.crown(pane: nil, delta: 10, velocity: nil, durationMs: nil),
            GestureDuration.crownDefaultMs
        )
    ])
    func anOmittedDurationTakesTheSharedDefault(command: CLICommand, expected: Int) throws {
        #expect(try actionBudget(for: command) == gestureTimeout(expected))
    }

    /// argv takes any `Int` and the daemon refuses anything past
    /// `GestureDuration.maxMs`, so a duration that will be rejected must not
    /// buy the client an unbounded wait on a peer that never answers.
    @Test
    func anOutOfRangeDurationCannotStretchTheDeadline() throws {
        let absurd = GestureDuration.maxMs * 10_000
        let ceiling = gestureTimeout(GestureDuration.maxMs)
        #expect(gestureTimeout(absurd) == ceiling)
        #expect(try actionBudget(
            for: .longPress(pane: nil, x: 0.5, y: 0.5, durationMs: absurd)
        ) == ceiling)
        // A minute of gesture plus its headroom is the most a single-phase
        // verb can claim.
        #expect(ceiling < 75)
    }

    /// `swipe` runs a motion and then a dwell, and the daemon validates the two
    /// independently, so both are legal at the ceiling and the gesture can
    /// legitimately outlast it. Bounding their sum instead would expire the
    /// deadline halfway through a swipe the daemon accepted.
    @Test
    func aSwipeDeadlineCoversItsDwellAsWellAsItsMotion() {
        let ceiling = GestureDuration.maxMs
        #expect(gestureTimeout(ceiling, ceiling) > gestureTimeout(ceiling))
        #expect(gestureTimeout(ceiling, ceiling) == gestureTimeout(ceiling) + 60)
        // Each phase is still bounded on its own, so an out-of-range pair
        // cannot reach past two legal ones.
        #expect(gestureTimeout(ceiling * 99, ceiling * 99) == gestureTimeout(ceiling, ceiling))
    }

    /// Pins every single-phase duration-bearing verb to a budget longer than
    /// the duration it asked for, so none can fall back to the floor on its
    /// own. `swipe`'s two-phase budget is covered above.
    @Test
    func everyDurationBearingVerbOutlastsItsOwnGesture() throws {
        let durationMs = 9_000
        let commands: [CLICommand] = [
            .longPress(pane: nil, x: 0.5, y: 0.5, durationMs: durationMs),
            pinch(durationMs: durationMs),
            .crown(pane: nil, delta: 100, velocity: nil, durationMs: durationMs)
        ]
        for command in commands {
            #expect(try actionBudget(for: command) > Double(durationMs) / 1_000)
        }
    }

    /// `ax sweep` takes `AXTimeout.response` whatever budget it asked for,
    /// including none: the daemon answers only once the walk has stopped, and
    /// the sweep can itself queue behind a ceiling-budget one. The budget does
    /// not size the wait, but the wait must not fall back to the floor.
    @Test(arguments: [30_000, nil])
    func aSweepWaitsOutTheLongestWalkTheDaemonAllows(budgetMs: Int?) throws {
        let budget = try actionBudget(
            for: .axSweep(pane: nil, step: 0.02, budgetMs: budgetMs)
        )
        #expect(budget == AXTimeout.response)
        #expect(budget > Double(AXSweepBudget.maxMs) / 1_000)
    }
}

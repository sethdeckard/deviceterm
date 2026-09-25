// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

@testable import DeviceTermCLI

private final class WaitScriptTransport: CLITransport {
    let observation = WaitSurfaceObservation()
    private(set) var observationCount = 0
    var responses: [Result<Data, CLIError>]
    private(set) var sent: [RPCEnvelope] = []
    private(set) var timeouts: [Double] = []
    var onSend: (() -> Void)?
    var beforeBuildingEnvelope: (() -> Void)?

    init(_ responses: [Result<Data, CLIError>]) {
        self.responses = responses
    }

    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data {
        sent.append(envelope)
        timeouts.append(timeoutSeconds)
        onSend?()
        guard !responses.isEmpty else {
            throw CLIError.invalidResponse("wait test exhausted its scripted responses")
        }
        let data = try responses.removeFirst().get()
        if envelope.method == RPCMethod.paneDeviceList.rawValue {
            observation.sequence = try JSONDecoder().decode([PanesListEntry].self, from: data).first?.surface?.sequence
        }
        return data
    }

    func observeSurface(
        paneId: String, credentials: (sessionId: String, cap: String), timeoutSeconds: Double
    ) -> any CLISurfaceObservation {
        observationCount += 1
        #expect(credentials.sessionId == waitCreds.sessionId)
        #expect(timeoutSeconds > 0)
        return observation
    }

    func send(
        timeoutSeconds: Double,
        buildingEnvelope: () throws -> RPCEnvelope
    ) throws -> Data {
        beforeBuildingEnvelope?()
        return try send(try buildingEnvelope(), timeoutSeconds: timeoutSeconds)
    }
}

private final class WaitSurfaceObservation: CLISurfaceObservation {
    var sequence: UInt64?
    var closed = false
    var failure: CLIError?

    func latestSequence() throws -> UInt64? {
        if let failure { throw failure }
        return sequence
    }

    func close() { closed = true }
}

private final class WaitTestClock: @unchecked Sendable {
    var now: UInt64 = 0
    private(set) var sleeps: [UInt64] = []

    var runtime: WaitEngine.Runtime {
        WaitEngine.Runtime(
            nowNanoseconds: { [self] in now },
            sleepNanoseconds: { [self] duration in
                sleeps.append(duration)
                now += duration
            }
        )
    }
}

private let waitCreds = (sessionId: "SESSION", cap: "CAP")

private func waitData(_ panes: [PanesListEntry]) throws -> Data {
    try JSONEncoder().encode(panes)
}

private func waitPane(
    state: PaneLifecycle = .rendering,
    orientation: Orientation? = nil,
    surface: PanesListEntry.Surface? = nil,
    paneId: String = "PANE",
    family: String? = "phone",
    capabilities: PaneCapabilities? = nil,
    orientationConfirmationSupported: Bool? = nil
) -> PanesListEntry {
    PanesListEntry(
        paneId: paneId,
        udid: "DEVICE",
        state: state,
        family: family,
        shortId: "abc123",
        capabilities: capabilities,
        orientationConfirmationSupported: orientationConfirmationSupported,
        orientation: orientation,
        surface: surface
    )
}

private func waitOutputObject(_ outcome: CommandOutcome) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any])
}

private func axQuery(
    identifier: String? = nil,
    label: String? = nil,
    role: String? = nil,
    value: String? = nil,
    matchMode: CLICommand.WaitAXMatchMode = .exact
) -> CLICommand.WaitAXQuery {
    CLICommand.WaitAXQuery(
        identifier: identifier,
        label: label,
        role: role,
        value: value,
        matchMode: matchMode,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
}

private func axSweepQuery(
    label: String,
    step: Double? = 0.2,
    budgetMs: Int? = 500
) -> CLICommand.WaitAXQuery {
    CLICommand.WaitAXQuery(
        identifier: nil,
        label: label,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: step,
        budgetMs: budgetMs
    )
}

/// Run one `wait ax` against a fixed tree. The clock only advances when the
/// engine sleeps, so a 1 ms timeout buys exactly one probe and a miss becomes
/// `wait.timeout` without wall-clock cost.
private func axWaitOutcome(
    tree: String,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int = 1_000
) throws -> CommandOutcome {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(tree.utf8))
    ])
    return try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: timeoutMs,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )
}

private func waitFailureDetails(_ outcome: CommandOutcome) throws -> [String: Any] {
    let data = try #require(outcome.failure?.details)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func axMatches(
    _ outcome: CommandOutcome
) throws -> (matches: [[String: Any]], count: Int) {
    let receipt = try waitOutputObject(outcome)
    let observation = try #require(receipt["observation"] as? [String: Any])
    return (
        try #require(observation["matches"] as? [[String: Any]]),
        try #require(observation["matchCount"] as? Int)
    )
}

/// One element serialized as the JSON `ax tree` would carry.
private func jsonText(_ element: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: element, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

/// An `Application` root containing the supplied element JSON, as `ax tree`
/// frames it.
private func axTree(_ elements: String) -> String {
    #"{"tree":{"role":"Application","children":[\#(elements)]}}"#
}

/// A sweep root that stopped before covering its grid, containing the supplied
/// element JSON.
private func truncatedSweep(_ elements: String) -> String {
    #"{"tree":{"role":"AXSweepRoot","truncated":true,"sweepedPoints":137,"#
        + #""step":0.05,"budgetMs":10000,"children":[\#(elements)]}}"#
}

@Test
func paneWaitProbesImmediatelyAndSucceeds() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane()]))])
    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    let object = try waitOutputObject(outcome)
    #expect(object["ok"] as? Bool == true)
    #expect(object["attempts"] as? Int == 1)
    #expect(object["elapsedMs"] as? Int == 0)
    #expect(clock.sleeps.isEmpty)
    #expect(transport.timeouts == [1.0])
}

@Test
func paneWaitUsesOneHundredMillisecondNonoverlappingProbes() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(state: .booting)])),
        .success(try waitData([waitPane()]))
    ])
    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    let object = try waitOutputObject(outcome)
    #expect(object["attempts"] as? Int == 2)
    #expect(object["elapsedMs"] as? Int == 100)
    #expect(clock.sleeps == [100_000_000])
    #expect(transport.timeouts == [1.0, 0.9])
}

@Test
func paneWaitCapsEachProbeAtTheNormalRPCDeadline() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane()]))])

    _ = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 30_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(transport.timeouts == [AppCommandDeadline.cliRequestTimeoutSeconds])
}

@Test
func transportTimeoutAtTheOverallDeadlineBecomesWaitTimeout() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .failure(.transportTimeout("timed out waiting for daemon response"))
    ])
    transport.onSend = { clock.now += 100_000_000 }

    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 100,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(transport.timeouts == [0.1])
}

@Test
func individualRPCDeadlineBeforeTheOverallDeadlineStaysTransportTimeout() {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .failure(.transportTimeout("timed out waiting for daemon response"))
    ])
    transport.onSend = {
        clock.now += UInt64(AppCommandDeadline.cliRequestTimeoutSeconds * 1_000_000_000)
    }

    do {
        _ = try handleWaitPane(
            pane: nil,
            state: .rendering,
            timeoutMs: 30_000,
            transport: transport,
            output: .json,
            creds: waitCreds,
            runtime: clock.runtime
        )
        Issue.record("individual RPC timeout unexpectedly became a wait result")
    } catch {
        #expect(errorOutcome(error).failure?.code == .transportTimeout)
    }
    #expect(transport.timeouts == [AppCommandDeadline.cliRequestTimeoutSeconds])
}

@Test
func waitDeadlineIsTypedAndUsesExitOneHundredTwentyFour() throws {
    let clock = WaitTestClock()
    let pending = try waitData([waitPane(state: .booting)])
    let transport = WaitScriptTransport([.success(pending), .success(pending), .success(pending)])
    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 250,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(outcome.stdout.isEmpty)
    let rendered = outcome.renderingFailure(
        for: .waitPane(pane: nil, state: .rendering, timeoutMs: 250),
        output: .json
    )
    let object = try waitOutputObject(rendered)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == "wait.timeout")
    #expect(clock.sleeps == [100_000_000, 100_000_000, 50_000_000])
}

@Test
func explicitPaneMayAppearAfterTheWaitStarts() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([])),
        .success(try waitData([waitPane()]))
    ])
    let outcome = try handleWaitPane(
        pane: "DEVICE",
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .human,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    let text = try #require(String(data: outcome.stdout, encoding: .utf8))
    #expect(text.contains("attempts=2"))
}

@Test
func paneAmbiguityFailsWithoutRetrying() throws {
    let clock = WaitTestClock()
    let panes = [waitPane(paneId: "ONE"), waitPane(paneId: "TWO")]
    let transport = WaitScriptTransport([.success(try waitData(panes))])

    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .paneAmbiguous)
    #expect(outcome.exitCode == 1)
    // Routed through the wait envelope rather than thrown, so it carries the
    // condition every other wait failure reports.
    #expect(try waitFailureDetails(outcome)["condition"] as? String == "pane.rendering")
    #expect(transport.sent.count == 1)
    #expect(clock.sleeps.isEmpty)
}

@Test
func aResolvedPaneDisappearingIsAQueryFailure() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(state: .booting)])),
        .success(try waitData([]))
    ])

    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .paneNotFound)
    #expect(outcome.failure?.message == "the pane disappeared while waiting")
    #expect(transport.sent.count == 2)
}

@Test
func aProbeThatObservedTheConditionLateStillReportsIt() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane()]))])
    // The request is bounded by the time left, so the daemon may answer at the
    // deadline and the walk over its response runs afterwards. Advancing the
    // clock inside the send reproduces a probe that saw the condition hold and
    // returned past the deadline.
    transport.onSend = { clock.now += 2_000_000_000 }

    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.failure == nil)
    let object = try waitOutputObject(outcome)
    #expect(object["ok"] as? Bool == true)
    // Honest rather than clamped: the observation really did take longer than
    // the deadline allowed.
    #expect(object["elapsedMs"] as? Int == 2_000)
    #expect(transport.sent.count == 1)
}

@Test
func aRefThatNeverResolvesReportsTheMissingPaneNotTheDeadline() throws {
    let clock = WaitTestClock()
    let roster = try waitData([waitPane()])
    let transport = WaitScriptTransport([
        .success(roster),
        .success(roster),
        .success(roster)
    ])

    let outcome = try handleWaitPane(
        pane: "nosuchpane",
        state: .rendering,
        timeoutMs: 250,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // The condition was never the problem: no pane ever answered to the ref,
    // so reporting the deadline would send the reader to inspect pane state
    // that was never observed.
    #expect(outcome.failure?.code == .paneNotFound)
    #expect(outcome.exitCode == 1)
    let message = try #require(outcome.failure?.message)
    #expect(message.contains("'nosuchpane'"))
    #expect(message.contains("after 3 attempts"))
    let details = try waitFailureDetails(outcome)
    #expect(details["condition"] as? String == "pane.rendering")
    #expect(details["attempts"] as? Int == 3)
}

@Test
func aRosterRequestExhaustingTheDeadlineStaysWaitTimeout() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .failure(.transportTimeout("timed out waiting for daemon response"))
    ])
    transport.onSend = { clock.now += 100_000_000 }

    let outcome = try handleWaitPane(
        pane: "nosuchpane",
        state: .rendering,
        timeoutMs: 250,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // The first probe read a roster naming no match, but the second never read
    // one at all. A pane may have appeared in the roster that went unobserved,
    // so reporting `pane.notFound` here would assert a state nothing saw, and
    // would hide the transport failure that actually ended the wait.
    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(transport.sent.count == 2)
}

@Test
func anUnmatchedExportedTargetIsNamedRatherThanCalledAnEmptyTab() {
    // The tab holds panes; the exported key names none of them. Reporting an
    // empty tab would send the reader looking for a missing tab instead of a
    // stale exported key.
    let message = unresolvedPaneMessage(
        ref: nil,
        exportedTarget: "GONE-KEY",
        attempts: 3
    )

    #expect(message == "no pane for exported target GONE-KEY in this tab after 3 attempts")
}

@Test
func anExplicitRefOutranksAnExportedTargetInTheDiagnostic() {
    let message = unresolvedPaneMessage(
        ref: "nosuchpane",
        exportedTarget: "GONE-KEY",
        attempts: 3
    )

    #expect(message.contains("'nosuchpane'"))
    #expect(!message.contains("GONE-KEY"))
}

@Test
func noRefAndNoExportedTargetReportsAnEmptyTab() {
    #expect(
        unresolvedPaneMessage(ref: nil, exportedTarget: nil, attempts: 3)
            == "no device pane in this tab after 3 attempts"
    )
    // An exported key set to empty is the same as unset, matching how
    // resolution itself treats it.
    #expect(
        unresolvedPaneMessage(ref: "", exportedTarget: "", attempts: nil)
            == "no device pane in this tab"
    )
}

@Test
func axWaitMatchesARecursiveElementOnALaterProbe() throws {
    let clock = WaitTestClock()
    let pending = Data(#"{"tree":{"role":"Application","children":[]}}"#.utf8)
    let matched = Data(
        #"{"tree":{"role":"Application","children":[{"role":"Button","identifier":"save"}]}}"#.utf8
    )
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])), .success(pending),
        .success(try waitData([waitPane()])), .success(matched)
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: "Button",
        value: nil,
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(transport.sent.map(\.method) == [
        RPCMethod.paneDeviceList.rawValue, RPCMethod.paneAXTree.rawValue,
        RPCMethod.paneDeviceList.rawValue, RPCMethod.paneAXTree.rawValue
    ])
}

@Test
func axWaitReportsEveryMatchAcrossSubtrees() throws {
    let clock = WaitTestClock()
    let tree = Data(
        #"""
        {
          "tree": {
            "role": "Application",
            "children": [
              {
                "role": "Group",
                "children": [{"identifier": "save", "label": "Nested"}]
              },
              {"identifier": "save", "label": "Sibling"}
            ]
          }
        }
        """#.utf8
    )
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])), .success(tree)
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )

    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // Neither match carries a frame, so both fall to the unsized tier and
    // keep depth-first discovery order relative to each other.
    let (matches, count) = try axMatches(outcome)
    #expect(count == 2)
    #expect(matches.map { $0["label"] as? String } == ["Nested", "Sibling"])
}

@Test("substring matching reaches a decorated label", arguments: [
    "Messages, 3 unread",
    "Messages…",
    "Unread Messages"
])
func containsReachesADecoratedLabel(label: String) throws {
    let tree = axTree(#"{"role":"Button","label":"\#(label)","frame":{"w":10,"h":10}}"#)

    let hit = try axWaitOutcome(tree: tree, query: axQuery(label: "Messages", matchMode: .contains))
    #expect(hit.exitCode == 0)
    let (matches, count) = try axMatches(hit)
    #expect(count == 1)
    #expect(matches.first?["label"] as? String == label)

    // The same needle under the default mode is the miss this flag exists for.
    let miss = try axWaitOutcome(tree: tree, query: axQuery(label: "Messages"), timeoutMs: 1)
    #expect(miss.failure?.code == .waitTimeout)
}

@Test("contains folds case in both directions", arguments: [
    ("messages", "Messages, 3 unread"),
    ("MESSAGES", "Messages, 3 unread"),
    ("Messages", "MESSAGES, 3 UNREAD"),
    // Caseless folding, not lowercasing: these two lowercase to "straße"
    // and "strasse" and would never compare equal.
    ("STRASSE", "Hauptstraße 4"),
    ("straße", "HAUPTSTRASSE 4")
])
func containsFoldsCase(needle: String, label: String) throws {
    let outcome = try axWaitOutcome(
        tree: axTree(#"{"role":"Button","label":"\#(label)","frame":{"w":10,"h":10}}"#),
        query: axQuery(label: needle, matchMode: .contains)
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test("exact admits neither a substring nor a case variant", arguments: [
    "Message",
    "messages",
    "MESSAGES"
])
func exactRejectsSubstringsAndCaseVariants(needle: String) throws {
    let outcome = try axWaitOutcome(
        tree: axTree(#"{"role":"Button","label":"Messages","frame":{"w":10,"h":10}}"#),
        query: axQuery(label: needle),
        timeoutMs: 1
    )

    #expect(outcome.failure?.code == .waitTimeout)
}

@Test("role stays exact and conjunctive under contains", arguments: [
    ("Butt", false),
    ("button", false),
    ("Button", true)
])
func roleStaysExactUnderContainsMatching(role: String, matches: Bool) throws {
    let outcome = try axWaitOutcome(
        tree: axTree(#"{"role":"Button","label":"Messages, 3 unread","frame":{"w":10,"h":10}}"#),
        query: axQuery(label: "Messages", role: role, matchMode: .contains),
        timeoutMs: matches ? 1_000 : 1
    )

    if matches {
        #expect(outcome.exitCode == 0)
    } else {
        #expect(outcome.failure?.code == .waitTimeout)
    }
}

@Test
func containsAppliesToTheIdentifierSelector() throws {
    let outcome = try axWaitOutcome(
        tree: axTree(#"{"role":"Button","identifier":"save-button-primary","frame":{"w":10,"h":10}}"#),
        query: axQuery(identifier: "save-button", matchMode: .contains)
    )

    #expect(outcome.exitCode == 0)
    let (matches, count) = try axMatches(outcome)
    #expect(count == 1)
    #expect(matches.first?["identifier"] as? String == "save-button-primary")
}

@Test(
    "a control outranks the caption inside it",
    arguments: [CLICommand.WaitAXMatchMode.exact, .contains]
)
func aControlOutranksItsOwnCaption(matchMode: CLICommand.WaitAXMatchMode) throws {
    // The caption nests inside its control and is therefore the smaller of
    // the two, so area alone would hand back the node that cannot be operated.
    let outcome = try axWaitOutcome(
        tree: axTree(
            #"""
            {"role":"Button","label":"Save","frame":{"w":80,"h":40},
             "children":[{"role":"StaticText","label":"Save","frame":{"w":40,"h":20}}]}
            """#
        ),
        query: axQuery(label: "Save", matchMode: matchMode)
    )

    let (matches, count) = try axMatches(outcome)
    #expect(count == 2)
    #expect(matches.map { $0["role"] as? String } == ["Button", "StaticText"])
}

@Test
func matchEntriesDropTheirChildren() throws {
    let outcome = try axWaitOutcome(
        tree: axTree(
            #"""
            {"role":"Button","label":"Save","frame":{"w":80,"h":40},
             "children":[{"role":"StaticText","label":"Save","frame":{"w":40,"h":20}}]}
            """#
        ),
        query: axQuery(label: "Save")
    )

    let (matches, _) = try axMatches(outcome)
    #expect(matches.allSatisfy { $0["children"] == nil })
    // Everything else the daemon annotated rides along, so a matched element
    // stays as useful as the one `ax tree` reports.
    #expect(matches.first?["frame"] is [String: Any])
}

@Test
func matchListIsCappedButTheCountIsNot() throws {
    let elements = (0..<25)
        .map { #"{"role":"Button","label":"Item \#($0)","frame":{"w":\#(10 + $0),"h":10}}"# }
        .joined(separator: ",")
    let outcome = try axWaitOutcome(
        tree: axTree(elements),
        query: axQuery(label: "Item", matchMode: .contains)
    )

    let (matches, count) = try axMatches(outcome)
    #expect(matches.count == WaitEngine.maxReportedMatches)
    #expect(count == 25)
    // Smallest first, so the cap drops the widest entries rather than a
    // random tail.
    #expect(matches.first?["label"] as? String == "Item 0")
    #expect(matches.last?["label"] as? String == "Item 19")
}

@Test
func aLoneMatchReportsACountOfOne() throws {
    let outcome = try axWaitOutcome(
        tree: axTree(#"{"role":"Button","label":"Save","frame":{"w":10,"h":10}}"#),
        query: axQuery(label: "Save")
    )

    let (matches, count) = try axMatches(outcome)
    #expect(matches.count == 1)
    #expect(count == 1)
}

@Test
func humanOutputReportsTheMatchCount() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(axTree(#"{"role":"Button","label":"Save","frame":{"w":10,"h":10}}"#).utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .human,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect((String(bytes: outcome.stdout, encoding: .utf8) ?? "").contains("matches=1"))
}

@Test
func paneWaitHumanOutputOmitsTheMatchCount() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane()]))])
    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: 1_000,
        transport: transport,
        output: .human,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(!(String(bytes: outcome.stdout, encoding: .utf8) ?? "").contains("matches="))
}

// MARK: - Match ranking

@Test
func rankingOrdersBySmallestFrameArea() {
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "large", "frame": ["w": 100, "h": 100]],
        ["label": "small", "frame": ["w": 10, "h": 10]],
        ["label": "medium", "frame": ["w": 50, "h": 50]]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["small", "medium", "large"])
}

@Test
func rankingKeepsDiscoveryOrderForEqualAreas() {
    let frame: [String: Any] = ["w": 10, "h": 10]
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "first", "frame": frame],
        ["label": "second", "frame": frame],
        ["label": "third", "frame": frame]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["first", "second", "third"])
}

@Test
func rankingRanksUnsizedMatchesLastWithoutDroppingThem() {
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "noFrame"],
        ["label": "zeroWidth", "frame": ["w": 0, "h": 40]],
        ["label": "sized", "frame": ["w": 30, "h": 30]],
        ["label": "negative", "frame": ["w": -5, "h": 40]]
    ])

    #expect(ordered.map { $0["label"] as? String }
        == ["sized", "noFrame", "zeroWidth", "negative"])
}

@Test("presentational roles rank last however small", arguments: ["StaticText", "Image"])
func rankingDemotesPresentationalRoles(role: String) {
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "caption", "role": role, "frame": ["w": 1, "h": 1]],
        ["label": "control", "role": "Button", "frame": ["w": 100, "h": 100]]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["control", "caption"])
}

@Test("an unrecognized role stays actionable", arguments: ["FutureControl", ""])
func rankingTreatsAnUnknownRoleAsActionable(role: String) {
    // Demoting on absence from a known-interactive list would bury a real
    // control every time Apple's best-effort vocabulary shifts.
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "caption", "role": "StaticText", "frame": ["w": 1, "h": 1]],
        ["label": "unknown", "role": role, "frame": ["w": 100, "h": 100]]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["unknown", "caption"])
}

@Test
func rankingPrefersAMatchCarryingACenter() {
    // The daemon omits normalizedCenter when a frame is positive but its
    // centre lands off-screen, so area alone cannot tell these apart.
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "offscreen", "role": "Button", "frame": ["w": 10, "h": 10]],
        [
            "label": "reachable",
            "role": "Button",
            "frame": ["w": 100, "h": 100],
            "normalizedCenter": ["x": 0.5, "y": 0.5]
        ]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["reachable", "offscreen"])
}

@Test
func rankingDemotesCaptionsAheadOfCheckingForACenter() {
    // A control at the screen edge loses its centre. It must still outrank
    // its own caption, or the caption/control defect returns wherever a
    // control sits off-screen.
    let ordered = WaitEngine.MatchRanking.ordered([
        [
            "label": "caption",
            "role": "StaticText",
            "frame": ["w": 10, "h": 10],
            "normalizedCenter": ["x": 0.5, "y": 0.5]
        ],
        ["label": "offscreenControl", "role": "Button", "frame": ["w": 100, "h": 100]]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["offscreenControl", "caption"])
}

@Test
func rankingReadsFractionalFrames() {
    let ordered = WaitEngine.MatchRanking.ordered([
        ["label": "big", "frame": ["w": 2.5, "h": 2.0]],
        ["label": "small", "frame": ["w": 1.5, "h": 1.0]]
    ])

    #expect(ordered.map { $0["label"] as? String } == ["small", "big"])
}

@Test
func truncatedAXSweepWithoutAMatchIsInconclusive() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(#"{"tree":{"role":"AXSweepRoot","truncated":true,"children":[]}}"#.utf8))
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: nil,
        label: "Save",
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.2,
        budgetMs: 500
    )
    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.exitCode == 1)
    #expect(transport.sent.map(\.method).last == RPCMethod.paneAXSweep.rawValue)
}

@Test("a truncated sweep reports the daemon's note", arguments: [
    AXTreeNote.sweepTruncated,
    AXTreeNote.sweepTruncatedAtMaxBudget
])
func truncatedAXSweepCarriesItsNoteAndCode(note: AXTreeNote) throws {
    let clock = WaitTestClock()
    let root = #"""
    {"tree":{"role":"AXSweepRoot","truncated":true,"children":[],
     "note":"\#(note.rawValue)","noteCode":"\#(note.code)"}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(root.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    // The two truncations differ only in prose under one error code, so the
    // token is the branchable difference.
    #expect(outcome.failure?.message == note.rawValue)
    let details = try waitFailureDetails(outcome)
    #expect(details["note"] as? String == note.rawValue)
    #expect(details["noteCode"] as? String == note.code)
}

@Test
func aTruncatedSweepWithNoNoteKeepsTheCLIsOwnProse() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(#"{"tree":{"role":"AXSweepRoot","truncated":true,"children":[]}}"#.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.failure?.message == "AX sweep ended before covering the full grid")
    let details = try waitFailureDetails(outcome)
    #expect(details["truncated"] as? Bool == true)
    #expect(details["note"] == nil)
    #expect(details["noteCode"] == nil)
}

@Test
func anUnrecognizedNoteIsRelayedRatherThanReplaced() throws {
    // A note this build has no case for is still the daemon's diagnostic, and
    // more use to a caller than the CLI's generic sentence. It is relayed
    // as-is, and no code is invented for it.
    let clock = WaitTestClock()
    let unknown = "a truncation this CLI has no case for"
    let root = #"""
    {"tree":{"role":"AXSweepRoot","truncated":true,"children":[],
     "note":"\#(unknown)","noteCode":"ax.someFutureNote"}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(root.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.failure?.message == unknown)
    let details = try waitFailureDetails(outcome)
    #expect(details["note"] as? String == unknown)
    #expect(details["noteCode"] as? String == "ax.someFutureNote")
}

@Test
func aMatchBeatsATruncatedSweep() throws {
    let clock = WaitTestClock()
    let root = #"""
    {"tree":{"role":"AXSweepRoot","truncated":true,
     "note":"\#(AXTreeNote.sweepTruncated.rawValue)",
     "children":[{"role":"Button","label":"Save","frame":{"w":10,"h":10}}]}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(root.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test("AX sweep budget is bounded by the wait", arguments: [nil, 60_000])
func axSweepBudgetIsBoundedByTheRemainingWait(requestedBudgetMs: Int?) throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(
            Data(
                #"{"tree":{"role":"AXSweepRoot","children":[{"identifier":"save"}]}}"#.utf8
            )
        )
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.2,
        budgetMs: requestedBudgetMs
    )

    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    let request = try #require(transport.sent.last)
    guard case let .params(data) = request.body else {
        Issue.record("expected AX sweep params")
        return
    }
    let params = try JSONDecoder().decode(AXSweepParams.self, from: data)
    #expect(params.budgetMs == 1_000)
}

@Test
func axSweepBudgetExcludesConnectionAuthenticationTime() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(
            Data(
                #"{"tree":{"role":"AXSweepRoot","children":[{"identifier":"save"}]}}"#.utf8
            )
        )
    ])
    transport.beforeBuildingEnvelope = { clock.now += 250_000_000 }
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.2,
        budgetMs: nil
    )

    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    let request = try #require(transport.sent.last)
    guard case let .params(data) = request.body else {
        Issue.record("expected AX sweep params")
        return
    }
    let params = try JSONDecoder().decode(AXSweepParams.self, from: data)
    #expect(params.budgetMs == 750)
}

@Test
func malformedAXResponseFailsInsteadOfTimingOut() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data("[]".utf8))
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )

    do {
        _ = try handleWaitAX(
            pane: nil,
            query: query,
            timeoutMs: 1_000,
            transport: transport,
            output: .json,
            creds: waitCreds,
            runtime: clock.runtime
        )
        Issue.record("malformed AX response unexpectedly became a miss")
    } catch {
        #expect(errorOutcome(error).failure?.code == .protocolInvalidResponse)
    }
    #expect(transport.sent.count == 2)
}

@Test
func watchTreeWaitIsUnsupportedWhenTheTreeSaysSo() throws {
    let clock = WaitTestClock()
    let note = AXTreeNote.watchOSEnumerationUnsupported
    let empty = #"{"tree":{"role":"Application","children":[],"note":"\#(note.rawValue)"}}"#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(family: "watch")])),
        .success(Data(empty.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(identifier: "save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitUnsupported)
    // The refusal depends on the AX response, so it requires one AX probe.
    #expect(transport.sent.map(\.method) == [
        RPCMethod.paneDeviceList.rawValue, RPCMethod.paneAXTree.rawValue
    ])
    let details = try waitFailureDetails(outcome)
    #expect(details["note"] as? String == note.rawValue)
    #expect(details["noteCode"] as? String == note.code)
}

@Test
func aRewordedWatchNoteIsStillRecognizedByItsCode() throws {
    // The reason the CLI reads `noteCode` first. A daemon that rephrases the
    // sentence keeps the same code, and matching prose alone would turn this
    // refusal into a wait that runs to its deadline.
    let clock = WaitTestClock()
    let code = AXTreeNote.watchOSEnumerationUnsupported.code
    let reworded = #"""
    {"tree":{"role":"Application","children":[],
     "note":"some future rewording of the watchOS limitation",
     "noteCode":"\#(code)"}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(family: "watch")])),
        .success(Data(reworded.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(identifier: "save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitUnsupported)
    let details = try waitFailureDetails(outcome)
    #expect(details["noteCode"] as? String == code)
    // The daemon's own wording surfaces, not this build's copy of it. A
    // newer sentence can carry remediation advice this CLI predates.
    #expect(details["note"] as? String == "some future rewording of the watchOS limitation")
    #expect(outcome.failure?.message == "some future rewording of the watchOS limitation")
}

@Test
func aRewordedTruncationNoteIsRelayedUnchanged() throws {
    // The daemon's reworded truncation sentence and code are relayed
    // unchanged. Both truncations answer with the same failure, so this
    // pins relay rather than selection.
    let clock = WaitTestClock()
    let note = AXTreeNote.sweepTruncatedAtMaxBudget
    let root = #"""
    {"tree":{"role":"AXSweepRoot","truncated":true,"children":[],
     "note":"some future rewording of the ceiling case",
     "noteCode":"\#(note.code)"}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(root.utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    let details = try waitFailureDetails(outcome)
    #expect(details["noteCode"] as? String == note.code)
    #expect(details["note"] as? String == "some future rewording of the ceiling case")
    #expect(outcome.failure?.message == "some future rewording of the ceiling case")
}

@Test
func aWatchPaneWithAPopulatedTreeStillMatches() throws {
    // A watch pane with enumerable children can satisfy the wait; only the
    // daemon's limitation note makes the observation unsupported.
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(family: "watch")])),
        .success(Data(axTree(#"{"role":"Button","identifier":"save","frame":{"w":10,"h":10}}"#).utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(identifier: "save"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test
func inaccessiblePaneWaitIsUnsupportedWithoutAnAXProbe() throws {
    let clock = WaitTestClock()
    var capabilities = PaneCapabilities.simulator
    capabilities.accessibility = false
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(capabilities: capabilities)]))
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.1,
        budgetMs: 500
    )
    let outcome = try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitUnsupported)
    #expect(transport.sent.map(\.method) == [RPCMethod.paneDeviceList.rawValue])
}

@Test
func orientationWaitRequiresTwoStablePositiveSurfaceReads() throws {
    let clock = WaitTestClock()
    let observed = waitPane(
        orientation: .landscapeLeft,
        surface: .init(sequence: 4, width: 800, height: 400),
        orientationConfirmationSupported: true
    )
    let transport = WaitScriptTransport([
        .success(try waitData([observed])),
        .success(try waitData([observed]))
    ])
    let outcome = try handleWaitOrientation(
        pane: nil,
        orientation: .landscapeLeft,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    let object = try waitOutputObject(outcome)
    #expect(object["attempts"] as? Int == 2)
    #expect(clock.sleeps == [100_000_000])
}

@Test
func explicitlyUnsupportedOrientationObservationFailsImmediately() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(orientationConfirmationSupported: false)]))
    ])
    let outcome = try handleWaitOrientation(
        pane: nil,
        orientation: .portrait,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitUnsupported)
    #expect(outcome.exitCode == 1)
}

@Test
func confirmedOrientationMayAppearAfterTheWaitStarts() throws {
    let clock = WaitTestClock()
    let pending = waitPane(orientationConfirmationSupported: true)
    let observed = waitPane(
        orientation: .landscapeRight,
        surface: .init(sequence: 8, width: 800, height: 400),
        orientationConfirmationSupported: true
    )
    let transport = WaitScriptTransport([
        .success(try waitData([pending])),
        .success(try waitData([observed])),
        .success(try waitData([observed]))
    ])
    let outcome = try handleWaitOrientation(
        pane: nil,
        orientation: .landscapeRight,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(transport.sent.count == 3)
}

@Test
func maximumIntegerTimeoutDoesNotOverflow() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane()]))])
    let outcome = try handleWaitPane(
        pane: nil,
        state: .rendering,
        timeoutMs: Int.max,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(transport.sent.count == 1)
}

@Test
func transportDeadlineNeverMasqueradesAsWaitDeadline() {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.failure(CLIError.transportTimeout("RPC expired"))])

    do {
        _ = try handleWaitPane(
            pane: nil,
            state: .rendering,
            timeoutMs: 1_000,
            transport: transport,
            output: .json,
            creds: waitCreds,
            runtime: clock.runtime
        )
        Issue.record("transport timeout unexpectedly became wait success")
    } catch {
        let failure = errorOutcome(error).failure
        #expect(failure?.code == .transportTimeout)
        #expect(failure?.code != .waitTimeout)
    }
    #expect(transport.sent.count == 1)
}

// MARK: - Value filtering

/// Two fields sharing a label, distinguished only by what they hold, plus a
/// third whose value is a number rather than a string.
private let valueTreeElements = """
    {"label":"Email","role":"TextField","value":"probe@example.com",
     "frame":{"x":0,"y":0,"w":10,"h":10}},
    {"label":"Email","role":"TextField","value":"someone@else.test",
     "frame":{"x":0,"y":20,"w":10,"h":10}},
    {"label":"Email","role":"StaticText","value":42,
     "frame":{"x":0,"y":40,"w":10,"h":10}}
    """

@Test
func valueNarrowsToTheFieldHoldingIt() throws {
    // Typing into a field puts the text in its `value`, not its label, so a
    // label-only query matches every field sharing that label.
    let outcome = try axWaitOutcome(
        tree: axTree(valueTreeElements),
        query: axQuery(label: "Email", value: "probe@example.com")
    )

    let (matches, count) = try axMatches(outcome)
    #expect(count == 1)
    #expect(matches[0]["value"] as? String == "probe@example.com")
}

@Test
func valueObeysTheSameMatchMode() throws {
    let outcome = try axWaitOutcome(
        tree: axTree(valueTreeElements),
        query: axQuery(label: "Email", value: "PROBE@", matchMode: .contains)
    )

    let (matches, count) = try axMatches(outcome)
    #expect(count == 1)
    #expect(matches[0]["value"] as? String == "probe@example.com")
}

@Test
func aNonStringValueNeverMatches() throws {
    // The third element's value is a number. The comparison is textual, so
    // it matches nothing rather than being coerced.
    let outcome = try axWaitOutcome(
        tree: axTree(valueTreeElements),
        query: axQuery(label: "Email", value: "42"),
        timeoutMs: 1
    )

    #expect(outcome.failure?.code == .waitTimeout)
}

// MARK: - Receipt completeness

@Test
func aTrimmedMatchListSaysSo() throws {
    let children = (0..<25).map {
        #"{"label": "Row", "frame": {"x": 0, "y": \#($0), "w": 10, "h": 10}}"#
    }
    let outcome = try axWaitOutcome(
        tree: axTree(children.joined(separator: ",")),
        query: axQuery(label: "Row")
    )

    let receipt = try waitOutputObject(outcome)
    let observation = try #require(receipt["observation"] as? [String: Any])
    #expect(observation["matchCount"] as? Int == 25)
    #expect((observation["matches"] as? [[String: Any]])?.count == 20)
    // Without this the caller has to know the cap out of band to notice.
    #expect(observation["matchesTruncated"] as? Bool == true)
}

@Test
func anUntrimmedMatchListOmitsTheFlag() throws {
    let outcome = try axWaitOutcome(
        tree: axTree(valueTreeElements),
        query: axQuery(label: "Email")
    )

    let receipt = try waitOutputObject(outcome)
    let observation = try #require(receipt["observation"] as? [String: Any])
    #expect(observation["matchCount"] as? Int == 3)
    #expect(observation["matchesTruncated"] == nil)
}

@Test
func aTruncatedSweepForwardsTheFieldsItsNoteNames() throws {
    let clock = WaitTestClock()
    let sweep = #"""
    {"tree":{"role":"AXSweepRoot","truncated":true,"children":[],
     "sweepedPoints":137,"step":0.05,"budgetMs":10000}}
    """#
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])), .success(Data(sweep.utf8))
    ])

    let outcome = try handleWaitAX(
        pane: nil,
        query: axSweepQuery(label: "Absent"),
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // The truncation note tells the reader to consult `sweepedPoints`, so
    // the failure has to carry it rather than name a field it drops.
    #expect(outcome.failure?.code == .waitInconclusive)
    let details = try waitFailureDetails(outcome)
    #expect(details["sweepedPoints"] as? Int == 137)
    #expect(details["step"] as? Double == 0.05)
    #expect(details["budgetMs"] as? Int == 10_000)
}

// MARK: - Selecting a coordinate target

private func element(
    role: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    centre: (Double, Double)?,
    label: String = "Go"
) -> [String: Any] {
    var element: [String: Any] = [
        "role": role,
        "label": label,
        "frame": ["x": x, "y": y, "w": width, "h": height]
    ]
    if let centre {
        element["normalizedCenter"] = ["x": centre.0, "y": centre.1]
    }
    return element
}

@Test
func selectionTakesTheInnermostOfANestedChain() {
    let outer = element(role: "Button", x: 0, y: 0, width: 100, height: 100, centre: (0.5, 0.5))
    let inner = element(role: "Button", x: 10, y: 10, width: 20, height: 20, centre: (0.2, 0.2))

    guard case let .target(target) = AXTarget.select(from: [outer, inner]) else {
        Issue.record("nested candidates should select")
        return
    }
    #expect(target.x == 0.2)
}

@Test
func selectionRefusesDisjointCandidates() {
    // Two unrelated controls matching one query. Nothing in the observation
    // says which was meant, so picking either would be a guess.
    let first = element(role: "Button", x: 0, y: 0, width: 20, height: 20, centre: (0.1, 0.1))
    let second = element(role: "Button", x: 50, y: 50, width: 20, height: 20, centre: (0.8, 0.8))

    guard case let .ambiguous(candidates) = AXTarget.select(from: [first, second]) else {
        Issue.record("disjoint candidates should refuse")
        return
    }
    #expect(candidates.count == 2)
}

@Test
func selectionRefusesWhenOnlyACaptionCarriesACentre() {
    // The ranking demotes a caption but still lists it. Selection is the
    // stricter question: a caption is not the control.
    let control = element(role: "Button", x: 0, y: 0, width: 100, height: 100, centre: nil)
    let caption = element(role: "StaticText", x: 10, y: 10, width: 20, height: 20, centre: (0.2, 0.2))

    #expect(AXTarget.select(from: [control, caption]) == .unreachable)
}

@Test
func selectionWorksOnAFlatSweepResult() {
    // `ax sweep` returns every element as a sibling, so a structural nesting
    // test would call this disjoint and refuse it. Containment does not.
    let card = element(role: "Button", x: 0, y: 0, width: 100, height: 100, centre: (0.5, 0.5))
    let field = element(role: "TextField", x: 5, y: 5, width: 10, height: 10, centre: (0.1, 0.1))

    guard case let .target(target) = AXTarget.select(from: [card, field]) else {
        Issue.record("a contained sweep sibling should select")
        return
    }
    #expect(target.role == "TextField")
}

@Test
func containmentToleratesRoundingAtTheEdge() {
    // Layout rounding can put a caption a fraction outside its control.
    let outer = element(role: "Button", x: 0, y: 0, width: 100, height: 100, centre: (0.5, 0.5))
    let inner = element(role: "Button", x: -0.5, y: 0, width: 20, height: 20, centre: (0.2, 0.2))

    guard case .target = AXTarget.select(from: [outer, inner]) else {
        Issue.record("a half-point overhang should still nest")
        return
    }
}

@Test
func aChainHoldsEvenWhereTheToleranceDoesNotCompose() {
    // Each step is inside the next within one epsilon, but the outermost is
    // not within one epsilon of the innermost. Selection checks a chain
    // rather than every pair, so this nests. Requiring every pair would
    // refuse a legitimate three-deep nesting purely from accumulated
    // rounding slack.
    let outer = element(role: "Button", x: 0, y: 0, width: 100, height: 100, centre: (0.5, 0.5))
    let middle = element(
        role: "Button", x: -0.9, y: 0, width: 50, height: 50, centre: (0.3, 0.3)
    )
    let inner = element(
        role: "Button", x: -1.8, y: 0, width: 20, height: 20, centre: (0.1, 0.1)
    )

    #expect(AXTarget.contains(outer, middle))
    #expect(AXTarget.contains(middle, inner))
    #expect(!AXTarget.contains(outer, inner))

    guard case let .target(target) = AXTarget.select(from: [outer, middle, inner]) else {
        Issue.record("a containment chain should select")
        return
    }
    #expect(target.x == 0.1)
}

@Test
func identicalFramesAreAChainNotAnAmbiguity() {
    // Stacked elements share a rectangle, so the coordinate is the same
    // either way and there is nothing to choose between.
    let lower = element(role: "Button", x: 0, y: 0, width: 20, height: 20, centre: (0.3, 0.3))
    let upper = element(role: "Link", x: 0, y: 0, width: 20, height: 20, centre: (0.3, 0.3))

    guard case let .target(target) = AXTarget.select(from: [lower, upper]) else {
        Issue.record("identical frames should select")
        return
    }
    #expect(target.x == 0.3)
}

// MARK: - Printing a centre

private func printCentreOutcome(
    tree: String,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int = 1,
    output: OutputMode = .human
) throws -> CommandOutcome {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(tree.utf8))
    ])
    return try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        printMode: .center,
        creds: waitCreds,
        runtime: clock.runtime
    )
}

@Test
func printCentreWritesABareCoordinate() throws {
    let button = element(
        role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.9016009521, 0.1243781)
    )
    let outcome = try printCentreOutcome(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Go")
    )

    // Fixed notation and nothing else, so the result can be passed as a
    // coordinate verb's two positional arguments. `String(_:)` would spell a
    // small value "5e-05".
    #expect(String(data: outcome.stdout, encoding: .utf8) == "0.901601 0.124378\n")
    #expect(outcome.exitCode == 0)
    #expect(outcome.failure == nil)
}

@Test
func printCentreRefusesWhenNothingIsReachable() throws {
    let caption = element(
        role: "StaticText", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5)
    )
    let outcome = try printCentreOutcome(
        tree: axTree(try jsonText(caption)),
        query: axQuery(label: "Go")
    )

    // Silence must never read as the origin, so a refusal writes nothing.
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.failure?.code == .waitUnreachable)
    #expect(outcome.exitCode == 1)
    let details = try waitFailureDetails(outcome)
    #expect(details["roles"] as? [String] == ["StaticText"])
}

@Test
func printCentreRefusesWhenCandidatesAreDisjoint() throws {
    let first = element(role: "Button", x: 0, y: 0, width: 20, height: 20, centre: (0.1, 0.1))
    let second = element(role: "Button", x: 50, y: 50, width: 20, height: 20, centre: (0.8, 0.8))
    let outcome = try printCentreOutcome(
        tree: axTree(try jsonText(first) + "," + jsonText(second)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.stdout.isEmpty)
    #expect(outcome.failure?.code == .waitAmbiguous)
    #expect(outcome.exitCode == 1)
    #expect(try waitFailureDetails(outcome)["candidateCount"] as? Int == 2)
}

@Test
func printCentreOnNoMatchStaysWaitTimeout() throws {
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try printCentreOutcome(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Absent")
    )

    // Nothing matched at all, which is the deadline's own story to tell.
    #expect(outcome.stdout.isEmpty)
    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

@Test
func printCentreWithJSONIsUsageBeforeAnyRequest() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([])

    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Go"),
        timeoutMs: 1,
        transport: transport,
        output: .json,
        printMode: .center,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .invalidUsage)
    // The driver prefixes a non-usage outcome's stderr, so the message must
    // not carry its own or it reads "deviceterm: deviceterm: ...".
    #expect(outcome.failure?.message.hasPrefix("deviceterm:") == false)
    // The two disagree about stdout on failure as well as on success, so the
    // refusal has to land before anything is observed.
    #expect(transport.sent.isEmpty)
}

// MARK: - Tapping the selected element

/// Run one `tap --label` against a fixed tree. The third scripted response is
/// the tap ack, which a refusing run never reaches.
private func tapElementRun(
    tree: String,
    query: CLICommand.WaitAXQuery,
    output: OutputMode = .human
) throws -> (outcome: CommandOutcome, sent: [RPCEnvelope]) {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(tree.utf8)),
        .success(Data(#"{"ok":true}"#.utf8))
    ])
    let outcome = try handleTapElement(
        pane: nil,
        query: query,
        timeoutMs: 1,
        transport: transport,
        output: output,
        creds: waitCreds,
        runtime: clock.runtime
    )
    return (outcome, transport.sent)
}

@Test
func tapBySelectorHitsTheSelectedElement() throws {
    let button = element(
        role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.9016009521, 0.1243781)
    )
    let (outcome, sent) = try tapElementRun(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.exitCode == 0)
    #expect(sent.last?.method == RPCMethod.paneInputTap.rawValue)
    guard case let .params(data) = try #require(sent.last).body else {
        Issue.record("tap request should carry params")
        return
    }
    let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    // The coordinate `--print center` would have written, sent straight to
    // the daemon instead of through the shell.
    #expect(params["x"] as? Double == 0.9016009521)
    #expect(params["y"] as? Double == 0.1243781)
    // The pane the wait resolved, not one resolved a second time.
    #expect(params["paneId"] as? String == "PANE")
}

@Test
func tapBySelectorEchoesTheElementWithoutItsLabel() throws {
    let button = element(
        role: "Button",
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        centre: (0.9016009521, 0.1243781),
        label: "Continue with Apple"
    )
    let (outcome, _) = try tapElementRun(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Continue with Apple")
    )

    // The echo line is space-separated `key=value` and is read by column
    // position, so a label with spaces would shift every field after it.
    #expect(
        String(data: outcome.stdout, encoding: .utf8)
        == "ok udid=DEVICE pane=abc123 x=0.901601 y=0.124378 role=Button matches=1\n"
    )
}

@Test
func tapBySelectorDropsARoleItCannotPrintUnquoted() throws {
    let button = element(
        role: "Text Field", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5)
    )
    let (outcome, _) = try tapElementRun(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Go")
    )

    // An absent `role=` is visible to a reader; a shifted column is not.
    let line = try #require(String(data: outcome.stdout, encoding: .utf8))
    #expect(!line.contains("role="))
    #expect(line.contains("matches=1"))
}

@Test
func tapBySelectorJSONCarriesTheElementItChose() throws {
    let button = element(
        role: "Button",
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        centre: (0.25, 0.75),
        label: "Continue with Apple"
    )
    let (outcome, _) = try tapElementRun(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Continue with Apple"),
        output: .json
    )

    let receipt = try waitOutputObject(outcome)
    #expect(receipt["x"] as? Double == 0.25)
    #expect(receipt["role"] as? String == "Button")
    // The label has somewhere to go in JSON, unlike the echo line.
    #expect(receipt["label"] as? String == "Continue with Apple")
    #expect(receipt["matchCount"] as? Int == 1)
}

@Test(
    "a refused selection sends no tap",
    arguments: [
        (
            "StaticText", 0.0, 0.0, "unreachable",
            CLIErrorCode.waitUnreachable
        ),
        (
            "Button", 50.0, 50.0, "ambiguous",
            CLIErrorCode.waitAmbiguous
        )
    ]
)
func aRefusedSelectionSendsNoTap(
    role: String,
    secondX: Double,
    secondY: Double,
    label: String,
    expected: CLIErrorCode
) throws {
    // The unreachable case matches one caption; the ambiguous case matches two
    // disjoint buttons. Both must end the command with nothing dispatched: a
    // query that named the wrong thing costs an exit code, never an input the
    // caller cannot take back.
    let first = element(role: role, x: 0, y: 0, width: 10, height: 10, centre: (0.1, 0.1))
    let second = element(
        role: "Button", x: secondX, y: secondY, width: 10, height: 10, centre: (0.8, 0.8)
    )
    let elements = try expected == .waitUnreachable
        ? jsonText(first)
        : jsonText(first) + "," + jsonText(second)
    let (outcome, sent) = try tapElementRun(
        tree: axTree(elements),
        query: axQuery(label: "Go")
    )

    #expect(outcome.failure?.code == expected, "\(label)")
    #expect(outcome.exitCode == 1)
    #expect(outcome.stdout.isEmpty)
    // Two requests: the roster and the tree. Never a third.
    #expect(sent.count == 2)
    #expect(!sent.contains { $0.method == RPCMethod.paneInputTap.rawValue })
}

@Test
func tapBySelectorOnNoMatchStaysWaitTimeout() throws {
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let (outcome, sent) = try tapElementRun(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Absent")
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(sent.count == 2)
}

// MARK: - Waiting for the surface to hold still

private func surface(
    _ sequence: UInt64,
    width: Int = 1_206,
    height: Int = 2_622
) -> PanesListEntry.Surface {
    PanesListEntry.Surface(sequence: sequence, width: width, height: height)
}

/// Run one `wait surface quiescent` over a scripted run of rosters, one per
/// probe. The clock only moves when the engine sleeps, so each entry is
/// exactly 100 ms after the one before it.
private func quiescenceOutcome(
    _ surfaces: [PanesListEntry.Surface?],
    settleMs: Int = 500,
    timeoutMs: Int = 5_000
) throws -> CommandOutcome {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport(
        try ([nil] + surfaces).map { .success(try waitData([waitPane(surface: $0)])) }
    )
    let outcome = try handleWaitSurfaceQuiescent(
        pane: nil,
        settleMs: settleMs,
        timeoutMs: timeoutMs,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )
    #expect(transport.observationCount == 1)
    #expect(transport.observation.closed)
    return outcome
}

@Test
func aStillSurfaceSatisfiesOnceTheWindowHasPassed() throws {
    // First sighting starts the window; the 100 ms cadence means six probes
    // cover the 500 ms it asks for.
    let outcome = try quiescenceOutcome(Array(repeating: surface(7), count: 8))

    #expect(outcome.exitCode == 0)
    let receipt = try waitOutputObject(outcome)
    #expect(receipt["condition"] as? String == "surface.quiescent")
    let observation = try #require(receipt["observation"] as? [String: Any])
    #expect(observation["settleMs"] as? Int == 500)
    let reported = try #require(observation["surface"] as? [String: Any])
    #expect(reported["sequence"] as? Int == 7)
    #expect(reported["width"] as? Int == 1_206)
}

@Test
func aMovingSurfaceNeverAccumulatesAWindow() throws {
    // A new sequence every probe models a pane that keeps producing frames.
    // The window restarts each time, so the deadline arrives first.
    let outcome = try quiescenceOutcome(
        (1...12).map { surface(UInt64($0)) },
        timeoutMs: 1_000
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(try waitFailureDetails(outcome)["condition"] as? String == "surface.quiescent")
}

@Test
func aLateChangeRestartsTheWindow() throws {
    // Still for four probes, then one frame, then still again. The run before
    // the change must not count toward the run after it.
    let outcome = try quiescenceOutcome(
        [surface(3), surface(3), surface(3), surface(3), surface(4)] +
            Array(repeating: surface(4), count: 3),
        timeoutMs: 800
    )

    #expect(outcome.failure?.code == .waitTimeout)
}

@Test
func aResizeCountsAsMovement() throws {
    // Same sequence, different dimensions. The receipt reports the size it
    // settled on, so a size that changed inside the window has to restart it.
    let outcome = try quiescenceOutcome(
        [surface(5), surface(5), surface(5, width: 800)] +
            Array(repeating: surface(5, width: 800), count: 2),
        timeoutMs: 500
    )

    #expect(outcome.failure?.code == .waitTimeout)
}

@Test
func aPaneWithNoSurfaceIsPendingRatherThanStill() throws {
    // Nothing drawn yet is not stillness. Waiting for a first frame is
    // `wait pane rendering`, and reporting quiescence here would let a caller
    // act on a pane that has never rendered.
    let outcome = try quiescenceOutcome(
        Array(repeating: nil, count: 12),
        settleMs: 0,
        timeoutMs: 1_000
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

@Test
func aZeroSettleStillNeedsTwoAgreeingObservations() throws {
    // Zero asks for no window, not for no evidence: the first probe records
    // the surface and the second confirms it is the same one.
    let outcome = try quiescenceOutcome(
        [surface(9), surface(9)],
        settleMs: 0,
        timeoutMs: 5_000
    )

    #expect(outcome.exitCode == 0)
    let observation = try #require(
        try waitOutputObject(outcome)["observation"] as? [String: Any]
    )
    #expect(observation["settleMs"] as? Int == 0)
}

// MARK: - Waiting for a match to disappear

/// Run one `wait ax --state absent` against a fixed tree.
private func absenceOutcome(
    tree: String,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int = 1
) throws -> CommandOutcome {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(tree.utf8))
    ])
    return try handleWaitAX(
        pane: nil,
        query: query,
        timeoutMs: timeoutMs,
        transport: transport,
        output: .json,
        state: .absent,
        creds: waitCreds,
        runtime: clock.runtime
    )
}

@Test
func anAbsentWaitSucceedsWhenNothingMatches() throws {
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try absenceOutcome(
        tree: axTree(try jsonText(button)),
        query: axQuery(label: "Spinner")
    )

    #expect(outcome.exitCode == 0)
    let receipt = try waitOutputObject(outcome)
    #expect(receipt["condition"] as? String == "ax.disappears")
    let observation = try #require(receipt["observation"] as? [String: Any])
    #expect(observation["matchCount"] as? Int == 0)
    #expect(observation["source"] as? String == "tree")
    // Present and absent publish the same observation shape, so `matches` is
    // an empty array rather than a missing key. A consumer reading it should
    // not have to check the condition first to know whether it is there.
    #expect(observation["matches"] is [[String: Any]])
    #expect((observation["matches"] as? [[String: Any]])?.isEmpty == true)
}

@Test
func anAbsentWaitTimesOutWhileTheElementIsStillThere() throws {
    let spinner = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try absenceOutcome(
        tree: axTree(try jsonText(spinner)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
    #expect(try waitFailureDetails(outcome)["condition"] as? String == "ax.disappears")
}

@Test
func anAbsentWaitNeverConcludesFromAnIncompleteObservation() throws {
    // The whole point of the flag is a claim about what is *not* there, so a
    // sweep that skipped cells cannot support it: the element may be sitting
    // in one of them. Reporting absence here would be the same defect as
    // tapping an unproven target.
    let other = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try absenceOutcome(
        tree: truncatedSweep(try jsonText(other)),
        query: axSweepQuery(label: "Spinner")
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.exitCode == 1)
    let details = try waitFailureDetails(outcome)
    #expect(details["truncated"] as? Bool == true)
    // The condition has to name the wait that was actually asked for. A
    // verification script branches on this field, and reporting `ax.appears`
    // for a wait the caller spelled `--state absent` sends it the wrong way.
    #expect(details["condition"] as? String == "ax.disappears")
}

@Test(
    "every wait failure reports the condition it was asked for",
    arguments: [
        ("ax.disappears", CLICommand.WaitAXState.absent),
        ("ax.appears", CLICommand.WaitAXState.present)
    ]
)
func aWaitFailureNamesItsOwnCondition(
    condition: String,
    state: CLICommand.WaitAXState
) throws {
    // An unobservable pane fails inside `observeAXMatches`, which is shared by
    // both directions, so it is the shortest path to a details dictionary that
    // could carry the wrong one.
    let clock = WaitTestClock()
    var capabilities = PaneCapabilities.simulator
    capabilities.accessibility = false
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(capabilities: capabilities)]))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Go"),
        timeoutMs: 1,
        transport: transport,
        output: .json,
        state: state,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitUnsupported)
    #expect(try waitFailureDetails(outcome)["condition"] as? String == condition)
}

@Test
func anAbsentWaitTrustsASightingOverAnyIncompleteness() throws {
    // Seeing the element is proof it is still there, whatever else the same
    // observation failed to cover, so this is an ordinary deadline rather
    // than an inconclusive one.
    let spinner = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try absenceOutcome(
        tree: truncatedSweep(try jsonText(spinner)),
        query: axSweepQuery(label: "Go")
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

// MARK: - Acting on an incomplete observation

@Test(
    "a selector never acts on a sweep that stopped short",
    arguments: [
        "one eligible target",
        "a caption only",
        "two disjoint candidates"
    ]
)
func aSelectorRefusesEveryVerdictFromAnIncompleteSweep(shape: String) throws {
    // Every verdict selection can reach is a claim about what did NOT match,
    // and an unswept cell refutes each of them differently: it can hold a
    // second control that makes a target ambiguous, the real control behind a
    // caption, or the intermediate frame that turns two disjoint candidates
    // into a containment chain. None survives partial coverage.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.1, 0.1))
    let caption = element(
        role: "StaticText", x: 0, y: 0, width: 10, height: 10, centre: (0.1, 0.1)
    )
    let distant = element(
        role: "Button", x: 50, y: 50, width: 10, height: 10, centre: (0.8, 0.8)
    )
    let elements: String
    switch shape {
    case "one eligible target":
        elements = try jsonText(button)

    case "a caption only":
        elements = try jsonText(caption)

    default:
        elements = try jsonText(button) + "," + (try jsonText(distant))
    }
    let (outcome, sent) = try tapElementRun(
        tree: truncatedSweep(elements),
        query: axSweepQuery(label: "Go")
    )

    #expect(outcome.failure?.code == .waitInconclusive, "\(shape)")
    #expect(outcome.exitCode == 1)
    // The whole point: no input reaches the device on an unproven observation.
    #expect(sent.count == 2, "\(shape)")
    #expect(!sent.contains { $0.method == RPCMethod.paneInputTap.rawValue })
    // The coverage the caller needs to decide whether raising the budget helps.
    let details = try waitFailureDetails(outcome)
    #expect(details["truncated"] as? Bool == true)
    #expect(details["sweepedPoints"] as? Int == 137)
}

/// A tree the daemon caught omitting an on-screen element, carrying the note
/// and code it annotates such a response with.
private func incompleteTree(_ elements: String) -> String {
    #"{"tree":{"role":"Application","noteCode":"ax.treeIncomplete","#
        + #""note":"\#(AXTreeNote.treeIncomplete.rawValue)","children":[\#(elements)]}}"#
}

@Test
func aSelectorNeverActsOnATreeKnownToBeMissingSomething() throws {
    // The daemon hit-tested an element its own walk never listed, which
    // refutes uniqueness the same way an unswept cell does: the element it
    // missed could be a second control matching this very selector.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let (outcome, sent) = try tapElementRun(
        tree: incompleteTree(try jsonText(button)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(!sent.contains { $0.method == RPCMethod.paneInputTap.rawValue })
    // The daemon's own sentence and code, so a caller branches on the note
    // rather than on this build's wording.
    let details = try waitFailureDetails(outcome)
    #expect(details["noteCode"] as? String == AXTreeNote.treeIncomplete.code)
}

@Test
func aThinTreeThatFillsInStillTaps() throws {
    // The difference from a truncated sweep: treeIncomplete is retryable, so
    // a later complete probe lets the tap proceed. Failing on the first thin
    // tree would break `tap` against a page still loading, which is the case
    // the selector form exists for.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.25, 0.75))
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(incompleteTree(try jsonText(button)).utf8)),
        .success(try waitData([waitPane()])),
        .success(Data(axTree(try jsonText(button)).utf8)),
        .success(Data(#"{"ok":true}"#.utf8))
    ])
    let outcome = try handleTapElement(
        pane: nil,
        query: axQuery(label: "Go"),
        timeoutMs: 200,
        transport: transport,
        output: .human,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.exitCode == 0)
    #expect(transport.sent.last?.method == RPCMethod.paneInputTap.rawValue)
}

@Test
func aPresenceWaitStillMatchesInsideAThinTree() throws {
    // Match-wins, whatever the note says. The element was seen, which is the
    // whole question a presence wait asks, so what the walk missed elsewhere
    // cannot unmake the sighting.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try axWaitOutcome(
        tree: incompleteTree(try jsonText(button)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test
func aPresenceWaitReportsAThinTreeAtItsDeadline() throws {
    // Nothing matched in a tree the daemon caught omitting something, so the
    // element may have been on screen the whole time and simply unpublished.
    // A bare `wait.timeout` would send the reader to inspect their app; the
    // daemon's own sentence sends them to `ax sweep` instead.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try axWaitOutcome(
        tree: incompleteTree(try jsonText(button)),
        query: axQuery(label: "Absent"),
        timeoutMs: 1
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.exitCode == 1)
    #expect(outcome.failure?.message == AXTreeNote.treeIncomplete.rawValue)
    let details = try waitFailureDetails(outcome)
    #expect(details["noteCode"] as? String == AXTreeNote.treeIncomplete.code)
    #expect(details["condition"] as? String == "ax.appears")
}

@Test
func aPresenceWaitOnATreeThatFillsInReportsItsDeadline() throws {
    // Two things at once. The thin tree does not fail the wait on the probe
    // that saw it, and the complete one that follows clears it, so a deadline
    // reached on a tree that reached everything reports the deadline.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(incompleteTree(try jsonText(button)).utf8)),
        .success(try waitData([waitPane()])),
        .success(Data(axTree(try jsonText(button)).utf8))
    ])
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Absent"),
        timeoutMs: 150,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

@Test
func aProbeThatDiesLeavesNoEarlierObservationToReportWith() throws {
    // The first probe sees a thin tree. The second dies in its roster request,
    // so the wait never learns what the pane held at the end. Standing in the
    // earlier observation would report coverage nobody checked, which is the
    // rule `lastProbeNamedNoPane` already follows for pane resolution.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(incompleteTree(try jsonText(button)).utf8)),
        .failure(.transportTimeout("timed out waiting for daemon response"))
    ])
    // Spend the rest of the deadline inside the request that fails.
    transport.onSend = { if transport.sent.count == 3 { clock.now += 200_000_000 } }
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Absent"),
        timeoutMs: 150,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

@Test
func aDeadProbeAlsoWithdrawsTheMatchesASelectorWouldJudge() throws {
    // Same rule, and the case it protects hardest. `--print center` classifies
    // its deadline from the last match list, so a stale one turns an
    // unobserved window into a positive verdict about what didn't match.
    let first = element(role: "Button", x: 0, y: 0, width: 40, height: 40, centre: (0.2, 0.2))
    let second = element(role: "Button", x: 60, y: 60, width: 40, height: 40, centre: (0.8, 0.8))
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(axTree(try jsonText(first) + "," + (try jsonText(second))).utf8)),
        .failure(.transportTimeout("timed out waiting for daemon response"))
    ])
    transport.onSend = { if transport.sent.count == 3 { clock.now += 200_000_000 } }
    let outcome = try handleWaitAX(
        pane: nil,
        query: axQuery(label: "Go"),
        timeoutMs: 150,
        transport: transport,
        output: .human,
        printMode: .center,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // Two disjoint matches would be `wait.ambiguous` had the last probe seen
    // them. It didn't, so the deadline is what there is to report.
    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.stdout.isEmpty)
}

@Test
func aSelectorNeverActsOnATreeThatCouldNotBeEnumerated() throws {
    // The root survives an unsupported walk, and it carries a label and a
    // centre of its own, so a selector naming the app matches it and would tap
    // the middle of the screen. The note has to refuse before selection runs,
    // not only when nothing matched.
    let root: [String: Any] = [
        "role": "Application",
        "label": "MyApp",
        "noteCode": AXTreeNote.watchOSEnumerationUnsupported.code,
        "note": AXTreeNote.watchOSEnumerationUnsupported.rawValue,
        "frame": ["x": 0, "y": 0, "w": 100, "h": 100],
        "normalizedCenter": ["x": 0.5, "y": 0.5],
        "children": []
    ]
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane()])),
        .success(Data(#"{"tree":\#(try jsonText(root))}"#.utf8)),
        .success(Data(#"{"ok":true}"#.utf8))
    ])
    let outcome = try handleTapElement(
        pane: nil,
        query: axQuery(label: "MyApp"),
        timeoutMs: 1,
        transport: transport,
        output: .human,
        creds: waitCreds,
        runtime: clock.runtime
    )

    // Unsupported, not inconclusive: the remedy is another --source, never
    // more time or a bigger budget.
    #expect(outcome.failure?.code == .waitUnsupported)
    #expect(!transport.sent.contains { $0.method == RPCMethod.paneInputTap.rawValue })
}

@Test
func aPresenceWaitStillMatchesAnUnenumerableRoot() throws {
    // Plain `wait ax` keeps match-wins here too. The root is a real element
    // that really carries that label, so a presence question is answered.
    let root: [String: Any] = [
        "role": "Application",
        "label": "MyApp",
        "noteCode": AXTreeNote.watchOSEnumerationUnsupported.code,
        "note": AXTreeNote.watchOSEnumerationUnsupported.rawValue,
        "children": []
    ]
    let outcome = try axWaitOutcome(
        tree: #"{"tree":\#(try jsonText(root))}"#,
        query: axQuery(label: "MyApp")
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test
func printingACentreRefusesAnIncompleteSweepToo() throws {
    // Same rule, same code path. Printing a coordinate the selection could not
    // prove unique is the same defect as tapping one.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try printCentreOutcome(
        tree: truncatedSweep(try jsonText(button)),
        query: axSweepQuery(label: "Go")
    )

    #expect(outcome.failure?.code == .waitInconclusive)
    #expect(outcome.stdout.isEmpty)
}

@Test
func aPresenceWaitStillSucceedsOnAnIncompleteSweep() throws {
    // The precedence that stays: a found element is proof of presence whatever
    // went unswept, so plain `wait ax` is unaffected by the selector rule. No
    // amount of missing coverage turns a sighting into an absence.
    let button = element(role: "Button", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5))
    let outcome = try axWaitOutcome(
        tree: truncatedSweep(try jsonText(button)),
        query: axSweepQuery(label: "Go")
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test
func plainWaitAXStillSucceedsOnACaptionOnlyMatch() throws {
    // Coordinate selection applies only to `--print center`; plain `wait ax`
    // succeeds on any match, including a presentational-only one.
    let caption = element(
        role: "StaticText", x: 0, y: 0, width: 10, height: 10, centre: (0.5, 0.5)
    )
    let outcome = try axWaitOutcome(
        tree: axTree(try jsonText(caption)),
        query: axQuery(label: "Go")
    )

    #expect(outcome.exitCode == 0)
    #expect(try axMatches(outcome).count == 1)
}

@Test
func anAbsurdSettleWindowTimesOutRatherThanTrapping() throws {
    // The parser admits any non-negative `Int`, and converting milliseconds
    // to nanoseconds by a plain multiply traps long before `Int.max`. A
    // window that saturates never elapses, which is the honest outcome.
    let outcome = try quiescenceOutcome(
        Array(repeating: surface(1), count: 5),
        settleMs: Int.max,
        timeoutMs: 300
    )

    #expect(outcome.failure?.code == .waitTimeout)
    #expect(outcome.exitCode == 124)
}

@Test
func cachedHiddenSurfaceCannotSatisfyQuiescenceBeforeResume() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport(try Array(repeating: surface(9), count: 12).map {
        .success(try waitData([waitPane(surface: $0)]))
    })
    let outcome = try handleWaitSurfaceQuiescent(
        pane: nil,
        settleMs: 0,
        timeoutMs: 1_000,
        transport: transport,
        output: .json,
        creds: waitCreds,
        runtime: clock.runtime
    )
    #expect(outcome.failure?.code == .waitTimeout)
    #expect(transport.observationCount == 1)
    #expect(transport.observation.closed)
}

@Test
func surfaceSubscriptionFailureClosesDemandAndCannotSatisfyWait() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([.success(try waitData([waitPane(surface: surface(1))]))])
    transport.observation.failure = .transportInterrupted("lost subscription")
    do {
        _ = try handleWaitSurfaceQuiescent(
            pane: nil,
            settleMs: 0,
            timeoutMs: 1_000,
            transport: transport,
            output: .json,
            creds: waitCreds,
            runtime: clock.runtime
        )
        Issue.record("expected the surface subscription error to propagate")
    } catch let CLIError.classified(code, message) {
        #expect(code == .transportInterrupted)
        #expect(message == "lost subscription")
    }
    #expect(transport.observation.closed)
}

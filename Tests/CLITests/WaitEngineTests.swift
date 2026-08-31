// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

@testable import DeviceTermCLI

private final class WaitScriptTransport: CLITransport {
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
        return try responses.removeFirst().get()
    }

    func send(
        timeoutSeconds: Double,
        buildingEnvelope: () throws -> RPCEnvelope
    ) throws -> Data {
        beforeBuildingEnvelope?()
        return try send(try buildingEnvelope(), timeoutSeconds: timeoutSeconds)
    }
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

/// An `Application` root containing the supplied element JSON, as `ax tree`
/// frames it.
private func axTree(_ elements: String) -> String {
    #"{"tree":{"role":"Application","children":[\#(elements)]}}"#
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
        RPCMethod.panesList.rawValue, RPCMethod.paneAXTree.rawValue,
        RPCMethod.panesList.rawValue, RPCMethod.paneAXTree.rawValue
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
        RPCMethod.panesList.rawValue, RPCMethod.paneAXTree.rawValue
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
    #expect(transport.sent.map(\.method) == [RPCMethod.panesList.rawValue])
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

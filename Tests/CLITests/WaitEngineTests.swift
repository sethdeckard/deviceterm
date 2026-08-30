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
        Issue.record("ambiguous wait unexpectedly succeeded")
    } catch {
        #expect(errorOutcome(error).failure?.code == .paneAmbiguous)
    }
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
        Issue.record("disappearing pane unexpectedly reached the condition")
    } catch {
        #expect(errorOutcome(error).failure?.code == .paneNotFound)
    }
    #expect(transport.sent.count == 2)
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
func axWaitReturnsTheFirstDepthFirstMatch() throws {
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

    let receipt = try waitOutputObject(outcome)
    let observation = try #require(receipt["observation"] as? [String: Any])
    let element = try #require(observation["element"] as? [String: Any])
    #expect(element["label"] as? String == "Nested")
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
func watchTreeWaitIsUnsupportedWithoutAnAXProbe() throws {
    let clock = WaitTestClock()
    let transport = WaitScriptTransport([
        .success(try waitData([waitPane(family: "watch")]))
    ])
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
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

    #expect(outcome.failure?.code == .waitUnsupported)
    #expect(transport.sent.map(\.method) == [RPCMethod.panesList.rawValue])
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

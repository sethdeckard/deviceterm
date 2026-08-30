// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum WaitEngine {
    struct Runtime: Sendable {
        static let live = Runtime(
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleepNanoseconds: { nanoseconds in
                usleep(useconds_t(min(nanoseconds / 1_000, UInt64(useconds_t.max))))
            }
        )

        let nowNanoseconds: @Sendable () -> UInt64
        let sleepNanoseconds: @Sendable (UInt64) -> Void
    }

    struct ProbeContext {
        let deadlineNanoseconds: UInt64
        let runtime: Runtime

        var isExpired: Bool {
            runtime.nowNanoseconds() >= deadlineNanoseconds
        }

        func remainingSeconds() throws -> Double {
            let now = runtime.nowNanoseconds()
            guard now < deadlineNanoseconds else { throw Failure.deadline }
            return Double(deadlineNanoseconds - now) / 1_000_000_000
        }

        func remainingMilliseconds() throws -> Int {
            let now = runtime.nowNanoseconds()
            guard now < deadlineNanoseconds else { throw Failure.deadline }
            return Int(min((deadlineNanoseconds - now) / 1_000_000, UInt64(Int.max)))
        }
    }

    struct Completion {
        let elapsedMs: Int
        let attempts: Int
        let pane: PanesListEntry
        let observation: [String: Any]
    }

    struct OrientationSnapshot {
        let paneId: String
        let orientation: Orientation
        let width: Int
        let height: Int
    }

    enum ProbeResult {
        case pending
        case satisfied(pane: PanesListEntry, observation: [String: Any])
    }

    struct Failure: Error {
        static let deadline = Failure(
            code: .waitTimeout,
            message: "wait deadline expired",
            exitCode: 124,
            details: nil
        )

        let code: CLIErrorCode
        let message: String
        let exitCode: Int32
        let details: Data?
    }

    static let cadenceNanoseconds: UInt64 = 100_000_000

    static func run(
        timeoutMs: Int,
        runtime: Runtime = .live,
        probe: (ProbeContext) throws -> ProbeResult
    ) throws -> Completion {
        let start = runtime.nowNanoseconds()
        let converted = UInt64(clamping: timeoutMs).multipliedReportingOverflow(by: 1_000_000)
        let timeoutNanoseconds = converted.overflow ? UInt64.max : converted.partialValue
        let deadline = start.addingReportingOverflow(timeoutNanoseconds).overflow
            ? UInt64.max
            : start + timeoutNanoseconds
        var attempts = 0
        while runtime.nowNanoseconds() < deadline {
            attempts += 1
            let result: ProbeResult
            do {
                result = try probe(
                    ProbeContext(deadlineNanoseconds: deadline, runtime: runtime)
                )
            } catch let failure as Failure where failure.code == .waitTimeout {
                break
            }
            let afterProbe = runtime.nowNanoseconds()
            if case let .satisfied(pane, observation) = result, afterProbe < deadline {
                return Completion(
                    elapsedMs: elapsedMilliseconds(from: start, to: afterProbe),
                    attempts: attempts,
                    pane: pane,
                    observation: observation
                )
            }
            guard afterProbe < deadline else { break }
            runtime.sleepNanoseconds(min(cadenceNanoseconds, deadline - afterProbe))
        }
        let elapsed = elapsedMilliseconds(from: start, to: runtime.nowNanoseconds())
        throw Failure(
            code: .waitTimeout,
            message: "wait deadline expired after \(elapsed) ms",
            exitCode: 124,
            details: waitDetails([
                "elapsedMs": elapsed,
                "timeoutMs": timeoutMs,
                "attempts": attempts
            ])
        )
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        Int(min(end >= start ? (end - start) / 1_000_000 : 0, UInt64(Int.max)))
    }
}

func handleWaitPane(
    pane: String?,
    state: PaneLifecycle,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    let condition = "pane.\(state.rawValue)"
    return try handleWait(
        pane: pane,
        condition: condition,
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    ) { entry, _ in
        guard entry.state == state else { return .pending }
        return .satisfied(pane: entry, observation: ["state": entry.state.rawValue])
    }
}

func handleWaitAX(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    try handleWait(
        pane: pane,
        condition: "ax.appears",
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    ) { entry, context in
        if entry.capabilities?.accessibility == false {
            throw WaitEngine.Failure(
                code: .waitUnsupported,
                message: "accessibility observation is unavailable for this pane",
                exitCode: 1,
                details: waitDetails([
                    "condition": "ax.appears",
                    "source": query.source.rawValue
                ])
            )
        }
        if query.source == .tree, entry.family?.lowercased() == "watch" {
            throw WaitEngine.Failure(
                code: .waitUnsupported,
                message: "AX tree observation is unavailable for watch panes",
                exitCode: 1,
                details: waitDetails([
                    "condition": "ax.appears",
                    "source": query.source.rawValue
                ])
            )
        }
        let data: Data
        switch query.source {
        case .tree:
            data = try sendWaitRequest(
                try CLICommands.axTreeRequest(paneId: entry.paneId),
                transport: transport,
                context: context,
                maximumSeconds: AXTimeout.response
            )

        case .sweep:
            data = try sendWaitRequest(
                transport: transport,
                context: context,
                maximumSeconds: AXTimeout.response
            ) {
                let budgetMs = min(
                    AXSweepBudget.clamp(query.budgetMs),
                    try context.remainingMilliseconds()
                )
                return try CLICommands.axSweepRequest(
                    paneId: entry.paneId,
                    step: query.step,
                    budgetMs: budgetMs
                )
            }
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIError.invalidResponse("invalid accessibility response: \(error)")
        }
        guard let envelope = object as? [String: Any],
            let root = envelope["tree"] as? [String: Any] else {
            throw CLIError.invalidResponse("accessibility response is not a JSON object")
        }
        if let match = matchingAXElement(in: root, query: query) {
            return .satisfied(
                pane: entry,
                observation: ["source": query.source.rawValue, "element": match]
            )
        }
        if query.source == .sweep, root["truncated"] as? Bool == true {
            throw WaitEngine.Failure(
                code: .waitInconclusive,
                message: "AX sweep ended before covering the full grid",
                exitCode: 1,
                details: waitDetails([
                    "condition": "ax.appears",
                    "source": "sweep",
                    "truncated": true
                ])
            )
        }
        return .pending
    }
}

func handleWaitOrientation(
    pane: String?,
    orientation: Orientation,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    var priorStable: WaitEngine.OrientationSnapshot?
    return try handleWait(
        pane: pane,
        condition: "orientation.\(orientation.rawValue)",
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    ) { entry, _ in
        if entry.orientationConfirmationSupported == false
            || (entry.orientationConfirmationSupported == nil && entry.orientation == nil) {
            throw WaitEngine.Failure(
                code: .waitUnsupported,
                message: "this pane cannot report a confirmed orientation",
                exitCode: 1,
                details: waitDetails([
                    "condition": "orientation.\(orientation.rawValue)"
                ])
            )
        }
        guard let observed = entry.orientation else {
            priorStable = nil
            return .pending
        }
        guard observed == orientation,
            let surface = entry.surface,
            surface.width > 0,
            surface.height > 0 else {
            priorStable = nil
            return .pending
        }
        let current = WaitEngine.OrientationSnapshot(
            paneId: entry.paneId,
            orientation: observed,
            width: surface.width,
            height: surface.height
        )
        defer { priorStable = current }
        guard let priorStable,
            priorStable.paneId == current.paneId,
            priorStable.orientation == current.orientation,
            priorStable.width == current.width,
            priorStable.height == current.height else {
            return .pending
        }
        return .satisfied(
            pane: entry,
            observation: [
                "orientation": observed.rawValue,
                "surface": [
                    "sequence": surface.sequence,
                    "width": surface.width,
                    "height": surface.height
                ]
            ]
        )
    }
}

private func handleWait(
    pane: String?,
    condition: String,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime,
    conditionProbe: (PanesListEntry, WaitEngine.ProbeContext) throws -> WaitEngine.ProbeResult
) throws -> CommandOutcome {
    let credentials = try creds ?? readSessionCredentials()
    var resolvedPaneId: String?
    do {
        let completion = try WaitEngine.run(timeoutMs: timeoutMs, runtime: runtime) { context in
            let request = try CLICommands.panesListRequest(
                sessionId: credentials.sessionId,
                cap: credentials.cap
            )
            let data = try sendWaitRequest(
                request,
                transport: transport,
                context: context,
                maximumSeconds: AppCommandDeadline.cliRequestTimeoutSeconds
            )
            let panes = try JSONDecoder().decode([PanesListEntry].self, from: data)
            guard let entry = try resolveWaitPane(
                ref: pane,
                panes: panes,
                resolvedPaneId: resolvedPaneId
            ) else {
                return .pending
            }
            resolvedPaneId = entry.paneId
            return try conditionProbe(entry, context)
        }
        return try waitSuccessOutcome(completion, condition: condition, output: output)
    } catch let failure as WaitEngine.Failure {
        var details = failure.details.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        details["condition"] = details["condition"] ?? condition
        return .failure(
            code: failure.code,
            message: failure.message,
            details: try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
            exitCode: failure.exitCode
        )
    }
}

private func sendWaitRequest(
    _ request: RPCEnvelope,
    transport: CLITransport,
    context: WaitEngine.ProbeContext,
    maximumSeconds: Double
) throws -> Data {
    let remaining = try context.remainingSeconds()
    do {
        return try transport.send(request, timeoutSeconds: min(remaining, maximumSeconds))
    } catch let CLIError.classified(code, _) where code == .transportTimeout && context.isExpired {
        throw WaitEngine.Failure.deadline
    }
}

private func sendWaitRequest(
    transport: CLITransport,
    context: WaitEngine.ProbeContext,
    maximumSeconds: Double,
    buildingRequest: () throws -> RPCEnvelope
) throws -> Data {
    let remaining = try context.remainingSeconds()
    do {
        return try transport.send(
            timeoutSeconds: min(remaining, maximumSeconds),
            buildingEnvelope: buildingRequest
        )
    } catch let CLIError.classified(code, _) where code == .transportTimeout && context.isExpired {
        throw WaitEngine.Failure.deadline
    }
}

private func waitDetails(_ details: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
}

private func resolveWaitPane(
    ref: String?,
    panes: [PanesListEntry],
    resolvedPaneId: String?
) throws -> PanesListEntry? {
    if let resolvedPaneId {
        guard let pane = panes.first(where: { $0.paneId == resolvedPaneId }) else {
            throw CLIError.paneNotFound("the pane disappeared while waiting")
        }
        return pane
    }
    if let ref, !ref.isEmpty {
        switch PaneRefResolver.resolve(ref, in: panes) {
        case let .entry(entry):
            return entry

        case let .ambiguous(hits):
            throw CLIError.paneAmbiguous(
                "'\(ref)' is ambiguous in this tab; matches:\n" + paneRosterLines(hits)
            )

        case .notFound, .sentinel:
            return nil
        }
    }
    if let envKey = envValue(DeviceTermEnv.targetPane), !envKey.isEmpty {
        return PaneRefResolver.exactKeyMatch(envKey, in: panes)
    }
    guard panes.count <= 1 else {
        throw CLIError.paneAmbiguous(
            "multiple panes in this tab; pass --pane <ref>:\n" + paneRosterLines(panes)
        )
    }
    return panes.first
}

private func matchingAXElement(
    in value: Any,
    query: CLICommand.WaitAXQuery
) -> [String: Any]? {
    if let element = value as? [String: Any] {
        let primaryMatches: Bool
        if let identifier = query.identifier {
            primaryMatches = element["identifier"] as? String == identifier
        } else if let label = query.label {
            primaryMatches = element["label"] as? String == label
        } else {
            primaryMatches = false
        }
        let roleMatches = query.role.map { element["role"] as? String == $0 } ?? true
        if primaryMatches, roleMatches { return element }
        if let children = element["children"] as? [Any] {
            for child in children {
                if let match = matchingAXElement(in: child, query: query) { return match }
            }
        }
    } else if let values = value as? [Any] {
        for child in values {
            if let match = matchingAXElement(in: child, query: query) { return match }
        }
    }
    return nil
}

private func waitSuccessOutcome(
    _ completion: WaitEngine.Completion,
    condition: String,
    output: OutputMode
) throws -> CommandOutcome {
    switch output {
    case .human:
        return .stdout(
            "ok condition=\(condition) elapsedMs=\(completion.elapsedMs) "
                + "attempts=\(completion.attempts) udid=\(completion.pane.udid) "
                + "pane=\(completion.pane.shortId ?? completion.pane.paneId)\n"
        )

    case .json:
        var pane: [String: Any] = [
            "paneId": completion.pane.paneId,
            "udid": completion.pane.udid
        ]
        if let shortId = completion.pane.shortId { pane["shortId"] = shortId }
        let receipt: [String: Any] = [
            "ok": true,
            "condition": condition,
            "elapsedMs": completion.elapsedMs,
            "attempts": completion.attempts,
            "pane": pane,
            "observation": completion.observation
        ]
        var data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        data.append(0x0A)
        return .stdout(data)
    }
}

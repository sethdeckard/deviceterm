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

    /// A `wait ax` query with its needle folded once, ahead of the walk.
    ///
    /// The walk visits every node of every probe for the life of the wait, so
    /// folding per node would repeat work the query fixes. Building this once
    /// leaves the comparison itself a plain `==` or `contains`.
    struct AXMatcher {
        /// Locale-independent caseless folding, so a match does not depend on
        /// the caller's `LANG`.
        ///
        /// `lowercased()` is not caseless matching: German "Straße" and
        /// "STRASSE" lowercase to "straße" and "strasse", which never
        /// compare equal. Folding maps both to "strasse". Turkish dotted and
        /// dotless I stay distinct under any locale-independent rule.
        static let foldingOptions: String.CompareOptions = [.caseInsensitive]

        /// The element key the primary selector reads: `identifier` or `label`.
        let attribute: String
        /// The needle, case-folded when `mode` is `.contains`.
        let needle: String
        let mode: CLICommand.WaitAXMatchMode
        /// Optional additional conjunct, exact and case-sensitive in both
        /// modes. A role names a fixed vocabulary rather than app-authored
        /// text, so there is nothing for a substring to reach.
        let role: String?

        /// Nil when the query names neither primary selector. The parser
        /// admits exactly one, so callers treat nil as matching nothing
        /// rather than as an error worth its own code.
        init?(query: CLICommand.WaitAXQuery) {
            let primary: (attribute: String, needle: String)
            if let identifier = query.identifier {
                primary = ("identifier", identifier)
            } else if let label = query.label {
                primary = ("label", label)
            } else {
                return nil
            }
            attribute = primary.attribute
            needle = query.matchMode == .contains
                ? primary.needle.folding(options: Self.foldingOptions, locale: nil)
                : primary.needle
            mode = query.matchMode
            role = query.role
        }

        func matches(_ element: [String: Any]) -> Bool {
            guard let candidate = element[attribute] as? String else { return false }
            let primaryMatches: Bool
            switch mode {
            case .exact:
                primaryMatches = candidate == needle

            case .contains:
                primaryMatches = candidate
                    .folding(options: Self.foldingOptions, locale: nil)
                    .contains(needle)
            }
            guard primaryMatches else { return false }
            guard let role else { return true }
            return element["role"] as? String == role
        }
    }

    /// Orders the elements a `wait ax` probe matched, so `matches[0]` is the
    /// node a caller can most likely act on.
    ///
    /// Three rules, in order. Presentational elements rank last, because a
    /// control and the caption inside it routinely share a label and the
    /// caption is the one that cannot be operated. Elements carrying no
    /// `normalizedCenter` rank next-to-last, since a caller with no
    /// coordinate cannot reach them. Everything else ranks by ascending
    /// frame area, since among unrelated matches the most specific node
    /// under a point is the control rather than the container holding it.
    ///
    /// Area alone would invert the first rule, because a caption nests
    /// inside its control and is always the smaller of the two. It would
    /// also miss the second: an off-screen element can have a perfectly
    /// valid frame.
    ///
    /// The result is a heuristic. It cannot see whether an element is
    /// enabled, obscured, or behind a modal, so a caller that must act
    /// should still check the entry it picked.
    enum MatchRanking {
        /// Presentational last, then elements with no centre, then smallest
        /// frame first, then discovery order.
        struct SortKey: Comparable {
            let isPresentational: Bool
            /// The daemon omits `normalizedCenter` when a frame is positive
            /// but its centre lands off-screen, so a small off-screen match
            /// would otherwise outrank a larger one a caller can actually
            /// reach. Area does not detect that case: it only sees a valid
            /// frame.
            ///
            /// Ranked below the presentational test rather than above it. A
            /// control whose centre is off-screen must still outrank its own
            /// caption, or the defect this ranking exists to fix returns
            /// wherever a control happens to sit at the screen edge.
            let lacksCenter: Bool
            /// `.infinity` when the element has no usable frame, which puts
            /// it last within its group: it cannot be ranked by area and
            /// cannot be tapped, but waiting on a status line is legitimate,
            /// so it is ranked down rather than dropped.
            let area: Double
            /// Depth-first position, which breaks ties. Explicit because
            /// `sorted(by:)` promises no stability and equal areas are
            /// common among siblings.
            let discovery: Int

            static func < (lhs: SortKey, rhs: SortKey) -> Bool {
                if lhs.isPresentational != rhs.isPresentational { return !lhs.isPresentational }
                if lhs.lacksCenter != rhs.lacksCenter { return !lhs.lacksCenter }
                if lhs.area != rhs.area { return lhs.area < rhs.area }
                return lhs.discovery < rhs.discovery
            }
        }

        /// Roles known to be presentational, which rank after everything
        /// else.
        ///
        /// The test is membership, not absence: roles come from private
        /// Apple frameworks, are best-effort, and shift between OS versions,
        /// so demoting whatever is missing from a known-interactive list
        /// would bury real controls the moment the vocabulary moves.
        /// Demoting only a role known to be presentational fails safe, and
        /// an unrecognized role is treated as actionable.
        static let presentationalRoles: Set<String> = ["StaticText", "Image"]

        /// Order `matches`, which arrive in depth-first discovery order.
        static func ordered(_ matches: [[String: Any]]) -> [[String: Any]] {
            matches
                .enumerated()
                .map { (key: sortKey(for: $0.element, discovery: $0.offset), element: $0.element) }
                .sorted { $0.key < $1.key }
                .map(\.element)
        }

        static func sortKey(for element: [String: Any], discovery: Int) -> SortKey {
            SortKey(
                isPresentational: presentationalRoles.contains(element["role"] as? String ?? ""),
                lacksCenter: !(element["normalizedCenter"] is [String: Any]),
                area: area(of: element) ?? .infinity,
                discovery: discovery
            )
        }

        /// The element's frame area, or nil when it has no usable frame.
        static func area(of element: [String: Any]) -> Double? {
            guard let frame = element["frame"] as? [String: Any],
                let width = numeric(frame["w"]),
                let height = numeric(frame["h"]),
                width > 0,
                height > 0
            else { return nil }
            return width * height
        }

        /// `JSONSerialization` hands back `NSNumber`, which bridges to either
        /// spelling depending on how the daemon serialized the frame.
        private static func numeric(_ value: Any?) -> Double? {
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            return nil
        }
    }

    static let cadenceNanoseconds: UInt64 = 100_000_000

    /// Most matched elements a receipt carries. `matchCount` reports the true
    /// total alongside, so a trimmed list is visibly trimmed rather than
    /// quietly short. Ranking runs before truncation, so the entries dropped
    /// are the lowest-ranked candidates.
    static let maxReportedMatches = 20

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
            // A probe that observed the condition reports it however late it
            // returned. Its request is bounded by the time left, so the daemon
            // may answer at the deadline and the walk over that response runs
            // afterwards; discarding the result here would report a timeout
            // for a condition that was seen to hold. The receipt's `elapsedMs`
            // may exceed `timeoutMs` as a result, which is the honest reading.
            if case let .satisfied(pane, observation) = result {
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
    // Built once per wait, not per probe: the needle's folded form is a
    // property of the query, and every probe walks the tree with it.
    let matcher = WaitEngine.AXMatcher(query: query)
    return try handleWait(
        pane: pane,
        condition: "ax.appears",
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    ) { entry, context in
        let matches = try observeAXMatches(
            entry: entry,
            context: context,
            query: query,
            matcher: matcher,
            transport: transport
        )
        guard !matches.isEmpty else { return .pending }
        return .satisfied(
            pane: entry,
            observation: [
                "source": query.source.rawValue,
                "matches": Array(matches.prefix(WaitEngine.maxReportedMatches)),
                "matchCount": matches.count
            ]
        )
    }
}

/// One accessibility observation of `entry`, reduced to the elements
/// `matcher` selects and ranked so the most operable comes first.
///
/// An empty result means the probe found nothing and the wait should keep
/// going. Incompleteness the observation reported is thrown instead, and only
/// after the match test, because a found element is proof of presence
/// whatever the observation failed to cover.
///
/// A nil `matcher` is a query that can never match. After a successful fetch
/// and parse it returns empty before the response-note and truncation checks,
/// leaving the probe pending rather than classifying the observation as
/// unsupported or inconclusive. The capability check, the fetch, and the parse
/// run ahead of it and can still fail the wait.
private func observeAXMatches(
    entry: PanesListEntry,
    context: WaitEngine.ProbeContext,
    query: CLICommand.WaitAXQuery,
    matcher: WaitEngine.AXMatcher?,
    transport: CLITransport
) throws -> [[String: Any]] {
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
    guard let matcher else { return [] }
    let matches = WaitEngine.MatchRanking.ordered(
        matchingAXElements(in: root, matcher: matcher)
    )
    // A match wins, then incompleteness is explained. A found element is
    // proof of presence whatever the observation failed to cover.
    if !matches.isEmpty { return matches }
    // A recognized code wins; otherwise a recognized sentence provides the
    // fallback. Show the daemon's sentence when present, and the CLI's own
    // wording only when it sent none: a newer daemon's wording can carry
    // remediation advice this build predates, so substituting the compiled
    // string would quietly stale it.
    let daemonNote = root["note"] as? String
    let daemonNoteCode = root["noteCode"] as? String
    let note = daemonNoteCode.flatMap(AXTreeNote.init(code:))
        ?? daemonNote.flatMap(AXTreeNote.init(rawValue:))
    if note == .watchOSEnumerationUnsupported {
        let message = daemonNote ?? AXTreeNote.watchOSEnumerationUnsupported.rawValue
        throw WaitEngine.Failure(
            code: .waitUnsupported,
            message: message,
            exitCode: 1,
            details: waitDetails([
                "condition": "ax.appears",
                "source": query.source.rawValue,
                "note": message,
                "noteCode": daemonNoteCode ?? AXTreeNote.watchOSEnumerationUnsupported.code
            ])
        )
    }
    if query.source == .sweep, root["truncated"] as? Bool == true {
        // `truncated` is the coverage signal and the note rides along with
        // it. Pass both fields through as sent, synthesizing a code only
        // when the daemon supplied none, so an older response still gives
        // its caller something to branch on.
        var details: [String: Any] = [
            "condition": "ax.appears",
            "source": "sweep",
            "truncated": true
        ]
        if let daemonNote { details["note"] = daemonNote }
        if let code = daemonNoteCode ?? note?.code { details["noteCode"] = code }
        throw WaitEngine.Failure(
            code: .waitInconclusive,
            message: daemonNote ?? "AX sweep ended before covering the full grid",
            exitCode: 1,
            details: waitDetails(details)
        )
    }
    return []
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
    do {
        let completion = try runWait(
            pane: pane,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime,
            conditionProbe: conditionProbe
        )
        return try waitSuccessOutcome(completion, condition: condition, output: output)
    } catch let failure as WaitEngine.Failure {
        return waitFailureOutcome(failure, condition: condition)
    }
}

/// Probe until `conditionProbe` reports the condition holds, or the deadline
/// expires.
///
/// Resolves the pane on every probe rather than once, because a pane can
/// appear while the wait runs.
private func runWait(
    pane: String?,
    timeoutMs: Int,
    transport: CLITransport,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime,
    conditionProbe: (PanesListEntry, WaitEngine.ProbeContext) throws -> WaitEngine.ProbeResult
) throws -> WaitEngine.Completion {
    let credentials = try creds ?? readSessionCredentials()
    var resolvedPaneId: String?
    // Whether the *most recent* probe read a roster that named no pane the ref
    // matches. Cleared at the top of every probe, so a roster request that
    // exhausts the deadline reports the timeout that actually ended the wait
    // instead of a verdict drawn from an earlier roster. The last pane state
    // went unobserved in that case, and a pane may well have appeared in it.
    var lastProbeNamedNoPane = false
    do {
        return try WaitEngine.run(timeoutMs: timeoutMs, runtime: runtime) { context in
            lastProbeNamedNoPane = false
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
            let resolved: PanesListEntry?
            do {
                resolved = try resolveWaitPane(
                    ref: pane,
                    panes: panes,
                    resolvedPaneId: resolvedPaneId
                )
            } catch let CLIError.classified(code, message) {
                // Convert resolution errors to `WaitEngine.Failure` so the
                // wait envelope includes `condition`.
                throw WaitEngine.Failure(
                    code: code,
                    message: message,
                    exitCode: 1,
                    details: nil
                )
            }
            guard let entry = resolved else {
                lastProbeNamedNoPane = true
                return .pending
            }
            resolvedPaneId = entry.paneId
            return try conditionProbe(entry, context)
        }
        // A deadline reached with the last roster naming no matching pane is a
        // missing pane, not an unmet condition, and `wait.timeout` sends the
        // reader to inspect a condition that never had anything to hold.
        // Polling an unresolved ref is deliberate: a pane can appear mid-wait,
        // which is what lets a boot be followed by a wait on the pane it
        // creates. That is also why the ref can only be judged once the
        // deadline has passed, and only against a roster actually read.
    } catch let failure as WaitEngine.Failure
        where failure.code == .waitTimeout && resolvedPaneId == nil && lastProbeNamedNoPane {
        let details = failure.details.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        throw WaitEngine.Failure(
            code: .paneNotFound,
            message: unresolvedPaneMessage(
                ref: pane,
                exportedTarget: envValue(DeviceTermEnv.targetPane),
                attempts: details?["attempts"] as? Int
            ),
            exitCode: 1,
            details: failure.details
        )
    }
}

/// Render a wait failure, adding the `condition` every wait failure reports.
private func waitFailureOutcome(
    _ failure: WaitEngine.Failure,
    condition: String
) -> CommandOutcome {
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

/// The message a wait reports when its deadline passed without the pane ref
/// ever naming a pane.
///
/// Mirrors `resolvePane`'s three arms, so the same unmatched target reads the
/// same way whether a verb resolved it once or a wait polled it. Naming the
/// exported target matters most: an env key that matches nothing would
/// otherwise report an empty tab while other panes are listed right there.
///
/// `attempts` reports how many rosters were checked before the deadline.
///
/// `exportedTarget` is passed in rather than read here so the function stays
/// pure. Reading `DEVICETERM_TARGET_PANE` inside it would leave no way to
/// cover the arms except by mutating the process environment, which every
/// concurrently running wait test would then observe.
func unresolvedPaneMessage(ref: String?, exportedTarget: String?, attempts: Int?) -> String {
    let polled = attempts.map { " after \($0) attempts" } ?? ""
    if let ref, !ref.isEmpty {
        return "no pane matching '\(ref)' in this tab\(polled); run `deviceterm panes list`"
    }
    if let exportedTarget, !exportedTarget.isEmpty {
        return "no pane for exported target \(exportedTarget) in this tab\(polled)"
    }
    return "no device pane in this tab\(polled)"
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

/// Every element matching `matcher`, in depth-first discovery order.
///
/// The walk descends into a matched element rather than stopping there. A
/// control and the caption inside it routinely share a label, and the inner
/// one is the match a caller must not be handed silently, so both are
/// reported and `WaitEngine.MatchRanking` decides which leads.
private func matchingAXElements(
    in value: Any,
    matcher: WaitEngine.AXMatcher
) -> [[String: Any]] {
    var found: [[String: Any]] = []
    collectAXMatches(in: value, matcher: matcher, into: &found)
    return found
}

private func collectAXMatches(
    in value: Any,
    matcher: WaitEngine.AXMatcher,
    into found: inout [[String: Any]]
) {
    if let element = value as? [String: Any] {
        if matcher.matches(element) {
            // Without this the entries nest: a matched container already
            // carries every matched descendant, so the list would grow with
            // the tree rather than with the match count.
            var entry = element
            entry.removeValue(forKey: "children")
            found.append(entry)
        }
        if let children = element["children"] as? [Any] {
            for child in children {
                collectAXMatches(in: child, matcher: matcher, into: &found)
            }
        }
    } else if let values = value as? [Any] {
        for child in values {
            collectAXMatches(in: child, matcher: matcher, into: &found)
        }
    }
}

private func waitSuccessOutcome(
    _ completion: WaitEngine.Completion,
    condition: String,
    output: OutputMode
) throws -> CommandOutcome {
    switch output {
    case .human:
        // Only an AX wait observes a count; pane and orientation waits leave
        // the field out rather than reporting a meaningless 1.
        let matches = (completion.observation["matchCount"] as? Int).map { "matches=\($0) " } ?? ""
        return .stdout(
            "ok condition=\(condition) elapsedMs=\(completion.elapsedMs) "
                + "attempts=\(completion.attempts) \(matches)udid=\(completion.pane.udid) "
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

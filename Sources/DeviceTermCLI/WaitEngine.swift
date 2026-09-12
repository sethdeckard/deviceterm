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

    /// One accessibility probe's result: what matched, and whether the
    /// observation managed to see everything.
    ///
    /// Incompleteness travels as data rather than as a thrown failure because
    /// the two waits built on it disagree about what it means, and only they
    /// can decide. The failure is prepared here so that a caller which does
    /// surface it need not rebuild the details.
    struct AXObservation {
        /// Why an observation cannot support a claim about what it did *not*
        /// see.
        ///
        /// Three causes reach this, differing on whether this wait probes
        /// again. A family whose walk is unsupported never enumerates, so the
        /// remedy is another `--source`. A truncated sweep stops the wait by
        /// policy: the wait never varies the step or budget it was asked for,
        /// and caps each probe's budget at the time left, so no probe gets
        /// more to work with than the one before. A tree caught omitting an
        /// element says nothing about why, so this wait keeps probing in case
        /// a later one is complete.
        struct Incompleteness {
            let failure: Failure
            /// Whether this wait stops here rather than probing again.
            ///
            /// A policy, not a prediction. A truncated sweep may well finish
            /// on a quieter pane, which is why the daemon's own note suggests
            /// retrying; this wait still refuses to be the thing that retries
            /// it, and leaves that to the caller.
            let isTerminal: Bool
        }

        let matches: [[String: Any]]
        /// Non-nil when the observation is known not to have seen everything:
        /// enumeration unsupported for the family, a sweep that stopped short,
        /// or a tree caught omitting an element the daemon hit-tested.
        let incompleteness: Incompleteness?
    }

    /// The most recent accessibility observation a wait made, for classifying
    /// its deadline once the probe that took it has returned.
    ///
    /// A reference type so `runWait` can drop it at the top of every probe
    /// while the caller keeps reading it after the wait ends. That drop is the
    /// point: a probe that dies in one of its own requests produces no
    /// observation, and the window it failed to look at is exactly the one a
    /// verdict would be describing. `runWait` treats its own
    /// `lastProbeNamedNoPane` the same way, for the same reason.
    final class LastObservation {
        var matches: [[String: Any]] = []
        var incompleteness: Failure?

        func clear() {
            matches = []
            incompleteness = nil
        }
    }

    /// What a coordinate-target wait produced.
    ///
    /// Carries the pane the wait resolved alongside the element, because a
    /// caller acting on the coordinate has to act on the pane the element was
    /// observed in rather than resolve one of its own.
    struct AXTargetCompletion {
        let target: AXTarget
        let pane: PanesListEntry
        let matchCount: Int
        let elapsedMs: Int
    }

    /// A surface seen unchanged, and when that run started.
    ///
    /// `since` is the first sighting of this exact surface, not the latest,
    /// so the window measures how long it has held rather than resetting
    /// every probe.
    struct SurfaceHold {
        let paneId: String
        let surface: PanesListEntry.Surface
        let since: UInt64
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

    /// Prepares a `wait ax` query's selector and optional value filter once,
    /// ahead of the tree walk.
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
        /// Optional conjunct on the element's `value`, folded and compared
        /// under the same mode as the primary selector, because a value is
        /// app-authored text and carries the same counts and ellipses a
        /// label does.
        let value: String?

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
            needle = Self.folded(primary.needle, mode: query.matchMode)
            mode = query.matchMode
            role = query.role
            value = query.value.map { Self.folded($0, mode: query.matchMode) }
        }

        /// A needle prepared for `mode`: folded once for `contains`, left
        /// alone for `exact`.
        private static func folded(
            _ needle: String,
            mode: CLICommand.WaitAXMatchMode
        ) -> String {
            mode == .contains
                ? needle.folding(options: foldingOptions, locale: nil)
                : needle
        }

        func matches(_ element: [String: Any]) -> Bool {
            guard let candidate = element[attribute] as? String,
                textMatches(candidate, needle) else { return false }
            if let role, element["role"] as? String != role { return false }
            guard let value else { return true }
            // A non-string value never matches. The comparison is textual,
            // and a caller asking for one has a string in hand.
            guard let candidateValue = element["value"] as? String else { return false }
            return textMatches(candidateValue, value)
        }

        private func textMatches(_ candidate: String, _ folded: String) -> Bool {
            switch mode {
            case .exact:
                return candidate == folded

            case .contains:
                return candidate
                    .folding(options: Self.foldingOptions, locale: nil)
                    .contains(folded)
            }
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
        static func numeric(_ value: Any?) -> Double? {
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
    printMode: CLICommand.WaitAXPrint? = nil,
    state: CLICommand.WaitAXState = .present,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    if printMode != nil, output == .json {
        // `--json` promises stdout is a JSON document and `--print` promises
        // a bare coordinate. Refuse before any round-trip rather than pick
        // one, because the two also disagree on failure: a JSON failure
        // writes an envelope to stdout, where `--print` writes nothing.
        return .failure(
            code: .invalidUsage,
            message: "--print cannot be combined with --json"
        )
    }
    if printMode == .center {
        return try printAXTargetCentre(
            pane: pane,
            query: query,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime
        )
    }
    // Build the matcher once per wait: every probe uses the same prepared
    // selector and optional value filter.
    let matcher = WaitEngine.AXMatcher(query: query)
    if state == .absent {
        return try awaitAXAbsence(
            pane: pane,
            query: query,
            matcher: matcher,
            timeoutMs: timeoutMs,
            transport: transport,
            output: output,
            creds: creds,
            runtime: runtime
        )
    }
    return try awaitAXPresence(
        pane: pane,
        query: query,
        matcher: matcher,
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    )
}

/// Block until the query matches something.
///
/// A match wins over incompleteness. Presence is an existential claim, and a
/// found element proves it whatever the observation failed to cover: no amount
/// of unswept screen turns a sighting into an absence.
///
/// A deadline reached without a match is the other case. Nothing matched is a
/// claim about everything the observation covered, so when the last one could
/// not see the whole pane it reports that rather than the deadline. A bare
/// `wait.timeout` there would send the reader to inspect an app that may have
/// been drawing the element the whole time, in a tree that never published it.
///
/// A late match still wins. `WaitEngine.run` honours a probe that reported
/// `.satisfied` after the deadline, so incompleteness only ever stands in for a
/// wait that matched nothing.
private func awaitAXPresence(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    matcher: WaitEngine.AXMatcher?,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime
) throws -> CommandOutcome {
    let condition = "ax.appears"
    let last = WaitEngine.LastObservation()
    do {
        let completion = try runWait(
            pane: pane,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime,
            carrying: last
        ) { entry, context in
            let observed = try observeAXMatches(
                entry: entry,
                context: context,
                query: query,
                matcher: matcher,
                transport: transport
            )
            let matches = observed.matches
            guard !matches.isEmpty else {
                last.incompleteness = observed.incompleteness?.failure
                // An observation this wait will not probe again is reported
                // now. One it will keeps waiting, so a tree that is merely
                // part-way through gets the rest of the deadline to fill in.
                if let incompleteness = observed.incompleteness, incompleteness.isTerminal {
                    throw incompleteness.failure
                }
                return .pending
            }
            var observation: [String: Any] = [
                "source": query.source.rawValue,
                "matches": Array(matches.prefix(WaitEngine.maxReportedMatches)),
                "matchCount": matches.count
            ]
            // Present only when the list was trimmed, so a caller learns it
            // from the receipt instead of comparing `matchCount` against a cap
            // it can only read in prose.
            if matches.count > WaitEngine.maxReportedMatches {
                observation["matchesTruncated"] = true
            }
            return .satisfied(pane: entry, observation: observation)
        }
        return try waitSuccessOutcome(completion, condition: condition, output: output)
    } catch let failure as WaitEngine.Failure where failure.code == .waitTimeout {
        return waitFailureOutcome(last.incompleteness ?? failure, condition: condition)
    } catch let failure as WaitEngine.Failure {
        return waitFailureOutcome(failure, condition: condition)
    }
}

/// Block until the query matches nothing.
///
/// Presence is an existential claim: something matched. Absence is a universal
/// one: nothing did. A partial observation is sufficient evidence for the
/// first and structurally insufficient for the second, which is why this wait
/// sits with selection rather than with presence. An element missing from a
/// truncated sweep may sit in an unswept cell, and one missing from a tree the
/// daemon caught omitting something may be the very thing omitted. Either way
/// the query matching nothing is not the element being gone.
///
/// Read the other way, a sighting is existential evidence, so nothing unseen
/// can touch it and the still-present path stays an ordinary deadline.
private func awaitAXAbsence(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    matcher: WaitEngine.AXMatcher?,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime
) throws -> CommandOutcome {
    let condition = "ax.disappears"
    // Carried so a deadline reached on an observation that could not see
    // everything reports that, rather than reporting absence was never
    // achieved.
    let last = WaitEngine.LastObservation()
    do {
        let completion = try runWait(
            pane: pane,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime,
            carrying: last
        ) { entry, context in
            let observed = try observeAXMatches(
                entry: entry,
                context: context,
                query: query,
                matcher: matcher,
                transport: transport
            )
            guard observed.matches.isEmpty else {
                // Still there, and seen to be. Any incompleteness the same
                // observation reported says nothing about a match in hand, so
                // it stays dropped.
                return .pending
            }
            last.incompleteness = observed.incompleteness?.failure
            if let incompleteness = observed.incompleteness {
                // Report it now when this wait will not probe again;
                // otherwise keep going and let the deadline report it.
                if incompleteness.isTerminal { throw incompleteness.failure }
                return .pending
            }
            return .satisfied(
                pane: entry,
                observation: [
                    "source": query.source.rawValue,
                    // Empty rather than absent. Both directions of `wait ax`
                    // publish the same observation shape, so a caller reading
                    // `matches` does not have to branch on the condition
                    // first to know whether the key is there.
                    "matches": [[String: Any]](),
                    "matchCount": 0
                ]
            )
        }
        return try waitSuccessOutcome(completion, condition: condition, output: output)
    } catch let failure as WaitEngine.Failure where failure.code == .waitTimeout {
        return waitFailureOutcome(last.incompleteness ?? failure, condition: condition)
    } catch let failure as WaitEngine.Failure {
        return waitFailureOutcome(failure, condition: condition)
    }
}

/// Block until the query names one eligible coordinate target, then write
/// its centre to stdout and nothing else.
///
/// Bare `<x> <y>` so the result can be passed as a coordinate verb's two
/// positional arguments, with no receipt to strip first.
///
/// A refusal emits no coordinate for an argument-forwarding caller to pass to
/// `tap`, because it must never be handed one the selection did not make.
private func printAXTargetCentre(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int,
    transport: CLITransport,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime
) throws -> CommandOutcome {
    do {
        let result = try awaitAXTarget(
            pane: pane,
            query: query,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime
        )
        // Fixed notation, not `String(_:)`: the shortest round-trip spelling
        // of a small coordinate is exponential ("5e-05"), which standard
        // `bc` downstream cannot read.
        return .stdout(
            String(format: "%.6f %.6f\n", result.target.x, result.target.y)
        )
    } catch let failure as WaitEngine.Failure {
        return waitFailureOutcome(failure, condition: "ax.appears")
    }
}

/// Block until the query names one eligible coordinate target, then tap its
/// centre in the pane the wait resolved.
///
/// One command where a caller would otherwise pipe a coordinate through the
/// shell, so no coordinate crosses that boundary and the whole locate-and-tap
/// fits one approval prefix.
///
/// The tap goes to `result.pane`, not through `sendResolved`, which would ask
/// for the roster a second time and could land on a pane other than the one
/// observed.
///
/// A refusal sends no tap. `wait.unreachable`, `wait.ambiguous`, and
/// `wait.inconclusive` all end the command with nothing dispatched, so a query
/// that named the wrong thing, or an observation that could not prove it named
/// one thing, costs an exit code rather than an input the caller cannot take
/// back.
func handleTapElement(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    let result: WaitEngine.AXTargetCompletion
    do {
        result = try awaitAXTarget(
            pane: pane,
            query: query,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime
        )
    } catch let failure as WaitEngine.Failure {
        return waitFailureOutcome(failure, condition: "ax.appears")
    }
    _ = try transport.send(
        try CLICommands.tapRequest(
            paneId: result.pane.paneId,
            x: result.target.x,
            y: result.target.y
        ),
        timeoutSeconds: AppCommandDeadline.cliRequestTimeoutSeconds
    )
    switch output {
    case .human:
        return .stdout(
            Echo.ok(
                udid: result.pane.udid,
                pane: result.pane.shortId ?? result.pane.paneId,
                fields: tapElementEchoFields(result)
            ) + "\n"
        )

    case .json:
        return .stdout(
            try encodeJSONReceipt(
                Receipt.Tap(
                    udid: result.pane.udid,
                    paneId: result.pane.paneId,
                    shortId: result.pane.shortId,
                    x: result.target.x,
                    y: result.target.y,
                    role: result.target.role,
                    label: result.target.label,
                    identifier: result.target.identifier,
                    matchCount: result.matchCount,
                    elapsedMs: result.elapsedMs
                )
            )
        )
    }
}

/// The per-command fields on a selector-driven tap's echo line.
///
/// The label and identifier stay out of it. The line is space-separated
/// `key=value` and reading it by column position is a documented property, so
/// a label like `Continue with Apple` would shift every field after it. Both
/// are in the `--json` receipt, which has somewhere to put a space.
///
/// The role is normally a single word, and is dropped rather than printed
/// when it isn't, since the vocabulary comes from private frameworks and this
/// line has no quoting to fall back on. An absent `role=` is something a
/// reader can see; a shifted column is not.
private func tapElementEchoFields(
    _ result: WaitEngine.AXTargetCompletion
) -> [(String, String)] {
    var fields = [
        ("x", String(format: "%.6f", result.target.x)),
        ("y", String(format: "%.6f", result.target.y))
    ]
    if let role = result.target.role, !role.contains(where: \.isWhitespace) {
        fields.append(("role", role))
    }
    fields.append(("matches", String(result.matchCount)))
    return fields
}

/// Block until `query` names exactly one eligible coordinate target.
///
/// The single place a query becomes a coordinate, so `wait ax --print center`
/// and `tap` cannot come to disagree about which element a query means.
///
/// A match list without a unique target leaves the wait pending rather than
/// failing on the probe that saw it: a control still sliding in has a valid
/// frame and a briefly off-screen centre, which is the transient a wait verb
/// exists to absorb. The deadline then classifies what the last observation
/// held.
///
/// An observation that did not see everything never selects, whatever it
/// matched. Unsupported enumeration and a truncated sweep both fail on the
/// probe that saw them, the first because it cannot succeed and the second
/// because this wait never varies the step or budget it was given. A tree
/// caught omitting one element keeps waiting instead, since the note does not
/// say whether the omission is transient, and the deadline reports it if it
/// persists.
private func awaitAXTarget(
    pane: String?,
    query: CLICommand.WaitAXQuery,
    timeoutMs: Int,
    transport: CLITransport,
    creds: (sessionId: String, cap: String)?,
    runtime: WaitEngine.Runtime
) throws -> WaitEngine.AXTargetCompletion {
    // Built once per wait: every probe uses the same prepared selector and
    // optional value filter.
    let matcher = WaitEngine.AXMatcher(query: query)
    // Carried so a refusal can describe the observation the deadline ended on,
    // which the probe itself has no way to return.
    let last = WaitEngine.LastObservation()
    var selected: AXTarget?
    do {
        let completion = try runWait(
            pane: pane,
            timeoutMs: timeoutMs,
            transport: transport,
            creds: creds,
            runtime: runtime,
            carrying: last
        ) { entry, context in
            let observed = try observeAXMatches(
                entry: entry,
                context: context,
                query: query,
                matcher: matcher,
                transport: transport
            )
            last.matches = observed.matches
            last.incompleteness = observed.incompleteness?.failure
            // Every verdict below is a claim about what did *not* match, and
            // anything the observation missed refutes all of them: it can hold
            // a second control that would have made a target ambiguous, the
            // real control behind a caption, or the intermediate frame that
            // turns two disjoint candidates into a containment chain. So an
            // incomplete observation answers before selection does, whatever
            // it managed to match. A tree whose walk never ran still carries
            // its root, and a root can match a selector and carry a centre.
            if let incompleteness = observed.incompleteness {
                // Report it now when this wait will not probe again;
                // otherwise keep going and let the deadline report it.
                if incompleteness.isTerminal { throw incompleteness.failure }
                return .pending
            }
            guard case let .target(target) = AXTarget.select(from: observed.matches) else {
                return .pending
            }
            selected = target
            return .satisfied(pane: entry, observation: [:])
        }
        // `runWait` returns only for a probe that reported `.satisfied`, and
        // this probe reports it only after assigning `selected`.
        guard let selected else {
            throw CLIError.invalidResponse("wait ax reported a target it had not selected")
        }
        return WaitEngine.AXTargetCompletion(
            target: selected,
            pane: completion.pane,
            matchCount: last.matches.count,
            elapsedMs: completion.elapsedMs
        )
    } catch let failure as WaitEngine.Failure where failure.code == .waitTimeout {
        throw axSelectionFailure(
            from: last.matches,
            incompleteness: last.incompleteness
        ) ?? failure
    }
}

/// Reclassify a deadline according to what the last observation held.
///
/// Nil when nothing matched and the observation was complete, leaving the
/// deadline to report itself: there was no element to reach or to choose
/// between, and nothing went unseen that might have held one.
///
/// An observation that did not see everything outranks every verdict below it,
/// including the deadline. Each of those verdicts asserts something about what
/// did not match, which is exactly what such an observation cannot support.
private func axSelectionFailure(
    from matches: [[String: Any]],
    incompleteness: WaitEngine.Failure?
) -> WaitEngine.Failure? {
    if let incompleteness { return incompleteness }
    guard !matches.isEmpty else { return nil }
    let roles = Array(Set(matches.compactMap { $0["role"] as? String })).sorted()
    switch AXTarget.select(from: matches) {
    case .target:
        // Selection succeeded on the last observation but the deadline had
        // already passed. Report the deadline: no coordinate was printed.
        return nil

    case .unreachable:
        return WaitEngine.Failure(
            code: .waitUnreachable,
            message: "matched \(matches.count) element(s), none eligible as a coordinate target",
            exitCode: 1,
            details: waitDetails([
                "matchCount": matches.count,
                "roles": roles
            ])
        )

    case let .ambiguous(candidates):
        return WaitEngine.Failure(
            code: .waitAmbiguous,
            message: "matched \(candidates.count) unrelated elements; "
                + "narrow with --role, --value, or --identifier",
            exitCode: 1,
            details: waitDetails([
                "matchCount": matches.count,
                "candidateCount": candidates.count,
                "roles": roles
            ])
        )
    }
}

/// One accessibility observation of `entry`, reduced to the elements
/// `matcher` selects and ranked so the most operable comes first.
///
/// Empty matches mean the probe found nothing and the wait should keep going.
/// Partial coverage rides back beside them rather than being thrown, because
/// what it means depends on the question the caller asked, and only the caller
/// knows that.
///
/// An observation that failed outright still throws: a pane without
/// accessibility, and a response that will not parse. Unsupported enumeration
/// comes back as incompleteness instead, beside whatever the root itself
/// matched, because a caller asking only whether something is present is
/// answered by that root.
///
/// A nil `matcher` is a query that can never match. After a successful fetch
/// and parse it returns empty before the response-note check, leaving the probe
/// pending rather than classifying the observation as unsupported. The
/// capability check, the fetch, and the parse run ahead of it and can still
/// fail the wait.
private func observeAXMatches(
    entry: PanesListEntry,
    context: WaitEngine.ProbeContext,
    query: CLICommand.WaitAXQuery,
    matcher: WaitEngine.AXMatcher?,
    transport: CLITransport
) throws -> WaitEngine.AXObservation {
    if entry.capabilities?.accessibility == false {
        throw WaitEngine.Failure(
            code: .waitUnsupported,
            message: "accessibility observation is unavailable for this pane",
            exitCode: 1,
            details: waitDetails([
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
    guard let matcher else {
        return WaitEngine.AXObservation(matches: [], incompleteness: nil)
    }
    let matches = WaitEngine.MatchRanking.ordered(
        matchingAXElements(in: root, matcher: matcher)
    )
    // A recognized code wins; otherwise a recognized sentence provides the
    // fallback. Show the daemon's sentence when present, and the CLI's own
    // wording only when it sent none: a newer daemon's wording can carry
    // remediation advice this build predates, so substituting the compiled
    // string would quietly stale it.
    let daemonNote = root["note"] as? String
    let daemonNoteCode = root["noteCode"] as? String
    let note = daemonNoteCode.flatMap(AXTreeNote.init(code:))
        ?? daemonNote.flatMap(AXTreeNote.init(rawValue:))
    return WaitEngine.AXObservation(
        matches: matches,
        incompleteness: observationIncompleteness(
            root: root,
            query: query,
            note: daemonNote,
            noteCode: daemonNoteCode ?? note?.code,
            treeNote: note
        )
    )
}

/// Why an observation cannot speak for what it did not see, or nil when it saw
/// everything it set out to.
///
/// Built rather than thrown because the same fact answers different questions
/// differently. A wait for presence is satisfied by any match, whatever went
/// unseen. A wait for a single coordinate target is not: every verdict
/// selection can reach is a claim about what did *not* match, and anything the
/// observation missed refutes all of them.
///
/// Three causes, ordered so the widest is tested first: enumeration that never
/// ran outranks a sweep that stopped short, which outranks a tree caught
/// missing one element.
///
/// The daemon's note becomes the message and its code rides in `details`, both
/// as sent, with a code synthesized only when the daemon supplied none, so an
/// older response still gives its caller something to branch on.
private func observationIncompleteness(
    root: [String: Any],
    query: CLICommand.WaitAXQuery,
    note: String?,
    noteCode: String?,
    treeNote: AXTreeNote?
) -> WaitEngine.AXObservation.Incompleteness? {
    var details: [String: Any] = [
        "source": query.source.rawValue
    ]
    if let noteCode { details["noteCode"] = noteCode }
    let code: CLIErrorCode
    let message: String
    let isTerminal: Bool
    if treeNote == .watchOSEnumerationUnsupported {
        // The walk does not run on this family at all, so the remedy is a
        // different `--source`, never more time. The tree still carries its
        // root, which can match a selector and carries a centre of its own, so
        // a caller asking for a coordinate has to be refused on the note
        // rather than on whether anything matched.
        code = .waitUnsupported
        message = note ?? AXTreeNote.watchOSEnumerationUnsupported.rawValue
        isTerminal = true
        details["note"] = message
        details["noteCode"] = noteCode ?? AXTreeNote.watchOSEnumerationUnsupported.code
    } else if query.source == .sweep, root["truncated"] as? Bool == true {
        code = .waitInconclusive
        message = note ?? "AX sweep ended before covering the full grid"
        // Terminal by policy. This wait never varies the requested step or
        // budget, and caps each probe's budget at the time left, so no probe
        // gets more than the one before. A fresh call with a larger budget, a
        // coarser step, or a quieter pane may well finish, and that call is
        // the caller's.
        isTerminal = true
        if let note { details["note"] = note }
        details["truncated"] = true
        // Forward the coverage count and the applied sweep settings so a
        // caller can act on the truncation note from the failure receipt.
        if let swept = root["sweepedPoints"] { details["sweepedPoints"] = swept }
        if let step = root["step"] { details["step"] = step }
        if let budgetMs = root["budgetMs"] { details["budgetMs"] = budgetMs }
    } else if treeNote == .treeIncomplete {
        code = .waitInconclusive
        message = note ?? "the accessibility tree omitted an element that is on screen"
        // The note does not say why the tree is short, so a later probe may
        // see a complete one.
        isTerminal = false
        if let note { details["note"] = note }
    } else {
        return nil
    }
    return WaitEngine.AXObservation.Incompleteness(
        failure: WaitEngine.Failure(
            code: code,
            message: message,
            exitCode: 1,
            details: waitDetails(details)
        ),
        isTerminal: isTerminal
    )
}

/// Block until the pane's rendered surface has held still for `settleMs`.
///
/// Stillness is the surface being *unchanged*, never advanced by some
/// amount. The increment is backend-dependent: a Simulator bumps the
/// sequence by one per frame, a physical device reports lease generations
/// that jump, so a delta means nothing across both.
///
/// Width and height join the sequence in the comparison. A resize produces
/// new frames anyway, so this rarely differs, and the receipt reports the
/// dimensions it settled on: a caller reading them should know they were
/// stable for the whole window rather than merely current at the end.
///
/// The probe cadence is 100 ms, so two consecutive observations prove only
/// about that much stillness. `--settle` is what makes the window a
/// caller's choice instead of the engine's.
func handleWaitSurfaceQuiescent(
    pane: String?,
    settleMs: Int,
    timeoutMs: Int,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil,
    runtime: WaitEngine.Runtime = .live
) throws -> CommandOutcome {
    // Saturating, the same way the overall deadline converts. The parser
    // admits any non-negative `Int`, and a plain multiply traps well before
    // `Int.max`. A saturated window simply never elapses, so an absurd
    // `--settle` reaches the deadline instead of killing the process.
    let converted = UInt64(clamping: settleMs).multipliedReportingOverflow(by: 1_000_000)
    let settleNanoseconds = converted.overflow ? UInt64.max : converted.partialValue
    var held: WaitEngine.SurfaceHold?
    return try handleWait(
        pane: pane,
        condition: "surface.quiescent",
        timeoutMs: timeoutMs,
        transport: transport,
        output: output,
        creds: creds,
        runtime: runtime
    ) { entry, context in
        // No surface means nothing has been drawn, which is not the same as
        // being still. Waiting for a first frame is `wait pane rendering`.
        guard let surface = entry.surface else {
            held = nil
            return .pending
        }
        let now = context.runtime.nowNanoseconds()
        guard let held, held.paneId == entry.paneId, held.surface == surface else {
            // Either the first sighting or a change. Both start the window
            // over, so a surface that keeps moving never accumulates one.
            held = WaitEngine.SurfaceHold(
                paneId: entry.paneId,
                surface: surface,
                since: now
            )
            return .pending
        }
        guard now >= held.since, now - held.since >= settleNanoseconds else {
            return .pending
        }
        return .satisfied(
            pane: entry,
            observation: [
                "surface": [
                    "sequence": surface.sequence,
                    "width": surface.width,
                    "height": surface.height
                ],
                "settleMs": settleMs
            ]
        )
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
                details: waitDetails([:])
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
    carrying last: WaitEngine.LastObservation? = nil,
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
            // An observation a caller carries goes stale on the same terms, so
            // it is dropped here rather than where it was set. Either request
            // below can consume the deadline, and a probe that dies in one
            // produces no observation to classify it with.
            last?.clear()
            let request = try CLICommands.paneDeviceListRequest(
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
        return "no pane matching '\(ref)' in this tab\(polled); run `deviceterm pane list`"
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
        // Only an AX wait observes a count; every other wait leaves the
        // field out rather than reporting a meaningless 1.
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

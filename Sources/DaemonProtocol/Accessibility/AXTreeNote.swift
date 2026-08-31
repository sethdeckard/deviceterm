// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finite wire-value vocabulary for the optional `note` field the daemon may
/// inject into an `ax tree` or `ax sweep` response when the result on its own
/// would read as more complete than it is.
///
/// Both verbs answer under the same `tree` key and carry the note in the same
/// place, so one vocabulary covers them: a client decoding `tree["note"]` gets
/// an `AXTreeNote` whichever verb it called. The cases say which verb they
/// come from, since a note only ever accompanies the result that raised it.
///
/// Lives in `DaemonProtocol` so agent-side decoders can pattern-match the enum
/// instead of doing string compares.
///
/// The raw value is the sentence to show a person. `code` is the short stable
/// token to branch on, written to `tree["noteCode"]` beside the sentence, and
/// `init(code:)` reads it back. Identify a note by its code: a rewording
/// changes the sentence and leaves the code alone. Unknown-key-tolerant on the
/// wire, so a client that decodes neither still sees plain strings at both
/// keys.
public enum AXTreeNote: String, Codable, Sendable, Equatable, CaseIterable {
    /// watchOS's `AXPMacPlatformElement.accessibilityChildren` returns
    /// empty regardless of on-screen state, so the recursive walk
    /// produces a `{"children": []}` tree, which is indistinguishable from a
    /// legitimately empty one. Agents enumerate the
    /// screen via `deviceterm ax sweep` (grid-walks `objectAtPoint:`),
    /// or resolve a single point with `deviceterm ax point <x> <y>`.
    case watchOSEnumerationUnsupported =
        // swiftlint:disable:next line_length
        "AX tree enumeration is unsupported on watchOS; use 'deviceterm ax sweep' to grid-walk via objectAtPoint, or 'deviceterm ax point <x> <y>' for a single element"

    /// Hit-testing one point the walk left uncovered returned an element the
    /// walk never produced, so the tree describes less than the screen holds
    /// and an element's absence from it proves nothing.
    ///
    /// Named for the evidence rather than a cause. The observed case is a web
    /// view: `AXPMacPlatformElement.accessibilityChildren` does not cross into
    /// `WKWebView`'s out-of-process subtree, so Safari's tree stops at its own
    /// chrome while `objectAtPoint:` reaches the page. That is what motivated
    /// the note, not the limit of what it detects, and a name like
    /// "web content" would have callers reading a diagnosis into a screen that
    /// is thin for some other reason.
    ///
    /// Only a positive finding earns this. A point the hit-test declines, and
    /// one that answers with an element the tree already carries, both leave
    /// the response unannotated: under-reporting leaves a successful tree
    /// response as it stands, while a note on a healthy screen sends a caller
    /// to a sweep it does not need.
    case treeIncomplete =
        // swiftlint:disable:next line_length
        "hit-testing found an element this tree does not contain, so the walk did not reach everything on screen; use 'deviceterm ax sweep' to grid-walk via objectAtPoint, or 'deviceterm ax point <x> <y>' for a single element"

    /// The sweep's budget went before it finished its grid, so `children`
    /// covers part of the screen and an element's absence proves nothing.
    /// The finest legal step plans enough cells to exhaust the default budget
    /// on an ordinary host, which is why a caller reads `truncated` rather
    /// than assuming the step it asked for was walked.
    ///
    /// Static, like the case above. `truncated`, `sweepedPoints`, `step`, and
    /// the echoed `budgetMs` report what was asked for and what was reached;
    /// interpolating a suggested budget would put an estimate in among them.
    /// Nothing here yields bridge throughput to base one on: `budgetMs` is a
    /// limit that the wait for the pane's queue also spends, and a completed
    /// sweep reports no elapsed time at all.
    case sweepTruncated =
        // swiftlint:disable:next line_length
        "the sweep stopped at its time budget with part of the grid unqueried; 'sweepedPoints' counts what it reached, and 'deviceterm ax sweep --budget <ms>' buys a longer walk"

    /// Same truncation, reached at `AXSweepBudget.maxMs`, where the advice
    /// above is a dead end: there is no larger budget to ask for. A sweep can
    /// land here two ways, and both are worth trying. The grid may genuinely
    /// cost more than the ceiling on this host, which a coarser `--step`
    /// fixes. Or the ceiling went waiting for the pane's accessibility queue
    /// behind another read, which nothing about this request can fix and a
    /// retry can.
    ///
    /// A separate case rather than a longer sentence on the one above,
    /// because an agent branches differently on the two: raising a number it
    /// already maxed out is the one response that cannot work.
    case sweepTruncatedAtMaxBudget =
        // swiftlint:disable:next line_length
        "the sweep stopped at the largest budget the daemon allows with part of the grid unqueried; 'sweepedPoints' counts what it reached, so widen 'deviceterm ax sweep --step <0..1>' or retry when the pane is serving fewer accessibility reads"

    /// Short, stable token naming this note, for clients that branch on it.
    ///
    /// The raw values are whole sentences, so a JSON client with only `note`
    /// must compare the entire sentence to tell `sweepTruncated` from
    /// `sweepTruncatedAtMaxBudget`. Those are separate cases precisely so a
    /// caller can branch, since at the ceiling "raise `--budget`" is the one
    /// remedy that cannot work, and an error code alone does not separate
    /// them. This is the identity to compare; the raw value is the sentence
    /// to show a human.
    ///
    /// Stable in the same way the raw values are: rewording a sentence leaves
    /// its code alone, and changing a code is a deliberate wire change.
    public var code: String {
        switch self {
        case .watchOSEnumerationUnsupported:
            "ax.watchOSEnumerationUnsupported"

        case .treeIncomplete:
            "ax.treeIncomplete"

        case .sweepTruncated:
            "ax.sweepTruncated"

        case .sweepTruncatedAtMaxBudget:
            "ax.sweepTruncatedAtMaxBudget"
        }
    }

    /// The note a `code` names, or nil when it is unknown.
    ///
    /// When `noteCode` is absent, fall back to `init(rawValue:)` for
    /// compatibility with older daemons.
    public init?(code: String) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// Which truncation note a sweep gets, given the budget it ran under.
    ///
    /// Kept pure so the max-budget branch can be tested without spending
    /// `AXSweepBudget.maxMs` of wall clock to reach it. `AXTreeAnnotator` is
    /// split out of the tree walk for the same reason.
    ///
    /// `>=` rather than `==` so an over-ceiling budget still lands on the
    /// note that doesn't tell its caller to raise one. The daemon clamps
    /// before calling this; the comparison covers any caller that doesn't.
    public static func forTruncatedSweep(budgetMs: Int) -> AXTreeNote {
        budgetMs >= AXSweepBudget.maxMs ? .sweepTruncatedAtMaxBudget : .sweepTruncated
    }
}

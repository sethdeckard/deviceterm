// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The element a coordinate-driven accessibility command acts on.
///
/// `WaitEngine.MatchRanking` orders candidates but never refuses one, so a
/// list whose only centre-bearing entry is a caption still has a `matches[0]`.
/// Selection asks the stricter question, once, so every caller that turns a
/// query into a coordinate answers it the same way.
struct AXTarget: Equatable, Sendable {
    /// What selection concluded about a ranked match list.
    ///
    /// `ambiguous` carries its candidates so the failure can report how many
    /// eligible candidates remain. It is a separate outcome from
    /// `unreachable` because the two ask different things of the caller:
    /// narrow the query, or accept that no match is eligible as a coordinate
    /// target.
    enum Selection: Equatable {
        case target(AXTarget)
        case unreachable
        case ambiguous([AXTarget])
    }

    /// A displayed-space rectangle, in points.
    ///
    /// Its own type rather than `CGRect` because this target links Foundation
    /// alone, and containment needs nothing CoreGraphics would add.
    struct Frame: Equatable, Sendable {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    /// Frames within this many displayed points still count as contained.
    ///
    /// Layout rounding can put a caption a fraction outside the control that
    /// owns it, which would otherwise read as two disjoint elements and be
    /// refused.
    static let containmentEpsilon = 1.0

    /// Normalized displayed-space centre, ready for a coordinate verb.
    let x: Double
    let y: Double
    let role: String?
    let label: String?
    let identifier: String?

    /// Nil when the element carries no usable `normalizedCenter`.
    init?(element: [String: Any]) {
        guard let centre = Self.normalizedCentre(of: element) else { return nil }
        x = centre.x
        y = centre.y
        role = element["role"] as? String
        label = element["label"] as? String
        identifier = element["identifier"] as? String
    }

    /// Reduce a ranked match list to the one element a coordinate verb should
    /// target.
    ///
    /// Three steps. Discard anything presentational or lacking a centre. A
    /// centreless element supplies no ready coordinate; a presentational one is
    /// excluded so a caption never stands in for the control wrapping it,
    /// even though a caption often carries a perfectly good centre. If what remains nests,
    /// take the innermost, which is the control rather than the container
    /// holding it. If it does not nest, refuse.
    ///
    /// Nesting is tested by frame containment rather than by position in the
    /// walk. `ax sweep` returns every element as a sibling of a synthetic
    /// root, so a structural test would call every multi-match sweep disjoint
    /// and refuse it. Containment also describes the relationship being
    /// detected more directly: a caption inside its button is inside it
    /// whether or not the walk reports the two as related.
    ///
    /// Refusing on disjoint candidates is a choice, not a deduction. Two
    /// unrelated controls matching one query is a query that named two
    /// things, and nothing in the observation says which was meant.
    ///
    /// What survives selection is reachable by coordinate, not necessarily
    /// operable: the observation cannot say whether an element is enabled,
    /// obscured, or behind a modal.
    static func select(from ranked: [[String: Any]]) -> Selection {
        let eligible = ranked.filter(isEligibleTarget)
        guard !eligible.isEmpty else { return .unreachable }
        guard let innermost = innermostOfChain(eligible),
            let target = AXTarget(element: innermost) else {
            return .ambiguous(eligible.compactMap(AXTarget.init(element:)))
        }
        return .target(target)
    }

    /// Whether an element is eligible to be a coordinate target.
    ///
    /// Two separate tests. The role test is a policy: a caption may carry a
    /// perfectly good centre, and is excluded anyway so it never stands in
    /// for the control wrapping it. The centre test is a fact: a coordinate
    /// verb has nothing to send without one.
    ///
    /// Neither says whether the element is enabled or unobscured.
    static func isEligibleTarget(_ element: [String: Any]) -> Bool {
        guard !WaitEngine.MatchRanking.presentationalRoles
            .contains(element["role"] as? String ?? "") else { return false }
        return normalizedCentre(of: element) != nil
    }

    /// The innermost element when `elements` form a containment chain, or
    /// nil when they do not.
    ///
    /// Sorting by descending area puts a container ahead of anything it could
    /// contain, then each adjacent pair is checked. That establishes a chain
    /// rather than containment between every pair: the epsilon tolerance does
    /// not compose, so the outermost frame need not contain the innermost
    /// within a single epsilon. The innermost is still the most specific
    /// element, which is what selection needs.
    ///
    /// An element with no usable frame cannot be placed in that order, so a
    /// set containing one never chains.
    static func innermostOfChain(_ elements: [[String: Any]]) -> [String: Any]? {
        guard elements.count > 1 else { return elements.first }
        let sized = elements.compactMap { element -> ([String: Any], Double)? in
            WaitEngine.MatchRanking.area(of: element).map { (element, $0) }
        }
        guard sized.count == elements.count else { return nil }
        let ordered = sized.sorted { $0.1 > $1.1 }
        for (outer, inner) in zip(ordered, ordered.dropFirst())
        where !contains(outer.0, inner.0) {
            return nil
        }
        return ordered.last?.0
    }

    /// Whether `inner`'s frame lies inside `outer`'s, within
    /// `containmentEpsilon`.
    static func contains(_ outer: [String: Any], _ inner: [String: Any]) -> Bool {
        guard let outerFrame = frame(of: outer), let innerFrame = frame(of: inner) else {
            return false
        }
        let epsilon = containmentEpsilon
        return innerFrame.minX >= outerFrame.minX - epsilon
            && innerFrame.minY >= outerFrame.minY - epsilon
            && innerFrame.maxX <= outerFrame.maxX + epsilon
            && innerFrame.maxY <= outerFrame.maxY + epsilon
    }

    /// The element's displayed-space frame, or nil when any component is
    /// missing or not a number.
    static func frame(of element: [String: Any]) -> Frame? {
        guard let frame = element["frame"] as? [String: Any],
            let x = WaitEngine.MatchRanking.numeric(frame["x"]),
            let y = WaitEngine.MatchRanking.numeric(frame["y"]),
            let width = WaitEngine.MatchRanking.numeric(frame["w"]),
            let height = WaitEngine.MatchRanking.numeric(frame["h"])
        else { return nil }
        return Frame(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    /// The element's `normalizedCenter` as a pair, or nil when the daemon
    /// omitted it or sent something other than two numbers.
    static func normalizedCentre(of element: [String: Any]) -> (x: Double, y: Double)? {
        guard let centre = element["normalizedCenter"] as? [String: Any],
            let x = WaitEngine.MatchRanking.numeric(centre["x"]),
            let y = WaitEngine.MatchRanking.numeric(centre["y"])
        else { return nil }
        return (x, y)
    }
}

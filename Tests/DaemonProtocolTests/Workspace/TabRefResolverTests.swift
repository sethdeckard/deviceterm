// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// TabRefResolver: `--tab <ref>` resolution priority:
//   short_id → name → UUID prefix → sentinel
//
// Each tier returns the most-specific match; ambiguity within a tier
// surfaces as `.ambiguous`; sentinels are the lowest-priority
// fallback so a literal tab named "current" shadows the keyword.

// MARK: - Fixtures

private let alpha = TabsListEntry(
    sessionId: "11111111-1111-1111-1111-111111111111",
    label: "Alpha",
    shortId: "ab12cd",
    name: "alpha"
)

private let beta = TabsListEntry(
    sessionId: "22222222-2222-2222-2222-222222222222",
    label: nil,
    shortId: "ef34gh",
    name: "beta"
)

private let unnamed = TabsListEntry(
    sessionId: "33333333-3333-3333-3333-333333333333",
    label: nil,
    shortId: "xy56zw",
    name: nil
)

private let fixtures = [alpha, beta, unnamed]

// MARK: - Short ID tier

@Test
func shortIdMatchWinsOverEverything() {
    if case let .entry(matched) = TabRefResolver.resolve("ab12cd", in: fixtures) {
        #expect(matched == alpha)
    } else {
        Issue.record("expected .entry, got \(TabRefResolver.resolve("ab12cd", in: fixtures))")
    }
}

@Test
func shortIdMatchIsCaseSensitive() {
    // Daemon emits lowercased Crockford; uppercase isn't a match.
    let result = TabRefResolver.resolve("AB12CD", in: fixtures)
    if case .entry = result {
        Issue.record("uppercase short_id should not match; got \(result)")
    }
}

// MARK: - Name tier

@Test
func nameMatchWinsWhenNoShortIdMatch() {
    if case let .entry(matched) = TabRefResolver.resolve("alpha", in: fixtures) {
        #expect(matched == alpha)
    } else {
        Issue.record("expected name match for 'alpha'")
    }
}

@Test
func nameMatchHandlesAmbiguity() {
    let duplicate = TabsListEntry(
        sessionId: "44444444-4444-4444-4444-444444444444",
        label: nil,
        shortId: "uvwxyz",
        name: "alpha"
    )
    let result = TabRefResolver.resolve("alpha", in: fixtures + [duplicate])
    guard case let .ambiguous(matches) = result else {
        Issue.record("expected .ambiguous, got \(result)")
        return
    }
    #expect(matches.count == 2)
}

@Test
func nameMatchDeduplicatesSessionsInTheSameTab() {
    let primary = TabsListEntry(
        sessionId: "44444444-4444-4444-4444-444444444441",
        label: nil,
        tabId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        shortId: "split1",
        name: "shared"
    )
    let split = TabsListEntry(
        sessionId: "44444444-4444-4444-4444-444444444442",
        label: nil,
        tabId: primary.tabId,
        shortId: "split2",
        name: "shared"
    )

    #expect(TabRefResolver.resolve("shared", in: [primary, split]) == .entry(primary))
}

// MARK: - UUID prefix tier

@Test
func uuidPrefixMatchWinsWhenLongEnough() {
    if case let .entry(matched) = TabRefResolver.resolve("2222", in: fixtures) {
        #expect(matched == beta)
    } else {
        Issue.record("expected UUID-prefix match")
    }
}

@Test
func uuidPrefixMatchToleratesUppercase() {
    // UUID strings are case-insensitive; the resolver lowercases
    // both sides.
    if case let .entry(matched) = TabRefResolver.resolve("2222", in: fixtures) {
        #expect(matched == beta)
    }
    if case let .entry(matched) = TabRefResolver.resolve("3333", in: fixtures) {
        #expect(matched == unnamed)
    }
}

@Test
func tabIdMatchResolvesSplitTabOnce() {
    let primary = TabsListEntry(
        sessionId: "44444444-4444-4444-4444-444444444441",
        label: nil,
        tabId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        shortId: "split1",
        name: nil
    )
    let split = TabsListEntry(
        sessionId: "44444444-4444-4444-4444-444444444442",
        label: nil,
        tabId: primary.tabId,
        shortId: "split2",
        name: nil
    )

    #expect(TabRefResolver.resolve(primary.tabId.uppercased(), in: [primary, split]) == .entry(primary))
    #expect(TabRefResolver.resolve("aaaaaaaa", in: [primary, split]) == .entry(primary))
}

@Test
func uuidPrefixBelowMinimumIsIgnored() {
    // 3-char prefix is shorter than `minUUIDPrefixLength` (4), so it
    // shouldn't fire the UUID tier. With no short_id / name match
    // for "111", the resolver falls through to .notFound.
    let result = TabRefResolver.resolve("111", in: fixtures)
    #expect(result == .notFound)
}

@Test
func uuidPrefixAmbiguity() {
    // Two tabs sharing a common UUID prefix surface as .ambiguous.
    let twinA = TabsListEntry(
        sessionId: "abcdef00-0000-0000-0000-000000000001",
        label: nil,
        shortId: "twin01",
        name: nil
    )
    let twinB = TabsListEntry(
        sessionId: "abcdef00-0000-0000-0000-000000000002",
        label: nil,
        shortId: "twin02",
        name: nil
    )
    let result = TabRefResolver.resolve("abcdef", in: [twinA, twinB])
    guard case let .ambiguous(matches) = result else {
        Issue.record("expected .ambiguous, got \(result)")
        return
    }
    #expect(matches.count == 2)
}

@Test
func uuidPrefixAmbiguityContainsOneEntryPerTab() {
    let firstPrimary = TabsListEntry(
        sessionId: "11111111-1111-1111-1111-111111111111",
        label: nil,
        tabId: "abcdef00-0000-0000-0000-000000000001",
        shortId: "tab001",
        name: nil
    )
    let firstSplit = TabsListEntry(
        sessionId: "22222222-2222-2222-2222-222222222222",
        label: nil,
        tabId: firstPrimary.tabId,
        shortId: "tab002",
        name: nil
    )
    let second = TabsListEntry(
        sessionId: "33333333-3333-3333-3333-333333333333",
        label: nil,
        tabId: "abcdef00-0000-0000-0000-000000000002",
        shortId: "tab003",
        name: nil
    )

    let result = TabRefResolver.resolve("abcdef", in: [firstPrimary, firstSplit, second])
    guard case let .ambiguous(matches) = result else {
        Issue.record("expected .ambiguous, got \(result)")
        return
    }
    #expect(matches == [firstPrimary, second])
}

// MARK: - Sentinel tier

@Test
func tabSentinelKeywordResolvesWhenNoOtherMatch() {
    #expect(TabRefResolver.resolve("current", in: fixtures) == .sentinel(.current))
    #expect(TabRefResolver.resolve("all", in: fixtures) == .sentinel(.all))
}

@Test
func tabSentinelIsShadowedByLiteralName() {
    // The documented priority (short_id → name → UUID prefix →
    // sentinel) means a tab literally named "current" wins. Rare
    // but self-inflicted.
    let shadowing = TabsListEntry(
        sessionId: "99999999-9999-9999-9999-999999999999",
        label: nil,
        shortId: "shadow",
        name: "current"
    )
    if case let .entry(matched) = TabRefResolver.resolve("current", in: fixtures + [shadowing]) {
        #expect(matched == shadowing)
    } else {
        Issue.record("name match should shadow the sentinel keyword")
    }
}

// MARK: - Not found

@Test
func tabUnmatchedReturnsNotFound() {
    let result = TabRefResolver.resolve("nothing-matches", in: fixtures)
    #expect(result == .notFound)
}

@Test
func tabEmptyEntriesReturnsNotFoundOrSentinel() {
    #expect(TabRefResolver.resolve("anything", in: []) == .notFound)
    // Sentinels still resolve even with an empty list: they're
    // CLI-level fallbacks the daemon doesn't need to know about.
    #expect(TabRefResolver.resolve("all", in: []) == .sentinel(.all))
}

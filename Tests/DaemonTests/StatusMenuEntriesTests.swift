// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// statusMenuEntries is the pure seam the status-item shutdown menu
// is built from. Unit-test it with plain OwnedSim fixtures (no
// CoreSimulator, no AppKit), covering the two things the menu wiring
// trusts: titles disambiguate duplicate device names, and the action
// udid is always the full udid (never the disambiguated title).

@Test
func statusMenuEntriesEmptyInputProducesNoEntries() {
    #expect(statusMenuEntries([]).isEmpty)
}

@Test
func statusMenuEntriesUniqueNamesPassThroughBare() {
    let sims = [
        OwnedSim(
            udid: "aaaaaaaa-0000-0000-0000-000000000001",
            name: "iPhone 17 Pro",
            runtimeIdentifier: "iOS-26-4"
            ),
        OwnedSim(
            udid: "bbbbbbbb-0000-0000-0000-000000000002",
            name: "iPad Pro",
            runtimeIdentifier: "iOS-26-4"
            )
    ]
    let entries = statusMenuEntries(sims)
    #expect(entries.map(\.title) == ["iPhone 17 Pro", "iPad Pro"])
    #expect(entries.map(\.udid) == sims.map(\.udid))
}

@Test
func statusMenuEntriesDuplicateNamesDisambiguateWithShortUDID() {
    let sims = [
        OwnedSim(
            udid: "abcdef01-0000-0000-0000-000000000001",
            name: "iPhone 17",
            runtimeIdentifier: "iOS-26-4"
            ),
        OwnedSim(
            udid: "feedface-0000-0000-0000-000000000002",
            name: "iPhone 17",
            runtimeIdentifier: "iOS-26-3"
            )
    ]
    let entries = statusMenuEntries(sims)
    #expect(
        entries.map(\.title) == [
        "iPhone 17 — ABCDEF01",
        "iPhone 17 — FEEDFACE"
        ]
        )
    // The action must stay keyed by the full udid, not the title.
    #expect(entries.map(\.udid) == sims.map(\.udid))
}

@Test
func statusMenuEntriesDisambiguatesOnlyTheSharedName() {
    let sims = [
        OwnedSim(
            udid: "abcdef01-0000-0000-0000-000000000001",
            name: "iPhone 17",
            runtimeIdentifier: "iOS-26-4"
            ),
        OwnedSim(
            udid: "feedface-0000-0000-0000-000000000002",
            name: "iPhone 17",
            runtimeIdentifier: "iOS-26-4"
            ),
        OwnedSim(
            udid: "0ddba11c-0000-0000-0000-000000000003",
            name: "iPad Pro",
            runtimeIdentifier: "iOS-26-4"
            )
    ]
    let entries = statusMenuEntries(sims)
    // A name unique within the snapshot stays bare; only the duplicated
    // name gets the short-udid suffix. Order follows the input.
    #expect(
        entries.map(\.title) == [
        "iPhone 17 — ABCDEF01",
        "iPhone 17 — FEEDFACE",
        "iPad Pro"
        ]
        )
    #expect(entries.map(\.udid) == sims.map(\.udid))
}

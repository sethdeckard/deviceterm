// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// PaneRefResolver: the mirror of `TabRefResolver` for `--pane <ref>`.
// The tab grammar's priority, with a device-key tier inserted:
// short_id → name → device key (a sim UDID or a physical deviceId) →
// UUID prefix → sentinel. An agent that learned the tab grammar
// resolves panes the same way. The resolver + tests pin the contract
// `pane info` and `pane close` rely on; `pane rename` parses but is
// not yet implemented.

// MARK: - Fixtures

private let watchPane = PanesListEntry(
    paneId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    udid: "1A2B3C4D-WATCH-0000-0000-000000000000",
    state: .rendering,
    family: "watch",
    shortId: "wch001",
    name: "morning"
)

private let phonePane = PanesListEntry(
    paneId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    udid: "5E6F7A8B-PHONE-0000-0000-000000000000",
    state: .rendering,
    family: "phone",
    shortId: "phn002",
    name: nil
)

private let devicePane = PanesListEntry(
    paneId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
    udid: "00008130-001C195E0E91802E",
    state: .rendering,
    family: "phone",
    shortId: "dev003",
    name: "field-unit",
    target: .device(deviceId: "00008130-001C195E0E91802E")
)

private let fixtures = [watchPane, phonePane]

// MARK: - Tier priority

@Test
func shortIdHitWinsOverEverything() {
    if case let .entry(matched) = PaneRefResolver.resolve("wch001", in: fixtures) {
        #expect(matched == watchPane)
    } else {
        Issue.record("expected .entry, got fallback")
    }
}

@Test
func nameHitFiresWhenShortIdMisses() {
    if case let .entry(matched) = PaneRefResolver.resolve("morning", in: fixtures) {
        #expect(matched == watchPane)
    } else {
        Issue.record("expected name match for 'morning'")
    }
}

@Test
func uuidPrefixHitRequiresMinimumLength() {
    if case let .entry(matched) = PaneRefResolver.resolve("aaaa", in: fixtures) {
        #expect(matched == watchPane)
    }
    // Below minimum: 3 chars, so it falls through.
    #expect(PaneRefResolver.resolve("aaa", in: fixtures) == .notFound)
}

@Test
func sentinelDefaultsToLowestPriority() {
    #expect(PaneRefResolver.resolve("default", in: fixtures) == .sentinel(.default))
    #expect(PaneRefResolver.resolve("all", in: fixtures) == .sentinel(.all))
}

@Test
func paneSentinelIsShadowedByLiteralName() {
    let shadowing = PanesListEntry(
        paneId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
        udid: "9F8E7D6C-0000-0000-0000-000000000000",
        state: .rendering,
        family: "phone",
        shortId: "shadow",
        name: "default"
    )
    if case let .entry(matched) = PaneRefResolver.resolve(
        "default",
        in: fixtures + [shadowing]
    ) {
        #expect(matched == shadowing)
    } else {
        Issue.record("name match should shadow the sentinel keyword")
    }
}

@Test
func paneAmbiguityWithinTierSurfaces() {
    let twinA = PanesListEntry(
        paneId: "dddddddd-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        udid: "U-1",
        state: .rendering,
        family: "phone",
        shortId: "twin01",
        name: "background"
    )
    let twinB = PanesListEntry(
        paneId: "dddddddd-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        udid: "U-2",
        state: .rendering,
        family: "phone",
        shortId: "twin02",
        name: "background"
    )
    let result = PaneRefResolver.resolve("background", in: [twinA, twinB])
    guard case let .ambiguous(matches) = result else {
        Issue.record("expected .ambiguous, got \(result)")
        return
    }
    #expect(matches.count == 2)
}

@Test
func paneUnmatchedReturnsNotFound() {
    #expect(PaneRefResolver.resolve("zzz999", in: fixtures) == .notFound)
}

// MARK: - Device-identity key tier

@Test
func simUdidExactMatchResolvesPane() {
    // A full sim UDID typed as `--pane` resolves via the device-key
    // tier (the `udid` column carries `target.key`), case-insensitively.
    if case let .entry(matched) = PaneRefResolver.resolve(
        "5e6f7a8b-phone-0000-0000-000000000000",
        in: fixtures
    ) {
        #expect(matched == phonePane)
    } else {
        Issue.record("expected sim UDID key match")
    }
}

@Test
func physicalDeviceIdExactMatchResolvesPane() {
    // A physical device's stable CoreDevice UDID, carried as deviceId,
    // resolves through the same key tier.
    let entries = fixtures + [devicePane]
    if case let .entry(matched) = PaneRefResolver.resolve(
        "00008130-001C195E0E91802E",
        in: entries
    ) {
        #expect(matched == devicePane)
    } else {
        Issue.record("expected deviceId key match")
    }
}

@Test
func deviceKeyMatchIsExactNotPrefix() {
    // A fragment of a device key does NOT match the key tier; it
    // falls through to the paneId-prefix tier (which it also misses
    // here), so the result is `.notFound`, never a silent key hit.
    let entries = fixtures + [devicePane]
    #expect(PaneRefResolver.resolve("00008130", in: entries) == .notFound)
}

@Test
func exactKeyMatchIsNotShadowedByName() {
    // The `DEVICETERM_TARGET_PANE` env fallback exports a canonical
    // key and resolves via `exactKeyMatch`. Even when another pane is
    // *named* exactly that UDID, the exact lookup returns the pane the
    // UDID belongs to, never the same-named pane. (The tiered
    // `resolve` WOULD pick the name match, which is precisely why the
    // env fallback uses `exactKeyMatch` instead.)
    let shadow = PanesListEntry(
        paneId: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        udid: "U-other",
        state: .rendering,
        family: "phone",
        shortId: "shadw2",
        name: phonePane.udid
    )
    let entries = [phonePane, shadow]
    #expect(PaneRefResolver.exactKeyMatch(phonePane.udid, in: entries) == phonePane)
    // Document the divergence the fix relies on: the tiered resolver
    // is shadowed by the name tier here.
    if case let .entry(matched) = PaneRefResolver.resolve(phonePane.udid, in: entries) {
        #expect(matched == shadow)
    } else {
        Issue.record("expected the name tier to shadow under tiered resolve")
    }
}

@Test
func exactKeyMatchMissesReturnNil() {
    #expect(PaneRefResolver.exactKeyMatch("nope", in: fixtures) == nil)
}

@Test
func shortIdStillWinsOverDeviceKey() {
    // Tier order holds: a shortId match short-circuits before the key
    // tier even when another pane's key would also be a candidate.
    let entries = fixtures + [devicePane]
    if case let .entry(matched) = PaneRefResolver.resolve("dev003", in: entries) {
        #expect(matched == devicePane)
    } else {
        Issue.record("expected shortId match for 'dev003'")
    }
}

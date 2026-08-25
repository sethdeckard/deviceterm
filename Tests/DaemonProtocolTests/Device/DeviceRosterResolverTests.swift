// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// DeviceRosterResolver: `device attach <ref>` resolution against the
// aggregate `devices.list` roster. Priority: id (sim UDID / physical
// deviceId) → name. No shortId tier (the roster carries none).

// MARK: - Fixtures

private let bootedSim = DeviceRosterEntry(
    id: "5E6F7A8B-PHONE-0000-0000-000000000000",
    kind: .sim,
    name: "iPhone 17 Pro",
    state: "Booted"
)

private let physical = DeviceRosterEntry(
    id: "00008130-001C195E0E91802E",
    kind: .device,
    name: "field-unit",
    state: "connected"
)

private let roster = [bootedSim, physical]

// MARK: - id tier

@Test
func resolvesSimByUDIDCaseInsensitively() {
    if case let .entry(matched) = DeviceRosterResolver.resolve(
        "5e6f7a8b-phone-0000-0000-000000000000",
        in: roster
    ) {
        #expect(matched == bootedSim)
    } else {
        Issue.record("expected sim UDID match")
    }
}

@Test
func resolvesPhysicalByDeviceId() {
    if case let .entry(matched) = DeviceRosterResolver.resolve(
        "00008130-001C195E0E91802E",
        in: roster
    ) {
        #expect(matched == physical)
    } else {
        Issue.record("expected deviceId match")
    }
}

// MARK: - name tier

@Test
func resolvesByNameWhenIdMisses() {
    if case let .entry(matched) = DeviceRosterResolver.resolve(
        "field-unit",
        in: roster
    ) {
        #expect(matched == physical)
    } else {
        Issue.record("expected name match")
    }
}

@Test
func idTierWinsOverName() {
    // A device whose name equals another device's id must not let the
    // name tier shadow the exact id hit.
    let shadow = DeviceRosterEntry(
        id: "U-shadow",
        kind: .sim,
        name: bootedSim.id,
        state: "Booted"
    )
    if case let .entry(matched) = DeviceRosterResolver.resolve(
        bootedSim.id,
        in: [bootedSim, shadow]
    ) {
        #expect(matched == bootedSim)
    } else {
        Issue.record("id tier should win over a same-valued name")
    }
}

// MARK: - misses + ambiguity

@Test
func unmatchedRefReturnsNotFound() {
    #expect(DeviceRosterResolver.resolve("nope", in: roster) == .notFound)
}

@Test
func ambiguousNameSurfaces() {
    let twinA = DeviceRosterEntry(id: "U-1", kind: .sim, name: "twin")
    let twinB = DeviceRosterEntry(id: "U-2", kind: .sim, name: "twin")
    let result = DeviceRosterResolver.resolve("twin", in: [twinA, twinB])
    guard case let .ambiguous(hits) = result else {
        Issue.record("expected .ambiguous, got \(result)")
        return
    }
    #expect(hits.count == 2)
}

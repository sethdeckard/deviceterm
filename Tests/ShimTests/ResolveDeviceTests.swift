// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import Shim
import Testing

// Pin `resolveDevice`'s snapshot-diff attribution behavior. The function
// takes before/after `simctl list` snapshots and decides which device the
// user's spec is pointing at. The required invariant is that a non-transition
// is never resolved to a device. Without that gate an idempotent invocation
// (`simctl bootstatus -b <udid>` against a sim that's already Booted, which
// exits 0 without changing any state) would still resolve via the
// literal-UDID / unique-name fallback and the shim would post a fabricated
// `.booted` event, claiming ownership of an externally-booted sim for the
// calling session. `simctl boot` against an already-Booted device exits
// non-zero, so the `boot <udid>` path gets that signal for free; `bootstatus`
// exits 0 either way and needs the explicit transition gate.

// MARK: - Fixture helpers

private func dev(
    _ udid: String,
    _ name: String,
    state: String = "Shutdown",
    runtime: String = "iOS-26-0"
) -> DeviceRecord {
    DeviceRecord(udid: udid, name: name, state: state, runtime: runtime)
}

private let phoneUDID = "ABCDEF12-3456-7890-ABCD-EF1234567890"
private let watchUDID = "11111111-2222-3333-4444-555555555555"

// MARK: - Single transition (the happy path)

@Test
func resolvesSingleBootTransition() {
    let before = [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")]
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(spec: phoneUDID, eventKind: .booted, before: before, after: after)
    #expect(resolved?.udid == phoneUDID)
    #expect(resolved?.name == "iPhone 17 Pro")
    #expect(resolved?.state == "Booted")
}

@Test
func resolvesBootingTransitionWithoutWaitingForBooted() {
    let before = [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")]
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Booting")]
    let resolved = resolveDevice(spec: phoneUDID, eventKind: .booted, before: before, after: after)
    #expect(resolved?.udid == phoneUDID)
    #expect(resolved?.state == "Booting")
}

@Test
func resolvesSingleShutdownTransition() {
    let before = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")]
    let resolved = resolveDevice(spec: phoneUDID, eventKind: .shutdown, before: before, after: after)
    #expect(resolved?.udid == phoneUDID)
}

@Test("shutdown resolves while a boot is still in progress", arguments: [
    "Shutting Down",
    "Shutdown"
])
func resolvesShutdownFromBooting(afterState: String) {
    let before = [dev(phoneUDID, "iPhone 17 Pro", state: "Booting")]
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: afterState)]
    let resolved = resolveDevice(
        spec: phoneUDID,
        eventKind: .shutdown,
        before: before,
        after: after
    )
    #expect(resolved?.udid == phoneUDID)
}

// MARK: - Idempotent invocations: must NOT resolve

@Test("bootstatus -b on already-Booted UDID — no transition, no attribution")
func rejectsBootEventWhenAlreadyBootedByUDID() {
    // The exact bug this guards against: `bootstatus -b <udid>`
    // against a Booted sim exits 0 with no state change, and the
    // literal-UDID fallback would resolve it anyway, posting a
    // fabricated event. The matched device must have transitioned in
    // the expected direction.
    let snapshot = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(
        spec: phoneUDID,
        eventKind: .booted,
        before: snapshot,
        after: snapshot
    )
    #expect(resolved == nil)
}

@Test("bootstatus -b on already-Booted name — no transition, no attribution")
func rejectsBootEventWhenAlreadyBootedByName() {
    // Same idempotency check, this time via the unique-name
    // fallback (spec is a bare name, not a UDID).
    let snapshot = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(
        spec: "iPhone 17 Pro",
        eventKind: .booted,
        before: snapshot,
        after: snapshot
    )
    #expect(resolved == nil)
}

@Test("an already-Booting device is not a new boot attempt")
func rejectsBootEventWhenAlreadyBooting() {
    let before = [dev(phoneUDID, "iPhone 17 Pro", state: "Booting")]
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(
        spec: phoneUDID,
        eventKind: .booted,
        before: before,
        after: after
    )
    #expect(resolved == nil)
}

@Test("shutdown on already-Shutdown UDID — no transition, no attribution")
func rejectsShutdownEventWhenAlreadyShutdown() {
    let snapshot = [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")]
    let resolved = resolveDevice(
        spec: phoneUDID,
        eventKind: .shutdown,
        before: snapshot,
        after: snapshot
    )
    #expect(resolved == nil)
}

// MARK: - Spec mismatch: no match found

@Test
func rejectsUDIDSpecNotInSnapshot() {
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(
        spec: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF",
        eventKind: .booted,
        before: [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")],
        after: after
    )
    #expect(resolved == nil)
}

@Test
func rejectsNameSpecNotInSnapshot() {
    let after = [dev(phoneUDID, "iPhone 17 Pro", state: "Booted")]
    let resolved = resolveDevice(
        spec: "iPad Pro M5",
        eventKind: .booted,
        before: [dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown")],
        after: after
    )
    #expect(resolved == nil)
}

// MARK: - Multi-transition disambiguation via spec

@Test
func disambiguatesMultiTransitionByUDID() {
    // Two sims booted concurrently. Spec is a UDID. Resolver must
    // pick the one named by the spec, and it must be the one that
    // transitioned (both did in this case).
    let before = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Shutdown")
    ]
    let after = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Booted"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Booted")
    ]
    let resolved = resolveDevice(spec: watchUDID, eventKind: .booted, before: before, after: after)
    #expect(resolved?.udid == watchUDID)
    #expect(resolved?.name == "Apple Watch Ultra 3")
}

@Test
func disambiguatesMultiTransitionByName() {
    let before = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Shutdown"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Shutdown")
    ]
    let after = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Booted"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Booted")
    ]
    let resolved = resolveDevice(
        spec: "Apple Watch Ultra 3",
        eventKind: .booted,
        before: before,
        after: after
    )
    #expect(resolved?.udid == watchUDID)
}

@Test("multi-transition + spec matches a non-transitioning device — no attribution")
func rejectsMultiTransitionWhenSpecDeviceDidNotTransition() {
    // Watch booted; phone was already Booted. Spec is the phone's
    // UDID. The phone didn't transition this round → the shim
    // would have been wrong to claim it. Fallback must reject.
    let before = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Booted"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Shutdown")
    ]
    let after = [
        dev(phoneUDID, "iPhone 17 Pro", state: "Booted"),
        dev(watchUDID, "Apple Watch Ultra 3", state: "Booted")
    ]
    let resolved = resolveDevice(spec: phoneUDID, eventKind: .booted, before: before, after: after)
    #expect(resolved == nil)
}

// MARK: - Cross-runtime ambiguity (name shared, UDIDs distinct)

@Test
func disambiguatesSharedNameViaTransition() {
    // Two "iPhone 17 Pro" sims across different runtimes; only one
    // transitions. Spec is the bare name. Resolver picks the one
    // that actually booted, by direct snapshot-diff (not fallback).
    let iosOneUDID = "11111111-1111-1111-1111-111111111111"
    let iosTwoUDID = "22222222-2222-2222-2222-222222222222"
    let before = [
        dev(iosOneUDID, "iPhone 17 Pro", state: "Shutdown", runtime: "iOS-26-0"),
        dev(iosTwoUDID, "iPhone 17 Pro", state: "Shutdown", runtime: "iOS-26-1")
    ]
    let after = [
        dev(iosOneUDID, "iPhone 17 Pro", state: "Booted", runtime: "iOS-26-0"),
        dev(iosTwoUDID, "iPhone 17 Pro", state: "Shutdown", runtime: "iOS-26-1")
    ]
    let resolved = resolveDevice(
        spec: "iPhone 17 Pro",
        eventKind: .booted,
        before: before,
        after: after
    )
    #expect(resolved?.udid == iosOneUDID)
    #expect(resolved?.runtime == "iOS-26-0")
}

@Test("shared name, none transitioned — no attribution")
func rejectsSharedNameWhenNoneTransitioned() {
    let iosOneUDID = "11111111-1111-1111-1111-111111111111"
    let iosTwoUDID = "22222222-2222-2222-2222-222222222222"
    let snapshot = [
        dev(iosOneUDID, "iPhone 17 Pro", state: "Booted", runtime: "iOS-26-0"),
        dev(iosTwoUDID, "iPhone 17 Pro", state: "Booted", runtime: "iOS-26-1")
    ]
    let resolved = resolveDevice(
        spec: "iPhone 17 Pro",
        eventKind: .booted,
        before: snapshot,
        after: snapshot
    )
    #expect(resolved == nil)
}

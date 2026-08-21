// SPDX-License-Identifier: GPL-3.0-or-later
//
// DetectEventTests: pin the shim's argv-detection layer across
// every state-changing simctl invocation the shim is expected to
// catch, plus the negative-space invocations that must NOT generate
// a boot claim or shutdown event (otherwise we'd misattribute boots that never
// happened or shutdowns we didn't cause).
//
// The shim's main loop relies on `detectEvent` to decide whether to
// take a `simctl list` snapshot, run the child, take another
// snapshot, diff for the unique state transition, and report it. A miss means
// the sim boots but
// deviceterm sees no pane attribution.

import DaemonProtocol
@testable import Shim
import Testing

// MARK: - Fixture helpers

/// Build a synthetic argv where `argv[0]` is the shim's own basename
/// (matches what `CommandLine.arguments[0]` looks like at runtime).
private func argv(_ invokedAs: String, _ rest: String...) -> [String] {
    [invokedAs] + rest
}

// MARK: - Positive cases: events the shim MUST detect

@Test("boot — bare xcrun simctl path", arguments: [
    (argv("xcrun", "simctl", "boot", "iPhone 17 Pro"), "iPhone 17 Pro"),
    (argv("xcrun", "simctl", "boot", "ABCDEF12-3456-7890-ABCD-EF1234567890"),
        "ABCDEF12-3456-7890-ABCD-EF1234567890"),
    (argv("xcrun", "simctl", "boot", "booted"), "booted")
])
func detectsBootViaXcrun(input: [String], expectedSpec: String) {
    let event = detectEvent(argv: input, invokedAs: "xcrun")
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == expectedSpec)
}

@Test("boot — bare simctl invocation (no xcrun)")
func detectsBootViaBareSimctl() {
    let event = detectEvent(
        argv: argv("simctl", "boot", "iPhone 17 Pro"),
        invokedAs: "simctl"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("shutdown — bare xcrun simctl path", arguments: [
    (argv("xcrun", "simctl", "shutdown", "iPhone 17 Pro"), "iPhone 17 Pro"),
    (argv("xcrun", "simctl", "shutdown", "all"), "all")
])
func detectsShutdownViaXcrun(input: [String], expectedSpec: String) {
    let event = detectEvent(argv: input, invokedAs: "xcrun")
    #expect(event?.kind == .shutdown)
    #expect(event?.deviceSpec == expectedSpec)
}

@Test("shutdown — bare simctl invocation")
func detectsShutdownViaBareSimctl() {
    let event = detectEvent(
        argv: argv("simctl", "shutdown", "iPhone 17 Pro"),
        invokedAs: "simctl"
    )
    #expect(event?.kind == .shutdown)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

// MARK: - Positive cases: bootstatus <device> -b
//
// `xcrun simctl bootstatus <device> -b` boots if needed AND waits
// for the boot to finish. Common in CI / scaffold scripts. simctl's
// CLI grammar is `bootstatus <device> [-bd]`: device is the first
// positional after the verb, flags come AFTER. Before this fix the
// shim's argv detector keyed only on `[simctl, boot, ...]` and
// missed every bootstatus-driven boot.

@Test("bootstatus <name> -b — name spec, single flag")
func detectsBootstatusBootFlag() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-b"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("bootstatus <udid> -b — UDID spec")
func detectsBootstatusWithUDID() {
    let udid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", udid, "-b"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == udid)
}

@Test("bootstatus <device> -d -b — both flags present, -b somewhere")
func detectsBootstatusWithBootAndDaemonFlags() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-d", "-b"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("bootstatus <device> -bd — short-flag cluster")
func detectsBootstatusWithClusterBD() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-bd"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("bootstatus <device> -db — short-flag cluster (reverse order)")
func detectsBootstatusWithClusterDB() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-db"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("bootstatus <device> -b — bare simctl invocation")
func detectsBootstatusViaBareSimctl() {
    let event = detectEvent(
        argv: argv("simctl", "bootstatus", "iPhone 17 Pro", "-b"),
        invokedAs: "simctl"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

// MARK: - Negative cases: bootstatus without -b is a poll, NOT a boot

@Test("bootstatus <device> (no flags) — pure poll, no event")
func ignoresBootstatusWithoutBootFlag() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event == nil)
}

@Test("bootstatus <device> -d (no -b) — daemon flag only, no event")
func ignoresBootstatusWithOnlyDaemonFlag() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "iPhone 17 Pro", "-d"),
        invokedAs: "xcrun"
    )
    #expect(event == nil)
}

@Test("bootstatus -b <udid> — wrong order (simctl rejects this)")
func ignoresBootstatusFlagBeforeDevice() {
    // simctl bootstatus interprets the first positional as the
    // device spec. `bootstatus -b <udid>` therefore fails with
    // "Invalid device: -b" and never reaches the boot step. The
    // shim must NOT post a spurious event in that case, even if
    // the user typed it. The flag-first form is a user error, not
    // a successful boot vector.
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus", "-b", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event == nil)
}

@Test("bootstatus alone — no device, no event")
func ignoresBootstatusWithoutAnyArgs() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "bootstatus"),
        invokedAs: "xcrun"
    )
    #expect(event == nil)
}

// MARK: - xcrun-level global flags with separate values
//
// Both long (`--sdk`) and short (`-sdk`) forms of every xcrun global
// flag must be skipped; missing either form means the SDK value
// (e.g. `iphonesimulator`) gets treated as the first positional and
// the shim fails to find `simctl` next. Unrolled per-flag rather
// than parameterised: the single-argument flat-array form of
// Swift Testing's `arguments:` crashes the bundle host (verified
// on swift-testing 1902 / Xcode 17 betas). Each pair below is one
// flag in long + short form.

@Test
func skipsXcrunSDKFlagLong() {
    let event = detectEvent(
        argv: argv("xcrun", "--sdk", "iphonesimulator", "simctl", "boot", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("xcrun -sdk iphonesimulator simctl boot — short form")
func skipsXcrunSDKFlagShort() {
    let event = detectEvent(
        argv: argv("xcrun", "-sdk", "iphonesimulator", "simctl", "boot", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("xcrun --toolchain swift simctl shutdown — long form")
func skipsXcrunToolchainFlagLong() {
    let event = detectEvent(
        argv: argv("xcrun", "--toolchain", "swift", "simctl", "shutdown", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .shutdown)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("xcrun -toolchain swift simctl shutdown — short form")
func skipsXcrunToolchainFlagShort() {
    let event = detectEvent(
        argv: argv("xcrun", "-toolchain", "swift", "simctl", "shutdown", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .shutdown)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("xcrun --sdk=iphonesimulator simctl boot — long flag with `=value`")
func skipsXcrunSDKFlagWithEmbeddedValue() {
    let event = detectEvent(
        argv: argv("xcrun", "--sdk=iphonesimulator", "simctl", "boot", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("xcrun --sdk iphonesimulator simctl bootstatus <device> -b — both flag layers cooperate")
func skipsXcrunSDKFlagBeforeBootstatus() {
    let input = argv("xcrun", "--sdk", "iphonesimulator", "simctl", "bootstatus", "iPhone 17 Pro", "-b")
    let event = detectEvent(argv: input, invokedAs: "xcrun")
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

// MARK: - simctl-level global flags with separate values

@Test("simctl --set <dir> boot — alternate device set")
func skipsSimctlSetFlag() {
    let event = detectEvent(
        argv: argv("xcrun", "simctl", "--set", "/tmp/devices", "boot", "iPhone 17 Pro"),
        invokedAs: "xcrun"
    )
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("simctl --profiles <file> shutdown")
func skipsSimctlProfilesFlag() {
    let input = argv("xcrun", "simctl", "--profiles", "/tmp/profiles.json", "shutdown", "iPhone 17 Pro")
    let event = detectEvent(argv: input, invokedAs: "xcrun")
    #expect(event?.kind == .shutdown)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

@Test("simctl --set <dir> bootstatus <device> -b — both layers + bootstatus")
func skipsSimctlSetFlagBeforeBootstatus() {
    let input = argv("xcrun", "simctl", "--set", "/tmp/devices", "bootstatus", "iPhone 17 Pro", "-b")
    let event = detectEvent(argv: input, invokedAs: "xcrun")
    #expect(event?.kind == .booted)
    #expect(event?.deviceSpec == "iPhone 17 Pro")
}

// MARK: - Negative cases: verbs that must NOT produce events

@Test("non-state-changing simctl verbs produce no event")
func ignoresNonStateChangingVerbs() {
    // Walk a representative slice of simctl's verb surface. Every
    // verb other than boot / shutdown / bootstatus-with-`-b` must
    // fall through to nil so the shim doesn't fabricate a transition
    // event for a command that didn't change device state. Internal
    // `for` loop (not @Test parameterisation) because the
    // single-argument flat-array `arguments:` form crashes the
    // current swift-testing bundle host.
    let nonStateChangingVerbs = [
        "list", "install", "uninstall", "launch", "terminate", "openurl",
        "addmedia", "spawn", "io", "diagnose", "logverbose", "help"
    ]
    for verb in nonStateChangingVerbs {
        let event = detectEvent(
            argv: argv("xcrun", "simctl", verb, "iPhone 17 Pro"),
            invokedAs: "xcrun"
        )
        #expect(event == nil, "verb '\(verb)' should not produce an event")
    }
}

@Test("xcrun without simctl as the first non-flag positional")
func ignoresXcrunWithoutSimctl() {
    let cases: [[String]] = [
        ["xcrun", "swift", "test"],
        ["xcrun", "clang", "--version"],
        ["xcrun", "--sdk", "iphonesimulator", "swiftc", "foo.swift"]
    ]
    for args in cases {
        let event = detectEvent(argv: args, invokedAs: "xcrun")
        #expect(event == nil, "argv \(args) should not produce an event")
    }
}

@Test("empty / boundary argv")
func ignoresEmptyAndBoundaryInputs() {
    // Just argv[0], with no verb at all.
    #expect(detectEvent(argv: ["xcrun"], invokedAs: "xcrun") == nil)
    #expect(detectEvent(argv: ["simctl"], invokedAs: "simctl") == nil)
    // simctl with no verb.
    #expect(detectEvent(argv: ["xcrun", "simctl"], invokedAs: "xcrun") == nil)
    // boot/shutdown without a spec.
    #expect(detectEvent(argv: ["xcrun", "simctl", "boot"], invokedAs: "xcrun") == nil)
    #expect(
        detectEvent(argv: ["xcrun", "simctl", "shutdown"], invokedAs: "xcrun") == nil
    )
}

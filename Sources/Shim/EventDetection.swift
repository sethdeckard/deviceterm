// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

// The shim's pure argv-pattern matchers, kept out of `main.swift` so the
// `ShimTests` target can call them from a nonisolated test context. Swift 6
// treats every top-level declaration in `main.swift` as `@MainActor` (it's the
// executable's entry point), which means a non-isolated test trips a runtime
// isolation check when it reaches a Set lookup inside
// `skipFlagsConsumingValues`. Keeping the pure surface here makes it
// default-nonisolated and unit-testable without forcing every test onto
// MainActor.

// MARK: - Flag tables

/// xcrun flags that take a separate-argument value, in both long
/// and short forms. `xcrun -sdk iphonesimulator simctl boot …` and
/// `xcrun --sdk iphonesimulator simctl …` are both common; missing
/// either form means we'd treat the SDK value as the first
/// positional and fail to recognize `simctl`, silently dropping
/// the provenance event.
let xcrunFlagsWithSeparateValue: Set<String> = [
    "--toolchain",
    "-toolchain",
    "--sdk",
    "-sdk"
]

/// simctl's own global flags that take a separate-argument value.
/// Invocations like `xcrun simctl --set /tmp/devices boot <udid>`
/// would otherwise treat `/tmp/devices` as the verb and the event
/// would never get attributed. Short forms aren't documented for
/// simctl; we only include the long forms we're confident about.
let simctlFlagsWithSeparateValue: Set<String> = [
    "--set",
    "--profiles"
]

// MARK: - Flag skipper

/// Pop flag tokens from the head of `args`, consuming the next
/// argument as a value when the flag is in `flagsWithValue`.
/// Handles `--flag value` (two args) and `--flag=value` (one arg)
/// equally. Stops at the first non-flag token, leaving it at the
/// head of `args`.
func skipFlagsConsumingValues(
    from args: inout [String],
    flagsWithValue: Set<String>
) {
    while let first = args.first, first.hasPrefix("-") {
        args.removeFirst()
        // `--flag=value` embeds the value in the flag itself, so
        // there's no extra arg to consume.
        if first.contains("=") { continue }
        if flagsWithValue.contains(first), !args.isEmpty {
            args.removeFirst()
        }
    }
}

// MARK: - Event detection

/// Detect a state-changing simctl invocation in the original argv.
/// Returns nil if the invocation isn't sim-state-changing.
///
/// Recognized verbs:
/// - `boot <spec>` → `.booted`
/// - `shutdown <spec>` → `.shutdown`
/// - `bootstatus -b <spec>` → `.booted`. The bare `bootstatus
///   <spec>` form just polls an in-flight boot; only `-b` (boot if
///   needed, then wait) actually transitions a device to Booted.
///   CI / scaffold scripts frequently reach for `bootstatus -b`
///   because it composes boot + wait into one step. Without
///   recognising it the shim misses every boot routed through that
///   path and the sim appears as an external (unattached) device.
func detectEvent(argv: [String], invokedAs: String) -> ShimEvent? {
    var args = argv
    args.removeFirst()  // drop argv[0] (our shim's invocation name)
    if invokedAs == "xcrun" {
        skipFlagsConsumingValues(
            from: &args,
            flagsWithValue: xcrunFlagsWithSeparateValue
        )
        guard args.first == "simctl" else { return nil }
        args.removeFirst()
    }
    // Skip simctl's own global flags AND their values before the
    // verb. `xcrun simctl --set /tmp/devices boot <udid>` would
    // otherwise read `/tmp/devices` as the verb.
    skipFlagsConsumingValues(
        from: &args,
        flagsWithValue: simctlFlagsWithSeparateValue
    )
    guard let verb = args.first else { return nil }
    let kind: ShimEventType
    switch verb {
    case "boot":
        kind = .booted

    case "shutdown":
        kind = .shutdown

    case "bootstatus":
        // simctl bootstatus's signature is `<device> [-bd]`: the
        // device spec is the FIRST positional after the verb, and
        // any presence flags come AFTER. Running `bootstatus -b
        // <udid>` makes simctl read `-b` as the device argument
        // and fail with "Invalid device: -b". `-b` (boot if needed
        // then wait) is the only flag that transitions the device;
        // bare `bootstatus <device>` just polls. `-bd` (cluster)
        // and `-db` both also imply boot, so scan the stripped flag
        // body for 'b' so any short-form cluster matches.
        var rest = Array(args.dropFirst())
        guard let spec = rest.first, !spec.hasPrefix("-") else { return nil }
        rest.removeFirst()
        var sawBootFlag = false
        while let head = rest.first, head.hasPrefix("-") {
            let stripped = head.drop(while: { $0 == "-" })
            if stripped.contains("b") { sawBootFlag = true }
            rest.removeFirst()
        }
        guard sawBootFlag else { return nil }
        return ShimEvent(kind: .booted, deviceSpec: spec)

    default:
        return nil
    }
    guard args.count >= 2 else { return nil }
    return ShimEvent(kind: kind, deviceSpec: args[1])
}

// MARK: - Device-attach detection (devicectl)

/// Detect a `devicectl` invocation that deploys or runs the user's app
/// on a physically-connected device, and pull out its `--device <id>`.
/// Returns the device spec verbatim (a name, UDID, or ECID, whatever the
/// user typed) when the invocation is a contextual auto-attach trigger,
/// else nil.
///
/// Recognized (the deploy / run-my-app analogs of `simctl boot`):
/// - `devicectl device install …` installs an app bundle.
/// - `devicectl device process launch …` launches an installed app.
///
/// Deliberately NOT recognized: `device info|list|reboot|capture`,
/// `process list`, and every other read-only or lifecycle subcommand.
/// Auto-attach must only fire on an intentional, device-targeted deploy
/// or run: never a query, and never anything that reboots the device.
///
/// A missing `--device` (devicectl requires it for these forms) returns
/// nil, since without a target we can't attribute the attach to a device.
func detectDeviceAttach(argv: [String], invokedAs: String) -> String? {
    // The shim is only installed as `xcrun`/`simctl`, so devicectl always
    // arrives as `xcrun devicectl …`; bare `devicectl` is not on the
    // shim's symlink set and `main` rejects any other argv[0]. Match only
    // the xcrun form rather than implying an unwired bare-devicectl path.
    guard invokedAs == "xcrun" else { return nil }
    var args = argv
    args.removeFirst()  // drop argv[0] (our shim's invocation name)
    skipFlagsConsumingValues(
        from: &args,
        flagsWithValue: xcrunFlagsWithSeparateValue
    )
    guard args.first == "devicectl" else { return nil }
    args.removeFirst()
    // devicectl's noun is `device`; the deploy/run verbs live under it.
    guard args.first == "device" else { return nil }
    args.removeFirst()
    guard let subcommand = args.first else { return nil }
    switch subcommand {
    case "install":
        break  // `device install [app] …`

    case "process":
        // Only `process launch` deploys/runs; `process list` is a query.
        guard args.count >= 2, args[1] == "launch" else { return nil }

    default:
        return nil
    }
    return deviceFlagValue(in: args)
}

/// Extract the value of `--device <id>` / `--device=<id>` from `args`.
/// Returns nil when the flag is absent (or present with no value).
func deviceFlagValue(in args: [String]) -> String? {
    var index = args.startIndex
    while index < args.endIndex {
        let token = args[index]
        if token == "--device" {
            let next = args.index(after: index)
            return next < args.endIndex ? args[next] : nil
        }
        if token.hasPrefix("--device=") {
            return String(token.dropFirst("--device=".count))
        }
        index = args.index(after: index)
    }
    return nil
}

// MARK: - Snapshot resolve

/// Resolve the affected device by diffing two `simctl list`
/// snapshots taken around the real `simctl` invocation. The
/// snapshot diff uniquely identifies the device that actually
/// transitioned in the expected direction even when the user's
/// spec is a name shared across runtimes.
///
/// **A transition is required.** Literal-UDID and unique-name
/// fallbacks (used when zero or multiple devices transitioned)
/// also gate on the matched device having transitioned. Without
/// this, an idempotent invocation (`simctl bootstatus -b <udid>`
/// against an already-Booted sim, which exits 0 without changing
/// any state) would have its spec resolved by name/UDID and the
/// shim would post a fabricated boot claim. The daemon would then bind
/// ownership of an externally-booted sim to the calling
/// session, breaking the linkage model's "external sims stay
/// unattached until `deviceterm pane attach`" property. `simctl boot
/// <udid>` against an already-Booted device fails non-zero so the
/// caller's `exitCode == 0` gate already screens it; bootstatus -b
/// is the first verb where success-without-transition is the
/// common case, but the gate is verb-agnostic so future Apple
/// changes to either verb's exit semantics can't reopen this hole.
func resolveDevice(
    spec: String,
    eventKind: ShimEventType,
    before: [DeviceRecord],
    after: [DeviceRecord]
) -> ResolvedDevice? {
    let beforeByUDID = Dictionary(uniqueKeysWithValues: before.map { ($0.udid, $0) })
    func transitioned(_ dev: DeviceRecord) -> Bool {
        guard let prev = beforeByUDID[dev.udid] else { return false }
        switch eventKind {
        case .booted:
            let wasBootingOrBooted = prev.state == "Booting" || prev.state == "Booted"
            let isBootingOrBooted = dev.state == "Booting" || dev.state == "Booted"
            return !wasBootingOrBooted && isBootingOrBooted

        case .shutdown:
            let wasBootingOrBooted = prev.state == "Booting" || prev.state == "Booted"
            let isBootingOrBooted = dev.state == "Booting" || dev.state == "Booted"
            return wasBootingOrBooted && !isBootingOrBooted

        case .deviceAttach:
            // Physical-device attach is not a sim-snapshot transition; it
            // never reaches this diff (it's a separate detection path).
            return false
        }
    }

    let transitions = after.filter(transitioned)
    if transitions.isEmpty { return nil }

    // Filter transitions by the user's spec so a concurrent boot
    // of an unrelated device, or a single transition that doesn't
    // match what the caller asked about, can't be attributed to
    // this invocation.
    let normalized = spec.replacingOccurrences(of: "-", with: "").lowercased()
    let isUDIDSpec = normalized.count == 32
        && normalized.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil
    let matched: [DeviceRecord]
    if isUDIDSpec {
        matched = transitions.filter {
            $0.udid.replacingOccurrences(of: "-", with: "").lowercased() == normalized
        }
    } else {
        matched = transitions.filter { $0.name == spec }
    }
    if matched.count == 1 {
        let dev = matched[0]
        return ResolvedDevice(
            udid: dev.udid,
            name: dev.name,
            runtime: dev.runtime,
            state: dev.state
        )
    }
    return nil
}

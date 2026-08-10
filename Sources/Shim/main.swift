// SPDX-License-Identifier: GPL-3.0-or-later
//
// deviceterm-shim: argv[0]-driven shim for `xcrun` and `simctl`.
//
// Runs in every deviceterm tab's shell as the first entry on PATH so
// `xcrun` and `simctl` invocations come through us instead of the
// real binaries. The shim itself is transparent: it `exec`s the
// real command with inherited stdio, mirrors the child's exit
// status, and forwards signals. The interesting part is the side
// effect: when the child succeeds and the invocation was one the
// shim recognizes, it posts a provenance-tagged `shim.event` to the
// daemon so the device gets attributed to the originating tab. Two
// invocation shapes qualify, and they are disjoint: `simctl
// boot|shutdown <spec>` (a sim state transition) and `devicectl
// device install|process launch --device <spec>` (a physical-device
// deploy or run).
//
// Behavior:
// 1. Inspect argv[0] basename to decide which real binary to launch
//    (only `xcrun` or `simctl` accepted).
// 2. Reconstruct PATH excluding our shim directory so we don't
//    recurse, then resolve the real binary on the cleaned PATH.
// 3. Detect which of the two recognized shapes the invocation is,
//    if either. A sim transition additionally snapshots every
//    device's state via `simctl list devices -j` *before* spawning
//    the real child; the device path carries the user's `--device`
//    spec verbatim and needs no snapshot.
// 4. `posix_spawn` the real binary with the original argv and an
//    environment whose PATH excludes our shim dir. Inherit
//    stdin/stdout/stderr fd's directly (no pipes) so TTY,
//    colours, and exit-status semantics stay intact.
// 5. Forward common signals to the child while it runs.
// 6. Wait for the child. If it exited 0, post the `shim.event`
//    the detected shape calls for: a sim transition snapshots
//    again and diffs to identify the device that actually flipped;
//    a device attach sends the spec as typed. Best-effort; the
//    shim is exiting either way.
// 7. Exit mirroring the child's termination (same exit code, or
//    re-raise the same signal).
//
// Provenance: the daemon validates the shim's `(DEVICETERM_SESSION,
// DEVICETERM_SESSION_CAP)` pair against its live session before
// mutating ownership. The cap is a session-tied secret injected by
// the daemon into the tab shell's env at PTY spawn (see AGENTS.md
// "Trust boundary"); a stale shell can't forge events for sibling
// tabs because each session has its own cap.

import DaemonProtocol
import Darwin
import Foundation

// MARK: - Env helpers

func envValue(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
}

func basename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// Reconstruct PATH excluding the directory containing our own
/// binary. Without this, the spawned `xcrun` would find us first
/// and recurse forever.
func sanitizedPathExcludingOurDir() -> String {
    let myExe = CommandLine.arguments.first.flatMap { argv0 -> String? in
        if argv0.hasPrefix("/") { return argv0 }
        var bufSize = UInt32(4_096)
        var buf = [Int8](repeating: 0, count: Int(bufSize))
        if _NSGetExecutablePath(&buf, &bufSize) == 0 {
            return buf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }
        }
        return nil
    } ?? ""
    let myDir = (myExe as NSString).deletingLastPathComponent
    let path = envValue("PATH") ?? ""
    let parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let filtered = parts.filter { dir in
        let resolvedDir = (dir as NSString).standardizingPath
        let resolvedMine = (myDir as NSString).standardizingPath
        return resolvedDir != resolvedMine && dir != myDir
    }
    return filtered.joined(separator: ":")
}

/// Find an executable named `name` on a PATH string.
func resolveExecutable(name: String, onPath path: String) -> String? {
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        var info = stat()
        if stat(candidate, &info) == 0, (info.st_mode & UInt16(S_IXUSR)) != 0 {
            return candidate
        }
    }
    if name == "xcrun", FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
        return "/usr/bin/xcrun"
    }
    return nil
}

// MARK: - Snapshot
//
// `ShimEvent`, `DeviceRecord`, `ResolvedDevice`, `detectEvent`,
// `resolveDevice`, the flag tables, and `skipFlagsConsumingValues`
// live in `EventDetection.swift` so the `ShimTests` target can call
// them from a nonisolated test context (Swift 6 marks every
// main.swift top-level decl `@MainActor`). `listAllDevices` stays
// here because it shells out to `xcrun simctl list -j`; it can't
// be unit-tested without a host simctl anyway.

func listAllDevices(sanitizedPath: String) -> [DeviceRecord] {
    guard let xcrun = resolveExecutable(name: "xcrun", onPath: sanitizedPath) else { return [] }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: xcrun)
    task.arguments = ["simctl", "list", "devices", "-j"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    // stderr → /dev/null. Without this, a stderr Pipe nobody reads
    // can fill up on hosts where xcrun emits warnings and block
    // the child indefinitely. We don't surface simctl's stderr,
    // so just discarding it is correct.
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return [] }
    // Drain stdout BEFORE waitUntilExit: on dev hosts with many
    // runtimes/devices, `simctl list devices -j` writes more than
    // the pipe's buffer (16-64KB), and `wait` first would deadlock
    // the child trying to write past a full buffer. `readData-
    // ToEndOfFile` reads until the child closes stdout, which it
    // does on exit, so by the time this returns, the child is
    // either exited or finishing imminently, and waitUntilExit
    // completes near-instantly.
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
    var out: [DeviceRecord] = []
    for (runtime, devs) in devicesByRuntime {
        for dev in devs {
            out.append(
                DeviceRecord(
                udid: (dev["udid"] as? String) ?? "",
                name: (dev["name"] as? String) ?? "",
                state: (dev["state"] as? String) ?? "",
                runtime: runtime
            )
                )
        }
    }
    return out
}

// MARK: - Daemon notification

/// Post a sim state transition the shim observed: `simctl
/// boot|shutdown <spec>` succeeded and the snapshot diff resolved
/// which device flipped. Builds the event-specific fields and hands
/// them to `postShimEvent`, which owns the session creds, the
/// envelope, and the handshake.
func sendShimEvent(
    event: ShimEvent,
    resolved: ResolvedDevice,
    originalArgv: [String],
    invokedAs: String
) {
    postShimEvent([
        "event": event.kind.rawValue,
        "udid": resolved.udid,
        "deviceName": resolved.name,
        "runtime": resolved.runtime,
        "invokedAs": invokedAs,
        "argv": originalArgv
    ])
}

/// Post a physical-device contextual auto-attach: the shim saw a
/// `devicectl device install|process launch --device <spec>` succeed.
/// The daemon resolves `spec` to a connected device and mounts its pane
/// under this tab's session. Best-effort, same as the sim path.
func sendDeviceAttachEvent(
    spec: String,
    originalArgv: [String],
    invokedAs: String
) {
    postShimEvent([
        "event": ShimEventType.deviceAttach.rawValue,
        "deviceIdentifier": spec,
        "invokedAs": invokedAs,
        "argv": originalArgv
    ])
}

/// Build the canonical length-prefixed `shim.event` envelope from
/// `eventFields` (the event-specific keys; this adds the session creds)
/// and send it over the daemon UDS. Authenticates the connection first
/// because `shim.event` is `.session`-scoped. Shared by both the sim
/// transition path and the device-attach path.
func postShimEvent(_ eventFields: [String: Any]) {
    guard let sock = envValue(DeviceTermEnv.daemonSock),
        let session = envValue(DeviceTermEnv.session),
        let cap = envValue(DeviceTermEnv.sessionCap),
        !sock.isEmpty, !session.isEmpty, !cap.isEmpty else {
        if envValue("DEVICETERM_DEBUG_SHIM") == "1" {
            writeStderr("deviceterm-shim: missing daemon env (sock/session/cap); skipping notify\n")
        }
        return
    }

    var params = eventFields
    params["sessionId"] = session
    params["cap"] = cap
    // Canonical wire via the shared `DaemonProtocol` module, same
    // envelope/framing the daemon and GUI client speak. RPCEnvelope
    // sorts JSON object keys; the daemon decodes order-agnostically
    // and no test pins the shim's output bytes.
    guard let paramsData = try? JSONSerialization.data(
        withJSONObject: params,
        options: []
    ) else { return }
    let eventEnvelope = RPCEnvelope(
        // Arbitrary id; the shim doesn't read responses, but the
        // daemon's envelope decoder requires a well-formed UInt32.
        id: UInt32.random(in: 0...UInt32(Int32.max)),
        type: .request,
        method: RPCMethod.shimEvent.rawValue,
        body: .params(paramsData)
    )
    guard let eventFrame = try? RPCFraming.encode(eventEnvelope.encode())
    else { return }

    // Build the connection-auth handshake frame. Without this
    // preceding `session.authenticate`, the dispatcher silently
    // rejects every shim post with `error.unauthorized`: sims
    // never get pane attribution, the GUI's discovery poll
    // never sees them, panes never get created.
    guard let authParams = try? JSONSerialization.data(
        withJSONObject: [
        "sessionId": session,
        "cap": cap
        ],
        options: []
        ) else { return }
    let authEnvelope = RPCEnvelope(
        id: UInt32.random(in: 0...UInt32(Int32.max)),
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(authParams)
    )
    guard let authFrame = try? RPCFraming.encode(authEnvelope.encode())
    else { return }

    // Connect, authenticate, and, only once the daemon confirms the auth
    // succeeded, send the event. The auth response MUST be decoded: with
    // kernel terminal provenance, `session.authenticate` can return
    // `notReadyCode` (-32002) when the tab's terminal anchor hasn't been bound
    // yet (a GUI/daemon restart briefly re-opens the window). Sending the event
    // on a connection the daemon didn't authenticate would be silently rejected
    // at the scope gate and the sim would lose its attribution. So we retry the
    // whole handshake on `notReadyCode`, send the event only on `.result`, and
    // give up otherwise. Any non-retryable authentication/event error or
    // transport failure is terminal.
    let maxRetries = 10
    var attempt = 0
    while true {
        let outcome = shimAuthenticateAndSend(
            sock: sock,
            authFrame: authFrame,
            eventFrame: eventFrame
        )
        switch outcome {
        case .sent, .hardFailure:
            return

        case .notReady:
            guard attempt < maxRetries else { return }
            attempt += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

private enum ShimAuthOutcome {
    /// Auth succeeded and the event was sent.
    case sent
    /// The daemon returned `notReadyCode`: retry the whole handshake.
    case notReady
    /// Any non-retryable authentication/event error or transport failure.
    case hardFailure
}

/// One handshake attempt: connect, send auth, decode the auth response, and
/// (only on success) send the event. A fresh fd per attempt re-runs the auth
/// handshake cleanly. Draining + decoding the auth response is also the
/// happens-before barrier the two-frame flow needs; reading it guarantees the
/// daemon's auth turn completed before the event write.
private func shimAuthenticateAndSend(
    sock: String,
    authFrame: Data,
    eventFrame: Data
) -> ShimAuthOutcome {
    guard let fd = try? UDSClientSocket.connect(to: sock) else { return .hardFailure }
    defer { UDSClientSocket.close(fd) }
    do {
        try UDSClientSocket.writeAll(fd: fd, data: authFrame)
        let authPayload = try readOneFrame(fd: fd, timeoutSeconds: 2)
        if case let .error(err) = try RPCEnvelope.decode(authPayload).body {
            return err.code == -32_002 ? .notReady : .hardFailure
        }
        // Send the event AND drain its acknowledgement. The anchor can be
        // revoked between the auth turn and the event turn (a GUI disconnect
        // fires the per-request re-check), which rejects the event with
        // `notReadyCode`. Reading the ack lets us retry the whole handshake in
        // that window instead of silently dropping the attribution; any other
        // outcome (`.result`, or a definitive error) is terminal.
        try UDSClientSocket.writeAll(fd: fd, data: eventFrame)
        let eventPayload = try readOneFrame(fd: fd, timeoutSeconds: 2)
        if case let .error(err) = try RPCEnvelope.decode(eventPayload).body {
            return err.code == -32_002 ? .notReady : .hardFailure
        }
        return .sent
    } catch {
        if envValue("DEVICETERM_DEBUG_SHIM") == "1" {
            writeStderr("deviceterm-shim: notify failed: \(error)\n")
        }
        return .hardFailure
    }
}

/// Block until one length-prefixed RPC frame arrives on `fd`, or
/// until the wall-clock timeout expires. Framing only: it returns
/// the raw payload and leaves the `RPCEnvelope` decode to the
/// caller, which branches on the daemon's answer.
func readOneFrame(fd: Int32, timeoutSeconds: Double) throws -> Data {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    var buffer = Data()
    while Date() < deadline {
        if let frame = try RPCFraming.decodeNext(from: buffer) {
            return frame.payload
        }
        if let chunk = try UDSClientSocket.readAvailable(fd: fd), !chunk.isEmpty {
            buffer.append(chunk)
            continue
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw NSError(
        domain: "deviceterm-shim",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey:
            "timed out waiting for daemon response"
        ]
    )
}

// MARK: - Signal forwarding

nonisolated(unsafe) var gChildPID: pid_t = 0

let forwardedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT]

func installForwarders() {
    for sig in forwardedSignals {
        signal(sig) { sig in
            if gChildPID > 0 { kill(gChildPID, sig) }
        }
    }
}

func restoreDefaults() {
    for sig in forwardedSignals { signal(sig, SIG_DFL) }
}

// MARK: - posix_spawn with inherited stdio

func spawnChildAndWait(realPath: String, argv: [String], envp: [String]) -> (exitCode: Int32, signal: Int32?) {
    var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    // No actions installed → child inherits our stdin/stdout/stderr.

    var attrs = posix_spawnattr_t(bitPattern: 0)
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }

    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    defer {
        for pointer in cArgv where pointer != nil { free(pointer) }
        for pointer in cEnvp where pointer != nil { free(pointer) }
    }

    var pid: pid_t = 0
    let spawnRC = realPath.withCString { realPathCStr in
        cArgv.withUnsafeBufferPointer { argvPtr in
            cEnvp.withUnsafeBufferPointer { envpPtr in
                posix_spawn(
                    &pid,
                    realPathCStr,
                    &fileActions,
                    &attrs,
                    UnsafeMutablePointer(mutating: argvPtr.baseAddress),
                    UnsafeMutablePointer(mutating: envpPtr.baseAddress)
                    )
            }
        }
    }
    guard spawnRC == 0 else {
        writeStderr("deviceterm-shim: posix_spawn failed: \(String(cString: strerror(spawnRC)))\n")
        return (127, nil)
    }
    gChildPID = pid
    installForwarders()

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    restoreDefaults()
    gChildPID = 0

    if (status & 0x7f) == 0 {
        return ((status >> 8) & 0xff, nil)
    }
    return (0, status & 0x7f)
}

// MARK: - main

let argv = CommandLine.arguments
let invokedAs = basename(argv.first ?? "")
let allowedNames: Set<String> = ["xcrun", "simctl"]
guard allowedNames.contains(invokedAs) else {
    writeStderr(
        "deviceterm-shim: invoked under unexpected name '\(invokedAs)' " +
        "(expected xcrun or simctl)\n"
    )
    exit(126)
}

let cleanPath = sanitizedPathExcludingOurDir()
guard let realBinary = resolveExecutable(name: invokedAs, onPath: cleanPath) else {
    // Bare `simctl` is the common stumble: it lives in
    // $(xcode-select -p)/usr/bin, which devs often don't have on
    // PATH. Point them at the canonical `xcrun simctl …` form
    // before suggesting they widen PATH; works regardless of
    // PATH config and matches Apple's own docs.
    if invokedAs == "simctl" {
        writeStderr(
            "deviceterm-shim: `simctl` is not on your PATH outside Xcode's developer dir;" +
            " use `xcrun simctl …` instead," +
            " or add $(xcode-select -p)/usr/bin to PATH.\n"
        )
    } else {
        writeStderr(
            "deviceterm-shim: cannot find real \(invokedAs) on PATH " +
            "(excluded our shim dir)\n"
        )
    }
    exit(127)
}

// Child env: ours, but with PATH stripped of our shim dir so
// descendant processes calling xcrun/simctl don't recurse through
// the shim.
var childEnv = ProcessInfo.processInfo.environment
childEnv["PATH"] = cleanPath
let envp = childEnv.map { "\($0.key)=\($0.value)" }

let debugShim = envValue("DEVICETERM_DEBUG_SHIM") == "1"
// A given invocation is either a simctl transition or a devicectl
// deploy/run, never both (disjoint binaries). The sim path needs a
// before/after `simctl list` diff; the device path carries the user's
// `--device` spec verbatim, no snapshot.
let prelimEvent = detectEvent(argv: argv, invokedAs: invokedAs)
let deviceAttachSpec = detectDeviceAttach(argv: argv, invokedAs: invokedAs)
let beforeSnapshot: [DeviceRecord] =
    prelimEvent != nil ? listAllDevices(sanitizedPath: cleanPath) : []
if debugShim, let event = prelimEvent {
    writeStderr(
        "deviceterm-shim: pre-snapshot event=\(event.kind.rawValue) " +
        "spec='\(event.deviceSpec)' devices=\(beforeSnapshot.count)\n"
    )
}
if debugShim, let spec = deviceAttachSpec {
    writeStderr("deviceterm-shim: device-attach trigger spec='\(spec)'\n")
}

let result = spawnChildAndWait(realPath: realBinary, argv: argv, envp: envp)

// Best-effort notification post-exit. Exit status takes precedence
// over notification outcome; a failed notify never blocks the
// user's command from completing.
if result.exitCode == 0, result.signal == nil {
    if let event = prelimEvent {
        let afterSnapshot = listAllDevices(sanitizedPath: cleanPath)
        if let resolved = resolveDevice(
            spec: event.deviceSpec,
            eventKind: event.kind,
            before: beforeSnapshot,
            after: afterSnapshot
        ) {
            if debugShim {
                writeStderr(
                    "deviceterm-shim: resolved udid=\(resolved.udid) name='\(resolved.name)'\n"
                )
            }
            sendShimEvent(
                event: event,
                resolved: resolved,
                originalArgv: argv,
                invokedAs: invokedAs
            )
            if debugShim { writeStderr("deviceterm-shim: notification sent\n") }
        } else if debugShim {
            writeStderr(
                "deviceterm-shim: device resolution failed " +
                "(no observable state change for '\(event.deviceSpec)')\n"
            )
        }
    } else if let spec = deviceAttachSpec {
        sendDeviceAttachEvent(
            spec: spec,
            originalArgv: argv,
            invokedAs: invokedAs
        )
        if debugShim { writeStderr("deviceterm-shim: device-attach notification sent\n") }
    } else if debugShim {
        writeStderr("deviceterm-shim: no event detected in argv \(argv)\n")
    }
}

if let sig = result.signal {
    // Re-raise the same signal in ourselves so the parent shell
    // sees the right termination.
    restoreDefaults()
    raise(sig)
    exit(128 + sig)
} else {
    exit(result.exitCode)
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// deviceterm-cli: short-lived RPC client for the deviceterm daemon.
//
// Symlinked as `deviceterm` into each tab's per-session `bin/`. Speaks
// the canonical `DaemonProtocol` wire: length-prefixed `RPCEnvelope`
// over the daemon's single Unix-domain socket. There is no bespoke
// per-session protocol; every client speaks the same wire.
//
// The CLI surface covers argv parsing, the daemon round-trip, and
// per-verb dispatch; see `CLICommands.swift` for the parser and
// `CommandDispatch.swift` for dispatch. Every wire round-trip goes
// through `roundTrip(method:params:)`.

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

func envValue(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
}

/// Print the terse usage block (top-level help cue) to stderr and
/// exit 1. Used for parse errors and unknown verbs; the caller got here
/// because something went wrong, so this points at the command list
/// rather than printing it. A mistyped verb should not bury the error
/// message under every command deviceterm has.
func usage() -> Never {
    writeStderr(
        """
    usage: deviceterm <command> [args...]

    Run `deviceterm help` for the command list, `deviceterm help <command>`
    to read one in full, and `deviceterm agents` for the workflow + triage
    guide.

    """
        )
    exit(1)
}

/// Spawn `/usr/bin/which <command>` and return the resolved absolute
/// path, or nil if `which` didn't find anything. Used by `deviceterm
/// doctor` to check whether `xcrun` resolves to the per-session shim.
/// The shim has to be first on PATH for boots to be intercepted.
func lookupOnPath(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let resolved = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (resolved?.isEmpty == false) ? resolved : nil
}

/// Resolve the daemon socket path from the env the tab shell carries
/// (`DEVICETERM_DAEMON_SOCK`), else the canonical default location.
func daemonSocketPath() -> String {
    if let sock = envValue(DeviceTermEnv.daemonSock), !sock.isEmpty { return sock }
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first
    return appSupport?
        .appendingPathComponent("deviceterm/daemon.sock")
        .path ?? "/tmp/deviceterm-daemon.sock"
}

// The round-trip path below is one request → one response: it frames an
// `RPCEnvelope`, sends it over the UDS, and reads framed bytes until a full
// response envelope decodes (or a bounded timeout elapses). It returns the
// response body `Data` for `.result`, or throws `CLIError` on `.error` /
// transport failure.
/// Read one framed response envelope from `fd`, blocking until a
/// full frame arrives or `deadline` passes. Extracted from `roundTrip`
/// so the auto-auth handshake can reuse the read path.
private func readOneEnvelope(
    fd: Int32,
    deadline: Date
) throws -> RPCEnvelope {
    var buffer = Data()
    while Date() < deadline {
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: fd)
        } catch {
            throw CLIError.transport("read failed: \(error)")
        }
        guard let chunk else {
            throw CLIError.transport("daemon closed the connection")
        }
        if chunk.isEmpty {
            usleep(10_000)
            continue
        }
        buffer.append(chunk)
        guard let (payload, _) = try? RPCFraming.decodeNext(from: buffer) else {
            continue
        }
        return try RPCEnvelope.decode(payload)
    }
    throw CLIError.transport("timed out waiting for daemon response")
}

/// Send `session.authenticate` over `fd` using the tab's env creds.
/// Returns silently on success. On auth failure, throws so the
/// caller surfaces the error rather than silently proceeding with a
/// connection the daemon won't honor for session-scoped methods.
private func authenticateConnection(
    fd: Int32,
    sessionId: String,
    cap: String,
    timeoutSeconds: Double
) throws {
    let params = SessionAuthenticateParams(sessionId: sessionId, cap: cap)
    let envelope = RPCEnvelope(
        id: 0,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(try JSONEncoder().encode(params))
    )
    let frame = try RPCFraming.encode(envelope.encode())
    do {
        try UDSClientSocket.writeAll(fd: fd, data: frame)
    } catch {
        throw CLIError.transport("auth write failed: \(error)")
    }
    let response = try readOneEnvelope(
        fd: fd,
        deadline: Date().addingTimeInterval(timeoutSeconds)
    )
    if case let .error(err) = response.body {
        throw CLIError.daemon(code: err.code, message: err.message)
    }
}

/// The daemon's "provenance not ready" code: session provenance or readiness
/// cannot yet be established, typically because terminal binding or
/// fresh-daemon restoration is incomplete (the GUI normally binds within a
/// round-trip of the tab opening; a daemon or GUI restart briefly re-opens the
/// window). It is retryable, distinct from a hard auth failure (`-32001`),
/// which is terminal. Kept as a literal because the CLI links `DaemonProtocol`,
/// not the daemon's `RPCMethodError`.
private let notReadyCode = -32_002

/// Connect, (auto-)authenticate, and round-trip one request, retrying briefly
/// on `notReadyCode`, the only retryable authentication outcome. Each retry
/// is a fresh connection (a new fd re-runs the auth handshake). A hard auth
/// failure (`-32001`) or any other error is surfaced immediately, never
/// retried.
func roundTrip(
    method: String,
    params: Data?,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds
) throws -> Data {
    let maxNotReadyRetries = 10
    var attempt = 0
    while true {
        do {
            return try roundTripOnce(method: method, params: params, timeoutSeconds: timeoutSeconds)
        } catch let CLIError.daemon(code, message) {
            guard code == notReadyCode, attempt < maxNotReadyRetries else {
                throw CLIError.daemon(code: code, message: message)
            }
            attempt += 1
            usleep(100_000)  // 100 ms between bounded retry attempts.
        }
    }
}

private func roundTripOnce(method: String, params: Data?, timeoutSeconds: Double) throws -> Data {
    let path = daemonSocketPath()
    let fd: Int32
    do {
        fd = try UDSClientSocket.connect(to: path)
    } catch {
        throw CLIError.transport("cannot connect to daemon at \(path): \(error)")
    }
    defer { UDSClientSocket.close(fd) }

    // Auto-auth when env carries tab creds. The daemon's dispatcher
    // requires every connection that wants .session-scoped methods
    // to have authenticated; pre-sending the auth handshake keeps
    // the CLI's per-call shape unchanged. Out-of-tab callers (no
    // env) skip this and only succeed against daemon-wide methods.
    if let session = envValue(DeviceTermEnv.session), !session.isEmpty,
        let cap = envValue(DeviceTermEnv.sessionCap), !cap.isEmpty {
        try authenticateConnection(
            fd: fd,
            sessionId: session,
            cap: cap,
            timeoutSeconds: timeoutSeconds
        )
    }

    let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
    let envelope = RPCEnvelope(id: 1, type: .request, method: method, body: body)
    let frame: Data
    do {
        frame = try RPCFraming.encode(envelope.encode())
    } catch {
        throw CLIError.transport("encode failed: \(error)")
    }
    do {
        try UDSClientSocket.writeAll(fd: fd, data: frame)
    } catch {
        throw CLIError.transport("write failed: \(error)")
    }

    let response = try readOneEnvelope(
        fd: fd,
        deadline: Date().addingTimeInterval(timeoutSeconds)
    )
    switch response.body {
    case let .result(data):
        return data

    case .empty:
        return Data()

    case let .error(err):
        throw CLIError.daemon(code: err.code, message: err.message)

    case .params:
        throw CLIError.transport("unexpected params body on a response")
    }
}

// MARK: - Pane resolution

/// Extract the params payload from a built request envelope, for handing
/// to `roundTrip(method:params:)`.
func paramsData(_ envelope: RPCEnvelope) -> Data? {
    if case let .params(data) = envelope.body { return data }
    return nil
}

/// Send a request envelope built by `CLICommands` and return the result
/// payload. The builders always set `method`; a nil here is a bug.
/// Response timeout for a gesture RPC that the daemon answers only after
/// the gesture finishes dispatching (`swipe` / `app-switcher`): the
/// gesture's own wall-clock plus generous headroom for the sim's
/// synchronous per-contact HID sends.
func gestureTimeout(_ gestureMs: Int) -> Double {
    5 + Double(max(0, gestureMs)) / 1_000.0 + 5
}

func send(
    _ envelope: RPCEnvelope,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds
) throws -> Data {
    guard let method = envelope.method else {
        throw CLIError.transport("internal error: request envelope has no method")
    }
    return try roundTrip(
        method: method,
        params: paramsData(envelope),
        timeoutSeconds: timeoutSeconds
    )
}

/// Read the tab's session credentials, throwing `CLIError.notInTab` when
/// the CLI is run outside a deviceterm tab. The throwing form used by the
/// typed command handlers; the driver maps `.notInTab` to stderr + exit 1.
func readSessionCredentials() throws -> (sessionId: String, cap: String) {
    guard let session = envValue(DeviceTermEnv.session), !session.isEmpty,
        let cap = envValue(DeviceTermEnv.sessionCap), !cap.isEmpty else {
        throw CLIError.notInTab(
            "not inside a deviceterm tab "
            + "(\(DeviceTermEnv.session) / \(DeviceTermEnv.sessionCap) unset)"
        )
    }
    return (session, cap)
}

/// Read the tab's session credentials, or exit with a clear message when
/// the CLI is run outside a deviceterm tab. Exit-based form for the verbs
/// that own their I/O and can't throw (`with-pane`); every other handler
/// uses the throwing `readSessionCredentials`.
func sessionCredentials() -> (sessionId: String, cap: String) {
    guard let creds = try? readSessionCredentials() else {
        writeStderr(
            "deviceterm: not inside a deviceterm tab "
            + "(\(DeviceTermEnv.session) / \(DeviceTermEnv.sessionCap) unset)\n"
            )
        exit(1)
    }
    return creds
}

/// The `sim` / `device` type label for a pane row, read from its
/// backend-neutral `target`. Defaults to `sim` when `target` is absent
/// (an older daemon that predates the discriminator), matching the
/// pre-device world where every pane was a sim.
func paneTypeLabel(_ entry: PanesListEntry) -> String {
    switch entry.target {
    case .device:
        return "device"

    case .sim, nil:
        return "sim"
    }
}

/// Render a pane roster as a `<shortId>  <type>  <key>` block, used
/// in the ambiguity / multi-pane error messages so the user sees both
/// sims and physical devices with their resolvable refs.
func paneRosterLines(_ panes: [PanesListEntry]) -> String {
    panes
        .map { entry in
            let shortId = entry.shortId ?? entry.paneId
            return "  \(shortId)\t\(paneTypeLabel(entry))\t\(entry.udid)"
        }
        .joined(separator: "\n")
}

// MARK: - Dispatch

let output = CLICommands.outputMode(for: CommandLine.arguments)

/// Render a `TabInfoPayload` as a column-aligned status block.
func formatTabInfo(_ payload: TabInfoPayload) -> String {
    var lines: [String] = []
    lines.append("session: \(payload.sessionId)")
    if let shortId = payload.shortId { lines.append("shortId: \(shortId)") }
    if let name = payload.name { lines.append("name:    \(name)") }
    lines.append("role:    \(payload.role)")
    lines.append("current: \(payload.isCurrent)")
    if let cwd = payload.cwd { lines.append("cwd:     \(cwd)") }
    if let label = payload.label { lines.append("label:   \(label)") }
    if payload.simPanes.isEmpty {
        lines.append("simPanes: (none)")
    } else {
        lines.append("simPanes:")
        for pane in payload.simPanes {
            let shortId = pane.shortId ?? "-"
            lines.append(
                "  \(shortId)\t\(pane.family)\t\(pane.displayName)\t\(pane.udid)"
            )
        }
    }
    return lines.joined(separator: "\n")
}

/// Render a `PaneInfoPayload` as a column-aligned status block.
func formatPaneInfo(_ payload: PaneInfoPayload) -> String {
    var lines: [String] = []
    lines.append("paneId:  \(payload.paneId)")
    lines.append("udid:    \(payload.udid)")
    if let shortId = payload.shortId { lines.append("shortId: \(shortId)") }
    if let name = payload.name { lines.append("name:    \(name)") }
    lines.append("display: \(payload.displayName)")
    lines.append("family:  \(payload.family)")
    lines.append("session: \(payload.linkedSessionId)")
    return lines.joined(separator: "\n")
}

/// Render the `devices.list` roster as one row per device:
/// `<id>\t<kind>\t<name>\t<model>\t<os>\t<state>\t<attachment>`. `model`
/// and `os` are physical-device only (sims show `-`) and disambiguate
/// two connected devices that share a name. The attachment column reads
/// `attached` (owner hidden by protection opacity) or `available`; an owner
/// session that the caller may see appears as `attached:<sessionId>`.
func formatDeviceRoster(_ roster: [DeviceRosterEntry]) -> String {
    roster
        .map { entry in
            let name = entry.name ?? "-"
            let model = entry.model ?? "-"
            let osVersion = entry.osVersion ?? "-"
            let state = entry.state ?? "-"
            let attachment: String
            if entry.attached {
                attachment = entry.ownerSessionId.map { "attached:\($0)" } ?? "attached"
            } else {
                attachment = "available"
            }
            return "\(entry.id)\t\(entry.kind.rawValue)\t\(name)\t\(model)"
                + "\t\(osVersion)\t\(state)\t\(attachment)"
        }
        .joined(separator: "\n")
}

/// Render a windows-list payload as one row per window:
/// `<marker>  <index>  <tabCount>  <selectedTabShortId>`.
func formatWindowsList(_ windows: [WindowInfoPayload]) -> String {
    windows
        .map { entry in
            let marker = entry.isKey ? "*" : " "
            let selected = entry.selectedTabShortId ?? "-"
            return "\(marker)\t\(entry.index)\t\(entry.tabCount)\t\(selected)"
        }
        .joined(separator: "\n")
}

/// Query `daemon.capabilities` against the running daemon. Returns
/// the response on success, nil if the daemon is unreachable or the
/// reply doesn't decode. Pure I/O; the caller decides what to render
/// when the daemon is down (typically: the no-session fallback view).
func fetchDaemonCapabilities() -> DaemonCapabilitiesResponse? {
    // No payload creds; `roundTrip` authenticates the connection from env,
    // and `daemon.capabilities` derives authority from that connection, not
    // the request body.
    guard let result = try? roundTrip(
        method: RPCMethod.daemonCapabilities.rawValue,
        params: nil,
        timeoutSeconds: 2
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(
        DaemonCapabilitiesResponse.self,
        from: result
    )
}

// MARK: - Meta / special verb helpers
//
// The doc-dump and diagnostic verbs (help, agents, doctor, version,
// dump-config, completions) return a CommandOutcome the driver
// renders. The streaming (`events`) and exec (`with-pane`) verbs own
// their I/O and terminate the process directly (`-> Never`).

/// `deviceterm --help` / `-h` / `help`, with or without a topic. The
/// command list and any known page write to stdout and exit 0; an
/// unknown topic fails with suggestions.
///
/// A topic page carries no role header, so it skips the daemon lookup
/// entirely: `deviceterm help crown` answers with the daemon stopped. The
/// bare command list does look the role up, because its header names it;
/// daemon-unreachable falls back to the env role so out-of-tab help still
/// works against a stopped daemon.
func helpOutcome(topic: String?) -> CommandOutcome {
    if let topic {
        guard let page = HelpText.page(forTopic: topic) else {
            return .failure(HelpText.unknownTopicMessage(topic))
        }
        return .stdout(page)
    }
    let helpCaps = fetchDaemonCapabilities()
    let helpRole = helpCaps?.role
        ?? envValue(DeviceTermEnv.sessionRole).flatMap(SessionRole.init)
    return .stdout(HelpText.render(role: helpRole))
}

/// `deviceterm doctor`: gather env/socket/daemon/session checks, hand
/// them to the pure `Doctor.*` primitives, and render the report. Exit
/// 0 when every check is ok/warn, 1 when any fails.
func doctorOutcome(output: OutputMode) -> CommandOutcome {
    var doctorChecks: [Doctor.Check] = []
    let sessionEnv = envValue(DeviceTermEnv.session)
    let capEnv = envValue(DeviceTermEnv.sessionCap)
    let shimDir = envValue(DeviceTermEnv.shimDir)
    doctorChecks.append(Doctor.sessionEnvCheck(value: sessionEnv))
    doctorChecks.append(Doctor.sessionCapCheck(value: capEnv))
    doctorChecks.append(
        Doctor.envPathCheck(
        name: DeviceTermEnv.daemonSock,
        value: envValue(DeviceTermEnv.daemonSock)
    )
        )
    doctorChecks.append(
        Doctor.envPathCheck(
        name: DeviceTermEnv.shimDir,
        value: shimDir
    )
        )
    doctorChecks.append(
        Doctor.xcrunCheck(
        path: lookupOnPath("xcrun"),
        shimDir: shimDir
    )
        )

    let socketPath = daemonSocketPath()
    let socketFd = try? UDSClientSocket.connect(to: socketPath)
    let socketReachable = socketFd != nil
    if let socketFd { UDSClientSocket.close(socketFd) }
    doctorChecks.append(Doctor.socketCheck(path: socketPath, reachable: socketReachable))

    if socketReachable {
        do {
            let pingResult = try roundTrip(
                method: RPCMethod.daemonPing.rawValue,
                params: nil
            )
            let pong = try JSONDecoder().decode(DaemonPingResponse.self, from: pingResult)
            doctorChecks.append(
                Doctor.pingCheck(
                wireVersion: pong.version,
                pid: Int(pong.pid),
                error: nil
            )
                )
        } catch {
            doctorChecks.append(
                Doctor.pingCheck(
                wireVersion: nil,
                pid: nil,
                error: "\(error)"
            )
                )
        }
    }

    // Session + linked-pane info (only meaningful inside a tab).
    var sessionInfo: Doctor.SessionInfo?
    var targets: [PanesListEntry]?
    if let sessionEnv, !sessionEnv.isEmpty, let capEnv, !capEnv.isEmpty, socketReachable {
        // tabs.list resolves the session's shortId + name AND
        // serves as the "session live in daemon" check: a stale
        // shell env after a daemon restart won't have its
        // sessionId in the list, and every session-scoped call
        // will fail.
        var foundInTabs = false
        if let tabsResult = try? roundTrip(
            method: RPCMethod.tabsList.rawValue,
            params: nil
        ),
            let entries = try? JSONDecoder().decode([TabsListEntry].self, from: tabsResult) {
            let entry = entries.first { $0.sessionId == sessionEnv }
            foundInTabs = (entry != nil)
            if let entry {
                sessionInfo = Doctor.SessionInfo(
                    sessionId: sessionEnv,
                    shortId: entry.shortId,
                    name: entry.name
                )
            }
        }
        doctorChecks.append(
            Doctor.sessionLivenessCheck(
            envSessionId: sessionEnv,
            foundInTabs: foundInTabs
        )
            )

        // panes.list: the linked sim panes are the "target
        // availability" axis AND the first call here that proves
        // session authorization (the cap is honored). Surface
        // failures explicitly rather than swallowing them, so a
        // stale/wrong cap doesn't slip past as a missing field.
        do {
            let panesRequest = try CLICommands.panesListRequest(
                sessionId: sessionEnv,
                cap: capEnv
            )
            let panesResult = try send(panesRequest)
            let panes = try JSONDecoder().decode(
                [PanesListEntry].self,
                from: panesResult
            )
            doctorChecks.append(Doctor.panesAuthorizationCheck(error: nil))
            targets = panes
        } catch CLIError.daemon(let code, let message) {
            doctorChecks.append(
                Doctor.panesAuthorizationCheck(
                error: "daemon \(code): \(message)"
            )
                )
        } catch {
            doctorChecks.append(
                Doctor.panesAuthorizationCheck(
                error: "\(error)"
            )
                )
        }
    }

    // Capabilities lookup populates the method-availability axis.
    // Reuses the in-tab creds (if present) so an agent sees its own
    // allowed set. Daemon-unreachable → role + allowedMethods stay
    // nil and formatHuman renders the fallback line.
    let doctorCaps = fetchDaemonCapabilities()
    let doctorReport = Doctor.Report(
        checks: doctorChecks,
        session: sessionInfo,
        targets: targets,
        role: doctorCaps?.role
            ?? envValue(DeviceTermEnv.sessionRole).flatMap(SessionRole.init),
        allowedMethods: doctorCaps?.allowedMethods
    )
    switch output {
    case .human:
        return CommandOutcome(
            stdout: Data(Doctor.formatHuman(doctorReport).utf8),
            exitCode: doctorReport.ok ? 0 : 1
        )

    case .json:
        do {
            return CommandOutcome(
                stdout: try encodeJSONReceipt(doctorReport),
                exitCode: doctorReport.ok ? 0 : 1
            )
        } catch {
            return .failure("failed to encode JSON receipt: \(error)")
        }
    }
}

/// `deviceterm with-pane <ref> <cmd…>`: resolve the pane, inject
/// `DEVICETERM_TARGET_PANE`, and exec the child with inherited stdio,
/// mirroring the child's exit code. Owns its I/O and never returns.
func withPaneExec(ref: String, cmd: [String]) -> Never {
    let creds = sessionCredentials()
    let withPaneKey: String
    do {
        let request = try CLICommands.panesListRequest(
            sessionId: creds.sessionId,
            cap: creds.cap
        )
        let panesData = try send(request)
        let panes = try JSONDecoder().decode([PanesListEntry].self, from: panesData)
        switch PaneRefResolver.resolve(ref, in: panes) {
        case let .entry(entry):
            withPaneKey = entry.udid

        case .sentinel, .notFound:
            writeStderr("deviceterm: no device pane matching '\(ref)' in this tab\n")
            writeStderr("  run `deviceterm panes list` to see available panes\n")
            exit(1)

        case let .ambiguous(hits):
            writeStderr("deviceterm: '\(ref)' is ambiguous; matches:\n")
            writeStderr(paneRosterLines(hits) + "\n")
            exit(1)
        }
    } catch CLIError.daemon(let code, let message) {
        writeStderr("deviceterm: daemon error \(code): \(message)\n")
        exit(1)
    } catch {
        writeStderr("deviceterm: \(error)\n")
        exit(1)
    }

    // Spawn the child via `/usr/bin/env` so PATH lookup applies to
    // the requested binary; inherit stdin/stdout/stderr; exit with
    // the child's exit code.
    var childEnv = ProcessInfo.processInfo.environment
    childEnv[DeviceTermEnv.targetPane] = withPaneKey
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = cmd
    child.environment = childEnv
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    do {
        try child.run()
    } catch {
        writeStderr("deviceterm with-pane: failed to spawn '\(cmd[0])': \(error)\n")
        exit(127)
    }
    child.waitUntilExit()
    // Mirror exec-like semantics: signal-terminated children
    // surface as `128 + signum` (shell convention) so wrapping
    // scripts can distinguish an orderly `exit 15` from a SIGTERM.
    exit(
        CLICommands.mapChildExitCode(
        status: child.terminationStatus,
        reason: child.terminationReason
    )
        )
}

/// `deviceterm version`: public CLI release, bundled RPC wire, live daemon
/// wire (via ping), and macOS versions. Daemon-unreachable is non-fatal
/// (`daemon: nil`).
func versionOutcome(output: OutputMode) -> CommandOutcome {
    var daemonVersion: String?
    let versionSocketFd = try? UDSClientSocket.connect(to: daemonSocketPath())
    if let versionSocketFd {
        UDSClientSocket.close(versionSocketFd)
        if let result = try? roundTrip(
            method: RPCMethod.daemonPing.rawValue,
            params: nil
        ),
            let pong = try? JSONDecoder().decode(DaemonPingResponse.self, from: result) {
            daemonVersion = pong.version
        }
    }
    let versionReport = VersionReport(
        deviceterm: VersionReportFormat.deviceTermCLIVersion,
        daemon: daemonVersion,
        rpcWire: DaemonProtocolInfo.wireVersion,
        macOS: VersionReportFormat.macOSVersionString()
    )
    switch output {
    case .human:
        return .stdout(VersionReportFormat.formatHuman(versionReport))

    case .json:
        return jsonOutcome(versionReport)
    }
}

/// `deviceterm dump-config`: parse `~/.config/deviceterm/config` (if
/// present) and report every recognized key with its value + source.
func dumpConfigOutcome(output: OutputMode) -> CommandOutcome {
    let configPath = XDGPaths.deviceTermConfig()
    let configText = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    let fileEntries = DumpConfig.parseFile(configText)
    let configReport = DumpConfig.buildReport(fileEntries: fileEntries)
    switch output {
    case .human:
        return .stdout(DumpConfig.formatHuman(configReport))

    case .json:
        return jsonOutcome(configReport)
    }
}

/// `deviceterm events`: subscribe to `daemon.events` and print one JSON
/// object per event until the daemon closes the connection or the
/// process is signalled. The stream is JSON by design (no `--json`).
/// Owns its I/O and never returns.
func eventsStream() -> Never {
    let eventsPath = daemonSocketPath()
    let creds: (session: String, cap: String)? = {
        guard let session = envValue(DeviceTermEnv.session), !session.isEmpty,
            let cap = envValue(DeviceTermEnv.sessionCap), !cap.isEmpty else { return nil }
        return (session, cap)
    }()

    // Connect + (auto-)authenticate, retrying on `notReadyCode` exactly like
    // `roundTrip`; the streaming path has its own one-shot connection, so it
    // must replicate the retry rather than inherit it. Each retry reconnects
    // (a fresh fd re-runs the auth handshake). `-32001` (out-of-tab) and any
    // other error are terminal. `.session`-scoped `daemon.events` needs a tab
    // session; out-of-tab callers (no env creds) skip auth and get the clear
    // scope-gate message below.
    var eventsFd: Int32 = -1
    var attempt = 0
    let maxNotReadyRetries = 10
    // Connect + authenticate + subscribe + read the subscription's FIRST
    // response as ONE retryable handshake. `notReadyCode` (-32002) can surface
    // at authentication OR at the `daemon.events` dispatch (the anchor can be
    // revoked between auth and subscribe), so both stages retry; otherwise a
    // subscription-stage -32002 would exit terminally.
    //
    // ONE persistent buffer spans the handshake's first-frame read AND the
    // streaming loop: if the subscription ack and the first event arrive in the
    // same read, decoding just the ack leaves the event's bytes in the buffer
    // for the loop below, rather than discarding them.
    var eventsBuffer = Data()
    handshake: while true {
        eventsBuffer.removeAll(keepingCapacity: true)  // fresh per (re)connect
        do {
            eventsFd = try UDSClientSocket.connect(to: eventsPath)
        } catch {
            writeStderr("deviceterm: cannot connect to daemon at \(eventsPath): \(error)\n")
            exit(1)
        }
        if let creds {
            do {
                try authenticateConnection(
                    fd: eventsFd,
                    sessionId: creds.session,
                    cap: creds.cap,
                    timeoutSeconds: AppCommandDeadline.cliRequestTimeoutSeconds
                )
            } catch let CLIError.daemon(code, _) where code == notReadyCode && attempt < maxNotReadyRetries {
                UDSClientSocket.close(eventsFd)
                attempt += 1
                usleep(100_000)
                continue handshake
            } catch {
                writeStderr("deviceterm: authentication failed: \(error)\n")
                exit(1)
            }
        }
        // Subscribe and read the first response (the ack, or an immediate
        // rejection), the dispatch-stage half of the handshake.
        do {
            let frame = try RPCFraming.encode(
                RPCEnvelope(id: 1, type: .request, method: RPCMethod.daemonEvents.rawValue, body: .empty).encode()
            )
            try UDSClientSocket.writeAll(fd: eventsFd, data: frame)
            // Read the first frame into the SHARED buffer, consuming ONLY that
            // frame; any trailing bytes (e.g. an event batched with the ack)
            // stay buffered for the streaming loop.
            let firstDeadline = Date().addingTimeInterval(5)
            var firstFrame: RPCEnvelope?
            while Date() < firstDeadline {
                if let (payload, consumed) = try? RPCFraming.decodeNext(from: eventsBuffer) {
                    eventsBuffer.removeFirst(consumed)
                    firstFrame = try RPCEnvelope.decode(payload)
                    break
                }
                guard let chunk = try UDSClientSocket.readAvailable(fd: eventsFd) else {
                    writeStderr("deviceterm: daemon closed the connection\n")
                    exit(1)
                }
                if chunk.isEmpty { usleep(10_000); continue }
                eventsBuffer.append(chunk)
            }
            guard let first = firstFrame else {
                writeStderr("deviceterm: timed out waiting for subscription ack\n")
                exit(1)
            }
            if case let .error(err) = first.body {
                if err.code == notReadyCode, attempt < maxNotReadyRetries {
                    UDSClientSocket.close(eventsFd)
                    attempt += 1
                    usleep(100_000)
                    continue handshake
                }
                if err.code == -32_001 {
                    writeStderr(
                        "deviceterm events requires an authenticated, live "
                            + "deviceterm tab session\n"
                    )
                } else {
                    writeStderr("deviceterm: daemon error \(err.code): \(err.message)\n")
                }
                exit(1)
            }
            // Established. An early event frame is printed; the ack
            // (`.result`/`.empty`) is silently dropped.
            if case let .params(data) = first.body, first.type == .event {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            break handshake
        } catch {
            writeStderr("deviceterm: subscribe failed: \(error)\n")
            exit(1)
        }
    }
    defer { UDSClientSocket.close(eventsFd) }

    // `eventsBuffer` carries over from the handshake; it may already hold an
    // event that arrived batched with the subscription ack.
    while true {
        // Drain every complete frame ALREADY buffered BEFORE blocking on
        // another read. Otherwise an event coalesced with the ack (already in
        // the buffer) would sit undecoded until the next byte arrives, which
        // may never come.
        for outcome in drainEventFrames(from: &eventsBuffer) {
            switch outcome {
            case let .event(data):
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))

            case .subscriptionAck:
                break

            case .unauthorizedSession:
                writeStderr(
                    "deviceterm events requires an authenticated, live "
                        + "deviceterm tab session\n"
                )
                exit(1)

            case let .daemonError(code, message):
                writeStderr("deviceterm: daemon error \(code): \(message)\n")
                exit(1)
            }
        }
        // No complete frame left; read another chunk.
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: eventsFd)
        } catch {
            writeStderr("deviceterm: read failed: \(error)\n")
            exit(1)
        }
        guard let chunk else { exit(0) }  // daemon EOF, clean close
        if chunk.isEmpty {
            usleep(10_000)  // nothing buffered; poll the fd again
            continue
        }
        eventsBuffer.append(chunk)
    }
}

/// Decode + classify EVERY complete frame in `buffer`, consuming them (leaving
/// any partial tail). Pure so the coalesced-frame behavior is testable: a
/// buffer holding the ack AND the first event yields both, so the streaming
/// loop draining this before its next read never strands a coalesced event.
func drainEventFrames(from buffer: inout Data) -> [EventFrameOutcome] {
    var outcomes: [EventFrameOutcome] = []
    while let (payload, consumed) = try? RPCFraming.decodeNext(from: buffer) {
        buffer.removeFirst(consumed)
        guard let env = try? RPCEnvelope.decode(payload) else { continue }
        switch env.body {
        case let .error(err):
            outcomes.append(
                err.code == -32_001
                    ? .unauthorizedSession
                    : .daemonError(code: err.code, message: err.message)
            )

        case let .params(data):
            if env.type == .event { outcomes.append(.event(data)) }

        case .result, .empty:
            outcomes.append(.subscriptionAck)
        }
    }
    return outcomes
}

/// `deviceterm completions install <shell>`: write the per-shell
/// completion script to its conventional autoload path and print the
/// install path + a one-line activation hint.
func completionsInstallOutcome(shell: Completions.Shell) -> CommandOutcome {
    let home = NSHomeDirectory()
    let installPath = Completions.defaultInstallPath(for: shell, homeDir: home)
    let installURL = URL(fileURLWithPath: installPath)
    let parentDir = installURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )
        try Completions.script(for: shell).write(
            to: installURL,
            atomically: true,
            encoding: .utf8
        )
    } catch {
        return .failure(
            "failed to install \(shell.rawValue) "
            + "completions at \(installPath): \(error)"
        )
    }
    return .stdout(
        "installed \(shell.rawValue) completions: \(installPath)\n"
        + Completions.activationHint(for: shell, installPath: installPath) + "\n"
    )
}

// The single dispatch entry point. `run` renders every verb to a
// CommandOutcome (or terminates directly for the streaming / exec
// verbs); the driver writes stdout / stderr and exits.
let command = CLICommands.parse(CommandLine.arguments)
let outcome = run(command, transport: UDSTransport(), output: output)
if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(outcome.stdout) }
if let message = outcome.stderr { writeStderr("deviceterm: \(message)\n") }
exit(outcome.exitCode)

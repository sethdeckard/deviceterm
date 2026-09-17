// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
        // A topic naming a declared command renders that command's own
        // page. It has to: the declaration is the grammar, so a
        // hand-written page for the same verb can contradict the parser
        // and leave a reader wrong rather than merely under-informed.
        // Verbs the tree does not declare, and the concept topics, keep
        // the written pages.
        if let command = CommandTree.command(for: topic.split(separator: " ").map(String.init)) {
            return .stdout(DeviceTerm.helpMessage(for: command))
        }
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

        // `device.list` is daemon-wide, so this runs out of tab too, where the
        // session checks below are skipped. It is also the only call here that
        // reaches the enumeration, which is the point: a wedged service still
        // answers the ping and fails this. The daemon caches its device
        // snapshot briefly, so a probe moments after a good read can answer
        // from that cache without touching CoreSimulator; this catches a wedge
        // that has outlasted the cache, not every wedge.
        //
        // Sent unauthenticated even in a tab. `roundTrip` otherwise pre-sends
        // the env credentials, and a stale capability or a rejected terminal
        // provenance would then fail here rather than at the session checks
        // below, reporting CoreSimulator as wedged and recommending a restart
        // that stops every simulator on the login. The method needs no
        // session, so the probe does not carry one.
        let probe: Doctor.CoreSimulatorProbe
        do {
            let scope = try JSONSerialization.data(
                withJSONObject: ["scope": DeviceListScope.all.rawValue]
            )
            let listResult = try roundTrip(
                method: RPCMethod.deviceList.rawValue,
                params: scope,
                authenticate: false
            )
            let devices = try JSONDecoder().decode(
                [DeviceListEntry].self,
                from: listResult
            )
            probe = .answered(count: devices.count)
        } catch CLIError.daemon(_, let message, _) {
            // The daemon returned an error for device.list; relay its message.
            // It already separates a bounded-read timeout from an enumeration
            // error, and re-deriving that here would mean matching on prose.
            probe = .enumerationFailed(message)
        } catch {
            // Transport, framing, or decode. The enumeration outcome is
            // unknown, so this must not carry the restart guidance.
            probe = .inconclusive("\(error)")
        }
        doctorChecks.append(Doctor.coreSimulatorCheck(probe))
    }

    // Session + linked-pane details (only meaningful inside a tab).
    var sessionInfo: Doctor.SessionInfo?
    var targets: [PanesListEntry]?
    if let sessionEnv, !sessionEnv.isEmpty, let capEnv, !capEnv.isEmpty, socketReachable {
        // The daemon-direct device-pane roster authenticates the session and
        // supplies the target availability axis without using the GUI's public
        // workspace projection.
        do {
            let panesRequest = try CLICommands.paneDeviceListRequest(
                sessionId: sessionEnv,
                cap: capEnv
            )
            let panesResult = try send(panesRequest)
            let panes = try JSONDecoder().decode(
                [PanesListEntry].self,
                from: panesResult
            )
            doctorChecks.append(Doctor.paneAuthorizationCheck(error: nil))
            doctorChecks.append(
                Doctor.sessionLivenessCheck(
                    envSessionId: sessionEnv,
                    authenticated: true
                )
            )
            sessionInfo = Doctor.SessionInfo(
                sessionId: sessionEnv,
                shortId: nil,
                name: nil
            )
            targets = panes
        } catch CLIError.daemon(let code, let message, _) {
            doctorChecks.append(
                Doctor.sessionLivenessCheck(
                    envSessionId: sessionEnv,
                    authenticated: false
                )
            )
            doctorChecks.append(
                Doctor.paneAuthorizationCheck(
                error: "daemon \(code): \(message)"
            )
                )
        } catch {
            doctorChecks.append(
                Doctor.sessionLivenessCheck(
                    envSessionId: sessionEnv,
                    authenticated: false
                )
            )
            doctorChecks.append(
                Doctor.paneAuthorizationCheck(
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
        allowedMethods: doctorCaps?.allowedMethods,
        automationGrant: doctorCaps?.automationGrant
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
            return .failure(
                code: .internalError,
                message: "failed to encode JSON receipt: \(error)"
            )
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
        let request = try CLICommands.paneDeviceListRequest(
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
            writeStderr("  run `deviceterm pane list` to see available panes\n")
            exit(1)

        case let .ambiguous(hits):
            writeStderr("deviceterm: '\(ref)' is ambiguous; matches:\n")
            writeStderr(paneRosterLines(hits) + "\n")
            exit(1)
        }
    } catch CLIError.daemon(let code, let message, _) {
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
                    deadline: Date().addingTimeInterval(AppCommandDeadline.cliRequestTimeoutSeconds)
                )
            } catch let CLIError.daemon(code, _, _)
                where code == notReadyCode && attempt < maxNotReadyRetries {
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
            while true {
                if let (payload, consumed) = try? RPCFraming.decodeNext(from: eventsBuffer) {
                    eventsBuffer.removeFirst(consumed)
                    firstFrame = try RPCEnvelope.decode(payload)
                    break
                }
                guard UDSClientSocket.waitReadable(fd: eventsFd, deadline: firstDeadline) else {
                    break
                }
                guard let chunk = try UDSClientSocket.readAvailable(fd: eventsFd) else {
                    writeStderr("deviceterm: daemon closed the connection\n")
                    exit(1)
                }
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
        // No complete frame left. Park in `poll` until the daemon sends the
        // next event or closes; a subscription has no deadline and no timer
        // work, so there is nothing for a periodic wakeup to do.
        _ = UDSClientSocket.waitReadable(fd: eventsFd, deadline: nil)
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: eventsFd)
        } catch {
            writeStderr("deviceterm: read failed: \(error)\n")
            exit(1)
        }
        guard let chunk else { exit(0) }  // daemon EOF, clean close
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

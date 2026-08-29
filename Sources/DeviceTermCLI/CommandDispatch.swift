// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Encode a receipt as stable sorted-key JSON with a trailing newline.
/// Sorted keys let tests pin the byte output; the trailing newline keeps
/// jq pipelines happy.
func encodeJSONReceipt(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

/// Encode `value` as a JSON success outcome, or a failing outcome
/// (stderr + exit 1) when the encode fails. Never yields silently-empty
/// stdout with a success code, which would break `--json` consumers.
func jsonOutcome(_ value: some Encodable) -> CommandOutcome {
    do {
        return .stdout(try encodeJSONReceipt(value))
    } catch {
        return .failure(
            code: .internalError,
            message: "failed to encode JSON receipt: \(error)"
        )
    }
}

/// Map one numeric daemon failure onto the public CLI code namespace.
private func daemonErrorCode(code: Int, message: String) -> CLIErrorCode {
    if let separator = message.firstIndex(of: ":") {
        let candidate = String(message[..<separator])
        if candidate.hasPrefix("intent."),
            candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) {
            return CLIErrorCode(rawValue: candidate)
        }
    }
    switch code {
    case -32_602:
        return .rpcInvalidParams

    case -32_601:
        return .rpcMethodNotFound

    case -32_600:
        return .rpcInvalidRequest

    case -32_020:
        return .paneBridgeFailed

    case -32_012:
        return .paneUnavailable

    case -32_011, -32_001:
        return .sessionUnauthorized

    case -32_002:
        return .sessionNotReady

    case -32_000:
        return .rpcServerError

    default:
        return .rpcError
    }
}

private func daemonErrorDetails(code: Int) -> Data? {
    try? JSONSerialization.data(withJSONObject: ["rpcCode": code], options: [.sortedKeys])
}

/// Map a thrown error to its stable code plus the existing stderr shape.
func errorOutcome(_ error: Error) -> CommandOutcome {
    switch error {
    case let CLIError.daemon(code, message):
        return .failure(
            code: daemonErrorCode(code: code, message: message),
            message: message,
            details: daemonErrorDetails(code: code),
            stderr: "daemon error \(code): \(message)"
        )

    case let CLIError.notInTab(message):
        return .failure(code: .sessionRequired, message: message)

    case let CLIError.classified(code, message):
        return .failure(code: code, message: message)

    case let error as DecodingError:
        return .failure(code: .protocolInvalidResponse, message: "\(error)")

    case let error as EncodingError:
        return .failure(code: .internalError, message: "\(error)")

    default:
        return .failure(code: .internalError, message: "\(error)")
    }
}

/// The single command dispatcher: render `command` to a `CommandOutcome`
/// the driver writes and exits on. Each verb becomes a handler that takes an
/// injected `CLITransport`, reads no globals it can't be handed, and returns
/// an outcome instead of writing to stdout/stderr and calling `exit`. Most
/// verbs return a value; the streaming (`events`) and exec (`with-pane`)
/// verbs own their I/O and terminate the process directly. Usage returns a
/// typed outcome so the driver can preserve its stderr block and add JSON.
///
/// Env-derived inputs (current session, credentials) are read here and
/// handed to the handlers so the handlers stay pure and unit-testable
/// against a fake transport.
///
/// Handlers throw `CLIError` for transport/daemon failures, which
/// `errorOutcome` maps to its stderr/exit shape, and return a failing
/// `CommandOutcome` for domain errors that carry a bespoke message
/// (e.g. "no live tab").
func run(
    _ command: CLICommand,
    transport: CLITransport,
    output: OutputMode
) -> CommandOutcome {
    do {
        switch command {
        case .tabsList:
            return try handleTabsList(
                transport: transport,
                output: output,
                currentSession: envValue(DeviceTermEnv.session)
            )

        case .tabsCurrent:
            return try handleTabsCurrent(
                transport: transport,
                output: output,
                currentSession: envValue(DeviceTermEnv.session)
            )

        case .panesList:
            return try handlePanesList(
                transport: transport,
                output: output,
                creds: try readSessionCredentials()
            )

        case .devicesList:
            // devices.list is session-scoped via connection auth; enforce
            // in-tab up front so an out-of-tab caller gets the same clear
            // "not inside a deviceterm tab" error every other verb gives.
            _ = try readSessionCredentials()
            return try handleDevicesList(transport: transport, output: output)

        case let .windowsList(all):
            return try handleWindowsList(all: all, transport: transport, output: output)

        case let .tap(pane, x, y):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                humanFields: { _ in [("x", String(x)), ("y", String(y))] },
                jsonReceipt: { resolved in
                    Receipt.Tap(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        x: x,
                        y: y
                    )
                },
                build: { try CLICommands.tapRequest(paneId: $0, x: x, y: y) }
            )

        case let .swipe(pane, fromX, fromY, toX, toY, durationMs, holdMs):
            return try handleSwipe(
                pane: pane,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                durationMs: durationMs,
                holdMs: holdMs,
                transport: transport,
                output: output
            )

        case let .appSwitcher(pane):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                // The daemon replies only after the whole edge gesture
                // (motion + dwell + synchronous HID samples) dispatches;
                // on a slow sim that legitimately exceeds the default 5s.
                timeoutSeconds: gestureTimeout(
                    AppSwitcherGesture.durationMs,
                    AppSwitcherGesture.holdMs
                ),
                humanFields: { _ in [] },
                jsonReceipt: { resolved in
                    Receipt.Tap(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        x: AppSwitcherGesture.fromX,
                        y: AppSwitcherGesture.fromY
                    )
                },
                build: {
                    try CLICommands.edgeSwipeRequest(
                        paneId: $0,
                        fromX: AppSwitcherGesture.fromX,
                        fromY: AppSwitcherGesture.fromY,
                        toX: AppSwitcherGesture.toX,
                        toY: AppSwitcherGesture.toY,
                        durationMs: AppSwitcherGesture.durationMs,
                        holdMs: AppSwitcherGesture.holdMs
                    )
                }
            )

        case let .longPress(pane, x, y, durationMs):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                // The daemon may hold the RPC open for the whole requested
                // duration, up to a minute. A preempted press ends sooner,
                // but the caller cannot know that in advance, so the wait
                // covers what it asked for.
                timeoutSeconds: gestureTimeout(
                    durationMs ?? GestureDuration.longPressDefaultMs
                ),
                humanFields: { _ in
                    var fields: [(String, String)] = [("x", String(x)), ("y", String(y))]
                    if let durationMs { fields.append(("durationMs", String(durationMs))) }
                    return fields
                },
                jsonReceipt: { resolved in
                    Receipt.LongPress(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        x: x,
                        y: y,
                        durationMs: durationMs
                    )
                },
                build: { try CLICommands.longPressRequest(paneId: $0, x: x, y: y, durationMs: durationMs) }
            )

        case let .pinch(pane, f1x, f1y, f2x, f2y, t1x, t1y, t2x, t2y, durationMs):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                // The RPC may stay open until both fingers have travelled
                // their whole path, so the wait covers the duration asked
                // for. Preemption can end it earlier.
                timeoutSeconds: gestureTimeout(
                    durationMs ?? GestureDuration.pinchDefaultMs
                ),
                // The eight coords would make the line illegible; surface
                // only `durationMs` (the parameter agents actually tune).
                humanFields: { _ in durationMs.map { [("durationMs", String($0))] } ?? [] },
                jsonReceipt: { resolved in
                    Receipt.Pinch(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        durationMs: durationMs
                    )
                },
                build: {
                    try CLICommands.pinchRequest(
                        paneId: $0,
                        fromF1X: f1x,
                        fromF1Y: f1y,
                        fromF2X: f2x,
                        fromF2Y: f2y,
                        toF1X: t1x,
                        toF1Y: t1y,
                        toF2X: t2x,
                        toF2Y: t2y,
                        durationMs: durationMs
                    )
                }
            )

        case let .button(pane, button):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                humanFields: { _ in [("button", button.rawValue)] },
                jsonReceipt: { resolved in
                    Receipt.Button(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        button: button.rawValue
                    )
                },
                build: { try CLICommands.buttonRequest(paneId: $0, button: button) }
            )

        case let .key(pane, keyCode, down):
            // Echo / encode the keyCode in `0x`-hex form to mirror the
            // parser (accepts both bases). kVK_* constants are
            // canonically hex in Apple's HIToolbox headers.
            let keyCodeHex = "0x" + String(keyCode, radix: 16, uppercase: false)
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                humanFields: { _ in [("keyCode", keyCodeHex), ("down", String(down))] },
                jsonReceipt: { resolved in
                    Receipt.Key(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        keyCode: keyCodeHex,
                        down: down
                    )
                },
                build: { try CLICommands.keyRequest(paneId: $0, keyCode: keyCode, down: down) }
            )

        case let .text(pane, text):
            // Echo `bytes=<count>`, not the typed content, which keeps the
            // receipt short and avoids re-printing sensitive input.
            let bytes = text.utf8.count
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                humanFields: { _ in [("bytes", String(bytes))] },
                jsonReceipt: { resolved in
                    Receipt.Text(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        bytes: bytes
                    )
                },
                build: { try CLICommands.textRequest(paneId: $0, text: text) }
            )

        case let .rotate(pane, target):
            // The receipt echoes what was asked for. A relative rotate
            // resolves against an orientation only the daemon holds, and the
            // ack doesn't carry the result, so reporting a resulting
            // orientation here would be a guess.
            let requested: [(String, String)] = switch target {
            case let .absolute(orientation):
                [("orientation", orientation.rawValue)]

            case let .relative(direction):
                [("direction", direction.rawValue)]
            }
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                humanFields: { _ in requested },
                jsonReceipt: { resolved in
                    Receipt.Rotate(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        orientation: target.orientation?.rawValue,
                        direction: target.direction?.rawValue
                    )
                },
                build: { try CLICommands.rotateRequest(paneId: $0, target: target) }
            )

        case let .crown(pane, delta, velocity, durationMs):
            return try sendResolved(
                ref: pane,
                output: output,
                transport: transport,
                // A positive duration sub-steps the rotation at ~60Hz and can
                // keep the RPC open through the final step; a generation
                // change stops it sooner. The default is 0, which resolves
                // to the plain floor.
                timeoutSeconds: gestureTimeout(
                    durationMs ?? GestureDuration.crownDefaultMs
                ),
                humanFields: { _ in
                    var fields: [(String, String)] = [("delta", String(delta))]
                    if let velocity { fields.append(("velocity", String(velocity))) }
                    if let durationMs { fields.append(("durationMs", String(durationMs))) }
                    return fields
                },
                jsonReceipt: { resolved in
                    Receipt.Crown(
                        udid: resolved.udid,
                        paneId: resolved.paneId,
                        shortId: resolved.shortId,
                        delta: delta,
                        velocity: velocity,
                        durationMs: durationMs
                    )
                },
                build: {
                    try CLICommands.crownRequest(
                        paneId: $0,
                        delta: delta,
                        velocity: velocity,
                        durationMs: durationMs
                    )
                }
            )

        case let .axTree(pane):
            // Shares the pane's accessibility queue with `ax sweep`, so it
            // can spend most of the sweep's scheduling budget queued
            // before its own walk starts.
            return try sendResolvedPrintingResult(
                ref: pane,
                transport: transport,
                timeoutSeconds: AXTimeout.response
            ) {
                try CLICommands.axTreeRequest(paneId: $0)
            }

        case let .axPoint(pane, x, y):
            // Queues behind a sweep the same way `ax tree` does.
            return try sendResolvedPrintingResult(
                ref: pane,
                transport: transport,
                timeoutSeconds: AXTimeout.response
            ) {
                try CLICommands.axPointRequest(paneId: $0, x: x, y: y)
            }

        case let .axSweep(pane, step, budgetMs):
            // The daemon answers only once the walk has stopped, and the wait
            // covers the largest budget it will honor, so `--budget` rides the
            // wire without the client having to size anything from it.
            return try sendResolvedPrintingResult(
                ref: pane,
                transport: transport,
                timeoutSeconds: AXTimeout.response
            ) {
                try CLICommands.axSweepRequest(paneId: $0, step: step, budgetMs: budgetMs)
            }

        case let .tabOpen(windowRef, cwd, cmd):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabOpenRequest(window: windowRef, cwd: cwd, cmd: cmd) },
                humanEcho: {
                    let label = windowRef.map(CLICommands.echoLabel) ?? "current"
                    return "ok window=\(label)"
                },
                jsonReceipt: {
                    let label = windowRef.map(CLICommands.echoLabel) ?? "current"
                    return Receipt.TabOpen(window: label)
                }
            )

        case let .tabClose(tabRef, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabCloseRequest(tab: tabRef, mode: mode) },
                humanEcho: { "ok tab=\(CLICommands.echoLabel(tabRef)) mode=\(mode)" },
                jsonReceipt: { Receipt.TabClose(tab: CLICommands.echoLabel(tabRef), mode: mode) }
            )

        case let .tabRename(tabRef, name):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabRenameRequest(tab: tabRef, name: name) },
                humanEcho: {
                    let target = CLICommands.echoLabel(tabRef)
                    return name.map { "ok tab=\(target) name=\($0)" }
                        ?? "ok tab=\(target) name=(auto)"
                },
                jsonReceipt: { Receipt.TabRename(tab: CLICommands.echoLabel(tabRef), name: name) }
            )

        case let .tabSelect(tabRef):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabSelectRequest(tab: tabRef) },
                humanEcho: { "ok tab=\(CLICommands.echoLabel(tabRef))" },
                jsonReceipt: { Receipt.TabSelect(tab: CLICommands.echoLabel(tabRef)) }
            )

        case let .tabInfo(tabRef):
            return try sendWorkspaceInfo(
                transport: transport,
                output: output,
                build: { try CLICommands.tabInfoRequest(tab: tabRef) },
                humanRender: { (payload: TabInfoPayload) in formatTabInfo(payload) }
            )

        case let .tabMove(tabRef, toIndex, toWindow):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: {
                    try CLICommands.tabMoveRequest(
                        tab: tabRef,
                        toIndex: toIndex,
                        toWindow: toWindow
                    )
                },
                humanEcho: {
                    var parts = ["ok tab=\(CLICommands.echoLabel(tabRef))"]
                    if let toWindow { parts.append("window=\(CLICommands.echoLabel(toWindow))") }
                    if let toIndex { parts.append("to=\(toIndex)") }
                    return parts.joined(separator: " ")
                },
                jsonReceipt: {
                    Receipt.TabMove(
                        tab: CLICommands.echoLabel(tabRef),
                        toIndex: toIndex,
                        toWindow: toWindow.map(CLICommands.echoLabel)
                    )
                }
            )

        case let .paneOpenTerminal(tabRef, cwd, cmd):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneOpenTerminalRequest(tab: tabRef, cwd: cwd, cmd: cmd) },
                humanEcho: {
                    let target = tabRef.map(CLICommands.echoLabel) ?? "current"
                    return "ok tab=\(target)"
                },
                jsonReceipt: {
                    let target = tabRef.map(CLICommands.echoLabel) ?? "current"
                    return Receipt.PaneOpenTerminal(tab: target)
                }
            )

        case let .paneClose(paneRef, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneCloseRequest(pane: paneRef, mode: mode) },
                humanEcho: { "ok pane=\(CLICommands.echoLabel(paneRef)) mode=\(mode)" },
                jsonReceipt: { Receipt.PaneClose(pane: CLICommands.echoLabel(paneRef), mode: mode) }
            )

        case let .paneRename(paneRef, name):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneRenameRequest(pane: paneRef, name: name) },
                humanEcho: {
                    let target = CLICommands.echoLabel(paneRef)
                    return name.map { "ok pane=\(target) name=\($0)" }
                        ?? "ok pane=\(target) name=(auto)"
                },
                jsonReceipt: { Receipt.PaneRename(pane: CLICommands.echoLabel(paneRef), name: name) }
            )

        case let .paneInfo(paneRef):
            return try sendWorkspaceInfo(
                transport: transport,
                output: output,
                build: { try CLICommands.paneInfoRequest(pane: paneRef) },
                humanRender: { (payload: PaneInfoPayload) in formatPaneInfo(payload) }
            )

        case let .paneMove(paneRef, toTabRef):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneMoveRequest(pane: paneRef, toTab: toTabRef) },
                humanEcho: {
                    "ok pane=\(CLICommands.echoLabel(paneRef)) "
                    + "toTab=\(CLICommands.echoLabel(toTabRef))"
                },
                jsonReceipt: {
                    Receipt.PaneMove(
                        pane: CLICommands.echoLabel(paneRef),
                        toTab: CLICommands.echoLabel(toTabRef)
                    )
                }
            )

        case let .deviceAttach(ref):
            return try handleDeviceAttach(ref: ref, transport: transport, output: output)

        case .windowOpen:
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowOpenRequest() },
                humanEcho: { "ok" },
                jsonReceipt: { Receipt.WindowOpen() }
            )

        case let .windowClose(windowRef, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowCloseRequest(window: windowRef, mode: mode) },
                humanEcho: { "ok window=\(CLICommands.echoLabel(windowRef)) mode=\(mode)" },
                jsonReceipt: {
                    Receipt.WindowClose(window: CLICommands.echoLabel(windowRef), mode: mode)
                }
            )

        case let .windowFocus(windowRef):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowFocusRequest(window: windowRef) },
                humanEcho: { "ok window=\(CLICommands.echoLabel(windowRef))" },
                jsonReceipt: { Receipt.WindowFocus(window: CLICommands.echoLabel(windowRef)) }
            )

        case let .tabSendInput(tabRef, text, typeDelay):
            // Paced typing is non-blocking on the GUI side: the ack
            // returns once the animation is enqueued, so the default
            // response timeout is fine regardless of how long the
            // string takes to type out.
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: {
                    try CLICommands.tabSendInputRequest(
                        tab: tabRef,
                        text: text,
                        typeDelayMillis: typeDelay
                    )
                },
                humanEcho: { "ok tab=\(CLICommands.echoLabel(tabRef)) bytes=\(text.utf8.count)" },
                jsonReceipt: {
                    Receipt.TabSendInput(
                        tab: CLICommands.echoLabel(tabRef),
                        bytes: text.utf8.count,
                        typeDelayMillis: typeDelay
                    )
                }
            )

        case let .tabCapture(tabRef):
            return try handleTabCapture(tabRef: tabRef, transport: transport, output: output)

        case let .tabSetProtected(tabRef, isProtected):
            // The GUI drives protection as an awaited transition, so the
            // result reports the daemon's real state: a definite rejection
            // throws here (surfaced as a failure), while a committed or
            // still-converging (`committed == false`) outcome comes back as
            // a `TabSetProtectedResult` we render honestly.
            let data = try transport.send(
                try CLICommands.tabSetProtectedRequest(tab: tabRef, isProtected: isProtected)
            )
            let result = try JSONDecoder().decode(TabSetProtectedResult.self, from: data)
            let label = CLICommands.echoLabel(tabRef)
            switch output {
            case .human:
                let line = result.committed
                    ? "ok tab=\(label) protected=\(result.isProtected)"
                    : "pending tab=\(label) protected=\(result.isProtected) (unconfirmed)"
                return .stdout(line + "\n")

            case .json:
                return .stdout(try encodeJSONReceipt(
                    Receipt.TabSetProtected(
                        tab: label,
                        isProtected: result.isProtected,
                        committed: result.committed
                    )
                ))
            }

        // Meta / special verbs. The doc-dump and diagnostic verbs return
        // a rendered outcome; `with-pane` and `events` own their I/O and
        // terminate directly (never returning here).
        case let .help(topic):
            return helpOutcome(topic: topic)

        case .agents:
            return .stdout(AgentsText.documentation)

        case .doctor:
            return doctorOutcome(output: output)

        case let .usage(message):
            return CLIUsage.outcome(message: message)

        case let .withPane(ref, cmd):
            withPaneExec(ref: ref, cmd: cmd)

        case .version:
            return versionOutcome(output: output)

        case .dumpConfig:
            return dumpConfigOutcome(output: output)

        case .events:
            eventsStream()

        case let .completionsInstall(shell):
            return completionsInstallOutcome(shell: shell)
        }
    } catch {
        return errorOutcome(error)
    }
}

// MARK: - Pane-targeted input helpers

/// Resolve the target device pane (sim or physical) over `transport`.
/// Resolution order: explicit `--pane <ref>` (tiered `PaneRefResolver`),
/// then the `DEVICETERM_TARGET_PANE` env key exported by `with-pane`
/// (exact key match, no tier shadowing), then the tab's sole pane.
/// Throws `CLIError.notInTab` out-of-tab and a typed pane-resolution
/// failure on ambiguity / no match, so JSON callers can branch without
/// parsing the diagnostic.
func resolvePane(
    ref: String?,
    transport: CLITransport,
    creds: (sessionId: String, cap: String)? = nil
) throws -> ResolvedPane {
    let creds = try creds ?? readSessionCredentials()
    let request = try CLICommands.panesListRequest(sessionId: creds.sessionId, cap: creds.cap)
    let result = try transport.send(request)
    let panes = try JSONDecoder().decode([PanesListEntry].self, from: result)

    func resolveGeneric(_ refValue: String) throws -> ResolvedPane {
        switch PaneRefResolver.resolve(refValue, in: panes) {
        case let .entry(pane):
            return ResolvedPane(paneId: pane.paneId, udid: pane.udid, shortId: pane.shortId)

        case let .ambiguous(hits):
            throw CLIError.paneAmbiguous(
                "'\(refValue)' is ambiguous in this tab; matches:\n"
                + paneRosterLines(hits)
            )

        case .sentinel, .notFound:
            throw CLIError.paneNotFound(
                "no pane matching '\(refValue)' in this tab; "
                + "run `deviceterm panes list`"
            )
        }
    }

    // 1. Explicit `--pane <ref>` flag.
    if let ref, !ref.isEmpty {
        return try resolveGeneric(ref)
    }
    // 2. Env fallback: `DEVICETERM_TARGET_PANE` holds a canonical key
    //    the `with-pane` wrapper already resolved, so match by key
    //    exactly (no tier shadowing).
    if let envKey = envValue(DeviceTermEnv.targetPane),
        !envKey.isEmpty {
        guard let pane = PaneRefResolver.exactKeyMatch(envKey, in: panes) else {
            throw CLIError.paneNotFound(
                "no pane for exported target \(envKey) in this tab"
            )
        }
        return ResolvedPane(paneId: pane.paneId, udid: pane.udid, shortId: pane.shortId)
    }
    // 3. No ref anywhere → the tab's sole pane, else a clear error.
    guard panes.count <= 1 else {
        throw CLIError.paneAmbiguous(
            "multiple panes in this tab; pass --pane <ref>:\n"
            + paneRosterLines(panes)
        )
    }
    guard let pane = panes.first else {
        throw CLIError.paneNotFound("no device pane in this tab")
    }
    return ResolvedPane(paneId: pane.paneId, udid: pane.udid, shortId: pane.shortId)
}

/// Resolve a pane, build the request, send it, and render the receipt.
/// Human mode returns the echo line `ok udid=… pane=… [key=value …]`;
/// JSON mode returns the per-command Receipt struct. The two closures
/// let each mode use the shape that fits best.
func sendResolved<R: Encodable>(
    ref: String?,
    output: OutputMode,
    transport: CLITransport,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds,
    creds: (sessionId: String, cap: String)? = nil,
    humanFields: (ResolvedPane) -> [(String, String)],
    jsonReceipt: (ResolvedPane) -> R,
    build: (String) throws -> RPCEnvelope
) throws -> CommandOutcome {
    let resolved = try resolvePane(ref: ref, transport: transport, creds: creds)
    let envelope = try build(resolved.paneId)
    _ = try transport.send(envelope, timeoutSeconds: timeoutSeconds)
    switch output {
    case .human:
        return .stdout(
            Echo.ok(
                udid: resolved.udid,
                pane: resolved.displayLabel,
                fields: humanFields(resolved)
            ) + "\n"
        )

    case .json:
        return .stdout(try encodeJSONReceipt(jsonReceipt(resolved)))
    }
}

/// Like `sendResolved`, but returns the daemon's JSON result verbatim
/// (for `ax.*`). Those commands aren't `pane.input.*`, so they carry no
/// echo line, since the JSON payload itself is the documented success shape.
func sendResolvedPrintingResult(
    ref: String?,
    transport: CLITransport,
    creds: (sessionId: String, cap: String)? = nil,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds,
    build: (String) throws -> RPCEnvelope
) throws -> CommandOutcome {
    let envelope = try build(try resolvePane(ref: ref, transport: transport, creds: creds).paneId)
    var result = try transport.send(envelope, timeoutSeconds: timeoutSeconds)
    result.append(0x0A)
    return .stdout(result)
}

/// `deviceterm swipe`: a custom handler because it decodes its own ack
/// shape (`SwipeAck`). The human echo prepends udid/pane to the
/// dispatched/steps/durationMs triple; the JSON receipt mirrors it.
/// The response wait scales with the gesture (motion + dwell), which
/// legitimately exceeds the default timeout for a long hold.
func handleSwipe(
    pane: String?,
    fromX: Double,
    fromY: Double,
    toX: Double,
    toY: Double,
    durationMs: Int?,
    holdMs: Int?,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil
) throws -> CommandOutcome {
    let resolved = try resolvePane(ref: pane, transport: transport, creds: creds)
    let envelope = try CLICommands.swipeRequest(
        paneId: resolved.paneId,
        fromX: fromX,
        fromY: fromY,
        toX: toX,
        toY: toY,
        durationMs: durationMs,
        holdMs: holdMs
    )
    // Motion and end dwell are separate phases the daemon validates and runs
    // independently, so the wait covers both rather than their capped sum.
    // The start dwell is the third such phase, omitted here because no flag
    // feeds it and `swipeRequest` therefore sends nil; a `--start-hold` would
    // have to be added to this list as well as to the request.
    let result = try transport.send(
        envelope,
        timeoutSeconds: gestureTimeout(
            durationMs ?? GestureDuration.swipeDefaultMs,
            holdMs ?? 0
        )
    )
    let ack = try JSONDecoder().decode(SwipeAck.self, from: result)
    switch output {
    case .human:
        return .stdout(
            Echo.ok(
                udid: resolved.udid,
                pane: resolved.displayLabel,
                fields: Echo.swipeFields(ack)
            ) + "\n"
        )

    case .json:
        return .stdout(try encodeJSONReceipt(
            Receipt.Swipe(
                udid: resolved.udid,
                paneId: resolved.paneId,
                shortId: resolved.shortId,
                dispatched: ack.dispatched?.rawValue,
                steps: ack.steps,
                durationMs: ack.durationMs
            )
        ))
    }
}

// MARK: - Workspace verb helpers

/// Build + send a mutating workspace verb, then render its receipt.
/// Human mode returns the `ok …` echo line; JSON mode returns the
/// per-verb Receipt struct. Errors throw to the driver.
func sendWorkspaceMutation<Receipt: Encodable>(
    transport: CLITransport,
    output: OutputMode,
    build: () throws -> RPCEnvelope,
    humanEcho: () -> String,
    jsonReceipt: () -> Receipt
) throws -> CommandOutcome {
    _ = try transport.send(try build())
    switch output {
    case .human:
        return .stdout(humanEcho() + "\n")

    case .json:
        return .stdout(try encodeJSONReceipt(jsonReceipt()))
    }
}

/// Build + send a read-only workspace verb and render the payload.
/// Human mode formats via `humanRender`; JSON mode returns the daemon's
/// payload bytes verbatim + a newline (preserving field ordering).
func sendWorkspaceInfo<Payload: Decodable>(
    transport: CLITransport,
    output: OutputMode,
    build: () throws -> RPCEnvelope,
    humanRender: (Payload) -> String
) throws -> CommandOutcome {
    let data = try transport.send(try build())
    switch output {
    case .human:
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return .stdout(humanRender(payload) + "\n")

    case .json:
        var out = data
        out.append(0x0A)
        return .stdout(out)
    }
}

/// `deviceterm device attach <ref>`: resolve the ref against the
/// devices.list roster, build the matching PaneTarget, and publish it on
/// the attach back-channel. A not-found / ambiguous ref is a domain
/// failure with a recovery hint. Enforces in-tab up front.
func handleDeviceAttach(
    ref: String,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil
) throws -> CommandOutcome {
    _ = try creds ?? readSessionCredentials()
    let roster = try JSONDecoder().decode(
        [DeviceRosterEntry].self,
        from: try transport.send(CLICommands.devicesListRequest())
    )
    let target: PaneTarget
    let echoId: String
    let echoKind: DeviceKind
    switch CLICommands.resolveDeviceAttach(ref: ref, roster: roster) {
    case let .target(resolvedTarget, id, kind):
        target = resolvedTarget
        echoId = id
        echoKind = kind

    case .notFound:
        return .failure(
            "no device matching '\(ref)'\n"
            + "  run `deviceterm devices list` to see available devices"
        )

    case let .ambiguous(ids):
        return .failure("'\(ref)' is ambiguous; matches: \(ids.joined(separator: ", "))")
    }
    _ = try transport.send(try CLICommands.deviceAttachRequest(target: target))
    switch output {
    case .human:
        return .stdout("ok target=\(echoId) kind=\(echoKind.rawValue)\n")

    case .json:
        return .stdout(try encodeJSONReceipt(
            Receipt.DeviceAttach(target: echoId, kind: echoKind.rawValue)
        ))
    }
}

/// `deviceterm tab capture`: human mode writes the captured text raw
/// (so a redirect saves the screen), appending a newline only when the
/// text doesn't already end with one; JSON mode emits the daemon's
/// payload verbatim + a newline.
func handleTabCapture(
    tabRef: Wire.TabRef,
    transport: CLITransport,
    output: OutputMode
) throws -> CommandOutcome {
    let data = try transport.send(try CLICommands.tabCaptureRequest(tab: tabRef))
    switch output {
    case .human:
        let payload = try JSONDecoder().decode(TabCapturePayload.self, from: data)
        var out = Data(payload.text.utf8)
        if !payload.text.hasSuffix("\n") { out.append(0x0A) }
        return .stdout(out)

    case .json:
        var out = data
        out.append(0x0A)
        return .stdout(out)
    }
}

// MARK: - Read-only listing handlers

/// `deviceterm tabs list`. Column shape marker\tshort_id\tname\t
/// sessionId\tlabel; `--json` emits an array of `TabsListRow`. The
/// current row is decided from `currentSession` (the caller's
/// `DEVICETERM_SESSION`), no daemon round-trip needed for it.
func handleTabsList(
    transport: CLITransport,
    output: OutputMode,
    currentSession: String?
) throws -> CommandOutcome {
    let result = try transport.send(CLICommands.tabsListRequest())
    let entries = try JSONDecoder().decode([TabsListEntry].self, from: result)
    switch output {
    case .human:
        return .lines(
            TabsListFormatter.formatList(
                entries: entries,
                currentSessionId: currentSession
            )
        )

    case .json:
        let rows = entries.map { entry in
            Receipt.TabsListRow(
                current: entry.sessionId == currentSession,
                shortId: entry.shortId,
                name: entry.name,
                displayTitle: entry.displayTitle,
                sessionId: entry.sessionId,
                label: entry.label
            )
        }
        return .stdout(try encodeJSONReceipt(rows))
    }
}

/// `deviceterm tabs current`: the row matching `DEVICETERM_SESSION`.
/// Out-of-tab or a stale session id is a domain error (stderr + exit 1)
/// with a recovery hint, regardless of output mode.
func handleTabsCurrent(
    transport: CLITransport,
    output: OutputMode,
    currentSession: String?
) throws -> CommandOutcome {
    guard let currentSession, !currentSession.isEmpty else {
        return .failure(
            code: .sessionRequired,
            message: "not inside a deviceterm tab (\(DeviceTermEnv.session) unset); "
                + "run `deviceterm tabs list` to see open tabs"
        )
    }
    let result = try transport.send(CLICommands.tabsListRequest())
    let entries = try JSONDecoder().decode([TabsListEntry].self, from: result)
    guard let entry = entries.first(where: { $0.sessionId == currentSession }) else {
        return .failure(
            "\(DeviceTermEnv.session)=\(currentSession) has no live tab; "
            + "the daemon may have restarted; try opening a fresh tab"
        )
    }
    switch output {
    case .human:
        return .stdout(TabsListFormatter.formatRow(entry: entry, isCurrent: true) + "\n")

    case .json:
        let row = Receipt.TabsListRow(
            current: true,
            shortId: entry.shortId,
            name: entry.name,
            displayTitle: entry.displayTitle,
            sessionId: entry.sessionId,
            label: entry.label
        )
        return .stdout(try encodeJSONReceipt(row))
    }
}

/// `deviceterm panes list`. Human columns paneId\tudid\tstate\tfamily\t
/// type (sim|device); `--json` emits the wire `PanesListEntry` array.
func handlePanesList(
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)
) throws -> CommandOutcome {
    let request = try CLICommands.panesListRequest(sessionId: creds.sessionId, cap: creds.cap)
    let result = try transport.send(request)
    let panes = try JSONDecoder().decode([PanesListEntry].self, from: result)
    switch output {
    case .human:
        return .lines(
            panes.map { pane in
                let family = DeviceFamily(wire: pane.family ?? "").rawValue
                return "\(pane.paneId)\t\(pane.udid)\t\(pane.state.rawValue)"
                    + "\t\(family)\t\(paneTypeLabel(pane))"
            }
        )

    case .json:
        return .stdout(try encodeJSONReceipt(panes))
    }
}

/// `deviceterm devices list`: the aggregate live roster. Human columns
/// via `formatDeviceRoster`; `--json` emits the `DeviceRosterEntry`
/// array verbatim.
func handleDevicesList(
    transport: CLITransport,
    output: OutputMode
) throws -> CommandOutcome {
    let roster = try JSONDecoder().decode(
        [DeviceRosterEntry].self,
        from: try transport.send(CLICommands.devicesListRequest())
    )
    switch output {
    case .human:
        return .stdout(formatDeviceRoster(roster) + "\n")

    case .json:
        return .stdout(try encodeJSONReceipt(roster))
    }
}

/// `deviceterm windows list [--all]`. Human rows via `formatWindowsList`;
/// `--json` emits the daemon's payload bytes verbatim (preserving field
/// order), each with a trailing newline.
func handleWindowsList(
    all: Bool,
    transport: CLITransport,
    output: OutputMode
) throws -> CommandOutcome {
    let data = try transport.send(try CLICommands.windowsListRequest(all: all))
    switch output {
    case .human:
        let payload = try JSONDecoder().decode([WindowInfoPayload].self, from: data)
        return .stdout(formatWindowsList(payload) + "\n")

    case .json:
        var out = data
        out.append(0x0A)
        return .stdout(out)
    }
}

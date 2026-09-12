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

private func daemonErrorDetails(code: Int, details: Data?) -> Data? {
    var object: [String: Any] = ["rpcCode": code]
    if let details,
        let supplied = try? JSONSerialization.jsonObject(with: details) as? [String: Any] {
        object.merge(supplied) { _, supplied in supplied }
    }
    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Map a thrown error to its stable code plus the existing stderr shape.
func errorOutcome(_ error: Error) -> CommandOutcome {
    switch error {
    case let CLIError.daemon(code, message, details):
        return .failure(
            code: daemonErrorCode(code: code, message: message),
            message: message,
            details: daemonErrorDetails(code: code, details: details),
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
        case .devicesList:
            // devices.list is session-scoped via connection auth; enforce
            // in-tab up front so an out-of-tab caller gets the same clear
            // "not inside a deviceterm tab" error every other verb gives.
            _ = try readSessionCredentials()
            return try handleDevicesList(transport: transport, output: output)

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

        case let .tapElement(pane, query, timeoutMs):
            return try handleTapElement(
                pane: pane,
                query: query,
                timeoutMs: timeoutMs,
                transport: transport,
                output: output
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
            return try handleRotate(
                pane: pane,
                target: target,
                transport: transport,
                output: output
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

        case let .waitPane(pane, state, timeoutMs):
            return try handleWaitPane(
                pane: pane,
                state: state,
                timeoutMs: timeoutMs,
                transport: transport,
                output: output
            )

        case let .waitAX(pane, query, timeoutMs, printMode, state):
            return try handleWaitAX(
                pane: pane,
                query: query,
                timeoutMs: timeoutMs,
                transport: transport,
                output: output,
                printMode: printMode,
                state: state
            )

        case let .waitSurfaceQuiescent(pane, settleMs, timeoutMs):
            return try handleWaitSurfaceQuiescent(
                pane: pane,
                settleMs: settleMs,
                timeoutMs: timeoutMs,
                transport: transport,
                output: output
            )

        case let .waitOrientation(pane, orientation, timeoutMs):
            return try handleWaitOrientation(
                pane: pane,
                orientation: orientation,
                timeoutMs: timeoutMs,
                transport: transport,
                output: output
            )

        case let .windowList(all):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.windowListRequest(all: all) },
                humanRender: formatWorkspaceWindows
            )

        case let .windowShow(window):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.windowShowRequest(window: window) },
                humanRender: formatWorkspaceWindowDetail
            )

        case .windowOpen:
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowOpenRequest() }
            )

        case let .windowFocus(window):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowFocusRequest(window: window) }
            )

        case let .windowClose(window, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.windowCloseRequest(window: window, mode: mode) }
            )

        case let .tabList(window, all):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.tabListRequest(window: window, all: all) },
                humanRender: formatWorkspaceTabs
            )

        case let .tabShow(tab):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.tabShowRequest(tab: tab) },
                humanRender: formatWorkspaceTabDetail
            )

        case let .tabOpen(window, cwd, command):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: {
                    try CLICommands.tabOpenRequest(
                        window: window,
                        cwd: cwd,
                        command: command
                    )
                }
            )

        case let .tabFocus(tab):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabFocusRequest(tab: tab) }
            )

        case let .tabClose(tab, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabCloseRequest(tab: tab, mode: mode) }
            )

        case let .tabRename(tab, name):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabRenameRequest(tab: tab, name: name) }
            )

        case let .tabMove(tab, window, index):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabMoveRequest(tab: tab, window: window, index: index) }
            )

        case let .tabProtect(tab):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabProtectionRequest(tab: tab, protected: true) }
            )

        case let .tabUnprotect(tab):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.tabProtectionRequest(tab: tab, protected: false) }
            )

        case let .paneList(tab):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.paneListRequest(tab: tab) },
                humanRender: formatWorkspacePanes
            )

        case let .paneShow(pane):
            return try sendWorkspaceData(
                transport: transport,
                output: output,
                build: { try CLICommands.paneShowRequest(pane: pane) },
                humanRender: formatWorkspacePane
            )

        case let .paneSplit(pane, direction):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneSplitRequest(pane: pane, direction: direction) }
            )

        case let .paneFocus(pane):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneFocusRequest(pane: pane) }
            )

        case let .paneClose(pane, mode):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneCloseRequest(pane: pane, mode: mode) }
            )

        case let .paneRename(pane, name):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: { try CLICommands.paneRenameRequest(pane: pane, name: name) }
            )

        case let .paneSendInput(pane, text, typeDelay):
            return try sendWorkspaceMutation(
                transport: transport,
                output: output,
                build: {
                    try CLICommands.paneSendInputRequest(
                        pane: pane,
                        text: text,
                        typeDelayMs: typeDelay
                    )
                }
            )

        case let .paneCaptureText(pane):
            return try handlePaneCaptureText(pane: pane, transport: transport, output: output)

        case let .deviceAttach(ref):
            return try handleDeviceAttach(ref: ref, transport: transport, output: output)

        // Meta / special verbs. The doc-dump and diagnostic verbs return
        // a rendered outcome; `with-pane` and `events` own their I/O and
        // terminate directly (never returning here).
        case let .help(topic):
            return helpOutcome(topic: topic)

        case .agents:
            return .stdout(AgentsText.documentation)

        case .doctor:
            return doctorOutcome(output: output)

        case let .cleanExit(text):
            return .stdout(text + "\n")

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
    let request = try CLICommands.paneDeviceListRequest(sessionId: creds.sessionId, cap: creds.cap)
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
                + "run `deviceterm pane list`"
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

func handleRotate(
    pane: String?,
    target: RotationTarget,
    transport: CLITransport,
    output: OutputMode,
    creds: (sessionId: String, cap: String)? = nil
) throws -> CommandOutcome {
    let resolved = try resolvePane(ref: pane, transport: transport, creds: creds)
    let response = try transport.send(
        try CLICommands.rotateRequest(paneId: resolved.paneId, target: target),
        timeoutSeconds: RotationConfirmationDeadline.clientResponseTimeoutSeconds
    )
    let result = try JSONDecoder().decode(RotateResult.self, from: response)
    guard result.success else {
        return rotateFailureOutcome(result, requested: target)
    }
    guard result.status == .confirmed,
        let targetOrientation = result.targetOrientation,
        let observedOrientation = result.observedOrientation else {
        throw CLIError.classified(
            code: .protocolInvalidResponse,
            message: "pane.input.rotate returned an invalid success result"
        )
    }
    var fields: [(String, String)] = []
    if let orientation = target.orientation { fields.append(("orientation", orientation.rawValue)) }
    if let direction = target.direction { fields.append(("direction", direction.rawValue)) }
    fields.append(("targetOrientation", targetOrientation.rawValue))
    fields.append(("observedOrientation", observedOrientation.rawValue))
    switch output {
    case .human:
        return .stdout(
            Echo.ok(udid: resolved.udid, pane: resolved.displayLabel, fields: fields) + "\n"
        )

    case .json:
        return .stdout(
            try encodeJSONReceipt(
                Receipt.Rotate(
                    udid: resolved.udid,
                    paneId: resolved.paneId,
                    shortId: resolved.shortId,
                    orientation: target.orientation?.rawValue,
                    direction: target.direction?.rawValue,
                    targetOrientation: targetOrientation.rawValue,
                    observedOrientation: observedOrientation.rawValue
                )
            )
        )
    }
}

private func rotateFailureOutcome(_ result: RotateResult, requested: RotationTarget) -> CommandOutcome {
    let code: CLIErrorCode
    let message: String
    switch result.status {
    case .unconfirmed:
        code = .rotateUnconfirmed
        message = "the device did not confirm the requested rotation"

    case .confirmationUnsupported:
        code = .rotateConfirmationUnsupported
        message = "rotation confirmation is unsupported by this daemon or device"

    case .refused:
        code = .inputRefused
        message = "the device refused the rotation"

    case .unavailable:
        code = .paneUnavailable
        message = "the pane became unavailable before rotation confirmation"

    case .confirmed:
        code = .protocolInvalidResponse
        message = "pane.input.rotate returned a confirmed failure result"
    }
    return .failure(
        code: code,
        message: message,
        details: rotateFailureDetails(result, requested: requested)
    )
}

private func rotateFailureDetails(_ result: RotateResult, requested: RotationTarget) -> Data? {
    var details: [String: Any] = [:]
    if let orientation = requested.orientation { details["requestedOrientation"] = orientation.rawValue }
    if let direction = requested.direction { details["requestedDirection"] = direction.rawValue }
    if let target = result.targetOrientation { details["targetOrientation"] = target.rawValue }
    if let observed = result.observedOrientation { details["observedOrientation"] = observed.rawValue }
    if let deadlineMs = result.deadlineMs { details["deadlineMs"] = deadlineMs }
    if let reason = result.reason { details["reason"] = reason.rawValue }
    return try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
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

/// Build and send a workspace mutation, then render the committed receipt
/// supplied by the GUI. The CLI never reconstructs mutation results from the
/// requested arguments.
func sendWorkspaceMutation(
    transport: CLITransport,
    output: OutputMode,
    build: () throws -> RPCEnvelope
) throws -> CommandOutcome {
    let data = try transport.send(
        try build(),
        timeoutSeconds: AppCommandDeadline.workspaceCLIRequestTimeoutSeconds
    )
    switch output {
    case .human:
        let receipt = try JSONDecoder().decode(WorkspaceMutationReceipt.self, from: data)
        return .stdout(formatWorkspaceMutation(receipt) + "\n")

    case .json:
        var out = data
        out.append(0x0A)
        return .stdout(out)
    }
}

/// Build and send a read-only workspace verb and render the payload.
/// Human mode formats via `humanRender`; JSON mode returns the daemon's
/// payload bytes verbatim plus a newline.
func sendWorkspaceData<Payload: Decodable>(
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
    switch CLICommands.resolveDeviceAttach(ref: ref, roster: roster) {
    case let .target(resolvedTarget, _, _):
        target = resolvedTarget

    case .notFound:
        return .failure(
            "no device matching '\(ref)'\n"
            + "  run `deviceterm devices list` to see available devices"
        )

    case let .ambiguous(ids):
        return .failure("'\(ref)' is ambiguous; matches: \(ids.joined(separator: ", "))")
    }
    return try sendWorkspaceMutation(
        transport: transport,
        output: output,
        build: { try CLICommands.deviceAttachRequest(target: target) }
    )
}

/// `deviceterm pane capture-text`: human mode writes captured text raw;
/// JSON mode emits the pane plus text payload.
func handlePaneCaptureText(
    pane: String,
    transport: CLITransport,
    output: OutputMode
) throws -> CommandOutcome {
    let data = try transport.send(try CLICommands.paneCaptureTextRequest(pane: pane))
    switch output {
    case .human:
        let payload = try JSONDecoder().decode(WorkspaceCaptureResult.self, from: data)
        var out = Data(payload.text.utf8)
        if !payload.text.hasSuffix("\n") { out.append(0x0A) }
        return .stdout(out)

    case .json:
        var out = data
        out.append(0x0A)
        return .stdout(out)
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

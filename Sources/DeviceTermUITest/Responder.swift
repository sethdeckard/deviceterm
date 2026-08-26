// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Maps one decoded request to a JSON reply.
///
/// Dispatch only: the work lives in `CaptureService` and friends, so this
/// stays a thin, readable switch. `async` because capture is async; the
/// resident bridges that back to its blocking socket worker.
struct Responder: Sendable {
    /// Methods deliberately left as stubs. Empty today: every
    /// `UITestMethod` has a handler.
    ///
    /// Kept because the drift guard in `UITestIPCTests` reads it, so a
    /// newly-added method must be either implemented or declared here.
    /// Hard-coding a method name in that test once let a "hermetic" test
    /// quietly exercise ScreenCaptureKit, passing only because no GUI
    /// happened to be up.
    static let unimplementedMethods: Set<UITestMethod> = []

    func respond(to request: UITestRequest) async -> Data {
        switch request.method {
        case .ping:
            return UITestReply.ok([
                "resident": true,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "tool": "deviceterm-uitest"
            ])

        case .captureWindow:
            return await captureWindow(request)

        case .captureStatusItem:
            return await captureStatusItem(request)

        case .axDump:
            return axDump(request)

        case .driveKey:
            return driveKey(request)

        case .driveClick:
            return driveClick(request)

        case .doctor:
            return doctor()
        }
    }

    // MARK: - Input drive

    private func driveKey(_ request: UITestRequest) -> Data {
        guard let text = request.params["shortcut"] else {
            return UITestReply.failure("drive.key requires a 'shortcut'")
        }
        let bundleID = request.params["bundleId"] ?? DeviceTermBundleID.app
        do {
            let shortcut = try KeyShortcutParser.parse(text)
            let (_, pid) = try AXDumpService.applicationElement(bundleID: bundleID)
            try InputDriver.postKey(shortcut, toPID: pid)
            return UITestReply.ok(["shortcut": text, "bundleId": bundleID, "pid": Int(pid)])
        } catch {
            return UITestReply.failure(describeDrive(error))
        }
    }

    private func driveClick(_ request: UITestRequest) -> Data {
        let bundleID = request.params["bundleId"] ?? DeviceTermBundleID.app
        do {
            if let needle = request.params["ax"] {
                try InputDriver.pressElement(matching: needle, bundleID: bundleID)
                return UITestReply.ok(["ax": needle, "bundleId": bundleID])
            }
            guard
                let rawX = request.params["x"], let x = Double(rawX),
                let rawY = request.params["y"], let y = Double(rawY)
            else {
                return UITestReply.failure("drive.click requires 'x' and 'y', or 'ax'")
            }
            let point = try InputDriver.click(normalizedX: x, normalizedY: y, bundleID: bundleID)
            return UITestReply.ok([
                "bundleId": bundleID,
                "x": x,
                "y": y,
                "screenX": Double(point.x),
                "screenY": Double(point.y)
            ])
        } catch {
            return UITestReply.failure(describeDrive(error))
        }
    }

    private func describeDrive(_ error: Error) -> String {
        switch error {
        case let KeyShortcutError.unknownToken(token):
            return "unknown key or modifier: \(token)"

        case KeyShortcutError.missingKey:
            return "shortcut needs exactly one non-modifier key (e.g. cmd+t)"

        case let KeyShortcutError.multipleKeys(first, second):
            return "shortcut names two keys (\(first), \(second)); use one"

        case KeyShortcutError.empty:
            return "shortcut is empty"

        case let InputDriverError.noMatchingElement(needle):
            return "no accessibility element titled \(needle)"

        case let InputDriverError.elementDoesNotSupportPress(needle):
            return "\(needle) exists but is not pressable"

        case let InputDriverError.pressFailed(needle):
            return "pressing \(needle) failed"

        case let InputDriverError.noWindow(bundleID):
            return "\(bundleID) has no window to click in"

        case let InputDriverError.pointOutOfRange(x, y):
            return "click point (\(x), \(y)) is outside the unit square"

        default:
            return describeAX(error)
        }
    }

    // MARK: - Accessibility

    private func axDump(_ request: UITestRequest) -> Data {
        let bundleID = request.params["bundleId"] ?? DeviceTermBundleID.app
        do {
            let result = try AXDumpService.dump(bundleID: bundleID)
            return UITestReply.ok([
                "bundleId": bundleID,
                "truncated": result.truncated,
                "tree": result.tree
            ])
        } catch {
            return UITestReply.failure(describeAX(error))
        }
    }

    private func describeAX(_ error: Error) -> String {
        switch error {
        case let AXDumpError.appNotRunning(bundleID):
            return "no running application with bundle id \(bundleID)"

        case AXDumpError.notTrusted:
            return "accessibility is not granted to the process running this harness"

        case let AXDumpError.unreadableRoot(bundleID):
            return "\(bundleID) is running but its accessibility tree is unreadable"

        case let AXDumpError.ambiguousTarget(bundleID, pids):
            return ambiguousTargetMessage(bundleID: bundleID, pids: pids)

        default:
            return "ax dump failed: \(error)"
        }
    }

    /// Names the pids so the caller can tell the instances apart. Stays
    /// generic: `bundleId` is a request parameter, so the target is not
    /// necessarily deviceterm's own app or daemon.
    private func ambiguousTargetMessage(bundleID: String, pids: [pid_t]) -> String {
        let list = pids.map(String.init).joined(separator: ", ")
        return "\(bundleID) is running \(pids.count) times (pids \(list)); "
            + "the harness will not guess which target you meant. Stop the "
            + "extra instance and retry."
    }

    // MARK: - Doctor

    /// Report the *resident's* identity and grants. The grants that matter
    /// are this process's, not the calling client's, so the check has to
    /// run here.
    private func doctor() -> Data {
        let screenRecording = TCCStatus.hasScreenRecording
        let accessibility = TCCStatus.hasAccessibility

        var fields: [String: Any] = [
            "resident": true,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundleId": Bundle.main.bundleIdentifier ?? "(unbundled)",
            "bundlePath": Bundle.main.bundlePath,
            "screenRecording": screenRecording,
            "accessibility": accessibility
        ]

        var missing: [String] = []
        if !screenRecording { missing.append("Screen Recording") }
        if !accessibility { missing.append("Accessibility") }
        if !missing.isEmpty {
            fields["error"] = "missing grants: \(missing.joined(separator: ", "))"
        }
        return UITestReply.result(ok: missing.isEmpty, fields)
    }

    // MARK: - Capture

    private func captureWindow(_ request: UITestRequest) async -> Data {
        guard let path = request.params["out"] else {
            return UITestReply.failure("capture.window requires an 'out' path")
        }
        let bundleID = request.params["bundleId"] ?? DeviceTermBundleID.app
        do {
            let outcome = try await CaptureService.captureWindow(bundleID: bundleID, out: path)
            return reply(for: outcome, extra: ["bundleId": bundleID])
        } catch {
            return UITestReply.failure(describe(error))
        }
    }

    private func captureStatusItem(_ request: UITestRequest) async -> Data {
        guard let path = request.params["out"] else {
            return UITestReply.failure("capture.status-item requires an 'out' path")
        }
        do {
            switch try await CaptureService.captureStatusItem(out: path) {
            case let .present(outcome):
                return reply(for: outcome, extra: ["present": true])

            case .absent:
                // Not an error: no status item == the daemon owns zero
                // booted sims, which is the hidden-at-zero state to verify.
                return UITestReply.ok(["present": false])
            }
        } catch {
            return UITestReply.failure(describe(error))
        }
    }

    private func reply(for outcome: CaptureOutcome, extra: [String: Any]) -> Data {
        var fields: [String: Any] = [
            "path": outcome.path,
            "width": outcome.width,
            "height": outcome.height,
            "scale": outcome.scale
        ]
        for (key, value) in extra { fields[key] = value }
        return UITestReply.ok(fields)
    }

    /// Turn a capture error into a message that names the likely fix.
    /// A missing Screen Recording grant is by far the most common cause,
    /// and its ScreenCaptureKit error text alone doesn't say so.
    private func describe(_ error: Error) -> String {
        switch error {
        case let CaptureError.noMatchingWindow(bundleID):
            return "no on-screen window owned by \(bundleID)"

        case let CaptureError.ambiguousTarget(bundleID, pids):
            return ambiguousTargetMessage(bundleID: bundleID, pids: pids)

        case let CaptureError.outputNotAFile(path):
            return "--out \(path) exists and is not a regular file; give a file path"

        case let CaptureError.outputUnreadable(path, underlying):
            return "--out \(path) can't be inspected (\(underlying))"

        case let CaptureError.cleanupFailed(path, underlying):
            return "couldn't remove a stale capture at \(path) (\(underlying))"

        case let CaptureError.captureFailed(underlying):
            return "capture failed (\(underlying)). Is Screen Recording granted "
                + "to the process running this harness?"

        default:
            return "capture failed: \(error)"
        }
    }
}

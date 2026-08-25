// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorShellOut: synchronous wrappers around the `xcrun simctl`
// subcommands that don't belong on the daemon's RPC surface. Per the
// project philosophy (cat E in docs/PHILOSOPHY.md), wholesale shelling-out
// to `simctl` for actions Apple already exposes is preferable to
// reimplementing them as new RPC verbs: the daemon owns the sim's
// runtime state (HID/AX/display), `simctl` owns one-shot device
// administration (erase / install / `simctl io` capture).
//
// Each entry point is a small wrapper around `Process`, with no new
// daemon types, no wire surface. Callers run them from the GUI
// process; the running sim's ownership is preserved because the
// caller frames the shutdown→action→boot sequence and the boot leg
// re-asserts `(sessionId, capability)` through the daemon's
// `device.boot` RPC.

import Foundation

enum SimulatorShellOut {
    private final class ProcessBox: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }
    }

    private static let commandQueue = DispatchQueue(
        label: "com.deviceterm.simctl-command",
        attributes: .concurrent
    )
    private static let recordingWaitQueue = DispatchQueue(
        label: "com.deviceterm.simctl-recording-wait",
        attributes: .concurrent
    )

    /// `xcrun simctl erase <udid>`: wipe the device back to factory
    /// state. The sim must already be shut down; callers sequence
    /// shutdown → erase → boot. Throws on non-zero exit.
    ///
    /// Async-only: a real `simctl erase` can take many seconds
    /// (Apple's tool blocks while CoreSimulator writes the data
    /// container back to factory), and `Process.waitUntilExit()` is
    /// synchronous. The implementation waits on a Dispatch worker so the
    /// caller's actor and Swift's cooperative executor remain free while the
    /// wipe runs. A sync variant would invite call-site bugs that silently
    /// freeze the GUI.
    static func eraseContent(udid: String) async throws {
        try await runOffPool(arguments: ["simctl", "erase", udid])
    }

    /// `xcrun simctl io <udid> screenshot <path>`: write a PNG of
    /// the current sim frame to `path`. Same off-pool discipline
    /// as `eraseContent`; throws on non-zero exit.
    static func captureScreenshot(udid: String, to path: String) async throws {
        try await runOffPool(
            arguments: ["simctl", "io", udid, "screenshot", path]
        )
    }

    /// `xcrun simctl install <udid> <path>`: install a built .app
    /// bundle on the sim. simctl install only accepts unpacked .app
    /// bundles; the GUI picker enforces that so this entry point
    /// doesn't need to validate. Same off-pool discipline as
    /// `eraseContent`; throws on non-zero exit so the caller can
    /// surface simctl's stderr (on failure the error usually
    /// identifies what's wrong with the bundle: missing
    /// architecture, mismatched runtime, etc.).
    static func installApp(udid: String, path: String) async throws {
        try await runOffPool(
            arguments: ["simctl", "install", udid, path]
        )
    }

    /// `xcrun simctl io <udid> recordVideo <path>`: start an mp4
    /// recording that continues until the returned Process is
    /// interrupted (SIGINT). Throws on launch failure; the long-lived
    /// recording itself runs asynchronously in the child process. The
    /// caller is responsible for stopping it via `stopRecording(_:)`.
    static func startRecording(udid: String, to path: String) throws -> Process {
        let process = Process()
        process.launchPath = "/usr/bin/xcrun"
        process.arguments = ["simctl", "io", udid, "recordVideo", path]
        // Route both streams to /dev/null rather than `Pipe()`, because a
        // Pipe whose reader nobody drains deadlocks the writer once
        // its kernel buffer (64KB on macOS) fills. simctl io
        // recordVideo prints status output during long recordings,
        // and an unread pipe would eventually wedge the child;
        // FileHandle.nullDevice forwards to /dev/null at the kernel
        // level so writes always succeed.
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Stop a recording started by `startRecording`. simctl io
    /// recordVideo flushes its mp4 trailer and exits cleanly on
    /// SIGINT; the Dispatch-backed wait avoids blocking `@MainActor` or a
    /// cooperative-executor worker during the final flush (sub-second on most
    /// recordings but not guaranteed bounded). No-op if the process has
    /// already exited.
    static func stopRecording(_ process: Process) async {
        guard process.isRunning else { return }
        process.interrupt()
        let box = ProcessBox(process)
        await withCheckedContinuation { continuation in
            recordingWaitQueue.async {
                box.process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private static func runOffPool(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandQueue.async {
                do {
                    continuation.resume(returning: try runSync(arguments: arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous core, isolated from the public surface and run only on
    /// `commandQueue`.
    nonisolated private static func runSync(arguments: [String]) throws {
        let process = Process()
        process.launchPath = "/usr/bin/xcrun"
        process.arguments = arguments
        // Capture stderr so the surfaced error message has a
        // chance of being useful; stdout is dropped (simctl
        // commands here don't produce useful output on success).
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SimulatorShellOutError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: message
            )
        }
    }
}
